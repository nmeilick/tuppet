//! The painter: a canvas of cells the size of the person's window, filled
//! from sessions' screens and from tuppet's own text, and written to the
//! person's terminal as only what changed since the last frame.
//!
//! What it writes is limited to cursor moves, SGR, printable text, OSC 8
//! links whose address is printable ASCII, cursor visibility and shape,
//! and the synchronized update around each frame; on the normal screen
//! also line feeds on the bottom row, erase-line, and autowrap on and off
//! around a wrap seam. Text from a session
//! never carries a control character, and the cursor is placed again
//! after every cell that is not plain ASCII, so a character the person's
//! terminal measures differently cannot shift what follows it.

const std = @import("std");
const vt = @import("vt");

/// A link's address is written only up to this length.
pub const max_link_len = 2000;
/// A cell's text is cut to this many bytes of UTF-8.
const max_grapheme_len = 64;
/// About how many bytes of rows for the scrollback one frame writes.
const scroll_budget = 1024 * 1024;
/// The first cell of the terminal's bottom row, whatever its size.
const bottom_row = "\x1b[9999;1H";
/// The widest session.
const limits_cols = 1000;
/// Interned text is dropped at the next `clear` once it holds this much.
const strings_reset = 1 << 20;
/// Interned text never passes this, so its offsets fit in a cell.
const strings_max = (1 << 21) - 1;

/// Written once when the canvas takes over the terminal: right-to-left
/// reordering and autowrap off, so every cell lands where it is placed and
/// the bottom-right cell does not scroll the screen, and insert mode,
/// origin mode, margins, the scroll region, and the character set (G0,
/// shifted in) reset from whatever ran before. The screen is erased after
/// reordering is off, since VTE applies that only to the cursor's row and
/// to rows erased later.
pub const enter = enter_modes ++ "\x1b[2J";
/// `enter` without the erase, for the normal screen, whose rows the
/// caller scrolls away and erases one by one.
pub const enter_modes = "\x1b[8l\x1b[?7l\x1b[4l\x1b[?6l\x1b[?69l\x1b[r\x1b(B\x0f\x1b[0m";
/// Written once when the canvas gives the terminal back: plain SGR, no
/// link, the person's own cursor shape, a visible cursor, autowrap and
/// right-to-left reordering on again.
pub const leave = "\x1b[0m\x1b]8;;\x1b\\\x1b[0 q\x1b[?25h\x1b[?7h\x1b[8h";

/// A colour as it is written: the person's default, a palette index, or
/// RGB.
pub const Color = packed struct {
    kind: Kind = .default,
    /// A palette index, or 0xRRGGBB.
    value: u24 = 0,

    pub const Kind = enum(u2) { default, palette, rgb };

    pub fn palette(i: u8) Color {
        return .{ .kind = .palette, .value = i };
    }

    pub fn rgb(c: vt.color.RGB) Color {
        return .{ .kind = .rgb, .value = @as(u24, c.r) << 16 | @as(u24, c.g) << 8 | c.b };
    }
};

pub const Underline = enum(u3) { none, single, double, curly, dotted, dashed };

/// Everything SGR sets for a cell.
pub const Style = packed struct {
    fg: Color = .{},
    bg: Color = .{},
    underline_color: Color = .{},
    underline: Underline = .none,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
};

/// What the terminal has marked of a row's wrap into the next.
pub const Mark = enum(u2) { off, on, unknown };

/// One cell of the canvas. Cells compare with `==`.
pub const Cell = packed struct {
    /// A code point, or with `grapheme` the canvas's interned text of a
    /// character of several code points.
    cp: u21 = ' ',
    grapheme: bool = false,
    width: Width = .narrow,
    /// The canvas's interned link address, or 0 for none.
    link: u21 = 0,
    style: Style = .{},
    /// tuppet's own cell over a session, such as a box's: written after
    /// every other cell of the frame, so nothing a session shows can be
    /// drawn over it.
    top: bool = false,

    pub const Width = enum(u2) {
        narrow,
        /// The left half of a wide character.
        wide,
        /// The right half of a wide character, which is never written.
        tail,
    };

    /// Plain ASCII, after which the terminal's cursor is where tuppet
    /// expects it.
    fn ascii(c: Cell) bool {
        return !c.grapheme and c.cp >= 0x20 and c.cp < 0x7f;
    }
};

/// The DECSCUSR shapes; `default` is the person's own.
pub const Shape = enum(u3) {
    default = 0,
    blinking_block = 1,
    steady_block = 2,
    blinking_underline = 3,
    steady_underline = 4,
    blinking_bar = 5,
    steady_bar = 6,
};

/// A cell of the canvas, counted from 0.
pub const Pos = struct { x: usize, y: usize };

pub const Cursor = struct {
    /// Where the cursor shows on the canvas; null hides it.
    at: ?Pos = null,
    shape: Shape = .default,
    /// Where the program's cursor is, also while it is hidden.
    park: ?Pos = null,
};

/// A part of the canvas.
pub const Rect = struct { x: usize, y: usize, cols: usize, rows: usize };

/// Whether a code point may be written to the person's terminal: no C0,
/// DEL, or C1 control, no bidirectional formatting character, no
/// surrogate.
pub fn printable(cp: u21) bool {
    return switch (cp) {
        0...0x1f, 0x7f...0x9f, 0x061c, 0x200e, 0x200f, 0x202a...0x202e, 0x2066...0x2069, 0xd800...0xdfff => false,
        else => cp <= 0x10ffff,
    };
}

/// Whether a link's address may be written: printable ASCII of at most
/// max_link_len bytes.
pub fn linkAllowed(uri: []const u8) bool {
    if (uri.len == 0 or uri.len > max_link_len) return false;
    for (uri) |b| if (b < 0x20 or b > 0x7e) return false;
    return true;
}

/// Whether a character of `cps` stays in its own cell between ordinary
/// neighbours. A terminal that clusters graphemes joins a spacing mark to
/// the character before it, even across a cursor move, and a prepended
/// mark to the one after.
fn isolated(cps: []const u21) bool {
    if (cps[0] < 0x80 and cps.len == 1) return true;
    if (vt.unicode.graphemeWidth(u21, &.{ 'x', cps[0] }).len > 1) return false;
    var buf: [max_grapheme_len + 1]u21 = undefined;
    @memcpy(buf[0..cps.len], cps);
    buf[cps.len] = 'x';
    return vt.unicode.graphemeWidth(u21, buf[0 .. cps.len + 1]).len <= cps.len;
}

/// Interned grapheme text and link addresses, each ended by a 0 byte,
/// found by offset; offset 0 is the empty string.
const Strings = struct {
    bytes: std.ArrayList(u8) = .empty,
    index: std.HashMapUnmanaged(u32, void, std.hash_map.StringIndexContext, 80) = .empty,

    fn deinit(s: *Strings, gpa: std.mem.Allocator) void {
        s.bytes.deinit(gpa);
        s.index.deinit(gpa);
    }

    /// Drop every string.
    fn reset(s: *Strings, gpa: std.mem.Allocator) void {
        s.bytes.clearRetainingCapacity();
        s.index.clearRetainingCapacity();
        s.bytes.append(gpa, 0) catch {};
    }

    fn get(s: *const Strings, offset: u21) []const u8 {
        if (offset >= s.bytes.items.len) return "";
        return std.mem.sliceTo(s.bytes.items[offset..], 0);
    }

    /// The offset of `text`, or null when it is empty, holds a 0 byte, or
    /// there is no room.
    fn intern(s: *Strings, gpa: std.mem.Allocator, text: []const u8) ?u21 {
        if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null or s.bytes.items.len == 0) return null;
        const ctx: std.hash_map.StringIndexContext = .{ .bytes = &s.bytes };
        const adapter: std.hash_map.StringIndexAdapter = .{ .bytes = &s.bytes };
        if (s.index.getKeyAdapted(text, adapter)) |offset| return @intCast(offset);
        const offset = s.bytes.items.len;
        if (offset + text.len + 1 > strings_max) return null;
        s.bytes.ensureUnusedCapacity(gpa, text.len + 1) catch return null;
        s.index.ensureUnusedCapacityContext(gpa, 1, ctx) catch return null;
        s.bytes.appendSliceAssumeCapacity(text);
        s.bytes.appendAssumeCapacity(0);
        s.index.putAssumeCapacityNoClobberContext(@intCast(offset), {}, ctx);
        return @intCast(offset);
    }

    /// The offset of a link address, or 0 when it may not be written.
    fn link(s: *Strings, gpa: std.mem.Allocator, uri: []const u8) u21 {
        if (!linkAllowed(uri)) return 0;
        return s.intern(gpa, uri) orelse 0;
    }

    /// A cell for a character of `cps`: the first code point, and with
    /// more the interned text of them all. Code points that may not be
    /// written are left out; a character that starts with one, or that
    /// would join its neighbours, is U+FFFD.
    fn character(s: *Strings, gpa: std.mem.Allocator, cps: []const u21, width: Cell.Width, style: Style) Cell {
        const bad: Cell = .{ .cp = 0xfffd, .style = style };
        if (!printable(cps[0])) return bad;
        var kept: [max_grapheme_len]u21 = undefined;
        var n: usize = 0;
        var len: usize = 0;
        for (cps) |cp| {
            if (!printable(cp)) continue;
            const size = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
            if (len + size > max_grapheme_len) break;
            kept[n] = cp;
            n += 1;
            len += size;
        }
        if (!isolated(kept[0..n])) return bad;
        if (n == 1) return .{ .cp = kept[0], .width = width, .style = style };
        var buf: [max_grapheme_len]u8 = undefined;
        len = 0;
        for (kept[0..n]) |cp| len += std.unicode.utf8Encode(cp, buf[len..]) catch unreachable;
        const offset = s.intern(gpa, buf[0..len]) orelse return .{ .cp = kept[0], .width = width, .style = style };
        return .{ .cp = offset, .grapheme = true, .width = width, .style = style };
    }

    /// `cell`, which refers to `from`'s strings, referring to these.
    fn move(s: *Strings, gpa: std.mem.Allocator, from: *const Strings, cell: Cell) Cell {
        var out = cell;
        if (cell.grapheme) {
            const chars = from.get(cell.cp);
            if (s.intern(gpa, chars)) |offset| {
                out.cp = offset;
            } else out = .{ .cp = alone(chars), .width = cell.width, .style = cell.style };
        }
        if (cell.link != 0) out.link = s.link(gpa, from.get(cell.link));
        return out;
    }
};

