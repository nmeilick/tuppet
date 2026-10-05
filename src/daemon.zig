//! The tuppet daemon: owns the unix socket and dispatches JSON-lines
//! requests to the session registry.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const store = @import("store.zig");
const session = @import("session.zig");
const mouse = @import("mouse.zig");
const render = @import("render.zig");
const attach = @import("attach.zig");
const vt = @import("vt");

const max_connections = 32;
const max_scrollback: u64 = 1 << 30;
/// How long a daemon without --socket waits, with no sessions and no
/// clients, before it exits; TUPPET_IDLE_EXIT overrides it, and 0 keeps the
/// daemon running.
const default_idle_exit_seconds = 30;

fn idleExitSeconds() u32 {
    const value = std.mem.span(std.c.getenv("TUPPET_IDLE_EXIT") orelse return default_idle_exit_seconds);
    return protocol.parseDecimal(u32, value) orelse {
        std.log.warn("ignoring TUPPET_IDLE_EXIT={s}: not a number of seconds", .{value});
        return default_idle_exit_seconds;
    };
}
const max_response_line = (1 << 24) - 1;
const max_png_render_size = 128 << 20;
const png_response_overhead = 128;
var active_connections: std.atomic.Value(usize) = .{ .raw = 0 };
var png_render_lock: std.Io.Mutex = .init;

/// How the daemon was started. With `socket` set it is supervised: it
/// listens on exactly that path, stops every session and exits on
/// SIGTERM or SIGINT, and (on Linux) its session children die with it.
pub const Options = struct {
    socket: ?[]const u8 = null,
    /// Supervised mode only: append the daemon's log here.
    log: ?[]const u8 = null,
};

