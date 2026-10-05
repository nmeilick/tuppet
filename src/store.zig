//! The session store: what tuppet keeps on disk about sessions. It lives in
//! $XDG_STATE_HOME/tuppet (by default ~/.local/state/tuppet; %LOCALAPPDATA%\tuppet
//! on Windows), with one directory per machine, so a home shared between
//! machines keeps them apart, and in it one directory per boot:
//!
//!     <boot>/lock                serializes changes across daemons
//!     <boot>/last-id             the last session id handed out
//!     <boot>/<id>/session.json   what ran, and how it ended
//!     <boot>/<id>/screen.vt      the final screen and history
//!     <boot>/<id>/running        locked by the daemon while the program runs
//!     <boot>/<id>/output.cast    a recording made with `tuppet run --record`
//!
//! Ids count up from 1 in each boot and are never reused within it, so
//! every daemon of the user shares one numbering, and an id can never name
//! a session from an earlier boot. Sessions cannot outlive their boot, so
//! a starting daemon deletes other boots' directories; ended sessions are
//! deleted a while after they ended.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const win32 = if (builtin.os.tag == .windows) @import("win32.zig") else @import("win32_stub.zig");

const Dir = std.Io.Dir;
const File = std.Io.File;

/// What session.json holds.
pub const Meta = struct {
    id: u64 = 0,
    name: []const u8 = "",
    argv: []const []const u8 = &.{},
    cwd: []const u8 = "",
    /// The endpoint of the daemon that ran the session.
    socket: []const u8 = "",
    pid: u32 = 0,
    cols: u16 = 120,
    rows: u16 = 40,
    /// History limit in bytes.
    scrollback: u64 = 0,
    /// Unix time in milliseconds.
    started_ms: i64 = 0,
    /// When the program ended, or when the session was found lost.
    ended_ms: ?i64 = null,
    /// Exit status; death by signal n is -n. Null while running and when
    /// the session was lost.
    exit_code: ?i32 = null,
    /// The daemon stopped while the program ran, so how it ended and its
    /// final screen are unknown.
    lost: bool = false,
    /// The recording made with `tuppet run --record`, if any.
    recording: ?[]const u8 = null,
};

pub const meta_file = "session.json";
pub const screen_file = "screen.vt";
const running_file = "running";

var root_buf: [std.fs.max_path_bytes]u8 = undefined;
/// The store's directory, shared by all machines.
var root: []const u8 = "";
var machine_buf: [std.fs.max_path_bytes]u8 = undefined;
/// This machine's directory in the store.
var machine_root: []const u8 = "";
var boot_buf: [64]u8 = undefined;
var boot: []const u8 = "";
var boot_dir: Dir = undefined;
var opened = false;

/// Find or create the store for the current boot. The daemon calls this
/// once, before it serves anything.
pub fn open(gpa: std.mem.Allocator) !void {
    const io = io_mod.io();
    root = try rootPath(gpa, &root_buf);
    boot = try readBootId(&boot_buf);
    var machine_id_buf: [64]u8 = undefined;
    const machine = try readMachineId(gpa, &machine_id_buf);
    machine_root = std.fmt.bufPrint(&machine_buf, "{s}{c}{s}", .{ root, std.fs.path.sep, machine }) catch return error.NameTooLong;
    try makePath(machine_root);
    {
        // Opened for iteration: a path-only handle cannot change permissions.
        const root_dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer root_dir.close(io);
        try makePrivate(root_dir);
    }
    const machine_dir = try Dir.cwd().openDir(io, machine_root, .{});
    defer machine_dir.close(io);
    try makeDir(machine_dir, boot);
    boot_dir = try machine_dir.openDir(io, boot, .{ .iterate = true });
    opened = true;
}

/// Use `dir` as the current boot's directory (tests).
fn openAt(dir: Dir, boot_name: []const u8) void {
    boot_dir = dir;
    @memcpy(boot_buf[0..boot_name.len], boot_name);
    boot = boot_buf[0..boot_name.len];
    opened = true;
}

pub fn bootId() []const u8 {
    return boot;
}

