//! A session: a child process in a PTY whose output is parsed by a
//! libghostty-vt terminal. The `write_pty` effect answers the child's
//! queries (DSR, DECRQM, ...) by writing responses back into the PTY
//! master - this is what makes querying apps (Bubble Tea, vim, ...)
//! work without long timeouts.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const io_mod = @import("io.zig");
const keys_mod = @import("keys.zig");
const mouse_mod = @import("mouse.zig");
const pty_mod = @import("pty.zig");
const plat = @import("plat.zig");
const trace_mod = @import("trace.zig");
const protocol = @import("protocol.zig");
const attach = @import("attach.zig");
const store = @import("store.zig");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else @import("win32_stub.zig");

const wait_c = if (builtin.os.tag == .windows) struct {} else @cImport({
    @cInclude("sys/wait.h");
});

// `openpty` cannot request close-on-exec atomically on every supported
// POSIX system. Serializing session startup closes the only in-process fork
// window before both PTY descriptors have FD_CLOEXEC.
var spawn_mutex: std.Io.Mutex = .init;

/// Set by a daemon started with --socket: a supervisor owns its
/// lifetime, so session children die with it (Linux).
pub var supervised = false;

/// How long an input write may make no progress (the child is not
/// reading) before the request fails. Below the client's 10 s request
/// timeout so the caller gets the real reason.
const input_stall_ns: i64 = 5 * std.time.ns_per_s;
/// After this long without progress, other writers stop queueing.
const stall_notice_ns: i64 = 200 * std.time.ns_per_ms;

/// After the child exits, output it wrote just before exiting is still
/// read until the pty has been quiet this long, capped at
/// `exit_drain_max_ns`. A background process that keeps the pty open
/// cannot hold the session in "running".
const exit_drain_idle_ms: c_int = 50;
const exit_drain_max_ns: i64 = 1 * std.time.ns_per_s;

/// `stop` gives the process group this long to exit after SIGHUP and
/// SIGTERM before it sends SIGKILL.
const stop_grace_ns: i64 = 500 * std.time.ns_per_ms;
/// How long `stop` waits for the session to finish after SIGKILL.
const stop_exit_wait_ns: i64 = 3 * std.time.ns_per_s;

/// The child process: std.process.Child on POSIX (for group kills and
/// wait), a raw PROCESS_INFORMATION on Windows (ConPTY requires a
/// hand-rolled CreateProcessW with the pseudoconsole attribute).
const Proc = union(enum) {
    posix: std.process.Child,
    windows: struct {
        process: win32.HANDLE,
        job: win32.HANDLE,
        pid: win32.DWORD,
    },
};

// execvp is not declared by std.c; PATH resolution of argv[0] happens
// in the C runtime, so the fork child only needs async-signal-safe
// calls (execvp itself). execvpe is a GNU extension missing on macOS;
// execvp resolves against the process environ on every POSIX target,
// so the child points `environ` at the session environment first.
extern "c" fn execvp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) c_int;

fn childSetupFailed(error_fd: std.c.fd_t) noreturn {
    const marker = [_]u8{1};
    _ = std.c.write(error_fd, &marker, marker.len);
    std.c._exit(127);
}

const CArgv = struct {
    list: []?[*:0]const u8,
    z: [*:null]const ?[*:0]const u8,
};

/// Build a null-terminated C argv array (with dupeZ'd strings), for
/// passing to execvp after fork. Allocates; call before fork.
fn allocCArgvZ(gpa: std.mem.Allocator, argv: []const []const u8) !CArgv {
    const list = try gpa.alloc(?[*:0]const u8, argv.len + 1);
    @memset(list, null);
    errdefer freeCArgvZ(gpa, .{ .list = list, .z = @ptrCast(list.ptr) });
    for (argv, 0..) |a, i| {
        if (std.mem.indexOfScalar(u8, a, 0) != null) return error.InvalidArgument;
        list[i] = (try gpa.dupeZ(u8, a)).ptr;
    }
    list[argv.len] = null;
    return .{ .list = list, .z = @ptrCast(list.ptr) };
}

fn freeCArgvZ(gpa: std.mem.Allocator, cargv: CArgv) void {
    for (cargv.list) |arg| {
        if (arg) |a| gpa.free(std.mem.span(a));
    }
    gpa.free(cargv.list);
}

pub const State = enum(u8) {
    running,
    exited,
};

/// History each session keeps unless its run asks for another size.
pub const default_scrollback: u64 = 512 * 1024;

pub const Options = struct {
    argv: []const []const u8,
    cols: u16 = 120,
    rows: u16 = 40,
    cwd: ?[]const u8 = null,
    name: []const u8 = "",
    /// "NAME=value" entries for the child; null inherits the daemon's
    /// environment. TERM is always set to xterm-256color.
    env: ?[]const []const u8 = null,
    /// History limit in bytes.
    scrollback: u64 = default_scrollback,
    /// Record from the program's first byte.
    record: ?RunRecord = null,
};

/// A recording that starts with the session: to `path`, or to a file in
/// the session's store directory when `path` is null.
pub const RunRecord = struct {
    path: ?[]const u8 = null,
    format: RecordFormat = .cast,
};

/// Set by the daemon at startup: the allocator for sessions it loads from
/// the store, and its endpoint, which owns the sessions it starts.
var store_gpa: std.mem.Allocator = undefined;
var endpoint: []const u8 = "";

pub fn init(gpa: std.mem.Allocator, socket_path: []const u8) void {
    store_gpa = gpa;
    endpoint = socket_path;
}

/// The terminal type every session emulates; its terminfo entry is what
/// TUIs need to see.
const session_term = "TERM=xterm-256color";

/// Ghostty's default theme colors, so OSC 10/11 color queries get
/// answers (the vt library ships them unset).
const default_fg: vt.color.RGB = .{ .r = 0xdc, .g = 0xd7, .b = 0xba };
const default_bg: vt.color.RGB = .{ .r = 0x1f, .g = 0x1f, .b = 0x28 };

/// Variables that describe the caller's terminal or multiplexer. A
/// session's terminal is tuppet's: a program that saw TMUX, for example,
/// would wrap its queries for a tmux that is not there.
const caller_terminal_vars = [_][]const u8{ "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TMUX", "TMUX_PANE", "STY" };

/// The child environment: `env` (or, on POSIX, the daemon's own) without
/// the caller's terminal variables, plus tuppet's TERM. Rejects entries
/// without a name or with NUL bytes. The result's strings alias the
/// inputs.
fn buildChildEnv(gpa: std.mem.Allocator, env: ?[]const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    if (env) |entries| {
        for (entries) |entry| try appendEnvEntry(gpa, &list, entry);
    } else if (builtin.os.tag != .windows) {
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            appendEnvEntry(gpa, &list, std.mem.span(entry)) catch |err| switch (err) {
                // The daemon's own environment is used as-is, minus
                // anything execve could not pass on anyway.
                error.BadEnv => {},
                else => return err,
            };
        }
    }
    try list.append(gpa, session_term);
    return list.toOwnedSlice(gpa);
}

fn appendEnvEntry(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), entry: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.BadEnv;
    if (eq == 0 or std.mem.indexOfScalar(u8, entry, 0) != null) return error.BadEnv;
    const name = entry[0..eq];
    for (caller_terminal_vars) |v| {
        const same = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(name, v) else std.mem.eql(u8, name, v);
        if (same) return;
    }
    try list.append(gpa, entry);
}

pub const RecordFormat = enum { cast, trace };

/// How a recording ended; reported in the trace stop event and in the
/// record-stop response.
pub const StopReason = enum { request, match, timeout, exit };

pub const RecordOptions = struct {
    path: []const u8,
    format: RecordFormat = .cast,
    /// Log input events; implied for the trace format.
    input: bool = false,
    /// Stop once this text appears on the rendered screen.
    until_match: ?[]const u8 = null,
    /// Stop this long after start.
    until_timeout_ms: ?u64 = null,
};

/// Active recording: an open file, the monotonic start time for event
/// timestamps, and the state the trace format needs for row diffs.
/// Owned strings/slices allocate from `Session.gpa`, never a
/// per-request arena.
pub const Recording = struct {
    file: plat.File,
    start: i64,
    format: RecordFormat,
    input: bool,
    until_match: ?[]u8 = null,
    /// Monotonic deadline for until_timeout_ms; checked by the watchdog.
    deadline: ?i64 = null,
    /// Distinguishes recording generations so a stale watchdog cannot
    /// stop a newer recording.
    generation: u64,
    last_match_check: i64 = 0,
    /// Last rendered plain screen, for the next trace frame's diff.
    prev_text: ?[]u8 = null,
    /// The end of the previous output chunk (shorter than the needle), so
    /// an until-match needle split across reads still matches.
    match_tail: std.ArrayListUnmanaged(u8) = .empty,
    /// Cast format: an incomplete UTF-8 sequence at the end of the last
    /// output chunk, completed by the next one.
    utf8_carry: trace_mod.Utf8Carry = .{},

    fn deinit(rec: *Recording, gpa: std.mem.Allocator) void {
        if (rec.until_match) |m| gpa.free(m);
        rec.match_tail.deinit(gpa);
        if (rec.prev_text) |t| gpa.free(t);
    }
};

/// How often the daemon-side until-match check renders the screen at
/// most. Renders are not free, and matches can only become true when
/// output (or a resize) changes the screen anyway.
const match_check_interval_ns: i64 = 50 * std.time.ns_per_ms;

