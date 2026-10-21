//! The status of a session: what `list` returns and every reply about one
//! session carries. A session this daemon holds reports it from memory;
//! an ended one that only the store has, from its stored metadata.

const std = @import("std");
const io_mod = @import("io.zig");
const store = @import("store.zig");
const session_mod = @import("session.zig");
const attach = @import("attach.zig");
const record = @import("record.zig");
const sample = @import("sample.zig");
const alert = @import("alert.zig");

const Session = session_mod.Session;

/// "lost": the daemon running the session stopped while it ran, so how it
/// ended and its final screen are unknown.
pub const State = enum { running, exited, lost };

/// How the program ended: an exit code, or the signal that killed it.
pub const Exit = struct {
    code: ?i32 = null,
    signal: ?[]const u8 = null,
    /// `stop` ended it.
    stopped: bool = false,
};

/// The latest desktop notification the program sent (OSC 9 or OSC 777).
pub const Notification = struct {
    /// OSC 777's title; OSC 9 has none.
    title: ?[]const u8 = null,
    text: []const u8 = "",
    /// Unix time in milliseconds.
    at_ms: i64 = 0,
};

/// What a client last showed of a session, as acks report it: the values
/// it displayed, so a mark clears only for what was seen.
pub const Seen = struct {
    seq: u64 = 0,
    bell_count: u64 = 0,
    notification_count: u64 = 0,
    hit_seq: ?u64 = null,
    ended: bool = false,
    /// Unix time in milliseconds of the latest ack.
    at_ms: ?i64 = null,
};

/// The values an ack says a client showed; a field left out stays as
/// seen before.
pub const Shown = struct {
    seq: ?u64 = null,
    bell_count: ?u64 = null,
    notification_count: ?u64 = null,
    hit_seq: ?u64 = null,
    ended: ?bool = null,
};

/// What a client shows of a session when it displays `st`, for an ack.
pub fn shownOf(st: Status) Shown {
    return .{
        .seq = st.seq,
        .bell_count = st.bell_count,
        .notification_count = st.notification_count,
        .hit_seq = st.hit_seq,
        .ended = st.state != .running,
    };
}

/// `old` after an ack at `at_ms`: each field moves to what the client
/// showed, but never past `current` and never back. Without `shown`, to
/// `current`.
pub fn mergeSeen(old: Seen, shown: ?Shown, current: Seen, at_ms: i64) Seen {
    const given = shown != null;
    const v = shown orelse Shown{};
    return .{
        .seq = mergeField(u64, old.seq, given, v.seq, current.seq),
        .bell_count = mergeField(u64, old.bell_count, given, v.bell_count, current.bell_count),
        .notification_count = mergeField(u64, old.notification_count, given, v.notification_count, current.notification_count),
        .hit_seq = if (current.hit_seq) |now| blk: {
            const merged = mergeField(u64, old.hit_seq orelse 0, given, v.hit_seq, now);
            // Hits count from 1: 0 is none seen.
            break :blk if (merged == 0) old.hit_seq else merged;
        } else old.hit_seq,
        .ended = old.ended or (current.ended and (if (given) v.ended orelse false else true)),
        .at_ms = at_ms,
    };
}

fn mergeField(comptime T: type, was: T, given: bool, showed: ?T, now: T) T {
    const target = if (given) showed orelse return was else now;
    return @max(was, @min(target, now));
}

/// Whether an ack moved anything but its time.
pub fn seenMoved(old: Seen, new: Seen) bool {
    var a = old;
    a.at_ms = new.at_ms;
    return !std.meta.eql(a, new);
}

/// The working directory the program reported (OSC 7).
pub const Cwd = struct {
    path: []const u8 = "",
    host: ?[]const u8 = null,
};

/// The foreground process group of the terminal, and its program's name
/// if it could be found.
pub const Foreground = struct {
    pgid: u32 = 0,
    name: ?[]const u8 = null,
};