pub fn rootDir() []const u8 {
    return root;
}

/// The store's directory: set HOME (or XDG_STATE_HOME) for it.
fn rootPath(gpa: std.mem.Allocator, buf: []u8) ![]const u8 {
    const env = io_mod.environ;
    if (builtin.os.tag == .windows) {
        const local = env.getAlloc(gpa, "LOCALAPPDATA") catch return error.NoStateDir;
        defer gpa.free(local);
        return std.fmt.bufPrint(buf, "{s}\\tuppet", .{local}) catch error.NoStateDir;
    }
    if (env.getAlloc(gpa, "XDG_STATE_HOME")) |state| {
        defer gpa.free(state);
        // The XDG spec ignores relative paths.
        if (std.fs.path.isAbsolute(state)) return std.fmt.bufPrint(buf, "{s}/tuppet", .{state}) catch error.NoStateDir;
    } else |_| {}
    const home = env.getAlloc(gpa, "HOME") catch return error.NoStateDir;
    defer gpa.free(home);
    if (!std.fs.path.isAbsolute(home)) return error.NoStateDir;
    return std.fmt.bufPrint(buf, "{s}/.local/state/tuppet", .{home}) catch error.NoStateDir;
}

/// An identifier that changes with every boot of the machine.
fn readBootId(buf: *[64]u8) ![]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            var raw: [64]u8 = undefined;
            const got = Dir.cwd().readFile(io_mod.io(), "/proc/sys/kernel/random/boot_id", &raw) catch return error.NoBootId;
            const id = std.mem.trim(u8, got, " \n");
            if (!isBootName(id)) return error.NoBootId;
            @memcpy(buf[0..id.len], id);
            return buf[0..id.len];
        },
        .macos => {
            var len: usize = buf.len;
            if (std.c.sysctlbyname("kern.bootsessionuuid", buf, &len, null, 0) != 0) return error.NoBootId;
            const id = std.mem.sliceTo(buf[0..len], 0);
            if (!isBootName(id)) return error.NoBootId;
            return id;
        },
        .windows => {
            const id = win32.bootCount() orelse return error.NoBootId;
            return std.fmt.bufPrint(buf, "{d}", .{id}) catch unreachable;
        },
        else => return error.NoBootId,
    }
}

/// An identifier of this machine: the OS's machine id, or its host name.
fn readMachineId(gpa: std.mem.Allocator, buf: *[64]u8) ![]const u8 {
    switch (builtin.os.tag) {
        .linux => for ([_][]const u8{ "/etc/machine-id", "/var/lib/dbus/machine-id" }) |path| {
            var raw: [64]u8 = undefined;
            const got = Dir.cwd().readFile(io_mod.io(), path, &raw) catch continue;
            const id = std.mem.trim(u8, got, " \n");
            if (isMachineName(id)) return copyName(buf, id);
        },
        // The hardware UUID; kern.uuid names the kernel build instead.
        .macos => {
            var uuid: [16]u8 = undefined;
            const wait: std.c.timespec = .{ .sec = 1, .nsec = 0 };
            if (gethostuuid(&uuid, &wait) == 0) {
                const hex = std.fmt.bytesToHex(uuid, .lower);
                return std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
            }
        },
        .windows => if (win32.machineGuid(buf)) |id| {
            if (isMachineName(id)) return id;
        },
        else => {},
    }
    const host = (if (builtin.os.tag == .windows)
        io_mod.environ.getAlloc(gpa, "COMPUTERNAME")
    else
        io_mod.environ.getAlloc(gpa, "HOSTNAME")) catch blk: {
        if (builtin.os.tag == .windows) return error.NoMachineId;
        var uts: std.posix.utsname = undefined;
        if (std.c.uname(&uts) != 0) return error.NoMachineId;
        break :blk try gpa.dupe(u8, std.mem.sliceTo(&uts.nodename, 0));
    };
    defer gpa.free(host);
    if (!isMachineName(host)) return error.NoMachineId;
    return copyName(buf, host);
}

