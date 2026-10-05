//! The session picker that `tuppet attach` opens without an id. Three modes:
//!
//!   - the list: the daemon's sessions, newest first, with a live preview
//!     of the selected one below;
//!   - the viewer: one session full screen, live and read-only, with the
//!     neighbors a key away and a small overlay saying which one it is;
//!   - attach: the terminal handed to the session, as `tuppet attach <id>`
//!     does, until Ctrl-] brings it back to where it came from.
//!
//! The list and the viewer draw sessions themselves, from a local copy
//! of the screen that a read-only attach stream keeps current, so they
//! can clip, overlay, and switch freely and the program's output never
//! reaches this terminal raw.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const plat = @import("plat.zig");
const client = @import("client.zig");
const attach_client = @import("attach_client.zig");
const attach = @import("attach.zig");

/// How often the session list is refreshed.
const list_interval_ns: i64 = 1000 * std.time.ns_per_ms;
/// How long the cursor must rest on a row before its preview opens, so
/// scrolling through the list does not open a stream per row.
const preview_delay_ns: i64 = 80 * std.time.ns_per_ms;
/// How long the viewer's overlay stays after a switch.
const overlay_ns: i64 = 2500 * std.time.ns_per_ms;
/// How long a notice stays in the footer.
const notice_ns: i64 = 5000 * std.time.ns_per_ms;
/// A lone ESC is the Escape key once nothing follows it for this long.
const esc_wait_ns: i64 = 30 * std.time.ns_per_ms;
/// Frames are drawn at most this often while a session is busy.
const frame_interval_ns: i64 = 33 * std.time.ns_per_ms;

/// Run the picker; returns the exit code: 0 after q or Esc, 130 after
/// Ctrl-C, 128+n after signal n.
pub fn run(gpa: std.mem.Allocator) !u8 {
    var p: Picker = .{ .gpa = gpa, .color = std.c.getenv("NO_COLOR") == null };
    defer p.deinit();
    try p.refreshList();
    attach_client.installHandlers();
    const saved = std.posix.tcgetattr(0) catch return error.NotATerminal;
    p.enter(saved);
    defer p.leave(saved);
    try p.loop(saved);
    const sig = attach_client.got_quit.load(.acquire);
    return if (sig != 0) 128 +| sig else p.exit_code;
}

// ---- screen cells -----------------------------------------------------

const Color = union(enum) {
    default,
    palette: u8,
    rgb: [3]u8,

    fn eql(a: Color, b: Color) bool {
        return std.meta.eql(a, b);
    }
};

const Attrs = packed struct(u8) {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strike: bool = false,
};

const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    fn eql(a: Style, b: Style) bool {
        return a.fg.eql(b.fg) and a.bg.eql(b.bg) and @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }
};

const Cell = struct {
    /// 0 marks the right half of a wide character.
    cp: u21 = ' ',
    /// The left half of a wide character.
    wide: bool = false,
    style: Style = .{},

    fn eql(a: Cell, b: Cell) bool {
        return a.cp == b.cp and a.wide == b.wide and a.style.eql(b.style);
    }
};

/// Columns a character takes: 2 for East Asian wide characters and
/// emoji, 0 for combining marks and other zero-width characters.
fn charWidth(cp: u21) u2 {
    return switch (cp) {
        0x0300...0x036f, 0x0483...0x0489, 0x0591...0x05bd, 0x0610...0x061a, 0x064b...0x065f, 0x200b...0x200f, 0x20d0...0x20ff, 0xfe00...0xfe0f, 0xfe20...0xfe2f, 0xe0100...0xe01ef => 0,
        0x1100...0x115f, 0x231a...0x231b, 0x2329...0x232a, 0x23e9...0x23ec, 0x2614...0x2615, 0x2e80...0x303e, 0x3041...0x33ff, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xa000...0xa4cf, 0xa960...0xa97f, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe10...0xfe19, 0xfe30...0xfe6f, 0xff00...0xff60, 0xffe0...0xffe6, 0x1f300...0x1f64f, 0x1f900...0x1f9ff, 0x20000...0x3fffd => 2,
        else => 1,
    };
}

/// What is on the screen, cell by cell; rows that did not change since
/// the last frame are not sent again.
const Grid = struct {
    cols: usize = 0,
    rows: usize = 0,
    cells: []Cell = &.{},

    fn resize(g: *Grid, gpa: std.mem.Allocator, cols: usize, rows: usize) !void {
        g.cells = try gpa.realloc(g.cells, cols * rows);
        g.cols = cols;
        g.rows = rows;
        @memset(g.cells, .{});
    }

    fn row(g: *Grid, y: usize) []Cell {
        return g.cells[y * g.cols ..][0..g.cols];
    }

    fn clear(g: *Grid) void {
        @memset(g.cells, .{});
    }

    fn fill(g: *Grid, y: usize, style: Style) void {
        if (y >= g.rows) return;
        for (g.row(y)) |*c| c.* = .{ .style = style };
    }

    /// Write text from column `x`, at most `max` columns wide; text that
    /// does not fit ends in "…". Bytes that are not UTF-8 and control
    /// characters show as U+FFFD. Returns the column after it.
    fn text(g: *Grid, y: usize, x: usize, max: usize, s: []const u8, style: Style) usize {
        if (y >= g.rows or x >= g.cols) return x;
        const limit = @min(x + max, g.cols);
        const out = g.row(y);
        var col = x;
        var i: usize = 0;
        while (i < s.len) {
            const len: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
            const whole = len > 0 and i + len <= s.len;
            const raw: u21 = if (whole) std.unicode.utf8Decode(s[i..][0..len]) catch 0xfffd else 0xfffd;
            i += if (whole) len else 1;
            const cp: u21 = if (raw < 0x20 or raw == 0x7f) 0xfffd else raw;
            const width = charWidth(cp);
            if (width == 0) continue;
            // A character that does not fit, or one that would fill the
            // last column while more text follows, becomes "…".
            if (col + width > limit or (i < s.len and col + width == limit)) {
                if (col < limit) out[col] = .{ .cp = 0x2026, .style = style };
                return @min(col + 1, limit);
            }
            out[col] = .{ .cp = cp, .wide = width == 2, .style = style };
            if (width == 2) out[col + 1] = .{ .cp = 0, .style = style };
            col += width;
        }
        return col;
    }

    /// Blank any half of a wide character whose other half was
    /// overwritten, so every row stays aligned.
    fn repair(g: *Grid) void {
        for (0..g.rows) |y| {
            const r = g.row(y);
            for (r, 0..) |*c, x| {
                if (c.wide and (x + 1 >= r.len or r[x + 1].cp != 0)) {
                    c.* = .{ .style = c.style };
                } else if (c.cp == 0 and (x == 0 or !r[x - 1].wide)) {
                    c.* = .{ .style = c.style };
                }
            }
        }
    }
};