/// Blank any half of a wide character in `r` without its other half.
fn repairRow(r: []Cell) void {
    for (r, 0..) |*cell, x| switch (cell.width) {
        .narrow => {},
        .wide => if (x + 1 >= r.len or r[x + 1].width != .tail) {
            cell.* = .{ .style = cell.style, .top = cell.top };
        },
        .tail => if (x == 0 or r[x - 1].width != .wide) {
            cell.* = .{ .style = cell.style, .top = cell.top };
        },
    };
}

/// Fill `out` with the row of `t` at `pin`, cut at `out`'s width.
fn fillRow(strings: *Strings, gpa: std.mem.Allocator, out: []Cell, t: *const vt.Terminal, pin: vt.Pin) void {
    const page = pin.node.page();
    const cells = pin.cells(.all);
    const width = @min(out.len, cells.len);
    const reverse = t.modes.get(.reverse_colors);
    var cps: [max_grapheme_len]u21 = undefined;
    var style_id: ?@FieldType(vt.Cell, "style_id") = null;
    var style: Style = .{};
    var link_id: ?u32 = null;
    var link: u21 = 0;
    for (out[0..width], cells[0..width], 0..) |*o, *cell, x| {
        const s = switch (cell.content_tag) {
            .bg_color_palette => resolveStyle(t, pin.style(cell), resolvePalette(t, cell.content.color_palette.data), reverse),
            .bg_color_rgb => resolveStyle(t, pin.style(cell), .rgb(.{ .r = cell.content.color_rgb.r, .g = cell.content.color_rgb.g, .b = cell.content.color_rgb.b }), reverse),
            .codepoint, .codepoint_grapheme => blk: {
                if (style_id != cell.style_id) {
                    style_id = cell.style_id;
                    style = resolveStyle(t, pin.style(cell), null, reverse);
                }
                break :blk style;
            },
        };
        o.* = switch (cell.wide) {
            .spacer_tail => .{ .cp = 0, .width = .tail, .style = s },
            .spacer_head => .{ .style = s },
            .narrow, .wide => blk: {
                // A wide character cut off at the right edge.
                if (cell.wide == .wide and x + 1 >= width) break :blk .{ .style = s };
                const w: Cell.Width = if (cell.wide == .wide) .wide else .narrow;
                const cp = cell.codepoint();
                if (cp == 0) break :blk .{ .style = s };
                if (!cell.hasGrapheme()) break :blk strings.character(gpa, &[_]u21{cp}, w, s);
                cps[0] = cp;
                var n: usize = 1;
                if (page.lookupGrapheme(cell)) |rest| for (rest) |extra| {
                    if (n == cps.len) break;
                    cps[n] = extra;
                    n += 1;
                };
                break :blk strings.character(gpa, cps[0..n], w, s);
            },
        };
        if (cell.hyperlink) if (page.lookupHyperlink(cell)) |id| {
            if (link_id != id) {
                link_id = id;
                link = strings.link(gpa, page.hyperlink_set.get(page.memory, id).uri.slice(page.memory));
            }
            o.link = link;
        };
    }
}

/// Rows that left a session's screen, oldest first, held until they are
/// written into the person's terminal's scrollback.
pub const Lines = struct {
    gpa: std.mem.Allocator,
    rows: std.ArrayList(Line) = .empty,
    head: usize = 0,
    strings: Strings = .{},
    /// The most cells held; past it the oldest rows go, and a note says
    /// so.
    max: usize = 1 << 20,
    held: usize = 0,

    pub const Line = struct {
        /// Without the blanks at its end.
        cells: []Cell = &.{},
        /// The session's width.
        cols: u16 = 0,
        /// The session wrapped the row into the next.
        wrap: bool = false,
        /// The row continues the one before it, which a clear or a reset
        /// may have cut it off from.
        cont: bool = false,
        /// Not a row: this many rows were left out here.
        gap: u64 = 0,

        fn first(line: *const Line) Cell {
            return if (line.cells.len > 0) line.cells[0] else .{};
        }

        fn last(line: *const Line) Cell {
            return if (line.cells.len == line.cols and line.cols > 0) line.cells[line.cols - 1] else .{};
        }
    };

    pub fn init(gpa: std.mem.Allocator) Lines {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *Lines) void {
        for (l.rows.items[l.head..]) |r| l.gpa.free(r.cells);
        l.rows.deinit(l.gpa);
        l.strings.deinit(l.gpa);
    }

    pub fn len(l: *const Lines) usize {
        return l.rows.items.len - l.head;
    }

    pub fn at(l: *const Lines, i: usize) *const Line {
        return &l.rows.items[l.head + i];
    }

    /// Hold the row of `t` at `pin`; with `cont` it continues the line
    /// held last when that wrapped, whatever the row says.
    pub fn push(l: *Lines, t: *const vt.Terminal, pin: vt.Pin, cont: bool) void {
        if (l.strings.bytes.items.len == 0) l.strings.reset(l.gpa);
        var row: [limits_cols]Cell = undefined;
        const cols = @min(t.cols, limits_cols);
        @memset(row[0..cols], .{});
        fillRow(&l.strings, l.gpa, row[0..cols], t, pin);
        repairRow(row[0..cols]);
        var end = cols;
        while (end > 0 and row[end - 1] == Cell{}) end -= 1;
        const cells = l.gpa.dupe(Cell, row[0..end]) catch return l.leftOut(1);
        const r = pin.rowAndCell().row;
        l.append(.{ .cells = cells, .cols = @intCast(cols), .wrap = r.wrap, .cont = cont or r.wrap_continuation });
    }

    /// Hold a line of tuppet's own text in `style`, such as the mark of
    /// a switch between two sessions' lines.
    pub fn note(l: *Lines, text: []const u8, style: Style) void {
        var row: std.ArrayList(Cell) = .empty;
        defer row.deinit(l.gpa);
        const view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const wide = vt.unicode.codepointWidth(cp) == 2;
            row.append(l.gpa, .{ .cp = if (printable(cp)) cp else 0xfffd, .width = if (wide) .wide else .narrow, .style = style }) catch return;
            if (wide) row.append(l.gpa, .{ .cp = 0, .width = .tail, .style = style }) catch return;
        }
        const cells = row.toOwnedSlice(l.gpa) catch return;
        l.append(.{ .cells = cells, .cols = @intCast(@min(cells.len, limits_cols)) });
    }

    /// Say that `n` rows were left out here.
    pub fn leftOut(l: *Lines, n: u64) void {
        if (n == 0) return;
        if (l.len() > 0) {
            const last = &l.rows.items[l.rows.items.len - 1];
            if (last.gap > 0) {
                last.gap +|= n;
                return;
            }
        }
        l.append(.{ .gap = n });
    }

    /// Make line `i` no wider than `cols`: a wider one, held at an older
    /// width, becomes several lines, each wrapped into the next.
    pub fn fit(l: *Lines, i: usize, cols: usize) void {
        const index = l.head + i;
        const line = l.rows.items[index];
        if (line.gap > 0 or cols == 0 or line.cells.len <= cols) return;
        var parts: std.ArrayList(Line) = .empty;
        defer parts.deinit(l.gpa);
        var from: usize = 0;
        while (from < line.cells.len) {
            var to = @min(from + cols, line.cells.len);
            // A wide character whose second half would start the next.
            if (to < line.cells.len and to > from + 1 and line.cells[to - 1].width == .wide) to -= 1;
            const cells = l.gpa.dupe(Cell, line.cells[from..to]) catch {
                for (parts.items) |p| l.gpa.free(p.cells);
                return;
            };
            // One column cannot hold a wide character.
            repairRow(cells);
            const last = to == line.cells.len;
            parts.append(l.gpa, .{ .cells = cells, .cols = @intCast(cols), .wrap = if (last) line.wrap else true, .cont = if (from == 0) line.cont else true }) catch {
                l.gpa.free(cells);
                for (parts.items) |p| l.gpa.free(p.cells);
                return;
            };
            from = to;
        }
        l.rows.replaceRange(l.gpa, index, 1, parts.items) catch {
            for (parts.items) |p| l.gpa.free(p.cells);
            return;
        };
        l.gpa.free(line.cells);
        l.held += parts.items.len - 1;
    }

    fn append(l: *Lines, line: Line) void {
        // Only a row that continues the line held last joins it.
        if (!line.cont and l.len() > 0) l.rows.items[l.rows.items.len - 1].wrap = false;
        l.rows.append(l.gpa, line) catch {
            l.gpa.free(line.cells);
            return;
        };
        l.held += line.cells.len + 1;
        if (l.held > l.max) l.trim();
    }

    /// Drop the oldest rows until half the cells are left, leaving a note
    /// in their place.
    fn trim(l: *Lines) void {
        var gone: u64 = 0;
        var n: usize = 0;
        while (l.held > l.max / 2 and n + 1 < l.len()) : (n += 1) {
            const r = l.rows.items[l.head + n];
            gone +|= if (r.gap > 0) r.gap else 1;
            l.held -= r.cells.len + 1;
            l.gpa.free(r.cells);
        }
        if (n == 0) return;
        l.head += n - 1;
        l.rows.items[l.head] = .{ .gap = gone };
        l.held += 1;
        l.compact();
    }

    /// Hold a copy of `line` of `from`; not a note of rows left out.
    fn copyLine(l: *Lines, from: *const Lines, line: *const Line) void {
        if (line.gap > 0) return;
        if (l.strings.bytes.items.len == 0) l.strings.reset(l.gpa);
        const cells = l.gpa.alloc(Cell, line.cells.len) catch return;
        for (line.cells, cells) |cell, *out| out.* = l.strings.move(l.gpa, &from.strings, cell);
        l.append(.{ .cells = cells, .cols = line.cols, .wrap = line.wrap, .cont = line.cont });
    }

    /// Drop the oldest `n`, which were written.
    pub fn drop(l: *Lines, n: usize) void {
        for (l.rows.items[l.head..][0..n]) |r| {
            l.held -= r.cells.len + 1;
            l.gpa.free(r.cells);
        }
        l.head += n;
        l.compact();
    }

    fn compact(l: *Lines) void {
        if (l.head == l.rows.items.len) {
            l.rows.clearRetainingCapacity();
            l.head = 0;
            l.strings.reset(l.gpa);
        } else if (l.head > 1024 and l.head * 2 > l.rows.items.len) {
            l.rows.replaceRangeAssumeCapacity(0, l.head, &.{});
            l.head = 0;
        }
    }

    /// Move every line of `from` behind these.
    pub fn take(l: *Lines, from: *Lines) void {
        for (from.rows.items[from.head..]) |r| {
            if (r.gap > 0) {
                l.leftOut(r.gap);
                continue;
            }
            if (l.strings.bytes.items.len == 0) l.strings.reset(l.gpa);
            for (r.cells) |*cell| cell.* = l.strings.move(l.gpa, &from.strings, cell.*);
            l.append(r);
        }
        from.rows.clearRetainingCapacity();
        from.head = 0;
        from.held = 0;
        from.strings.reset(from.gpa);
    }
};

