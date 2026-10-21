//! Minimal streaming PNG encoder for non-interlaced 8-bit RGBA images.

const std = @import("std");

const signature = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

const crc_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if (c & 1 != 0) 0xedb88320 ^ (c >> 1) else c >> 1;
        }
        table[i] = c;
    }
    break :blk table;
};

fn updateCrc(crc: u32, data: []const u8) u32 {
    var result = crc;
    for (data) |byte| result = crc_table[(result ^ byte) & 0xff] ^ (result >> 8);
    return result;
}

fn writeChunk(writer: *std.Io.Writer, kind: [4]u8, data: []const u8) !void {
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(&kind);
    try writer.writeAll(data);
    var crc = updateCrc(0xffffffff, &kind);
    crc = updateCrc(crc, data);
    try writer.writeInt(u32, ~crc, .big);
}

fn imageLengths(width: u32, height: u32) !struct { stride: usize, pixels: usize, raw: usize } {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const stride = std.math.mul(usize, width, 4) catch return error.InvalidDimensions;
    const pixels = std.math.mul(usize, stride, height) catch return error.InvalidDimensions;
    const scanline = std.math.add(usize, stride, 1) catch return error.InvalidDimensions;
    const raw = std.math.mul(usize, scanline, height) catch return error.InvalidDimensions;
    return .{ .stride = stride, .pixels = pixels, .raw = raw };
}

fn compressedBound(raw_len: usize) !usize {
    const blocks = std.math.divCeil(usize, raw_len, 16 * 1024) catch unreachable;
    const block_overhead = std.math.mul(usize, blocks, 8) catch return error.InvalidDimensions;
    const fixed_huffman_overhead = std.math.divCeil(usize, raw_len, 8) catch unreachable;
    const deflate = std.math.add(usize, raw_len, fixed_huffman_overhead) catch return error.InvalidDimensions;
    return std.math.add(usize, deflate, block_overhead + 6) catch return error.InvalidDimensions;
}

/// Estimate an upper bound for the encoded PNG size: the raw scanlines
/// plus generous slack for deflate's fixed-huffman worst case and block
/// overhead. Callers use this before rendering to enforce a transport
/// limit; the exact encoded size is only known after compression.
pub fn maxEncodedSize(width: u32, height: u32) !usize {
    const lengths = try imageLengths(width, height);
    const compressed = try compressedBound(lengths.raw);
    if (compressed > std.math.maxInt(u32)) return error.InvalidDimensions;
    return std.math.add(usize, compressed, signature.len + 12 + 13 + 12 + 12) catch error.InvalidDimensions;
}

/// Encode a row-major RGBA8 image as a PNG. The caller frees the result.
pub fn writeRgba8(gpa: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    const lengths = try imageLengths(width, height);
    // Keeps the @intCast of the IDAT length below safe.
    const bound = try maxEncodedSize(width, height);
    if (pixels.len != lengths.pixels) return error.BadPixelBuffer;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Terminal screens compress to a small fraction of the worst-case
    // bound, so reserve modestly and let the buffer grow if needed.
    try out.ensureTotalCapacity(@min(bound, 1 << 20));

    try out.writer.writeAll(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(&out.writer, .{ 'I', 'H', 'D', 'R' }, &ihdr);

    const idat_len_offset = out.writer.end;
    try out.writer.writeInt(u32, 0, .big);
    const kind = [4]u8{ 'I', 'D', 'A', 'T' };
    try out.writer.writeAll(&kind);
    const idat_start = out.writer.end;

    var compression_buffer: [std.compress.flate.max_window_len * 2]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &out.writer,
        &compression_buffer,
        .zlib,
        .level_3,
    );
    for (0..height) |y| {
        try compressor.writer.writeByte(0);
        const row_start = y * lengths.stride;
        try compressor.writer.writeAll(pixels[row_start..][0..lengths.stride]);
    }
    try compressor.finish();

    const idat_end = out.writer.end;
    std.mem.writeInt(u32, out.written()[idat_len_offset..][0..4], @intCast(idat_end - idat_start), .big);
    var crc = updateCrc(0xffffffff, &kind);
    crc = updateCrc(crc, out.written()[idat_start..idat_end]);
    try out.writer.writeInt(u32, ~crc, .big);
    try writeChunk(&out.writer, .{ 'I', 'E', 'N', 'D' }, &.{});

    return out.toOwnedSlice();
}

test "encode structure and decompress pixels" {
    const pixels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 128,
    };
    const encoded = try writeRgba8(std.testing.allocator, 2, 2, &pixels);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &signature, encoded[0..signature.len]);
    try std.testing.expectEqualStrings("IHDR", encoded[12..16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[16..20], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[20..24], .big));

    const idat_offset: usize = 8 + 12 + 13;
    const idat_len: usize = std.mem.readInt(u32, encoded[idat_offset..][0..4], .big);
    try std.testing.expectEqualStrings("IDAT", encoded[idat_offset + 4 .. idat_offset + 8]);
    const idat = encoded[idat_offset + 8 ..][0..idat_len];
    const idat_crc = std.mem.readInt(u32, encoded[idat_offset + 8 + idat_len ..][0..4], .big);
    var expected_crc = updateCrc(0xffffffff, "IDAT");
    expected_crc = updateCrc(expected_crc, idat);
    try std.testing.expectEqual(~expected_crc, idat_crc);
    const iend_offset = idat_offset + 12 + idat_len;
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, encoded[iend_offset..][0..4], .big));
    try std.testing.expectEqualStrings("IEND", encoded[iend_offset + 4 ..][0..4]);

    var input = std.Io.Reader.fixed(idat);
    var decompression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input, .zlib, &decompression_buffer);
    var raw: [18]u8 = undefined;
    try decompressor.reader.readSliceAll(&raw);
    try std.testing.expectError(error.EndOfStream, decompressor.reader.takeByte());
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255, 0, 255, 0, 255 }, raw[0..9]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 255, 128 }, raw[9..18]);
}

test "reject invalid dimensions and pixel lengths" {
    try std.testing.expectError(error.InvalidDimensions, writeRgba8(std.testing.allocator, 0, 1, &.{}));
    try std.testing.expectError(error.InvalidDimensions, writeRgba8(std.testing.allocator, 1, 0, &.{}));
    try std.testing.expectError(error.BadPixelBuffer, writeRgba8(std.testing.allocator, 1, 1, &.{ 0, 0, 0 }));
    try std.testing.expectError(error.InvalidDimensions, maxEncodedSize(std.math.maxInt(u32), std.math.maxInt(u32)));
}
