//! Software renderer: draws the terminal's active screen into an RGBA
//! buffer with the glyphs of a font chain (src/fonts.zig), then encodes it
//! as PNG.

const std = @import("std");
const vt = @import("vt");
const fonts = @import("fonts.zig");
const png = @import("png.zig");

const Rgba = extern struct { r: u8, g: u8, b: u8, a: u8 };

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []Rgba,
};

fn imageDimensions(cols: u32, rows: u32, cell: fonts.Cell) !struct { width: u32, height: u32 } {
    if (cols == 0 or rows == 0) return error.InvalidDimensions;
    const width = std.math.mul(u32, cols, cell.width) catch return error.InvalidDimensions;
    const height = std.math.mul(u32, rows, cell.height) catch return error.InvalidDimensions;
    return .{ .width = width, .height = height };
}

/// Return a conservative PNG size bound for a terminal grid.
pub fn maxPngSize(cols: u32, rows: u32, cell: fonts.Cell) !usize {
    const dimensions = try imageDimensions(cols, rows, cell);
    return png.maxEncodedSize(dimensions.width, dimensions.height);
}

/// Render the active screen as a PNG. The caller frees the result.
pub fn renderPng(gpa: std.mem.Allocator, t: *const vt.Terminal, chain: *fonts.Chain) ![]u8 {
    const image = try renderImage(gpa, t, chain);
    defer gpa.free(image.pixels);
    return encodePng(gpa, image);
}

/// Draw the active screen; only this step needs the terminal. The caller
/// frees `pixels`.
pub fn renderImage(gpa: std.mem.Allocator, t: *const vt.Terminal, chain: *fonts.Chain) !Image {
    return renderRgba(gpa, t, @intCast(t.cols), @intCast(t.rows), chain);
}

pub fn encodePng(gpa: std.mem.Allocator, image: Image) ![]u8 {
    return png.writeRgba8(gpa, image.width, image.height, std.mem.sliceAsBytes(image.pixels));
}

/// The pixels of an image and its size, for drawing into.
const Canvas = struct {
    px: []Rgba,
    width: usize,
    height: usize,

    fn rect(c: Canvas, x0: usize, y0: usize, w: usize, h: usize, color: Rgba) void {
        if (x0 >= c.width) return;
        const span = @min(w, c.width - x0);
        for (y0..@min(y0 + h, c.height)) |y| @memset(c.px[y * c.width + x0 ..][0..span], color);
    }

    fn dot(c: Canvas, x: usize, y: usize, color: Rgba) void {
        if (x < c.width and y < c.height) c.px[y * c.width + x] = color;
    }

    /// Composite a glyph whose box starts at (x0, y0): mono and alpha glyphs
    /// in `fg`, color ones over what is there.
    fn glyph(c: Canvas, x0: usize, y0: usize, g: fonts.Glyph, fg: Rgba) void {
        const gx = x0 + g.x;
        const gy = y0 + g.y;
        if (gx >= c.width or gy >= c.height) return;
        const w = @min(g.width, c.width - gx);
        const h = @min(g.height, c.height - gy);
        for (0..h) |dy| {
            const row = g.data[dy * g.stride ..];
            const out = c.px[(gy + dy) * c.width + gx ..][0..w];
            switch (g.format) {
                .mono => for (0..(w + 7) / 8) |byte| {
                    const bits = row[byte];
                    if (bits == 0) continue;
                    for (0..@min(8, w - byte * 8)) |b| {
                        if (bits & (@as(u8, 0x80) >> @intCast(b)) != 0) out[byte * 8 + b] = fg;
                    }
                },
                .alpha => for (out, row[0..w]) |*p, a| {
                    if (a == 255) p.* = fg else if (a != 0) p.* = blend(p.*, fg, a);
                },
                .rgba => for (out, 0..) |*p, dx| {
                    const s = row[dx * 4 ..][0..4];
                    if (s[3] == 0) continue;
                    if (s[3] == 255) {
                        p.* = .{ .r = s[0], .g = s[1], .b = s[2], .a = 255 };
                        continue;
                    }
                    const inv: u16 = 255 - s[3];
                    p.* = .{
                        .r = @intCast(@min(255, @as(u16, s[0]) + (@as(u16, p.r) * inv + 127) / 255)),
                        .g = @intCast(@min(255, @as(u16, s[1]) + (@as(u16, p.g) * inv + 127) / 255)),
                        .b = @intCast(@min(255, @as(u16, s[2]) + (@as(u16, p.b) * inv + 127) / 255)),
                        .a = 255,
                    };
                },
            }
        }
    }
};

