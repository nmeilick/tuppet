//! Transport for the daemon/CLI JSON-lines protocol: unix-domain
//! sockets on POSIX, per-user named pipes on Windows. Both ends verify
//! that the other side runs as the same user.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else @import("win32_stub.zig");

const c = if (builtin.os.tag == .windows)
    struct {}
else
    @cImport({
        @cInclude("unistd.h");
        @cInclude("stdlib.h");
        @cInclude("sys/socket.h");
        @cInclude("sys/un.h");
    });

// struct ucred needs _GNU_SOURCE in glibc headers; its layout is fixed.
const LinuxUcred = extern struct { pid: i32, uid: u32, gid: u32 };
const linux_so_peercred: c_int = 17;
extern "c" fn flock(fd: c_int, operation: c_int) c_int;
extern "c" fn getpeereid(fd: c_int, uid: *std.c.uid_t, gid: *std.c.gid_t) c_int;

const request_timeout_seconds = 10;
const request_timeout_ns = request_timeout_seconds * std.time.ns_per_s;

/// Capacity of an endpoint path buffer.
pub const max_path_len = 128;

/// File type and owner of a filesystem object. Read with fstatat, not
/// statx: statx needs Linux 4.11, and Zig's own stat calls use it with no
/// fallback, while tuppet must also run on older kernels.
const Meta = struct {
    mode: u32,
    uid: u32,

    const ifmt = 0o170000;
    const ifreg = 0o100000;
    const ifdir = 0o040000;
    const ifsock = 0o140000;

    fn isType(m: Meta, t: u32) bool {
        return m.mode & ifmt == t;
    }

    fn ownedByCurrentUser(m: Meta) bool {
        return m.uid == std.c.getuid();
    }
};

/// The kernel's struct stat (what newfstatat fills) on the Linux release
/// architectures.
const LinuxStat = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        pad0: u32,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        times: [6]u64,
        unused: [3]i64,
    },
    else => extern struct {
        dev: u64,
        ino: u64,
        mode: u32,
        nlink: u32,
        uid: u32,
        gid: u32,
        rdev: u64,
        pad1: u64,
        size: i64,
        blksize: i32,
        pad2: i32,
        blocks: i64,
        times: [6]u64,
        unused: [2]u32,
    },
};

/// Stat `path` relative to `dirfd` without following a final symlink;
/// an empty path stats `dirfd` itself.
fn statMeta(dirfd: std.posix.fd_t, path: [*:0]const u8) error{ FileNotFound, StatFailed }!Meta {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var st: LinuxStat = undefined;
            const flags: usize = @as(usize, linux.AT.SYMLINK_NOFOLLOW) | @as(usize, if (path[0] == 0) linux.AT.EMPTY_PATH else 0);
            const rc = linux.syscall4(
                .fstatat64,
                @bitCast(@as(isize, dirfd)),
                @intFromPtr(path),
                @intFromPtr(&st),
                flags,
            );
            return switch (linux.errno(rc)) {
                .SUCCESS => .{ .mode = st.mode, .uid = st.uid },
                .NOENT => error.FileNotFound,
                else => error.StatFailed,
            };
        },
        else => {
            var st = std.mem.zeroes(std.c.Stat);
            const flags: u32 = std.c.AT.SYMLINK_NOFOLLOW;
            const rc = if (path[0] == 0) std.c.fstat(dirfd, &st) else std.c.fstatat(dirfd, path, &st, flags);
            if (rc != 0) return if (std.posix.errno(rc) == .NOENT) error.FileNotFound else error.StatFailed;
            return .{ .mode = @intCast(st.mode), .uid = st.uid };
        },
    }
}

/// Whether an open file or directory belongs to the current user.
pub fn ownedByCurrentUser(fd: std.posix.fd_t) bool {
    const meta = statMeta(fd, "") catch return false;
    return meta.ownedByCurrentUser();
}

