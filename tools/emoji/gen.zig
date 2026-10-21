//! Generates tuppet's emoji atlas from Noto Color Emoji, so that `tuppet png`
//! draws color emoji without a font engine. `make emoji` downloads the pinned
//! inputs, checks them by sha256, and runs:
//!
//!     zig run -OReleaseFast tools/emoji/gen.zig -- FONT EMOJI_SEQUENCES ZWJ_SEQUENCES OUTDIR SIZE
//!
//! It reads the font's color bitmaps (CBDT/CBLC), its cmap, and the ligatures
//! of its GSUB, and keeps exactly the RGI emoji that the two Unicode sequence
//! files list, keyed by their code points with FE0E and FE0F left out. A
//! ligature whose components come in another order than the Unicode sequence
//! is matched by its set of code points. Each glyph is scaled to fit a
//! SIZE x SIZE square by area averaging, premultiplied, and centred.
//!
//! OUTDIR/atlas.bin, all little-endian:
//!
//!     "TPEMOJI1", u16 size, u16 glyphs, u16 glyphs per chunk, u16 chunks,
//!     u32 keys, u32 key bytes, u32 chunk offsets[chunks + 1],
//!     the key table (raw deflate), the chunks (raw deflate each).
//!
//! A key is a u8 (its code point count; bit 7 marks a single code point whose
//! default presentation is text), its code points as u24, and its u16 glyph.
//! Keys are sorted by code points. A chunk holds `glyphs per chunk` glyphs
//! (the last one fewer), each size * size premultiplied RGBA pixels.
//! OUTDIR/keys.txt lists the same keys for people. The output depends only on
//! the inputs and the Zig version, byte for byte.

const std = @import("std");

