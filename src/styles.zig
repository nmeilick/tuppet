//! The styles of a plain view: the style that covers the most cells of the
//! screen, and runs of the cells whose style differs from it, so a client
//! sees colors, emphasis, and links next to the text.

const std = @import("std");
const vt = @import("vt");

const Page = vt.Page;
const Cell = vt.Cell;
const Pin = vt.Pin;

/// A link is cut to at most this many bytes.
pub const max_link_len = 512;

pub const Color = union(enum) {
    default,
    /// An index into the 256-color palette.
    palette: u8,
    rgb: vt.color.RGB,

    fn of(c: vt.Style.Color) Color {
        return switch (c) {
            .none => .default,
            .palette => |i| .{ .palette = i },
            .rgb => |rgb| .{ .rgb = rgb },
        };
    }

    /// `default`, a palette index, or "#rrggbb".
    pub fn jsonStringify(c: Color, jw: anytype) !void {
        switch (c) {
            .default => try jw.write("default"),
            .palette => |i| try jw.write(i),
            .rgb => |rgb| {
                var buf: [7]u8 = undefined;
                try jw.write(std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }) catch unreachable);
            },
        }
    }

    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Color {
        return jsonParseFromValue(a, try std.json.innerParse(std.json.Value, a, source, options), options);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !Color {
        switch (value) {
            .integer => |n| return .{ .palette = std.math.cast(u8, n) orelse return error.InvalidNumber },
            .string => |s| {
                if (std.mem.eql(u8, s, "default")) return .default;
                if (s.len != 7 or s[0] != '#') return error.InvalidCharacter;
                const v = try std.fmt.parseInt(u24, s[1..], 16);
                return .{ .rgb = .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) } };
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn format(c: Color, w: *std.Io.Writer) !void {
        switch (c) {
            .default => try w.writeAll("default"),
            .palette => |i| try w.print("{d}", .{i}),
            .rgb => |rgb| try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }),
        }
    }
};

pub const Underline = enum { none, single, double, curly, dotted, dashed };

/// Everything a cell's style shows, and its link.
pub const Attrs = struct {
    fg: Color = .default,
    bg: Color = .default,
    underline: Underline = .none,
    underline_color: Color = .default,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    /// The OSC 8 link's URI, cut to max_link_len bytes.
    link: ?[]const u8 = null,

    pub fn eql(a: Attrs, b: Attrs) bool {
        inline for (@typeInfo(Attrs).@"struct".field_names) |name| {
            const x = @field(a, name);
            const y = @field(b, name);
            const same = switch (@TypeOf(x)) {
                ?[]const u8 => if (x) |s| (if (y) |t| std.mem.eql(u8, s, t) else false) else y == null,
                else => std.meta.eql(x, y),
            };
            if (!same) return false;
        }
        return true;
    }

    fn hash(a: Attrs) u64 {
        var h = std.hash.Wyhash.init(0);
        inline for (@typeInfo(Attrs).@"struct".field_names) |name| {
            const x = @field(a, name);
            switch (@TypeOf(x)) {
                ?[]const u8 => if (x) |s| {
                    h.update("L");
                    h.update(s);
                },
                Color => switch (x) {
                    .default => h.update("d"),
                    .palette => |i| h.update(&.{ 'p', i }),
                    .rgb => |rgb| h.update(&.{ 'r', rgb.r, rgb.g, rgb.b }),
                },
                bool => h.update(&.{@intFromBool(x)}),
                else => h.update(&.{@backingInt(x)}),
            }
        }
        return h.final();
    }
};

const AttrsContext = struct {
    pub fn hash(_: AttrsContext, a: Attrs) u64 {
        return a.hash();
    }
    pub fn eql(_: AttrsContext, a: Attrs, b: Attrs) bool {
        return a.eql(b);
    }
};

/// Cells of one row that share a style other than the base.
pub const Run = struct {
    /// Counted as `view` with `since` counts rows: the top row of the
    /// screen is 1, the history row above it 0.
    row: i64,
    /// The first cell, counting from 1, and how many cells it takes.
    col: u32,
    cols: u32,
    text: []const u8,
    attrs: Attrs,
};

pub const Styles = struct {
    base: Attrs = .{},
    runs: []const Run = &.{},
    /// Runs of rows above the last ones were left out to fit the reply.
    truncated: bool = false,
};

/// A row a view shows: where it is, and its number as runs count rows.
pub const ViewRow = struct { pin: Pin, row: i64 };

