//! A session's pty I/O: the reader loop that parses child output, input
//! writes that cannot wedge on a child that stops reading, and the
//! `write_pty` and other vt effects that answer the child's queries.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const io_mod = @import("io.zig");
const pty_mod = @import("pty.zig");
const trace_mod = @import("trace.zig");
const protocol = @import("protocol.zig");
const attach = @import("attach.zig");
const record = @import("record.zig");
const store = @import("store.zig");
const registry = @import("registry.zig");
const session_mod = @import("session.zig");
const evaluator = @import("evaluator.zig");
const sample = @import("sample.zig");
const status = @import("status.zig");
const events = @import("events.zig");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else @import("win32_stub.zig");

const Session = session_mod.Session;

/// How long an input write may make no progress (the child is not
/// reading) before the request fails. Below the client's 10 s request
/// timeout so the caller gets the real reason.
const input_stall_ns: i64 = 5 * std.time.ns_per_s;
/// After this long without progress, other writers stop queueing.
const stall_notice_ns: i64 = 200 * std.time.ns_per_ms;
/// An input waits at most this long for output already pending on the pty
/// to be settled, so its input_seq covers that output.
const input_settle_wait_ns: i64 = 50 * std.time.ns_per_ms;

/// After the child exits, output it wrote just before exiting is still
/// read until the pty has been quiet this long, capped at
/// `exit_drain_max_ns`. A background process that keeps the pty open
/// cannot hold the session in "running".
const exit_drain_idle_ms: c_int = 50;
const exit_drain_max_ns: i64 = 1 * std.time.ns_per_s;

/// POSIX only; unused (and never opened) on Windows.
pub const WakeFd = if (builtin.os.tag == .windows) i32 else std.c.fd_t;

pub fn closeWakePipe(pipe: *[2]WakeFd) void {
    if (builtin.os.tag == .windows) return;
    for (pipe) |*fd| {
        if (fd.* >= 0) _ = std.c.close(fd.*);
        fd.* = -1;
    }
}

/// Reads child output until the pty closes, or until the child has
/// exited and the remaining output is drained, then marks the
/// session exited.
pub fn readerLoop(s: *Session) void {
    var buf: [32 * 1024]u8 = undefined;
    switch (builtin.os.tag) {
        .windows => while (true) {
            s.track.beginRead();
            const n = ptyRead(s, &buf) catch 0;
            s.track.endRead(n);
            if (n == 0) break;
            _ = consumeOutput(s, buf[0..n], .unknown);
        },
        else => readPosix(s, &buf),
    }
    settleRest(s);
    // The exit code comes from the waiter. If the pty closed while
    // the child still runs (it closed its stdio), this waits for it.
    if (s.waiter) |waiter| waiter.join();
    s.waiter = null;
    if (s.stopped.load(.acquire)) s.markStopSeen();
    s.ended_ms.store(store.nowMillis(), .release);
    s.end_seq.store(s.track.counter.next(), .release);
    s.state.store(.exited, .release);
    s.track.notify();
    releasePty(s);
    {
        // Attached clients get the exit event and the final status, then
        // their stream ends.
        const io = io_mod.io();
        s.terminal_mutex.lockUncancelable(io);
        defer s.terminal_mutex.unlock(io);
        const frames = attach.endFramesLocked(s.gpa, s) catch null;
        defer if (frames) |f| s.gpa.free(f);
        var exit_buf: [80]u8 = undefined;
        const fallback = attach.exitFrame(&exit_buf, s.exit_code.load(.acquire));
        for (s.viewers.items) |v| v.finish(frames orelse fallback);
    }
    // The evaluator's last pass stops a recording whose conditions it
    // checks; any other ends here.
    evaluator.finish(s);
    record.stopRecording(s, .ended);
    s.persist();
    events.publish(s.id, .ended, .{});
    // After the ended event: a daemon that shuts down once its sessions
    // settled still tells its event streams.
    s.settled.store(true, .release);
}

