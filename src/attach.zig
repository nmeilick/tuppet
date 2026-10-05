//! Live attach: after the attach reply, a connection becomes a two-way
//! JSON-lines stream between one client and a session (see
//! docs/protocol.md). Any number of read-only viewers and at most one
//! writer share a session. Output reaches each viewer through its own
//! bounded queue and sender thread, so a slow viewer never blocks the
//! session, the daemon, or other viewers: when its queue overflows it
//! is disconnected.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;

/// Output queued for one viewer before it counts as too slow.
pub const max_queue = 4 << 20;
/// How long the daemon keeps trying to deliver the final "too slow" line.
const final_line_wait_ns: i64 = std.time.ns_per_s;
/// Attached clients across all sessions; each holds two threads.
const max_viewers = 256;

const too_slow_line = "{\"error\":\"too slow; reattach\"}\n";

var viewer_count: std.atomic.Value(usize) = .{ .raw = 0 };

pub const Viewer = struct {
    gpa: std.mem.Allocator,
    fd: std.posix.fd_t,
    /// May send input; cleared when a forced attach takes over.
    can_write: std.atomic.Value(bool),
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
        if (limited and v.queue.items.len + line.len > max_queue) {
            v.queue.clearRetainingCapacity();
            v.queue.appendSlice(v.gpa, too_slow_line) catch {};
            v.closing = true;
            v.ending.store(true, .release);
            v.overflowed.store(true, .release);
        } else {
            v.queue.appendSlice(v.gpa, line) catch {
                v.closing = true;
                v.ending.store(true, .release);
            };
        }
        v.cond.signal(io);
    }

    /// Queue a last frame (if any) and let the stream end after it.
    pub fn finish(v: *Viewer, last: ?[]const u8) void {
        const io = io_mod.io();
        v.mutex.lockUncancelable(io);
        defer v.mutex.unlock(io);
        if (!v.closing) {
            if (last) |line| v.queue.appendSlice(v.gpa, line) catch {};
            v.closing = true;
            v.ending.store(true, .release);
        }
        v.cond.signal(io);
    }
};

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

pub fn resizeFrame(buf: []u8, cols: u16, rows: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"resize\":{{\"cols\":{d},\"rows\":{d}}}}}\n", .{ cols, rows }) catch unreachable;
}

/// {"exit":{"code":N|null,"signal":"SIGNAME"|null}}; tuppet stores death by
/// signal n as exit code -n.
pub fn exitFrame(buf: []u8, code: i32) []const u8 {
    // A code below -255 is no signal (a damaged stored session); pass it on.
    if (code >= 0 or code <= -256) return std.fmt.bufPrint(buf, "{{\"exit\":{{\"code\":{d},\"signal\":null}}}}\n", .{code}) catch unreachable;
    var name_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{{\"exit\":{{\"code\":null,\"signal\":\"{s}\"}}}}\n", .{signalName(&name_buf, @intCast(-code))}) catch unreachable;
}

/// How a program ended, for people: "exited 7", "killed SIGTERM", or the
/// raw code when it is no signal tuppet knows.
pub fn exitText(buf: []u8, code: i32) []const u8 {
    if (code >= 0) return std.fmt.bufPrint(buf, "exited {d}", .{code}) catch "exited";
    if (code <= -256) return std.fmt.bufPrint(buf, "exited {d}", .{code}) catch "exited";
    var sig_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "killed {s}", .{signalName(&sig_buf, @intCast(-code))}) catch "killed";
}

/// "SIGKILL" for 9, with the platform's own numbering.
pub fn signalName(buf: []u8, sig: u32) []const u8 {
    if (builtin.os.tag != .windows) {
        if (std.enums.tagName(std.posix.SIG, @enumFromInt(sig))) |name| {
            return std.fmt.bufPrint(buf, "SIG{s}", .{name}) catch "SIG?";
        }
    }
    return std.fmt.bufPrint(buf, "SIG{d}", .{sig}) catch "SIG?";
}

test "exit frames name signals" {
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("{\"exit\":{\"code\":null,\"signal\":\"SIGKILL\"}}\n", exitFrame(&buf, -9));
}

const AttachReq = struct {
    cmd: []const u8 = "attach",
    id: []const u8,
    mode: []const u8 = "read",
    force: bool = false,
};

