//! Conditions, what waits wait for: text on the screen or gone from it, a
//! quiet or settled screen, hidden input, an alert hit, and the end of the
//! program. A wait's
//! `until` is a list of conditions, met when any of them holds; the
//! fields of one condition must all hold.
//!
//! Text is matched on logical lines: rows joined across soft wraps, the
//! spacer cells of wide characters skipped, and empty cells inside a line
//! (such as a tab leaves) read as spaces. A scan copies those lines and
//! the state of their rows under terminal_mutex, and conditions are
//! checked against the copy after it is released.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const track = @import("track.zig");
const names = @import("names.zig");
const regex = @import("regex.zig");

const Key = vt.ScreenSet.Key;

/// The longest text a match condition takes.
pub const max_match_len = 4096;
/// The most conditions one `until` takes.
pub const max_conditions = 64;
/// A scan copies at most this many rows and this much text; the rows
/// past either limit go unchecked and are reported as lost.
pub const max_scan_rows = 10_000;
pub const max_scan_bytes = 2 << 20;
/// A bundled wait remembers at most this many rows where its needle went
/// away.
const max_absent_rows = 4096;

/// The input `after_input` means: the one with this input_seq, or the
/// latest one at each check.
pub const AfterInput = union(enum) {
    seq: u64,
    latest,

    pub const expected = "an input_seq or \"latest\"";

    pub fn fromJson(value: std.json.Value) ?AfterInput {
        return switch (value) {
            .integer => |n| if (n >= 0) .{ .seq = @intCast(n) } else null,
            .string => |s| if (std.mem.eql(u8, s, "latest")) .latest else null,
            else => null,
        };
    }

    /// The input_seq it stands for, given the latest one.
    pub fn inputSeq(self: AfterInput, latest: u64) u64 {
        return switch (self) {
            .seq => |n| n,
            .latest => latest,
        };
    }

    pub fn jsonStringify(self: AfterInput, jw: anytype) !void {
        switch (self) {
            .seq => |n| try jw.write(n),
            .latest => try jw.write("latest"),
        }
    }
};

pub const Hit = struct {
    /// An alert's name, or "*" for any.
    name: []const u8,
    /// Any hit numbered above this one counts; without it, a hit after
    /// the condition's since, its input, or the latest input.
    after_hit: ?u64 = null,
};

pub const Condition = struct {
    /// Text on one logical line: at most 4 KiB, without line breaks.
    match: ?[]const u8 = null,
    /// Compare ASCII letters regardless of case.
    icase: bool = false,
    /// match is a regular expression (see regex.zig), at most
    /// regex.max_pattern_len bytes; ^ and $ hold at the line's ends.
    regex: bool = false,
    /// With match and after_input: what the input typed, whose echo does
    /// not count. Copies of it on the line the cursor was on at the input
    /// are left out (without the input's snapshot: on the lines changed
    /// after it), and on every line when match is a part of it.
    typed: ?[]const u8 = null,
    /// Only what happened after this seq counts: text on a line whose
    /// text changed after it, an end after it.
    since: ?u64 = null,
    /// Only what is new since the input counts: text that the screen did
    /// not show there at the input, an end after it.
    after_input: ?AfterInput = null,
    /// The screen's text has not changed for this long.
    idle_ms: ?u64 = null,
    /// After a change of text or style since the condition's since, its
    /// input, or the wait's start, the text has not changed for this
    /// long, and no output waits to be read or settled.
    settled_ms: ?u64 = null,
    /// With settled_ms and after_input: the change must be to the text of
    /// a line other than the one the cursor was on at the input, so the
    /// input's echo alone is no change.
    past_input_line: bool = false,
    /// With match: the text was on the screen at the wait's start or came
    /// after it, and is gone from the screen now.
    absent: bool = false,
    /// The program has ended.
    ended: bool = false,
    /// The terminal reads a line without echo; with since or after_input,
    /// that began after it.
    hidden_input: bool = false,
    hit: ?Hit = null,

    /// The fields an older daemon does not know go out only when set, so
    /// that it takes the conditions that do not use them.
    pub fn jsonStringify(c: Condition, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Condition).@"struct".field_names) |name| {
            const v = @field(c, name);
            const newer = comptime std.mem.eql(u8, name, "regex") or std.mem.eql(u8, name, "typed") or std.mem.eql(u8, name, "past_input_line");
            const skip = switch (@typeInfo(@TypeOf(v))) {
                .optional => v == null and (newer or !jw.options.emit_null_optional_fields),
                .bool => newer and !v,
                else => false,
            };
            if (!skip) {
                try jw.objectField(name);
                try jw.write(v);
            }
        }
        try jw.endObject();
    }

    /// Whether the condition is `since` or `after_input` alone: some
    /// line's text changed after that point.
    pub fn changes(c: Condition) bool {
        return c.match == null and c.idle_ms == null and c.settled_ms == null and !c.ended and !c.hidden_input and
            c.hit == null and (c.since != null or c.after_input != null);
    }

    /// Whether checking the condition needs a scan of the screen.
    pub fn needsScan(c: Condition) bool {
        return c.match != null or c.settled_ms != null or c.changes();
    }

    /// What the condition waits for, in one word.
    pub fn kind(c: Condition) []const u8 {
        if (c.match != null) return if (c.absent) "gone" else "match";
        if (c.changes()) return "changed";
        if (c.hit != null) return "hit";
        if (c.hidden_input) return "hidden_input";
        if (c.settled_ms != null) return "settled";
        if (c.idle_ms != null) return "idle";
        return "ended";
    }

    /// When the idle part of the condition holds at the latest, if no text
    /// changes before; null without one.
    pub fn idleDeadline(c: Condition, last_text_change: i64, start: i64) ?i64 {
        const ms = c.idle_ms orelse return null;
        const from = if (c.since != null or c.after_input != null) @max(last_text_change, start) else last_text_change;
        return from +| nanos(ms);
    }

    /// When the settled part of the condition holds at the earliest, if
    /// the text does not change before; null without one. The quiet
    /// counts from the wait's start at the earliest.
    pub fn settledDeadline(c: Condition, last_text_change: i64, start: i64) ?i64 {
        const ms = c.settled_ms orelse return null;
        return @max(last_text_change, start) +| nanos(ms);
    }
};

fn nanos(ms: u64) i64 {
    return std.math.mul(i64, @intCast(@min(ms, std.math.maxInt(i64))), std.time.ns_per_ms) catch std.math.maxInt(i64);
}

