//! Recordings of a session: asciicast and trace output, input events and
//! marks. The evaluator writes the trace's screen frames and stops a
//! recording once its conditions hold or its time is up.

const std = @import("std");
const vt = @import("vt");
const io_mod = @import("io.zig");
const mouse_mod = @import("mouse.zig");
const plat = @import("plat.zig");
const trace_mod = @import("trace.zig");
const session_mod = @import("session.zig");
const store = @import("store.zig");
const protocol = @import("protocol.zig");
const cond = @import("cond.zig");
const track = @import("track.zig");
const view = @import("view.zig");
const evaluator = @import("evaluator.zig");
const sample = @import("sample.zig");
const status = @import("status.zig");

const Session = session_mod.Session;

pub const RecordFormat = protocol.RecordFormat;
pub const StopReason = protocol.StopReason;

pub const RecordOptions = struct {
    /// Null records into the session's store directory.
    path: ?[]const u8 = null,
    format: RecordFormat = .cast,
    /// Log input events; implied for the trace format.
    input: bool = false,
    /// Stop once one of these holds.
    until: []const cond.Condition = &.{},
    /// Stop this long after the start.
    max_ms: ?u64 = null,
    /// Gets why the file could not be created, on error.CantOpenFile.
    why: ?*[]const u8 = null,
};

/// Active recording: an open file, the monotonic start time for event
/// timestamps, and what the last trace frame showed. Owned memory comes
/// from `Session.gpa`, never a per-request arena.
pub const Recording = struct {
    file: plat.File,
    path: []u8,
    start: i64,
    /// Unix time in milliseconds.
    started_ms: i64,
    format: RecordFormat,
    input: bool,
    /// Answered by the evaluator when `until` holds or `max_ms` is over.
    waiter: ?*evaluator.Waiter = null,
    /// Trace format: the screen, size, and row text hashes of the last
    /// frame.
    key: vt.ScreenSet.Key = .primary,
    cols: u16 = 0,
    rows: u16 = 0,
    hashes: []u64 = &.{},
    /// Cast format: an incomplete UTF-8 sequence at the end of the last
    /// output chunk, completed by the next one.
    utf8_carry: trace_mod.Utf8Carry = .{},

    fn deinit(rec: *Recording, gpa: std.mem.Allocator) void {
        gpa.free(rec.path);
        gpa.free(rec.hashes);
        if (rec.waiter) |w| w.release();
    }
};

/// The latest recording that stopped, for the reply to a stop request.
pub const Stopped = struct {
    path: []u8,
    reason: StopReason,
    /// A stop request reported it already.
    reported: bool = false,
};

/// What a record reply tells about the session's latest recording.
pub const Latest = struct {
    active: bool = false,
    reason: ?StopReason = null,
    path: ?[]const u8 = null,
};