fn copyName(buf: *[64]u8, name: []const u8) []const u8 {
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

extern "c" fn gethostuuid(id: *[16]u8, wait: *const std.c.timespec) c_int;

/// A machine directory name: no path separators, no leading dot.
fn isMachineName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |c| switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

/// Boot ids are UUIDs (Linux, macOS) or counters (Windows). Only names of
/// this shape are ever deleted as another boot's directory.
fn isBootName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F', '-' => {},
        else => return false,
    };
    return true;
}

/// Create `path` and any missing parents. Not std's createDirPath: that
/// stats existing directories with statx, which kernels before 4.11 lack.
/// Opening the result as a directory checks what an existing one is.
fn makePath(path: []const u8) !void {
    var end: usize = 0;
    while (end < path.len) {
        end = std.mem.indexOfAnyPos(u8, path, end + 1, if (builtin.os.tag == .windows) "/\\" else "/") orelse path.len;
        if (end == 0 or (builtin.os.tag == .windows and path[end - 1] == ':')) continue;
        try makeDir(Dir.cwd(), path[0..end]);
    }
}

fn makeDir(dir: Dir, sub_path: []const u8) !void {
    dir.createDir(io_mod.io(), sub_path, dirPermissions()) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn dirPermissions() Dir.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn filePermissions() File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

/// The store belongs to one user, and session output is private, also
/// when the directory already existed. A store owned by someone else
/// (HOME kept across sudo, say) is refused rather than shared.
fn makePrivate(dir: Dir) !void {
    if (builtin.os.tag == .windows) return;
    if (!ipc.ownedByCurrentUser(dir.handle)) return error.StoreOwnedByAnotherUser;
    try dir.setPermissions(io_mod.io(), .fromMode(0o700));
}

fn idName(buf: *[24]u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{id}) catch unreachable;
}

fn parseId(name: []const u8) ?u64 {
    if (name.len == 0 or name.len > 20 or name[0] == '0') return null;
    for (name) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u64, name, 10) catch null;
}

/// Hold the boot's lock, which serializes id allocation and housekeeping
/// across every daemon of the user.
fn lockBoot() !File {
    return boot_dir.createFile(io_mod.io(), "lock", .{ .truncate = false, .lock = .exclusive, .permissions = filePermissions() });
}

/// A new session: its id, and the lock that marks it running until
/// `finish` or `discard` releases it.
pub const Created = struct { id: u64, running: File };

/// Allocate the next id and create the session's directory with `meta`.
pub fn create(gpa: std.mem.Allocator, meta: Meta) !Created {
    const io = io_mod.io();
    const lock = try lockBoot();
    defer lock.close(io);

    var id = (try lastId(gpa)) + 1;
    var name_buf: [24]u8 = undefined;
    // An existing directory means last-id was behind; never reuse it.
    while (boot_dir.openDir(io, idName(&name_buf, id), .{})) |existing| : (id += 1) {
        existing.close(io);
    } else |err| if (err != error.FileNotFound) return err;
    // The id is taken before its directory exists, so whatever happens
    // next, it is never handed out again.
    var id_text: [24]u8 = undefined;
    try writeAtomic(boot_dir, "last-id", idName(&id_text, id));
    try boot_dir.createDir(io, idName(&name_buf, id), dirPermissions());
    var dir = try boot_dir.openDir(io, idName(&name_buf, id), .{});
    defer dir.close(io);
    const running = dir.createFile(io, running_file, .{ .lock = .exclusive, .lock_nonblocking = true, .permissions = filePermissions() }) catch |err| {
        removeSession(id);
        return err;
    };
    errdefer {
        running.close(io);
        removeSession(id);
    }
    var with_id = meta;
    with_id.id = id;
    try writeMetaIn(gpa, dir, with_id);
    return .{ .id = id, .running = running };
}