/// The base style of the active screen of `t` and the runs of `rows`, in
/// `gpa`; runs of the rows at the top are left out once their JSON would
/// take more than `budget` bytes. terminal_mutex must be held.
pub fn collect(gpa: std.mem.Allocator, t: *vt.Terminal, rows: []const ViewRow, budget: usize) !Styles {
    const base = try baseOf(gpa, t);
    var out: std.ArrayList(Run) = .empty;
    var size: usize = 0;
    var truncated = false;
    // From the bottom up, whole rows at a time, then put in order.
    var row_runs: std.ArrayList(Run) = .empty;
    defer row_runs.deinit(gpa);
    var i = rows.len;
    while (i > 0) {
        i -= 1;
        row_runs.clearRetainingCapacity();
        try rowRuns(gpa, rows[i], base, &row_runs);
        var row_size: usize = 0;
        for (row_runs.items) |run| row_size += jsonSize(run) + 1;
        if (size + row_size > budget) {
            truncated = true;
            break;
        }
        size += row_size;
        var j = row_runs.items.len;
        while (j > 0) {
            j -= 1;
            try out.append(gpa, row_runs.items[j]);
        }
    }
    std.mem.reverse(Run, out.items);
    return .{ .base = try dupeAttrs(gpa, base), .runs = out.items, .truncated = truncated };
}

fn jsonSize(run: Run) usize {
    var buf: [256]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&buf);
    std.json.Stringify.value(run, .{}, &counter.writer) catch return std.math.maxInt(u32);
    return @intCast(counter.fullCount());
}

