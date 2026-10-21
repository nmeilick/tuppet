//! GNU Unifont, embedded compressed: the Basic Multilingual Plane and
//! U+1F000 to U+1FBFF as 8x16 and 16x16 bitmaps. tools/unifont.zig packs
//! it at build time; `unpack` restores it on first use.

const std = @import("std");
const bitmap = @import("bitmap.zig");
const deflated = @import("deflated.zig");

const blob = @embedFile("unifont.bin");

/// Inflate the embedded font. The caller owns the face.
pub fn unpack(gpa: std.mem.Allocator) !bitmap.Face {
    const raw = try deflated.inflate(gpa, blob);
    defer gpa.free(raw);
    return decode(gpa, raw);
}

fn decode(gpa: std.mem.Allocator, raw: []const u8) !bitmap.Face {
    if (raw.len < 4) return error.BadFont;
    const count: usize = std.mem.readInt(u32, raw[0..4], .little);
    const bits_len = (count + 7) / 8;
    const fixed = 4 + count * 3 + bits_len + count * 16;
    if (raw.len < fixed) return error.BadFont;
    const deltas = raw[4..][0 .. count * 3];
    const wide_bits = raw[4 + count * 3 ..][0..bits_len];
    const left = raw[4 + count * 3 + bits_len ..][0 .. count * 16];
    const right = raw[fixed..];

    var wide_count: usize = 0;
    for (0..count) |i| wide_count += wideBit(wide_bits, i);
    if (right.len != wide_count * 16) return error.BadFont;

    const cps = try gpa.alloc(u21, count);
    errdefer gpa.free(cps);
    const entries = try gpa.alloc(bitmap.Face.Entry, count);
    errdefer gpa.free(entries);
    const data = try gpa.alloc(u8, (count + wide_count) * 16);
    errdefer gpa.free(data);

    var cp: u32 = 0;
    var offset: usize = 0;
    var r: usize = 0;
    for (0..count) |i| {
        cp += std.mem.readInt(u24, deltas[i * 3 ..][0..3], .little);
        if (cp > 0x10FFFF or (i > 0 and cp <= cps[i - 1])) return error.BadFont;
        cps[i] = @intCast(cp);
        const wide = wideBit(wide_bits, i) == 1;
        entries[i] = .{ .offset = @intCast(offset), .wide = wide };
        const l = left[i * 16 ..][0..16];
        if (wide) {
            for (0..16) |row| {
                data[offset + row * 2] = l[row];
                data[offset + row * 2 + 1] = right[r * 16 + row];
            }
            r += 1;
            offset += 32;
        } else {
            @memcpy(data[offset..][0..16], l);
            offset += 16;
        }
    }
    return .{ .width = 8, .height = 16, .cps = cps, .entries = entries, .data = data };
}

fn wideBit(bits: []const u8, i: usize) u1 {
    return @intCast((bits[i / 8] >> @intCast(i % 8)) & 1);
}

test "the embedded Unifont has Latin, CJK, and the replacement glyph" {
    var face = try unpack(std.testing.allocator);
    defer face.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 1), face.glyph('A').?.stride);
    try std.testing.expectEqual(@as(u16, 16), face.glyph(0x754C).?.width);
    try std.testing.expect(face.glyph(0xFFFD) != null);
    try std.testing.expect(face.glyph(0x1FB00) != null);
    try std.testing.expect(face.glyph(0x20000) == null);
}
