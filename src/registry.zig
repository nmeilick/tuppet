//! The session table: sessions this daemon holds in memory (the ones it
//! runs, and ended ones loaded back from the store), an index of the ended
//! ones only the store has, how references pick among them, the
//! references requests hold on them, and removal.

const std = @import("std");
const io_mod = @import("io.zig");
const store = @import("store.zig");
const names = @import("names.zig");
const status = @import("status.zig");
const session_mod = @import("session.zig");
const protocol = @import("protocol.zig");
const events = @import("events.zig");
const alert = @import("alert.zig");
const limits = @import("limits.zig");
const budget = @import("budget.zig");

const Session = session_mod.Session;
const Status = status.Status;

/// Set by the daemon at startup: the allocator for sessions it loads from
/// the store, and its endpoint, which owns the sessions it starts.
var store_gpa: std.mem.Allocator = undefined;
pub var endpoint: []const u8 = "";

/// Sessions this daemon holds in memory: the ones it runs, and ended
/// ones loaded from the store. Ids come from the store.
var registry: std.AutoArrayHashMapUnmanaged(u64, *Session) = .empty;
/// Ended (or lost) sessions of this endpoint that only the store has, so
/// that references and `list` never read the store. A session is in
/// `registry` or here, never in both.
var stored: std.AutoArrayHashMapUnmanaged(u64, Stored) = .empty;

const Stored = struct {
    parsed: std.json.Parsed(store.Meta),
    /// Why the session cannot be loaded (store.checkMeta), in the
    /// parsed arena; null when it can.
    damage: ?[]const u8 = null,

    fn deinit(entry: Stored) void {
        entry.parsed.deinit();
    }
};
/// The tables' only allocator; growing and freeing them with different
/// allocators corrupts the heap.
const registry_gpa = std.heap.page_allocator;
/// Guards both tables.
var reg_mutex: std.Io.Mutex = .init;
/// Serializes loading ended sessions from the store with deleting them,
/// so a deleted session is never loaded back into memory. Entries leave
/// `stored` only while it is held.
var load_mutex: std.Io.Mutex = .init;

/// Start the table, indexing the ended sessions of `socket_path` that
/// earlier daemons left in the store.
pub fn init(gpa: std.mem.Allocator, socket_path: []const u8) void {
    store_gpa = gpa;
    endpoint = socket_path;
    budget.reclaim = reclaim;
    store.held = exists;
    const all = store.ids(gpa) catch |err| {
        std.log.err("cannot list the stored sessions: {}", .{err});
        return;
    };
    defer gpa.free(all);
    for (all) |id| {
        var parsed = (store.readMeta(gpa, id) catch |err| {
            indexUnreadable(gpa, id, err);
            continue;
        }) orelse continue;
        const meta = parsed.value;
        if (!std.mem.eql(u8, meta.socket, endpoint) or (meta.ended_ms == null and store.isRunning(id))) {
            parsed.deinit();
            continue;
        }
        const entry = checked(id, &parsed) catch {
            parsed.deinit();
            continue;
        };
        stored.put(registry_gpa, id, entry) catch entry.deinit();
    }
}

/// Index stored session `id`, whose session.json cannot be read, as
/// damaged, unless a daemon runs it: whose it is cannot be told, so only
/// `remove` and expiry delete it.
fn indexUnreadable(gpa: std.mem.Allocator, id: u64, err: anyerror) void {
    if (store.isRunning(id)) return;
    var parsed = std.json.parseFromSlice(store.Meta, gpa, "{}", .{ .allocate = .alloc_always }) catch return;
    parsed.value.id = id;
    const why = switch (err) {
        error.StreamTooLong => "its session.json is larger than 1 MiB",
        error.OutOfMemory, error.AccessDenied, error.PermissionDenied, error.SystemResources, error.InputOutput => {
            std.log.err("session {d}: cannot read its session.json: {}", .{ id, err });
            parsed.deinit();
            return;
        },
        else => "its session.json does not parse",
    };
    std.log.warn("session {d} is damaged: {s}", .{ id, why });
    stored.put(registry_gpa, id, .{ .parsed = parsed, .damage = why }) catch parsed.deinit();
}

