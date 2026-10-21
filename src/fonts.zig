//! The fonts of `tuppet png`. A request names its fonts (built-in names and
//! absolute paths); `Library.resolve` turns them into a `Chain`, which picks
//! and rasterizes the glyph of every cell:
//!
//! 1. drawn glyphs (box drawing, blocks, braille, Powerline, sextants);
//! 2. color emoji, for a wide cell with emoji presentation;
//! 3. the requested faces, in order: bitmap fonts, and in medium and full
//!    builds TrueType faces read through FreeType (src/fonts/truetype.zig);
//!    a built-in TrueType font is unpacked when a lookup first reaches it;
//! 4. color emoji for whatever else the atlas has;
//! 5. Unifont, when the request did not name it;
//! 6. Unifont's U+FFFD.
//!
//! Combining marks after a base are composed with it where Unicode has a
//! precomposed form; the others come from the first of the faces in 3 and
//! 5 that has them, drawn over the base.
//!
//! The library keeps loaded faces and rasterized glyphs between requests. It
//! is not thread-safe: the daemon renders one PNG at a time.

const std = @import("std");
const build_options = @import("build_options");
pub const bitmap = @import("fonts/bitmap.zig");
const compose = @import("fonts/compose.zig");
const drawn = @import("fonts/drawn.zig");
const emoji = @import("fonts/emoji.zig");
const unifont = @import("fonts/unifont.zig");

/// Which built-in fonts this build has: lean, medium, or full.
pub const variant: []const u8 = @tagName(build_options.variant);

/// Whether this build reads TrueType fonts; lean builds compile no C.
pub const has_truetype = build_options.variant != .lean;
const truetype = if (has_truetype) @import("fonts/truetype.zig") else struct {};
/// A family of faces read through FreeType; lean builds have none.
pub const TrueType = if (has_truetype) *truetype.Family else noreturn;
const FreeType = if (has_truetype) truetype.Library else void;

pub const Face = union(enum) {
    bitmap: *const bitmap.Face,
    truetype: TrueType,
    /// A built-in TrueType font not unpacked yet: a chain unpacks it when a
    /// lookup first reaches it.
    embedded: Builtin,
};

pub const Builtin = enum {
    jetbrains,
    julia,
    nerd,
    cjk,
    unifont,

    fn isTrueType(b: Builtin) bool {
        return b != .unifont;
    }
};

/// The built-in faces of this build, in the order `default` lists them.
pub const embedded: []const Builtin = switch (build_options.variant) {
    .lean => &.{.unifont},
    .medium => &.{ .jetbrains, .unifont },
    .full => &.{ .jetbrains, .julia, .nerd, .cjk, .unifont },
};

fn isEmbedded(b: Builtin) bool {
    return std.mem.indexOfScalar(Builtin, embedded, b) != null;
}

/// The embedded faces of a built-in TrueType font, in `truetype.Style`
/// order, null for the styles it lacks; deflated unless `isStored`.
fn embeddedBlobs(comptime b: Builtin) [4]?[]const u8 {
    return switch (b) {
        .jetbrains => .{
            @embedFile("jetbrains-Regular.bin"),
            @embedFile("jetbrains-Bold.bin"),
            @embedFile("jetbrains-Italic.bin"),
            @embedFile("jetbrains-BoldItalic.bin"),
        },
        .julia => .{ @embedFile("julia-Regular.bin"), @embedFile("julia-Bold.bin"), null, null },
        .nerd => .{ @embedFile("nerd-Regular.bin"), null, null, null },
        .cjk => .{ @embedFile("cjk-Regular.otf"), null, null, null },
        .unifont => @compileError("Unifont is a bitmap font"),
    };
}

/// Whether a built-in font is embedded as is, for FreeType to read in
/// place (build.zig's `stored`).
fn isStored(b: Builtin) bool {
    return b == .cjk;
}

/// At most this many fonts per request, after `default` is expanded.
pub const max_faces = 16;
/// Font files are read up to this size.
pub const max_file_size = 64 << 20;
pub const min_font_size = 6;
pub const max_font_size = 64;
/// The size of TrueType fonts when a request names none.
pub const default_font_size = 14;
/// Cached glyphs are dropped when they exceed this many bytes.
const glyph_budget = 16 << 20;
/// Font files kept loaded, those of the current request included, and the
/// bytes they may hold together, parsed or unpacked: the least recently
/// used go first, and the fonts of one request must fit alone.
const max_cached_files = 32;
pub const max_cached_bytes = 256 << 20;

/// The cell of the bitmap renderer, Unifont's narrow glyph.
pub const bitmap_cell: Cell = .{ .width = 8, .height = 16 };

pub const Cell = struct { width: u16, height: u16 };

/// The style a cell asks for.
pub const Style = struct { bold: bool = false, italic: bool = false };

/// The fonts a request asks for.
pub const Settings = struct {
    /// Built-in names, `default`, and absolute paths; empty means `default`.
    fonts: []const []const u8 = &.{},
    /// Leave out every TrueType face, as `bitmap` in `fonts` does.
    bitmap: bool = false,
    font_size: ?u16 = null,
};

/// An entry of a font list that names a file rather than a built-in font: it
/// holds a path separator or a dot, or starts with `~`.
pub fn isPath(entry: []const u8) bool {
    return std.mem.indexOfAny(u8, entry, "/\\.") != null or std.mem.startsWith(u8, entry, "~");
}

pub const FileKind = enum { bitmap, truetype, unknown };