/// Why `until` cannot be waited for, in `gpa`; null when it can.
pub fn problem(gpa: std.mem.Allocator, until: []const Condition) !?[]const u8 {
    if (until.len == 0) return "until needs at least one condition";
    if (until.len > max_conditions) return try std.fmt.allocPrint(gpa, "until takes at most {d} conditions", .{max_conditions});
    for (until, 0..) |c, i| {
        if (c.match == null and c.idle_ms == null and c.settled_ms == null and !c.ended and !c.hidden_input and c.hit == null and !c.changes()) {
            return try std.fmt.allocPrint(gpa, "until[{d}] waits for nothing: give it match, idle_ms, settled_ms, ended, hidden_input, or hit, or since or after_input alone", .{i});
        }
        if (c.absent) {
            if (c.match == null) return try std.fmt.allocPrint(gpa, "until[{d}].absent needs match", .{i});
            if (c.since != null or c.after_input != null) {
                return try std.fmt.allocPrint(gpa, "until[{d}].absent counts from the wait's start: it takes no since or after_input", .{i});
            }
        }
        if (c.match) |text| {
            if (text.len == 0) return try std.fmt.allocPrint(gpa, "until[{d}].match must not be empty", .{i});
            if (text.len > max_match_len) return try std.fmt.allocPrint(gpa, "until[{d}].match is longer than {d} bytes", .{ i, max_match_len });
            if (std.mem.findAny(u8, text, "\r\n") != null) {
                return try std.fmt.allocPrint(gpa, "until[{d}].match must not contain a line break: text is matched one line at a time", .{i});
            }
            if (c.regex) {
                if (text.len > regex.max_pattern_len) return try std.fmt.allocPrint(gpa, "until[{d}].match is longer than {d} bytes, the most a regex takes", .{ i, regex.max_pattern_len });
                var why: []const u8 = "";
                if (regex.compile(gpa, text, .{ .icase = c.icase }, &why)) |re| {
                    var compiled = re;
                    compiled.deinit(gpa);
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadPattern => return try std.fmt.allocPrint(gpa, "until[{d}].match is no valid regex: {s}", .{ i, why }),
                }
            }
        } else if (c.icase) return try std.fmt.allocPrint(gpa, "until[{d}].icase needs match", .{i});
        if (c.regex and c.match == null) return try std.fmt.allocPrint(gpa, "until[{d}].regex needs match", .{i});
        if (c.typed) |text| {
            if (c.match == null or c.absent or c.after_input == null) return try std.fmt.allocPrint(gpa, "until[{d}].typed needs match and after_input", .{i});
            if (text.len == 0 or text.len > max_match_len) return try std.fmt.allocPrint(gpa, "until[{d}].typed must be 1 to {d} bytes", .{ i, max_match_len });
            if (std.mem.findAny(u8, text, "\r\n") != null) return try std.fmt.allocPrint(gpa, "until[{d}].typed must not contain a line break", .{i});
        }
        if (c.past_input_line and (c.settled_ms == null or c.after_input == null))
            return try std.fmt.allocPrint(gpa, "until[{d}].past_input_line needs settled_ms and after_input", .{i});
        if (c.since != null and c.after_input != null) return try std.fmt.allocPrint(gpa, "until[{d}] takes since or after_input, not both", .{i});
        if (c.hit) |h| if (!std.mem.eql(u8, h.name, "*")) if (names.nameError(h.name)) |why| {
            return try std.fmt.allocPrint(gpa, "until[{d}].hit.name must be an alert's name or \"*\": {s}", .{ i, why });
        };
    }
    return null;
}

/// The first condition that needs something this daemon cannot check,
/// and why.
pub fn unsupported(until: []const Condition) ?struct { index: usize, why: []const u8 } {
    for (until, 0..) |c, i| {
        if (c.hidden_input and builtin.os.tag == .windows) return .{ .index = i, .why = "hidden_input is not supported on Windows" };
    }
    return null;
}

/// How often `needle`, at most max_match_len bytes, occurs in `text`,
/// overlapping occurrences included. It takes time linear in both, also
/// for a text that almost matches everywhere (Knuth-Morris-Pratt).
pub fn count(text: []const u8, needle: []const u8, icase: bool) usize {
    std.debug.assert(needle.len > 0 and needle.len <= max_match_len);
    if (text.len < needle.len) return 0;
    return if (icase) countIn(true, text, needle) else countIn(false, text, needle);
}

fn countIn(comptime icase: bool, text: []const u8, needle: []const u8) usize {
    const same = struct {
        inline fn f(a: u8, b: u8) bool {
            return if (icase) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
        }
    }.f;
    // overlap[i]: the longest proper prefix of needle[0..i + 1] that also
    // ends it.
    var overlap: [max_match_len]u16 = undefined;
    overlap[0] = 0;
    var k: usize = 0;
    for (needle[1..], 1..) |c, i| {
        while (k > 0 and !same(c, needle[k])) k = overlap[k - 1];
        if (same(c, needle[k])) k += 1;
        overlap[i] = @intCast(k);
    }
    // Between candidates the first byte is searched for at memchr speed.
    const skip = !icase or !std.ascii.isAlphabetic(needle[0]);
    var n: usize = 0;
    var j: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (j == 0 and skip) i = std.mem.findScalarPos(u8, text, i, needle[0]) orelse break;
        const c = text[i];
        while (j > 0 and !same(c, needle[j])) j = overlap[j - 1];
        if (same(c, needle[j])) j += 1;
        if (j == needle.len) {
            n += 1;
            j = overlap[j - 1];
        }
    }
    return n;
}

/// What a match condition looks for: its text or the regex compiled from
/// it, and the typed text whose echo does not count.
pub const Needle = struct {
    text: []const u8,
    icase: bool = false,
    re: ?*const regex.Regex = null,
    typed: ?[]const u8 = null,
    /// The match is a part of the typed text, so no copy of that counts,
    /// on any line.
    anywhere: bool = false,
    /// The bytes a regex may still search in this check.
    budget: ?*usize = null,

    pub fn of(c: *const Condition, re: ?*const regex.Regex) Needle {
        var n: Needle = .{ .text = c.match.?, .icase = c.icase, .re = re };
        if (c.typed) |typed| {
            n.typed = typed;
            n.anywhere = if (re) |r| if (r.find(typed, 0)) |span| span.start > 0 or span.end < typed.len else false else typed.len > n.text.len and
                (if (c.icase) std.ascii.findIgnoreCase(typed, n.text) else std.mem.find(u8, typed, n.text)) != null;
        }
        return n;
    }

    /// How often it occurs in `text`; on a line that shows the echo,
    /// outside the copies of the typed text.
    pub fn countIn(n: Needle, text: []const u8, echo: bool) usize {
        const typed = n.typed orelse return n.plain(text);
        if (!echo and !n.anywhere) return n.plain(text);
        if (n.re) |r| return regexCount(r, text, typed, n.budget);
        var total: usize = 0;
        var from: usize = 0;
        while (std.mem.findPos(u8, text, from, typed)) |at| {
            total += n.plain(text[from..at]);
            from = at + typed.len;
        }
        return total + n.plain(text[from..]);
    }

    fn plain(n: Needle, text: []const u8) usize {
        if (n.re) |r| return regexCount(r, text, null, n.budget);
        return count(text, n.text, n.icase);
    }
};

/// A regex looks at this much of a line, and searches at most
/// `max_regex_scan` bytes in one check of a condition: a pattern that
/// searches far past its matches costs the rest of the line each time,
/// and the budget keeps one from stalling the session's waits.
pub const max_regex_line = 4096;
pub const max_regex_scan = 256 << 10;

