//! What callers say about sessions as members of the groups a drawn
//! attach shows: the group and the number the daemon gives each member, a
//! label, an accent, a mark, meta values, the actions a switcher offers, a
//! flag for attention, and side sessions tied to another session. The
//! daemon keeps and reports these; it acts on none of them.

const std = @import("std");
const io_mod = @import("io.zig");
const names = @import("names.zig");
const status = @import("status.zig");
const store = @import("store.zig");
const events = @import("events.zig");
const registry = @import("registry.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;
const Member = status.Member;

pub const max_label = 64;
pub const max_mark = 16;
pub const max_meta = 16;
pub const max_meta_value = 256;
pub const max_actions = 16;
pub const max_action_name = 32;
pub const max_choices = 8;
pub const max_choice = 32;
pub const max_hint = 64;
pub const max_attention = 256;
/// Switcher keys that a caller's action cannot take.
pub const reserved_keys = "0123456789/\\dfh";

/// Serializes giving numbers in groups and tying side sessions, so two
/// requests never give one number twice.
var mutex: std.Io.Mutex = .init;

pub fn lock() void {
    mutex.lockUncancelable(io_mod.io());
}

pub fn unlock() void {
    mutex.unlock(io_mod.io());
}

/// The lowest number no session of `group` has, ended ones included;
/// the caller holds the lock.
pub fn nextNumber(gpa: std.mem.Allocator, group: []const u8) !u32 {
    const used = try registry.groupNumbers(gpa, group);
    defer gpa.free(used);
    std.mem.sortUnstable(u32, used, {}, std.sort.asc(u32));
    var n: u32 = 0;
    for (used) |u| {
        if (u == n) n += 1 else if (u > n) break;
    }
    return n;
}

/// `text` cleaned as a status shows caller text; null when nothing is
/// left of it.
fn clean(gpa: std.mem.Allocator, text: []const u8, cap: usize) !?[]const u8 {
    const out = try status.cleanText(gpa, text, cap);
    if (out.len > 0) return out;
    gpa.free(out);
    return null;
}

/// What an `update` (or `run`) changes; null leaves a field as it is,
/// an empty text takes it away.
pub const Change = struct {
    group: ?[]const u8 = null,
    label: ?[]const u8 = null,
    accent: ?bool = null,
    mark: ?[]const u8 = null,
    /// Sets these keys; an empty value takes a key away.
    meta: ?[]const status.MetaValue = null,
    /// Replaces the actions.
    actions: ?[]const status.Action = null,
};

pub const Checked = union(enum) {
    ok: Member,
    /// Why the change is refused.
    bad: []const u8,
};

/// `old` with `change` applied, its texts cleaned and checked, in `gpa`.
/// A new group gets no number here: the caller gives it one.
pub fn apply(gpa: std.mem.Allocator, old: Member, change: Change) !Checked {
    var m = try old.dupe(gpa);
    if (change.group) |g| {
        if (g.len > 0) if (names.nameErrorOf(g, "group name")) |why| return .{ .bad = try std.fmt.allocPrint(gpa, "invalid group '{s}': {s}", .{ g, why }) };
        const same = if (m.group) |was| std.mem.eql(u8, was, g) else g.len == 0;
        if (!same) {
            m.group = if (g.len > 0) try gpa.dupe(u8, g) else null;
            m.number = null;
        }
    }
    if (change.label) |l| m.label = try clean(gpa, l, max_label);
    if (change.accent) |a| m.accent = a;
    if (change.mark) |k| m.mark = try clean(gpa, k, max_mark);
    if (change.meta) |given| {
        var list: std.ArrayList(status.MetaValue) = .empty;
        try list.appendSlice(gpa, m.meta);
        for (given) |v| {
            if (names.nameErrorOf(v.key, "meta key")) |why| return .{ .bad = try std.fmt.allocPrint(gpa, "invalid meta key '{s}': {s}", .{ v.key, why }) };
            for (list.items, 0..) |have, i| if (std.mem.eql(u8, have.key, v.key)) {
                _ = list.orderedRemove(i);
                break;
            };
            const value = try clean(gpa, v.value, max_meta_value) orelse continue;
            try list.append(gpa, .{ .key = try gpa.dupe(u8, v.key), .value = value });
        }
        if (list.items.len > max_meta) return .{ .bad = try std.fmt.allocPrint(gpa, "a session keeps at most {d} meta values", .{max_meta}) };
        m.meta = list.items;
    }
    if (change.actions) |given| switch (try checkActions(gpa, given)) {
        .ok => |actions| m.actions = actions,
        .bad => |why| return .{ .bad = why },
    };
    return .{ .ok = m };
}

fn checkActions(gpa: std.mem.Allocator, given: []const status.Action) !union(enum) { ok: []const status.Action, bad: []const u8 } {
    if (given.len > max_actions) return .{ .bad = try std.fmt.allocPrint(gpa, "a session takes at most {d} actions", .{max_actions}) };
    const out = try gpa.alloc(status.Action, given.len);
    for (given, out, 0..) |a, *o, i| {
        if (a.key.len != 1 or a.key[0] < 0x21 or a.key[0] > 0x7e) return .{ .bad = try std.fmt.allocPrint(gpa, "actions[{d}]: the key must be one printable ASCII character", .{i}) };
        if (std.mem.indexOfScalar(u8, reserved_keys, a.key[0]) != null) return .{ .bad = try std.fmt.allocPrint(gpa, "actions[{d}]: the switcher keeps '{s}' for itself (digits, / \\ d f h)", .{ i, a.key }) };
        for (out[0..i]) |before| if (before.key[0] == a.key[0]) return .{ .bad = try std.fmt.allocPrint(gpa, "actions[{d}]: the key '{s}' is given twice", .{ i, a.key }) };
        const name = try clean(gpa, a.name, max_action_name) orelse return .{ .bad = try std.fmt.allocPrint(gpa, "actions[{d}]: the name must not be empty", .{i}) };
        if (a.choices.len > 0 and a.input != null) return .{ .bad = try std.fmt.allocPrint(gpa, "actions[{d}]: give choices or input, not both", .{i}) };
        if (a.choices.len > max_choices) return .{ .bad = try std.fmt.allocPrint(gpa, "actions[{d}]: at most {d} choices", .{ i, max_choices }) };
        const choices = try gpa.alloc([]const u8, a.choices.len);
        for (a.choices, choices) |c, *co| co.* = try clean(gpa, c, max_choice) orelse return .{ .bad = try std.fmt.allocPrint(gpa, "actions[{d}]: a choice must not be empty", .{i}) };
        o.* = .{
            .key = try gpa.dupe(u8, a.key),
            .name = name,
            .confirm = a.confirm,
            .choices = choices,
            .input = if (a.input) |hint| (try clean(gpa, hint, max_hint)) orelse "" else null,
        };
    }
    return .{ .ok = out };
}

/// Give `s` the member `new`, save it, and tell the event streams what
/// changed.
pub fn set(s: *Session, new: Member) !void {
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const old = try s.memberOf(arena.allocator());
    try s.setMember(new);
    store.setMember(arena.allocator(), s.id, new) catch |err| std.log.err("session {d}: cannot save what its caller says about it: {}", .{ s.id, err });
    const fields = changes(old, new);
    if (fields.count() > 0) events.publish(s.id, .changed, fields);
    if (old.side_view != new.side_view) events.publish(s.id, .side_view, .{});
}

/// The change fields that tell `a` from `b`.
fn changes(a: Member, b: Member) events.Fields {
    const eqlText = struct {
        fn f(x: ?[]const u8, y: ?[]const u8) bool {
            if (x == null or y == null) return x == null and y == null;
            return std.mem.eql(u8, x.?, y.?);
        }
    }.f;
    var f: events.Fields = .empty;
    f.setPresent(.group, !eqlText(a.group, b.group) or !std.meta.eql(a.number, b.number));
    f.setPresent(.label, !eqlText(a.label, b.label) or a.accent != b.accent or !eqlText(a.mark, b.mark));
    f.setPresent(.attention, !eqlText(a.attention, b.attention));
    f.setPresent(.side, !std.meta.eql(a.side_of, b.side_of));
    var meta_same = a.meta.len == b.meta.len;
    if (meta_same) for (a.meta, b.meta) |x, y| {
        meta_same = meta_same and std.mem.eql(u8, x.key, y.key) and std.mem.eql(u8, x.value, y.value);
    };
    f.setPresent(.meta, !meta_same);
    var actions_same = a.actions.len == b.actions.len;
    if (actions_same) for (a.actions, b.actions) |x, y| {
        actions_same = actions_same and std.mem.eql(u8, x.key, y.key) and std.mem.eql(u8, x.name, y.name) and x.confirm == y.confirm and
            eqlText(x.input, y.input) and x.choices.len == y.choices.len;
        if (actions_same) for (x.choices, y.choices) |cx, cy| {
            actions_same = actions_same and std.mem.eql(u8, cx, cy);
        };
    };
    f.setPresent(.actions, !actions_same);
    return f;
}

/// Tie the side session `side` to `main`; the caller holds the lock. A
/// side session that ended meanwhile is untied again: `ended` may have
/// looked before the tie.
pub fn tie(main: *Session, side: *Session) void {
    const io = io_mod.io();
    main.member_mutex.lockUncancelable(io);
    main.side = side.id;
    main.member_mutex.unlock(io);
    if (side.state.load(.acquire) == .exited) untie(main, side.id);
    events.publish(main.id, .changed, .initOne(.side));
}

/// `main` has no side session any more, if `side` was it.
fn untie(main: *Session, side: u64) void {
    const io = io_mod.io();
    main.member_mutex.lockUncancelable(io);
    const was = main.side == side;
    if (was) main.side = null;
    main.member_mutex.unlock(io);
    if (was) events.publish(main.id, .changed, .initOne(.side));
}

/// The running side session tied to `s`, if any.
pub fn sideOf(s: *Session) ?u64 {
    const io = io_mod.io();
    s.member_mutex.lockUncancelable(io);
    defer s.member_mutex.unlock(io);
    return s.side;
}

/// A side session ended: the session it is tied to has none now. Takes no
/// lock but the sessions' own, as it runs on the side session's reader,
/// which a request holding the lock may wait for.
pub fn ended(s: *Session) void {
    const io = io_mod.io();
    s.member_mutex.lockUncancelable(io);
    const main_id = s.member.side_of;
    s.member_mutex.unlock(io);
    const main = registry.acquireLoaded(main_id orelse return) orelse return;
    defer registry.release(main);
    untie(main, s.id);
}

test "a change cleans texts, merges meta values, and checks actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old: Member = .{ .group = "w", .number = 2, .meta = &.{.{ .key = "route", .value = "dmz" }} };
    const m = (try apply(a, old, .{ .label = "db07\x1b prod", .meta = &.{ .{ .key = "route", .value = "" }, .{ .key = "env", .value = "lab" } } })).ok;
    try std.testing.expectEqualStrings("db07 prod", m.label.?);
    try std.testing.expectEqual(@as(?u32, 2), m.number);
    try std.testing.expectEqual(@as(usize, 1), m.meta.len);
    try std.testing.expectEqualStrings("env", m.meta[0].key);
    // Another group takes the number away, for the caller to give anew.
    try std.testing.expectEqual(@as(?u32, null), (try apply(a, old, .{ .group = "v" })).ok.number);
    try std.testing.expect((try apply(a, old, .{ .actions = &.{.{ .key = "d", .name = "x" }} })) == .bad);
    try std.testing.expect((try apply(a, old, .{ .actions = &.{ .{ .key = "s", .name = "share" }, .{ .key = "s", .name = "again" } } })) == .bad);
    try std.testing.expect((try apply(a, old, .{ .actions = &.{.{ .key = "s", .name = "s", .choices = &.{"a"}, .input = "h" }} })) == .bad);
}
