//! Starting a session's program: the child environment, the POSIX
//! fork/exec and Windows ConPTY process start, the exit waiter, and
//! signalling and reaping the child.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const pty_mod = @import("pty.zig");
const session_mod = @import("session.zig");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else @import("win32_stub.zig");

const Session = session_mod.Session;
const Options = session_mod.Options;

const wait_c = if (builtin.os.tag == .windows) struct {} else @import("c");

// `openpty` cannot request close-on-exec atomically on every supported
// POSIX system. Serializing session startup closes the only in-process fork
// window before both PTY descriptors have FD_CLOEXEC.
pub var spawn_mutex: std.Io.Mutex = .init;

/// The child process: std.process.Child on POSIX (for group kills and
/// wait), a raw PROCESS_INFORMATION on Windows (ConPTY requires a
/// hand-rolled CreateProcessW with the pseudoconsole attribute).
pub const Proc = union(enum) {
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
        list[i] = (try gpa.dupeSentinel(u8, a, 0)).ptr;
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

/// The descriptor limit to give session children, when the daemon raised
/// its own.
pub var child_nofile: ?std.c.rlimit = null;

/// The terminal type every session emulates; its terminfo entry is what
/// TUIs need to see.
const session_term = "TERM=xterm-256color";

/// Variables that describe the caller's terminal or multiplexer, tuppet's
/// own included. A session's terminal is tuppet's: a program that saw
/// TMUX, for example, would wrap its queries for a tmux that is not there.
const caller_terminal_vars = [_][]const u8{ "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TMUX", "TMUX_PANE", "STY", "TUPPET_SESSION", "TUPPET_SESSION_SOCKET" };

/// The child environment: `env` (or, on POSIX, the daemon's own) without
/// the caller's terminal variables, plus tuppet's TERM and `session_vars`
/// (TUPPET_SESSION=<id>, TUPPET_SESSION_SOCKET=<endpoint>). Rejects
/// entries without a name or with NUL bytes. The result's strings alias
/// the inputs.
pub fn buildChildEnv(gpa: std.mem.Allocator, env: ?[]const []const u8, session_vars: []const []const u8) ![]const []const u8 {
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
    try list.appendSlice(gpa, session_vars);
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

/// A POSIX child spawn handed to the session's waiter thread.
pub const SpawnRequest = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    child_env: []const []const u8,
    done: std.Io.Event = .unset,
    result: anyerror!void = {},
};

/// POSIX waiter thread: fork the child, report the outcome to `start`
/// (whose stack owns `request`), then wait for the child to exit.
pub fn spawnAndWait(s: *Session, request: *SpawnRequest) void {
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
pub fn waiterLoop(s: *Session) void {
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

/// Spawn the child on Windows with the pseudoconsole attribute. The
/// child's ConPTY handles are the ones given to CreatePseudoConsole;
/// only the HPCON is passed via STARTUPINFOEXW.
pub fn spawnWindowsChild(gpa: std.mem.Allocator, opts: Options, child_env: []const []const u8, pair: *const pty_mod.Pair) !Proc {
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
        const z = try gpa.dupeSentinel(u8, cwd, 0);
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
        while (sig < 32) : (sig += 1) _ = std.c.sigaction(@fromBackingInt(@intCast(sig)), &default_action, null);
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, &empty_mask, null);
        // Programs get the descriptor limit the daemon started with, not
        // the one it raised for itself.
        if (child_nofile) |limit| _ = std.c.setrlimit(.NOFILE, &limit);
        // A supervised daemon's sessions must not outlive it, even when
        // it is SIGKILLed. If the daemon died before prctl took effect,
        // the child is already orphaned: give up.
        if (builtin.os.tag == .linux and session_mod.supervised) {
            _ = std.os.linux.prctl(@backingInt(std.os.linux.PR.SET_PDEATHSIG), @backingInt(std.posix.SIG.KILL), 0, 0, 0);
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
pub fn signalGroup(s: *Session, how: GroupSignal) void {
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
pub fn groupAlive(s: *Session) bool {
    return switch (builtin.os.tag) {
        .windows => !s.process_reaped.load(.acquire),
        else => std.c.kill(-@as(std.posix.pid_t, @intCast(s.process_id)), @fromBackingInt(0)) == 0 or
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
    const path = std.mem.printSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch return null;
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
pub fn stopAndReapProc(proc: *Proc, io: std.Io) i32 {
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
    if (std.c.W.IFSIGNALED(st)) return -@as(i32, @intCast(@backingInt(std.c.W.TERMSIG(st))));
    return -1;
}

pub fn procPid(proc: Proc) u32 {
    return switch (builtin.os.tag) {
        .windows => proc.windows.pid,
        else => @intCast(proc.posix.id orelse 0),
    };
}

fn windowsExitCode(raw: u32) i32 {
    return @bitCast(raw);
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
    const env = try buildChildEnv(std.testing.allocator, &.{ "A=1", "TERM=dumb", "TMUX=/tmp/tmux-1/default,1,0", "TERM_PROGRAM=tmux", "TUPPET_SESSION=1", "TUPPET_SESSION_SOCKET=/a" }, &.{ "TUPPET_SESSION=2", "TUPPET_SESSION_SOCKET=/b" });
    defer std.testing.allocator.free(env);
    try std.testing.expectEqualDeep(&[_][]const u8{ "A=1", "TERM=xterm-256color", "TUPPET_SESSION=2", "TUPPET_SESSION_SOCKET=/b" }, env);
}
