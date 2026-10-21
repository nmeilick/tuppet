//! The session store: what tuppet keeps on disk about sessions. It lives in
//! $XDG_STATE_HOME/tuppet (by default ~/.local/state/tuppet; %LOCALAPPDATA%\tuppet
//! on Windows), with one directory per machine, so a home shared between
//! machines keeps them apart, and in it one directory per boot:
//!
//!     <boot>/lock                serializes changes across daemons
//!     <boot>/last-id             the last session id handed out
//!     <boot>/seq                 the highest change seq daemons may have used
//!     <boot>/epoch               how often `tuppet shutdown --reset` reset
//!                                the boot's ids
//!     <boot>/<id>/session.json   what ran, and how it ended
//!     <boot>/<id>/screen.vt      the final screen and history
//!     <boot>/<id>/running        locked by the daemon while the program runs
//!     <boot>/<id>/output.cast    a recording made with `tuppet run --record`
//!                                (output.trace for a trace)
//!     <boot>/<id>/record-N.cast  a recording started without a path
//!                                (record-N.trace for a trace)
//!     <boot>/last-detached       the session `tuppet attach -` returns
//!                                to, kept by the CLI
//!
//! Ids count up from 1 in each boot and are never reused within it, so
//! every daemon of the user shares one numbering, and an id can never name
//! a session from an earlier boot. A reset starts the ids over and counts
//! an epoch up, which daemons report as part of the boot. Sessions cannot outlive their boot, so
//! a starting daemon deletes other boots' directories; ended sessions are
//! deleted a while after they ended.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const RecordFormat = @import("protocol.zig").RecordFormat;
const StopReason = @import("protocol.zig").StopReason;
const status = @import("status.zig");
const alert = @import("alert.zig");
const limits = @import("limits.zig");
const Cwd = status.Cwd;
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
    /// The recording made with `tuppet run --record`, if any: an absolute
    /// path, or a file in the session's directory.
    recording: ?[]const u8 = null,
    recording_format: RecordFormat = .cast,
    /// The change seq the session started at, and its last one.
    start_seq: u64 = 0,
    seq: u64 = 0,
    /// The seq stamped when it ended, and the seq at its latest input.
    end_seq: ?u64 = null,
    input_seq: ?u64 = null,
    /// The seq of its latest resize's reflow.
    resize_seq: ?u64 = null,
    /// Unix time in milliseconds of the last text change, visible change,
    /// and output.
    last_text_ms: ?i64 = null,
    last_change_ms: ?i64 = null,
    last_output_ms: ?i64 = null,
    /// The title and working directory the program reported last, as its
    /// status shows them.
    title: ?[]const u8 = null,
    reported_cwd: ?Cwd = null,
    /// `stop` ended the program.
    stopped: bool = false,
    bell_count: u64 = 0,
    notification_count: u64 = 0,
    notification: ?status.Notification = null,
    /// The bytes the program wrote, its settled draws, and its full
    /// clears; null when they were not recorded.
    out_bytes: ?u64 = null,
    draws: ?u64 = null,
    full_clears: ?u64 = null,
    /// What a client last showed of the session.
    seen: status.Seen = .{},
    /// The session's alerts; `run` like it copies them.
    alerts: []const alert.Rule = &.{},
    /// The latest alert hits, oldest first, as the session's hit log
    /// kept them.
    hits: []const alert.Hit = &.{},
    /// The history limit dropped older output.
    history_dropped: bool = false,
    /// The latest recording, once it stopped, until a stop request
    /// reports it.
    recording_report: RecordingReport = .{},
};

