//! The fixed limits that keep one request, stored file, or program from
//! using unbounded memory. The CLI, the daemon, and the store all check
//! against these; the daemon-wide sum is budget.zig's.

const std = @import("std");

/// Terminal sizes are 1..max_side cells on each side.
pub const max_side: u16 = 1000;
/// How sizes look in messages.
pub const size_range = std.fmt.comptimePrint("1..{d}", .{max_side});

/// History each session keeps unless its run asks for another size.
pub const default_scrollback: u64 = 8 << 20;
/// The most history a session may keep.
pub const max_scrollback: u64 = 1 << 30;

/// What one PNG render may hold: its pixels and its encoded image.
pub const max_png_render_bytes: u64 = 128 << 20;

/// A request's `sessions` list takes at most this many references.
pub const max_refs = 1024;

/// Change seqs and session ids above this are taken for damage, so that
/// counting up from any accepted one never overflows.
pub const max_seq: u64 = 1 << 62;
pub const max_id: u64 = 1 << 62;
/// Unix times in milliseconds above this (the year 3084) are damage.
pub const max_unix_ms: i64 = 1 << 45;

/// Ghostty allocates screens in pages of this size (measured), and a
/// cell costs about this much on one (measured: 8.4 bytes a cell for a
/// 1000x1000 screen).
pub const page_bytes: u64 = 372 << 10;
const cell_bytes: u64 = 9;

pub fn validSize(cols: u16, rows: u16) bool {
    return cols >= 1 and cols <= max_side and rows >= 1 and rows <= max_side;
}

/// Why a size is refused, or null when it is fine.
pub fn sizeError(cols: u16, rows: u16) ?[]const u8 {
    if (validSize(cols, rows)) return null;
    return "both dimensions must be " ++ size_range;
}

/// The least memory a session of this size holds whatever its history:
/// the main and the alternate screen, and the spare page Ghostty keeps
/// for the main one.
pub fn sessionFloor(cols: u16, rows: u16) u64 {
    const pages = std.math.divCeil(u64, cell_bytes * cols * rows, page_bytes) catch unreachable;
    return (2 * @max(1, pages) + 1) * page_bytes;
}

test "sizes are 1..1000 on each side" {
    try std.testing.expect(validSize(1, 1));
    try std.testing.expect(validSize(max_side, max_side));
    try std.testing.expect(!validSize(0, 40));
    try std.testing.expect(!validSize(120, max_side + 1));
    try std.testing.expectEqualStrings("both dimensions must be 1..1000", sizeError(65535, 65535).?);
}

test "a session's floor is whole pages, no less than Ghostty allocates" {
    // Measured: three pages up to 200x60; 17.1 MB at 1000x1000.
    try std.testing.expectEqual(3 * page_bytes, sessionFloor(1, 1));
    try std.testing.expectEqual(3 * page_bytes, sessionFloor(200, 60));
    try std.testing.expect(sessionFloor(max_side, max_side) >= 17_141_760);
}
