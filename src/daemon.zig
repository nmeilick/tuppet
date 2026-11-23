//! The tuppet daemon: owns the unix socket and dispatches JSON-lines
//! requests to the session registry.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const store = @import("store.zig");
const session = @import("session.zig");
const render = @import("render.zig");
const fonts = @import("fonts.zig");
const attach = @import("attach.zig");
const names = @import("names.zig");
const track = @import("track.zig");
const registry = @import("registry.zig");
const spawn = @import("spawn.zig");
const status = @import("status.zig");
const units = @import("units.zig");
const view = @import("view.zig");
const cond = @import("cond.zig");
const evaluator = @import("evaluator.zig");
const hangup = @import("hangup.zig");
const sample = @import("sample.zig");
const batch = @import("batch.zig");
const events = @import("events.zig");
const alert = @import("alert.zig");
const limits = @import("limits.zig");
const budget = @import("budget.zig");
const over = @import("over.zig");
const member = @import("member.zig");
const marks = @import("marks.zig");
const vt = @import("vt");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else @import("win32_stub.zig");

const Status = status.Status;

const max_connections = 32;
/// How long a daemon without --socket waits, with no sessions and no
/// clients, before it exits; TUPPET_IDLE_EXIT overrides it, and 0 keeps the
/// daemon running.
const default_idle_exit_ms = 30 * std.time.ms_per_s;

fn idleExitMillis() u64 {
    const value = std.mem.span(std.c.getenv("TUPPET_IDLE_EXIT") orelse return default_idle_exit_ms);
    return units.parseDuration(value, .no_days) orelse {
        std.log.warn("ignoring TUPPET_IDLE_EXIT={s}: expected {s}", .{ value, units.durationHint(.no_days) });
        return default_idle_exit_ms;
    };
}

/// Ghostty logs every sequence it cannot use, so a program that writes
/// garbage would fill the log; its scopes get this many lines a minute,
/// and the count of those left out follows.
const terminal_log_per_min = 20;
var terminal_log_lock: std.atomic.Mutex = .unlocked;
var terminal_log_minute: i64 = 0;
var terminal_log_lines: u32 = 0;
var terminal_log_dropped: u64 = 0;

/// The process's std.log function: tuppet's own lines (and the
/// allocator's leak reports) as the default does, those of the terminal
/// emulator's scopes rate-limited.
pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (scope != .default and scope != .gpa) {
        const minute: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.Options.debug_io, .boot).raw.nanoseconds, std.time.ns_per_min));
        while (!terminal_log_lock.tryLock()) std.Thread.yield() catch {};
        var dropped: u64 = 0;
        if (minute != terminal_log_minute) {
            terminal_log_minute = minute;
            terminal_log_lines = 0;
            dropped = terminal_log_dropped;
            terminal_log_dropped = 0;
        }
        const keep = terminal_log_lines < terminal_log_per_min;
        if (keep) terminal_log_lines += 1 else terminal_log_dropped += 1;
        terminal_log_lock.unlock();
        if (dropped > 0) logFn(.warn, .default, "left out {d} lines of the terminal emulator's log", .{dropped});
        if (!keep) return;
    }
    if (builtin.os.tag == .windows) if (log_file) |file| return logTo(file, level, scope, format, args);
    std.log.defaultLog(level, scope, format, args);
}

/// Windows, supervised mode with --log: the log file, which takes every
/// line from then on. Std caches its stderr handle, so swapping the
/// standard handle would not move the lines there.
var log_file: ?win32.HANDLE = null;

/// One line in std.log's format, cut at 4 KiB.
fn logTo(file: win32.HANDLE, comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const prefix = comptime level.asText() ++ (if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ");
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(prefix ++ format ++ "\n", args) catch {
        buf[buf.len - 1] = '\n';
        w.end = buf.len;
    };
    var written: win32.DWORD = 0;
    _ = win32.WriteFile(file, &buf, @intCast(w.end), &written, null);
}

const max_response_line = (1 << 24) - 1;
const png_response_overhead = 128;
var active_connections: std.atomic.Value(usize) = .{ .raw = 0 };
/// Waits and event streams hold none of the request slots; they share
/// this many slots of their own.
const max_streams = 256;
var open_streams: std.atomic.Value(usize) = .{ .raw = 0 };
/// Attach streams, which attach limits itself; counted so that an idle
/// daemon does not exit under one.
var open_attaches: std.atomic.Value(usize) = .{ .raw = 0 };
/// The longest a wait may wait.
const max_wait_ms = 10 * std.time.ms_per_min;
var png_render_lock: std.Io.Mutex = .init;
/// Loaded fonts and glyphs; png_render_lock guards them.
var png_fonts: ?fonts.Library = null;

/// How the daemon was started. With `socket` set it is supervised: it
/// listens on exactly that path, never exits when idle, and (on Linux)
/// its session children die with it. Either way it shuts down on SIGTERM
/// or SIGINT as on a shutdown request.
pub const Options = struct {
    socket: ?[]const u8 = null,
    /// Supervised mode only: append the daemon's log here.
    log: ?[]const u8 = null,
    /// Exit once no session has run for a minute, also when supervised.
    idle_exit: bool = false,
    /// Refresh the times of the socket's folder, the socket, and its lock
    /// every hour, so age-based cleaning of /tmp leaves them alone.
    keep_fresh: bool = false,
};

/// How long a daemon with --idle-exit waits without sessions.
const idle_exit_flag_ms = std.time.ms_per_min;

pub fn run(gpa: std.mem.Allocator, opts: Options) !void {
    prepareProcess();
    blockShutdownSignals();
    if (opts.socket != null) session.supervised = true;

    var path_buf: [ipc.max_path_len:0]u8 = undefined;
    const path = if (opts.socket) |p|
        std.mem.printSentinel(&path_buf, "{s}", .{p}, 0) catch return error.SocketPathTooLong
    else
        try ipc.socketPath(&path_buf);
    var server = try ipc.listen(path);
    defer server.deinit();
    store.open(gpa) catch |err| {
        if (store.rootDir().len == 0) {
            std.log.err("cannot use the session store: {s}", .{store.errorText(err)});
        } else std.log.err("cannot use the session store in {s}: {s}", .{ store.rootDir(), store.errorText(err) });
        return error.StoreUnavailable;
    };
    track.counter.start(store.reserveSeqs) catch |err| {
        std.log.err("cannot reserve change seqs in the session store: {s}; they may repeat after a restart", .{@errorName(err)});
    };
    budget.init();
    session.init(gpa, path);
    shutdown_server = &server;
    // Only now: startup failures above still reach the terminal. Before
    // the threads, which log.
    if (opts.socket != null) if (opts.log) |log_path| try redirectLog(log_path);
    (try std.Thread.spawn(.{}, housekeep, .{gpa})).detach();
    (try std.Thread.spawn(.{}, unloadIdle, .{})).detach();
    (try std.Thread.spawn(.{}, registry.trimmer, .{})).detach();
    (try std.Thread.spawn(.{}, compressIdle, .{})).detach();
    (try std.Thread.spawn(.{}, shutdownOnSignal, .{})).detach();
    if (opts.keep_fresh) (try std.Thread.spawn(.{}, keepFresh, .{path})).detach();

    std.log.info("tuppet daemon listening on {s}", .{path});

    // A supervised daemon lives as long as its supervisor wants.
    const idle_exit: u64 = if (builtin.os.tag == .windows) 0 else if (opts.idle_exit) idle_exit_flag_ms else if (opts.socket == null) idleExitMillis() else 0;
    var last_accept_error: ?anyerror = null;
    while (true) {
        const io = io_mod.io();
        if (idle_exit > 0) waitForClient(&server, idle_exit);
        var conn = ipc.accept(&server, io) catch |err| {
            // Persistent failures (out of descriptors) must not spin the
            // CPU or flood the log: back off, and log each new error once.
            if (last_accept_error == null or last_accept_error.? != err) std.log.err("accept failed: {}", .{err});
            last_accept_error = err;
            std.Io.sleep(io, .fromMilliseconds(100), .boot) catch {};
            continue;
        };
        last_accept_error = null;
        // At the request limit, stop accepting until a slot frees up:
        // further clients queue in the listen backlog instead of failing.
        while (active_connections.load(.acquire) >= max_connections) {
            std.Io.sleep(io, .fromMilliseconds(5), .boot) catch {};
        }
        _ = active_connections.fetchAdd(1, .acq_rel);
        const worker = std.Thread.spawn(.{}, handleConnection, .{ gpa, conn }) catch |err| {
            _ = active_connections.fetchSub(1, .acq_rel);
            conn.deinit();
            std.log.err("cannot start connection worker: {}", .{err});
            continue;
        };
        worker.detach();
    }
}

/// Touch the socket's folder, the socket, and its lock file now and every
/// hour, without following links.
fn keepFresh(path: [:0]const u8) void {
    if (builtin.os.tag == .windows) return;
    var buf: [ipc.max_path_len + 8:0]u8 = undefined;
    while (true) {
        const dir = std.fs.path.dirname(path) orelse "/";
        const lock_path = std.fmt.bufPrintSentinel(&buf, "{s}.lock", .{path}, 0) catch path;
        var dir_buf: [ipc.max_path_len:0]u8 = undefined;
        const dir_z = std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{dir}, 0) catch path;
        for ([_][:0]const u8{ dir_z, path, lock_path }) |p| {
            if (std.c.utimensat(std.c.AT.FDCWD, p, null, std.c.AT.SYMLINK_NOFOLLOW) != 0) std.log.warn("cannot refresh the time of {s}", .{p});
        }
        std.Io.sleep(io_mod.io(), .fromSeconds(3600), .awake) catch return;
    }
}

/// Ended sessions stay in the store this long unless TUPPET_KEEP says
/// otherwise.
const default_keep_ms: i64 = 7 * std.time.ms_per_day;

/// TUPPET_KEEP: a duration, or 0 to keep sessions until they are removed.
fn keepMillis() ?i64 {
    const value = std.mem.span(std.c.getenv("TUPPET_KEEP") orelse return default_keep_ms);
    const ms = units.parseDuration(value, .days) orelse {
        std.log.warn("ignoring TUPPET_KEEP={s}: expected {s}", .{ value, units.durationHint(.days) });
        return default_keep_ms;
    };
    return if (ms == 0) null else @intCast(ms);
}

/// Store upkeep: delete other boots' sessions once, then mark lost
/// sessions and delete expired ones at start and every hour.
fn housekeep(gpa: std.mem.Allocator) void {
    store.removeOtherBoots();
    const keep = keepMillis();
    while (true) {
        if (store.housekeep(gpa, keep)) |deleted| {
            defer gpa.free(deleted);
            session.forgetExpired(deleted);
        } else |err| std.log.err("store upkeep failed: {}", .{err});
        std.Io.sleep(io_mod.io(), .fromSeconds(3600), .awake) catch return;
    }
}

/// Unload ended sessions restored from the store once nothing uses them,
/// forget those another daemon's expiry deleted, and give trimmed
/// sessions their history back when there is room.
fn unloadIdle() void {
    while (true) {
        std.Io.sleep(io_mod.io(), .fromSeconds(10), .awake) catch return;
        _ = registry.unloadIdle(registry.unload_idle_ns);
        registry.liftHistoryCaps();
        registry.forgetVanished();
    }
}

/// Compress the history of quiet sessions every second, for as long as
/// the target can.
fn compressIdle() void {
    while (true) {
        std.Io.sleep(io_mod.io(), .fromSeconds(1), .awake) catch return;
        if (!registry.compressIdle()) return;
    }
}

