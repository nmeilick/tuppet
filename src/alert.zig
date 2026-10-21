//! Alerts: per-session rules that watch the screen for a text, and the
//! hits they produce. The tracker matches a session's rules against the
//! lines that changed when it settles (see track.zig), so an occurrence
//! is a line that comes to show the text; the evaluator turns those into
//! hits, which this log keeps, at most ten a second per alert; the latest
//! one a burst left out goes in once its second is over.

const std = @import("std");
const names = @import("names.zig");
const status = @import("status.zig");
const limits = @import("limits.zig");

/// A session has at most this many alerts, one bit each in a row's mask.
pub const max_alerts = 32;
/// The longest text an alert watches for.
pub const max_match_len = 256;
/// The hit log keeps this many hits.
pub const max_hits = 64;
/// A hit keeps at most this much of its line.
pub const max_line_len = 512;
/// Hits of one alert beyond this many a second are only counted.
pub const max_rate = 10;

pub const Mask = u32;

/// An alert as requests give it and the store keeps it.
pub const Rule = struct {
    name: []const u8,
    /// Text on one logical line.
    match: []const u8,
    /// Compare ASCII letters regardless of case.
    icase: bool = false,
};

/// Why `rule` cannot be an alert, or null when it can.
pub fn ruleError(rule: Rule) ?[]const u8 {
    if (names.nameErrorOf(rule.name, "the alert name")) |why| return why;
    if (rule.match.len == 0) return "its text is empty";
    if (rule.match.len > max_match_len) return "its text is longer than 256 bytes";
    if (std.mem.findAny(u8, rule.match, "\r\n") != null) return "its text contains a line break: lines are matched one at a time";
    // The screen's text never holds them.
    for (rule.match) |c| if (c < 0x20 or c == 0x7f) return "its text contains a control character, which the screen never shows";
    return null;
}

/// Why `rules` cannot be a session's alerts, in `gpa`; null when they can.
pub fn rulesError(gpa: std.mem.Allocator, rules: []const Rule) !?[]const u8 {
    if (rules.len > max_alerts) return try std.fmt.allocPrint(gpa, "a session takes at most {d} alerts", .{max_alerts});
    for (rules, 0..) |rule, i| {
        if (ruleError(rule)) |why| return try std.fmt.allocPrint(gpa, "alert '{s}': {s}", .{ rule.name, why });
        for (rules[0..i]) |other| if (std.mem.eql(u8, other.name, rule.name)) {
            return try std.fmt.allocPrint(gpa, "alert '{s}' is given twice", .{rule.name});
        };
    }
    return null;
}