/// An index entry for the metadata of stored session `id`.
fn checked(id: u64, parsed: *std.json.Parsed(store.Meta)) !Stored {
    const damage = try store.checkMeta(parsed.arena.allocator(), id, &parsed.value);
    if (damage) |why| std.log.warn("session {d} is damaged: {s}", .{ id, why });
    return .{ .parsed = parsed.*, .damage = damage };
}

pub fn reserveRegistrySlot() !void {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    try registry.ensureUnusedCapacity(registry_gpa, 1);
}

/// The slot was reserved by reserveRegistrySlot under spawn_mutex.
pub fn register(s: *Session) void {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    registry.putAssumeCapacity(s.id, s);
}

/// Look up a session and take a reference that keeps it alive until
/// `release`. Every request touching a session holds one. A session that
/// ended under an earlier daemon is loaded from the store; a lost one has
/// nothing to load.
pub fn acquire(id: u64) ?*Session {
    return switch (acquireOr(id)) {
        .session => |s| s,
        else => null,
    };
}

/// What `acquireOr` found.
pub const Acquired = union(enum) {
    session: *Session,
    /// No session it could load: see missingReason.
    missing,
    /// A stored session the memory budget has no room for; the bytes it
    /// needs.
    over_budget: u64,
};

/// `acquire`, saying why there is no session.
pub fn acquireOr(id: u64) Acquired {
    if (acquireLoaded(id)) |s| return .{ .session = use(s) };
    const io = io_mod.io();
    // Reserved before load_mutex, which reclaiming memory takes.
    const floor = blk: {
        reg_mutex.lockUncancelable(io);
        defer reg_mutex.unlock(io);
        const entry = stored.getPtr(id) orelse break :blk null;
        const meta = entry.parsed.value;
        if (entry.damage != null or meta.lost or meta.ended_ms == null) break :blk null;
        break :blk limits.sessionFloor(meta.cols, meta.rows);
    } orelse return if (acquireLoaded(id)) |s| .{ .session = use(s) } else .missing;
    budget.reserve(floor) catch return .{ .over_budget = floor };
    const loaded = load(id, floor);
    // With load_mutex released, which trimming takes.
    if (loaded == .session) trimHistory();
    return loaded;
}

/// Load the stored session `id`, with `floor` reserved for it.
fn load(id: u64, floor: u64) Acquired {
    const io = io_mod.io();
    load_mutex.lockUncancelable(io);
    defer load_mutex.unlock(io);
    // Loaded by another request meanwhile, or gone.
    if (acquireLoaded(id)) |s| {
        budget.release(floor, floor);
        return .{ .session = use(s) };
    }
    const meta = storedMeta(id) orelse {
        budget.release(floor, floor);
        return .missing;
    };
    const loaded = loadStored(meta, floor) orelse {
        budget.release(floor, floor);
        return .missing;
    };
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    // Keep a slot spare: a start in progress has reserved one, and starts
    // are serialized, so there is never more than one.
    registry.ensureUnusedCapacity(registry_gpa, 2) catch {
        loaded.deinit();
        return .missing;
    };
    registry.putAssumeCapacity(id, loaded);
    dropStoredLocked(id);
    take(loaded);
    return .{ .session = use(loaded) };
}

/// Like `acquire`, but only a session held in memory: none is loaded
/// from the store.
pub fn acquireLoaded(id: u64) ?*Session {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    const s = registry.get(id) orelse return null;
    take(s);
    return s;
}

/// Take a reference on `s`; reg_mutex must be held.
fn take(s: *Session) void {
    _ = s.refs.fetchAdd(1, .acq_rel);
}

/// Count a reference on `s` that may change it or its stored metadata,
/// taken while it is held, so unloading never stores what it read before.
fn use(s: *Session) *Session {
    _ = s.uses.fetchAdd(1, .acq_rel);
    return s;
}

