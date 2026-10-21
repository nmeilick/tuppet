//! Session events, which `events` streams (see docs/protocol.md). Where
//! something happens to a session, a small entry goes into one daemon-wide
//! ring: the session's id, what happened, and for a change the fields that
//! changed. Each subscriber reads the ring on its own thread, takes a
//! session's status when it sends a frame about it, and writes to its
//! client itself, so whoever publishes never waits for a client. A
//! subscriber that falls a whole ring behind starts over: resync, a fresh
//! snapshot, synced.
//!
//! Lifecycle events (started, ended, removed, renamed, seen) and alert
//! hits are published where they happen. Changes are found by each running session's
//! evaluator, which compares what a status shows at most every 100 ms (see
//! `Detector`), so a busy session publishes at most ten a second. A
//! subscriber sends at most ten frames a second about one session too,
//! idle and active edges included; lifecycle and hit frames do not wait.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const names = @import("names.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const sample = @import("sample.zig");
const session_mod = @import("session.zig");
const status = @import("status.zig");
const hangup = @import("hangup.zig");

const Session = session_mod.Session;
const Status = status.Status;

/// Change frames about one session go out at most this often.
pub const interval_ns: i64 = 100 * std.time.ns_per_ms;
/// A client that takes nothing for this long is too slow.
const stall_ns: i64 = 30 * std.time.ns_per_s;
/// How long a stream that ends tries to deliver its last line.
const final_line_ns: i64 = std.time.ns_per_s;
/// The longest idle_ms a stream takes.
pub const max_idle_ms: u64 = std.time.ms_per_day;
/// Entries a subscriber may fall behind before it resyncs.
const ring_len = 1024;

const too_slow_line = "{\"type\":\"end\",\"reason\":\"too_slow\"}\n";
const shutdown_line = "{\"type\":\"end\",\"reason\":\"shutdown\"}\n";

/// What happened to a session.
pub const Kind = enum(u8) { started, ended, removed, renamed, changed, seen, hit };

/// What a change frame names as changed.
pub const Field = enum { seq, input, title, cwd, foreground, tty, writer, viewers, bell, notification, size };
pub const Fields = std.EnumSet(Field);

const Entry = struct {
    id: u64 = 0,
    kind: Kind = .changed,
    fields: Fields = .empty,
    /// The hit's number, for a hit.
    n: u64 = 0,
};

/// Guards the ring, `head`, and `subscribers`. Nobody holds it while
/// doing anything else.
var mutex: std.Io.Mutex = .init;
/// Entry n is at ring[n % ring_len]; `head` is the next n.
var ring: [ring_len]Entry = undefined;
var head: u64 = 0;
var subscribers: u32 = 0;
/// `subscribers`, for checks that take no lock.
var watchers: std.atomic.Value(u32) = .init(0);
/// Bumped after every entry, for subscribers to wait on.
var wake: std.atomic.Value(u32) = .init(0);
var shutting_down: std.atomic.Value(bool) = .init(false);
var open_streams: std.atomic.Value(usize) = .init(0);

/// Tell the subscribers, if there are any, that `kind` happened to session
/// `id`. Never waits for a client.
pub fn publish(id: u64, kind: Kind, fields: Fields) void {
    put(.{ .id = id, .kind = kind, .fields = fields });
}

/// Tell the subscribers about hit `n` of session `id`.
pub fn publishHit(id: u64, n: u64) void {
    put(.{ .id = id, .kind = .hit, .n = n });
}

fn put(e: Entry) void {
    const io = io_mod.io();
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (subscribers == 0) return;
        ring[head % ring_len] = e;
        head += 1;
    }
    _ = wake.fetchAdd(1, .release);
    io.futexWake(u32, &wake.raw, std.math.maxInt(u32));
}

/// Whether anyone subscribes: the pty is sampled every 250 ms meanwhile.
pub fn watching() bool {
    return watchers.load(.acquire) > 0;
}