/// The alerts of a session, each in a slot whose bit stands for it in
/// row masks. Strings are owned.
pub const Set = struct {
    gpa: std.mem.Allocator,
    slots: [max_alerts]?Rule = @splat(null),
    /// Slots in the order their alerts were added.
    order: [max_alerts]u8 = undefined,
    len: usize = 0,
    /// The bits of alerts whose text can start with a byte; both cases
    /// with icase.
    first: [256]Mask = @splat(0),

    pub fn deinit(set: *Set) void {
        for (&set.slots) |*slot| if (slot.*) |rule| {
            set.gpa.free(rule.name);
            set.gpa.free(rule.match);
            slot.* = null;
        };
        set.len = 0;
    }

    /// The bits of every alert.
    pub fn all(set: *const Set) Mask {
        var m: Mask = 0;
        for (set.order[0..set.len]) |slot| m |= bit(slot);
        return m;
    }

    pub fn find(set: *const Set, name: []const u8) ?u5 {
        for (set.order[0..set.len]) |slot| {
            if (std.mem.eql(u8, set.slots[slot].?.name, name)) return @intCast(slot);
        }
        return null;
    }

    /// Add a checked rule; returns its slot.
    pub fn add(set: *Set, rule: Rule) error{ Exists, Limit, OutOfMemory }!u5 {
        if (set.find(rule.name) != null) return error.Exists;
        if (set.len == max_alerts) return error.Limit;
        const slot: u5 = for (set.slots, 0..) |s, i| {
            if (s == null) break @intCast(i);
        } else unreachable;
        const name = try set.gpa.dupe(u8, rule.name);
        errdefer set.gpa.free(name);
        const match = try set.gpa.dupe(u8, rule.match);
        set.slots[slot] = .{ .name = name, .match = match, .icase = rule.icase };
        set.order[set.len] = slot;
        set.len += 1;
        set.first[match[0]] |= bit(slot);
        if (rule.icase) {
            set.first[std.ascii.toLower(match[0])] |= bit(slot);
            set.first[std.ascii.toUpper(match[0])] |= bit(slot);
        }
        return slot;
    }

    /// Remove the alert named `name`; returns its slot.
    pub fn remove(set: *Set, name: []const u8) ?u5 {
        const slot = set.find(name) orelse return null;
        const rule = set.slots[slot].?;
        set.gpa.free(rule.name);
        set.gpa.free(rule.match);
        set.slots[slot] = null;
        const at = std.mem.indexOfScalar(u8, set.order[0..set.len], slot).?;
        std.mem.copyForwards(u8, set.order[at .. set.len - 1], set.order[at + 1 .. set.len]);
        set.len -= 1;
        for (&set.first) |*m| m.* &= ~bit(slot);
        return slot;
    }

    /// The rules in the order they were added; strings alias the set.
    pub fn rules(set: *const Set, gpa: std.mem.Allocator) ![]Rule {
        const out = try gpa.alloc(Rule, set.len);
        for (set.order[0..set.len], out) |slot, *r| r.* = set.slots[slot].?;
        return out;
    }

    /// The names in the order the alerts were added, in `gpa`.
    pub fn nameList(set: *const Set, gpa: std.mem.Allocator) ![]const []const u8 {
        const out = try gpa.alloc([]const u8, set.len);
        for (set.order[0..set.len], out) |slot, *n| n.* = try gpa.dupe(u8, set.slots[slot].?.name);
        return out;
    }

    /// The bits of the alerts whose text is in `text`.
    pub fn mask(set: *const Set, text: []const u8) Mask {
        if (set.len == 0) return 0;
        const wanted = set.all();
        var found: Mask = 0;
        for (0..text.len) |i| {
            found |= set.matchAt(text, i, set.first[text[i]] & ~found);
            if (found == wanted) break;
        }
        return found;
    }

    /// The bits of the alerts whose text starts at `text[i]`.
    pub fn startsAt(set: *const Set, text: []const u8, i: usize) Mask {
        return set.matchAt(text, i, set.first[text[i]]);
    }

    /// The length of the longest alert text; 0 without alerts.
    pub fn longest(set: *const Set) usize {
        var n: usize = 0;
        for (set.order[0..set.len]) |slot| n = @max(n, set.slots[slot].?.match.len);
        return n;
    }

    /// Those of the alerts in `candidates` whose text starts at `text[i]`.
    fn matchAt(set: *const Set, text: []const u8, i: usize, candidates: Mask) Mask {
        var found: Mask = 0;
        var bits = candidates;
        while (bits != 0) : (bits &= bits - 1) {
            const slot: u5 = @intCast(@ctz(bits));
            const rule = set.slots[slot].?;
            if (rule.match.len > text.len - i) continue;
            const here = text[i..][0..rule.match.len];
            // The last byte first: a cheap no for texts that share a long
            // start with the output.
            const last = rule.match[rule.match.len - 1];
            if (here[here.len - 1] != last and !(rule.icase and std.ascii.toLower(here[here.len - 1]) == std.ascii.toLower(last))) continue;
            if (if (rule.icase) std.ascii.eqlIgnoreCase(here, rule.match) else std.mem.eql(u8, here, rule.match)) found |= bit(slot);
        }
        return found;
    }
};

pub fn bit(slot: anytype) Mask {
    return @as(Mask, 1) << @intCast(slot);
}