/// Drop a reference that only read the session, which is no use that
/// keeps it in memory; see `release`.
fn unref(s: *Session) void {
    _ = s.refs.fetchSub(1, .acq_rel);
}

/// The indexed metadata of a stored session that can be loaded.
/// load_mutex must be held: it keeps the entry alive.
fn storedMeta(id: u64) ?store.Meta {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    const entry = stored.getPtr(id) orelse return null;
    const meta = entry.parsed.value;
    if (entry.damage != null or meta.lost or meta.ended_ms == null) return null;
    return meta;
}

/// reg_mutex and load_mutex must be held.
fn dropStoredLocked(id: u64) void {
    if (stored.fetchOrderedRemove(id)) |entry| entry.value.deinit();
}

/// Rebuild a session that ended under an earlier daemon from its stored
/// screen, with `floor` of the memory budget reserved for it. A session
/// whose directory went missing (another daemon expired it) leaves the
/// index; one whose screen is missing or too large to be one is damaged.
fn loadStored(meta: store.Meta, floor: u64) ?*Session {
    const io = io_mod.io();
    const screen = store.openScreen(meta.id) catch |err| {
        if (err != error.FileNotFound) {
            std.log.err("session {d}: cannot read its saved screen: {}", .{ meta.id, err });
        } else if (store.exists(meta.id)) {
            markDamaged(meta.id, "its saved screen is missing");
        } else {
            reg_mutex.lockUncancelable(io);
            defer reg_mutex.unlock(io);
            dropStoredLocked(meta.id);
        }
        return null;
    };
    defer screen.close(io);
    const size = screen.length(io) catch |err| {
        std.log.err("session {d}: cannot read its saved screen: {}", .{ meta.id, err });
        return null;
    };
    if (size > store.max_screen_file) {
        markDamaged(meta.id, "its saved screen is larger than 1 GiB");
        return null;
    }
    return Session.restore(store_gpa, meta, screen, floor) catch |err| {
        std.log.err("session {d}: cannot restore it: {}", .{ meta.id, err });
        return null;
    };
}

/// Mark the stored session `id` damaged for the static reason `why`.
fn markDamaged(id: u64, why: []const u8) void {
    std.log.warn("session {d} is damaged: {s}", .{ id, why });
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    if (stored.getPtr(id)) |entry| entry.damage = why;
}

/// Why `acquire` found no session with this id.
pub const Missing = struct {
    /// no_session, elsewhere, or ended (lost).
    code: protocol.Code,
    err: []u8,
};

pub fn missingReason(gpa: std.mem.Allocator, id: u64) !Missing {
    const lost_text = "session {d} was lost: its daemon stopped while it ran, so its output was not saved";
    {
        const io = io_mod.io();
        reg_mutex.lockUncancelable(io);
        defer reg_mutex.unlock(io);
        if (stored.getPtr(id)) |entry| {
            if (entry.damage) |why| return .{ .code = .damaged, .err = try std.fmt.allocPrint(gpa, "session {d} is damaged: {s}; 'tuppet remove {d}' deletes it", .{ id, why, id }) };
            if (entry.parsed.value.lost or entry.parsed.value.ended_ms == null) {
                return .{ .code = .ended, .err = try std.fmt.allocPrint(gpa, lost_text, .{id}) };
            }
        }
    }
    if (store.readMeta(gpa, id) catch null) |parsed| {
        defer parsed.deinit();
        const meta = parsed.value;
        if (!std.mem.eql(u8, meta.socket, endpoint)) {
            return .{ .code = .elsewhere, .err = try std.fmt.allocPrint(gpa, "session {d} belongs to the daemon on {s}", .{ id, meta.socket }) };
        }
        if (meta.lost or (meta.ended_ms == null and !store.isRunning(id))) {
            return .{ .code = .ended, .err = try std.fmt.allocPrint(gpa, lost_text, .{id}) };
        }
    }
    return .{ .code = .no_session, .err = try std.fmt.allocPrint(gpa, "no session with id {d}", .{id}) };
}