/// The kind of font a file is, by its name; `file.ttc#N` picks a face of a
/// collection.
pub fn fileKind(path: []const u8) FileKind {
    const name = std.fs.path.basename(path);
    for ([_][]const u8{ ".hex", ".psf", ".psf.gz" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return .bitmap;
    }
    for ([_][]const u8{ ".ttf", ".otf", ".ttc", ".otb", ".pcf", ".pcf.gz", ".bdf", ".bdf.gz" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return .truetype;
    }
    if (std.mem.lastIndexOfScalar(u8, name, '#')) |hash| {
        if (std.ascii.endsWithIgnoreCase(name[0..hash], ".ttc")) return .truetype;
    }
    return .unknown;
}

/// The built-in fonts of this build, comma-separated.
pub const embedded_names: []const u8 = blk: {
    var text: []const u8 = "";
    for (embedded, 0..) |b, i| text = text ++ (if (i == 0) "" else ", ") ++ @tagName(b);
    break :blk text;
};

/// The names a font list may use in this build, for errors.
pub fn builtinNames() []const u8 {
    return embedded_names ++ ", default, bitmap";
}

const formats = ".hex, .psf, .psf.gz, .ttf, .otf, .ttc, .otb, .pcf, or .bdf";

const over_budget = "{s}: with the other fonts of this request it would hold more than " ++ std.fmt.comptimePrint("{d}", .{max_cached_bytes >> 20}) ++ " MiB loaded";

const no_truetype = "this tuppet build (" ++ variant ++ ") has no TrueType support; use a .hex or .psf font" ++
    if (build_options.variant == .lean) ", or a medium or full build" else "";

/// What a failed resolve says.
pub const Diagnostic = struct {
    buf: [1024]u8 = undefined,
    message: []const u8 = "",
    texts: [3][max_text + "…".len]u8 = undefined,

    /// Texts longer than this, such as long paths, are cut short at a
    /// character so that the reason after them always fits.
    const max_text = 300;

    fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) error{BadFont} {
        var short = args;
        comptime var n = 0;
        inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |name| {
            if (@TypeOf(@field(args, name)) == []const u8) {
                @field(short, name) = clip(&d.texts[n], @field(args, name));
                n += 1;
            }
        }
        d.message = std.fmt.bufPrint(&d.buf, fmt, short) catch "the font error is too long to tell";
        return error.BadFont;
    }

    fn clip(out: []u8, text: []const u8) []const u8 {
        if (text.len <= max_text) return text;
        var cut: usize = max_text;
        while (cut > 0 and text[cut] & 0xC0 == 0x80) cut -= 1;
        @memcpy(out[0..cut], text[0..cut]);
        @memcpy(out[cut..][0.."…".len], "…");
        return out[0 .. cut + "…".len];
    }
};

pub const Format = enum { mono, alpha, rgba };

/// A rasterized glyph, placed at (x, y) within its box.
pub const Glyph = struct {
    format: Format,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    /// Bytes per row: (width + 7) / 8 for mono, width for alpha, 4 * width
    /// for premultiplied RGBA.
    stride: u32,
    data: []const u8,
};

const drawn_id = 0;
const emoji_id = 1;
const unifont_id = 2;
/// Built-in TrueType fonts take 3 + their `Builtin` value.
const first_builtin_id = 3;
const first_file_id = 8;

comptime {
    std.debug.assert(first_builtin_id + @typeInfo(Builtin).@"enum".field_names.len <= first_file_id);
}

const GlyphKey = struct {
    source: u32,
    code: u32,
    width: u16,
    height: u16,
    bold: bool,
    italic: bool = false,
    /// Bitmap glyphs: whether a wide glyph is squeezed into one cell, which
    /// depends on the request's cell as well as on the box.
    squeeze: bool = false,
    /// TrueType glyphs: the font size and the baseline in the box, and
    /// whether the glyph is a mark centred over its base.
    size: u16 = 0,
    baseline: i32 = 0,
    mark: bool = false,
};

const LoadedFile = struct {
    face: Face,
    id: u32,
    mtime: i96,
    size: u64,
    /// What it holds in memory, unpacked.
    bytes: u64,
    /// The request that used it last.
    generation: u64,
};

pub const Library = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    unifont: ?bitmap.Face = null,
    atlas: ?emoji.Atlas = null,
    files: std.StringHashMapUnmanaged(LoadedFile) = .empty,
    /// The bytes of the files in `files`.
    file_bytes: u64 = 0,
    next_id: u32 = first_file_id,
    /// Created on the first TrueType face, at a fixed address.
    freetype: ?*FreeType = null,
    /// The built-in TrueType fonts unpacked so far.
    families: if (has_truetype) std.EnumArray(Builtin, ?truetype.Family) else void = if (has_truetype) .initFill(null) else {},
    generation: u64 = 0,
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, Glyph) = .empty,
    glyph_arena: std.heap.ArenaAllocator,
    glyph_bytes: usize = 0,
    /// Counts the resets of `glyphs`, whose data a chain's memo points to.
    epoch: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Library {
        return .{ .gpa = gpa, .io = io, .glyph_arena = .init(gpa) };
    }

    pub fn deinit(l: *Library) void {
        if (l.unifont) |*f| f.deinit(l.gpa);
        if (l.atlas) |*a| a.deinit(l.gpa);
        var it = l.files.iterator();
        while (it.next()) |e| l.dropFile(e.key_ptr.*, e.value_ptr.*);
        l.files.deinit(l.gpa);
        if (comptime has_truetype) {
            for (&l.families.values) |*family| if (family.*) |*f| f.deinit(l.gpa);
            if (l.freetype) |ft| {
                ft.deinit();
                l.gpa.destroy(ft);
            }
        }
        l.glyphs.deinit(l.gpa);
        l.glyph_arena.deinit();
        l.* = undefined;
    }

    fn dropFile(l: *Library, path: []const u8, file: LoadedFile) void {
        l.dropFace(file.face);
        l.file_bytes -= file.bytes;
        l.gpa.free(path);
    }

    fn dropFace(l: *Library, face: Face) void {
        switch (face) {
            .bitmap => |f| {
                const owned = @constCast(f);
                owned.deinit(l.gpa);
                l.gpa.destroy(owned);
            },
            .truetype => |t| if (comptime has_truetype) {
                t.deinit(l.gpa);
                l.gpa.destroy(t);
            },
            .embedded => {},
        }
    }

    fn freeType(l: *Library) !*FreeType {
        if (l.freetype) |ft| return ft;
        const ft = try l.gpa.create(FreeType);
        errdefer l.gpa.destroy(ft);
        try ft.init(l.gpa);
        l.freetype = ft;
        return ft;
    }

    fn embeddedFamily(l: *Library, b: Builtin) !*truetype.Family {
        const slot = l.families.getPtr(b);
        if (slot.* == null) slot.* = switch (b) {
            inline else => |t| if (comptime t.isTrueType() and isEmbedded(t))
                try truetype.Family.openEmbedded(try l.freeType(), l.gpa, embeddedBlobs(t), isStored(t))
            else
                unreachable,
        };
        return &slot.*.?;
    }

    fn unifontFace(l: *Library) !*const bitmap.Face {
        if (l.unifont == null) l.unifont = try unifont.unpack(l.gpa);
        return &l.unifont.?;
    }

    fn emojiAtlas(l: *Library) !*emoji.Atlas {
        if (l.atlas == null) l.atlas = try emoji.Atlas.init(l.gpa, @embedFile("emoji_atlas"));
        return &l.atlas.?;
    }

    /// The chain for `settings`. On error.BadFont, `diag` says which font
    /// failed and why.
    pub fn resolve(l: *Library, settings: Settings, diag: *Diagnostic) !Chain {
        l.generation += 1;
        if (l.atlas) |*a| a.trim(l.gpa);
        if (settings.font_size) |size| if (size < min_font_size or size > max_font_size)
            return diag.set("font size {d} is outside {d}..{d}", .{ size, min_font_size, max_font_size });
        var chain: Chain = .{ .lib = l, .size = settings.font_size orelse default_font_size };
        const requested: []const []const u8 = if (settings.fonts.len == 0) &.{"default"} else settings.fonts;
        var count: usize = 0;
        // `bitmap` in the list is the flag.
        var bitmap_only = settings.bitmap;
        for (requested) |entry| {
            if (std.mem.eql(u8, entry, "bitmap")) bitmap_only = true else count += if (std.mem.eql(u8, entry, "default")) embedded.len else 1;
        }
        if (count > max_faces) return diag.set("{d} fonts given; at most {d}", .{ count, max_faces });
        var with_unifont = false;
        for (requested, 0..) |entry, index| {
            if (std.mem.eql(u8, entry, "default")) {
                for (embedded) |b| if (!(bitmap_only and b.isTrueType())) try chain.addBuiltin(b, &with_unifont);
            } else if (std.mem.eql(u8, entry, "bitmap")) {
                continue;
            } else if (std.meta.stringToEnum(Builtin, entry)) |b| {
                if (bitmap_only and b.isTrueType()) continue;
                if (!isEmbedded(b)) {
                    if (!has_truetype and b == .jetbrains) return diag.set("{s}: " ++ no_truetype, .{entry});
                    if (!has_truetype) return diag.set("{s}: this tuppet build (lean) has no TrueType support; a full build has {s}", .{ entry, entry });
                    return diag.set("this tuppet build (" ++ variant ++ ") does not include {s}; a full build does", .{entry});
                }
                try chain.addBuiltin(b, &with_unifont);
            } else {
                if (!std.fs.path.isAbsolute(entry)) return diag.set("font {d}, '{s}': not a built-in name ({s}) or an absolute path", .{ index + 1, entry, builtinNames() });
                const kind = fileKind(entry);
                switch (kind) {
                    .unknown => return diag.set("{s}: unsupported font format (want " ++ formats ++ ")", .{entry}),
                    .truetype => {
                        if (bitmap_only) continue;
                        if (!has_truetype) return diag.set("{s}: " ++ no_truetype, .{entry});
                    },
                    .bitmap => {},
                }
                const file = try l.loadFile(entry, kind, diag);
                try chain.add(file.face, file.id, l.files.getKey(entry).?);
            }
        }
        if (!with_unifont) chain.closing = try l.unifontFace();
        for (chain.entries[0..chain.len]) |e| switch (e.face) {
            .bitmap, .embedded => {},
            .truetype => |t| if (comptime has_truetype) t.regular().setSize(chain.size) catch |err| return switch (err) {
                error.FarSize => diag.set("{s}: its bitmap sizes, {d} to {d} pixels, are all far from the font size {d}; give a --font-size within {d} times one of them", .{ e.name, t.regular().sizeRange()[0], t.regular().sizeRange()[1], chain.size, truetype.Face.max_size_ratio }),
                error.BadSize => diag.set("{s}: unusable at {d} pixels (no size, or broken metrics)", .{ e.name, chain.size }),
            },
        };
        // The first face sets the cell.
        if (chain.len > 0) switch (chain.entries[0].face) {
            .bitmap => |f| chain.cell = .{ .width = f.width, .height = f.height },
            .truetype => |t| if (comptime has_truetype) {
                const m = t.regular().metrics;
                chain.cell = .{ .width = m.width, .height = m.height };
                chain.baseline = m.baseline;
            },
            // addBuiltin unpacks a first face at once.
            .embedded => unreachable,
        };
        return chain;
    }

    /// The face of a font file, from the cache unless the file changed.
    /// `file.ttc#N` names the face N of a collection.
    fn loadFile(l: *Library, entry: []const u8, kind: FileKind, diag: *Diagnostic) !LoadedFile {
        const io = l.io;
        const path, const face_index = splitIndex(entry) catch return diag.set("{s}: the face number after # is not a number below 65536", .{entry});
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return diag.set("{s}: cannot read it: {s}", .{ entry, statErrorText(err) });
        if (st.kind != .file) return diag.set("{s}: not a regular file", .{entry});
        if (l.files.getPtr(entry)) |hit| {
            // A chain of this request may hold the face already: keep it.
            if (hit.generation == l.generation or (hit.mtime == st.mtime.nanoseconds and hit.size == st.size)) {
                hit.generation = l.generation;
                return hit.*;
            }
        }
        if (st.size > max_file_size) return diag.set("{s}: larger than 64 MiB", .{entry});
        // Make room before reading, for at least the file's size.
        if (l.files.fetchRemove(entry)) |old| l.dropFile(old.key, old.value);
        if (!l.makeRoom(st.size)) return diag.set(over_budget, .{entry});
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| return diag.set("{s}: cannot open it: {s}", .{ entry, @errorName(err) });
        defer file.close(io);
        const opened = file.stat(io) catch |err| return diag.set("{s}: cannot read it: {s}", .{ entry, @errorName(err) });
        if (opened.kind != .file) return diag.set("{s}: not a regular file", .{entry});
        if (opened.size > max_file_size) return diag.set("{s}: larger than 64 MiB", .{entry});
        var bytes = try l.gpa.alloc(u8, @intCast(opened.size));
        var owned = false;
        // What the face holds once loaded.
        var held: u64 = 0;
        defer if (!owned) l.gpa.free(bytes);
        const n = file.readPositionalAll(io, bytes, 0) catch |err| return diag.set("{s}: cannot read it: {s}", .{ entry, @errorName(err) });
        if (n != bytes.len) return diag.set("{s}: the file changed while it was read", .{entry});
        const face: Face = switch (kind) {
            .unknown => unreachable,
            .bitmap => face: {
                var font_diag: bitmap.Diagnostic = .{};
                const f = try l.gpa.create(bitmap.Face);
                errdefer l.gpa.destroy(f);
                f.* = bitmap.parse(l.gpa, path, bytes, &font_diag) catch |err| switch (err) {
                    error.BadFont => return diag.set("{s}: {s}", .{ entry, font_diag.message }),
                    error.OutOfMemory => return error.OutOfMemory,
                };
                held = f.bytes();
                break :face .{ .bitmap = f };
            },
            .truetype => if (comptime has_truetype) face: {
                // Compressed fonts are unpacked here, within the file size
                // limit, rather than by FreeType without one.
                var font_diag: bitmap.Diagnostic = .{};
                var data = bytes;
                if (std.mem.startsWith(u8, bytes, "\x1f\x8b")) {
                    data = bitmap.gunzip(l.gpa, bytes, max_file_size, &font_diag) catch |err| switch (err) {
                        error.BadFont => return diag.set("{s}: {s}", .{ entry, font_diag.message }),
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    l.gpa.free(bytes);
                    bytes = data;
                }
                for ([_][]const u8{ "\x1f\x8b", "\x1f\x9d", "BZh" }) |magic| {
                    if (std.mem.startsWith(u8, data, magic)) return diag.set("{s}: compressed twice, or with LZW or bzip2; only gzip is supported", .{entry});
                }
                const ft = try l.freeType();
                const t = try l.gpa.create(truetype.Family);
                errdefer l.gpa.destroy(t);
                const before = ft.used;
                t.* = truetype.Family.openFile(ft, data, face_index) catch |err| return switch (err) {
                    error.NoUnicodeMap => diag.set("{s}: the font has no Unicode character map", .{entry}),
                    error.NoSizes => diag.set("{s}: the font has neither outlines nor bitmap sizes", .{entry}),
                    error.OutOfMemory => diag.set("{s}: FreeType ran out of memory reading it (limit {d} MiB)", .{ entry, truetype.memory_limit >> 20 }),
                    error.InvalidArgument => if (face_index > 0)
                        diag.set("{s}: the file has no face {d}", .{ entry, face_index })
                    else
                        diag.set("{s}: FreeType cannot read it (InvalidArgument)", .{entry}),
                    else => diag.set("{s}: FreeType cannot read it ({s})", .{ entry, @errorName(err) }),
                };
                owned = true;
                held = data.len + (ft.used -| before);
                break :face .{ .truetype = t };
            } else unreachable,
        };
        if (!l.makeRoom(held)) {
            l.dropFace(face);
            return diag.set(over_budget, .{entry});
        }
        const loaded: LoadedFile = .{ .face = face, .id = l.next_id, .mtime = opened.mtime.nanoseconds, .size = opened.size, .bytes = held, .generation = l.generation };
        l.next_id += 1;
        const key = l.gpa.dupe(u8, entry) catch |err| {
            l.dropFace(face);
            return err;
        };
        l.files.put(l.gpa, key, loaded) catch |err| {
            l.dropFace(face);
            l.gpa.free(key);
            return err;
        };
        l.file_bytes += loaded.bytes;
        return loaded;
    }

    /// Drop the least recently used files that no chain of this request
    /// holds until one more file and `need` more bytes fit; false when the
    /// files of this request leave no room.
    fn makeRoom(l: *Library, need: u64) bool {
        while (l.files.count() >= max_cached_files or l.file_bytes + need > max_cached_bytes) {
            var oldest: ?[]const u8 = null;
            var generation: u64 = l.generation;
            var it = l.files.iterator();
            while (it.next()) |e| if (e.value_ptr.generation < generation) {
                oldest = e.key_ptr.*;
                generation = e.value_ptr.generation;
            };
            const old = l.files.fetchRemove(oldest orelse return false).?;
            l.dropFile(old.key, old.value);
        }
        return true;
    }

    /// The cached glyph for `key`, rasterized by `raster` on a miss.
    fn cached(l: *Library, key: GlyphKey, raster: anytype) !?Glyph {
        if (l.glyphs.get(key)) |g| return g;
        if (l.glyph_bytes > glyph_budget) {
            l.glyphs.clearRetainingCapacity();
            _ = l.glyph_arena.reset(.retain_capacity);
            l.glyph_bytes = 0;
            l.epoch += 1;
        }
        const g = try raster.run(l.glyph_arena.allocator()) orelse return null;
        l.glyph_bytes += g.data.len + @sizeOf(Glyph);
        try l.glyphs.put(l.gpa, key, g);
        return g;
    }
};