/// Where the line of a hit was when it was seen: on a screen, in the
/// history, or gone before its text could be read.
pub const Region = enum { visible, scrollback, lost };

/// A line that came to show the texts of some alerts, as the tracker
/// found it; its text is in a buffer of the caller's.
pub const Candidate = struct {
    mask: Mask,
    /// The seq of the settle that found it.
    seq: u64,
    region: Region,
    /// Counted as `view --since` counts rows: the top row of the screen
    /// is 1, the history row above it 0, and so on.
    row: ?i64,
    start: usize = 0,
    len: usize = 0,
};

/// A hit, as replies carry it.
pub const Hit = struct {
    /// Hits are numbered from 1 in each session.
    n: u64,
    /// The alerts whose text the line showed.
    alerts: []const []const u8,
    line: []const u8,
    seq: u64,
    region: Region,
    row: ?i64,
    /// Hits of these alerts that the rate limit left out since each one's
    /// previous hit.
    suppressed: u64,

    /// A copy in `gpa`.
    pub fn dupe(h: Hit, gpa: std.mem.Allocator) !Hit {
        var out = h;
        const list = try gpa.alloc([]const u8, h.alerts.len);
        for (h.alerts, list) |name, *n| n.* = try gpa.dupe(u8, name);
        out.alerts = list;
        out.line = try gpa.dupe(u8, h.line);
        return out;
    }
};

const Limit = struct {
    window_ns: i64 = std.math.minInt(i64) / 2,
    count: u32 = 0,
    suppressed: u64 = 0,
    /// The latest hit the rate limit left out since the alert's last one
    /// in the log; it goes in once the window is over.
    pending: ?Pending = null,

    /// Whether its window is over at `now`.
    fn over(limit: Limit, now: i64) bool {
        return now - limit.window_ns >= std.time.ns_per_s;
    }
};

const Pending = struct {
    seq: u64,
    region: Region,
    row: ?i64,
    /// Cleaned and cut; owned by the log.
    line: []u8,

    fn same(p: Pending, other: Pending) bool {
        return p.seq == other.seq and p.region == other.region and std.meta.eql(p.row, other.row) and std.mem.eql(u8, p.line, other.line);
    }
};

