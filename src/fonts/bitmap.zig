//! Bitmap fonts: GNU Unifont .hex and PC Screen Font (PSF1, PSF2,
//! optionally gzip-compressed), parsed strictly since the files may come
//! from users.

const std = @import("std");

/// A bitmap font: 1-bit glyphs `width` (narrow) or `2 * width` (wide) pixels wide and `height` tall.
pub const Face = struct {
    width: u16,
    height: u16,
    /// Ascending and unique.
    cps: []const u21,
    /// Parallel to `cps`.
    entries: []const Entry,
    /// Glyph rows, MSB first, each row ceil(glyph width / 8) bytes.
    data: []const u8,

    pub const Entry = struct { offset: u32, wide: bool };

    /// The bytes the face holds.
    pub fn bytes(f: *const Face) usize {
        return f.cps.len * @sizeOf(u21) + f.entries.len * @sizeOf(Entry) + f.data.len;
    }

    pub fn deinit(f: *Face, gpa: std.mem.Allocator) void {
        gpa.free(f.cps);
        gpa.free(f.entries);
        gpa.free(f.data);
        f.* = undefined;
    }

    /// The glyph for `cp` (binary search), or null.
    pub fn glyph(f: *const Face, cp: u21) ?Glyph {
        const i = std.sort.binarySearch(u21, f.cps, cp, orderCp) orelse return null;
        const e = f.entries[i];
        const width = if (e.wide) 2 * f.width else f.width;
        const stride = (width + 7) / 8;
        return .{
            .width = width,
            .height = f.height,
            .stride = stride,
            .bits = f.data[e.offset..][0 .. @as(usize, stride) * f.height],
        };
    }
};

pub const Glyph = struct { width: u16, height: u16, stride: u16, bits: []const u8 };

pub const Error = error{ BadFont, OutOfMemory };

/// What a failed parse says.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    message: []const u8 = "",

    fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        d.message = std.fmt.bufPrint(&d.buf, fmt, args) catch d.buf[0..];
    }
};

pub const HexOptions = struct { min: u21 = 0, max: u21 = 0x10FFFF };

pub const max_file_size = 64 << 20;
/// The largest glyphs: wide ones are twice as wide.
pub const max_width = 64;
pub const max_height = 128;

const max_cp = 0x10FFFF;

fn orderCp(target: u21, cp: u21) std.math.Order {
    return std.math.order(target, cp);
}

fn fail(diag: *Diagnostic, comptime fmt: []const u8, args: anytype) error{BadFont} {
    diag.set(fmt, args);
    return error.BadFont;
}

fn isSurrogate(cp: u32) bool {
    return cp >= 0xD800 and cp <= 0xDFFF;
}

const Builder = struct {
    seen: std.DynamicBitSetUnmanaged,
    pairs: std.ArrayList(Pair) = .empty,
    data: std.ArrayList(u8) = .empty,

    const Pair = struct {
        cp: u21,
        entry: Face.Entry,

        fn less(_: void, a: Pair, b: Pair) bool {
            return a.cp < b.cp;
        }
    };

    fn init(gpa: std.mem.Allocator) !Builder {
        return .{ .seen = try .initEmpty(gpa, max_cp + 1) };
    }

    fn deinit(b: *Builder, gpa: std.mem.Allocator) void {
        b.seen.deinit(gpa);
        b.pairs.deinit(gpa);
        b.data.deinit(gpa);
    }

    /// Marks `cp` as mapped; false when it already was.
    fn claim(b: *Builder, cp: u21) bool {
        if (b.seen.isSet(cp)) return false;
        b.seen.set(cp);
        return true;
    }

    fn put(b: *Builder, gpa: std.mem.Allocator, cp: u21, offset: usize, wide: bool) !void {
        try b.pairs.append(gpa, .{ .cp = cp, .entry = .{ .offset = @intCast(offset), .wide = wide } });
    }

    fn finish(b: *Builder, gpa: std.mem.Allocator, width: u16, height: u16) !Face {
        const pairs = b.pairs.items;
        if (!std.sort.isSorted(Pair, pairs, {}, Pair.less)) std.mem.sortUnstable(Pair, pairs, {}, Pair.less);
        const cps = try gpa.alloc(u21, pairs.len);
        errdefer gpa.free(cps);
        const entries = try gpa.alloc(Face.Entry, pairs.len);
        errdefer gpa.free(entries);
        for (pairs, cps, entries) |p, *cp, *e| {
            cp.* = p.cp;
            e.* = p.entry;
        }
        const data = try b.data.toOwnedSlice(gpa);
        return .{ .width = width, .height = height, .cps = cps, .entries = entries, .data = data };
    }
};