/// How often `r` matches `line`, without overlap, leaving out matches that
/// overlap a copy of `typed`. The whole line is matched, so ^ and $ hold
/// only at its ends; a match that ends where a long line was cut does not
/// count. Each search takes what it looks at from `budget`.
fn regexCount(r: *const regex.Regex, line: []const u8, typed: ?[]const u8, budget: ?*usize) usize {
    const text = regexText(line);
    const cut = text.len < line.len;
    var n: usize = 0;
    var from: usize = 0;
    while (from < text.len) {
        if (budget) |b| {
            if (b.* == 0) break;
            b.* -|= text.len - from;
        }
        const span = r.find(text, from) orelse break;
        if (typed) |t| if (copyOver(text, t, span)) |end| {
            from = end;
            continue;
        };
        if (cut and span.end == text.len) break;
        n += 1;
        from = span.end;
    }
    return n;
}

/// What a regex looks at of `line`: at most max_regex_line bytes, cut
/// before a UTF-8 character rather than inside one.
fn regexText(line: []const u8) []const u8 {
    var end = @min(line.len, max_regex_line);
    while (end < line.len and end + 3 > max_regex_line and line[end] & 0xc0 == 0x80) end -= 1;
    return line[0..end];
}

/// The end of a copy of `typed` that overlaps `span`, if any.
fn copyOver(text: []const u8, typed: []const u8, span: regex.Span) ?usize {
    const at = std.mem.findPos(u8, text, (span.start + 1) -| typed.len, typed) orelse return null;
    return if (at < span.end) at + typed.len else null;
}

/// Whether the rows [top, top + rows) hold `row`.
fn holds(top: i64, rows: u32, row: i64) bool {
    return row >= top and row < top + rows;
}

/// A logical line of a scan.
pub const Line = struct {
    /// The absolute number of its first row, and its row count.
    top: i64,
    rows: u32,
    /// Its text in `Scan.text`.
    start: u32,
    len: u32,
    /// The newest text change and blanking among the rows the tracker
    /// knows.
    text_seq: u64,
    blank_seq: u64,
    /// The newest change of anything visible among those rows.
    change_seq: u64 = 0,
    /// Some row has no known change: it scrolled too far into history, or
    /// a resize brought it back from there. Only a match without since or
    /// after_input goes by its text alone.
    unknown: bool = false,
    /// Its text did not fit into the scan, which has none of it.
    dropped: bool = false,
};

/// The text of the active screen, and of the rows that scrolled into
/// history after a given row, with what the tracker knows about them.
pub const Scan = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    lines: std.ArrayListUnmanaged(Line) = .empty,
    /// lines[0..history] are history rows; the rest is the screen.
    history: usize = 0,
    key: Key = .primary,
    epoch: u64 = 0,
    /// The top row of the primary screen, and the first history row the
    /// scan covers; the requested rows above it went unchecked.
    primary_top: i64 = 0,
    first: i64 = 0,
    /// Rows whose text did not fit.
    dropped: u64 = 0,
    input_seq: u64 = 0,
    /// Whether the input snapshot describes the scanned screen, and
    /// whether it lost text past its cap.
    snap_valid: bool = false,
    snap_truncated: bool = false,
    snap_lines: std.ArrayListUnmanaged(track.SnapLine) = .empty,
    snap_displaced: std.ArrayListUnmanaged(track.SnapText) = .empty,
    snap_text: std.ArrayListUnmanaged(u8) = .empty,
    snap_version: ?u64 = null,
    /// The absolute row the cursor was on at the input, when the snapshot
    /// is valid and knows it.
    snap_cursor_row: ?i64 = null,
    /// Output waits on the pty, or was read and not settled yet; the
    /// caller of `collect` sets it.
    output_pending: bool = false,

    pub fn deinit(scan: *Scan) void {
        scan.text.deinit(scan.gpa);
        scan.lines.deinit(scan.gpa);
        scan.snap_lines.deinit(scan.gpa);
        scan.snap_displaced.deinit(scan.gpa);
        scan.snap_text.deinit(scan.gpa);
    }

    /// Copy the active screen and, on the primary screen, the history rows
    /// from absolute row `from` on; terminal_mutex must be held.
    pub fn collect(scan: *Scan, tracker: *const track.Tracker, t: *vt.Terminal, from: ?i64) !void {
        scan.text.clearRetainingCapacity();
        scan.lines.clearRetainingCapacity();
        scan.history = 0;
        scan.dropped = 0;
        const key = t.screens.active_key;
        const pages = &t.screens.active.pages;
        const top = tracker.top(key);
        scan.key = key;
        scan.epoch = tracker.epoch;
        scan.primary_top = tracker.top(.primary);
        scan.input_seq = tracker.input_seq.load(.acquire);

        var above: usize = 0;
        if (key == .primary) if (from) |row| if (row < top) {
            const kept = pages.total_rows - pages.rows;
            above = @min(@as(usize, @intCast(top - row)), kept, max_scan_rows -| pages.rows);
        };
        const active = pages.getTopLeft(.active);
        const start = if (above > 0) active.up(above) orelse blk: {
            above = 0;
            break :blk active;
        } else active;
        scan.first = top - @as(i64, @intCast(above));

        const total = above + pages.rows;
        var it = start.rowIterator(.right_down, null);
        var y: usize = 0;
        while (y < total) {
            const first = it.next() orelse break;
            var rows: usize = 1;
            var p = first;
            while (y + rows < total and p.rowAndCell().row.wrap) {
                p = it.next() orelse break;
                rows += 1;
            }
            try scan.addLine(tracker, key, first, scan.first + @as(i64, @intCast(y)), rows);
            // A line that wraps onto the screen belongs to the screen.
            if (y + rows <= above) scan.history += 1;
            y += rows;
        }

        const snap = &tracker.snapshot;
        scan.snap_truncated = snap.truncated;
        scan.snap_valid = scan.input_seq == 0 or
            (snap.seq == scan.input_seq and snap.key == key and snap.generation == t.screens.generation(key));
        scan.snap_lines.clearRetainingCapacity();
        scan.snap_displaced.clearRetainingCapacity();
        scan.snap_cursor_row = if (scan.input_seq != 0 and scan.snap_valid) snap.cursor_row else null;
        if (scan.input_seq != 0 and scan.snap_valid) {
            try scan.snap_lines.appendSlice(scan.gpa, snap.lines.items);
            try scan.snap_displaced.appendSlice(scan.gpa, snap.displaced.items);
            if (scan.snap_version != snap.version) {
                scan.snap_version = null;
                scan.snap_text.clearRetainingCapacity();
                try scan.snap_text.appendSlice(scan.gpa, snap.text.items);
                scan.snap_version = snap.version;
            }
        }
    }

    fn addLine(scan: *Scan, tracker: *const track.Tracker, key: Key, first: vt.Pin, abs: i64, rows: usize) !void {
        var text_seq: u64 = 0;
        var blank_seq: u64 = 0;
        var change_seq: u64 = 0;
        var unknown = false;
        for (0..rows) |r| {
            const state = tracker.rowAt(key, abs + @as(i64, @intCast(r))) orelse {
                unknown = true;
                continue;
            };
            if (state.text_change_seq == track.unknown_seq) {
                unknown = true;
                continue;
            }
            text_seq = @max(text_seq, state.text_change_seq);
            blank_seq = @max(blank_seq, state.blank_seq);
            change_seq = @max(change_seq, state.change_seq);
        }
        const start = scan.text.items.len;
        var fits = start < max_scan_bytes;
        if (fits) {
            track.appendLineText(scan.gpa, &scan.text, .{ .y = 0, .rows = rows, .first = first }) catch {
                fits = false;
            };
            if (scan.text.items.len > max_scan_bytes) fits = false;
        }
        if (!fits) {
            scan.text.shrinkRetainingCapacity(start);
            scan.dropped += rows;
        }
        try scan.lines.append(scan.gpa, .{
            .top = abs,
            .rows = @intCast(rows),
            .start = @intCast(start),
            .len = @intCast(scan.text.items.len - start),
            .text_seq = text_seq,
            .blank_seq = blank_seq,
            .change_seq = change_seq,
            .unknown = unknown,
            .dropped = !fits,
        });
    }

    fn lineText(scan: *const Scan, line: Line) []const u8 {
        return scan.text.items[line.start..][0..line.len];
    }

    /// How often the snapshot showed `needle` on the rows of `line`; a
    /// snapshot line that held `cursor_row`, or without it any where
    /// `echo` says the line does now, counts outside the copies of the
    /// typed text.
    fn snapshotCount(scan: *const Scan, line: Line, needle: Needle, cursor_row: ?i64, echo_now: bool) usize {
        const lines = scan.snap_lines.items;
        var i = std.sort.partitionPoint(track.SnapLine, lines, line.top, struct {
            fn before(abs: i64, l: track.SnapLine) bool {
                return l.top + l.rows <= abs;
            }
        }.before);
        var n: usize = 0;
        while (i < lines.len and lines[i].top < line.top + line.rows) : (i += 1) {
            const echo = if (cursor_row) |row| holds(lines[i].top, lines[i].rows, row) else echo_now;
            n += needle.countIn(scan.snap_text.items[lines[i].start..][0..lines[i].len], echo);
        }
        return n;
    }

    /// How often the snapshot showed `needle` on lines that a resize took
    /// off their rows.
    fn displacedCount(scan: *const Scan, needle: Needle) usize {
        var n: usize = 0;
        for (scan.snap_displaced.items) |d| n += needle.countIn(scan.snap_text.items[d.start..][0..d.len], true);
        return n;
    }
};