/// A grid of cells the size of the person's window, and what its
/// terminal shows now. Each frame: `clear`, draw, set `cursor`, `emit`.
pub const Canvas = struct {
    gpa: std.mem.Allocator,
    cols: usize = 0,
    rows: usize = 0,
    /// The next frame.
    cells: []Cell = &.{},
    /// What the person's terminal shows.
    shown: []Cell = &.{},
    cursor: Cursor = .{},
    shown_cursor: Cursor = .{},
    /// The DECSCUSR style written for the person's own cursor shape: 0,
    /// the terminal's default, unless the terminal said which it had.
    own_shape: u8 = 0,
    /// The cursor's shape is written again in the next frame.
    shape_due: bool = false,
    /// The next emit writes every cell and the cursor's state.
    full: bool = true,
    strings: Strings = .{},
    out: std.ArrayList(u8) = .empty,
    /// On the normal screen: whether the terminal is to mark each row as
    /// wrapped into the next, and whether it has, so that what it copies
    /// into its scrollback joins the rows the session joined, and no
    /// others. A row whose mark is unknown is joined again where it is to
    /// be wrapped and erased where it is not.
    marks: bool = false,
    wrap: []bool = &.{},
    shown_wrap: []Mark = &.{},
    /// The top row continues the row above it, the last line held.
    top_continues: bool = false,
    /// Where the cursor waits while it is hidden: the session's cursor
    /// row, so a terminal that keeps the cursor's row on a resize keeps
    /// the right rows.
    park: ?Pos = null,
    /// Where the terminal's cursor is after the last emit; null unknown.
    term_at: ?Pos = null,
    /// A row's worth of cells for the lines written into the scrollback.
    scratch: []Cell = &.{},
    /// Links that cells carry are written; off, they are left out.
    links: bool = true,
    /// The color a faded copy is painted in; null paints it faint, which
    /// most terminals ignore on a light background.
    dim: ?Color = null,
    /// Top cells that a cell written before them may have drawn over.
    redo: std.DynamicBitSetUnmanaged = .{},
    /// The last lines written into the terminal's scrollback, up to
    /// `keep` of them, to write again where the terminal may have lost
    /// them.
    written: Lines,
    keep: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Canvas {
        var written: Lines = .init(gpa);
        // Bounded by `keep`, never by a note of lines left out.
        written.max = std.math.maxInt(usize);
        return .{ .gpa = gpa, .written = written };
    }

    pub fn deinit(c: *Canvas) void {
        c.written.deinit();
        c.gpa.free(c.cells);
        c.gpa.free(c.shown);
        c.gpa.free(c.wrap);
        c.gpa.free(c.shown_wrap);
        c.gpa.free(c.scratch);
        c.strings.deinit(c.gpa);
        c.out.deinit(c.gpa);
        c.redo.deinit(c.gpa);
    }

    /// Size the canvas to the window; the next emit repaints everything.
    pub fn resize(c: *Canvas, cols: usize, rows: usize) !void {
        const cells = try c.gpa.alloc(Cell, cols * rows);
        errdefer c.gpa.free(cells);
        const shown = try c.gpa.alloc(Cell, cols * rows);
        errdefer c.gpa.free(shown);
        const wrap = try c.gpa.alloc(bool, rows);
        errdefer c.gpa.free(wrap);
        const shown_wrap = try c.gpa.alloc(Mark, rows);
        errdefer c.gpa.free(shown_wrap);
        const scratch = try c.gpa.alloc(Cell, cols);
        c.gpa.free(c.cells);
        c.gpa.free(c.shown);
        c.gpa.free(c.wrap);
        c.gpa.free(c.shown_wrap);
        c.gpa.free(c.scratch);
        c.cells = cells;
        c.shown = shown;
        c.wrap = wrap;
        // The terminal rewrapped its rows as it saw fit.
        c.shown_wrap = shown_wrap;
        @memset(c.shown_wrap, .unknown);
        c.scratch = scratch;
        c.term_at = null;
        c.cols = cols;
        c.rows = rows;
        c.cursor = .{};
        c.clear();
        c.full = true;
    }

    /// Repaint everything at the next emit, as after the terminal was
    /// cleared by something else.
    pub fn invalidate(c: *Canvas) void {
        c.full = true;
        c.term_at = null;
    }

    /// Write line feeds on the terminal's bottom row that push its top `n`
    /// rows into its scrollback as they are, at most a window's worth, and
    /// repaint everything at the next emit.
    pub fn pushUp(c: *Canvas, w: *std.Io.Writer, n: usize) !void {
        if (n == 0) return;
        try w.writeAll("\x1b[0m" ++ bottom_row);
        try w.splatByteAll('\n', @min(n, c.rows));
        c.invalidate();
        c.setMarks(c.marks, false);
    }

    /// Keep the last `keep` written lines, and only the text they use.
    fn trimWritten(c: *Canvas) void {
        const w = &c.written;
        if (w.len() > c.keep) w.drop(w.len() - c.keep);
        if (w.strings.bytes.items.len <= strings_reset) return;
        var fresh: Lines = .init(c.gpa);
        fresh.max = w.max;
        fresh.take(w);
        w.deinit();
        w.* = fresh;
    }

    /// Put the last `n` lines written into the scrollback, of the `keep`
    /// kept, before `lines`, to be written again.
    pub fn writeAgain(c: *Canvas, n: usize, lines: *Lines) void {
        const w = &c.written;
        const k = @min(n, w.len());
        if (k == 0) return;
        var again: Lines = .init(lines.gpa);
        again.max = lines.max;
        for (w.len() - k..w.len()) |i| again.copyLine(w, w.at(i));
        again.take(lines);
        lines.deinit();
        lines.* = again;
    }

    /// Erase the rows where the terminal shows tuppet's own cells, so no
    /// line feed pushes them into its scrollback later; the cursor stays
    /// where it was. Nothing when what it shows is not known.
    pub fn eraseOwn(c: *Canvas, w: *std.Io.Writer) !void {
        if (c.full) return;
        var erased = false;
        for (0..c.rows) |y| {
            const shown = c.shown[y * c.cols ..][0..c.cols];
            const own = for (shown) |cell| {
                if (cell.top) break true;
            } else false;
            if (!own) continue;
            if (!erased) try w.writeAll("\x1b[0m");
            erased = true;
            try w.print("\x1b[{d};1H\x1b[2K", .{y + 1});
            @memset(shown, .{});
        }
        if (!erased) return;
        if (c.term_at) |p| try w.print("\x1b[{d};{d}H", .{ p.y + 1, p.x + 1 });
    }

    /// Whether the terminal marks rows as wrapped, from now on: set on
    /// the normal screen. `known` says that no row is marked now.
    pub fn setMarks(c: *Canvas, on: bool, known: bool) void {
        c.marks = on;
        @memset(c.shown_wrap, if (known) .off else .unknown);
    }

    /// Start a frame: every cell blank and the cursor hidden.
    pub fn clear(c: *Canvas) void {
        @memset(c.cells, .{});
        @memset(c.wrap, false);
        c.top_continues = false;
        c.cursor = .{};
        c.park = null;
        if (c.strings.bytes.items.len == 0 or c.strings.bytes.items.len > strings_reset) {
            // The shown cells refer to the old offsets.
            if (c.strings.bytes.items.len != 0) c.full = true;
            c.strings.reset(c.gpa);
        }
    }

    pub fn row(c: *Canvas, y: usize) []Cell {
        return c.cells[y * c.cols ..][0..c.cols];
    }

    /// The text of an interned string.
    pub fn string(c: *const Canvas, offset: u21) []const u8 {
        return c.strings.get(offset);
    }

    /// The UTF-8 a cell shows.
    pub fn cellText(c: *const Canvas, cell: Cell, buf: *[4]u8) []const u8 {
        if (cell.grapheme) return c.string(cell.cp);
        const cp: u21 = if (printable(cell.cp)) cell.cp else 0xfffd;
        return buf[0 .. std.unicode.utf8Encode(cp, buf) catch std.unicode.utf8Encode(0xfffd, buf) catch unreachable];
    }

    fn intern(c: *Canvas, s: []const u8) ?u21 {
        return c.strings.intern(c.gpa, s);
    }

    /// Write tuppet's own text from column `x`, at most `max` columns
    /// wide; text that does not fit ends in "…". Each code point takes a
    /// cell of its own: zero-width ones are left out, and bytes that are
    /// not UTF-8, controls, bidirectional formatting characters, and
    /// characters that would join a neighbour show as U+FFFD. Returns the
    /// column after it.
    pub fn text(c: *Canvas, y: usize, x: usize, max: usize, s: []const u8, style: Style) usize {
        if (y >= c.rows or x >= c.cols) return x;
        const limit = @min(x +| max, c.cols);
        const out = c.row(y);
        var col = x;
        var prev: ?u21 = null;
        var i: usize = 0;
        while (nextVisible(s, &i)) |next| {
            const cp: u21 = if (!isolated(&.{next}) or (prev != null and vt.unicode.graphemeWidth(u21, &.{ prev.?, next }).len > 1)) 0xfffd else next;
            const width: usize = @min(vt.unicode.codepointWidth(cp), 2);
            // A character that does not fit, or one that would fill the
            // last column while more text follows, becomes "…".
            var rest = i;
            if (col + width > limit or (col + width == limit and nextVisible(s, &rest) != null)) {
                if (col < limit) out[col] = .{ .cp = 0x2026, .style = style };
                return @min(col + 1, limit);
            }
            out[col] = .{ .cp = cp, .width = if (width == 2) .wide else .narrow, .style = style };
            if (width == 2) out[col + 1] = .{ .cp = 0, .width = .tail, .style = style };
            col += width;
            prev = cp;
        }
        return col;
    }

    /// Paint the active screen of `t` into `area`: cropped at the right
    /// and bottom when it is larger, at the top left when it is smaller.
    /// Colours the program changed are written as their RGB value, the
    /// others as the palette index or the default. Returns the program's
    /// cursor, hidden when it is hidden or outside the area.
    pub fn drawScreen(c: *Canvas, t: *const vt.Terminal, area: Rect) Cursor {
        const screen = t.screens.active;
        const pages = &screen.pages;
        const x0 = @min(area.x, c.cols);
        const y0 = @min(area.y, c.rows);
        const width = @min(area.cols, t.cols, c.cols - x0);
        const height = @min(area.rows, t.rows, c.rows - y0);
        for (0..height) |r| {
            const pin = pages.pin(.{ .active = .{ .y = @intCast(r) } }) orelse continue;
            fillRow(&c.strings, c.gpa, c.row(y0 + r)[x0..][0..width], t, pin);
            // A row as wide as the window may be marked as wrapped.
            if (x0 == 0 and t.cols == c.cols) {
                c.wrap[y0 + r] = pin.rowAndCell().row.wrap;
                if (y0 + r == 0) c.top_continues = pin.rowAndCell().row.wrap_continuation;
            }
        }
        const cur = screen.cursor;
        var shown: Cursor = .{ .shape = cursorShape(t) };
        if (cur.x < width and cur.y < height) {
            shown.park = .{ .x = x0 + cur.x, .y = y0 + cur.y };
            if (t.modes.get(.cursor_visible)) shown.at = shown.park;
        }
        return shown;
    }

    /// How `blit` copies cells.
    pub const Copy = enum {
        /// As they are.
        same,
        /// One code point per cell, so nothing in them joins a
        /// neighbour on the person's terminal.
        plain,
        /// Plain, with SGR 0;2 only and no links: a backdrop.
        faded,
    };

    /// Copy the cells of `src` into this canvas from column `x` and row
    /// `y`, as far as both reach.
    pub fn blit(c: *Canvas, src: *const Canvas, x: usize, y: usize, copy: Copy) void {
        if (x >= c.cols or y >= c.rows) return;
        const width = @min(src.cols, c.cols - x);
        const height = @min(src.rows, c.rows - y);
        for (0..height) |r| {
            const from = src.cells[r * src.cols ..][0..width];
            const to = c.row(y + r)[x..][0..width];
            if (copy == .same and x == 0 and src.cols == c.cols) {
                c.wrap[y + r] = src.wrap[r];
                if (y + r == 0 and r == 0) c.top_continues = src.top_continues;
            }
            for (from, to) |cell, *o| {
                var out = cell;
                out.top = false;
                if (cell.grapheme) {
                    const chars = src.string(cell.cp);
                    if (copy == .same) {
                        if (c.intern(chars)) |offset| {
                            out.cp = offset;
                        } else out = .{ .cp = alone(chars), .width = cell.width, .style = cell.style };
                    } else {
                        out.cp = alone(chars);
                        out.grapheme = false;
                    }
                }
                if (cell.link != 0) out.link = if (copy == .faded or !c.links) 0 else c.strings.link(c.gpa, src.string(cell.link));
                if (copy == .faded) out.style = if (c.dim) |dim| .{ .fg = dim } else .{ .faint = true };
                o.* = out;
            }
        }
    }

    /// One code point per cell in row `y`.
    pub fn plainRow(c: *Canvas, y: usize) void {
        if (y >= c.rows) return;
        for (c.row(y)) |*cell| if (cell.grapheme and !cell.top) {
            cell.cp = alone(c.string(cell.cp));
            cell.grapheme = false;
        };
    }

    /// One code point per cell in row `y` from `x` up to `end`, with
    /// U+FFFD for every right-to-left character.
    pub fn leftToRight(c: *Canvas, y: usize, x: usize, end: usize) void {
        if (y >= c.rows or x >= c.cols) return;
        for (c.row(y)[x..@min(end, c.cols)]) |*cell| {
            if (cell.grapheme) {
                cell.cp = alone(c.string(cell.cp));
                cell.grapheme = false;
            }
            if (rightToLeft(cell.cp)) cell.cp = 0xfffd;
        }
    }

    /// Give the cells of row `y` from `x` up to `end` that have the
    /// terminal's own background the color `bg`.
    pub fn fillBackground(c: *Canvas, y: usize, x: usize, end: usize, bg: Color) void {
        if (y >= c.rows or x >= c.cols) return;
        for (c.row(y)[x..@min(end, c.cols)]) |*cell| if (cell.style.bg.kind == .default) {
            cell.style.bg = bg;
        };
    }

    /// Mark the cells of row `y` from `x` up to `end` as tuppet's own.
    pub fn setTop(c: *Canvas, y: usize, x: usize, end: usize) void {
        if (y >= c.rows or x >= c.cols) return;
        for (c.row(y)[x..@min(end, c.cols)]) |*cell| cell.top = true;
    }

    /// Blank the cells of row `y` from `x` up to `end`, as tuppet's own.
    pub fn blank(c: *Canvas, y: usize, x: usize, end: usize, style: Style) void {
        if (y >= c.rows or x >= c.cols) return;
        for (c.row(y)[x..@min(end, c.cols)]) |*cell| cell.* = .{ .style = style, .top = true };
    }

    /// Blank any half of a wide character whose other half was
    /// overwritten, so every row stays aligned.
    fn repair(c: *Canvas) void {
        for (0..c.rows) |y| repairRow(c.row(y));
    }

    /// The bytes that bring the person's terminal from the last frame to
    /// this one, inside a synchronized update; empty when nothing changed.
    /// On the normal screen (`marks`), up to `max` of `lines` go into the
    /// terminal's scrollback first, and are dropped from them. The bytes
    /// stay valid until the next call.
    pub fn emit(c: *Canvas, lines: ?*Lines, max: usize) ![]const u8 {
        c.repair();
        c.out.clearRetainingCapacity();
        var aw: std.Io.Writer.Allocating = .fromArrayList(c.gpa, &c.out);
        defer c.out = aw.toArrayList();
        const w = &aw.writer;
        try w.writeAll("\x1b[?2026h");
        const start = aw.written().len;

        // Unknown at first, so the first cell sets both.
        var pen: Pen = .{};
        // A window's worth at a time, up to `max` rows and about
        // `scroll_budget` bytes, so the frame after them is not held up.
        if (c.marks) if (lines) |l| {
            var left = max;
            while (left > 0 and l.len() > 0 and aw.written().len - start < scroll_budget) {
                const before = l.len();
                try c.scrollOut(w, &pen, l, left);
                const done = before - l.len();
                if (done == 0) break;
                left -|= done;
            }
        };
        if (c.marks) for (0..c.rows) |y| if (c.shown_wrap[y] != .off and !c.seamWanted(y)) try c.unmark(w, &pen, y);
        try c.redo.resize(c.gpa, c.cells.len, false);
        c.redo.unsetAll();
        // Top cells last: whatever the person's terminal makes of a
        // session's cell, a top cell written after it lands in place.
        for ([_]bool{ false, true }) |top| {
            for (0..c.rows) |y| {
                const now = c.row(y);
                const was = c.shown[y * c.cols ..][0..c.cols];
                // Blanks at the end of a row are erased, not written as
                // spaces, which a terminal keeps in its scrollback.
                const tail = if (top) c.cols else blankTail(now);
                // The cell after a character that is not plain ASCII is
                // written even when unchanged: the person's terminal may
                // have drawn that character over it.
                var after_wider = false;
                for (now, 0..) |cell, x| {
                    if (x == tail) {
                        if (c.full or after_wider or !std.mem.eql(Cell, now[tail..], was[tail..])) try c.eraseFrom(w, &pen, y, tail);
                        break;
                    }
                    if (cell.width == .tail) continue;
                    if (cell.top != top) {
                        if (after_wider) c.redo.set(y * c.cols + x);
                        after_wider = false;
                        continue;
                    }
                    const changed = cell != was[x] or (cell.width == .wide and now[x + 1] != was[x + 1]);
                    const covered = after_wider or (top and c.redo.isSet(y * c.cols + x));
                    after_wider = false;
                    if (!c.full and !changed and !covered) continue;
                    after_wider = try c.writeCell(w, &pen, y, x, cell);
                }
            }
        }
        @memcpy(c.shown, c.cells);
        if (c.marks) for (0..c.rows) |y| if (c.shown_wrap[y] != .on and c.seamWanted(y)) try c.seam(w, &pen, y, c.row(y)[c.cols - 1], c.row(y + 1)[0]);
        if (pen.link != 0) try w.writeAll("\x1b]8;;\x1b\\");
        if (pen.style) |p| if (p != Style{}) try w.writeAll("\x1b[0m");

        const cur = c.cursor;
        const was = c.shown_cursor;
        const wrote = aw.written().len > start;
        if (c.full or c.shape_due or cur.shape != was.shape) try w.print("\x1b[{d} q", .{if (cur.shape == .default) c.own_shape else @backingInt(cur.shape)});
        c.shape_due = false;
        // Where the terminal's cursor is to be, shown or not.
        const place = cur.at orelse c.park;
        if (place) |p| {
            const there = !wrote and c.term_at != null and c.term_at.?.x == p.x and c.term_at.?.y == p.y;
            if (c.full or !there) try w.print("\x1b[{d};{d}H", .{ p.y + 1, p.x + 1 });
            c.term_at = p;
        } else if (wrote) c.term_at = null;
        if (cur.at != null) {
            if (c.full or was.at == null) try w.writeAll("\x1b[?25h");
        } else if (c.full or was.at != null) try w.writeAll("\x1b[?25l");
        c.shown_cursor = cur;
        c.full = false;

        if (aw.written().len == start) return &.{};
        try w.writeAll("\x1b[?2026l");
        return aw.written();
    }

    /// What the terminal's pen holds while a frame is written.
    const Pen = struct {
        style: ?Style = null,
        link: u21 = 0,
        /// Where the next character lands; null when unknown.
        at: ?Pos = null,
    };

    /// Write `cell` at column `x` of row `y`. Returns whether it is a
    /// narrow character that is not plain ASCII, which the terminal may
    /// draw over the cell after it.
    fn writeCell(c: *Canvas, w: *std.Io.Writer, pen: *Pen, y: usize, x: usize, cell: Cell) !bool {
        // A wide character goes over a blank in its right half, for a
        // terminal that draws it narrow.
        const wide = cell.width == .wide;
        if (wide or pen.at == null or pen.at.?.x != x or pen.at.?.y != y) try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 + @intFromBool(wide) });
        if (pen.style == null or pen.style.? != cell.style) {
            try writeSgr(w, cell.style);
            pen.style = cell.style;
        }
        if (pen.link != cell.link) {
            try w.print("\x1b]8;;{s}\x1b\\", .{c.string(cell.link)});
            pen.link = cell.link;
        }
        if (wide) try w.print(" \x1b[{d};{d}H", .{ y + 1, x + 1 });
        var buf: [4]u8 = undefined;
        try w.writeAll(c.cellText(cell, &buf));
        // After the last column, or after a character the person's
        // terminal may measure otherwise, the cursor is placed anew.
        const ascii = cell.ascii();
        pen.at = if (ascii and x + 1 < c.cols) .{ .x = x + 1, .y = y } else null;
        return !ascii and cell.width == .narrow;
    }

    /// Whether row `y` of the frame is to be marked as wrapped into the
    /// next: the session wrapped it, it is as wide as the window, and the
    /// two cells at the seam are the session's plain ASCII.
    fn seamWanted(c: *Canvas, y: usize) bool {
        if (!c.wrap[y] or y + 1 >= c.rows) return false;
        for (c.row(y)) |cell| if (cell.top) return false;
        const next = c.row(y + 1)[0];
        return !next.top and seamCells(c.row(y)[c.cols - 1], next);
    }

    fn seamCells(last: Cell, next: Cell) bool {
        return last.ascii() and last.link == 0 and next.ascii() and next.link == 0;
    }

    /// Mark row `y` as wrapped: its last cell is written with autowrap
    /// on, so the terminal wraps to the next row itself, where `next`
    /// goes in its first cell.
    fn seam(c: *Canvas, w: *std.Io.Writer, pen: *Pen, y: usize, last: Cell, next: Cell) !void {
        try w.print("\x1b[{d};{d}H", .{ y + 1, c.cols });
        if (pen.link != 0) {
            try w.writeAll("\x1b]8;;\x1b\\");
            pen.link = 0;
        }
        var buf: [4]u8 = undefined;
        if (pen.style == null or pen.style.? != last.style) try writeSgr(w, last.style);
        try w.writeAll("\x1b[?7h");
        try w.writeAll(c.cellText(last, &buf));
        if (next.style != last.style) try writeSgr(w, next.style);
        try w.writeAll(c.cellText(next, &buf));
        try w.writeAll("\x1b[?7l");
        pen.style = next.style;
        pen.at = if (c.cols > 1) .{ .x = 1, .y = y + 1 } else null;
        c.shown[y * c.cols + c.cols - 1] = last;
        c.shown[(y + 1) * c.cols] = next;
        c.shown_wrap[y] = .on;
    }

    /// Erase row `y`, which the terminal marks as wrapped, so it is
    /// written anew without the mark.
    /// Erase row `y` from column `x` to its end, in the default style. A
    /// terminal may forget that the row wraps, so it is marked again.
    fn eraseFrom(c: *Canvas, w: *std.Io.Writer, pen: *Pen, y: usize, x: usize) !void {
        if (c.marks and c.shown_wrap[y] == .on) c.shown_wrap[y] = .unknown;
        if (pen.link != 0) {
            try w.writeAll("\x1b]8;;\x1b\\");
            pen.link = 0;
        }
        if (pen.at == null or pen.at.?.x != x or pen.at.?.y != y) try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
        if (pen.style == null or pen.style.? != Style{}) {
            try w.writeAll("\x1b[0m");
            pen.style = .{};
        }
        try w.writeAll("\x1b[K");
        pen.at = .{ .x = x, .y = y };
    }

    fn unmark(c: *Canvas, w: *std.Io.Writer, pen: *Pen, y: usize) !void {
        if (pen.link != 0) {
            try w.writeAll("\x1b]8;;\x1b\\");
            pen.link = 0;
        }
        try w.print("\x1b[{d};1H\x1b[0m\x1b[2K", .{y + 1});
        pen.style = .{};
        pen.at = .{ .x = 0, .y = y };
        @memset(c.shown[y * c.cols ..][0..c.cols], .{});
        c.shown_wrap[y] = .off;
    }

    /// Write up to `max` of `lines` into the terminal's scrollback: each
    /// over one of the window's top rows, then as many line feeds on the
    /// bottom row push them up and out. The rows below move up with them.
    fn scrollOut(c: *Canvas, w: *std.Io.Writer, pen: *Pen, lines: *Lines, max: usize) !void {
        // Never the bottom row, where a seam would scroll; a window of one
        // row writes its lines there, without seams.
        if (c.rows == 0) return;
        const one = c.rows == 1;
        const room = if (one) 1 else c.rows - 1;
        // A line wider than the window takes several of its rows.
        var i: usize = 0;
        while (i < @min(lines.len(), max, room)) : (i += 1) lines.fit(i, c.cols);
        const n = @min(lines.len(), max, room);
        if (n == 0) return;
        // Marks go first, then the rows, then the seams.
        for (0..n) |y| if (c.shown_wrap[y] != .off and (one or c.lineSeam(lines, y) == null)) try c.unmark(w, pen, y);
        // A row that shows its line already is left alone: after a resize
        // the terminal tells of late, it may show a row it took back from
        // its scrollback there, which the line feeds then put back.
        for (0..n) |y| {
            const line = c.scratch;
            c.lineCells(lines, lines.at(y), line);
            const was = c.shown[y * c.cols ..][0..c.cols];
            if (!c.full and std.mem.eql(Cell, was, line)) continue;
            const tail = blankTail(line);
            for (line[0..tail], 0..) |cell, x| if (cell.width != .tail) {
                _ = try c.writeCell(w, pen, y, x, cell);
            };
            if (tail < c.cols) try c.eraseFrom(w, pen, y, tail);
            @memcpy(was, line);
        }
        if (!one) for (0..n) |y| if (c.shown_wrap[y] != .on) if (c.lineSeam(lines, y)) |next| {
            try c.seam(w, pen, y, c.shown[y * c.cols + c.cols - 1], next);
        };
        if (pen.link != 0) {
            try w.writeAll("\x1b]8;;\x1b\\");
            pen.link = 0;
        }
        // On the terminal's own bottom row, which may be below the
        // window's when it grew; the rows that scroll in take the pen's
        // background.
        try w.writeAll("\x1b[0m" ++ bottom_row);
        pen.style = .{};
        try w.splatByteAll('\n', n);
        pen.at = null;
        const keep = c.rows - n;
        std.mem.copyForwards(Cell, c.shown[0 .. keep * c.cols], c.shown[n * c.cols ..]);
        @memset(c.shown[keep * c.cols ..], .{});
        std.mem.copyForwards(Mark, c.shown_wrap[0..keep], c.shown_wrap[n..]);
        @memset(c.shown_wrap[keep..], .off);
        if (c.keep > 0) for (0..n) |j| c.written.copyLine(lines, lines.at(j));
        lines.drop(n);
        c.trimWritten();
    }

    /// The cells line `line` of `lines` shows in a row of this window:
    /// cut at its width, or a note of rows left out.
    fn lineCells(c: *Canvas, lines: *const Lines, line: *const Lines.Line, out: []Cell) void {
        @memset(out, .{});
        if (line.gap > 0) {
            var buf: [96]u8 = undefined;
            const note = std.fmt.bufPrint(&buf, "tuppet: {d} line{s} left out here", .{ line.gap, if (line.gap == 1) "" else "s" }) catch "tuppet: lines left out here";
            for (note[0..@min(note.len, out.len)], 0..) |b, x| out[x] = .{ .cp = b };
            return;
        }
        const width = @min(out.len, line.cells.len);
        for (line.cells[0..width], 0..) |cell, x| {
            out[x] = c.strings.move(c.gpa, &lines.strings, cell);
            if (!c.links) out[x].link = 0;
        }
        // A wide character cut in half at the edge.
        if (width > 0 and out[width - 1].width == .wide) out[width - 1] = .{ .style = out[width - 1].style };
    }

    /// The first cell of the row after line `i` when line `i` is to be
    /// marked as wrapped into it; null when not.
    fn lineSeam(c: *Canvas, lines: *const Lines, i: usize) ?Cell {
        const line = lines.at(i);
        if (line.gap > 0 or !line.wrap or line.cols != c.cols or c.cols == 0) return null;
        const last = c.strings.move(c.gpa, &lines.strings, line.last());
        const next = c.nextFirst(lines, i) orelse return null;
        return if (seamCells(last, next)) next else null;
    }

    /// The first cell of the row after line `i`: the next line, or the
    /// frame's first row once the lines run out; null when unknown.
    fn nextFirst(c: *Canvas, lines: *const Lines, i: usize) ?Cell {
        if (i + 1 < lines.len()) {
            const next = lines.at(i + 1);
            if (next.gap > 0) return null;
            return c.strings.move(c.gpa, &lines.strings, next.first());
        }
        const first = c.cells[0];
        return if (first.top or !c.top_continues) null else first;
    }
};