/// Whether more output waits on the pty after a chunk.
const Pending = enum { more, drained, unknown };

/// Parse one chunk of child output, answer its queries, record it, and
/// settle it when it is due (always when `pending` is unknown). Returns
/// when unsettled output must be settled even without more output.
fn consumeOutput(s: *Session, data: []const u8, pending: Pending) ?i64 {
    const io = io_mod.io();
    const now = io_mod.nowNanos();
    s.terminal_mutex.lockUncancelable(io);
    const bells = s.bell_count.load(.monotonic) +% s.notification_count.load(.monotonic);
    s.stream.nextSlice(data);
    // The evaluator reports them, also when nothing is settled.
    const rang = s.bell_count.load(.monotonic) +% s.notification_count.load(.monotonic) != bells;
    s.track.noteParsed(data.len, now);
    const grew = s.chargeLocked();
    const settle = pending == .unknown or s.track.settleDue(&s.terminal, now, pending == .drained);
    if (settle) s.track.settle(&s.terminal, now);
    const settle_at = s.track.settleDeadline();
    if (s.viewers.items.len > 0) {
        if (attach.outFrame(s.gpa, data)) |frame| {
            defer s.gpa.free(frame);
            s.broadcastLocked(frame);
        } else |_| {}
    }
    const has_replies = s.pending_replies.items.len > 0;
    s.terminal_mutex.unlock(io);
    if (settle or rang) s.track.notify();
    if (has_replies) _ = tryFlushReplies(s);
    if (grew) registry.wantTrim();
    if (s.recording_active.load(.acquire) and !s.recording_trace.load(.acquire)) record.recordOutput(s, data);
    s.last_output.store(now, .monotonic);
    return settle_at;
}

/// Settle parsed output once it is due without more output arriving.
fn settlePending(s: *Session) ?i64 {
    const io = io_mod.io();
    const now = io_mod.nowNanos();
    s.terminal_mutex.lockUncancelable(io);
    const settle = s.track.settleDue(&s.terminal, now, true);
    if (settle) s.track.settle(&s.terminal, now);
    const settle_at = s.track.settleDeadline();
    s.terminal_mutex.unlock(io);
    if (settle) s.track.notify();
    return settle_at;
}

/// Settle whatever output is left once the pty is done.
fn settleRest(s: *Session) void {
    const io = io_mod.io();
    s.terminal_mutex.lockUncancelable(io);
    const settle = s.track.unsettled();
    if (settle) s.track.settle(&s.terminal, io_mod.nowNanos());
    s.terminal_mutex.unlock(io);
    if (settle) s.track.notify();
}

/// An ended session needs no pty: closing it (and the wake pipe, whose
/// writer is gone) keeps a long-lived daemon within its descriptor limit.
fn releasePty(s: *Session) void {
    const io = io_mod.io();
    s.write_mutex.lockUncancelable(io);
    defer s.write_mutex.unlock(io);
    s.terminal_mutex.lockUncancelable(io);
    defer s.terminal_mutex.unlock(io);
    pty_mod.close(&s.pty);
    closeWakePipe(&s.wake_pipe);
}

