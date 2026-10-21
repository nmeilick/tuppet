//! Faces read through FreeType, in medium and full builds: the embedded
//! TrueType fonts and the user's TrueType, OpenType, and bitmap fonts
//! (.otb, .pcf, .bdf). Glyphs come out as 8-bit coverage, placed on the
//! baseline of their box.

const std = @import("std");
const ft = @import("freetype");
const c = ft.c;
const deflated = @import("deflated.zig");

// From ftmodapi.h and ftsynth.h, which Ghostty's header leaves out.
extern fn FT_New_Library(memory: c.FT_Memory, library: *c.FT_Library) c.FT_Error;
extern fn FT_Add_Default_Modules(library: c.FT_Library) void;
extern fn FT_Done_Library(library: c.FT_Library) c.FT_Error;
extern fn FT_GlyphSlot_Embolden(slot: c.FT_GlyphSlot) void;
extern fn FT_GlyphSlot_Oblique(slot: c.FT_GlyphSlot) void;

/// FreeType's heap is capped, so that a hostile font fails to load rather
/// than exhausting the daemon's memory.
pub const memory_limit = 256 << 20;
/// The largest cell side a face may make, in pixels.
const max_cell = 256;
/// FT_GlyphSlot_Oblique's shear, about 12 degrees, in 16.16.
const oblique_shear = 0x0366A;
// Outlines rather than a scalable font's embedded bitmaps, which could
// not be fitted or slanted.
const load_flags: c.FT_Int32 = c.FT_LOAD_DEFAULT | c.FT_LOAD_TARGET_LIGHT;
const scalable_flags: c.FT_Int32 = load_flags | c.FT_LOAD_NO_BITMAP;

/// A FreeType library whose memory comes from `gpa`, up to `memory_limit`.
pub const Library = struct {
    handle: c.FT_Library = null,
    memory: c.struct_FT_MemoryRec_,
    gpa: std.mem.Allocator,
    used: usize = 0,

    /// FreeType keeps a pointer to `l`, which must stay where it is.
    pub fn init(l: *Library, gpa: std.mem.Allocator) !void {
        l.* = .{ .memory = .{ .user = l, .alloc = ftAlloc, .free = ftFree, .realloc = ftRealloc }, .gpa = gpa };
        if (FT_New_Library(&l.memory, &l.handle) != 0) return error.OutOfMemory;
        // Not FT_Init_FreeType: it would read FREETYPE_PROPERTIES from the
        // daemon's environment.
        FT_Add_Default_Modules(l.handle);
    }

    pub fn deinit(l: *Library) void {
        _ = FT_Done_Library(l.handle);
        l.* = undefined;
    }
};

const header = 16;

fn libraryOf(memory: c.FT_Memory) *Library {
    return @ptrCast(@alignCast(memory.*.user));
}

fn ftAlloc(memory: c.FT_Memory, size: c_long) callconv(.c) ?*anyopaque {
    const l = libraryOf(memory);
    if (size <= 0 or @as(usize, @intCast(size)) > memory_limit - l.used) return null;
    const n: usize = @intCast(size);
    const block = l.gpa.alignedAlloc(u8, .@"16", header + n) catch return null;
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], n, .native);
    l.used += n;
    return block.ptr + header;
}

fn blockOf(ptr: *anyopaque) []align(16) u8 {
    const base: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(ptr)) - header);
    return base[0 .. header + std.mem.readInt(usize, base[0..@sizeOf(usize)], .native)];
}

fn ftFree(memory: c.FT_Memory, ptr: ?*anyopaque) callconv(.c) void {
    const l = libraryOf(memory);
    const block = blockOf(ptr orelse return);
    l.used -= block.len - header;
    l.gpa.free(block);
}

