//! The bookkeeping of a drawn attach of a group (`tuppet attach --drawn
//! --group NAME`): the members it shows one at a time, ordered by the
//! numbers the daemon gave them, the boxes and side sessions it knows of,
//! what needs attention, which members fit the bar, and the switcher's
//! keys. Streams, painting, and the keyboard are drawn.zig's.

const std = @import("std");
const protocol = @import("protocol.zig");
const status = @import("status.zig");

const Status = status.Status;

/// A status kept for as long as it is the latest, in an arena of its own.
pub const Kept = struct {
    arena: std.heap.ArenaAllocator,
    st: Status,

    /// A copy of `st`.
    pub fn of(gpa: std.mem.Allocator, st: Status) !*Kept {
        const k = try gpa.create(Kept);
        errdefer gpa.destroy(k);
        k.arena = .init(gpa);
        errdefer k.arena.deinit();
        const a = k.arena.allocator();
        const line = try protocol.stringifyAlloc(a, st);
        k.st = try std.json.parseFromSliceLeaky(Status, a, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        return k;
    }

    pub fn destroy(k: *Kept, gpa: std.mem.Allocator) void {
        k.arena.deinit();
        gpa.destroy(k);
    }
};

pub const Member = struct {
    id: u64,
    kept: *Kept,
    /// The number of the copy's top row when it was last in front: coming
    /// back asks for the rows from there on.
    top_row: ?u64 = null,
    /// Its bell count when it was last in front.
    bells_seen: u64 = 0,
    /// It was in front since it joined.
    visited: bool = false,
    /// It needed attention at the last look, and the bell rang for that.
    rang: bool = false,

    pub fn st(m: *const Member) *const Status {
        return &m.kept.st;
    }

    pub fn number(m: *const Member) u32 {
        return m.st().number orelse std.math.maxInt(u32);
    }

    pub fn running(m: *const Member) bool {
        return m.st().state == .running;
    }

    pub fn name(m: *const Member, buf: []u8) []const u8 {
        return m.st().name orelse (std.fmt.bufPrint(buf, "#{d}", .{m.id}) catch "");
    }
};

pub const Group = struct {
    gpa: std.mem.Allocator,
    name: []const u8,
    /// Ordered by number.
    members: std.ArrayList(*Member) = .empty,
    /// Boxes over any session, and the side sessions tied to members, by
    /// id.
    others: std.AutoHashMapUnmanaged(u64, *Kept) = .empty,

    pub fn deinit(g: *Group) void {
        for (g.members.items) |m| {
            m.kept.destroy(g.gpa);
            g.gpa.destroy(m);
        }
        g.members.deinit(g.gpa);
        var it = g.others.valueIterator();
        while (it.next()) |k| k.*.destroy(g.gpa);
        g.others.deinit(g.gpa);
    }

    /// Whether `st` is a member: in the group, and no side session.
    pub fn isMember(g: *const Group, st: Status) bool {
        const name = st.group orelse return false;
        return std.mem.eql(u8, name, g.name) and st.side_of == null and st.over == null;
    }

    pub fn index(g: *const Group, id: u64) ?usize {
        for (g.members.items, 0..) |m, i| if (m.id == id) return i;
        return null;
    }

    pub fn get(g: *const Group, id: u64) ?*Member {
        return g.members.items[g.index(id) orelse return null];
    }

    pub fn byNumber(g: *const Group, n: u32) ?*Member {
        for (g.members.items) |m| if (m.st().number == n) return m;
        return null;
    }

    /// What happened to a member's status.
    pub const Seen = enum { joined, changed, left, other };

    /// Take a session's status: a member joins or changes, one that left
    /// the group leaves, boxes and side sessions are kept.
    pub fn seen(g: *Group, st: Status) !Seen {
        if (g.isMember(st)) {
            const kept = try Kept.of(g.gpa, st);
            if (g.get(st.id)) |m| {
                const was = m.st().number;
                m.kept.destroy(g.gpa);
                m.kept = kept;
                if (was != st.number) g.sort();
                return .changed;
            }
            const m = g.gpa.create(Member) catch |err| {
                kept.destroy(g.gpa);
                return err;
            };
            m.* = .{ .id = st.id, .kept = kept, .bells_seen = st.bell_count };
            g.members.append(g.gpa, m) catch |err| {
                kept.destroy(g.gpa);
                g.gpa.destroy(m);
                return err;
            };
            g.sort();
            return .joined;
        }
        if (g.get(st.id) != null) {
            g.gone(st.id);
            return .left;
        }
        if (st.over != null or st.side_of != null) {
            const kept = try Kept.of(g.gpa, st);
            const entry = g.others.getOrPut(g.gpa, st.id) catch |err| {
                kept.destroy(g.gpa);
                return err;
            };
            if (entry.found_existing) entry.value_ptr.*.destroy(g.gpa);
            entry.value_ptr.* = kept;
        }
        return .other;
    }

    /// The session `id` was removed.
    pub fn gone(g: *Group, id: u64) void {
        if (g.index(id)) |i| {
            const m = g.members.orderedRemove(i);
            m.kept.destroy(g.gpa);
            g.gpa.destroy(m);
        }
        if (g.others.fetchRemove(id)) |kv| kv.value.destroy(g.gpa);
    }

    fn sort(g: *Group) void {
        std.mem.sort(*Member, g.members.items, {}, struct {
            fn less(_: void, a: *Member, b: *Member) bool {
                return a.number() < b.number() or (a.number() == b.number() and a.id < b.id);
            }
        }.less);
    }

    /// The status of a box or side session.
    pub fn other(g: *const Group, id: u64) ?*const Status {
        const k = g.others.get(id) orelse return null;
        return &k.st;
    }

    /// The title of the first box that waits over `id`: it runs, takes
    /// keys, and has no writer.
    pub fn boxWaits(g: *const Group, id: u64) ?[]const u8 {
        var it = g.others.valueIterator();
        while (it.next()) |k| {
            const st = &k.*.st;
            const o = st.over orelse continue;
            if (o.id != id or st.state != .running or o.grab == .never or st.writer != null) continue;
            return o.title orelse st.name orelse "box";
        }
        return null;
    }

    /// Why member `m` needs attention, when it does and is not in front:
    /// a box waits over it, its program reads hidden input, it rang the
    /// bell since it was last in front, or the caller flagged it.
    pub fn attention(g: *const Group, m: *const Member) ?[]const u8 {
        if (g.boxWaits(m.id)) |title| return title;
        if (m.st().attention) |text| return text;
        if (m.st().hidden_input == true) return "password?";
        if (m.st().bell_count > m.bells_seen) return "bell";
        return null;
    }
};

/// Which of `widths` (each member's cells on the bar, the front's at
/// `front`) fit `room` cells with `sep` between them: all when they
/// fit, else the front, those needing attention (`wanted`), and the
/// others in order as long as room is left for a count of the rest.
/// Returns how many were left out.
pub fn fitBar(widths: []const usize, wanted: []const bool, front: ?usize, room: usize, sep: usize, count_cells: usize, shown: []bool) usize {
    var total: usize = 0;
    for (widths, 0..) |w, i| total += w + (if (i > 0) sep else 0);
    if (total <= room) {
        @memset(shown, true);
        return 0;
    }
    @memset(shown, false);
    var used: usize = count_cells;
    const take = struct {
        fn f(s: []bool, ws: []const usize, i: usize, u: *usize, r: usize, gap: usize) void {
            if (s[i]) return;
            const need = ws[i] + gap;
            if (u.* + need > r) return;
            s[i] = true;
            u.* += need;
        }
    }.f;
    if (front) |f| take(shown, widths, f, &used, room, sep);
    for (wanted, 0..) |w, i| if (w) take(shown, widths, i, &used, room, sep);
    for (0..widths.len) |i| take(shown, widths, i, &used, room, sep);
    var left: usize = 0;
    for (shown) |s| left += @intFromBool(!s);
    return left;
}

test "the bar keeps the front and those that need attention, and counts the rest" {
    const widths = [_]usize{ 10, 10, 10, 10, 10 };
    var shown: [5]bool = undefined;
    try std.testing.expectEqual(@as(usize, 0), fitBar(&widths, &.{ false, false, false, false, false }, 0, 100, 3, 4, &shown));
    const left = fitBar(&widths, &.{ false, false, false, true, false }, 2, 30, 3, 4, &shown);
    try std.testing.expect(shown[2] and shown[3]);
    try std.testing.expectEqual(@as(usize, 3), left);
}

/// How the switcher's footer of `widths` wraps onto rows of `room`
/// cells with `sep` between parts, in at most `most` rows (one or
/// more): filled from the end, so the last parts, tuppet's own keys,
/// always show and those left out are the first. `starts` gets each
/// row's first part, top row first; returns the number of rows.
pub fn wrapFooter(widths: []const usize, room: usize, sep: usize, most: usize, starts: []usize) usize {
    var rows: usize = 0;
    var end = widths.len;
    while (end > 0 and rows < most) : (rows += 1) {
        var start = end - 1;
        var used = widths[start];
        while (start > 0 and used + sep + widths[start - 1] <= room) {
            start -= 1;
            used += sep + widths[start];
        }
        starts[rows] = start;
        end = start;
    }
    std.mem.reverse(usize, starts[0..rows]);
    return rows;
}

test "the footer wraps from the end and leaves out the first parts" {
    var starts: [4]usize = undefined;
    const widths = [_]usize{ 6, 8, 10, 8, 8 };
    try std.testing.expectEqual(@as(usize, 1), wrapFooter(&widths, 100, 3, 3, &starts));
    try std.testing.expectEqual(@as(usize, 0), starts[0]);
    // 8+3+8 fits 20, 10 does not join them.
    try std.testing.expectEqual(@as(usize, 3), wrapFooter(&widths, 20, 3, 3, &starts));
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3 }, starts[0..3]);
    try std.testing.expectEqual(@as(usize, 2), wrapFooter(&widths, 20, 3, 2, &starts));
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, starts[0..2]);
}