/// Start writing a recording to `opts.path`. Fails if a recording is
/// already active. The trace format begins with `start` and `snap`
/// events so the artifact always opens with a complete screen.
pub fn startRecording(self: *Session, opts: RecordOptions) !void {
    const gpa = self.gpa;
    const io = io_mod.io();
    if (self.state.load(.acquire) == .exited) return error.SessionExited;

    // Rendered before taking record_mutex: no lock is held here, and
    // record_mutex holders may take terminal_mutex, never the reverse.
    self.terminal_mutex.lockUncancelable(io);
    const cols = self.cols;
    const rows = self.rows;
    const initial_text: ?[]u8 = if (opts.format == .trace)
        self.formatLocked(gpa, .plain, .screen) catch null
    else
        null;
    self.terminal_mutex.unlock(io);
    defer if (initial_text) |t| gpa.free(t);

    // A previous recording's watchdog is joined below, after the unlock
    // defer (defers run LIFO): it exits on its own within ~20 ms once
    // its recording is gone (generation check), and joining while
    // holding record_mutex would deadlock against that check. The swap
    // must happen under the mutex so two concurrent starts cannot join
    // the same thread.
    var old_watchdog: ?std.Thread = null;
    defer if (old_watchdog) |w| w.join();

    self.record_mutex.lockUncancelable(io);
    // errdefer owns every error-path unlock; the success path unlocks
    // explicitly before the initial match check.
    errdefer self.record_mutex.unlock(io);
    if (self.state.load(.acquire) == .exited) return error.SessionExited;
    if (self.recording != null) return error.AlreadyRecording;
    old_watchdog = self.record_watchdog;
    self.record_watchdog = null;

    const path_z = try gpa.dupeZ(u8, opts.path);
    defer gpa.free(path_z);
    const file = plat.create(path_z, .nonblocking) catch return error.CantOpenFile;
    errdefer plat.close(file);
    plat.makePrivate(file);

    self.record_generation += 1;
    var rec = Recording{
        .file = file,
        .start = io_mod.nowNanos(),
        .format = opts.format,
        .input = opts.input or opts.format == .trace,
        .generation = self.record_generation,
    };
    errdefer rec.deinit(gpa);
    if (opts.until_match) |needle| rec.until_match = try gpa.dupe(u8, needle);
    // Saturates: any timeout beyond the representable range means "never".
    if (opts.until_timeout_ms) |ms| {
        const ns = std.math.mul(i64, std.math.cast(i64, ms) orelse std.math.maxInt(i64), std.time.ns_per_ms) catch std.math.maxInt(i64);
        rec.deadline = std.math.add(i64, rec.start, ns) catch std.math.maxInt(i64);
    }
    if (opts.format == .trace) rec.prev_text = if (initial_text) |t| try gpa.dupe(u8, t) else null;

    switch (opts.format) {
        .cast => {
            var header_buf: [512]u8 = undefined;
            const ts = std.Io.Clock.now(.real, io_mod.io());
            const line = std.fmt.bufPrint(
                &header_buf,
                "{{\"version\":2,\"width\":{d},\"height\":{d},\"timestamp\":{d},\"env\":{{\"TERM\":\"xterm-256color\"}}}}\n",
                .{ cols, rows, @divTrunc(ts.nanoseconds, std.time.ns_per_s) },
            ) catch return error.WriteFailed;
            plat.writeAll(file, line) catch return error.WriteFailed;
        },
        .trace => {
            const start_line = trace_mod.formatStart(gpa, cols, rows, self.name) catch return error.WriteFailed;
            defer gpa.free(start_line);
            plat.writeAll(file, start_line) catch return error.WriteFailed;
            const rows_split = trace_mod.splitRows(gpa, rec.prev_text orelse "") catch return error.WriteFailed;
            defer gpa.free(rows_split);
            const snap_line = trace_mod.formatSnap(gpa, 0, rows_split) catch return error.WriteFailed;
            defer gpa.free(snap_line);
            plat.writeAll(file, snap_line) catch return error.WriteFailed;
        },
    }

    self.recording = rec;
    self.recording_active.store(true, .release);
    self.recording_failed.store(false, .release);
    self.last_stop_reason = null;

    if (rec.deadline != null or rec.until_match != null) {
        // On failure the errdefers above free the recording's owned
        // memory and close the file.
        self.record_watchdog = std.Thread.spawn(.{}, recordWatchdog, .{ self, rec.generation, rec.deadline }) catch {
            self.recording = null;
            self.recording_active.store(false, .release);
            return error.WatchdogFailed;
        };
    }
    self.record_mutex.unlock(io);

    // A needle already on screen at start stops the recording
    // immediately, with reason "match".
    if (opts.until_match != null) checkMatchStop(self, true);
}

/// Stop and close the active recording with reason "request".
pub fn stopRecording(self: *Session) void {
    stopRecordingReason(self, .request, null);
}

/// Stop and close the active recording. Trace recordings get a final
/// `snap` (the end state is always complete) and a `stop` event. A
/// non-null `generation` stops only that recording; a stale watchdog
/// uses this to avoid killing a newer one.
pub fn stopRecordingReason(self: *Session, reason: StopReason, generation: ?u64) void {
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording == null) return;
    if (generation) |g| {
        if (self.recording.?.generation != g) return;
    }
    stopRecordingLocked(self, reason);
}

/// record_mutex must be held and a recording must be active.
fn stopRecordingLocked(self: *Session, reason: StopReason) void {
    const gpa = self.gpa;
    const rec = &self.recording.?;
    if (rec.format == .trace) {
        // Rendering under record_mutex nests record -> terminal; safe
        // because no path nests terminal -> record.
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        const text = self.formatLocked(gpa, .plain, .screen) catch null;
        self.terminal_mutex.unlock(io);
        if (text) |t| {
            defer gpa.free(t);
            const exit_code: ?i32 = if (reason == .exit) self.exit_code.load(.acquire) else null;
            writeTraceStop(gpa, rec, t, reason, exit_code) catch {
                failRecordingLocked(self, rec.*);
                return;
            };
        }
    } else if (rec.utf8_carry.len > 0) {
        // A sequence the child never completed ends as U+FFFD.
        const secs = trace_mod.elapsedSecs(rec.start, io_mod.nowNanos());
        const line = trace_mod.formatCastOutput(gpa, secs, "", &rec.utf8_carry, true) catch {
            failRecordingLocked(self, rec.*);
            return;
        };
        if (line) |l| {
            defer gpa.free(l);
            plat.writeAll(rec.file, l) catch {
                failRecordingLocked(self, rec.*);
                return;
            };
        }
    }
    rec.deinit(gpa);
    plat.close(rec.file);
    self.recording = null;
    self.recording_active.store(false, .release);
    self.last_stop_reason = reason;
}

/// Write the final snap and the stop event of a trace recording.
fn writeTraceStop(gpa: std.mem.Allocator, rec: *Recording, text: []const u8, reason: StopReason, exit_code: ?i32) !void {
    const now = io_mod.nowNanos();
    const rows = try trace_mod.splitRows(gpa, text);
    defer gpa.free(rows);
    const snap_line = try trace_mod.formatSnap(gpa, trace_mod.elapsedSecs(rec.start, now), rows);
    defer gpa.free(snap_line);
    try plat.writeAll(rec.file, snap_line);
    const stop_line = try trace_mod.formatStop(gpa, trace_mod.elapsedSecs(rec.start, now), @tagName(reason), rec.until_match, exit_code);
    defer gpa.free(stop_line);
    try plat.writeAll(rec.file, stop_line);
}

/// How the last recording stopped, for the record-stop response.
pub fn lastStopReason(self: *Session) ?StopReason {
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    return self.last_stop_reason;
}

/// Watchdog for the daemon-side stop conditions. Runs while its
/// recording is alive: stops it at the timeout deadline, and polls the
/// until-match needle (throttled inside checkMatchStop). Polling here
/// instead of in the reader loop means a match cannot be missed when
/// the child goes silent right after printing the needle. Exits when
/// its recording is gone or superseded (generation check).
fn recordWatchdog(self: *Session, generation: u64, deadline: ?i64) void {
    const io = io_mod.io();
    while (true) {
        const now = io_mod.nowNanos();
        if (deadline) |d| {
            if (now >= d) {
                stopRecordingReason(self, .timeout, generation);
                return;
            }
        }
        self.record_mutex.lockUncancelable(io);
        const gone = if (self.recording) |rec| rec.generation != generation else true;
        self.record_mutex.unlock(io);
        if (gone) return;
        checkMatchStop(self, false);
        const sleep_ms: i64 = if (deadline) |d|
            @max(1, @min(@divTrunc(d - io_mod.nowNanos(), std.time.ns_per_ms), 20))
        else
            20;
        std.Io.sleep(io, .fromMilliseconds(@intCast(sleep_ms)), .boot) catch {};
    }
}

/// Record the input the session just accepted. Called after a
/// successful pty write by send/sendKey/sendMouse/sendFocus/resize.
pub fn recordInput(self: *Session, input: trace_mod.Input) void {
    if (!self.recording_active.load(.acquire)) return;
    const gpa = self.gpa;
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording == null) return;
    const rec = &self.recording.?;
    // Resizes change how output plays back, so casts always carry them.
    if (rec.format == .cast and !rec.input and input != .resize) return;
    const secs = trace_mod.elapsedSecs(rec.start, io_mod.nowNanos());
    const line = switch (rec.format) {
        .trace => trace_mod.formatIn(gpa, secs, input),
        .cast => trace_mod.formatCastInput(gpa, secs, input),
    } catch {
        failRecordingLocked(self, rec.*);
        return;
    };
    defer gpa.free(line);
    plat.writeAll(rec.file, line) catch failRecordingLocked(self, rec.*);
}

/// Append a marker to the active recording.
pub fn recordMark(self: *Session, label: []const u8) !void {
    const gpa = self.gpa;
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording == null) return error.NotRecording;
    const rec = &self.recording.?;
    const secs = trace_mod.elapsedSecs(rec.start, io_mod.nowNanos());
    const line = switch (rec.format) {
        .trace => trace_mod.formatMark(gpa, secs, label),
        .cast => trace_mod.formatCastMark(gpa, secs, label),
    } catch {
        failRecordingLocked(self, rec.*);
        return error.WriteFailed;
    };
    defer gpa.free(line);
    plat.writeAll(rec.file, line) catch {
        failRecordingLocked(self, rec.*);
        return error.WriteFailed;
    };
}

/// Record one chunk of child output: an "o" event for the cast format,
/// or a screen-diff frame for the trace format. Called from the reader
/// thread after each parsed chunk.
fn recordOutput(self: *Session, data: []const u8) void {
    const gpa = self.gpa;
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    if (self.recording == null) {
        self.record_mutex.unlock(io);
        return;
    }
    if (self.recording.?.format != .cast) {
        self.record_mutex.unlock(io);
        traceFrame(self);
        return;
    }
    defer self.record_mutex.unlock(io);
    const rec = &self.recording.?;
    const secs = trace_mod.elapsedSecs(rec.start, io_mod.nowNanos());
    const line = trace_mod.formatCastOutput(gpa, secs, data, &rec.utf8_carry, false) catch {
        failRecordingLocked(self, rec.*);
        return;
    } orelse return;
    defer gpa.free(line);
    plat.writeAll(rec.file, line) catch failRecordingLocked(self, rec.*);
}

/// Until-match on the output stream itself: a needle printed and then
/// scrolled away (or drawn and overwritten) before the screen is next
/// checked still stops the recording, right after the chunk that
/// carried it was recorded.
fn checkChunkMatch(self: *Session, data: []const u8) void {
    const gpa = self.gpa;
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording == null) return;
    const rec = &self.recording.?;
    const needle = rec.until_match orelse return;
    rec.match_tail.appendSlice(gpa, data) catch return;
    if (std.mem.indexOf(u8, rec.match_tail.items, needle) != null) {
        stopRecordingLocked(self, .match);
        return;
    }
    const keep = @min(rec.match_tail.items.len, needle.len - 1);
    std.mem.copyForwards(u8, rec.match_tail.items[0..keep], rec.match_tail.items[rec.match_tail.items.len - keep ..]);
    rec.match_tail.shrinkRetainingCapacity(keep);
}

