//! Live attach: after the attach reply, a connection becomes a two-way
//! JSON-lines stream between one client and a session (see
//! docs/protocol.md). Any number of read-only viewers and at most one
//! writer share a session. Output reaches each viewer through its own
//! bounded queue and sender thread, so a slow viewer never blocks the
//! session, the daemon, or other viewers: when its queue overflows, or
//! it is far behind while all queues together hold too much, it is
//! disconnected.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const status = @import("status.zig");
const batch_mod = @import("batch.zig");
const limits = @import("limits.zig");
const track = @import("track.zig");
const vt = @import("vt");

const Session = session_mod.Session;

/// Output queued for one viewer before it counts as too slow.
pub const max_queue = 4 << 20;
/// Output queued for all viewers together. Past it, a viewer more than
/// its share of it behind counts as too slow, and no client attaches.
const max_queued_total = 64 << 20;
var queued_total: std.atomic.Value(usize) = .{ .raw = 0 };
/// How long the daemon keeps trying to deliver the final "too slow" line.
const final_line_wait_ns: i64 = std.time.ns_per_s;
/// Attached clients across all sessions; each holds two threads.
const max_viewers = 256;

const too_slow_line = "{\"end\":{\"reason\":\"too_slow\"}}\n";
const detach_line = "{\"end\":{\"reason\":\"detach\"}}\n";
pub const shutdown_line = "{\"end\":{\"reason\":\"shutdown\"}}\n";
const hold_line = "{\"hold\":true}\n";
const unhold_line = "{\"hold\":false}\n";
/// A writer's input held during a batch is discarded once the hold lasts
/// this much longer than the batch may.
const hold_margin_ns: i64 = std.time.ns_per_s;

var viewer_count: std.atomic.Value(usize) = .{ .raw = 0 };

pub const Viewer = struct {
    gpa: std.mem.Allocator,
    fd: std.posix.fd_t,
    /// May send input; cleared when a forced attach takes over.
    can_write: std.atomic.Value(bool),
    /// A preview: it watches without counting among the viewers.
    passive: bool = false,
    /// Gets a fresh screen after every resize, and screens that carry
    /// what a client's own copy of the screen needs; see
    /// Session.redrawLocked.
    redraw_on_resize: bool = false,
    /// History rows to send before the first screen, and the lowest row
    /// number among them; see historyFrames.
    history: u32 = 0,
    history_from: ?u64 = null,
    /// What the client calls itself, cleaned; owned by `gpa`.
    label: ?[]u8 = null,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    /// Encoded frames waiting for the sender thread.
    queue: std.ArrayListUnmanaged(u8) = .empty,
    /// No further frames are accepted; the sender exits once the queue
    /// is sent.
    closing: bool = false,
    /// The queue overflowed: the sender abandons what it is sending.
    overflowed: std.atomic.Value(bool) = .{ .raw = false },
    /// Mirrors `closing` for the sender's waits.
    ending: std.atomic.Value(bool) = .{ .raw = false },
    /// The bytes of its frames queued or being sent, counted in
    /// `queued_total`; `mutex` guards it.
    held: usize = 0,
    /// The bytes of `held` that `pushInitial` queued and the sender has
    /// not sent yet: a client is not behind for them, however much
    /// history they carry.
    initial: usize = 0,

    /// Queue one frame. Never blocks on the client.
    pub fn push(v: *Viewer, line: []const u8) void {
        v.pushLimited(line, true);
    }

    /// The attach reply and first redraw: never dropped for size (a
    /// large, colourful screen can exceed the queue limit by itself).
    pub fn pushInitial(v: *Viewer, line: []const u8) void {
        v.pushLimited(line, false);
    }

    fn pushLimited(v: *Viewer, line: []const u8, limited: bool) void {
        const io = io_mod.io();
        v.mutex.lockUncancelable(io);
        defer v.mutex.unlock(io);
        if (v.closing) return;
        if (limited and tooFarBehind(v.held - v.initial, line.len, queued_total.load(.acquire), viewer_count.load(.acquire))) {
            v.forget(v.queue.items.len);
            v.queue.clearRetainingCapacity();
            v.initial = 0;
            v.queueLocked(too_slow_line) catch {};
            v.closing = true;
            v.ending.store(true, .release);
            v.overflowed.store(true, .release);
        } else if (v.queueLocked(line)) {
            if (!limited) v.initial += line.len;
        } else |_| {
            v.closing = true;
            v.ending.store(true, .release);
        }
        v.cond.signal(io);
    }

    fn queueLocked(v: *Viewer, bytes: []const u8) !void {
        try v.queue.appendSlice(v.gpa, bytes);
        v.held += bytes.len;
        _ = queued_total.fetchAdd(bytes.len, .acq_rel);
    }

    /// `bytes` of its frames are sent or dropped; `mutex` must be held.
    fn forget(v: *Viewer, bytes: usize) void {
        v.held -= bytes;
        _ = queued_total.fetchSub(bytes, .acq_rel);
    }

    /// Queue a last frame (if any) and let the stream end after it.
    pub fn finish(v: *Viewer, last: ?[]const u8) void {
        const io = io_mod.io();
        v.mutex.lockUncancelable(io);
        defer v.mutex.unlock(io);
        if (!v.closing) {
            if (last) |line| v.queueLocked(line) catch {};
            v.closing = true;
            v.ending.store(true, .release);
        }
        v.cond.signal(io);
    }
};