/// The daemon is stopping: every stream sends what is published by now,
/// then ends with reason shutdown.
pub fn shutdown() void {
    shutting_down.store(true, .release);
    _ = wake.fetchAdd(1, .release);
    io_mod.io().futexWake(u32, &wake.raw, std.math.maxInt(u32));
}

/// Wait until every stream has closed, or until `deadline` (monotonic).
pub fn waitClosed(deadline: i64) void {
    while (open_streams.load(.acquire) > 0 and io_mod.nowNanos() < deadline) {
        std.Io.sleep(io_mod.io(), .fromMilliseconds(5), .boot) catch {};
    }
}

// ---- finding changes ----------------------------------------------------

/// What change frames compare, as cheap values.
const Facts = struct {
    seq: u64,
    input_seq: u64,
    title: u64,
    cwd: u64,
    pgid: ?u32,
    fg_name: u64,
    tty: ?sample.Tty,
    writer: u64,
    viewers: usize,
    bells: u64,
    notifications: u64,
    cols: u16,
    rows: u16,
    resize_seq: u64,

    fn of(s: *Session) Facts {
        const hash = std.hash.Wyhash.hash;
        s.lockTerminal();
        defer s.unlockTerminal();
        return .{
            .seq = s.track.seq.load(.acquire),
            .input_seq = s.track.input_seq.load(.acquire),
            .title = hash(0, s.terminal.getTitle() orelse ""),
            .cwd = hash(0, s.terminal.getPwd() orelse ""),
            .pgid = s.sampler.last.pgid,
            .fg_name = hash(0, s.sampler.foregroundName() orelse ""),
            .tty = s.sampler.last.tty,
            .writer = if (s.writer) |w| @intFromPtr(w) ^ hash(1, w.label orelse "") else 0,
            .viewers = s.viewerCountLocked(),
            .bells = s.bell_count.load(.acquire),
            .notifications = s.notification_count.load(.acquire),
            .cols = s.cols,
            .rows = s.rows,
            .resize_seq = s.resize_seq.load(.acquire),
        };
    }

    fn changes(a: Facts, b: Facts) Fields {
        var f: Fields = .empty;
        f.setPresent(.seq, a.seq != b.seq);
        f.setPresent(.input, a.input_seq != b.input_seq);
        f.setPresent(.title, a.title != b.title);
        f.setPresent(.cwd, a.cwd != b.cwd);
        f.setPresent(.foreground, !std.meta.eql(a.pgid, b.pgid) or a.fg_name != b.fg_name);
        f.setPresent(.tty, !std.meta.eql(a.tty, b.tty));
        f.setPresent(.writer, a.writer != b.writer);
        f.setPresent(.viewers, a.viewers != b.viewers);
        f.setPresent(.bell, a.bells != b.bells);
        f.setPresent(.notification, a.notifications != b.notifications);
        // A resize and its undoing within one frame still count.
        f.setPresent(.size, a.cols != b.cols or a.rows != b.rows or a.resize_seq != b.resize_seq);
        return f;
    }
};

/// Finds what changed on a running session and publishes it; its
/// evaluator calls `step` on every turn of its loop.
pub const Detector = struct {
    last: ?Facts = null,
    last_ns: i64 = std.math.minInt(i64) / 2,
    settles: u32 = 0,
    /// Something may have changed since the last look.
    dirty: bool = true,

    /// Look for changes if any can have happened (the screen settled, a
    /// client came or went, the pty was sampled) and the last look is
    /// `interval_ns` ago, or at once when `final`. Returns when to look
    /// again, while anyone subscribes.
    pub fn step(d: *Detector, s: *Session, settles: u32, sampled: bool, now: i64, final: bool) ?i64 {
        if (settles != d.settles or sampled) {
            d.settles = settles;
            d.dirty = true;
        }
        if (!d.dirty) return null;
        if (!final and now < d.last_ns + interval_ns) return if (watching()) d.last_ns + interval_ns else null;
        d.dirty = false;
        d.last_ns = now;
        // Read before anything is published: a subscriber that comes
        // later sees these values in its snapshot.
        const facts = Facts.of(s);
        const before = d.last;
        d.last = facts;
        var fields = (before orelse return null).changes(facts);
        // At the end these only tell that the pty closed.
        if (final) fields = fields.differenceWith(.initMany(&.{ .foreground, .tty }));
        if (fields.count() > 0) publish(s.id, .changed, fields);
        return null;
    }
};

