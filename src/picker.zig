//! The session picker that bare `tuppet` and `tuppet attach` open. Three modes:
//!
//!   - the list: the daemon's sessions, newest first, with a live preview
//!     of the selected one below;
//!   - the viewer: one session full screen, live and read-only, with the
//!     neighbors a key away and a small overlay saying which one it is;
//!   - attach: the terminal handed to the session, as `tuppet attach <id>`
//!     does, until the detach key brings it back to where it came from.
//!
//! The list and the viewer draw sessions themselves, from a local copy
//! of the screen that a read-only attach stream keeps current, so they
//! can clip, overlay, and switch freely and the program's output never
//! reaches this terminal raw. The preview watches in the passive role, so
//! it is neither a viewer nor an ack; the viewer acks what it showed once
//! it has shown a session for a second.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const plat = @import("plat.zig");
const client = @import("client.zig");
const attach_client = @import("attach_client.zig");
const words = @import("words.zig");
const status = @import("status.zig");
const names = @import("names.zig");
const store = @import("store.zig");
const limits = @import("limits.zig");

const Status = protocol.Status;

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
/// How long the rest of a sequence that has begun (ESC [, ESC O) may
/// take to arrive before the part that came is dropped.
const seq_wait_ns: i64 = 500 * std.time.ns_per_ms;
/// Frames are drawn at most this often while a session is busy.
const frame_interval_ns: i64 = 33 * std.time.ns_per_ms;
/// Stop, remove, and restart do nothing this long after an attach ended
/// or the mode changed, and right after an attach ended only keys that
/// move around work, so keys typed for what came before cannot hit them.
const guard_ns: i64 = 500 * std.time.ns_per_ms;
/// The viewer acks a session once it has shown it this long.
const view_ack_ns: i64 = 1000 * std.time.ns_per_ms;
/// Two clicks on a row this close together open the viewer.
const double_click_ns: i64 = 400 * std.time.ns_per_ms;
/// Ctrl-U erases what a prompt holds, as in a shell.
const ctrl_u: u8 = 0x15;
/// Below this size the picker only says that the terminal is too small.
const min_cols = 20;
const min_rows = 5;

pub const Options = struct {
    detach_key: u8 = attach_client.default_detach_key,
    /// Resize sessions to this terminal while attached.
    resize: bool = true,
    /// Ring this terminal's bell while attached when another session
    /// comes to need attention.
    bell: bool = true,
    /// Show only this session, in the viewer (`tuppet attach -r`).
    only: ?u64 = null,
};

/// Run the picker; returns the exit code: 0 after q (or Esc in the
/// viewer of `attach -r`), 130 after Ctrl-C, 128+n after signal n.
pub fn run(gpa: std.mem.Allocator, opts: Options) !u8 {
    var p: Picker = .{
        .gpa = gpa,
        .opts = opts,
        .color = colorWanted(),
        .ascii = !utf8Locale(),
        .self_id = try attach_client.selfSession(gpa),
    };
    defer p.deinit();
    if (opts.only) |id| {
        p.selected = id;
        p.mode = .view;
        p.view_since = io_mod.nowNanos();
        p.overlay_until = io_mod.nowNanos() + overlay_ns;
    }
    if (store.lastDetached(gpa)) |id| try p.mru.append(gpa, id);
    try p.refreshList();
    if (attach_client.nestedSession()) |id| if (opts.detach_key == attach_client.default_detach_key) {
        p.setNotice("this terminal is tuppet session #{d}; an attach around it takes Ctrl-] first (-k or TUPPET_DETACH_KEY sets another key)", .{id});
    };
    attach_client.installHandlers();
    const saved = plat.tcgetattr(0) catch return error.NotATerminal;
    // Keys typed before the picker showed anything.
    p.guard_until = io_mod.nowNanos() + guard_ns;
    p.enter(saved);
    defer p.leave(saved);
    try p.loop(saved);
    const sig = attach_client.got_quit.load(.acquire);
    return if (sig != 0) 128 +| sig else p.exit_code;
}

/// NO_COLOR, when set and not empty, turns colors off.
fn colorWanted() bool {
    const env = std.c.getenv("NO_COLOR") orelse return true;
    return std.mem.span(env).len == 0;
}

/// Whether the locale says the terminal takes UTF-8; without one (the C
/// locale) the picker draws ASCII.
fn utf8Locale() bool {
    for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        const value = std.mem.span(std.c.getenv(name) orelse continue);
        if (value.len == 0) continue;
        return std.ascii.findIgnoreCase(value, "utf-8") != null or std.ascii.findIgnoreCase(value, "utf8") != null;
    }
    return false;
}