/// The highest id handed out so far: last-id, or the highest session
/// directory if last-id is missing or damaged.
fn lastId(gpa: std.mem.Allocator) !u64 {
    var buf: [32]u8 = undefined;
    if (boot_dir.readFile(io_mod.io(), "last-id", &buf)) |text| {
        if (parseId(std.mem.trim(u8, text, " \n"))) |id| return id;
    } else |err| if (err != error.FileNotFound) return err;
    const all = try ids(gpa);
    defer gpa.free(all);
    return if (all.len == 0) 0 else all[all.len - 1];
}

/// Record the program's pid once it has started.
pub fn setPid(gpa: std.mem.Allocator, id: u64, pid: u32) void {
    const io = io_mod.io();
    var name_buf: [24]u8 = undefined;
    var dir = boot_dir.openDir(io, idName(&name_buf, id), .{}) catch return;
    defer dir.close(io);
    const parsed = (readMeta(gpa, id) catch null) orelse return;
    defer parsed.deinit();
    var meta = parsed.value;
    meta.pid = pid;
    writeMetaIn(gpa, dir, meta) catch |err| std.log.err("session {d}: cannot save its pid: {}", .{ id, err });
}

/// How a session ended, and the size its final screen has.
pub const Ending = struct {
    pid: u32,
    exit_code: i32,
    cols: u16,
    rows: u16,
};

/// Record how a session ended, then release its running lock.
pub fn finish(gpa: std.mem.Allocator, id: u64, ending: Ending, screen: []const u8, running: File) void {
    const io = io_mod.io();
    defer running.close(io);
    var name_buf: [24]u8 = undefined;
    var dir = boot_dir.openDir(io, idName(&name_buf, id), .{}) catch |err| {
        std.log.err("session {d}: cannot open its store directory: {}", .{ id, err });
        return;
    };
    defer dir.close(io);
    const parsed = (readMeta(gpa, id) catch null) orelse {
        std.log.err("session {d}: its stored metadata is gone", .{id});
        return;
    };
    defer parsed.deinit();
    var meta = parsed.value;
    meta.pid = ending.pid;
    meta.exit_code = ending.exit_code;
    meta.cols = ending.cols;
    meta.rows = ending.rows;
    meta.ended_ms = nowMillis();
    meta.lost = false;
    // The screen first: a session whose metadata says it ended has one.
    writeAtomic(dir, screen_file, screen) catch |err| std.log.err("session {d}: cannot save its screen: {}", .{ id, err });
    writeMetaIn(gpa, dir, meta) catch |err| std.log.err("session {d}: cannot save how it ended: {}", .{ id, err });
    // Still locked while it goes, so nobody takes the session for lost.
    dir.deleteFile(io, running_file) catch {};
}

/// Undo `create` for a session whose program never started.
pub fn discard(id: u64, running: File) void {
    // Deleted while still locked, so housekeeping never sees it unlocked
    // and takes it for lost.
    removeSession(id);
    running.close(io_mod.io());
}

pub fn readMeta(gpa: std.mem.Allocator, id: u64) !?std.json.Parsed(Meta) {
    var name_buf: [24]u8 = undefined;
    var path_buf: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ idName(&name_buf, id), meta_file }) catch unreachable;
    const text = boot_dir.readFileAlloc(io_mod.io(), path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(text);
    return try std.json.parseFromSlice(Meta, gpa, text, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

pub fn readScreen(gpa: std.mem.Allocator, id: u64) ![]u8 {
    var name_buf: [24]u8 = undefined;
    var path_buf: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ idName(&name_buf, id), screen_file }) catch unreachable;
    return boot_dir.readFileAlloc(io_mod.io(), path, gpa, .limited(1 << 30));
}

/// The absolute path of a file in a session's directory.
pub fn sessionFile(buf: []u8, id: u64, name: []const u8) ![]const u8 {
    const sep = std.fs.path.sep;
    return std.fmt.bufPrint(buf, "{s}{c}{s}{c}{d}{c}{s}", .{ machine_root, sep, boot, sep, id, sep, name }) catch error.NameTooLong;
}