/// Whether the session `id` is known: held in memory or indexed.
pub fn exists(id: u64) bool {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    return registry.contains(id) or stored.contains(id);
}

/// The ids of the sessions the name or pattern `ref` picks, ascending.
pub fn pick(gpa: std.mem.Allocator, ref: []const u8, filter: names.Filter) ![]u64 {
    var ids: std.ArrayList(u64) = .empty;
    errdefer ids.deinit(gpa);
    {
        const io = io_mod.io();
        reg_mutex.lockUncancelable(io);
        defer reg_mutex.unlock(io);
        for (registry.values()) |s| {
            if (names.picks(ref, s.name, s.state.load(.acquire) == .running, filter)) try ids.append(gpa, s.id);
        }
        for (stored.values()) |entry| {
            if (names.picks(ref, entry.parsed.value.name, false, filter)) try ids.append(gpa, entry.parsed.value.id);
        }
    }
    std.mem.sortUnstable(u64, ids.items, {}, std.sort.asc(u64));
    return ids.toOwnedSlice(gpa);
}

/// Every session id, ascending.
pub fn allIds(gpa: std.mem.Allocator) ![]u64 {
    var ids: std.ArrayList(u64) = .empty;
    errdefer ids.deinit(gpa);
    {
        const io = io_mod.io();
        reg_mutex.lockUncancelable(io);
        defer reg_mutex.unlock(io);
        try ids.appendSlice(gpa, registry.keys());
        try ids.appendSlice(gpa, stored.keys());
    }
    std.mem.sortUnstable(u64, ids.items, {}, std.sort.asc(u64));
    return ids.toOwnedSlice(gpa);
}

/// The status of session `id`, or null when there is none. Everything it
/// holds lives in `gpa`.
pub fn statusOf(gpa: std.mem.Allocator, id: u64) !?Status {
    if (acquireLoaded(id)) |s| {
        defer unref(s);
        var st = try status.of(gpa, s);
        st.argv = try dupeArgv(gpa, st.argv);
        return st;
    }
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    const entry = stored.getPtr(id) orelse return null;
    var st = try status.ofMeta(gpa, entry.parsed.value, store.nowMillis());
    if (st.name) |name| st.name = try gpa.dupe(u8, name);
    st.argv = try dupeArgv(gpa, st.argv);
    if (entry.damage) |why| st.damaged = try gpa.dupe(u8, why);
    return st;
}

/// What a run `like` a session copies from it.
pub const Template = struct {
    argv: []const []const u8,
    /// Empty when the run gave none.
    cwd: []const u8,
    name: []const u8,
    cols: u16,
    rows: u16,
    scrollback: u64,
    alerts: []const alert.Rule,
};

/// The template session `id` gives, in `gpa`; null when there is none.
/// A session in memory gives its current name and size.
pub fn templateOf(gpa: std.mem.Allocator, id: u64) !?Template {
    if (acquireLoaded(id)) |s| {
        defer unref(s);
        var t: Template = .{ .argv = try dupeArgv(gpa, @ptrCast(s.argv)), .cwd = "", .name = "", .cols = 0, .rows = 0, .scrollback = s.scrollback, .alerts = &.{} };
        if (try store.readMeta(gpa, id)) |parsed| {
            defer parsed.deinit();
            t.cwd = try gpa.dupe(u8, parsed.value.cwd);
        }
        s.lockTerminal();
        defer s.unlockTerminal();
        t.name = try gpa.dupe(u8, s.name);
        t.cols = s.cols;
        t.rows = s.rows;
        t.alerts = try dupeRules(gpa, try s.track.alerts().rules(gpa));
        return t;
    }
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    const entry = stored.getPtr(id) orelse return null;
    if (entry.damage != null) return null;
    const meta = entry.parsed.value;
    return .{
        .argv = try dupeArgv(gpa, meta.argv),
        .cwd = try gpa.dupe(u8, meta.cwd),
        .name = try gpa.dupe(u8, meta.name),
        .cols = meta.cols,
        .rows = meta.rows,
        .scrollback = meta.scrollback,
        .alerts = try dupeRules(gpa, meta.alerts),
    };
}