/// What a check needs to know besides the scan.
pub const Facts = struct {
    /// Monotonic nanoseconds, now and at the last text change.
    now: i64,
    last_text_change: i64,
    /// The seq the session ended at; null while it runs.
    end_seq: ?u64,
    input_seq: u64,
    /// Monotonic nanoseconds of the latest input; 0 before any.
    input_ns: i64 = 0,
    /// Since when the terminal reads input without echo; null when it does
    /// not, or nobody knows.
    hidden: ?Hidden = null,
    /// The hits the session's log has, oldest first.
    hits: []const HitInfo = &.{},
};

/// What a check needs to know about a hit.
pub const HitInfo = struct {
    n: u64,
    seq: u64,
    alerts: []const []const u8,
};

/// Whether hit `h` meets the hit part of `c`; `input_seq` is the latest
/// input's.
pub fn hitCounts(c: *const Condition, h: HitInfo, input_seq: u64) bool {
    const want = c.hit orelse return false;
    if (!std.mem.eql(u8, want.name, "*")) {
        for (h.alerts) |name| {
            if (std.mem.eql(u8, name, want.name)) break;
        } else return false;
    }
    if (want.after_hit) |n| return h.n > n;
    const after = c.since orelse if (c.after_input) |a| a.inputSeq(input_seq) else input_seq;
    return h.seq > after;
}

/// When hidden input began: the session's seq, and monotonic nanoseconds.
pub const Hidden = struct {
    seq: u64,
    ns: i64,
};

/// One wait's part in a check.
pub const Window = struct {
    /// When the wait started, in monotonic nanoseconds.
    start: i64,
    /// History rows from this absolute row on are new to the wait.
    from: i64,
    /// The session's seq when the wait started.
    start_seq: u64 = 0,
};

/// What one condition of a wait found in earlier checks.
pub const Memory = struct {
    /// settled_ms: a text or style change came after the start point.
    changed: bool = false,
    /// absent: the text was on the screen.
    seen: bool = false,
};

/// Whether `needle` is on a line of the active screen of `t` now;
/// terminal_mutex must be held.
pub fn onScreen(gpa: std.mem.Allocator, t: *vt.Terminal, of: Needle) bool {
    var budget: usize = max_regex_scan;
    var needle = of;
    needle.budget = &budget;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    var it = track.LineIterator.active(t.screens.active);
    while (it.next()) |line| {
        text.clearRetainingCapacity();
        track.appendLineText(gpa, &text, line) catch return false;
        if (needle.countIn(text.items, false) > 0) return true;
    }
    return false;
}

/// Rows where a bundled wait saw its needle go away after the input: the
/// needle coming back there is new.
pub const Absent = struct {
    gpa: std.mem.Allocator,
    rows: std.AutoHashMapUnmanaged(i64, void) = .empty,

    pub fn deinit(a: *Absent) void {
        a.rows.deinit(a.gpa);
    }

    pub fn reset(a: *Absent) void {
        a.rows.clearRetainingCapacity();
    }

    fn add(a: *Absent, line: Line) void {
        for (0..line.rows) |r| {
            if (a.rows.count() >= max_absent_rows) return;
            a.rows.put(a.gpa, line.top + @as(i64, @intCast(r)), {}) catch return;
        }
    }

    fn any(a: *const Absent, line: Line) bool {
        for (0..line.rows) |r| if (a.rows.contains(line.top + @as(i64, @intCast(r)))) return true;
        return false;
    }
};

pub const Verdict = struct {
    met: bool = false,
    /// The input snapshot was truncated, so after_input fell back to the
    /// lines that changed after the input.
    truncated: bool = false,
    /// Lines without a known change were skipped: they may have changed
    /// after the condition's seq, or not.
    unknown: bool = false,
    /// The check looked at the history rows of the scan from the window's
    /// `from` on; a condition that some other part held off did not.
    scanned: bool = false,
};

/// Whether `c` holds. A condition with match or settled_ms needs `scan`;
/// one with settled_ms or absent needs `memory`; one with regex needs `re`,
/// compiled from its match.
pub fn check(c: *const Condition, re: ?*const regex.Regex, scan: ?*const Scan, facts: Facts, w: Window, absent: ?*Absent, memory: ?*Memory) Verdict {
    if (c.hit != null) {
        for (facts.hits) |h| {
            if (hitCounts(c, h, facts.input_seq)) break;
        } else return .{};
    }
    if (c.hidden_input and !hiddenSince(c, facts)) return .{};
    if (c.ended) {
        const end = facts.end_seq orelse return .{};
        const after = c.since orelse if (c.after_input) |a| a.inputSeq(facts.input_seq) else null;
        if (after) |seq| if (end <= seq) return .{};
    }
    if (c.idleDeadline(facts.last_text_change, w.start)) |at| if (facts.now < at) return .{};
    if (c.settled_ms != null) {
        var v = settled(c, scan.?, facts, w, memory.?);
        if (!v.met) {
            v.scanned = c.match == null;
            return v;
        }
    }
    if (c.changes()) return scanned(changedText(c, scan.?, w));
    if (c.match == null) return .{ .met = true };
    std.debug.assert(c.regex == (re != null));
    var budget: usize = max_regex_scan;
    var needle: Needle = .of(c, re);
    needle.budget = &budget;
    if (c.absent) return scanned(gone(needle, scan.?, w, memory.?));
    return scanned(findText(c, needle, scan.?, w, absent));
}

