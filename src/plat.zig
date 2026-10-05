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
            if (file < 0) return error.CantOpenFile;
            return .{ .posix = file };
        },
    }
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

test "created POSIX files are close-on-exec" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/record.cast", .{tmp.sub_path});
    const file = try create(path, .nonblocking);
    defer close(file);

    const flags = std.c.fcntl(file.posix, std.c.F.GETFD);
    try std.testing.expect(flags >= 0);
    try std.testing.expect(flags & std.c.FD_CLOEXEC != 0);
}
