//! Compresses a file for embedding; build.zig runs it on the host:
//!
//!     deflate IN OUT
//!
//! OUT is a u32 (little-endian) with the length of IN, then IN as raw
//! deflate.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) fatal("usage: deflate IN OUT", .{});
    const cwd = std.Io.Dir.cwd();
    const raw = try cwd.readFileAlloc(io, args[1], a, .limited(64 << 20));
    var out: std.Io.Writer.Allocating = try .initCapacity(a, raw.len / 2);
    try out.writer.writeInt(u32, @intCast(raw.len), .little);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&out.writer, &window, .raw, .best);
    try c.writer.writeAll(raw);
    try c.finish();
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("deflate: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
