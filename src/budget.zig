//! The daemon's memory budget, TUPPET_MEMORY: how much memory its
//! sessions may use together. Each session reserves its floor, what its
//! screens need (limits.sessionFloor), before its terminal is made, grows,
//! or loads, and is refused when the floors do not fit: Ghostty cannot
//! fail an allocation once a screen exists. History is charged as it is
//! allocated; when sessions together use more than
//! the budget, registry.trimHistory takes the oldest history of those
//! that keep the most.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const units = @import("units.zig");

/// The budget in bytes; null when TUPPET_MEMORY is off.
var total: ?u64 = null;
/// The sessions' floors, and what they use: each its floor or more.
var floors: u64 = 0;
var used: u64 = 0;
var mutex: std.Io.Mutex = .init;

/// Frees floors that can be loaded again, before a reservation is
/// refused; returns whether it freed any. Set by the registry.
pub var reclaim: ?*const fn () bool = null;

/// The budget without TUPPET_MEMORY: a quarter of the memory the daemon
/// may use, the machine's or its cgroup's, whichever is less.
fn defaultTotal() u64 {
    const floor: u64 = 512 << 20;
    var memory: u64 = std.process.totalSystemMemory() catch return 4 << 30;
    if (cgroupLimit()) |limit| memory = @min(memory, limit);
    return @max(floor, memory / 4);
}

/// Read TUPPET_MEMORY once, at start.
pub fn init() void {
    total = defaultTotal();
    if (std.c.getenv("TUPPET_MEMORY")) |env| {
        const value = std.mem.span(env);
        if (std.mem.eql(u8, value, "off")) {
            total = null;
        } else if (units.parseByteSize(value)) |bytes| {
            if (bytes > 0) total = bytes else std.log.warn("ignoring TUPPET_MEMORY=0: a budget of nothing refuses every session; 'off' turns the budget off", .{});
        } else std.log.warn("ignoring TUPPET_MEMORY={s}: expected bytes, optionally with K, M, or G, or off", .{value});
    }
    if (total) |t| {
        std.log.info("memory budget for sessions: {d} MiB (TUPPET_MEMORY)", .{t >> 20});
    } else std.log.info("memory budget for sessions: off (TUPPET_MEMORY=off)", .{});
}

/// Reserve a new session's floor, which it also uses from now on.
pub fn reserve(floor: u64) error{OverBudget}!void {
    try exchange(0, floor);
    account(0, floor);
}

/// Give back a floor and what its session used.
pub fn release(floor: u64, held: u64) void {
    force(floor, 0);
    account(held, 0);
}

/// Swap a floor of `old` for one of `new`; nothing changes when `new`
/// does not fit. Shrinking always fits.
pub fn exchange(old: u64, new: u64) error{OverBudget}!void {
    if (tryExchange(old, new)) return;
    // Nothing to free when even an empty budget is too small.
    if (total) |t| if (new > t) return error.OverBudget;
    if (reclaim) |free| if (free() and tryExchange(old, new)) return;
    return error.OverBudget;
}

fn tryExchange(old: u64, new: u64) bool {
    const io = io_mod.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const others = floors - old;
    if (new > old) if (total) |t| if (new > t or others > t - new) return false;
    floors = others + new;
    return true;
}

/// Swap a floor of `old` for one of `new` even when `new` does not fit:
/// for a session that returns to a size it had before.
pub fn force(old: u64, new: u64) void {
    const io = io_mod.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    floors = floors - old + new;
}

/// A session went from using `old` bytes to using `new`.
pub fn account(old: u64, new: u64) void {
    const io = io_mod.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    used = used - old + new;
}

/// The bytes of history to trim: none until the sessions use more than
/// the budget, then enough to come back below it by a margin, so the next
/// trim waits for some growth.
pub fn excess() u64 {
    const io = io_mod.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const t = total orelse return 0;
    if (used <= t) return 0;
    return used - (t - marginLocked(t));
}