/// Whether a viewer `behind` bytes behind falls too far behind with
/// `more`: past its own limit, or, while all `viewers` together hold
/// `total` and would go past theirs, past its share of that.
fn tooFarBehind(behind: usize, more: usize, total: usize, viewers: usize) bool {
    if (behind + more > max_queue) return true;
    return total + more > max_queued_total and behind + more > max_queued_total / @max(viewers, 1);
}

/// Whether a client may attach with a first screen of `bytes`: the
/// queues have room for it, or hold nothing.
pub fn roomForScreen(bytes: usize) bool {
    const total = queued_total.load(.acquire);
    return total == 0 or total + bytes <= max_queued_total;
}

test "a viewer falls too far behind past its limit, or past its share of a full total" {
    try std.testing.expect(tooFarBehind(max_queue - 10, 11, 0, 1));
    try std.testing.expect(!tooFarBehind(max_queue - 10, 10, 0, 1));
    // 64 viewers share the 64 MiB total: 1 MiB each.
    try std.testing.expect(tooFarBehind(2 << 20, 1, max_queued_total, 64));
    try std.testing.expect(!tooFarBehind(1 << 10, 1, max_queued_total, 64));
    try std.testing.expect(!tooFarBehind(2 << 20, 1, max_queued_total - 1, 64));
}

test "a viewer is not behind for its first frames, however large" {
    const gpa = std.testing.allocator;
    var v: Viewer = .{ .gpa = gpa, .fd = -1, .can_write = .init(false) };
    defer {
        _ = queued_total.fetchSub(v.held, .acq_rel);
        v.queue.deinit(gpa);
    }
    const history = try gpa.alloc(u8, max_queue + 1);
    defer gpa.free(history);
    @memset(history, 'h');
    v.pushInitial(history);
    v.push("out");
    try std.testing.expect(!v.closing);
}

/// Wait until every attach stream has closed, or until `deadline`
/// (monotonic nanoseconds).
pub fn waitClosed(deadline: i64) void {
    while (viewer_count.load(.acquire) > 0 and io_mod.nowNanos() < deadline) {
        std.Io.sleep(io_mod.io(), .fromMilliseconds(5), .boot) catch {};
    }
}

/// Frames built by the session, encoded once and queued to every viewer.
pub fn outFrame(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    return base64Frame(gpa, "out", data, "");
}

/// {"screen":"<base64>","row":T,"wrapped":[Y,...],"continued":true}: T
/// is the number of the primary screen's top row when the screen was
/// taken; the screen rows Y (from 0) wrap into the next, and with
/// `continued` the top row continues the row above it; each is left out
/// when there is nothing to say.
pub fn screenFrame(gpa: std.mem.Allocator, vt_bytes: []const u8, row: u64, wrapped: []const u16, continued: bool) ![]u8 {
    var extra: std.Io.Writer.Allocating = .init(gpa);
    defer extra.deinit();
    try extra.writer.print(",\"row\":{d}", .{row});
    if (wrapped.len > 0) {
        try extra.writer.writeAll(",\"wrapped\":[");
        for (wrapped, 0..) |y, i| try extra.writer.print("{s}{d}", .{ if (i > 0) "," else "", y });
        try extra.writer.writeAll("]");
    }
    if (continued) try extra.writer.writeAll(",\"continued\":true");
    return base64Frame(gpa, "screen", vt_bytes, extra.written());
}

/// The longest line of a history frame.
pub const max_history_line = 256 << 10;
/// The most VT bytes one history frame holds: their base64 and the
/// frame's other fields fit the line.
pub const max_history_bytes = (max_history_line - 64) / 4 * 3;

/// {"history":"<base64>","row":X,"rows":N}: N history rows from row X;
/// without `row` for rows that have no number.
pub fn historyFrame(gpa: std.mem.Allocator, vt_bytes: []const u8, row: ?u64, rows: usize) ![]u8 {
    var buf: [64]u8 = undefined;
    const fields = if (row) |r|
        std.fmt.bufPrint(&buf, ",\"row\":{d},\"rows\":{d}", .{ r, rows }) catch unreachable
    else
        std.fmt.bufPrint(&buf, ",\"rows\":{d}", .{rows}) catch unreachable;
    return base64Frame(gpa, "history", vt_bytes, fields);
}

/// At most this many VT bytes of history go with one attach; past it the
/// oldest of the rows asked for are left out.
pub const max_history_total = 16 << 20;

