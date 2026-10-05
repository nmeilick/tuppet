//! PTY creation: openpty on POSIX, ConPTY on Windows.

const std = @import("std");
const builtin = @import("builtin");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else @import("win32_stub.zig");

const c = if (builtin.os.tag == .windows)
    struct {}
else
    @cImport({
        @cInclude("sys/ioctl.h");
    });

const PosixFd = if (builtin.os.tag == .windows) i32 else std.posix.fd_t;

// openpty is in libutil/util.h on macOS (not bundled with Zig's
// darwin headers) and in pty.h on Linux; both export the same C ABI,
// so one extern declaration serves every POSIX target.
extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*const anyopaque,
    winp: ?*const anyopaque,
) c_int;

/// The TIOCSWINSZ request constant on the current POSIX platform
/// (Linux and macOS differ; Windows never uses it).
pub const TIOCSWINSZ = if (builtin.os.tag == .windows) 0 else c.TIOCSWINSZ;

/// The TIOCSCTTY request constant ("make this tty my controlling
/// terminal").
pub const TIOCSCTTY = if (builtin.os.tag == .windows) 0 else c.TIOCSCTTY;

/// Set the kernel pty's window size (rows, cols). Returns false on
/// failure.
pub fn setWinsize(master: std.posix.fd_t, rows: u16, cols: u16) bool {
    var ws: std.posix.winsize = .{
        .row = rows,
        .col = cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    return c.ioctl(master, TIOCSWINSZ, &ws) == 0;
}

pub const Pair = union(enum) {
    posix: struct {
        master: PosixFd,
        slave: PosixFd,
    },
    windows: struct {
        /// Host-side handles: write input to and read output from the
        /// child through the pseudoconsole.
        in_h: ?win32.HANDLE,
        out_h: ?win32.HANDLE,
        hpc: ?win32.HPCON,
    },
};

/// Close every resource still owned by a PTY pair. Closed fields are
/// invalidated so startup rollback and normal teardown can share this path.
pub fn close(pair: *Pair) void {
    switch (builtin.os.tag) {
        .windows => {
            const p = &pair.windows;
            if (p.in_h) |h| {
                _ = win32.CloseHandle(h);
                p.in_h = null;
            }
            if (p.out_h) |h| {
                _ = win32.CloseHandle(h);
                p.out_h = null;
            }
            if (p.hpc) |h| {
                win32.ClosePseudoConsole(h);
                p.hpc = null;
            }
        },
        else => {
            const p = &pair.posix;
            if (p.master >= 0) {
                _ = std.c.close(p.master);
                p.master = -1;
            }
            if (p.slave >= 0) {
                _ = std.c.close(p.slave);
                p.slave = -1;
            }
        },
    }
}

fn setCloseOnExec(fd: PosixFd) bool {
    return std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) == 0;
}

/// Open a new pseudo-terminal pair with the given cell dimensions.
pub fn open(cols: u16, rows: u16) !Pair {
    switch (builtin.os.tag) {
        .windows => {
            var child_in: win32.HANDLE = undefined;
            var host_in: win32.HANDLE = undefined;
            var host_out: win32.HANDLE = undefined;
            var child_out: win32.HANDLE = undefined;
            var child_in_open = false;
            var host_in_open = false;
            var host_out_open = false;
            var child_out_open = false;
            // The child ends must be inheritable so CreatePseudoConsole
            // can duplicate them into the console.
            var sa: win32.SECURITY_ATTRIBUTES = .{
                .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
                .lpSecurityDescriptor = null,
                .bInheritHandle = 1,
            };
            if (win32.CreatePipe(&child_in, &host_in, &sa, 0) == 0) return error.PipeFailed;
            child_in_open = true;
            host_in_open = true;
            errdefer {
                if (child_in_open) _ = win32.CloseHandle(child_in);
                if (host_in_open) _ = win32.CloseHandle(host_in);
            }
            if (win32.CreatePipe(&host_out, &child_out, &sa, 0) == 0) return error.PipeFailed;
            host_out_open = true;
            child_out_open = true;
            errdefer {
                if (host_out_open) _ = win32.CloseHandle(host_out);
                if (child_out_open) _ = win32.CloseHandle(child_out);
            }

            if (win32.SetHandleInformation(host_in, win32.HANDLE_FLAG_INHERIT, 0) == 0 or
                win32.SetHandleInformation(host_out, win32.HANDLE_FLAG_INHERIT, 0) == 0)
            {
                return error.PipeFailed;
            }

            var hpc: win32.HPCON = undefined;
            const hr = win32.CreatePseudoConsole(
                .{ .x = @intCast(cols), .y = @intCast(rows) },
                child_in,
                child_out,
                0,
                &hpc,
            );
            // The console duplicates the handles; the originals can go.
            _ = win32.CloseHandle(child_in);
            child_in_open = false;
            _ = win32.CloseHandle(child_out);
            child_out_open = false;
            if (hr < 0) return error.PseudoConsoleFailed;

            return .{ .windows = .{
                .in_h = host_in,
                .out_h = host_out,
                .hpc = hpc,
            } };
        },
        else => {
            var master: c_int = undefined;
            var slave: c_int = undefined;
            if (openpty(&master, &slave, null, null, null) != 0) return error.OpenPtyFailed;
            errdefer {
                _ = std.c.close(master);
                _ = std.c.close(slave);
            }
            if (!setCloseOnExec(master) or !setCloseOnExec(slave)) return error.OpenPtyFailed;
            // The session never blocks on the master: reads are polled and
            // writes give up when the child stops reading.
            const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
            const flags = std.c.fcntl(master, std.c.F.GETFL);
            if (flags < 0 or std.c.fcntl(master, std.c.F.SETFL, flags | nonblock) < 0) return error.OpenPtyFailed;

            var ws: std.posix.winsize = .{
                .row = rows,
                .col = cols,
                .xpixel = 0,
                .ypixel = 0,
            };
            _ = c.ioctl(slave, TIOCSWINSZ, &ws);

            return .{ .posix = .{
                .master = @intCast(master),
                .slave = @intCast(slave),
            } };
        },
    }
}

test "POSIX PTY descriptors are close-on-exec" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var pair = try open(80, 24);
    defer close(&pair);
    const master_flags = std.c.fcntl(pair.posix.master, std.c.F.GETFD);
    const slave_flags = std.c.fcntl(pair.posix.slave, std.c.F.GETFD);
    try std.testing.expect(master_flags >= 0);
    try std.testing.expect(slave_flags >= 0);
    try std.testing.expect(master_flags & std.c.FD_CLOEXEC != 0);
    try std.testing.expect(slave_flags & std.c.FD_CLOEXEC != 0);
}