/// The file of a font entry and the face of a collection, `file.ttc#N`.
fn splitIndex(entry: []const u8) !struct { []const u8, u16 } {
    const hash = std.mem.lastIndexOfScalar(u8, entry, '#') orelse return .{ entry, 0 };
    if (!std.ascii.endsWithIgnoreCase(entry[0..hash], ".ttc")) return .{ entry, 0 };
    return .{ entry[0..hash], try std.fmt.parseInt(u16, entry[hash + 1 ..], 10) };
}

fn statErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        else => @errorName(err),
    };
}

/// The fonts of one request.
pub const Chain = struct {
    lib: *Library,
    entries: [max_faces]Entry = undefined,
    len: usize = 0,
    /// Unifont after the emoji, when the request did not name it.
    closing: ?*const bitmap.Face = null,
    cell: Cell = bitmap_cell,
    /// The size of TrueType faces.
    size: u16 = default_font_size,
    /// The baseline of TrueType glyphs from the top of the cell, set by a
    /// TrueType first face; else each face centres its own.
    baseline: ?i32 = null,
    used: std.StaticBitSet(max_faces) = .empty,
    used_drawn: bool = false,
    used_emoji: bool = false,
    used_closing: bool = false,
    /// The latest glyphs of lone code points, by code point.
    memo: [memo_size]Memo = @splat(.{}),
    /// What `glyphs` returns.
    stack: [compose.max_rest + 1]Glyph = undefined,

    const memo_size = 512;
    const Memo = struct { cp: u21 = 0, span: u16 = 0, style: Style = .{}, epoch: u32 = 0, glyph: ?Glyph = null };

    pub const Entry = struct {
        face: Face,
        id: u32,
        /// A built-in name or the file's path.
        name: []const u8,
    };

    fn add(c: *Chain, face: Face, id: u32, name: []const u8) !void {
        for (c.entries[0..c.len]) |e| if (e.id == id) return;
        c.entries[c.len] = .{ .face = face, .id = id, .name = name };
        c.len += 1;
    }

    fn addBuiltin(c: *Chain, b: Builtin, with_unifont: *bool) !void {
        switch (b) {
            .unifont => {
                with_unifont.* = true;
                try c.add(.{ .bitmap = try c.lib.unifontFace() }, unifont_id, "unifont");
            },
            else => if (comptime has_truetype) {
                const id = first_builtin_id + @as(u32, @backingInt(b));
                // The first face sets the cell, so it is unpacked now.
                const face: Face = if (c.len == 0) .{ .truetype = try c.lib.embeddedFamily(b) } else .{ .embedded = b };
                try c.add(face, id, @tagName(b));
            } else unreachable,
        }
    }

    /// Unpack the built-in font of `e` and size it for this chain.
    fn unpack(c: *Chain, e: *Entry) !void {
        if (comptime !has_truetype) unreachable;
        const t = try c.lib.embeddedFamily(e.face.embedded);
        t.regular().setSize(c.size) catch return error.BadEmbeddedFont;
        e.face = .{ .truetype = t };
    }

    /// `ttf` when a TrueType face took part, setting the cell or drawing
    /// something, else `bitmap`.
    pub fn renderer(c: *const Chain) []const u8 {
        for (c.entries[0..c.len], 0..) |e, i| if (e.face == .truetype and (i == 0 or c.used.isSet(i))) return "ttf";
        return "bitmap";
    }

    /// The names of the faces that drew something, copied into `gpa`: the
    /// library may drop a file's face once the next request comes.
    pub fn usedFaces(c: *const Chain, gpa: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (c.used_drawn) try out.append(gpa, "drawn");
        for (c.entries[0..c.len], 0..) |e, i| if (c.used.isSet(i)) try out.append(gpa, try gpa.dupe(u8, e.name));
        if (c.used_emoji) try out.append(gpa, "emoji");
        if (c.used_closing) try out.append(gpa, "unifont");
        return out.toOwnedSlice(gpa);
    }

    /// The glyphs to draw, in order, for a cell's code points (the base,
    /// then the rest of its grapheme) in a box `span` cells wide: the base,
    /// precomposed with its combining marks where Unicode and a font have
    /// that form, then the other marks over it. Valid until the next call.
    pub fn glyphs(c: *Chain, cps: []const u21, span: u16, style: Style) ![]const Glyph {
        var buf: [compose.max_rest]u21 = undefined;
        var cl: compose.Cluster = if (cps.len > 1) compose.cluster(cps, &buf, true) else .{ .base = cps[0], .marks = &.{} };
        // A precomposed form no font has would draw as U+FFFD.
        if (cl.base != cps[0] and !try c.covers(cl.base)) cl = compose.cluster(cps, &buf, false);
        if (cl.base == cps[0] and cl.marks.len == 0) {
            const g = try c.glyph(cps, span, style) orelse return &.{};
            c.stack[0] = g;
            return c.stack[0..1];
        }
        const box: Cell = .{ .width = c.cell.width * span, .height = c.cell.height };
        // An emoji sequence the atlas has, such as a keycap, stays whole.
        if (span >= 2 and cps[1] != 0xFE0E) if (try c.emojiGlyph(cps, true, box)) |g| {
            c.stack[0] = g;
            return c.stack[0..1];
        };
        // A rasterization may drop the glyphs cached before it, once: the
        // glyphs of one cell are far below the budget.
        while (true) {
            const epoch = c.lib.epoch;
            var n: usize = 0;
            if (try c.glyph(&.{cl.base}, span, style)) |g| {
                c.stack[0] = g;
                n = 1;
            }
            for (cl.marks) |m| if (try c.markGlyph(m, box, style)) |g| {
                c.stack[n] = g;
                n += 1;
            };
            if (c.lib.epoch == epoch) return c.stack[0..n];
        }
    }

    /// The glyph for a cell's code points (the base, then the rest of its
    /// grapheme) in a box `span` cells wide, or null when nothing shows.
    pub fn glyph(c: *Chain, cps: []const u21, span: u16, style: Style) !?Glyph {
        const cp = cps[0];
        if (cp == 0 or cp == ' ') return null;
        if (cps.len > 1) return c.find(cps, span, style);
        const m = &c.memo[cp % memo_size];
        if (m.cp == cp and m.span == span and std.meta.eql(m.style, style) and m.epoch == c.lib.epoch) return m.glyph;
        const g = try c.find(cps, span, style);
        m.* = .{ .cp = cp, .span = span, .style = style, .epoch = c.lib.epoch, .glyph = g };
        return g;
    }

    fn find(c: *Chain, cps: []const u21, span: u16, style: Style) !?Glyph {
        const bold = style.bold;
        const cp = cps[0];
        const box: Cell = .{ .width = c.cell.width * span, .height = c.cell.height };
        if (drawn.covers(cp)) {
            c.used_drawn = true;
            return c.lib.cached(.{ .source = drawn_id, .code = cp, .width = box.width, .height = box.height, .bold = false }, DrawnRaster{ .cp = cp, .box = box });
        }
        const text = cps.len > 1 and cps[1] == 0xFE0E;
        if (span >= 2 and !text) if (try c.emojiGlyph(cps, true, box)) |g| return g;
        if (try c.faceGlyph(cp, box, style, false)) |g| return g;
        if (!text) if (try c.emojiGlyph(cps, true, box)) |g| return g;
        if (try c.closingGlyph(cp, box, bold)) |g| return g;
        const last = c.closing orelse &c.lib.unifont.?;
        const replacement = last.glyph(0xFFFD) orelse return null;
        if (c.closing != null) {
            c.used_closing = true;
        } else for (c.entries[0..c.len], 0..) |e, i| {
            if (e.id == unifont_id) c.used.set(i);
        }
        return c.bitmapGlyph(unifont_id, 0xFFFD, replacement, last.width, box, bold);
    }

    /// Whether a requested face or the closing Unifont has `cp`.
    fn covers(c: *Chain, cp: u21) !bool {
        for (c.entries[0..c.len]) |*e| {
            if (e.face == .embedded) try c.unpack(e);
            switch (e.face) {
                .bitmap => |f| if (f.glyph(cp) != null) return true,
                .truetype => |t| if (comptime has_truetype) if (t.regular().index(cp) != null) return true,
                .embedded => unreachable,
            }
        }
        const last = c.closing orelse return false;
        return last.glyph(cp) != null;
    }

    /// A combining mark from the first face that has it; nothing when none
    /// has.
    fn markGlyph(c: *Chain, cp: u21, box: Cell, style: Style) !?Glyph {
        return try c.faceGlyph(cp, box, style, true) orelse c.closingGlyph(cp, box, style.bold);
    }

    /// The glyph of `cp` from the first requested face that has it.
    fn faceGlyph(c: *Chain, cp: u21, box: Cell, style: Style, mark: bool) !?Glyph {
        for (c.entries[0..c.len], 0..) |*e, i| {
            if (e.face == .embedded) try c.unpack(e);
            switch (e.face) {
                .bitmap => |f| if (f.glyph(cp)) |g| {
                    c.used.set(i);
                    return c.bitmapGlyph(e.id, cp, g, f.width, box, style.bold);
                },
                .truetype => |t| if (comptime has_truetype) if (t.regular().index(cp) != null) {
                    if (try c.trueTypeGlyph(e.id, t, cp, box, style, mark)) |g| {
                        c.used.set(i);
                        return g;
                    }
                },
                .embedded => unreachable,
            }
        }
        return null;
    }

    /// The glyph of `cp` from Unifont after the emoji, when the request did
    /// not name it.
    fn closingGlyph(c: *Chain, cp: u21, box: Cell, bold: bool) !?Glyph {
        const last = c.closing orelse return null;
        const g = last.glyph(cp) orelse return null;
        c.used_closing = true;
        return c.bitmapGlyph(unifont_id, cp, g, last.width, box, bold);
    }

    fn bitmapGlyph(c: *Chain, id: u32, cp: u21, g: bitmap.Glyph, narrow: u16, box: Cell, bold: bool) !?Glyph {
        const squeeze = g.width > narrow and g.width > box.width and box.width == c.cell.width;
        return c.lib.cached(.{ .source = id, .code = cp, .width = box.width, .height = box.height, .bold = bold, .squeeze = squeeze }, BitmapRaster{
            .glyph = g,
            .squeeze = squeeze,
            .box = box,
            .bold = bold,
        });
    }

    fn trueTypeGlyph(c: *Chain, id: u32, t: TrueType, cp: u21, box: Cell, style: Style, mark: bool) !?Glyph {
        const m = t.regular().metrics;
        const baseline = c.baseline orelse m.baseline + @divFloor(@as(i32, c.cell.height) - m.height, 2);
        return c.lib.cached(.{
            .source = id,
            .code = cp,
            .width = box.width,
            .height = box.height,
            .bold = style.bold,
            .italic = style.italic,
            .size = c.size,
            .baseline = baseline,
            .mark = mark,
        }, TrueTypeRaster{
            .lib = c.lib,
            .family = t,
            .cp = cp,
            .style = truetype.Style.of(style.bold, style.italic),
            .box = .{ .width = box.width, .height = box.height, .baseline = baseline, .size = c.size, .centre = mark },
        });
    }

    fn emojiGlyph(c: *Chain, cps: []const u21, presentation: bool, box: Cell) !?Glyph {
        const atlas = try c.lib.emojiAtlas();
        const slot = atlas.lookup(cps, presentation) orelse return null;
        c.used_emoji = true;
        return c.lib.cached(.{ .source = emoji_id, .code = slot, .width = box.width, .height = box.height, .bold = false }, EmojiRaster{ .lib = c.lib, .atlas = atlas, .slot = slot, .box = box });
    }
};