/// Whether an open descriptor refers to a regular file.
pub fn isRegularFile(fd: std.posix.fd_t) bool {
    const meta = statMeta(fd, "") catch return false;
    return meta.isType(Meta.ifreg);
}

fn pathMeta(path: [:0]const u8) !Meta {
    return statMeta(std.c.AT.FDCWD, path.ptr);
}

/// The uid of the process on the other end of a connected unix socket.
fn peerUid(fd: std.posix.fd_t) ?std.c.uid_t {
    switch (builtin.os.tag) {
        .linux => {
            var cred: LinuxUcred = undefined;
            var len: c.socklen_t = @sizeOf(LinuxUcred);
            if (c.getsockopt(fd, c.SOL_SOCKET, linux_so_peercred, &cred, &len) != 0) return null;
            return cred.uid;
        },
        else => {
            var uid: std.c.uid_t = undefined;
            var gid: std.c.gid_t = undefined;
            if (getpeereid(fd, &uid, &gid) != 0) return null;
            return uid;
        },
    }
}

fn requestExpired(started: i64) bool {
    return io_mod.nowNanos() - started >= request_timeout_ns;
}

/// The daemon endpoint. POSIX: `$XDG_RUNTIME_DIR/tuppet-<uid>.sock`, or
/// `/tmp/tuppet-<uid>/tuppet.sock` (in a private 0700 directory) when
/// XDG_RUNTIME_DIR is unset or empty. A runtime directory too long for a
/// socket address is an error, never a silent fallback. Windows:
/// `\\.\pipe\tuppet-<user SID>`.
pub fn socketPath(buf: *[max_path_len:0]u8) error{ SocketPathTooLong, UnsafeRuntimeDir, UnknownUser }![:0]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            var sid_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
            const sid = win32.processUserSid(win32.GetCurrentProcess(), &sid_buf) orelse return error.UnknownUser;
            var wide: ?win32.LPWSTR = null;
            if (win32.ConvertSidToStringSidW(sid, &wide) == 0) return error.UnknownUser;
            defer _ = win32.LocalFree(wide);
            const sid_w = std.mem.span(@as([*:0]const u16, @ptrCast(wide.?)));
            var sid_utf8: [184]u8 = undefined;
            const sid_len = std.unicode.utf16LeToUtf8(&sid_utf8, sid_w) catch return error.UnknownUser;
            return std.fmt.bufPrintZ(buf, "\\\\.\\pipe\\tuppet-{s}", .{sid_utf8[0..sid_len]}) catch return error.UnknownUser;
        },
        else => {
            const uid = c.getuid();
            const addr: c.struct_sockaddr_un = undefined;
            const max_socket_path = @sizeOf(@TypeOf(addr.sun_path)) - 1;
            if (c.getenv("XDG_RUNTIME_DIR")) |rt| {
                const dir = std.mem.span(@as([*:0]const u8, @ptrCast(rt)));
                if (dir.len > 0) {
                    const p = std.fmt.bufPrintZ(buf, "{s}/tuppet-{d}.sock", .{ dir, uid }) catch return error.SocketPathTooLong;
                    if (p.len > max_socket_path) return error.SocketPathTooLong;
                    return p;
                }
            }
            var dir_buf: [64:0]u8 = undefined;
            const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/tuppet-{d}", .{uid}) catch unreachable;
            try ensurePrivateDir(dir);
            return std.fmt.bufPrintZ(buf, "{s}/tuppet.sock", .{dir}) catch unreachable;
        },
    }
}

/// Create `dir` mode 0700 if needed and make sure it is a real directory
/// owned by this user that nobody else can enter, so another user cannot
/// plant or replace the socket in the shared /tmp.
fn ensurePrivateDir(dir: [:0]const u8) error{UnsafeRuntimeDir}!void {
    if (std.c.mkdir(dir.ptr, 0o700) != 0 and std.posix.errno(-1) != .EXIST) return error.UnsafeRuntimeDir;
    const meta = pathMeta(dir) catch return error.UnsafeRuntimeDir;
    if (!meta.isType(Meta.ifdir) or !meta.ownedByCurrentUser()) return error.UnsafeRuntimeDir;
    // Owned by this user, so tightening the mode is safe.
    if (std.c.chmod(dir.ptr, 0o700) != 0) return error.UnsafeRuntimeDir;
}

