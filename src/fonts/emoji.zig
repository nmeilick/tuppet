//! Color emoji from the atlas that tools/emoji/gen.zig extracts from Noto
//! Color Emoji (format described there). The key table is read on first
//! use; the glyph pixels are inflated a chunk at a time, when a glyph of
//! the chunk is first drawn.

const std = @import("std");

pub const Atlas = struct {
    bytes: []const u8,
    /// Side of the square glyphs, in pixels.
    size: u16,
    glyphs: u16,
    per_chunk: u16,
    /// Chunk i spans chunk_offsets[i]..chunk_offsets[i + 1] of chunk_data.
    chunk_offsets: []const u8,
    chunk_data: []const u8,
    /// Key i's code points are key_cps[key_starts[i]..key_starts[i + 1]].
    key_starts: []u32,
    key_cps: []u21,
    key_glyphs: []u16,
    /// Keys of one code point whose default presentation is text.
    key_text: std.DynamicBitSetUnmanaged,
    chunks: []?[]u8,

    /// Read the header and the key table of `bytes`, which outlive the atlas.
    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) !Atlas {
        if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "TPEMOJI1")) return error.BadAtlas;
        const size = std.mem.readInt(u16, bytes[8..10], .little);
        const glyphs = std.mem.readInt(u16, bytes[10..12], .little);
        const per_chunk = std.mem.readInt(u16, bytes[12..14], .little);
        const chunk_count = std.mem.readInt(u16, bytes[14..16], .little);
        const key_count = std.mem.readInt(u32, bytes[16..20], .little);
        const keys_len = std.mem.readInt(u32, bytes[20..24], .little);
        const table_end = 24 + (@as(usize, chunk_count) + 1) * 4;
        if (size == 0 or per_chunk == 0 or chunk_count != (@as(usize, glyphs) + per_chunk - 1) / per_chunk) return error.BadAtlas;
        if (key_count > max_keys) return error.BadAtlas;
        if (bytes.len < table_end + keys_len) return error.BadAtlas;
        const offsets = bytes[24..table_end];
        const chunk_data = bytes[table_end + keys_len ..];
        var prev: u32 = 0;
        for (0..@as(usize, chunk_count) + 1) |i| {
            const o = std.mem.readInt(u32, offsets[i * 4 ..][0..4], .little);
            if (o < prev or o > chunk_data.len) return error.BadAtlas;
            prev = o;
        }

        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var in = std.Io.Reader.fixed(bytes[table_end..][0..keys_len]);
        var z = std.compress.flate.Decompress.init(&in, .raw, window);
        var table: std.Io.Writer.Allocating = .init(gpa);
        defer table.deinit();
        _ = z.reader.streamRemaining(&table.writer) catch return error.BadAtlas;
        if (table.written().len > key_count * (1 + max_sequence * 3 + 2)) return error.BadAtlas;
        const t = table.written();

        var a: Atlas = .{
            .bytes = bytes,
            .size = size,
            .glyphs = glyphs,
            .per_chunk = per_chunk,
            .chunk_offsets = offsets,
            .chunk_data = chunk_data,
            .key_starts = &.{},
            .key_cps = &.{},
            .key_glyphs = &.{},
            .key_text = .{},
            .chunks = &.{},
        };
        errdefer a.deinit(gpa);
        a.key_starts = try gpa.alloc(u32, key_count + 1);
        a.key_text = try .initEmpty(gpa, key_count);
        a.key_glyphs = try gpa.alloc(u16, key_count);
        a.chunks = try gpa.alloc(?[]u8, chunk_count);
        @memset(a.chunks, null);
        var cps: std.ArrayList(u21) = .empty;
        errdefer cps.deinit(gpa);
        var pos: usize = 0;
        for (0..key_count) |k| {
            if (pos >= t.len) return error.BadAtlas;
            const n = t[pos] & 0x7f;
            if (t[pos] & 0x80 != 0) a.key_text.set(k);
            pos += 1;
            if (n == 0 or n > max_sequence or pos + @as(usize, n) * 3 + 2 > t.len) return error.BadAtlas;
            a.key_starts[k] = @intCast(cps.items.len);
            for (0..n) |_| {
                const cp = std.mem.readInt(u24, t[pos..][0..3], .little);
                if (cp > 0x10FFFF) return error.BadAtlas;
                try cps.append(gpa, @intCast(cp));
                pos += 3;
            }
            a.key_glyphs[k] = std.mem.readInt(u16, t[pos..][0..2], .little);
            if (a.key_glyphs[k] >= glyphs) return error.BadAtlas;
            pos += 2;
        }
        a.key_starts[key_count] = @intCast(cps.items.len);
        a.key_cps = try cps.toOwnedSlice(gpa);
        return a;
    }

    pub fn deinit(a: *Atlas, gpa: std.mem.Allocator) void {
        for (a.chunks) |c| if (c) |px| gpa.free(px);
        gpa.free(a.chunks);
        gpa.free(a.key_starts);
        gpa.free(a.key_cps);
        gpa.free(a.key_glyphs);
        a.key_text.deinit(gpa);
        a.* = undefined;
    }

    fn key(a: *const Atlas, k: usize) []const u21 {
        return a.key_cps[a.key_starts[k]..a.key_starts[k + 1]];
    }

    fn find(a: *const Atlas, cps: []const u21) ?usize {
        var lo: usize = 0;
        var hi: usize = a.key_glyphs.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            switch (std.mem.order(u21, a.key(mid), cps)) {
                .eq => return mid,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    /// The longest prefix of `cps`, of two code points or more, that is a key.
    fn longest(a: *const Atlas, cps: []const u21) ?u16 {
        var n = cps.len;
        while (n >= 2) : (n -= 1) if (a.find(cps[0..n])) |k| return a.key_glyphs[k];
        return null;
    }

    /// The glyph for a grapheme's code points, ignoring FE0E and FE0F: the
    /// whole sequence, then the same without skin tones, then the longest
    /// prefix that matches, with tones and without, then the first code
    /// point alone. With `presentation`, a lone code point
    /// whose default presentation is text only matches when FE0F follows it.
    pub fn lookup(a: *const Atlas, cps: []const u21, presentation: bool) ?u16 {
        if (cps.len == 0) return null;
        var buf: [max_sequence]u21 = undefined;
        var n: usize = 0;
        for (cps) |cp| {
            if (cp == 0xFE0E or cp == 0xFE0F) continue;
            if (n == buf.len) break;
            buf[n] = cp;
            n += 1;
        }
        if (n == 0) return null;
        var toneless: [max_sequence]u21 = undefined;
        var m: usize = 0;
        for (buf[0..n]) |cp| {
            if (isTone(cp)) continue;
            toneless[m] = cp;
            m += 1;
        }
        if (n >= 2) if (a.find(buf[0..n])) |k| return a.key_glyphs[k];
        if (m >= 2 and m < n) if (a.find(toneless[0..m])) |k| return a.key_glyphs[k];
        if (a.longest(buf[0..n])) |g| return g;
        if (m < n) if (a.longest(toneless[0..m])) |g| return g;
        const k = a.find(buf[0..1]) orelse return null;
        if (presentation and a.key_text.isSet(k) and !(cps.len > 1 and cps[1] == 0xFE0F)) return null;
        return a.key_glyphs[k];
    }

    /// Drop the inflated chunks when they hold more than the budget; glyphs
    /// taken from them earlier must not be used after.
    pub fn trim(a: *Atlas, gpa: std.mem.Allocator) void {
        var total: usize = 0;
        for (a.chunks) |c| if (c) |px| {
            total += px.len;
        };
        if (total <= chunk_budget) return;
        for (a.chunks) |*c| if (c.*) |px| {
            gpa.free(px);
            c.* = null;
        };
    }

    /// The premultiplied RGBA pixels of a glyph, size * size of them.
    pub fn pixels(a: *Atlas, gpa: std.mem.Allocator, glyph: u16) ![]const u8 {
        const glyph_bytes = @as(usize, a.size) * a.size * 4;
        const c = glyph / a.per_chunk;
        const chunk = a.chunks[c] orelse blk: {
            const start = std.mem.readInt(u32, a.chunk_offsets[@as(usize, c) * 4 ..][0..4], .little);
            const end = std.mem.readInt(u32, a.chunk_offsets[(@as(usize, c) + 1) * 4 ..][0..4], .little);
            const count = @min(a.per_chunk, a.glyphs - c * a.per_chunk);
            const px = try gpa.alloc(u8, glyph_bytes * count);
            errdefer gpa.free(px);
            const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(window);
            var in = std.Io.Reader.fixed(a.chunk_data[start..end]);
            var z = std.compress.flate.Decompress.init(&in, .raw, window);
            z.reader.readSliceAll(px) catch return error.BadAtlas;
            a.chunks[c] = px;
            break :blk px;
        };
        return chunk[(glyph % a.per_chunk) * glyph_bytes ..][0..glyph_bytes];
    }
};

/// No RGI sequence is longer.
const max_sequence = 16;
const max_keys = 1 << 16;

/// Inflated chunks beyond this many bytes are dropped by `trim`.
const chunk_budget = 8 << 20;

fn isTone(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

test "emoji lookup: longest match, skin-tone fallback, FE0F ignored" {
    const gpa = std.testing.allocator;
    var atlas = try Atlas.init(gpa, @embedFile("emoji_atlas"));
    defer atlas.deinit(gpa);
    const thumbs = atlas.lookup(&.{0x1F44D}, true).?;
    const thumbs_medium = atlas.lookup(&.{ 0x1F44D, 0x1F3FD }, true).?;
    try std.testing.expect(thumbs != thumbs_medium);
    const family = atlas.lookup(&.{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 }, true).?;
    try std.testing.expect(family != atlas.lookup(&.{0x1F468}, true).?);
    // A sequence that is no key falls back to its longest matching prefix.
    try std.testing.expectEqual(family, atlas.lookup(&.{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F680 }, true).?);
    // A toned sequence that has no toned form uses the plain one, before a
    // shorter prefix with the tone.
    const family_kids = atlas.lookup(&.{ 0x1F9D1, 0x200D, 0x1F9D1, 0x200D, 0x1F9D2 }, true).?;
    try std.testing.expectEqual(family_kids, atlas.lookup(&.{ 0x1F9D1, 0x1F3FB, 0x200D, 0x1F9D1, 0x200D, 0x1F9D2 }, true).?);
    const rainbow = atlas.lookup(&.{ 0x1F3F3, 0xFE0F, 0x200D, 0x1F308 }, true).?;
    try std.testing.expectEqual(rainbow, atlas.lookup(&.{ 0x1F3F3, 0x200D, 0x1F308 }, true).?);
    try std.testing.expectEqual(rainbow, atlas.lookup(&.{ 0x1F3F3, 0x1F3FB, 0x200D, 0x1F308 }, true).?);
    // Text presentation by default: only with FE0F, or when asked anyway.
    try std.testing.expectEqual(@as(?u16, null), atlas.lookup(&.{0x2764}, true));
    try std.testing.expect(atlas.lookup(&.{ 0x2764, 0xFE0F }, true) != null);
    try std.testing.expect(atlas.lookup(&.{0x2764}, false) != null);
    try std.testing.expectEqual(@as(?u16, null), atlas.lookup(&.{'A'}, false));
    const px = try atlas.pixels(gpa, thumbs);
    try std.testing.expectEqual(@as(usize, atlas.size) * atlas.size * 4, px.len);
    try std.testing.expect(std.mem.indexOfNone(u8, px, &.{0}) != null);
}