/// Wait until a client connects. After `idle_ms` without sessions or
/// clients, exit instead: closing the listener resets the connections
/// still queued on it, which the daemon has not read, and their clients
/// retry against the next daemon they start.
fn waitForClient(server: *ipc.Server, idle_ms: u64) void {
    const fd = server.posix.listener.socket.handle;
    const limit_ns = @as(i64, @intCast(idle_ms)) * std.time.ns_per_ms;
    // Idle time counts from the last client or session.
    var idle_since = io_mod.nowNanos();
    while (true) {
        const left_ms = @divTrunc(limit_ns - (io_mod.nowNanos() - idle_since), std.time.ns_per_ms);
        var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&pfd, 1, @intCast(std.math.clamp(left_ms, 1, 1000)));
        if (ready > 0) return;
        if (ready < 0) continue;
        if (session.unsettledCount() > 0 or active_connections.load(.acquire) > 0 or open_streams.load(.acquire) > 0 or open_attaches.load(.acquire) > 0) {
            idle_since = io_mod.nowNanos();
        } else if (io_mod.nowNanos() - idle_since >= limit_ns) {
            // A shutdown under way releases the endpoint and exits itself.
            if (session.refuseStarts()) return;
            std.log.info("no sessions for {d} ms; exiting", .{idle_ms});
            server.deinit();
            std.process.exit(0);
        }
    }
}

var shutdown_server: ?*ipc.Server = null;
var shutdown_signals: std.c.sigset_t = undefined;

/// Before any thread starts: block SIGTERM/SIGINT in every thread so only
/// `shutdownOnSignal` receives them. Session children reset their signal
/// mask before exec.
fn blockShutdownSignals() void {
    if (builtin.os.tag == .windows) return;
    _ = std.c.sigemptyset(&shutdown_signals);
    _ = std.c.sigaddset(&shutdown_signals, std.posix.SIG.TERM);
    _ = std.c.sigaddset(&shutdown_signals, std.posix.SIG.INT);
    _ = std.c.sigprocmask(std.c.SIG.BLOCK, &shutdown_signals, null);
}

/// Supervised mode: append the daemon's log to `log_path`.
fn redirectLog(log_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        var path_w: [std.fs.max_path_bytes]u16 = undefined;
        const path = win32.utf8ToUtf16(&path_w, log_path) catch return error.LogPathTooLong;
        const h = win32.CreateFileW(@ptrCast(path.ptr), win32.FILE_APPEND_DATA, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
        if (h == win32.INVALID_HANDLE_VALUE) return error.CannotOpenLog;
        log_file = h;
        return;
    }
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = std.mem.printSentinel(&buf, "{s}", .{log_path}, 0) catch return error.LogPathTooLong;
    const fd = std.c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.CannotOpenLog;
    _ = std.c.dup2(fd, 2);
    _ = std.c.close(fd);
}

/// On SIGTERM or SIGINT, shut down as a shutdown request does, and on a
/// second one exit at once; on Windows, shut down on Ctrl-C, Ctrl-Break,
/// or the console closing.
fn shutdownOnSignal() void {
    if (builtin.os.tag == .windows) {
        // A process started in a new process group ignores Ctrl-C until
        // this turns it back on.
        _ = win32.SetConsoleCtrlHandler(null, 0);
        _ = win32.SetConsoleCtrlHandler(&onConsoleEvent, 1);
        return;
    }
    var sig: c_int = 0;
    while (std.c.sigwait(&shutdown_signals, &sig) != 0) {}
    std.log.info("signal {d}: stopping all sessions", .{sig});
    const stopper = std.Thread.spawn(.{}, shutDown, .{ @as(?*Request, null), false }) catch return shutDown(null, false);
    stopper.detach();
    while (std.c.sigwait(&shutdown_signals, &sig) != 0) {}
    std.log.warn("signal {d} again: exiting without waiting for the sessions", .{sig});
    std.process.exit(1);
}

/// Windows runs this on a thread of its own.
fn onConsoleEvent(event: win32.DWORD) callconv(.winapi) win32.BOOL {
    std.log.info("console event {d}: stopping all sessions", .{event});
    shutDown(null, false);
    return 1;
}

/// Stop the daemon, for the shutdown request `r` or, when null, a signal:
/// refuse new work, end every attach stream with reason shutdown, stop
/// every running session as `tuppet stop` does (all at once), let ended
/// ones finish saving, give the
/// waits their answers and the event streams their last frames, reset
/// the store when asked, reply, release the endpoint, and exit 0. Only
/// the first caller gets that far. Nothing here waits for a signal,
/// which Windows lacks.
fn shutDown(r: ?*Request, reset: bool) void {
    if (session.refuseStarts()) {
        if (r) |req| req.fail(.stopping, null, "the daemon is shutting down already", .{});
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    var resp: protocol.ShutdownResp = .{ .socket = registry.endpoint };
    stopAll(a, &resp);
    // A program that ended on its own just before may still be saving its
    // results; exiting now would lose them.
    const saved_by = io_mod.nowNanos() + session.save_wait_ns;
    while (session.unsettledCount() > 0 and io_mod.nowNanos() < saved_by) {
        std.Io.sleep(io_mod.io(), .fromMilliseconds(5), .boot) catch {};
    }
    if (session.unsettledCount() > 0) std.log.err("{d} sessions did not finish saving their results", .{session.unsettledCount()});
    // After the sessions stopped, so subscribers see them end.
    events.shutdown();
    // Streams get as long to take their last line as a slow viewer does,
    // and requests that came meanwhile as long to take their refusal.
    const deadline = io_mod.nowNanos() + 2500 * std.time.ns_per_ms;
    attach.waitClosed(deadline);
    events.waitClosed(deadline);
    const own: usize = @intFromBool(r != null);
    while ((open_streams.load(.acquire) > 0 or active_connections.load(.acquire) > own) and io_mod.nowNanos() < deadline) {
        std.Io.sleep(io_mod.io(), .fromMilliseconds(5), .boot) catch {};
    }
    // Under the boot lock and before the endpoint goes, so a daemon that
    // starts on it meanwhile finds the reset done.
    var reset_failed: ?anyerror = null;
    if (reset) {
        if (store.reset(a, registry.endpoint, ipc.answersHello)) |done| {
            resp.removed = done.removed;
            resp.kept = done.kept;
            resp.next_id = done.next_id;
            std.log.info("reset the session store: deleted {d} sessions, kept {d}", .{ done.removed, done.kept });
        } else |err| {
            reset_failed = err;
            std.log.err("cannot reset the session store: {}", .{err});
        }
    } else {
        resp.kept = if (registry.allIds(a)) |ids| ids.len else |_| 0;
        resp.next_id = store.nextId(a) catch 1;
    }
    resp.boot = store.bootLabel(a) catch store.bootId();
    if (r) |req| {
        if (reset_failed) |err|
            req.fail(.internal, null, "the sessions stopped, but the session store could not be reset: {s}", .{@errorName(err)})
        else
            req.reply(resp);
        req.conn.flush();
    }
    std.log.info("shut down", .{});
    // The main thread may be accepting on it still.
    if (shutdown_server) |server| server.withdraw();
    std.process.exit(0);
}

/// End every attach stream and stop every running session, and record in
/// `resp` which stopped and which could not.
fn stopAll(a: std.mem.Allocator, resp: *protocol.ShutdownResp) void {
    var targets: std.ArrayList(Target) = .empty;
    if (session.acquireAll(a)) |sessions| {
        defer session.releaseAll(a, sessions);
        for (sessions) |s| {
            s.endViewers(attach.shutdown_line);
            if (s.state.load(.acquire) != .running) continue;
            targets.append(a, .{ .session = .{ .ref = "", .id = s.id } }) catch {
                s.stop() catch {};
            };
        }
    } else |err| std.log.err("cannot list the sessions to stop: {}", .{err});
    const which = a.alloc(bool, targets.items.len) catch return stopEach(targets.items);
    @memset(which, true);
    const outcomes = stopRunning(a, targets.items, which) catch return stopEach(targets.items);
    var stopped: std.ArrayList(Status) = .empty;
    var failed: std.ArrayList(protocol.StopFailure) = .empty;
    for (targets.items, outcomes) |t, outcome| {
        const id = t.session.id;
        const st = registry.statusOf(a, id) catch null;
        if (outcome) |err| {
            const why = sessionError(err);
            const text = std.fmt.allocPrint(a, "cannot stop session {d}: {s}", .{ id, why.text }) catch why.text;
            failed.append(a, .{ .id = id, .code = why.code, .err = text, .status = st }) catch {};
            std.log.err("{s}", .{text});
        } else if (st) |stopped_status| stopped.append(a, stopped_status) catch {};
    }
    resp.stopped = stopped.items;
    resp.failed = failed.items;
}

/// Stop the targets one after another, when there is no memory to stop
/// them at once.
fn stopEach(targets: []const Target) void {
    for (targets) |t| {
        var outcome: ?anyerror = null;
        stopOne(t.session.id, &outcome);
    }
}

/// POSIX: make sure fds 0-2 are open, so nothing the daemon opens later
/// lands on them (a setup pipe on fd 0-2 would be clobbered by the
/// child's dup2), and keep descriptors inherited from whoever started
/// the daemon away from session children. SIGCHLD must not be ignored,
/// or the kernel reaps children before their exit codes are read. The
/// daemon leaves the starting directory so it never keeps a filesystem
/// busy; requests carry absolute paths.
fn prepareProcess() void {
    if (builtin.os.tag == .windows) return;
    var empty_mask: std.c.sigset_t = undefined;
    _ = std.c.sigemptyset(&empty_mask);
    const default_action: std.c.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = empty_mask,
        .flags = 0,
    };
    _ = std.c.sigaction(std.posix.SIG.CHLD, &default_action, null);
    _ = std.c.chdir("/");
    for (0..3) |fd| {
        if (std.c.fcntl(@intCast(fd), std.c.F.GETFD) < 0) {
            // open() returns the lowest free descriptor: this one.
            _ = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        }
    }
    var limit: std.c.rlimit = undefined;
    const max_fd: usize = if (std.c.getrlimit(.NOFILE, &limit) == 0)
        @intCast(@min(limit.cur, 65536))
    else
        1024;
    var fd: usize = 3;
    while (fd < max_fd) : (fd += 1) {
        const flags = std.c.fcntl(@intCast(fd), std.c.F.GETFD);
        if (flags >= 0 and flags & std.c.FD_CLOEXEC == 0) {
            _ = std.c.fcntl(@intCast(fd), std.c.F.SETFD, flags | std.c.FD_CLOEXEC);
        }
    }
    raiseFileLimit();
}

/// Every session, request, and attach stream holds descriptors: raise the
/// soft limit to the hard one. Session children get the old limit back.
fn raiseFileLimit() void {
    var limit: std.c.rlimit = undefined;
    if (std.c.getrlimit(.NOFILE, &limit) != 0 or limit.cur >= limit.max) return;
    var raised = limit;
    raised.cur = limit.max;
    // macOS refuses more than OPEN_MAX, whatever the hard limit says.
    if (std.c.setrlimit(.NOFILE, &raised) != 0) {
        raised.cur = @min(limit.max, 10240);
        if (raised.cur <= limit.cur or std.c.setrlimit(.NOFILE, &raised) != 0) return;
    }
    spawn.child_nofile = limit;
}

