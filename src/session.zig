//! A session: a child process in a PTY whose output is parsed by a
//! libghostty-vt terminal. The `write_pty` effect answers the child's
//! queries (DSR, DECRQM, ...) by writing responses back into the PTY
//! master - this is what makes querying apps (Bubble Tea, vim, ...)
//! work without long timeouts.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const io_mod = @import("io.zig");
const pty_mod = @import("pty.zig");
const attach = @import("attach.zig");
const store = @import("store.zig");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else @import("win32_stub.zig");
const spawn = @import("spawn.zig");
const ptyio = @import("ptyio.zig");
const record = @import("record.zig");
const registry = @import("registry.zig");
const track = @import("track.zig");
const protocol = @import("protocol.zig");
const status_mod = @import("status.zig");
const evaluator = @import("evaluator.zig");
const sample = @import("sample.zig");
const batch_mod = @import("batch.zig");
const events = @import("events.zig");
const alert = @import("alert.zig");
const limits = @import("limits.zig");
const budget = @import("budget.zig");

pub const RecordFormat = record.RecordFormat;
pub const startRecording = record.startRecording;
pub const stopRecording = record.stopRecording;
pub const stopRequested = record.stopRequested;
pub const latestRecording = record.latest;
pub const recordMark = record.recordMark;

pub const init = registry.init;
pub const acquire = registry.acquire;
pub const unsettledCount = registry.unsettledCount;
pub const release = registry.release;
pub const acquireAll = registry.acquireAll;
pub const releaseAll = registry.releaseAll;
pub const forgetExpired = registry.forgetExpired;
pub const remove = registry.remove;

/// Set by a daemon started with --socket: a supervisor owns its
/// lifetime, so session children die with it (Linux).
pub var supervised = false;

/// Set once the daemon is shutting down: no session starts after that.
pub var stopping: std.atomic.Value(bool) = .{ .raw = false };

/// Refuse every later start, and return whether starts were refused
/// already. Under spawn_mutex, so a start in progress has registered its
/// session before this returns.
pub fn refuseStarts() bool {
    const io = io_mod.io();
    spawn.spawn_mutex.lockUncancelable(io);
    defer spawn.spawn_mutex.unlock(io);
    return stopping.swap(true, .acq_rel);
}

/// `stop` gives the process group this long to exit after SIGHUP and
/// SIGTERM before it sends SIGKILL.
const stop_grace_ns: i64 = 500 * std.time.ns_per_ms;
/// How long `stop` waits for the program to exit after SIGKILL.
pub const stop_exit_wait_ns: i64 = 3 * std.time.ns_per_s;
/// How long an ended session may take to save its results: rendering a
/// large history and writing it can take seconds on a busy machine. With
/// the grace and the exit wait, a stop stays within the 10 s a client
/// waits for its reply.
pub const save_wait_ns: i64 = 5 * std.time.ns_per_s;

pub const State = enum(u8) {
    running,
    exited,
};

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
    scrollback: u64 = limits.default_scrollback,
    /// Record from the program's first byte.
    record: ?RunRecord = null,
    /// Alerts, checked with alert.rulesError, watching from the first byte.
    alerts: []const alert.Rule = &.{},
};

/// A recording that starts with the session: to `path`, or to a file in
/// the session's store directory when `path` is null.
pub const RunRecord = struct {
    path: ?[]const u8 = null,
    format: RecordFormat = .cast,
};

/// Ghostty's default theme colors, so OSC 10/11 color queries get
/// answers (the vt library ships them unset).
const default_fg: vt.color.RGB = .{ .r = 0xdc, .g = 0xd7, .b = 0xba };
const default_bg: vt.color.RGB = .{ .r = 0x1f, .g = 0x1f, .b = 0x28 };