/// The first code point of interned text, or U+FFFD where that would
/// join a neighbour on its own, as a prepended mark joins the next cell.
fn alone(s: []const u8) u21 {
    const cp = firstCodepoint(s);
    return if (isolated(&.{cp})) cp else 0xfffd;
}

/// Where the blank cells that end `row` begin; its length when the last
/// cell is not blank.
fn blankTail(row: []const Cell) usize {
    var x = row.len;
    while (x > 0 and row[x - 1] == Cell{}) x -= 1;
    return x;
}

/// Whether `cp` is in a block of right-to-left scripts, or is the
/// right-to-left mark.
fn rightToLeft(cp: u21) bool {
    return switch (cp) {
        0x0590...0x08ff, 0x200f, 0xfb1d...0xfdff, 0xfe70...0xfeff, 0x10800...0x10fff, 0x1e800...0x1efff => true,
        else => false,
    };
}

/// The first code point of interned text, which is valid UTF-8.
fn firstCodepoint(s: []const u8) u21 {
    if (s.len == 0) return ' ';
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0xfffd;
    if (len > s.len) return 0xfffd;
    return std.unicode.utf8Decode(s[0..len]) catch 0xfffd;
}

/// The next code point of `s` from `i.*` that takes a cell, with bytes
/// that are not UTF-8 and characters that may not be written as U+FFFD.
fn nextVisible(s: []const u8, i: *usize) ?u21 {
    while (i.* < s.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(s[i.*]) catch 0;
        const whole = len > 0 and i.* + len <= s.len;
        const raw: u21 = if (whole) std.unicode.utf8Decode(s[i.*..][0..len]) catch 0xfffd else 0xfffd;
        i.* += if (whole) len else 1;
        const cp: u21 = if (printable(raw)) raw else 0xfffd;
        if (vt.unicode.codepointWidth(cp) > 0) return cp;
    }
    return null;
}