pub const Writer = struct {
    /// What the writing client calls itself, if it said.
    label: ?[]const u8 = null,
};

/// The active recording; once the session has ended, the one
/// `run --record` made.
pub const Recording = struct {
    path: []const u8 = "",
    format: record.RecordFormat = .cast,
    /// Whether input events are recorded too.
    input: bool = false,
    started_ms: i64 = 0,
};

pub const Status = struct {
    id: u64 = 0,
    name: ?[]const u8 = null,
    state: State = .running,
    pid: ?u32 = null,
    argv: []const []const u8 = &.{},
    cols: u16 = 0,
    rows: u16 = 0,
    /// Unix time in milliseconds.
    started_ms: i64 = 0,
    ended_ms: ?i64 = null,
    exit: ?Exit = null,
    /// The seq of the latest visible change; null when the session was
    /// lost.
    seq: ?u64 = null,
    /// The seq the session started at; older seqs are stale.
    start_seq: u64 = 0,
    /// The seq stamped when the session ended.
    end_seq: ?u64 = null,
    /// `seq` when the latest input was written; null before any input.
    input_seq: ?u64 = null,
    /// The seq of the latest resize's reflow; null before any resize.
    resize_seq: ?u64 = null,
    /// Milliseconds since the text on screen last changed, since anything
    /// visible last changed, since the last output, and since the last
    /// input (null before any input and once the session has ended).
    idle_ms: u64 = 0,
    change_idle_ms: u64 = 0,
    output_idle_ms: u64 = 0,
    input_idle_ms: ?u64 = null,
    /// The window title (OSC 0 and 2).
    title: ?[]const u8 = null,
    cwd: ?Cwd = null,
    /// Sampled from the pty while the program runs (not on Windows):
    /// the foreground group, the input modes, whether input is read a
    /// line at a time without echo (a password prompt, most likely), and
    /// how old the sample is.
    foreground: ?Foreground = null,
    tty: ?sample.Tty = null,
    hidden_input: ?bool = null,
    sample_age_ms: ?u64 = null,
    writer: ?Writer = null,
    /// Attached clients that only watch.
    viewers: u32 = 0,
    /// Attached previews, which watch in passing.
    previews: u32 = 0,
    recording: ?Recording = null,
    /// BELs and desktop notifications the program sent, and the latest
    /// notification.
    bell_count: u64 = 0,
    notification_count: u64 = 0,
    notification: ?Notification = null,
    /// The number of the latest alert hit; null without hits.
    hit_seq: ?u64 = null,
    /// The alerts the latest hit matched; empty without hits.
    hit_alerts: []const []const u8 = &.{},
    /// The names of the session's alerts, in the order they were added.
    alerts: []const []const u8 = &.{},
    seen: Seen = .{},
    /// The bytes the program wrote, the settles of its output that took a
    /// seq, and its erases of the whole screen; null when they are not
    /// known, as for a lost session.
    out_bytes: ?u64 = null,
    draws: ?u64 = null,
    full_clears: ?u64 = null,
    /// The memory budget holds the history below its limit for now: the
    /// oldest lines went to make room (see TUPPET_MEMORY).
    history_trimmed: bool = false,
    /// Why the stored session cannot be loaded, such as "its stored size
    /// 65535x65535 is outside 1..1000"; null when it can. Only `list`,
    /// `ack`, and `remove` work on a damaged session.
    damaged: ?[]const u8 = null,
};

/// Labels and other strings that clients or programs supply are kept at
/// most this long.
pub const max_label_len = 64;
/// Titles, working directories, and host names are kept at most this
/// long.
pub const max_title_len = 256;
pub const max_path_len = 4096;
pub const max_host_len = 255;
/// Notification texts are kept at most this long.
pub const max_notification_len = 1024;

