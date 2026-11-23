//! The hang-up watcher: one daemon-wide thread polls the connections of
//! open waits, so a client that goes away ends its wait at once instead of
//! at its deadline, and the connections of leases, so the session a lease
//! keeps alive is stopped once its client goes. Only a full hang-up
//! counts: a client that shut down its sending side can still read the
//! answer.
//!
//! Linux only: elsewhere poll does not report a hang-up without asking for
//! input, and input is also reported for a half-close, so a wait there
//! runs until its answer or its deadline.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const evaluator = @import("evaluator.zig");
const registry = @import("registry.zig");

const Waiter = evaluator.Waiter;

const Entry = struct {
    fd: std.c.fd_t,
    target: union(enum) {
        waiter: *Waiter,
        /// The session a lease keeps alive; the entry owns `fd`.
        lease: u64,
    },
    /// Never repeats, unlike a descriptor and a waiter's address, which a
    /// later watch may reuse while the thread still polls the old ones.
    id: u64,
};

const gpa = std.heap.page_allocator;
var mutex: std.Io.Mutex = .init;
var entries: std.ArrayListUnmanaged(Entry) = .empty;
var next_id: u64 = 0;
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
        entries.append(gpa, .{ .fd = fd, .target = .{ .waiter = w }, .id = next_id }) catch return;
        next_id += 1;
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
            if (entry.target != .waiter or entry.target.waiter != w) continue;
            _ = entries.swapRemove(i);
            break :blk true;
        }
        break :blk false;
    };
    if (!found) return;
    w.release();
    poke();
}

/// Keep session `id` alive while the client on `fd` stays: once it hangs
/// up, the session is stopped as `stop` does. Takes over `fd`; Linux
/// only.
pub fn lease(fd: std.c.fd_t, id: u64) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const io = io_mod.io();
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (!started) try startLocked();
        try entries.append(gpa, .{ .fd = fd, .target = .{ .lease = id }, .id = next_id });
        next_id += 1;
    }
    poke();
}

/// Session `id` ended: its leases close, which their clients read as the
/// end of the stream.
pub fn endLeases(id: u64) void {
    if (builtin.os.tag != .linux) return;
    const io = io_mod.io();
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        var i: usize = 0;
        while (i < entries.items.len) {
            const entry = entries.items[i];
            if (entry.target == .lease and entry.target.lease == id) {
                _ = std.c.close(entry.fd);
                _ = entries.swapRemove(i);
            } else i += 1;
        }
    }
    poke();
}

fn stopLeased(id: u64) void {
    const s = registry.acquire(id) orelse return;
    defer registry.release(s);
    s.stop() catch |err| std.log.err("session {d}: its lease closed, but it could not be stopped: {}", .{ id, err });
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
    // Close-on-exec from the start: another thread may fork meanwhile.
    if (std.c.pipe2(&wake_pipe, .{ .CLOEXEC = true, .NONBLOCK = true }) != 0) return error.PipeFailed;
    errdefer for (&wake_pipe) |*fd| {
        _ = std.c.close(fd.*);
        fd.* = -1;
    };
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
    var owners: std.ArrayListUnmanaged(u64) = .empty;
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
                owners.appendAssumeCapacity(entry.id);
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
        for (fds.items[1..], owners.items) |pfd, id| {
            if (pfd.revents & (POLL.HUP | POLL.ERR | POLL.NVAL) == 0) continue;
            // It may have been unwatched since the poll started.
            for (entries.items, 0..) |entry, i| {
                if (entry.id != id) continue;
                _ = entries.swapRemove(i);
                switch (entry.target) {
                    .waiter => |w| {
                        w.cancel();
                        w.release();
                    },
                    .lease => |session| {
                        _ = std.c.close(entry.fd);
                        std.log.info("session {d}: its lease closed; stopping it", .{session});
                        const t = std.Thread.spawn(.{}, stopLeased, .{session}) catch |err| {
                            std.log.err("session {d}: cannot stop it after its lease closed: {}", .{ session, err });
                            break;
                        };
                        t.detach();
                    },
                }
                break;
            }
        }
    }
}