fn blend(under: Rgba, over: Rgba, a: u8) Rgba {
    const inv: u16 = 255 - @as(u16, a);
    return .{
        .r = @intCast((@as(u16, over.r) * a + @as(u16, under.r) * inv + 127) / 255),
        .g = @intCast((@as(u16, over.g) * a + @as(u16, under.g) * inv + 127) / 255),
        .b = @intCast((@as(u16, over.b) * a + @as(u16, under.b) * inv + 127) / 255),
        .a = 255,
    };
}

fn renderRgba(gpa: std.mem.Allocator, t: *const vt.Terminal, cols: u32, rows: u32, chain: *fonts.Chain) !Image {
    const cell = chain.cell;
    const dimensions = try imageDimensions(cols, rows, cell);
    const cols_usize: usize = cols;
    const rows_usize: usize = rows;
    const width: usize = dimensions.width;
    const height: usize = dimensions.height;
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidDimensions;
    const cw: usize = cell.width;
    const ch: usize = cell.height;
    // Decoration lines grow with the cell: one pixel at 16 pixels high.
    const line: usize = @max(1, ch / 16);

    // Terminal default colors (ghostty ships them unset; Session.start
    // installs the default theme).
    const fg = resolveDefault(t.colors.foreground.get(), 0xdc, 0xd7, 0xba);
    const bg = resolveDefault(t.colors.background.get(), 0x1f, 0x1f, 0x28);

    const px = try gpa.alloc(Rgba, pixel_count);
    errdefer gpa.free(px);
    @memset(px, bg);
    const canvas: Canvas = .{ .px = px, .width = width, .height = height };

    // Reverse video (DECSCNM) inverts every cell.
    const reverse_screen = t.modes.get(.reverse_colors);
    const pages = &t.screens.active.pages;
    // The active area is the visible screen; scrollback lies above it.
    var it = pages.cellIterator(.right_down, .{ .active = .{} }, null);

    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(gpa);
    var row: usize = 0;
    var seen = false;
    while (it.next()) |pin| {
        if (seen and pin.x == 0) row += 1;
        seen = true;
        if (row >= rows_usize) break;

        const cells = pin.cells(.all);
        const c = &cells[@intCast(pin.x)];
        const col: usize = @intCast(pin.x);

        // Wide characters paint their spacer tail as part of the head cell.
        if (c.wide == .spacer_tail) continue;

        const st = pin.style(c);

        var fg_rgb = styleColor(st.fg_color, fg, t, st.flags.bold);
        var bg_rgb = cellBackground(c, st.bg_color, bg, t);
        if (st.flags.inverse != reverse_screen) {
            const tmp = fg_rgb;
            fg_rgb = bg_rgb;
            bg_rgb = tmp;
        }
        if (st.flags.faint) fg_rgb = midpoint(fg_rgb, bg_rgb);

        const span_cells: usize = @min(c.gridWidth(), cols_usize - col);
        const span_width = span_cells * cw;
        const x0 = col * cw;
        const y0 = row * ch;
        canvas.rect(x0, y0, span_width, ch, bg_rgb);

        if (st.flags.invisible) continue;

        const cp = c.codepoint();
        if (cp != 0) {
            cps.clearRetainingCapacity();
            try cps.append(gpa, cp);
            if (c.hasGrapheme()) if (pin.node.page().lookupGrapheme(c)) |rest| try cps.appendSlice(gpa, rest);
            for (try chain.glyphs(cps.items, @intCast(span_cells), .{ .bold = st.flags.bold, .italic = st.flags.italic })) |g| canvas.glyph(x0, y0, g, fg_rgb);
        }
        const line_rgb = styleColor(st.underline_color, fg_rgb, t, false);
        paintUnderline(canvas, x0, y0, ch, span_width, line, st.flags.underline, line_rgb);
        if (st.flags.strikethrough) canvas.rect(x0, y0 + ch / 2, span_width, line, fg_rgb);
        if (st.flags.overline) canvas.rect(x0, y0 + @min(line, ch -| line), span_width, line, fg_rgb);
    }

    return .{ .width = dimensions.width, .height = dimensions.height, .pixels = px };
}

fn midpoint(a: Rgba, b: Rgba) Rgba {
    return .{
        .r = @intCast((@as(u16, a.r) + b.r) / 2),
        .g = @intCast((@as(u16, a.g) + b.g) / 2),
        .b = @intCast((@as(u16, a.b) + b.b) / 2),
        .a = 255,
    };
}

fn resolveDefault(c: ?vt.color.RGB, dr: u8, dg: u8, db: u8) Rgba {
    if (c) |rgb| return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 };
    return .{ .r = dr, .g = dg, .b = db, .a = 255 };
}