/// The status of a session this daemon holds, from a fresh sample.
pub fn of(gpa: std.mem.Allocator, s: *Session) !Status {
    const rec = try recordingOf(gpa, s);
    sample.refresh(s, true);
    s.lockTerminal();
    defer s.unlockTerminal();
    return ofLocked(gpa, s, rec);
}

/// The active recording of `s`. Taken before terminal_mutex: holders of
/// the recording's lock may take that one, never the reverse.
pub fn recordingOf(gpa: std.mem.Allocator, s: *Session) !?Recording {
    const io = io_mod.io();
    s.record_mutex.lockUncancelable(io);
    defer s.record_mutex.unlock(io);
    const rec = &(s.recording orelse return null);
    return .{
        .path = try gpa.dupe(u8, rec.path),
        .format = rec.format,
        .input = rec.input,
        .started_ms = rec.started_ms,
    };
}

/// `of` with terminal_mutex held, the recording already read, and the
/// pty sampled.
pub fn ofLocked(gpa: std.mem.Allocator, s: *Session, recording: ?Recording) !Status {
    const now = io_mod.nowNanos();
    const exited = s.state.load(.acquire) == .exited;
    const ended_ms = s.ended_ms.load(.acquire);
    const end_seq = s.end_seq.load(.acquire);
    const input_seq = s.track.input_seq.load(.acquire);
    const resize_seq = s.resize_seq.load(.acquire);
    const last_input = s.track.last_input_ns.load(.acquire);
    const smp = s.sampler.last;
    const sampled = !exited and smp.taken_ns != 0;
    const fg_name = s.sampler.foregroundName();
    return .{
        .id = s.id,
        .name = if (s.name.len > 0) try gpa.dupe(u8, s.name) else null,
        .state = if (exited) .exited else .running,
        .pid = if (s.process_id != 0) s.process_id else null,
        .argv = @ptrCast(s.argv),
        .cols = s.cols,
        .rows = s.rows,
        .started_ms = s.started_ms,
        .ended_ms = if (ended_ms != 0) ended_ms else null,
        .exit = if (exited) try exitOf(gpa, s.exit_code.load(.acquire), s.stopped.load(.acquire)) else null,
        .seq = s.track.seq.load(.acquire),
        .start_seq = s.track.start_seq,
        .end_seq = if (end_seq != 0) end_seq else null,
        .input_seq = if (input_seq != 0) input_seq else null,
        .resize_seq = if (resize_seq != 0) resize_seq else null,
        .idle_ms = sinceMs(now, s.track.last_text_change_ns.load(.acquire)),
        .change_idle_ms = sinceMs(now, s.track.last_change_ns.load(.acquire)),
        .output_idle_ms = sinceMs(now, s.last_output.load(.acquire)),
        .input_idle_ms = if (exited or last_input == 0) null else sinceMs(now, last_input),
        .title = try titleOf(gpa, s.terminal.getTitle()),
        .cwd = try cwdOf(gpa, s.terminal.getPwd() orelse ""),
        .foreground = if (!sampled) null else if (smp.pgid) |pgid| .{
            .pgid = pgid,
            .name = if (fg_name) |n| try gpa.dupe(u8, n) else null,
        } else null,
        .tty = if (sampled) smp.tty else null,
        .hidden_input = if (sampled and smp.tty != null) smp.hidden() else null,
        .sample_age_ms = if (sampled) sinceMs(now, smp.taken_ns) else null,
        .writer = if (s.writer) |w| .{ .label = if (w.label) |l| try gpa.dupe(u8, l) else null } else null,
        .viewers = s.viewerCountLocked(),
        .previews = s.previewCountLocked(),
        .recording = recording orelse if (exited) try dupeRecording(gpa, s.run_recording) else null,
        .bell_count = s.bell_count.load(.acquire),
        .notification_count = s.notification_count.load(.acquire),
        .notification = if (s.notification) |n| try dupeNotification(gpa, n) else null,
        .hit_seq = s.hits.latest(),
        .hit_alerts = if (s.hits.latest()) |n| try dupeNames(gpa, s.hits.get(n).?.alerts) else &.{},
        .alerts = try s.track.alerts().nameList(gpa),
        .seen = s.seenNow(),
        .out_bytes = if (s.counted) s.track.read_bytes.load(.acquire) else null,
        .draws = if (s.counted) s.track.draws.load(.acquire) else null,
        .full_clears = if (s.counted) s.stream.handler.full_clears else null,
        .history_trimmed = s.history_cap != null,
    };
}