/// The `history` frames for an attach: the newest `count` rows of the
/// primary screen's history, of those only rows numbered `from` or
/// higher, oldest first; empty when there are none. terminal_mutex must
/// be held, and output settled.
pub fn historyFrames(gpa: std.mem.Allocator, t: *const vt.Terminal, tracker: *const track.Tracker, count: u32, from: ?u64) ![]u8 {
    const top = tracker.historyTop(t) orelse return &.{};
    const screen = t.screens.get(.primary).?;
    const kept = screen.pages.total_rows - screen.pages.rows;
    // A resize keeps the top row's number, so rows it moved into history
    // can be numbered below 0: they have no number.
    var first: i64 = @as(i64, @intCast(top)) - @as(i64, @intCast(@min(@as(u64, kept), count)));
    // A row numbered below numbered_from may have the number of a row
    // that the client has had.
    if (from) |f| {
        if (f >= top) return &.{};
        first = @max(first, @as(i64, @intCast(f)), tracker.numbered_from, 0);
    }
    if (first >= top) return &.{};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Newest first, so the limit leaves out the oldest rows.
    var bytes: std.ArrayList(u8) = .empty;
    var bounds: std.ArrayList([2]usize) = .empty;
    const newest = screen.pages.getTopLeft(.active).up(1) orelse return &.{};
    var it = newest.rowIterator(.left_up, null);
    while (bounds.items.len < @as(i64, @intCast(top)) - first) {
        const pin = it.next() orelse break;
        const start = bytes.items.len;
        try appendHistoryRow(a, &bytes, screen, pin);
        if (bytes.items.len > max_history_total) break;
        try bounds.append(a, .{ start, bytes.items.len });
    }

    var frames: std.ArrayList(u8) = .empty;
    errdefer frames.deinit(gpa);
    var frame_bytes: std.ArrayList(u8) = .empty;
    var row: i64 = @as(i64, @intCast(top)) - @as(i64, @intCast(bounds.items.len));
    var i = bounds.items.len;
    while (i > 0) {
        frame_bytes.clearRetainingCapacity();
        var rows: usize = 0;
        while (i > 0) : (i -= 1) {
            const b = bounds.items[i - 1];
            if (rows > 0 and frame_bytes.items.len + (b[1] - b[0]) > max_history_bytes) break;
            // Rows without a number and numbered ones go in frames apart.
            if (rows > 0 and row < 0 and row + @as(i64, @intCast(rows)) == 0) break;
            try frame_bytes.appendSlice(a, bytes.items[b[0]..b[1]]);
            rows += 1;
        }
        const frame = try historyFrame(a, frame_bytes.items, if (row < 0) null else @intCast(row), rows);
        try frames.appendSlice(gpa, frame);
        row += @intCast(rows);
    }
    return frames.toOwnedSlice(gpa);
}

/// One history row as VT bytes: its cells with their styles and links,
/// then CR LF. A row that wraps into the next gets nothing after it, so a
/// terminal of the session's width wraps it there itself.
fn appendHistoryRow(a: std.mem.Allocator, bytes: *std.ArrayList(u8), screen: *const vt.Screen, pin: vt.Pin) !void {
    const start = bytes.items.len;
    const pad = if (pin.rowAndCell().row.wrap) wrapPadding(pin.cells(.all)) else null;
    try formatRow(a, bytes, screen, pin, .vt, pad == null);
    if (bytes.items.len - start + (pad orelse 2) <= max_history_bytes) {
        if (pad) |n| return bytes.appendNTimes(a, ' ', n);
        return bytes.appendSlice(a, "\r\n");
    }
    // Too long for a frame with its styles and links: the text alone.
    bytes.shrinkRetainingCapacity(start);
    try formatRow(a, bytes, screen, pin, .plain, true);
    var end = bytes.items.len;
    if (end - start > max_history_bytes - 2) {
        end = start + max_history_bytes - 2;
        while (end > start and bytes.items[end] & 0xc0 == 0x80) end -= 1;
    }
    bytes.shrinkRetainingCapacity(end);
    try bytes.appendSlice(a, "\r\n");
}

fn formatRow(a: std.mem.Allocator, bytes: *std.ArrayList(u8), screen: *const vt.Screen, pin: vt.Pin, emit: vt.formatter.Format, trim: bool) !void {
    var w: std.Io.Writer.Allocating = .fromArrayList(a, bytes);
    var formatter = vt.formatter.ScreenFormatter.init(screen, .{ .emit = emit, .trim = trim });
    var left = pin;
    left.x = 0;
    var right = pin;
    right.x = @intCast(pin.cells(.all).len - 1);
    formatter.content = .{ .selection = vt.Selection.init(left, right, false) };
    try formatter.format(&w.writer);
    bytes.* = w.toArrayList();
}

/// How many spaces make a wrapped row's VT bytes end in its last column,
/// so that the next row wraps: the formatter leaves out the empty cells
/// at its end. Null when they cannot end there: after cells with only a
/// background, which the formatter steps over to the last column.
fn wrapPadding(cells: []const vt.Cell) ?usize {
    var end = cells.len;
    // A wide character that did not fit left a spacer; a terminal moves
    // it to the next row itself.
    const spacer = end > 0 and cells[end - 1].wide == .spacer_head;
    if (spacer) end -= 1;
    var n: usize = 0;
    while (end > 0 and cells[end - 1].isEmpty() and !cells[end - 1].hasStyling()) : (end -= 1) n += 1;
    if (n == 0 and !spacer and end > 0) switch (cells[end - 1].content_tag) {
        .bg_color_palette, .bg_color_rgb => return null,
        .codepoint, .codepoint_grapheme => {},
    };
    return n;
}