// ---- subscribers ----------------------------------------------------------

/// The change frames about one session that a subscriber has yet to send:
/// at most one every `interval_ns`, fields merged meanwhile.
pub const Coalescer = struct {
    fields: Fields = .empty,
    last_ns: i64 = std.math.minInt(i64) / 2,

    pub fn add(c: *Coalescer, fields: Fields) void {
        c.fields.setUnion(fields);
    }

    /// Whether a frame may go out now.
    pub fn open(c: *const Coalescer, now: i64) bool {
        return now >= c.last_ns + interval_ns;
    }

    /// When the pending fields may go out; null without any.
    pub fn due(c: *const Coalescer) ?i64 {
        if (c.fields.count() == 0) return null;
        return c.last_ns + interval_ns;
    }

    /// The pending fields, if there are any and they may go out now, or
    /// with `force` (right before a lifecycle frame) at once.
    pub fn take(c: *Coalescer, now: i64, force: bool) ?Fields {
        if (c.fields.count() == 0 or !(force or c.open(now))) return null;
        defer c.fields = .empty;
        c.last_ns = now;
        return c.fields;
    }

    /// Another frame, an idle or active edge, went out now.
    pub fn spend(c: *Coalescer, now: i64) void {
        c.last_ns = now;
    }
};

pub const Options = struct {
    /// References that pick the sessions, by name or pattern also when
    /// they are renamed or start later; empty picks every session.
    refs: []const []const u8 = &.{},
    /// Send idle and active edges: the screen's text unchanged for this
    /// long, and changing again.
    idle_ms: ?u64 = null,
};

/// What a subscriber knows about one session.
const Tracked = struct {
    matched: bool,
    /// Its end was reported, in a snapshot or an ended frame.
    ended: bool,
    pending: Coalescer = .{},
    /// With idle_ms, while it runs: whether the last edge said idle, the
    /// latest text change known, and the one it went idle after
    /// (monotonic nanoseconds).
    idle: ?bool = null,
    text_ns: i64 = 0,
    idle_text_ns: i64 = 0,
};

const gpa = std.heap.page_allocator;