fn handleConnection(persistent_gpa: std.mem.Allocator, owned_conn: ipc.Conn) void {
    var conn = owned_conn;
    var arena = std.heap.ArenaAllocator.init(persistent_gpa);
    defer arena.deinit();
    var r: Request = .{ .arena = &arena, .gpa = arena.allocator(), .persistent_gpa = persistent_gpa, .conn = &conn };
    // After the connection closed: on Windows the reply is only delivered
    // then, and a daemon that shuts down waits for the slots to free up.
    defer r.releaseSlot();
    defer conn.deinit();

    // An attach client may send frames right behind its request; `rest`
    // keeps them for the stream.
    const split = conn.recvRequest(r.gpa, 1 << 20) catch |err| {
        switch (err) {
            error.LineTooLong => r.fail(.limit, null, "the request exceeds the 1 MiB limit", .{}),
            error.ReadTimeout => r.fail(.bad_request, null, "the request did not arrive within 10 s", .{}),
            error.OutOfMemory => r.fail(.internal, null, "out of memory", .{}),
            error.Eof => {},
            else => std.log.err("read failed: {}", .{err}),
        }
        return;
    };
    r.rest = split.rest;
    const envelope = protocol.parseEnvelope(r.gpa, split.line) catch |err| {
        switch (err) {
            error.OutOfMemory => r.fail(.internal, null, "out of memory", .{}),
            error.RequestMustBeObject => r.fail(.bad_request, null, "the request must be a JSON object", .{}),
            error.MissingCommand => r.fail(.bad_request, null, "missing field 'cmd'", .{}),
            error.CommandMustBeString => r.fail(.bad_request, null, "field 'cmd' must be a string", .{}),
            else => r.fail(.bad_request, null, "the request is not valid JSON", .{}),
        }
        return;
    };
    r.value = envelope.value;
    // A daemon that is shutting down takes no more work; hello still says
    // what it is.
    if (session.stopping.load(.acquire) and !std.mem.eql(u8, envelope.cmd, "hello")) {
        r.fail(.stopping, null, "the daemon is shutting down", .{});
        return;
    }
    const index = handlers.getIndex(envelope.cmd) orelse {
        r.fail(.bad_request, null, "unknown command '{s}'", .{envelope.cmd});
        return;
    };
    // The name outlives the request line.
    r.cmd = handlers.keys()[index];
    handlers.values()[index].run(&r);
}

/// A stream (events, attach) must not hold one of the request slots for
/// its whole life: it releases its slot once it counts as open, so that
/// it always counts as one or the other.
const Handler = struct {
    run: *const fn (r: *Request) void,
};

fn handle(comptime f: fn (r: *Request) anyerror!void) Handler {
    return .{ .run = struct {
        fn run(r: *Request) void {
            f(r) catch |err| {
                if (r.replied) return;
                if (err == error.OutOfMemory) return r.fail(.internal, null, "out of memory", .{});
                r.fail(.internal, null, "{s}", .{@errorName(err)});
            };
        }
    }.run };
}

const handlers = std.StaticStringMap(Handler).initComptime(.{
    .{ "hello", handle(hello) },
    .{ "run", handle(runSession) },
    .{ "list", handle(list) },
    .{ "view", handle(viewSession) },
    .{ "png", handle(png) },
    .{ "resize", handle(resize) },
    .{ "rename", handle(renameSession) },
    .{ "input", handle(input) },
    .{ "record", handle(recordRequest) },
    .{ "wait", handle(waitSession) },
    .{ "stop", handle(stop) },
    .{ "remove", handle(remove) },
    .{ "ack", handle(ack) },
    .{ "alert", handle(alertRequest) },
    .{ "shutdown", handle(shutdownRequest) },
    .{ "events", handle(eventsStream) },
    .{ "attach", handle(attachStream) },
    .{ "update", handle(update) },
    .{ "side", handle(side) },
    .{ "flag", handle(flag) },
    .{ "action", handle(action) },
    .{ "lease", handle(leaseRequest) },
    .{ "respawn", handle(respawn) },
    .{ "commands", handle(commands) },
});

/// One request: its connection, its parsed line, and an arena that lives
/// as long as it does, unless `shed` frees it first.
const Request = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    persistent_gpa: std.mem.Allocator,
    conn: *ipc.Conn,
    cmd: []const u8 = "",
    value: std.json.Value = .null,
    rest: []const u8 = "",
    replied: bool = false,
    slot_released: bool = false,
    /// An input request: its failures say how many steps ran.
    input: bool = false,

    /// Give the request slot back, for a request that may last long.
    fn releaseSlot(r: *Request) void {
        if (r.slot_released) return;
        r.slot_released = true;
        _ = active_connections.fetchSub(1, .acq_rel);
    }

    /// Free the arena, the parsed request line with it, before the request
    /// waits or streams for long; what it still needs must live elsewhere.
    /// Later allocations start the arena anew.
    fn shed(r: *Request) void {
        r.value = .null;
        r.rest = "";
        _ = r.arena.reset(.free_all);
    }

    /// Whether `refs` names more sessions than a request may, after a
    /// limit reply that says so.
    fn tooManyRefs(r: *Request, refs: []const []const u8) bool {
        if (refs.len <= limits.max_refs) return false;
        r.fail(.limit, null, "a {s} request takes at most {d} session references, not {d}", .{ r.cmd, limits.max_refs, refs.len });
        return true;
    }

    /// The request as `T`, or null after a bad_request reply.
    fn decode(r: *Request, comptime T: type) !?T {
        var problem: protocol.Problem = .{};
        return protocol.decode(T, r.gpa, r.value, &problem) catch |err| {
            if (err != error.BadRequest) return err;
            r.fail(.bad_request, null, "bad {s} request: {s}", .{ r.cmd, try problem.message(r.gpa) });
            return null;
        };
    }

    fn reply(r: *Request, value: anytype) void {
        r.replied = true;
        const out = protocol.stringifyAlloc(r.gpa, value) catch {
            r.conn.sendLine("{\"ok\":false,\"code\":\"internal\",\"err\":\"out of memory\",\"status\":null}") catch {};
            return;
        };
        if (out.len > max_response_line) {
            r.conn.sendLine("{\"ok\":false,\"code\":\"limit\",\"err\":\"the reply exceeds the 16 MiB limit\",\"status\":null}") catch {};
            return;
        }
        r.conn.sendLine(out) catch {};
    }

    fn fail(r: *Request, code: protocol.Code, st: ?Status, comptime fmt: []const u8, args: anytype) void {
        const err = std.fmt.allocPrint(r.gpa, fmt, args) catch "out of memory";
        if (r.input) return r.reply(protocol.InputFailure{ .code = code, .err = err, .status = st });
        r.reply(protocol.Failure{ .code = code, .err = err, .status = st });
    }

    /// Reply to a mark or stop that found no recording, or could not
    /// write it.
    fn failNotRecording(r: *Request, s: *session.Session, err: anyerror) void {
        const st = status.of(r.gpa, s) catch null;
        switch (err) {
            error.NotRecording => if (s.state.load(.acquire) == .exited)
                r.fail(.ended, st, "the session has ended, so no recording is active", .{})
            else
                r.fail(.bad_request, st, "no recording is active", .{}),
            error.OutOfMemory => r.fail(.internal, st, "out of memory", .{}),
            else => r.fail(.internal, st, "the recording could not be written", .{}),
        }
    }

    /// Reply to a failed session operation.
    fn failSession(r: *Request, s: *session.Session, err: anyerror) void {
        const st = status.of(r.gpa, s) catch null;
        if (err == error.OutOfMemory) return r.fail(.internal, st, "out of memory", .{});
        const why = sessionError(err);
        r.fail(why.code, st, "{s}", .{why.text});
    }

    /// The id of the session `ref` picks, or null after a reply that says
    /// why there is none.
    fn resolve(r: *Request, ref: []const u8) !?u64 {
        if (names.refError(ref)) |why| {
            r.fail(.bad_request, null, "invalid session '{s}': {s}", .{ ref, why });
            return null;
        }
        if (names.kind(ref) == .id) return protocol.parseDecimal(u64, ref).?;
        const ids = try registry.pick(r.gpa, ref, .any);
        if (ids.len == 0) {
            r.fail(.no_session, null, "{s}", .{try names.noMatch(r.gpa, ref)});
            return null;
        }
        if (ids.len > 1) {
            const matches = try r.statuses(ids);
            const err = try names.tooMany(r.gpa, ref, matches);
            if (r.input) {
                r.reply(protocol.InputFailure{ .code = .ambiguous, .err = err, .matches = matches });
            } else r.reply(protocol.Ambiguous{ .err = err, .matches = matches });
            return null;
        }
        return ids[0];
    }

    /// The session `ref` picks, with a reference taken (release it with
    /// `session.release`), or null after a reply that says why there is
    /// none.
    fn acquireSession(r: *Request, ref: []const u8) !?*session.Session {
        const id = try r.resolve(ref) orelse return null;
        return r.acquireId(id);
    }

    /// The session `id`, with a reference taken, or null after a reply
    /// that says why there is none.
    fn acquireId(r: *Request, id: u64) !?*session.Session {
        switch (registry.acquireOr(id)) {
            .session => |s| return s,
            .missing => {
                const missing = try registry.missingReason(r.gpa, id);
                r.fail(missing.code, try registry.statusOf(r.gpa, id), "{s}", .{missing.err});
            },
            .over_budget => |asked| {
                var buf: [256]u8 = undefined;
                r.fail(.limit, try registry.statusOf(r.gpa, id), "cannot load session {d} from the store: {s}", .{ id, budget.describe(&buf, asked) });
            },
        }
        return null;
    }

    fn statuses(r: *Request, ids: []const u64) ![]Status {
        var out: std.ArrayList(Status) = .empty;
        for (ids) |id| if (try registry.statusOf(r.gpa, id)) |st| try out.append(r.gpa, st);
        return out.toOwnedSlice(r.gpa);
    }

    fn replyStatus(r: *Request, s: *session.Session) !void {
        r.reply(protocol.StatusResp{ .status = try status.of(r.gpa, s) });
    }

    /// Whether `until` cannot be waited for, after a reply that says why.
    fn badUntil(r: *Request, until: []const cond.Condition, timeout_ms: u64) !bool {
        if (try cond.problem(r.gpa, until)) |why| {
            r.fail(.bad_request, null, "bad {s} request: {s}", .{ r.cmd, why });
            return true;
        }
        if (timeout_ms > max_wait_ms) {
            r.fail(.bad_request, null, "bad {s} request: timeout_ms must be at most {d} (10 minutes)", .{ r.cmd, max_wait_ms });
            return true;
        }
        return r.unsupportedUntil(until);
    }

    fn unsupportedUntil(r: *Request, until: []const cond.Condition) bool {
        if (cond.unsupported(until)) |u| {
            r.fail(.unsupported, null, "until[{d}]: {s}", .{ u.index, u.why });
            return true;
        }
        return false;
    }

    /// Whether a seq in `until` is stale for `s`, after a reply that says so.
    fn staleUntil(r: *Request, s: *session.Session, until: []const cond.Condition) !bool {
        for (until) |c| {
            if (c.since) |since| if (since < s.track.start_seq) {
                r.fail(.stale, try status.of(r.gpa, s), "seq {d} is older than session {d}, which started at seq {d}", .{ since, s.id, s.track.start_seq });
                return true;
            };
            const after = c.after_input orelse continue;
            if (after != .seq) continue;
            const latest = s.track.input_seq.load(.acquire);
            if (after.seq != latest) {
                r.fail(.stale, try status.of(r.gpa, s), "input_seq {d} is not the latest input of session {d}, which is {d}", .{ after.seq, s.id, latest });
                return true;
            }
        }
        return false;
    }

    /// Whether a `hit` condition in `until` names an alert that `s` does
    /// not have, after a reply that says so.
    fn unknownAlert(r: *Request, s: *session.Session, until: []const cond.Condition) !bool {
        const name = blk: {
            s.lockTerminal();
            defer s.unlockTerminal();
            for (until) |c| if (c.hit) |h| {
                if (!std.mem.eql(u8, h.name, "*") and s.track.alerts().find(h.name) == null) break :blk h.name;
            };
            return false;
        };
        r.fail(.no_alert, try status.of(r.gpa, s), "session {d} has no alert named '{s}', so no hit of it can come ('tuppet alert add' adds it)", .{ s.id, name });
        return true;
    }

    /// A wait on `s` about to begin, counted among the open streams, or
    /// null after a reply that says why it cannot. Hand it to
    /// `awaitAnswer`, or give it back with `dropWait`.
    fn openWait(r: *Request, s: *session.Session, opts: evaluator.Options) !?*evaluator.Waiter {
        if (try r.staleUntil(s, opts.until)) return null;
        if (try r.unknownAlert(s, opts.until)) return null;
        if (open_streams.fetchAdd(1, .acq_rel) >= max_streams) {
            _ = open_streams.fetchSub(1, .acq_rel);
            r.fail(.limit, try status.of(r.gpa, s), "too many open waits and event streams (at most {d})", .{max_streams});
            return null;
        }
        errdefer _ = open_streams.fetchSub(1, .acq_rel);
        return try evaluator.Waiter.create(r.persistent_gpa, opts);
    }

    fn dropWait(w: *evaluator.Waiter) void {
        w.release();
        _ = open_streams.fetchSub(1, .acq_rel);
    }

    /// Wait for the answer to `w` and reply with it. This takes over the
    /// references on `s` and `w`; `registered` says whether `w` is on the
    /// evaluator of `s`, else it is checked once. Nothing is replied when
    /// the client hangs up first.
    fn awaitAnswer(r: *Request, s: *session.Session, w: *evaluator.Waiter, registered: bool) !void {
        defer dropWait(w);
        // The answer is read before the wait stops counting.
        defer r.conn.flush();
        r.releaseSlot();
        const id = s.id;
        if (!registered) evaluator.answerNow(s, w);
        session.release(s);
        // The waiter has its own copy of the conditions.
        r.shed();
        if (builtin.os.tag != .windows) hangup.watch(r.conn.posix.socket.handle, w);
        defer hangup.unwatch(w);
        if (!evaluator.block(w, id)) {
            r.replied = true;
            return;
        }
        r.reply(w.reply());
    }

    /// Keep the connection, after the reply, as a lease on `s`: the
    /// hang-up watcher stops the session once the client goes, and closes
    /// the connection when the session ends.
    fn lease(r: *Request, s: *session.Session) void {
        // Requests for a lease are refused off Linux before this.
        if (builtin.os.tag != .linux) return;
        r.conn.flush();
        const fd = std.c.dup(r.conn.posix.socket.handle);
        if (fd < 0) return std.log.err("session {d}: cannot keep its lease: no descriptor left", .{s.id});
        hangup.lease(fd, s.id) catch |err| {
            _ = std.c.close(fd);
            return std.log.err("session {d}: cannot keep its lease: {}", .{ s.id, err });
        };
        // It may have ended before the lease was kept.
        if (s.state.load(.acquire) == .exited) hangup.endLeases(s.id);
    }

    /// Wait on `s`, whose reference this takes over, and reply with the
    /// outcome. Nothing is replied when the client hangs up first.
    fn waitOn(r: *Request, s: *session.Session, opts: evaluator.Options) !void {
        const w = (r.openWait(s, opts) catch |err| {
            session.release(s);
            return err;
        }) orelse return session.release(s);
        const registered = evaluator.register(s, w, opts.from_start) catch |err| {
            session.release(s);
            dropWait(w);
            return err;
        };
        return r.awaitAnswer(s, w, registered);
    }
};

