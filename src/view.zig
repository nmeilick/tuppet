//! The text of a view reply: the screen, optionally with its history, or
//! only the lines that changed after a seq, in plain text, VT sequences,
//! or HTML; with plain text, optionally its styles.

const std = @import("std");
const vt = @import("vt");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const track = @import("track.zig");
const styles_mod = @import("styles.zig");

const Session = session_mod.Session;

pub const Options = struct {
    format: vt.formatter.Format = .plain,
    scrollback: bool = false,
    unwrap: bool = false,
    since: ?u64 = null,
    /// The text is cut, oldest lines first, until it takes at most this
    /// many bytes as a JSON string. A whole screen in vt or html is never
    /// cut: it fails with error.ViewTooLarge instead.
    budget: usize = std.math.maxInt(usize),
    /// Add the styles of the rows the text shows; plain format only. The
    /// text and the styles get half the budget each.
    styles: bool = false,
};

pub const View = struct {
    text: []const u8,
    /// With `since`: the screen row of each line of `text`. Rows of the
    /// screen count from 1, the history row right above it is 0, the one
    /// above that -1, and so on.
    rows: ?[]const i64 = null,
    truncated: bool = false,
    cursor: protocol.Cursor,
    styles: ?styles_mod.Styles = null,
};

/// Render the active screen of `s`; terminal_mutex must be held.
pub fn renderLocked(gpa: std.mem.Allocator, s: *Session, opts: Options) !View {
    const t = &s.terminal;
    const cursor = t.screens.active.cursor;
    const at: protocol.Cursor = .{
        .row = @intCast(@min(@as(usize, cursor.y) + 1, s.rows)),
        .col = @intCast(@min(@as(usize, cursor.x) + 1, s.cols)),
    };
    var text_opts = opts;
    if (opts.styles) text_opts.budget = opts.budget / 2;
    var rows: std.ArrayList(styles_mod.ViewRow) = .empty;
    defer rows.deinit(gpa);
    var v = if (opts.since) |since|
        try renderChanged(gpa, s, text_opts, since, at, if (opts.styles) &rows else null)
    else blk: {
        const text = try s.formatLocked(gpa, opts.format, if (opts.scrollback) .scrollback else .screen, opts.unwrap);
        const start = fitTail(text, text_opts.budget);
        // A cut would lose the HTML header, or the styles VT set before it.
        if (start > 0 and opts.format != .plain) return error.ViewTooLarge;
        if (opts.styles) try shownRows(gpa, t, opts.scrollback, &rows);
        break :blk View{ .text = text[start..], .truncated = start > 0, .cursor = at };
    };
    if (opts.styles) v.styles = try styles_mod.collect(gpa, t, rows.items, opts.budget - text_opts.budget);
    return v;
}

/// The rows a whole view shows: the screen's, and with `scrollback` the
/// history's above it.
fn shownRows(gpa: std.mem.Allocator, t: *vt.Terminal, scrollback: bool, out: *std.ArrayList(styles_mod.ViewRow)) !void {
    const pages = &t.screens.active.pages;
    const above = if (scrollback) pages.total_rows - pages.rows else 0;
    const active = pages.getTopLeft(.active);
    const start = if (above > 0) active.up(above) orelse active else active;
    var it = start.rowIterator(.right_down, null);
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        try out.append(gpa, .{ .pin = p, .row = @as(i64, @intCast(i)) - @as(i64, @intCast(above)) + 1 });
    }
}