/// Start writing a recording. Fails if a recording is already active.
/// The trace format begins with `start` and `snap` events so the artifact
/// always opens with a complete screen.
pub fn startRecording(self: *Session, opts: RecordOptions) !void {
    const gpa = self.gpa;
    const io = io_mod.io();
    if (self.state.load(.acquire) == .exited) return error.SessionExited;
    var waiter: ?*evaluator.Waiter = null;
    errdefer if (waiter) |w| w.release();
    if (opts.until.len > 0 or opts.max_ms != null) {
        const w = try evaluator.Waiter.create(gpa, .{ .until = opts.until, .timeout_ms = opts.max_ms orelse 0, .on_answer = &untilAnswered });
        if (opts.max_ms == null) w.deadline = std.math.maxInt(i64);
        waiter = w;
    }

    self.record_mutex.lockUncancelable(io);
    // errdefer owns every error-path unlock; success unlocks at the end.
    errdefer self.record_mutex.unlock(io);
    if (self.state.load(.acquire) == .exited) return error.SessionExited;
    if (self.recording != null) return error.AlreadyRecording;
    self.record_generation += 1;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var name_buf: [32]u8 = undefined;
    const path = opts.path orelse try store.sessionFile(&path_buf, self.id, std.fmt.bufPrint(&name_buf, "record-{d}.{s}", .{ self.record_generation, @tagName(opts.format) }) catch unreachable);
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.CantOpenFile;
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);
    const file = plat.create(path_z, .nonblocking) catch |err| {
        if (opts.why) |why| why.* = plat.createErrorText(err);
        return error.CantOpenFile;
    };
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    errdefer plat.close(file);
    plat.makePrivate(file);

    var rec = Recording{
        .file = file,
        .path = try gpa.dupe(u8, path),
        .start = io_mod.nowNanos(),
        .started_ms = store.nowMillis(),
        .format = opts.format,
        .input = opts.input or opts.format == .trace,
    };
    errdefer rec.deinit(gpa);

    // The first snap and the hashes later frames compare with describe
    // the same settled screen.
    var initial: ?[]u8 = null;
    defer if (initial) |t| gpa.free(t);
    var name: []u8 = &.{};
    defer gpa.free(name);
    var settled = false;
    {
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        settled = self.track.unsettled();
        if (settled) self.track.settle(&self.terminal, io_mod.nowNanos());
        rec.cols = self.cols;
        rec.rows = self.rows;
        if (opts.format == .trace) {
            initial = try self.formatLocked(gpa, .plain, .screen, false);
            try setHashes(gpa, &rec, self.terminal.screens.active_key, self.track.rows(self.terminal.screens.active_key));
        }
        // A rename swaps the name under this lock.
        name = try gpa.dupe(u8, self.name);
    }
    if (settled) self.track.notify();

    switch (opts.format) {
        .cast => {
            var header_buf: [512]u8 = undefined;
            const ts = std.Io.Clock.now(.real, io_mod.io());
            const line = std.fmt.bufPrint(
                &header_buf,
                "{{\"version\":2,\"width\":{d},\"height\":{d},\"timestamp\":{d},\"env\":{{\"TERM\":\"xterm-256color\"}}}}\n",
                .{ rec.cols, rec.rows, @divTrunc(ts.nanoseconds, std.time.ns_per_s) },
            ) catch return error.WriteFailed;
            plat.writeAll(file, line) catch return error.WriteFailed;
        },
        .trace => {
            const start_line = trace_mod.formatStart(gpa, rec.cols, rec.rows, name) catch return error.WriteFailed;
            defer gpa.free(start_line);
            plat.writeAll(file, start_line) catch return error.WriteFailed;
            const rows_split = trace_mod.splitRows(gpa, initial.?) catch return error.WriteFailed;
            defer gpa.free(rows_split);
            const snap_line = trace_mod.formatSnap(gpa, 0, rows_split) catch return error.WriteFailed;
            defer gpa.free(snap_line);
            plat.writeAll(file, snap_line) catch return error.WriteFailed;
        },
    }

    if (waiter) |w| {
        rec.waiter = w;
        waiter = null;
        // Last: nothing fails once the evaluator has it.
        if (!try evaluator.register(self, w, false)) return error.SessionExited;
    }
    self.recording = rec;
    self.recording_active.store(true, .release);
    self.recording_trace.store(opts.format == .trace, .release);
    self.recording_failed.store(false, .release);
    if (self.last_stopped) |old| gpa.free(old.path);
    self.last_stopped = null;
    self.record_mutex.unlock(io);
}

/// Stop the active recording, if there is one. Trace recordings get a
/// final `snap` (the end state is always complete) and a `stop` event.
pub fn stopRecording(self: *Session, reason: StopReason) void {
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording != null) stopLocked(self, reason);
}

/// A stop request: stop the active recording, or report the one that
/// stopped by itself since the last request. error.NotRecording when
/// there is neither; error.WriteFailed when the recording could not be
/// written. Strings of the result are in `gpa`.
pub fn stopRequested(self: *Session, gpa: std.mem.Allocator) !Latest {
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording != null) stopLocked(self, .request);
    if (self.recording_failed.swap(false, .acq_rel)) {
        saveReportLocked(self, gpa);
        return error.WriteFailed;
    }
    const stopped = if (self.last_stopped) |*st| st else return error.NotRecording;
    if (stopped.reported) return error.NotRecording;
    stopped.reported = true;
    saveReportLocked(self, gpa);
    return .{ .reason = stopped.reason, .path = try gpa.dupe(u8, stopped.path) };
}

/// What the store keeps of the latest recording; record_mutex must be
/// held.
pub fn reportLocked(self: *Session) store.RecordingReport {
    return .{
        .stopped = if (self.last_stopped) |st| .{ .path = st.path, .reason = st.reason, .reported = st.reported } else null,
        .failed = self.recording_failed.load(.acquire),
    };
}