fn scanned(v: Verdict) Verdict {
    var out = v;
    out.scanned = true;
    return out;
}

/// Whether the screen changed after the condition's start point and has
/// settled since: its text unchanged for settled_ms, nothing pending.
fn settled(c: *const Condition, scan: *const Scan, facts: Facts, w: Window, memory: *Memory) Verdict {
    var v: Verdict = .{};
    if (!memory.changed) {
        const after = c.since orelse if (c.after_input) |a| a.inputSeq(scan.input_seq) else w.start_seq;
        // The input line is known only from the latest input's snapshot.
        const input_row = if (c.past_input_line and after == scan.input_seq) scan.snap_cursor_row else null;
        for (scan.lines.items, 0..) |line, i| {
            if (i < scan.history and line.top < w.from) continue;
            if (input_row) |row| if (holds(line.top, line.rows, row)) continue;
            if (if (c.past_input_line) line.text_seq > after else line.change_seq > after) {
                memory.changed = true;
                break;
            }
            if (line.unknown) v.unknown = true;
        }
        if (!memory.changed) return v;
    }
    if (scan.output_pending) return .{};
    if (facts.now < c.settledDeadline(facts.last_text_change, w.start).?) return .{};
    return .{ .met = true };
}

/// Whether the needle, on the screen at the wait's start or since, is
/// gone from it. Rows that scrolled into the history since the last
/// check showed it too.
fn gone(needle: Needle, scan: *const Scan, w: Window, memory: *Memory) Verdict {
    // Rows whose text did not fit may show it.
    if (scan.dropped > 0) return .{};
    for (scan.lines.items, 0..) |line, i| {
        if (needle.countIn(scan.lineText(line), false) == 0) continue;
        if (i >= scan.history) {
            memory.seen = true;
            return .{};
        }
        if (line.top >= w.from) memory.seen = true;
    }
    return .{ .met = memory.seen };
}

/// Whether input is hidden, and began after the condition's since or
/// input. The latest input is compared by time: hidden input that began
/// at a prompt before it is not new, though no seq lies in between.
fn hiddenSince(c: *const Condition, facts: Facts) bool {
    const hidden = facts.hidden orelse return false;
    if (c.since) |seq| return hidden.seq > seq;
    const after = c.after_input orelse return true;
    const input_seq = after.inputSeq(facts.input_seq);
    if (input_seq == facts.input_seq) return hidden.ns > facts.input_ns;
    return hidden.seq > input_seq;
}

/// Whether some line's text changed after the condition's since or input.
fn changedText(c: *const Condition, scan: *const Scan, w: Window) Verdict {
    const after = c.since orelse c.after_input.?.inputSeq(scan.input_seq);
    var v: Verdict = .{};
    for (scan.lines.items, 0..) |line, i| {
        if (i < scan.history and line.top < w.from) continue;
        if (line.text_seq > after) return .{ .met = true };
        if (line.unknown) v.unknown = true;
    }
    return v;
}

fn findText(c: *const Condition, needle: Needle, scan: *const Scan, w: Window, absent: ?*Absent) Verdict {
    const after_input = c.after_input != null;
    const input_seq = if (c.after_input) |a| a.inputSeq(scan.input_seq) else scan.input_seq;
    // Without a snapshot of this screen taken at the input, what changed
    // after the input is what is new.
    const fallback = after_input and (!scan.snap_valid or scan.snap_truncated or input_seq != scan.input_seq);
    const changed_after: ?u64 = c.since orelse if (fallback) input_seq else null;
    const truncated = fallback and scan.snap_truncated and input_seq == scan.input_seq;
    const compare = after_input and !fallback;
    // The echo is on the line that held the cursor at the input; without
    // that row, on any line that changed after it.
    const cursor_row = if (compare) scan.snap_cursor_row else null;
    var unknown = false;
    // Occurrences on lines a resize displaced that no line has taken yet:
    // a redraw may bring them back on any row.
    var displaced: ?usize = null;
    for (scan.lines.items, 0..) |line, i| {
        if (i < scan.history and line.top < w.from) continue;
        const echo = if (cursor_row) |row| holds(line.top, line.rows, row) else line.text_seq > input_seq;
        const n = needle.countIn(scan.lineText(line), echo);
        if (compare) if (absent) |a| {
            if (n == 0 and !line.dropped and line.text_seq > scan.input_seq and scan.snapshotCount(line, needle, cursor_row, echo) > 0) a.add(line);
        };
        if (n == 0) continue;
        const new = if (changed_after) |seq| blk: {
            if (line.text_seq <= seq and line.unknown) unknown = true;
            break :blk line.text_seq > seq;
        } else if (compare) blk: {
            if (line.blank_seq > scan.input_seq) break :blk true;
            if (absent) |a| if (a.any(line)) break :blk true;
            const shown = scan.snapshotCount(line, needle, cursor_row, echo);
            if (n <= shown) break :blk false;
            const left = displaced orelse scan.displacedCount(needle);
            const taken = @min(n - shown, left);
            displaced = left - taken;
            break :blk n - shown > taken;
        } else true;
        if (new) return .{ .met = true, .truncated = truncated };
    }
    return .{ .truncated = truncated, .unknown = unknown };
}

// ---- tests ------------------------------------------------------------

const Fixture = struct {
    term: vt.Terminal,
    stream: vt.TerminalStream,
    seqs: track.Counter = .{},
    tracker: track.Tracker,
    scan: Scan,
    memory: Memory = .{},

    fn create(cols: u16, rows: u16) !*Fixture {
        const gpa = std.testing.allocator;
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);
        f.* = .{ .term = undefined, .stream = undefined, .tracker = undefined, .scan = .{ .gpa = gpa } };
        f.term = try vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = 10_000 });
        errdefer f.term.deinit(gpa);
        var handler = f.term.vtHandler();
        handler.effects = .readonly;
        f.stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = gpa });
        const start = f.seqs.next();
        f.tracker = try .init(gpa, &f.seqs, &f.term, start, start, 0);
        return f;
    }

    fn destroy(f: *Fixture) void {
        const gpa = std.testing.allocator;
        f.scan.deinit();
        f.tracker.deinit(&f.term);
        f.stream.deinit();
        f.term.deinit(gpa);
        gpa.destroy(f);
    }

    fn feed(f: *Fixture, bytes: []const u8) void {
        f.stream.nextSlice(bytes);
        f.tracker.noteParsed(bytes.len, 0);
        f.tracker.settle(&f.term, 0);
    }

    fn input(f: *Fixture) u64 {
        _ = f.tracker.takeInput(&f.term, 0);
        return f.tracker.input_seq.raw;
    }

    fn verdict(f: *Fixture, c: Condition) !Verdict {
        return f.verdictIn(c, null, null);
    }

    /// The verdict for a wait whose history rows start at `from`.
    fn verdictIn(f: *Fixture, c: Condition, from: ?i64, absent: ?*Absent) !Verdict {
        try f.scan.collect(&f.tracker, &f.term, from);
        const facts: Facts = .{ .now = 0, .last_text_change = 0, .end_seq = null, .input_seq = f.scan.input_seq };
        return check(&c, null, &f.scan, facts, .{ .start = 0, .from = from orelse 0 }, absent, &f.memory);
    }

    fn holds(f: *Fixture, c: Condition) !bool {
        return (try f.verdict(c)).met;
    }

    fn resize(f: *Fixture, cols: u16, rows: u16) !void {
        var reflow = f.tracker.beginReflow(&f.term, 0);
        defer reflow.deinit(std.testing.allocator);
        try f.term.resize(std.testing.allocator, .{ .cols = cols, .rows = rows });
        _ = f.tracker.endReflow(&f.term, &reflow, 0, true);
    }
};