fn readPosix(s: *Session, buf: []u8) void {
    const master = s.pty.posix.master;
    const POLL = std.c.POLL;
    // Set once the child has been reaped: keep reading until the pty
    // goes quiet, but never past this deadline.
    var drain_end: ?i64 = null;
    // A writer holds write_mutex and will flush the queued replies; do
    // not spin on POLLOUT meanwhile.
    var replies_busy = false;
    // Parsed output not settled yet must be by then.
    var settle_at: ?i64 = null;
    while (true) {
        var fds = [2]std.c.pollfd{
            .{ .fd = master, .events = POLL.IN, .revents = 0 },
            .{ .fd = s.wake_pipe[0], .events = POLL.IN, .revents = 0 },
        };
        if (!replies_busy and hasPendingReplies(s)) fds[0].events |= POLL.OUT;
        var timeout_ms: c_int = -1;
        var nfds: std.c.nfds_t = 2;
        const now = io_mod.nowNanos();
        if (drain_end) |end| {
            const left_ms = @divTrunc(end - now, std.time.ns_per_ms);
            if (left_ms <= 0) return;
            timeout_ms = @intCast(@min(left_ms, exit_drain_idle_ms));
            nfds = 1;
        } else if (replies_busy) {
            timeout_ms = 10;
        }
        var settle_wait = false;
        if (settle_at) |at| {
            if (at <= now) {
                settle_at = settlePending(s);
                continue;
            }
            const left_ms: c_int = @intCast(@min(std.math.divCeil(i64, at - now, std.time.ns_per_ms) catch 1, 1000));
            if (timeout_ms < 0 or left_ms < timeout_ms) {
                timeout_ms = left_ms;
                settle_wait = true;
            }
        }
        const rc = std.c.poll(&fds, nfds, timeout_ms);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return;
        }
        if (rc == 0) {
            if (settle_wait) continue;
            if (drain_end != null) return;
            replies_busy = false;
            continue;
        }
        if (nfds == 2 and fds[1].revents & POLL.IN != 0) {
            var byte: [1]u8 = undefined;
            _ = std.c.read(s.wake_pipe[0], &byte, 1);
            if (s.child_exited.load(.acquire)) drain_end = io_mod.nowNanos() + exit_drain_max_ns;
        }
        if (fds[0].revents & POLL.OUT != 0) {
            replies_busy = tryFlushReplies(s) == .busy;
        }
        if (fds[0].revents & (POLL.IN | POLL.HUP | POLL.ERR) != 0) {
            s.track.beginRead();
            const n = std.c.read(master, buf.ptr, buf.len);
            s.track.endRead(if (n > 0) @intCast(n) else 0);
            if (n > 0) {
                settle_at = consumeOutput(s, buf[0..@intCast(n)], if (hasOutput(master)) .more else .drained);
            } else if (n == 0) {
                return;
            } else switch (std.posix.errno(n)) {
                .INTR, .AGAIN => {},
                // EIO: every slave descriptor is closed.
                else => return,
            }
        }
    }
}

fn hasOutput(master: std.c.fd_t) bool {
    var pfd = [1]std.c.pollfd{.{ .fd = master, .events = std.c.POLL.IN, .revents = 0 }};
    return std.c.poll(&pfd, 1, 0) > 0 and pfd[0].revents & std.c.POLL.IN != 0;
}

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

pub fn pasteBytes(gpa: std.mem.Allocator, text: []const u8, bracketed: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (bracketed) try out.appendSlice(gpa, paste_start);
    const body = out.items.len;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        try out.append(gpa, if (text[i] == '\n') '\r' else text[i]);
        // Dropping each end marker as it forms keeps the body free of
        // them, even when a removal joins the bytes around it.
        if (bracketed and std.mem.endsWith(u8, out.items[body..], paste_end))
            out.shrinkRetainingCapacity(out.items.len - paste_end.len);
    }
    if (bracketed) try out.appendSlice(gpa, paste_end);
    return out.toOwnedSlice(gpa);
}

test "paste normalizes line endings and cannot end its bracket early" {
    const plain = try pasteBytes(std.testing.allocator, "a\r\nb\nc", false);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("a\rb\rc", plain);
    const wrapped = try pasteBytes(std.testing.allocator, "x\x1b[201~y\n", true);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("\x1b[200~xy\r\x1b[201~", wrapped);
    const nested = try pasteBytes(std.testing.allocator, "A\x1b[20\x1b[201~1~B", true);
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("\x1b[200~AB\x1b[201~", nested);
}

// --- Platform helpers ---------------------------------------------------

pub fn hasPendingReplies(s: *Session) bool {
    const io = io_mod.io();
    s.terminal_mutex.lockUncancelable(io);
    defer s.terminal_mutex.unlock(io);
    return s.pending_replies.items.len > 0;
}