/// What a key in the switcher asks for.
pub const Do = union(enum) {
    none,
    /// Close the switcher; the front stays.
    close,
    /// Go to this member, and close.
    go: u64,
    detach,
    /// Send the switch key, or the menu key, to the front.
    send_switch_key,
    send_menu_key,
    /// Step the side pane of this member, or ask for one.
    side_step: u64,
    /// This member's history in $PAGER.
    history: u64,
    /// Report the caller's action: member, key, and value.
    action: struct { id: u64, key: u8, value: ?[]const u8 },
};

/// A key the switcher takes.
pub const Key = union(enum) {
    switch_key,
    menu_key,
    bytes: []const u8,
};

/// Action letters do nothing this long after the switcher opened.
pub const quiet_ns: i64 = 500 * std.time.ns_per_ms;
/// Digits wait this long for another one before they jump.
pub const digits_ns: i64 = 600 * std.time.ns_per_ms;

pub const Switcher = struct {
    gpa: std.mem.Allocator,
    open: bool = false,
    opened_at: i64 = 0,
    /// The selected member's id.
    selected: ?u64 = null,
    /// The filter by name while it is typed or kept.
    filter: std.ArrayList(u8) = .empty,
    filtering: bool = false,
    digits: [4]u8 = undefined,
    digits_len: usize = 0,
    digits_at: i64 = 0,
    /// An action that waits: for its second press, a choice, or a line of
    /// text.
    pending: ?Pending = null,
    text: std.ArrayList(u8) = .empty,
    no_detach: bool = false,

    pub const Pending = struct {
        id: u64,
        key: u8,
        kind: enum { confirm, choice, input },
        /// The choice selected.
        choice: usize = 0,
    };

    pub fn deinit(sw: *Switcher) void {
        sw.filter.deinit(sw.gpa);
        sw.text.deinit(sw.gpa);
    }

    /// Open it with `select` selected: the member in front before.
    pub fn show(sw: *Switcher, select: ?u64, now: i64) void {
        sw.open = true;
        sw.opened_at = now;
        sw.selected = select;
        sw.filter.clearRetainingCapacity();
        sw.filtering = false;
        sw.digits_len = 0;
        sw.pending = null;
        sw.text.clearRetainingCapacity();
    }

    pub fn hide(sw: *Switcher) void {
        sw.open = false;
        sw.pending = null;
        sw.filtering = false;
        sw.digits_len = 0;
    }

    /// The members the list shows: all, or those whose name holds the
    /// filter, in `out`.
    pub fn shown(sw: *const Switcher, g: *const Group, out: []*Member) []*Member {
        var n: usize = 0;
        for (g.members.items) |m| {
            if (sw.filter.items.len > 0) {
                var buf: [24]u8 = undefined;
                if (std.ascii.findIgnoreCase(m.name(&buf), sw.filter.items) == null) continue;
            }
            if (n == out.len) break;
            out[n] = m;
            n += 1;
        }
        return out[0..n];
    }

    /// When the digits typed jump by themselves; null without any.
    pub fn deadline(sw: *const Switcher) ?i64 {
        return if (sw.open and sw.digits_len > 0) sw.digits_at + digits_ns else null;
    }

    /// Jump to the number typed once its time is up.
    pub fn tick(sw: *Switcher, g: *const Group, now: i64) Do {
        const due = sw.deadline() orelse return .none;
        if (now < due) return .none;
        defer sw.digits_len = 0;
        const n = std.fmt.parseInt(u32, sw.digits[0..sw.digits_len], 10) catch return .none;
        const m = g.byNumber(n) orelse return .none;
        return .{ .go = m.id };
    }

    /// The action of member `m` for `key`, if it has one.
    fn actionOf(m: *const Member, letter: u8) ?status.Action {
        for (m.st().actions) |a| if (a.key.len == 1 and a.key[0] == letter) return a;
        return null;
    }

    pub fn pendingAction(sw: *const Switcher, g: *const Group) ?status.Action {
        const p = sw.pending orelse return null;
        const m = g.get(p.id) orelse return null;
        return actionOf(m, p.key);
    }

    /// Take a key while the switcher is open; `attention` says which
    /// members need attention, for Space.
    pub fn key(sw: *Switcher, g: *const Group, k: Key, now: i64, attention: []const bool) Do {
        var buf: [256]*Member = undefined;
        const list = sw.shown(g, &buf);
        switch (k) {
            .switch_key => return if (sw.selected) |id| .{ .go = id } else .close,
            .menu_key => return .send_menu_key,
            .bytes => {},
        }
        const bytes = k.bytes;
        if (sw.pending) |*p| return sw.pendingKey(g, p, bytes);
        if (sw.filtering) {
            if (isEnter(bytes)) {
                sw.filtering = false;
                return if (list.len > 0) .{ .go = list[0].id } else .none;
            }
            if (isEsc(bytes)) {
                sw.filtering = false;
                sw.filter.clearRetainingCapacity();
                return .none;
            }
            if (isBackspace(bytes)) {
                if (sw.filter.items.len > 0) sw.filter.items.len -= 1;
            } else if (printableText(bytes)) {
                sw.filter.appendSlice(sw.gpa, bytes) catch {};
            }
            sw.reselect(sw.shown(g, &buf));
            return .none;
        }
        if (isEnter(bytes)) return if (sw.selected) |id| .{ .go = id } else .close;
        if (isEsc(bytes)) return .close;
        if (std.mem.eql(u8, bytes, "/")) {
            sw.filtering = true;
            sw.filter.clearRetainingCapacity();
            return .none;
        }
        if (std.mem.eql(u8, bytes, " ")) {
            // The next member that needs attention after the selected one.
            const from = if (sw.selected) |id| g.index(id) orelse 0 else 0;
            const n = g.members.items.len;
            for (1..n + 1) |step| {
                const i = (from + step) % n;
                if (i < attention.len and attention[i]) return .{ .go = g.members.items[i].id };
            }
            return .none;
        }
        if (bytes.len == 1 and std.ascii.isDigit(bytes[0])) {
            if (sw.digits_len == sw.digits.len) sw.digits_len = 0;
            sw.digits[sw.digits_len] = bytes[0];
            sw.digits_len += 1;
            sw.digits_at = now;
            const typed = sw.digits[0..sw.digits_len];
            const n = std.fmt.parseInt(u32, typed, 10) catch return .none;
            // A longer number could still follow.
            for (g.members.items) |m| {
                var nb: [12]u8 = undefined;
                const text = std.fmt.bufPrint(&nb, "{d}", .{m.number()}) catch continue;
                if (text.len > typed.len and std.mem.startsWith(u8, text, typed)) return .none;
            }
            sw.digits_len = 0;
            const m = g.byNumber(n) orelse return .none;
            return .{ .go = m.id };
        }
        if (isUp(bytes) or isDown(bytes)) {
            sw.move(list, isDown(bytes));
            return .none;
        }
        // Letters: not within the first moments, so a key meant for the
        // front right before the switcher opened acts on nothing.
        if (now - sw.opened_at < quiet_ns) return .none;
        if (bytes.len != 1) return .none;
        const id = sw.selected orelse return .none;
        const m = g.get(id) orelse return .none;
        if (actionOf(m, bytes[0])) |a| {
            if (a.choices.len > 0) {
                sw.pending = .{ .id = id, .key = bytes[0], .kind = .choice };
                return .none;
            }
            if (a.input != null) {
                sw.pending = .{ .id = id, .key = bytes[0], .kind = .input };
                sw.text.clearRetainingCapacity();
                return .none;
            }
            if (a.confirm and m.running()) {
                sw.pending = .{ .id = id, .key = bytes[0], .kind = .confirm };
                return .none;
            }
            return .{ .action = .{ .id = id, .key = bytes[0], .value = null } };
        }
        return switch (bytes[0]) {
            '\\' => .send_switch_key,
            'd' => if (sw.no_detach) .none else .detach,
            'f' => .{ .side_step = id },
            'h' => .{ .history = id },
            'r' => if (!m.running()) .{ .action = .{ .id = id, .key = 'r', .value = null } } else .none,
            else => .none,
        };
    }

    fn pendingKey(sw: *Switcher, g: *const Group, p: *Pending, bytes: []const u8) Do {
        const a = sw.pendingAction(g) orelse {
            sw.pending = null;
            return .none;
        };
        // The caller may have changed the action meanwhile.
        const still = switch (p.kind) {
            .confirm => true,
            .choice => a.choices.len > 0,
            .input => a.input != null,
        };
        if (!still) {
            sw.pending = null;
            return .none;
        }
        if (p.kind == .choice) p.choice = @min(p.choice, a.choices.len - 1);
        if (isEsc(bytes)) {
            sw.pending = null;
            return .none;
        }
        switch (p.kind) {
            .confirm => {
                const again = bytes.len == 1 and bytes[0] == p.key;
                defer sw.pending = null;
                return if (again) .{ .action = .{ .id = p.id, .key = p.key, .value = null } } else .none;
            },
            .choice => {
                if (isEnter(bytes)) {
                    defer sw.pending = null;
                    return .{ .action = .{ .id = p.id, .key = p.key, .value = a.choices[p.choice] } };
                }
                if (isLeft(bytes) or isUp(bytes)) {
                    p.choice = (p.choice + a.choices.len - 1) % a.choices.len;
                } else if (isRight(bytes) or isDown(bytes) or std.mem.eql(u8, bytes, "\t")) {
                    p.choice = (p.choice + 1) % a.choices.len;
                } else if (bytes.len == 1 and bytes[0] >= '1' and bytes[0] <= '9' and bytes[0] - '1' < a.choices.len) {
                    defer sw.pending = null;
                    return .{ .action = .{ .id = p.id, .key = p.key, .value = a.choices[bytes[0] - '1'] } };
                }
                return .none;
            },
            .input => {
                if (isEnter(bytes)) {
                    defer sw.pending = null;
                    if (sw.text.items.len == 0) return .none;
                    return .{ .action = .{ .id = p.id, .key = p.key, .value = sw.text.items } };
                }
                if (isBackspace(bytes)) {
                    if (sw.text.items.len > 0) {
                        // A whole character.
                        var n = sw.text.items.len - 1;
                        while (n > 0 and sw.text.items[n] & 0xc0 == 0x80) n -= 1;
                        sw.text.items.len = n;
                    }
                } else if (printableText(bytes) and sw.text.items.len + bytes.len <= 200) {
                    sw.text.appendSlice(sw.gpa, bytes) catch {};
                }
                return .none;
            },
        }
    }

    fn move(sw: *Switcher, list: []*Member, down: bool) void {
        if (list.len == 0) return;
        var at: usize = 0;
        if (sw.selected) |id| for (list, 0..) |m, i| if (m.id == id) {
            at = i;
        };
        at = if (down) (at + 1) % list.len else (at + list.len - 1) % list.len;
        sw.selected = list[at].id;
    }

    /// Keep the selection among `list`.
    fn reselect(sw: *Switcher, list: []*Member) void {
        if (sw.selected) |id| for (list) |m| if (m.id == id) return;
        sw.selected = if (list.len > 0) list[0].id else null;
    }
};

