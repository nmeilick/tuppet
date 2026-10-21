//! Facts sampled from a session's pty rather than read from its output: the
//! foreground process group and its program's name, and whether the
//! terminal reads input by line and echoes it. A line read without echo is
//! most likely a password prompt (hidden input).
//!
//! The pty calls run under terminal_mutex once the master is known to be
//! open, through libc with their errors checked. Hidden input begins when
//! a sample finds it after one that did not, or after an input answered it
//! and new text appeared while it stayed hidden. The program's name is
//! looked up without that lock: once when the group changes, scanning
//! /proc for a member when the group's leader is gone, and from the leader
//! again at most every second, so a program that exec'd shows its new
//! name. Windows has none of this.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const plat = @import("plat.zig");
const protocol = @import("protocol.zig");
const status = @import("status.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;

/// How often the foreground program's name is read again while its group
/// stays the same.
const name_refresh_ns: i64 = std.time.ns_per_s;

extern "c" fn tcgetpgrp(fd: c_int) std.c.pid_t;
extern "c" fn proc_name(pid: c_int, buffer: *anyopaque, size: u32) c_int;
extern "c" fn proc_listpgrppids(pgrp: c_int, buffer: ?*anyopaque, size: c_int) c_int;

pub const Tty = struct {
    /// Input is read a line at a time.
    canonical: bool,
    echo: bool,
};

/// One sample.
pub const Sample = struct {
    /// Monotonic nanoseconds; 0 before the first sample.
    taken_ns: i64 = 0,
    /// The foreground process group; null when there is none.
    pgid: ?u32 = null,
    tty: ?Tty = null,
    /// When hidden input last began: the session's seq and monotonic
    /// nanoseconds of the sample that saw it first.
    hidden_seq: u64 = 0,
    hidden_ns: i64 = 0,

    pub fn hidden(smp: Sample) bool {
        const tty = smp.tty orelse return false;
        return tty.canonical and !tty.echo;
    }
};

/// A session's samples; guarded by terminal_mutex.
pub const Sampler = struct {
    last: Sample = .{},
    /// The foreground program's name, cleaned, for group `name_pgid`; null
    /// when it could not be found.
    name: ?[]u8 = null,
    name_pgid: u32 = 0,
    name_ns: i64 = 0,

    pub fn deinit(self: *Sampler, gpa: std.mem.Allocator) void {
        if (self.name) |n| gpa.free(n);
        self.name = null;
    }

    /// The foreground program's name, if known for the sampled group.
    pub fn foregroundName(self: *const Sampler) ?[]const u8 {
        const pgid = self.last.pgid orelse return null;
        return if (pgid == self.name_pgid) self.name else null;
    }
};

/// Sample `s` now; the caller must not hold terminal_mutex. With
/// `names`, the foreground program's name is looked up when due. When
/// hidden input began or ended, the evaluator is woken.
pub fn refresh(s: *Session, names: bool) void {
    if (builtin.os.tag == .windows) return;
    const io = io_mod.io();
    var now: i64 = undefined;
    var lookup: ?u32 = null;
    var leader_only = false;
    var changed = false;
    {
        s.terminal_mutex.lockUncancelable(io);
        defer s.terminal_mutex.unlock(io);
        // Under the lock, as an input's time is: a sample ordered after an
        // input is also later than it.
        now = io_mod.nowNanos();
        const smp = &s.sampler;
        const was = smp.last.hidden();
        smp.last.taken_ns = now;
        const fd = s.pty.posix.master;
        if (fd < 0) {
            smp.last.pgid = null;
            smp.last.tty = null;
        } else {
            smp.last.pgid = foregroundGroup(fd);
            smp.last.tty = ttyModes(fd);
        }
        const hidden = smp.last.hidden();
        // A prompt drawn after an input answered the one before while input
        // stayed hidden ("Retype password"): echo was on in between for too
        // short a time to be seen.
        const input_ns = s.track.last_input_ns.load(.acquire);
        const anew = was and hidden and input_ns > smp.last.hidden_ns and
            s.track.last_text_change_ns.load(.acquire) > input_ns;
        if (hidden and (!was or anew)) {
            smp.last.hidden_seq = s.track.seq.load(.acquire);
            smp.last.hidden_ns = now;
        }
        changed = hidden != was or anew;
        if (names) if (smp.last.pgid) |pgid| {
            if (pgid != smp.name_pgid) {
                lookup = pgid;
            } else if (now - smp.name_ns >= name_refresh_ns) {
                lookup = pgid;
                leader_only = true;
            }
        };
    }
    if (changed) s.track.notify();
    const pgid = lookup orelse return;
    var buf: [256]u8 = undefined;
    const raw = if (leader_only) leaderName(&buf, pgid) else groupName(&buf, pgid);
    const name = if (raw) |r| status.cleanText(s.gpa, r, status.max_label_len) catch null else null;
    s.terminal_mutex.lockUncancelable(io);
    defer s.terminal_mutex.unlock(io);
    const smp = &s.sampler;
    // Another sample may have moved on meanwhile.
    if (smp.last.pgid != pgid) {
        if (name) |n| s.gpa.free(n);
        return;
    }
    // Without its leader, the group keeps the member's name found before.
    if (leader_only and name == null) {
        smp.name_ns = now;
        return;
    }
    if (smp.name) |old| s.gpa.free(old);
    smp.name = name;
    smp.name_pgid = pgid;
    smp.name_ns = now;
}

/// The latest sample of `s`.
pub fn latest(s: *Session) Sample {
    s.lockTerminal();
    defer s.unlockTerminal();
    return s.sampler.last;
}

fn foregroundGroup(fd: std.c.fd_t) ?u32 {
    const pgid = tcgetpgrp(fd);
    if (pgid <= 0) return null;
    return @intCast(pgid);
}

fn ttyModes(fd: std.c.fd_t) ?Tty {
    const t = plat.tcgetattr(fd) catch return null;
    return .{ .canonical = t.lflag.ICANON, .echo = t.lflag.ECHO };
}

/// The name of a program in group `pgid`: its leader's, or a member's
/// while the leader is gone.
fn groupName(buf: *[256]u8, pgid: u32) ?[]const u8 {
    if (leaderName(buf, pgid)) |name| return name;
    switch (builtin.os.tag) {
        .linux => {
            const io = io_mod.io();
            var dir = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return null;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                const pid = protocol.parseDecimal(u32, entry.name) orelse continue;
                if (procName(buf, pid, pgid)) |name| return name;
            }
            return null;
        },
        .macos => {
            var pids: [64]c_int = undefined;
            const bytes = proc_listpgrppids(@intCast(pgid), &pids, @sizeOf(@TypeOf(pids)));
            if (bytes <= 0) return null;
            const n = @min(pids.len, @as(usize, @intCast(bytes)) / @sizeOf(c_int));
            for (pids[0..n]) |pid| {
                const len = proc_name(pid, buf, buf.len);
                if (len > 0) return buf[0..@intCast(len)];
            }
            return null;
        },
        else => return null,
    }
}

