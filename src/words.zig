//! How sessions look to people, the same in `tuppet list` and the picker:
//! one state word, an age, and the command line.

const std = @import("std");
const status = @import("status.zig");

const Status = status.Status;

/// A running session whose screen text has not changed for this long is
/// "quiet".
pub const quiet_ms: u64 = std.time.ms_per_min;

/// A hit's alert in the STATE word is cut to this many columns.
pub const max_label_cols = 12;

/// The state in one word or two, by priority: "damaged" (the stored
/// session cannot be loaded), "failed N" (an exit code or a signal),
/// "password?" (input is read without echo), "box waits" (see
/// `boxWaits`), the alert of a hit not seen yet, "bell" (rung and not
/// seen yet), "stopped" (by `tuppet stop`), "done", "lost", "quiet 3m",
/// or "running". `all` holds the sessions known with `s`, its boxes
/// among them.
pub fn stateWord(buf: []u8, s: Status, all: []const Status) []const u8 {
    const end = endWord(buf, s);
    if (std.mem.startsWith(u8, end, "failed") or std.mem.eql(u8, end, "lost") or std.mem.eql(u8, end, "damaged")) return end;
    if (s.state == .running and s.hidden_input == true) return "password?";
    if (boxWaits(s, all)) return "box waits";
    if ((s.hit_seq orelse 0) > (s.seen.hit_seq orelse 0)) {
        // Alert names are ASCII: a byte is a column.
        const label = if (s.hit_alerts.len > 0) s.hit_alerts[0] else "hit";
        return label[0..@min(label.len, max_label_cols)];
    }
    if (s.bell_count > s.seen.bell_count) return "bell";
    if (s.state != .running) return end;
    if (s.idle_ms < quiet_ms) return "running";
    var age_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "quiet {s}", .{age(&age_buf, s.idle_ms)}) catch "quiet";
}

/// How an ended session ended: "failed N", "stopped", "done", "lost",
/// or "damaged"; "" while it runs.
pub fn endWord(buf: []u8, s: Status) []const u8 {
    if (s.damaged != null) return "damaged";
    return switch (s.state) {
        .running => "",
        .lost => "lost",
        .exited => blk: {
            const exit = s.exit orelse break :blk "done";
            if (exit.stopped) break :blk "stopped";
            if (exit.signal) |sig| break :blk std.fmt.bufPrint(buf, "failed {s}", .{sig}) catch "failed";
            const code = exit.code orelse 0;
            if (code == 0) break :blk "done";
            break :blk std.fmt.bufPrint(buf, "failed {d}", .{code}) catch "failed";
        },
    };
}

/// Whether the session needs someone: a bell, a notification, an alert
/// hit, or its end that no client has shown yet, or a box that waits
/// over it, which no ack clears.
pub fn needsAttention(s: Status, all: []const Status) bool {
    return s.bell_count > s.seen.bell_count or
        s.notification_count > s.seen.notification_count or
        (s.hit_seq orelse 0) > (s.seen.hit_seq orelse 0) or
        (s.state != .running and !s.seen.ended) or
        boxWaits(s, all);
}

/// Whether a box waits over session `s`: one of `all` runs over it,
/// takes the keyboard (its grab is not never), and has no writer.
pub fn boxWaits(s: Status, all: []const Status) bool {
    for (s.under) |id| {
        for (all) |box| {
            if (box.id != id) continue;
            if (waitsOver(box, s.id)) return true;
            break;
        }
    }
    return false;
}

/// Whether `box` is a box that waits over session `under`.
pub fn waitsOver(box: Status, under: u64) bool {
    const over = box.over orelse return false;
    return box.state == .running and over.id == under and over.grab != .never and box.writer == null;
}

/// A duration in its largest whole unit: 42s, 3m, 5h, 2d.
pub fn age(buf: []u8, ms: u64) []const u8 {
    const secs = ms / std.time.ms_per_s;
    return (if (secs < 60)
        std.fmt.bufPrint(buf, "{d}s", .{secs})
    else if (secs < 3600)
        std.fmt.bufPrint(buf, "{d}m", .{secs / 60})
    else if (secs < 86400)
        std.fmt.bufPrint(buf, "{d}h", .{secs / 3600})
    else
        std.fmt.bufPrint(buf, "{d}d", .{secs / 86400})) catch "";
}

/// How long ago a session started, from a Unix time in milliseconds.
pub fn ageSince(buf: []u8, started_ms: i64, now_ms: i64) []const u8 {
    return age(buf, @intCast(@max(0, now_ms -| started_ms)));
}

/// The command line, with arguments that need it quoted for a shell.
/// Control characters (C0, C1, and bidi) and bytes that are not UTF-8
/// are shown escaped, never written as they are.
pub fn commandText(buf: []u8, argv: []const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (argv, 0..) |arg, i| {
        if (i > 0) w.writeByte(' ') catch break;
        if (isPlain(arg)) {
            w.writeAll(arg) catch break;
            continue;
        }
        w.writeByte('\'') catch break;
        var at: usize = 0;
        while (at < arg.len) {
            const start = at;
            const cp = nextChar(arg, &at);
            const char = arg[start..at];
            if (cp == null or status.isControl(cp.?)) {
                for (char) |c| w.print("\\x{x:0>2}", .{c}) catch break;
            } else {
                w.writeAll(if (cp.? == '\'') "'\\''" else char) catch break;
            }
        }
        w.writeByte('\'') catch break;
    }
    return w.buffered();
}