/// Trace format only: render the screen, diff it against the previous
/// frame, and append a diff (or snap) event. One frame per read chunk:
/// changes inside a single read (up to 32 KiB) share one frame, but no
/// chunk's state is ever dropped.
fn traceFrame(self: *Session) void {
    const gpa = self.gpa;
    const io = io_mod.io();
    // Rendered under record_mutex (record -> terminal nesting, as in
    // stopRecordingLocked) so frames reach the file in screen order.
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording == null) return;
    const rec = &self.recording.?;
    if (rec.format != .trace) return;

    self.terminal_mutex.lockUncancelable(io);
    const grid_rows = self.rows;
    const text = self.formatLocked(gpa, .plain, .screen) catch {
        self.terminal_mutex.unlock(io);
        return;
    };
    self.terminal_mutex.unlock(io);
    defer gpa.free(text);

    const rows = trace_mod.splitRows(gpa, text) catch return;
    defer gpa.free(rows);

    const prev_rows = trace_mod.splitRows(gpa, rec.prev_text orelse "") catch {
        failRecordingLocked(self, rec.*);
        return;
    };
    defer gpa.free(prev_rows);

    const diff = trace_mod.diffRows(gpa, prev_rows, rows, grid_rows, 0.6) catch {
        failRecordingLocked(self, rec.*);
        return;
    };
    const secs = trace_mod.elapsedSecs(rec.start, io_mod.nowNanos());
    switch (diff) {
        .none => {},
        .snap => {
            const line = trace_mod.formatSnap(gpa, secs, rows) catch {
                failRecordingLocked(self, rec.*);
                return;
            };
            defer gpa.free(line);
            plat.writeAll(rec.file, line) catch {
                failRecordingLocked(self, rec.*);
                return;
            };
        },
        .rows => |changes| {
            defer gpa.free(changes);
            const line = trace_mod.formatDiff(gpa, secs, changes) catch {
                failRecordingLocked(self, rec.*);
                return;
            };
            defer gpa.free(line);
            plat.writeAll(rec.file, line) catch {
                failRecordingLocked(self, rec.*);
                return;
            };
        },
    }
    if (diff != .none) {
        // Keep the rendered text as the next frame's baseline.
        const owned = gpa.dupe(u8, text) catch {
            failRecordingLocked(self, rec.*);
            return;
        };
        if (rec.prev_text) |old| gpa.free(old);
        rec.prev_text = owned;
    }
}

/// Check the until-match stop condition against the rendered screen,
/// throttled to one render per match_check_interval_ns. Called by the
/// watchdog (throttled), by resize and at start (`force`), and once
/// unthrottled before the exit stop, so a final-chunk match yields
/// reason "match", not "exit".
fn checkMatchStop(self: *Session, force: bool) void {
    if (!self.recording_active.load(.acquire)) return;
    const gpa = self.gpa;
    const io = io_mod.io();
    self.record_mutex.lockUncancelable(io);
    defer self.record_mutex.unlock(io);
    if (self.recording == null) return;
    const rec = &self.recording.?;
    const needle = rec.until_match orelse return;
    const now = io_mod.nowNanos();
    if (!force and now - rec.last_match_check < match_check_interval_ns) return;
    rec.last_match_check = now;

    self.terminal_mutex.lockUncancelable(io);
    const text = self.formatLocked(gpa, .plain, .screen) catch {
        self.terminal_mutex.unlock(io);
        return;
    };
    self.terminal_mutex.unlock(io);
    defer gpa.free(text);
    if (std.mem.indexOf(u8, text, needle) != null) stopRecordingLocked(self, .match);
}

fn failRecordingLocked(self: *Session, rec: Recording) void {
    var owned = rec;
    owned.deinit(self.gpa);
    plat.close(rec.file);
    self.recording = null;
    self.recording_active.store(false, .release);
    self.recording_failed.store(true, .release);
}

/// Stable names for trace events: the wheel aliases read better than
/// the enum's "four"/"five".
fn canonicalButtonName(button: ?mouse_mod.Button) []const u8 {
    const b = button orelse return "none";
    return switch (b) {
        .four => "up",
        .five => "down",
        else => @tagName(b),
    };
}

