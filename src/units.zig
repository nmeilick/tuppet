//! Values people type: durations and byte sizes, in options and in
//! environment variables alike.

const std = @import("std");
const protocol = @import("protocol.zig");

/// Whether a duration may be given in days: only where that much makes
/// sense, such as how long ended sessions are kept.
pub const Days = enum { days, no_days };

/// A duration in milliseconds: a whole number with a unit (ms, s, m, h,
/// and d where `days` allows it), or 0 alone.
pub fn parseDuration(text: []const u8, days: Days) ?u64 {
    if (std.mem.eql(u8, text, "0")) return 0;
    const digits = std.mem.indexOfNone(u8, text, "0123456789") orelse return null;
    if (digits == 0) return null;
    const unit = text[digits..];
    const scale: u64 = if (std.mem.eql(u8, unit, "ms"))
        1
    else if (std.mem.eql(u8, unit, "s"))
        std.time.ms_per_s
    else if (std.mem.eql(u8, unit, "m"))
        std.time.ms_per_min
    else if (std.mem.eql(u8, unit, "h"))
        std.time.ms_per_hour
    else if (std.mem.eql(u8, unit, "d") and days == .days)
        std.time.ms_per_day
    else
        return null;
    const n = protocol.parseDecimal(u64, text[0..digits]) orelse return null;
    const ms = std.math.mul(u64, n, scale) catch return null;
    // Everything downstream counts in signed nanoseconds.
    if (ms > std.math.maxInt(i64) / std.time.ns_per_ms) return null;
    return ms;
}

/// What a duration looks like, for error messages.
pub fn durationHint(days: Days) []const u8 {
    return switch (days) {
        .days => "a number with ms, s, m, h, or d, such as 500ms or 7d, or 0",
        .no_days => "a number with ms, s, m, or h, such as 500ms or 5s, or 0",
    };
}

/// A duration as people write it, exactly: 200ms, 2s, 1.5s, 1m30s, 2h,
/// 1999ms.
pub fn durationText(buf: []u8, ms: u64) []const u8 {
    if (ms % 1000 != 0) {
        if (ms > std.time.ms_per_s and ms < std.time.ms_per_min and ms % 100 == 0)
            return std.fmt.bufPrint(buf, "{d}.{d}s", .{ ms / 1000, ms % 1000 / 100 }) catch "";
        return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "";
    }
    if (ms < std.time.ms_per_min) return std.fmt.bufPrint(buf, "{d}s", .{ms / 1000}) catch "";
    const s = ms / 1000;
    if (s % 3600 == 0) return std.fmt.bufPrint(buf, "{d}h", .{s / 3600}) catch "";
    if (s % 60 == 0) return std.fmt.bufPrint(buf, "{d}m", .{s / 60}) catch "";
    return std.fmt.bufPrint(buf, "{d}m{d}s", .{ s / 60, s % 60 }) catch "";
}

/// A byte count with an optional K, M, or G suffix (powers of 1024).
pub fn parseByteSize(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    const shift: u6 = switch (std.ascii.toUpper(text[text.len - 1])) {
        'K' => 10,
        'M' => 20,
        'G' => 30,
        else => 0,
    };
    const digits = if (shift == 0) text else text[0 .. text.len - 1];
    const n = protocol.parseDecimal(u64, digits) orelse return null;
    return std.math.shlExact(u64, n, shift) catch null;
}

const testing = std.testing;

test "durations need a unit, except 0" {
    try testing.expectEqual(@as(?u64, 500), parseDuration("500ms", .no_days));
    try testing.expectEqual(@as(?u64, 5000), parseDuration("5s", .no_days));
    try testing.expectEqual(@as(?u64, 120_000), parseDuration("2m", .no_days));
    try testing.expectEqual(@as(?u64, 3_600_000), parseDuration("1h", .no_days));
    try testing.expectEqual(@as(?u64, 0), parseDuration("0", .no_days));
    try testing.expectEqual(@as(?u64, 0), parseDuration("0s", .no_days));
    try testing.expectEqual(@as(?u64, 7 * std.time.ms_per_day), parseDuration("7d", .days));
    try testing.expectEqual(@as(?u64, null), parseDuration("7d", .no_days));
    try testing.expectEqual(@as(?u64, null), parseDuration("500", .no_days));
    try testing.expectEqual(@as(?u64, null), parseDuration("s", .no_days));
    try testing.expectEqual(@as(?u64, null), parseDuration("-1s", .no_days));
    try testing.expectEqual(@as(?u64, null), parseDuration("1.5s", .no_days));
    try testing.expectEqual(@as(?u64, null), parseDuration("9223372036854775807s", .no_days));
}

test "byte sizes take K, M, and G suffixes" {
    try testing.expectEqual(@as(?u64, 512 * 1024), parseByteSize("512K"));
    try testing.expectEqual(@as(?u64, 2 << 20), parseByteSize("2m"));
    try testing.expectEqual(@as(?u64, 0), parseByteSize("0"));
    try testing.expectEqual(@as(?u64, null), parseByteSize("1.5M"));
    try testing.expectEqual(@as(?u64, null), parseByteSize("K"));
}

test "durations print in the largest unit that fits" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("200ms", durationText(&buf, 200));
    try testing.expectEqualStrings("1.5s", durationText(&buf, 1500));
    try testing.expectEqualStrings("30s", durationText(&buf, 30_000));
    try testing.expectEqualStrings("1m30s", durationText(&buf, 90_000));
    try testing.expectEqualStrings("2h", durationText(&buf, 7_200_000));
    try testing.expectEqualStrings("1999ms", durationText(&buf, 1999));
    try testing.expectEqualStrings("61500ms", durationText(&buf, 61_500));
}
