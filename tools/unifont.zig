//! Packs GNU Unifont for embedding; build.zig runs it on the host:
//!
//!     unifont BMP.hex UPPER.hex OUT
//!
//! It takes the whole Basic Multilingual Plane from BMP.hex and U+1F000 to
//! U+1FBFF from UPPER.hex. OUT is a u32 (little-endian) with the unpacked
//! length, then raw deflate of: a u32 glyph count; each code point as a u24
//! delta from the one before; a bitset of the wide glyphs; the left byte of
//! every glyph's 16 rows; the right byte of every wide glyph's rows.
//! Keeping the byte columns apart makes the data compress better.

const std = @import("std");
const bitmap = @import("bitmap");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) fatal("usage: unifont BMP.hex UPPER.hex OUT", .{});
    const cwd = std.Io.Dir.cwd();
    var diag: bitmap.Diagnostic = .{};
    const bmp_text = try cwd.readFileAlloc(io, args[1], a, .limited(bitmap.max_file_size));
    const bmp = bitmap.parseHex(a, bmp_text, .{ .max = 0xFFFF }, &diag) catch fatal("{s}: {s}", .{ args[1], diag.message });
    const upper_text = try cwd.readFileAlloc(io, args[2], a, .limited(bitmap.max_file_size));
    const upper = bitmap.parseHex(a, upper_text, .{ .min = 0x1F000, .max = 0x1FBFF }, &diag) catch fatal("{s}: {s}", .{ args[2], diag.message });

    const faces = [_]*const bitmap.Face{ &bmp, &upper };
    var count: u32 = 0;
    for (faces) |f| count += @intCast(f.cps.len);
    var raw: std.ArrayList(u8) = .empty;
    try appendInt(a, &raw, u32, count);
    var prev: u21 = 0;
    for (faces) |f| for (f.cps) |cp| {
        try appendInt(a, &raw, u24, cp - prev);
        prev = cp;
    };
    var bits = try a.alloc(u8, (count + 7) / 8);
    @memset(bits, 0);
    var i: usize = 0;
    for (faces) |f| for (f.entries) |e| {
        if (e.wide) bits[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        i += 1;
    };
    try raw.appendSlice(a, bits);
    for (faces) |f| for (f.cps) |cp| {
        const g = f.glyph(cp).?;
        for (0..16) |row| try raw.append(a, g.bits[row * g.stride]);
    };
    for (faces) |f| for (f.cps) |cp| {
        const g = f.glyph(cp).?;
        if (g.stride == 2) for (0..16) |row| try raw.append(a, g.bits[row * 2 + 1]);
    };

    var out: std.Io.Writer.Allocating = try .initCapacity(a, raw.items.len / 2);
    try out.writer.writeInt(u32, @intCast(raw.items.len), .little);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&out.writer, &window, .raw, .best);
    try c.writer.writeAll(raw.items);
    try c.finish();
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = out.written() });
}

fn appendInt(a: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(a, &b);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("unifont: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