const per_chunk = 64;
const max_input = 64 << 20;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("emoji: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 6) fail("usage: gen FONT EMOJI_SEQUENCES ZWJ_SEQUENCES OUTDIR SIZE", .{});
    const size = std.fmt.parseInt(u16, args[5], 10) catch fail("bad size '{s}'", .{args[5]});
    if (size < 8 or size > 128) fail("size {d} is outside 8..128", .{size});
    const cwd = std.Io.Dir.cwd();
    const font = try cwd.readFileAlloc(io, args[1], a, .limited(max_input));
    const sequences = try cwd.readFileAlloc(io, args[2], a, .limited(max_input));
    const zwj = try cwd.readFileAlloc(io, args[3], a, .limited(max_input));

    var f = try Font.parse(a, font);
    var rgi: Rgi = .{};
    try rgi.read(a, sequences);
    try rgi.read(a, zwj);

    // Ligature sequences, by their code points and by their sorted code points.
    var by_seq: std.StringHashMapUnmanaged(u16) = .empty;
    var by_set: std.StringHashMapUnmanaged(Candidates) = .empty;
    for (f.ligatures.items) |lig| {
        const seq = f.sequenceOf(a, lig.components) catch continue;
        const stripped = try strip(a, seq);
        if (stripped.len < 2) continue;
        const key = try encodeKey(a, stripped);
        if (!(try by_seq.getOrPut(a, key)).found_existing) by_seq.putAssumeCapacity(key, lig.glyph);
        const set = try encodeKey(a, try sorted(a, stripped));
        const gop = try by_set.getOrPut(a, set);
        if (!gop.found_existing) gop.value_ptr.* = .{ .glyph = lig.glyph, .sequence = key };
        if (gop.value_ptr.glyph != lig.glyph) gop.value_ptr.ambiguous = true;
    }

    var keys: std.ArrayList(Key) = .empty;
    var reordered: usize = 0;
    var missing: usize = 0;
    var it = rgi.keys.iterator();
    while (it.next()) |entry| {
        const cps = entry.value_ptr.cps;
        const glyph: ?u16 = if (cps.len == 1) f.cmap.get(cps[0]) else by_seq.get(entry.key_ptr.*) orelse blk: {
            const c = by_set.get(try encodeKey(a, try sorted(a, cps))) orelse break :blk null;
            // A ligature that is another RGI sequence's glyph is not this one's.
            if (c.ambiguous or rgi.keys.contains(c.sequence)) break :blk null;
            reordered += 1;
            break :blk c.glyph;
        };
        const g = glyph orelse {
            if (missing < 10) std.debug.print("emoji: no glyph for {any}\n", .{cps});
            missing += 1;
            continue;
        };
        if (f.bitmaps.get(g) == null) {
            if (missing < 10) std.debug.print("emoji: no bitmap for {any} (glyph {d})\n", .{ cps, g });
            missing += 1;
            continue;
        }
        try keys.append(a, .{ .cps = cps, .font_glyph = g, .text = entry.value_ptr.text });
    }
    std.mem.sortUnstable(Key, keys.items, {}, Key.less);

    // Atlas slots in key order, so a base emoji and its skin tones share a chunk.
    var slots: std.AutoHashMapUnmanaged(u16, u16) = .empty;
    var order: std.ArrayList(u16) = .empty;
    for (keys.items) |*k| {
        const gop = try slots.getOrPut(a, k.font_glyph);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(order.items.len);
            try order.append(a, k.font_glyph);
        }
        k.slot = gop.value_ptr.*;
    }

    const glyph_bytes = @as(usize, size) * size * 4;
    var chunks: std.ArrayList([]u8) = .empty;
    var raw: std.ArrayList(u8) = .empty;
    for (order.items, 0..) |g, i| {
        const png = f.bitmaps.get(g).?;
        const image = decodePng(a, png) catch |err| fail("glyph {d}: {s}", .{ g, @errorName(err) });
        const start = raw.items.len;
        try raw.appendNTimes(a, 0, glyph_bytes);
        fit(image, size, raw.items[start..][0..glyph_bytes]);
        if ((i + 1) % per_chunk == 0 or i + 1 == order.items.len) {
            try chunks.append(a, try deflate(a, raw.items));
            raw.clearRetainingCapacity();
        }
    }

    var table: std.ArrayList(u8) = .empty;
    for (keys.items) |k| {
        if (k.cps.len > 16) fail("key {any} is longer than 16 code points", .{k.cps});
        const flag: u8 = if (k.text and k.cps.len == 1) 0x80 else 0;
        try table.append(a, @as(u8, @intCast(k.cps.len)) | flag);
        for (k.cps) |cp| {
            var b: [3]u8 = undefined;
            std.mem.writeInt(u24, &b, cp, .little);
            try table.appendSlice(a, &b);
        }
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, k.slot, .little);
        try table.appendSlice(a, &b);
    }
    const packed_keys = try deflate(a, table.items);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "TPEMOJI1");
    try appendInt(a, &out, u16, size);
    try appendInt(a, &out, u16, @intCast(order.items.len));
    try appendInt(a, &out, u16, per_chunk);
    try appendInt(a, &out, u16, @intCast(chunks.items.len));
    try appendInt(a, &out, u32, @intCast(keys.items.len));
    try appendInt(a, &out, u32, @intCast(packed_keys.len));
    var offset: u32 = 0;
    try appendInt(a, &out, u32, 0);
    for (chunks.items) |c| {
        offset += @intCast(c.len);
        try appendInt(a, &out, u32, offset);
    }
    try out.appendSlice(a, packed_keys);
    for (chunks.items) |c| try out.appendSlice(a, c);

    var listing: std.ArrayList(u8) = .empty;
    try listing.appendSlice(a, "# Generated by tools/emoji/gen.zig: code points (FE0E/FE0F left out); atlas glyph; \"text\" for text presentation.\n");
    for (keys.items) |k| {
        for (k.cps, 0..) |cp, i| try listing.print(a, "{s}{X:0>4}", .{ if (i == 0) "" else " ", cp });
        try listing.print(a, ";{d}{s}\n", .{ k.slot, if (k.text and k.cps.len == 1) ";text" else "" });
    }

    var dir = try cwd.createDirPathOpen(io, args[4], .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "atlas.bin", .data = out.items });
    try dir.writeFile(io, .{ .sub_path = "keys.txt", .data = listing.items });
    std.debug.print("emoji: {d} keys ({d} matched by reordering, {d} missing), {d} glyphs at {d} px, {d} chunks, {d} bytes (keys {d})\n", .{
        keys.items.len, reordered, missing, order.items.len, size, chunks.items.len, out.items.len, packed_keys.len,
    });
}

const Candidates = struct { glyph: u16, sequence: []const u8, ambiguous: bool = false };

const Key = struct {
    cps: []const u21,
    font_glyph: u16,
    text: bool,
    slot: u16 = 0,

    fn less(_: void, x: Key, y: Key) bool {
        return std.mem.order(u21, x.cps, y.cps) == .lt;
    }
};

fn appendInt(a: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(a, &b);
}