const Subscriber = struct {
    fd: std.posix.fd_t,
    opts: Options,
    idle_ns: ?i64,
    cursor: u64 = 0,
    table: std.AutoArrayHashMapUnmanaged(u64, Tracked) = .empty,
    /// Holds one frame at a time.
    arena: std.heap.ArenaAllocator,
    /// The client is gone or too slow: the stream ends.
    gone: bool = false,
    /// A write stopped inside a line.
    mid_line: bool = false,
    /// The end line was sent, or tried.
    finished: bool = false,

    fn deinit(sub: *Subscriber) void {
        sub.table.deinit(gpa);
        sub.arena.deinit();
    }

    /// An allocator for the next frame; what the last one held is freed.
    fn fresh(sub: *Subscriber) std.mem.Allocator {
        _ = sub.arena.reset(.{ .retain_with_limit = 64 << 10 });
        return sub.arena.allocator();
    }

    fn statusOf(sub: *Subscriber, id: u64) ?Status {
        return registry.statusOf(sub.arena.allocator(), id) catch null;
    }

    fn matches(sub: *const Subscriber, st: Status) bool {
        if (sub.opts.refs.len == 0) return true;
        for (sub.opts.refs) |ref| {
            if (names.kind(ref) == .id) {
                if (protocol.parseDecimal(u64, ref)) |id| if (id == st.id) return true;
            } else if (names.picks(ref, st.name orelse "", st.state == .running, .any)) return true;
        }
        return false;
    }

    /// The entries published since the last call, into `out`; null when
    /// the ring has overwritten some of them.
    fn take(sub: *Subscriber, out: []Entry) ?usize {
        const io = io_mod.io();
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (head - sub.cursor > ring_len) return null;
        const n: usize = @intCast(@min(head - sub.cursor, out.len));
        for (out[0..n], sub.cursor..) |*e, i| e.* = ring[i % ring_len];
        sub.cursor += n;
        return n;
    }

    /// A frame for every session that matches, then synced.
    fn snapshot(sub: *Subscriber) void {
        const ids = registry.allIds(gpa) catch {
            sub.gone = true;
            return;
        };
        defer gpa.free(ids);
        for (ids) |id| {
            _ = sub.fresh();
            const st = sub.statusOf(id) orelse continue;
            sub.add(st, "snapshot");
            if (sub.gone) return;
        }
        _ = sub.write("{\"type\":\"synced\"}\n");
    }

    /// The client fell a ring behind: start over.
    fn resync(sub: *Subscriber) void {
        if (!sub.write("{\"type\":\"resync\"}\n")) return;
        sub.table.clearRetainingCapacity();
        {
            const io = io_mod.io();
            mutex.lockUncancelable(io);
            defer mutex.unlock(io);
            sub.cursor = head;
        }
        sub.snapshot();
    }

    /// Track the session `st` describes, and send a `kind` frame when it
    /// matches.
    fn add(sub: *Subscriber, st: Status, kind: []const u8) void {
        const entry = sub.table.getOrPut(gpa, st.id) catch {
            sub.gone = true;
            return;
        };
        entry.value_ptr.* = .{ .matched = sub.matches(st), .ended = st.state != .running };
        if (!entry.value_ptr.matched) return;
        sub.startIdle(st.id, entry.value_ptr, st);
        sub.frame(kind, st.id, st);
    }

    fn startIdle(sub: *Subscriber, id: u64, t: *Tracked, st: Status) void {
        if (sub.idle_ns == null) return;
        if (st.state != .running) return;
        const now = io_mod.nowNanos();
        t.text_ns = lastTextChange(id) orelse now - @as(i64, @intCast(@min(st.idle_ms, std.math.maxInt(i32)))) * std.time.ns_per_ms;
        t.idle_text_ns = t.text_ns;
        // One that is quiet already gets its idle frame at once.
        t.idle = false;
    }

    fn handle(sub: *Subscriber, e: Entry) void {
        _ = sub.fresh();
        switch (e.kind) {
            // Every other kind is about a session the snapshot or a started
            // frame told of; one published before its start is late.
            .started => {
                // Already in the snapshot.
                if (sub.table.contains(e.id)) return;
                const st = sub.statusOf(e.id) orelse return;
                sub.add(st, "started");
                // It ended before its start was told: its end may have come
                // before too.
                if (st.state != .running and sub.matches(st)) sub.frame("ended", e.id, st);
            },
            .changed => {
                const t = sub.table.getPtr(e.id) orelse return;
                if (!t.matched or t.ended) return;
                t.pending.add(e.fields);
                if (t.idle != null) if (lastTextChange(e.id)) |ns| {
                    t.text_ns = @max(t.text_ns, ns);
                };
            },
            .renamed => {
                const t = sub.table.getPtr(e.id) orelse return;
                const st = sub.statusOf(e.id) orelse return;
                const was = t.matched;
                t.matched = sub.matches(st);
                if (was) sub.flushPending(e.id, t);
                if (was and t.matched) {
                    sub.frame("renamed", e.id, st);
                } else if (was) {
                    sub.frame("left", e.id, st);
                } else if (t.matched) {
                    // A new match.
                    t.ended = st.state != .running;
                    sub.startIdle(e.id, t, st);
                    sub.frame("snapshot", e.id, st);
                }
            },
            .ended => {
                const t = sub.table.getPtr(e.id) orelse return;
                if (!t.matched or t.ended) return;
                sub.flushPending(e.id, t);
                t.ended = true;
                t.idle = null;
                sub.frame("ended", e.id, sub.statusOf(e.id));
            },
            .removed => {
                const t = sub.table.fetchSwapRemove(e.id) orelse return;
                if (t.value.matched) sub.frame("removed", e.id, null);
            },
            .seen => {
                const t = sub.table.getPtr(e.id) orelse return;
                if (!t.matched) return;
                sub.flushPending(e.id, t);
                sub.frame("seen", e.id, sub.statusOf(e.id));
            },
            .hit => {
                const t = sub.table.getPtr(e.id) orelse return;
                if (!t.matched) return;
                sub.flushPending(e.id, t);
                sub.hitFrame(e.id, e.n);
            },
        }
    }

    /// A hit frame, unless the session's log dropped the hit meanwhile.
    fn hitFrame(sub: *Subscriber, id: u64, n: u64) void {
        const a = sub.arena.allocator();
        const hit = blk: {
            const s = registry.acquireLoaded(id) orelse return;
            defer registry.release(s);
            s.lockTerminal();
            defer s.unlockTerminal();
            const h = s.hits.get(n) orelse return;
            break :blk h.dupe(a) catch return;
        };
        const st = sub.statusOf(id) orelse return;
        const line = protocol.stringifyAlloc(a, .{ .type = "hit", .id = id, .hit = hit, .status = st }) catch return;
        sub.sendLine(line);
    }

    /// Send the changes pending for `t` now, before a lifecycle frame.
    fn flushPending(sub: *Subscriber, id: u64, t: *Tracked) void {
        const fields = t.pending.take(io_mod.nowNanos(), true) orelse return;
        sub.changed(id, fields);
    }

    /// Send what is due; returns when more will be.
    fn flush(sub: *Subscriber) ?i64 {
        var due: ?i64 = null;
        var it = sub.table.iterator();
        while (it.next()) |kv| {
            const id = kv.key_ptr.*;
            const t = kv.value_ptr;
            if (!t.matched or t.ended) continue;
            _ = sub.fresh();
            const now = io_mod.nowNanos();
            if (sub.edge(id, t, now)) |at| due = earliest(due, at);
            if (t.pending.take(now, false)) |fields| sub.changed(id, fields);
            if (t.pending.due()) |at| due = earliest(due, at);
            if (sub.gone) return null;
        }
        return due;
    }

    /// Send an idle or active edge for `t` if one is due and may go out;
    /// returns when to look again.
    fn edge(sub: *Subscriber, id: u64, t: *Tracked, now: i64) ?i64 {
        const idle_ns = sub.idle_ns orelse return null;
        const was_idle = t.idle orelse return null;
        if (!was_idle) {
            if (now < t.text_ns + idle_ns) return t.text_ns + idle_ns;
            // The change may not have been published yet.
            t.text_ns = @max(t.text_ns, lastTextChange(id) orelse return null);
            if (now < t.text_ns + idle_ns) return t.text_ns + idle_ns;
        } else if (t.text_ns == t.idle_text_ns) return null;
        if (!t.pending.open(now)) return t.pending.last_ns + interval_ns;
        t.pending.spend(now);
        t.idle = !was_idle;
        t.idle_text_ns = t.text_ns;
        sub.frame(if (was_idle) "active" else "idle", id, sub.statusOf(id) orelse return null);
        return if (was_idle) t.text_ns + idle_ns else null;
    }

    fn changed(sub: *Subscriber, id: u64, fields: Fields) void {
        const a = sub.arena.allocator();
        const st = sub.statusOf(id) orelse return;
        var list: std.ArrayList([]const u8) = .empty;
        var it = fields.iterator();
        while (it.next()) |f| list.append(a, @tagName(f)) catch return;
        const line = protocol.stringifyAlloc(a, .{ .type = "changed", .id = id, .fields = list.items, .status = st }) catch return;
        sub.sendLine(line);
    }

    fn frame(sub: *Subscriber, kind: []const u8, id: u64, st: ?Status) void {
        const line = protocol.stringifyAlloc(sub.arena.allocator(), .{ .type = kind, .id = id, .status = st }) catch return;
        sub.sendLine(line);
    }

    fn sendLine(sub: *Subscriber, text: []const u8) void {
        const with_end = std.mem.concat(sub.arena.allocator(), u8, &.{ text, "\n" }) catch return;
        _ = sub.write(with_end);
    }

    /// Write `bytes`; false once the client is gone, or took nothing for
    /// `stall_ns` and got the too_slow end. Never blocks for long without
    /// checking.
    fn write(sub: *Subscriber, bytes: []const u8) bool {
        if (sub.gone) return false;
        var last_progress = io_mod.nowNanos();
        var i: usize = 0;
        while (i < bytes.len) {
            const no_signal = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;
            const n = std.c.sendto(sub.fd, bytes.ptr + i, bytes.len - i, std.c.MSG.DONTWAIT | no_signal, null, 0);
            if (n > 0) {
                i += @intCast(n);
                last_progress = io_mod.nowNanos();
                continue;
            }
            switch (std.posix.errno(n)) {
                .INTR => {},
                .AGAIN => {
                    const stalled = io_mod.nowNanos() - last_progress;
                    if (stalled >= stall_ns or (shutting_down.load(.acquire) and stalled >= final_line_ns)) {
                        sub.mid_line = i > 0;
                        if (stalled >= stall_ns) sub.finish(too_slow_line);
                        sub.gone = true;
                        return false;
                    }
                    var pfd = [1]std.c.pollfd{.{ .fd = sub.fd, .events = std.c.POLL.OUT, .revents = 0 }};
                    _ = std.c.poll(&pfd, 1, 100);
                },
                else => {
                    sub.gone = true;
                    return false;
                },
            }
        }
        return true;
    }

    /// Try to deliver the last line for at most `final_line_ns`.
    fn finish(sub: *Subscriber, last: []const u8) void {
        if (sub.finished) return;
        sub.finished = true;
        const deadline = io_mod.nowNanos() + final_line_ns;
        const bytes = if (sub.mid_line) "\n" else "";
        for ([_][]const u8{ bytes, last }) |part| {
            var i: usize = 0;
            while (i < part.len and io_mod.nowNanos() < deadline) {
                const no_signal = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;
                const n = std.c.sendto(sub.fd, part.ptr + i, part.len - i, std.c.MSG.DONTWAIT | no_signal, null, 0);
                if (n > 0) {
                    i += @intCast(n);
                    continue;
                }
                switch (std.posix.errno(n)) {
                    .INTR => {},
                    .AGAIN => {
                        var pfd = [1]std.c.pollfd{.{ .fd = sub.fd, .events = std.c.POLL.OUT, .revents = 0 }};
                        _ = std.c.poll(&pfd, 1, 100);
                    },
                    else => return,
                }
            }
        }
    }
};