const hex_value = blk: {
    var t: [256]u8 = @splat(0xff);
    for ("0123456789", 0..) |c, i| t[c] = i;
    for ("abcdef", 10..) |c, i| t[c] = i;
    for ("ABCDEF", 10..) |c, i| t[c] = i;
    break :blk t;
};

/// GNU Unifont .hex: `XXXX:` + 32 hex digits (8x16) or 64 (16x16) per line.
pub fn parseHex(gpa: std.mem.Allocator, text: []const u8, options: HexOptions, diag: *Diagnostic) Error!Face {
    if (text.len > max_file_size) return fail(diag, "the font is larger than 64 MiB", .{});
    var b: Builder = try .init(gpa);
    defer b.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        if (line.len == 0) continue;
        var i: usize = 0;
        var cp: u32 = 0;
        while (i < line.len and i < 7) : (i += 1) {
            const d = hex_value[line[i]];
            if (d > 15) break;
            cp = cp << 4 | d;
        }
        if (i < 4 or i > 6) return fail(diag, "line {d}: expected a code point of 4 to 6 hex digits", .{number});
        if (i == line.len or line[i] != ':') return fail(diag, "line {d}: expected ':' after the code point", .{number});
        if (cp > max_cp) return fail(diag, "line {d}: code point U+{X:0>4} is above U+10FFFF", .{ number, cp });
        if (isSurrogate(cp)) return fail(diag, "line {d}: code point U+{X:0>4} is a surrogate", .{ number, cp });
        const digits = line[i + 1 ..];
        for (digits, i + 2..) |c, column| {
            if (hex_value[c] > 15) return fail(diag, "line {d}: column {d} is not a hex digit", .{ number, column });
        }
        if (digits.len != 32 and digits.len != 64)
            return fail(diag, "line {d}: glyph has {d} hex digits, expected 32 or 64", .{ number, digits.len });
        if (!b.claim(@intCast(cp))) return fail(diag, "line {d}: code point U+{X:0>4} is given twice", .{ number, cp });
        if (cp < options.min or cp > options.max) continue;
        const offset = b.data.items.len;
        const out = try b.data.addManyAsSlice(gpa, digits.len / 2);
        for (out, 0..) |*byte, k| byte.* = hex_value[digits[2 * k]] << 4 | hex_value[digits[2 * k + 1]];
        try b.put(gpa, @intCast(cp), offset, digits.len == 64);
    }
    if (b.pairs.items.len == 0) {
        if (options.min == 0 and options.max == max_cp) return fail(diag, "the font has no glyphs", .{});
        return fail(diag, "the font has no glyphs between U+{X:0>4} and U+{X:0>4}", .{ options.min, options.max });
    }
    return b.finish(gpa, 8, 16);
}

/// PC Screen Font, version 1 or 2, with its Unicode table if it has one.
pub fn parsePsf(gpa: std.mem.Allocator, bytes: []const u8, diag: *Diagnostic) Error!Face {
    if (bytes.len > max_file_size) return fail(diag, "the font is larger than 64 MiB", .{});
    if (std.mem.startsWith(u8, bytes, "\x36\x04")) return parsePsf1(gpa, bytes, diag);
    if (std.mem.startsWith(u8, bytes, "\x72\xb5\x4a\x86")) return parsePsf2(gpa, bytes, diag);
    return fail(diag, "not a PSF font (bad magic)", .{});
}