fn deflate(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(a, data.len / 2 + 64);
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&out.writer, &buf, .raw, .best);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

fn strip(a: std.mem.Allocator, cps: []const u21) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    for (cps) |cp| if (cp != 0xFE0E and cp != 0xFE0F) try out.append(a, cp);
    return out.items;
}

fn sorted(a: std.mem.Allocator, cps: []const u21) ![]u21 {
    const out = try a.dupe(u21, cps);
    std.mem.sortUnstable(u21, out, {}, std.sort.asc(u21));
    return out;
}

fn encodeKey(a: std.mem.Allocator, cps: []const u21) ![]u8 {
    const out = try a.alloc(u8, cps.len * 3);
    for (cps, 0..) |cp, i| std.mem.writeInt(u24, out[i * 3 ..][0..3], cp, .little);
    return out;
}

/// The RGI emoji of the Unicode sequence files.
const Rgi = struct {
    keys: std.StringHashMapUnmanaged(struct { cps: []const u21, text: bool }) = .empty,

    fn read(r: *Rgi, a: std.mem.Allocator, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 0;
        while (lines.next()) |line| {
            number += 1;
            const body = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
            if (body.len == 0) continue;
            var fields = std.mem.splitScalar(u8, body, ';');
            const points = std.mem.trim(u8, fields.next().?, " ");
            const kind = std.mem.trim(u8, fields.next() orelse fail("line {d}: no type field", .{number}), " ");
            if (std.mem.indexOf(u8, points, "..")) |dots| {
                const lo = parseCp(points[0..dots], number);
                const hi = parseCp(points[dots + 2 ..], number);
                if (hi < lo) fail("line {d}: bad range", .{number});
                var cp = lo;
                while (cp <= hi) : (cp += 1) try r.add(a, &.{cp}, false);
                continue;
            }
            var cps: std.ArrayList(u21) = .empty;
            var words = std.mem.tokenizeScalar(u8, points, ' ');
            while (words.next()) |w| try cps.append(a, parseCp(w, number));
            if (cps.items.len == 0) fail("line {d}: no code points", .{number});
            // A Basic_Emoji listed as "X FE0F" has text presentation by default.
            const text_default = std.mem.eql(u8, kind, "Basic_Emoji") and cps.items.len == 2 and cps.items[1] == 0xFE0F;
            try r.add(a, try strip(a, cps.items), text_default);
        }
    }

    fn add(r: *Rgi, a: std.mem.Allocator, cps: []const u21, text: bool) !void {
        const key = try encodeKey(a, cps);
        const gop = try r.keys.getOrPut(a, key);
        if (gop.found_existing) {
            gop.value_ptr.text = gop.value_ptr.text and text;
            return;
        }
        gop.value_ptr.* = .{ .cps = try a.dupe(u21, cps), .text = text };
    }
};

fn parseCp(text: []const u8, number: usize) u21 {
    const cp = std.fmt.parseInt(u21, text, 16) catch fail("line {d}: bad code point '{s}'", .{ number, text });
    if (cp > 0x10FFFF) fail("line {d}: code point out of range", .{number});
    return cp;
}

const Ligature = struct { glyph: u16, components: []const u16 };