/// What a stop request has yet to report of a session's latest recording.
pub const RecordingReport = struct {
    stopped: ?Stopped = null,
    /// The recording could not be written.
    failed: bool = false,

    pub const Stopped = struct {
        /// Absolute.
        path: []const u8,
        reason: StopReason,
        reported: bool = false,
    };
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
/// The current boot's directory. Replaced when it was deleted and made
/// again; the old handle stays open, as other threads may still use it.
var boot_handle: std.atomic.Value(Dir.Handle) = .init(undefined);
var opened = false;

fn bootDir() Dir {
    return .{ .handle = boot_handle.load(.acquire) };
}

/// Find or create the store for the current boot. The daemon calls this
/// before it serves anything; once it is open, this does nothing.
pub fn open(gpa: std.mem.Allocator) !void {
    if (opened) return;
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
    boot_handle.store((try openBoot()).handle, .release);
    opened = true;
}

/// Open the current boot's directory, making it when it is missing.
fn openBoot() !Dir {
    const io = io_mod.io();
    const machine_dir = try Dir.cwd().openDir(io, machine_root, .{});
    defer machine_dir.close(io);
    try makeDir(machine_dir, boot);
    return machine_dir.openDir(io, boot, .{ .iterate = true });
}

var remake_mutex: std.Io.Mutex = .init;

/// The boot's directory was deleted under the daemon (rm -r of the
/// store): make it, and the store's directories above it, again.
/// Sessions stored before are gone with it.
fn remakeBoot() !void {
    const io = io_mod.io();
    remake_mutex.lockUncancelable(io);
    defer remake_mutex.unlock(io);
    // Made again by another thread meanwhile.
    if (bootDir().createFile(io, "lock", .{ .truncate = false, .permissions = filePermissions() })) |file| {
        file.close(io);
        return;
    } else |err| if (err != error.FileNotFound) return err;
    try makePath(machine_root);
    {
        const root_dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer root_dir.close(io);
        try makePrivate(root_dir);
    }
    boot_handle.store((try openBoot()).handle, .release);
    std.log.warn("the session store directory {s}{c}{s} was deleted; made it again", .{ machine_root, std.fs.path.sep, boot });
}

/// Use `dir` as the current boot's directory (tests).
fn openAt(dir: Dir, boot_name: []const u8) void {
    boot_handle.store(dir.handle, .release);
    @memcpy(boot_buf[0..boot_name.len], boot_name);
    boot = boot_buf[0..boot_name.len];
    opened = true;
}

pub fn bootId() []const u8 {
    return boot;
}

/// The boot as daemons report it: `<boot>`, or `<boot>.<epoch>` once a
/// reset started the ids over. Read anew each time, as another daemon
/// may have reset the store.
pub fn bootLabel(gpa: std.mem.Allocator) ![]u8 {
    const n = readEpoch() catch 0;
    if (n == 0) return gpa.dupe(u8, boot);
    return std.fmt.allocPrint(gpa, "{s}.{d}", .{ boot, n });
}

const epoch_file = "epoch";

fn readEpoch() !u64 {
    var buf: [32]u8 = undefined;
    const text = bootDir().readFile(io_mod.io(), epoch_file, &buf) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    const n = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch return 0;
    // Damaged: counting up from it must not overflow.
    return if (n <= limits.max_seq) n else 0;
}

pub fn rootDir() []const u8 {
    return root;
}

/// Why the store cannot be used, in words, for an error of `open` or of a
/// change to it.
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NoStateDir => "neither XDG_STATE_HOME nor HOME is an absolute path",
        error.NoBootId => "cannot read the boot id of this machine",
        error.NoMachineId => "cannot tell this machine's id or host name",
        error.StoreOwnedByAnotherUser => "it belongs to another user",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.ReadOnlyFileSystem => "the file system is read-only",
        error.NoSpaceLeft, error.DiskQuota => "the disk is full",
        error.NotDir => "a part of its path is not a directory",
        error.NameTooLong => "its path is too long",
        else => @errorName(err),
    };
}

const last_detached_file = "last-detached";

/// The current boot's directory, for the CLI, which does not open the
/// store; null when it cannot be found.
fn clientBootPath(gpa: std.mem.Allocator, buf: []u8) ?[]const u8 {
    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = rootPath(gpa, &root_path_buf) catch return null;
    var boot_id_buf: [64]u8 = undefined;
    const boot_id = readBootId(&boot_id_buf) catch return null;
    var machine_id_buf: [64]u8 = undefined;
    const machine = readMachineId(gpa, &machine_id_buf) catch return null;
    const sep = std.fs.path.sep;
    return std.fmt.bufPrint(buf, "{s}{c}{s}{c}{s}", .{ root_path, sep, machine, sep, boot_id }) catch null;
}

/// Remember the session this user detached from last, for
/// `tuppet attach -`. Nothing is kept when no daemon made the boot's
/// directory yet.
pub fn setLastDetached(gpa: std.mem.Allocator, id: u64) void {
    const io = io_mod.io();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = clientBootPath(gpa, &path_buf) orelse return;
    var dir = Dir.cwd().openDir(io, path, .{}) catch return;
    defer dir.close(io);
    var buf: [24]u8 = undefined;
    writeAtomic(dir, last_detached_file, std.fmt.bufPrint(&buf, "{d}\n", .{id}) catch unreachable) catch {};
}