/// The latest hits of a session, guarded by its terminal_mutex.
pub const Log = struct {
    gpa: std.mem.Allocator,
    /// Hit n is at ring[(n - 1) % max_hits] while n > next - 1 - max_hits.
    ring: [max_hits]Hit = undefined,
    /// The n of the next hit.
    next: u64 = 1,
    limits: [max_alerts]Limit = @splat(.{}),
    /// When the first window with a pending hit is over, in monotonic
    /// nanoseconds; maxInt without one. Read without the lock.
    due: std.atomic.Value(i64) = .init(std.math.maxInt(i64)),

    pub fn deinit(log: *Log) void {
        var n = log.oldest();
        while (n < log.next) : (n += 1) free(log.gpa, log.ring[index(n)]);
        log.next = 1;
        for (0..max_alerts) |slot| log.dropPending(@intCast(slot));
    }

    /// The n of the latest hit; null before the first.
    pub fn latest(log: *const Log) ?u64 {
        return if (log.next > 1) log.next - 1 else null;
    }

    /// The n of the oldest hit kept; `next` when none is.
    pub fn oldest(log: *const Log) u64 {
        return if (log.next > max_hits) log.next - max_hits else 1;
    }

    pub fn get(log: *const Log, n: u64) ?*const Hit {
        if (n < log.oldest() or n >= log.next) return null;
        return &log.ring[index(n)];
    }

    /// The hits kept, oldest first.
    pub fn each(log: *const Log) Iterator {
        return .{ .log = log, .n = log.oldest() };
    }

    pub const Iterator = struct {
        log: *const Log,
        n: u64,

        pub fn next(it: *Iterator) ?*const Hit {
            if (it.n >= it.log.next) return null;
            defer it.n += 1;
            return &it.log.ring[index(it.n)];
        }
    };

    /// Hits of the alert in `slot` that never made it into the log, such
    /// as rows that scrolled past before the evaluator saw them.
    pub fn suppress(log: *Log, slot: u5, count: u64) void {
        log.limits[slot].suppressed += count;
    }

    /// The alert in `slot` was removed or replaced.
    pub fn forget(log: *Log, slot: u5) void {
        log.dropPending(slot);
        log.limits[slot] = .{};
        log.updateDue();
    }

    /// When `flush` has a hit to log, at the earliest; maxInt for never.
    pub fn flushDue(log: *const Log) i64 {
        return log.due.load(.acquire);
    }

    /// Log the latest hit that the rate limit left out of a burst, once
    /// the alert's window is over, or with `all` at once, as the first hit
    /// of a new window. Null when none is due.
    pub fn flush(log: *Log, set: *const Set, now: i64, all: bool) !?*const Hit {
        while (true) {
            const first = for (log.limits, 0..) |limit, slot| {
                if (limit.pending != null and (all or limit.over(now))) break slot;
            } else return null;
            const p = log.limits[first].pending.?;
            // The alerts left out of the same line go in as one hit.
            var mask: Mask = 0;
            var suppressed: u64 = 0;
            for (log.limits, 0..) |limit, slot| {
                const other = limit.pending orelse continue;
                if (!(all or limit.over(now)) or !other.same(p)) continue;
                mask |= bit(slot);
                suppressed += limit.suppressed -| 1;
            }
            const hit = if (mask & set.all() != 0) try log.append(set, mask & set.all(), p.seq, p.region, p.row, p.line, suppressed) else null;
            var bits = mask;
            while (bits != 0) : (bits &= bits - 1) {
                const slot: u5 = @intCast(@ctz(bits));
                log.dropPending(slot);
                log.limits[slot].suppressed = 0;
                log.limits[slot].window_ns = now;
                log.limits[slot].count = 1;
            }
            log.updateDue();
            if (hit) |h| return h;
        }
    }

    /// Log the hit `c` stands for, of the alerts of `set` that are within
    /// their rate at `now` (monotonic); `text` holds its line. Null when
    /// the rate limit left out every one of them.
    pub fn add(log: *Log, set: *const Set, c: Candidate, text: []const u8, now: i64) !?*const Hit {
        defer log.updateDue();
        var mask = c.mask & set.all();
        var suppressed: u64 = 0;
        var bits = mask;
        while (bits != 0) : (bits &= bits - 1) {
            const slot: u5 = @intCast(@ctz(bits));
            const limit = &log.limits[slot];
            if (limit.over(now)) {
                limit.window_ns = now;
                limit.count = 0;
            }
            if (limit.count >= max_rate) {
                limit.suppressed += 1;
                mask &= ~bit(slot);
                try log.keepPending(slot, c, text);
                continue;
            }
            limit.count += 1;
        }
        if (mask == 0) return null;
        bits = mask;
        while (bits != 0) : (bits &= bits - 1) {
            const slot: u5 = @intCast(@ctz(bits));
            const limit = &log.limits[slot];
            suppressed += limit.suppressed;
            limit.suppressed = 0;
            // This hit is newer than the one left out.
            log.dropPending(slot);
        }
        const line = try status.cleanText(log.gpa, text, max_line_len);
        defer log.gpa.free(line);
        return try log.append(set, mask, c.seq, c.region, c.row, line, suppressed);
    }

    /// Log a hit of the alerts in `mask`, with a copy of `line`.
    fn append(log: *Log, set: *const Set, mask: Mask, seq: u64, region: Region, row: ?i64, text: []const u8, suppressed: u64) !*const Hit {
        const gpa = log.gpa;
        const line = try gpa.dupe(u8, text);
        errdefer gpa.free(line);
        const list = try gpa.alloc([]const u8, @popCount(mask));
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |name| gpa.free(name);
            gpa.free(list);
        }
        // In the order the alerts were added.
        for (set.order[0..set.len]) |slot| {
            if (mask & bit(slot) == 0) continue;
            list[filled] = try gpa.dupe(u8, set.slots[slot].?.name);
            filled += 1;
        }
        if (log.next > max_hits) free(gpa, log.ring[index(log.next)]);
        const hit = &log.ring[index(log.next)];
        hit.* = .{ .n = log.next, .alerts = list, .line = line, .seq = seq, .region = region, .row = row, .suppressed = suppressed };
        log.next += 1;
        return hit;
    }

    fn keepPending(log: *Log, slot: u5, c: Candidate, text: []const u8) !void {
        const line = try status.cleanText(log.gpa, text, max_line_len);
        log.dropPending(slot);
        log.limits[slot].pending = .{ .seq = c.seq, .region = c.region, .row = c.row, .line = line };
    }

    fn dropPending(log: *Log, slot: u5) void {
        const p = log.limits[slot].pending orelse return;
        log.gpa.free(p.line);
        log.limits[slot].pending = null;
    }

    fn updateDue(log: *Log) void {
        var due: i64 = std.math.maxInt(i64);
        for (log.limits) |limit| if (limit.pending != null) {
            due = @min(due, limit.window_ns +| std.time.ns_per_s);
        };
        log.due.store(due, .release);
    }

    /// Fill an empty log with the hits a session kept when it ended,
    /// oldest first, checked with hitsError.
    pub fn restore(log: *Log, hits: []const Hit) !void {
        for (hits) |h| {
            log.ring[index(h.n)] = try h.dupe(log.gpa);
            log.next = h.n + 1;
        }
    }

    fn index(n: u64) usize {
        return @intCast((n - 1) % max_hits);
    }

    fn free(gpa: std.mem.Allocator, h: Hit) void {
        for (h.alerts) |name| gpa.free(name);
        gpa.free(h.alerts);
        gpa.free(h.line);
    }
};