/// Resolve a cell style color (none/palette/rgb) to RGBA. Bold palette
/// colors use the bright variants.
fn styleColor(c: anytype, fallback: Rgba, t: *const vt.Terminal, bold: bool) Rgba {
    return switch (c) {
        .none => fallback,
        .palette => |idx| blk: {
            const i: usize = if (bold and idx < 8) idx + 8 else idx;
            const rgb = t.colors.palette.current[i];
            break :blk .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 };
        },
        .rgb => |rgb| .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 },
    };
}

fn cellBackground(cell: anytype, style_bg: anytype, fallback: Rgba, t: *const vt.Terminal) Rgba {
    return switch (cell.content_tag) {
        .bg_color_palette => blk: {
            const rgb = t.colors.palette.current[cell.content.color_palette.data];
            break :blk .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 };
        },
        .bg_color_rgb => blk: {
            const rgb = cell.content.color_rgb;
            break :blk .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 };
        },
        else => styleColor(style_bg, fallback, t, false),
    };
}

/// Underlines of `line` pixels near the bottom of the cell at y0, `ch` high.
fn paintUnderline(c: Canvas, x0: usize, y0: usize, ch: usize, w: usize, line: usize, kind: anytype, color: Rgba) void {
    const low = y0 + (ch -| 2 * line);
    switch (kind) {
        .none => {},
        .single => c.rect(x0, low, w, line, color),
        .double => {
            c.rect(x0, y0 + (ch -| 3 * line), w, line, color);
            c.rect(x0, y0 + (ch -| line), w, line, color);
        },
        .curly => for (0..w) |x| {
            const y = low + ((x / line) & 1) * line;
            for (0..line) |dy| c.dot(x0 + x, y + dy, color);
        },
        .dotted => for (0..w) |x| {
            if ((x / line) & 1 == 0) c.rect(x0 + x, low, 1, line, color);
        },
        .dashed => for (0..w) |x| {
            if ((x / line) % 4 < 3) c.rect(x0 + x, low, 1, line, color);
        },
    }
}

fn testChain(lib: *fonts.Library) !fonts.Chain {
    var diag: fonts.Diagnostic = .{};
    return lib.resolve(.{}, &diag);
}

test "render stored appearance and line decorations" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 8, .rows = 4 });
    defer term.deinit(alloc);
    var lib: fonts.Library = .init(alloc, std.testing.io);
    defer lib.deinit();
    var chain = try testChain(&lib);

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(
        "\x1b[1;1H\x1b[48;2;10;20;30m\x1b[2K" ++
            "\x1b[2;1H\x1b[0;41m界" ++
            "\x1b[3;1H\x1b[0;31;8mA" ++
            "\x1b[4;1H\x1b[0;4;58;2;1;2;3;9;53mA",
    );

    const image = try renderRgba(alloc, &term, 8, 4, &chain);
    defer alloc.free(image.pixels);
    const width: usize = image.width;
    const cw = chain.cell.width;
    const ch = chain.cell.height;

    try expectRgb(image.pixels[0], 10, 20, 30);
    const red = term.colors.palette.current[1];
    try expectRgb(image.pixels[ch * width + cw], red.r, red.g, red.b);

    const invisible = image.pixels[2 * ch * width ..][0 .. cw * ch];
    for (invisible) |pixel| try std.testing.expect(!(pixel.r > 100 and pixel.g < 80 and pixel.b < 80));

    const decorated_y = 3 * ch;
    try expectRgb(image.pixels[(decorated_y + ch - 2) * width], 1, 2, 3);
    try expectRgb(image.pixels[(decorated_y + ch / 2) * width], 220, 215, 186);
    try expectRgb(image.pixels[(decorated_y + 1) * width], 220, 215, 186);
}

test "render text, CJK, drawn lines, and color emoji" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 12, .rows = 1 });
    defer term.deinit(alloc);
    var lib: fonts.Library = .init(alloc, std.testing.io);
    defer lib.deinit();
    var chain = try testChain(&lib);

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("Ж─▄界\u{1F642}\u{E0B0}");

    const image = try renderRgba(alloc, &term, 12, 1, &chain);
    defer alloc.free(image.pixels);
    const fg = Rgba{ .r = 220, .g = 215, .b = 186, .a = 255 };
    const cw = chain.cell.width;

    for ([_]usize{ 0, 1, 2, 3, 7 }) |cell_col| {
        var visible = false;
        for (0..chain.cell.height) |y| {
            for (0..cw) |x| visible = visible or std.meta.eql(image.pixels[y * image.width + cell_col * cw + x], fg);
        }
        try std.testing.expect(visible);
    }
    // The emoji is in color: some pixel is neither the foreground nor gray.
    var colored = false;
    for (0..chain.cell.height) |y| for (0..2 * cw) |x| {
        const p = image.pixels[y * image.width + 5 * cw + x];
        colored = colored or (@max(p.r, p.g, p.b) - @min(p.r, p.g, p.b) > 60 and !std.meta.eql(p, fg));
    };
    try std.testing.expect(colored);

    const encoded = try renderPng(alloc, &term, &chain);
    defer alloc.free(encoded);
    try std.testing.expect(encoded.len < std.mem.sliceAsBytes(image.pixels).len);
}