/// {"key":"<base64 of data>"<fields>}, a line.
fn base64Frame(gpa: std.mem.Allocator, key: []const u8, data: []const u8, fields: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const prefix_len = key.len + 5; // {"key":"
    const end = prefix_len + enc.calcSize(data.len);
    const out = try gpa.alloc(u8, end + 1 + fields.len + 2);
    _ = std.fmt.bufPrint(out, "{{\"{s}\":\"", .{key}) catch unreachable;
    _ = enc.encode(out[prefix_len..end], data);
    out[end] = '"';
    @memcpy(out[end + 1 ..][0..fields.len], fields);
    @memcpy(out[out.len - 2 ..], "}\n");
    return out;
}

/// {"resize":{"cols":C,"rows":R,"seq":N|null}}: the seq of the reflow,
/// null when the size stayed.
pub fn resizeFrame(buf: []u8, cols: u16, rows: u16, seq: ?u64) []const u8 {
    if (seq) |n| return std.fmt.bufPrint(buf, "{{\"resize\":{{\"cols\":{d},\"rows\":{d},\"seq\":{d}}}}}\n", .{ cols, rows, n }) catch unreachable;
    return std.fmt.bufPrint(buf, "{{\"resize\":{{\"cols\":{d},\"rows\":{d},\"seq\":null}}}}\n", .{ cols, rows }) catch unreachable;
}

/// {"exit":{"code":N|null,"signal":"SIGNAME"|null}}; tuppet stores death by
/// signal n as exit code -n.
pub fn exitFrame(buf: []u8, code: i32) []const u8 {
    // A code below -255 is no signal (a damaged stored session); pass it on.
    if (code >= 0 or code <= -256) return std.fmt.bufPrint(buf, "{{\"exit\":{{\"code\":{d},\"signal\":null}}}}\n", .{code}) catch unreachable;
    var name_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{{\"exit\":{{\"code\":null,\"signal\":\"{s}\"}}}}\n", .{signalName(&name_buf, @intCast(-code))}) catch unreachable;
}

/// "SIGKILL" for 9, with the platform's own numbering.
pub fn signalName(buf: []u8, sig: u32) []const u8 {
    if (builtin.os.tag != .windows) {
        if (std.enums.tagName(std.posix.SIG, @fromBackingInt(@intCast(sig)))) |name| {
            return std.fmt.bufPrint(buf, "SIG{s}", .{name}) catch "SIG?";
        }
    }
    return std.fmt.bufPrint(buf, "SIG{d}", .{sig}) catch "SIG?";
}

/// The frames that end a stream on an ended session: the exit with the
/// final status, then the end. terminal_mutex must be held.
pub fn endFramesLocked(gpa: std.mem.Allocator, s: *Session) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = try status.ofLocked(a, s, null);
    const line = try protocol.stringifyAlloc(a, .{ .exit = st.exit orelse status.Exit{}, .status = st });
    return std.mem.concat(gpa, u8, &.{ line, "\n{\"end\":{\"reason\":\"exited\"}}\n" });
}

/// {"error":{"code":...,"err":...}}, for a client frame the daemon
/// rejected.
pub fn errorFrame(gpa: std.mem.Allocator, code: protocol.Code, err: []const u8) ![]u8 {
    const line = try protocol.stringifyAlloc(gpa, .{ .@"error" = .{ .code = @tagName(code), .err = err } });
    defer gpa.free(line);
    return std.mem.concat(gpa, u8, &.{ line, "\n" });
}

test "a viewer whose queue overflowed gives up its batch at once" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer for (fds) |fd| {
        _ = std.c.close(fd);
    };
    var v: Viewer = .{ .gpa = std.testing.allocator, .fd = fds[0], .can_write = .init(false) };
    v.ending.store(true, .release);
    v.overflowed.store(true, .release);
    // More than the socket takes while nobody reads.
    const bytes = try std.testing.allocator.alloc(u8, 16 << 20);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    const started = io_mod.nowNanos();
    try std.testing.expect(!sendAll(&v, bytes, false));
    try std.testing.expect(io_mod.nowNanos() - started < final_line_wait_ns);
}

test "exit frames name signals" {
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("{\"exit\":{\"code\":null,\"signal\":\"SIGKILL\"}}\n", exitFrame(&buf, -9));
}