/// 1/16 of the budget, or half of what the floors leave of it when that is
/// less: trimming to below the floors would take all history.
fn marginLocked(t: u64) u64 {
    return @min(t / 16, (t -| floors) / 2);
}

/// What sessions may still allocate before the budget is full.
pub fn room() u64 {
    const io = io_mod.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const t = total orelse return std.math.maxInt(u64);
    return t -| used;
}

/// Whether trimmed sessions may keep their full history again: they use
/// four margins less than the budget (3/4 of it at most), well below where
/// trimming starts.
pub fn roomy() bool {
    const io = io_mod.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const t = total orelse return true;
    return used + 4 * marginLocked(t) <= t;
}

pub fn enabled() bool {
    const io = io_mod.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return total != null;
}

/// The budget in MiB for log lines; 0 when it is off.
pub fn totalMiB() u64 {
    return (total orelse 0) >> 20;
}

/// Why `asked` more bytes did not fit, for the end of a message.
pub fn describe(buf: []u8, asked: u64) []const u8 {
    const io = io_mod.io();
    mutex.lockUncancelable(io);
    const in_use = floors;
    const t = total orelse 0;
    mutex.unlock(io);
    const mib = 1 << 20;
    return std.fmt.bufPrint(buf, "its screens need {d} MiB more of the daemon's {d} MiB memory budget, of which the screens of other sessions take {d} MiB; remove ended sessions with 'tuppet remove', or start the daemon with a larger TUPPET_MEMORY", .{
        std.math.divCeil(u64, asked, mib) catch unreachable,
        t / mib,
        std.math.divCeil(u64, in_use, mib) catch unreachable,
    }) catch "it does not fit the daemon's memory budget (TUPPET_MEMORY)";
}

/// The lowest memory.max of the daemon's cgroup and those above it
/// (Linux, cgroup v2); null when none is set.
fn cgroupLimit() ?u64 {
    if (builtin.os.tag != .linux) return null;
    const io = io_mod.io();
    const dir = std.Io.Dir.cwd();
    var raw: [4096]u8 = undefined;
    const text = dir.readFile(io, "/proc/self/cgroup", &raw) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const group = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) break line[3..];
    } else return null;
    var lowest: ?u64 = null;
    var path = group;
    while (true) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const file = std.fmt.bufPrint(&path_buf, "/sys/fs/cgroup{s}/memory.max", .{std.mem.trimEnd(u8, path, "/")}) catch return lowest;
        var value_buf: [32]u8 = undefined;
        if (dir.readFile(io, file, &value_buf)) |value| {
            if (std.fmt.parseInt(u64, std.mem.trim(u8, value, " \n"), 10)) |limit| {
                lowest = @min(lowest orelse limit, limit);
            } else |_| {}
        } else |_| {}
        if (path.len <= 1) return lowest;
        path = path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse return lowest];
    }
}

test "floors stay within the budget, use may pass it and is trimmed back" {
    total = 160;
    floors = 0;
    used = 0;
    defer total = null;
    try reserve(60);
    try std.testing.expectError(error.OverBudget, reserve(110));
    try exchange(60, 30);
    try reserve(70);
    try std.testing.expectError(error.OverBudget, exchange(30, 91));
    force(30, 40);
    try std.testing.expectEqual(@as(u64, 110), floors);
    try std.testing.expectEqual(@as(u64, 0), excess());
    // History grows past the budget: trim back to 15/16 of it.
    account(70, 130);
    try std.testing.expectEqual(@as(u64, 190 - 150), excess());
    try std.testing.expect(!roomy());
    account(130, 50);
    try std.testing.expect(roomy());
    // Floors near the budget leave history half of the rest.
    force(40, 80);
    account(60, 120);
    try std.testing.expectEqual(@as(u64, 170 - 155), excess());
    force(80, 40);
    account(120, 60);
    release(40, 60);
    release(70, 50);
    try std.testing.expectEqual(@as(u64, 0), floors);
    try std.testing.expectEqual(@as(u64, 0), used);
}