fn dupeRules(gpa: std.mem.Allocator, rules: []const alert.Rule) ![]const alert.Rule {
    const out = try gpa.alloc(alert.Rule, rules.len);
    for (rules, out) |rule, *o| o.* = .{ .name = try gpa.dupe(u8, rule.name), .match = try gpa.dupe(u8, rule.match), .icase = rule.icase };
    return out;
}

/// Whether session `id` is running in this daemon.
pub fn isRunning(id: u64) bool {
    const s = acquireLoaded(id) orelse return false;
    defer unref(s);
    return s.state.load(.acquire) == .running;
}

/// Give `s` the name `owned` and return its old one; terminal_mutex must
/// be held, so status readers see one or the other.
pub fn swapName(s: *Session, owned: []const u8) []const u8 {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    const old = s.name;
    s.name = owned;
    return old;
}

/// The running session named `name`, with a reference taken.
pub fn acquireRunningNamed(name: []const u8) ?*Session {
    if (name.len == 0) return null;
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    for (registry.values()) |s| {
        if (!std.mem.eql(u8, s.name, name) or s.state.load(.acquire) != .running) continue;
        take(s);
        return s;
    }
    return null;
}

/// The ended sessions of this endpoint named `name`, in memory or only in
/// the store; error.NameTaken when a running one has it. Starts hold
/// spawn_mutex, so no other session can take the name meanwhile.
pub fn endedNamesakes(gpa: std.mem.Allocator, name: []const u8) ![]u64 {
    var found: std.ArrayList(u64) = .empty;
    errdefer found.deinit(gpa);
    if (name.len == 0) return found.toOwnedSlice(gpa);
    const io = io_mod.io();
    var in_memory: usize = 0;
    {
        reg_mutex.lockUncancelable(io);
        defer reg_mutex.unlock(io);
        for (registry.values()) |s| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            if (s.state.load(.acquire) == .running) return error.NameTaken;
            try found.append(gpa, s.id);
        }
        in_memory = found.items.len;
        for (stored.values()) |entry| {
            if (std.mem.eql(u8, entry.parsed.value.name, name)) try found.append(gpa, entry.parsed.value.id);
        }
    }
    // One that is still saving its results could not be removed once the
    // new program runs; wait for it now, before anything has started.
    for (found.items[0..in_memory]) |id| {
        const s = acquireLoaded(id) orelse continue;
        defer unref(s);
        s.waitSettled(io_mod.nowNanos() + session_mod.save_wait_ns) catch return error.NameTaken;
    }
    return found.toOwnedSlice(gpa);
}

/// How many sessions are running or still saving their results: the
/// daemon may only exit when there are none. Ended sessions are safe in
/// the store.
pub fn unsettledCount() usize {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    var n: usize = 0;
    for (registry.values()) |s| {
        if (!s.settled.load(.acquire)) n += 1;
    }
    return n;
}

/// Drop a request's reference; the session counts as used until now.
pub fn release(s: *Session) void {
    s.released_ns.store(io_mod.nowNanos(), .release);
    _ = s.refs.fetchSub(1, .acq_rel);
}

/// Every session in memory, each with a reference taken; see `releaseAll`.
pub fn acquireAll(gpa: std.mem.Allocator) ![]*Session {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    const list = try gpa.dupe(*Session, registry.values());
    for (list) |s| take(s);
    return list;
}

pub fn releaseAll(gpa: std.mem.Allocator, list: []*Session) void {
    for (list) |s| unref(s);
    gpa.free(list);
}

/// Drop sessions the store has expired from memory and the index too.
pub fn forgetExpired(deleted: []const u64) void {
    for (deleted) |id| if (forget(id)) events.publish(id, .removed, .{});
}