fn parsePsf1(gpa: std.mem.Allocator, bytes: []const u8, diag: *Diagnostic) Error!Face {
    if (bytes.len < 4) return fail(diag, "PSF1 header is truncated", .{});
    const mode = bytes[2];
    const charsize = bytes[3];
    if (charsize == 0 or charsize > max_height) return fail(diag, "PSF1 charsize {d} is outside 1..{d}", .{ charsize, max_height });
    const count: usize = if (mode & 0x01 != 0) 512 else 256;
    const glyphs_len = count * charsize;
    if (bytes.len - 4 < glyphs_len)
        return fail(diag, "PSF1 glyphs run past the end of the file (need {d} bytes, have {d})", .{ 4 + glyphs_len, bytes.len });
    var b: Builder = try .init(gpa);
    defer b.deinit(gpa);
    try b.data.appendSlice(gpa, bytes[4..][0..glyphs_len]);
    if (mode & 0x06 == 0) {
        for (0..count) |g| try identity(&b, gpa, g, charsize);
        return b.finish(gpa, 8, charsize);
    }
    var p = 4 + glyphs_len;
    for (0..count) |g| {
        var sequences = false;
        while (true) {
            if (bytes.len - p < 2) return fail(diag, "PSF1 Unicode table: glyph {d} runs past the end of the file", .{g});
            const v = std.mem.readInt(u16, bytes[p..][0..2], .little);
            p += 2;
            if (v == 0xFFFF) break;
            if (v == 0xFFFE) sequences = true;
            if (sequences) continue;
            if (isSurrogate(v)) return fail(diag, "PSF1 Unicode table: glyph {d} maps surrogate U+{X:0>4}", .{ g, v });
            if (b.claim(v)) try b.put(gpa, v, g * charsize, false);
        }
    }
    if (b.pairs.items.len == 0) return fail(diag, "PSF1 Unicode table maps no code points", .{});
    return b.finish(gpa, 8, charsize);
}