const TrueTypeRaster = struct {
    lib: *Library,
    family: TrueType,
    cp: u21,
    style: truetype.Style,
    box: truetype.Box,

    fn run(r: TrueTypeRaster, a: std.mem.Allocator) !?Glyph {
        const g = try r.family.render(r.lib.freetype.?, r.lib.gpa, a, r.cp, r.style, r.box) orelse return null;
        return .{ .format = .alpha, .x = g.x, .y = g.y, .width = g.width, .height = g.height, .stride = g.width, .data = g.data };
    }
};

const DrawnRaster = struct {
    cp: u21,
    box: Cell,

    fn run(r: DrawnRaster, a: std.mem.Allocator) !?Glyph {
        const data = try a.alloc(u8, @as(usize, r.box.width) * r.box.height);
        @memset(data, 0);
        if (!drawn.draw(r.cp, r.box.width, r.box.height, data)) return null;
        return .{ .format = .alpha, .x = 0, .y = 0, .width = r.box.width, .height = r.box.height, .stride = r.box.width, .data = data };
    }
};

fn bit(bits: []const u8, stride: usize, x: usize, y: usize) bool {
    return bits[y * stride + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
}

/// A bitmap glyph fitted to its box: a wide glyph in a narrow box is
/// squeezed by joining column pairs; a glyph that fits twice or more is
/// scaled up by a whole factor and centred. One larger than the box keeps
/// its pixels when its ink fits, centred as far as the ink allows, and is
/// otherwise scaled down to the coverage of its pixels, centred. Bold
/// smears each row one pixel to the right. There is no synthetic italic:
/// slanting rows of a 16-pixel bitmap only makes it ragged.
const BitmapRaster = struct {
    glyph: bitmap.Glyph,
    /// A wide glyph in a one-cell box.
    squeeze: bool,
    box: Cell,
    bold: bool,

    fn run(r: BitmapRaster, a: std.mem.Allocator) !?Glyph {
        const g = r.glyph;
        const squeeze = r.squeeze;
        const w: usize = if (squeeze) g.width / 2 else g.width;
        const h: usize = g.height;
        const bw: usize = r.box.width;
        const bh: usize = r.box.height;
        // The glyph after squeezing and bold, 0 or 255 per pixel.
        var src_buf: [2 * bitmap.max_width * bitmap.max_height]u8 = undefined;
        const src = src_buf[0 .. w * h];
        for (0..h) |y| for (0..w) |x| {
            var on = if (squeeze) bit(g.bits, g.stride, 2 * x, y) or bit(g.bits, g.stride, 2 * x + 1, y) else bit(g.bits, g.stride, x, y);
            if (r.bold and x > 0 and !on) on = if (squeeze) bit(g.bits, g.stride, 2 * x - 1, y) else bit(g.bits, g.stride, x - 1, y);
            src[y * w + x] = if (on) 255 else 0;
        };
        const k = @min(bw / w, bh / h);
        if (k >= 1) return try monoGlyph(a, src, w, .{ .x = 0, .y = 0, .width = w, .height = h }, k, (bw - w * k) / 2, (bh - h * k) / 2);
        var ink: Rect = .{ .x = w, .y = h, .width = 0, .height = 0 };
        var x1: usize = 0;
        var y1: usize = 0;
        for (0..h) |y| for (0..w) |x| if (src[y * w + x] != 0) {
            ink.x = @min(ink.x, x);
            ink.y = @min(ink.y, y);
            x1 = @max(x1, x + 1);
            y1 = @max(y1, y + 1);
        };
        if (x1 == 0) return .{ .format = .mono, .x = 0, .y = 0, .width = 0, .height = 0, .stride = 0, .data = &.{} };
        ink.width = x1 - ink.x;
        ink.height = y1 - ink.y;
        if (ink.width <= bw and ink.height <= bh) return try monoGlyph(a, src, w, ink, 1, place(ink.x, ink.width, w, bw), place(ink.y, ink.height, h, bh));
        const fw: usize, const fh: usize = if (w * bh > h * bw) .{ bw, @max(1, h * bw / w) } else .{ @max(1, w * bh / h), bh };
        const data = try a.alloc(u8, fw * fh);
        areaAverage(1, src, w, h, data, fw, fh);
        return .{
            .format = .alpha,
            .x = @intCast((bw - fw) / 2),
            .y = @intCast((bh - fh) / 2),
            .width = @intCast(fw),
            .height = @intCast(fh),
            .stride = @intCast(fw),
            .data = data,
        };
    }
};

const Rect = struct { x: usize, y: usize, width: usize, height: usize };

/// Where ink `len` long, starting at `lo` of a glyph `size` long, starts in
/// a box `room` long that it fits: as with the glyph centred, moved as
/// little as keeps the ink inside.
fn place(lo: usize, len: usize, size: usize, room: usize) usize {
    const centred = @divFloor(@as(isize, @intCast(room)) - @as(isize, @intCast(size)), 2) + @as(isize, @intCast(lo));
    return @intCast(std.math.clamp(centred, 0, @as(isize, @intCast(room - len))));
}

/// A mono glyph of `part` of `src`, whose rows are `stride` pixels long,
/// scaled up `k` times, at (x, y) of its box.
fn monoGlyph(a: std.mem.Allocator, src: []const u8, stride: usize, part: Rect, k: usize, x: usize, y: usize) !Glyph {
    const fw = part.width * k;
    const fh = part.height * k;
    const row = (fw + 7) / 8;
    const data = try a.alloc(u8, row * fh);
    @memset(data, 0);
    for (0..fh) |dy| for (0..fw) |dx| {
        if (src[(part.y + dy / k) * stride + part.x + dx / k] != 0) data[dy * row + dx / 8] |= @as(u8, 0x80) >> @intCast(dx % 8);
    };
    return .{ .format = .mono, .x = @intCast(x), .y = @intCast(y), .width = @intCast(fw), .height = @intCast(fh), .stride = @intCast(row), .data = data };
}

/// An emoji scaled to the largest square that fits its box, by area
/// averaging when smaller than the atlas and bilinearly when larger.
const EmojiRaster = struct {
    lib: *Library,
    atlas: *emoji.Atlas,
    slot: u16,
    box: Cell,

    fn run(r: EmojiRaster, a: std.mem.Allocator) !?Glyph {
        const px = try r.atlas.pixels(r.lib.gpa, r.slot);
        const s: usize = r.atlas.size;
        const d: usize = @max(1, @min(r.box.width, r.box.height));
        const data = try a.alloc(u8, d * d * 4);
        if (d == s) {
            @memcpy(data, px);
        } else if (d < s) {
            areaAverage(4, px, s, s, data, d, d);
        } else {
            bilinear(px, s, data, d);
        }
        return .{
            .format = .rgba,
            .x = @intCast((r.box.width - d) / 2),
            .y = @intCast((r.box.height - d) / 2),
            .width = @intCast(d),
            .height = @intCast(d),
            .stride = @intCast(d * 4),
            .data = data,
        };
    }
};

/// Scale `src`, `sw` by `sh` pixels of `n` channels, down to `dw` by `dh`
/// in `dst`, each pixel the average of the source area it covers.
fn areaAverage(comptime n: usize, src: []const u8, sw: usize, sh: usize, dst: []u8, dw: usize, dh: usize) void {
    // Destination pixel edges in units of 1 / (sw * dw) and 1 / (sh * dh)
    // of the source; source pixel edges are multiples of dw and dh.
    for (0..dh) |y| {
        const y0 = y * sh;
        const y1 = y0 + sh;
        for (0..dw) |x| {
            const x0 = x * sw;
            const x1 = x0 + sw;
            var acc: [n]u64 = @splat(0);
            var sy = y0 / dh;
            while (sy * dh < y1) : (sy += 1) {
                const wy = @min(y1, (sy + 1) * dh) - @max(y0, sy * dh);
                var sx = x0 / dw;
                while (sx * dw < x1) : (sx += 1) {
                    const wx = @min(x1, (sx + 1) * dw) - @max(x0, sx * dw);
                    const p = src[(sy * sw + sx) * n ..][0..n];
                    for (0..n) |ch| acc[ch] += @as(u64, p[ch]) * wx * wy;
                }
            }
            const area = @as(u64, sw) * sh;
            for (0..n) |ch| dst[(y * dw + x) * n + ch] = @intCast((acc[ch] + area / 2) / area);
        }
    }
}

fn bilinear(src: []const u8, s: usize, dst: []u8, d: usize) void {
    for (0..d) |y| {
        // Sample centres, in units of 1 / (2 * d) source pixels.
        const fy = @max(0, @as(i64, @intCast((2 * y + 1) * s)) - @as(i64, @intCast(d)));
        const y0: usize = @min(s - 1, @as(usize, @intCast(@divTrunc(fy, @as(i64, @intCast(2 * d))))));
        const y1 = @min(s - 1, y0 + 1);
        const ty: u64 = @intCast(@mod(fy, @as(i64, @intCast(2 * d))));
        for (0..d) |x| {
            const fx = @max(0, @as(i64, @intCast((2 * x + 1) * s)) - @as(i64, @intCast(d)));
            const x0: usize = @min(s - 1, @as(usize, @intCast(@divTrunc(fx, @as(i64, @intCast(2 * d))))));
            const x1 = @min(s - 1, x0 + 1);
            const tx: u64 = @intCast(@mod(fx, @as(i64, @intCast(2 * d))));
            const dd: u64 = 2 * d;
            for (0..4) |ch| {
                const p00: u64 = src[(y0 * s + x0) * 4 + ch];
                const p01: u64 = src[(y0 * s + x1) * 4 + ch];
                const p10: u64 = src[(y1 * s + x0) * 4 + ch];
                const p11: u64 = src[(y1 * s + x1) * 4 + ch];
                const top = p00 * (dd - tx) + p01 * tx;
                const bottom = p10 * (dd - tx) + p11 * tx;
                dst[(y * d + x) * 4 + ch] = @intCast((top * (dd - ty) + bottom * ty + dd * dd / 2) / (dd * dd));
            }
        }
    }
}

test "lookup order: drawn glyphs, wide emoji, the requested faces, emoji, Unifont, U+FFFD" {
    const gpa = std.testing.allocator;
    var lib: Library = .init(gpa, std.testing.io);
    defer lib.deinit();
    var diag: Diagnostic = .{};
    var chain = try lib.resolve(.{ .fonts = &.{"unifont"} }, &diag);

    // U+2500 is in Unifont too, but drawn glyphs come first.
    const line = (try chain.glyph(&.{0x2500}, 1, .{})).?;
    try std.testing.expectEqual(Format.alpha, line.format);
    // A wide cell with emoji presentation takes the color emoji ...
    try std.testing.expectEqual(Format.rgba, (try chain.glyph(&.{0x1F600}, 2, .{})).?.format);
    // ... a narrow one Unifont's glyph, as does text presentation.
    try std.testing.expectEqual(Format.mono, (try chain.glyph(&.{0x1F600}, 1, .{})).?.format);
    try std.testing.expectEqual(Format.mono, (try chain.glyph(&.{ 0x1F600, 0xFE0E }, 2, .{})).?.format);
    // A text-default emoji stays text unless FE0F follows it.
    try std.testing.expectEqual(Format.mono, (try chain.glyph(&.{0x2764}, 2, .{})).?.format);
    try std.testing.expectEqual(Format.rgba, (try chain.glyph(&.{ 0x2764, 0xFE0F }, 2, .{})).?.format);
    // Unifont lacks plane 2; U+FFFD stands in.
    const missing = (try chain.glyph(&.{0x20000}, 2, .{})).?;
    const replacement = (try chain.glyph(&.{0xFFFD}, 2, .{})).?;
    try std.testing.expectEqualSlices(u8, replacement.data, missing.data);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const faces = try chain.usedFaces(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), faces.len);
    try std.testing.expectEqualStrings("drawn", faces[0]);
    try std.testing.expectEqualStrings("unifont", faces[1]);
    try std.testing.expectEqualStrings("emoji", faces[2]);

    // A user font goes first; Unifont closes the chain after the emoji.
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.testing.io;
    try dir.dir.writeFile(io, .{ .sub_path = "a.hex", .data = "0041:FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\n" });
    const path = try dir.dir.realPathFileAlloc(io, "a.hex", gpa);
    defer gpa.free(path);
    chain = try lib.resolve(.{ .fonts = &.{path} }, &diag);
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xff)), (try chain.glyph(&.{'A'}, 1, .{})).?.data);
    _ = try chain.glyph(&.{'B'}, 1, .{});
    const used = try chain.usedFaces(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), used.len);
    try std.testing.expectEqualStrings(path, used[0]);
    try std.testing.expectEqualStrings("unifont", used[1]);

    try std.testing.expectError(error.BadFont, lib.resolve(.{ .fonts = &.{"/x/y.ttf"} }, &diag));
    try std.testing.expectEqualStrings(if (has_truetype) "/x/y.ttf: cannot read it: no such file" else "/x/y.ttf: " ++ no_truetype, diag.message);
    // `bitmap` leaves out TrueType files and faces, and their cells.
    chain = try lib.resolve(.{ .fonts = &.{ "/x/y.ttf", "default" }, .bitmap = true }, &diag);
    try std.testing.expectEqualStrings("bitmap", chain.renderer());
    try std.testing.expectEqual(bitmap_cell, chain.cell);
    chain = try lib.resolve(.{ .fonts = &.{ "/x/y.ttf", "bitmap", "default" } }, &diag);
    try std.testing.expectEqual(bitmap_cell, chain.cell);
}