/// Serve an attach stream on `conn` for session `s` until either side
/// ends it. The caller has replied to nothing yet, holds a reference on
/// `s`, owns `conn`, and closes it afterwards.
pub fn serve(gpa: std.mem.Allocator, conn: *ipc.Conn, s: *Session, req: protocol.AttachReq, rest: []const u8) !void {
    if (viewer_count.fetchAdd(1, .acq_rel) >= max_viewers) {
        _ = viewer_count.fetchSub(1, .acq_rel);
        return error.TooManyViewers;
    }
    defer _ = viewer_count.fetchSub(1, .acq_rel);

    const fd = conn.posix.socket.handle;
    // The stream lives as long as the client wants: no request deadline.
    // Sends are non-blocking (MSG_DONTWAIT) and polled by the sender.
    var no_timeout: std.posix.timeval = .{ .sec = 0, .usec = 0 };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&no_timeout), @sizeOf(std.posix.timeval));

    const write = req.mode == .write;
    var viewer: Viewer = .{
        .gpa = std.heap.page_allocator,
        .fd = fd,
        .can_write = .init(write),
        .passive = req.mode == .preview,
        .redraw_on_resize = req.redraw_on_resize orelse false,
        .history = req.history orelse 0,
        .history_from = req.history_from,
    };
    defer viewer.queue.deinit(viewer.gpa);
    // What the sender left unsent.
    defer _ = queued_total.fetchSub(viewer.held, .acq_rel);
    if (req.label) |label| viewer.label = try status.cleanText(viewer.gpa, label, status.max_label_len);
    defer if (viewer.label) |label| viewer.gpa.free(label);
    const size: ?[2]u16 = if (req.cols) |cols| .{ cols, req.rows.? } else null;
    try s.attachViewer(&viewer, write, req.force, size);
    defer s.detachViewer(&viewer);

    const sender = std.Thread.spawn(.{}, sendLoop, .{&viewer}) catch {
        viewer.finish(null);
        return;
    };
    defer sender.join();
    const end = readLoop(gpa, s, &viewer, rest);
    viewer.finish(end);
}

/// Client frames until EOF, a detach, or a stream error; returns the
/// stream's last frame, if it gets one. `pending` holds bytes the client
/// sent right behind its attach request.
fn readLoop(gpa: std.mem.Allocator, s: *Session, viewer: *Viewer, pending: []const u8) ?[]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, pending) catch return null;
    // While positive, the data frames in the first this many bytes of
    // `buf` belong to a discarded burst.
    var discard: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (true) {
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |end| {
            const verdict = handleFrame(gpa, s, viewer, buf.items[0..end], discard > 0);
            if (verdict == .held_too_long) {
                // The client typed on while held: what it sent so far goes
                // with this frame, all of it, never a part.
                drainReadable(gpa, viewer.fd, &buf);
                discard = buf.items.len;
                if (errorFrame(gpa, .busy, "an input batch held this input too long; it was discarded")) |line| {
                    defer gpa.free(line);
                    viewer.push(line);
                } else |_| {}
                viewer.push(unhold_line);
                s.redrawTo(viewer);
            }
            buf.replaceRange(gpa, 0, end + 1, &.{}) catch return null;
            discard -|= end + 1;
            if (verdict == .detach) return detach_line;
        }
        // Same limit as requests.
        if (buf.items.len >= 1 << 20) {
            return "{\"error\":{\"code\":\"limit\",\"err\":\"frame exceeds the 1 MiB limit\"}}\n";
        }
        const n = std.c.read(viewer.fd, &chunk, chunk.len);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return null;
        }
        buf.appendSlice(gpa, chunk[0..@intCast(n)]) catch return null;
    }
}

/// Append to `buf` what the client has sent and nobody read yet, without
/// waiting for more.
fn drainReadable(gpa: std.mem.Allocator, fd: std.posix.fd_t, buf: *std.ArrayListUnmanaged(u8)) void {
    var chunk: [4096]u8 = undefined;
    while (buf.items.len < 1 << 20) {
        const n = std.c.recv(fd, &chunk, chunk.len, std.c.MSG.DONTWAIT);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return;
        }
        buf.appendSlice(gpa, chunk[0..@intCast(n)]) catch return;
    }
}

const ClientFrame = struct {
    data: ?[]const u8 = null,
    resize: ?struct { cols: u16, rows: u16 } = null,
    detach: bool = false,
};

const Verdict = enum { more, detach, held_too_long };