pub fn run(gpa: std.mem.Allocator, opts: Options) !void {
    prepareProcess();
    if (opts.socket != null) try superviseSetup(opts);

    var path_buf: [ipc.max_path_len:0]u8 = undefined;
    const path = if (opts.socket) |p|
        std.fmt.bufPrintZ(&path_buf, "{s}", .{p}) catch return error.SocketPathTooLong
    else
        try ipc.socketPath(&path_buf);
    var server = try ipc.listen(path);
    defer server.deinit();
    store.open(gpa) catch |err| {
        std.log.err("cannot use the session store in {s}: {s}", .{ store.rootDir(), @errorName(err) });
        return error.StoreUnavailable;
    };
    session.init(gpa, path);
    _ = try std.Thread.spawn(.{}, housekeep, .{gpa});
    if (opts.socket != null) {
        // Only now: startup failures above still reach the terminal.
        if (opts.log) |log_path| try redirectLog(log_path);
        shutdown_server = &server;
        _ = try std.Thread.spawn(.{}, shutdownOnSignal, .{});
    }

    std.log.info("tuppet daemon listening on {s}", .{path});

    // A supervised daemon lives as long as its supervisor wants.
    const idle_exit: u32 = if (opts.socket == null and builtin.os.tag != .windows) idleExitSeconds() else 0;
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

/// Ended sessions stay in the store this long unless TUPPET_KEEP says
/// otherwise.
const default_keep_ms: i64 = 7 * std.time.ms_per_day;

/// TUPPET_KEEP: a number with s, m, h, or d, or 0 to keep sessions until
/// they are removed.
fn keepMillis() ?i64 {
    const value = std.mem.span(std.c.getenv("TUPPET_KEEP") orelse return default_keep_ms);
    return parseKeep(value) catch {
        std.log.warn("ignoring TUPPET_KEEP={s}: expected a number with s, m, h, or d, or 0", .{value});
        return default_keep_ms;
    };
}

fn parseKeep(value: []const u8) !?i64 {
    if (std.mem.eql(u8, value, "0")) return null;
    if (value.len < 2) return error.Invalid;
    const unit: i64 = switch (value[value.len - 1]) {
        's' => std.time.ms_per_s,
        'm' => std.time.ms_per_min,
        'h' => std.time.ms_per_hour,
        'd' => std.time.ms_per_day,
        else => return error.Invalid,
    };
    const n = protocol.parseDecimal(u32, value[0 .. value.len - 1]) orelse return error.Invalid;
    if (n == 0) return null;
    return @as(i64, n) * unit;
}

test "TUPPET_KEEP accepts a count with a unit, or 0" {
    try std.testing.expectEqual(@as(?i64, 90 * std.time.ms_per_min), try parseKeep("90m"));
    try std.testing.expectEqual(@as(?i64, 7 * std.time.ms_per_day), try parseKeep("7d"));
    try std.testing.expectEqual(@as(?i64, null), try parseKeep("0"));
    try std.testing.expectError(error.Invalid, parseKeep("7"));
    try std.testing.expectError(error.Invalid, parseKeep("-1d"));
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

/// Wait until a client connects. After `idle_seconds` without sessions or
/// clients, exit instead: closing the listener resets the connections
/// still queued on it, which the daemon has not read, and their clients
/// retry against the next daemon they start.
fn waitForClient(server: *ipc.Server, idle_seconds: u32) void {
    const fd = server.posix.listener.socket.handle;
    const limit_ns = @as(i64, idle_seconds) * std.time.ns_per_s;
    // Idle time counts from the last client or session.
    var idle_since = io_mod.nowNanos();
    while (true) {
        const left_ms = @divTrunc(limit_ns - (io_mod.nowNanos() - idle_since), std.time.ns_per_ms);
        var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&pfd, 1, @intCast(std.math.clamp(left_ms, 1, 1000)));
        if (ready > 0) return;
        if (ready < 0) continue;
        if (session.unsettledCount() > 0 or active_connections.load(.acquire) > 0) {
            idle_since = io_mod.nowNanos();
        } else if (io_mod.nowNanos() - idle_since >= limit_ns) {
            std.log.info("no sessions for {d} s; exiting", .{idle_seconds});
            server.deinit();
            std.process.exit(0);
        }
    }
}

var shutdown_server: ?*ipc.Server = null;
var shutdown_signals: std.c.sigset_t = undefined;

/// Supervised mode, before any thread starts: mark sessions supervised,
/// and block SIGTERM/SIGINT in every thread so only `shutdownOnSignal`
/// receives them. Session children reset their signal mask before exec.
fn superviseSetup(opts: Options) !void {
    _ = opts;
    session.supervised = true;
    if (builtin.os.tag == .windows) return;
    _ = std.c.sigemptyset(&shutdown_signals);
    _ = std.c.sigaddset(&shutdown_signals, std.posix.SIG.TERM);
    _ = std.c.sigaddset(&shutdown_signals, std.posix.SIG.INT);
    _ = std.c.sigprocmask(std.c.SIG.BLOCK, &shutdown_signals, null);
}

/// Supervised mode: append the daemon's stderr to `log_path`.
fn redirectLog(log_path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{log_path}) catch return error.LogPathTooLong;
    const fd = std.c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.CannotOpenLog;
    _ = std.c.dup2(fd, 2);
    _ = std.c.close(fd);
}

/// Supervised mode: on SIGTERM or SIGINT, stop every session (as
/// `tuppet stop` does, all at once), remove the endpoint, and exit.
fn shutdownOnSignal() void {
    if (builtin.os.tag == .windows) return;
    var sig: c_int = 0;
    while (std.c.sigwait(&shutdown_signals, &sig) != 0) {}
    std.log.info("signal {d}: stopping all sessions", .{sig});
    const gpa = std.heap.page_allocator;
    if (session.acquireAll(gpa)) |sessions| {
        defer session.releaseAll(gpa, sessions);
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(gpa);
        for (sessions) |s| {
            const t = std.Thread.spawn(.{}, stopQuietly, .{s}) catch {
                stopQuietly(s);
                continue;
            };
            threads.append(gpa, t) catch t.join();
        }
        for (threads.items) |t| t.join();
    } else |_| {}
    if (shutdown_server) |server| server.deinit();
    std.process.exit(0);
}

fn stopQuietly(s: *session.Session) void {
    s.stop() catch {};
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
}