test "bitmap glyphs larger than their box keep their ink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A 16x16 glyph whose only ink is row 7 does not fit 12x13: scaled to
    // coverage, the line still shows.
    var line: [32]u8 = @splat(0);
    line[14] = 0xff;
    line[15] = 0xff;
    const scaled = (try (BitmapRaster{ .glyph = .{ .width = 16, .height = 16, .stride = 2, .bits = &line }, .squeeze = false, .box = .{ .width = 12, .height = 13 }, .bold = false }).run(arena.allocator())).?;
    try std.testing.expectEqual(Format.alpha, scaled.format);
    try std.testing.expectEqual(@as(u16, 12), scaled.width);
    try std.testing.expect(std.mem.max(u8, scaled.data) >= 128);
    // Ink in rows 2 to 13 fits 14 rows: kept pixel for pixel.
    var tall: [16]u8 = @splat(0);
    @memset(tall[2..14], 0x81);
    const kept = (try (BitmapRaster{ .glyph = .{ .width = 8, .height = 16, .stride = 1, .bits = &tall }, .squeeze = false, .box = .{ .width = 8, .height = 14 }, .bold = false }).run(arena.allocator())).?;
    try std.testing.expectEqual(Format.mono, kept.format);
    try std.testing.expectEqual(@as(u16, 12), kept.height);
    try std.testing.expectEqual(@as(u16, 1), kept.y);
    for (kept.data) |b| try std.testing.expectEqual(@as(u8, 0x81), b);
}