/// Write input to the pty and record it. The input event is recorded
/// first so a trace never shows the screen reacting before the input;
/// a failed write is followed by a marker saying so. Every input becomes
/// the session's latest one (`markInput`) before its first byte. While an
/// input batch runs, nothing is written and this fails with
/// error.BatchHeld, so the caller can wait and keep its input in order.
pub fn writeInput(s: *Session, data: []const u8, input: trace_mod.Input) !void {
    if (s.batch.active.load(.acquire)) return error.BatchHeld;
    return writePty(s, data, input);
}

/// Write bytes to the PTY master after any queued query replies, so the
/// child's input stream is never interleaved mid-sequence. Fails with
/// error.InputStalled when the child stops reading for `input_stall_ns`
/// and with error.SessionExited when it exits meanwhile. While an input
/// batch runs it writes nothing: the batch sends the queued replies.
pub fn ptyWrite(s: *Session, data: []const u8) !void {
    return writePty(s, data, null) catch |err| switch (err) {
        error.BatchHeld => {},
        else => err,
    };
}

fn writePty(s: *Session, data: []const u8, input: ?trace_mod.Input) !void {
    const io = io_mod.io();
    {
        // Another write may be stalled on a child that stopped reading;
        // queueing behind it without a limit would pin this request (and
        // its connection slot) for N x the stall limit.
        try lockWrite(s, io_mod.nowNanos() + input_stall_ns, true);
        defer s.write_mutex.unlock(io);
        if (input) |event| {
            markInput(s);
            // Recorded under the lock, so an input that has to wait for a
            // batch is recorded once, when it is written.
            record.recordInput(s, event);
        }
        writeLocked(s, data, null) catch |err| {
            if (input != null) record.recordMark(s, "input not delivered") catch {};
            return err;
        };
    }
    flushAfterWrite(s);
}

/// Write `data` between the replies queued before and after it, by
/// `deadline` (monotonic) when one is given; write_mutex must be held.
pub fn writeLocked(s: *Session, data: []const u8, deadline: ?i64) !void {
    try flushRepliesBlocking(s, deadline);
    try writeAllBounded(s, data, deadline);
    try flushRepliesBlocking(s, deadline);
}

/// The reader cannot flush while a write holds the lock; replies it
/// queued after that write's last flush are sent here, after the unlock.
pub fn flushAfterWrite(s: *Session) void {
    if (hasPendingReplies(s)) _ = tryFlushReplies(s);
}

/// Take input_seq and the input snapshot; write_mutex must be held. Output
/// the child wrote before the input is settled first (waiting a little
/// for what is still on the pty), so input_seq covers it, and the pty is
/// sampled, so hidden input that began before the input is not new after it.
pub fn markInput(s: *Session) void {
    settleOutput(s);
    sample.refresh(s, false);
    const io = io_mod.io();
    s.terminal_mutex.lockUncancelable(io);
    const settled = s.track.takeInput(&s.terminal, io_mod.nowNanos());
    s.terminal_mutex.unlock(io);
    if (settled) s.track.notify();
}

/// Whether output the child wrote waits to be read or settled, on the pty
/// or in a read in progress; terminal_mutex must be held, which keeps the
/// pty open. Windows cannot tell: false.
pub fn outputPendingLocked(s: *Session) bool {
    if (builtin.os.tag == .windows) return false;
    const master = s.pty.posix.master;
    if (master < 0) return false;
    const t = &s.track;
    const reads = t.reads.load(.seq_cst);
    if (reads % 2 != 0) return true;
    const read = t.read_bytes.load(.seq_cst) + pty_mod.pendingOutput(master);
    if (t.reads.load(.seq_cst) != reads) return true;
    return read > t.settled_bytes.load(.seq_cst);
}