/// Apply one client frame. `discarding` drops its data: it belongs to a
/// burst that was held too long.
fn handleFrame(gpa: std.mem.Allocator, s: *Session, viewer: *Viewer, line: []const u8, discarding: bool) Verdict {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: protocol.Problem = .{};
    const frame = blk: {
        const value = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch {
            pushError(a, viewer, .bad_request, "a frame must be a JSON object");
            return .more;
        };
        break :blk protocol.decode(ClientFrame, a, value, &problem) catch |err| {
            const msg = if (err == error.BadRequest) problem.message(a) catch return .detach else return .detach;
            pushError(a, viewer, .bad_request, msg);
            return .more;
        };
    };
    if (frame.detach) return .detach;
    if (frame.data == null and frame.resize == null) {
        pushError(a, viewer, .bad_request, "a frame needs data, resize, or detach");
        return .more;
    }
    if (!viewer.can_write.load(.acquire)) {
        pushError(a, viewer, .bad_request, "a read-only attach cannot send input or resize");
        return .more;
    }
    if (frame.data) |b64| if (!discarding) {
        const dec = std.base64.standard.Decoder;
        const len = dec.calcSizeForSlice(b64) catch {
            pushError(a, viewer, .bad_request, "data is not base64");
            return .more;
        };
        const bytes = a.alloc(u8, len) catch return .detach;
        dec.decode(bytes, b64) catch {
            pushError(a, viewer, .bad_request, "data is not base64");
            return .more;
        };
        if (!sendHeld(a, s, viewer, bytes)) return .held_too_long;
    };
    if (frame.resize) |r| {
        if (limits.sizeError(r.cols, r.rows)) |why| {
            pushError(a, viewer, .bad_request, std.fmt.allocPrint(a, "invalid size {d}x{d} ({s})", .{ r.cols, r.rows, why }) catch "invalid size");
        } else {
            if (s.resizeSeq(r.cols, r.rows, .writer, false)) |seq| {
                if (seq != null) {
                    // The client's terminal reflowed its copy of the screen
                    // in its own way: a fresh screen makes the two agree
                    // again. One that asked for it got it with the resize.
                    if (!viewer.redraw_on_resize) s.redrawTo(viewer);
                } else {
                    // Every viewer saw the frame of a resize that took place.
                    var buf: [96]u8 = undefined;
                    viewer.push(resizeFrame(&buf, r.cols, r.rows, null));
                    if (viewer.redraw_on_resize) s.redrawTo(viewer);
                }
            } else |err| pushSessionError(a, viewer, err);
        }
    }
    return .more;
}

/// Send a writer's input. While a batch runs it waits, and the client,
/// which this stream stops reading meanwhile, holds back what it types
/// next: the input keeps its order. False when the hold outlasted the
/// batch, and nothing was sent.
fn sendHeld(a: std.mem.Allocator, s: *Session, viewer: *Viewer, bytes: []const u8) bool {
    var cutoff: ?i64 = null;
    while (true) {
        s.send(bytes) catch |err| switch (err) {
            error.BatchHeld => {
                if (cutoff == null) {
                    const until = s.batch.deadline.load(.acquire);
                    cutoff = @max(until, io_mod.nowNanos()) + hold_margin_ns;
                    viewer.push(hold_line);
                }
                if (!batch_mod.awaitIdle(s, cutoff.?)) return false;
                // Another client may have taken over the writing meanwhile.
                if (!viewer.can_write.load(.acquire)) {
                    pushError(a, viewer, .bad_request, "a read-only attach cannot send input or resize");
                    break;
                }
                continue;
            },
            else => pushSessionError(a, viewer, err),
        };
        break;
    }
    if (cutoff != null) {
        viewer.push(unhold_line);
        s.redrawTo(viewer);
    }
    return true;
}

fn pushError(a: std.mem.Allocator, viewer: *Viewer, code: protocol.Code, err: []const u8) void {
    viewer.push(errorFrame(a, code, err) catch return);
}

fn pushSessionError(a: std.mem.Allocator, viewer: *Viewer, err: anyerror) void {
    switch (err) {
        error.SessionExited => pushError(a, viewer, .ended, "the session has ended"),
        error.InputStalled => pushError(a, viewer, .stalled, "the session stopped reading its input"),
        error.InputBusy => pushError(a, viewer, .busy, "another input to this session is stalled; nothing was sent"),
        error.OverBudget => pushError(a, viewer, .limit, "this terminal's size does not fit the daemon's memory budget (TUPPET_MEMORY); the session keeps its size"),
        else => pushError(a, viewer, .internal, @errorName(err)),
    }
}

/// Send queued frames until the stream closes. A viewer that falls too
/// far behind (`tooFarBehind`) loses its connection; nothing here ever
/// waits on the session.
fn sendLoop(viewer: *Viewer) void {
    const io = io_mod.io();
    defer _ = std.c.shutdown(viewer.fd, std.c.SHUT.RDWR);
    var batch: std.ArrayListUnmanaged(u8) = .empty;
    defer batch.deinit(viewer.gpa);
    while (true) {
        var done = false;
        // Whether `batch` is what an overflow left: its last line.
        var overflow_before = false;
        {
            viewer.mutex.lockUncancelable(io);
            defer viewer.mutex.unlock(io);
            while (viewer.queue.items.len == 0 and !viewer.closing) viewer.cond.waitUncancelable(io, &viewer.mutex);
            std.mem.swap(std.ArrayListUnmanaged(u8), &batch, &viewer.queue);
            done = viewer.closing;
            overflow_before = viewer.overflowed.load(.acquire);
        }
        if (!sendAll(viewer, batch.items, overflow_before)) {
            if (viewer.overflowed.load(.acquire) and !overflow_before) {
                // The abandoned batch may end mid-frame: finish that line
                // first, so the error arrives as a line of its own.
                _ = sendAll(viewer, "\n" ++ too_slow_line, true);
            }
            return;
        }
        viewer.mutex.lockUncancelable(io);
        viewer.forget(batch.items.len);
        // The initial frames were queued first, so they are sent first.
        viewer.initial -|= batch.items.len;
        const empty = viewer.queue.items.len == 0;
        viewer.mutex.unlock(io);
        batch.clearRetainingCapacity();
        if (done and empty) return;
    }
}