/// Render modifiers as the CLI's "cams" letters (c ctrl, a alt, s
/// shift, m super).
fn modsString(buf: *[4]u8, mods: mouse_mod.Mods) []const u8 {
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

/// POSIX only; unused (and never opened) on Windows.
const WakeFd = if (builtin.os.tag == .windows) i32 else std.c.fd_t;

fn closeWakePipe(pipe: *[2]WakeFd) void {
    if (builtin.os.tag == .windows) return;
    for (pipe) |*fd| {
        if (fd.* >= 0) _ = std.c.close(fd.*);
        fd.* = -1;
    }
}

pub const Session = struct {
    id: u64,
    name: []const u8,
    cols: u16,
    rows: u16,
    gpa: std.mem.Allocator,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    pty: pty_mod.Pair,
    proc: Proc,
    process_id: u32,
    /// Set under `stop_mutex` when the exit waiter reaps the child, so
    /// `stop` never signals a recycled pid.
    process_reaped: std.atomic.Value(bool) = .{ .raw = false },
    /// Set once the child is reaped and `exit_code` is stored. The session
    /// turns "exited" after the reader has drained the remaining output.
    child_exited: std.atomic.Value(bool) = .{ .raw = false },
    /// Protects the parser, terminal, geometry, and queued parser replies.
    terminal_mutex: std.Io.Mutex = .init,
    /// Serializes every complete PTY write without holding `terminal_mutex`.
    /// The reader only ever try-locks it, so it never waits behind input.
    write_mutex: std.Io.Mutex = .init,
    stop_mutex: std.Io.Mutex = .init,
    /// POSIX: the exit waiter writes a byte here to wake the reader.
    wake_pipe: [2]WakeFd = .{ -1, -1 },
    /// Requests currently using this session; `remove` waits for them.
    refs: std.atomic.Value(u32) = .{ .raw = 0 },
    /// Attached clients, and the one allowed to write; guarded by
    /// terminal_mutex so they see output exactly as it is parsed.
    viewers: std.ArrayListUnmanaged(*attach.Viewer) = .empty,
    writer: ?*attach.Viewer = null,
    /// Set while the current input write has been blocked for a while by
    /// a child that is not reading; other writers then fail at once.
    write_stalled: std.atomic.Value(bool) = .{ .raw = false },
    /// Guards the recording file: the reader thread writes events while
    /// record start/stop commands come from the daemon loop.
    record_mutex: std.Io.Mutex = .init,
    /// Active recording, if any.
    recording: ?Recording = null,
    /// Cheap check for the reader thread's fast path; mirrors
    /// `recording != null` but is atomic.
    recording_active: std.atomic.Value(bool) = .{ .raw = false },
    recording_failed: std.atomic.Value(bool) = .{ .raw = false },
    /// Set under record_mutex every time a recording stops.
    last_stop_reason: ?StopReason = null,
    /// Bumped per recording under record_mutex; lets a stale watchdog
    /// tell its recording apart from a newer one.
    record_generation: u64 = 0,
    /// until-timeout watchdog of the current (or most recent) recording;
    /// joined before a new recording starts and at deinit.
    record_watchdog: ?std.Thread = null,
    pending_replies: std.ArrayListUnmanaged(u8) = .empty,
    state: std.atomic.Value(State),
    exit_code: std.atomic.Value(i32),
    /// Monotonic nanoseconds of the last parsed output.
    last_output: std.atomic.Value(i64),
    reader: ?std.Thread,
    /// Waits for the child to exit; joined by the reader.
    waiter: ?std.Thread = null,
    /// Held in the store while the program runs; released once the
    /// session's results are saved.
    running_lock: ?std.Io.File = null,
    /// Set once the session's results are in the store (or it came from
    /// there): only then may the daemon exit without losing anything.
    settled: std.atomic.Value(bool) = .{ .raw = false },
    /// The absolute path of the recording made with `tuppet run --record`.
    run_recording: ?[]u8 = null,
    /// The command line, for `list`.
    argv: [][]u8 = &.{},
    /// Unix time in milliseconds; ended is 0 until the program has ended.
    started_ms: i64 = 0,
    ended_ms: std.atomic.Value(i64) = .{ .raw = 0 },

    pub fn start(gpa: std.mem.Allocator, opts: Options) !*Session {
        if (opts.argv.len == 0) return error.EmptyArgv;
        const io = io_mod.io();
        spawn_mutex.lockUncancelable(io);
        defer spawn_mutex.unlock(io);

        // Reserved up front so registering after the threads start cannot
        // fail (spawn_mutex serializes every start).
        try reserveRegistrySlot();

        const child_env = try buildChildEnv(gpa, opts.env);
        defer gpa.free(child_env);

        const name_dup = try gpa.dupe(u8, opts.name);
        errdefer gpa.free(name_dup);

        var record_name: ?[]const u8 = null;
        if (opts.record) |rec| record_name = rec.path orelse switch (rec.format) {
            .cast => "output.cast",
            .trace => "output.trace",
        };
        const created = try store.create(gpa, .{
            .name = opts.name,
            .argv = opts.argv,
            .cwd = opts.cwd orelse "",
            .socket = endpoint,
            .cols = opts.cols,
            .rows = opts.rows,
            .scrollback = opts.scrollback,
            .started_ms = store.nowMillis(),
            .recording = record_name,
        });
        errdefer store.discard(created.id, created.running);

        // The handler's `terminal` pointer must point at the terminal's final
        // address, so allocate the Session first and initialize the terminal
        // in place. The session owns the pty and wake pipe from the start;
        // closing them is idempotent, so every failure path can.
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        const argv_dup = try dupeArgv(gpa, opts.argv);
        errdefer freeArgv(gpa, argv_dup);
        s.* = .{
            .id = created.id,
            .argv = argv_dup,
            .started_ms = store.nowMillis(),
            .name = name_dup,
            .cols = opts.cols,
            .rows = opts.rows,
            .gpa = gpa,
            .terminal = undefined,
            .stream = undefined,
            .pty = try pty_mod.open(opts.cols, opts.rows),
            .proc = undefined,
            .process_id = 0,
            .state = .{ .raw = .running },
            .exit_code = .{ .raw = -1 },
            .last_output = .{ .raw = io_mod.nowNanos() },
            .reader = null,
        };
        errdefer pty_mod.close(&s.pty);
        if (builtin.os.tag != .windows) {
            if (std.c.pipe(&s.wake_pipe) != 0) return error.PipeFailed;
            for (s.wake_pipe) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        }
        errdefer closeWakePipe(&s.wake_pipe);

        s.terminal = try vt.Terminal.init(
            (vt.TinyIo.init).io(),
            gpa,
            .{ .cols = opts.cols, .rows = opts.rows, .max_scrollback_bytes = opts.scrollback },
        );
        errdefer s.terminal.deinit(gpa);

        s.terminal.colors.foreground.set(default_fg);
        s.terminal.colors.background.set(default_bg);

        var handler = s.terminal.vtHandler();
        handler.effects = .readonly;
        handler.effects.write_pty = &writePtyEffect;
        handler.effects.device_attributes = &deviceAttributesEffect;
        handler.effects.xtversion = &xtversionEffect;
        handler.effects.size = &sizeEffect;
        // We emulate ghostty's vt, so its terminfo entry is the truthful
        // answer for XTGETTCAP "TN" queries.
        handler.terminfo_name = "ghostty";
        s.stream = vt.TerminalStream.init(.{
            .handler = handler,
            .allocator = gpa,
            // Keeps a chunk's unfinished escape sequence for attach redraws.
            .continuation_max_bytes = 64 * 1024,
        });
        errdefer s.stream.deinit();

        // Recording before the program starts captures its first byte.
        errdefer {
            stopRecording(s);
            if (s.run_recording) |path| gpa.free(path);
        }
        if (opts.record) |rec| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = rec.path orelse try store.sessionFile(&path_buf, s.id, record_name.?);
            s.run_recording = try gpa.dupe(u8, path);
            try startRecording(s, .{ .path = path, .format = rec.format });
        }

        switch (builtin.os.tag) {
            .windows => {
                s.proc = try spawnWindowsChild(gpa, opts, child_env, &s.pty);
                s.process_id = procPid(s.proc);
                s.waiter = std.Thread.spawn(.{}, waiterLoop, .{s}) catch |err| {
                    _ = stopAndReapProc(&s.proc, io);
                    return err;
                };
            },
            else => {
                // The child is forked on the waiter thread, which lives
                // exactly as long as the child: Linux delivers the
                // parent-death signal when the forking *thread* exits.
                var request: SpawnRequest = .{ .gpa = gpa, .opts = opts, .child_env = child_env };
                s.waiter = try std.Thread.spawn(.{}, spawnAndWait, .{ s, &request });
                request.done.waitUncancelable(io);
                request.result catch |err| {
                    s.waiter.?.join();
                    s.waiter = null;
                    return err;
                };
            },
        }

        // Before the reader starts: a program that exits at once is saved
        // by the reader, which needs the lock.
        s.running_lock = created.running;
        store.setPid(gpa, s.id, s.process_id);
        s.reader = std.Thread.spawn(.{}, readerLoop, .{s}) catch |err| {
            s.running_lock = null;
            // The waiter reaps the child once it is gone; the errdefers
            // above release the rest.
            s.stop_mutex.lockUncancelable(io);
            signalGroup(s, .kill);
            s.stop_mutex.unlock(io);
            if (builtin.os.tag == .windows) {
                // Nobody drains the console output; closing our end keeps
                // the waiter's ClosePseudoConsole from blocking on it.
                if (s.pty.windows.out_h) |h| _ = win32.CloseHandle(h);
                s.pty.windows.out_h = null;
            }
            s.waiter.?.join();
            return err;
        };
        register(s);
        return s;
    }

    /// A session that ended under an earlier daemon, rebuilt from its
    /// stored screen. It stays exited: it has no program, pty, or threads.
    fn restore(gpa: std.mem.Allocator, meta: store.Meta, screen: []const u8) !*Session {
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        const name = try gpa.dupe(u8, meta.name);
        errdefer gpa.free(name);
        const argv_dup = try dupeArgv(gpa, meta.argv);
        errdefer freeArgv(gpa, argv_dup);
        s.* = .{
            .id = meta.id,
            .argv = argv_dup,
            .started_ms = meta.started_ms,
            .ended_ms = .{ .raw = meta.ended_ms orelse 0 },
            .name = name,
            .cols = meta.cols,
            .rows = meta.rows,
            .gpa = gpa,
            .terminal = undefined,
            .stream = undefined,
            .pty = if (builtin.os.tag == .windows)
                .{ .windows = .{ .in_h = null, .out_h = null, .hpc = null } }
            else
                .{ .posix = .{ .master = -1, .slave = -1 } },
            .proc = undefined,
            .process_id = meta.pid,
            .state = .{ .raw = .exited },
            .exit_code = .{ .raw = meta.exit_code orelse -1 },
            .last_output = .{ .raw = io_mod.nowNanos() },
            .reader = null,
            .settled = .{ .raw = true },
        };
        s.terminal = try vt.Terminal.init(
            (vt.TinyIo.init).io(),
            gpa,
            .{ .cols = meta.cols, .rows = meta.rows, .max_scrollback_bytes = meta.scrollback },
        );
        errdefer s.terminal.deinit(gpa);
        s.terminal.colors.foreground.set(default_fg);
        s.terminal.colors.background.set(default_bg);
        var handler = s.terminal.vtHandler();
        handler.effects = .readonly;
        s.stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = gpa });
        errdefer s.stream.deinit();
        s.stream.nextSlice(screen);
        if (meta.recording) |rec| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = if (std.fs.path.isAbsolute(rec)) rec else try store.sessionFile(&path_buf, meta.id, rec);
            s.run_recording = try gpa.dupe(u8, path);
        }
        return s;
    }

    /// Save the session's results to the store and release its running
    /// lock. Runs once, after the program has ended and its output is in.
    fn persist(self: *Session) void {
        defer self.settled.store(true, .release);
        self.ended_ms.store(store.nowMillis(), .release);
        const running = self.running_lock orelse return;
        self.running_lock = null;
        const screen = self.storedScreen() catch |err| blk: {
            std.log.err("session {d}: cannot render its final screen: {}", .{ self.id, err });
            break :blk &[_]u8{};
        };
        defer self.gpa.free(screen);
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        const cols = self.cols;
        const rows = self.rows;
        self.terminal_mutex.unlock(io);
        store.finish(self.gpa, self.id, .{
            .pid = self.process_id,
            .exit_code = self.exit_code.load(.acquire),
            .cols = cols,
            .rows = rows,
        }, screen, running);
    }

    /// The screen and history as escape sequences that rebuild them,
    /// modes and colors included. The parts come in the order of Ghostty's
    /// own full format, plus the blank rows at the bottom of the screen,
    /// which its content trims: without them a screen that ends in empty
    /// rows would come back shifted up.
    fn storedScreen(self: *Session) ![]u8 {
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        const t = &self.terminal;
        var w: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer w.deinit();

        var head = vt.formatter.TerminalFormatter.init(t, .{ .emit = .vt });
        head.content = .none;
        head.extra = .none;
        head.extra.palette = true;
        head.extra.modes = true;
        head.extra.tabstops = true;
        try head.format(&w.writer);

        var content = vt.formatter.ScreenFormatter.init(t.screens.active, .{ .emit = .vt });
        content.extra = .none;
        try content.format(&w.writer);
        for (0..trailingBlankRows(t)) |_| try w.writer.writeAll("\r\n");

        // Setting a scroll region homes the cursor, so it goes first.
        var region = vt.formatter.TerminalFormatter.init(t, .{ .emit = .vt });
        region.content = .none;
        region.extra = .none;
        region.extra.scrolling_region = true;
        try region.format(&w.writer);

        var cursor = vt.formatter.ScreenFormatter.init(t.screens.active, .{ .emit = .vt });
        cursor.content = .none;
        cursor.extra = .all;
        try cursor.format(&w.writer);
        // In origin mode a cursor position counts from the region.
        if (t.modes.get(.origin)) {
            const c = t.screens.active.cursor;
            const r = t.scrolling_region;
            try w.writer.print("\x1b[{d};{d}H", .{ c.y -| r.top + 1, c.x -| r.left + 1 });
        }

        var tail = vt.formatter.TerminalFormatter.init(t, .{ .emit = .vt });
        tail.content = .none;
        tail.extra = .none;
        tail.extra.keyboard = true;
        tail.extra.pwd = true;
        try tail.format(&w.writer);
        return w.toOwnedSlice();
    }

    /// Frees an exited session. `remove` calls this once no request
    /// holds a reference.
    fn deinit(self: *Session) void {
        const gpa = self.gpa;
        if (self.reader) |reader| reader.join();
        stopRecording(self);
        // The watchdog holds a `self` pointer; it must not outlive the
        // session. Recording is already stopped, so it exits on its own.
        if (self.record_watchdog) |watchdog| watchdog.join();
        self.pending_replies.deinit(gpa);
        self.viewers.deinit(gpa);
        self.stream.deinit();
        self.terminal.deinit(gpa);
        pty_mod.close(&self.pty);
        closeWakePipe(&self.wake_pipe);
        if (self.running_lock) |lock| lock.close(io_mod.io());
        if (self.run_recording) |path| gpa.free(path);
        freeArgv(gpa, self.argv);
        gpa.free(self.name);
        gpa.destroy(self);
    }
    pub fn send(self: *Session, data: []const u8) !void {
        if (self.state.load(.acquire) == .exited) return error.SessionExited;
        try writeInput(self, data, .{ .send = data });
    }

    /// Paste text the way a terminal does: CRLF and LF become CR, and when
    /// the application enabled bracketed paste (mode 2004) the text is
    /// wrapped in ESC[200~ ... ESC[201~ (with any end marker inside it
    /// removed, so the paste cannot end early). Returns whether it was
    /// bracketed.
    pub fn paste(self: *Session, gpa: std.mem.Allocator, text: []const u8) !bool {
        if (self.state.load(.acquire) == .exited) return error.SessionExited;
        const bracketed = blk: {
            const io = io_mod.io();
            self.terminal_mutex.lockUncancelable(io);
            defer self.terminal_mutex.unlock(io);
            break :blk self.terminal.modes.get(.bracketed_paste);
        };
        const data = try pasteBytes(gpa, text, bracketed);
        defer gpa.free(data);
        try writeInput(self, data, .{ .send = data });
        return bracketed;
    }

    /// Encode vim-notation keys against the live terminal state (DECCKM,
    /// kitty keyboard flags, ...) and write them to the PTY.
    pub fn sendKey(self: *Session, gpa: std.mem.Allocator, keys: []const []const u8) !void {
        if (self.state.load(.acquire) == .exited) return error.SessionExited;
        const io = io_mod.io();
        const encoded = blk: {
            self.terminal_mutex.lockUncancelable(io);
            defer self.terminal_mutex.unlock(io);
            break :blk try keys_mod.encodeAll(gpa, &self.terminal, keys);
        };
        defer gpa.free(encoded);
        if (encoded.len == 0) return error.KeyNotEncodable;
        try writeInput(self, encoded, .{ .key = .{ .keys = keys, .encoded = encoded } });
    }

    /// Encode and write one mouse event (SGR/X10/... per terminal state).
    /// Succeeds without sending anything when the application has mouse
    /// reporting off, as a real terminal would; an event the active
    /// reporting mode cannot express is an error.
    pub fn sendMouse(
        self: *Session,
        gpa: std.mem.Allocator,
        button: ?mouse_mod.Button,
        action: mouse_mod.Action,
        mods: mouse_mod.Mods,
        x: u16,
        y: u16,
    ) !void {
        if (self.state.load(.acquire) == .exited) return error.SessionExited;
        const io = io_mod.io();
        var reporting = false;
        const encoded = blk: {
            self.terminal_mutex.lockUncancelable(io);
            defer self.terminal_mutex.unlock(io);
            // Checked under the same lock as the encode so a concurrent
            // resize cannot re-admit an out-of-grid event.
            if (x >= self.cols or y >= self.rows) return error.CoordinatesOutsideGrid;
            reporting = self.terminal.flags.mouse_event != .none;
            break :blk try mouse_mod.encodeMouse(gpa, &self.terminal, self.cols, self.rows, button, action, mods, x, y);
        };
        defer gpa.free(encoded);
        if (encoded.len == 0) {
            if (reporting) return error.MouseEventNotReportable;
            return;
        }
        var mods_buf: [4]u8 = undefined;
        try writeInput(self, encoded, .{ .mouse = .{
            .button = canonicalButtonName(button),
            .action = @tagName(action),
            .mods = modsString(&mods_buf, mods),
            .x = x,
            .y = y,
        } });
    }

    /// Encode and write a focus event (mode 1004). Succeeds without
    /// sending anything when focus reporting is off.
    pub fn sendFocus(self: *Session, gpa: std.mem.Allocator, focused: bool) !void {
        if (self.state.load(.acquire) == .exited) return error.SessionExited;
        const io = io_mod.io();
        const encoded = blk: {
            self.terminal_mutex.lockUncancelable(io);
            defer self.terminal_mutex.unlock(io);
            break :blk try mouse_mod.encodeFocus(gpa, &self.terminal, focused);
        };
        defer gpa.free(encoded);
        if (encoded.len == 0) return;
        try writeInput(self, encoded, .{ .focus = focused });
    }

    /// Resize the PTY and the emulated terminal. The kernel pty is
    /// resized first so SIGWINCH and TIOCGWINSZ agree with the vt state.
    pub fn resize(self: *Session, cols: u16, rows: u16) !void {
        if (self.state.load(.acquire) == .exited) return error.SessionExited;
        const io = io_mod.io();
        {
            self.terminal_mutex.lockUncancelable(io);
            defer self.terminal_mutex.unlock(io);
            try ptyResize(self, cols, rows);
            // Mode 2048 (in-band size reports) needs the handler, which also
            // resizes the terminal grid and reflows the screen.
            try self.stream.handler.resize(.{
                .cols = cols,
                .rows = rows,
                .cell_size_px = .{ .width = 1, .height = 1 },
            });
            self.cols = cols;
            self.rows = rows;
            var frame_buf: [64]u8 = undefined;
            self.broadcastLocked(attach.resizeFrame(&frame_buf, cols, rows));
        }
        recordInput(self, .{ .resize = .{ .cols = cols, .rows = rows } });
        // The in-band size report (mode 2048) was queued by the resize;
        // the child may be waiting for it without producing output.
        ptyWrite(self, "") catch {};
        // Reflow changed the screen without producing child output, so
        // the reader thread will not emit a frame for it.
        if (self.recording_active.load(.acquire)) {
            traceFrame(self);
            // Reflow can also join a wrapped needle onto one row.
            checkMatchStop(self, true);
        }
    }

    /// Terminates the child's process group the way closing a terminal
    /// does: SIGHUP (shells pass it on to their jobs) and SIGTERM, then
    /// SIGKILL for whatever is left after a grace period. Returns once
    /// the session has exited. Processes that left the session (setsid,
    /// daemons) are not tracked.
    pub fn stop(self: *Session) !void {
        const io = io_mod.io();
        if (self.state.load(.acquire) == .exited) return self.waitSettled(io_mod.nowNanos() + stop_exit_wait_ns);
        self.stop_mutex.lockUncancelable(io);
        if (!self.process_reaped.load(.acquire)) signalGroup(self, .terminate);
        self.stop_mutex.unlock(io);

        const grace_end = io_mod.nowNanos() + stop_grace_ns;
        while (io_mod.nowNanos() < grace_end and groupAlive(self)) {
            std.Io.sleep(io, .fromMilliseconds(10), .boot) catch {};
        }
        self.stop_mutex.lockUncancelable(io);
        if (groupAlive(self)) signalGroup(self, .kill);
        self.stop_mutex.unlock(io);

        return self.waitSettled(io_mod.nowNanos() + stop_exit_wait_ns);
    }

    /// Wait until the session has ended and its results are saved: a
    /// daemon told to shut down stops its sessions and must not exit
    /// before then.
    fn waitSettled(self: *Session, deadline: i64) !void {
        while (!self.settled.load(.acquire)) {
            if (io_mod.nowNanos() >= deadline) return error.StopTimeout;
            std.Io.sleep(io_mod.io(), .fromMilliseconds(5), .boot) catch {};
        }
    }

    /// The child's pid, for `list`.
    pub fn pid(self: *Session) u32 {
        return self.process_id;
    }

    /// What a text render covers: the visible screen (the default
    /// everywhere), or the screen plus its scrollback history.
    pub const Region = enum { screen, scrollback };

    fn formatLocked(self: *Session, gpa: std.mem.Allocator, fmt: vt.formatter.Format, region: Region) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        var w = std.Io.Writer.Allocating.fromArrayList(gpa, &list);
        errdefer w.deinit();
        var opts: vt.formatter.Options = .{ .emit = fmt };
        if (fmt == .html) {
            // The page uses the same theme as PNG snapshots.
            opts.background = self.terminal.colors.background.get();
            opts.foreground = self.terminal.colors.foreground.get();
        }
        var formatter = vt.formatter.TerminalFormatter.init(&self.terminal, opts);
        if (region == .screen) {
            const pages = &self.terminal.screens.active.pages;
            formatter.content = .{ .selection = vt.Selection.init(
                pages.getTopLeft(.active),
                pages.getBottomRight(.active).?,
                false,
            ) };
        }
        try formatter.format(&w.writer);
        var out = std.Io.Writer.Allocating.toArrayList(&w);
        return out.toOwnedSlice(gpa);
    }

    /// Subscribe an attach client: under one lock it gets the reply, a
    /// full redraw, and then every later output, so nothing is lost or
    /// repeated in between. A write attach displaces the current writer
    /// only with `force`.
    pub fn attachViewer(self: *Session, v: *attach.Viewer, write: bool, force: bool) !void {
        const gpa = self.gpa;
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        if (write) {
            if (self.writer) |old| {
                if (!force) return error.WriterAttached;
                old.can_write.store(false, .release);
                old.push("{\"writer\":\"taken\"}\n");
            }
        }
        try self.viewers.ensureUnusedCapacity(gpa, 1);
        const vt_bytes = try self.redrawLocked(gpa);
        defer gpa.free(vt_bytes);
        const screen = try attach.screenFrame(gpa, vt_bytes);
        defer gpa.free(screen);
        var reply_buf: [64]u8 = undefined;
        v.pushInitial(std.fmt.bufPrint(&reply_buf, "{{\"ok\":true,\"cols\":{d},\"rows\":{d}}}\n", .{ self.cols, self.rows }) catch unreachable);
        v.pushInitial(screen);
        if (write) self.writer = v;
        self.viewers.appendAssumeCapacity(v);
        if (self.state.load(.acquire) == .exited) {
            var exit_buf: [80]u8 = undefined;
            v.finish(attach.exitFrame(&exit_buf, self.exit_code.load(.acquire)));
        }
    }

    pub fn detachViewer(self: *Session, v: *attach.Viewer) void {
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        if (self.writer == v) self.writer = null;
        for (self.viewers.items, 0..) |item, i| {
            if (item == v) {
                _ = self.viewers.swapRemove(i);
                break;
            }
        }
    }

    /// terminal_mutex must be held.
    fn broadcastLocked(self: *Session, line: []const u8) void {
        for (self.viewers.items) |v| v.push(line);
    }

    /// A full redraw for an attach client: reset, then everything needed
    /// to rebuild the visible screen (palette, modes, content, cursor),
    /// then any escape sequence the child has not finished yet.
    fn redrawLocked(self: *Session, gpa: std.mem.Allocator) ![]u8 {
        var w: std.Io.Writer.Allocating = .init(gpa);
        errdefer w.deinit();
        try w.writer.writeAll("\x1bc");
        // Only palette entries the program changed: the rest would repaint
        // the attaching terminal's own theme with Ghostty's defaults.
        const palette = &self.terminal.colors.palette;
        for (palette.current, palette.original, 0..) |now, was, i| {
            if (std.meta.eql(now, was)) continue;
            try w.writer.print("\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ i, now.r, now.g, now.b });
        }
        var formatter = vt.formatter.TerminalFormatter.init(&self.terminal, .{ .emit = .vt });
        formatter.extra = .all;
        formatter.extra.palette = false;
        const pages = &self.terminal.screens.active.pages;
        formatter.content = .{ .selection = vt.Selection.init(
            pages.getTopLeft(.active),
            pages.getBottomRight(.active).?,
            false,
        ) };
        try formatter.format(&w.writer);
        // If the last chunk ended inside a sequence, replay its start so
        // the next out frame completes it instead of printing as text.
        self.stream.writeContinuation(&w.writer) catch |err| switch (err) {
            error.ContinuationDisabled, error.ContinuationUnavailable => {},
            else => |e| return e,
        };
        return w.toOwnedSlice();
    }

    pub fn format(self: *Session, gpa: std.mem.Allocator, fmt: vt.formatter.Format) ![]u8 {
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        return self.formatLocked(gpa, fmt, .screen);
    }

    pub const ViewSnapshot = struct {
        text: []u8,
        cols: u16,
        rows: u16,
        cursor_row: u16,
        cursor_col: u16,
    };

    pub fn viewSnapshot(self: *Session, gpa: std.mem.Allocator, fmt: vt.formatter.Format, region: Region) !ViewSnapshot {
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        return .{
            .text = try self.formatLocked(gpa, fmt, region),
            .cols = self.cols,
            .rows = self.rows,
            .cursor_row = @intCast(@min(@as(u16, @intCast(self.terminal.screens.active.cursor.y)) + 1, self.rows)),
            .cursor_col = @intCast(@min(@as(u16, @intCast(self.terminal.screens.active.cursor.x)) + 1, self.cols)),
        };
    }

    pub fn lockTerminal(self: *Session) void {
        self.terminal_mutex.lockUncancelable(io_mod.io());
    }

    pub fn unlockTerminal(self: *Session) void {
        self.terminal_mutex.unlock(io_mod.io());
    }

    pub fn recordingFailed(self: *const Session) bool {
        return self.recording_failed.load(.acquire);
    }

    /// Clear the sticky recording-failed flag after it has been
    /// reported, so later unrelated stops do not keep failing.
    pub fn clearRecordingFailed(self: *Session) void {
        self.recording_failed.store(false, .release);
    }

    /// Whether a recording is active right now (lock-free peek).
    pub fn recordingActive(self: *const Session) bool {
        return self.recording_active.load(.acquire);
    }

    /// Reads child output until the pty closes, or until the child has
    /// exited and the remaining output is drained, then marks the
    /// session exited.
    fn readerLoop(s: *Session) void {
        var buf: [32 * 1024]u8 = undefined;
        switch (builtin.os.tag) {
            .windows => while (true) {
                const n = ptyRead(s, &buf) catch break;
                if (n == 0) break;
                consumeOutput(s, buf[0..n]);
            },
            else => readPosix(s, &buf),
        }
        // The exit code comes from the waiter. If the pty closed while
        // the child still runs (it closed its stdio), this waits for it.
        if (s.waiter) |waiter| waiter.join();
        s.waiter = null;
        s.state.store(.exited, .release);
        releasePty(s);
        {
            // Attached clients get the exit event, then their stream ends.
            const io = io_mod.io();
            s.terminal_mutex.lockUncancelable(io);
            defer s.terminal_mutex.unlock(io);
            var exit_buf: [80]u8 = undefined;
            const frame = attach.exitFrame(&exit_buf, s.exit_code.load(.acquire));
            for (s.viewers.items) |v| v.finish(frame);
        }
        // Unthrottled final check: the last chunk may have printed the
        // needle within the throttle window.
        checkMatchStop(s, true);
        stopRecordingReason(s, .exit, null);
        s.persist();
    }
};