fn ftRealloc(memory: c.FT_Memory, _: c_long, new_size: c_long, ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const fresh: [*]u8 = @ptrCast(ftAlloc(memory, new_size) orelse return null);
    if (ptr) |old| {
        const block = blockOf(old);
        const n = @min(block.len - header, @as(usize, @intCast(new_size)));
        @memcpy(fresh[0..n], block[header..][0..n]);
        ftFree(memory, old);
    }
    return fresh;
}

/// What a face's metrics give at its current size, in whole pixels.
pub const Metrics = struct {
    width: u16,
    height: u16,
    /// From the top of the cell, for glyphs of this face.
    baseline: i32,
};

/// Glyph synthesis for a face that lacks the style.
pub const Synthetic = struct { bold: bool = false, italic: bool = false };

/// Where a glyph goes: a box of one or more cells, with the baseline at
/// `baseline` pixels from its top. `centre` centres the ink across the box,
/// for a combining mark drawn over its base: fonts place marks by their
/// own metrics, often over the glyph before.
pub const Box = struct { width: u16, height: u16, baseline: i32, size: u16, centre: bool = false };

/// An 8-bit coverage bitmap at (x, y) of its box, clipped to it.
pub const Raster = struct { x: u16, y: u16, width: u16, height: u16, data: []u8 };

pub const OpenError = ft.Error || error{ NoUnicodeMap, NoSizes };