/// The lines with a row that changed after `since`, each formatted on its
/// own and followed by a newline; their rows go to `shown`.
fn renderChanged(gpa: std.mem.Allocator, s: *Session, opts: Options, since: u64, at: protocol.Cursor, shown: ?*std.ArrayList(styles_mod.ViewRow)) !View {
    const t = &s.terminal;
    const key = t.screens.active_key;
    const screen = t.screens.active;
    const pages = &screen.pages;
    const top = s.track.top(key);
    // Only history rows the tracker still knows can say when they changed.
    var above: usize = 0;
    if (opts.scrollback) {
        const history = pages.total_rows - pages.rows;
        while (above < history and s.track.rowAt(key, top - @as(i64, @intCast(above)) - 1) != null) above += 1;
    }
    const active = pages.getTopLeft(.active);
    const start = if (above > 0) active.up(above) orelse active else active;
    const first_abs = top - @as(i64, @intCast(above));

    var text: std.ArrayList(u8) = .empty;
    var rows: std.ArrayList(i64) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    var it = track.LineIterator.init(start);
    var pending: ?track.Line = null;
    while (true) {
        const line = pending orelse it.next() orelse break;
        pending = null;
        // Without unwrap every row is a line of its own.
        const n = if (opts.unwrap) line.rows else 1;
        if (!opts.unwrap and line.rows > 1) {
            pending = .{ .y = line.y + 1, .rows = line.rows - 1, .first = line.first.down(1) orelse line.first };
        }
        var changed = false;
        for (0..n) |r| {
            const state = s.track.rowAt(key, first_abs + @as(i64, @intCast(line.y + r))) orelse continue;
            if (state.change_seq > since and state.change_seq != track.unknown_seq) changed = true;
        }
        if (!changed) continue;
        try starts.append(gpa, text.items.len);
        const row = @as(i64, @intCast(line.y)) - @as(i64, @intCast(above)) + 1;
        try rows.append(gpa, row);
        if (shown) |list| {
            var p = line.first;
            for (0..n) |r| {
                try list.append(gpa, .{ .pin = p, .row = row + @as(i64, @intCast(r)) });
                p = p.down(1) orelse break;
            }
        }
        try formatLine(gpa, &text, s, line.first, n, opts);
        try text.append(gpa, '\n');
    }
    const cut = fitTail(text.items, opts.budget);
    var dropped: usize = 0;
    while (dropped < starts.items.len and starts.items[dropped] < cut) dropped += 1;
    const from = if (dropped < starts.items.len) starts.items[dropped] else text.items.len;
    return .{
        .text = text.items[from..],
        .rows = rows.items[dropped..],
        .truncated = dropped > 0,
        .cursor = at,
    };
}

/// One line of HTML stands alone: its colors are resolved, with the same
/// theme as a full view.
pub fn formatLine(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: *Session, first: vt.Pin, n: usize, opts: Options) !void {
    var w = std.Io.Writer.Allocating.fromArrayList(gpa, out);
    defer out.* = w.toArrayList();
    const last = first.down(n - 1) orelse first;
    const screen = s.terminal.screens.active;
    var format_opts: vt.formatter.Options = .{ .emit = opts.format, .unwrap = opts.unwrap };
    if (opts.format == .html) {
        format_opts.background = s.terminal.colors.background.get();
        format_opts.foreground = s.terminal.colors.foreground.get();
        format_opts.palette = &s.terminal.colors.palette.current;
    }
    var formatter = vt.formatter.ScreenFormatter.init(screen, format_opts);
    formatter.content = .{ .selection = vt.Selection.init(
        .{ .node = first.node, .y = first.y, .x = 0 },
        .{ .node = last.node, .y = last.y, .x = @intCast(screen.pages.cols - 1) },
        false,
    ) };
    try formatter.format(&w.writer);
}

/// Where `text` must start so that it takes at most `budget` bytes as a
/// JSON string: 0, or the start of a line.
fn fitTail(text: []const u8, budget: usize) usize {
    var size: usize = 0;
    var i = text.len;
    while (i > 0) {
        const c = text[i - 1];
        size += switch (c) {
            '"', '\\', '\n', '\r', '\t', 0x08, 0x0c => 2,
            0...0x07, 0x0b, 0x0e...0x1f => 6,
            else => 1,
        };
        if (size > budget) break;
        i -= 1;
    } else return 0;
    if (text[i - 1] == '\n') return i;
    const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return text.len;
    return nl + 1;
}

test "a cut keeps the newest whole lines" {
    try std.testing.expectEqual(@as(usize, 0), fitTail("one\ntwo\n", 100));
    try std.testing.expectEqual(@as(usize, 4), fitTail("one\ntwo\n", 6));
    try std.testing.expectEqual(@as(usize, 8), fitTail("one\ntwo\n", 1));
}