test "render combining marks precomposed or over their base" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 8, .rows = 1 });
    defer term.deinit(alloc);
    var lib: fonts.Library = .init(alloc, std.testing.io);
    defer lib.deinit();
    var chain = try testChain(&lib);
    var stream = term.vtStream();
    defer stream.deinit();
    // e + U+0301, é, x + U+0301, x, Hangul jamo ᄒ ᅡ ᆫ, and 한.
    stream.nextSlice("e\u{301}\u{e9}x\u{301}x\u{1112}\u{1161}\u{11ab}\u{d55c}");

    const image = try renderRgba(alloc, &term, 8, 1, &chain);
    defer alloc.free(image.pixels);
    const cw = chain.cell.width;
    const Cells = struct {
        fn same(img: Image, w: usize, a: usize, b: usize, n: usize) bool {
            for (0..img.height) |y| {
                const row = img.pixels[y * img.width ..];
                if (!std.mem.eql(u8, std.mem.sliceAsBytes(row[a * w ..][0 .. n * w]), std.mem.sliceAsBytes(row[b * w ..][0 .. n * w]))) return false;
            }
            return true;
        }
    };
    try std.testing.expect(Cells.same(image, cw, 0, 1, 1));
    try std.testing.expect(!Cells.same(image, cw, 2, 3, 1));
    try std.testing.expect(Cells.same(image, cw, 4, 6, 2));
}

test "render draws the visible screen, not the scrollback" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 4, .rows = 1 });
    defer term.deinit(alloc);
    var lib: fonts.Library = .init(alloc, std.testing.io);
    defer lib.deinit();
    var chain = try testChain(&lib);
    var stream = term.vtStream();
    defer stream.deinit();
    // The red row scrolls into history; the screen shows only "Y".
    stream.nextSlice("\x1b[41mX\x1b[0m\r\nY");

    const image = try renderRgba(alloc, &term, 4, 1, &chain);
    defer alloc.free(image.pixels);
    try expectRgb(image.pixels[0], 0x1f, 0x1f, 0x28);
}

test "decorations fit cells one pixel high" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 2, .rows = 2 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[4;53mA\x1b[0m\r\n\x1b[21;9mA");

    // A PSF2 font of one 8x1 glyph for 'A' sets 8x1 cells.
    var psf: [36]u8 = @splat(0);
    @memcpy(psf[0..4], "\x72\xb5\x4a\x86");
    for ([_]u32{ 0, 32, 1, 1, 1, 1, 8 }, 0..) |v, i| std.mem.writeInt(u32, psf[4 + 4 * i ..][0..4], v, .little);
    psf[32] = 0xff;
    @memcpy(psf[33..35], "A\xff");
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "tiny.psf", .data = &psf });
    const path = try dir.dir.realPathFileAlloc(std.testing.io, "tiny.psf", alloc);
    defer alloc.free(path);
    var lib: fonts.Library = .init(alloc, std.testing.io);
    defer lib.deinit();
    var diag: fonts.Diagnostic = .{};
    var chain = try lib.resolve(.{ .fonts = &.{path} }, &diag);
    try std.testing.expectEqual(@as(u16, 1), chain.cell.height);
    const image = try renderRgba(alloc, &term, 2, 2, &chain);
    defer alloc.free(image.pixels);
}

fn expectRgb(pixel: Rgba, r: u8, g: u8, b: u8) !void {
    try std.testing.expectEqual(r, pixel.r);
    try std.testing.expectEqual(g, pixel.g);
    try std.testing.expectEqual(b, pixel.b);
}

test "reject invalid and overflowing cell dimensions" {
    try std.testing.expectError(error.InvalidDimensions, maxPngSize(0, 1, fonts.bitmap_cell));
    try std.testing.expectError(error.InvalidDimensions, maxPngSize(1, 0, fonts.bitmap_cell));
    try std.testing.expectError(error.InvalidDimensions, maxPngSize(std.math.maxInt(u32), 1, fonts.bitmap_cell));
}