pub const Session = struct {
    id: u64,
    name: []const u8,
    cols: u16,
    rows: u16,
    /// The history limit in bytes.
    scrollback: u64,
    /// What the session reserves of the memory budget for its screens
    /// (limits.sessionFloor), and what it uses of it: that or what its
    /// screens and history take, whichever is more; both guarded
    /// by terminal_mutex.
    floor: u64 = 0,
    charged: u64 = 0,
    /// The lower history limit the memory budget holds it to, or null
    /// while it has its own; guarded by terminal_mutex.
    history_cap: ?u64 = null,
    /// The bytes of history that trimming could free.
    trimmable: std.atomic.Value(u64) = .init(0),
    /// The session has ended and the store has all of it, so it can leave
    /// memory and load again when needed; see registry.unloadIdle.
    in_store: std.atomic.Value(bool) = .init(false),
    /// Monotonic nanoseconds of the latest `release`.
    released_ns: std.atomic.Value(i64) = .init(0),
    /// Counts the references taken, so unloading sees one taken and
    /// dropped while it read the store.
    uses: std.atomic.Value(u64) = .init(0),
    gpa: std.mem.Allocator,
    terminal: vt.Terminal,
    stream: ptyio.Stream,
    /// What changed on the screen, and when; see track.zig.
    track: track.Tracker,
    pty: pty_mod.Pair,
    proc: spawn.Proc,
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
    wake_pipe: [2]ptyio.WakeFd = .{ -1, -1 },
    /// Requests currently using this session; `remove` waits for them.
    refs: std.atomic.Value(u32) = .{ .raw = 0 },
    /// Attached clients, and the one allowed to write; guarded by
    /// terminal_mutex so they see output exactly as it is parsed.
    viewers: std.ArrayListUnmanaged(*attach.Viewer) = .empty,
    writer: ?*attach.Viewer = null,
    /// Set while the current input write has been blocked for a while by
    /// a child that is not reading; other writers then fail at once.
    write_stalled: std.atomic.Value(bool) = .{ .raw = false },
    /// Guards the recording: the reader thread writes cast output, the
    /// evaluator trace frames and stops, and requests start and stop it.
    /// Its holders may take terminal_mutex, never the reverse.
    record_mutex: std.Io.Mutex = .init,
    /// Active recording, if any.
    recording: ?record.Recording = null,
    /// The recording `run --record` made, which an ended session reports;
    /// its path is owned.
    run_recording: ?status_mod.Recording = null,
    /// Cheap check for the reader thread's fast path; mirrors
    /// `recording != null` but is atomic.
    recording_active: std.atomic.Value(bool) = .{ .raw = false },
    /// The active recording is a trace, whose frames the evaluator writes.
    recording_trace: std.atomic.Value(bool) = .{ .raw = false },
    recording_failed: std.atomic.Value(bool) = .{ .raw = false },
    /// The latest recording that stopped; guarded by record_mutex.
    last_stopped: ?record.Stopped = null,
    /// Counts recordings under record_mutex, naming those in the store.
    record_generation: u64 = 0,
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
    /// The command line, for `list`.
    argv: [][]u8 = &.{},
    /// Unix time in milliseconds; ended is 0 until the program has ended.
    started_ms: i64 = 0,
    ended_ms: std.atomic.Value(i64) = .{ .raw = 0 },
    /// The daemon-wide seq taken when the session ended; 0 until then.
    end_seq: std.atomic.Value(u64) = .{ .raw = 0 },
    /// The seq of the latest resize's reflow; 0 before any resize.
    resize_seq: std.atomic.Value(u64) = .{ .raw = 0 },
    /// The output counters are known: false for a session restored from
    /// stored metadata that holds none.
    counted: bool = true,
    /// Answers the session's waits; see evaluator.zig.
    eval: evaluator.Evaluator = .{},
    /// The foreground program and the input modes; see sample.zig.
    sampler: sample.Sampler = .{},
    /// The input batch that runs, if any; see batch.zig.
    batch: batch_mod.State = .{},
    /// The size before a writer first resized the session, which it gets
    /// back when the writer detaches; guarded by terminal_mutex.
    size_before_writer: ?[2]u16 = null,
    /// BELs and desktop notifications (OSC 9, OSC 777) the program sent,
    /// and the latest notification (owned, guarded by terminal_mutex).
    bell_count: std.atomic.Value(u64) = .init(0),
    notification_count: std.atomic.Value(u64) = .init(0),
    notification: ?status_mod.Notification = null,
    /// What a client last showed; guarded by seen_mutex. ack_mutex
    /// serializes acks, which also write it to the store.
    seen: status_mod.Seen = .{},
    seen_mutex: std.Io.Mutex = .init,
    ack_mutex: std.Io.Mutex = .init,
    /// `stop` signalled the program.
    stopped: std.atomic.Value(bool) = .init(false),
    /// The latest alert hits; guarded by terminal_mutex. The alerts are
    /// the tracker's.
    hits: alert.Log,
    /// Serializes changes of the alerts, which also write them to the
    /// store; taken before terminal_mutex.
    alert_mutex: std.Io.Mutex = .init,

    /// Start a session. It is returned with a reference taken: release it
    /// with `release`.
    pub fn start(gpa: std.mem.Allocator, opts: Options) !*Session {
        if (opts.argv.len == 0) return error.EmptyArgv;
        const io = io_mod.io();
        spawn.spawn_mutex.lockUncancelable(io);
        defer spawn.spawn_mutex.unlock(io);
        if (stopping.load(.acquire)) return error.Stopping;

        // Reserved up front so registering after the threads start cannot
        // fail (spawn_mutex serializes every start).
        try registry.reserveRegistrySlot();
        const floor = limits.sessionFloor(opts.cols, opts.rows);
        try budget.reserve(floor);
        // Only the reader, started last, charges more.
        errdefer budget.release(floor, floor);

        // Names are unique among this daemon's sessions. An ended session
        // gives its name up to the new one once that has started, so a
        // failed start leaves it alone.
        const namesakes = try registry.endedNamesakes(gpa, opts.name);
        defer gpa.free(namesakes);

        const name_dup = try gpa.dupe(u8, opts.name);
        errdefer gpa.free(name_dup);

        const start_seq = track.counter.next();
        var record_name: ?[]const u8 = null;
        if (opts.record) |rec| record_name = rec.path orelse switch (rec.format) {
            .cast => "output.cast",
            .trace => "output.trace",
        };
        const created = store.create(gpa, .{
            .name = opts.name,
            .argv = opts.argv,
            .cwd = opts.cwd orelse "",
            .socket = registry.endpoint,
            .cols = opts.cols,
            .rows = opts.rows,
            .scrollback = opts.scrollback,
            .started_ms = store.nowMillis(),
            .recording = record_name,
            .recording_format = if (opts.record) |rec| rec.format else .cast,
            .start_seq = start_seq,
            .seq = start_seq,
            .alerts = opts.alerts,
        }) catch |err| return storeFailure(err);
        errdefer store.discard(created.id, created.running);

        var id_var_buf: [48]u8 = undefined;
        const id_var = std.fmt.bufPrint(&id_var_buf, "TUPPET_SESSION={d}", .{created.id}) catch unreachable;
        const socket_var = try std.mem.concat(gpa, u8, &.{ "TUPPET_SESSION_SOCKET=", registry.endpoint });
        defer gpa.free(socket_var);
        const child_env = try spawn.buildChildEnv(gpa, opts.env, &.{ id_var, socket_var });
        defer gpa.free(child_env);

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
            .scrollback = opts.scrollback,
            .gpa = gpa,
            .terminal = undefined,
            .stream = undefined,
            .track = undefined,
            .pty = try pty_mod.open(opts.cols, opts.rows),
            .proc = undefined,
            .process_id = 0,
            .state = .{ .raw = .running },
            .exit_code = .{ .raw = -1 },
            .last_output = .{ .raw = io_mod.nowNanos() },
            .reader = null,
            .hits = .{ .gpa = gpa },
        };
        errdefer pty_mod.close(&s.pty);
        if (builtin.os.tag != .windows) {
            if (std.c.pipe(&s.wake_pipe) != 0) return error.PipeFailed;
            for (s.wake_pipe) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        }
        errdefer ptyio.closeWakePipe(&s.wake_pipe);

        s.terminal = try newTerminal(gpa, opts.cols, opts.rows, opts.scrollback);
        errdefer s.terminal.deinit(gpa);
        s.floor = floor;
        s.charged = floor;

        s.terminal.colors.foreground.set(default_fg);
        s.terminal.colors.background.set(default_bg);
        // ConPTY keeps its own screen without scrollback; rows pulled back
        // from history on a resize would put its next output out of place.
        if (builtin.os.tag == .windows) s.terminal.flags.resize_pull_scrollback = false;
        s.track = try .init(gpa, &track.counter, &s.terminal, start_seq, start_seq, io_mod.nowNanos());
        errdefer s.track.deinit(&s.terminal);
        for (opts.alerts) |rule| _ = try s.track.addAlert(&s.terminal, rule);

        var handler = s.terminal.vtHandler();
        handler.effects = .readonly;
        handler.effects.write_pty = &ptyio.writePtyEffect;
        handler.effects.device_attributes = &ptyio.deviceAttributesEffect;
        handler.effects.xtversion = &ptyio.xtversionEffect;
        handler.effects.size = &ptyio.sizeEffect;
        handler.effects.bell = &ptyio.bellEffect;
        handler.effects.desktop_notification = &ptyio.notificationEffect;
        // We emulate ghostty's vt, so its terminfo entry is the truthful
        // answer for XTGETTCAP "TN" queries.
        handler.terminfo_name = "ghostty";
        s.stream = ptyio.Stream.init(.{
            .handler = .{ .inner = handler },
            .allocator = gpa,
            // Keeps a chunk's unfinished escape sequence for attach redraws.
            .continuation_max_bytes = 64 * 1024,
        });
        errdefer s.stream.deinit();

        // Recording before the program starts captures its first byte.
        errdefer if (s.last_stopped) |st| gpa.free(st.path);
        errdefer stopRecording(s, .ended);
        if (opts.record) |rec| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = rec.path orelse try store.sessionFile(&path_buf, s.id, record_name.?);
            try startRecording(s, .{ .path = path, .format = rec.format });
            s.run_recording = .{ .path = try gpa.dupe(u8, path), .format = rec.format, .input = rec.format == .trace, .started_ms = s.started_ms };
        }
        errdefer if (s.run_recording) |rec| gpa.free(rec.path);

        // Before the program, so a failure leaves nothing running. The
        // reader stops it once the session has ended.
        try evaluator.start(s);
        errdefer evaluator.finish(s);

        switch (builtin.os.tag) {
            .windows => {
                s.proc = try spawn.spawnWindowsChild(gpa, opts, child_env, &s.pty);
                s.process_id = spawn.procPid(s.proc);
                s.waiter = std.Thread.spawn(.{}, spawn.waiterLoop, .{s}) catch |err| {
                    _ = spawn.stopAndReapProc(&s.proc, io);
                    return err;
                };
            },
            else => {
                // The child is forked on the waiter thread, which lives
                // exactly as long as the child: Linux delivers the
                // parent-death signal when the forking *thread* exits.
                var request: spawn.SpawnRequest = .{ .gpa = gpa, .opts = opts, .child_env = child_env };
                s.waiter = try std.Thread.spawn(.{}, spawn.spawnAndWait, .{ s, &request });
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
        s.reader = std.Thread.spawn(.{}, ptyio.readerLoop, .{s}) catch |err| {
            s.running_lock = null;
            // The waiter reaps the child once it is gone; the errdefers
            // above release the rest.
            s.stop_mutex.lockUncancelable(io);
            spawn.signalGroup(s, .kill);
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
        for (namesakes) |id| remove(id) catch |err| switch (err) {
            // Deleted meanwhile, e.g. by another daemon's expiry.
            error.NoSession => {},
            error.StillRunning => std.log.err("session {d}: cannot give its name to session {d}: still running", .{ id, s.id }),
        };
        s.refs.store(1, .release);
        registry.register(s);
        events.publish(s.id, .started, .{});
        return s;
    }

    /// A failed store.create as an error that says the store failed.
    fn storeFailure(err: anyerror) anyerror {
        return switch (err) {
            error.OutOfMemory, error.IdsExhausted => err,
            error.AccessDenied, error.PermissionDenied, error.StoreOwnedByAnotherUser => error.StoreAccessDenied,
            error.ReadOnlyFileSystem => error.StoreReadOnly,
            error.NoSpaceLeft, error.DiskQuota => error.StoreFull,
            else => {
                std.log.err("cannot create a session in the session store: {s}", .{store.errorText(err)});
                return error.StoreFailed;
            },
        };
    }

    /// A session that ended under an earlier daemon, rebuilt from its
    /// metadata, checked with store.checkMeta, and its stored screen. It
    /// stays exited: it has no program, pty, or threads. `charge` of the
    /// memory budget was reserved for it, which it holds from now on.
    pub fn restore(gpa: std.mem.Allocator, meta: store.Meta, screen: std.Io.File, floor: u64) !*Session {
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
            .end_seq = .{ .raw = meta.end_seq orelse 0 },
            .resize_seq = .{ .raw = meta.resize_seq orelse 0 },
            .name = name,
            .cols = meta.cols,
            .rows = meta.rows,
            .scrollback = meta.scrollback,
            .in_store = .init(true),
            .gpa = gpa,
            .terminal = undefined,
            .stream = undefined,
            .track = undefined,
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
            .bell_count = .init(meta.bell_count),
            .notification_count = .init(meta.notification_count),
            .seen = meta.seen,
            .stopped = .init(meta.stopped),
            .hits = .{ .gpa = gpa },
        };
        s.terminal = try newTerminal(gpa, meta.cols, meta.rows, meta.scrollback);
        errdefer s.terminal.deinit(gpa);
        // History comes back only as far as the budget has room for it.
        const room = budget.room();
        const pages = &s.terminal.screens.get(.primary).?.pages;
        if (room < meta.scrollback) {
            s.history_cap = pages.limits.bytes.min + room;
            s.terminal.setScrollbackMaxBytes(s.history_cap);
        }
        s.terminal.colors.foreground.set(default_fg);
        s.terminal.colors.background.set(default_bg);
        var handler = s.terminal.vtHandler();
        handler.effects = .readonly;
        s.stream = ptyio.Stream.init(.{ .handler = .{ .inner = handler }, .allocator = gpa });
        errdefer s.stream.deinit();
        // In pieces: the history limit drops what does not fit, so memory
        // stays bounded whatever the file's size.
        var buf: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = try screen.readPositional(io_mod.io(), &.{&buf}, offset);
            if (n == 0) break;
            s.stream.nextSlice(buf[0..n]);
            offset += n;
        }
        s.stream.handler.full_clears = meta.full_clears orelse 0;
        // It all fit: Ghostty drops a page only for one that would not.
        if (s.history_cap) |cap| if (pages.page_size + limits.page_bytes <= cap) {
            s.terminal.setScrollbackMaxBytes(meta.scrollback);
            s.history_cap = null;
        };
        try s.hits.restore(meta.hits);
        errdefer s.hits.deinit();
        s.counted = meta.out_bytes != null and meta.draws != null and meta.full_clears != null;
        // The stored screen brings the working directory back, not the title.
        if (meta.title) |title| try s.terminal.setTitle(title);
        const now = io_mod.nowNanos();
        s.track = try .init(gpa, &track.counter, &s.terminal, meta.start_seq, meta.seq, now);
        errdefer s.track.deinit(&s.terminal);
        for (meta.alerts) |rule| {
            // The store may hold what this release would refuse.
            if (alert.ruleError(rule) != null) continue;
            _ = s.track.addAlert(&s.terminal, rule) catch |err| switch (err) {
                error.Exists, error.Limit => continue,
                else => |e| return e,
            };
        }
        // Idle times go on from what the store kept.
        const ended = meta.ended_ms orelse store.nowMillis();
        const monotonic = struct {
            fn at(wall_ms: ?i64, fallback: i64, now_ns: i64) i64 {
                return now_ns - @max(0, store.nowMillis() - (wall_ms orelse fallback)) * std.time.ns_per_ms;
            }
        }.at;
        s.track.last_text_change_ns.store(monotonic(meta.last_text_ms, ended, now), .release);
        s.track.last_change_ns.store(monotonic(meta.last_change_ms, ended, now), .release);
        s.last_output.store(monotonic(meta.last_output_ms, ended, now), .release);
        s.track.input_seq.store(meta.input_seq orelse 0, .release);
        s.track.read_bytes.store(meta.out_bytes orelse 0, .release);
        s.track.draws.store(meta.draws orelse 0, .release);
        s.track.history_dropped = meta.history_dropped;
        s.run_recording = try status_mod.runRecording(gpa, meta);
        errdefer if (s.run_recording) |rec| gpa.free(rec.path);
        if (meta.recording_report.stopped) |st| s.last_stopped = .{ .path = try gpa.dupe(u8, st.path), .reason = st.reason, .reported = st.reported };
        errdefer if (s.last_stopped) |st| gpa.free(st.path);
        s.recording_failed.store(meta.recording_report.failed, .release);
        if (meta.notification) |n| s.notification = try status_mod.dupeNotification(gpa, n);
        // Last: the caller gives back the floor if anything above fails.
        s.floor = floor;
        s.charged = floor;
        _ = s.chargeLocked();
        return s;
    }

    /// Save the session's results to the store and release its running
    /// lock. Runs once, after the program has ended and its output is in.
    pub fn persist(self: *Session) void {
        const running = self.running_lock orelse return;
        self.running_lock = null;
        var complete = true;
        const screen = self.storedScreen() catch |err| blk: {
            std.log.err("session {d}: cannot render its final screen: {}", .{ self.id, err });
            complete = false;
            break :blk &[_]u8{};
        };
        defer self.gpa.free(screen);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const io = io_mod.io();
        // Held until the report is saved: a stop request that reports the
        // recording meanwhile saves after this, not before.
        self.record_mutex.lockUncancelable(io);
        defer self.record_mutex.unlock(io);
        var report = record.reportLocked(self);
        if (report.stopped) |*st| {
            if (arena.allocator().dupe(u8, st.path)) |path| st.path = path else |_| {
                report.stopped = null;
                complete = false;
            }
        }
        self.terminal_mutex.lockUncancelable(io);
        const cols = self.cols;
        const rows = self.rows;
        const title = status_mod.titleOf(arena.allocator(), self.terminal.getTitle()) catch null;
        const cwd = status_mod.cwdOf(arena.allocator(), self.terminal.getPwd() orelse "") catch null;
        const notification = if (self.notification) |n| status_mod.dupeNotification(arena.allocator(), n) catch null else null;
        const full_clears = self.stream.handler.full_clears;
        const history_dropped = self.track.history_dropped;
        var hits: std.ArrayList(alert.Hit) = .empty;
        var copied = true;
        var it = self.hits.each();
        while (it.next()) |h| hits.append(arena.allocator(), h.*) catch {
            copied = false;
            break;
        };
        self.terminal_mutex.unlock(io);
        const now = io_mod.nowNanos();
        const now_ms = store.nowMillis();
        const wall = struct {
            fn at(ns: i64, now_ns: i64, wall_now: i64) i64 {
                return wall_now - @divTrunc(@max(0, now_ns - ns), std.time.ns_per_ms);
            }
        }.at;
        const input_seq = self.track.input_seq.load(.acquire);
        const resize_seq = self.resize_seq.load(.acquire);
        const saved = store.finish(self.gpa, self.id, .{
            .pid = self.process_id,
            .exit_code = self.exit_code.load(.acquire),
            .cols = cols,
            .rows = rows,
            .ended_ms = self.ended_ms.load(.acquire),
            .seq = self.track.seq.load(.acquire),
            .end_seq = self.end_seq.load(.acquire),
            .input_seq = if (input_seq != 0) input_seq else null,
            .resize_seq = if (resize_seq != 0) resize_seq else null,
            .last_text_ms = wall(self.track.last_text_change_ns.load(.acquire), now, now_ms),
            .last_change_ms = wall(self.track.last_change_ns.load(.acquire), now, now_ms),
            .last_output_ms = wall(self.last_output.load(.acquire), now, now_ms),
            .title = title,
            .reported_cwd = cwd,
            .stopped = self.stopped.load(.acquire),
            .bell_count = self.bell_count.load(.acquire),
            .notification_count = self.notification_count.load(.acquire),
            .notification = notification,
            .out_bytes = self.track.read_bytes.load(.acquire),
            .draws = self.track.draws.load(.acquire),
            .full_clears = full_clears,
            .hits = if (copied) hits.items else &.{},
            .history_dropped = history_dropped,
            .recording_report = report,
        }, screen, running);
        self.in_store.store(saved and complete and copied, .release);
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
        // In origin mode a cursor position counts from the region.
        if (t.modes.get(.origin)) cursor.cursor_origin = .{ .x = t.scrolling_region.left, .y = t.scrolling_region.top };
        try cursor.format(&w.writer);

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
    pub fn deinit(self: *Session) void {
        const gpa = self.gpa;
        if (self.reader) |reader| reader.join();
        evaluator.finish(self);
        evaluator.close(self);
        stopRecording(self, .ended);
        if (self.last_stopped) |st| gpa.free(st.path);
        self.pending_replies.deinit(gpa);
        self.viewers.deinit(gpa);
        self.stream.deinit();
        self.track.deinit(&self.terminal);
        self.hits.deinit();
        self.terminal.deinit(gpa);
        pty_mod.close(&self.pty);
        ptyio.closeWakePipe(&self.wake_pipe);
        if (self.running_lock) |lock| lock.close(io_mod.io());
        if (self.run_recording) |rec| gpa.free(rec.path);
        if (self.notification) |n| status_mod.freeNotification(gpa, n);
        self.sampler.deinit(gpa);
        freeArgv(gpa, self.argv);
        gpa.free(self.name);
        budget.release(self.floor, self.charged);
        gpa.destroy(self);
    }
    /// Attach input: written as it is, after any batch that runs.
    pub fn send(self: *Session, data: []const u8) !void {
        if (self.state.load(.acquire) == .exited) return error.SessionExited;
        try ptyio.writeInput(self, data, .{ .send = data });
    }

    /// Who resizes: a request sets the size for good, a writer until it
    /// detaches, when the size it found comes back; `undo` takes back a
    /// writer's resize whose attach failed.
    pub const ResizeBy = enum { request, writer, restore, undo };

    /// Resize the PTY and the emulated terminal. The kernel pty is
    /// resized first so SIGWINCH and TIOCGWINSZ agree with the vt state.
    pub fn resize(self: *Session, cols: u16, rows: u16, by: ResizeBy) !void {
        _ = try self.resizeSeq(cols, rows, by, false);
    }

    /// `resize`, returning the seq of the reflow: what the program draws
    /// after the resize comes later. Null when the size stays: the program
    /// gets no SIGWINCH. With `unattended`, it fails with error.Attended
    /// while a writer is attached, checked under the same lock.
    pub fn resizeSeq(self: *Session, cols: u16, rows: u16, by: ResizeBy, unattended: bool) !?u64 {
        if (self.state.load(.acquire) == .exited) return error.SessionExited;
        const io = io_mod.io();
        // What the program wrote for the old size comes before the reflow.
        ptyio.settleOutput(self);
        var seq: ?u64 = null;
        {
            // Held across the reflow, so a trace shows the screen before
            // it, then the resize, then what the reflow made of it.
            self.record_mutex.lockUncancelable(io);
            defer self.record_mutex.unlock(io);
            record.beforeResizeLocked(self);
            {
                self.terminal_mutex.lockUncancelable(io);
                defer self.terminal_mutex.unlock(io);
                if (unattended and self.writer != null) return error.Attended;
                seq = try self.resizeLocked(cols, rows, by);
                if (seq == null) return null;
            }
            record.recordInputLocked(self, .{ .resize = .{ .cols = cols, .rows = rows } });
        }
        self.afterResize();
        registry.trimHistory();
        return seq;
    }

    /// The part of `resize` under record_mutex and terminal_mutex, both
    /// held; the seq of the reflow, or null when it leaves the size as it
    /// is (the same size, or a restore while a writer is attached).
    fn resizeLocked(self: *Session, cols: u16, rows: u16, by: ResizeBy) !?u64 {
        switch (by) {
            .request => self.size_before_writer = null,
            .writer => if (self.size_before_writer == null) {
                self.size_before_writer = .{ self.cols, self.rows };
            },
            // A writer attached meanwhile: its size wins.
            .restore => if (self.writer != null) return null,
            .undo => {},
        }
        if (cols == self.terminal.cols and rows == self.terminal.rows) return null;
        if (!limits.validSize(cols, rows)) return error.SizeOutOfRange;
        const old_cols = self.terminal.cols;
        const old_rows = self.terminal.rows;
        const old_floor = self.floor;
        const floor = limits.sessionFloor(cols, rows);
        // Back to a size from before a writer: that was reserved before.
        if (by == .restore or by == .undo) budget.force(old_floor, floor) else try budget.exchange(old_floor, floor);
        self.floor = floor;
        // A reflow allocates, failed or not.
        defer _ = self.chargeLocked();
        errdefer {
            budget.force(floor, old_floor);
            self.floor = old_floor;
        }
        try ptyio.ptyResize(self, cols, rows);
        const now = io_mod.nowNanos();
        var reflow = self.track.beginReflow(&self.terminal, now);
        defer reflow.deinit(self.gpa);
        // Mode 2048 (in-band size reports) needs the handler, which also
        // resizes the terminal grid and reflows the screen.
        self.stream.handler.inner.resize(.{
            .cols = cols,
            .rows = rows,
            .cell_size_px = .{ .width = 1, .height = 1 },
        }) catch |err| {
            // A failed resize may have changed some of the screen.
            _ = self.track.endReflow(&self.terminal, &reflow, now, false);
            // The program must not see a size the screen does not have.
            ptyio.ptyResize(self, old_cols, old_rows) catch {};
            return err;
        };
        const seq = self.track.endReflow(&self.terminal, &reflow, now, true).?;
        self.resize_seq.store(seq, .release);
        self.cols = cols;
        self.rows = rows;
        var frame_buf: [96]u8 = undefined;
        self.broadcastLocked(attach.resizeFrame(&frame_buf, cols, rows, seq));
        return seq;
    }

    /// Charge the budget for what the screens and history use now; true
    /// when that grew. terminal_mutex must be held.
    pub fn chargeLocked(self: *Session) bool {
        var bytes: u64 = 0;
        for ([_]vt.ScreenSet.Key{ .primary, .alternate }) |key| {
            const screen = self.terminal.screens.get(key) orelse continue;
            bytes += screen.pages.page_size;
        }
        const pages = &self.terminal.screens.get(.primary).?.pages;
        self.trimmable.store(pages.page_size -| pages.limits.bytes.min, .release);
        const charge = @max(self.floor, bytes);
        if (charge == self.charged) return false;
        budget.account(self.charged, charge);
        defer self.charged = charge;
        return charge > self.charged;
    }

    /// Keep no more than `level` bytes of history for the memory budget,
    /// dropping the oldest lines beyond it, and keep it from growing back;
    /// see registry.trimHistory. False when it keeps no more already.
    pub fn trimHistory(self: *Session, level: u64) bool {
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        const pages = &self.terminal.screens.get(.primary).?.pages;
        if (pages.page_size -| pages.limits.bytes.min <= level) return false;
        const rows = pages.total_rows;
        self.history_cap = pages.limits.bytes.min + level;
        self.terminal.setScrollbackMaxBytes(self.history_cap);
        if (pages.total_rows < rows) self.track.history_dropped = true;
        _ = self.chargeLocked();
        return true;
    }

    /// Let a trimmed session's history grow to its own limit again.
    pub fn liftHistoryCap(self: *Session) void {
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        if (self.history_cap == null) return;
        self.terminal.setScrollbackMaxBytes(self.scrollback);
        self.history_cap = null;
    }

    /// After a resize, with no lock held.
    fn afterResize(self: *Session) void {
        self.track.notify();
        // The in-band size report (mode 2048) was queued by the resize;
        // the child may be waiting for it without producing output.
        ptyio.ptyWrite(self, "") catch {};
    }

    /// Terminates the child's process group the way closing a terminal
    /// does: SIGHUP (shells pass it on to their jobs) and SIGTERM, then
    /// SIGKILL for whatever is left after a grace period. Returns once
    /// the session has exited. Processes that left the session (setsid,
    /// daemons) are not tracked.
    pub fn stop(self: *Session) !void {
        const io = io_mod.io();
        if (self.state.load(.acquire) == .exited) return self.waitSettled(io_mod.nowNanos() + save_wait_ns);
        self.stop_mutex.lockUncancelable(io);
        if (!self.process_reaped.load(.acquire)) {
            self.stopped.store(true, .release);
            spawn.signalGroup(self, .terminate);
        }
        self.stop_mutex.unlock(io);

        const grace_end = io_mod.nowNanos() + stop_grace_ns;
        while (io_mod.nowNanos() < grace_end and spawn.groupAlive(self)) {
            std.Io.sleep(io, .fromMilliseconds(10), .boot) catch {};
        }
        self.stop_mutex.lockUncancelable(io);
        if (spawn.groupAlive(self)) spawn.signalGroup(self, .kill);
        self.stop_mutex.unlock(io);

        const exit_deadline = io_mod.nowNanos() + stop_exit_wait_ns;
        while (self.state.load(.acquire) != .exited) {
            if (io_mod.nowNanos() >= exit_deadline) return error.StopTimeout;
            std.Io.sleep(io, .fromMilliseconds(5), .boot) catch {};
        }
        return self.waitSettled(io_mod.nowNanos() + save_wait_ns);
    }

    /// Wait until the session has ended and its results are saved: a
    /// daemon told to shut down stops its sessions and must not exit
    /// before then.
    pub fn waitSettled(self: *Session, deadline: i64) !void {
        while (!self.settled.load(.acquire)) {
            if (io_mod.nowNanos() >= deadline) return error.SaveTimeout;
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

    pub fn formatLocked(self: *Session, gpa: std.mem.Allocator, fmt: vt.formatter.Format, region: Region, unwrap: bool) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        var w = std.Io.Writer.Allocating.fromArrayList(gpa, &list);
        errdefer w.deinit();
        var opts: vt.formatter.Options = .{ .emit = fmt, .unwrap = unwrap };
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
    /// only with `force`. A writer's `size` is applied first, so the
    /// redraw already has the size the client shows it at.
    pub fn attachViewer(self: *Session, v: *attach.Viewer, write: bool, force: bool, size: ?[2]u16) !void {
        const io = io_mod.io();
        // After the unlock: the evaluator notices the new client.
        defer self.track.notify();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const recording = try status_mod.recordingOf(arena.allocator(), self);
        sample.refresh(self, true);
        const want = if (write) size else null;
        // The lock order of `resize`: record_mutex, then terminal_mutex.
        if (want != null) {
            self.record_mutex.lockUncancelable(io);
            record.beforeResizeLocked(self);
        }
        var record_locked = want != null;
        defer if (record_locked) self.record_mutex.unlock(io);
        const resized = blk: {
            self.terminal_mutex.lockUncancelable(io);
            defer self.terminal_mutex.unlock(io);
            break :blk try self.attachLocked(arena.allocator(), v, write, force, want, recording);
        };
        if (record_locked) {
            if (resized) record.recordInputLocked(self, .{ .resize = .{ .cols = want.?[0], .rows = want.?[1] } });
            self.record_mutex.unlock(io);
            record_locked = false;
        }
        if (resized) self.afterResize();
    }

    /// `attachViewer` with terminal_mutex held, and record_mutex with
    /// `size`; whether it resized the session.
    fn attachLocked(self: *Session, a: std.mem.Allocator, v: *attach.Viewer, write: bool, force: bool, size: ?[2]u16, recording: ?status_mod.Recording) !bool {
        const gpa = self.gpa;
        if (write and self.writer != null and !force) return error.WriterAttached;
        try self.viewers.ensureUnusedCapacity(gpa, 1);
        const ended = self.state.load(.acquire) == .exited;
        var resized = false;
        const old_size = [2]u16{ self.cols, self.rows };
        const old_saved = self.size_before_writer;
        if (size) |sz| if (!ended and (sz[0] != self.cols or sz[1] != self.rows)) {
            // As with a resize frame, a failed resize does not end the attach.
            resized = (self.resizeLocked(sz[0], sz[1], .writer) catch |err| blk: {
                std.log.err("session {d}: cannot resize to the writer's {d}x{d}: {}", .{ self.id, sz[0], sz[1], err });
                break :blk null;
            }) != null;
        };
        // An attach that fails after all leaves the size as it found it.
        errdefer if (resized) {
            _ = self.resizeLocked(old_size[0], old_size[1], .undo) catch {};
            self.size_before_writer = old_saved;
        };
        const vt_bytes = try self.redrawLocked(gpa);
        defer gpa.free(vt_bytes);
        const screen = try attach.screenFrame(gpa, vt_bytes);
        defer gpa.free(screen);
        if (!attach.roomForScreen(screen.len)) return error.ViewersBehind;
        const end = if (ended) try attach.endFramesLocked(a, self) else "";
        const previous = self.writer;
        if (write) self.writer = v;
        self.viewers.appendAssumeCapacity(v);
        errdefer {
            _ = self.viewers.pop();
            self.writer = previous;
        }
        const st = try status_mod.ofLocked(a, self, recording);
        const reply = try protocol.stringifyAlloc(a, protocol.StatusResp{ .status = st });
        if (write) if (previous) |old| {
            old.can_write.store(false, .release);
            // A fresh screen repairs what its notice of the takeover drew.
            old.push("{\"writer\":\"taken\"}\n");
            old.push(screen);
        };
        v.pushInitial(reply);
        v.pushInitial("\n");
        v.pushInitial(screen);
        if (ended) v.finish(end);
        return resized;
    }

    /// Attached clients that only watch, previews left out;
    /// terminal_mutex must be held.
    pub fn viewerCountLocked(self: *const Session) u32 {
        var n: u32 = 0;
        for (self.viewers.items) |v| n += @intFromBool(v != self.writer and !v.passive);
        return n;
    }

    /// Attached previews; terminal_mutex must be held.
    pub fn previewCountLocked(self: *const Session) u32 {
        var n: u32 = 0;
        for (self.viewers.items) |v| n += @intFromBool(v.passive);
        return n;
    }

    /// Unsubscribe an attach client. The writer leaving gives the session
    /// back the size it had before a writer resized it, unless a request
    /// set the size since.
    pub fn detachViewer(self: *Session, v: *attach.Viewer) void {
        const io = io_mod.io();
        const before = blk: {
            self.terminal_mutex.lockUncancelable(io);
            defer self.terminal_mutex.unlock(io);
            for (self.viewers.items, 0..) |item, i| {
                if (item == v) {
                    _ = self.viewers.swapRemove(i);
                    break;
                }
            }
            if (self.writer != v) break :blk null;
            self.writer = null;
            const size = self.size_before_writer;
            self.size_before_writer = null;
            break :blk size;
        };
        self.track.notify();
        const size = before orelse return;
        self.resize(size[0], size[1], .restore) catch |err| switch (err) {
            error.SessionExited => {},
            else => std.log.err("session {d}: cannot restore its size {d}x{d}: {}", .{ self.id, size[0], size[1], err }),
        };
    }

    /// Give the session another name; an empty one takes it away. An
    /// ended session that has the name gives it up, as for a start;
    /// error.NameTaken when a running one has it. spawn_mutex must be held,
    /// taken before the reference on the session: holders remove sessions
    /// and wait for their references.
    pub fn rename(self: *Session, name: []const u8) !void {
        const io = io_mod.io();
        if (std.mem.eql(u8, self.name, name)) return;
        const namesakes = try registry.endedNamesakes(self.gpa, name);
        defer self.gpa.free(namesakes);
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try store.setName(self.gpa, self.id, name);
        for (namesakes) |id| remove(id) catch |err| switch (err) {
            error.NoSession => {},
            error.StillRunning => std.log.err("session {d}: cannot give its name to session {d}: still running", .{ id, self.id }),
        };
        self.terminal_mutex.lockUncancelable(io);
        const old = registry.swapName(self, owned);
        self.terminal_mutex.unlock(io);
        self.gpa.free(old);
        events.publish(self.id, .renamed, .{});
    }

    /// What a client last showed of the session.
    pub fn seenNow(self: *Session) status_mod.Seen {
        const io = io_mod.io();
        self.seen_mutex.lockUncancelable(io);
        defer self.seen_mutex.unlock(io);
        return self.seen;
    }

    /// Record that a client showed `shown` of the session (without it,
    /// everything there is now); see status.mergeSeen. Returns whether
    /// seen moved.
    pub fn ack(self: *Session, shown: ?status_mod.Shown) bool {
        const io = io_mod.io();
        self.ack_mutex.lockUncancelable(io);
        defer self.ack_mutex.unlock(io);
        self.lockTerminal();
        const hit_seq = self.hits.latest();
        self.unlockTerminal();
        const current: status_mod.Seen = .{
            .seq = self.track.seq.load(.acquire),
            .bell_count = self.bell_count.load(.acquire),
            .notification_count = self.notification_count.load(.acquire),
            .hit_seq = hit_seq,
            .ended = self.state.load(.acquire) == .exited,
        };
        const new = blk: {
            self.seen_mutex.lockUncancelable(io);
            defer self.seen_mutex.unlock(io);
            const old = self.seen;
            self.seen = status_mod.mergeSeen(old, shown, current, store.nowMillis());
            break :blk .{ self.seen, status_mod.seenMoved(old, self.seen) };
        };
        store.setSeen(self.gpa, self.id, new[0]) catch |err| std.log.err("session {d}: cannot save what was seen: {}", .{ self.id, err });
        return new[1];
    }

    /// Count the end of a session that `stop` ended as seen: whoever
    /// stopped it knows.
    pub fn markStopSeen(self: *Session) void {
        const io = io_mod.io();
        const seen = blk: {
            self.seen_mutex.lockUncancelable(io);
            defer self.seen_mutex.unlock(io);
            if (self.seen.ended) return;
            self.seen.ended = true;
            break :blk self.seen;
        };
        store.setSeen(self.gpa, self.id, seen) catch |err| std.log.err("session {d}: cannot save what was seen: {}", .{ self.id, err });
    }

    /// Send one attach client a full redraw, after a notice it showed
    /// over the screen.
    pub fn redrawTo(self: *Session, v: *attach.Viewer) void {
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        const vt_bytes = self.redrawLocked(self.gpa) catch return;
        defer self.gpa.free(vt_bytes);
        const screen = attach.screenFrame(self.gpa, vt_bytes) catch return;
        defer self.gpa.free(screen);
        v.push(screen);
    }

    /// End every attach stream with `line`.
    pub fn endViewers(self: *Session, line: []const u8) void {
        const io = io_mod.io();
        self.terminal_mutex.lockUncancelable(io);
        defer self.terminal_mutex.unlock(io);
        for (self.viewers.items) |v| v.finish(line);
    }

    /// terminal_mutex must be held.
    pub fn broadcastLocked(self: *Session, line: []const u8) void {
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

    pub fn lockTerminal(self: *Session) void {
        self.terminal_mutex.lockUncancelable(io_mod.io());
    }

    pub fn unlockTerminal(self: *Session) void {
        self.terminal_mutex.unlock(io_mod.io());
    }
};

/// A session's terminal. Every one is made here, so no size outside the
/// limits reaches Ghostty, which allocates the whole grid at once.
fn newTerminal(gpa: std.mem.Allocator, cols: u16, rows: u16, scrollback: u64) !vt.Terminal {
    if (!limits.validSize(cols, rows) or scrollback > limits.max_scrollback) return error.SizeOutOfRange;
    // No Kitty graphics: nothing shows images, so storing them only costs
    // memory, and programs asking for the protocol hear nothing back.
    return vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = scrollback,
        .kitty_image_storage_limit = 0,
    });
}

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

/// Rows without text or background color at the bottom of the screen,
/// the rows Ghostty's formatter leaves out.
fn trailingBlankRows(t: *const vt.Terminal) usize {
    const pages = &t.screens.active.pages;
    var blank: usize = 0;
    var row: usize = t.rows;
    while (row > 0) {
        row -= 1;
        const pin = pages.pin(.{ .active = .{ .y = @intCast(row) } }) orelse break;
        for (pin.cells(.all)) |cell| switch (cell.content_tag) {
            .bg_color_palette, .bg_color_rgb => return blank,
            .codepoint, .codepoint_grapheme => if (cell.hasText()) return blank,
        };
        blank += 1;
    }
    return blank;
}