fn dupeArgv(gpa: std.mem.Allocator, argv: []const []const u8) ![][]u8 {
    const out = try gpa.alloc([]u8, argv.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |arg| gpa.free(arg);
        gpa.free(out);
    }
    for (argv, 0..) |arg, i| {
        out[i] = try gpa.dupe(u8, arg);
        done = i + 1;
    }
    return out;
}

fn freeArgv(gpa: std.mem.Allocator, argv: [][]u8) void {
    for (argv) |arg| gpa.free(arg);
    gpa.free(argv);
}

/// Rows without text at the bottom of the screen, the rows Ghostty's
/// formatter leaves out.
fn trailingBlankRows(t: *const vt.Terminal) usize {
    const pages = &t.screens.active.pages;
    var blank: usize = 0;
    var row: usize = t.rows;
    while (row > 0) {
        row -= 1;
        const pin = pages.pin(.{ .active = .{ .y = @intCast(row) } }) orelse break;
        for (pin.cells(.all)) |cell| {
            if (cell.hasText()) return blank;
        }
        blank += 1;
    }
    return blank;
}

/// Parse one chunk of child output, answer its queries, and record it.
fn consumeOutput(s: *Session, data: []const u8) void {
    const io = io_mod.io();
    s.terminal_mutex.lockUncancelable(io);
    s.stream.nextSlice(data);
    if (s.viewers.items.len > 0) {
        if (attach.outFrame(s.gpa, data)) |frame| {
            defer s.gpa.free(frame);
            s.broadcastLocked(frame);
        } else |_| {}
    }
    const has_replies = s.pending_replies.items.len > 0;
    s.terminal_mutex.unlock(io);
    if (has_replies) _ = tryFlushReplies(s);
    if (s.recording_active.load(.acquire)) {
        recordOutput(s, data);
        checkChunkMatch(s, data);
    }
    s.last_output.store(io_mod.nowNanos(), .monotonic);
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
    while (true) {
        var fds = [2]std.c.pollfd{
            .{ .fd = master, .events = POLL.IN, .revents = 0 },
            .{ .fd = s.wake_pipe[0], .events = POLL.IN, .revents = 0 },
        };
        if (!replies_busy and hasPendingReplies(s)) fds[0].events |= POLL.OUT;
        var timeout_ms: c_int = -1;
        var nfds: std.c.nfds_t = 2;
        if (drain_end) |end| {
            const left_ms = @divTrunc(end - io_mod.nowNanos(), std.time.ns_per_ms);
            if (left_ms <= 0) return;
            timeout_ms = @intCast(@min(left_ms, exit_drain_idle_ms));
            nfds = 1;
        } else if (replies_busy) {
            timeout_ms = 10;
        }
        const rc = std.c.poll(&fds, nfds, timeout_ms);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return;
        }
        if (rc == 0) {
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
            const n = std.c.read(master, buf.ptr, buf.len);
            if (n > 0) {
                consumeOutput(s, buf[0..@intCast(n)]);
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

/// A POSIX child spawn handed to the session's waiter thread.
const SpawnRequest = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    child_env: []const []const u8,
    done: std.Io.Event = .unset,
    result: anyerror!void = {},
};

/// POSIX waiter thread: fork the child, report the outcome to `start`
/// (whose stack owns `request`), then wait for the child to exit.
fn spawnAndWait(s: *Session, request: *SpawnRequest) void {
    const io = io_mod.io();
    const proc = spawnPosixChild(request.gpa, request.opts, request.child_env, &s.pty) catch |err| {
        request.result = err;
        request.done.set(io);
        return;
    };
    s.proc = proc;
    s.process_id = procPid(proc);
    request.done.set(io);
    waiterLoop(s);
}

/// Waits for the child to exit, stores its exit code, and wakes the
/// reader. On POSIX the child is waited for without reaping, so its pid
/// (and with it the process group id) stays reserved until it is reaped
/// under `stop_mutex`; `stop` therefore never signals a recycled pid.
fn waiterLoop(s: *Session) void {
    const io = io_mod.io();
    switch (builtin.os.tag) {
        .windows => {
            _ = win32.WaitForSingleObject(s.proc.windows.process, win32.INFINITE);
            s.stop_mutex.lockUncancelable(io);
            var raw: win32.DWORD = 0xFFFFFFFF;
            _ = win32.GetExitCodeProcess(s.proc.windows.process, &raw);
            _ = win32.CloseHandle(s.proc.windows.process);
            // KILL_ON_JOB_CLOSE: closing the job ends whatever the child
            // left behind, as closing a terminal window would.
            _ = win32.CloseHandle(s.proc.windows.job);
            s.process_reaped.store(true, .release);
            s.stop_mutex.unlock(io);
            s.exit_code.store(windowsExitCode(raw), .release);
            s.child_exited.store(true, .release);
            // ConPTY keeps its output pipe open until the pseudoconsole
            // is closed, so the reader sees EOF only after this.
            s.terminal_mutex.lockUncancelable(io);
            const hpc = s.pty.windows.hpc;
            s.pty.windows.hpc = null;
            s.terminal_mutex.unlock(io);
            if (hpc) |h| win32.ClosePseudoConsole(h);
        },
        else => {
            const child_pid = s.proc.posix.id.?;
            var info: wait_c.siginfo_t = undefined;
            while (true) {
                const rc = wait_c.waitid(wait_c.P_PID, @intCast(child_pid), &info, wait_c.WEXITED | wait_c.WNOWAIT);
                if (rc == 0 or std.posix.errno(rc) != .INTR) break;
            }
            s.stop_mutex.lockUncancelable(io);
            const code = reapPosix(&s.proc, io);
            s.process_reaped.store(true, .release);
            s.stop_mutex.unlock(io);
            s.exit_code.store(code, .release);
            s.child_exited.store(true, .release);
            const byte = [_]u8{1};
            _ = std.c.write(s.wake_pipe[1], &byte, 1);
        },
    }
}

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

fn pasteBytes(gpa: std.mem.Allocator, text: []const u8, bracketed: bool) ![]u8 {
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

fn hasPendingReplies(s: *Session) bool {
    const io = io_mod.io();
    s.terminal_mutex.lockUncancelable(io);
    defer s.terminal_mutex.unlock(io);
    return s.pending_replies.items.len > 0;
}

/// Write input to the pty and record it. The input event is recorded
/// first so a trace never shows the screen reacting before the input;
/// a failed write is followed by a marker saying so.
fn writeInput(s: *Session, data: []const u8, input: trace_mod.Input) !void {
    recordInput(s, input);
    ptyWrite(s, data) catch |err| {
        recordMark(s, "input not delivered") catch {};
        return err;
    };
}

/// Write bytes to the PTY master after any queued query replies, so the
/// child's input stream is never interleaved mid-sequence. Fails with
/// error.InputStalled when the child stops reading for `input_stall_ns`
/// and with error.SessionExited when it exits meanwhile.
fn ptyWrite(s: *Session, data: []const u8) !void {
    const io = io_mod.io();
    {
        // Another write may be stalled on a child that stopped reading;
        // queueing behind it without a limit would pin this request (and
        // its connection slot) for N x the stall limit.
        try lockWriteBounded(s);
        defer s.write_mutex.unlock(io);
        try flushRepliesBlocking(s);
        try writeAllBounded(s, data);
        try flushRepliesBlocking(s);
    }
    // The reader cannot flush while this write holds the lock; replies
    // it queued after the last flush above are sent here.
    if (hasPendingReplies(s)) _ = tryFlushReplies(s);
}

fn lockWriteBounded(s: *Session) !void {
    const deadline = io_mod.nowNanos() + input_stall_ns;
    while (!s.write_mutex.tryLock()) {
        if (s.child_exited.load(.acquire)) return error.SessionExited;
        if (s.write_stalled.load(.acquire)) return error.InputBusy;
        if (io_mod.nowNanos() >= deadline) return error.InputBusy;
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

/// write_mutex must be held.
fn flushRepliesBlocking(s: *Session) !void {
    var replies = takeReplies(s);
    defer replies.deinit(s.gpa);
    if (replies.items.len > 0) try writeAllBounded(s, replies.items);
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
            writeAllBounded(s, replies.items) catch {};
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
/// exits) can never wedge the calling request.
fn writeAllBounded(s: *Session, data: []const u8) !void {
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
                        const waited = io_mod.nowNanos() - last_progress;
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
fn ptyResize(s: *Session, cols: u16, rows: u16) !void {
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

/// Spawn the child on Windows with the pseudoconsole attribute. The
/// child's ConPTY handles are the ones given to CreatePseudoConsole;
/// only the HPCON is passed via STARTUPINFOEXW.
fn spawnWindowsChild(gpa: std.mem.Allocator, opts: Options, child_env: []const []const u8, pair: *const pty_mod.Pair) !Proc {
    const cmd = try buildWindowsCommandLine(gpa, opts.argv);
    defer gpa.free(cmd);
    // Without a caller environment the child inherits the daemon's.
    const env_block: ?[:0]u16 = if (opts.env != null) try buildWindowsEnvBlock(gpa, child_env) else null;
    defer if (env_block) |block| gpa.free(block);
    const cwd_buf = if (opts.cwd) |cwd_path| blk: {
        if (cwd_path.len == 0 or std.mem.indexOfScalar(u8, cwd_path, 0) != null) return error.BadCwd;
        break :blk std.unicode.utf8ToUtf16LeAllocZ(gpa, cwd_path) catch return error.BadCwd;
    } else null;
    defer if (cwd_buf) |buf| gpa.free(buf);
    const cwd: ?win32.LPCWSTR = if (cwd_buf) |buf| @ptrCast(buf.ptr) else null;

    // The pseudoconsole attribute list lives in a plain byte buffer.
    // The first call is the documented sizing query: it always fails
    // with ERROR_INSUFFICIENT_BUFFER but writes the required size.
    var attr_size: usize = 0;
    _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    if (attr_size == 0) return error.SpawnFailed;
    // The list holds pointer-sized fields; align the storage accordingly.
    const attr_list = gpa.alignedAlloc(u8, .of(usize), attr_size) catch return error.OutOfMemory;
    defer gpa.free(attr_list);
    if (win32.InitializeProcThreadAttributeList(attr_list.ptr, 1, 0, &attr_size) == 0) return error.SpawnFailed;
    defer win32.DeleteProcThreadAttributeList(attr_list.ptr);
    const hpc = pair.windows.hpc.?;
    if (win32.UpdateProcThreadAttribute(
        attr_list.ptr,
        0,
        win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        @as(*const anyopaque, @ptrCast(&hpc)),
        @sizeOf(win32.HPCON),
        null,
        null,
    ) == 0) return error.SpawnFailed;

    var si: win32.STARTUPINFOEXW = std.mem.zeroes(win32.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);
    si.lpAttributeList = attr_list.ptr;

    var pi: win32.PROCESS_INFORMATION = std.mem.zeroes(win32.PROCESS_INFORMATION);
    const job = win32.CreateJobObjectW(null, null);
    if (@intFromPtr(job) == 0) return error.SpawnFailed;
    errdefer _ = win32.CloseHandle(job);
    var job_info: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    job_info.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (win32.SetInformationJobObject(
        job,
        win32.JobObjectExtendedLimitInformation,
        &job_info,
        @sizeOf(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ) == 0) return error.SpawnFailed;
    if (win32.CreateProcessW(
        null,
        @ptrCast(cmd.ptr),
        null,
        null,
        0, // ConPTY handles are not inherited; the console is.
        win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_SUSPENDED | win32.CREATE_UNICODE_ENVIRONMENT,
        if (env_block) |block| @ptrCast(block.ptr) else null,
        cwd,
        &si.StartupInfo,
        &pi,
    ) == 0) return error.SpawnFailed;
    errdefer {
        _ = win32.TerminateProcess(pi.hProcess, 1);
        _ = win32.WaitForSingleObject(pi.hProcess, win32.INFINITE);
        _ = win32.CloseHandle(pi.hThread);
        _ = win32.CloseHandle(pi.hProcess);
    }
    if (win32.AssignProcessToJobObject(job, pi.hProcess) == 0) return error.SpawnFailed;
    if (win32.ResumeThread(pi.hThread) == 0xFFFFFFFF) return error.SpawnFailed;
    _ = win32.CloseHandle(pi.hThread);
    return .{ .windows = .{ .process = pi.hProcess, .job = job, .pid = pi.dwProcessId } };
}

/// A CreateProcessW environment block: UTF-16 "NAME=value" entries, each
/// NUL-terminated, sorted case-insensitively by name, ending in an empty
/// entry.
fn buildWindowsEnvBlock(gpa: std.mem.Allocator, env: []const []const u8) ![:0]u16 {
    const sorted = try gpa.dupe([]const u8, env);
    defer gpa.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const an = a[0 .. std.mem.indexOfScalar(u8, a, '=') orelse a.len];
            const bn = b[0 .. std.mem.indexOfScalar(u8, b, '=') orelse b.len];
            return std.ascii.lessThanIgnoreCase(an, bn);
        }
    }.lessThan);
    var block: std.ArrayList(u16) = .empty;
    defer block.deinit(gpa);
    for (sorted) |entry| {
        const wide = std.unicode.utf8ToUtf16LeAlloc(gpa, entry) catch return error.BadEnv;
        defer gpa.free(wide);
        try block.appendSlice(gpa, wide);
        try block.append(gpa, 0);
    }
    // The block ends with an empty entry; the returned sentinel is the
    // final terminator.
    if (sorted.len == 0) try block.append(gpa, 0);
    return block.toOwnedSliceSentinel(gpa, 0);
}

/// Fork and exec the child on the pty slave: new session, the slave as
/// controlling terminal (which makes the child's process group the
/// foreground group), default signal dispositions and an empty signal
/// mask, the session environment, and the requested working directory.
/// The master is the parent's only end; the slave is closed here.
fn spawnPosixChild(gpa: std.mem.Allocator, opts: Options, child_env: []const []const u8, pair: *pty_mod.Pair) !Proc {
    // Everything that allocates or locks must happen before fork();
    // after fork the child only runs async-signal-safe calls.
    const cargv = try allocCArgvZ(gpa, opts.argv);
    defer freeCArgvZ(gpa, cargv);
    const cenv = try allocCArgvZ(gpa, child_env);
    defer freeCArgvZ(gpa, cenv);
    const cwd_z = if (opts.cwd) |cwd| blk_cwd: {
        if (cwd.len == 0 or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.BadCwd;
        const z = try gpa.dupeZ(u8, cwd);
        errdefer gpa.free(z);
        const dir_fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (dir_fd < 0) return switch (std.posix.errno(dir_fd)) {
            .MFILE, .NFILE => error.TooManyOpenFiles,
            else => error.BadCwd,
        };
        _ = std.c.close(dir_fd);
        if (std.c.access(z, std.c.X_OK) != 0) return error.BadCwd;
        break :blk_cwd z;
    } else null;
    defer if (cwd_z) |z| gpa.free(z);

    var empty_mask: std.c.sigset_t = undefined;
    _ = std.c.sigemptyset(&empty_mask);
    const default_action: std.c.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = empty_mask,
        .flags = 0,
    };

    var setup_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&setup_pipe) != 0) return error.PipeFailed;
    defer _ = std.c.close(setup_pipe[0]);
    errdefer _ = std.c.close(setup_pipe[1]);
    if (std.c.fcntl(setup_pipe[1], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) != 0) return error.PipeFailed;

    const daemon_pid = std.c.getpid();
    const child_pid = std.c.fork();
    if (child_pid < 0) return error.ForkFailed;
    if (child_pid == 0) {
        _ = std.c.close(setup_pipe[0]);
        // Ignored signals and the blocked mask survive exec; a daemon
        // started from a script (`tuppet daemon &` ignores SIGINT) must not
        // pass that on, or Ctrl-C could never interrupt the child.
        var sig: u8 = 1;
        while (sig < 32) : (sig += 1) _ = std.c.sigaction(@enumFromInt(sig), &default_action, null);
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, &empty_mask, null);
        // A supervised daemon's sessions must not outlive it, even when
        // it is SIGKILLed. If the daemon died before prctl took effect,
        // the child is already orphaned: give up.
        if (builtin.os.tag == .linux and supervised) {
            _ = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_PDEATHSIG), @intFromEnum(std.posix.SIG.KILL), 0, 0, 0);
            if (std.c.getppid() != daemon_pid) std.c._exit(1);
        }
        // A slave that landed on fd 0-2 (daemon started with stdio
        // closed) must move first: dup2 onto the same fd is a no-op
        // and would keep FD_CLOEXEC, so the exec'd child would find its
        // own stdio closed. dup() clears FD_CLOEXEC on the new
        // descriptor.
        var slave = pair.posix.slave;
        if (slave >= 0 and slave <= 2) {
            slave = std.c.dup(slave);
            if (slave < 0) childSetupFailed(setup_pipe[1]);
        }
        if (std.c.setsid() < 0 or
            std.c.ioctl(slave, pty_mod.TIOCSCTTY, @as(?*anyopaque, null)) < 0 or
            (cwd_z != null and std.c.chdir(cwd_z.?) < 0) or
            std.c.dup2(slave, 0) < 0 or
            std.c.dup2(slave, 1) < 0 or
            std.c.dup2(slave, 2) < 0)
        {
            childSetupFailed(setup_pipe[1]);
        }
        if (slave > 2) _ = std.c.close(slave);
        std.c.environ = @ptrCast(@constCast(cenv.z));
        _ = execvp(cargv.z[0].?, cargv.z);
        childSetupFailed(setup_pipe[1]);
    }
    _ = std.c.close(pair.posix.slave);
    pair.posix.slave = -1;
    _ = std.c.close(setup_pipe[1]);
    setup_pipe[1] = -1;
    var child = std.process.Child{
        .id = @intCast(child_pid),
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    var setup_failed: [1]u8 = undefined;
    if (std.c.read(setup_pipe[0], &setup_failed, setup_failed.len) > 0) {
        _ = child.wait(io_mod.io()) catch null;
        return error.ChildSetupFailed;
    }
    return .{ .posix = child };
}

fn buildWindowsCommandLine(gpa: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var cmd: std.ArrayList(u16) = .empty;
    defer cmd.deinit(gpa);
    for (argv, 0..) |arg, arg_index| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgument;
        const wide = try std.unicode.utf8ToUtf16LeAlloc(gpa, arg);
        defer gpa.free(wide);
        if (arg_index > 0) try cmd.append(gpa, ' ');
        const quote = wide.len == 0 or std.mem.indexOfAny(u16, wide, &.{ ' ', '\t', '"' }) != null;
        if (!quote) {
            try cmd.appendSlice(gpa, wide);
            continue;
        }
        try cmd.append(gpa, '"');
        var slash_count: usize = 0;
        for (wide) |ch| {
            if (ch == '\\') {
                slash_count += 1;
                continue;
            }
            const copies = if (ch == '"') slash_count * 2 + 1 else slash_count;
            try cmd.appendNTimes(gpa, '\\', copies);
            slash_count = 0;
            try cmd.append(gpa, ch);
        }
        try cmd.appendNTimes(gpa, '\\', slash_count * 2);
        try cmd.append(gpa, '"');
    }
    return cmd.toOwnedSliceSentinel(gpa, 0);
}

const GroupSignal = enum { terminate, kill };

/// Signal the child's process group (Windows: its job). stop_mutex must
/// be held: on POSIX the group id is the child's pid, which the waiter
/// keeps reserved until it reaps the child under the same mutex. SIGKILL
/// also reaches the session's other process groups on Linux: an
/// interactive shell runs each background job in its own group.
fn signalGroup(s: *Session, how: GroupSignal) void {
    switch (builtin.os.tag) {
        .windows => {
            if (!s.process_reaped.load(.acquire)) _ = win32.TerminateJobObject(s.proc.windows.job, 1);
        },
        else => {
            const group = -@as(std.posix.pid_t, @intCast(s.process_id));
            switch (how) {
                .terminate => {
                    _ = std.c.kill(group, std.posix.SIG.HUP);
                    _ = std.c.kill(group, std.posix.SIG.TERM);
                },
                .kill => {
                    _ = std.c.kill(group, std.posix.SIG.KILL);
                    _ = forEachSessionMember(s.process_id, std.posix.SIG.KILL);
                },
            }
        },
    }
}

/// Whether any process of the child's group (or, on Linux, its session)
/// is still alive; the child itself counts until it is reaped. A group
/// or session that still has members keeps its id reserved, so
/// signalling it right after this check is safe from pid reuse.
fn groupAlive(s: *Session) bool {
    return switch (builtin.os.tag) {
        .windows => !s.process_reaped.load(.acquire),
        else => std.c.kill(-@as(std.posix.pid_t, @intCast(s.process_id)), @enumFromInt(0)) == 0 or
            forEachSessionMember(s.process_id, null) > 0,
    };
}

/// Linux: send `sig` (or nothing, to count) to every process whose
/// session id is `sid`, by scanning /proc. Returns how many there are.
/// Other systems have no such scan; they rely on the group kill.
fn forEachSessionMember(sid: u32, sig: ?std.posix.SIG) usize {
    if (builtin.os.tag != .linux) return 0;
    const io = io_mod.io();
    var proc_dir = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return 0;
    defer proc_dir.close(io);
    var count: usize = 0;
    var it = proc_dir.iterate();
    while (it.next(io) catch null) |entry| {
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        if (procSessionId(pid) != sid) continue;
        count += 1;
        if (sig) |sg| _ = std.c.kill(pid, sg);
    }
    return count;
}

/// The session id from /proc/<pid>/stat: the fourth field after the
/// parenthesized command name.
fn procSessionId(pid: std.posix.pid_t) ?u32 {
    var path_buf: [32:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var buf: [512]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const text = buf[0..@intCast(n)];
    const close_paren = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[close_paren + 1 ..], ' ');
    _ = fields.next(); // state
    _ = fields.next(); // ppid
    _ = fields.next(); // pgrp
    return std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch null;
}

fn forceKillProc(proc: Proc) void {
    switch (builtin.os.tag) {
        .windows => _ = win32.TerminateJobObject(proc.windows.job, 1),
        else => {
            if (proc.posix.id) |child_pid| _ = std.c.kill(-child_pid, std.posix.SIG.KILL);
        },
    }
}

/// Startup rollback before the exit waiter owns the child.
fn stopAndReapProc(proc: *Proc, io: std.Io) i32 {
    forceKillProc(proc.*);
    return switch (builtin.os.tag) {
        .windows => blk: {
            _ = win32.WaitForSingleObject(proc.windows.process, win32.INFINITE);
            var raw: win32.DWORD = 0xFFFFFFFF;
            _ = win32.GetExitCodeProcess(proc.windows.process, &raw);
            _ = win32.CloseHandle(proc.windows.process);
            _ = win32.CloseHandle(proc.windows.job);
            break :blk windowsExitCode(raw);
        },
        else => reapPosix(proc, io),
    };
}

/// Reap the child with waitpid directly: Child.wait treats ECHILD (a
/// daemon started with SIGCHLD ignored lets the kernel auto-reap) as a
/// programmer bug and panics in safe builds.
fn reapPosix(proc: *Proc, io: std.Io) i32 {
    _ = io;
    const child_pid = proc.posix.id orelse return -1;
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(child_pid, &status, 0);
        if (rc == child_pid) break;
        if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
        return -1;
    }
    const st: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(st)) return std.c.W.EXITSTATUS(st);
    if (std.c.W.IFSIGNALED(st)) return -@as(i32, @intCast(@intFromEnum(std.c.W.TERMSIG(st))));
    return -1;
}