fn writeSgr(w: *std.Io.Writer, s: Style) !void {
    try w.writeAll("\x1b[0");
    if (s.bold) try w.writeAll(";1");
    if (s.faint) try w.writeAll(";2");
    if (s.italic) try w.writeAll(";3");
    switch (s.underline) {
        .none => {},
        .single => try w.writeAll(";4"),
        .double => try w.writeAll(";4:2"),
        .curly => try w.writeAll(";4:3"),
        .dotted => try w.writeAll(";4:4"),
        .dashed => try w.writeAll(";4:5"),
    }
    if (s.blink) try w.writeAll(";5");
    if (s.inverse) try w.writeAll(";7");
    if (s.invisible) try w.writeAll(";8");
    if (s.strikethrough) try w.writeAll(";9");
    if (s.overline) try w.writeAll(";53");
    try writeColor(w, s.fg, "38;5;", "38;2;", ";");
    try writeColor(w, s.bg, "48;5;", "48;2;", ";");
    // Colons, so a terminal that does not know SGR 58 skips it whole.
    try writeColor(w, s.underline_color, "58:5:", "58:2::", ":");
    try w.writeAll("m");
}

fn writeColor(w: *std.Io.Writer, c: Color, palette: []const u8, rgb: []const u8, sep: []const u8) !void {
    switch (c.kind) {
        .default => {},
        .palette => try w.print(";{s}{d}", .{ palette, c.value }),
        .rgb => try w.print(";{s}{d}{s}{d}{s}{d}", .{ rgb, c.value >> 16, sep, (c.value >> 8) & 0xff, sep, c.value & 0xff }),
    }
}