/// The style that covers the most cells of the active screen, blanks
/// included; a tie goes to the default style. Its link aliases a page.
fn baseOf(gpa: std.mem.Allocator, t: *vt.Terminal) !Attrs {
    var counts: std.HashMapUnmanaged(Attrs, u64, AttrsContext, 80) = .empty;
    defer counts.deinit(gpa);
    const pages = &t.screens.active.pages;
    var it = pages.getTopLeft(.active).rowIterator(.right_down, null);
    for (0..pages.rows) |_| {
        const p = it.next() orelse break;
        const page = p.node.page();
        var prev: Attrs = .{};
        for (p.cells(.all)) |*cell| {
            const attrs = if (cell.wide == .spacer_tail) prev else attrsOf(page, cell);
            prev = attrs;
            const entry = try counts.getOrPut(gpa, attrs);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }
    var best: Attrs = .{};
    var most: u64 = counts.get(.{}) orelse 0;
    var each = counts.iterator();
    while (each.next()) |entry| {
        if (entry.value_ptr.* > most) {
            most = entry.value_ptr.*;
            best = entry.key_ptr.*;
        }
    }
    return best;
}

/// The runs of one row; their text and links are in `gpa`.
fn rowRuns(gpa: std.mem.Allocator, row: ViewRow, base: Attrs, out: *std.ArrayList(Run)) !void {
    const page = row.pin.node.page();
    const cells = row.pin.cells(.all);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var x: usize = 0;
    while (x < cells.len) {
        const attrs = attrsOf(page, &cells[x]);
        var end = x + 1;
        // A wide character's spacer belongs to it.
        while (end < cells.len and (cells[end].wide == .spacer_tail or attrsOf(page, &cells[end]).eql(attrs))) end += 1;
        if (!attrs.eql(base)) {
            text.clearRetainingCapacity();
            for (cells[x..end]) |*cell| try appendCell(gpa, &text, page, cell);
            try out.append(gpa, .{
                .row = row.row,
                .col = @intCast(x + 1),
                .cols = @intCast(end - x),
                .text = try gpa.dupe(u8, text.items),
                .attrs = try dupeAttrs(gpa, attrs),
            });
        }
        x = end;
    }
}

fn appendCell(gpa: std.mem.Allocator, out: *std.ArrayList(u8), page: *const Page, cell: *const Cell) !void {
    if (cell.wide == .spacer_tail or cell.wide == .spacer_head) return;
    if (!cell.hasText()) return out.append(gpa, ' ');
    var buf: [4]u8 = undefined;
    const encode = struct {
        fn f(b: *[4]u8, cp: u21) []const u8 {
            const n = std.unicode.utf8Encode(cp, b) catch std.unicode.utf8Encode(std.unicode.replacement_character, b) catch unreachable;
            return b[0..n];
        }
    }.f;
    try out.appendSlice(gpa, encode(&buf, cell.codepoint()));
    if (cell.hasGrapheme()) if (page.lookupGrapheme(cell)) |cps| for (cps) |cp| try out.appendSlice(gpa, encode(&buf, cp));
}

/// The style of a cell; its link aliases the page.
fn attrsOf(page: *const Page, cell: *const Cell) Attrs {
    var a: Attrs = .{};
    if (cell.hasStyling()) {
        const style = page.styles.get(page.memory, cell.style_id);
        a.fg = .of(style.fg_color);
        a.bg = .of(style.bg_color);
        a.underline_color = .of(style.underline_color);
        a.underline = switch (style.flags.underline) {
            .none => .none,
            .single => .single,
            .double => .double,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        };
        a.bold = style.flags.bold;
        a.faint = style.flags.faint;
        a.italic = style.flags.italic;
        a.blink = style.flags.blink;
        a.inverse = style.flags.inverse;
        a.invisible = style.flags.invisible;
        a.strikethrough = style.flags.strikethrough;
        a.overline = style.flags.overline;
    }
    // A cell without text that only has a background keeps it here.
    switch (cell.content_tag) {
        .bg_color_palette => a.bg = .{ .palette = cell.content.color_palette.data },
        .bg_color_rgb => a.bg = .{ .rgb = .{ .r = cell.content.color_rgb.r, .g = cell.content.color_rgb.g, .b = cell.content.color_rgb.b } },
        else => {},
    }
    if (cell.hyperlink) if (page.lookupHyperlink(cell)) |id| {
        const uri = page.hyperlink_set.get(page.memory, id).uri.slice(page.memory);
        a.link = cut(uri, max_link_len);
    };
    return a;
}

fn dupeAttrs(gpa: std.mem.Allocator, a: Attrs) !Attrs {
    var out = a;
    if (a.link) |link| out.link = try gpa.dupe(u8, link);
    return out;
}

fn cut(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

// ---- tests ------------------------------------------------------------

test "the base covers the most cells, and runs hold every other cell, blanks and wide characters included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer term.deinit(std.testing.allocator);
    var handler = term.vtHandler();
    handler.effects = .readonly;
    var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = std.testing.allocator });
    defer stream.deinit();
    // A blue background on most cells; bold red text, an inverse blank,
    // a green wide character, and a link.
    stream.nextSlice("\x1b[44m\x1b[2J\x1b[H\x1b[1;31mab\x1b[22;39m \x1b[7m \x1b[27;32m\xe4\xb8\x80\x1b[39m\x1b]8;;http://x\x1b\\L\x1b]8;;\x1b\\");
    stream.nextSlice("\r\n\x1b[0mz");
    const pages = &term.screens.active.pages;
    const top = pages.getTopLeft(.active);
    const rows = [_]ViewRow{ .{ .pin = top, .row = 1 }, .{ .pin = top.down(1).?, .row = 2 } };
    const got = try collect(a, &term, &rows, 1 << 20);
    try std.testing.expect(got.base.eql(.{ .bg = .{ .palette = 4 } }));
    try std.testing.expectEqual(@as(usize, 5), got.runs.len);
    const bold = got.runs[0];
    try std.testing.expectEqualStrings("ab", bold.text);
    try std.testing.expectEqual(@as(u32, 1), bold.col);
    try std.testing.expect(bold.attrs.bold and std.meta.eql(bold.attrs.fg, Color{ .palette = 1 }));
    try std.testing.expect(got.runs[1].attrs.inverse and got.runs[1].col == 4 and got.runs[1].cols == 1);
    // A wide character is one run of both its cells.
    try std.testing.expectEqualStrings("\xe4\xb8\x80", got.runs[2].text);
    try std.testing.expectEqual(@as(u32, 5), got.runs[2].col);
    try std.testing.expectEqual(@as(u32, 2), got.runs[2].cols);
    try std.testing.expectEqualStrings("http://x", got.runs[3].attrs.link.?);
    // The default style is a value of its own when the base is not.
    try std.testing.expectEqual(@as(i64, 2), got.runs[4].row);
    try std.testing.expect(got.runs[4].attrs.eql(.{}) and got.runs[4].cols == 1);
    var json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(got.base, .{}, &json.writer);
    try std.testing.expect(std.mem.indexOf(u8, json.written(), "\"fg\":\"default\",\"bg\":4") != null);
}