// ---- requests -----------------------------------------------------------

fn hello(r: *Request) !void {
    _ = try r.decode(protocol.HelloReq) orelse return;
    r.reply(protocol.HelloResp{ .boot = try store.bootLabel(r.gpa) });
}

fn shutdownRequest(r: *Request) !void {
    const req = try r.decode(protocol.ShutdownReq) orelse return;
    std.log.info("shutdown requested{s}: stopping all sessions", .{if (req.reset) ", with a reset" else ""});
    shutDown(r, req.reset);
}

fn runSession(r: *Request) !void {
    var req = try r.decode(protocol.RunReq) orelse return;
    if (req.like) |ref| {
        const id = try r.resolve(ref) orelse return;
        const like = try registry.templateOf(r.gpa, id) orelse {
            const missing = try registry.missingReason(r.gpa, id);
            return r.fail(missing.code, null, "{s}", .{missing.err});
        };
        req.argv = req.argv orelse like.argv;
        req.cwd = req.cwd orelse if (like.cwd.len > 0) like.cwd else null;
        req.name = req.name orelse like.name;
        req.cols = req.cols orelse like.cols;
        req.rows = req.rows orelse like.rows;
        req.scrollback = req.scrollback orelse like.scrollback;
        req.alerts = req.alerts orelse like.alerts;
    }
    const argv = req.argv orelse return r.fail(.bad_request, null, "bad run request: missing field 'argv'", .{});
    const cols = req.cols orelse 120;
    const rows = req.rows orelse 40;
    if (limits.sizeError(cols, rows)) |why| return r.fail(.bad_request, null, "invalid size {d}x{d} ({s})", .{ cols, rows, why });
    if (argv.len == 0) return r.fail(.bad_request, null, "run requires a command", .{});
    for (argv, 0..) |arg, i| if (hasNul(arg)) return r.fail(.bad_request, null, "bad run request: argv[{d}] contains a NUL byte", .{i});
    if (req.cwd) |cwd| if (hasNul(cwd) or !std.fs.path.isAbsolute(cwd)) return r.fail(.bad_request, null, "cwd must be an absolute path, without NUL bytes", .{});
    const name = req.name orelse "";
    if (name.len > 0) if (names.nameError(name)) |why| return r.fail(.bad_request, null, "invalid session name '{s}': {s}", .{ name, why });
    const scrollback = req.scrollback orelse limits.default_scrollback;
    if (scrollback > limits.max_scrollback) return r.fail(.bad_request, null, "scrollback must be at most 1 GiB", .{});
    const alerts = req.alerts orelse &.{};
    if (alerts.len > alert.max_alerts) return r.fail(.limit, null, "bad run request: a session takes at most {d} alerts", .{alert.max_alerts});
    if (try alert.rulesError(r.gpa, alerts)) |why| return r.fail(.bad_request, null, "bad run request: {s}", .{why});
    var record: ?session.RunRecord = null;
    if (req.record) |rec| {
        if (rec.path) |p| if (hasNul(p) or !std.fs.path.isAbsolute(p)) return r.fail(.bad_request, null, "recording path must be absolute, without NUL bytes", .{});
        record = .{ .path = rec.path, .format = rec.format, .passwords = rec.passwords orelse false };
    }
    if (req.until) |until| {
        const timeout_ms = req.timeout_ms orelse return r.fail(.bad_request, null, "bad run request: until needs timeout_ms", .{});
        if (try r.badUntil(until, timeout_ms)) return;
        for (until, 0..) |c, i| {
            const after_seq = if (c.after_input) |after| after == .seq else false;
            if (c.since != null or after_seq) return r.fail(.bad_request, null, "bad run request: until[{d}] cannot refer to a seq of a session that has not started", .{i});
            // A kept session is checked for its own alerts.
            if (req.if_exists == .keep) if (registry.acquireRunningNamed(name)) |namesake| {
                session.release(namesake);
                continue;
            };
            if (c.hit) |h| if (!std.mem.eql(u8, h.name, "*")) {
                for (alerts) |rule| {
                    if (std.mem.eql(u8, rule.name, h.name)) break;
                } else return r.fail(.no_alert, null, "until[{d}] waits for a hit of the alert '{s}', which the session would not have; give it in alerts ('tuppet run --alert')", .{ i, h.name });
            };
        }
    } else if (req.timeout_ms != null) return r.fail(.bad_request, null, "bad run request: timeout_ms needs until", .{});
    var colors: ?[2]vt.color.RGB = null;
    if (req.colors) |c| {
        const fg = protocol.parseHexColor(c.fg) orelse return r.fail(.bad_request, null, "bad run request: colors.fg must be #rrggbb", .{});
        const bg = protocol.parseHexColor(c.bg) orelse return r.fail(.bad_request, null, "bad run request: colors.bg must be #rrggbb", .{});
        colors = .{ .{ .r = fg[0], .g = fg[1], .b = fg[2] }, .{ .r = bg[0], .g = bg[1], .b = bg[2] } };
    }
    var box: ?over.Start = null;
    if (req.over) |o| {
        if (req.if_exists != .fail) return r.fail(.bad_request, null, "bad run request: over goes with if_exists fail only", .{});
        if (req.group != null) return r.fail(.bad_request, null, "bad run request: a box belongs to the session it is shown over; give no group", .{});
        box = switch (try over.check(r.gpa, o, nullBackdrop(r.value))) {
            .ok => |start| start,
            .bad => |why| return r.fail(.bad_request, null, "bad run request: {s}", .{why}),
        };
    }
    var joined = switch (try member.apply(r.gpa, .{}, .{ .group = req.group, .label = req.label, .accent = req.accent, .mark = req.mark, .meta = req.meta, .actions = req.actions })) {
        .ok => |m| m,
        .bad => |why| return r.fail(.bad_request, null, "bad run request: {s}", .{why}),
    };
    if (req.side_view != null and req.side_of == null) return r.fail(.bad_request, null, "bad run request: side_view goes with side_of", .{});
    if (req.side_of) |ref| {
        if (req.over != null) return r.fail(.bad_request, null, "bad run request: a box is no side session; give over or side_of", .{});
        if (req.group != null) return r.fail(.bad_request, null, "bad run request: a side session belongs to the session it is tied to; give no group", .{});
        const main = try r.acquireSession(ref) orelse return;
        defer session.release(main);
        if (main.state.load(.acquire) == .exited) return r.fail(.ended, try status.of(r.gpa, main), "session {d} has ended, so no side session is tied to it", .{main.id});
        const main_member = try main.memberOf(r.gpa);
        if (main_member.side_of != null) return r.fail(.bad_request, try status.of(r.gpa, main), "session {d} is a side session itself", .{main.id});
        joined.side_of = main.id;
        joined.side_view = req.side_view orelse .compact;
    }
    if (req.lease == true) {
        if (req.until != null) return r.fail(.bad_request, null, "bad run request: lease goes without until", .{});
        if (builtin.os.tag != .linux) return r.fail(.unsupported, null, "leases are supported on Linux only", .{});
    }
    // The id of the session underneath, with room for the box reserved
    // on it. No reference on it is held across the start, which removes
    // ended namesakes and waits for their references.
    var under: ?u64 = null;
    defer if (under) |id| over.unreserve(id);
    if (req.over) |o| {
        const u = try r.acquireSession(o.session) orelse return;
        defer session.release(u);
        if (u.over != null) return r.fail(.bad_request, try status.of(r.gpa, u), "session {d} is a box, and no box is shown over a box", .{u.id});
        u.lockTerminal();
        const room = if (u.state.load(.acquire) == .exited) error.Ended else u.boxes.reserve();
        u.unlockTerminal();
        room catch |err| return switch (err) {
            error.Ended => r.fail(.ended, try status.of(r.gpa, u), "session {d} has ended, so no box is shown over it", .{u.id}),
            error.Limit => r.fail(.limit, try status.of(r.gpa, u), "session {d} has {d} running boxes, the most it takes", .{ u.id, over.max_boxes }),
        };
        under = u.id;
        box.?.over.id = u.id;
        // A box looks like the session it is shown over.
        if (colors == null) colors = u.defaultColors();
    }
    if (req.if_exists != .fail) if (registry.acquireRunningNamed(name)) |namesake| {
        if (req.if_exists == .keep) return started(r, namesake, req, false);
        defer session.release(namesake);
        namesake.stop() catch |err| return r.failSession(namesake, err);
    };
    // Numbers in a group and side ties are given one request at a time.
    var tying = joined.group != null or joined.side_of != null;
    if (tying) member.lock();
    defer if (tying) member.unlock();
    if (joined.group) |g| joined.number = try member.nextNumber(r.gpa, g);
    const main_side: ?*session.Session = if (joined.side_of) |id| registry.acquireLoaded(id) else null;
    defer if (main_side) |m| session.release(m);
    if (main_side) |m| if (member.sideOf(m)) |other| return r.fail(.exists, try status.of(r.gpa, m), "session {d} has a side session already ({d})", .{ m.id, other });
    const s = session.Session.start(r.persistent_gpa, .{
        .argv = argv,
        .cols = cols,
        .rows = rows,
        .cwd = req.cwd,
        .name = name,
        .env = req.env,
        .scrollback = scrollback,
        .record = record,
        .alerts = alerts,
        .over = if (box) |b| b.over else null,
        .colors = colors,
        .member = joined,
    }) catch |err| {
        if (err == error.NameTaken) if (registry.acquireRunningNamed(name)) |namesake| {
            // Started by another request meanwhile.
            if (req.if_exists == .keep) return started(r, namesake, req, false);
            defer session.release(namesake);
            return r.fail(.exists, try status.of(r.gpa, namesake), "the running session '{s}' has that name; stop it first, choose another name, or replace it with --if-exists replace", .{name});
        };
        return startFailed(r, req, err);
    };
    if (under) |id| {
        under = null;
        const kept = over.started(id, s);
        events.publish(id, .changed, .initOne(.under));
        // The session underneath ended while the box started.
        if (!kept) {
            over.stopLater(s, .under);
        } else if (box.?.unseen_ms) |ms| s.armUnseen(ms);
    }
    if (main_side) |m| member.tie(m, s);
    // Not held through the reply, nor through a wait that follows it.
    if (tying) member.unlock();
    tying = false;
    // Its screens may have pushed the sessions past the budget.
    registry.trimHistory();
    return started(r, s, req, true);
}