/// The session `setLastDetached` remembered in this boot, if any.
pub fn lastDetached(gpa: std.mem.Allocator) ?u64 {
    const io = io_mod.io();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = clientBootPath(gpa, &path_buf) orelse return null;
    var dir = Dir.cwd().openDir(io, path, .{}) catch return null;
    defer dir.close(io);
    var raw: [24]u8 = undefined;
    const got = dir.readFile(io, last_detached_file, &raw) catch return null;
    return parseId(std.mem.trim(u8, got, " \n"));
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

/// Ids above limits.max_id are damage, never a session's.
fn parseId(name: []const u8) ?u64 {
    if (name.len == 0 or name.len > 20 or name[0] == '0') return null;
    for (name) |c| if (c < '0' or c > '9') return null;
    const id = std.fmt.parseInt(u64, name, 10) catch return null;
    return if (id <= limits.max_id) id else null;
}

/// Hold the boot's lock, which serializes id allocation and housekeeping
/// across every daemon of the user. Every change takes it, so this is
/// where a deleted store is made again.
fn lockBoot() !File {
    const io = io_mod.io();
    const options: Dir.CreateFileOptions = .{ .truncate = false, .lock = .exclusive, .permissions = filePermissions() };
    return bootDir().createFile(io, "lock", options) catch |err| {
        if (err != error.FileNotFound or machine_root.len == 0) return err;
        try remakeBoot();
        return bootDir().createFile(io, "lock", options);
    };
}

/// Whether this daemon holds a session with the id; set by the registry.
pub var held: ?*const fn (id: u64) bool = null;

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
    // An existing directory means last-id was behind; never reuse it. Nor
    // one this daemon still holds: the store lost it (another daemon's
    // reset, or a deleted store), but its sessions may name it.
    while (true) : (id += 1) {
        if (bootDir().openDir(io, idName(&name_buf, id), .{})) |existing| {
            existing.close(io);
            continue;
        } else |err| if (err != error.FileNotFound) return err;
        if (held) |isHeld| if (isHeld(id)) continue;
        break;
    }
    if (id > limits.max_id) return error.IdsExhausted;
    // The id is taken before its directory exists, so whatever happens
    // next, it is never handed out again.
    var id_text: [24]u8 = undefined;
    try writeAtomic(bootDir(), "last-id", idName(&id_text, id));
    try bootDir().createDir(io, idName(&name_buf, id), dirPermissions());
    var dir = try bootDir().openDir(io, idName(&name_buf, id), .{});
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
    if (bootDir().readFile(io_mod.io(), "last-id", &buf)) |text| {
        if (parseId(std.mem.trim(u8, text, " \n"))) |id| return id;
    } else |err| if (err != error.FileNotFound) return err;
    const all = try ids(gpa);
    defer gpa.free(all);
    return if (all.len == 0) 0 else all[all.len - 1];
}

/// The id the next session gets.
pub fn nextId(gpa: std.mem.Allocator) !u64 {
    return (try lastId(gpa)) + 1;
}

/// Reserve `n` change seqs for this daemon: returns the highest seq any
/// daemon of this boot may have used, and records that `n` more may be.
pub fn reserveSeqs(n: u64) !u64 {
    const lock = try lockBoot();
    defer lock.close(io_mod.io());
    const mark = try seqMark(n);
    const reserved = std.math.add(u64, mark, n) catch return error.SeqsExhausted;
    var text: [24]u8 = undefined;
    try writeAtomic(bootDir(), "seq", std.fmt.bufPrint(&text, "{d}", .{reserved}) catch unreachable);
    return mark;
}

/// The seq mark, or if it is missing or damaged (above limits.max_seq
/// counts as damaged), `n` above the highest seq a stored session
/// recorded: a running one may have used more since.
fn seqMark(n: u64) !u64 {
    var buf: [32]u8 = undefined;
    if (bootDir().readFile(io_mod.io(), "seq", &buf)) |text| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10)) |mark| {
            if (mark <= limits.max_seq) return mark;
            std.log.warn("the session store's seq mark {d} is above {d}; counting on from the stored sessions", .{ mark, limits.max_seq });
        } else |_| {}
    } else |err| if (err != error.FileNotFound) return err;
    const gpa = std.heap.page_allocator;
    const all = try ids(gpa);
    defer gpa.free(all);
    var highest: u64 = 0;
    for (all) |id| {
        const meta = (readMeta(gpa, id) catch continue) orelse continue;
        defer meta.deinit();
        for ([_]u64{ meta.value.start_seq, meta.value.seq }) |seq| {
            if (seq <= limits.max_seq) highest = @max(highest, seq);
        }
    }
    return if (highest == 0) 0 else highest + n;
}

/// Serializes the changes of a session's metadata in this daemon, each a
/// read and a write.
var meta_mutex: std.Io.Mutex = .init;

/// Record the program's pid once it has started.
pub fn setPid(gpa: std.mem.Allocator, id: u64, pid: u32) void {
    const io = io_mod.io();
    meta_mutex.lockUncancelable(io);
    defer meta_mutex.unlock(io);
    var name_buf: [24]u8 = undefined;
    var dir = bootDir().openDir(io, idName(&name_buf, id), .{}) catch return;
    defer dir.close(io);
    const parsed = (readMeta(gpa, id) catch null) orelse return;
    defer parsed.deinit();
    var meta = parsed.value;
    meta.pid = pid;
    writeMetaIn(gpa, dir, meta) catch |err| std.log.err("session {d}: cannot save its pid: {}", .{ id, err });
}

/// Record a session's new name.
pub fn setName(gpa: std.mem.Allocator, id: u64, name: []const u8) !void {
    const io = io_mod.io();
    meta_mutex.lockUncancelable(io);
    defer meta_mutex.unlock(io);
    var name_buf: [24]u8 = undefined;
    var dir = try bootDir().openDir(io, idName(&name_buf, id), .{});
    defer dir.close(io);
    const parsed = (try readMeta(gpa, id)) orelse return error.FileNotFound;
    defer parsed.deinit();
    var meta = parsed.value;
    meta.name = name;
    try writeMetaIn(gpa, dir, meta);
}