fn parsePsf2(gpa: std.mem.Allocator, bytes: []const u8, diag: *Diagnostic) Error!Face {
    if (bytes.len < 32) return fail(diag, "PSF2 header is truncated", .{});
    const field = struct {
        fn at(h: []const u8, i: usize) u32 {
            return std.mem.readInt(u32, h[4 * i ..][0..4], .little);
        }
    }.at;
    const version = field(bytes, 1);
    const headersize = field(bytes, 2);
    const flags = field(bytes, 3);
    const length = field(bytes, 4);
    const charsize = field(bytes, 5);
    const height = field(bytes, 6);
    const width = field(bytes, 7);
    if (version != 0) return fail(diag, "PSF2 version {d} is not 0", .{version});
    if (headersize < 32) return fail(diag, "PSF2 headersize {d} is below 32", .{headersize});
    if (headersize > bytes.len) return fail(diag, "PSF2 headersize {d} runs past the end of the file", .{headersize});
    if (width < 1 or width > max_width) return fail(diag, "PSF2 width {d} is not in 1..{d}", .{ width, max_width });
    if (height < 1 or height > max_height) return fail(diag, "PSF2 height {d} is not in 1..{d}", .{ height, max_height });
    const stride = (width + 7) / 8;
    if (charsize != height * stride)
        return fail(diag, "PSF2 charsize {d} does not match height {d} and width {d} (want {d})", .{ charsize, height, width, height * stride });
    if (length < 1 or length > 65536) return fail(diag, "PSF2 length {d} is not in 1..65536", .{length});
    const glyphs_len = std.math.mul(usize, length, charsize) catch
        return fail(diag, "PSF2 glyphs run past the end of the file", .{});
    const end = std.math.add(usize, headersize, glyphs_len) catch
        return fail(diag, "PSF2 glyphs run past the end of the file", .{});
    if (end > bytes.len)
        return fail(diag, "PSF2 glyphs run past the end of the file (need {d} bytes, have {d})", .{ end, bytes.len });
    var b: Builder = try .init(gpa);
    defer b.deinit(gpa);
    try b.data.appendSlice(gpa, bytes[headersize..end]);
    if (flags & 0x01 == 0) {
        for (0..length) |g| try identity(&b, gpa, g, charsize);
        return b.finish(gpa, @intCast(width), @intCast(height));
    }
    var p = end;
    for (0..length) |g| {
        while (true) {
            if (p == bytes.len) return fail(diag, "PSF2 Unicode table: glyph {d} runs past the end of the file", .{g});
            const lead = bytes[p];
            if (lead == 0xFF) {
                p += 1;
                break;
            }
            if (lead == 0xFE) {
                const stop = std.mem.indexOfScalarPos(u8, bytes, p, 0xFF) orelse
                    return fail(diag, "PSF2 Unicode table: glyph {d} runs past the end of the file", .{g});
                p = stop + 1;
                break;
            }
            const n = std.unicode.utf8ByteSequenceLength(lead) catch
                return fail(diag, "PSF2 Unicode table: glyph {d} has invalid UTF-8", .{g});
            if (bytes.len - p < n) return fail(diag, "PSF2 Unicode table: glyph {d} runs past the end of the file", .{g});
            const cp = decodeUtf8(bytes[p..][0..n]) catch |err| return switch (err) {
                error.Utf8EncodesSurrogateHalf => fail(diag, "PSF2 Unicode table: glyph {d} maps a surrogate", .{g}),
                error.Utf8CodepointTooLarge => fail(diag, "PSF2 Unicode table: glyph {d} maps a code point above U+10FFFF", .{g}),
                else => fail(diag, "PSF2 Unicode table: glyph {d} has invalid UTF-8", .{g}),
            };
            p += n;
            if (b.claim(cp)) try b.put(gpa, cp, g * charsize, false);
        }
    }
    if (b.pairs.items.len == 0) return fail(diag, "PSF2 Unicode table maps no code points", .{});
    return b.finish(gpa, @intCast(width), @intCast(height));
}

/// Maps glyph `g` to code point `g` for printable ASCII, in fonts without a
/// Unicode table; their other glyphs follow some code page, often 437.
fn identity(b: *Builder, gpa: std.mem.Allocator, g: usize, charsize: usize) !void {
    if (g < 0x20 or g > 0x7E) return;
    try b.put(gpa, @intCast(g), g * charsize, false);
}

fn decodeUtf8(s: []const u8) !u21 {
    return switch (s.len) {
        1 => s[0],
        2 => std.unicode.utf8Decode2(s[0..2].*),
        3 => std.unicode.utf8Decode3(s[0..3].*),
        4 => std.unicode.utf8Decode4(s[0..4].*),
        else => unreachable,
    };
}

/// A font file's contents by its name: .hex, .psf, or gzip-compressed .psf.gz (also recognised by the gzip magic 1f 8b).
pub fn parse(gpa: std.mem.Allocator, name: []const u8, bytes: []const u8, diag: *Diagnostic) Error!Face {
    if (bytes.len > max_file_size) return fail(diag, "the font is larger than 64 MiB", .{});
    if (std.ascii.endsWithIgnoreCase(name, ".psf.gz") or std.mem.startsWith(u8, bytes, "\x1f\x8b")) {
        const unpacked = try gunzip(gpa, bytes, max_file_size, diag);
        defer gpa.free(unpacked);
        return parsePsf(gpa, unpacked, diag);
    }
    if (std.ascii.endsWithIgnoreCase(name, ".hex")) return parseHex(gpa, bytes, .{}, diag);
    if (std.ascii.endsWithIgnoreCase(name, ".psf")) return parsePsf(gpa, bytes, diag);
    return fail(diag, "unsupported font format (want .hex, .psf, or .psf.gz)", .{});
}