/// The daemon log next to a POSIX socket path: `.sock` becomes `.log`.
/// The daemon's stderr goes there when the CLI starts it.
pub fn logPath(buf: *[max_path_len:0]u8, socket_path: []const u8) ?[:0]const u8 {
    const stem = if (std.mem.endsWith(u8, socket_path, ".sock")) socket_path[0 .. socket_path.len - 5] else socket_path;
    return std.fmt.bufPrintZ(buf, "{s}.log", .{stem}) catch null;
}

/// One connection: a socket stream on POSIX, a pipe handle on Windows.
/// Reads time out after the request deadline on both platforms.
pub const Conn = union(enum) {
    posix: std.Io.net.Stream,
    windows: struct {
        handle: win32.HANDLE,
        /// The daemon's end disconnects its pipe instance on close.
        server: bool,
    },

    pub fn connect(path: []const u8) !Conn {
        switch (builtin.os.tag) {
            .windows => {
                var wbuf: [max_path_len]u16 = undefined;
                const wpath = win32.utf8ToUtf16(&wbuf, path) catch return error.BadPath;
                var tries: u32 = 0;
                while (tries < 5) : (tries += 1) {
                    // Identification-level impersonation only: a server
                    // squatting the name cannot act as this user.
                    const h = win32.CreateFileW(
                        @ptrCast(wpath.ptr),
                        win32.GENERIC_READ | win32.GENERIC_WRITE,
                        0,
                        null,
                        win32.OPEN_EXISTING,
                        win32.SECURITY_SQOS_PRESENT | win32.SECURITY_IDENTIFICATION,
                        null,
                    );
                    if (h != win32.INVALID_HANDLE_VALUE) {
                        errdefer _ = win32.CloseHandle(h);
                        if (!pipeServerIsCurrentUser(h)) return error.UntrustedDaemon;
                        // Non-blocking reads give the client the same
                        // request deadline as on POSIX.
                        var mode = win32.PIPE_READMODE_BYTE | win32.PIPE_NOWAIT;
                        if (win32.SetNamedPipeHandleState(h, &mode, null, null) == 0) return error.ConnectionRefused;
                        return .{ .windows = .{ .handle = h, .server = false } };
                    }
                    const err = win32.GetLastError();
                    if (err == win32.ERROR_PIPE_BUSY) {
                        // A client is being served; wait for a free
                        // instance, then retry.
                        _ = win32.WaitNamedPipeW(@ptrCast(wpath.ptr), 5000);
                        continue;
                    }
                    return error.ConnectionRefused;
                }
                return error.ConnectionRefused;
            },
            else => {
                // Raw libc connect: a stale socket file (daemon died, file
                // left behind) fails with ECONNREFUSED, which std.Io's
                // connect panics on. We must turn that into a plain error
                // so the CLI can retry and auto-restart the daemon.
                var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
                if (path.len > 0 and path.len < @sizeOf(@TypeOf(addr.sun_path))) {
                    // SOCK_CLOEXEC is not portable (missing from macOS
                    // SDK headers), so mark the fd close-on-exec after
                    // the fact.
                    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
                    if (fd < 0) return error.SocketFailed;
                    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
                    // Match the daemon's per-request deadline: a wedged
                    // daemon must fail the request, not hang the CLI
                    // forever. Best-effort: a failure here only loses the
                    // hang protection, not the connection.
                    var timeout: std.posix.timeval = .{ .sec = request_timeout_seconds, .usec = 0 };
                    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(std.posix.timeval));
                    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &timeout, @sizeOf(std.posix.timeval));
                    addr.sun_family = c.AF_UNIX;
                    @memcpy(addr.sun_path[0..path.len], path);
                    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0) {
                        // Whoever listens there gets every request; it
                        // must be this user's daemon.
                        if (peerUid(fd) != std.c.getuid()) {
                            _ = c.close(fd);
                            return error.UntrustedDaemon;
                        }
                        return .{ .posix = .{ .socket = .{ .handle = fd, .address = undefined } } };
                    }
                    _ = c.close(fd);
                    return error.ConnectionRefused;
                }
                return error.BadPath;
            },
        }
    }

    fn posixFd(self: *Conn) std.posix.fd_t {
        return self.posix.socket.handle;
    }

    /// Sends one line (newline-terminated).
    pub fn sendLine(self: *Conn, line: []const u8) !void {
        const started = io_mod.nowNanos();
        try self.writeAllBefore(line, started);
        try self.writeAllBefore("\n", started);
    }

    fn writeAllBefore(self: *Conn, bytes: []const u8, started: i64) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            switch (builtin.os.tag) {
                .windows => {
                    // Non-blocking pipe: a full buffer writes 0 bytes;
                    // wait for the reader until the request deadline.
                    var written: win32.DWORD = 0;
                    if (win32.WriteFile(self.windows.handle, bytes.ptr + i, @intCast(bytes.len - i), &written, null) == 0) {
                        return error.WriteFailed;
                    }
                    i += written;
                    if (written == 0) {
                        if (requestExpired(started)) return error.WriteTimeout;
                        std.Io.sleep(io_mod.io(), .fromMilliseconds(1), .boot) catch {};
                    }
                },
                else => {
                    const flags = if (builtin.os.tag == .linux) c.MSG_NOSIGNAL else 0;
                    const n = c.send(self.posixFd(), bytes.ptr + i, bytes.len - i, flags);
                    if (n < 0) switch (std.posix.errno(n)) {
                        .INTR => continue,
                        .PIPE, .CONNRESET => return error.ConnectionResetByPeer,
                        else => return error.WriteFailed,
                    };
                    if (n == 0) return error.WriteFailed;
                    i += @intCast(n);
                    if (requestExpired(started)) return error.WriteTimeout;
                },
            }
        }
    }

    /// Reads one bounded line into request-owned memory. A client that sends
    /// no data does not reserve the full protocol limit while it waits.
    pub fn recvLineAlloc(self: *Conn, gpa: std.mem.Allocator, max_len: usize) ![]u8 {
        const split = try self.recvLineSplit(gpa, max_len);
        gpa.free(split.rest);
        return split.line;
    }

    /// Like recvLineAlloc, but also returns the bytes read past the
    /// newline (the start of a stream that follows the line).
    pub fn recvLineSplit(self: *Conn, gpa: std.mem.Allocator, max_len: usize) !struct { line: []u8, rest: []u8 } {
        const started = io_mod.nowNanos();
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(gpa);
        var chunk: [4096]u8 = undefined;
        while (true) {
            if (builtin.os.tag != .windows) self.limitReadTo(started);
            const got = self.readSome(&chunk, chunk.len) catch |err| {
                if (err != error.WouldBlock) return err;
                if (requestExpired(started)) return error.ReadTimeout;
                std.Io.sleep(io_mod.io(), .fromMilliseconds(1), .boot) catch {};
                continue;
            };
            if (got == 0) return error.Eof;
            if (requestExpired(started)) return error.ReadTimeout;
            const end = std.mem.indexOfScalar(u8, chunk[0..got], '\n') orelse got;
            if (end > max_len -| line.items.len) return error.LineTooLong;
            try line.appendSlice(gpa, chunk[0..end]);
            if (end < got) {
                const rest = try gpa.dupe(u8, chunk[end + 1 .. got]);
                errdefer gpa.free(rest);
                return .{ .line = try line.toOwnedSlice(gpa), .rest = rest };
            }
            if (line.items.len == max_len) return error.LineTooLong;
        }
    }

    /// A blocking read must end at the request deadline, not a full
    /// timeout after the last byte arrived.
    fn limitReadTo(self: *Conn, started: i64) void {
        const left: u64 = @intCast(@max(request_timeout_ns - (io_mod.nowNanos() - started), std.time.ns_per_ms));
        var timeout: std.posix.timeval = .{
            .sec = @intCast(left / std.time.ns_per_s),
            .usec = @intCast(left % std.time.ns_per_s / std.time.ns_per_us),
        };
        _ = c.setsockopt(self.posixFd(), c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(std.posix.timeval));
    }

    /// Read up to `want` bytes. Returns 0 on EOF.
    fn readSome(self: *Conn, buf: []u8, want: usize) !usize {
        switch (builtin.os.tag) {
            .windows => {
                var read: win32.DWORD = 0;
                if (win32.ReadFile(self.windows.handle, buf.ptr, @intCast(want), &read, null) == 0) {
                    return switch (win32.GetLastError()) {
                        win32.ERROR_NO_DATA => error.WouldBlock,
                        win32.ERROR_BROKEN_PIPE, win32.ERROR_PIPE_NOT_CONNECTED => 0,
                        else => error.ReadFailed,
                    };
                }
                // Non-blocking mode reports "no data yet" as a 0-byte read.
                if (read == 0) return error.WouldBlock;
                return read;
            },
            else => return std.posix.read(self.posixFd(), buf[0..want]),
        }
    }

    pub fn deinit(self: *Conn) void {
        switch (builtin.os.tag) {
            .windows => {
                if (self.windows.server) {
                    // Disconnecting discards unread data; let the client
                    // read the whole response first.
                    _ = win32.FlushFileBuffers(self.windows.handle);
                    _ = win32.DisconnectNamedPipe(self.windows.handle);
                }
                _ = win32.CloseHandle(self.windows.handle);
            },
            else => self.posix.close(io_mod.io()),
        }
    }
};