fn dupeNames(gpa: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, list.len);
    for (list, out) |name, *o| o.* = try gpa.dupe(u8, name);
    return out;
}

fn dupeRecording(gpa: std.mem.Allocator, rec: ?Recording) !?Recording {
    var out = rec orelse return null;
    out.path = try gpa.dupe(u8, out.path);
    return out;
}

/// The recording `run --record` made for a stored session, in `gpa`.
pub fn runRecording(gpa: std.mem.Allocator, meta: store.Meta) !?Recording {
    const name = meta.recording orelse return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (std.fs.path.isAbsolute(name)) name else try store.sessionFile(&buf, meta.id, name);
    return .{
        .path = try gpa.dupe(u8, path),
        .format = meta.recording_format,
        .input = meta.recording_format == .trace,
        .started_ms = meta.started_ms,
    };
}

/// The status of an ended session that only the store has. Its strings
/// alias `meta`.
pub fn ofMeta(gpa: std.mem.Allocator, meta: store.Meta, now_ms: i64) !Status {
    const lost = meta.lost or meta.ended_ms == null;
    // Nothing is known about a lost session after its start.
    const last_known = if (lost) meta.started_ms else meta.ended_ms.?;
    return .{
        .id = meta.id,
        .name = if (meta.name.len > 0) meta.name else null,
        .state = if (lost) .lost else .exited,
        .pid = if (meta.pid != 0) meta.pid else null,
        .argv = meta.argv,
        .cols = meta.cols,
        .rows = meta.rows,
        .started_ms = meta.started_ms,
        .ended_ms = meta.ended_ms,
        .exit = if (lost) null else try exitOf(gpa, meta.exit_code orelse 0, meta.stopped),
        .seq = if (lost) null else meta.seq,
        .start_seq = meta.start_seq,
        .end_seq = if (lost) null else meta.end_seq,
        .input_seq = if (lost) null else meta.input_seq,
        .resize_seq = meta.resize_seq,
        .idle_ms = sinceWallMs(now_ms, meta.last_text_ms orelse last_known),
        .change_idle_ms = sinceWallMs(now_ms, meta.last_change_ms orelse last_known),
        .output_idle_ms = sinceWallMs(now_ms, meta.last_output_ms orelse last_known),
        .title = try titleOf(gpa, meta.title),
        .cwd = if (meta.reported_cwd) |cwd| try dupeCwd(gpa, cwd) else null,
        // A damaged session may name what no path can be.
        .recording = runRecording(gpa, meta) catch |err| switch (err) {
            error.NameTooLong => null,
            else => |e| return e,
        },
        .bell_count = meta.bell_count,
        .notification_count = meta.notification_count,
        .notification = if (meta.notification) |n| try dupeNotification(gpa, n) else null,
        .hit_seq = if (meta.hits.len > 0) meta.hits[meta.hits.len - 1].n else null,
        .hit_alerts = if (meta.hits.len > 0) try dupeNames(gpa, meta.hits[meta.hits.len - 1].alerts) else &.{},
        .alerts = try ruleNames(gpa, meta.alerts),
        .seen = meta.seen,
        .out_bytes = if (lost) null else meta.out_bytes,
        .draws = if (lost) null else meta.draws,
        .full_clears = if (lost) null else meta.full_clears,
    };
}

fn ruleNames(gpa: std.mem.Allocator, rules: []const alert.Rule) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, rules.len);
    for (rules, out) |rule, *name| name.* = try gpa.dupe(u8, rule.name);
    return out;
}