/// The data of gzip members, one after another as gzip(1) reads them; any
/// other bytes after a member are refused.
pub fn gunzip(gpa: std.mem.Allocator, bytes: []const u8, limit: usize, diag: *Diagnostic) Error![]u8 {
    const flate = std.compress.flate;
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var input: std.Io.Reader = .fixed(bytes);
    while (true) {
        var decompress: flate.Decompress = .init(&input, .gzip, window);
        const start = out.items.len;
        decompress.reader.appendRemaining(gpa, &out, .limited(limit - start + 1)) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => fail(diag, "gzip: unpacks to more than 64 MiB", .{}),
            error.ReadFailed => fail(diag, "gzip: corrupt data ({s})", .{if (decompress.err) |e| @errorName(e) else "read failed"}),
        };
        if (out.items.len > limit) return fail(diag, "gzip: unpacks to more than 64 MiB", .{});
        const member = out.items[start..];
        // The decompressor reads the gzip footer but leaves checking it to us.
        const footer = decompress.container_metadata.gzip;
        if (footer.crc != std.hash.Crc32.hash(member)) return fail(diag, "gzip: corrupt data (WrongGzipChecksum)", .{});
        if (footer.count != @as(u32, @truncate(member.len))) return fail(diag, "gzip: corrupt data (WrongGzipSize)", .{});
        const rest = input.buffered();
        if (rest.len == 0) return out.toOwnedSlice(gpa);
        if (!std.mem.startsWith(u8, rest, "\x1f\x8b")) return fail(diag, "gzip: {d} bytes of trailing data after the compressed font", .{rest.len});
    }
}

fn le32(v: u32) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, v, .little);
    return out;
}

fn testPsf2Header(fields: struct {
    version: u32 = 0,
    headersize: u32 = 32,
    flags: u32 = 1,
    length: u32 = 3,
    charsize: u32 = 2,
    height: u32 = 2,
    width: u32 = 5,
}) [32]u8 {
    return "\x72\xb5\x4a\x86".* ++ le32(fields.version) ++ le32(fields.headersize) ++ le32(fields.flags) ++
        le32(fields.length) ++ le32(fields.charsize) ++ le32(fields.height) ++ le32(fields.width);
}

const test_psf2_glyphs = "\xf8\x88" ++ "\x50\x20" ++ "\x08\x10";
// Glyph 1 also maps the sequence e + U+0301, and glyph 2 maps A again.
const test_psf2_table = "A\xff" ++ "\xc3\xa9B\xfee\xcc\x81\xff" ++ "A\xe2\x82\xac\xff";
const test_psf2 = testPsf2Header(.{}) ++ test_psf2_glyphs ++ test_psf2_table;

inline fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const out = comptime blk: {
        @setEvalBranchQuota(10 * n);
        var a: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(a[i * s.len ..][0..s.len], s);
        break :blk a;
    };
    return &out;
}

fn expectBad(result: Error!Face, diag: *const Diagnostic, message: []const u8) !void {
    if (result) |face| {
        var f = face;
        f.deinit(std.testing.allocator);
        return error.TestExpectedError;
    } else |err| try std.testing.expectEqual(error.BadFont, err);
    try std.testing.expectEqualStrings(message, diag.message);
}