test "a font error keeps its reason after a long path" {
    const gpa = std.testing.allocator;
    var lib: Library = .init(gpa, std.testing.io);
    defer lib.deinit();
    var diag: Diagnostic = .{};
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    for (0..10) |_| {
        try path.append(gpa, '/');
        for (0..100) |_| try path.appendSlice(gpa, "é");
    }
    try path.appendSlice(gpa, ".hex");
    try std.testing.expectError(error.BadFont, lib.resolve(.{ .fonts = &.{path.items} }, &diag));
    try std.testing.expect(std.unicode.utf8ValidateSlice(diag.message));
    try std.testing.expect(std.mem.startsWith(u8, diag.message, "/é"));
    try std.testing.expect(std.mem.endsWith(u8, diag.message, "…: cannot read it: no such file"));
}

test "the font cache counts what a face holds, not its file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var lib: Library = .init(gpa, io);
    defer lib.deinit();
    var diag: Diagnostic = .{};
    // 512 blank PSF1 glyphs pack into a few bytes of gzip.
    const psf = "\x36\x04\x01\x10" ++ @as([512 * 16]u8, @splat(0));
    var packed_buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&packed_buf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&w, &window, .gzip, .default);
    try compress.writer.writeAll(psf);
    try compress.finish();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(io, .{ .sub_path = "f.psf.gz", .data = w.buffered() });
    const path = try dir.dir.realPathFileAlloc(io, "f.psf.gz", gpa);
    defer gpa.free(path);
    _ = try lib.resolve(.{ .fonts = &.{path} }, &diag);
    const held = lib.files.get(path).?.face.bitmap.bytes();
    try std.testing.expect(held > w.buffered().len);
    try std.testing.expectEqual(@as(u64, held), lib.file_bytes);
}