/// The name of group `pgid`'s leader, while it lives.
fn leaderName(buf: *[256]u8, pgid: u32) ?[]const u8 {
    switch (builtin.os.tag) {
        .linux => return procName(buf, pgid, pgid),
        .macos => {
            const len = proc_name(@intCast(pgid), buf, buf.len);
            return if (len > 0) buf[0..@intCast(len)] else null;
        },
        else => return null,
    }
}

/// Linux: the name of process `pid` if it is in group `pgid`.
fn procName(buf: *[256]u8, pid: u32, pgid: u32) ?[]const u8 {
    var path_buf: [32:0]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buf, buf.len);
    if (n <= 0) return null;
    const stat = parseStat(buf[0..@intCast(n)]) orelse return null;
    return if (stat.pgrp == pgid) stat.comm else null;
}

pub const Stat = struct {
    comm: []const u8,
    pgrp: u32,
};

/// The name and group from the start of /proc/<pid>/stat:
/// "pid (comm) state ppid pgrp ...", where comm may hold spaces and
/// parentheses of its own.
pub fn parseStat(text: []const u8) ?Stat {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close < open) return null;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    _ = fields.next() orelse return null; // state
    _ = fields.next() orelse return null; // ppid
    const pgrp = protocol.parseDecimal(u32, fields.next() orelse return null) orelse return null;
    return .{ .comm = text[open + 1 .. close], .pgrp = pgrp };
}

test "the name and group come from a stat line, whatever the name holds" {
    const st = parseStat("4242 (my (odd) prog) S 1 4240 4240 34816 4240 4194560").?;
    try std.testing.expectEqualStrings("my (odd) prog", st.comm);
    try std.testing.expectEqual(@as(u32, 4240), st.pgrp);
    try std.testing.expectEqual(@as(?Stat, null), parseStat("4242 (cut"));
    try std.testing.expectEqual(@as(?Stat, null), parseStat("4242 (sh) S 1"));
}

test "a sampled pty reports its foreground group and input modes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const pty_mod = @import("pty.zig");
    var pair = try pty_mod.open(80, 24);
    defer pty_mod.close(&pair);
    const tty = ttyModes(pair.posix.master).?;
    try std.testing.expect(tty.canonical and tty.echo);
    // Nothing made the pty its controlling terminal, so it has no group.
    try std.testing.expectEqual(@as(?u32, null), foregroundGroup(pair.posix.master));
    try std.testing.expectEqual(@as(?Tty, null), ttyModes(-1));
}