fn handleConnection(persistent_gpa: std.mem.Allocator, owned_conn: ipc.Conn) void {
    defer _ = active_connections.fetchSub(1, .acq_rel);
    var conn = owned_conn;
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(persistent_gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    // This one-shot loop lets every validation branch share the same cleanup.
    var handling = true;
    while (handling) : (handling = false) {
        const io = io_mod.io();
        // An attach client may send frames right behind its request;
        // `rest` keeps them for the stream.
        const split = conn.recvLineSplit(gpa, 1 << 20) catch |err| {
            switch (err) {
                error.OutOfMemory => respondOutOfMemory(&conn),
                error.LineTooLong => conn.sendLine("{\"ok\":false,\"err\":\"request exceeds the 1 MiB limit\"}") catch {},
                error.ReadTimeout => conn.sendLine("{\"ok\":false,\"err\":\"request not received within 10 s\"}") catch {},
                error.Eof => {},
                else => std.log.err("read failed: {}", .{err}),
            }
            continue;
        };
        const line = split.line;
        if (line.len == 0) {
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "empty request" }) catch {};
            continue;
        }
        const n = line.len;

        const cmd = protocol.parseCommand(gpa, line[0..n]) catch |err| {
            const message: []const u8 = switch (err) {
                error.OutOfMemory => {
                    respondOutOfMemory(&conn);
                    continue;
                },
                error.RequestMustBeObject => "request must be an object",
                error.MissingCommand => "missing cmd",
                error.CommandMustBeString => "cmd must be a string",
                else => "bad json",
            };
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = message }) catch {};
            continue;
        };

        if (std.mem.eql(u8, cmd, "attach")) {
            // A stream, not a request: it must not hold one of the
            // request slots for its whole life.
            _ = active_connections.fetchSub(1, .acq_rel);
            defer _ = active_connections.fetchAdd(1, .acq_rel);
            attach.serve(gpa, &conn, line[0..n], split.rest);
        } else if (std.mem.eql(u8, cmd, "hello")) {
            _ = std.json.parseFromSliceLeaky(struct { cmd: []const u8 }, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "bad hello request" }) catch {};
                continue;
            };
            _ = respond(&conn, io, gpa, protocol.HelloResp{ .boot = store.bootId() }) catch {};
        } else if (std.mem.eql(u8, cmd, "run")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.RunReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.RunResp{ .ok = false, .err = "bad run request" }) catch {};
                continue;
            };
            if (r2.cols < 1 or r2.cols > 1000 or r2.rows < 1 or r2.rows > 1000) {
                invalidSize(&conn, io, gpa, protocol.RunResp, r2.cols, r2.rows);
                continue;
            }
            if (r2.argv.len == 0) {
                _ = respond(&conn, io, gpa, protocol.RunResp{ .ok = false, .err = "run requires a command" }) catch {};
                continue;
            }
            if (r2.cwd) |cwd| if (!std.fs.path.isAbsolute(cwd)) {
                _ = respond(&conn, io, gpa, protocol.RunResp{ .ok = false, .err = "cwd must be an absolute path" }) catch {};
                continue;
            };
            const scrollback = r2.scrollback orelse session.default_scrollback;
            if (scrollback > max_scrollback) {
                _ = respond(&conn, io, gpa, protocol.RunResp{ .ok = false, .err = "scrollback must be at most 1 GiB" }) catch {};
                continue;
            }
            var record: ?session.RunRecord = null;
            if (r2.record) |rec| {
                const format = std.meta.stringToEnum(session.RecordFormat, rec.format) orelse {
                    _ = respond(&conn, io, gpa, protocol.RunResp{ .ok = false, .err = "unknown recording format (choose cast or trace)" }) catch {};
                    continue;
                };
                if (rec.path) |p| if (!std.fs.path.isAbsolute(p)) {
                    _ = respond(&conn, io, gpa, protocol.RunResp{ .ok = false, .err = "recording path must be absolute" }) catch {};
                    continue;
                };
                record = .{ .path = rec.path, .format = format };
            }
            const s = session.Session.start(persistent_gpa, .{
                .argv = r2.argv,
                .cols = r2.cols,
                .rows = r2.rows,
                .cwd = r2.cwd,
                .name = r2.name orelse "",
                .env = r2.env,
                .scrollback = scrollback,
                .record = record,
            }) catch |err| {
                startFailed(&conn, io, gpa, r2, err);
                continue;
            };
            _ = respond(&conn, io, gpa, protocol.RunResp{ .ok = true, .id = s.id }) catch {};
        } else if (std.mem.eql(u8, cmd, "list")) {
            _ = std.json.parseFromSliceLeaky(struct { cmd: []const u8 }, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.ListResp{ .ok = false, .err = "bad list request" }) catch {};
                continue;
            };
            const sessions = session.acquireAll(gpa) catch {
                respondOutOfMemory(&conn);
                continue;
            };
            defer session.releaseAll(gpa, sessions);
            const infos = gpa.alloc(protocol.SessionInfo, sessions.len) catch {
                respondOutOfMemory(&conn);
                continue;
            };
            for (sessions, 0..) |s, i| {
                s.lockTerminal();
                const cols = s.cols;
                const rows = s.rows;
                const writer = s.writer != null;
                const viewers: u32 = @intCast(s.viewers.items.len - @intFromBool(writer));
                s.unlockTerminal();
                const exited = s.state.load(.acquire) == .exited;
                const ended = s.ended_ms.load(.acquire);
                infos[i] = .{
                    .id = s.id,
                    .name = s.name,
                    .state = @tagName(s.state.load(.acquire)),
                    .pid = @intCast(s.pid()),
                    .cols = cols,
                    .rows = rows,
                    .exit_code = if (exited) s.exit_code.load(.acquire) else null,
                    .argv = @ptrCast(s.argv),
                    .started_ms = s.started_ms,
                    .ended_ms = if (ended != 0) ended else null,
                    .writer = writer,
                    .viewers = viewers,
                };
            }
            // Ended sessions that only the store still has.
            const stored = session.storedInfos(gpa) catch {
                respondOutOfMemory(&conn);
                continue;
            };
            const all = std.mem.concat(gpa, protocol.SessionInfo, &.{ infos, stored }) catch {
                respondOutOfMemory(&conn);
                continue;
            };
            std.mem.sortUnstable(protocol.SessionInfo, all, {}, struct {
                fn lessThan(_: void, a: protocol.SessionInfo, b: protocol.SessionInfo) bool {
                    return a.id < b.id;
                }
            }.lessThan);
            _ = respond(&conn, io, gpa, protocol.ListResp{ .ok = true, .sessions = all }) catch {};
        } else if (std.mem.eql(u8, cmd, "send")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.SendReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "bad send request" }) catch {};
                continue;
            };
            const s = lookup(&conn, io, gpa, protocol.SendResp, r2.id) orelse continue;
            defer session.release(s);
            if (r2.paste) {
                const bracketed = s.paste(gpa, r2.data) catch |err| {
                    _ = respond(&conn, io, gpa, protocol.PasteResp{ .ok = false, .err = sessionErrorText(err) }) catch {};
                    continue;
                };
                _ = respond(&conn, io, gpa, protocol.PasteResp{ .ok = true, .bracketed = bracketed }) catch {};
                continue;
            }
            s.send(r2.data) catch |err| {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = sessionErrorText(err) }) catch {};
                continue;
            };
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = true }) catch {};
        } else if (std.mem.eql(u8, cmd, "key")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.KeyReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "bad key request" }) catch {};
                continue;
            };
            const s = lookup(&conn, io, gpa, protocol.SendResp, r2.id) orelse continue;
            defer session.release(s);
            s.sendKey(gpa, r2.keys) catch |err| {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = sessionErrorText(err) }) catch {};
                continue;
            };
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = true }) catch {};
        } else if (std.mem.eql(u8, cmd, "mouse")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.MouseReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "bad mouse request" }) catch {};
                continue;
            };
            const event = mouse.parseEvent(r2.button, r2.action, r2.mods) catch |err| {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = mouse.eventErrorText(err) }) catch {};
                continue;
            };
            const s = lookup(&conn, io, gpa, protocol.SendResp, r2.id) orelse continue;
            defer session.release(s);
            s.sendMouse(gpa, event.button, event.action, event.mods, r2.x, r2.y) catch |err| {
                if (err == error.CoordinatesOutsideGrid) {
                    s.lockTerminal();
                    const grid_cols = s.cols;
                    const grid_rows = s.rows;
                    s.unlockTerminal();
                    if (badValue(gpa, "mouse coordinates {d},{d} outside the {d}x{d} grid", .{ r2.x, r2.y, grid_cols, grid_rows })) |msg| {
                        defer gpa.free(msg);
                        _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = msg }) catch {};
                    }
                    continue;
                }
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = sessionErrorText(err) }) catch {};
                continue;
            };
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = true }) catch {};
        } else if (std.mem.eql(u8, cmd, "focus")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.FocusReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "bad focus request" }) catch {};
                continue;
            };
            const s = lookup(&conn, io, gpa, protocol.SendResp, r2.id) orelse continue;
            defer session.release(s);
            s.sendFocus(gpa, r2.focused) catch |err| {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = sessionErrorText(err) }) catch {};
                continue;
            };
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = true }) catch {};
        } else if (std.mem.eql(u8, cmd, "resize")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.ResizeReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "bad resize request" }) catch {};
                continue;
            };
            if (r2.cols < 1 or r2.cols > 1000 or r2.rows < 1 or r2.rows > 1000) {
                invalidSize(&conn, io, gpa, protocol.SendResp, r2.cols, r2.rows);
                continue;
            }
            const s = lookup(&conn, io, gpa, protocol.SendResp, r2.id) orelse continue;
            defer session.release(s);
            s.resize(r2.cols, r2.rows) catch |err| {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = sessionErrorText(err) }) catch {};
                continue;
            };
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = true }) catch {};
        } else if (std.mem.eql(u8, cmd, "record")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.RecordReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "bad record request" }) catch {};
                continue;
            };
            const s = lookup(&conn, io, gpa, protocol.RecordResp, r2.id) orelse continue;
            defer session.release(s);
            if (r2.mark) |label| {
                if (r2.path != null) {
                    _ = respond(&conn, io, gpa, protocol.RecordResp{ .ok = false, .err = "mark takes no path" }) catch {};
                    continue;
                }
                session.recordMark(s, label) catch |err| {
                    const message: []const u8 = switch (err) {
                        error.NotRecording => "no active recording",
                        else => "recording write failed",
                    };
                    _ = respond(&conn, io, gpa, protocol.RecordResp{ .ok = false, .err = message }) catch {};
                    continue;
                };
                _ = respond(&conn, io, gpa, protocol.RecordResp{ .ok = true, .active = true }) catch {};
            } else if (r2.path) |record_path| {
                if (!std.fs.path.isAbsolute(record_path)) {
                    _ = respond(&conn, io, gpa, protocol.RecordResp{ .ok = false, .err = "recording path must be absolute" }) catch {};
                    continue;
                }
                const format: session.RecordFormat = if (std.mem.eql(u8, r2.format, "cast"))
                    .cast
                else if (std.mem.eql(u8, r2.format, "trace"))
                    .trace
                else {
                    if (badValue(gpa, "unknown recording format '{s}' (choose cast or trace)", .{r2.format})) |msg| {
                        defer gpa.free(msg);
                        _ = respond(&conn, io, gpa, protocol.RecordResp{ .ok = false, .err = msg }) catch {};
                    }
                    continue;
                };
                session.startRecording(s, .{
                    .path = record_path,
                    .format = format,
                    .input = r2.input,
                    .until_match = r2.until_match,
                    .until_timeout_ms = r2.until_timeout_ms,
                }) catch |err| {
                    const reason: []const u8 = switch (err) {
                        error.CantOpenFile => "cannot create the file",
                        error.AlreadyRecording => "a recording is already active (stop it with 'tuppet record <id>')",
                        error.SessionExited => "session has exited",
                        else => @errorName(err),
                    };
                    if (badValue(gpa, "cannot start recording '{s}': {s}", .{ record_path, reason })) |msg| {
                        defer gpa.free(msg);
                        _ = respond(&conn, io, gpa, protocol.RecordResp{ .ok = false, .err = msg }) catch {};
                    }
                    continue;
                };
                // An until-match needle already on screen stops the
                // recording during start; report that accurately.
                _ = respond(&conn, io, gpa, protocol.RecordResp{ .ok = true, .active = s.recordingActive() }) catch {};
            } else {
                session.stopRecording(s);
                if (s.recordingFailed()) {
                    s.clearRecordingFailed();
                    _ = respond(&conn, io, gpa, protocol.RecordResp{
                        .ok = false,
                        .err = "recording write failed",
                    }) catch {};
                    continue;
                }
                const reason: ?[]const u8 = if (session.lastStopReason(s)) |r| @tagName(r) else null;
                _ = respond(&conn, io, gpa, protocol.RecordResp{ .ok = true, .active = false, .reason = reason }) catch {};
            }
        } else if (std.mem.eql(u8, cmd, "png")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.PngReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.PngResp{ .ok = false, .err = "bad png request" }) catch {};
                continue;
            };
            const s = lookup(&conn, io, gpa, protocol.PngResp, r2.id) orelse continue;
            defer session.release(s);

            // One render at a time bounds memory; the reply is sent
            // outside the lock so a slow reader cannot stall other renders.
            png_render_lock.lockUncancelable(io);
            const rendered_or_err = renderSessionPng(gpa, s);
            png_render_lock.unlock(io);
            const rendered = rendered_or_err catch |err| {
                const message = switch (err) {
                    error.ImageTooLarge => "PNG exceeds the 128 MiB render limit",
                    else => @errorName(err),
                };
                _ = respond(&conn, io, gpa, protocol.PngResp{ .ok = false, .err = message }) catch {};
                continue;
            };
            const png_bytes = rendered.bytes;
            const b64_len = std.base64.standard.Encoder.calcSize(png_bytes.len);
            if (b64_len > max_response_line - png_response_overhead) {
                _ = respond(&conn, io, gpa, protocol.PngResp{
                    .ok = false,
                    .err = "PNG exceeds the 16 MiB response limit",
                }) catch {};
                continue;
            }
            const b64 = gpa.alloc(u8, b64_len) catch {
                respondOutOfMemory(&conn);
                continue;
            };
            _ = std.base64.standard.Encoder.encode(b64, png_bytes);
            _ = respond(&conn, io, gpa, protocol.PngResp{
                .ok = true,
                .png_b64 = b64,
                .cols = rendered.cols,
                .rows = rendered.rows,
            }) catch {};
        } else if (std.mem.eql(u8, cmd, "view")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.ViewReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.ViewResp{ .ok = false, .err = "bad view request" }) catch {};
                continue;
            };
            const fmt: vt.formatter.Format = if (std.mem.eql(u8, r2.format, "vt"))
                .vt
            else if (std.mem.eql(u8, r2.format, "html"))
                .html
            else if (std.mem.eql(u8, r2.format, "plain") or std.mem.eql(u8, r2.format, "json"))
                .plain
            else {
                if (badValue(gpa, "unknown format '{s}' (choose plain, vt, html, or json)", .{r2.format})) |msg| {
                    defer gpa.free(msg);
                    _ = respond(&conn, io, gpa, protocol.ViewResp{ .ok = false, .err = msg }) catch {};
                }
                continue;
            };
            if (r2.scrollback and std.mem.eql(u8, r2.format, "json")) {
                _ = respond(&conn, io, gpa, protocol.ViewResp{ .ok = false, .err = "scrollback is not available with the json format" }) catch {};
                continue;
            }
            const s = lookup(&conn, io, gpa, protocol.ViewResp, r2.id) orelse continue;
            defer session.release(s);
            // Exit state first: a session is marked exited only after its
            // output is consumed, so the snapshot then holds all of it.
            const exited = s.state.load(.acquire) == .exited;
            const exit_code: ?i32 = if (exited) s.exit_code.load(.acquire) else null;
            const snapshot = s.viewSnapshot(gpa, fmt, if (r2.scrollback) .scrollback else .screen) catch |err| {
                _ = respond(&conn, io, gpa, protocol.ViewResp{ .ok = false, .err = sessionErrorText(err) }) catch {};
                continue;
            };
            // Real idle time even after exit: `tuppet wait --idle` must be
            // able to succeed on a finished session.
            const idle_ms: u64 = @intCast(@max(0, io_mod.nowNanos() - s.last_output.load(.acquire)) / std.time.ns_per_ms);
            _ = respond(&conn, io, gpa, protocol.ViewResp{
                .ok = true,
                .text = snapshot.text,
                .cols = snapshot.cols,
                .rows = snapshot.rows,
                .cursor_row = snapshot.cursor_row,
                .cursor_col = snapshot.cursor_col,
                .exited = exited,
                .exit_code = exit_code,
                .idle_ms = idle_ms,
                .recording = s.run_recording,
            }) catch {};
        } else if (std.mem.eql(u8, cmd, "stop")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.StopReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "bad stop request" }) catch {};
                continue;
            };
            const s = lookup(&conn, io, gpa, protocol.SendResp, r2.id) orelse continue;
            defer session.release(s);
            s.stop() catch |err| {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = sessionErrorText(err) }) catch {};
                continue;
            };
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = true }) catch {};
        } else if (std.mem.eql(u8, cmd, "remove")) {
            const r2 = std.json.parseFromSliceLeaky(protocol.RemoveReq, gpa, line[0..n], .{}) catch {
                _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "bad remove request" }) catch {};
                continue;
            };
            const id = protocol.parseDecimal(u64, r2.id) orelse {
                badId(&conn, io, gpa, protocol.SendResp, r2.id);
                continue;
            };
            session.remove(id) catch |err| switch (err) {
                error.NoSession => {
                    noSession(&conn, io, gpa, protocol.SendResp, id);
                    continue;
                },
                error.StillRunning => {
                    _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "session still running" }) catch {};
                    continue;
                },
            };
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = true }) catch {};
        } else {
            _ = respond(&conn, io, gpa, protocol.SendResp{ .ok = false, .err = "unknown command" }) catch {};
        }
    }
}