/// Whether a run request gives `over.backdrop` as null, which leaving it
/// out does not.
fn nullBackdrop(value: std.json.Value) bool {
    const o = value.object.get("over") orelse return false;
    if (o != .object) return false;
    const backdrop = o.object.get("backdrop") orelse return false;
    return backdrop == .null;
}

/// Reply with the status of the session a run started (or kept), whose
/// reference this takes over, and then, with until, with the wait.
fn started(r: *Request, s: *session.Session, req: protocol.RunReq, new: bool) !void {
    const until = req.until orelse {
        defer session.release(s);
        try replyRun(r, s);
        if (req.lease == true) r.lease(s);
        return;
    };
    replyRun(r, s) catch |err| {
        session.release(s);
        return err;
    };
    return r.waitOn(s, .{ .until = until, .timeout_ms = req.timeout_ms.?, .bundled = true, .from_start = new });
}

fn replyRun(r: *Request, s: *session.Session) !void {
    r.reply(protocol.RunResp{ .status = try status.of(r.gpa, s), .boot = try store.bootLabel(r.gpa) });
}

/// A NUL byte would end the string where the system reads it.
fn hasNul(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, 0) != null;
}

fn startFailed(r: *Request, req: protocol.RunReq, err: anyerror) void {
    const argv0 = req.argv.?[0];
    switch (err) {
        error.BadCwd => r.fail(.bad_request, null, "cannot start '{s}': working directory '{s}' is missing or not accessible", .{ argv0, req.cwd orelse "" }),
        error.TooManyOpenFiles => r.fail(.limit, null, "cannot start '{s}': the daemon has too many open files", .{argv0}),
        error.CantOpenFile => if (req.record.?.path) |path|
            r.fail(.bad_request, null, "cannot start '{s}': cannot create the recording file '{s}'", .{ argv0, path })
        else
            r.fail(.internal, null, "cannot start '{s}': cannot create the recording file in the session directory", .{argv0}),
        error.ChildSetupFailed => r.fail(.bad_request, null, "cannot start '{s}': command not found or not executable", .{argv0}),
        error.BadEnv => r.fail(.bad_request, null, "cannot start '{s}': malformed environment entry", .{argv0}),
        error.NameTaken => r.fail(.exists, null, "cannot start '{s}': the session named '{s}' is still saving its results", .{ argv0, req.name.? }),
        error.Stopping => r.fail(.stopping, null, "cannot start '{s}': the daemon is shutting down", .{argv0}),
        error.OverBudget => {
            var buf: [256]u8 = undefined;
            const asked = limits.sessionFloor(req.cols orelse 120, req.rows orelse 40);
            r.fail(.limit, null, "cannot start '{s}': {s}", .{ argv0, budget.describe(&buf, asked) });
        },
        error.IdsExhausted => r.fail(.limit, null, "cannot start '{s}': the session store has no ids left; 'tuppet shutdown --reset' starts them over", .{argv0}),
        error.StoreAccessDenied, error.StoreReadOnly, error.StoreFull, error.StoreFailed => r.fail(.internal, null, "cannot start '{s}': cannot write to the session store in {s}: {s}", .{ argv0, store.rootDir(), switch (err) {
            error.StoreAccessDenied => "permission denied",
            error.StoreReadOnly => "the file system is read-only",
            error.StoreFull => "the disk is full",
            else => "the daemon's log says why",
        } }),
        error.OutOfMemory => r.fail(.internal, null, "out of memory", .{}),
        else => r.fail(.internal, null, "cannot start '{s}': {s}", .{ argv0, @errorName(err) }),
    }
}

fn list(r: *Request) !void {
    const req = try r.decode(protocol.ListReq) orelse return;
    const ids = if (req.sessions) |refs| blk: {
        if (r.tooManyRefs(refs)) return;
        for (refs) |ref| if (names.refError(ref)) |why| return r.fail(.bad_request, null, "invalid session '{s}': {s}", .{ ref, why });
        var picked: std.ArrayList(u64) = .empty;
        for (refs) |ref| {
            var one = [1]u64{protocol.parseDecimal(u64, ref) orelse 0};
            const found = if (names.kind(ref) == .id) one[0..] else try registry.pick(r.gpa, ref, .any);
            for (found) |id| if (registry.exists(id) and std.mem.indexOfScalar(u64, picked.items, id) == null) try picked.append(r.gpa, id);
        }
        std.mem.sortUnstable(u64, picked.items, {}, std.sort.asc(u64));
        break :blk picked.items;
    } else try registry.allIds(r.gpa);
    r.reply(protocol.ListResp{ .sessions = try r.statuses(ids) });
}

fn viewSession(r: *Request) !void {
    const req = try r.decode(protocol.ViewReq) orelse return;
    if (req.styles and req.format != .plain) return r.fail(.bad_request, null, "bad view request: styles go with format plain; vt and html carry them already", .{});
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    if (req.since) |since| if (since < s.track.start_seq) {
        return r.fail(.stale, try status.of(r.gpa, s), "seq {d} is older than session {d}, which started at seq {d}", .{ since, s.id, s.track.start_seq });
    };
    const recording = try status.recordingOf(r.gpa, s);
    sample.refresh(s, true);
    const io = io_mod.io();
    s.terminal_mutex.lockUncancelable(io);
    // Output parsed but not settled yet: the text and the seq must agree.
    const settled = s.track.unsettled();
    if (settled) s.track.settle(&s.terminal, io_mod.nowNanos());
    const rendered = view.renderLocked(r.gpa, s, .{
        .format = switch (req.format) {
            .plain => .plain,
            .vt => .vt,
            .html => .html,
        },
        .scrollback = req.scrollback,
        .unwrap = req.unwrap,
        .since = req.since,
        .budget = max_response_line - view_reply_reserve,
        .styles = req.styles,
    });
    const st = status.ofLocked(r.gpa, s, recording);
    const dropped = s.track.history_dropped;
    s.terminal_mutex.unlock(io);
    if (settled) s.track.notify();
    const v = rendered catch |err| switch (err) {
        error.ViewTooLarge => return r.fail(.limit, try st, "the view exceeds the 16 MiB reply limit; plain text keeps the newest lines that fit", .{}),
        else => return err,
    };
    r.reply(protocol.ViewResp{ .text = v.text, .cursor = v.cursor, .truncated = v.truncated, .rows = v.rows, .history_dropped = dropped, .styles = v.styles, .status = try st });
}

fn waitSession(r: *Request) !void {
    const req = try r.decode(protocol.WaitReq) orelse return;
    if (try r.badUntil(req.until, req.timeout_ms)) return;
    const s = try r.acquireSession(req.session) orelse return;
    const shown: ?view.Options = if (req.format) |format| .{
        .format = switch (format) {
            .plain => .plain,
            .vt => .vt,
            .html => .html,
        },
        .scrollback = req.scrollback,
        .unwrap = req.unwrap,
        .budget = max_response_line - view_reply_reserve,
    } else null;
    return r.waitOn(s, .{ .until = req.until, .timeout_ms = req.timeout_ms, .view = shown });
}

/// Room in a view reply for everything but the text.
const view_reply_reserve = 1 << 20;

fn png(r: *Request) !void {
    const req = try r.decode(protocol.PngReq) orelse return;
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    // One render at a time bounds memory; the reply is sent outside the
    // lock so a slow reader cannot stall other renders.
    const io = io_mod.io();
    var diag: fonts.Diagnostic = .{};
    var oversize: Oversize = undefined;
    png_render_lock.lockUncancelable(io);
    const rendered_or_err = renderSessionPng(r.gpa, r.persistent_gpa, s, .{ .fonts = req.fonts orelse &.{}, .bitmap = req.bitmap orelse false, .font_size = req.font_size }, &diag, &oversize);
    png_render_lock.unlock(io);
    const rendered = rendered_or_err catch |err| switch (err) {
        error.ImageTooLarge => return r.fail(.limit, try status.of(r.gpa, s), "a PNG of {d}x{d} cells of {d}x{d} pixels exceeds the 128 MiB render limit; choose a smaller --font-size, or resize the session", .{ oversize.cols, oversize.rows, oversize.cell.width, oversize.cell.height }),
        error.BadFont => return r.fail(.bad_request, try status.of(r.gpa, s), "{s}", .{diag.message}),
        else => return err,
    };
    const b64_len = std.base64.standard.Encoder.calcSize(rendered.png.len);
    // JSON escapes a name to at most six bytes per byte.
    var overhead: usize = png_response_overhead;
    for (rendered.faces) |name| overhead += 6 * name.len + 3;
    if (b64_len + overhead > max_response_line) {
        return r.fail(.limit, try status.of(r.gpa, s), "the PNG exceeds the 16 MiB reply limit", .{});
    }
    const b64 = try r.gpa.alloc(u8, b64_len);
    _ = std.base64.standard.Encoder.encode(b64, rendered.png);
    r.reply(protocol.PngResp{
        .png_b64 = b64,
        .renderer = rendered.renderer,
        .cell = rendered.cell,
        .faces = rendered.faces,
        .status = try status.of(r.gpa, s),
    });
}