/// The parts of an OpenType color bitmap font that the atlas needs.
const Font = struct {
    data: []const u8,
    cmap: std.AutoHashMapUnmanaged(u21, u16) = .empty,
    /// The lowest code point of each glyph in the cmap.
    reverse: std.AutoHashMapUnmanaged(u16, u21) = .empty,
    ligatures: std.ArrayList(Ligature) = .empty,
    /// Glyph id to the PNG of the largest strike.
    bitmaps: std.AutoHashMapUnmanaged(u16, []const u8) = .empty,
    resolved: std.AutoHashMapUnmanaged(u16, []const u21) = .empty,

    fn parse(a: std.mem.Allocator, data: []const u8) !Font {
        var f: Font = .{ .data = data };
        const cmap = f.table("cmap") orelse fail("the font has no cmap", .{});
        const gsub = f.table("GSUB") orelse fail("the font has no GSUB", .{});
        const cblc = f.table("CBLC") orelse fail("the font has no CBLC", .{});
        const cbdt = f.table("CBDT") orelse fail("the font has no CBDT", .{});
        try f.readCmap(a, cmap);
        try f.readGsub(a, gsub);
        try f.readStrike(a, cblc, cbdt);
        return f;
    }

    fn u16At(f: *const Font, off: usize) u16 {
        if (off + 2 > f.data.len) fail("font offset {d} is out of bounds", .{off});
        return std.mem.readInt(u16, f.data[off..][0..2], .big);
    }

    fn u32At(f: *const Font, off: usize) u32 {
        if (off + 4 > f.data.len) fail("font offset {d} is out of bounds", .{off});
        return std.mem.readInt(u32, f.data[off..][0..4], .big);
    }

    fn table(f: *const Font, tag: *const [4]u8) ?usize {
        const n = f.u16At(4);
        for (0..n) |i| {
            const rec = 12 + 16 * i;
            if (rec + 16 > f.data.len) fail("truncated table directory", .{});
            if (std.mem.eql(u8, f.data[rec..][0..4], tag)) return f.u32At(rec + 8);
        }
        return null;
    }

    fn readCmap(f: *Font, a: std.mem.Allocator, off: usize) !void {
        const n = f.u16At(off + 2);
        var best: ?usize = null;
        for (0..n) |i| {
            const sub = off + f.u32At(off + 4 + 8 * i + 4);
            if (f.u16At(sub) == 12) best = sub;
        }
        const sub = best orelse fail("the cmap has no format 12 subtable", .{});
        const groups = f.u32At(sub + 12);
        for (0..groups) |g| {
            const rec = sub + 16 + 12 * g;
            const start = f.u32At(rec);
            const end = f.u32At(rec + 4);
            const first = f.u32At(rec + 8);
            if (end < start or end > 0x10FFFF) fail("bad cmap group", .{});
            var cp = start;
            while (cp <= end) : (cp += 1) {
                const gid: u16 = @intCast(first + (cp - start));
                try f.cmap.put(a, @intCast(cp), gid);
                const gop = try f.reverse.getOrPut(a, gid);
                if (!gop.found_existing or cp < gop.value_ptr.*) gop.value_ptr.* = @intCast(cp);
            }
        }
    }

    fn coverage(f: *const Font, a: std.mem.Allocator, off: usize) ![]u16 {
        var out: std.ArrayList(u16) = .empty;
        switch (f.u16At(off)) {
            1 => for (0..f.u16At(off + 2)) |i| try out.append(a, f.u16At(off + 4 + 2 * i)),
            2 => for (0..f.u16At(off + 2)) |i| {
                const rec = off + 4 + 6 * i;
                const start = f.u16At(rec);
                const end = f.u16At(rec + 2);
                const index = f.u16At(rec + 4);
                if (end < start) fail("bad coverage range", .{});
                if (out.items.len < index + (end - start) + 1) try out.appendNTimes(a, 0, index + (end - start) + 1 - out.items.len);
                for (start..@as(usize, end) + 1) |g| out.items[index + (g - start)] = @intCast(g);
            },
            else => fail("unknown coverage format", .{}),
        }
        return out.items;
    }

    fn readGsub(f: *Font, a: std.mem.Allocator, off: usize) !void {
        const list = off + f.u16At(off + 8);
        for (0..f.u16At(list)) |i| {
            const lookup = list + f.u16At(list + 2 + 2 * i);
            const kind = f.u16At(lookup);
            for (0..f.u16At(lookup + 4)) |j| {
                var sub = lookup + f.u16At(lookup + 6 + 2 * j);
                var t = kind;
                if (t == 7) {
                    t = f.u16At(sub + 2);
                    sub += f.u32At(sub + 4);
                }
                if (t != 4) continue;
                const cov = try f.coverage(a, sub + f.u16At(sub + 2));
                const sets = f.u16At(sub + 4);
                if (sets > cov.len) fail("ligature sets exceed the coverage", .{});
                for (0..sets) |k| {
                    const set = sub + f.u16At(sub + 6 + 2 * k);
                    for (0..f.u16At(set)) |l| {
                        const lig = set + f.u16At(set + 2 + 2 * l);
                        const count = f.u16At(lig + 2);
                        if (count == 0) fail("empty ligature", .{});
                        const comps = try a.alloc(u16, count);
                        comps[0] = cov[k];
                        for (1..count) |m| comps[m] = f.u16At(lig + 4 + 2 * (m - 1));
                        try f.ligatures.append(a, .{ .glyph = f.u16At(lig), .components = comps });
                    }
                }
            }
        }
    }

    /// The code points a ligature's components stand for; components that
    /// are ligatures themselves expand to theirs.
    fn sequenceOf(f: *Font, a: std.mem.Allocator, components: []const u16) ![]const u21 {
        var out: std.ArrayList(u21) = .empty;
        for (components) |g| {
            if (f.reverse.get(g)) |cp| {
                try out.append(a, cp);
            } else if (f.resolved.get(g)) |seq| {
                try out.appendSlice(a, seq);
            } else {
                const lig = for (f.ligatures.items) |l| {
                    if (l.glyph == g) break l;
                } else return error.Unmapped;
                const seq = try f.sequenceOf(a, lig.components);
                try f.resolved.put(a, g, seq);
                try out.appendSlice(a, seq);
            }
        }
        return out.items;
    }

    fn readStrike(f: *Font, a: std.mem.Allocator, cblc: usize, cbdt: usize) !void {
        const sizes = f.u32At(cblc + 4);
        if (sizes == 0) fail("the CBLC has no strikes", .{});
        var best: usize = 0;
        var best_ppem: u8 = 0;
        for (0..sizes) |s| {
            const rec = cblc + 8 + 48 * s;
            if (rec + 48 > f.data.len) fail("truncated CBLC", .{});
            if (f.data[rec + 44] > best_ppem) {
                best_ppem = f.data[rec + 44];
                best = rec;
            }
        }
        const array = cblc + f.u32At(best);
        for (0..f.u32At(best + 8)) |i| {
            const first = f.u16At(array + 8 * i);
            const last = f.u16At(array + 8 * i + 2);
            const sub = array + f.u32At(array + 8 * i + 4);
            const index_format = f.u16At(sub);
            const image_format = f.u16At(sub + 2);
            const image_base = cbdt + f.u32At(sub + 4);
            if (last < first) fail("bad CBLC glyph range", .{});
            for (first..@as(usize, last) + 1) |g| {
                const k = g - first;
                const start: usize, const end: usize = switch (index_format) {
                    1 => .{ f.u32At(sub + 8 + 4 * k), f.u32At(sub + 8 + 4 * (k + 1)) },
                    3 => .{ f.u16At(sub + 8 + 2 * k), f.u16At(sub + 8 + 2 * (k + 1)) },
                    else => fail("CBLC index format {d} is not supported", .{index_format}),
                };
                if (end <= start) continue;
                const at = image_base + start;
                const header: usize = switch (image_format) {
                    17 => 5,
                    18 => 8,
                    else => fail("CBDT image format {d} is not supported", .{image_format}),
                };
                const len = f.u32At(at + header);
                const png_start = at + header + 4;
                if (png_start + len > image_base + end or png_start + len > f.data.len) fail("CBDT image of glyph {d} overruns", .{g});
                try f.bitmaps.put(a, @intCast(g), f.data[png_start..][0..len]);
            }
        }
    }
};