fn procPid(proc: Proc) u32 {
    return switch (builtin.os.tag) {
        .windows => proc.windows.pid,
        else => @intCast(proc.posix.id orelse 0),
    };
}

fn windowsExitCode(raw: u32) i32 {
    return @bitCast(raw);
}

/// Queue the parser's reply (DSR, DA, ...) for the pty. Runs on the
/// reader thread with terminal_mutex held.
/// Replies queued for a child that floods queries without reading its
/// input are dropped beyond this; it cannot be waiting for them.
const max_pending_replies = 64 * 1024;

fn writePtyEffect(h: *vt.TerminalStream.Handler, data: [:0]const u8) void {
    const s: *Session = @fieldParentPtr("terminal", h.terminal);
    if (s.pending_replies.items.len + data.len > max_pending_replies) return;
    s.pending_replies.appendSlice(s.gpa, data) catch {};
}

/// Answer DA1 (CSI c): identify as a VT220 with ANSI color. The
/// return type (device_attributes.Attributes) is not exported by the
/// vt module, so it is derived from the effects struct's field type.
const DA_Attributes = @typeInfo(@typeInfo(
    std.meta.Child(std.meta.fieldInfo(std.meta.fieldInfo(vt.TerminalStream.Handler, .effects).type, .device_attributes).type),
).pointer.child).@"fn".return_type.?;