pub const Face = struct {
    handle: c.FT_Face,
    /// The bytes FreeType reads the face from.
    data: []const u8,
    /// Whether `data` is the face's own, else embedded in the binary.
    owned: bool,
    size: u16 = 0,
    metrics: Metrics = undefined,

    /// The face `index` of `data`, which it takes over on success if
    /// `owned`.
    pub fn open(lib: *Library, data: []const u8, face_index: u16, owned: bool) OpenError!Face {
        const face = try (ft.Library{ .handle = lib.handle }).initMemoryFace(data, face_index);
        errdefer face.deinit();
        const h = face.handle;
        if (c.FT_Select_Charmap(h, c.FT_ENCODING_UNICODE) != 0) return error.NoUnicodeMap;
        if (h.*.face_flags & c.FT_FACE_FLAG_SCALABLE == 0 and h.*.num_fixed_sizes <= 0) return error.NoSizes;
        return .{ .handle = h, .data = data, .owned = owned };
    }

    pub fn deinit(f: *Face, gpa: std.mem.Allocator) void {
        _ = c.FT_Done_Face(f.handle);
        if (f.owned) gpa.free(f.data);
        f.* = undefined;
    }

    /// The glyph index of `cp`, or null when the face lacks it.
    pub fn index(f: *const Face, cp: u21) ?u32 {
        const i = c.FT_Get_Char_Index(f.handle, cp);
        return if (i == 0) null else i;
    }

    /// A face without outlines takes a bitmap size within this factor of
    /// the font size, or none.
    pub const max_size_ratio = 4;

    /// The index of the bitmap size of a face without outlines nearest to
    /// `px` pixels among those within `max_size_ratio` of it.
    fn nearestSize(f: *const Face, px: u16) ?usize {
        const sizes = f.bitmapSizes();
        const want = @as(i64, px) * 64;
        var best: ?usize = null;
        for (sizes, 0..) |s, i| {
            if (s.y_ppem * max_size_ratio < want or s.y_ppem > want * max_size_ratio) continue;
            if (best == null or @abs(s.y_ppem - want) < @abs(sizes[best.?].y_ppem - want)) best = i;
        }
        return best;
    }

    /// The smallest and largest bitmap size of a face without outlines, in
    /// pixels.
    pub fn sizeRange(f: *const Face) [2]i64 {
        var range: [2]i64 = .{ std.math.maxInt(i64), 0 };
        for (f.bitmapSizes()) |s| {
            range[0] = @min(range[0], @divFloor(s.y_ppem + 32, 64));
            range[1] = @max(range[1], @divFloor(s.y_ppem + 32, 64));
        }
        return range;
    }

    fn bitmapSizes(f: *const Face) []const c.FT_Bitmap_Size {
        return f.handle.*.available_sizes[0..@intCast(f.handle.*.num_fixed_sizes)];
    }

    /// Size the face to `px` pixels, or the nearest bitmap size of a face
    /// without outlines, and compute its metrics. A cell is the advance of
    /// 'M' (else the widest advance) wide and ascent plus descent high.
    /// error.FarSize: the face has only bitmap sizes, none within
    /// `max_size_ratio` of `px`, such as a color emoji font.
    pub fn setSize(f: *Face, px: u16) error{ BadSize, FarSize }!void {
        if (f.size == px) return;
        f.size = 0;
        const h = f.handle;
        var advance: i64 = undefined;
        var ascent: i64 = undefined;
        var descent: i64 = undefined;
        if (h.*.face_flags & c.FT_FACE_FLAG_SCALABLE != 0) {
            if (c.FT_Set_Pixel_Sizes(h, 0, px) != 0) return error.BadSize;
            const m = h.*.size.*.metrics;
            ascent = c.FT_MulFix(h.*.ascender, m.y_scale);
            descent = -c.FT_MulFix(h.*.descender, m.y_scale);
            var units: i64 = h.*.max_advance_width;
            if (f.index('M')) |m_index| {
                if (c.FT_Load_Glyph(h, m_index, c.FT_LOAD_NO_SCALE) == 0) units = h.*.glyph.*.advance.x;
            }
            advance = c.FT_MulFix(@intCast(units), m.x_scale);
        } else {
            const best = f.nearestSize(px) orelse return error.FarSize;
            if (c.FT_Select_Size(h, @intCast(best)) != 0) return error.BadSize;
            const m = h.*.size.*.metrics;
            ascent = m.ascender;
            descent = -m.descender;
            advance = m.max_advance;
            if (ascent + descent <= 0) {
                ascent = m.height;
                descent = 0;
            }
        }
        const ppem: i64 = @max(1, h.*.size.*.metrics.y_ppem);
        const width = @divFloor(advance + 63, 64);
        const height = @divFloor(ascent + descent + 63, 64);
        // Corrupt metrics must not make giant or empty cells.
        if (width < 1 or height < 1 or width > @min(2 * ppem, max_cell) or height > @min(3 * ppem, max_cell) or ascent < 0) return error.BadSize;
        f.metrics = .{
            .width = @intCast(width),
            .height = @intCast(height),
            // Any slack splits evenly above and below.
            .baseline = @intCast(@divFloor(ascent * 2 + height * 64 - (ascent + descent) + 64, 128)),
        };
        f.size = px;
    }

    /// The glyph `glyph_index` in `box`, or null when FreeType fails on it.
    /// A glyph narrower than its box, as in a wide cell, is centred. One
    /// wider than its box by more than a quarter, or taller by more than an
    /// eighth, is scaled down to fit and centred; one that sticks out of its box but fits is moved in; what
    /// still overflows is clipped.
    pub fn render(f: *Face, a: std.mem.Allocator, glyph_index: u32, synthetic: Synthetic, box: Box) !?Raster {
        f.setSize(box.size) catch return null;
        const h = f.handle;
        const flags = if (h.*.face_flags & c.FT_FACE_FLAG_SCALABLE != 0) scalable_flags else load_flags;
        if (c.FT_Load_Glyph(h, glyph_index, flags) != 0) return null;
        const slot = h.*.glyph;
        const bw: i64 = @as(i64, box.width) * 64;
        const bh: i64 = @as(i64, box.height) * 64;
        const base: i64 = @as(i64, box.baseline) * 64;
        const origin: i64 = @max(0, @divFloor(bw - slot.*.advance.x, 2)) & ~@as(i64, 63);
        switch (slot.*.format) {
            c.FT_GLYPH_FORMAT_OUTLINE => {
                const outline = &slot.*.outline;
                if (synthetic.italic) {
                    FT_GlyphSlot_Oblique(slot);
                    // Slant about the middle of the em box rather than the
                    // baseline, so the glyph stays in its cell.
                    const mid = @divFloor(c.FT_MulFix(h.*.ascender + h.*.descender, h.*.size.*.metrics.y_scale), 2);
                    c.FT_Outline_Translate(outline, -c.FT_MulFix(@intCast(mid), oblique_shear), 0);
                }
                if (synthetic.bold) FT_GlyphSlot_Embolden(slot);
                var cb: c.FT_BBox = undefined;
                c.FT_Outline_Get_CBox(outline, &cb);
                const ink_w = cb.xMax - cb.xMin;
                const ink_h = cb.yMax - cb.yMin;
                if (ink_w <= 0 or ink_h <= 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0, .data = &.{} };
                var dx: i64 = undefined;
                var dy: i64 = undefined;
                if (ink_w > bw + @max(64, @divFloor(bw, 4)) or ink_h > bh + @max(64, @divFloor(bh, 8))) {
                    const scale: i64 = @min(@divFloor(bw * 0x10000, ink_w), @divFloor(bh * 0x10000, ink_h));
                    var m: c.FT_Matrix = .{ .xx = @intCast(scale), .xy = 0, .yx = 0, .yy = @intCast(scale) };
                    c.FT_Outline_Transform(outline, &m);
                    c.FT_Outline_Get_CBox(outline, &cb);
                    dx = (@divFloor(bw - (cb.xMax - cb.xMin), 2) - cb.xMin - origin) & ~@as(i64, 63);
                    dy = (base - @divFloor(bh - (cb.yMax - cb.yMin), 2) - cb.yMax) & ~@as(i64, 63);
                } else {
                    dx = nudge(origin + cb.xMin, origin + cb.xMax, bw);
                    dy = -nudge(base - cb.yMax, base - cb.yMin, bh);
                }
                if (dx != 0 or dy != 0) c.FT_Outline_Translate(outline, @intCast(dx), @intCast(dy));
                if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) return null;
            },
            c.FT_GLYPH_FORMAT_BITMAP => if (synthetic.bold) FT_GlyphSlot_Embolden(slot),
            else => return null,
        }
        const bm = slot.*.bitmap;
        if (bm.pitch < 0) return null;
        // Bits per pixel, packed from the most significant bit.
        const depth: u4 = switch (bm.pixel_mode) {
            c.FT_PIXEL_MODE_MONO => 1,
            c.FT_PIXEL_MODE_GRAY2 => 2,
            c.FT_PIXEL_MODE_GRAY4 => 4,
            c.FT_PIXEL_MODE_GRAY => 8,
            else => return null,
        };
        const pitch: usize = @intCast(bm.pitch);
        const max_value: u32 = if (depth == 8) @max(1, @min(255, @as(u32, bm.num_grays) -| 1)) else (@as(u32, 1) << depth) - 1;
        const gx: i64 = if (box.centre) @divFloor(@as(i64, box.width) - bm.width, 2) else @divFloor(origin, 64) + slot.*.bitmap_left;
        const gy: i64 = box.baseline - @as(i64, slot.*.bitmap_top);
        const x0: i64 = @max(0, gx);
        const y0: i64 = @max(0, gy);
        const x1: i64 = @min(box.width, gx + bm.width);
        const y1: i64 = @min(box.height, gy + bm.rows);
        if (x1 <= x0 or y1 <= y0) return .{ .x = 0, .y = 0, .width = 0, .height = 0, .data = &.{} };
        const w: usize = @intCast(x1 - x0);
        const rows: usize = @intCast(y1 - y0);
        const data = try a.alloc(u8, w * rows);
        for (0..rows) |y| {
            const sy: usize = @intCast(y0 - gy + @as(i64, @intCast(y)));
            const src = bm.buffer[sy * pitch ..];
            const sx0: usize = @intCast(x0 - gx);
            for (data[y * w ..][0..w], sx0..) |*p, sx| {
                const bit = sx * depth;
                const v = (src[bit / 8] >> @intCast(8 - depth - bit % 8)) & max_value;
                p.* = @intCast(@min(255, v * 255 / max_value));
            }
        }
        return .{ .x = @intCast(x0), .y = @intCast(y0), .width = @intCast(w), .height = @intCast(rows), .data = data };
    }
};