test "TrueType faces: the cell, real and synthetic styles, corrupt files" {
    if (!has_truetype) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var lib: Library = .init(gpa, std.testing.io);
    defer lib.deinit();
    var diag: Diagnostic = .{};
    // A TrueType face takes part when it sets the cell or draws.
    var chain = try lib.resolve(.{ .fonts = &.{ "unifont", "jetbrains" } }, &diag);
    _ = try chain.glyph(&.{'A'}, 1, .{});
    try std.testing.expectEqualStrings("bitmap", chain.renderer());
    chain = try lib.resolve(.{}, &diag);
    try std.testing.expectEqualStrings("ttf", chain.renderer());
    try std.testing.expectEqual(Cell{ .width = 9, .height = 19 }, chain.cell);
    const regular = (try chain.glyph(&.{'A'}, 1, .{})).?;
    try std.testing.expectEqual(Format.alpha, regular.format);
    const bold = (try chain.glyph(&.{'A'}, 1, .{ .bold = true })).?;
    try std.testing.expect(!std.mem.eql(u8, regular.data, bold.data));

    // A user font gets synthetic styles; broken ones fail with their name
    // or draw what FreeType can make of them, but never crash.
    const raw = try @import("fonts/deflated.zig").inflate(gpa, @embedFile("jetbrains-Regular.bin"));
    defer gpa.free(raw);
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.testing.io;
    var prng = std.Random.DefaultPrng.init(1);
    for (0..3) |round| {
        const data = try gpa.dupe(u8, if (round == 1) raw[0 .. raw.len / 3] else raw);
        defer gpa.free(data);
        if (round == 2) for (data[raw.len / 2 ..]) |*b| {
            if (prng.random().uintLessThan(u8, 16) == 0) b.* = prng.random().int(u8);
        };
        const name = try std.fmt.allocPrint(gpa, "f{d}.ttf", .{round});
        defer gpa.free(name);
        try dir.dir.writeFile(io, .{ .sub_path = name, .data = data });
        const path = try dir.dir.realPathFileAlloc(io, name, gpa);
        defer gpa.free(path);
        chain = lib.resolve(.{ .fonts = &.{path}, .font_size = 20 }, &diag) catch |err| {
            try std.testing.expectEqual(error.BadFont, err);
            try std.testing.expect(std.mem.startsWith(u8, diag.message, path));
            continue;
        };
        for ([_]Style{ .{}, .{ .bold = true }, .{ .italic = true }, .{ .bold = true, .italic = true } }) |style| {
            for ("Ag|") |ch| _ = try chain.glyph(&.{ch}, 1, style);
            _ = try chain.glyph(&.{0x754C}, 2, style);
        }
        if (round == 0) {
            try std.testing.expectEqual(Cell{ .width = 12, .height = 27 }, chain.cell);
            const italic = (try chain.glyph(&.{'I'}, 1, .{ .italic = true })).?;
            const upright = (try chain.glyph(&.{'I'}, 1, .{})).?;
            try std.testing.expect(!std.mem.eql(u8, italic.data, upright.data));
        }
    }
}