/// Record what a client last showed of a session.
pub fn setSeen(gpa: std.mem.Allocator, id: u64, seen: status.Seen) !void {
    const io = io_mod.io();
    meta_mutex.lockUncancelable(io);
    defer meta_mutex.unlock(io);
    var name_buf: [24]u8 = undefined;
    var dir = try bootDir().openDir(io, idName(&name_buf, id), .{});
    defer dir.close(io);
    const parsed = (try readMeta(gpa, id)) orelse return error.FileNotFound;
    defer parsed.deinit();
    var meta = parsed.value;
    meta.seen = seen;
    try writeMetaIn(gpa, dir, meta);
}

/// Record a session's alerts.
pub fn setAlerts(gpa: std.mem.Allocator, id: u64, rules: []const alert.Rule) !void {
    const io = io_mod.io();
    meta_mutex.lockUncancelable(io);
    defer meta_mutex.unlock(io);
    var name_buf: [24]u8 = undefined;
    var dir = try bootDir().openDir(io, idName(&name_buf, id), .{});
    defer dir.close(io);
    const parsed = (try readMeta(gpa, id)) orelse return error.FileNotFound;
    defer parsed.deinit();
    var meta = parsed.value;
    meta.alerts = rules;
    try writeMetaIn(gpa, dir, meta);
}

/// Record what a stop request reported of an ended session's recording.
pub fn setRecordingReport(gpa: std.mem.Allocator, id: u64, report: RecordingReport) !void {
    const io = io_mod.io();
    meta_mutex.lockUncancelable(io);
    defer meta_mutex.unlock(io);
    var name_buf: [24]u8 = undefined;
    var dir = try bootDir().openDir(io, idName(&name_buf, id), .{});
    defer dir.close(io);
    const parsed = (try readMeta(gpa, id)) orelse return error.FileNotFound;
    defer parsed.deinit();
    var meta = parsed.value;
    meta.recording_report = report;
    try writeMetaIn(gpa, dir, meta);
}

/// How a session ended, and the size its final screen has.
pub const Ending = struct {
    pid: u32,
    exit_code: i32,
    cols: u16,
    rows: u16,
    ended_ms: i64 = 0,
    seq: u64 = 0,
    end_seq: ?u64 = null,
    input_seq: ?u64 = null,
    resize_seq: ?u64 = null,
    last_text_ms: ?i64 = null,
    last_change_ms: ?i64 = null,
    last_output_ms: ?i64 = null,
    title: ?[]const u8 = null,
    reported_cwd: ?Cwd = null,
    stopped: bool = false,
    bell_count: u64 = 0,
    notification_count: u64 = 0,
    notification: ?status.Notification = null,
    out_bytes: ?u64 = null,
    draws: ?u64 = null,
    full_clears: ?u64 = null,
    hits: []const alert.Hit = &.{},
    history_dropped: bool = false,
    recording_report: RecordingReport = .{},
};