/// Resolve a request's session id and take a reference on the session
/// (release it with `session.release`). Responds and returns null when
/// the id is malformed or unknown.
fn lookup(conn: *ipc.Conn, io: std.Io, gpa: std.mem.Allocator, comptime Resp: type, raw_id: []const u8) ?*session.Session {
    const id = protocol.parseDecimal(u64, raw_id) orelse {
        badId(conn, io, gpa, Resp, raw_id);
        return null;
    };
    return session.acquire(id) orelse {
        noSession(conn, io, gpa, Resp, id);
        return null;
    };
}

// ---- error helpers -----------------------------------------------------

const RenderedPng = struct {
    bytes: []u8,
    cols: u16,
    rows: u16,
};

/// Only drawing holds the terminal lock; compression runs after it, so
/// the session keeps processing output meanwhile.
fn renderSessionPng(gpa: std.mem.Allocator, s: *session.Session) !RenderedPng {
    s.lockTerminal();
    const cols = s.cols;
    const rows = s.rows;
    const image = drawn: {
        defer s.unlockTerminal();
        const max_png_size = try render.maxPngSize(cols, rows);
        if (max_png_size > max_png_render_size) return error.ImageTooLarge;
        break :drawn try render.renderImage(gpa, &s.terminal);
    };
    defer gpa.free(image.pixels);
    return .{ .bytes = try render.encodePng(gpa, image), .cols = cols, .rows = rows };
}