test "full builds unpack a built-in font when a lookup reaches it; medium ones name it" {
    if (!has_truetype) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var lib: Library = .init(gpa, std.testing.io);
    defer lib.deinit();
    var diag: Diagnostic = .{};
    if (build_options.variant != .full) {
        try std.testing.expectError(error.BadFont, lib.resolve(.{ .fonts = &.{"cjk"} }, &diag));
        try std.testing.expectEqualStrings("this tuppet build (medium) does not include cjk; a full build does", diag.message);
        return;
    }
    var chain = try lib.resolve(.{}, &diag);
    _ = try chain.glyph(&.{'A'}, 1, .{});
    try std.testing.expect(lib.families.get(.cjk) == null);
    // A wide ideograph spans both cells of its box.
    const wide = (try chain.glyph(&.{0x754C}, 2, .{})).?;
    try std.testing.expect(wide.format == .alpha and wide.width > chain.cell.width and wide.x + wide.width <= 2 * chain.cell.width);
    _ = try chain.glyph(&.{0xF015}, 1, .{});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const faces = try chain.usedFaces(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), faces.len);
    try std.testing.expectEqualStrings("jetbrains", faces[0]);
    try std.testing.expectEqualStrings("nerd", faces[1]);
    try std.testing.expectEqualStrings("cjk", faces[2]);
}
