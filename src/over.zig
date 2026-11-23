//! Boxes: sessions started with `run` `over` another session, which a
//! drawing client shows over it. The daemon keeps the relation: the
//! running boxes of each session (at most 16), what a box's `over` says,
//! and the only two cases in which the daemon stops a session on its own:
//! a box whose session underneath ended, and a box whose `unseen_ms` ran
//! out before it was held (shown, for grab never).

const std = @import("std");
const status = @import("status.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const events = @import("events.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;

/// A session has at most this many running boxes.
pub const max_boxes = 16;
/// The longest `unseen_ms`: a day.
pub const max_unseen_ms: u64 = std.time.ms_per_day;

/// The running boxes over one session, oldest first, and the ones still
/// starting; guarded by the session's terminal_mutex.
pub const Boxes = struct {
    ids: [max_boxes]u64 = undefined,
    len: u8 = 0,
    starting: u8 = 0,
    /// The session has ended: no box starts over it any more.
    closed: bool = false,

    /// Make room for a box that starts.
    pub fn reserve(b: *Boxes) error{ Ended, Limit }!void {
        if (b.closed) return error.Ended;
        if (b.len + b.starting >= max_boxes) return error.Limit;
        b.starting += 1;
    }

    /// Give back the room of a box that did not start.
    pub fn unreserve(b: *Boxes) void {
        b.starting -= 1;
    }

    /// Box `id` started in the room it reserved. False when the session
    /// ended meanwhile, so that the box must be stopped.
    pub fn add(b: *Boxes, id: u64) bool {
        b.starting -= 1;
        var i: usize = b.len;
        while (i > 0 and b.ids[i - 1] > id) : (i -= 1) b.ids[i] = b.ids[i - 1];
        b.ids[i] = id;
        b.len += 1;
        return !b.closed;
    }

    /// Box `id` ended; whether it was one of these.
    pub fn remove(b: *Boxes, id: u64) bool {
        const i = std.mem.indexOfScalar(u64, b.list(), id) orelse return false;
        std.mem.copyForwards(u64, b.ids[i .. b.len - 1], b.ids[i + 1 .. b.len]);
        b.len -= 1;
        return true;
    }

    pub fn list(b: *const Boxes) []const u64 {
        return b.ids[0..b.len];
    }

    /// The session ended: no box starts any more. Returns the boxes as
    /// they are, for stopping.
    pub fn close(b: *Boxes) Boxes {
        b.closed = true;
        return b.*;
    }
};

/// What `over` of a run request asks for: how the box is shown (the
/// session underneath is resolved by the caller) and its unseen_ms.
pub const Start = struct {
    over: status.Over,
    unseen_ms: ?u64 = null,
};

pub const Checked = union(enum) {
    ok: Start,
    /// Why the request is bad.
    bad: []const u8,
};

/// Check `over` of a run request. `null_backdrop` says that the request
/// gave `backdrop` as null, which leaving it out does not: left out, it
/// is frozen, or none with grab never.
pub fn check(gpa: std.mem.Allocator, o: protocol.RunOver, null_backdrop: bool) !Checked {
    if (o.unseen_ms) |ms| if (ms == 0 or ms > max_unseen_ms) {
        return .{ .bad = std.fmt.comptimePrint("over.unseen_ms must be 1..{d} (a day)", .{max_unseen_ms}) };
    };
    const backdrop: ?status.Backdrop = switch (o.grab) {
        .never => if (o.backdrop != null) return .{ .bad = "over.backdrop must be null with grab never, which never takes the keyboard" } else null,
        .pause, .now => if (null_backdrop) return .{ .bad = "over.backdrop must be frozen or live with grab pause or now" } else o.backdrop orelse .frozen,
    };
    return .{ .ok = .{
        .over = .{ .title = try status.boxTitleOf(gpa, o.title), .backdrop = backdrop, .grab = o.grab },
        .unseen_ms = o.unseen_ms,
    } };
}

/// Whether a box was seen as its unseen_ms asks: held, or shown with grab
/// never.
pub fn seenEnough(over: status.Over) bool {
    return if (over.grab == .never) over.shown else over.held;
}

/// For the evaluator of session `s`: once the unseen_ms of a box ran out
/// while it was not seen enough, stop it. Returns when to look again, or
/// null.
pub fn checkUnseen(s: *Session, now: i64) ?i64 {
    const deadline = s.unseen_deadline.load(.acquire);
    if (deadline == 0) return null;
    if (now < deadline) return deadline;
    s.unseen_deadline.store(0, .release);
    s.lockTerminal();
    const seen = seenEnough(s.over.?);
    s.unlockTerminal();
    if (!seen) stopLater(s, .unseen);
    return null;
}

/// Session `s` has ended, its state exited already: stop the boxes over
/// it, and a box leaves the session underneath. Before its results are
/// saved, which can take a while.
pub fn ended(s: *Session) void {
    s.lockTerminal();
    const boxes = s.boxes.close();
    const under_id = if (s.over) |o| o.id else null;
    s.unlockTerminal();
    for (boxes.list()) |id| {
        const box = registry.acquireLoaded(id) orelse continue;
        defer registry.release(box);
        stopLater(box, .under);
    }
    const under = registry.acquireLoaded(under_id orelse return) orelse return;
    defer registry.release(under);
    under.lockTerminal();
    const left = under.boxes.remove(s.id);
    under.unlockTerminal();
    if (left) events.publish(under.id, .changed, .initOne(.under));
}

/// Box `s` started in the room it reserved on session `under_id`; the
/// caller holds a reference on `s` only. One that ended already is not
/// added: it left before it came. False when the session underneath
/// ended meanwhile, so that the box must be stopped.
pub fn started(under_id: u64, s: *Session) bool {
    const under = registry.acquireLoaded(under_id) orelse return s.state.load(.acquire) == .exited;
    defer registry.release(under);
    under.lockTerminal();
    defer under.unlockTerminal();
    // Its room is gone once it ended: it may even be a copy loaded back
    // from the store, which reserved none.
    if (under.state.load(.acquire) == .exited) return s.state.load(.acquire) == .exited;
    // `ended` removes a box after its state turned exited, under this lock.
    if (s.state.load(.acquire) == .exited) {
        under.boxes.unreserve();
        return true;
    }
    return under.boxes.add(s.id);
}

/// Give back the room reserved on session `under_id` for a box that did
/// not start; see `started`.
pub fn unreserve(under_id: u64) void {
    const under = registry.acquireLoaded(under_id) orelse return;
    defer registry.release(under);
    under.lockTerminal();
    defer under.unlockTerminal();
    if (under.state.load(.acquire) != .exited) under.boxes.unreserve();
}

/// Stop box `s` for `why` on a thread of its own, as a stop waits for the
/// program to end. The caller holds a reference on `s`, or is its
/// evaluator.
pub fn stopLater(s: *Session, why: status.EndedBy) void {
    _ = s.refs.fetchAdd(1, .acq_rel);
    const thread = std.Thread.spawn(.{}, stopNow, .{ s, why }) catch |err| {
        std.log.err("session {d}: cannot stop it ({s}): {}", .{ s.id, @tagName(why), err });
        registry.release(s);
        return;
    };
    thread.detach();
}

fn stopNow(s: *Session, why: status.EndedBy) void {
    defer registry.release(s);
    s.stopFor(why) catch |err| std.log.err("session {d}: cannot stop it ({s}): {}", .{ s.id, @tagName(why), err });
}

test "a session takes 16 running boxes, oldest first, and none once it ended" {
    var b: Boxes = .{};
    for (0..max_boxes) |_| try b.reserve();
    try std.testing.expectError(error.Limit, b.reserve());
    // Starts finish in any order; the list stays in id order.
    try std.testing.expect(b.add(5));
    try std.testing.expect(b.add(3));
    for (0..max_boxes - 2) |i| try std.testing.expect(b.add(10 + i));
    try std.testing.expectEqualSlices(u64, &.{ 3, 5, 10 }, b.list()[0..3]);
    try std.testing.expect(b.remove(5));
    try std.testing.expect(!b.remove(5));
    try std.testing.expectEqualSlices(u64, &.{ 3, 10, 11 }, b.list()[0..3]);
    // One ended leaves room for one more.
    try b.reserve();
    try std.testing.expectError(error.Limit, b.reserve());
    b.unreserve();
    try b.reserve();
    const stopping = b.close();
    try std.testing.expectEqual(@as(usize, max_boxes - 1), stopping.list().len);
    try std.testing.expectError(error.Ended, b.reserve());
    // A box that started while the session ended is stopped by its starter.
    try std.testing.expect(!b.add(99));
}

test "over is checked at the request: the backdrop goes with grab, unseen_ms is 1 ms to a day" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = (try check(a, .{ .session = "1", .title = "deploy\x1b[31m?\u{202e}" }, false)).ok;
    try std.testing.expectEqual(status.Backdrop.frozen, ok.over.backdrop.?);
    try std.testing.expectEqual(status.Grab.pause, ok.over.grab);
    try std.testing.expectEqualStrings("deploy[31m?", ok.over.title.?);
    var long: [90]u8 = undefined;
    for (0..30) |i| @memcpy(long[i * 3 ..][0..3], "\u{20ac}");
    try std.testing.expectEqual(@as(usize, 63), (try check(a, .{ .session = "1", .title = &long }, false)).ok.over.title.?.len);
    try std.testing.expectEqual(@as(?[]const u8, null), (try check(a, .{ .session = "1", .title = "\x07" }, false)).ok.over.title);
    try std.testing.expectEqual(@as(?status.Backdrop, null), (try check(a, .{ .session = "1", .grab = .never }, true)).ok.over.backdrop);
    try std.testing.expectEqual(@as(?status.Backdrop, null), (try check(a, .{ .session = "1", .grab = .never }, false)).ok.over.backdrop);
    try std.testing.expect((try check(a, .{ .session = "1", .grab = .never, .backdrop = .frozen }, false)) == .bad);
    try std.testing.expect((try check(a, .{ .session = "1", .grab = .now }, true)) == .bad);
    try std.testing.expectEqual(status.Backdrop.live, (try check(a, .{ .session = "1", .grab = .now, .backdrop = .live }, false)).ok.over.backdrop.?);
    try std.testing.expect((try check(a, .{ .session = "1", .unseen_ms = 0 }, false)) == .bad);
    try std.testing.expect((try check(a, .{ .session = "1", .unseen_ms = max_unseen_ms + 1 }, false)) == .bad);
    try std.testing.expectEqual(@as(?u64, max_unseen_ms), (try check(a, .{ .session = "1", .unseen_ms = max_unseen_ms }, false)).ok.unseen_ms);
}

test "unseen_ms asks for a writer, or a viewer with grab never" {
    try std.testing.expect(!seenEnough(.{ .shown = true }));
    try std.testing.expect(seenEnough(.{ .shown = true, .held = true }));
    try std.testing.expect(seenEnough(.{ .grab = .never, .shown = true }));
    try std.testing.expect(!seenEnough(.{ .grab = .never }));
}
