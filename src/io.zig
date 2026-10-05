//! Process-wide std.Io instance. Zig 0.16 routes file, process, socket,
//! sleep, and clock operations through an `Io`; tuppet keeps one Threaded
//! instance for the whole process. The real process environment must be
//! passed in so spawned children (the daemon) inherit it.

const std = @import("std");

var instance: std.Io.Threaded = undefined;
pub var environ: std.process.Environ = undefined;

pub fn init(gpa: std.mem.Allocator, environ_in: std.process.Environ) void {
    environ = environ_in;
    instance = std.Io.Threaded.init(gpa, .{ .environ = environ_in });
}

pub fn io() std.Io {
    return instance.io();
}

/// Monotonic time in nanoseconds.
pub fn nowNanos() i64 {
    const ts = std.Io.Clock.Timestamp.now(io(), .boot);
    return @intCast(ts.raw.nanoseconds);
}