/// Drop the ended sessions whose store directory is gone, as another
/// daemon's expiry deletes them, from memory and the index. One whose
/// results never reached the store stays in memory.
pub fn forgetVanished() void {
    const gpa = std.heap.page_allocator;
    var known: std.ArrayList(u64) = .empty;
    defer known.deinit(gpa);
    {
        const io = io_mod.io();
        reg_mutex.lockUncancelable(io);
        defer reg_mutex.unlock(io);
        known.appendSlice(gpa, stored.keys()) catch return;
        for (registry.values()) |s| {
            if (s.settled.load(.acquire) and s.in_store.load(.acquire)) known.append(gpa, s.id) catch return;
        }
    }
    // One at a time: a listing would skip an entry it fails to check.
    for (known.items) |id| {
        if (store.exists(id)) continue;
        if (forget(id)) events.publish(id, .removed, .{});
    }
}

/// Drop ended session `id`, which the store has deleted, from memory or
/// the index; whether either had it.
fn forget(id: u64) bool {
    const io = io_mod.io();
    const s = blk: {
        load_mutex.lockUncancelable(io);
        defer load_mutex.unlock(io);
        break :blk detach(id) catch {
            reg_mutex.lockUncancelable(io);
            defer reg_mutex.unlock(io);
            const indexed = stored.contains(id);
            dropStoredLocked(id);
            return indexed;
        };
    };
    free(s);
    return true;
}

/// Delete an ended session, from memory and from the store.
pub fn remove(id: u64) error{ NoSession, StillRunning }!void {
    const io = io_mod.io();
    waitSaved(id);
    const s = blk: {
        load_mutex.lockUncancelable(io);
        defer load_mutex.unlock(io);
        // Its files go once nothing writes them: free waits for that, and
        // nothing loads it back meanwhile, as no table has it.
        if (detach(id)) |s| break :blk s else |err| if (err != error.NoSession) return err;
        {
            reg_mutex.lockUncancelable(io);
            defer reg_mutex.unlock(io);
            if (!stored.contains(id)) return error.NoSession;
            dropStoredLocked(id);
        }
        store.removeSession(id);
        break :blk null;
    };
    if (s) |gone| {
        free(gone);
        store.removeSession(id);
    }
    events.publish(id, .removed, .{});
}

/// Record that a client showed `shown` of session `id`, in memory or only
/// in the store; see Session.ack. A seen that moved is an event.
pub fn ack(gpa: std.mem.Allocator, id: u64, shown: ?status.Shown) error{NoSession}!void {
    const moved = try ackSession(gpa, id, shown);
    if (moved) events.publish(id, .seen, .{});
}

fn ackSession(gpa: std.mem.Allocator, id: u64, shown: ?status.Shown) error{NoSession}!bool {
    if (acquireLoaded(id)) |s| {
        defer unref(s);
        return use(s).ack(shown);
    }
    const io = io_mod.io();
    load_mutex.lockUncancelable(io);
    defer load_mutex.unlock(io);
    // Loaded meanwhile.
    if (acquireLoaded(id)) |s| {
        defer unref(s);
        return use(s).ack(shown);
    }
    const seen, const moved = blk: {
        reg_mutex.lockUncancelable(io);
        defer reg_mutex.unlock(io);
        const meta = &(stored.getPtr(id) orelse return error.NoSession).parsed.value;
        const lost = meta.lost or meta.ended_ms == null;
        const current: status.Seen = .{
            .seq = if (lost) 0 else meta.seq,
            .hit_seq = if (meta.hits.len > 0) meta.hits[meta.hits.len - 1].n else null,
            .bell_count = meta.bell_count,
            .notification_count = meta.notification_count,
            .ended = true,
        };
        const old = meta.seen;
        meta.seen = status.mergeSeen(old, shown, current, store.nowMillis());
        break :blk .{ meta.seen, status.seenMoved(old, meta.seen) };
    };
    store.setSeen(gpa, id, seen) catch |err| std.log.err("session {d}: cannot save what was seen: {}", .{ id, err });
    return moved;
}