/// tuppet keeps death by signal n as exit code -n.
pub fn exitOf(gpa: std.mem.Allocator, code: i32, stopped: bool) !Exit {
    // A code below -255 is no signal (Windows, or damaged data).
    if (code >= 0 or code <= -256) return .{ .code = code, .stopped = stopped };
    var buf: [16]u8 = undefined;
    return .{ .signal = try gpa.dupe(u8, attach.signalName(&buf, @intCast(-code))), .stopped = stopped };
}

fn sinceMs(now: i64, then: i64) u64 {
    return @intCast(@max(0, now - then) / std.time.ns_per_ms);
}

fn sinceWallMs(now_ms: i64, then_ms: i64) u64 {
    return @intCast(@max(0, now_ms -| then_ms));
}

/// A title as a status shows it.
pub fn titleOf(gpa: std.mem.Allocator, title: ?[]const u8) !?[]const u8 {
    const clean = try cleanText(gpa, title orelse return null, max_title_len);
    if (clean.len > 0) return clean;
    gpa.free(clean);
    return null;
}

/// A notification as a status shows it, from the program's title (empty
/// for none) and text.
pub fn notificationOf(gpa: std.mem.Allocator, title: []const u8, text: []const u8, at_ms: i64) !Notification {
    const clean_title = try titleOf(gpa, title);
    errdefer if (clean_title) |t| gpa.free(t);
    return .{ .title = clean_title, .text = try cleanText(gpa, text, max_notification_len), .at_ms = at_ms };
}

pub fn dupeNotification(gpa: std.mem.Allocator, n: Notification) !Notification {
    const title = if (n.title) |t| try gpa.dupe(u8, t) else null;
    errdefer if (title) |t| gpa.free(t);
    return .{ .title = title, .text = try gpa.dupe(u8, n.text), .at_ms = n.at_ms };
}

pub fn freeNotification(gpa: std.mem.Allocator, n: Notification) void {
    if (n.title) |t| gpa.free(t);
    gpa.free(n.text);
}

fn dupeCwd(gpa: std.mem.Allocator, cwd: Cwd) !Cwd {
    return .{ .path = try gpa.dupe(u8, cwd.path), .host = if (cwd.host) |h| try gpa.dupe(u8, h) else null };
}

/// The working directory in an OSC 7 report: `file://HOST/PATH` with the
/// path percent-encoded, kitty's `kitty-shell-cwd://HOST/PATH` without, or
/// a bare absolute path. Null for anything else.
pub fn cwdOf(gpa: std.mem.Allocator, report: []const u8) !?Cwd {
    var host: []const u8 = "";
    var path: []const u8 = undefined;
    var encoded = false;
    if (std.mem.startsWith(u8, report, "/")) {
        path = report;
    } else {
        const rest = if (std.mem.startsWith(u8, report, "file://")) blk: {
            encoded = true;
            break :blk report["file://".len..];
        } else if (std.mem.startsWith(u8, report, "kitty-shell-cwd://"))
            report["kitty-shell-cwd://".len..]
        else
            return null;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        host = rest[0..slash];
        path = rest[slash..];
    }
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);
    if (encoded) {
        try decoded.ensureTotalCapacity(gpa, path.len);
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '%' and i + 2 < path.len) {
                const hi = std.fmt.charToDigit(path[i + 1], 16) catch null;
                const lo = std.fmt.charToDigit(path[i + 2], 16) catch null;
                if (hi != null and lo != null) {
                    decoded.appendAssumeCapacity(hi.? << 4 | lo.?);
                    i += 2;
                    continue;
                }
            }
            decoded.appendAssumeCapacity(path[i]);
        }
        path = decoded.items;
    }
    const clean_path = try cleanText(gpa, path, max_path_len);
    errdefer gpa.free(clean_path);
    if (clean_path.len == 0) {
        gpa.free(clean_path);
        return null;
    }
    const clean_host = try cleanText(gpa, host, max_host_len);
    if (clean_host.len == 0) {
        gpa.free(clean_host);
        return .{ .path = clean_path };
    }
    return .{ .path = clean_path, .host = clean_host };
}

