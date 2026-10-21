//! Platform-neutral low-level file and console I/O: raw fds on POSIX,
//! HANDLEs on Windows. Keeps session/client/main code free of platform
//! branches for ordinary file writes.

const std = @import("std");
const builtin = @import("builtin");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else @import("win32_stub.zig");
const ipc = @import("ipc.zig");

pub const File = union(enum) {
    posix: std.posix.fd_t,
    windows: win32.HANDLE,
};

pub const CreateMode = enum {
    /// Ordinary writes (the CLI's own output files).
    blocking,
    /// Recordings: a pipe whose reader stalls makes writeAll fail after
    /// a short wait instead of blocking the recording session, and a
    /// FIFO without a reader fails to open at once.
    nonblocking,
};

/// Make an existing regular file readable only by this user, as a newly
/// created one already is. Pipes and devices keep their mode.
pub fn makePrivate(file: File) void {
    if (builtin.os.tag == .windows) return;
    if (!ipc.isRegularFile(file.posix)) return;
    _ = std.c.fchmod(file.posix, 0o600);
}

/// Open (or truncate) a file for writing, readable only by this user
/// when created: recordings capture everything typed into a session.
pub fn create(path: [:0]const u8, mode: CreateMode) !File {
    switch (builtin.os.tag) {
        .windows => {
            var wbuf: [1024]u16 = undefined;
            const wpath = win32.utf8ToUtf16(&wbuf, path) catch return error.BadPath;
            const h = win32.CreateFileW(
                @ptrCast(wpath.ptr),
                win32.GENERIC_WRITE,
                win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
                null,
                win32.CREATE_ALWAYS,
                win32.FILE_ATTRIBUTE_NORMAL,
                null,
            );
            if (h == win32.INVALID_HANDLE_VALUE) return error.CantOpenFile;
            return .{ .windows = h };
        },
        else => {
            // Regular files never report EAGAIN either way.
            const file = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NONBLOCK = mode == .nonblocking }, @as(std.c.mode_t, 0o600));
            if (file < 0) return switch (std.posix.errno(file)) {
                .ACCES, .PERM => error.AccessDenied,
                .NOENT => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .ISDIR => error.IsDir,
                .ROFS => error.ReadOnlyFileSystem,
                .NOSPC, .DQUOT => error.NoSpaceLeft,
                .NAMETOOLONG => error.NameTooLong,
                else => error.CantOpenFile,
            };
            return .{ .posix = file };
        },
    }
}

/// Why `create` failed, in words.
pub fn createErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied => "permission denied",
        error.FileNotFound => "its directory does not exist",
        error.NotDir => "a part of the path is not a directory",
        error.IsDir => "it is a directory",
        error.ReadOnlyFileSystem => "the file system is read-only",
        error.NoSpaceLeft => "no space left on the device",
        error.NameTooLong, error.BadPath => "the path is too long or not valid",
        else => "the system refused to open it",
    };
}

pub fn writeAll(f: File, data: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => {
            var i: usize = 0;
            while (i < data.len) {
                var written: win32.DWORD = 0;
                if (win32.WriteFile(f.windows, data.ptr + i, @intCast(data.len - i), &written, null) == 0) {
                    return error.WriteFailed;
                }
                if (written == 0) return error.WriteFailed;
                i += written;
            }
        },
        else => {
            var i: usize = 0;
            while (i < data.len) {
                const n = std.c.write(f.posix, data.ptr + i, data.len - i);
                if (n > 0) {
                    i += @intCast(n);
                    continue;
                }
                switch (std.posix.errno(n)) {
                    .INTR => {},
                    .AGAIN => {
                        // A pipe whose reader is not keeping up: wait up
                        // to a second for room, then fail.
                        var pfd = [1]std.c.pollfd{.{ .fd = f.posix, .events = std.c.POLL.OUT, .revents = 0 }};
                        if (std.c.poll(&pfd, 1, write_stall_ms) <= 0) return error.WriteFailed;
                    },
                    else => return error.WriteFailed,
                }
            }
        },
    }
}

const write_stall_ms = 1000;