test "conditions are decoded strictly and checked for what they can wait for" {
    const protocol = @import("protocol.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const parse = struct {
        fn one(a: std.mem.Allocator, json: []const u8) ![]const Condition {
            const value = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
            var p: protocol.Problem = .{};
            return protocol.decode([]const Condition, a, value, &p);
        }
    }.one;
    const until = try parse(gpa, "[{\"match\":\"$ \",\"after_input\":\"latest\"},{\"ended\":true,\"since\":7},{\"idle_ms\":500,\"after_input\":12}]");
    try std.testing.expectEqual(AfterInput.latest, until[0].after_input.?);
    try std.testing.expectEqual(@as(u64, 12), until[2].after_input.?.seq);
    try std.testing.expectEqual(@as(?[]const u8, null), try problem(gpa, until));
    // A condition that does not use the newer fields leaves them out, so
    // an older daemon takes it.
    const json = try std.json.Stringify.valueAlloc(gpa, Condition{ .match = "x" }, .{ .emit_null_optional_fields = false });
    try std.testing.expectEqualStrings("{\"match\":\"x\",\"icase\":false,\"absent\":false,\"ended\":false,\"hidden_input\":false}", json);
    try std.testing.expectError(error.BadRequest, parse(gpa, "[{\"after_input\":\"first\"}]"));
    try std.testing.expectError(error.BadRequest, parse(gpa, "[{\"matc\":\"x\"}]"));

    const bad = [_]struct { json: []const u8, text: []const u8 }{
        .{ .json = "[]", .text = "until needs at least one condition" },
        .{ .json = "[{\"icase\":true}]", .text = "until[0] waits for nothing" },
        .{ .json = "[{\"match\":\"a\\nb\"}]", .text = "until[0].match must not contain a line break" },
        .{ .json = "[{\"ended\":true},{\"match\":\"\"}]", .text = "until[1].match must not be empty" },
        .{ .json = "[{\"idle_ms\":5,\"since\":3,\"after_input\":\"latest\"}]", .text = "until[0] takes since or after_input" },
    };
    for (bad) |case| {
        const why = (try problem(gpa, try parse(gpa, case.json))) orelse return error.TestExpectedProblem;
        try std.testing.expect(std.mem.startsWith(u8, why, case.text));
    }
    const long = try gpa.alloc(u8, max_match_len + 1);
    @memset(long, 'x');
    try std.testing.expect((try problem(gpa, &.{.{ .match = long }})) != null);
    try std.testing.expect((try problem(gpa, &.{.{ .hit = .{ .name = "no good" } }})) != null);
}

test "a match is on screen now, across soft wraps, and with icase in any case" {
    const f = try Fixture.create(10, 4);
    defer f.destroy();
    f.feed("012345678\xe4\xb8\x80ab\tTAB");
    try std.testing.expect(try f.holds(.{ .match = "8" }));
    // The wide character wrapped to the next row and joins the line.
    try std.testing.expect(try f.holds(.{ .match = "8\xe4\xb8\x80ab" }));
    try std.testing.expect(try f.holds(.{ .match = "ab    TAB" }));
    try std.testing.expect(!try f.holds(.{ .match = "tab" }));
    try std.testing.expect(try f.holds(.{ .match = "tab", .icase = true }));
    try std.testing.expect(!try f.holds(.{ .match = "absent" }));
}

test "with since a match counts only on lines changed after the seq" {
    const f = try Fixture.create(20, 4);
    defer f.destroy();
    f.feed("old line\r\n");
    const seq = f.tracker.seq.raw;
    try std.testing.expect(!try f.holds(.{ .match = "line", .since = seq }));
    f.feed("new line");
    try std.testing.expect(try f.holds(.{ .match = "line", .since = seq }));
    try std.testing.expect(!try f.holds(.{ .match = "old", .since = seq }));
}

test "since or after_input alone holds once the text of a line changed" {
    const f = try Fixture.create(20, 4);
    defer f.destroy();
    f.feed("$ ");
    const seq = f.tracker.seq.raw;
    _ = f.input();
    try std.testing.expect(!try f.holds(.{ .since = seq }));
    try std.testing.expect(!try f.holds(.{ .after_input = .latest }));
    // A cursor move alone is no text change.
    f.feed("\x1b[2;1H");
    try std.testing.expect(!try f.holds(.{ .since = seq }));
    f.feed("x");
    try std.testing.expect(try f.holds(.{ .since = seq }));
    try std.testing.expect(try f.holds(.{ .after_input = .latest }));
    try std.testing.expectEqualStrings("changed", (Condition{ .since = seq }).kind());
}

test "after an input only a new occurrence counts" {
    const f = try Fixture.create(30, 6);
    defer f.destroy();
    f.feed("$ ");
    _ = f.input();
    const latest: Condition = .{ .match = "$ ", .after_input = .latest };
    // The echo of the typed text is on the row that showed the prompt.
    f.feed("echo hi");
    try std.testing.expect(!try f.holds(latest));
    // A needle in the typed text itself is one more occurrence there.
    f.feed(" $ x");
    try std.testing.expect(try f.holds(latest));
    _ = f.input();
    f.feed("\r\nhi\r\n");
    try std.testing.expect(!try f.holds(latest));
    f.feed("$ ");
    try std.testing.expect(try f.holds(latest));

    // A row that went blank after the input shows the needle anew.
    _ = f.input();
    f.feed("\x1b[2J");
    try std.testing.expect(!try f.holds(latest));
    f.feed("\x1b[1;1H$ ");
    try std.testing.expect(try f.holds(latest));

    // An input that is no longer the latest one: what changed after it is
    // new, though the latest input's snapshot shows it.
    const earlier = f.input();
    f.feed("\r\nDONE");
    _ = f.input();
    try std.testing.expect(try f.holds(.{ .match = "DONE", .after_input = .{ .seq = earlier } }));
    try std.testing.expect(!try f.holds(.{ .match = "DONE", .after_input = .latest }));
}