const Image = struct { width: u32, height: u32, rgba: []const u8 };

/// Decode an 8-bit, non-interlaced PNG to straight-alpha RGBA.
fn decodePng(a: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return error.NotPng;
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var color: u8 = 0;
    var depth: u8 = 8;
    var palette: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    while (pos + 12 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const kind = data[pos + 4 ..][0..4];
        if (pos + 12 + len > data.len) return error.Truncated;
        const body = data[pos + 8 ..][0..len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.BadHeader;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            depth = body[8];
            color = body[9];
            if (body[12] != 0) return error.Unsupported;
            const small = (color == 0 or color == 3) and (depth == 1 or depth == 2 or depth == 4);
            if (depth != 8 and !small) return error.Unsupported;
            if (width == 0 or height == 0 or width > 1024 or height > 1024) return error.BadHeader;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = body;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            trns = body;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(a, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
        pos += 12 + len;
    }
    if (width == 0) return error.BadHeader;
    const bpp: usize = switch (color) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Unsupported,
    };
    const stride = if (depth == 8) width * bpp else (width * depth + 7) / 8;
    const raw_len = (stride + 1) * height;
    var in = std.Io.Reader.fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var z = std.compress.flate.Decompress.init(&in, .zlib, &window);
    const raw = try a.alloc(u8, raw_len);
    try z.reader.readSliceAll(raw);

    const rows = try a.alloc(u8, stride * height);
    for (0..height) |y| {
        const filter = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const cur = rows[y * stride ..][0..stride];
        for (0..stride) |i| {
            const left: u8 = if (i >= bpp) cur[i - bpp] else 0;
            const up: u8 = if (y > 0) rows[(y - 1) * stride + i] else 0;
            const corner: u8 = if (y > 0 and i >= bpp) rows[(y - 1) * stride + i - bpp] else 0;
            cur[i] = src[i] +% switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @as(u8, @intCast((@as(u16, left) + up) / 2)),
                4 => paeth(left, up, corner),
                else => return error.BadFilter,
            };
        }
    }

    const rgba = try a.alloc(u8, @as(usize, width) * height * 4);
    for (0..@as(usize, width) * height) |p| {
        const px = rgba[p * 4 ..][0..4];
        if (depth < 8) {
            const x = p % width;
            const bit = x * depth;
            const byte = rows[(p / width) * stride + bit / 8];
            const mask = (@as(u8, 1) << @intCast(depth)) - 1;
            const v: usize = (byte >> @intCast(8 - depth - bit % 8)) & mask;
            if (color == 0) {
                const g: u8 = @intCast(v * (255 / mask));
                px.* = .{ g, g, g, 255 };
                continue;
            }
            if (v * 3 + 3 > palette.len) return error.BadPalette;
            px.* = .{ palette[v * 3], palette[v * 3 + 1], palette[v * 3 + 2], if (v < trns.len) trns[v] else 255 };
            continue;
        }
        switch (color) {
            0 => px.* = .{ rows[p], rows[p], rows[p], 255 },
            2 => px.* = .{ rows[p * 3], rows[p * 3 + 1], rows[p * 3 + 2], 255 },
            3 => {
                const i: usize = rows[p];
                if (i * 3 + 3 > palette.len) return error.BadPalette;
                px.* = .{ palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2], if (i < trns.len) trns[i] else 255 };
            },
            4 => px.* = .{ rows[p * 2], rows[p * 2], rows[p * 2], rows[p * 2 + 1] },
            6 => px.* = rows[p * 4 ..][0..4].*,
            else => unreachable,
        }
    }
    return .{ .width = width, .height = height, .rgba = rgba };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Scale `image` to fit a size x size square, keeping its aspect, by area