/// Whether the process serving a pipe runs as this user.
fn pipeServerIsCurrentUser(pipe: win32.HANDLE) bool {
    var server_pid: win32.windows.ULONG = 0;
    if (win32.GetNamedPipeServerProcessId(pipe, &server_pid) == 0) return false;
    const process = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, 0, server_pid) orelse return false;
    defer _ = win32.CloseHandle(process);
    var their_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
    var our_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
    const theirs = win32.processUserSid(process, &their_buf) orelse return false;
    const ours = win32.processUserSid(win32.GetCurrentProcess(), &our_buf) orelse return false;
    return win32.EqualSid(theirs, ours) != 0;
}

pub const Server = union(enum) {
    posix: struct {
        listener: std.Io.net.Server,
        lock_fd: c_int,
        path: [max_path_len:0]u8,
    },
    windows: struct {
        name: [max_path_len]u16,
        /// Security descriptor granting only this user access.
        security: ?*anyopaque,
        /// The instance waiting for the next client.
        pending: ?win32.HANDLE,
    },

    pub fn deinit(self: *Server) void {
        switch (builtin.os.tag) {
            .windows => {
                if (self.windows.pending) |h| _ = win32.CloseHandle(h);
                _ = win32.LocalFree(self.windows.security);
            },
            else => {
                self.posix.listener.deinit(io_mod.io());
                _ = c.unlink(&self.posix.path);
                _ = c.close(self.posix.lock_fd);
            },
        }
    }
};