fn deviceAttributesEffect(h: *vt.TerminalStream.Handler) DA_Attributes {
    _ = h;
    return .{};
}

/// Answer XTVERSION (CSI > 0 q): identify as tuppet.
fn xtversionEffect(h: *vt.TerminalStream.Handler) []const u8 {
    _ = h;
    return "tuppet " ++ protocol.version;
}

/// Answer size queries (CSI 14/16/18 t) with the session's cell geometry.
/// Headless, so the cell size is reported as 1x1 pixel.
fn sizeEffect(h: *vt.TerminalStream.Handler) ?vt.size_report.Size {
    return .{
        .rows = h.terminal.rows,
        .columns = h.terminal.cols,
        .cell_width = 1,
        .cell_height = 1,
    };
}

// ---- registry ---------------------------------------------------------

/// Sessions this daemon holds in memory: the ones it runs, and ended
/// ones loaded from the store. Ids come from the store.
var registry: std.AutoArrayHashMapUnmanaged(u64, *Session) = .empty;
/// The registry's only allocator; growing and freeing it with different
/// allocators corrupts the heap.
const registry_gpa = std.heap.page_allocator;
var reg_mutex: std.Io.Mutex = .init;
/// Serializes loading ended sessions from the store with deleting them,
/// so a deleted session is never loaded back into memory.
var load_mutex: std.Io.Mutex = .init;