fn writeSgr(w: *std.Io.Writer, s: Style, color: bool) !void {
    try w.writeAll("\x1b[0");
    const a = s.attrs;
    if (a.bold) try w.writeAll(";1");
    if (a.faint) try w.writeAll(";2");
    if (a.italic) try w.writeAll(";3");
    if (a.underline) try w.writeAll(";4");
    if (a.blink) try w.writeAll(";5");
    if (a.inverse) try w.writeAll(";7");
    if (a.invisible) try w.writeAll(";8");
    if (a.strike) try w.writeAll(";9");
    if (color) {
        switch (s.fg) {
            .default => {},
            .palette => |i| try w.print(";38;5;{d}", .{i}),
            .rgb => |c| try w.print(";38;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
        }
        switch (s.bg) {
            .default => {},
            .palette => |i| try w.print(";48;5;{d}", .{i}),
            .rgb => |c| try w.print(";48;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
        }
    }
    try w.writeAll("m");
}

// ---- a watched session ------------------------------------------------

/// A read-only attach stream to one session, kept as a local terminal.
const Watch = struct {
    gpa: std.mem.Allocator,
    id: u64,
    conn: ipc.Conn,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    /// The stream ended: the program exited, or the daemon closed it.
    closed: bool = false,
    /// The session was resized. The local copy has no history to reflow
    /// from, so it is opened again for a fresh redraw.
    resized: bool = false,
    exit: ?[]u8 = null,
    dirty: bool = true,

    /// Open a watch, or return the daemon's reason why not.
    fn open(gpa: std.mem.Allocator, id: u64) union(enum) { ok: *Watch, refused: []u8 } {
        var id_buf: [24]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
        var conn = client.connect(gpa) catch return .{ .refused = gpa.dupe(u8, "the daemon is not reachable") catch &.{} };
        const req = protocol.stringifyRequest(gpa, .{ .cmd = "attach", .id = id_text, .mode = "read" }) catch {
            conn.deinit();
            return .{ .refused = &.{} };
        };
        defer gpa.free(req);
        conn.sendLine(req) catch {
            conn.deinit();
            return .{ .refused = gpa.dupe(u8, "the daemon closed the connection") catch &.{} };
        };
        const split = conn.recvLineSplit(gpa, 1 << 20) catch {
            conn.deinit();
            return .{ .refused = gpa.dupe(u8, "the daemon did not answer") catch &.{} };
        };
        defer gpa.free(split.line);
        const Reply = struct { ok: bool, err: ?[]const u8 = null, cols: u16 = 120, rows: u16 = 40 };
        const reply = std.json.parseFromSlice(Reply, gpa, split.line, .{ .ignore_unknown_fields = true }) catch {
            gpa.free(split.rest);
            conn.deinit();
            return .{ .refused = gpa.dupe(u8, "the daemon sent a malformed reply") catch &.{} };
        };
        defer reply.deinit();
        if (!reply.value.ok) {
            gpa.free(split.rest);
            conn.deinit();
            return .{ .refused = gpa.dupe(u8, reply.value.err orelse "the session cannot be watched") catch &.{} };
        }
        const w = gpa.create(Watch) catch {
            gpa.free(split.rest);
            conn.deinit();
            return .{ .refused = &.{} };
        };
        w.* = .{ .gpa = gpa, .id = id, .conn = conn, .terminal = undefined, .stream = undefined };
        w.terminal = vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{
            .cols = reply.value.cols,
            .rows = reply.value.rows,
            .max_scrollback_bytes = 0,
        }) catch {
            gpa.free(split.rest);
            conn.deinit();
            gpa.destroy(w);
            return .{ .refused = &.{} };
        };
        var handler = w.terminal.vtHandler();
        handler.effects = .readonly;
        w.stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = gpa });
        // No read timeout: the stream is quiet while the session is.
        var no_timeout: std.posix.timeval = .{ .sec = 0, .usec = 0 };
        _ = std.c.setsockopt(w.conn.posix.socket.handle, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&no_timeout), @sizeOf(std.posix.timeval));
        w.buf.appendSlice(gpa, split.rest) catch {};
        gpa.free(split.rest);
        w.drain();
        return .{ .ok = w };
    }

    fn deinit(w: *Watch) void {
        const gpa = w.gpa;
        if (!w.closed) w.conn.sendLine("{\"detach\":true}") catch {};
        w.conn.deinit();
        w.buf.deinit(gpa);
        if (w.exit) |e| gpa.free(e);
        w.stream.deinit();
        w.terminal.deinit(gpa);
        gpa.destroy(w);
    }

    fn fd(w: *Watch) std.posix.fd_t {
        return w.conn.posix.socket.handle;
    }

    /// Read what the daemon sent and apply it.
    fn pump(w: *Watch) void {
        var chunk: [64 * 1024]u8 = undefined;
        const n = std.c.read(w.fd(), &chunk, chunk.len);
        if (n <= 0) {
            w.closed = true;
            w.dirty = true;
            return;
        }
        w.buf.appendSlice(w.gpa, chunk[0..@intCast(n)]) catch return;
        w.drain();
    }

    fn drain(w: *Watch) void {
        while (std.mem.indexOfScalar(u8, w.buf.items, '\n')) |end| {
            w.frame(w.buf.items[0..end]);
            w.buf.replaceRange(w.gpa, 0, end + 1, &.{}) catch {};
        }
    }

    fn frame(w: *Watch, line: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(w.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const Frame = struct {
            screen: ?[]const u8 = null,
            out: ?[]const u8 = null,
            resize: ?struct { cols: u16, rows: u16 } = null,
            exit: ?struct { code: ?i32 = null, signal: ?[]const u8 = null } = null,
        };
        const f = std.json.parseFromSliceLeaky(Frame, a, line, .{ .ignore_unknown_fields = true }) catch return;
        if (f.screen orelse f.out) |b64| {
            const dec = std.base64.standard.Decoder;
            const len = dec.calcSizeForSlice(b64) catch return;
            const bytes = a.alloc(u8, len) catch return;
            dec.decode(bytes, b64) catch return;
            w.stream.nextSlice(bytes);
            w.dirty = true;
        }
        if (f.resize != null) {
            w.resized = true;
            w.dirty = true;
        }
        if (f.exit) |e| {
            if (w.exit) |old| w.gpa.free(old);
            w.exit = if (e.code) |c|
                std.fmt.allocPrint(w.gpa, "exited {d}", .{c}) catch null
            else
                std.fmt.allocPrint(w.gpa, "killed {s}", .{e.signal orelse "?"}) catch null;
            w.dirty = true;
        }
    }

    /// Draw the part of the session's screen that fits a `width` by
    /// `height` area at (x, y): all of it if it fits, else the rows down
    /// to the cursor or the last text, whichever is lower, and the
    /// columns up to the cursor. Returns the rows and columns shown.
    fn draw(w: *Watch, g: *Grid, x: usize, y: usize, width: usize, height: usize, color: bool) struct { top: usize, left: usize } {
        const t = &w.terminal;
        const rows: usize = t.rows;
        const cols: usize = t.cols;
        const cursor = t.screens.active.cursor;
        var top: usize = 0;
        if (rows > height) {
            const bottom = @max(@as(usize, cursor.y), lastTextRow(t));
            top = @min(rows - height, (bottom + 1) -| height);
        }
        var left: usize = 0;
        if (cols > width and cursor.x >= width) left = @min(cols - width, @as(usize, cursor.x) + 1 - width);
        const show_cursor = t.modes.get(.cursor_visible);
        const pages = &t.screens.active.pages;
        for (0..@min(height, rows - top)) |r| {
            if (y + r >= g.rows) break;
            const pin = pages.pin(.{ .active = .{ .y = @intCast(top + r) } }) orelse continue;
            const cells = pin.cells(.all);
            const out = g.row(y + r);
            var c: usize = 0;
            while (c < width and left + c < cols and x + c < g.cols) : (c += 1) {
                const cell = &cells[left + c];
                var style = cellStyle(pin.style(cell), color);
                if (show_cursor and top + r == cursor.y and left + c == cursor.x) style.attrs.inverse = !style.attrs.inverse;
                out[x + c] = switch (cell.wide) {
                    .spacer_tail => .{ .cp = 0, .style = style },
                    .spacer_head => .{ .cp = ' ', .style = style },
                    else => blk: {
                        const cp = cell.codepoint();
                        // A wide character cut off at the right edge.
                        if (cell.wide == .wide and (c + 1 >= width or x + c + 1 >= g.cols)) break :blk .{ .cp = ' ', .style = style };
                        break :blk .{ .cp = if (cp == 0) ' ' else cp, .wide = cell.wide == .wide, .style = style };
                    },
                };
            }
        }
        return .{ .top = top, .left = left };
    }
};