test "the echo of the typed text does not count, also for a regex, nor as the change past the input line" {
    const f = try Fixture.create(40, 6);
    defer f.destroy();
    f.feed("$ ");
    _ = f.input();
    const typed = "cd /opt/x && pwd";
    const part: Condition = .{ .match = "/opt/x", .after_input = .latest, .typed = typed };
    const whole: Condition = .{ .match = "pwd", .after_input = .latest, .typed = "pwd" };
    f.feed(typed);
    try std.testing.expect(!try f.holds(part));
    // A part of the typed text: its copies count nowhere, other text does.
    f.feed("\r\n" ++ typed ++ "\r\n");
    try std.testing.expect(!try f.holds(part));
    f.feed("/opt/x\r\n$ ");
    try std.testing.expect(try f.holds(part));
    // The whole typed text counts off the input's line.
    _ = f.input();
    f.feed("pwd");
    try std.testing.expect(!try f.holds(whole));
    f.feed("\r\npwd");
    try std.testing.expect(try f.holds(whole));

    var why: []const u8 = "";
    var re = try regex.compile(std.testing.allocator, "^/opt/\\w+$", .{}, &why);
    defer re.deinit(std.testing.allocator);
    _ = f.input();
    f.feed("\r\n$ cd /opt/y");
    const rc: Condition = .{ .match = "^/opt/\\w+$", .regex = true, .after_input = .latest, .typed = "cd /opt/y" };
    try f.scan.collect(&f.tracker, &f.term, null);
    const facts: Facts = .{ .now = 0, .last_text_change = 0, .end_seq = null, .input_seq = f.scan.input_seq };
    try std.testing.expect(!check(&rc, &re, &f.scan, facts, .{ .start = 0, .from = 0 }, null, &f.memory).met);
    f.feed("\r\n/opt/y");
    try f.scan.collect(&f.tracker, &f.term, null);
    try std.testing.expect(check(&rc, &re, &f.scan, facts, .{ .start = 0, .from = 0 }, null, &f.memory).met);

    // Settled: the echo on the input's line is no change; the next line is.
    f.feed("\r\n$ ");
    _ = f.input();
    const settle: Condition = .{ .settled_ms = 1, .after_input = .latest, .past_input_line = true };
    f.feed("sleep 9");
    f.memory = .{};
    try f.scan.collect(&f.tracker, &f.term, null);
    const later: Facts = .{ .now = std.time.ns_per_s, .last_text_change = 0, .end_seq = null, .input_seq = f.scan.input_seq };
    try std.testing.expect(!check(&settle, null, &f.scan, later, .{ .start = 0, .from = 0 }, null, &f.memory).met);
    f.feed("\r\nout");
    try f.scan.collect(&f.tracker, &f.term, null);
    try std.testing.expect(check(&settle, null, &f.scan, later, .{ .start = 0, .from = 0 }, null, &f.memory).met);
}

test "after an input, a redraw that brings back what a shrinking resize cut off is not new" {
    const f = try Fixture.create(20, 10);
    defer f.destroy();
    // A full-screen program with its cursor on the bottom line.
    f.feed("\x1b[?1049h\x1b[Hline one\r\nNEEDLE here\r\nline three");
    var buf: [16]u8 = undefined;
    for (4..10) |y| f.feed(try std.fmt.bufPrint(&buf, "\x1b[{d};1H~", .{y}));
    f.feed("\x1b[10;1Hstatus");
    _ = f.input();
    const latest: Condition = .{ .match = "NEEDLE", .after_input = .latest };
    // The shorter screen loses its top rows; the program draws them again.
    try f.resize(20, 5);
    try std.testing.expect(f.tracker.snapshot.displaced.items.len > 0);
    f.feed("\x1b[H\x1b[2Jline one\r\nNEEDLE here\r\nline three\r\n~\r\nstatus");
    try std.testing.expect(!try f.holds(latest));
    // One more than the input saw is new.
    f.feed("\x1b[4;1HNEEDLE again");
    try std.testing.expect(try f.holds(latest));
}

test "a bundled wait counts a needle that went away and came back on its row" {
    const f = try Fixture.create(20, 4);
    defer f.destroy();
    var absent: Absent = .{ .gpa = std.testing.allocator };
    defer absent.deinit();
    f.feed("$ ");
    _ = f.input();
    const latest: Condition = .{ .match = "$ ", .after_input = .latest };
    f.feed("\rbusy");
    try std.testing.expect(!(try f.verdictIn(latest, null, &absent)).met);
    f.feed("\r$ ");
    try std.testing.expect(!try f.holds(latest));
    try std.testing.expect((try f.verdictIn(latest, null, &absent)).met);
}

test "a bundled wait takes no line whose text did not fit as one its needle left" {
    const gpa = std.testing.allocator;
    var scan: Scan = .{ .gpa = gpa, .input_seq = 1, .snap_valid = true };
    defer scan.deinit();
    try scan.snap_text.appendSlice(gpa, "$ ");
    try scan.snap_lines.append(gpa, .{ .top = 0, .rows = 1, .start = 0, .len = 2 });
    try scan.lines.append(gpa, .{ .top = 0, .rows = 1, .start = 0, .len = 0, .text_seq = 2, .blank_seq = 0, .dropped = true });
    var absent: Absent = .{ .gpa = gpa };
    defer absent.deinit();
    var memory: Memory = .{};
    const facts: Facts = .{ .now = 0, .last_text_change = 0, .end_seq = null, .input_seq = 1 };
    _ = check(&.{ .match = "$ ", .after_input = .latest }, null, &scan, facts, .{ .start = 0, .from = 0 }, &absent, &memory);
    try std.testing.expectEqual(0, absent.rows.count());
}

test "a regex looks at a long line up to the start of a character" {
    var line: [max_regex_line + 2]u8 = @splat('a');
    line[max_regex_line - 2 ..][0..2].* = "ä".*;
    try std.testing.expectEqual(max_regex_line, regexText(&line).len);
    @memset(&line, 'a');
    line[max_regex_line - 1 ..][0..2].* = "é".*;
    try std.testing.expectEqual(max_regex_line - 1, regexText(&line).len);
}

test "a match counts on rows that scrolled into the history since the wait started" {
    const f = try Fixture.create(10, 3);
    defer f.destroy();
    f.feed("start\r\n");
    const from = f.tracker.top(.primary);
    // The wrapped line's first row scrolls into the history, its second
    // stays at the top of the screen.
    f.feed("aaaaaaNEEDLE\r\n1\r\n2");
    try std.testing.expectEqual(from + 2, f.tracker.top(.primary));
    try std.testing.expect((try f.verdictIn(.{ .match = "start" }, from, null)).met);
    try std.testing.expect((try f.verdictIn(.{ .match = "aNEEDLE" }, from, null)).met);
    try std.testing.expect(!(try f.verdictIn(.{ .match = "start" }, from + 2, null)).met);
}

test "idle counts from the wait's start with after_input, and ended needs an end after since" {
    const ms = std.time.ns_per_ms;
    const w: Window = .{ .start = 100 * ms, .from = 0 };
    const quiet: Facts = .{ .now = 150 * ms, .last_text_change = 0, .end_seq = null, .input_seq = 0 };
    try std.testing.expect(check(&.{ .idle_ms = 100 }, null, null, quiet, w, null, null).met);
    try std.testing.expect(!check(&.{ .idle_ms = 100, .after_input = .latest }, null, null, quiet, w, null, null).met);
    var later = quiet;
    later.now = 200 * ms;
    try std.testing.expect(check(&.{ .idle_ms = 100, .after_input = .latest }, null, null, later, w, null, null).met);
    const ended: Facts = .{ .now = 0, .last_text_change = 0, .end_seq = 7, .input_seq = 0 };
    try std.testing.expect(!check(&.{ .ended = true, .since = 7 }, null, null, ended, w, null, null).met);
    try std.testing.expect(check(&.{ .ended = true, .since = 6 }, null, null, ended, w, null, null).met);
}