/// Record how a session ended, then release its running lock. Returns
/// whether all of it was saved.
pub fn finish(gpa: std.mem.Allocator, id: u64, ending: Ending, screen: []const u8, running: File) bool {
    const io = io_mod.io();
    defer running.close(io);
    meta_mutex.lockUncancelable(io);
    defer meta_mutex.unlock(io);
    var name_buf: [24]u8 = undefined;
    var dir = bootDir().openDir(io, idName(&name_buf, id), .{}) catch |err| {
        std.log.err("session {d}: cannot open its store directory: {}", .{ id, err });
        return false;
    };
    defer dir.close(io);
    const parsed = (readMeta(gpa, id) catch null) orelse {
        std.log.err("session {d}: its stored metadata is gone", .{id});
        return false;
    };
    defer parsed.deinit();
    var meta = parsed.value;
    meta.pid = ending.pid;
    meta.exit_code = ending.exit_code;
    meta.cols = ending.cols;
    meta.rows = ending.rows;
    meta.seq = ending.seq;
    meta.end_seq = ending.end_seq;
    meta.input_seq = ending.input_seq;
    meta.resize_seq = ending.resize_seq;
    meta.last_text_ms = ending.last_text_ms;
    meta.last_change_ms = ending.last_change_ms;
    meta.last_output_ms = ending.last_output_ms;
    meta.title = ending.title;
    meta.reported_cwd = ending.reported_cwd;
    meta.stopped = ending.stopped;
    meta.bell_count = ending.bell_count;
    meta.notification_count = ending.notification_count;
    meta.notification = ending.notification;
    meta.out_bytes = ending.out_bytes;
    meta.draws = ending.draws;
    meta.full_clears = ending.full_clears;
    meta.hits = ending.hits;
    meta.history_dropped = ending.history_dropped;
    meta.recording_report = ending.recording_report;
    meta.ended_ms = if (ending.ended_ms != 0) ending.ended_ms else nowMillis();
    meta.lost = false;
    var saved = true;
    // The screen first: a session whose metadata says it ended has one.
    writeAtomic(dir, screen_file, screen) catch |err| {
        std.log.err("session {d}: cannot save its screen: {}", .{ id, err });
        saved = false;
    };
    writeMetaIn(gpa, dir, meta) catch |err| {
        std.log.err("session {d}: cannot save how it ended: {}", .{ id, err });
        saved = false;
    };
    // Still locked while it goes, so nobody takes the session for lost.
    dir.deleteFile(io, running_file) catch {};
    return saved;
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
    const text = bootDir().readFileAlloc(io_mod.io(), path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(text);
    return std.json.parseFromSlice(Meta, gpa, text, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadMeta,
    };
}

/// Whether readMeta failed for what session.json holds, not for reading
/// it: the session is damaged.
pub fn metaDamaged(err: anyerror) bool {
    return err == error.BadMeta or err == error.StreamTooLong;
}

/// Whether session `id` has a directory in the store.
pub fn exists(id: u64) bool {
    const io = io_mod.io();
    var name_buf: [24]u8 = undefined;
    const dir = bootDir().openDir(io, idName(&name_buf, id), .{}) catch |err| return err != error.FileNotFound;
    dir.close(io);
    return true;
}

/// The checks a stored session's metadata must pass before the daemon
/// uses it; `meta` comes from the directory of session `id`. A history
/// limit above the most allowed is lowered to it. Returns why the session
/// cannot be used, in `gpa`, or null when it can.
pub fn checkMeta(gpa: std.mem.Allocator, id: u64, meta: *Meta) !?[]const u8 {
    const named = meta.id;
    meta.id = id;
    if (named != id) return try std.fmt.allocPrint(gpa, "its session.json names session {d}", .{named});
    if (!limits.validSize(meta.cols, meta.rows)) {
        return try std.fmt.allocPrint(gpa, "its stored size {d}x{d} is outside {s}", .{ meta.cols, meta.rows, limits.size_range });
    }
    const seqs = [_]struct { []const u8, ?u64 }{
        .{ "start_seq", meta.start_seq },
        .{ "seq", meta.seq },
        .{ "end_seq", meta.end_seq },
        .{ "input_seq", meta.input_seq },
        .{ "resize_seq", meta.resize_seq },
        .{ "seen.seq", meta.seen.seq },
    };
    for (seqs) |field| if (field[1]) |seq| if (seq > limits.max_seq) {
        return try std.fmt.allocPrint(gpa, "its stored {s} {d} is above {d}", .{ field[0], seq, limits.max_seq });
    };
    const times = [_]struct { []const u8, ?i64 }{
        .{ "started_ms", meta.started_ms },
        .{ "ended_ms", meta.ended_ms },
        .{ "last_text_ms", meta.last_text_ms },
        .{ "last_change_ms", meta.last_change_ms },
        .{ "last_output_ms", meta.last_output_ms },
        .{ "seen.at_ms", meta.seen.at_ms },
        .{ "notification.at_ms", if (meta.notification) |n| n.at_ms else null },
    };
    for (times) |field| if (field[1]) |ms| if (ms < 0 or ms > limits.max_unix_ms) {
        return try std.fmt.allocPrint(gpa, "its stored {s} {d} is not a time", .{ field[0], ms });
    };
    if (alert.hitsError(meta.hits)) |why| return try std.fmt.allocPrint(gpa, "its stored hits {s}", .{why});
    if (meta.recording) |name| if (!recordingName(name)) return try gpa.dupe(u8, "its stored recording is neither an absolute path nor a file name");
    if (meta.recording_report.stopped) |st| if (!std.fs.path.isAbsolute(st.path) or st.path.len >= std.fs.max_path_bytes) {
        return try gpa.dupe(u8, "its stored recording report has no absolute path");
    };
    if (meta.scrollback > limits.max_scrollback) {
        std.log.warn("session {d}: its stored history limit of {d} bytes is above the most allowed; it keeps {d}", .{ id, meta.scrollback, limits.max_scrollback });
        meta.scrollback = limits.max_scrollback;
    }
    return null;
}

/// A recording as session.json names it: an absolute path, or a file in
/// the session's directory.
fn recordingName(name: []const u8) bool {
    if (std.fs.path.isAbsolute(name)) return name.len < std.fs.max_path_bytes;
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\") == null;
}

/// A stored screen above this size is taken for damage.
pub const max_screen_file: u64 = 1 << 30;

/// Open session `id`'s stored screen to read it.
pub fn openScreen(id: u64) !File {
    var name_buf: [24]u8 = undefined;
    var path_buf: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ idName(&name_buf, id), screen_file }) catch unreachable;
    return bootDir().openFile(io_mod.io(), path, .{});
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
    var dir = bootDir().openDir(io, idName(&name_buf, id), .{}) catch return false;
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
    var dir = try bootDir().openDir(io, ".", .{ .iterate = true });
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
    bootDir().deleteTree(io_mod.io(), idName(&name_buf, id)) catch |err| {
        std.log.err("session {d}: cannot delete its store directory: {}", .{ id, err });
    };
}

