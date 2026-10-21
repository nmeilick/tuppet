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
/// "password?" (input is read without echo), the alert of a
/// hit not seen yet, "bell" (rung and not seen yet), "stopped" (by
/// `tuppet stop`), "done", "lost", "quiet 3m", or "running".
pub fn stateWord(buf: []u8, s: Status) []const u8 {
    const end = endWord(buf, s);
    if (std.mem.startsWith(u8, end, "failed") or std.mem.eql(u8, end, "lost") or std.mem.eql(u8, end, "damaged")) return end;
    if (s.state == .running and s.hidden_input == true) return "password?";
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
/// hit, or its end that no client has shown yet.
pub fn needsAttention(s: Status) bool {
    return s.bell_count > s.seen.bell_count or
        s.notification_count > s.seen.notification_count or
        (s.hit_seq orelse 0) > (s.seen.hit_seq orelse 0) or
        (s.state != .running and !s.seen.ended);
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
/// Control characters are shown escaped, never written as they are.
pub fn commandText(buf: []u8, argv: []const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (argv, 0..) |arg, i| {
        if (i > 0) w.writeByte(' ') catch break;
        const plain = arg.len > 0 and for (arg) |c| {
            if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_./=:,+@%", c) != null or c >= 0x80)) break false;
        } else true;
        if (plain) {
            w.writeAll(arg) catch break;
            continue;
        }
        w.writeByte('\'') catch break;
        for (arg) |c| {
            (switch (c) {
                '\'' => w.writeAll("'\\''"),
                0...0x1f, 0x7f => w.print("\\x{x:0>2}", .{c}),
                else => w.writeByte(c),
            }) catch break;
        }
        w.writeByte('\'') catch break;
    }
    return w.buffered();
}

const testing = std.testing;

test "state words follow the priority list" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("failed 3", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 3 } }));
    try testing.expectEqualStrings("failed SIGKILL", stateWord(&buf, .{ .state = .exited, .exit = .{ .signal = "SIGKILL" } }));
    try testing.expectEqualStrings("done", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 0 } }));
    try testing.expectEqualStrings("password?", stateWord(&buf, .{ .state = .running, .idle_ms = 200_000, .hidden_input = true }));
    try testing.expectEqualStrings("quiet 3m", stateWord(&buf, .{ .state = .running, .idle_ms = 200_000 }));
    try testing.expectEqualStrings("running", stateWord(&buf, .{ .state = .running, .idle_ms = 500 }));
    try testing.expectEqualStrings("lost", stateWord(&buf, .{ .state = .lost }));
    try testing.expectEqualStrings("damaged", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 0 }, .bell_count = 1, .damaged = "its stored size 0x0 is outside 1..1000" }));
    try testing.expectEqualStrings("bell", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 0 }, .bell_count = 2, .seen = .{ .bell_count = 1 } }));
    try testing.expectEqualStrings("done", stateWord(&buf, .{ .state = .exited, .exit = .{ .code = 0 }, .bell_count = 2, .seen = .{ .bell_count = 2 } }));
    try testing.expectEqualStrings("stopped", stateWord(&buf, .{ .state = .exited, .exit = .{ .signal = "SIGHUP", .stopped = true } }));
    const hit: Status = .{ .state = .running, .bell_count = 1, .hit_seq = 2, .hit_alerts = &.{"approve-edits-now"}, .seen = .{ .hit_seq = 1 } };
    try testing.expectEqualStrings("approve-edit", stateWord(&buf, hit));
    var seen = hit;
    seen.seen.hit_seq = 2;
    try testing.expectEqualStrings("bell", stateWord(&buf, seen));
}

test "commands are shown as a shell would need them" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("vim notes.txt", commandText(&buf, &.{ "vim", "notes.txt" }));
    try testing.expectEqualStrings("sh -c 'echo hi; exit 3'", commandText(&buf, &.{ "sh", "-c", "echo hi; exit 3" }));
    try testing.expectEqualStrings("echo 'it'\\''s'", commandText(&buf, &.{ "echo", "it's" }));
    try testing.expectEqualStrings("printf 'a\\x1bb'", commandText(&buf, &.{ "printf", "a\x1bb" }));
}