test "hex with a narrow and a wide glyph" {
    const text = "4e00:" ++ rep("0100", 15) ++ "fffe\r\n" ++ "\n" ++ "0041:0000000018242442427E424242420000\n";
    var diag: Diagnostic = .{};
    var face = try parseHex(std.testing.allocator, text, .{}, &diag);
    defer face.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u21, &.{ 0x41, 0x4E00 }, face.cps);
    const a = face.glyph('A').?;
    try std.testing.expectEqual(Glyph{ .width = 8, .height = 16, .stride = 1, .bits = a.bits }, a);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0x18, 0x24, 0x24, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x42, 0, 0 }, a.bits);
    const wide = face.glyph(0x4E00).?;
    try std.testing.expectEqual(@as(u16, 16), wide.width);
    try std.testing.expectEqual(@as(u16, 2), wide.stride);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00 }, wide.bits[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xfe }, wide.bits[30..32]);
    try std.testing.expect(face.glyph('B') == null);
}

test "hex range leaves glyphs out but still validates them" {
    const narrow = ":" ++ rep("00", 16) ++ "\n";
    var diag: Diagnostic = .{};
    var face = try parseHex(std.testing.allocator, "0041" ++ narrow ++ "0100" ++ narrow, .{ .min = 0x100 }, &diag);
    defer face.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u21, &.{0x100}, face.cps);
    try std.testing.expectEqual(@as(usize, 16), face.data.len);
    try expectBad(parseHex(std.testing.allocator, "0041:zz\n0100" ++ narrow, .{ .min = 0x100 }, &diag), &diag, "line 1: column 6 is not a hex digit");
}

test "bad hex lines" {
    const glyph = rep("00", 16);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "# comment", "line 1: expected a code point of 4 to 6 hex digits" },
        .{ "041:" ++ glyph, "line 1: expected a code point of 4 to 6 hex digits" },
        .{ "0000041:" ++ glyph, "line 1: expected a code point of 4 to 6 hex digits" },
        .{ "0041 " ++ glyph, "line 1: expected ':' after the code point" },
        .{ "0041", "line 1: expected ':' after the code point" },
        .{ "0041:" ++ glyph ++ " ", "line 1: column 38 is not a hex digit" },
        .{ "0041:" ++ glyph[1..], "line 1: glyph has 31 hex digits, expected 32 or 64" },
        .{ "0041:" ++ glyph ++ "00", "line 1: glyph has 34 hex digits, expected 32 or 64" },
        .{ "110000:" ++ glyph, "line 1: code point U+110000 is above U+10FFFF" },
        .{ "d800:" ++ glyph, "line 1: code point U+D800 is a surrogate" },
        .{ "0041:" ++ glyph ++ "\n\n0041:" ++ glyph, "line 3: code point U+0041 is given twice" },
        .{ "\n\r\n", "the font has no glyphs" },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try expectBad(parseHex(std.testing.allocator, case[0], .{}, &diag), &diag, case[1]);
    }
    var diag: Diagnostic = .{};
    try expectBad(parseHex(std.testing.allocator, "0041:" ++ glyph, .{ .min = 0x1F000, .max = 0x1FBFF }, &diag), &diag, "the font has no glyphs between U+1F000 and U+1FBFF");
}

test "psf2 with a Unicode table" {
    var diag: Diagnostic = .{};
    var face = try parse(std.testing.allocator, "font.psf", test_psf2, &diag);
    defer face.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 5), face.width);
    try std.testing.expectEqual(@as(u16, 2), face.height);
    try std.testing.expectEqualSlices(u21, &.{ 'A', 'B', 0xE9, 0x20AC }, face.cps);
    const a = face.glyph('A').?;
    try std.testing.expectEqual(Glyph{ .width = 5, .height = 2, .stride = 1, .bits = a.bits }, a);
    try std.testing.expectEqualSlices(u8, "\xf8\x88", a.bits);
    try std.testing.expectEqualSlices(u8, "\x50\x20", face.glyph('B').?.bits);
    try std.testing.expectEqualSlices(u8, "\x50\x20", face.glyph(0xE9).?.bits);
    try std.testing.expectEqualSlices(u8, "\x08\x10", face.glyph(0x20AC).?.bits);
    try std.testing.expect(face.glyph('e') == null);
    try std.testing.expect(!face.entries[0].wide);
}