fn resize(r: *Request) !void {
    const req = try r.decode(protocol.ResizeReq) orelse return;
    if (limits.sizeError(req.cols, req.rows)) |why| return r.fail(.bad_request, null, "invalid size {d}x{d} ({s})", .{ req.cols, req.rows, why });
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    const seq = s.resizeSeq(req.cols, req.rows, .request, req.require.unattended) catch |err| switch (err) {
        error.Attended => return r.reply(protocol.GuardFailure{
            .err = try std.fmt.allocPrint(r.gpa, "session {d} has a writer attached; its size stays", .{s.id}),
            .status = try status.of(r.gpa, s),
            .guard = "unattended",
        }),
        error.OverBudget => {
            var buf: [256]u8 = undefined;
            s.lockTerminal();
            const asked = limits.sessionFloor(req.cols, req.rows) -| limits.sessionFloor(s.cols, s.rows);
            s.unlockTerminal();
            return r.fail(.limit, try status.of(r.gpa, s), "cannot resize session {d} to {d}x{d}: {s}", .{ s.id, req.cols, req.rows, budget.describe(&buf, asked) });
        },
        else => return r.failSession(s, err),
    };
    r.reply(protocol.ResizeResp{ .resize_seq = seq, .status = try status.of(r.gpa, s) });
}

fn renameSession(r: *Request) !void {
    const req = try r.decode(protocol.RenameReq) orelse return;
    if (req.name.len > 0) if (names.nameError(req.name)) |why| return r.fail(.bad_request, null, "invalid session name '{s}': {s}", .{ req.name, why });
    const id = try r.resolve(req.session) orelse return;
    // Before the reference: see Session.rename.
    const io = io_mod.io();
    spawn.spawn_mutex.lockUncancelable(io);
    defer spawn.spawn_mutex.unlock(io);
    const s = try r.acquireId(id) orelse return;
    defer session.release(s);
    s.rename(req.name) catch |err| switch (err) {
        error.NameTaken => {
            const namesake = registry.acquireRunningNamed(req.name);
            defer if (namesake) |n| session.release(n);
            const st = if (namesake) |n| try status.of(r.gpa, n) else null;
            return r.fail(.exists, st, "the running session '{s}' has that name; stop it first, or choose another name", .{req.name});
        },
        else => return err,
    };
    try r.replyStatus(s);
}

fn input(r: *Request) !void {
    r.input = true;
    const req = try r.decode(protocol.InputReq) orelse return;
    const plans = switch (try batch.check(r.gpa, req.steps)) {
        .plans => |plans| plans,
        .bad => |why| return r.fail(.bad_request, null, "bad input request: {s}", .{why}),
    };
    if (req.require.hidden_input and builtin.os.tag == .windows) return r.fail(.unsupported, null, "require.hidden_input is not supported on Windows", .{});
    if (req.require.prompt != null) if (batch.promptTextError(req.steps)) |why| {
        const id = try r.resolve(req.session) orelse return;
        return r.reply(protocol.InputFailure{ .code = .guard, .err = try std.fmt.allocPrint(r.gpa, "{s}; nothing was typed", .{why}), .status = try registry.statusOf(r.gpa, id), .guard = "prompt" });
    };
    if (req.until) |until| {
        const timeout_ms = req.timeout_ms orelse return r.fail(.bad_request, null, "bad input request: until needs timeout_ms", .{});
        if (try r.badUntil(until, timeout_ms)) return;
        for (until, 0..) |c, i| if (c.after_input) |after| if (after == .seq) {
            return r.fail(.bad_request, null, "bad input request: until[{d}] waits after this input; give after_input \"latest\"", .{i});
        };
    } else if (req.timeout_ms != null) return r.fail(.bad_request, null, "bad input request: timeout_ms needs until", .{});
    const s = try r.acquireSession(req.session) orelse return;
    var held = true;
    defer if (held) session.release(s);
    const w: ?*evaluator.Waiter = if (req.until) |until|
        try r.openWait(s, .{ .until = until, .timeout_ms = req.timeout_ms.?, .bundled = true }) orelse return
    else
        null;
    var waiting = w != null;
    defer if (waiting) Request.dropWait(w.?);
    const client: ?std.posix.fd_t = if (builtin.os.tag == .windows) null else r.conn.posix.socket.handle;
    const out = batch.run(s, r.gpa, plans, .{ .require = req.require, .client = client, .waiter = w });
    if (out.registered and (out.hung_up or out.err != null or out.guard != null)) evaluator.withdraw(s, w.?);
    if (out.hung_up) {
        r.replied = true;
        return;
    }
    if (out.guard) |guard| {
        const err = switch (guard) {
            .unattended => try std.fmt.allocPrint(r.gpa, "session {d} has a writer attached; nothing was typed", .{s.id}),
            .input_seq => try std.fmt.allocPrint(r.gpa, "input_seq {d} is not the latest input of session {d}, which is {d}; nothing was typed", .{ req.require.input_seq.?, s.id, s.track.input_seq.load(.acquire) }),
            .hidden_input => try std.fmt.allocPrint(r.gpa, "session {d} is not reading hidden input (no password prompt), so this input was not typed", .{s.id}),
            .hit_seq => try std.fmt.allocPrint(r.gpa, "hit {d} is not the latest hit of session {d}; nothing was typed", .{ req.require.hit_seq.?, s.id }),
            .reply_to => try std.fmt.allocPrint(r.gpa, "hit {d} of session {d} was answered already, or is no longer kept; nothing was typed", .{ req.require.reply_to.?, s.id }),
            .prompt => try std.fmt.allocPrint(r.gpa, "session {d}: {s}; nothing was typed", .{ s.id, out.prompt_why }),
        };
        return r.reply(protocol.InputFailure{ .code = .guard, .err = err, .status = try status.of(r.gpa, s), .guard = @tagName(guard) });
    }
    if (out.err) |err| {
        const why = sessionError(err);
        const text = if (out.key.len == 0) why.text else switch (err) {
            error.KeyNotEncodable => try std.fmt.allocPrint(r.gpa, "the program's keyboard mode cannot express the key '{s}'", .{out.key}),
            error.KeyNeedsKittyProtocol => try std.fmt.allocPrint(r.gpa, "the key '{s}' needs the kitty keyboard protocol, which the program has not enabled", .{out.key}),
            else => why.text,
        };
        return r.reply(protocol.InputFailure{ .code = why.code, .err = text, .status = try status.of(r.gpa, s), .done = out.done });
    }
    r.reply(protocol.InputResp{ .done = out.done, .status = try status.of(r.gpa, s) });
    if (w) |waiter| {
        waiting = false;
        held = false;
        return r.awaitAnswer(s, waiter, out.registered);
    }
}

fn recordRequest(r: *Request) !void {
    const req = try r.decode(protocol.RecordReq) orelse return;
    const given = @as(u8, @intFromBool(req.start != null)) + @intFromBool(req.mark != null) + @intFromBool(req.stop);
    if (given != 1) return r.fail(.bad_request, null, "bad record request: give exactly one of start, mark, and stop (true)", .{});
    if (req.start) |start| {
        if (start.path) |path| if (hasNul(path) or !std.fs.path.isAbsolute(path)) return r.fail(.bad_request, null, "recording path must be absolute, without NUL bytes", .{});
        if (start.until) |until| if (try cond.problem(r.gpa, until)) |why| return r.fail(.bad_request, null, "bad record request: start.{s}", .{why});
        if (start.max_ms) |ms| if (ms == 0 or ms > max_record_ms) return r.fail(.bad_request, null, "bad record request: start.max_ms must be 1..{d} (a day)", .{max_record_ms});
        if (start.until) |until| if (r.unsupportedUntil(until)) return;
    }
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    if (req.start) |start| {
        const until = start.until orelse &.{};
        if (try r.staleUntil(s, until)) return;
        if (try r.unknownAlert(s, until)) return;
        const shown = start.path orelse "in the session's directory";
        var why: []const u8 = "the system refused to open it";
        session.startRecording(s, .{ .path = start.path, .format = start.format, .input = start.input, .passwords = start.passwords orelse false, .until = until, .max_ms = start.max_ms, .why = &why }) catch |err| {
            const st = try status.of(r.gpa, s);
            return switch (err) {
                error.CantOpenFile => if (start.path != null)
                    r.fail(.bad_request, st, "cannot start recording '{s}': cannot create the file: {s}", .{ shown, why })
                else
                    r.fail(.internal, st, "cannot start recording: cannot create the file in the session's directory: {s}", .{why}),
                error.AlreadyRecording => r.fail(.busy, st, "cannot start recording: a recording is already active (stop it with 'tuppet record {d} --stop')", .{s.id}),
                error.SessionExited => r.fail(.ended, st, "cannot start recording: the session has ended", .{}),
                error.OutOfMemory => r.fail(.internal, st, "out of memory", .{}),
                else => r.fail(.internal, st, "cannot start recording: {s}", .{@errorName(err)}),
            };
        };
    } else if (req.mark) |label| {
        session.recordMark(s, label) catch |err| return r.failNotRecording(s, err);
    } else {
        const stopped = session.stopRequested(s, r.gpa) catch |err| return r.failNotRecording(s, err);
        return r.reply(protocol.RecordResp{ .reason = stopped.reason, .path = stopped.path, .status = try status.of(r.gpa, s) });
    }
    const rec = try session.latestRecording(s, r.gpa);
    r.reply(protocol.RecordResp{ .active = rec.active, .reason = rec.reason, .path = rec.path, .status = try status.of(r.gpa, s) });
}

fn alertRequest(r: *Request) !void {
    const req = try r.decode(protocol.AlertReq) orelse return;
    const given = @as(u8, @intFromBool(req.add != null)) + @intFromBool(req.remove != null) + @intFromBool(req.list);
    if (given != 1) return r.fail(.bad_request, null, "bad alert request: give exactly one of add, remove, and list (true)", .{});
    if (req.add) |rule| if (alert.ruleError(rule)) |why| return r.fail(.bad_request, null, "bad alert request: alert '{s}': {s}", .{ rule.name, why });
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    const io = io_mod.io();
    s.alert_mutex.lockUncancelable(io);
    defer s.alert_mutex.unlock(io);
    var failed: ?anyerror = null;
    var settled = false;
    const rules = blk: {
        s.lockTerminal();
        defer s.unlockTerminal();
        settled = s.track.unsettled();
        if (settled) s.track.settle(&s.terminal, io_mod.nowNanos());
        if (req.add) |rule| {
            if (s.track.addAlert(&s.terminal, rule)) |slot| s.hits.forget(slot) else |err| failed = err;
        } else if (req.remove) |name| {
            if (s.track.removeAlert(name)) |slot| s.hits.forget(slot) else failed = error.NoAlert;
        }
        const rules = try s.track.alerts().rules(r.gpa);
        for (rules) |*rule| rule.* = .{ .name = try r.gpa.dupe(u8, rule.name), .match = try r.gpa.dupe(u8, rule.match), .icase = rule.icase };
        break :blk rules;
    };
    if (settled) s.track.notify();
    if (failed) |err| {
        const st = try status.of(r.gpa, s);
        return switch (err) {
            error.Exists => r.fail(.exists, st, "session {d} has an alert named '{s}' already; remove it first", .{ s.id, req.add.?.name }),
            error.Limit => r.fail(.limit, st, "session {d} has {d} alerts, the most it takes", .{ s.id, alert.max_alerts }),
            error.NoAlert => r.fail(.no_alert, st, "session {d} has no alert named '{s}'", .{ s.id, req.remove.? }),
            else => err,
        };
    }
    if (!req.list) store.setAlerts(r.gpa, s.id, rules) catch |err| std.log.err("session {d}: cannot save its alerts: {}", .{ s.id, err });
    r.reply(protocol.AlertResp{ .alerts = rules, .status = try status.of(r.gpa, s) });
}