fn resolvePalette(t: *const vt.Terminal, i: u8) Color {
    const palette = &t.colors.palette;
    return if (palette.mask.isSet(i)) .rgb(palette.current[i]) else .palette(i);
}

/// A cell colour as the person's terminal is to show it: palette entries
/// and defaults the program changed as their RGB value. `default` is the
/// program's default colour, if it set one.
fn resolveColor(t: *const vt.Terminal, c: vt.Style.Color, default: ?vt.color.RGB) Color {
    return switch (c.value()) {
        .none => if (default) |rgb| .rgb(rgb) else .{},
        .palette => |i| resolvePalette(t, i),
        .rgb => |rgb| .rgb(rgb),
    };
}

/// `bg` is a background the cell itself carries, as a blank left by an
/// erase does.
fn resolveStyle(t: *const vt.Terminal, s: vt.Style, bg: ?Color, reverse: bool) Style {
    const f = s.flags;
    var out: Style = .{
        .fg = resolveColor(t, s.fg_color, t.colors.foreground.override),
        .bg = bg orelse resolveColor(t, s.bg_color, t.colors.background.override),
        .underline_color = resolveColor(t, s.underline_color, null),
        .underline = switch (f.underline) {
            .none => .none,
            .single => .single,
            .double => .double,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        },
        .bold = f.bold,
        .faint = f.faint,
        .italic = f.italic,
        .blink = f.blink,
        .inverse = f.inverse,
        .invisible = f.invisible,
        .strikethrough = f.strikethrough,
        .overline = f.overline,
    };
    if (reverse) {
        // Reverse video (DECSCNM) swaps the default colours only. The
        // person's defaults have no SGR of their own, so the cell is
        // written inverted with its colours swapped: a default foreground
        // then shows the default background, and the reverse.
        const fg: Color = if (s.fg_color.value() == .none) (if (t.colors.background.override) |rgb| .rgb(rgb) else .{}) else out.fg;
        const back: Color = if (bg == null and s.bg_color.value() == .none) (if (t.colors.foreground.override) |rgb| .rgb(rgb) else .{}) else out.bg;
        out.fg = back;
        out.bg = fg;
        out.inverse = !f.inverse;
    }
    return out;
}

/// The program's cursor shape, or the person's own while the program
/// keeps the default.
fn cursorShape(t: *const vt.Terminal) Shape {
    const blink = t.modes.get(.cursor_blinking);
    if (t.cursor.is_default and blink == (t.cursor.default_blink orelse true)) return .default;
    return switch (t.screens.active.cursor.cursor_style) {
        .block, .block_hollow => if (blink) .blinking_block else .steady_block,
        .underline => if (blink) .blinking_underline else .steady_underline,
        .bar => if (blink) .blinking_bar else .steady_bar,
    };
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

const TestTerm = struct {
    term: vt.Terminal,
    stream: vt.TerminalStream,

    fn init(t: *TestTerm, cols: u16, rows: u16) !void {
        t.term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = 0 });
        var handler = t.term.vtHandler();
        handler.effects = .readonly;
        t.stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = testing.allocator });
    }

    fn deinit(t: *TestTerm) void {
        t.stream.deinit();
        t.term.deinit(testing.allocator);
    }
};

/// Paint `src` into `canvas`, emit, feed the bytes to `dst`, and check
/// that `dst` painted the same way shows the same cells.
fn roundTrip(canvas: *Canvas, src: *TestTerm, dst: *TestTerm) ![]const u8 {
    canvas.clear();
    canvas.cursor = canvas.drawScreen(&src.term, .{ .x = 0, .y = 0, .cols = canvas.cols, .rows = canvas.rows });
    const bytes = try canvas.emit(null, 0);
    dst.stream.nextSlice(bytes);

    var again = Canvas.init(testing.allocator);
    defer again.deinit();
    try again.resize(canvas.cols, canvas.rows);
    const cursor = again.drawScreen(&dst.term, .{ .x = 0, .y = 0, .cols = canvas.cols, .rows = canvas.rows });
    try testing.expectEqual(canvas.cursor.at, cursor.at);
    try testing.expectEqual(canvas.cursor.shape, cursor.shape);
    for (canvas.cells, again.cells, 0..) |want, got, i| {
        errdefer std.debug.print("cell {d},{d}\n", .{ i % canvas.cols, i / canvas.cols });
        var b1: [4]u8 = undefined;
        var b2: [4]u8 = undefined;
        try testing.expectEqualStrings(canvas.cellText(want, &b1), again.cellText(got, &b2));
        try testing.expectEqualStrings(canvas.string(want.link), again.string(got.link));
        try testing.expectEqual(want.width, got.width);
        try testing.expectEqual(want.style, got.style);
    }
    return bytes;
}