test "psf1 with and without a Unicode table" {
    const gpa = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, &.{ 0x36, 0x04, 0x02, 2 });
    for (0..256) |g| try bytes.appendSlice(gpa, &.{ @intCast(g), 0x80 });
    const units = [_]u16{ 'A', 0xFFFF, 0xE9, 0xFFFE, 'e', 0x301, 0xFFFF } ++ @as([254]u16, @splat(0xFFFF));
    for (units) |u| try bytes.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, u)));

    var diag: Diagnostic = .{};
    var face = try parsePsf(gpa, bytes.items, &diag);
    try std.testing.expectEqualSlices(u21, &.{ 'A', 0xE9 }, face.cps);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0x80 }, face.glyph(0xE9).?.bits);
    try std.testing.expectEqual(@as(u16, 8), face.glyph('A').?.width);
    face.deinit(gpa);

    bytes.items[2] = 0;
    face = try parsePsf(gpa, bytes.items, &diag);
    defer face.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 95), face.cps.len);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0x80 }, face.glyph('A').?.bits);
}

fn testGzip(out: []u8, data: []const u8) ![]const u8 {
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(out);
    var compress = try std.compress.flate.Compress.init(&w, &window, .gzip, .default);
    try compress.writer.writeAll(data);
    try compress.finish();
    return w.buffered();
}

test "gzip-compressed psf2" {
    var buf: [256]u8 = undefined;
    const packed_psf = try testGzip(&buf, test_psf2);
    var diag: Diagnostic = .{};
    for ([_][]const u8{ "font.psf.gz", "font" }) |name| {
        var face = try parse(std.testing.allocator, name, packed_psf, &diag);
        defer face.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u21, &.{ 'A', 'B', 0xE9, 0x20AC }, face.cps);
    }
}

test "bad psf headers and tables" {
    const glyphs = test_psf2_glyphs;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "\x00\x00\x00\x00", "not a PSF font (bad magic)" },
        .{ "\x36\x04\x00", "PSF1 header is truncated" },
        .{ "\x36\x04\x00\x00", "PSF1 charsize 0 is outside 1..128" },
        .{ "\x36\x04\x01\x01" ++ rep("\x00", 256), "PSF1 glyphs run past the end of the file (need 516 bytes, have 260)" },
        .{ "\x36\x04\x02\x01" ++ rep("\x00", 256) ++ "\x00\xd8\xff\xff", "PSF1 Unicode table: glyph 0 maps surrogate U+D800" },
        .{ "\x36\x04\x02\x01" ++ rep("\x00", 256) ++ rep("\xff\xff", 255), "PSF1 Unicode table: glyph 255 runs past the end of the file" },
        .{ "\x36\x04\x02\x01" ++ rep("\x00", 256) ++ rep("\xff\xff", 256), "PSF1 Unicode table maps no code points" },
        .{ test_psf2[0..31], "PSF2 header is truncated" },
        .{ &testPsf2Header(.{ .version = 1 }), "PSF2 version 1 is not 0" },
        .{ &testPsf2Header(.{ .headersize = 16 }), "PSF2 headersize 16 is below 32" },
        .{ &testPsf2Header(.{ .headersize = 33 }), "PSF2 headersize 33 runs past the end of the file" },
        .{ &testPsf2Header(.{ .width = 0 }), "PSF2 width 0 is not in 1..64" },
        .{ &testPsf2Header(.{ .width = 65 }), "PSF2 width 65 is not in 1..64" },
        .{ &testPsf2Header(.{ .height = 0 }), "PSF2 height 0 is not in 1..128" },
        .{ &testPsf2Header(.{ .height = 129 }), "PSF2 height 129 is not in 1..128" },
        .{ &testPsf2Header(.{ .width = 9 }), "PSF2 charsize 2 does not match height 2 and width 9 (want 4)" },
        .{ &testPsf2Header(.{ .length = 0 }), "PSF2 length 0 is not in 1..65536" },
        .{ &testPsf2Header(.{ .length = 65537 }), "PSF2 length 65537 is not in 1..65536" },
        .{ &testPsf2Header(.{}) ++ glyphs[0..5], "PSF2 glyphs run past the end of the file (need 38 bytes, have 37)" },
        .{ &testPsf2Header(.{ .length = 1 }) ++ glyphs[0..2] ++ "\x80\xff", "PSF2 Unicode table: glyph 0 has invalid UTF-8" },
        .{ &testPsf2Header(.{ .length = 1 }) ++ glyphs[0..2] ++ "\xc0\x80\xff", "PSF2 Unicode table: glyph 0 has invalid UTF-8" },
        .{ &testPsf2Header(.{ .length = 1 }) ++ glyphs[0..2] ++ "\xed\xa0\x80\xff", "PSF2 Unicode table: glyph 0 maps a surrogate" },
        .{ &testPsf2Header(.{ .length = 1 }) ++ glyphs[0..2] ++ "\xf4\x90\x80\x80\xff", "PSF2 Unicode table: glyph 0 maps a code point above U+10FFFF" },
        .{ &testPsf2Header(.{ .length = 1 }) ++ glyphs[0..2] ++ "\xfeA", "PSF2 Unicode table: glyph 0 runs past the end of the file" },
        .{ &testPsf2Header(.{ .length = 1 }) ++ glyphs[0..2] ++ "\xff", "PSF2 Unicode table maps no code points" },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try expectBad(parsePsf(std.testing.allocator, case[0], &diag), &diag, case[1]);
    }
    for (0..test_psf2.len) |n| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.BadFont, parsePsf(std.testing.allocator, test_psf2[0..n], &diag));
    }
}