/// Mark sessions whose daemon stopped while they ran as lost, and delete
/// sessions that ended more than `keep_ms` ago (never, when null). A
/// session.json that does not parse, or names an end still to come,
/// counts as written when the session ended. Returns the deleted ids.
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
        const parsed = readMeta(gpa, id) catch |err| {
            if (!metaDamaged(err)) continue;
            const keep = keep_ms orelse continue;
            const written = metaWritten(id) orelse continue;
            if (now -| written >= keep) {
                removeSession(id);
                try deleted.append(gpa, id);
            }
            continue;
        } orelse {
            // Not even its metadata was written: debris of a failed start.
            removeSession(id);
            try deleted.append(gpa, id);
            continue;
        };
        defer parsed.deinit();
        var meta = parsed.value;
        if (meta.ended_ms) |ended| if (ended > now) {
            meta.ended_ms = metaWritten(id) orelse continue;
        };
        if (meta.ended_ms == null) {
            meta.ended_ms = now;
            meta.lost = true;
            var name_buf: [24]u8 = undefined;
            var dir = bootDir().openDir(io_mod.io(), idName(&name_buf, id), .{}) catch continue;
            defer dir.close(io_mod.io());
            writeMetaIn(gpa, dir, meta) catch {};
            continue;
        }
        const keep = keep_ms orelse continue;
        if (now -| meta.ended_ms.? >= keep) {
            removeSession(id);
            try deleted.append(gpa, id);
        }
    }
    return deleted.toOwnedSlice(gpa);
}

/// When session `id`'s session.json was last written, in Unix
/// milliseconds.
fn metaWritten(id: u64) ?i64 {
    const io = io_mod.io();
    var name_buf: [24]u8 = undefined;
    const dir = bootDir().openDir(io, idName(&name_buf, id), .{}) catch return null;
    defer dir.close(io);
    return ipc.modifiedMillis(dir, meta_file);
}

/// What a reset did.
pub const Reset = struct {
    removed: u64 = 0,
    kept: u64 = 0,
    next_id: u64 = 1,
};

/// Start the boot's ids over: delete every session of `endpoint`, and
/// every other one that no live process runs and whose daemon does not
/// answer on its endpoint (`answers` probes it), with the recordings kept
/// in their directories; forget the last-detached session; set last-id to
/// the highest id kept; and count the epoch up. The boot's directory,
/// its lock, and the seq mark stay, so seqs never repeat. Each directory
/// is renamed to a hidden name before it is deleted, so a half-deleted
/// one is never taken for a session.
pub fn reset(gpa: std.mem.Allocator, endpoint: []const u8, answers: *const fn ([]const u8) bool) !Reset {
    const io = io_mod.io();
    const lock = try lockBoot();
    defer lock.close(io);
    removeTrash();
    var probed: std.StringHashMapUnmanaged(bool) = .empty;
    defer {
        var it = probed.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        probed.deinit(gpa);
    }
    var done: Reset = .{};
    var highest: u64 = 0;
    const all = try ids(gpa);
    defer gpa.free(all);
    for (all) |id| {
        if (try keepOnReset(gpa, id, endpoint, answers, &probed)) {
            done.kept += 1;
            highest = id;
            continue;
        }
        var name_buf: [24]u8 = undefined;
        var trash_buf: [32]u8 = undefined;
        const trash = std.fmt.bufPrint(&trash_buf, ".trash-{d}", .{id}) catch unreachable;
        bootDir().rename(idName(&name_buf, id), bootDir(), trash, io) catch |err| {
            std.log.err("session {d}: cannot delete its store directory: {}", .{ id, err });
            done.kept += 1;
            highest = id;
            continue;
        };
        bootDir().deleteTree(io, trash) catch |err| std.log.err("session {d}: cannot delete its store directory: {}", .{ id, err });
        done.removed += 1;
    }
    // The epoch first: ids never start over under the old boot.
    var epoch_text: [24]u8 = undefined;
    try writeAtomic(bootDir(), epoch_file, std.fmt.bufPrint(&epoch_text, "{d}", .{(readEpoch() catch 0) + 1}) catch unreachable);
    bootDir().deleteFile(io, last_detached_file) catch |err| if (err != error.FileNotFound) return err;
    if (highest == 0) {
        bootDir().deleteFile(io, "last-id") catch |err| if (err != error.FileNotFound) return err;
    } else {
        var id_text: [24]u8 = undefined;
        try writeAtomic(bootDir(), "last-id", idName(&id_text, highest));
    }
    done.next_id = highest + 1;
    return done;
}