/// An ended session can leave memory, so the store keeps what a stop
/// request reported; record_mutex must be held.
fn saveReportLocked(self: *Session, gpa: std.mem.Allocator) void {
    if (self.state.load(.acquire) != .exited) return;
    store.setRecordingReport(gpa, self.id, reportLocked(self)) catch |err| {
        std.log.err("session {d}: cannot save that its recording was reported: {}", .{ self.id, err });
    };
}

/// The session's latest recording; strings in `gpa`.
pub fn latest(self: *Session, gpa: std.mem.Allocator) !Latest {
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording) |rec| return .{ .active = true, .path = try gpa.dupe(u8, rec.path) };
    const stopped = self.last_stopped orelse return .{};
    return .{ .reason = stopped.reason, .path = try gpa.dupe(u8, stopped.path) };
}

/// The evaluator answered the recording's waiter: a condition of its
/// `until` holds, its time is up, or the session ended.
fn untilAnswered(self: *Session, w: *evaluator.Waiter) void {
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    const rec = self.recording orelse return;
    if (rec.waiter != w) return;
    stopLocked(self, switch (w.result.outcome) {
        .met => .met,
        .timeout => .max_ms,
        .ended, .removed => .ended,
    });
}

/// record_mutex must be held and a recording must be active.
fn stopLocked(self: *Session, reason: StopReason) void {
    const gpa = self.gpa;
    // The changes not framed yet come before the final snap.
    if (self.recording.?.format == .trace) {
        _ = frameLocked(self);
        if (self.recording == null) return;
    }
    const rec = &self.recording.?;
    finishFile(self, rec, reason) catch return failLocked(self);
    const path = rec.path;
    rec.path = &.{};
    closeLocked(self);
    if (self.last_stopped) |old| gpa.free(old.path);
    self.last_stopped = .{ .path = path, .reason = reason };
}

/// Write what ends the file: a trace's final snap and stop event, or the
/// rest of a cast's incomplete character.
fn finishFile(self: *Session, rec: *Recording, reason: StopReason) !void {
    const gpa = self.gpa;
    const io = io_mod.io();
    if (rec.format == .trace) {
        self.terminal_mutex.lockUncancelable(io);
        const text = self.formatLocked(gpa, .plain, .screen, false);
        self.terminal_mutex.unlock(io);
        const screen = try text;
        defer gpa.free(screen);
        const now = io_mod.nowNanos();
        const rows = try trace_mod.splitRows(gpa, screen);
        defer gpa.free(rows);
        const snap_line = try trace_mod.formatSnap(gpa, trace_mod.elapsedSecs(rec.start, now), rows);
        defer gpa.free(snap_line);
        try plat.writeAll(rec.file, snap_line);
        var exit: ?trace_mod.Exit = null;
        if (reason == .ended and self.state.load(.acquire) == .exited) {
            const how = try status.exitOf(gpa, self.exit_code.load(.acquire), false);
            exit = if (how.signal) |name| .{ .signal = name } else .{ .code = how.code.? };
        }
        defer if (exit) |e| if (e == .signal) gpa.free(e.signal);
        const stop_line = try trace_mod.formatStop(gpa, trace_mod.elapsedSecs(rec.start, now), @tagName(reason), exit);
        defer gpa.free(stop_line);
        try plat.writeAll(rec.file, stop_line);
    } else if (rec.utf8_carry.len > 0) {
        // A sequence the child never completed ends as U+FFFD.
        const secs = trace_mod.elapsedSecs(rec.start, io_mod.nowNanos());
        const line = try trace_mod.formatCastOutput(gpa, secs, "", &rec.utf8_carry, true) orelse return;
        defer gpa.free(line);
        try plat.writeAll(rec.file, line);
    }
}

/// Close the active recording's file and forget it; record_mutex must be
/// held.
fn closeLocked(self: *Session) void {
    var rec = self.recording.?;
    self.recording = null;
    self.recording_active.store(false, .release);
    self.recording_trace.store(false, .release);
    if (rec.waiter) |w| {
        w.cancel();
        evaluator.withdraw(self, w);
    }
    plat.close(rec.file);
    rec.deinit(self.gpa);
}

fn failLocked(self: *Session) void {
    closeLocked(self);
    if (self.last_stopped) |old| self.gpa.free(old.path);
    self.last_stopped = null;
    self.recording_failed.store(true, .release);
}