fn isEnter(b: []const u8) bool {
    return std.mem.eql(u8, b, "\r") or std.mem.eql(u8, b, "\n") or std.mem.eql(u8, b, "\x1b[13u");
}

fn isEsc(b: []const u8) bool {
    return std.mem.eql(u8, b, "\x1b") or std.mem.eql(u8, b, "\x1b[27u");
}

fn isBackspace(b: []const u8) bool {
    return std.mem.eql(u8, b, "\x7f") or std.mem.eql(u8, b, "\x08") or std.mem.eql(u8, b, "\x1b[127u");
}

fn arrow(b: []const u8, final: u8) bool {
    return b.len == 3 and (b[1] == '[' or b[1] == 'O') and b[0] == 0x1b and b[2] == final;
}

fn isUp(b: []const u8) bool {
    return arrow(b, 'A');
}

fn isDown(b: []const u8) bool {
    return arrow(b, 'B');
}

fn isRight(b: []const u8) bool {
    return arrow(b, 'C');
}

fn isLeft(b: []const u8) bool {
    return arrow(b, 'D');
}

/// One character or more of printable text, no control or escape.
fn printableText(b: []const u8) bool {
    if (b.len == 0 or !std.unicode.utf8ValidateSlice(b)) return false;
    const view = std.unicode.Utf8View.initUnchecked(b);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (status.isControl(cp)) return false;
    return true;
}