fn earliest(a: ?i64, b: i64) i64 {
    return if (a) |x| @min(x, b) else b;
}

/// When the screen text of running session `id` last changed (monotonic);
/// null once it has ended.
fn lastTextChange(id: u64) ?i64 {
    const s = registry.acquireLoaded(id) orelse return null;
    defer registry.release(s);
    if (s.state.load(.acquire) != .running) return null;
    return s.track.last_text_change_ns.load(.acquire);
}

/// Serve an events stream to the client on `fd` until it hangs up, falls
/// too far behind, or the daemon shuts down. `reply` is the request's
/// reply line, sent first. The caller counts the stream among the open
/// ones, and closes `fd` afterwards.
pub fn serve(fd: std.posix.fd_t, opts: Options, reply: []const u8) void {
    _ = open_streams.fetchAdd(1, .acq_rel);
    defer _ = open_streams.fetchSub(1, .acq_rel);
    // The stream lives as long as the client wants: no request deadline.
    var no_timeout: std.posix.timeval = .{ .sec = 0, .usec = 0 };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&no_timeout), @sizeOf(std.posix.timeval));
    var sub: Subscriber = .{
        .fd = fd,
        .opts = opts,
        .idle_ns = if (opts.idle_ms) |ms| @as(i64, @intCast(@min(ms, max_idle_ms))) * std.time.ns_per_ms else null,
        .arena = .init(gpa),
    };
    defer sub.deinit();
    const io = io_mod.io();
    const first = blk: {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        subscribers += 1;
        watchers.store(subscribers, .release);
        sub.cursor = head;
        break :blk subscribers == 1;
    };
    // Evaluators parked without anyone wanting samples start sampling.
    if (first) if (registry.acquireAll(gpa)) |all| {
        defer registry.releaseAll(gpa, all);
        for (all) |s| s.track.notify();
    } else |_| {};
    defer {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        subscribers -= 1;
        watchers.store(subscribers, .release);
    }
    defer if (shutting_down.load(.acquire)) sub.finish(shutdown_line);
    const reply_line = std.mem.concat(gpa, u8, &.{ reply, "\n" }) catch return;
    defer gpa.free(reply_line);
    if (!sub.write(reply_line)) return;
    sub.snapshot();
    var batch: [64]Entry = undefined;
    while (!sub.gone and !shutting_down.load(.acquire)) {
        if (hangup.gone(fd)) return;
        const woken = wake.load(.acquire);
        const got = sub.take(&batch) orelse {
            sub.resync();
            continue;
        };
        for (batch[0..got]) |e| {
            sub.handle(e);
            if (sub.gone) break;
        }
        const due = sub.flush();
        if (got == batch.len) continue;
        const now = io_mod.nowNanos();
        const until = @min(due orelse std.math.maxInt(i64), now + std.time.ns_per_s);
        if (until <= now) continue;
        io.futexWaitTimeout(u32, &wake.raw, woken, .{
            .duration = .{ .raw = .fromNanoseconds(until - now), .clock = .boot },
        }) catch {};
    }
    // The sessions the shutdown stopped have published their ends.
    if (shutting_down.load(.acquire)) while (!sub.gone) {
        const got = sub.take(&batch) orelse break;
        for (batch[0..got]) |e| {
            sub.handle(e);
            if (sub.gone) break;
        }
        _ = sub.flush();
        if (got < batch.len) break;
    };
}

test "change frames about a session wait their turn, and their fields add up" {
    var c: Coalescer = .{};
    const t0: i64 = 1_000_000_000;
    c.add(.initOne(.seq));
    try std.testing.expectEqual(Fields.initOne(.seq), c.take(t0, false).?);
    // Within the interval nothing goes out, but everything is kept.
    c.add(.initOne(.title));
    c.add(.initOne(.seq));
    try std.testing.expectEqual(@as(?Fields, null), c.take(t0 + interval_ns / 2, false));
    try std.testing.expectEqual(@as(?i64, t0 + interval_ns), c.due());
    const both = c.take(t0 + interval_ns, false).?;
    try std.testing.expect(both.contains(.title) and both.contains(.seq));
    try std.testing.expectEqual(@as(?i64, null), c.due());
    // A lifecycle frame takes what is pending at once; an edge spends the
    // turn.
    c.add(.initOne(.bell));
    try std.testing.expectEqual(Fields.initOne(.bell), c.take(t0 + interval_ns + 1, true).?);
    c.spend(t0 + 3 * interval_ns);
    try std.testing.expect(!c.open(t0 + 3 * interval_ns + 1));
}