/// Record an input the session is about to write (attach data, a batch
/// step). A trace gets the frame of what the screen showed before the
/// input first, so it never shows the screen reacting before the input.
pub fn recordInput(self: *Session, given: trace_mod.Input) void {
    if (!self.recording_active.load(.acquire)) return;
    // What the program reads without echo, a password most likely, is
    // kept out like a secret, whoever types it.
    const input: trace_mod.Input = switch (given) {
        .send, .key => blk: {
            sample.refresh(self, false);
            break :blk if (sample.latest(self).hidden()) .secret else given;
        },
        else => given,
    };
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording == null) return;
    if (self.recording.?.format == .trace) {
        _ = frameLocked(self);
        if (self.recording == null) return;
    }
    recordInputLocked(self, input);
}

/// Before a resize: a trace gets the frame of the screen before the
/// reflow. record_mutex must be held, across the reflow until
/// `recordInputLocked` records the resize, so no frame comes between.
pub fn beforeResizeLocked(self: *Session) void {
    const rec = self.recording orelse return;
    if (rec.format == .trace) _ = frameLocked(self);
}

/// `recordInput` with record_mutex held and no frame first.
pub fn recordInputLocked(self: *Session, input: trace_mod.Input) void {
    const gpa = self.gpa;
    const rec = if (self.recording) |*r| r else return;
    // Resizes change how output plays back, so casts always carry them.
    if (rec.format == .cast and !rec.input and input != .resize) return;
    const secs = trace_mod.elapsedSecs(rec.start, io_mod.nowNanos());
    const line = switch (rec.format) {
        .trace => trace_mod.formatIn(gpa, secs, input),
        .cast => trace_mod.formatCastInput(gpa, secs, input),
    } catch return failLocked(self);
    defer gpa.free(line);
    plat.writeAll(rec.file, line) catch failLocked(self);
}

/// Append a marker to the active recording; a trace gets the frame of
/// the screen before it.
pub fn recordMark(self: *Session, label: []const u8) !void {
    const gpa = self.gpa;
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording == null) return error.NotRecording;
    if (self.recording.?.format == .trace) {
        _ = frameLocked(self);
        if (self.recording == null) return error.WriteFailed;
    }
    const rec = &self.recording.?;
    const secs = trace_mod.elapsedSecs(rec.start, io_mod.nowNanos());
    const line = switch (rec.format) {
        .trace => trace_mod.formatMark(gpa, secs, label),
        .cast => trace_mod.formatCastMark(gpa, secs, label),
    } catch {
        failLocked(self);
        return error.WriteFailed;
    };
    defer gpa.free(line);
    plat.writeAll(rec.file, line) catch {
        failLocked(self);
        return error.WriteFailed;
    };
}

/// An alert hit: it always marks the active recording, if there is one.
pub fn markHit(self: *Session, label: []const u8) void {
    if (!self.recording_active.load(.acquire)) return;
    recordMark(self, label) catch {};
}

/// Cast format: record one chunk of child output as an "o" event. Called
/// from the reader thread after each parsed chunk.
pub fn recordOutput(self: *Session, data: []const u8) void {
    const gpa = self.gpa;
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    const rec = if (self.recording) |*r| r else return;
    if (rec.format != .cast) return;
    const secs = trace_mod.elapsedSecs(rec.start, io_mod.nowNanos());
    const line = trace_mod.formatCastOutput(gpa, secs, data, &rec.utf8_carry, false) catch {
        return failLocked(self);
    } orelse return;
    defer gpa.free(line);
    plat.writeAll(rec.file, line) catch failLocked(self);
}

/// Trace format: append a frame of the rows whose text changed since the
/// last frame, and tell whether there was one. The evaluator calls this
/// after settles, at most every 50 ms, so the reader thread never renders.
pub fn traceFrame(self: *Session) bool {
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    const rec = self.recording orelse return false;
    return rec.format == .trace and frameLocked(self);
}

/// record_mutex must be held and a trace recording must be active.
fn frameLocked(self: *Session) bool {
    const rec = &self.recording.?;
    const line = (formatFrame(self, rec) catch {
        failLocked(self);
        return false;
    }) orelse return false;
    defer self.gpa.free(line);
    plat.writeAll(rec.file, line) catch {
        failLocked(self);
        return false;
    };
    return true;
}