/// Whether a daemon is running the session's program right now.
pub fn isRunning(id: u64) bool {
    const io = io_mod.io();
    var name_buf: [24]u8 = undefined;
    var dir = boot_dir.openDir(io, idName(&name_buf, id), .{}) catch return false;
    defer dir.close(io);
    const file = dir.openFile(io, running_file, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true }) catch |err| {
        return err == error.WouldBlock;
    };
    file.close(io);
    return false;
}

/// Every session id in the current boot, ascending.
pub fn ids(gpa: std.mem.Allocator) ![]u64 {
    var list: std.ArrayList(u64) = .empty;
    errdefer list.deinit(gpa);
    const io = io_mod.io();
    // A handle of its own: iterating rewinds and reads through the
    // descriptor's offset, which concurrent callers would share.
    var dir = try boot_dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const id = parseId(entry.name) orelse continue;
        switch (entry.kind) {
            .directory => {},
            // Some filesystems do not report entry types; opening tells.
            .unknown => {
                const sub_dir = dir.openDir(io, entry.name, .{}) catch continue;
                sub_dir.close(io);
            },
            else => continue,
        }
        try list.append(gpa, id);
    }
    std.mem.sortUnstable(u64, list.items, {}, std.sort.asc(u64));
    return list.toOwnedSlice(gpa);
}

/// Delete a session's directory. Missing files are fine: another daemon
/// may be removing it at the same time.
pub fn removeSession(id: u64) void {
    var name_buf: [24]u8 = undefined;
    boot_dir.deleteTree(io_mod.io(), idName(&name_buf, id)) catch |err| {
        std.log.err("session {d}: cannot delete its store directory: {}", .{ id, err });
    };
}

/// Mark sessions whose daemon stopped while they ran as lost, and delete
/// sessions that ended more than `keep_ms` ago (never, when null).
/// Returns the deleted ids.
pub fn housekeep(gpa: std.mem.Allocator, keep_ms: ?i64) ![]u64 {
    return housekeepAt(gpa, keep_ms, nowMillis());
}

fn housekeepAt(gpa: std.mem.Allocator, keep_ms: ?i64, now: i64) ![]u64 {
    const lock = try lockBoot();
    defer lock.close(io_mod.io());
    var deleted: std.ArrayList(u64) = .empty;
    errdefer deleted.deinit(gpa);
    const all = try ids(gpa);
    defer gpa.free(all);
    for (all) |id| {
        if (isRunning(id)) continue;
        const parsed = readMeta(gpa, id) catch continue orelse {
            // Not even its metadata was written: debris of a failed start.
            removeSession(id);
            try deleted.append(gpa, id);
            continue;
        };
        defer parsed.deinit();
        var meta = parsed.value;
        if (meta.ended_ms == null) {
            meta.ended_ms = now;
            meta.lost = true;
            var name_buf: [24]u8 = undefined;
            var dir = boot_dir.openDir(io_mod.io(), idName(&name_buf, id), .{}) catch continue;
            defer dir.close(io_mod.io());
            writeMetaIn(gpa, dir, meta) catch {};
            continue;
        }
        const keep = keep_ms orelse continue;
        if (now - meta.ended_ms.? >= keep) {
            removeSession(id);
            try deleted.append(gpa, id);
        }
    }
    return deleted.toOwnedSlice(gpa);
}

/// Delete this machine's directories of other boots. Each is first
/// renamed to a hidden name, so a half-deleted one is never mistaken for
/// a boot and daemons starting together never delete the same tree; only
/// names shaped like boot ids, or those hidden names, are touched.
pub fn removeOtherBoots() void {
    const io = io_mod.io();
    var root_dir = Dir.cwd().openDir(io, machine_root, .{ .iterate = true }) catch return;
    defer root_dir.close(io);
    var it = root_dir.iterate();
    var trash_buf: [96]u8 = undefined;
    while (it.next(io) catch return) |entry| {
        // Some filesystems do not report entry types; renaming and
        // deleting work for whatever an old boot's name turns out to be.
        if (entry.kind != .directory and entry.kind != .unknown) continue;
        const trash = if (std.mem.startsWith(u8, entry.name, ".trash-")) entry.name else blk: {
            if (!isBootName(entry.name) or std.mem.eql(u8, entry.name, boot)) continue;
            const name = std.fmt.bufPrint(&trash_buf, ".trash-{s}", .{entry.name}) catch continue;
            root_dir.rename(entry.name, root_dir, name, io) catch continue;
            break :blk name;
        };
        root_dir.deleteTree(io, trash) catch |err| std.log.err("cannot delete an old boot's sessions ({s}): {}", .{ trash, err });
    }
}