fn reserveRegistrySlot() !void {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    try registry.ensureUnusedCapacity(registry_gpa, 1);
}

/// The slot was reserved by reserveRegistrySlot under spawn_mutex.
fn register(s: *Session) void {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    registry.putAssumeCapacity(s.id, s);
}

/// Look up a session and take a reference that keeps it alive until
/// `release`. Every request touching a session holds one. A session that
/// ended under an earlier daemon is loaded from the store.
pub fn acquire(id: u64) ?*Session {
    if (acquireLoaded(id)) |s| return s;
    const io = io_mod.io();
    load_mutex.lockUncancelable(io);
    defer load_mutex.unlock(io);
    const loaded = loadStored(id) orelse return null;
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    // Another request may have loaded it meanwhile.
    const s = registry.get(id) orelse blk: {
        // Keep a slot spare: a start in progress has reserved one, and
        // starts are serialized, so there is never more than one.
        registry.ensureUnusedCapacity(registry_gpa, 2) catch {
            loaded.deinit();
            return null;
        };
        registry.putAssumeCapacity(id, loaded);
        break :blk loaded;
    };
    if (s != loaded) loaded.deinit();
    _ = s.refs.fetchAdd(1, .acq_rel);
    return s;
}

fn acquireLoaded(id: u64) ?*Session {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    const s = registry.get(id) orelse return null;
    _ = s.refs.fetchAdd(1, .acq_rel);
    return s;
}

/// Rebuild a session of this daemon's endpoint that ended and was saved.
fn loadStored(id: u64) ?*Session {
    const parsed = (store.readMeta(store_gpa, id) catch null) orelse return null;
    defer parsed.deinit();
    const meta = parsed.value;
    if (!std.mem.eql(u8, meta.socket, endpoint) or meta.ended_ms == null or meta.lost) return null;
    const screen = store.readScreen(store_gpa, id) catch |err| {
        std.log.err("session {d}: cannot read its saved screen: {}", .{ id, err });
        return null;
    };
    defer store_gpa.free(screen);
    return Session.restore(store_gpa, meta, screen) catch |err| {
        std.log.err("session {d}: cannot restore it: {}", .{ id, err });
        return null;
    };
}

/// Why `acquire` found no session, for the error message; null when the
/// id was never used for one in this boot (or was removed).
pub fn missingReason(gpa: std.mem.Allocator, id: u64) ?[]u8 {
    const parsed = (store.readMeta(gpa, id) catch null) orelse return null;
    defer parsed.deinit();
    const meta = parsed.value;
    if (!std.mem.eql(u8, meta.socket, endpoint)) {
        return std.fmt.allocPrint(gpa, "session {d} belongs to the daemon on {s}", .{ id, meta.socket }) catch null;
    }
    if (meta.lost or (meta.ended_ms == null and !store.isRunning(id))) {
        return std.fmt.allocPrint(gpa, "session {d} was lost: its daemon stopped while it ran, so its output was not saved", .{id}) catch null;
    }
    return null;
}

/// The stored sessions of this daemon's endpoint that it does not hold
/// in memory, for `list`. `arena` owns everything returned.
pub fn storedInfos(arena: std.mem.Allocator) ![]protocol.SessionInfo {
    const gpa = arena;
    var list: std.ArrayList(protocol.SessionInfo) = .empty;
    const all = try store.ids(gpa);
    for (all) |id| {
        if (acquireLoaded(id)) |s| {
            release(s);
            continue;
        }
        const parsed = (store.readMeta(gpa, id) catch continue) orelse continue;
        const meta = parsed.value;
        if (!std.mem.eql(u8, meta.socket, endpoint)) continue;
        const lost = meta.lost or (meta.ended_ms == null and !store.isRunning(id));
        if (!lost and meta.ended_ms == null) continue;
        try list.append(gpa, .{
            .id = id,
            .name = meta.name,
            .state = if (lost) "lost" else "exited",
            .pid = @intCast(meta.pid),
            .cols = meta.cols,
            .rows = meta.rows,
            .exit_code = if (lost) null else meta.exit_code,
            .argv = meta.argv,
            .started_ms = meta.started_ms,
            .ended_ms = meta.ended_ms,
        });
    }
    return list.toOwnedSlice(gpa);
}

/// How many sessions are running or still saving their results: the
/// daemon may only exit when there are none. Ended sessions are safe in
/// the store.
pub fn unsettledCount() usize {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    var n: usize = 0;
    for (registry.values()) |s| {
        if (!s.settled.load(.acquire)) n += 1;
    }
    return n;
}

pub fn release(s: *Session) void {
    _ = s.refs.fetchSub(1, .acq_rel);
}

/// Every session, each with a reference taken; see `releaseAll`.
pub fn acquireAll(gpa: std.mem.Allocator) ![]*Session {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    const list = try gpa.dupe(*Session, registry.values());
    for (list) |s| _ = s.refs.fetchAdd(1, .acq_rel);
    return list;
}

pub fn releaseAll(gpa: std.mem.Allocator, list: []*Session) void {
    for (list) |s| release(s);
    gpa.free(list);
}

/// Drop sessions the store has expired from memory as well.
pub fn forgetExpired(deleted: []const u64) void {
    const io = io_mod.io();
    load_mutex.lockUncancelable(io);
    defer load_mutex.unlock(io);
    for (deleted) |id| forget(id) catch {};
}

/// Delete an ended session, from memory and from the store.
pub fn remove(id: u64) error{ NoSession, StillRunning }!void {
    const io = io_mod.io();
    load_mutex.lockUncancelable(io);
    defer load_mutex.unlock(io);
    if (forget(id)) |_| {
        store.removeSession(id);
        return;
    } else |err| if (err != error.NoSession) return err;
    // Not in memory: an ended or lost session of this endpoint in the
    // store.
    const parsed = (store.readMeta(store_gpa, id) catch null) orelse return error.NoSession;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.socket, endpoint)) return error.NoSession;
    if (store.isRunning(id)) return error.StillRunning;
    store.removeSession(id);
}

/// Drop an ended session from memory: it disappears from the registry at
/// once and is freed when the requests still using it are done. Only
/// this session's users wait; no lock is held while they finish.
pub fn forget(id: u64) error{ NoSession, StillRunning }!void {
    const io = io_mod.io();
    // A program that has just exited is still saving its results; wait
    // for that rather than fail a remove right after `wait --exit`.
    if (acquireLoaded(id)) |s| {
        defer release(s);
        if (s.state.load(.acquire) == .exited) s.waitSettled(io_mod.nowNanos() + stop_exit_wait_ns) catch {};
    }
    const s = blk: {
        reg_mutex.lockUncancelable(io);
        defer reg_mutex.unlock(io);
        const s = registry.get(id) orelse return error.NoSession;
        if (!s.settled.load(.acquire)) return error.StillRunning;
        _ = registry.orderedRemove(id);
        break :blk s;
    };
    while (s.refs.load(.acquire) != 0) {
        std.Io.sleep(io, .fromMilliseconds(1), .boot) catch {};
    }
    s.deinit();
}

// ---- tests ------------------------------------------------------------

var test_resp: std.ArrayListUnmanaged(u8) = .empty;

fn testWritePty(h: *vt.TerminalStream.Handler, data: [:0]const u8) void {
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

test "Windows command line preserves quoting and Unicode" {
    const alloc = std.testing.allocator;
    const cmd = try buildWindowsCommandLine(alloc, &.{
        "",
        "plain",
        "two words",
        "quote\"here",
        "trailing slash\\",
        "space slash\\",
        "Grüße 😀",
    });
    defer alloc.free(cmd);
    const expected = std.unicode.utf8ToUtf16LeStringLiteral(
        "\"\" plain \"two words\" \"quote\\\"here\" \"trailing slash\\\\\" \"space slash\\\\\" \"Grüße 😀\"",
    );
    try std.testing.expectEqualSlices(u16, expected, cmd);
    try std.testing.expectError(error.InvalidArgument, buildWindowsCommandLine(alloc, &.{"bad\x00arg"}));
}

test "Windows exception exit codes have stable signed representation" {
    try std.testing.expectEqual(@as(i32, 0), windowsExitCode(0));
    try std.testing.expectEqual(@as(i32, -1073741819), windowsExitCode(0xC0000005));
    try std.testing.expectEqual(@as(i32, -1), windowsExitCode(0xFFFFFFFF));
}

test "an explicit environment is used as given, apart from the terminal variables" {
    const env = try buildChildEnv(std.testing.allocator, &.{ "A=1", "TERM=dumb", "TMUX=/tmp/tmux-1/default,1,0", "TERM_PROGRAM=tmux" });
    defer std.testing.allocator.free(env);
    try std.testing.expectEqualDeep(&[_][]const u8{ "A=1", "TERM=xterm-256color" }, env);
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