/// Why stored hits cannot fill a log, or null when they can: the hits a
/// log keeps are consecutive, from the first or the latest max_hits.
pub fn hitsError(hits: []const Hit) ?[]const u8 {
    if (hits.len == 0) return null;
    if (hits.len > max_hits) return "are too many";
    if (hits[0].n == 0 or (hits[0].n != 1 and hits.len != max_hits)) return "do not start where a hit log starts";
    for (hits, 0..) |h, i| {
        if (h.n != hits[0].n + i) return "are not numbered one after another";
        if (h.n > limits.max_seq or h.seq > limits.max_seq) return "have a number or seq out of range";
        if (h.alerts.len == 0 or h.alerts.len > max_alerts or h.line.len > max_line_len) return "have too many alerts or too long a line";
    }
    return null;
}

const testing = std.testing;

test "a set finds every alert whose text a line shows, with icase in any case" {
    var set: Set = .{ .gpa = testing.allocator };
    defer set.deinit();
    const ask = try set.add(.{ .name = "ask", .match = "Proceed?" });
    const err = try set.add(.{ .name = "err", .match = "error", .icase = true });
    try testing.expectError(error.Exists, set.add(.{ .name = "ask", .match = "x" }));
    try testing.expectEqual(bit(ask), set.mask("Do you want to Proceed? [y/n]"));
    try testing.expectEqual(bit(ask) | bit(err), set.mask("ERROR: Proceed?"));
    try testing.expectEqual(@as(Mask, 0), set.mask("Proceed"));
    try testing.expectEqual(err, set.remove("err").?);
    try testing.expectEqual(@as(Mask, 0), set.mask("ERROR"));
    const rules = try set.rules(testing.allocator);
    defer testing.allocator.free(rules);
    try testing.expectEqualStrings("ask", rules[0].name);
    try testing.expect(ruleError(.{ .name = "a", .match = "x\ny" }) != null);
    try testing.expect(ruleError(.{ .name = "1", .match = "x" }) != null);
}

