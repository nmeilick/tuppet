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
        if (limited and tooFarBehind(v.held, line.len, queued_total.load(.acquire), viewer_count.load(.acquire))) {
            v.forget(v.queue.items.len);
            v.queue.clearRetainingCapacity();
            v.queueLocked(too_slow_line) catch {};
            v.closing = true;
            v.ending.store(true, .release);
            v.overflowed.store(true, .release);
        } else {
            v.queueLocked(line) catch {
                v.closing = true;
                v.ending.store(true, .release);
            };
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

/// Wait until every attach stream has closed, or until `deadline`
/// (monotonic nanoseconds).
pub fn waitClosed(deadline: i64) void {
    while (viewer_count.load(.acquire) > 0 and io_mod.nowNanos() < deadline) {
        std.Io.sleep(io_mod.io(), .fromMilliseconds(5), .boot) catch {};
    }
}

/// Frames built by the session, encoded once and queued to every viewer.
pub fn outFrame(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    return base64Frame(gpa, "out", data);
}

pub fn screenFrame(gpa: std.mem.Allocator, vt_bytes: []const u8) ![]u8 {
    return base64Frame(gpa, "screen", vt_bytes);
}

fn base64Frame(gpa: std.mem.Allocator, key: []const u8, data: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const prefix_len = key.len + 5; // {"key":"
    const out = try gpa.alloc(u8, prefix_len + enc.calcSize(data.len) + 3);
    _ = std.fmt.bufPrint(out, "{{\"{s}\":\"", .{key}) catch unreachable;
    _ = enc.encode(out[prefix_len..][0..enc.calcSize(data.len)], data);
    @memcpy(out[out.len - 3 ..], "\"}\n");
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
    var viewer: Viewer = .{ .gpa = std.heap.page_allocator, .fd = fd, .can_write = .init(write), .passive = req.mode == .preview };
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
                // The client's terminal reflowed its copy of the screen in
                // its own way: a fresh screen makes the two agree again.
                if (seq != null) s.redrawTo(viewer) else {
                    // Every viewer saw the frame of a resize that took place.
                    var buf: [96]u8 = undefined;
                    viewer.push(resizeFrame(&buf, r.cols, r.rows, null));
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
        {
            viewer.mutex.lockUncancelable(io);
            defer viewer.mutex.unlock(io);
            while (viewer.queue.items.len == 0 and !viewer.closing) viewer.cond.waitUncancelable(io, &viewer.mutex);
            std.mem.swap(std.ArrayListUnmanaged(u8), &batch, &viewer.queue);
            done = viewer.closing;
        }
        const overflow_before = viewer.overflowed.load(.acquire);
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
                if (final or viewer.ending.load(.acquire)) {
                    if (io_mod.nowNanos() - last_progress >= final_line_wait_ns) return false;
                } else if (viewer.overflowed.load(.acquire)) {
                    return false;
                }
                var pfd = [1]std.c.pollfd{.{ .fd = viewer.fd, .events = std.c.POLL.OUT, .revents = 0 }};
                _ = std.c.poll(&pfd, 1, 100);
            },
            else => return false,
        }
    }
    return true;
}