fn createPipeInstance(server: *Server, first: bool) !win32.HANDLE {
    var sa: win32.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = server.windows.security,
        .bInheritHandle = 0,
    };
    const h = win32.CreateNamedPipeW(
        @ptrCast(&server.windows.name),
        win32.PIPE_ACCESS_DUPLEX | (if (first) win32.FILE_FLAG_FIRST_PIPE_INSTANCE else 0),
        win32.PIPE_TYPE_BYTE | win32.PIPE_READMODE_BYTE | win32.PIPE_WAIT | win32.PIPE_REJECT_REMOTE_CLIENTS,
        win32.PIPE_UNLIMITED_INSTANCES,
        1 << 20,
        1 << 20,
        0,
        &sa,
    );
    if (h == win32.INVALID_HANDLE_VALUE) {
        // Someone else already owns the name (another daemon, or
        // another user squatting it).
        if (first) return error.AddressInUse;
        return error.AcceptFailed;
    }
    return h;
}

/// Bind and listen. POSIX: a lock file makes the endpoint exclusive and
/// lets a stale socket be removed safely. Windows: the first pipe
/// instance is created with FILE_FLAG_FIRST_PIPE_INSTANCE, which fails
/// if anyone already owns the name, and only this user may connect.
pub fn listen(path: []const u8) !Server {
    switch (builtin.os.tag) {
        .windows => {
            var server: Server = .{ .windows = .{ .name = undefined, .security = null, .pending = null } };
            _ = win32.utf8ToUtf16(&server.windows.name, path) catch return error.BadPath;

            var sid_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
            const sid = win32.processUserSid(win32.GetCurrentProcess(), &sid_buf) orelse return error.UnknownUser;
            var sid_w: ?win32.LPWSTR = null;
            if (win32.ConvertSidToStringSidW(sid, &sid_w) == 0) return error.UnknownUser;
            defer _ = win32.LocalFree(sid_w);
            // D:P = protected DACL with one entry: generic-all for this user.
            var sddl: [256]u16 = undefined;
            const prefix = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
            const sid_span = std.mem.span(@as([*:0]const u16, @ptrCast(sid_w.?)));
            if (prefix.len + sid_span.len + 2 > sddl.len) return error.UnknownUser;
            @memcpy(sddl[0..prefix.len], prefix);
            @memcpy(sddl[prefix.len..][0..sid_span.len], sid_span);
            sddl[prefix.len + sid_span.len] = ')';
            sddl[prefix.len + sid_span.len + 1] = 0;
            if (win32.ConvertStringSecurityDescriptorToSecurityDescriptorW(
                @ptrCast(&sddl),
                win32.SDDL_REVISION_1,
                &server.windows.security,
                null,
            ) == 0) return error.CannotSecureEndpoint;
            errdefer _ = win32.LocalFree(server.windows.security);

            server.windows.pending = try createPipeInstance(&server, true);
            return server;
        },
        else => {
            const addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
            if (path.len == 0 or path.len >= @sizeOf(@TypeOf(addr.sun_path))) return error.BadPath;

            var path_z: [max_path_len:0]u8 = undefined;
            const owned_path = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch return error.BadPath;
            var lock_path_buf: [max_path_len + 8:0]u8 = undefined;
            const lock_path = std.fmt.bufPrintZ(&lock_path_buf, "{s}.lock", .{path}) catch return error.BadPath;
            const lock_fd = std.c.open(lock_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o600));
            if (lock_fd < 0) return error.OwnershipFailed;
            errdefer _ = c.close(lock_fd);
            _ = std.c.fcntl(lock_fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));

            const io = io_mod.io();
            const lock_meta = statMeta(lock_fd, "") catch return error.UnsafeLockFile;
            if (!lock_meta.isType(Meta.ifreg) or !lock_meta.ownedByCurrentUser()) return error.UnsafeLockFile;
            // A daemon that is exiting holds the lock for a moment after it
            // stopped answering; one that still answers is never waited for.
            var waited_ms: u32 = 0;
            while (flock(lock_fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) : (waited_ms += 10) {
                if (waited_ms >= 2000) return error.AddressInUse;
                if (Conn.connect(owned_path)) |live| {
                    var conn = live;
                    conn.deinit();
                    return error.AddressInUse;
                } else |_| {}
                std.Io.sleep(io, .fromMilliseconds(10), .boot) catch {};
            }

            if (pathMeta(owned_path)) |endpoint| {
                if (!endpoint.isType(Meta.ifsock) or !endpoint.ownedByCurrentUser()) {
                    return error.EndpointPathOccupied;
                }
                // Only a dead endpoint is replaced; anything still
                // answering there (even without our lock) keeps it.
                if (Conn.connect(owned_path)) |live| {
                    var conn = live;
                    conn.deinit();
                    return error.AddressInUse;
                } else |_| {}
                if (c.unlink(owned_path.ptr) != 0) return error.CannotRemoveStaleEndpoint;
            } else |err| switch (err) {
                error.FileNotFound => {},
                error.StatFailed => return error.EndpointPathOccupied,
            }

            const ua = try std.Io.net.UnixAddress.init(path);
            // The socket must never exist with group or world access,
            // not even between bind and chmod. The daemon is still
            // single-threaded here, so the process-wide umask is safe.
            const old_umask = std.c.umask(0o077);
            var listener = ua.listen(io, .{}) catch |err| {
                _ = std.c.umask(old_umask);
                return err;
            };
            _ = std.c.umask(old_umask);
            errdefer listener.deinit(io);
            std.Io.Dir.cwd().setFilePermissions(
                io,
                owned_path,
                @enumFromInt(0o600),
                .{},
            ) catch return error.CannotSecureEndpoint;
            return .{ .posix = .{
                .listener = listener,
                .lock_fd = lock_fd,
                .path = path_z,
            } };
        },
    }
}