/// A recording may run this long at most with max_ms.
const max_record_ms: u64 = 24 * std.time.ms_per_hour;

/// What one reference of a stop or remove picked: a session, or nothing,
/// with the failed result that says so.
const Target = union(enum) {
    session: struct { ref: []const u8, id: u64 },
    missing: protocol.Result,
};

/// Resolve the references of a stop or remove: each session once, in the
/// order the references pick them, and each reference once. Patterns pick
/// only what `filter` admits; a reference that picks nothing at all is a
/// failed result.
fn pickMany(r: *Request, refs: []const []const u8, filter: names.Filter) !?[]Target {
    if (r.tooManyRefs(refs)) return null;
    for (refs) |ref| if (names.refError(ref)) |why| {
        r.fail(.bad_request, null, "invalid session '{s}': {s}", .{ ref, why });
        return null;
    };
    var given: std.StringHashMapUnmanaged(void) = .empty;
    var picked: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var targets: std.ArrayList(Target) = .empty;
    for (refs) |ref| {
        if ((try given.getOrPut(r.gpa, ref)).found_existing) continue;
        if (names.kind(ref) == .id) {
            const id = protocol.parseDecimal(u64, ref).?;
            if (!registry.exists(id)) {
                const missing = try registry.missingReason(r.gpa, id);
                try targets.append(r.gpa, .{ .missing = .{ .ref = ref, .id = id, .code = missing.code, .err = missing.err } });
            } else if (!(try picked.getOrPut(r.gpa, id)).found_existing) {
                try targets.append(r.gpa, .{ .session = .{ .ref = ref, .id = id } });
            }
            continue;
        }
        const all = try registry.pick(r.gpa, ref, .any);
        if (all.len == 0) {
            try targets.append(r.gpa, .{ .missing = .{ .ref = ref, .code = .no_session, .err = try names.noMatch(r.gpa, ref) } });
            continue;
        }
        const admitted = if (names.kind(ref) == .pattern) try registry.pick(r.gpa, ref, filter) else all;
        for (admitted) |id| if (!(try picked.getOrPut(r.gpa, id)).found_existing) try targets.append(r.gpa, .{ .session = .{ .ref = ref, .id = id } });
    }
    return targets.items;
}

fn stop(r: *Request) !void {
    const req = try r.decode(protocol.StopReq) orelse return;
    const targets = try pickMany(r, req.sessions, .running) orelse return;
    // A name or id may pick a session that has ended already.
    const was_running = try r.gpa.alloc(bool, targets.len);
    for (targets, was_running) |t, *running| running.* = t == .session and registry.isRunning(t.session.id);
    const outcomes = try stopRunning(r.gpa, targets, was_running);
    const results = try r.gpa.alloc(protocol.Result, targets.len);
    for (targets, was_running, outcomes, results) |t, running, outcome, *result| {
        const p = switch (t) {
            .missing => |m| {
                result.* = m;
                continue;
            },
            .session => |p| p,
        };
        const st = try registry.statusOf(r.gpa, p.id);
        result.* = if (!running) .{
            .ref = p.ref,
            .id = p.id,
            .code = .ended,
            .err = try std.fmt.allocPrint(r.gpa, "session {d} has ended already", .{p.id}),
            .status = st,
        } else if (outcome) |err| .{
            .ref = p.ref,
            .id = p.id,
            .code = sessionError(err).code,
            .err = try std.fmt.allocPrint(r.gpa, "cannot stop session {d}: {s}", .{ p.id, sessionError(err).text }),
            .status = st,
        } else .{ .ref = p.ref, .id = p.id, .ok = true, .status = st };
    }
    r.reply(protocol.ResultsResp{ .results = results });
}

/// Stop the targets marked in `which`, all at once: each may take its
/// grace period. The outcomes line up with `targets`.
fn stopRunning(gpa: std.mem.Allocator, targets: []const Target, which: []const bool) ![]?anyerror {
    const outcomes = try gpa.alloc(?anyerror, targets.len);
    @memset(outcomes, null);
    const threads = try gpa.alloc(?std.Thread, targets.len);
    @memset(threads, null);
    for (targets, which, threads, outcomes) |t, wanted, *thread, *outcome| {
        if (!wanted) continue;
        thread.* = std.Thread.spawn(.{}, stopOne, .{ t.session.id, outcome }) catch blk: {
            stopOne(t.session.id, outcome);
            break :blk null;
        };
    }
    for (threads) |thread| if (thread) |th| th.join();
    return outcomes;
}

fn stopOne(id: u64, outcome: *?anyerror) void {
    const s = session.acquire(id) orelse return;
    defer session.release(s);
    s.stop() catch |err| {
        outcome.* = err;
    };
}

fn remove(r: *Request) !void {
    const req = try r.decode(protocol.RemoveReq) orelse return;
    const targets = try pickMany(r, req.sessions, if (req.force) .any else .ended) orelse return;
    const running = try r.gpa.alloc(bool, targets.len);
    for (targets, running) |t, *is_running| is_running.* = req.force and t == .session and registry.isRunning(t.session.id);
    const outcomes = try stopRunning(r.gpa, targets, running);
    const results = try r.gpa.alloc(protocol.Result, targets.len);
    for (targets, outcomes, results) |t, stop_outcome, *result| {
        const p = switch (t) {
            .missing => |m| {
                result.* = m;
                continue;
            },
            .session => |p| p,
        };
        var outcome = stop_outcome;
        const st = try registry.statusOf(r.gpa, p.id);
        if (outcome == null) session.remove(p.id) catch |err| {
            outcome = err;
        };
        const err = outcome orelse {
            result.* = .{ .ref = p.ref, .id = p.id, .ok = true, .status = st };
            continue;
        };
        const code: protocol.Code, const text = switch (err) {
            error.StillRunning => .{ .running, try std.fmt.allocPrint(r.gpa, "session {d} is still running; stop it first, or stop and remove it at once with 'tuppet remove -f {d}'", .{ p.id, p.id }) },
            error.NoSession => .{ .no_session, try std.fmt.allocPrint(r.gpa, "no session with id {d}", .{p.id}) },
            else => .{ sessionError(err).code, try std.fmt.allocPrint(r.gpa, "cannot stop session {d}: {s}", .{ p.id, sessionError(err).text }) },
        };
        result.* = .{ .ref = p.ref, .id = p.id, .code = code, .err = text, .status = st };
    }
    r.reply(protocol.ResultsResp{ .results = results });
}

fn ack(r: *Request) !void {
    const req = try r.decode(protocol.AckReq) orelse return;
    const targets = try pickMany(r, req.sessions, .any) orelse return;
    const results = try r.gpa.alloc(protocol.Result, targets.len);
    for (targets, results) |t, *result| {
        const p = switch (t) {
            .missing => |m| {
                result.* = m;
                continue;
            },
            .session => |p| p,
        };
        registry.ack(r.gpa, p.id, req.shown) catch {
            result.* = .{ .ref = p.ref, .id = p.id, .code = .no_session, .err = try std.fmt.allocPrint(r.gpa, "no session with id {d}", .{p.id}) };
            continue;
        };
        result.* = .{ .ref = p.ref, .id = p.id, .ok = true, .status = try registry.statusOf(r.gpa, p.id) };
    }
    r.reply(protocol.ResultsResp{ .results = results });
}

fn update(r: *Request) !void {
    const req = try r.decode(protocol.UpdateReq) orelse return;
    // Before the reference: a respawn that holds the lock waits for the
    // references on the session it replaces.
    member.lock();
    defer member.unlock();
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    const old = try s.memberOf(r.gpa);
    if (req.group != null and old.side_of != null) return r.fail(.bad_request, try status.of(r.gpa, s), "session {d} is a side session, which belongs to the session it is tied to; it takes no group", .{s.id});
    if (req.group != null and s.over != null) return r.fail(.bad_request, try status.of(r.gpa, s), "session {d} is a box, which belongs to the session it is shown over; it takes no group", .{s.id});
    var m = switch (try member.apply(r.gpa, old, .{ .group = req.group, .label = req.label, .accent = req.accent, .mark = req.mark, .meta = req.meta, .actions = req.actions })) {
        .ok => |m| m,
        .bad => |why| return r.fail(.bad_request, try status.of(r.gpa, s), "bad update request: {s}", .{why}),
    };
    if (m.group) |g| if (m.number == null) {
        m.number = try member.nextNumber(r.gpa, g);
    };
    try member.set(s, m);
    try r.replyStatus(s);
}

/// The side session `s` is, or the running one tied to it.
fn sideSession(s: *session.Session, m: status.Member) ?*session.Session {
    if (m.side_of != null) {
        _ = registry.acquireLoaded(s.id) orelse return null;
        return s;
    }
    return registry.acquireLoaded(member.sideOf(s) orelse return null);
}

fn side(r: *Request) !void {
    const req = try r.decode(protocol.SideReq) orelse return;
    if ((req.view != null) == req.request) return r.fail(.bad_request, null, "bad side request: give view or request, one of them", .{});
    member.lock();
    defer member.unlock();
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    const m = try s.memberOf(r.gpa);
    const found = sideSession(s, m);
    if (req.request) {
        if (found) |f| {
            session.release(f);
            return r.fail(.bad_request, try status.of(r.gpa, s), "session {d} {s} a side session; set its view instead", .{ s.id, if (m.side_of != null) "is" else "has" });
        }
        events.publish(s.id, .side_requested, .{});
        return r.replyStatus(s);
    }
    const sd = found orelse return r.fail(.bad_request, try status.of(r.gpa, s), "session {d} has no side session", .{s.id});
    defer session.release(sd);
    var sm = try sd.memberOf(r.gpa);
    sm.side_view = req.view;
    try member.set(sd, sm);
    try r.replyStatus(sd);
}

fn flag(r: *Request) !void {
    const req = try r.decode(protocol.FlagReq) orelse return;
    if ((req.attention != null) == req.clear) return r.fail(.bad_request, null, "bad flag request: give attention or clear, one of them", .{});
    member.lock();
    defer member.unlock();
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    var m = try s.memberOf(r.gpa);
    if (req.attention) |text| {
        const clean = try status.cleanText(r.gpa, text, member.max_attention);
        if (clean.len == 0) return r.fail(.bad_request, try status.of(r.gpa, s), "bad flag request: attention must not be empty", .{});
        m.attention = clean;
    } else m.attention = null;
    try member.set(s, m);
    try r.replyStatus(s);
}

fn action(r: *Request) !void {
    const req = try r.decode(protocol.ActionReq) orelse return;
    if (req.key.len != 1 or req.key[0] < 0x21 or req.key[0] > 0x7e) return r.fail(.bad_request, null, "bad action request: the key must be one printable ASCII character", .{});
    if (req.value) |v| {
        if (v.len > events.max_value) return r.fail(.bad_request, null, "bad action request: the value is longer than {d} bytes", .{events.max_value});
        if (!std.unicode.utf8ValidateSlice(v)) return r.fail(.bad_request, null, "bad action request: the value is not valid UTF-8", .{});
        for (v) |c| if (c < 0x20 or c == 0x7f) return r.fail(.bad_request, null, "bad action request: the value holds a control character", .{});
    }
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    events.publishAction(s.id, req.key[0], req.value);
    try r.replyStatus(s);
}