pub fn close(f: File) void {
    switch (builtin.os.tag) {
        .windows => _ = win32.CloseHandle(f.windows),
        else => _ = std.c.close(f.posix),
    }
}

fn consoleWriteAll(which: win32.DWORD, data: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => {
            const h = win32.GetStdHandle(which);
            var i: usize = 0;
            while (i < data.len) {
                var written: win32.DWORD = 0;
                if (win32.WriteFile(h, data.ptr + i, @intCast(data.len - i), &written, null) == 0) {
                    return error.OutputFailed;
                }
                if (written == 0) return error.OutputFailed;
                i += written;
            }
        },
        else => {
            var i: usize = 0;
            while (i < data.len) {
                const n = std.c.write(if (which == win32.STD_OUTPUT_HANDLE) 1 else 2, data.ptr + i, data.len - i);
                if (n < 0 and std.posix.errno(n) == .INTR) continue;
                if (n < 0 and std.posix.errno(n) == .PIPE) return error.BrokenPipe;
                if (n <= 0) return error.OutputFailed;
                i += @intCast(n);
            }
        },
    }
}

pub fn stdoutWriteAll(data: []const u8) !void {
    try consoleWriteAll(win32.STD_OUTPUT_HANDLE, data);
}

pub fn stderrWriteAll(data: []const u8) !void {
    try consoleWriteAll(win32.STD_ERROR_HANDLE, data);
}

/// All of standard input, failing with error.StreamTooLong past `limit`
/// bytes. Caller owns the result.
pub fn stdinReadAll(gpa: std.mem.Allocator, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n: usize = switch (builtin.os.tag) {
            .windows => blk: {
                var read: win32.DWORD = 0;
                if (win32.ReadFile(win32.GetStdHandle(win32.STD_INPUT_HANDLE), &chunk, chunk.len, &read, null) == 0) {
                    if (win32.GetLastError() == win32.ERROR_BROKEN_PIPE) break :blk 0;
                    return error.InputFailed;
                }
                break :blk read;
            },
            else => blk: {
                const n = std.c.read(0, &chunk, chunk.len);
                if (n < 0 and std.posix.errno(n) == .INTR) continue;
                if (n < 0) return error.InputFailed;
                break :blk @intCast(n);
            },
        };
        if (n == 0) return out.toOwnedSlice(gpa);
        if (out.items.len + n > limit) return error.StreamTooLong;
        try out.appendSlice(gpa, chunk[0..n]);
    }
}

// On Linux, std.posix.termios has the kernel's layout, which is shorter
// than libc's struct termios: libc's tcgetattr would write past it. So
// on Linux the attributes go to and from the kernel directly.

/// The terminal attributes of `fd`.
pub fn tcgetattr(fd: std.posix.fd_t) std.posix.TermiosGetError!std.posix.termios {
    const linux = std.os.linux;
    while (true) {
        var t: std.posix.termios = undefined;
        const e = if (builtin.os.tag == .linux)
            linux.errno(linux.tcgetattr(fd, &t))
        else
            std.posix.errno(std.c.tcgetattr(fd, &t));
        switch (e) {
            .SUCCESS => return t,
            .INTR => continue,
            .BADF, .NOTTY => return error.NotATerminal,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

/// Set the terminal attributes of `fd`.
pub fn tcsetattr(fd: std.posix.fd_t, action: std.posix.TCSA, t: std.posix.termios) std.posix.TermiosSetError!void {
    if (builtin.os.tag != .linux) return std.posix.tcsetattr(fd, action, t);
    const linux = std.os.linux;
    while (true) {
        switch (linux.errno(linux.tcsetattr(fd, action, &t))) {
            .SUCCESS => return,
            .INTR => continue,
            .BADF, .NOTTY => return error.NotATerminal,
            .IO => return error.ProcessOrphaned,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

test "created POSIX files are close-on-exec" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, ".zig-cache/tmp/{s}/record.cast", .{tmp.sub_path}, 0);
    const file = try create(path, .nonblocking);
    defer close(file);

    const flags = std.c.fcntl(file.posix, std.c.F.GETFD);
    try std.testing.expect(flags >= 0);
    try std.testing.expect(flags & std.c.FD_CLOEXEC != 0);
}