test "corrupt gzip" {
    var buf: [256]u8 = undefined;
    const packed_psf = try testGzip(&buf, test_psf2);
    var diag: Diagnostic = .{};
    for (0..packed_psf.len) |n| {
        try std.testing.expectError(error.BadFont, parse(std.testing.allocator, "font.psf.gz", packed_psf[0..n], &diag));
    }
    buf[packed_psf.len - 5] ^= 1;
    try expectBad(parse(std.testing.allocator, "font.psf.gz", packed_psf, &diag), &diag, "gzip: corrupt data (WrongGzipChecksum)");
    buf[packed_psf.len - 5] ^= 1;
    const unpacked = gunzip(std.testing.allocator, packed_psf, 8, &diag);
    try std.testing.expectError(error.BadFont, unpacked);
    try std.testing.expectEqualStrings("gzip: unpacks to more than 64 MiB", diag.message);
    // Members may follow each other, but nothing else may.
    var two: [512]u8 = undefined;
    const half = try testGzip(two[0..256], test_psf2[0..40]);
    const second = try testGzip(two[half.len..], test_psf2[40..]);
    var face = try parse(std.testing.allocator, "font.psf.gz", two[0 .. half.len + second.len], &diag);
    face.deinit(std.testing.allocator);
    @memcpy(buf[packed_psf.len..][0..4], "junk");
    try expectBad(parse(std.testing.allocator, "font.psf.gz", buf[0 .. packed_psf.len + 4], &diag), &diag, "gzip: 4 bytes of trailing data after the compressed font");
}

test "unsupported or oversized files" {
    var diag: Diagnostic = .{};
    try expectBad(parse(std.testing.allocator, "font.ttf", "", &diag), &diag, "unsupported font format (want .hex, .psf, or .psf.gz)");
    const huge = try std.testing.allocator.alloc(u8, max_file_size + 1);
    defer std.testing.allocator.free(huge);
    try expectBad(parse(std.testing.allocator, "font.hex", huge, &diag), &diag, "the font is larger than 64 MiB");
}