/// averaging in premultiplied alpha, and centre it in `out`.
fn fit(image: Image, size: u16, out: []u8) void {
    const longest = @max(image.width, image.height);
    const scale = @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(longest));
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(image.width)) * scale))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(image.height)) * scale))));
    const ox = (size - dw) / 2;
    const oy = (size - dh) / 2;
    const sx = @as(f64, @floatFromInt(image.width)) / @as(f64, @floatFromInt(dw));
    const sy = @as(f64, @floatFromInt(image.height)) / @as(f64, @floatFromInt(dh));
    for (0..dh) |y| {
        const y0 = @as(f64, @floatFromInt(y)) * sy;
        const y1 = y0 + sy;
        for (0..dw) |x| {
            const x0 = @as(f64, @floatFromInt(x)) * sx;
            const x1 = x0 + sx;
            var acc = [4]f64{ 0, 0, 0, 0 };
            var sy_i: usize = @intFromFloat(@floor(y0));
            while (@as(f64, @floatFromInt(sy_i)) < y1 and sy_i < image.height) : (sy_i += 1) {
                const fy = @min(y1, @as(f64, @floatFromInt(sy_i + 1))) - @max(y0, @as(f64, @floatFromInt(sy_i)));
                var sx_i: usize = @intFromFloat(@floor(x0));
                while (@as(f64, @floatFromInt(sx_i)) < x1 and sx_i < image.width) : (sx_i += 1) {
                    const fx = @min(x1, @as(f64, @floatFromInt(sx_i + 1))) - @max(x0, @as(f64, @floatFromInt(sx_i)));
                    const w = fx * fy;
                    const px = image.rgba[(sy_i * image.width + sx_i) * 4 ..][0..4];
                    const alpha = @as(f64, @floatFromInt(px[3])) / 255.0;
                    acc[0] += w * @as(f64, @floatFromInt(px[0])) * alpha;
                    acc[1] += w * @as(f64, @floatFromInt(px[1])) * alpha;
                    acc[2] += w * @as(f64, @floatFromInt(px[2])) * alpha;
                    acc[3] += w * @as(f64, @floatFromInt(px[3]));
                }
            }
            const area = sx * sy;
            const dst = out[((oy + y) * size + ox + x) * 4 ..][0..4];
            for (0..4) |c| dst[c] = @intFromFloat(@min(255.0, @round(acc[c] / area)));
        }
    }
}