fn lastTextRow(t: *const vt.Terminal) usize {
    const pages = &t.screens.active.pages;
    var r: usize = t.rows;
    while (r > 0) {
        r -= 1;
        const pin = pages.pin(.{ .active = .{ .y = @intCast(r) } }) orelse continue;
        for (pin.cells(.all)) |cell| if (cell.hasText()) return r;
    }
    return 0;
}

fn cellStyle(s: anytype, color: bool) Style {
    var out: Style = .{ .attrs = .{
        .bold = s.flags.bold,
        .faint = s.flags.faint,
        .italic = s.flags.italic,
        .underline = s.flags.underline != .none,
        .blink = s.flags.blink,
        .inverse = s.flags.inverse,
        .invisible = s.flags.invisible,
        .strike = s.flags.strikethrough,
    } };
    if (color) {
        out.fg = vtColor(s.fg_color);
        out.bg = vtColor(s.bg_color);
    }
    return out;
}

fn vtColor(c: anytype) Color {
    return switch (c) {
        .none => .default,
        .palette => |i| .{ .palette = i },
        .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    };
}

// ---- keys -------------------------------------------------------------

const Key = union(enum) {
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    enter,
    escape,
    backspace,
    ctrl_c,
    ctrl_close_bracket,
    char: u21,
};

/// Decode one key from the start of `buf`: the key and its length, or
/// null when more bytes are needed to tell (a lone ESC, a partial
/// sequence). Unknown sequences are skipped.
fn parseKey(buf: []const u8) ?struct { key: ?Key, len: usize } {
    if (buf.len == 0) return null;
    const b = buf[0];
    if (b == 0x1b) {
        if (buf.len == 1) return null;
        if (buf[1] != '[' and buf[1] != 'O') return .{ .key = .escape, .len = 1 };
        // CSI or SS3: parameters, then a final byte.
        var i: usize = 2;
        while (i < buf.len and buf[i] >= 0x20 and buf[i] < 0x40) : (i += 1) {}
        if (i >= buf.len) return null;
        const params = buf[2..i];
        const key: ?Key = switch (buf[i]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '~' => if (std.mem.eql(u8, params, "5"))
                .page_up
            else if (std.mem.eql(u8, params, "6"))
                .page_down
            else if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7"))
                .home
            else if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8"))
                .end
            else
                null,
            else => null,
        };
        return .{ .key = key, .len = i + 1 };
    }
    return switch (b) {
        '\r', '\n' => .{ .key = .enter, .len = 1 },
        0x7f, 0x08 => .{ .key = .backspace, .len = 1 },
        0x03 => .{ .key = .ctrl_c, .len = 1 },
        0x1d => .{ .key = .ctrl_close_bracket, .len = 1 },
        0x00...0x02, 0x04...0x07, 0x09, 0x0b, 0x0c, 0x0e...0x1a, 0x1c, 0x1e, 0x1f => .{ .key = null, .len = 1 },
        else => blk: {
            const n = std.unicode.utf8ByteSequenceLength(b) catch break :blk .{ .key = null, .len = 1 };
            if (buf.len < n) break :blk null;
            const cp = std.unicode.utf8Decode(buf[0..n]) catch break :blk .{ .key = null, .len = n };
            break :blk .{ .key = .{ .char = cp }, .len = n };
        },
    };
}

test "keys decode from the bytes terminals send" {
    try std.testing.expectEqual(Key.up, parseKey("\x1b[A").?.key.?);
    try std.testing.expectEqual(Key.down, parseKey("\x1bOB").?.key.?);
    try std.testing.expectEqual(Key.page_down, parseKey("\x1b[6~").?.key.?);
    try std.testing.expectEqual(Key.home, parseKey("\x1b[1~").?.key.?);
    try std.testing.expectEqual(Key.enter, parseKey("\r").?.key.?);
    try std.testing.expectEqual(@as(u21, 'q'), parseKey("q").?.key.?.char);
    try std.testing.expect(parseKey("\x1b") == null);
    try std.testing.expect(parseKey("\x1b[") == null);
    try std.testing.expectEqual(Key.escape, parseKey("\x1bq").?.key.?);
}