/// A program that has just exited is still saving its results; wait for
/// that rather than fail a remove right after it ended.
fn waitSaved(id: u64) void {
    const s = acquireLoaded(id) orelse return;
    defer unref(s);
    if (s.state.load(.acquire) == .exited) s.waitSettled(io_mod.nowNanos() + session_mod.save_wait_ns) catch {};
}

/// Take an ended session out of memory: it disappears from the registry
/// at once, so no request takes a reference on it any more. load_mutex
/// must be held; `free` it once that is released.
fn detach(id: u64) error{ NoSession, StillRunning }!*Session {
    const io = io_mod.io();
    reg_mutex.lockUncancelable(io);
    defer reg_mutex.unlock(io);
    const s = registry.get(id) orelse return error.NoSession;
    if (!s.settled.load(.acquire)) return error.StillRunning;
    _ = registry.orderedRemove(id);
    return s;
}

/// Free a detached session once the requests still using it are done.
/// Only this session's users wait, and no lock is held meanwhile: one of
/// them may be waiting for load_mutex.
fn free(s: *Session) void {
    while (s.refs.load(.acquire) != 0) {
        std.Io.sleep(io_mod.io(), .fromMilliseconds(1), .boot) catch {};
    }
    s.deinit();
}

/// Ended sessions stay in memory this long after their last use, so
/// requests in a row load them once.
pub const unload_idle_ns: i64 = 30 * std.time.ns_per_s;

/// Unload the ended sessions that nothing has used for `idle_ns` and
/// whose results the store has: they load again when needed, every row
/// counting as changed at their last seq. Returns how many went.
pub fn unloadIdle(idle_ns: i64) usize {
    const io = io_mod.io();
    load_mutex.lockUncancelable(io);
    defer load_mutex.unlock(io);
    const gpa = std.heap.page_allocator;
    const Candidate = struct { id: u64, uses: u64 };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(gpa);
    {
        const now = io_mod.nowNanos();
        reg_mutex.lockUncancelable(io);
        defer reg_mutex.unlock(io);
        for (registry.values()) |s| {
            if (!unloadable(s) or now - s.released_ns.load(.acquire) < idle_ns) continue;
            candidates.append(gpa, .{ .id = s.id, .uses = s.uses.load(.acquire) }) catch break;
        }
    }
    var unloaded: usize = 0;
    for (candidates.items) |c| {
        // Read again: a rename, an ack, or an alert change since the load
        // went to the store. One while this reads is caught below.
        var parsed = (store.readMeta(store_gpa, c.id) catch continue);
        var entry: ?Stored = if (parsed) |*p| (checked(c.id, p) catch {
            p.deinit();
            continue;
        }) else null;
        const s = blk: {
            reg_mutex.lockUncancelable(io);
            defer reg_mutex.unlock(io);
            const s = registry.get(c.id) orelse break :blk null;
            if (!unloadable(s) or s.uses.load(.acquire) != c.uses) break :blk null;
            if (entry) |e| {
                stored.put(registry_gpa, c.id, e) catch break :blk null;
                entry = null;
            }
            _ = registry.orderedRemove(c.id);
            break :blk s;
        };
        if (entry) |e| e.deinit();
        const gone = s orelse continue;
        gone.deinit();
        unloaded += 1;
    }
    return unloaded;
}

/// Whether `s` can be unloaded now: it ended, the store has all of it,
/// and no request holds it. reg_mutex must be held, so none takes a
/// reference meanwhile.
fn unloadable(s: *Session) bool {
    return s.settled.load(.acquire) and s.in_store.load(.acquire) and s.refs.load(.acquire) == 0;
}

fn reclaim() bool {
    return unloadIdle(0) > 0;
}

var trim_mutex: std.Io.Mutex = .init;