const testing = std.testing;

fn testGroup(a: std.mem.Allocator) !Group {
    var g: Group = .{ .gpa = a, .name = "w" };
    for ([_]u32{ 0, 1, 2, 12 }, 1..) |n, id| _ = try g.seen(.{ .id = id, .name = "m", .group = "w", .number = n });
    return g;
}

test "the switcher jumps by number, waits for a longer one, and filters by name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = try testGroup(a);
    var sw: Switcher = .{ .gpa = a };
    sw.show(1, 0);
    const none: [4]bool = @splat(false);
    try testing.expectEqual(@as(u64, 3), sw.key(&g, .{ .bytes = "2" }, 1, &none).go);
    // 1 could be the start of 12.
    try testing.expectEqual(Do.none, sw.key(&g, .{ .bytes = "1" }, 1, &none));
    try testing.expectEqual(@as(u64, 4), sw.key(&g, .{ .bytes = "2" }, 2, &none).go);
    try testing.expectEqual(Do.none, sw.key(&g, .{ .bytes = "1" }, 3, &none));
    try testing.expectEqual(@as(u64, 2), sw.tick(&g, 3 + digits_ns).go);
    // The switch key goes to the selected member: twice toggles.
    try testing.expectEqual(@as(u64, 1), sw.key(&g, .switch_key, 4, &none).go);
    _ = try g.seen(.{ .id = 9, .name = "db07", .group = "w", .number = 5 });
    _ = sw.key(&g, .{ .bytes = "/" }, 5, &none);
    _ = sw.key(&g, .{ .bytes = "d" }, 5, &none);
    _ = sw.key(&g, .{ .bytes = "b" }, 5, &none);
    try testing.expectEqual(@as(u64, 9), sw.key(&g, .{ .bytes = "\r" }, 6, &none).go);
    const att = [_]bool{ false, false, true, false, false };
    sw.show(1, 0);
    try testing.expectEqual(@as(u64, 3), sw.key(&g, .{ .bytes = " " }, 1, &att).go);
}