/// How far to move ink spanning [lo, hi] into [0, size], in whole pixels
/// (all 26.6): zero when it is within half a pixel of fitting, or cannot fit.
fn nudge(lo: i64, hi: i64, size: i64) i64 {
    if (hi - lo > size) return 0;
    const d: i64 = if (lo < -32) -lo else if (hi > size + 32) size - hi else return 0;
    return (d + 32) & ~@as(i64, 63);
}

/// The styles of a family: regular, bold, italic, bold italic.
pub const Style = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,

    pub fn of(bold: bool, italic: bool) Style {
        return @fromBackingInt(@intCast(@as(u2, @intFromBool(bold)) | @as(u2, @intFromBool(italic)) << 1));
    }
};

/// A font family: a regular face and, for the embedded fonts, real bold
/// and italic faces, each unpacked on first need. Styles a family lacks
/// are synthesized from the regular face.
pub const Family = struct {
    faces: [4]?Face = @splat(null),
    /// The embedded faces not opened yet.
    blobs: [4]?[]const u8 = @splat(null),
    /// The blobs are font files to read in place, not deflated.
    stored: bool = false,

    /// A family of the user's font file, which it takes over on success.
    pub fn openFile(lib: *Library, data: []u8, face_index: u16) OpenError!Family {
        return .{ .faces = .{ try Face.open(lib, data, face_index, true), null, null, null } };
    }

    /// An embedded family of faces in `Style` order, null for the styles it
    /// lacks, deflated unless `stored`; the regular one is opened now.
    pub fn openEmbedded(lib: *Library, gpa: std.mem.Allocator, blobs: [4]?[]const u8, stored: bool) !Family {
        var f: Family = .{ .blobs = blobs, .stored = stored };
        if (try f.styled(lib, gpa, .regular) == null) return error.BadEmbeddedFont;
        return f;
    }

    pub fn deinit(f: *Family, gpa: std.mem.Allocator) void {
        for (&f.faces) |*face| if (face.*) |*x| x.deinit(gpa);
        f.* = undefined;
    }

    pub fn regular(f: *Family) *Face {
        return &f.faces[0].?;
    }

    fn styled(f: *Family, lib: *Library, gpa: std.mem.Allocator, style: Style) !?*Face {
        const i = @backingInt(style);
        if (f.faces[i] == null) {
            const blob = f.blobs[i] orelse return null;
            const data = if (f.stored) blob else deflated.inflate(gpa, blob) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadEmbeddedFont,
            };
            errdefer if (!f.stored) gpa.free(data);
            f.faces[i] = Face.open(lib, data, 0, !f.stored) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadEmbeddedFont,
            };
            f.blobs[i] = null;
        }
        return &f.faces[i].?;
    }

    /// The glyph of `cp`, which the regular face has, in `style`: from the
    /// family's face of that style, else made bold or oblique.
    pub fn render(f: *Family, lib: *Library, gpa: std.mem.Allocator, a: std.mem.Allocator, cp: u21, style: Style, box: Box) !?Raster {
        if (style != .regular) if (try f.styled(lib, gpa, style)) |face| {
            if (face.index(cp)) |i| return face.render(a, i, .{}, box);
        };
        const face = f.regular();
        const i = face.index(cp) orelse return null;
        return face.render(a, i, .{
            .bold = style == .bold or style == .bold_italic,
            .italic = style == .italic or style == .bold_italic,
        }, box);
    }
};