// ---- the picker ---------------------------------------------------------

const Mode = enum { list, view };

const Picker = struct {
    gpa: std.mem.Allocator,
    color: bool,
    mode: Mode = .list,
    sessions: ?std.json.Parsed(protocol.ListResp) = null,
    /// Indices into the session list after filtering, newest first.
    shown: std.ArrayListUnmanaged(usize) = .empty,
    selected: ?u64 = null,
    scroll: usize = 0,
    filter: std.ArrayListUnmanaged(u8) = .empty,
    filtering: bool = false,
    help: bool = false,
    /// The viewer's overlay: shown until this time, or always when pinned.
    overlay_until: i64 = 0,
    overlay_pinned: bool = false,
    notice: ?[]u8 = null,
    notice_until: i64 = 0,
    /// Offer to take over a session another client controls.
    offer_force: ?u64 = null,
    watch: ?*Watch = null,
    watch_error: ?[]u8 = null,
    /// The session `watch_error` is about; it is tried again with the
    /// next list.
    watch_error_id: ?u64 = null,
    /// The session the preview watched when the list was fetched: its own
    /// viewer is not someone else watching.
    list_watch_id: ?u64 = null,
    watch_due: i64 = 0,
    next_list: i64 = 0,
    input: std.ArrayListUnmanaged(u8) = .empty,
    esc_since: i64 = 0,
    grid: Grid = .{},
    prev: Grid = .{},
    full_redraw: bool = true,
    /// Something changed that the screen must show.
    stale: bool = true,
    last_frame: i64 = 0,
    quit: bool = false,
    exit_code: u8 = 0,

    fn deinit(p: *Picker) void {
        const gpa = p.gpa;
        if (p.watch) |w| w.deinit();
        if (p.watch_error) |e| gpa.free(e);
        if (p.sessions) |s| s.deinit();
        if (p.notice) |n| gpa.free(n);
        p.shown.deinit(gpa);
        p.filter.deinit(gpa);
        p.input.deinit(gpa);
        gpa.free(p.grid.cells);
        gpa.free(p.prev.cells);
    }

    // -- terminal ownership --

    fn enter(p: *Picker, saved: std.posix.termios) void {
        attach_client.setRaw(saved);
        // Alternate screen, no cursor, no autowrap (the bottom-right cell
        // must not scroll the screen).
        plat.stdoutWriteAll("\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[H\x1b[2J") catch {};
        p.full_redraw = true;
    }

    fn leave(_: *Picker, saved: std.posix.termios) void {
        plat.stdoutWriteAll("\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l") catch {};
        std.posix.tcsetattr(0, .FLUSH, saved) catch {};
    }

    // -- data --

    fn refreshList(p: *Picker) !void {
        // A refused preview is tried again with each list.
        p.watch_error_id = null;
        p.list_watch_id = if (p.watch) |w| w.id else null;
        const fresh = try client.listSessions(p.gpa);
        if (!fresh.value.ok) {
            defer fresh.deinit();
            p.setNotice("{s}", .{fresh.value.err orelse "the daemon could not list sessions"});
            return;
        }
        if (p.sessions) |old| old.deinit();
        p.sessions = fresh;
        p.next_list = io_mod.nowNanos() + list_interval_ns;
        try p.applyFilter();
    }

    fn all(p: *Picker) []const protocol.SessionInfo {
        const s = p.sessions orelse return &.{};
        return s.value.sessions orelse &.{};
    }

    fn applyFilter(p: *Picker) !void {
        p.shown.clearRetainingCapacity();
        const list = p.all();
        var i = list.len;
        while (i > 0) {
            i -= 1;
            if (p.matches(list[i])) try p.shown.append(p.gpa, i);
        }
        std.mem.sortUnstable(usize, p.shown.items, list, struct {
            fn newer(l: []const protocol.SessionInfo, a: usize, b: usize) bool {
                return l[a].id > l[b].id;
            }
        }.newer);
        // Keep the selection by id; when it is gone, pick the newest
        // running session, or the first one.
        if (p.selected) |id| if (p.indexOf(id) != null) return;
        p.selected = null;
        for (p.shown.items) |idx| if (std.mem.eql(u8, list[idx].state, "running")) {
            p.selected = list[idx].id;
            break;
        };
        if (p.selected == null and p.shown.items.len > 0) p.selected = list[p.shown.items[0]].id;
    }

    fn matches(p: *Picker, s: protocol.SessionInfo) bool {
        if (p.filter.items.len == 0) return true;
        var id_buf: [24]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{s.id}) catch "";
        if (std.ascii.indexOfIgnoreCase(id, p.filter.items) != null) return true;
        if (std.ascii.indexOfIgnoreCase(s.name, p.filter.items) != null) return true;
        for (s.argv) |arg| if (std.ascii.indexOfIgnoreCase(arg, p.filter.items) != null) return true;
        return false;
    }

    /// Position of session `id` among the shown sessions.
    fn indexOf(p: *Picker, id: u64) ?usize {
        const list = p.all();
        for (p.shown.items, 0..) |idx, pos| if (list[idx].id == id) return pos;
        return null;
    }

    fn current(p: *Picker) ?protocol.SessionInfo {
        const id = p.selected orelse return null;
        const pos = p.indexOf(id) orelse return null;
        return p.all()[p.shown.items[pos]];
    }

    fn move(p: *Picker, delta: isize) void {
        if (p.shown.items.len == 0) return;
        const pos: isize = @intCast(if (p.selected) |id| p.indexOf(id) orelse 0 else 0);
        const last: isize = @intCast(p.shown.items.len - 1);
        const next: usize = @intCast(std.math.clamp(pos + delta, 0, last));
        p.select(p.all()[p.shown.items[next]].id);
    }

    fn select(p: *Picker, id: u64) void {
        if (p.selected == id) return;
        p.selected = id;
        p.offer_force = null;
        // The viewer switches at once; the list waits for the cursor to
        // rest, so scrolling past rows opens no streams.
        p.watch_due = io_mod.nowNanos() + (if (p.mode == .view) 0 else preview_delay_ns);
        if (p.mode == .view) p.overlay_until = io_mod.nowNanos() + overlay_ns;
    }

    /// Point the watch at the selected session.
    fn syncWatch(p: *Picker) void {
        const id = p.selected orelse {
            p.closeWatch();
            return;
        };
        if (p.watch) |w| if (w.id == id and !w.resized) return;
        if (p.watch_error_id == id) return;
        if (io_mod.nowNanos() < p.watch_due) return;
        p.closeWatch();
        switch (Watch.open(p.gpa, id)) {
            .ok => |w| p.watch = w,
            .refused => |msg| {
                p.watch_error = msg;
                p.watch_error_id = id;
            },
        }
        p.stale = true;
    }

    fn closeWatch(p: *Picker) void {
        if (p.watch) |w| w.deinit();
        p.watch = null;
        if (p.watch_error) |e| p.gpa.free(e);
        p.watch_error = null;
        p.watch_error_id = null;
    }

    fn setNotice(p: *Picker, comptime fmt: []const u8, args: anytype) void {
        if (p.notice) |n| p.gpa.free(n);
        p.notice = std.fmt.allocPrint(p.gpa, fmt, args) catch null;
        p.notice_until = io_mod.nowNanos() + notice_ns;
    }

    // -- the loop --

    fn loop(p: *Picker, saved: std.posix.termios) !void {
        while (!p.quit) {
            if (attach_client.got_quit.load(.acquire) != 0) return;
            const now = io_mod.nowNanos();
            if (now >= p.next_list) p.refreshList() catch |err| {
                // The daemon died: say so, and the next list starts a new
                // one, which serves the sessions kept on disk.
                p.next_list = now + list_interval_ns;
                p.setNotice("lost contact with the daemon ({s}); retrying", .{reason(err)});
                client.forgetDaemon();
            };
            p.syncWatch();
            const busy = if (p.watch) |w| w.dirty else false;
            // Input redraws at once; a busy session at most every frame
            // interval; and once a second for ages and notices.
            if (p.full_redraw or p.stale or now - p.last_frame >= list_interval_ns or
                (busy and now - p.last_frame >= frame_interval_ns)) try p.render();

            var fds = [2]std.c.pollfd{
                .{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = if (p.watch) |w| (if (w.closed) -1 else w.fd()) else -1, .events = std.c.POLL.IN, .revents = 0 },
            };
            const waiting = if (p.selected) |id| (if (p.watch) |w| w.id != id else p.watch_error == null) else false;
            const timeout: c_int = if (p.input.items.len > 0) 10 else if (busy or waiting) 15 else 100;
            if (std.c.poll(&fds, 2, timeout) < 0) {
                if (attach_client.got_winch.swap(false, .acq_rel)) p.full_redraw = true;
                continue;
            }
            if (attach_client.got_winch.swap(false, .acq_rel)) p.full_redraw = true;
            if (fds[1].revents != 0) if (p.watch) |w| w.pump();
            if (fds[0].revents != 0) {
                var chunk: [1024]u8 = undefined;
                const n = std.c.read(0, &chunk, chunk.len);
                if (n <= 0) return;
                try p.input.appendSlice(p.gpa, chunk[0..@intCast(n)]);
            }
            try p.handleInput(saved);
        }
    }

    fn handleInput(p: *Picker, saved: std.posix.termios) !void {
        while (p.input.items.len > 0) {
            const parsed = parseKey(p.input.items) orelse {
                // Wait briefly for the rest of a sequence; a lone ESC
                // that stays alone is the Escape key.
                const now = io_mod.nowNanos();
                if (p.esc_since == 0) p.esc_since = now;
                if (now - p.esc_since < esc_wait_ns) return;
                p.esc_since = 0;
                const lone_esc = p.input.items[0] == 0x1b;
                p.input.replaceRange(p.gpa, 0, 1, &.{}) catch {};
                // Anything else that stays incomplete is not a key.
                if (lone_esc) try p.onKey(.escape, saved);
                continue;
            };
            p.esc_since = 0;
            p.input.replaceRange(p.gpa, 0, parsed.len, &.{}) catch {};
            if (parsed.key) |key| try p.onKey(key, saved);
            if (p.quit) return;
        }
    }

    fn onKey(p: *Picker, key: Key, saved: std.posix.termios) !void {
        p.stale = true;
        p.full_redraw = p.full_redraw or p.help;
        if (p.help) {
            p.help = false;
            return;
        }
        if (key == .ctrl_c) {
            p.quit = true;
            p.exit_code = 130;
            return;
        }
        if (p.filtering) return p.onFilterKey(key);
        switch (p.mode) {
            .list => switch (key) {
                .up => p.move(-1),
                .down => p.move(1),
                .page_up => p.move(-@as(isize, @intCast(@max(1, p.listHeight())))),
                .page_down => p.move(@intCast(@max(1, p.listHeight()))),
                .home => p.move(std.math.minInt(isize) / 2),
                .end => p.move(std.math.maxInt(isize) / 2),
                .enter => p.view(),
                .escape => if (p.filter.items.len > 0) {
                    p.filter.clearRetainingCapacity();
                    try p.applyFilter();
                } else {
                    p.quit = true;
                },
                .char => |c| switch (c) {
                    'q' => p.quit = true,
                    'k' => p.move(-1),
                    'j' => p.move(1),
                    'g' => p.move(std.math.minInt(isize) / 2),
                    'G' => p.move(std.math.maxInt(isize) / 2),
                    'v' => p.view(),
                    'a' => try p.attachSelected(saved, false),
                    'A' => try p.attachSelected(saved, true),
                    '/' => p.filtering = true,
                    '?' => p.help = true,
                    else => {},
                },
                else => {},
            },
            .view => switch (key) {
                .up, .left => p.move(-1),
                .down, .right => p.move(1),
                .home => p.move(std.math.minInt(isize) / 2),
                .end => p.move(std.math.maxInt(isize) / 2),
                .enter => try p.attachSelected(saved, false),
                .escape, .backspace, .ctrl_close_bracket => p.back(),
                .char => |c| switch (c) {
                    'q' => p.back(),
                    'k', 'h', 'p' => p.move(-1),
                    'j', 'l', 'n' => p.move(1),
                    'a' => try p.attachSelected(saved, false),
                    'A' => try p.attachSelected(saved, true),
                    'i' => {
                        p.overlay_pinned = !p.overlay_pinned;
                        p.overlay_until = 0;
                    },
                    '?' => p.help = true,
                    else => {},
                },
                else => {},
            },
        }
    }

    fn onFilterKey(p: *Picker, key: Key) !void {
        switch (key) {
            .enter, .down => {
                p.filtering = false;
                if (key == .down) p.move(1);
            },
            .up => p.move(-1),
            .escape => {
                p.filtering = false;
                p.filter.clearRetainingCapacity();
                try p.applyFilter();
            },
            .backspace => {
                if (p.filter.items.len > 0) {
                    var cut = p.filter.items.len - 1;
                    while (cut > 0 and p.filter.items[cut] & 0xc0 == 0x80) cut -= 1;
                    p.filter.shrinkRetainingCapacity(cut);
                    try p.applyFilter();
                }
            },
            .char => |c| {
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &utf8) catch return;
                try p.filter.appendSlice(p.gpa, utf8[0..n]);
                try p.applyFilter();
            },
            else => {},
        }
    }

    fn view(p: *Picker) void {
        if (p.selected == null) return;
        p.mode = .view;
        p.watch_due = 0;
        p.overlay_until = io_mod.nowNanos() + overlay_ns;
        p.full_redraw = true;
    }

    fn back(p: *Picker) void {
        p.mode = .list;
        p.full_redraw = true;
    }

    /// Hand the terminal to the selected session until it is detached
    /// (Ctrl-]) or ends, then come back to the same mode.
    fn attachSelected(p: *Picker, saved: std.posix.termios, force: bool) !void {
        const s = p.current() orelse return;
        if (!std.mem.eql(u8, s.state, "running")) {
            p.setNotice("#{d} has ended; there is nothing to control", .{s.id});
            return;
        }
        p.closeWatch();
        // Cooked mode and a visible cursor for the attach to start from;
        // the alternate screen stays.
        plat.stdoutWriteAll("\x1b[0m\x1b[?7h\x1b[?25h") catch {};
        std.posix.tcsetattr(0, .FLUSH, saved) catch {};
        var id_buf: [24]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{s.id}) catch unreachable;
        const outcome = attach_client.attach(p.gpa, id, .{ .alt_screen = true }, force) catch |err| {
            p.enter(saved);
            p.setNotice("cannot attach to #{d}: {s}", .{ s.id, reason(err) });
            return;
        };
        p.enter(saved);
        p.watch_due = 0;
        p.next_list = 0;
        const msg = outcome.message orelse "";
        defer if (outcome.message) |m| p.gpa.free(m);
        switch (outcome.kind) {
            .detached => p.setNotice("detached from #{d}", .{s.id}),
            .exited => p.setNotice("#{d} {s}", .{ s.id, messageText(msg, "tuppet: session ") }),
            .refused => if (std.mem.indexOf(u8, msg, "writer") != null) {
                p.offer_force = s.id;
                p.setNotice("another client controls #{d}; press A to take over", .{s.id});
            } else {
                p.setNotice("{s}", .{messageText(msg, "tuppet: ")});
            },
            .failed => p.setNotice("{s}", .{messageText(msg, "tuppet: ")}),
        }
    }

    // -- drawing --

    fn listHeight(p: *Picker) usize {
        const rows = p.grid.rows;
        const n = @max(p.shown.items.len, 1);
        if (!p.hasPreview()) return rows -| 3;
        return @min(n, @max(3, (rows -| 4) / 3));
    }

    fn hasPreview(p: *Picker) bool {
        return p.grid.rows >= 14 and p.grid.cols >= 40;
    }

    fn render(p: *Picker) !void {
        const size = attach_client.terminalSize() orelse .{ 80, 24 };
        if (size[0] != p.grid.cols or size[1] != p.grid.rows) {
            try p.grid.resize(p.gpa, size[0], size[1]);
            try p.prev.resize(p.gpa, size[0], size[1]);
            p.full_redraw = true;
        }
        p.grid.clear();
        switch (p.mode) {
            .list => p.drawList(),
            .view => p.drawView(),
        }
        if (p.help) p.drawHelp();
        p.grid.repair();
        try p.flush();
        if (p.watch) |w| w.dirty = false;
        p.stale = false;
        p.last_frame = io_mod.nowNanos();
    }

    fn style(p: *Picker, fg: ?u8, attrs: Attrs) Style {
        return .{ .fg = if (p.color and fg != null) .{ .palette = fg.? } else .default, .attrs = attrs };
    }

    fn drawList(p: *Picker) void {
        const g = &p.grid;
        const list = p.all();
        const bar: Style = .{ .attrs = .{ .inverse = true } };
        g.fill(0, bar);
        var running: usize = 0;
        for (list) |s| running += @intFromBool(std.mem.eql(u8, s.state, "running"));
        var title_buf: [96]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, " tuppet · {d} session{s}, {d} running", .{ list.len, if (list.len == 1) "" else "s", running }) catch "";
        _ = g.text(0, 0, g.cols, title, bar);
        if (p.filtering or p.filter.items.len > 0) {
            var f_buf: [128]u8 = undefined;
            const f = fmtCut(&f_buf, "/{s}{s} ", .{ p.filter.items, if (p.filtering) "▏" else "" });
            _ = g.text(0, g.cols -| (f.len + 1), f.len + 1, f, bar);
        }

        // Columns: marker, id, name (when any session has one), state,
        // age, attached marker, command.
        var id_w: usize = 2;
        var name_w: usize = 0;
        for (list) |s| {
            id_w = @max(id_w, std.fmt.count("{d}", .{s.id}));
            name_w = @max(name_w, @min(s.name.len, 16));
        }
        const head = p.style(null, .{ .bold = true, .faint = true });
        var x: usize = 2;
        x = column(g, 1, x, id_w, "ID", head, true);
        if (name_w > 0) x = column(g, 1, x, @max(name_w, 4), "NAME", head, false);
        x = column(g, 1, x, 14, "STATE", head, false);
        x = column(g, 1, x, 5, "AGE", head, true);
        x += 2;
        _ = g.text(1, x, g.cols -| x, "COMMAND", head);

        const height = p.listHeight();
        const pos = if (p.selected) |id| p.indexOf(id) orelse 0 else 0;
        if (pos < p.scroll) p.scroll = pos;
        if (pos >= p.scroll + height) p.scroll = pos + 1 - height;
        p.scroll = @min(p.scroll, p.shown.items.len -| height);
        if (p.shown.items.len == 0) {
            const msg = if (list.len == 0)
                "No sessions. Start one with: tuppet run -a <command>"
            else
                "No session matches the filter.";
            _ = g.text(2, 4, g.cols -| 4, msg, p.style(null, .{ .faint = true }));
        }
        const now_ms = nowMillis();
        for (0..height) |r| {
            const at = p.scroll + r;
            if (at >= p.shown.items.len) break;
            const s = list[p.shown.items[at]];
            const y = 2 + r;
            const sel = p.selected == s.id;
            const base: Style = if (sel) .{ .attrs = .{ .inverse = true, .bold = true } } else .{};
            if (sel) g.fill(y, base);
            _ = g.text(y, 0, 2, if (sel) "›" else " ", base);
            var id_buf: [24]u8 = undefined;
            x = column(g, y, 2, id_w, std.fmt.bufPrint(&id_buf, "{d}", .{s.id}) catch "", base, true);
            if (name_w > 0) x = column(g, y, x, @max(name_w, 4), s.name, base, false);
            var state_buf: [32]u8 = undefined;
            const state = stateText(&state_buf, s);
            var st = base;
            if (!sel) st = p.style(stateColor(s), .{ .faint = std.mem.eql(u8, s.state, "lost") });
            x = column(g, y, x, 14, state, st, false);
            var age_buf: [16]u8 = undefined;
            x = column(g, y, x, 5, ageText(&age_buf, s.started_ms, now_ms), base, true);
            // The preview is a viewer too; it does not count.
            const own: u32 = @intFromBool(p.list_watch_id == s.id);
            _ = g.text(y, x, 1, if (s.writer) "◆" else if (s.viewers > own) "◇" else " ", base);
            x += 2;
            var cmd_buf: [512]u8 = undefined;
            _ = g.text(y, x, g.cols -| x, commandText(&cmd_buf, s.argv), base);
        }

        const footer_y = g.rows -| 1;
        if (p.hasPreview()) {
            const sep_y = 2 + height;
            p.drawPreviewTitle(sep_y);
            if (p.watch) |w| {
                if (p.selected == w.id) _ = w.draw(g, 0, sep_y + 1, g.cols, footer_y -| (sep_y + 1), p.color);
            } else if (p.watch_error) |e| {
                _ = g.text(sep_y + 2, 2, g.cols -| 4, e, p.style(1, .{}));
            }
        }
        p.drawFooter(footer_y, if (p.filtering)
            "type to filter   Enter done   Esc clear"
        else if (p.offer_force != null)
            "A take over   Enter view   q quit"
        else
            "Enter view   a attach   / filter   ? help   q quit");
    }

    fn drawPreviewTitle(p: *Picker, y: usize) void {
        const g = &p.grid;
        const line = p.style(null, .{ .faint = true });
        for (g.row(y)) |*c| c.* = .{ .cp = 0x2500, .style = line };
        const s = p.current() orelse return;
        var buf: [600]u8 = undefined;
        var cmd_buf: [512]u8 = undefined;
        var state_buf: [32]u8 = undefined;
        const size = if (p.watch) |w| (if (w.id == s.id) [2]u16{ w.terminal.cols, w.terminal.rows } else [2]u16{ s.cols, s.rows }) else [2]u16{ s.cols, s.rows };
        const title = fmtCut(&buf, " #{d}{s}{s} · {s} · {s} · {d}x{d} ", .{
            s.id,
            if (s.name.len > 0) " " else "",
            s.name,
            commandText(&cmd_buf, s.argv),
            stateText(&state_buf, s),
            size[0],
            size[1],
        });
        _ = g.text(y, 2, g.cols -| 4, title, p.style(null, .{ .bold = true }));
    }

    fn drawView(p: *Picker) void {
        const g = &p.grid;
        if (p.watch) |w| {
            if (p.selected == w.id) _ = w.draw(g, 0, 0, g.cols, g.rows, p.color);
        } else if (p.watch_error) |e| {
            _ = g.text(g.rows / 2, 2, g.cols -| 4, e, p.style(1, .{}));
        }
        const now = io_mod.nowNanos();
        if (p.overlay_pinned or now < p.overlay_until or p.notice != null and now < p.notice_until) p.drawBadge();
    }

    /// The viewer's overlay: which session this is, where it sits in the
    /// list, and the keys.
    fn drawBadge(p: *Picker) void {
        const g = &p.grid;
        const s = p.current() orelse return;
        const pos = (p.indexOf(s.id) orelse 0) + 1;
        var buf: [600]u8 = undefined;
        var cmd_buf: [512]u8 = undefined;
        var state_buf: [32]u8 = undefined;
        const line1 = fmtCut(&buf, " ◂ #{d}{s}{s} · {s} · {s}  {d}/{d} ▸ ", .{
            s.id,
            if (s.name.len > 0) " " else "",
            s.name,
            commandText(&cmd_buf, s.argv),
            stateText(&state_buf, s),
            pos,
            p.shown.items.len,
        });
        const now = io_mod.nowNanos();
        const line2 = if (p.notice != null and now < p.notice_until)
            p.notice.?
        else if (p.offer_force == s.id)
            "A take over   ←/→ switch   Esc back"
        else
            "←/→ switch   a attach   i pin   Esc back";
        const width = @min(g.cols, @max(utf8Len(line1), utf8Len(line2) + 2));
        const x = g.cols -| width;
        const box: Style = .{ .attrs = .{ .inverse = true } };
        for (0..2) |r| {
            if (r >= g.rows) break;
            for (g.row(r)[x..][0..width]) |*c| c.* = .{ .style = box };
        }
        _ = g.text(0, x, width, line1, .{ .attrs = .{ .inverse = true, .bold = true } });
        _ = g.text(1, x + 1, width -| 1, line2, box);
    }

    fn drawFooter(p: *Picker, y: usize, keys: []const u8) void {
        const g = &p.grid;
        const now = io_mod.nowNanos();
        if (p.notice != null and now < p.notice_until) {
            _ = g.text(y, 1, g.cols -| 2, p.notice.?, p.style(3, .{ .bold = true }));
            return;
        }
        _ = g.text(y, 1, g.cols -| 2, keys, p.style(null, .{ .faint = true }));
    }

    fn drawHelp(p: *Picker) void {
        const g = &p.grid;
        const lines = [_][]const u8{
            "tuppet attach: sessions (any key closes this)",
            "In the list",
            "  ↑/↓ k/j       move",
            "  PgUp/PgDn     page",
            "  Home/End g/G  newest / oldest",
            "  Enter v       view the session (read-only)",
            "  a / A         attach / take over from its writer",
            "  /             filter by id, name, or command",
            "  q Esc         quit (Esc clears a filter first)",
            "",
            "In the viewer",
            "  ←/→ ↑/↓       previous / next session",
            "  h/l k/j p/n   the same",
            "  a Enter / A   attach / take over from its writer",
            "  i             pin the overlay",
            "  Esc q ⌫ C-]   back to the list",
            "",
            "While attached",
            "  Ctrl-]        back to the list or viewer",
        };
        const width: usize = @min(g.cols, 52);
        const height: usize = @min(g.rows, lines.len + 2);
        const x = (g.cols -| width) / 2;
        const y = (g.rows -| height) / 2;
        const box: Style = .{ .attrs = .{ .inverse = true } };
        for (0..height) |r| {
            for (g.row(y + r)[x..][0..width]) |*c| c.* = .{ .style = box };
            if (r >= 1 and r - 1 < lines.len) _ = g.text(y + r, x + 2, width -| 4, lines[r - 1], box);
        }
    }

    fn flush(p: *Picker) !void {
        var w: std.Io.Writer.Allocating = .init(p.gpa);
        defer w.deinit();
        const out = &w.writer;
        try out.writeAll("\x1b[?2026h");
        if (p.full_redraw) try out.writeAll("\x1b[0m\x1b[2J");
        const g = &p.grid;
        for (0..g.rows) |y| {
            const now_row = g.row(y);
            const was = p.prev.row(y);
            if (!p.full_redraw and rowsEql(now_row, was)) continue;
            try out.print("\x1b[{d};1H", .{y + 1});
            var cur: ?Style = null;
            for (now_row) |c| {
                if (c.cp == 0) continue;
                if (cur == null or !cur.?.eql(c.style)) {
                    try writeSgr(out, c.style, p.color);
                    cur = c.style;
                }
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c.cp, &utf8) catch blk: {
                    utf8[0] = '?';
                    break :blk 1;
                };
                try out.writeAll(utf8[0..n]);
            }
            try out.writeAll("\x1b[0m");
            @memcpy(was, now_row);
        }
        try out.writeAll("\x1b[?2026l");
        try plat.stdoutWriteAll(w.written());
        p.full_redraw = false;
    }
};