/// Bring the sessions back within the memory budget once they use more:
/// first unload ended sessions the store has in full, then trim the
/// oldest history of those that keep the most, down to one level for
/// all of them, which then keep no more. No session lock may be held.
pub fn trimHistory() void {
    if (budget.excess() == 0) return;
    const io = io_mod.io();
    trim_mutex.lockUncancelable(io);
    defer trim_mutex.unlock(io);
    if (budget.excess() == 0) return;
    _ = unloadIdle(0);
    const need = budget.excess();
    if (need == 0) return;
    const gpa = std.heap.page_allocator;
    const list = acquireAll(gpa) catch return;
    defer releaseAll(gpa, list);
    const Share = struct { s: *Session, bytes: u64 };
    const shares = gpa.alloc(Share, list.len) catch return;
    defer gpa.free(shares);
    for (list, shares) |s, *share| share.* = .{ .s = s, .bytes = s.trimmable.load(.acquire) };
    std.mem.sort(Share, shares, {}, struct {
        fn more(_: void, a: Share, b: Share) bool {
            return a.bytes > b.bytes;
        }
    }.more);
    const level = trimLevel(shares, need);
    var trimmed: usize = 0;
    var freed: u64 = 0;
    for (shares) |share| {
        if (share.bytes <= level) break;
        if (!share.s.trimHistory(level)) continue;
        freed += share.bytes - level;
        trimmed += 1;
    }
    if (trimmed > 0) std.log.info("memory budget: trimmed the oldest history of {d} sessions by {d} MiB to stay within {d} MiB", .{ trimmed, std.math.divCeil(u64, freed, 1 << 20) catch unreachable, budget.totalMiB() });
}

/// The history each session may keep so that trimming the sessions that
/// keep more, `shares` in descending order, frees at least `need` bytes.
fn trimLevel(shares: anytype, need: u64) u64 {
    var sum: u64 = 0;
    for (shares, 0..) |share, i| {
        sum += share.bytes;
        const next = if (i + 1 < shares.len) shares[i + 1].bytes else 0;
        const n: u64 = i + 1;
        if (sum - n * next >= need) return (sum - need) / n;
    }
    return 0;
}

var trim_wanted = false;
var trim_wake_mutex: std.Io.Mutex = .init;
var trim_wake: std.Io.Condition = .init;

/// Have the trimmer thread trim when the sessions use more than the
/// budget: for the readers, whose output must not wait for a trim.
pub fn wantTrim() void {
    if (budget.excess() == 0) return;
    const io = io_mod.io();
    trim_wake_mutex.lockUncancelable(io);
    defer trim_wake_mutex.unlock(io);
    trim_wanted = true;
    trim_wake.signal(io);
}

/// The trimmer thread: `trimHistory` whenever `wantTrim` asks.
pub fn trimmer() void {
    const io = io_mod.io();
    while (true) {
        trim_wake_mutex.lockUncancelable(io);
        while (!trim_wanted) trim_wake.waitUncancelable(io, &trim_wake_mutex);
        trim_wanted = false;
        trim_wake_mutex.unlock(io);
        trimHistory();
    }
}

/// Give trimmed sessions their own history limits back once the budget
/// has room again.
pub fn liftHistoryCaps() void {
    if (!budget.enabled() or !budget.roomy()) return;
    const gpa = std.heap.page_allocator;
    const list = acquireAll(gpa) catch return;
    defer releaseAll(gpa, list);
    for (list) |s| s.liftHistoryCap();
}

test "trimming brings the sessions that keep the most down to one level" {
    const Share = struct { bytes: u64 };
    const shares = [_]Share{ .{ .bytes = 100 }, .{ .bytes = 60 }, .{ .bytes = 20 } };
    // 40 from the first alone.
    try std.testing.expectEqual(@as(u64, 60), trimLevel(&shares, 40));
    // 60: the first two down to 50.
    try std.testing.expectEqual(@as(u64, 50), trimLevel(&shares, 60));
    // More than all of it: nothing stays.
    try std.testing.expectEqual(@as(u64, 0), trimLevel(&shares, 500));
}

fn dupeArgv(gpa: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, argv.len);
    for (argv, out) |arg, *o| o.* = try gpa.dupe(u8, arg);
    return out;
}