test "a painted screen comes out the same in a second terminal, also after a change" {
    var src: TestTerm = undefined;
    try src.init(20, 6);
    defer src.deinit();
    var dst: TestTerm = undefined;
    // The window is larger than the session.
    try dst.init(24, 8);
    defer dst.deinit();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try canvas.resize(24, 8);

    // The program changes palette entry 1 and the default foreground,
    // leaves entry 2 and the default background alone.
    src.stream.nextSlice("\x1b]4;1;rgb:12/34/56\x1b\\\x1b]10;rgb:aa/bb/cc\x1b\\");
    src.stream.nextSlice("\x1b[31mR\x1b[32mG\x1b[39mD\x1b[0m ");
    src.stream.nextSlice("\x1b[1;3;4:3;58:2::1:2:3;53mcurly\x1b[0m \x1b[4:2;9;58:5:1mdbl\x1b[0m");
    // A background left by an erase, on blank cells only.
    src.stream.nextSlice("\r\n\x1b[44m\x1b[K\x1b[0m");
    src.stream.nextSlice("\r\n\xe4\xb8\x80e\xcc\x81\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb\xe2\x9d\xa4\xef\xb8\x8f");
    src.stream.nextSlice("\r\n\x1b]8;;http://x.test/a\x1b\\link\x1b]8;;\x1b\\ \x1b[2;5;7;8mhid\x1b[0m");
    src.stream.nextSlice("\x1b[6 q\x1b[5;3H");

    _ = try roundTrip(&canvas, &src, &dst);
    const style = canvas.row(0)[4].style;
    try testing.expect(style.bold and style.italic and style.overline and style.underline == .curly);
    try testing.expectEqual(Color.rgb(.{ .r = 1, .g = 2, .b = 3 }), style.underline_color);
    try testing.expectEqual(Color.rgb(.{ .r = 0x12, .g = 0x34, .b = 0x56 }), canvas.row(0)[0].style.fg);
    try testing.expectEqual(Color.palette(2), canvas.row(0)[1].style.fg);
    try testing.expectEqual(Color.rgb(.{ .r = 0xaa, .g = 0xbb, .b = 0xcc }), canvas.row(0)[2].style.fg);
    try testing.expectEqual(Color{}, canvas.row(0)[2].style.bg);
    try testing.expectEqual(Color.palette(4), canvas.row(1)[5].style.bg);
    try testing.expect(canvas.row(2)[0].width == .wide and canvas.row(2)[2].grapheme and canvas.row(2)[3].grapheme);
    try testing.expectEqual(Shape.steady_bar, canvas.cursor.shape);
    try testing.expectEqual(Pos{ .x = 2, .y = 4 }, canvas.cursor.at.?);
    try testing.expectEqual(Shape.steady_bar, cursorShape(&dst.term));

    // Only the changed cells, and the cursor, are written again.
    src.stream.nextSlice("\x1b[1;2H\x1b[33mY\x1b[?25l\x1b[0 q");
    const second = try roundTrip(&canvas, &src, &dst);
    try testing.expectEqualStrings("\x1b[?2026h\x1b[1;2H\x1b[0;38;5;3mY\x1b[0m\x1b[0 q\x1b[?25l\x1b[?2026l", second);
    try testing.expectEqual(Shape.default, cursorShape(&dst.term));

    // Reverse video swaps the default colours and keeps the others.
    src.stream.nextSlice("\x1b[?5h");
    _ = try roundTrip(&canvas, &src, &dst);
    const red = canvas.row(0)[0].style;
    try testing.expect(red.inverse and red.bg == Color.rgb(.{ .r = 0x12, .g = 0x34, .b = 0x56 }) and red.fg == Color.rgb(.{ .r = 0xaa, .g = 0xbb, .b = 0xcc }));
    const blue = canvas.row(1)[5].style;
    try testing.expect(blue.inverse and blue.fg == Color.palette(4) and blue.bg == Color{});

    try testing.expectEqualStrings("", try canvas.emit(null, 0));
}

test "tuppet's cells stay in their columns on a terminal that measures and joins characters otherwise" {
    var src: TestTerm = undefined;
    try src.init(6, 1);
    defer src.deinit();
    var dst: TestTerm = undefined;
    try dst.init(6, 1);
    defer dst.deinit();
    dst.term.modes.set(.grapheme_cluster, true);
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try canvas.resize(6, 1);

    // A prepended mark before a border cell and a spacing mark after it,
    // then an emoji that the second terminal draws two wide.
    for ([_][]const u8{ "\u{0600}b\u{0903}", "\r\u{2764}\u{fe0f}" }) |out| {
        src.stream.nextSlice(out);
        canvas.clear();
        _ = canvas.drawScreen(&src.term, .{ .x = 0, .y = 0, .cols = 6, .rows = 1 });
        _ = canvas.text(0, 1, 1, "\u{2502}", .{});
        dst.stream.nextSlice(try canvas.emit(null, 0));
        const cell = dst.term.screens.active.pages.pin(.{ .active = .{} }).?.cells(.all)[1];
        try testing.expectEqual(@as(u21, 0x2502), cell.codepoint());
        try testing.expect(!cell.hasGrapheme() and cell.wide == .narrow);
    }
}

test "emitted bytes hold only cursor moves, line erases, SGR, links, chosen modes, and printable text" {
    var src: TestTerm = undefined;
    try src.init(12, 3);
    defer src.deinit();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try canvas.resize(12, 4);

    const long: [max_link_len]u8 = @splat('a');
    src.stream.nextSlice("a\xe2\x80\x8f\xd8\x9c\x1b]8;;http://x.test/");
    src.stream.nextSlice(&long);
    src.stream.nextSlice("\x1b\\long\x1b]8;;\x1b\\");
    src.stream.nextSlice("\x1b]8;;http://\xc3\xa4.test\x1b\\uni\x1b]8;;\x1b\\");
    canvas.clear();
    canvas.cursor = canvas.drawScreen(&src.term, .{ .x = 0, .y = 0, .cols = 12, .rows = 4 });
    _ = canvas.text(3, 0, 12, "t\x1b[2J\xc2\x9b\xe2\x80\xae\x07!", .{});
    canvas.row(2)[0] = .{ .cp = 0x1b };
    canvas.row(2)[1] = .{ .cp = 0x9b };
    canvas.row(2)[2] = .{ .cp = 0x202e };
    const bytes = try canvas.emit(null, 0);

    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            try testing.expect(i + 1 < bytes.len);
            if (bytes[i + 1] == ']') {
                try testing.expect(std.mem.startsWith(u8, bytes[i..], "\x1b]8;;"));
                const end = std.mem.indexOfPos(u8, bytes, i, "\x1b\\").?;
                const uri = bytes[i + 5 .. end];
                try testing.expect(uri.len <= max_link_len);
                for (uri) |b| try testing.expect(b >= 0x20 and b < 0x7f);
                i = end + 2;
                continue;
            }
            try testing.expectEqual(@as(u8, '['), bytes[i + 1]);
            var j = i + 2;
            while (j < bytes.len and (std.ascii.isDigit(bytes[j]) or bytes[j] == ';' or bytes[j] == ':' or bytes[j] == '?' or bytes[j] == ' ')) j += 1;
            const seq = bytes[i..j];
            switch (bytes[j]) {
                'H', 'm' => try testing.expect(std.mem.indexOfScalar(u8, seq, '?') == null),
                'q' => try testing.expect(seq[seq.len - 1] == ' '),
                'K' => try testing.expectEqualStrings("\x1b[", seq),
                'h', 'l' => try testing.expect(std.mem.eql(u8, seq, "\x1b[?2026") or std.mem.eql(u8, seq, "\x1b[?25")),
                else => return error.TestUnexpectedSequence,
            }
            i = j + 1;
            continue;
        }
        const len = try std.unicode.utf8ByteSequenceLength(bytes[i]);
        const cp = try std.unicode.utf8Decode(bytes[i..][0..len]);
        try testing.expect(cp >= 0x20 and cp != 0x7f and !(cp >= 0x80 and cp <= 0x9f));
        try testing.expect(cp != 0x061c and cp != 0x200e and cp != 0x200f and !(cp >= 0x202a and cp <= 0x202e) and !(cp >= 0x2066 and cp <= 0x2069));
        i += len;
    }
    // The long link's text is painted, without the link.
    try testing.expect(std.mem.indexOf(u8, bytes, "long") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b]8;;http") == null);
}

test "box cells land in their columns and are written last, whatever the session's cells hold" {
    var src: TestTerm = undefined;
    try src.init(24, 4);
    defer src.deinit();
    var dst: TestTerm = undefined;
    try dst.init(24, 4);
    defer dst.deinit();
    // The person's terminal clusters graphemes and measures emoji otherwise.
    dst.term.modes.set(.grapheme_cluster, true);
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try canvas.resize(24, 4);

    // Prepended and spacing marks, combining marks, joined and
    // variation-selected emoji, wide and right-to-left characters.
    const pieces = [_][]const u8{ "a", "\u{0600}", "\u{0903}", "e\u{0301}", "\u{2764}\u{fe0f}", "\u{1f469}\u{200d}\u{1f4bb}", "\u{4e00}", "\u{05d0}", "\u{fe0f}", " ", "\u{200d}", "\u{1f1e9}\u{1f1ea}" };
    // A box from column 6 to 13: a border and a title.
    const box = "\u{2503}t\u{00e9}tle\u{2502}\u{2503}";
    var prng: std.Random.DefaultPrng = .init(0x7061696e74);
    const random = prng.random();
    for (0..300) |_| {
        src.stream.nextSlice("\x1b[H");
        for (0..4) |r| {
            if (r > 0) src.stream.nextSlice("\r\n");
            for (0..10) |_| src.stream.nextSlice(pieces[random.uintLessThan(usize, pieces.len)]);
            src.stream.nextSlice("\x1b[K");
        }
        canvas.clear();
        _ = canvas.drawScreen(&src.term, .{ .x = 0, .y = 0, .cols = 24, .rows = 4 });
        const row = random.uintLessThan(usize, 4);
        const end = canvas.text(row, 6, 8, box, .{ .bold = true });
        canvas.setTop(row, 6, end);
        const bytes = try canvas.emit(null, 0);
        dst.stream.nextSlice(bytes);

        const cells = dst.term.screens.active.pages.pin(.{ .active = .{ .y = @intCast(row) } }).?.cells(.all);
        var i: usize = 0;
        var x: usize = 6;
        while (nextVisible(box, &i)) |cp| : (x += 1) {
            errdefer std.debug.print("column {d} of row {d}\n", .{ x, row });
            try testing.expectEqual(cp, cells[x].codepoint());
            try testing.expect(!cells[x].hasGrapheme() and cells[x].wide == .narrow);
        }
        // Once a box cell is written, only box cells follow.
        var in_box = false;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, at, "\x1b[")) |esc| {
            at = esc + 2;
            const semi = std.mem.indexOfScalarPos(u8, bytes, at, ';') orelse continue;
            const h = std.mem.indexOfScalarPos(u8, bytes, semi, 'H') orelse continue;
            const y = std.fmt.parseInt(usize, bytes[at..semi], 10) catch continue;
            const col = std.fmt.parseInt(usize, bytes[semi + 1 .. h], 10) catch continue;
            const top = canvas.row(y - 1)[col - 1].top;
            if (in_box) try testing.expect(top);
            in_box = in_box or top;
        }
    }
}