test "letters wait half a second; actions ask for a second press, a choice, or a line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Group = .{ .gpa = a, .name = "w" };
    const actions = [_]status.Action{
        .{ .key = "x", .name = "close", .confirm = true },
        .{ .key = "s", .name = "share", .choices = &.{ "Once", "Live" } },
        .{ .key = "o", .name = "open", .input = "[user@]host" },
    };
    _ = try g.seen(.{ .id = 1, .group = "w", .number = 0, .actions = &actions });
    var sw: Switcher = .{ .gpa = a };
    sw.show(1, 0);
    const none = [_]bool{false};
    try testing.expectEqual(Do.none, sw.key(&g, .{ .bytes = "d" }, 1, &none));
    const later = quiet_ns + 1;
    try testing.expectEqual(Do.detach, sw.key(&g, .{ .bytes = "d" }, later, &none));
    try testing.expectEqual(Do.none, sw.key(&g, .{ .bytes = "x" }, later, &none));
    try testing.expectEqual(@as(u8, 'x'), sw.key(&g, .{ .bytes = "x" }, later, &none).action.key);
    _ = sw.key(&g, .{ .bytes = "s" }, later, &none);
    _ = sw.key(&g, .{ .bytes = "\x1b[C" }, later, &none);
    try testing.expectEqualStrings("Live", sw.key(&g, .{ .bytes = "\r" }, later, &none).action.value.?);
    _ = sw.key(&g, .{ .bytes = "o" }, later, &none);
    for ("db07") |c| _ = sw.key(&g, .{ .bytes = &.{c} }, later, &none);
    try testing.expectEqualStrings("db07", sw.key(&g, .{ .bytes = "\r" }, later, &none).action.value.?);
}