test "the rate limit keeps ten hits a second per alert and counts the rest" {
    var set: Set = .{ .gpa = testing.allocator };
    defer set.deinit();
    const slot = try set.add(.{ .name = "tick", .match = "tick" });
    var log: Log = .{ .gpa = testing.allocator };
    defer log.deinit();
    const c: Candidate = .{ .mask = bit(slot), .seq = 1, .region = .visible, .row = 1 };
    var logged: usize = 0;
    for (0..25) |i| {
        if (try log.add(&set, c, "tick", @intCast(i * std.time.ns_per_ms))) |_| logged += 1;
    }
    try testing.expectEqual(@as(usize, max_rate), logged);
    // A second later the next one goes in and tells how many were left out.
    const next = (try log.add(&set, c, "tick", std.time.ns_per_s)).?;
    try testing.expectEqual(@as(u64, 15), next.suppressed);
    try testing.expectEqual(@as(?u64, 11), log.latest());
    // The log keeps the latest 64.
    for (0..100) |i| _ = try log.add(&set, c, "tick", @as(i64, @intCast(i + 2)) * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 111 - max_hits + 1), log.oldest());
    try testing.expect(log.get(10) == null);
}

test "the latest hit the rate limit left out goes in once its second is over" {
    var set: Set = .{ .gpa = testing.allocator };
    defer set.deinit();
    const slot = try set.add(.{ .name = "tick", .match = "tick" });
    var log: Log = .{ .gpa = testing.allocator };
    defer log.deinit();
    var buf: [16]u8 = undefined;
    for (0..25) |i| {
        const c: Candidate = .{ .mask = bit(slot), .seq = i + 1, .region = .visible, .row = 1 };
        _ = try log.add(&set, c, try std.fmt.bufPrint(&buf, "tick {d}", .{i}), @intCast(i * std.time.ns_per_ms));
    }
    try testing.expectEqual(@as(i64, std.time.ns_per_s), log.flushDue());
    try testing.expect(try log.flush(&set, std.time.ns_per_s - 1, false) == null);
    const end = (try log.flush(&set, std.time.ns_per_s, false)).?;
    try testing.expectEqualStrings("tick 24", end.line);
    try testing.expectEqual(@as(u64, 25), end.seq);
    try testing.expectEqual(@as(u64, 14), end.suppressed);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), log.flushDue());
    // It is the first hit of the next second.
    var logged: usize = 0;
    for (0..20) |_| {
        if (try log.add(&set, .{ .mask = bit(slot), .seq = 30, .region = .visible, .row = 1 }, "tick", std.time.ns_per_s + 1)) |_| logged += 1;
    }
    try testing.expectEqual(@as(usize, max_rate - 1), logged);
}

test "a log refilled from stored hits reads like the one that kept them" {
    var set: Set = .{ .gpa = testing.allocator };
    defer set.deinit();
    const slot = try set.add(.{ .name = "tick", .match = "tick" });
    var log: Log = .{ .gpa = testing.allocator };
    defer log.deinit();
    const c: Candidate = .{ .mask = bit(slot), .seq = 1, .region = .visible, .row = 1 };
    for (0..70) |i| _ = try log.add(&set, c, "tick", @as(i64, @intCast(i)) * std.time.ns_per_s);
    var kept: std.ArrayList(Hit) = .empty;
    defer kept.deinit(testing.allocator);
    var it = log.each();
    while (it.next()) |h| try kept.append(testing.allocator, h.*);
    try testing.expectEqual(@as(?[]const u8, null), hitsError(kept.items));
    try testing.expect(hitsError(kept.items[1..]) != null);
    var copy: Log = .{ .gpa = testing.allocator };
    defer copy.deinit();
    try copy.restore(kept.items);
    try testing.expectEqual(log.latest(), copy.latest());
    try testing.expectEqual(log.oldest(), copy.oldest());
    try testing.expectEqualStrings("tick", copy.get(70).?.alerts[0]);
}