/// Write `bytes` without ever blocking for long: gives up when the
/// viewer's queue overflows meanwhile, or, for a final line or a stream
/// that is ending (exit, detach), after a second without progress, so a
/// client that stopped reading cannot hold the session.
fn sendAll(viewer: *Viewer, bytes: []const u8, final: bool) bool {
    var last_progress = io_mod.nowNanos();
    var i: usize = 0;
    while (i < bytes.len) {
        // macOS sockets have SO_NOSIGPIPE set at accept instead.
        const no_signal = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;
        const n = std.c.sendto(viewer.fd, bytes.ptr + i, bytes.len - i, std.c.MSG.DONTWAIT | no_signal, null, 0);
        if (n > 0) {
            i += @intCast(n);
            last_progress = io_mod.nowNanos();
            continue;
        }
        switch (std.posix.errno(n)) {
            .INTR => {},
            .AGAIN => {
                // An overflow ends the stream too, but its batch is
                // given up at once.
                if (!final and viewer.overflowed.load(.acquire)) return false;
                if (final or viewer.ending.load(.acquire)) {
                    if (io_mod.nowNanos() - last_progress >= final_line_wait_ns) return false;
                }
                var pfd = [1]std.c.pollfd{.{ .fd = viewer.fd, .events = std.c.POLL.OUT, .revents = 0 }};
                _ = std.c.poll(&pfd, 1, 100);
            },
            else => return false,
        }
    }
    return true;
}

const HistoryFixture = struct {
    term: vt.Terminal,
    stream: vt.TerminalStream,
    seqs: track.Counter = .{},
    tracker: track.Tracker,

    fn create(cols: u16, rows: u16, scrollback: usize) !*HistoryFixture {
        const gpa = std.testing.allocator;
        const f = try gpa.create(HistoryFixture);
        errdefer gpa.destroy(f);
        f.* = .{ .term = undefined, .stream = undefined, .tracker = undefined };
        f.term = try vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = scrollback });
        errdefer f.term.deinit(gpa);
        var handler = f.term.vtHandler();
        handler.effects = .readonly;
        f.stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = gpa });
        const start = f.seqs.next();
        f.tracker = try .init(gpa, &f.seqs, &f.term, start, start, 0);
        return f;
    }

    fn destroy(f: *HistoryFixture) void {
        const gpa = std.testing.allocator;
        f.tracker.deinit(&f.term);
        f.stream.deinit();
        f.term.deinit(gpa);
        gpa.destroy(f);
    }

    fn feed(f: *HistoryFixture, bytes: []const u8) void {
        f.stream.nextSlice(bytes);
        f.tracker.noteParsed(bytes.len, 0);
        f.tracker.settle(&f.term, 0);
    }

    /// A frame's first row when its rows have no number.
    const no_row = std.math.maxInt(u64);

    /// The history frames' bytes, and each frame's first row and rows.
    fn history(f: *HistoryFixture, a: std.mem.Allocator, count: u32, from: ?u64) !struct { bytes: []u8, frames: [][2]u64 } {
        const lines = try historyFrames(a, &f.term, &f.tracker, count, from);
        var bytes: std.ArrayList(u8) = .empty;
        var frames: std.ArrayList([2]u64) = .empty;
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(line.len < max_history_line);
            const frame = try std.json.parseFromSliceLeaky(struct { history: []const u8, row: ?u64 = null, rows: u64 }, a, line, .{});
            const dec = std.base64.standard.Decoder;
            const raw = try a.alloc(u8, try dec.calcSizeForSlice(frame.history));
            try dec.decode(raw, frame.history);
            try bytes.appendSlice(a, raw);
            try frames.append(a, .{ frame.row orelse no_row, frame.rows });
        }
        return .{ .bytes = bytes.items, .frames = frames.items };
    }
};

test "history frames give the rows in order, wrapped where the session wrapped them, split between rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try HistoryFixture.create(10, 3, 1 << 20);
    defer f.destroy();
    // A wide character that does not fit wraps with an empty cell left.
    f.feed("\x1b[31mred\x1b[0m\r\n0123456789abcde\r\n123456789\xe7\x95\x8c\r\nx\r\ny\r\nz");
    const got = try f.history(a, 10, null);
    try std.testing.expectEqualStrings("\x1b[0m\x1b[38;5;1mred\x1b[0m\r\n0123456789abcde\r\n123456789\xe7\x95\x8c\r\n", got.bytes);
    try std.testing.expectEqualSlices([2]u64, &.{.{ 0, 5 }}, got.frames);
    // A terminal of the session's width shows them as the session did.
    var copy = try vt.Terminal.init((vt.TinyIo.init).io(), std.testing.allocator, .{ .cols = 10, .rows = 6 });
    defer copy.deinit(std.testing.allocator);
    var handler = copy.vtHandler();
    handler.effects = .readonly;
    var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = std.testing.allocator });
    defer stream.deinit();
    stream.nextSlice(got.bytes);
    var same = vt.formatter.TerminalFormatter.init(&copy, .{ .emit = .plain, .unwrap = true });
    var text: std.Io.Writer.Allocating = .init(a);
    try same.format(&text.writer);
    try std.testing.expectEqualStrings("red\n0123456789abcde\n123456789\xe7\x95\x8c", text.written());

    // More rows than one frame holds.
    const g = try HistoryFixture.create(100, 2, 64 << 20);
    defer g.destroy();
    var flood: std.ArrayList(u8) = .empty;
    for (0..2500) |i| try flood.print(a, "{d:0>99}\r\n", .{i});
    g.feed(flood.items);
    const many = try g.history(a, 3000, null);
    try std.testing.expectEqual(@as(usize, 2), many.frames.len);
    try std.testing.expectEqual(@as(u64, 0), many.frames[0][0]);
    try std.testing.expectEqual(many.frames[0][1], many.frames[1][0]);
    // The last line and the empty one below it are on the screen.
    try std.testing.expectEqual(@as(u64, 2499), many.frames[0][1] + many.frames[1][1]);
}