fn leaseRequest(r: *Request) !void {
    const req = try r.decode(protocol.LeaseReq) orelse return;
    if (builtin.os.tag != .linux) return r.fail(.unsupported, null, "leases are supported on Linux only", .{});
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    if (s.state.load(.acquire) == .exited) return r.fail(.ended, try status.of(r.gpa, s), "session {d} has ended; there is nothing to keep alive", .{s.id});
    try r.replyStatus(s);
    r.lease(s);
}

fn respawn(r: *Request) !void {
    const req = try r.decode(protocol.RespawnReq) orelse return;
    for (req.env, 0..) |entry, i| if (hasNul(entry) or std.mem.indexOfScalar(u8, entry, '=') == null) {
        return r.fail(.bad_request, null, "bad respawn request: env[{d}] must be NAME=value, without NUL bytes", .{i});
    };
    const id = try r.resolve(req.session) orelse return;
    // Read, and the reference dropped, before the start: it removes the
    // ended session, which waits for every reference on it.
    const old = try r.acquireId(id) orelse return;
    var released = false;
    defer if (!released) session.release(old);
    if (old.state.load(.acquire) != .exited) return r.fail(.running, try status.of(r.gpa, old), "session {d} is still running; respawn starts an ended session's program again", .{id});
    const t = try registry.templateOf(r.gpa, id) orelse return r.fail(.no_session, null, "no session with id {d}", .{id});
    const old_gpa = old.gpa;
    const seed = try old.screenBytes();
    defer old_gpa.free(seed);
    const kept = try old.memberOf(r.gpa);
    const colors = old.defaultColors();
    const side_id = member.sideOf(old);
    session.release(old);
    released = true;
    member.lock();
    defer member.unlock();
    const s = session.Session.start(r.persistent_gpa, .{
        .argv = t.argv,
        .cols = t.cols,
        .rows = t.rows,
        .cwd = if (t.cwd.len > 0) t.cwd else null,
        .name = t.name,
        .env = req.env,
        .scrollback = t.scrollback,
        .alerts = t.alerts,
        .colors = colors,
        .member = kept,
        .seed = seed,
    }) catch |err| return startFailed(r, .{ .argv = t.argv, .name = t.name, .cwd = t.cwd, .cols = t.cols, .rows = t.rows }, err);
    defer session.release(s);
    // An unnamed one is no namesake that the start removed.
    registry.remove(id) catch {};
    if (side_id) |sid| if (registry.acquireLoaded(sid)) |sd| {
        defer session.release(sd);
        var sm = try sd.memberOf(r.gpa);
        sm.side_of = s.id;
        try member.set(sd, sm);
        member.tie(s, sd);
    };
    // A side session that is respawned is tied to its session again.
    if (kept.side_of) |main_id| if (registry.acquireLoaded(main_id)) |main| {
        defer session.release(main);
        if (main.state.load(.acquire) == .running and member.sideOf(main) == null) member.tie(main, s);
    };
    registry.trimHistory();
    return replyRun(r, s);
}

fn commands(r: *Request) !void {
    const req = try r.decode(protocol.CommandsReq) orelse return;
    const last = req.last orelse marks.max_commands;
    if (last < 1 or last > marks.max_commands) return r.fail(.bad_request, null, "bad commands request: last must be 1..{d}", .{marks.max_commands});
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    const kept = blk: {
        s.lockTerminal();
        defer s.unlockTerminal();
        const found = s.marks.last(last);
        const out = try r.gpa.alloc(marks.Command, found.len);
        for (found, out) |c, *o| {
            o.* = c;
            o.command = try r.gpa.dupe(u8, c.command);
            o.output = try r.gpa.dupe(u8, c.output);
        }
        break :blk out;
    };
    r.reply(protocol.CommandsResp{ .commands = kept, .status = try status.of(r.gpa, s) });
}

fn eventsStream(r: *Request) !void {
    const req = try r.decode(protocol.EventsReq) orelse return;
    if (builtin.os.tag == .windows) return r.fail(.unsupported, null, "events are not supported on Windows", .{});
    const given = req.sessions orelse &.{};
    if (r.tooManyRefs(given)) return;
    for (given) |ref| if (names.refError(ref)) |why| return r.fail(.bad_request, null, "invalid session '{s}': {s}", .{ ref, why });
    if (req.idle_ms) |ms| if (ms < 1 or ms > events.max_idle_ms) return r.fail(.bad_request, null, "bad events request: idle_ms must be 1..{d} (a day)", .{events.max_idle_ms});
    if (open_streams.fetchAdd(1, .acq_rel) >= max_streams) {
        _ = open_streams.fetchSub(1, .acq_rel);
        return r.fail(.limit, null, "too many open waits and event streams (at most {d})", .{max_streams});
    }
    defer _ = open_streams.fetchSub(1, .acq_rel);
    r.releaseSlot();
    // The stream keeps only its references.
    const refs = try dupeAll(r.persistent_gpa, given);
    defer freeAll(r.persistent_gpa, refs);
    r.shed();
    const reply = try protocol.stringifyAlloc(r.gpa, protocol.EventsResp{ .boot = try store.bootLabel(r.gpa) });
    r.replied = true;
    events.serve(r.conn.posix.socket.handle, .{ .refs = refs, .idle_ms = req.idle_ms }, reply);
}

fn dupeAll(gpa: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, strings.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |text| gpa.free(text);
        gpa.free(out);
    }
    for (strings, out) |text, *copy| {
        copy.* = try gpa.dupe(u8, text);
        done += 1;
    }
    return out;
}

fn freeAll(gpa: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |text| gpa.free(text);
    gpa.free(strings);
}

fn attachStream(r: *Request) !void {
    const req = try r.decode(protocol.AttachReq) orelse return;
    if (builtin.os.tag == .windows) return r.fail(.unsupported, null, "attach is not supported on Windows", .{});
    if ((req.cols == null) != (req.rows == null)) return r.fail(.bad_request, null, "bad attach request: give cols and rows together", .{});
    if (req.cols) |cols| {
        if (req.mode != .write) return r.fail(.bad_request, null, "bad attach request: cols and rows go with mode write", .{});
        if (limits.sizeError(cols, req.rows.?)) |why| return r.fail(.bad_request, null, "invalid size {d}x{d} ({s})", .{ cols, req.rows.?, why });
    }
    if ((req.history orelse 0) > protocol.max_history_rows) return r.fail(.bad_request, null, "bad attach request: history must be 0 to {d} rows", .{protocol.max_history_rows});
    if (req.history_from != null and (req.history orelse 0) == 0) return r.fail(.bad_request, null, "bad attach request: history_from goes with a history of 1 or more rows", .{});
    const s = try r.acquireSession(req.session) orelse return;
    defer session.release(s);
    _ = open_attaches.fetchAdd(1, .acq_rel);
    defer _ = open_attaches.fetchSub(1, .acq_rel);
    r.releaseSlot();
    // The stream keeps only its label and the frames that came along.
    var kept = req;
    kept.session = "";
    kept.label = if (req.label) |label| try r.persistent_gpa.dupe(u8, label) else null;
    defer if (kept.label) |label| r.persistent_gpa.free(label);
    const rest = try r.persistent_gpa.dupe(u8, r.rest);
    defer r.persistent_gpa.free(rest);
    r.shed();
    attach.serve(r.persistent_gpa, r.conn, s, kept, rest) catch |err| {
        const st = status.of(r.gpa, s) catch null;
        return switch (err) {
            error.WriterAttached => r.fail(.busy, st, "session {d} already has a writer ('tuppet attach -f {d}' takes over)", .{ s.id, s.id }),
            error.TooManyViewers => r.fail(.limit, st, "too many attached clients", .{}),
            error.ViewersBehind => r.fail(.limit, st, "the attached clients have too much output waiting to be read; try again once they catch up", .{}),
            else => err,
        };
    };
    r.replied = true;
}

const RenderedPng = struct {
    png: []const u8,
    renderer: []const u8,
    cell: []const u8,
    faces: []const []const u8,
};

/// What a render too large for the render limit was asked to draw.
const Oversize = struct { cols: u16, rows: u16, cell: fonts.Cell };

/// Only drawing holds the terminal lock; compression runs after it, so
/// the session keeps processing output meanwhile. Drawing may unpack a
/// built-in font on its first need, which holds the lock for up to a few
/// tens of milliseconds, once per daemon. The caller holds png_render_lock.
fn renderSessionPng(gpa: std.mem.Allocator, persistent_gpa: std.mem.Allocator, s: *session.Session, settings: fonts.Settings, diag: *fonts.Diagnostic, oversize: *Oversize) !RenderedPng {
    if (png_fonts == null) png_fonts = .init(persistent_gpa, io_mod.io());
    var chain = try png_fonts.?.resolve(settings, diag);
    s.lockTerminal();
    const image = drawn: {
        defer s.unlockTerminal();
        oversize.* = .{ .cols = s.cols, .rows = s.rows, .cell = chain.cell };
        // A session's size is never 0, so this only fails beyond any limit.
        const max_png_size = render.maxPngSize(s.cols, s.rows, chain.cell) catch return error.ImageTooLarge;
        if (max_png_size > limits.max_png_render_bytes) return error.ImageTooLarge;
        break :drawn try render.renderImage(gpa, &s.terminal, &chain);
    };
    defer gpa.free(image.pixels);
    return .{
        .png = try render.encodePng(gpa, image),
        .renderer = chain.renderer(),
        .cell = try std.fmt.allocPrint(gpa, "{d}x{d}", .{ chain.cell.width, chain.cell.height }),
        .faces = try chain.usedFaces(gpa),
    };
}

/// The code and readable text for a failed session operation; raw error
/// names are a last resort.
fn sessionError(err: anyerror) struct { code: protocol.Code, text: []const u8 } {
    return switch (err) {
        error.SessionExited => .{ .code = .ended, .text = "the session has ended" },
        error.WriteFailed => .{ .code = .internal, .text = "cannot write to the session's pty" },
        error.InputStalled => .{ .code = .stalled, .text = "the session stopped reading its input (no progress for 5 s); part of the input may have been delivered" },
        error.InputBusy => .{ .code = .busy, .text = "another input to this session is stalled; nothing was sent" },
        error.ResizeFailed => .{ .code = .internal, .text = "cannot resize the session's pty" },
        error.BatchBusy => .{ .code = .busy, .text = "another input batch is running on this session; nothing was typed" },
        error.BatchTooSlow => .{ .code = .stalled, .text = "the input took longer than 5 s to write; part of it may have been delivered" },
        error.BatchQueued => .{ .code = .stalled, .text = "another input held the session for 5 s; nothing was typed" },
        error.CoordinatesOutsideGrid => .{ .code = .bad_request, .text = "a mouse step lies outside the session's grid" },
        error.KeyNotEncodable => .{ .code = .unsupported, .text = "the program's keyboard mode cannot express a key" },
        error.KeyNeedsKittyProtocol => .{ .code = .unsupported, .text = "a key needs the kitty keyboard protocol, which the program has not enabled" },
        error.MouseEventNotReportable => .{ .code = .unsupported, .text = "the program's mouse mode cannot report this event (button, action, or position)" },
        error.StopTimeout => .{ .code = .internal, .text = "the session did not exit within 3 s after SIGKILL" },
        error.SaveTimeout => .{ .code = .internal, .text = "the program ended, but saving the session's results took more than 5 s" },
        error.SizeOutOfRange => .{ .code = .bad_request, .text = "the size is outside " ++ limits.size_range ++ " cells per side" },
        error.OverBudget => .{ .code = .limit, .text = "the new size does not fit the daemon's memory budget (TUPPET_MEMORY)" },
        else => .{ .code = .internal, .text = @errorName(err) },
    };
}
