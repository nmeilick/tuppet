//! Combining marks: a cell's base character composed with the marks after
//! it, as Unicode normalization form C composes them, and the marks left to
//! draw over it. The tables come from tools/marks.zig.

const std = @import("std");
const tables = @import("marks");

/// At most this many code points after the base are looked at; Ghostty
/// keeps no more per cell.
pub const max_rest = 64;

pub const Cluster = struct {
    base: u21,
    /// In canonical order.
    marks: []const u21,
};

/// The base of `cps` (a base and the rest of its grapheme) composed with
/// the code points that have a precomposed form with it, unless not
/// `composes`, and the marks that remain, in `buf`. Code points that are neither, such as variation
/// selectors and joiners, are left out. Unlike NFC, a precomposed base is
/// not decomposed first, which can leave a mark to draw rather than pick
/// another precomposed form; the drawing is the same.
pub fn cluster(cps: []const u21, buf: *[max_rest]u21, composes: bool) Cluster {
    const rest = buf[0..@min(cps.len - 1, max_rest)];
    @memcpy(rest, cps[1..][0..rest.len]);
    // Canonical order: each run of non-starters sorted by class, stably.
    var i: usize = 0;
    while (i < rest.len) {
        if (class(rest[i]) == 0) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < rest.len and class(rest[end]) != 0) end += 1;
        std.sort.insertion(u21, rest[i..end], {}, byClass);
        i = end;
    }
    var base = cps[0];
    var n: usize = 0;
    // The class of the latest code point not composed, which blocks those
    // of the same or a lower class.
    var last: ?u8 = null;
    for (rest) |cp| {
        const r = find(cp);
        const ccc: u8 = if (r) |x| x.ccc else 0;
        const blocked = if (last) |l| l == 0 or l >= ccc else false;
        if (composes and !blocked) if (composite(base, cp)) |c| {
            base = c;
            continue;
        };
        last = ccc;
        // n never passes the code point being read.
        if (r != null and r.?.mark) {
            rest[n] = cp;
            n += 1;
        }
    }
    return .{ .base = base, .marks = rest[0..n] };
}

/// Whether `cp` is a mark drawn over its base.
pub fn isMark(cp: u21) bool {
    return if (find(cp)) |r| r.mark else false;
}

fn class(cp: u21) u8 {
    return if (find(cp)) |r| r.ccc else 0;
}

fn byClass(_: void, a: u21, b: u21) bool {
    return class(a) < class(b);
}

fn find(cp: u21) ?tables.Run {
    const i = std.sort.binarySearch(tables.Run, &tables.runs, cp, struct {
        fn order(target: u21, r: tables.Run) std.math.Order {
            return if (target < r.first) .lt else if (target > r.last) .gt else .eq;
        }
    }.order) orelse return null;
    return tables.runs[i];
}

const hangul = struct {
    const s_base = 0xAC00;
    const l_base = 0x1100;
    const v_base = 0x1161;
    const t_base = 0x11A7;
    const l_count = 19;
    const v_count = 21;
    const t_count = 28;
    const s_count = l_count * v_count * t_count;
};

/// The primary composite of `a` then `b`, Hangul syllables included.
fn composite(a: u21, b: u21) ?u21 {
    const h = hangul;
    if (a >= h.l_base and a < h.l_base + h.l_count and b >= h.v_base and b < h.v_base + h.v_count)
        return h.s_base + ((a - h.l_base) * h.v_count + (b - h.v_base)) * h.t_count;
    if (a >= h.s_base and a < h.s_base + h.s_count and (a - h.s_base) % h.t_count == 0 and b > h.t_base and b < h.t_base + h.t_count)
        return a + (b - h.t_base);
    const i = std.sort.binarySearch(tables.Pair, &tables.pairs, [2]u21{ a, b }, struct {
        fn order(target: [2]u21, p: tables.Pair) std.math.Order {
            const o = std.math.order(target[0], p.first);
            return if (o != .eq) o else std.math.order(target[1], p.second);
        }
    }.order) orelse return null;
    return tables.pairs[i].composite;
}

test "compose marks onto their base as NFC does, and keep the rest to draw" {
    var buf: [max_rest]u21 = undefined;
    // e + acute is é; a + circumflex + dot below is ậ, whose dot below
    // composes first.
    var c = cluster(&.{ 'e', 0x0301 }, &buf, true);
    try std.testing.expectEqual(@as(u21, 0xE9), c.base);
    try std.testing.expectEqual(@as(usize, 0), c.marks.len);
    c = cluster(&.{ 'a', 0x0302, 0x0323 }, &buf, true);
    try std.testing.expectEqual(@as(u21, 0x1EAD), c.base);
    c = cluster(&.{ 'x', 0x0301, 0x0323, 0xFE0F }, &buf, true);
    try std.testing.expectEqual(@as(u21, 'x'), c.base);
    try std.testing.expectEqualSlices(u21, &.{ 0x0323, 0x0301 }, c.marks);
    // A mark that does not compose blocks later ones of its class.
    c = cluster(&.{ 'e', 0x0310, 0x0301 }, &buf, true);
    try std.testing.expectEqual(@as(u21, 'e'), c.base);
    try std.testing.expectEqualSlices(u21, &.{ 0x0310, 0x0301 }, c.marks);
    // Hangul jamo compose to a syllable: ᄒ ᅡ ᆫ is 한.
    c = cluster(&.{ 0x1112, 0x1161, 0x11AB }, &buf, true);
    try std.testing.expectEqual(@as(u21, 0xD55C), c.base);
    try std.testing.expectEqual(@as(usize, 0), c.marks.len);
    // Excluded composites stay apart.
    c = cluster(&.{ 0x0915, 0x093C }, &buf, true);
    try std.testing.expectEqual(@as(u21, 0x0915), c.base);
    try std.testing.expectEqualSlices(u21, &.{0x093C}, c.marks);
    c = cluster(&.{ 'a', 0x0302, 0x0323 }, &buf, false);
    try std.testing.expectEqual(@as(u21, 'a'), c.base);
    try std.testing.expectEqualSlices(u21, &.{ 0x0323, 0x0302 }, c.marks);
    try std.testing.expect(isMark(0x20E3) and !isMark(0xFE0F) and !isMark(0x034F) and !isMark('a'));
}