/// Whether a reset keeps session `id`: it belongs to another endpoint, and
/// a live process runs it or its daemon answers. `probed` remembers the
/// endpoints asked.
fn keepOnReset(gpa: std.mem.Allocator, id: u64, endpoint: []const u8, answers: *const fn ([]const u8) bool, probed: *std.StringHashMapUnmanaged(bool)) !bool {
    const parsed = readMeta(gpa, id) catch null orelse return isRunning(id);
    defer parsed.deinit();
    const socket = parsed.value.socket;
    if (std.mem.eql(u8, socket, endpoint)) return false;
    if (isRunning(id)) return true;
    if (socket.len == 0) return false;
    if (probed.get(socket)) |live| return live;
    const live = answers(socket);
    const key = try gpa.dupe(u8, socket);
    errdefer gpa.free(key);
    try probed.put(gpa, key, live);
    return live;
}

/// Delete what an interrupted reset left behind.
fn removeTrash() void {
    const io = io_mod.io();
    var dir = bootDir().openDir(io, ".", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (!std.mem.startsWith(u8, entry.name, ".trash-")) continue;
        dir.deleteTree(io, entry.name) catch |err| std.log.err("cannot delete {s} in the session store: {}", .{ entry.name, err });
    }
}

/// The endpoints the stored sessions name, each once, in `gpa`.
pub fn endpoints(gpa: std.mem.Allocator) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (found.items) |path| gpa.free(path);
        found.deinit(gpa);
    }
    const all = try ids(gpa);
    defer gpa.free(all);
    for (all) |id| {
        const parsed = readMeta(gpa, id) catch continue orelse continue;
        defer parsed.deinit();
        const socket = parsed.value.socket;
        if (socket.len == 0) continue;
        for (found.items) |path| {
            if (std.mem.eql(u8, path, socket)) break;
        } else try found.append(gpa, try gpa.dupe(u8, socket));
    }
    return found.toOwnedSlice(gpa);
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

    try std.testing.expect(finish(gpa, a.id, .{ .pid = 42, .exit_code = 3, .cols = 80, .rows = 24 }, "screen", a.running));
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

test "change seqs are reserved in blocks, also past a damaged mark" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    openAt(tmp.dir, "test-boot");
    try std.testing.expectEqual(@as(u64, 0), try reserveSeqs(100));
    try std.testing.expectEqual(@as(u64, 100), try reserveSeqs(100));
    const a = try create(gpa, .{ .start_seq = 150 });
    try std.testing.expect(finish(gpa, a.id, .{ .pid = 1, .exit_code = 0, .cols = 80, .rows = 24, .seq = 170 }, "", a.running));
    try tmp.dir.writeFile(io_mod.io(), .{ .sub_path = "seq", .data = "garbage" });
    try std.testing.expectEqual(@as(u64, 270), try reserveSeqs(100));
    try std.testing.expectEqual(@as(u64, 370), try reserveSeqs(100));
    // A mark no counting could reach is damage too.
    try tmp.dir.writeFile(io_mod.io(), .{ .sub_path = "seq", .data = "18446744073709551615" });
    try std.testing.expectEqual(@as(u64, 270), try reserveSeqs(100));
}

test "a last-id beyond any id is damage, and the ids go on from the directories" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    openAt(tmp.dir, "test-boot");
    const io = io_mod.io();
    const a = try create(gpa, .{});
    a.running.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "last-id", .data = "18446744073709551615" });
    const b = try create(gpa, .{});
    b.running.close(io);
    try std.testing.expectEqual(a.id + 1, b.id);
}

test "stored metadata outside the limits is damage; too much history is lowered" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var meta: Meta = .{ .id = 3, .cols = 65535, .rows = 65535 };
    try std.testing.expectEqualStrings("its stored size 65535x65535 is outside 1..1000", (try checkMeta(a, 3, &meta)).?);
    meta = .{ .id = 9 };
    try std.testing.expectEqualStrings("its session.json names session 9", (try checkMeta(a, 3, &meta)).?);
    try std.testing.expectEqual(@as(u64, 3), meta.id);
    meta = .{ .id = 3, .seq = std.math.maxInt(u64) };
    try std.testing.expect((try checkMeta(a, 3, &meta)) != null);
    meta = .{ .id = 3, .started_ms = std.math.minInt(i64) };
    try std.testing.expect((try checkMeta(a, 3, &meta)) != null);
    meta = .{ .id = 3, .scrollback = std.math.maxInt(u64) };
    try std.testing.expectEqual(@as(?[]const u8, null), try checkMeta(a, 3, &meta));
    try std.testing.expectEqual(limits.max_scrollback, meta.scrollback);
}

test "housekeeping marks orphans lost and expires ended sessions" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    openAt(tmp.dir, "test-boot");
    const io = io_mod.io();

    const old = try create(gpa, .{});
    try std.testing.expect(finish(gpa, old.id, .{ .pid = 1, .exit_code = 0, .cols = 80, .rows = 24 }, "", old.running));
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