/// Format an error message; null on OOM (the connection is closed
/// without a response in that case).
fn badValue(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[]u8 {
    return std.fmt.allocPrint(gpa, fmt, args) catch null;
}

/// Readable text for session operation failures; the CLI prints the
/// response verbatim, so raw error names are a last resort.
fn sessionErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.SessionExited => "session has exited",
        error.WriteFailed => "cannot write to the session's pty",
        error.InputStalled => "the session stopped reading its input (no progress for 5 s); part of the input may have been delivered",
        error.InputBusy => "another input to this session is stalled; nothing was sent",
        error.ResizeFailed => "cannot resize the session's pty",
        error.KeyNotEncodable => "the program's keyboard mode cannot express this key",
        error.MouseEventNotReportable => "the program's mouse mode cannot report this event (button, action, or position)",
        error.StopTimeout => "session did not exit within 3 s after SIGKILL",
        else => @errorName(err),
    };
}

fn badId(conn: *ipc.Conn, io: std.Io, gpa: std.mem.Allocator, comptime Resp: type, raw: []const u8) void {
    if (badValue(gpa, "invalid session id '{s}'", .{raw})) |msg| {
        defer gpa.free(msg);
        _ = respond(conn, io, gpa, Resp{ .ok = false, .err = msg }) catch {};
    }
}