/// Whether a shell takes `arg` as it is, and it shows as it is.
fn isPlain(arg: []const u8) bool {
    if (arg.len == 0) return false;
    var at: usize = 0;
    while (at < arg.len) {
        const cp = nextChar(arg, &at) orelse return false;
        if (cp >= 0x80) {
            if (status.isControl(cp)) return false;
        } else if (!std.ascii.isAlphanumeric(@intCast(cp)) and std.mem.indexOfScalar(u8, "-_./=:,+@%", @intCast(cp)) == null) return false;
    }
    return true;
}

/// The character at `i.*`, or null for a byte that does not start one;
/// moves `i` past it.
fn nextChar(text: []const u8, i: *usize) ?u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[i.*]) catch 0;
    const cp: ?u21 = if (len > 0 and i.* + len <= text.len) std.unicode.utf8Decode(text[i.*..][0..len]) catch null else null;
    i.* += if (cp != null) len else 1;
    return cp;
}

const testing = std.testing;

test "state words follow the priority list" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("failed 3", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 3 } }, &.{}));
    try testing.expectEqualStrings("failed SIGKILL", stateWord(&buf, .{ .state = .exited, .exit = .{ .signal = "SIGKILL" } }, &.{}));
    try testing.expectEqualStrings("done", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 0 } }, &.{}));
    try testing.expectEqualStrings("password?", stateWord(&buf, .{ .state = .running, .idle_ms = 200_000, .hidden_input = true }, &.{}));
    try testing.expectEqualStrings("quiet 3m", stateWord(&buf, .{ .state = .running, .idle_ms = 200_000 }, &.{}));
    try testing.expectEqualStrings("running", stateWord(&buf, .{ .state = .running, .idle_ms = 500 }, &.{}));
    try testing.expectEqualStrings("lost", stateWord(&buf, .{ .state = .lost }, &.{}));
    try testing.expectEqualStrings("damaged", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 0 }, .bell_count = 1, .damaged = "its stored size 0x0 is outside 1..1000" }, &.{}));
    try testing.expectEqualStrings("bell", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 0 }, .bell_count = 2, .seen = .{ .bell_count = 1 } }, &.{}));
    try testing.expectEqualStrings("done", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 0 }, .bell_count = 2, .seen = .{ .bell_count = 2 } }, &.{}));
    try testing.expectEqualStrings("stopped", stateWord(&buf, .{ .state = .exited, .exit = .{ .signal = "SIGHUP", .stopped = true } }, &.{}));
    const hit: Status = .{ .state = .running, .bell_count = 1, .hit_seq = 2, .hit_alerts = &.{"approve-edits-now"}, .seen = .{ .hit_seq = 1 } };
    try testing.expectEqualStrings("approve-edit", stateWord(&buf, hit, &.{}));
    var seen = hit;
    seen.seen.hit_seq = 2;
    try testing.expectEqualStrings("bell", stateWord(&buf, seen, &.{}));
}

test "a box that takes keys and has no writer waits over its session, also after an ack" {
    var buf: [32]u8 = undefined;
    const under: Status = .{ .id = 1, .idle_ms = 500, .under = &.{2}, .seen = .{ .at_ms = 1 } };
    var box: Status = .{ .id = 2, .over = .{ .id = 1 } };
    try testing.expectEqualStrings("box waits", stateWord(&buf, under, &.{ under, box }));
    try testing.expect(needsAttention(under, &.{ under, box }));
    try testing.expectEqualStrings("password?", stateWord(&buf, .{ .id = 1, .hidden_input = true, .under = &.{2} }, &.{box}));
    // The box itself waits for no one, and old daemons send no under.
    try testing.expect(!needsAttention(box, &.{ under, box }));
    try testing.expect(!boxWaits(.{ .id = 1 }, &.{box}));
    box.writer = .{};
    try testing.expectEqualStrings("running", stateWord(&buf, under, &.{ under, box }));
    box.writer = null;
    box.over.?.grab = .never;
    try testing.expect(!needsAttention(under, &.{ under, box }));
}

test "commands are shown as a shell would need them" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("vim notes.txt", commandText(&buf, &.{ "vim", "notes.txt" }));
    try testing.expectEqualStrings("sh -c 'echo hi; exit 3'", commandText(&buf, &.{ "sh", "-c", "echo hi; exit 3" }));
    try testing.expectEqualStrings("echo 'it'\\''s'", commandText(&buf, &.{ "echo", "it's" }));
    try testing.expectEqualStrings("printf 'a\\x1bb'", commandText(&buf, &.{ "printf", "a\x1bb" }));
    try testing.expectEqualStrings("echo caf\u{e9} 'a\\xc2\\x9bb\\xe2\\x80\\xaec\\xffd'", commandText(&buf, &.{ "echo", "caf\u{e9}", "a\u{9b}b\u{202e}c\xffd" }));
}