test "housekeeping expires a session whose end time is damaged" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    openAt(tmp.dir, "test-boot");
    const a = try create(gpa, .{});
    try std.testing.expect(finish(gpa, a.id, .{ .pid = 1, .exit_code = 0, .cols = 80, .rows = 24, .ended_ms = std.math.minInt(i64) }, "", a.running));
    const deleted = try housekeepAt(gpa, 5_000, nowMillis());
    defer gpa.free(deleted);
    try std.testing.expectEqualSlices(u64, &.{a.id}, deleted);
}

test "housekeeping expires a session.json that does not parse or ends later by when it was written" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    openAt(tmp.dir, "test-boot");
    const garbled = try create(gpa, .{});
    try std.testing.expect(finish(gpa, garbled.id, .{ .pid = 1, .exit_code = 0, .cols = 80, .rows = 24 }, "", garbled.running));
    try tmp.dir.writeFile(io_mod.io(), .{ .sub_path = "1/session.json", .data = "garbage" });
    const later = try create(gpa, .{});
    try std.testing.expect(finish(gpa, later.id, .{ .pid = 1, .exit_code = 0, .cols = 80, .rows = 24, .ended_ms = limits.max_unix_ms }, "", later.running));
    const kept = try housekeepAt(gpa, 5_000, nowMillis());
    defer gpa.free(kept);
    try std.testing.expectEqualSlices(u64, &.{}, kept);
    const deleted = try housekeepAt(gpa, 5_000, nowMillis() + 10_000);
    defer gpa.free(deleted);
    try std.testing.expectEqualSlices(u64, &.{ garbled.id, later.id }, deleted);
}

test "only directories named like boot ids are other boots" {
    try std.testing.expect(isBootName("2f0a9f1c-6b8e-4c1d-9a51-3c1e5f7d2b40"));
    try std.testing.expect(isBootName("17"));
    try std.testing.expect(!isBootName(".trash-x"));
    try std.testing.expect(!isBootName("notes"));
    try std.testing.expect(!isBootName(""));
}

fn answersOnlyLive(path: []const u8) bool {
    return std.mem.eql(u8, path, "/live.sock");
}

test "a reset deletes this endpoint's and dead daemons' sessions, keeps live ones, and starts ids over" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    openAt(tmp.dir, "test-boot");
    const io = io_mod.io();
    _ = try reserveSeqs(100);

    // This endpoint's: an ended one with a recording, and one whose stop
    // failed, so its daemon still holds it.
    const own = try create(gpa, .{ .socket = "/own.sock", .recording = "output.cast" });
    try tmp.dir.writeFile(io, .{ .sub_path = "1/output.cast", .data = "cast" });
    try std.testing.expect(finish(gpa, own.id, .{ .pid = 1, .exit_code = 0, .cols = 80, .rows = 24 }, "", own.running));
    const stuck = try create(gpa, .{ .socket = "/own.sock" });
    defer stuck.running.close(io);
    // Another daemon that runs a program, one that answers, and one that
    // is gone.
    const running = try create(gpa, .{ .socket = "/dead.sock" });
    const live = try create(gpa, .{ .socket = "/live.sock" });
    try std.testing.expect(finish(gpa, live.id, .{ .pid = 1, .exit_code = 0, .cols = 80, .rows = 24 }, "", live.running));
    const dead = try create(gpa, .{ .socket = "/dead.sock" });
    try std.testing.expect(finish(gpa, dead.id, .{ .pid = 1, .exit_code = 0, .cols = 80, .rows = 24 }, "", dead.running));
    try tmp.dir.writeFile(io, .{ .sub_path = last_detached_file, .data = "1\n" });
    const label = try bootLabel(gpa);
    defer gpa.free(label);
    try std.testing.expectEqualStrings("test-boot", label);

    const done = try reset(gpa, "/own.sock", answersOnlyLive);
    try std.testing.expectEqual(Reset{ .removed = 3, .kept = 2, .next_id = live.id + 1 }, done);
    const left = try ids(gpa);
    defer gpa.free(left);
    try std.testing.expectEqualSlices(u64, &.{ running.id, live.id }, left);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, last_detached_file, .{}));
    const relabelled = try bootLabel(gpa);
    defer gpa.free(relabelled);
    try std.testing.expectEqualStrings("test-boot.1", relabelled);
    // The seq mark stays, so seqs keep rising.
    try std.testing.expectEqual(@as(u64, 100), try reserveSeqs(100));

    // Once nothing is left, ids start at 1 again.
    running.running.close(io);
    const last = try reset(gpa, "/live.sock", answersOnlyLive);
    try std.testing.expectEqual(Reset{ .removed = 2, .kept = 0, .next_id = 1 }, last);
    const first = try create(gpa, .{});
    defer first.running.close(io);
    try std.testing.expectEqual(@as(u64, 1), first.id);
}