test "hidden input holds while the terminal hides it, and after an input only once it began anew" {
    const w: Window = .{ .start = 0, .from = 0 };
    var facts: Facts = .{ .now = 0, .last_text_change = 0, .end_seq = null, .input_seq = 10, .input_ns = 500 };
    const hidden: Condition = .{ .hidden_input = true };
    const after: Condition = .{ .hidden_input = true, .after_input = .latest };
    try std.testing.expect(!check(&hidden, null, null, facts, w, null, null).met);
    // A prompt that hid input before the latest input.
    facts.hidden = .{ .seq = 10, .ns = 400 };
    try std.testing.expect(check(&hidden, null, null, facts, w, null, null).met);
    try std.testing.expect(!check(&after, null, null, facts, w, null, null).met);
    try std.testing.expect(!check(&.{ .hidden_input = true, .since = 10 }, null, null, facts, w, null, null).met);
    // The next prompt, after the input.
    facts.hidden = .{ .seq = 10, .ns = 600 };
    try std.testing.expect(check(&after, null, null, facts, w, null, null).met);
    // An input before the latest one, and a since, are compared by seq.
    const earlier: Condition = .{ .hidden_input = true, .after_input = .{ .seq = 7 } };
    facts.hidden = .{ .seq = 7, .ns = 600 };
    try std.testing.expect(!check(&earlier, null, null, facts, w, null, null).met);
    facts.hidden = .{ .seq = 11, .ns = 600 };
    try std.testing.expect(check(&earlier, null, null, facts, w, null, null).met);
    try std.testing.expect(check(&.{ .hidden_input = true, .since = 10 }, null, null, facts, w, null, null).met);
    try std.testing.expectEqualStrings("hidden_input", after.kind());
}

test "a hit counts after the latest input, or after after_hit" {
    const asked: HitInfo = .{ .n = 4, .seq = 10, .alerts = &.{ "ask", "warn" } };
    const any: Condition = .{ .hit = .{ .name = "*" } };
    try std.testing.expect(hitCounts(&any, asked, 9));
    // Answered: the input came after the hit.
    try std.testing.expect(!hitCounts(&any, asked, 10));
    try std.testing.expect(hitCounts(&.{ .hit = .{ .name = "warn", .after_hit = 3 } }, asked, 12));
    try std.testing.expect(!hitCounts(&.{ .hit = .{ .name = "ask", .after_hit = 4 } }, asked, 0));
    try std.testing.expect(!hitCounts(&.{ .hit = .{ .name = "other" } }, asked, 0));
}

test "settled holds once the screen changed after the start and its text stayed quiet, with nothing pending" {
    const ms = std.time.ns_per_ms;
    const f = try Fixture.create(20, 4);
    defer f.destroy();
    f.feed("$ ");
    const start = f.tracker.seq.raw;
    const c: Condition = .{ .settled_ms = 100 };
    const at = struct {
        fn check_(fx: *Fixture, cond_: Condition, now: i64, start_seq: u64) !bool {
            try fx.scan.collect(&fx.tracker, &fx.term, null);
            const facts: Facts = .{ .now = now, .last_text_change = 0, .end_seq = null, .input_seq = fx.scan.input_seq };
            return check(&cond_, null, &fx.scan, facts, .{ .start = 0, .from = 0, .start_seq = start_seq }, null, &fx.memory).met;
        }
    }.check_;
    // Quiet, but nothing changed after the start.
    try std.testing.expect(!try at(f, c, 500 * ms, start));
    // A change of style alone starts it; the text has been quiet since 0.
    f.feed("\r\x1b[7m$ \x1b[m");
    try std.testing.expect(!try at(f, c, 50 * ms, start));
    try std.testing.expect(try at(f, c, 150 * ms, start));
    // Output still waiting on the pty holds it back.
    f.scan.output_pending = true;
    try std.testing.expect(!check(&c, null, &f.scan, .{ .now = 150 * ms, .last_text_change = 0, .end_seq = null, .input_seq = 0 }, .{ .start = 0, .from = 0, .start_seq = start }, null, &f.memory).met);
    try std.testing.expectEqualStrings("settled", c.kind());
}

test "absent holds once text on the screen at the start, or that came, is gone, never for text that never came" {
    const gpa = std.testing.allocator;
    const f = try Fixture.create(20, 4);
    defer f.destroy();
    f.feed("Loading...");
    const loading: Condition = .{ .match = "loading", .icase = true, .absent = true };
    f.memory.seen = onScreen(gpa, &f.term, .{ .text = "loading", .icase = true });
    try std.testing.expect(!try f.holds(loading));
    f.feed("\r\x1b[2KDone");
    try std.testing.expect(try f.holds(loading));
    f.memory = .{};
    try std.testing.expect(!try f.holds(.{ .match = "Never", .absent = true }));
    // Text that came after the start and scrolled into the history
    // between two checks is gone.
    const from = f.tracker.top(.primary);
    f.feed("\r\nBUSY\r\n1\r\n2\r\n3\r\n4");
    try std.testing.expect((try f.verdictIn(.{ .match = "BUSY", .absent = true }, from, null)).met);
    try std.testing.expectEqualStrings("gone", loading.kind());
}

test "count finds overlapping occurrences in linear time, with icase in any case" {
    try std.testing.expectEqual(@as(usize, 3), count("aaaa", "aa", false));
    try std.testing.expectEqual(@as(usize, 2), count("abABab", "AbA", true));
    try std.testing.expectEqual(@as(usize, 0), count("abABab", "AbA", false));
    try std.testing.expectEqual(@as(usize, 2), count("x$ y$ ", "$ ", false));
    try std.testing.expectEqual(@as(usize, 1), count("aabaabaaab", "aaab", false));
    try std.testing.expectEqual(@as(usize, 0), count("ab", "abc", false));
    // A needle that almost matches at every byte of a long text.
    const gpa = std.testing.allocator;
    const text = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(text);
    @memset(text, 'a');
    var needle: [max_match_len]u8 = undefined;
    @memset(&needle, 'a');
    needle[needle.len - 1] = 'b';
    try std.testing.expectEqual(@as(usize, 0), count(text, &needle, true));
    text[text.len - 1] = 'B';
    try std.testing.expectEqual(@as(usize, 1), count(text, &needle, true));
}

test "a truncated input snapshot falls back to the lines changed after the input" {
    const gpa = std.testing.allocator;
    const f = try Fixture.create(1000, 300);
    defer f.destroy();
    const row = try gpa.alloc(u8, 1000);
    defer gpa.free(row);
    @memset(row, 'x');
    for (0..299) |_| {
        f.feed(row);
    }
    f.feed("$ ");
    _ = f.input();
    try std.testing.expect(f.tracker.snapshot.truncated);
    const latest: Condition = .{ .match = "x", .after_input = .latest };
    try std.testing.expectEqual(Verdict{ .truncated = true, .scanned = true }, try f.verdict(latest));
    f.feed("x");
    try std.testing.expectEqual(Verdict{ .met = true, .truncated = true, .scanned = true }, try f.verdict(latest));
}