/// The next frame: a diff of the rows whose text hash changed, or a snap
/// when most rows did or the screen or its size changed; null when no
/// row did.
fn formatFrame(self: *Session, rec: *Recording) !?[]u8 {
    const gpa = self.gpa;
    const io = io_mod.io();
    var settled = false;
    defer if (settled) self.track.notify();
    self.terminal_mutex.lockUncancelable(io);
    defer self.terminal_mutex.unlock(io);
    const t = &self.terminal;
    const now = io_mod.nowNanos();
    settled = self.track.settleDue(t, now, true);
    if (settled) self.track.settle(t, now);
    // Synchronized output holds back a frame still being drawn.
    if (self.track.unsettled()) return null;
    const key = t.screens.active_key;
    const states = self.track.rows(key);
    const secs = trace_mod.elapsedSecs(rec.start, now);
    const same = key == rec.key and self.cols == rec.cols and self.rows == rec.rows and states.len == rec.hashes.len;
    var changed: usize = 0;
    if (same) {
        for (states, rec.hashes) |st, h| {
            if (st.text_hash != h) changed += 1;
        }
        if (changed == 0) return null;
    }
    if (!same or changed * 10 > states.len * 6) {
        const text = try self.formatLocked(gpa, .plain, .screen, false);
        defer gpa.free(text);
        const rows = try trace_mod.splitRows(gpa, text);
        defer gpa.free(rows);
        const line = try trace_mod.formatSnap(gpa, secs, rows);
        errdefer gpa.free(line);
        rec.cols = self.cols;
        rec.rows = self.rows;
        try setHashes(gpa, rec, key, states);
        return line;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const changes = try a.alloc(trace_mod.RowChange, changed);
    var n: usize = 0;
    var pin = t.screens.active.pages.getTopLeft(.active);
    for (states, rec.hashes, 0..) |st, *h, r| {
        if (st.text_hash != h.*) {
            var text: std.ArrayList(u8) = .empty;
            try view.formatLine(a, &text, self, pin, 1, .{});
            changes[n] = .{ .r = @intCast(r), .text = std.mem.trimEnd(u8, text.items, "\r\n") };
            n += 1;
            h.* = st.text_hash;
        }
        pin = pin.down(1) orelse break;
    }
    return try trace_mod.formatDiff(gpa, secs, changes[0..n]);
}

/// Remember the text hashes of `states`, the rows of the screen `key`.
fn setHashes(gpa: std.mem.Allocator, rec: *Recording, key: vt.ScreenSet.Key, states: []const track.RowState) !void {
    if (rec.hashes.len != states.len) {
        const hashes = try gpa.alloc(u64, states.len);
        gpa.free(rec.hashes);
        rec.hashes = hashes;
    }
    for (states, rec.hashes) |st, *h| h.* = st.text_hash;
    rec.key = key;
}

/// Stable names for trace events: the wheel aliases read better than
/// the enum's "four"/"five".
pub fn canonicalButtonName(button: ?mouse_mod.Button) []const u8 {
    const b = button orelse return "none";
    return switch (b) {
        .four => "up",
        .five => "down",
        else => @tagName(b),
    };
}

/// Render modifiers as the CLI's "cams" letters (c ctrl, a alt, s
/// shift, m super).
pub fn modsString(buf: *[4]u8, mods: mouse_mod.Mods) []const u8 {
    var len: usize = 0;
    if (mods.ctrl) {
        buf[len] = 'c';
        len += 1;
    }
    if (mods.alt) {
        buf[len] = 'a';
        len += 1;
    }
    if (mods.super) {
        buf[len] = 'm';
        len += 1;
    }
    if (mods.shift) {
        buf[len] = 's';
        len += 1;
    }
    return buf[0..len];
}

test "recording event keeps a full 32 KiB reader chunk" {
    const alloc = std.testing.allocator;
    const data = try alloc.alloc(u8, 32 * 1024);
    defer alloc.free(data);
    @memset(data, 'x');
    var carry: trace_mod.Utf8Carry = .{};
    const line = (try trace_mod.formatCastOutput(alloc, 1.25, data, &carry, false)).?;
    defer alloc.free(line);
    try std.testing.expect(line.len > data.len);
    try std.testing.expect(std.mem.startsWith(u8, line, "[1.250000,\"o\",\""));
    try std.testing.expect(std.mem.endsWith(u8, line, "\"]\n"));
}