fn noSession(conn: *ipc.Conn, io: std.Io, gpa: std.mem.Allocator, comptime Resp: type, id: u64) void {
    if (session.missingReason(gpa, id) orelse badValue(gpa, "no session with id {d}", .{id})) |msg| {
        defer gpa.free(msg);
        _ = respond(conn, io, gpa, Resp{ .ok = false, .err = msg }) catch {};
    }
}

fn invalidSize(conn: *ipc.Conn, io: std.Io, gpa: std.mem.Allocator, comptime Resp: type, cols: u16, rows: u16) void {
    if (badValue(gpa, "invalid size {d}x{d} (both dimensions must be 1..1000)", .{ cols, rows })) |msg| {
        defer gpa.free(msg);
        _ = respond(conn, io, gpa, Resp{ .ok = false, .err = msg }) catch {};
    }
}

fn startFailed(conn: *ipc.Conn, io: std.Io, gpa: std.mem.Allocator, req: protocol.RunReq, err: anyerror) void {
    const argv0 = req.argv[0];
    const msg = switch (err) {
        error.BadCwd => badValue(gpa, "cannot start '{s}': working directory '{s}' is missing or not accessible", .{ argv0, req.cwd orelse "" }),
        error.TooManyOpenFiles => badValue(gpa, "cannot start '{s}': the daemon has too many open files", .{argv0}),
        error.CantOpenFile => if (req.record.?.path) |path|
            badValue(gpa, "cannot start '{s}': cannot create the recording file '{s}'", .{ argv0, path })
        else
            badValue(gpa, "cannot start '{s}': cannot create the recording file in the session directory", .{argv0}),
        error.ChildSetupFailed => badValue(gpa, "cannot start '{s}': command not found or not executable", .{argv0}),
        error.BadEnv => badValue(gpa, "cannot start '{s}': malformed environment entry", .{argv0}),
        else => badValue(gpa, "cannot start '{s}': {s}", .{ argv0, @errorName(err) }),
    };
    if (msg) |m| {
        defer gpa.free(m);
        _ = respond(conn, io, gpa, protocol.RunResp{ .ok = false, .err = m }) catch {};
    }
}

fn respondOutOfMemory(conn: *ipc.Conn) void {
    conn.sendLine("{\"ok\":false,\"err\":\"OutOfMemory\"}") catch {};
}

fn respond(conn: *ipc.Conn, io: std.Io, gpa: std.mem.Allocator, value: anytype) !void {
    _ = io;
    const out = try protocol.stringifyAlloc(gpa, value);
    defer gpa.free(out);
    if (out.len > max_response_line) {
        return conn.sendLine("{\"ok\":false,\"err\":\"response exceeds the 16 MiB limit\"}");
    }
    try conn.sendLine(out);
}