/// Wait a little, holding no lock, until the output the child wrote so
/// far is settled.
pub fn settleOutput(s: *Session) void {
    if (builtin.os.tag == .windows) return;
    const deadline = io_mod.nowNanos() + input_settle_wait_ns;
    if (pendingOutputEnd(s, deadline)) |target| s.track.waitSettled(target, deadline);
}

/// The read count the reader reaches once it has read everything the
/// child wrote so far; null once the pty is closed, or when the reader is
/// still in the middle of a read at `deadline`.
fn pendingOutputEnd(s: *Session, deadline: i64) ?u64 {
    const master = s.pty.posix.master;
    if (master < 0) return null;
    const t = &s.track;
    while (true) {
        // During a read, the bytes it took are neither pending nor counted.
        const reads = t.reads.load(.seq_cst);
        if (reads % 2 == 0) {
            const read = t.read_bytes.load(.seq_cst);
            const pending = pty_mod.pendingOutput(master);
            if (t.reads.load(.seq_cst) == reads) return read + pending;
        }
        if (io_mod.nowNanos() >= deadline) return null;
        std.Thread.yield() catch {};
    }
}

/// Take write_mutex by `deadline`. With `yield`, a batch that starts
/// meanwhile wins: error.BatchHeld.
pub fn lockWrite(s: *Session, deadline: i64, yield: bool) !void {
    while (!s.write_mutex.tryLock()) {
        if (s.child_exited.load(.acquire)) return error.SessionExited;
        if (yield and s.batch.active.load(.acquire)) return error.BatchHeld;
        if (s.write_stalled.load(.acquire)) return error.InputBusy;
        if (io_mod.nowNanos() >= deadline) return if (yield) error.InputBusy else error.BatchQueued;
        std.Io.sleep(io_mod.io(), .fromMilliseconds(2), .boot) catch {};
    }
}

fn takeReplies(s: *Session) std.ArrayListUnmanaged(u8) {
    const io = io_mod.io();
    s.terminal_mutex.lockUncancelable(io);
    defer s.terminal_mutex.unlock(io);
    const replies = s.pending_replies;
    s.pending_replies = .empty;
    return replies;
}

/// Send the queued replies, by `deadline` when one is given; write_mutex
/// must be held.
pub fn flushRepliesBlocking(s: *Session, deadline: ?i64) !void {
    var replies = takeReplies(s);
    defer replies.deinit(s.gpa);
    if (replies.items.len > 0) try writeAllBounded(s, replies.items, deadline);
}

const FlushResult = enum { done, busy, would_block };

/// Send queued query replies without blocking: `busy` when a writer
/// holds the pty (it flushes them itself), `would_block` when the
/// child's input buffer is full (the rest stays queued, in order).
fn tryFlushReplies(s: *Session) FlushResult {
    if (!s.write_mutex.tryLock()) return .busy;
    const io = io_mod.io();
    defer s.write_mutex.unlock(io);
    var replies = takeReplies(s);
    defer replies.deinit(s.gpa);
    if (replies.items.len == 0) return .done;
    switch (builtin.os.tag) {
        .windows => {
            writeAllBounded(s, replies.items, null) catch {};
            return .done;
        },
        else => {
            var i: usize = 0;
            while (i < replies.items.len) {
                const n = std.c.write(s.pty.posix.master, replies.items.ptr + i, replies.items.len - i);
                if (n > 0) {
                    i += @intCast(n);
                    continue;
                }
                switch (std.posix.errno(n)) {
                    .INTR => continue,
                    .AGAIN => {
                        // Put the rest back in front of anything queued
                        // since; this thread holds write_mutex, so no
                        // other flush can reorder them.
                        s.terminal_mutex.lockUncancelable(io);
                        defer s.terminal_mutex.unlock(io);
                        s.pending_replies.insertSlice(s.gpa, 0, replies.items[i..]) catch {};
                        return .would_block;
                    },
                    else => return .done,
                }
            }
            return .done;
        },
    }
}