pub fn nowMillis() i64 {
    const ts = std.Io.Clock.Timestamp.now(io_mod.io(), .real);
    return @intCast(@divFloor(ts.raw.nanoseconds, std.time.ns_per_ms));
}

fn writeMetaIn(gpa: std.mem.Allocator, dir: Dir, meta: Meta) !void {
    const text = try std.json.Stringify.valueAlloc(gpa, meta, .{});
    defer gpa.free(text);
    try writeAtomic(dir, meta_file, text);
}

/// Replace a file so that readers see either the old or the new content.
fn writeAtomic(dir: Dir, name: []const u8, bytes: []const u8) !void {
    const io = io_mod.io();
    var tmp_buf: [64]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name}) catch return error.NameTooLong;
    {
        const file = try dir.createFile(io, tmp, .{ .permissions = filePermissions() });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
    }
    try dir.rename(tmp, dir, name, io);
}

test "ids count up, survive a lost last-id, and are never reused" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    openAt(tmp.dir, "test-boot");
    const io = io_mod.io();

    const a = try create(gpa, .{ .name = "a" });
    const b = try create(gpa, .{ .name = "b" });
    try std.testing.expectEqual(@as(u64, 1), a.id);
    try std.testing.expectEqual(@as(u64, 2), b.id);
    try std.testing.expect(isRunning(a.id));

    finish(gpa, a.id, .{ .pid = 42, .exit_code = 3, .cols = 80, .rows = 24 }, "screen", a.running);
    try std.testing.expect(!isRunning(a.id));
    const meta = (try readMeta(gpa, a.id)).?;
    defer meta.deinit();
    try std.testing.expectEqual(@as(?i32, 3), meta.value.exit_code);

    // Removing the newest session or losing last-id never brings an id back.
    discard(b.id, b.running);
    const c = try create(gpa, .{});
    try std.testing.expectEqual(@as(u64, 3), c.id);
    try tmp.dir.deleteFile(io, "last-id");
    const d = try create(gpa, .{});
    try std.testing.expectEqual(@as(u64, 4), d.id);
    c.running.close(io);
    d.running.close(io);
}

test "housekeeping marks orphans lost and expires ended sessions" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    openAt(tmp.dir, "test-boot");
    const io = io_mod.io();

    const old = try create(gpa, .{});
    finish(gpa, old.id, .{ .pid = 1, .exit_code = 0, .cols = 80, .rows = 24 }, "", old.running);
    const orphan = try create(gpa, .{});
    orphan.running.close(io); // its daemon died
    const live = try create(gpa, .{});
    defer live.running.close(io);

    // Ended "10 s ago" against a 5 s limit: kept for 5 s, so it goes.
    const deleted = try housekeepAt(gpa, 5_000, nowMillis() + 10_000);
    defer gpa.free(deleted);
    try std.testing.expectEqualSlices(u64, &.{old.id}, deleted);
    const lost = (try readMeta(gpa, orphan.id)).?;
    defer lost.deinit();
    try std.testing.expect(lost.value.lost);
    try std.testing.expect(isRunning(live.id));
    const live_meta = (try readMeta(gpa, live.id)).?;
    defer live_meta.deinit();
    try std.testing.expect(!live_meta.value.lost);
}

test "only directories named like boot ids are other boots" {
    try std.testing.expect(isBootName("2f0a9f1c-6b8e-4c1d-9a51-3c1e5f7d2b40"));
    try std.testing.expect(isBootName("17"));
    try std.testing.expect(!isBootName(".trash-x"));
    try std.testing.expect(!isBootName("notes"));
    try std.testing.expect(!isBootName(""));
}
