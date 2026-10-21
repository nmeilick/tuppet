//! Data that build.zig compressed for embedding (tools/deflate.zig,
//! tools/unifont.zig): a u32 (little-endian) with the unpacked length, then
//! raw deflate.

const std = @import("std");

/// The unpacked bytes of `blob`, owned by the caller.
pub fn inflate(gpa: std.mem.Allocator, blob: []const u8) ![]u8 {
    if (blob.len < 4) return error.BadFont;
    const raw = try gpa.alloc(u8, std.mem.readInt(u32, blob[0..4], .little));
    errdefer gpa.free(raw);
    var in = std.Io.Reader.fixed(blob[4..]);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var z = std.compress.flate.Decompress.init(&in, .raw, window);
    z.reader.readSliceAll(raw) catch return error.BadFont;
    return raw;
}