/// `text` as a status shows it: without C0, C1, and bidi controls,
/// invalid UTF-8 replaced, and cut at a character boundary to at most
/// `cap` bytes.
pub fn cleanText(gpa: std.mem.Allocator, text: []const u8, cap: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const decoded: ?u21 = if (len > 0 and i + len <= text.len)
            std.unicode.utf8Decode(text[i..][0..len]) catch null
        else
            null;
        i += if (decoded != null) len else 1;
        const cp = decoded orelse 0xfffd;
        if (isControl(cp)) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        if (out.items.len + n > cap) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or
        cp == 0x061c or cp == 0x200e or cp == 0x200f or
        (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069);
}

test "an OSC 7 report gives a decoded path and its host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = (try cwdOf(a, "file://box/tmp/a%20b%2x%e2%82%ac%1b")).?;
    try std.testing.expectEqualStrings("/tmp/a b%2x\u{20ac}", file.path);
    try std.testing.expectEqualStrings("box", file.host.?);
    const local = (try cwdOf(a, "file:///srv/50%")).?;
    try std.testing.expectEqualStrings("/srv/50%", local.path);
    try std.testing.expectEqual(@as(?[]const u8, null), local.host);
    try std.testing.expectEqualStrings("/a%20b", (try cwdOf(a, "kitty-shell-cwd://box/a%20b")).?.path);
    try std.testing.expectEqualStrings("/home", (try cwdOf(a, "/home")).?.path);
    try std.testing.expectEqual(@as(?Cwd, null), try cwdOf(a, "http://box/x"));
    try std.testing.expectEqual(@as(?Cwd, null), try cwdOf(a, "file://box"));
}

test "program and client strings lose controls and are capped" {
    const gpa = std.testing.allocator;
    const clean = try cleanText(gpa, "a\x1b[31mb\u{202e}c\u{85}d\xffé", 64);
    defer gpa.free(clean);
    try std.testing.expectEqualStrings("a[31mbcd\u{fffd}é", clean);
    const cut = try cleanText(gpa, "abé", 3);
    defer gpa.free(cut);
    try std.testing.expectEqualStrings("ab", cut);
}

test "an ack moves seen up to what was shown, never past now and never back" {
    const current: Seen = .{ .seq = 50, .bell_count = 3, .notification_count = 1, .ended = true };
    const all = mergeSeen(.{}, null, current, 7);
    try std.testing.expectEqual(@as(u64, 3), all.bell_count);
    try std.testing.expect(all.ended);
    try std.testing.expectEqual(@as(?i64, 7), all.at_ms);
    // A client that showed less, then a stale one that showed even less.
    const first = mergeSeen(.{}, .{ .seq = 40, .bell_count = 2, .ended = false }, current, 8);
    try std.testing.expectEqual(@as(u64, 40), first.seq);
    try std.testing.expectEqual(@as(u64, 2), first.bell_count);
    try std.testing.expectEqual(@as(u64, 0), first.notification_count);
    try std.testing.expect(!first.ended);
    const stale = mergeSeen(first, .{ .seq = 10, .bell_count = 1, .notification_count = 9 }, current, 9);
    try std.testing.expectEqual(@as(u64, 40), stale.seq);
    try std.testing.expectEqual(@as(u64, 2), stale.bell_count);
    try std.testing.expectEqual(@as(u64, 1), stale.notification_count);
    try std.testing.expect(seenMoved(first, stale));
    try std.testing.expect(!seenMoved(stale, mergeSeen(stale, .{ .bell_count = 1 }, current, 10)));
    try std.testing.expectEqual(@as(?u64, null), stale.hit_seq);
}