/// What a character the picker draws becomes on a terminal without
/// UTF-8.
fn asciiFallback(cp: u21) u8 {
    return switch (cp) {
        0x00b7 => '-',
        0x258f => '|',
        0x25c6 => '*',
        0x203a, 0x25b8, 0x2192 => '>',
        0x25c2, 0x2190 => '<',
        0x2191 => '^',
        0x2193 => 'v',
        0x2026 => '~',
        0x2500...0x257f => switch (cp) {
            0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x254c, 0x254d, 0x2550 => '-',
            0x2502, 0x2503, 0x2506, 0x2507, 0x250a, 0x250b, 0x254e, 0x254f, 0x2551 => '|',
            else => '+',
        },
        else => '?',
    };
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
    /// A preview, which does not count among the session's viewers.
    passive: bool,
    conn: ipc.Conn,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    /// The stream ended: the program exited, or the daemon closed it.
    closed: bool = false,
    /// Open the watch again: the session was resized (the local copy has
    /// no history to reflow from), or the stream ended before the session
    /// did, as when the daemon dropped it for falling behind.
    reopen: bool = false,
    exit: ?[]u8 = null,
    dirty: bool = true,

    /// Open a watch, or return the daemon's reason why not.
    fn open(gpa: std.mem.Allocator, id: u64, passive: bool) union(enum) { ok: *Watch, refused: []u8 } {
        var id_buf: [24]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
        var conn = client.connect(gpa) catch return .{ .refused = gpa.dupe(u8, "the daemon is not reachable") catch &.{} };
        const req = protocol.stringifyRequest(gpa, protocol.AttachReq{ .session = id_text, .mode = if (passive) .preview else .read }) catch {
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
        const Reply = struct { ok: bool, err: []const u8 = "the session cannot be watched", status: ?protocol.Status = null };
        const reply = std.json.parseFromSlice(Reply, gpa, split.line, .{ .ignore_unknown_fields = true }) catch {
            gpa.free(split.rest);
            conn.deinit();
            return .{ .refused = gpa.dupe(u8, "the daemon sent a malformed reply") catch &.{} };
        };
        defer reply.deinit();
        const st = reply.value.status orelse protocol.Status{ .cols = 120, .rows = 40 };
        if (!reply.value.ok) {
            gpa.free(split.rest);
            conn.deinit();
            return .{ .refused = gpa.dupe(u8, reply.value.err) catch &.{} };
        }
        if (limits.sizeError(st.cols, st.rows)) |why| {
            gpa.free(split.rest);
            conn.deinit();
            return .{ .refused = std.fmt.allocPrint(gpa, "the session's size {d}x{d} cannot be shown: {s}", .{ st.cols, st.rows, why }) catch &.{} };
        }
        const w = gpa.create(Watch) catch {
            gpa.free(split.rest);
            conn.deinit();
            return .{ .refused = &.{} };
        };
        w.* = .{ .gpa = gpa, .id = id, .passive = passive, .conn = conn, .terminal = undefined, .stream = undefined };
        w.terminal = vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{
            .cols = st.cols,
            .rows = st.rows,
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
            w.reopen = w.exit == null;
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
            w.reopen = true;
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
    /// columns up to the cursor. Returns where the session's cursor is on
    /// the grid, if it shows.
    fn draw(w: *Watch, g: *Grid, x: usize, y: usize, width: usize, height: usize, color: bool) ?[2]usize {
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
        if (cursor.y < top or cursor.y - top >= height or cursor.x < left or cursor.x - left >= width) return null;
        return .{ y + cursor.y - top, x + cursor.x - left };
    }

    /// Whether the session's screen is larger than `width` by `height`.
    fn cropped(w: *const Watch, width: usize, height: usize) bool {
        return w.terminal.cols > width or w.terminal.rows > height;
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
    tab,
    back_tab,
    ctrl_c,
    /// Any other control character, such as a detach key.
    control: u8,
    char: u21,
    mouse: Mouse,
};

/// A mouse report in SGR form: the button code, and the 0-based cell.
const Mouse = struct {
    button: u16,
    x: u16,
    y: u16,
    press: bool,
};

/// Decode one key from the start of `buf`: the key and its length, or
/// null when more bytes are needed to tell (a lone ESC, a partial
/// sequence). Unknown sequences, and Alt with a character, are skipped.
fn parseKey(buf: []const u8) ?struct { key: ?Key, len: usize } {
    if (buf.len == 0) return null;
    const b = buf[0];
    if (b == 0x1b) {
        if (buf.len == 1) return null;
        if (buf[1] != '[' and buf[1] != 'O') {
            if (buf[1] >= 0x20 and buf[1] < 0x7f) return .{ .key = null, .len = 2 };
            if (buf[1] >= 0x80) {
                const n = std.unicode.utf8ByteSequenceLength(buf[1]) catch return .{ .key = null, .len = 2 };
                if (buf.len < 1 + n) return null;
                return .{ .key = null, .len = 1 + n };
            }
            return .{ .key = .escape, .len = 1 };
        }
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
            'Z' => .back_tab,
            'M', 'm' => if (params.len > 0 and params[0] == '<') parseMouse(params[1..], buf[i] == 'M') else null,
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
        '\t' => .{ .key = .tab, .len = 1 },
        0x00...0x02, 0x04...0x07, 0x0b, 0x0c, 0x0e...0x1a, 0x1c...0x1f => .{ .key = .{ .control = b }, .len = 1 },
        else => blk: {
            const n = std.unicode.utf8ByteSequenceLength(b) catch break :blk .{ .key = null, .len = 1 };
            if (buf.len < n) break :blk null;
            const cp = std.unicode.utf8Decode(buf[0..n]) catch break :blk .{ .key = null, .len = n };
            break :blk .{ .key = .{ .char = cp }, .len = n };
        },
    };
}

/// What to do with the input at the start of `buf`, whose start has
/// been waiting `waited` ns for the rest: take a key (or skip bytes,
/// with no key), or wait for more.
fn nextKey(buf: []const u8, waited: i64) ?struct { key: ?Key, len: usize } {
    if (parseKey(buf)) |parsed| return .{ .key = parsed.key, .len = parsed.len };
    // Only a lone ESC is ambiguous; a sequence that has begun is never
    // the Escape key, and what came of it is dropped, never typed.
    if (buf[0] == 0x1b and buf.len > 1) return if (waited < seq_wait_ns) null else .{ .key = null, .len = buf.len };
    if (waited < esc_wait_ns) return null;
    // Anything else that stays incomplete is not a key.
    return .{ .key = if (buf[0] == 0x1b) .escape else null, .len = 1 };
}

test "a split sequence is waited for and never becomes Escape and keys" {
    const ms = std.time.ns_per_ms;
    try std.testing.expect(nextKey("\x1b[", 100 * ms) == null);
    try std.testing.expect(nextKey("\x1b[5", 100 * ms) == null);
    const dropped = nextKey("\x1b[5", 600 * ms).?;
    try std.testing.expect(dropped.key == null and dropped.len == 3);
    try std.testing.expect(nextKey("\x1b", 10 * ms) == null);
    try std.testing.expectEqual(Key.escape, nextKey("\x1b", 40 * ms).?.key.?);
    try std.testing.expectEqual(Key.up, nextKey("\x1b[A", 0).?.key.?);
}

/// "b;x;y" of an SGR mouse report, with 1-based cells.
fn parseMouse(params: []const u8, press: bool) ?Key {
    var it = std.mem.splitScalar(u8, params, ';');
    const button = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    const x = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    if (x == 0 or y == 0) return null;
    return .{ .mouse = .{ .button = button, .x = x - 1, .y = y - 1, .press = press } };
}

test "keys decode from the bytes terminals send" {
    try std.testing.expectEqual(Key.up, parseKey("\x1b[A").?.key.?);
    try std.testing.expectEqual(Key.down, parseKey("\x1bOB").?.key.?);
    try std.testing.expectEqual(Key.page_down, parseKey("\x1b[6~").?.key.?);
    try std.testing.expectEqual(Key.home, parseKey("\x1b[1~").?.key.?);
    try std.testing.expectEqual(Key.enter, parseKey("\r").?.key.?);
    try std.testing.expectEqual(Key.tab, parseKey("\t").?.key.?);
    try std.testing.expectEqual(Key.back_tab, parseKey("\x1b[Z").?.key.?);
    try std.testing.expectEqual(@as(u8, 0x1d), parseKey("\x1d").?.key.?.control);
    try std.testing.expectEqual(@as(u21, 'q'), parseKey("q").?.key.?.char);
    try std.testing.expect(parseKey("\x1b") == null);
    try std.testing.expect(parseKey("\x1b[") == null);
    try std.testing.expectEqual(Key.escape, parseKey("\x1b\x1b[A").?.key.?);
    // Alt with a character is no key of the picker's.
    const alt = parseKey("\x1bq").?;
    try std.testing.expect(alt.key == null and alt.len == 2);
    const click = parseKey("\x1b[<0;5;3M").?.key.?.mouse;
    try std.testing.expect(click.press and click.button == 0 and click.x == 4 and click.y == 2);
}

/// A detach key as people write it: "Ctrl-]" for 0x1d.
fn keyName(buf: []u8, key: u8) []const u8 {
    return (if (key == 0x7f)
        std.fmt.bufPrint(buf, "Ctrl-?", .{})
    else if (key < 0x20)
        std.fmt.bufPrint(buf, "Ctrl-{c}", .{key + '@'})
    else
        std.fmt.bufPrint(buf, "{c}", .{key})) catch "";
}

/// Whether `text` matches `pattern`, ASCII letters in any case, where `*`
/// stands for any run of characters and `?` for one.
fn globIcase(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(text[t]))) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_t = t;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_t += 1;
            t = star_t;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test "filter patterns ignore case" {
    try std.testing.expect(globIcase("ci-*", "CI-lint"));
    try std.testing.expect(globIcase("*make*", "make -j8"));
    try std.testing.expect(!globIcase("web?", "web"));
}

// ---- the picker ---------------------------------------------------------

const Mode = enum { list, view };

/// A question or an input line in the footer (the overlay in the
/// viewer), about the session with this id, wherever its row moves.
const Prompt = union(enum) {
    stop: u64,
    restart: u64,
    remove: u64,
    rename: u64,
};

/// Where the list's columns go at the terminal's width; a width of 0
/// leaves a column out.
const Layout = struct {
    id_w: usize,
    name_w: usize,
    state_w: usize,
    age_w: usize,
    writer_w: usize,
    command: bool,
};

const Picker = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    color: bool,
    /// Draw ASCII in place of the picker's own glyphs.
    ascii: bool,
    /// The session this terminal is, from TUPPET_SESSION.
    self_id: ?u64,
    mode: Mode = .list,
    sessions: ?client.Reply(protocol.ListResp) = null,
    /// Indices into the session list after filtering, newest first.
    shown: std.ArrayListUnmanaged(usize) = .empty,
    selected: ?u64 = null,
    scroll: usize = 0,
    filter: std.ArrayListUnmanaged(u8) = .empty,
    filtering: bool = false,
    help: bool = false,
    preview_on: bool = true,
    /// The viewer's overlay: shown until this time, or always when pinned.
    overlay_until: i64 = 0,
    overlay_pinned: bool = false,
    notice: ?[]u8 = null,
    notice_until: i64 = 0,
    prompt: ?Prompt = null,
    /// What the rename prompt holds.
    entry: std.ArrayListUnmanaged(u8) = .empty,
    /// Offer to take over a session another client controls.
    offer_force: ?u64 = null,
    /// The viewer shows how this session ended, after it ended while
    /// attached, until it is left.
    ended_view: ?u64 = null,
    /// Stop, remove, and restart do nothing before this time.
    guard_until: i64 = 0,
    /// Until then, after an attach ended, only keys that move around,
    /// Esc, q, and ? work.
    settle_until: i64 = 0,
    /// The last list failed: the daemon is gone, and the list shown is
    /// what it said before.
    disconnected: bool = false,
    /// Since when the viewer shows the selected session.
    view_since: i64 = 0,
    /// What the viewer acked last, so it acks again only for news.
    acked: ?struct { id: u64, shown: status.Shown } = null,
    /// Sessions attached from here, most recent first.
    mru: std.ArrayListUnmanaged(u64) = .empty,
    watch: ?*Watch = null,
    watch_error: ?[]u8 = null,
    /// The session `watch_error` is about; it is tried again with the
    /// next list.
    watch_error_id: ?u64 = null,
    watch_due: i64 = 0,
    next_list: i64 = 0,
    input: std.ArrayListUnmanaged(u8) = .empty,
    esc_since: i64 = 0,
    last_click: struct { id: u64 = 0, at: i64 = 0 } = .{},
    mouse_on: bool = false,
    grid: Grid = .{},
    prev: Grid = .{},
    /// Where the terminal's cursor is left after a frame.
    cursor: ?[2]usize = null,
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
        p.entry.deinit(gpa);
        p.mru.deinit(gpa);
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
        p.mouse_on = false;
        p.full_redraw = true;
    }

    fn leave(p: *Picker, saved: std.posix.termios) void {
        plat.stdoutWriteAll("\x1b[?1000l\x1b[?1006l\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l") catch {};
        p.mouse_on = false;
        plat.tcsetattr(0, .FLUSH, saved) catch {};
        attach_client.forgetRaw();
    }

    /// Mouse reports only in the list: the viewer leaves the mouse to
    /// the terminal, for selecting text.
    fn syncMouse(p: *Picker) void {
        const want = p.mode == .list and !p.help and !p.tooSmall();
        if (want == p.mouse_on) return;
        plat.stdoutWriteAll(if (want) "\x1b[?1000h\x1b[?1006h" else "\x1b[?1000l\x1b[?1006l") catch {};
        p.mouse_on = want;
    }

    // -- data --

    fn refreshList(p: *Picker) !void {
        // A refused preview is tried again with each list.
        p.watch_error_id = null;
        const fresh = try client.listSessions(p.gpa);
        p.next_list = io_mod.nowNanos() + list_interval_ns;
        if (p.disconnected) {
            p.disconnected = false;
            p.notice_until = 0;
        }
        if (!fresh.parsed.value.ok) {
            defer fresh.deinit();
            const text = client.failureText(p.gpa, fresh.line) catch null;
            defer if (text) |t| p.gpa.free(t);
            p.setNotice("{s}", .{text orelse "the daemon could not list sessions"});
            return;
        }
        const pos = p.position();
        if (p.sessions) |old| old.deinit();
        p.sessions = fresh;
        try p.applyFilter(pos);
        p.ackViewed();
    }

    fn all(p: *Picker) []const Status {
        const s = p.sessions orelse return &.{};
        return s.parsed.value.sessions;
    }

    /// The selected row's position among the shown rows.
    fn position(p: *Picker) ?usize {
        return p.indexOf(p.selected orelse return null);
    }

    /// Rebuild the shown rows. The selection stays on its session; when
    /// that row is gone, on the row that took its place `pos` (its
    /// neighbor); the first time, on the newest running session.
    fn applyFilter(p: *Picker, pos: ?usize) !void {
        p.shown.clearRetainingCapacity();
        const list = p.all();
        for (list, 0..) |s, i| {
            if (p.opts.only) |only| if (s.id != only) continue;
            if (p.matches(s)) try p.shown.append(p.gpa, i);
        }
        std.mem.sortUnstable(usize, p.shown.items, list, struct {
            fn newer(l: []const Status, a: usize, b: usize) bool {
                return l[a].id > l[b].id;
            }
        }.newer);
        if (p.opts.only != null) return;
        if (p.selected) |id| if (p.indexOf(id) != null) return;
        if (p.shown.items.len == 0) return;
        if (p.selected != null) if (pos) |at| {
            p.select(list[p.shown.items[@min(at, p.shown.items.len - 1)]].id);
            return;
        };
        for (p.shown.items) |idx| if (list[idx].state == .running and !p.isSelf(list[idx].id)) {
            p.selected = list[idx].id;
            return;
        };
        p.selected = list[p.shown.items[0]].id;
    }

    /// A filter matches the name, the command, the directory, and the
    /// title: as a pattern when it has `*` or `?`, else as a part of them.
    fn matches(p: *Picker, s: Status) bool {
        const f = p.filter.items;
        if (f.len == 0) return true;
        var cmd_buf: [512]u8 = undefined;
        const fields = [_][]const u8{ s.name orelse "", words.commandText(&cmd_buf, s.argv), if (s.cwd) |c| c.path else "", s.title orelse "" };
        const pattern = std.mem.indexOfAny(u8, f, "*?") != null;
        for (fields) |text| {
            if (if (pattern) globIcase(f, text) else std.ascii.findIgnoreCase(text, f) != null) return true;
        }
        return false;
    }

    /// Position of session `id` among the shown sessions.
    fn indexOf(p: *Picker, id: u64) ?usize {
        const list = p.all();
        for (p.shown.items, 0..) |idx, pos| if (list[idx].id == id) return pos;
        return null;
    }

    fn current(p: *Picker) ?Status {
        const pos = p.position() orelse return null;
        return p.all()[p.shown.items[pos]];
    }

    fn byId(p: *Picker, id: u64) ?Status {
        for (p.all()) |s| if (s.id == id) return s;
        return null;
    }

    fn isSelf(p: *const Picker, id: u64) bool {
        return p.self_id == id;
    }

    fn move(p: *Picker, delta: isize) void {
        if (p.shown.items.len == 0) return;
        const pos: isize = @intCast(p.position() orelse 0);
        const last: isize = @intCast(p.shown.items.len - 1);
        const next: usize = @intCast(std.math.clamp(pos + delta, 0, last));
        p.select(p.all()[p.shown.items[next]].id);
    }

    fn select(p: *Picker, id: u64) void {
        if (p.selected == id) return;
        p.selected = id;
        p.offer_force = null;
        p.ended_view = null;
        const now = io_mod.nowNanos();
        // The viewer switches at once; the list waits for the cursor to
        // rest, so scrolling past rows opens no streams.
        p.watch_due = now + (if (p.mode == .view) 0 else preview_delay_ns);
        if (p.mode == .view) {
            p.overlay_until = now + overlay_ns;
            p.view_since = now;
        }
    }

    /// The next (or, `backwards`, previous) session that needs
    /// attention after the selected one, around the end.
    fn nextMarked(p: *Picker, backwards: bool) void {
        const n = p.shown.items.len;
        if (n == 0) return;
        const list = p.all();
        const start = p.position() orelse 0;
        for (1..n + 1) |step| {
            const at = if (backwards) (start + n - step % n) % n else (start + step) % n;
            const s = list[p.shown.items[at]];
            if (words.needsAttention(s) and !p.isSelf(s.id)) return p.select(s.id);
        }
        p.setNotice("no session needs you", .{});
    }

    /// The session attached most recently, other than the selected one.
    fn lastAttached(p: *Picker) void {
        for (p.mru.items) |id| {
            if (id == p.selected or p.indexOf(id) == null) continue;
            return p.select(id);
        }
        p.setNotice("no other session was attached from here", .{});
    }

    fn remember(p: *Picker, id: u64) void {
        if (std.mem.indexOfScalar(u64, p.mru.items, id)) |at| _ = p.mru.orderedRemove(at);
        p.mru.insert(p.gpa, 0, id) catch {};
    }

    /// Point the watch at the selected session: a passive preview in the
    /// list, a viewer in the viewer.
    fn syncWatch(p: *Picker) void {
        const id = p.selected orelse return p.closeWatch();
        const passive = p.mode == .list;
        if (p.isSelf(id) or (passive and !p.hasPreview())) return p.closeWatch();
        if (p.watch) |w| if (w.id == id and w.passive == passive and !w.reopen) return;
        if (p.watch_error_id == id) return;
        if (io_mod.nowNanos() < p.watch_due) return;
        p.closeWatch();
        switch (Watch.open(p.gpa, id, passive)) {
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
        p.stale = true;
    }

    fn noticeShown(p: *const Picker) ?[]const u8 {
        const n = p.notice orelse return null;
        return if (io_mod.nowNanos() < p.notice_until) n else null;
    }

    // -- acks --

    /// Tell the daemon that this terminal showed `shown` of session `id`.
    fn ack(p: *Picker, id: u64, shown: status.Shown) bool {
        var id_buf: [20]u8 = undefined;
        const ref = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
        const reply = client.request(p.gpa, protocol.AckReq{ .sessions = &.{ref}, .shown = shown }, protocol.ResultsResp) catch |err| {
            p.setNotice("cannot mark #{d} seen: {s}", .{ id, reason(err) });
            return false;
        };
        defer reply.deinit();
        return p.resultOk(reply, id);
    }

    /// The viewer acks a session it has shown for a second, with what the
    /// list said of it, and again when that shows something new.
    fn ackViewed(p: *Picker) void {
        if (p.mode != .view) return;
        const s = p.current() orelse return;
        const w = p.watch orelse return;
        if (w.id != s.id or w.passive or io_mod.nowNanos() - p.view_since < view_ack_ns) return;
        const shown = status.shownOf(s);
        if (p.acked) |last| if (last.id == s.id and (std.meta.eql(last.shown, shown) or !words.needsAttention(s))) return;
        if (p.ack(s.id, shown)) p.acked = .{ .id = s.id, .shown = shown };
    }

    /// Whether the one result of a request about session `id` succeeded;
    /// a notice says why not.
    fn resultOk(p: *Picker, reply: client.Reply(protocol.ResultsResp), id: u64) bool {
        if (!reply.parsed.value.ok) {
            const text = client.failureText(p.gpa, reply.line) catch null;
            defer if (text) |t| p.gpa.free(t);
            p.setNotice("#{d}: {s}", .{ id, text orelse "the request failed" });
            return false;
        }
        const results = reply.parsed.value.results;
        if (results.len == 1 and !results[0].ok) {
            p.setNotice("#{d}: {s}", .{ id, results[0].err orelse "the request failed" });
            return false;
        }
        return true;
    }

    // -- the loop --

    fn loop(p: *Picker, saved: std.posix.termios) !void {
        while (!p.quit) {
            if (attach_client.got_quit.load(.acquire) != 0) return;
            const now = io_mod.nowNanos();
            if (now >= p.next_list) p.refreshList() catch {
                // The daemon died: say so, and the next list starts a new
                // one, which serves the sessions kept on disk.
                p.next_list = now + list_interval_ns;
                if (!p.disconnected) p.full_redraw = true;
                p.disconnected = true;
                p.setNotice("lost contact with the daemon; retrying", .{});
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
            const waiting = if (p.selected) |id| (if (p.watch) |w| w.id != id else p.watch_error == null and !p.isSelf(id)) else false;
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
            const now = io_mod.nowNanos();
            const parsed = nextKey(p.input.items, if (p.esc_since == 0) 0 else now - p.esc_since) orelse {
                // Wait for the rest of a sequence.
                if (p.esc_since == 0) p.esc_since = now;
                return;
            };
            p.esc_since = 0;
            p.input.replaceRange(p.gpa, 0, parsed.len, &.{}) catch {};
            if (parsed.key) |key| try p.onKey(key, saved);
            if (p.quit) return;
        }
    }

    fn onKey(p: *Picker, key: Key, saved: std.posix.termios) !void {
        p.stale = true;
        // Keys typed for the session that just had the terminal only
        // move around meanwhile; a Ctrl-C meant for it does not quit.
        if (io_mod.nowNanos() < p.settle_until and !p.isSettleKey(key)) return;
        if (key == .ctrl_c) {
            p.quit = true;
            p.exit_code = 130;
            return;
        }
        if (p.help) {
            p.help = false;
            p.full_redraw = true;
            return;
        }
        // Too small to show anything: only quitting works.
        if (p.tooSmall()) {
            if (key == .char and key.char == 'q') p.quit = true;
            return;
        }
        if (p.prompt != null) return if (key == .mouse) {} else p.onPromptKey(key);
        if (p.filtering) return p.onFilterKey(key);
        if (key == .mouse) return p.onMouse(key.mouse);
        if (try p.onCommonKey(key, saved)) return;
        switch (p.mode) {
            .list => switch (key) {
                .up => p.move(-1),
                .down => p.move(1),
                .page_up => p.move(-@as(isize, @intCast(@max(1, p.listHeight())))),
                .page_down => p.move(@intCast(@max(1, p.listHeight()))),
                .home => p.move(std.math.minInt(isize) / 2),
                .end => p.move(std.math.maxInt(isize) / 2),
                .enter => p.view(),
                // Only q quits: Esc is too easily pressed for something
                // else, or arrives cut off from a sequence.
                .escape => if (p.filter.items.len > 0) {
                    const pos = p.position();
                    p.filter.clearRetainingCapacity();
                    try p.applyFilter(pos);
                },
                .char => |c| switch (c) {
                    'q' => p.quit = true,
                    'k' => p.move(-1),
                    'j' => p.move(1),
                    'g' => p.move(std.math.minInt(isize) / 2),
                    'G' => p.move(std.math.maxInt(isize) / 2),
                    'v' => p.view(),
                    'i' => {
                        p.preview_on = !p.preview_on;
                        p.full_redraw = true;
                    },
                    '/' => p.filtering = true,
                    else => {},
                },
                else => {},
            },
            .view => switch (key) {
                .up, .left => p.move(-1),
                .down, .right => p.move(1),
                .home => p.move(std.math.minInt(isize) / 2),
                .end => p.move(std.math.maxInt(isize) / 2),
                // Enter does nothing here: only `a` attaches.
                .escape, .backspace => p.back(),
                .control => |b| if (b == p.opts.detach_key or b == attach_client.default_detach_key) p.back(),
                .char => |c| switch (c) {
                    'q' => p.back(),
                    'k', 'h', 'p' => p.move(-1),
                    'j', 'l', 'n' => p.move(1),
                    'i' => {
                        p.overlay_pinned = !p.overlay_pinned;
                        p.overlay_until = 0;
                        p.full_redraw = true;
                    },
                    '/' => if (p.opts.only == null) {
                        p.back();
                        p.filtering = true;
                    },
                    else => {},
                },
                else => {},
            },
        }
    }

    /// Keys that do the same in the list and the viewer; whether `key`
    /// was one.
    fn onCommonKey(p: *Picker, key: Key, saved: std.posix.termios) !bool {
        switch (key) {
            .tab => p.nextMarked(false),
            .back_tab => p.nextMarked(true),
            .char => |c| switch (c) {
                'a' => try p.attachSelected(saved, false),
                'A' => try p.attachSelected(saved, true),
                '-' => p.lastAttached(),
                ' ' => p.ackSelected(),
                'x', 'd', 'r' => {
                    // Keys typed for what was on the screen before.
                    if (io_mod.nowNanos() < p.guard_until) return true;
                    const s = p.current() orelse return true;
                    switch (c) {
                        'x' => if (s.state == .running) {
                            p.prompt = .{ .stop = s.id };
                        } else p.setNotice("#{d} has ended already; d removes it", .{s.id}),
                        'd' => if (s.state == .running) {
                            p.setNotice("#{d} is running; x stops it first", .{s.id});
                        } else {
                            p.prompt = .{ .remove = s.id };
                        },
                        else => if (s.state == .running) {
                            p.setNotice("#{d} is still running; restart starts an ended session again", .{s.id});
                        } else {
                            p.prompt = .{ .restart = s.id };
                        },
                    }
                },
                'R' => {
                    const s = p.current() orelse return true;
                    p.entry.clearRetainingCapacity();
                    try p.entry.appendSlice(p.gpa, s.name orelse "");
                    p.prompt = .{ .rename = s.id };
                },
                'o' => try p.openHistory(saved),
                '?' => {
                    p.help = true;
                    p.full_redraw = true;
                },
                else => return false,
            },
            else => return false,
        }
        return true;
    }

    /// Whether `key` only moves around, looks, or leaves: what works
    /// right after an attach ended.
    fn isSettleKey(p: *const Picker, key: Key) bool {
        return switch (key) {
            .up, .down, .left, .right, .page_up, .page_down, .home, .end, .tab, .back_tab => true,
            // In `attach -r`'s viewer Esc quits.
            .escape => p.opts.only == null,
            .control => |b| b == p.opts.detach_key or b == attach_client.default_detach_key,
            .char => |c| std.mem.indexOfScalar(u8, "jkhlnpgG-q?", std.math.cast(u8, c) orelse return false) != null,
            else => false,
        };
    }

    fn onPromptKey(p: *Picker, key: Key) !void {
        const prompt = p.prompt.?;
        switch (prompt) {
            .stop, .restart, .remove => |id| {
                p.prompt = null;
                const yes = key == .char and (key.char == 'y' or key.char == 'Y');
                if (!yes) return p.setNotice("#{d} left as it is", .{id});
                switch (prompt) {
                    .stop => p.stopSession(id),
                    .restart => p.restartSession(id),
                    else => p.removeSession(id),
                }
            },
            .rename => |id| switch (key) {
                .enter => {
                    p.prompt = null;
                    p.renameSession(id);
                },
                .escape => p.prompt = null,
                .backspace => if (p.entry.items.len > 0) {
                    p.entry.shrinkRetainingCapacity(p.entry.items.len - 1);
                },
                .control => |b| if (b == ctrl_u) p.entry.clearRetainingCapacity(),
                // Names are ASCII.
                .char => |c| if (c < 0x80 and p.entry.items.len < names.max_name_len) try p.entry.append(p.gpa, @intCast(c)),
                else => {},
            },
        }
    }

    fn onFilterKey(p: *Picker, key: Key) !void {
        const pos = p.position();
        switch (key) {
            .enter, .down => {
                p.filtering = false;
                if (key == .down) p.move(1);
            },
            .up => p.move(-1),
            .escape => {
                p.filtering = false;
                p.filter.clearRetainingCapacity();
                try p.applyFilter(pos);
            },
            .backspace => {
                if (p.filter.items.len > 0) {
                    var cut = p.filter.items.len - 1;
                    while (cut > 0 and p.filter.items[cut] & 0xc0 == 0x80) cut -= 1;
                    p.filter.shrinkRetainingCapacity(cut);
                    try p.applyFilter(pos);
                }
            },
            .control => |b| if (b == ctrl_u) {
                p.filter.clearRetainingCapacity();
                try p.applyFilter(pos);
            },
            .char => |c| {
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &utf8) catch return;
                try p.filter.appendSlice(p.gpa, utf8[0..n]);
                try p.applyFilter(pos);
            },
            else => {},
        }
    }

    /// A click selects a row, a second one on it opens the viewer, and
    /// the wheel moves.
    fn onMouse(p: *Picker, m: Mouse) void {
        if (p.mode != .list or !m.press) return;
        switch (m.button) {
            64 => p.move(-1),
            65 => p.move(1),
            0 => {
                const at = @as(usize, m.y) -% 2;
                if (m.y < 2 or at >= p.listHeight() or p.scroll + at >= p.shown.items.len) return;
                const id = p.all()[p.shown.items[p.scroll + at]].id;
                const now = io_mod.nowNanos();
                const again = p.last_click.id == id and now - p.last_click.at < double_click_ns;
                p.select(id);
                p.last_click = .{ .id = id, .at = now };
                if (again) {
                    p.last_click = .{};
                    p.view();
                }
            },
            else => {},
        }
    }

    fn view(p: *Picker) void {
        const s = p.current() orelse return;
        if (p.isSelf(s.id)) return p.selfNotice(s.id);
        p.mode = .view;
        p.changedMode();
        p.view_since = io_mod.nowNanos();
        p.overlay_until = io_mod.nowNanos() + overlay_ns;
    }

    fn back(p: *Picker) void {
        if (p.opts.only != null) {
            p.quit = true;
            return;
        }
        p.mode = .list;
        p.ended_view = null;
        p.changedMode();
    }

    fn changedMode(p: *Picker) void {
        p.watch_due = 0;
        p.guard_until = io_mod.nowNanos() + guard_ns;
        p.full_redraw = true;
    }

    fn selfNotice(p: *Picker, id: u64) void {
        p.setNotice("#{d} is this terminal; it cannot be viewed or attached from here", .{id});
    }

    fn ackSelected(p: *Picker) void {
        const s = p.current() orelse return;
        if (p.ack(s.id, status.shownOf(s))) p.setNotice("#{d} marked seen", .{s.id});
        p.next_list = 0;
    }

    /// Draw a notice before a request that can take a moment.
    fn working(p: *Picker, comptime fmt: []const u8, args: anytype) void {
        p.setNotice(fmt, args);
        p.render() catch {};
    }

    fn stopSession(p: *Picker, id: u64) void {
        var id_buf: [20]u8 = undefined;
        const ref = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
        p.working("stopping #{d}…", .{id});
        defer p.next_list = 0;
        const reply = client.request(p.gpa, protocol.StopReq{ .sessions = &.{ref} }, protocol.ResultsResp) catch |err|
            return p.setNotice("cannot stop #{d}: {s}", .{ id, reason(err) });
        defer reply.deinit();
        if (p.resultOk(reply, id)) p.setNotice("stopped #{d}", .{id});
    }

    fn removeSession(p: *Picker, id: u64) void {
        var id_buf: [20]u8 = undefined;
        const ref = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
        defer p.next_list = 0;
        const reply = client.request(p.gpa, protocol.RemoveReq{ .sessions = &.{ref} }, protocol.ResultsResp) catch |err|
            return p.setNotice("cannot remove #{d}: {s}", .{ id, reason(err) });
        defer reply.deinit();
        if (p.resultOk(reply, id)) p.setNotice("removed #{d}", .{id});
    }

    /// Start an ended session again as `tuppet restart` does, with this
    /// terminal's environment, and select the new one.
    fn restartSession(p: *Picker, id: u64) void {
        var id_buf: [20]u8 = undefined;
        const ref = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
        p.working("restarting #{d}…", .{id});
        defer p.next_list = 0;
        const env = client.currentEnv(p.gpa, false) catch return p.setNotice("cannot restart #{d}: out of memory", .{id});
        defer client.freeEnv(p.gpa, env);
        const reply = client.request(p.gpa, protocol.RunReq{ .like = ref, .env = env }, protocol.StatusResp) catch |err|
            return p.setNotice("cannot restart #{d}: {s}", .{ id, reason(err) });
        defer reply.deinit();
        if (!reply.parsed.value.ok) {
            const text = client.failureText(p.gpa, reply.line) catch null;
            defer if (text) |t| p.gpa.free(t);
            return p.setNotice("cannot restart #{d}: {s}", .{ id, text orelse "the request failed" });
        }
        const new = reply.parsed.value.status.?.id;
        p.setNotice("restarted #{d} as #{d}", .{ id, new });
        p.selected = new;
        p.watch_due = 0;
    }

    fn renameSession(p: *Picker, id: u64) void {
        const name = p.entry.items;
        if (name.len > 0) if (names.nameError(name)) |why| return p.setNotice("cannot name #{d} '{s}': {s}", .{ id, name, why });
        var id_buf: [20]u8 = undefined;
        const ref = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
        defer p.next_list = 0;
        const reply = client.request(p.gpa, protocol.RenameReq{ .session = ref, .name = name }, protocol.StatusResp) catch |err|
            return p.setNotice("cannot rename #{d}: {s}", .{ id, reason(err) });
        defer reply.deinit();
        if (!reply.parsed.value.ok) {
            const text = client.failureText(p.gpa, reply.line) catch null;
            defer if (text) |t| p.gpa.free(t);
            return p.setNotice("cannot rename #{d}: {s}", .{ id, text orelse "the request failed" });
        }
        if (name.len == 0) p.setNotice("#{d} has no name now", .{id}) else p.setNotice("#{d} is named {s} now", .{ id, name });
    }

    /// Show the selected session's history in $PAGER (else `less -R
    /// +G`, at the newest output, else as it is), then come back.
    fn openHistory(p: *Picker, saved: std.posix.termios) !void {
        const s = p.current() orelse return;
        if (p.isSelf(s.id)) return p.selfNotice(s.id);
        // Nobody reads its stream while the pager runs, and keys typed
        // behind `o` were meant for the pager.
        p.closeWatch();
        p.input.clearRetainingCapacity();
        var id_buf: [20]u8 = undefined;
        const ref = std.fmt.bufPrint(&id_buf, "{d}", .{s.id}) catch unreachable;
        const reply = client.request(p.gpa, protocol.ViewReq{ .session = ref, .scrollback = true }, protocol.ViewResp) catch |err|
            return p.setNotice("cannot read the history of #{d}: {s}", .{ s.id, reason(err) });
        defer reply.deinit();
        if (!reply.parsed.value.ok) {
            const text = client.failureText(p.gpa, reply.line) catch null;
            defer if (text) |t| p.gpa.free(t);
            return p.setNotice("cannot read the history of #{d}: {s}", .{ s.id, text orelse "the request failed" });
        }
        const v = reply.parsed.value;
        const text = std.mem.trimEnd(u8, v.text, "\n");
        const lines = if (text.len == 0) 0 else std.mem.count(u8, text, "\n") + 1;
        const header = try std.fmt.allocPrint(p.gpa, "history: {d} line{s} kept{s}\n", .{
            lines,
            if (lines == 1) "" else "s",
            if (v.history_dropped or v.truncated) "; older output was dropped (TUPPET_SCROLLBACK)" else "",
        });
        defer p.gpa.free(header);
        p.leave(saved);
        page(p.gpa, header, text);
        p.enter(saved);
        p.guard_until = io_mod.nowNanos() + guard_ns;
    }

    /// Hand the terminal to the selected session until it is detached or
    /// ends, then come back: to the same mode after a detach, with the
    /// cursor on the session; to the viewer and its final screen after an
    /// exit or a takeover.
    fn attachSelected(p: *Picker, saved: std.posix.termios, force: bool) !void {
        const s = p.current() orelse return;
        if (p.isSelf(s.id)) return p.selfNotice(s.id);
        if (s.state != .running) {
            p.setNotice("#{d} has ended; there is nothing to control", .{s.id});
            return;
        }
        p.closeWatch();
        // What was said before is stale once the session had the screen,
        // and keys typed behind `a` were meant for the session, not for
        // the picker once it comes back.
        p.notice_until = 0;
        p.input.clearRetainingCapacity();
        // Cooked mode and a visible cursor for the attach to start from;
        // the alternate screen stays.
        plat.stdoutWriteAll("\x1b[?1000l\x1b[?1006l\x1b[0m\x1b[?7h\x1b[?25h") catch {};
        p.mouse_on = false;
        plat.tcsetattr(0, .FLUSH, saved) catch {};
        p.remember(s.id);
        var id_buf: [24]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{s.id}) catch unreachable;
        const outcome = attach_client.attach(p.gpa, id, .{
            .alt_screen = true,
            .detach_key = p.opts.detach_key,
            .resize = p.opts.resize,
            .bell = p.opts.bell,
            .end_on_takeover = true,
        }, force) catch |err| {
            p.enter(saved);
            p.setNotice("cannot attach to #{d}: {s}", .{ s.id, reason(err) });
            return;
        };
        p.enter(saved);
        const now = io_mod.nowNanos();
        p.guard_until = now + guard_ns;
        // A refused attach never had the terminal: nothing was typed for
        // the session.
        if (outcome.kind != .refused) p.settle_until = now + guard_ns;
        p.selected = s.id;
        p.watch_due = 0;
        p.next_list = 0;
        const msg = outcome.message orelse "";
        defer if (outcome.message) |m| p.gpa.free(m);
        switch (outcome.kind) {
            .detached => p.setNotice("detached from #{d}", .{s.id}),
            .exited => {
                p.mode = .view;
                p.ended_view = s.id;
                p.view_since = now;
            },
            .taken => {
                p.refreshList() catch {};
                const label = if (p.byId(s.id)) |now_s| (if (now_s.writer) |w| w.label else null) else null;
                p.mode = .view;
                p.view_since = now;
                p.overlay_until = now + overlay_ns;
                p.setNotice("taken over by {s}", .{label orelse "another client"});
            },
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

    fn tooSmall(p: *const Picker) bool {
        return p.grid.cols < min_cols or p.grid.rows < min_rows;
    }

    fn listHeight(p: *Picker) usize {
        const rows = p.grid.rows;
        const n = @max(p.shown.items.len, 1);
        if (!p.hasPreview()) return rows -| 3;
        return @min(n, @max(3, (rows -| 4) / 3));
    }

    fn hasPreview(p: *Picker) bool {
        return p.preview_on and p.grid.rows >= 14 and p.grid.cols >= 40;
    }

    fn render(p: *Picker) !void {
        const size = attach_client.terminalSize() orelse .{ 80, 24 };
        if (size[0] != p.grid.cols or size[1] != p.grid.rows) {
            try p.grid.resize(p.gpa, size[0], size[1]);
            try p.prev.resize(p.gpa, size[0], size[1]);
            p.full_redraw = true;
        }
        p.grid.clear();
        p.cursor = null;
        if (p.tooSmall()) {
            const g = &p.grid;
            const msg = if (g.cols >= 18) "terminal too small" else "too small";
            _ = g.text(g.rows / 2, (g.cols -| msg.len) / 2, g.cols, msg, .{ .attrs = .{ .bold = true } });
        } else {
            switch (p.mode) {
                .list => p.drawList(),
                .view => p.drawView(),
            }
            if (p.help) p.drawHelp();
        }
        p.grid.repair();
        p.syncMouse();
        try p.flush();
        if (p.watch) |w| w.dirty = false;
        p.stale = false;
        p.last_frame = io_mod.nowNanos();
    }

    fn style(p: *Picker, fg: ?u8, attrs: Attrs) Style {
        return .{ .fg = if (p.color and fg != null) .{ .palette = fg.? } else .default, .attrs = attrs };
    }

    /// The columns that fit on this terminal; see `fit`.
    fn layout(p: *Picker) Layout {
        const list = p.all();
        var l: Layout = .{ .id_w = 2, .name_w = 0, .state_w = 5, .age_w = 4, .writer_w = 0, .command = true };
        for (p.shown.items) |idx| {
            const s = list[idx];
            l.id_w = @max(l.id_w, std.fmt.count("{d}", .{s.id}));
            l.name_w = @max(l.name_w, @min(if (s.name) |n| n.len else 0, 16));
            var state_buf: [32]u8 = undefined;
            l.state_w = @max(l.state_w, @min(utf8Len(words.stateWord(&state_buf, s)), 14));
            if (p.isSelf(s.id)) {
                l.writer_w = @max(l.writer_w, self_label.len);
            } else if (s.writer) |w| {
                l.writer_w = @max(l.writer_w, @min(2 + utf8Len(w.label orelse "attached"), 18));
            }
        }
        if (l.name_w > 0) l.name_w = @max(l.name_w, 4);
        if (l.writer_w > 0) l.writer_w = @max(l.writer_w, "WRITER".len);
        return fit(l, p.grid.cols);
    }

    fn drawList(p: *Picker) void {
        const g = &p.grid;
        const list = p.all();
        const bar: Style = .{ .attrs = .{ .inverse = true } };
        g.fill(0, bar);
        var running: usize = 0;
        var need: usize = 0;
        for (list) |s| {
            running += @intFromBool(s.state == .running);
            need += @intFromBool(words.needsAttention(s));
        }
        var title_buf: [128]u8 = undefined;
        const full = if (p.disconnected)
            " tuppet · not connected: the list may be out of date"
        else
            std.fmt.bufPrint(&title_buf, " tuppet · {d} session{s}, {d} running · {d} need{s} you", .{
                list.len, if (list.len == 1) "" else "s", running, need, if (need == 1) "s" else "",
            }) catch "";
        // Narrow: the counts matter more than the name.
        const title = if (utf8Len(full) > g.cols) full[" tuppet ·".len..] else full;
        _ = g.text(0, 0, g.cols, title, if (need > 0) .{ .attrs = .{ .inverse = true, .bold = true } } else bar);
        if (p.filtering or p.filter.items.len > 0) {
            var f_buf: [128]u8 = undefined;
            const f = fmtCut(&f_buf, "/{s}{s} ", .{ p.filter.items, if (p.filtering) "▏" else "" });
            _ = g.text(0, g.cols -| (utf8Len(f) + 1), utf8Len(f) + 1, f, bar);
        }

        const l = p.layout();
        const head = p.style(null, .{ .bold = true, .faint = true });
        _ = g.text(1, 1, 1, "!", head);
        var x = column(g, 1, 3, l.id_w, "ID", head, true);
        if (l.name_w > 0) x = column(g, 1, x, l.name_w, "NAME", head, false);
        x = column(g, 1, x, l.state_w, "STATE", head, false);
        if (l.age_w > 0) x = column(g, 1, x, l.age_w, "AGE", head, true);
        if (l.writer_w > 0) x = column(g, 1, x, l.writer_w, "WRITER", head, false);
        if (l.command) _ = g.text(1, x, g.cols -| x, "COMMAND", head);

        const height = p.listHeight();
        const pos = p.position() orelse 0;
        if (pos < p.scroll) p.scroll = pos;
        if (pos >= p.scroll + height) p.scroll = pos + 1 - height;
        p.scroll = @min(p.scroll, p.shown.items.len -| height);
        if (p.shown.items.len == 0) {
            const faint = p.style(null, .{ .faint = true });
            if (list.len == 0) {
                _ = g.text(2, 4, g.cols -| 4, "No sessions yet. Start one with: tuppet run -a <command>", faint);
                _ = g.text(3, 4, g.cols -| 4, "or in the background: tuppet run -n NAME <command>", faint);
                _ = g.text(4, 4, g.cols -| 4, "'tuppet help' lists every command.", faint);
            } else {
                _ = g.text(2, 4, g.cols -| 4, "No session matches the filter.", faint);
            }
        }
        const now_ms = nowMillis();
        for (0..height) |r| {
            const at = p.scroll + r;
            if (at >= p.shown.items.len) break;
            const s = list[p.shown.items[at]];
            const y = 2 + r;
            const sel = p.selected == s.id;
            const base: Style = if (sel) .{ .attrs = .{ .inverse = true, .bold = true } } else .{};
            if (sel) {
                g.fill(y, base);
                p.cursor = .{ y, 0 };
            }
            _ = g.text(y, 0, 1, if (sel) "›" else " ", base);
            if (words.needsAttention(s)) _ = g.text(y, 1, 1, "!", if (sel) base else p.style(3, .{ .bold = true }));
            var id_buf: [24]u8 = undefined;
            x = column(g, y, 3, l.id_w, std.fmt.bufPrint(&id_buf, "{d}", .{s.id}) catch "", base, true);
            if (l.name_w > 0) x = column(g, y, x, l.name_w, s.name orelse "", base, false);
            var state_buf: [32]u8 = undefined;
            const state = words.stateWord(&state_buf, s);
            var st = base;
            if (!sel) st = p.style(stateColor(s), .{ .faint = s.state == .lost or s.damaged != null });
            x = column(g, y, x, l.state_w, state, st, false);
            var age_buf: [16]u8 = undefined;
            if (l.age_w > 0) x = column(g, y, x, l.age_w, words.ageSince(&age_buf, s.started_ms, now_ms), base, true);
            if (l.writer_w > 0) {
                var label_buf: [80]u8 = undefined;
                const label = if (p.isSelf(s.id))
                    self_label
                else if (s.writer) |w|
                    fmtCut(&label_buf, "◆ {s}", .{w.label orelse "attached"})
                else
                    "";
                x = column(g, y, x, l.writer_w, label, base, false);
            }
            var cmd_buf: [512]u8 = undefined;
            if (l.command) _ = g.text(y, x, g.cols -| x, words.commandText(&cmd_buf, s.argv), base);
            // What the daemon said before it went away: dim, with no
            // colors that read as live states.
            if (p.disconnected) for (g.row(y)) |*c| {
                c.style.fg = .default;
                c.style.attrs.faint = true;
            };
        }
        if (p.shown.items.len > height) {
            var at_buf: [48]u8 = undefined;
            const at = std.fmt.bufPrint(&at_buf, " {d}/{d}", .{ pos + 1, p.shown.items.len }) catch "";
            _ = g.text(1, g.cols -| (at.len + 1), at.len, at, head);
        }

        const footer_y = g.rows -| 1;
        if (p.hasPreview()) {
            const sep_y = 2 + height;
            p.drawPreviewTitle(sep_y);
            if (p.current()) |s| {
                const faint = p.style(null, .{ .faint = true });
                if (p.isSelf(s.id)) {
                    _ = g.text(sep_y + 2, 2, g.cols -| 4, "This is the terminal the picker runs in.", faint);
                } else if (p.watch) |w| {
                    if (w.id == s.id) _ = w.draw(g, 0, sep_y + 1, g.cols, footer_y -| (sep_y + 1), p.color);
                } else if (p.watch_error) |e| {
                    _ = g.text(sep_y + 2, 2, g.cols -| 4, e, p.style(1, .{}));
                }
            }
        }
        var keys_buf: [160]u8 = undefined;
        const width = g.cols -| 2;
        p.drawFooter(footer_y, if (p.filtering)
            fitHints(&keys_buf, &.{ .{ "type to filter (* and ? are patterns)", 2 }, .{ "Enter done", 0 }, .{ "Esc clear", 1 } }, width)
        else if (p.offer_force != null)
            fitHints(&keys_buf, &.{ .{ "A take over", 0 }, .{ "Enter view", 1 }, .{ "q quit", 0 } }, width)
        else
            fitHints(&keys_buf, &.{ .{ "Enter view", 1 }, .{ "a attach", 1 }, .{ "/ filter", 2 }, .{ "? keys", 0 }, .{ "q quit", 0 }, .{ "·   tuppet help: commands", 3 } }, width));
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
            if (s.name != null) " " else "",
            s.name orelse "",
            words.commandText(&cmd_buf, s.argv),
            words.stateWord(&state_buf, s),
            size[0],
            size[1],
        });
        _ = g.text(y, 2, g.cols -| 4, title, p.style(null, .{ .bold = true }));
    }

    fn drawView(p: *Picker) void {
        const g = &p.grid;
        const s = p.current();
        if (s == null and p.opts.only != null) {
            _ = g.text(g.rows / 2, 2, g.cols -| 4, "the session is gone", p.style(1, .{}));
        }
        var cropped = false;
        if (p.watch) |w| {
            if (p.selected == w.id) {
                p.cursor = w.draw(g, 0, 0, g.cols, g.rows, p.color);
                cropped = w.cropped(g.cols, g.rows);
            }
        } else if (p.watch_error) |e| {
            _ = g.text(g.rows / 2, 2, g.cols -| 4, e, p.style(1, .{}));
        }
        const id = p.selected orelse return;
        const now = io_mod.nowNanos();
        if (p.overlay_pinned or now < p.overlay_until or p.noticeShown() != null or p.prompt != null or p.ended_view == id) p.drawBadge(cropped);
    }

    /// The viewer's overlay: which session this is, where it sits in the
    /// list, and the keys, or a notice, a question, or how it ended.
    fn drawBadge(p: *Picker, cropped: bool) void {
        const g = &p.grid;
        const s = p.current() orelse return;
        const pos = (p.indexOf(s.id) orelse 0) + 1;
        var buf: [700]u8 = undefined;
        var cmd_buf: [512]u8 = undefined;
        var state_buf: [32]u8 = undefined;
        var crop_buf: [48]u8 = undefined;
        const crop = if (cropped) fmtCut(&crop_buf, " · {d}x{d} of {d}x{d}", .{ g.cols, g.rows, s.cols, s.rows }) else "";
        const line1 = if (p.opts.only != null)
            fmtCut(&buf, " #{d}{s}{s} · {s} · {s}{s} ", .{ s.id, if (s.name != null) " " else "", s.name orelse "", words.commandText(&cmd_buf, s.argv), words.stateWord(&state_buf, s), crop })
        else
            fmtCut(&buf, " ◂ #{d}{s}{s} · {s} · {s}{s}  {d}/{d} ▸ ", .{
                s.id,
                if (s.name != null) " " else "",
                s.name orelse "",
                words.commandText(&cmd_buf, s.argv),
                words.stateWord(&state_buf, s),
                crop,
                pos,
                p.shown.items.len,
            });
        var line2_buf: [300]u8 = undefined;
        const back_word = if (p.opts.only != null) "quit" else "back";
        const room = g.cols -| 2;
        const line2 = if (p.prompt != null)
            p.promptText(&line2_buf)
        else if (p.noticeShown()) |n|
            n
        else if (p.ended_view == s.id)
            fmtCut(&line2_buf, "{s} · Esc {s}", .{ if (p.watch) |w| (if (w.exit) |e| e else "ended") else "ended", back_word })
        else if (p.offer_force == s.id)
            fitHints(&line2_buf, &.{ .{ "A take over", 0 }, .{ "←/→ switch", 1 }, .{ "Esc back", 0 } }, room)
        else if (p.opts.only != null)
            fitHints(&line2_buf, &.{ .{ "a attach", 1 }, .{ "i pin", 2 }, .{ "Esc quit", 0 } }, room)
        else
            fitHints(&line2_buf, &.{ .{ "←/→ switch", 1 }, .{ "a attach", 1 }, .{ "i pin", 2 }, .{ "Esc back", 0 } }, room);
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

    fn promptText(p: *Picker, buf: []u8) []const u8 {
        const prompt = p.prompt orelse return "";
        const id = switch (prompt) {
            inline else => |id| id,
        };
        const s = p.byId(id);
        const name = if (s) |st| st.name orelse "" else "";
        const space = if (name.len > 0) " " else "";
        return switch (prompt) {
            .stop => fmtCut(buf, "stop #{d}{s}{s}? y/N", .{ id, space, name }),
            .restart => fmtCut(buf, "restart #{d}{s}{s}? y/N", .{ id, space, name }),
            .remove => fmtCut(buf, "remove #{d}{s}{s}? y/N", .{ id, space, name }),
            .rename => fmtCut(buf, "rename #{d}: {s}▏  Enter save  Esc cancel  (empty: no name)", .{ id, p.entry.items }),
        };
    }

    fn drawFooter(p: *Picker, y: usize, keys: []const u8) void {
        const g = &p.grid;
        if (p.prompt != null) {
            var buf: [300]u8 = undefined;
            _ = g.text(y, 1, g.cols -| 2, p.promptText(&buf), p.style(3, .{ .bold = true }));
            return;
        }
        if (p.noticeShown()) |n| {
            _ = g.text(y, 1, g.cols -| 2, n, p.style(3, .{ .bold = true }));
            return;
        }
        _ = g.text(y, 1, g.cols -| 2, keys, p.style(null, .{ .faint = true }));
    }

    fn drawHelp(p: *Picker) void {
        const g = &p.grid;
        var key_buf: [16]u8 = undefined;
        var attached_buf: [64]u8 = undefined;
        const attached = fmtCut(&attached_buf, "  {s: <13}back to the list or viewer", .{keyName(&key_buf, p.opts.detach_key)});
        // On a short terminal the less important lines (higher numbers)
        // are left out.
        const all_lines = [_]Hint{
            .{ "tuppet: sessions (any key closes this)", 0 },
            .{ "In the list", 0 },
            .{ "  ↑/↓ k/j      move (PgUp/PgDn, Home/End g/G)", 0 },
            .{ "  Enter v      view the session, read-only", 0 },
            .{ "  i            preview on or off", 2 },
            .{ "  /            filter: name, command, directory, title", 1 },
            .{ "  q            quit (Esc clears the filter)", 0 },
            .{ "In the list and the viewer", 0 },
            .{ "  a / A        attach / take over from its writer", 0 },
            .{ "  -            the session attached before", 2 },
            .{ "  Tab S-Tab    next / previous session that needs you", 1 },
            .{ "  Space        mark the session seen", 1 },
            .{ "  x            stop (asks first)", 1 },
            .{ "  d / r        remove / restart an ended session (asks)", 1 },
            .{ "  R            rename (Ctrl-U clears the name)", 2 },
            .{ "  o            history in $PAGER", 1 },
            .{ "In the viewer", 1 },
            .{ "  ←/→ h/l      previous / next session", 1 },
            .{ "  i            pin the overlay;  Esc q  back", 1 },
            .{ "While attached", 0 },
            .{ attached, 0 },
            .{ "Commands for scripts: tuppet help", 2 },
        };
        const room = g.rows -| 2;
        var level: u8 = 2;
        while (level > 0) : (level -= 1) {
            var n: usize = 0;
            for (all_lines) |l| n += @intFromBool(l[1] <= level);
            if (n <= room) break;
        }
        var lines_buf: [all_lines.len][]const u8 = undefined;
        var count: usize = 0;
        for (all_lines) |l| if (l[1] <= level) {
            lines_buf[count] = l[0];
            count += 1;
        };
        const lines = lines_buf[0..count];
        const width: usize = @min(g.cols, 60);
        const height: usize = @min(g.rows, lines.len + 2);
        const x = (g.cols -| width) / 2;
        const y = (g.rows -| height) / 2;
        const box: Style = .{ .attrs = .{ .inverse = true } };
        for (0..height) |r| {
            for (g.row(y + r)[x..][0..width]) |*c| c.* = .{ .style = box };
            if (r >= 1 and r - 1 < lines.len) _ = g.text(y + r, x + 2, width -| 4, lines[r - 1], box);
        }
        p.cursor = null;
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
                // The right half of a wide character: the terminal moved
                // past it, unless it shows ASCII.
                if (c.cp == 0 and !p.ascii) continue;
                if (cur == null or !cur.?.eql(c.style)) {
                    try writeSgr(out, c.style, p.color);
                    cur = c.style;
                }
                if (p.ascii) {
                    try out.writeByte(if (c.cp == 0) ' ' else if (c.cp < 0x80) @intCast(c.cp) else asciiFallback(c.cp));
                    continue;
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
        // The cursor stays on the selected row (or the session's cursor),
        // for screen readers and magnifiers that follow it.
        if (p.cursor) |c| try out.print("\x1b[{d};{d}H", .{ c[0] + 1, c[1] + 1 });
        try out.writeAll("\x1b[?2026l");
        try plat.stdoutWriteAll(w.written());
        p.full_redraw = false;
    }
};

const self_label = "(this terminal)";

/// The command needs this many columns to be worth showing.
const min_command_cols = 10;

/// `l` with what does not fit in `cols` left out: COMMAND first, then
/// AGE, then names are cut, and the writer goes last.
fn fit(l: Layout, cols: usize) Layout {
    var out = l;
    if (layoutWidth(out) > cols) out.command = false;
    if (layoutWidth(out) > cols) out.age_w = 0;
    if (out.name_w > 4 and layoutWidth(out) > cols) out.name_w = @max(4, out.name_w -| (layoutWidth(out) - cols));
    if (layoutWidth(out) > cols) out.writer_w = 0;
    return out;
}

/// A key hint and its importance: 0 always shows, higher numbers go
/// first when the line is too narrow.
const Hint = struct { []const u8, u8 };

/// The hints that fit `width` columns, joined into `buf`.
fn fitHints(buf: []u8, hints: []const Hint, width: usize) []const u8 {
    var level: u8 = 0;
    for (hints) |h| level = @max(level, h[1]);
    while (true) : (level -= 1) {
        var w: std.Io.Writer = .fixed(buf);
        var first = true;
        for (hints) |h| {
            if (h[1] > level) continue;
            if (!first) w.writeAll("   ") catch {};
            first = false;
            w.writeAll(h[0]) catch {};
        }
        if (utf8Len(w.buffered()) <= width or level == 0) return w.buffered();
    }
}

test "key hints drop the least important first and keep ? and q" {
    var buf: [160]u8 = undefined;
    const hints = [_]Hint{ .{ "Enter view", 1 }, .{ "a attach", 1 }, .{ "/ filter", 2 }, .{ "? keys", 0 }, .{ "q quit", 0 }, .{ "·   tuppet help: commands", 3 } };
    try std.testing.expectEqualStrings("Enter view   a attach   / filter   ? keys   q quit", fitHints(&buf, &hints, 58));
    try std.testing.expectEqualStrings("? keys   q quit", fitHints(&buf, &hints, 18));
}

fn layoutWidth(l: Layout) usize {
    var w: usize = 3 + l.id_w + 2 + l.state_w;
    if (l.name_w > 0) w += l.name_w + 2;
    if (l.age_w > 0) w += 2 + l.age_w;
    if (l.writer_w > 0) w += 2 + l.writer_w;
    if (l.command) w += 2 + min_command_cols;
    return w;
}

/// Show `header` and `text` in $PAGER, else in `less -R +G`, which
/// starts at the newest output; when neither runs, write them out. Less
/// gets -+F, so a LESS=-F does not quit it before the history is read;
/// after any other pager, which may have just printed the text (cat),
/// wait for a key.
fn page(gpa: std.mem.Allocator, header: []const u8, text: []const u8) void {
    const pager = if (std.c.getenv("PAGER")) |env| std.mem.span(env) else "";
    if (pager.len == 0) {
        if (pipeTo(gpa, &.{ "less", "-R", "-+F", "+G" }, header, text)) return;
    } else if (isLess(pager)) {
        const cmd = std.mem.concat(gpa, u8, &.{ pager, " -+F" }) catch return;
        defer gpa.free(cmd);
        if (pipeTo(gpa, &.{ "sh", "-c", cmd }, header, text)) return;
    } else if (pipeTo(gpa, &.{ "sh", "-c", pager }, header, text)) {
        return waitKey();
    }
    plat.stdoutWriteAll(header) catch {};
    plat.stdoutWriteAll(text) catch {};
    waitKey();
}

/// Whether the shell command `pager` runs less.
fn isLess(pager: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, pager, " \t");
    const first = parts.next() orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(first), "less");
}

fn waitKey() void {
    plat.stdoutWriteAll("\n-- press a key to return to tuppet --") catch {};
    const saved = plat.tcgetattr(0) catch return;
    attach_client.setRaw(saved);
    var key: [16]u8 = undefined;
    _ = std.c.read(0, &key, key.len);
    plat.tcsetattr(0, .FLUSH, saved) catch {};
    attach_client.forgetRaw();
}

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Run `argv` with `header` and `text` on its input and wait for it, as
/// system() would: Ctrl-C and Ctrl-\ are its, not tuppet's, meanwhile.
/// False when it could not run.
fn pipeTo(gpa: std.mem.Allocator, argv: []const []const u8, header: []const u8, text: []const u8) bool {
    if (builtin.os.tag == .windows) return false;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv_z = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch return false;
    for (argv, 0..) |arg, i| argv_z[i] = (arena.dupeSentinel(u8, arg, 0) catch return false).ptr;
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return false;
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    const default: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    const sigs = [_]std.posix.SIG{ .INT, .QUIT, .PIPE };
    var old: [sigs.len]std.posix.Sigaction = undefined;
    for (sigs, &old) |sig, *o| std.posix.sigaction(sig, &ignore, o);
    defer for (sigs, &old) |sig, *o| std.posix.sigaction(sig, o, null);
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return false;
    }
    if (pid == 0) {
        _ = std.c.dup2(fds[0], 0);
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        for (sigs) |sig| std.posix.sigaction(sig, &default, null);
        _ = execvp(argv_z[0].?, argv_z.ptr);
        std.c._exit(127);
    }
    _ = std.c.close(fds[0]);
    // A pager that quits early closes the pipe: the rest is not wanted.
    for ([_][]const u8{ header, text, "\n" }) |part| {
        var i: usize = 0;
        while (i < part.len) {
            const n = std.c.write(fds[1], part.ptr + i, part.len - i);
            if (n <= 0) {
                if (n < 0 and std.posix.errno(n) == .INTR) continue;
                break;
            }
            i += @intCast(n);
        }
    }
    _ = std.c.close(fds[1]);
    var wait_status: c_int = 0;
    while (std.c.waitpid(pid, &wait_status, 0) < 0) {
        if (std.posix.errno(-1) != .INTR) return false;
    }
    const st: u32 = @bitCast(wait_status);
    return !(std.posix.W.IFEXITED(st) and std.posix.W.EXITSTATUS(st) == 127);
}

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

fn stateColor(s: Status) ?u8 {
    return switch (s.state) {
        .running => 2,
        .lost => 1,
        .exited => if (s.exit) |e| (if (e.signal != null and !e.stopped) 1 else if ((e.code orelse 0) != 0 and !e.stopped) 3 else null) else null,
    };
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

test "narrow lists drop COMMAND, then AGE, then cut names, then drop the writer" {
    const wide: Layout = .{ .id_w = 2, .name_w = 16, .state_w = 7, .age_w = 4, .writer_w = 8, .command = true };
    try std.testing.expect(fit(wide, 80).command);
    const no_command = fit(wide, 50);
    try std.testing.expect(!no_command.command and no_command.age_w > 0);
    const no_age = fit(wide, 44);
    try std.testing.expect(no_age.age_w == 0 and no_age.name_w == 16);
    const cut = fit(wide, 32);
    try std.testing.expect(cut.writer_w > 0 and cut.name_w < 16 and cut.name_w >= 4);
    try std.testing.expectEqual(@as(usize, 0), fit(wide, 20).writer_w);
}