test "rows a resize moves into history below row 0 come without a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try HistoryFixture.create(10, 5, 1 << 20);
    defer f.destroy();
    f.feed("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng");
    try std.testing.expectEqual(@as(i64, 2), f.tracker.top(.primary));
    // A shorter screen moves three more rows into history and keeps the
    // top row's number.
    var reflow = f.tracker.beginReflow(&f.term, 0);
    defer reflow.deinit(std.testing.allocator);
    try f.term.resize(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    _ = f.tracker.endReflow(&f.term, &reflow, 0, true);
    try std.testing.expectEqual(@as(i64, 2), f.tracker.top(.primary));
    const all = try f.history(a, 100, null);
    try std.testing.expectEqualStrings("a\r\nb\r\nc\r\nd\r\ne\r\n", all.bytes);
    try std.testing.expectEqualSlices([2]u64, &.{ .{ HistoryFixture.no_row, 3 }, .{ 0, 2 } }, all.frames);
    // A client that had rows from a number on gets none of them.
    try std.testing.expectEqualSlices([2]u64, &.{.{ 0, 2 }}, (try f.history(a, 100, 0)).frames);
}

test "history rows keep their numbers after scrolling and after the limit dropped old ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Wide rows fill the smallest history quickly.
    const f = try HistoryFixture.create(400, 5, 1);
    defer f.destroy();
    for (0..100) |chunk| {
        var lines: std.ArrayList(u8) = .empty;
        for (chunk * 4..chunk * 4 + 4) |i| try lines.print(a, "line {d}\r\n", .{i});
        f.feed(lines.items);
    }
    try std.testing.expect(f.tracker.history_dropped);
    try std.testing.expectEqual(@as(i64, 0), f.tracker.numbered_from);
    // Line i is on row i.
    const top: u64 = @intCast(f.tracker.top(.primary));
    const last = try f.history(a, 2, null);
    try std.testing.expectEqualSlices([2]u64, &.{.{ top - 2, 2 }}, last.frames);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "line {d}\r\nline {d}\r\n", .{ top - 2, top - 1 }), last.bytes);
    // Only the rows from a number on, and of those the last ones asked for.
    try std.testing.expectEqualSlices([2]u64, &.{.{ top - 3, 3 }}, (try f.history(a, 100, top - 3)).frames);
    try std.testing.expectEqualSlices([2]u64, &.{.{ top - 1, 1 }}, (try f.history(a, 1, top - 3)).frames);
    try std.testing.expectEqual(@as(usize, 0), (try f.history(a, 100, top)).frames.len);
    try std.testing.expectEqual(@as(usize, 0), (try f.history(a, 100, std.math.maxInt(u64))).frames.len);

    // Rows that went by unseen: their numbers may repeat earlier ones, so
    // a client fetching what it missed gets only rows after them.
    var flood: std.ArrayList(u8) = .empty;
    for (400..1000) |i| try flood.print(a, "line {d}\r\n", .{i});
    f.feed(flood.items);
    const from: u64 = @intCast(f.tracker.numbered_from);
    try std.testing.expect(from > top);
    f.feed("after\r\n");
    try std.testing.expectEqualSlices([2]u64, &.{.{ from, 1 }}, (try f.history(a, 100, top)).frames);

    // A taller screen pulls rows back out of history: the rows left there
    // get higher numbers, and those pulled out get new ones when they
    // scroll back.
    const before: u64 = @intCast(f.tracker.top(.primary));
    var reflow = f.tracker.beginReflow(&f.term, 0);
    defer reflow.deinit(std.testing.allocator);
    try f.term.resize(std.testing.allocator, .{ .cols = 400, .rows = 8 });
    _ = f.tracker.endReflow(&f.term, &reflow, 0, true);
    try std.testing.expectEqual(@as(u64, before), @as(u64, @intCast(f.tracker.top(.primary))));
    try std.testing.expectEqual(@as(i64, @intCast(before + 3)), f.tracker.numbered_from);
    try std.testing.expectEqual(@as(usize, 0), (try f.history(a, 100, 0)).frames.len);
}
