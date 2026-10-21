//! The hang-up watcher: one daemon-wide thread polls the connections of
//! open waits, so a client that goes away ends its wait at once instead of
//! at its deadline. Only a full hang-up counts: a client that shut down
//! its sending side can still read the answer.
//!
//! Linux only: elsewhere poll does not report a hang-up without asking for
//! input, and input is also reported for a half-close, so a wait there
//! runs until its answer or its deadline.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const evaluator = @import("evaluator.zig");

const Waiter = evaluator.Waiter;

const Entry = struct {
    fd: std.c.fd_t,
    waiter: *Waiter,
};

const gpa = std.heap.page_allocator;
var mutex: std.Io.Mutex = .init;
var entries: std.ArrayListUnmanaged(Entry) = .empty;
/// Wakes the thread when the entries change.
var wake_pipe: [2]std.c.fd_t = .{ -1, -1 };
var started = false;

/// Cancel `w` when the client on `fd` hangs up, until `unwatch`.
pub fn watch(fd: std.c.fd_t, w: *Waiter) void {
    if (builtin.os.tag != .linux) return;
    const io = io_mod.io();
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (!started) {
            startLocked() catch |err| {
                std.log.err("cannot watch waiting clients for hang-ups: {}", .{err});
                return;
            };
        }
        entries.append(gpa, .{ .fd = fd, .waiter = w }) catch return;
        w.retain();
    }
    poke();
}

pub fn unwatch(w: *Waiter) void {
    if (builtin.os.tag != .linux) return;
    const io = io_mod.io();
    const found = blk: {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        for (entries.items, 0..) |entry, i| {
            if (entry.waiter != w) continue;
            _ = entries.swapRemove(i);
            break :blk true;
        }
        break :blk false;
    };
    if (!found) return;
    w.release();
    poke();
}

/// Whether the client on `fd` hung up, for requests that check now and
/// then instead of waiting; Linux only, as above.
pub fn hungUp(fd: std.c.fd_t) bool {
    if (builtin.os.tag != .linux) return false;
    var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = 0, .revents = 0 }};
    return std.c.poll(&pfd, 1, 0) > 0 and pfd[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR) != 0;
}

/// Whether the client on `fd`, which sends nothing after its request (an
/// events stream), went away. Off Linux, where poll does not report a
/// hang-up by itself, the end of its input counts as one.
pub fn gone(fd: std.c.fd_t) bool {
    if (builtin.os.tag == .linux) return hungUp(fd);
    if (builtin.os.tag == .windows) return false;
    var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    if (std.c.poll(&pfd, 1, 0) <= 0) return false;
    if (pfd[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR | std.c.POLL.NVAL) != 0) return true;
    var byte: [1]u8 = undefined;
    const n = std.c.recv(fd, &byte, 1, std.c.MSG.PEEK | std.c.MSG.DONTWAIT);
    if (n > 0) return false;
    if (n == 0) return true;
    return switch (std.posix.errno(n)) {
        .AGAIN, .INTR => false,
        else => true,
    };
}

fn startLocked() !void {
    if (std.c.pipe(&wake_pipe) != 0) return error.PipeFailed;
    errdefer for (&wake_pipe) |*fd| {
        _ = std.c.close(fd.*);
        fd.* = -1;
    };
    for (wake_pipe) |fd| {
        _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        _ = std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
    }
    const thread = try std.Thread.spawn(.{}, loop, .{});
    thread.detach();
    started = true;
}

fn poke() void {
    const byte = [1]u8{0};
    _ = std.c.write(wake_pipe[1], &byte, 1);
}

fn loop() void {
    const io = io_mod.io();
    const POLL = std.c.POLL;
    var fds: std.ArrayListUnmanaged(std.c.pollfd) = .empty;
    var owners: std.ArrayListUnmanaged(*Waiter) = .empty;
    while (true) {
        fds.clearRetainingCapacity();
        owners.clearRetainingCapacity();
        const listed = blk: {
            mutex.lockUncancelable(io);
            defer mutex.unlock(io);
            fds.ensureTotalCapacity(gpa, entries.items.len + 1) catch break :blk false;
            owners.ensureTotalCapacity(gpa, entries.items.len) catch break :blk false;
            fds.appendAssumeCapacity(.{ .fd = wake_pipe[0], .events = POLL.IN, .revents = 0 });
            for (entries.items) |entry| {
                // No events: Linux reports POLLHUP and POLLERR anyway, and
                // a half-closed client stays readable without hanging up.
                fds.appendAssumeCapacity(.{ .fd = entry.fd, .events = 0, .revents = 0 });
                owners.appendAssumeCapacity(entry.waiter);
            }
            break :blk true;
        };
        if (!listed) {
            std.Io.sleep(io, .fromMilliseconds(100), .boot) catch {};
            continue;
        }
        const rc = std.c.poll(fds.items.ptr, @intCast(fds.items.len), -1);
        if (rc < 0) {
            if (std.posix.errno(rc) != .INTR) std.Io.sleep(io, .fromMilliseconds(100), .boot) catch {};
            continue;
        }
        if (fds.items[0].revents & POLL.IN != 0) {
            var buf: [64]u8 = undefined;
            while (std.c.read(wake_pipe[0], &buf, buf.len) > 0) {}
        }
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        for (fds.items[1..], owners.items) |pfd, w| {
            if (pfd.revents & (POLL.HUP | POLL.ERR | POLL.NVAL) == 0) continue;
            // It may have been unwatched since the poll started.
            for (entries.items, 0..) |entry, i| {
                if (entry.waiter != w or entry.fd != pfd.fd) continue;
                _ = entries.swapRemove(i);
                w.cancel();
                w.release();
                break;
            }
        }
    }
}
