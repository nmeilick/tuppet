//! Software renderer: draws the terminal's active screen into an RGBA
//! buffer using the embedded 8x16 VGA font, then encodes it as PNG.

const std = @import("std");
const vt = @import("vt");
const font = @import("font.zig");
const png = @import("png.zig");

const Rgba = extern struct { r: u8, g: u8, b: u8, a: u8 };

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []Rgba,
};

fn imageDimensions(cols: u32, rows: u32) !struct { width: u32, height: u32 } {
    if (cols == 0 or rows == 0) return error.InvalidDimensions;
    const width = std.math.mul(u32, cols, font.char_width) catch return error.InvalidDimensions;
    const height = std.math.mul(u32, rows, font.char_height) catch return error.InvalidDimensions;
    return .{ .width = width, .height = height };
}

/// Return a conservative PNG size bound for a terminal grid.
pub fn maxPngSize(cols: u32, rows: u32) !usize {
    const dimensions = try imageDimensions(cols, rows);
    return png.maxEncodedSize(dimensions.width, dimensions.height);
}

/// Render the active screen as a PNG. The caller frees the result.
pub fn renderPng(gpa: std.mem.Allocator, t: *const vt.Terminal) ![]u8 {
    const image = try renderImage(gpa, t);
    defer gpa.free(image.pixels);
    return encodePng(gpa, image);
}

/// Draw the active screen; only this step needs the terminal. The caller
/// frees `pixels`.
pub fn renderImage(gpa: std.mem.Allocator, t: *const vt.Terminal) !Image {
    return renderRgba(gpa, t, @intCast(t.cols), @intCast(t.rows));
}

pub fn encodePng(gpa: std.mem.Allocator, image: Image) ![]u8 {
    return png.writeRgba8(gpa, image.width, image.height, std.mem.sliceAsBytes(image.pixels));
}

fn renderRgba(gpa: std.mem.Allocator, t: *const vt.Terminal, cols: u32, rows: u32) !Image {
    const dimensions = try imageDimensions(cols, rows);
    const cols_usize: usize = cols;
    const rows_usize: usize = rows;
    const width: usize = dimensions.width;
    const height: usize = dimensions.height;
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidDimensions;

    // Terminal default colors (ghostty ships them unset; Session.start
    // installs the default theme).
    const fg = resolveDefault(t.colors.foreground.get(), 0xdc, 0xd7, 0xba);
    const bg = resolveDefault(t.colors.background.get(), 0x1f, 0x1f, 0x28);

    const px = try gpa.alloc(Rgba, pixel_count);
    errdefer gpa.free(px);
    for (px) |*p| p.* = bg;

    // Reverse video (DECSCNM) inverts every cell.
    const reverse_screen = t.modes.get(.reverse_colors);
    const pages = &t.screens.active.pages;
    // The active area is the visible screen; scrollback lies above it.
    var it = pages.cellIterator(.right_down, .{ .active = .{} }, null);

    var row: usize = 0;
    var seen = false;
    while (it.next()) |pin| {
        if (seen and pin.x == 0) row += 1;
        seen = true;
        if (row >= rows_usize) break;

        const cells = pin.cells(.all);
        const cell = &cells[@intCast(pin.x)];
        const col: usize = @intCast(pin.x);

        // Wide characters paint their spacer tail as part of the head cell.
        if (cell.wide == .spacer_tail) continue;

        const st = pin.style(cell);

        var fg_rgb = styleColor(st.fg_color, fg, t, st.flags.bold);
        var bg_rgb = cellBackground(cell, st.bg_color, bg, t);
        if (st.flags.inverse != reverse_screen) {
            const tmp = fg_rgb;
            fg_rgb = bg_rgb;
            bg_rgb = tmp;
        }
        if (st.flags.faint) fg_rgb = midpoint(fg_rgb, bg_rgb);

        const span_cells: usize = @min(cell.gridWidth(), cols_usize - col);
        const span_width = span_cells * font.char_width;
        const x0 = col * font.char_width;
        const y0 = row * font.char_height;
        paintRect(px, width, x0, y0, span_width, font.char_height, bg_rgb);

        if (st.flags.invisible) continue;

        const cp = cell.codepoint();
        if (cp != 0) paintGlyph(px, width, x0, y0, font.glyphFor(cp), fg_rgb);
        const line_rgb = styleColor(st.underline_color, fg_rgb, t, false);
        paintUnderline(px, width, x0, y0, span_width, st.flags.underline, line_rgb);
        if (st.flags.strikethrough) paintLine(px, width, x0, y0 + font.char_height / 2, span_width, fg_rgb);
        if (st.flags.overline) paintLine(px, width, x0, y0 + 1, span_width, fg_rgb);
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

fn paintRect(px: []Rgba, width: usize, x0: usize, y0: usize, w: usize, h: usize, c: Rgba) void {
    for (0..h) |dy| {
        const y = y0 + dy;
        if (y >= px.len / width) break;
        for (0..w) |dx| {
            const x = x0 + dx;
            if (x >= width) break;
            px[y * width + x] = c;
        }
    }
}

fn paintLine(px: []Rgba, width: usize, x0: usize, y: usize, line_width: usize, c: Rgba) void {
    if (y >= px.len / width or x0 >= width) return;
    @memset(px[y * width + x0 ..][0..@min(line_width, width - x0)], c);
}

fn paintUnderline(px: []Rgba, width: usize, x0: usize, y0: usize, line_width: usize, kind: anytype, c: Rgba) void {
    switch (kind) {
        .none => {},
        .single => paintLine(px, width, x0, y0 + font.char_height - 2, line_width, c),
        .double => {
            paintLine(px, width, x0, y0 + font.char_height - 3, line_width, c);
            paintLine(px, width, x0, y0 + font.char_height - 1, line_width, c);
        },
        .curly => for (0..line_width) |x| {
            const y = y0 + font.char_height - 2 + (x & 1);
            if (x0 + x < width and y < px.len / width) px[y * width + x0 + x] = c;
        },
        .dotted => for (0..line_width) |x| {
            if (x & 1 == 0) paintLine(px, width, x0 + x, y0 + font.char_height - 2, 1, c);
        },
        .dashed => for (0..line_width) |x| {
            if (x % 4 < 3) paintLine(px, width, x0 + x, y0 + font.char_height - 2, 1, c);
        },
    }
}

/// Paint one 8x16 glyph; MSB of each row byte is the leftmost pixel.
fn paintGlyph(px: []Rgba, width: usize, x0: usize, y0: usize, glyph: [16]u8, c: Rgba) void {
    for (0..16) |dy| {
        const bits = glyph[dy];
        if (bits == 0) continue;
        const y = y0 + dy;
        if (y >= px.len / width) break;
        var x = x0;
        var bit: u8 = 0x80;
        while (bit != 0) : (bit >>= 1) {
            if (x >= width) break;
            if (bits & bit != 0) px[y * width + x] = c;
            x += 1;
        }
    }
}

test "render stored appearance and line decorations" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 8, .rows = 4 });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(
        "\x1b[1;1H\x1b[48;2;10;20;30m\x1b[2K" ++
            "\x1b[2;1H\x1b[0;41m界" ++
            "\x1b[3;1H\x1b[0;31;8mA" ++
            "\x1b[4;1H\x1b[0;4;58;2;1;2;3;9;53mA",
    );

    const image = try renderRgba(alloc, &term, 8, 4);
    defer alloc.free(image.pixels);
    const width: usize = image.width;

    try expectRgb(image.pixels[0], 10, 20, 30);
    const red = term.colors.palette.current[1];
    try expectRgb(image.pixels[font.char_height * width + font.char_width], red.r, red.g, red.b);

    const invisible = image.pixels[2 * font.char_height * width ..][0 .. font.char_width * font.char_height];
    for (invisible) |pixel| try std.testing.expect(!(pixel.r > 100 and pixel.g < 80 and pixel.b < 80));

    const decorated_y = 3 * font.char_height;
    try expectRgb(image.pixels[(decorated_y + font.char_height - 2) * width], 1, 2, 3);
    try expectRgb(image.pixels[(decorated_y + font.char_height / 2) * width], 220, 215, 186);
    try expectRgb(image.pixels[(decorated_y + 1) * width], 220, 215, 186);
}