/// An attach message without its prefix and line ending.
fn messageText(msg: []const u8, prefix: []const u8) []const u8 {
    const rest = if (std.mem.startsWith(u8, msg, prefix)) msg[prefix.len..] else msg;
    return std.mem.trimEnd(u8, rest, " \r\n");
}

fn rowsEql(a: []const Cell, b: []const Cell) bool {
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

/// Write one column cell, padded to `width`; numbers are right-aligned.
fn column(g: *Grid, y: usize, x: usize, width: usize, s: []const u8, st: Style, right: bool) usize {
    const len = @min(utf8Len(s), width);
    _ = g.text(y, if (right) x + width - len else x, width, s, st);
    return x + width + 2;
}

fn utf8Len(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn stateText(buf: []u8, s: protocol.SessionInfo) []const u8 {
    if (std.mem.eql(u8, s.state, "exited")) {
        const code = s.exit_code orelse return "exited";
        return attach.exitText(buf, code);
    }
    return s.state;
}

fn stateColor(s: protocol.SessionInfo) ?u8 {
    if (std.mem.eql(u8, s.state, "running")) return 2;
    if (std.mem.eql(u8, s.state, "lost")) return 1;
    const code = s.exit_code orelse return null;
    return if (code == 0) null else if (code > 0) 3 else 1;
}

fn ageText(buf: []u8, started_ms: ?i64, now_ms: i64) []const u8 {
    const start = started_ms orelse return "";
    const secs = @max(0, @divFloor(now_ms - start, 1000));
    return (if (secs < 60)
        std.fmt.bufPrint(buf, "{d}s", .{secs})
    else if (secs < 3600)
        std.fmt.bufPrint(buf, "{d}m", .{@divFloor(secs, 60)})
    else if (secs < 86400)
        std.fmt.bufPrint(buf, "{d}h", .{@divFloor(secs, 3600)})
    else
        std.fmt.bufPrint(buf, "{d}d", .{@divFloor(secs, 86400)})) catch "";
}

/// The command line, with arguments that need it quoted.
fn commandText(buf: []u8, argv: []const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (argv, 0..) |arg, i| {
        if (i > 0) w.writeByte(' ') catch break;
        const plain = arg.len > 0 and for (arg) |c| {
            if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_./=:,+@%", c) != null or c >= 0x80)) break false;
        } else true;
        if (plain) {
            w.writeAll(arg) catch break;
        } else {
            w.writeByte('\'') catch break;
            for (arg) |c| (if (c == '\'') w.writeAll("'\\''") else w.writeByte(c)) catch break;
            w.writeByte('\'') catch break;
        }
    }
    return w.buffered();
}

/// Why a request failed, in words.
fn reason(err: anyerror) []const u8 {
    const text = client.errorText(err) orelse "";
    return if (text.len > 0) text else @errorName(err);
}

/// Format into `buf`, cutting the text off where it does not fit.
fn fmtCut(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {};
    return w.buffered();
}

fn nowMillis() i64 {
    const ts = std.Io.Clock.Timestamp.now(io_mod.io(), .real);
    return @intCast(@divFloor(ts.raw.nanoseconds, std.time.ns_per_ms));
}

test "text is clipped by width, wide characters included, and never panics" {
    const gpa = std.testing.allocator;
    var g: Grid = .{};
    defer gpa.free(g.cells);
    try g.resize(gpa, 8, 1);
    _ = g.text(0, 0, 8, "ab\xffc\x01", .{});
    try std.testing.expectEqual(@as(u21, 0xfffd), g.row(0)[2].cp);
    try std.testing.expectEqual(@as(u21, 0xfffd), g.row(0)[4].cp);
    g.clear();
    try std.testing.expectEqual(@as(usize, 5), g.text(0, 0, 8, "漢字x", .{}));
    try std.testing.expect(g.row(0)[0].wide and g.row(0)[1].cp == 0);
    g.clear();
    _ = g.text(0, 0, 4, "abcdef", .{});
    try std.testing.expectEqual(@as(u21, 0x2026), g.row(0)[3].cp);
    // Overwriting half of a wide character blanks the other half.
    g.clear();
    _ = g.text(0, 0, 8, "漢", .{});
    g.row(0)[1] = .{ .cp = 'x' };
    g.repair();
    try std.testing.expectEqual(@as(u21, ' '), g.row(0)[0].cp);
}

test "commands are shown as a shell would need them" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("vim notes.txt", commandText(&buf, &.{ "vim", "notes.txt" }));
    try std.testing.expectEqualStrings("sh -c 'echo hi; exit 3'", commandText(&buf, &.{ "sh", "-c", "echo hi; exit 3" }));
    try std.testing.expectEqualStrings("echo 'it'\\''s'", commandText(&buf, &.{ "echo", "it's" }));
}