test "the blanks that end a row are erased, not written as spaces a terminal would keep" {
    var dst: TestTerm = undefined;
    try dst.init(10, 2);
    defer dst.deinit();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try canvas.resize(10, 2);
    _ = canvas.text(0, 0, 10, "ab", .{});
    _ = canvas.text(1, 0, 10, "c d", .{});
    dst.stream.nextSlice(try canvas.emit(null, 0));
    for (0..2) |y| {
        const cells = dst.term.screens.active.pages.pin(.{ .active = .{ .y = @intCast(y) } }).?.cells(.all);
        for (cells[3..]) |cell| try testing.expectEqual(@as(u21, 0), cell.codepoint());
    }
    const middle = dst.term.screens.active.pages.pin(.{ .active = .{ .y = 1 } }).?.cells(.all)[1];
    try testing.expectEqual(@as(u21, ' '), middle.codepoint());
}

test "a faint copy keeps no character that would join the next cell" {
    var src = Canvas.init(testing.allocator);
    defer src.deinit();
    try src.resize(2, 1);
    src.row(0)[0] = .{ .cp = src.intern("\u{0600}1").?, .grapheme = true };
    src.row(0)[1] = .{ .cp = '2' };
    var dst = Canvas.init(testing.allocator);
    defer dst.deinit();
    try dst.resize(2, 1);
    dst.blit(&src, 0, 0, .faded);
    try testing.expectEqual(@as(u21, 0xfffd), dst.row(0)[0].cp);
    try testing.expectEqual(@as(u21, '2'), dst.row(0)[1].cp);
}

test "beside a box, a row keeps no right-to-left character and one code point per cell" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.resize(4, 1);
    c.row(0)[0] = .{ .cp = '\u{05d0}' };
    c.row(0)[1] = .{ .cp = c.intern("e\u{0301}").?, .grapheme = true };
    c.row(0)[2] = .{ .cp = '\u{0627}' };
    c.row(0)[3] = .{ .cp = 'a' };
    c.leftToRight(0, 0, 4);
    for ([_]u21{ 0xfffd, 'e', 0xfffd, 'a' }, c.row(0)) |want, cell| {
        try testing.expectEqual(want, cell.cp);
        try testing.expect(!cell.grapheme);
    }
}

/// The rows of `t` from the top of its history, joined where the
/// terminal marked them wrapped.
fn historyText(t: *const vt.Terminal, out: *std.ArrayList(u8)) !void {
    const pages = &t.screens.active.pages;
    var y: u32 = 0;
    while (pages.pin(.{ .screen = .{ .y = y } })) |pin| : (y += 1) {
        const row = out.items.len;
        for (pin.cells(.all)) |cell| try out.append(testing.allocator, if (cell.codepoint() == 0) ' ' else @intCast(cell.codepoint()));
        while (out.items.len > row and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        if (!pin.rowAndCell().row.wrap) try out.append(testing.allocator, '\n');
    }
}

fn heldLine(lines: *Lines, text: []const u8, cols: u16, wrap: bool, cont: bool) !void {
    const cells = try testing.allocator.alloc(Cell, text.len);
    for (cells, text) |*cell, b| cell.* = .{ .cp = b };
    lines.append(.{ .cells = cells, .cols = cols, .wrap = wrap, .cont = cont });
}

/// Emit until every held line is written, feeding `dst`.
fn drain(canvas: *Canvas, lines: *Lines, dst: *vt.TerminalStream) !void {
    for (0..10) |_| {
        canvas.clear();
        dst.nextSlice(try canvas.emit(lines, std.math.maxInt(usize)));
        if (lines.len() == 0) return;
    }
    return error.TestUnexpectedResult;
}

test "a held line keeps no half of a wide character its width cannot show" {
    var lines = Lines.init(testing.allocator);
    defer lines.deinit();
    const cells = try testing.allocator.alloc(Cell, 3);
    cells[0] = .{ .cp = 0x4e16, .width = .wide };
    cells[1] = .{ .width = .tail };
    cells[2] = .{ .cp = 'a' };
    lines.append(.{ .cells = cells, .cols = 3, .wrap = false, .cont = false });
    lines.fit(0, 1);
    try testing.expectEqual(@as(usize, 3), lines.len());
    for (0..lines.len()) |i| for (lines.at(i).cells) |cell| try testing.expectEqual(Cell.Width.narrow, cell.width);
}

test "held lines reach the scrollback once, joined only where they continue each other" {
    for ([_]u16{ 3, 1 }) |rows| {
        var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 4, .rows = rows, .max_scrollback_bytes = 1 << 20 });
        defer term.deinit(testing.allocator);
        var handler = term.vtHandler();
        handler.effects = .readonly;
        var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = testing.allocator });
        defer stream.deinit();
        var canvas = Canvas.init(testing.allocator);
        defer canvas.deinit();
        try canvas.resize(4, rows);
        canvas.setMarks(true, true);
        var lines = Lines.init(testing.allocator);
        defer lines.deinit();
        // Held at a width of 8: wider than the window, and wrapped.
        try heldLine(&lines, "abcdefgh", 8, true, false);
        try heldLine(&lines, "ij", 8, false, true);
        // A wrapped line that a reset cut off from the one after it.
        try heldLine(&lines, "wxyz", 4, true, false);
        try heldLine(&lines, "new", 4, false, false);
        try drain(&canvas, &lines, &stream);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        try historyText(&term, &got);
        // A window of one row writes no seams: its lines end hard.
        const want = if (rows > 1) "abcdefghij\nwxyz\nnew\n" else "abcd\nefgh\nij\nwxyz\nnew\n";
        try testing.expect(std.mem.startsWith(u8, got.items, want));
    }
}

test "rows a growing terminal took back from its scrollback survive a frame painted for its old size" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 10, .rows = 4, .max_scrollback_bytes = 1 << 20 });
    defer term.deinit(testing.allocator);
    var handler = term.vtHandler();
    handler.effects = .readonly;
    var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = testing.allocator });
    defer stream.deinit();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try canvas.resize(10, 4);
    canvas.setMarks(true, true);
    var lines = Lines.init(testing.allocator);
    defer lines.deinit();
    const paintFrom = struct {
        /// The session's rows from L`top` down, its cursor on the bottom row.
        fn paintFrom(c: *Canvas, top: usize) void {
            c.clear();
            for (0..c.rows) |y| {
                var buf: [8]u8 = undefined;
                _ = c.text(y, 0, c.cols, std.fmt.bufPrint(&buf, "L{d}", .{top + y}) catch unreachable, .{});
            }
            c.park = .{ .x = 0, .y = c.rows - 1 };
        }
    }.paintFrom;

    // L1 to L4 in the scrollback, L5 to L8 on the screen.
    for ([_][]const u8{ "L1", "L2", "L3", "L4" }) |t| try heldLine(&lines, t, 10, false, false);
    paintFrom(&canvas, 5);
    stream.nextSlice(try canvas.emit(&lines, std.math.maxInt(usize)));
    try testing.expectEqual(@as(usize, 0), lines.len());

    // L5 leaves the session's screen in a frame that the terminal applies
    // after it grew by two rows and took L3 and L4 back from its scrollback.
    try heldLine(&lines, "L5", 10, false, false);
    paintFrom(&canvas, 6);
    const late = try canvas.emit(&lines, std.math.maxInt(usize));
    try term.resize(testing.allocator, .{ .cols = 10, .rows = 6 });
    stream.nextSlice(late);

    // The window's new size arrives: what the terminal may have taken back
    // goes back, and the session, grown too, shows L4 to L9.
    try canvas.resize(10, 6);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try canvas.pushUp(&aw.writer, 2);
    stream.nextSlice(aw.written());
    paintFrom(&canvas, 4);
    stream.nextSlice(try canvas.emit(&lines, std.math.maxInt(usize)));

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try historyText(&term, &got);
    var at: usize = 0;
    for (1..10) |i| {
        var buf: [8]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "L{d}\n", .{i});
        errdefer std.debug.print("L{d} missing or out of order in:\n{s}", .{ i, got.items });
        at = std.mem.indexOfPos(u8, got.items, at, want) orelse return error.TestUnexpectedResult;
    }
}

test "the last lines written into the scrollback can be written again before the held ones" {
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try canvas.resize(10, 3);
    canvas.setMarks(true, true);
    canvas.keep = 2;
    var lines = Lines.init(testing.allocator);
    defer lines.deinit();
    for ([_][]const u8{ "a", "b", "c" }) |t| try heldLine(&lines, t, 10, false, false);
    _ = try canvas.emit(&lines, std.math.maxInt(usize));
    try testing.expectEqual(@as(usize, 0), lines.len());

    try heldLine(&lines, "d", 10, false, false);
    // More than were kept: only the last two come again.
    canvas.writeAgain(5, &lines);
    try testing.expectEqual(@as(usize, 3), lines.len());
    for ([_]u21{ 'b', 'c', 'd' }, 0..) |want, i| try testing.expectEqual(want, lines.at(i).cells[0].cp);
}