/// Write all of `data`, waiting while the child's input buffer is full.
/// The POSIX master is non-blocking, so a child that stops reading (or
/// exits) can never wedge the calling request; a batch's write also ends
/// at its `deadline` with error.BatchTooSlow.
fn writeAllBounded(s: *Session, data: []const u8, deadline: ?i64) !void {
    switch (builtin.os.tag) {
        .windows => {
            var i: usize = 0;
            while (i < data.len) {
                var written: win32.DWORD = 0;
                const in_h = s.pty.windows.in_h orelse return error.SessionExited;
                if (win32.WriteFile(in_h, data.ptr + i, @intCast(data.len - i), &written, null) == 0) {
                    return error.WriteFailed;
                }
                if (written == 0) return error.WriteFailed;
                i += written;
            }
        },
        else => {
            // Released once the session ended.
            if (s.pty.posix.master < 0) return error.SessionExited;
            var i: usize = 0;
            var last_progress = io_mod.nowNanos();
            defer s.write_stalled.store(false, .release);
            while (i < data.len) {
                const n = std.c.write(s.pty.posix.master, data.ptr + i, data.len - i);
                if (n > 0) {
                    i += @intCast(n);
                    last_progress = io_mod.nowNanos();
                    s.write_stalled.store(false, .release);
                    continue;
                }
                switch (std.posix.errno(n)) {
                    .INTR => {},
                    .AGAIN => {
                        if (s.child_exited.load(.acquire)) return error.SessionExited;
                        const now = io_mod.nowNanos();
                        if (deadline) |d| if (now >= d) return error.BatchTooSlow;
                        const waited = now - last_progress;
                        if (waited >= input_stall_ns) return error.InputStalled;
                        if (waited >= stall_notice_ns) s.write_stalled.store(true, .release);
                        var pfd = [1]std.c.pollfd{.{ .fd = s.pty.posix.master, .events = std.c.POLL.OUT, .revents = 0 }};
                        _ = std.c.poll(&pfd, 1, 50);
                    },
                    else => return error.WriteFailed,
                }
            }
        },
    }
}

/// Blocking read from the ConPTY output pipe. Returns 0 on EOF.
fn ptyRead(s: *Session, buf: []u8) !usize {
    var n: win32.DWORD = 0;
    if (win32.ReadFile(s.pty.windows.out_h.?, buf.ptr, @intCast(buf.len), &n, null) == 0) {
        const err = win32.GetLastError();
        // Broken pipe / not connected: the pseudoconsole is closed.
        if (err == win32.ERROR_BROKEN_PIPE or err == 233) return 0;
        return error.ReadFailed;
    }
    return n;
}

/// terminal_mutex must be held (it guards the Windows HPCON's lifetime).
pub fn ptyResize(s: *Session, cols: u16, rows: u16) !void {
    switch (builtin.os.tag) {
        .windows => {
            const hpc = s.pty.windows.hpc orelse return error.SessionExited;
            if (win32.ResizePseudoConsole(hpc, .{ .x = @intCast(cols), .y = @intCast(rows) }) < 0) {
                return error.ResizeFailed;
            }
        },
        else => {
            if (s.pty.posix.master < 0) return error.SessionExited;
            if (!pty_mod.setWinsize(s.pty.posix.master, rows, cols)) return error.ResizeFailed;
        },
    }
}

/// A session's stream handler: Ghostty's, which applies the output to the
/// terminal, counting the program's full clears on the way.
pub const Handler = struct {
    inner: GhosttyHandler,
    /// Erases of the whole screen: ED 2, kitty's ED 22, and ED 0 with the
    /// cursor at the top left cell. ED 3 erases only the history.
    full_clears: u64 = 0,

    pub fn vt(self: *Handler, comptime action: Action.Tag, value: Action.Value(action)) void {
        switch (action) {
            .erase_display_complete, .erase_display_scroll_complete => self.full_clears += 1,
            .erase_display_below => {
                const cursor = self.inner.terminal.screens.active.cursor;
                if (cursor.x == 0 and cursor.y == 0) self.full_clears += 1;
            },
            else => {},
        }
        self.inner.vt(action, value);
    }

    pub fn deinit(self: *Handler) void {
        self.inner.deinit();
    }
};