/// Serve an attach request on `conn` until either side ends the stream.
/// The caller owns `conn` and closes it afterwards.
pub fn serve(gpa: std.mem.Allocator, conn: *ipc.Conn, line: []const u8, rest: []const u8) void {
    if (builtin.os.tag == .windows) {
        conn.sendLine("{\"ok\":false,\"err\":\"attach is not supported on Windows\"}") catch {};
        return;
    }
    const req = std.json.parseFromSliceLeaky(AttachReq, gpa, line, .{}) catch {
        conn.sendLine("{\"ok\":false,\"err\":\"bad attach request\"}") catch {};
        return;
    };
    const write = if (std.mem.eql(u8, req.mode, "write"))
        true
    else if (std.mem.eql(u8, req.mode, "read"))
        false
    else {
        conn.sendLine("{\"ok\":false,\"err\":\"mode must be read or write\"}") catch {};
        return;
    };
    const id = protocol.parseDecimal(u64, req.id) orelse {
        conn.sendLine("{\"ok\":false,\"err\":\"invalid session id\"}") catch {};
        return;
    };
    const s = session_mod.acquire(id) orelse {
        const reason = session_mod.missingReason(gpa, id) orelse std.fmt.allocPrint(gpa, "no session with id {d}", .{id}) catch null;
        const reply = protocol.stringifyAlloc(gpa, .{ .ok = false, .err = reason orelse "no such session" }) catch return;
        conn.sendLine(reply) catch {};
        return;
    };
    defer session_mod.release(s);

    if (viewer_count.fetchAdd(1, .acq_rel) >= max_viewers) {
        _ = viewer_count.fetchSub(1, .acq_rel);
        conn.sendLine("{\"ok\":false,\"err\":\"too many attached clients\"}") catch {};
        return;
    }
    defer _ = viewer_count.fetchSub(1, .acq_rel);

    const fd = conn.posix.socket.handle;
    // The stream lives as long as the client wants: no request deadline.
    // Sends are non-blocking (MSG_DONTWAIT) and polled by the sender.
    var no_timeout: std.posix.timeval = .{ .sec = 0, .usec = 0 };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&no_timeout), @sizeOf(std.posix.timeval));

    var viewer: Viewer = .{ .gpa = std.heap.page_allocator, .fd = fd, .can_write = .init(write) };
    defer viewer.queue.deinit(viewer.gpa);
    s.attachViewer(&viewer, write, req.force) catch |err| {
        const msg = switch (err) {
            error.WriterAttached => "{\"ok\":false,\"err\":\"session already has a writer (attach with --force to take over)\"}",
            else => "{\"ok\":false,\"err\":\"cannot attach\"}",
        };
        conn.sendLine(msg) catch {};
        return;
    };
    defer s.detachViewer(&viewer);

    const sender = std.Thread.spawn(.{}, sendLoop, .{&viewer}) catch {
        viewer.finish(null);
        return;
    };
    defer sender.join();
    defer viewer.finish(null);
    readLoop(gpa, s, &viewer, rest);
}

/// Client frames until EOF, a detach, or a stream error. `pending` holds
/// bytes the client sent right behind its attach request.
fn readLoop(gpa: std.mem.Allocator, s: *Session, viewer: *Viewer, pending: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, pending) catch return;
    var chunk: [4096]u8 = undefined;
    while (true) {
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |end| {
            const keep_going = handleFrame(gpa, s, viewer, buf.items[0..end]);
            buf.replaceRange(gpa, 0, end + 1, &.{}) catch return;
            if (!keep_going) return;
        }
        // Same limit as requests.
        if (buf.items.len >= 1 << 20) {
            viewer.finish("{\"error\":\"frame exceeds the 1 MiB limit\"}\n");
            return;
        }
        const n = std.c.read(viewer.fd, &chunk, chunk.len);
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

/// Apply one client frame; false ends the stream.
fn handleFrame(gpa: std.mem.Allocator, s: *Session, viewer: *Viewer, line: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = std.json.parseFromSliceLeaky(ClientFrame, a, line, .{ .ignore_unknown_fields = true }) catch {
        viewer.push("{\"error\":\"bad frame\"}\n");
        return true;
    };
    if (frame.detach) return false;
    if (frame.data == null and frame.resize == null) {
        viewer.push("{\"error\":\"frame needs data, resize, or detach\"}\n");
        return true;
    }
    if (!viewer.can_write.load(.acquire)) {
        viewer.push("{\"error\":\"read-only attach cannot send input or resize\"}\n");
        return true;
    }
    if (frame.data) |b64| {
        const dec = std.base64.standard.Decoder;
        const len = dec.calcSizeForSlice(b64) catch {
            viewer.push("{\"error\":\"data is not base64\"}\n");
            return true;
        };
        const bytes = a.alloc(u8, len) catch return false;
        dec.decode(bytes, b64) catch {
            viewer.push("{\"error\":\"data is not base64\"}\n");
            return true;
        };
        s.send(bytes) catch |err| pushError(a, viewer, err);
    }
    if (frame.resize) |r| {
        if (r.cols < 1 or r.cols > 1000 or r.rows < 1 or r.rows > 1000) {
            viewer.push("{\"error\":\"invalid size (both dimensions must be 1..1000)\"}\n");
        } else {
            s.resize(r.cols, r.rows) catch |err| pushError(a, viewer, err);
        }
    }
    return true;
}

fn pushError(a: std.mem.Allocator, viewer: *Viewer, err: anyerror) void {
    const text = switch (err) {
        error.SessionExited => "session has exited",
        error.InputStalled => "the session stopped reading its input",
        error.InputBusy => "another input to this session is stalled; nothing was sent",
        else => @errorName(err),
    };
    const line = protocol.stringifyAlloc(a, .{ .@"error" = text }) catch return;
    const with_nl = std.mem.concat(a, u8, &.{ line, "\n" }) catch return;
    viewer.push(with_nl);
}

/// Send queued frames until the stream closes. A viewer that falls
/// behind by more than `max_queue` loses its connection; nothing here
/// ever waits on the session.
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
        batch.clearRetainingCapacity();
        if (done) {
            viewer.mutex.lockUncancelable(io);
            const empty = viewer.queue.items.len == 0;
            viewer.mutex.unlock(io);
            if (empty) return;
        }
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