/// Accept the next client connection. Clients running as another user
/// are refused.
pub fn accept(server: *Server, io: std.Io) !Conn {
    switch (builtin.os.tag) {
        .windows => {
            const h = server.windows.pending orelse try createPipeInstance(server, false);
            server.windows.pending = null;
            errdefer _ = win32.CloseHandle(h);
            if (win32.ConnectNamedPipe(h, null) == 0) {
                // ERROR_PIPE_CONNECTED: a client connected between
                // CreateNamedPipeW and this call.
                const err = win32.GetLastError();
                if (err != win32.ERROR_PIPE_CONNECTED) return error.AcceptFailed;
            }
            // Have the next instance ready before serving this client,
            // so new clients rarely find no instance to connect to.
            server.windows.pending = createPipeInstance(server, false) catch null;
            var mode = win32.PIPE_READMODE_BYTE | win32.PIPE_NOWAIT;
            if (win32.SetNamedPipeHandleState(h, &mode, null, null) == 0) return error.CannotSetTimeout;
            return .{ .windows = .{ .handle = h, .server = true } };
        },
        else => {
            var stream = try server.posix.listener.accept(io);
            errdefer stream.close(io);
            const fd = stream.socket.handle;
            if (peerUid(fd) != std.c.getuid()) return error.ForeignClient;
            var timeout: std.posix.timeval = .{ .sec = request_timeout_seconds, .usec = 0 };
            if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(std.posix.timeval)) != 0 or
                c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &timeout, @sizeOf(std.posix.timeval)) != 0)
            {
                return error.CannotSetTimeout;
            }
            if (builtin.os.tag == .macos) {
                var enabled: c_int = 1;
                if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0) {
                    return error.CannotDisableSigpipe;
                }
            }
            return .{ .posix = stream };
        },
    }
}

test "socket path rejects a runtime directory too long for a socket address" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const saved = c.getenv("XDG_RUNTIME_DIR");
    _ = c.setenv("XDG_RUNTIME_DIR", "/" ++ "d" ** 120, 1);
    defer _ = if (saved) |v| c.setenv("XDG_RUNTIME_DIR", v, 1) else c.unsetenv("XDG_RUNTIME_DIR");
    var buf: [max_path_len:0]u8 = undefined;
    try std.testing.expectError(error.SocketPathTooLong, socketPath(&buf));
}