pub const Stream = vt.Stream(Handler);
const GhosttyHandler = vt.TerminalStream.Handler;
const Action = vt.TerminalStream.Action;

test "a full clear is ED 2, or ED 0 from the top left cell, not ED 3" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 20, .rows = 4 });
    defer term.deinit(alloc);
    var inner = term.vtHandler();
    inner.effects = .readonly;
    var stream = Stream.init(.{ .handler = .{ .inner = inner }, .allocator = alloc });
    defer stream.deinit();
    stream.nextSlice("text\x1b[2J\x1b[3J\x1b[2;1H\x1b[J");
    try std.testing.expectEqual(@as(u64, 1), stream.handler.full_clears);
    stream.nextSlice("\x1b[H\x1b[0J");
    try std.testing.expectEqual(@as(u64, 2), stream.handler.full_clears);
}

/// Queue the parser's reply (DSR, DA, ...) for the pty. Runs on the
/// reader thread with terminal_mutex held.
/// Replies queued for a child that floods queries without reading its
/// input are dropped beyond this; it cannot be waiting for them.
const max_pending_replies = 64 * 1024;

pub fn writePtyEffect(h: *vt.TerminalStream.Handler, data: []const u8) void {
    const s: *Session = @fieldParentPtr("terminal", h.terminal);
    if (s.pending_replies.items.len + data.len > max_pending_replies) return;
    s.pending_replies.appendSlice(s.gpa, data) catch {};
    // A batch that sleeps holds the write lock; it sends the reply.
    _ = s.batch.replies.fetchAdd(1, .release);
    if (s.batch.active.load(.acquire)) io_mod.io().futexWake(u32, &s.batch.replies.raw, 1);
}

/// The program rang the bell (BEL); terminal_mutex is held.
pub fn bellEffect(h: *vt.TerminalStream.Handler) void {
    const s: *Session = @fieldParentPtr("terminal", h.terminal);
    _ = s.bell_count.fetchAdd(1, .release);
}

/// The program sent a desktop notification (OSC 9 or OSC 777);
/// terminal_mutex is held.
pub fn notificationEffect(h: *vt.TerminalStream.Handler, n: vt.StreamAction.ShowDesktopNotification) void {
    const s: *Session = @fieldParentPtr("terminal", h.terminal);
    const note = status.notificationOf(s.gpa, n.title, n.body, store.nowMillis()) catch return;
    if (s.notification) |old| status.freeNotification(s.gpa, old);
    s.notification = note;
    _ = s.notification_count.fetchAdd(1, .release);
}

/// Answer DA1 (CSI c): identify as a VT220 with ANSI color. The
/// return type (device_attributes.Attributes) is not exported by the
/// vt module, so it is derived from the effects struct's field type.
const DA_Attributes = @typeInfo(@typeInfo(
    std.meta.Child(std.meta.fieldInfo(std.meta.fieldInfo(vt.TerminalStream.Handler, .effects).type, .device_attributes).type),
).pointer.child).@"fn".return_type.?;

pub fn deviceAttributesEffect(h: *vt.TerminalStream.Handler) DA_Attributes {
    _ = h;
    return .{};
}

/// Answer XTVERSION (CSI > 0 q): identify as tuppet.
pub fn xtversionEffect(h: *vt.TerminalStream.Handler) []const u8 {
    _ = h;
    return "tuppet " ++ protocol.version;
}

/// Answer size queries (CSI 14/16/18 t) with the session's cell geometry.
/// Headless, so the cell size is reported as 1x1 pixel.
pub fn sizeEffect(h: *vt.TerminalStream.Handler) ?vt.size_report.Size {
    return .{
        .rows = h.terminal.rows,
        .columns = h.terminal.cols,
        .cell_width = 1,
        .cell_height = 1,
    };
}