test "render mapped blocks and visible unicode replacements" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 12, .rows = 1 });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("▀▄▌▐Ж界🙂");

    const image = try renderRgba(alloc, &term, 12, 1);
    defer alloc.free(image.pixels);
    const fg = Rgba{ .r = 220, .g = 215, .b = 186, .a = 255 };

    for ([_]usize{ 0, 1, 2, 3, 4, 5, 7 }) |cell_col| {
        var visible = false;
        for (0..font.char_height) |y| {
            for (0..font.char_width) |x| {
                const pixel = image.pixels[y * image.width + cell_col * font.char_width + x];
                visible = visible or std.meta.eql(pixel, fg);
            }
        }
        try std.testing.expect(visible);
    }

    const encoded = try renderPng(alloc, &term);
    defer alloc.free(encoded);
    try std.testing.expect(encoded.len < std.mem.sliceAsBytes(image.pixels).len);
}

test "render draws the visible screen, not the scrollback" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 4, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    // The red row scrolls into history; the screen shows only "Y".
    stream.nextSlice("\x1b[41mX\x1b[0m\r\nY");

    const image = try renderRgba(alloc, &term, 4, 1);
    defer alloc.free(image.pixels);
    try expectRgb(image.pixels[0], 0x1f, 0x1f, 0x28);
}

fn expectRgb(pixel: Rgba, r: u8, g: u8, b: u8) !void {
    try std.testing.expectEqual(r, pixel.r);
    try std.testing.expectEqual(g, pixel.g);
    try std.testing.expectEqual(b, pixel.b);
}

test "reject invalid and overflowing cell dimensions" {
    try std.testing.expectError(error.InvalidDimensions, maxPngSize(0, 1));
    try std.testing.expectError(error.InvalidDimensions, maxPngSize(1, 0));
    try std.testing.expectError(error.InvalidDimensions, maxPngSize(std.math.maxInt(u32), 1));
}