// ---- tests ------------------------------------------------------------

var test_resp: std.ArrayListUnmanaged(u8) = .empty;

fn testWritePty(h: *vt.TerminalStream.Handler, data: []const u8) void {
    _ = h;
    test_resp.appendSlice(std.testing.allocator, data) catch {};
}

test "write_pty effect answers DSR cursor position query" {
    test_resp = .empty;
    defer test_resp.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    var handler = term.vtHandler();
    handler.effects = .readonly;
    handler.effects.write_pty = &testWritePty;
    var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = alloc });
    defer stream.deinit();

    stream.nextSlice("\x1b[6n");

    try std.testing.expectEqualStrings("\x1b[1;1R", test_resp.items);
}

test "OSC 4/10/11 color queries are answered" {
    test_resp = .empty;
    defer test_resp.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);
    // Mirrors Session.start: ghostty's default theme colors.
    term.colors.foreground.set(.{ .r = 0xdc, .g = 0xd7, .b = 0xba });
    term.colors.background.set(.{ .r = 0x1f, .g = 0x1f, .b = 0x28 });

    var handler = term.vtHandler();
    handler.effects = .readonly;
    handler.effects.write_pty = &testWritePty;
    var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = alloc });
    defer stream.deinit();

    stream.nextSlice("\x1b]4;0;?\x07\x1b]4;2;?\x1b\\\x1b]10;?\x07\x1b]11;?\x07");

    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1b]4;0;rgb:") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1b]4;2;rgb:") != null);
    // Foreground/background report the configured defaults (16-bit rgb).
    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1b]10;rgb:dcdc/d7d7/baba") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1b]11;rgb:1f1f/1f1f/2828") != null);
}

test "OSC 52 clipboard policy: writes dropped, reads never answered" {
    test_resp = .empty;
    defer test_resp.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    var handler = term.vtHandler();
    handler.effects = .readonly;
    handler.effects.write_pty = &testWritePty;
    var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = alloc });
    defer stream.deinit();

    // Clipboard read request (OSC 52;c;?) and a base64 write must produce
    // no terminal output: a headless daemon has no clipboard, and read
    // requests are never forwarded by design.
    stream.nextSlice("\x1b]52;c;?\x07\x1b]52;c;aGVsbG8=\x07");
    try std.testing.expectEqual(@as(usize, 0), test_resp.items.len);
}

test "DA2, XTVERSION, size reports, XTGETTCAP are answered" {
    test_resp = .empty;
    defer test_resp.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init((vt.TinyIo.init).io(), alloc, .{ .cols = 80, .rows = 24 });
    defer term.deinit(alloc);

    var handler = term.vtHandler();
    handler.effects = .readonly;
    handler.effects.write_pty = &testWritePty;
    handler.effects.device_attributes = &deviceAttributesEffect;
    handler.effects.xtversion = &xtversionEffect;
    handler.effects.size = &sizeEffect;
    handler.terminfo_name = "ghostty";
    var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = alloc });
    defer stream.deinit();

    // DA1, DA2, XTVERSION, size (14t), XTGETTCAP TN (hex "544e") and Co.
    stream.nextSlice("\x1b[c\x1b[>c\x1b[>0q\x1b[14t\x1bP+q544e\x1b\\\x1bP+q436f\x1b\\");

    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1b[?62;22c") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1b[>1;0;0c") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1bP>|tuppet " ++ protocol.version ++ "\x1b\\") != null);
    // 24 rows x 80 cols with 1x1 cells: height/width pixels are 24/80.
    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1b[4;24;80t") != null);
    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1bP1+r544E=67686F73747479\x1b\\") != null);
    // "Co" (colors) is answered from ghostty's built-in terminfo map.
    try std.testing.expect(std.mem.indexOf(u8, test_resp.items, "\x1bP1+r436F=") != null);
}
