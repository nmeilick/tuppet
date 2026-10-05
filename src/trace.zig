//! The trace artifact: a JSONL timeline of typed events (start, snap,
//! in, diff, mark, stop) written next to the asciicast v2 format. This
//! file holds the pure pieces - row extraction from rendered text, the
//! row-diff computation, and event serialization - so they can be unit
//! tested without a session.
//!
//! Row model: the ghostty plain formatter trims trailing blank rows, so
//! a rendered screen splits into `rows` lines where missing trailing
//! lines are blank. Row indices are stable across renders, which is
//! what makes index-wise diffing sound.

const std = @import("std");

/// One changed row: the new content of grid row `r` (already trimmed of
/// trailing whitespace by the formatter).
pub const RowChange = struct {
    r: u16,
    text: []const u8,
};

pub const Diff = union(enum) {
    /// No visible change; emit nothing.
    none,
    /// A few rows changed; emit a diff event.
    rows: []RowChange,
    /// Too much changed (or the row count did); emit a full snapshot.
    snap,
};

/// Split rendered plain text into rows. The result aliases `text`.
/// A trailing newline produces no extra empty row; interior blank rows
/// are empty slices.
pub fn splitRows(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try list.append(gpa, line);
    // A trailing '\n' yields a final empty row that is not a grid row.
    // Pop before toOwnedSlice so the allocation size matches the result.
    if (text.len > 0 and text[text.len - 1] == '\n' and list.items.len > 0) {
        _ = list.pop();
    }
    return list.toOwnedSlice(gpa);
}

/// Compare two renders row-wise (missing trailing rows count as blank).
/// `snap_threshold` is the fraction of changed rows (0..1) above which a
/// full snapshot is cheaper than a diff.
pub fn diffRows(
    gpa: std.mem.Allocator,
    prev: []const []const u8,
    cur: []const []const u8,
    grid_rows: u16,
    snap_threshold: f64,
) !Diff {
    const n = @max(prev.len, cur.len);
    var changes: std.ArrayList(RowChange) = .empty;
    defer changes.deinit(gpa);
    for (0..n) |i| {
        const old: []const u8 = if (i < prev.len) prev[i] else "";
        const new: []const u8 = if (i < cur.len) cur[i] else "";
        if (std.mem.eql(u8, old, new)) continue;
        // A shrink (resize) can leave prev rows beyond the grid; the
        // resize's own `in` event documents the change, so drop them.
        if (i >= grid_rows) continue;
        try changes.append(gpa, .{ .r = @intCast(i), .text = new });
    }
    if (changes.items.len == 0) return .none;
    const fraction = @as(f64, @floatFromInt(changes.items.len)) /
        @as(f64, @floatFromInt(@max(grid_rows, 1)));
    if (fraction > snap_threshold) return .snap;
    return .{ .rows = try changes.toOwnedSlice(gpa) };
}

/// Seconds-since-start timestamp, six decimals, matching the asciicast
/// event convention.
pub fn elapsedSecs(start: i64, now: i64) f64 {
    return @as(f64, @floatFromInt(now - start)) / std.time.ns_per_s;
}

/// Write `s` as a JSON string. Child output and raw input need not be
/// valid UTF-8; every byte that is not part of a valid sequence becomes
/// U+FFFD, so events always carry strings that JSON and asciicast
/// readers accept.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            switch (b) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => if (b < 0x20) try w.print("\\u{x:0>4}", .{b}) else try w.writeByte(b),
            }
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch 0;
        if (len > 0 and i + len <= s.len) {
            if (std.unicode.utf8Decode(s[i..][0..len])) |_| {
                try w.writeAll(s[i..][0..len]);
                i += len;
                continue;
            } else |_| {}
        }
        try w.writeAll("\\ufffd");
        i += 1;
    }
    try w.writeByte('"');
}

/// An incomplete UTF-8 sequence held back from the end of one output
/// chunk until the next chunk completes it.
pub const Utf8Carry = struct {
    buf: [3]u8 = undefined,
    len: u8 = 0,
};

/// Length of an incomplete (but so far valid-looking) UTF-8 sequence at
/// the end of `bytes`, 0 if there is none.
fn incompleteUtf8Tail(bytes: []const u8) usize {
    var back: usize = 1;
    while (back <= 3 and back <= bytes.len) : (back += 1) {
        const b = bytes[bytes.len - back];
        if (b & 0xC0 == 0x80) continue;
        const len = std.unicode.utf8ByteSequenceLength(b) catch return 0;
        return if (len > back) back else 0;
    }
    return 0;
}

/// {"t":0.000000,"ev":"start","cols":80,"rows":24,"name":"..."}
pub fn formatStart(gpa: std.mem.Allocator, cols: u16, rows: u16, name: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.print("{{\"t\":0.000000,\"ev\":\"start\",\"cols\":{d},\"rows\":{d},\"name\":", .{ cols, rows });
    try writeJsonString(w, name);
    try w.writeAll("}\n");
    return aw.toOwnedSlice();
}

/// {"t":...,"ev":"snap","screen":["row0",...]}
pub fn formatSnap(gpa: std.mem.Allocator, t: f64, rows: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.print("{{\"t\":{d:.6},\"ev\":\"snap\",\"screen\":[", .{t});
    for (rows, 0..) |row, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, row);
    }
    try w.writeAll("]}\n");
    return aw.toOwnedSlice();
}

/// {"t":...,"ev":"diff","rows":[{"r":2,"text":"..."},...]}
pub fn formatDiff(gpa: std.mem.Allocator, t: f64, changes: []const RowChange) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.print("{{\"t\":{d:.6},\"ev\":\"diff\",\"rows\":[", .{t});
    for (changes, 0..) |change, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"r\":{d},\"text\":", .{change.r});
        try writeJsonString(w, change.text);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
    return aw.toOwnedSlice();
}

/// {"t":...,"ev":"mark","label":"..."}
pub fn formatMark(gpa: std.mem.Allocator, t: f64, label: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.print("{{\"t\":{d:.6},\"ev\":\"mark\",\"label\":", .{t});
    try writeJsonString(w, label);
    try w.writeAll("}\n");
    return aw.toOwnedSlice();
}

/// {"t":...,"ev":"stop","reason":"match"[,"match":"..."][,"exit_code":N]}
pub fn formatStop(gpa: std.mem.Allocator, t: f64, reason: []const u8, match: ?[]const u8, exit_code: ?i32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.print("{{\"t\":{d:.6},\"ev\":\"stop\",\"reason\":\"{s}\"", .{ t, reason });
    if (match) |needle| {
        try w.writeAll(",\"match\":");
        try writeJsonString(w, needle);
    }
    if (exit_code) |code| try w.print(",\"exit_code\":{d}", .{code});
    try w.writeAll("}\n");
    return aw.toOwnedSlice();
}

/// Input events: what was sent to the session, in both artifact flavors.
pub const Input = union(enum) {
    send: []const u8,
    key: struct { keys: []const []const u8, encoded: []const u8 },
    mouse: struct { button: []const u8, action: []const u8, mods: []const u8, x: u16, y: u16 },
    focus: bool,
    resize: struct { cols: u16, rows: u16 },
};

/// Trace format: {"t":...,"ev":"in","kind":"key",...}
pub fn formatIn(gpa: std.mem.Allocator, t: f64, input: Input) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.print("{{\"t\":{d:.6},\"ev\":\"in\",", .{t});
    switch (input) {
        .send => |data| {
            try w.writeAll("\"kind\":\"send\",\"text\":");
            try writeJsonString(w, data);
        },
        .key => |k| {
            try w.writeAll("\"kind\":\"key\",\"keys\":[");
            for (k.keys, 0..) |tok, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonString(w, tok);
            }
            try w.writeByte(']');
        },
        .mouse => |m| {
            try w.print("\"kind\":\"mouse\",\"button\":", .{});
            try writeJsonString(w, m.button);
            try w.writeAll(",\"action\":");
            try writeJsonString(w, m.action);
            try w.writeAll(",\"mods\":");
            try writeJsonString(w, m.mods);
            try w.print(",\"x\":{d},\"y\":{d}", .{ m.x, m.y });
        },
        .focus => |focused| {
            try w.print("\"kind\":\"focus\",\"focused\":{}", .{focused});
        },
        .resize => |r| {
            try w.print("\"kind\":\"resize\",\"cols\":{d},\"rows\":{d}", .{ r.cols, r.rows });
        },
    }
    try w.writeAll("}\n");
    return aw.toOwnedSlice();
}

/// Cast format output event: [t,"o","<text>"]. A multi-byte character
/// split across reads is held in `carry` and emitted whole with the next
/// chunk; `final` flushes the carry instead. Null when nothing is left
/// to emit.
pub fn formatCastOutput(gpa: std.mem.Allocator, t: f64, data: []const u8, carry: *Utf8Carry, final: bool) !?[]u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    try joined.appendSlice(gpa, carry.buf[0..carry.len]);
    try joined.appendSlice(gpa, data);
    carry.len = 0;
    const tail = if (final) 0 else incompleteUtf8Tail(joined.items);
    const text = joined.items[0 .. joined.items.len - tail];
    @memcpy(carry.buf[0..tail], joined.items[text.len..]);
    carry.len = @intCast(tail);
    if (text.len == 0) return null;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("[{d:.6},\"o\",", .{t});
    try writeJsonString(w, text);
    try w.writeAll("]\n");
    return try aw.toOwnedSlice();
}

/// Cast format marker: [t,"m","label"].
pub fn formatCastMark(gpa: std.mem.Allocator, t: f64, label: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.print("[{d:.6},\"m\",", .{t});
    try writeJsonString(w, label);
    try w.writeAll("]\n");
    return aw.toOwnedSlice();
}

/// Cast format: key/send become asciicast "i" events carrying the bytes
/// written to the pty, resizes become "r" events, and mouse/focus
/// become "m" markers.
pub fn formatCastInput(gpa: std.mem.Allocator, t: f64, input: Input) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    switch (input) {
        .send => |data| {
            try w.print("[{d:.6},\"i\",", .{t});
            try writeJsonString(w, data);
            try w.writeAll("]\n");
        },
        .key => |k| {
            try w.print("[{d:.6},\"i\",", .{t});
            try writeJsonString(w, k.encoded);
            try w.writeAll("]\n");
        },
        .mouse => |m| {
            try w.print("[{d:.6},\"m\",", .{t});
            const label = try std.fmt.allocPrint(gpa, "mouse {s} {s} {d},{d} mods={s}", .{ m.button, m.action, m.x, m.y, m.mods });
            defer gpa.free(label);
            try writeJsonString(w, label);
            try w.writeAll("]\n");
        },
        .focus => |focused| {
            try w.print("[{d:.6},\"m\",", .{t});
            try writeJsonString(w, if (focused) "focus on" else "focus off");
            try w.writeAll("]\n");
        },
        // asciicast v2 resize event.
        .resize => |r| try w.print("[{d:.6},\"r\",\"{d}x{d}\"]\n", .{ t, r.cols, r.rows }),
    }
    return aw.toOwnedSlice();
}

const testing = std.testing;

test "splitRows keeps interior blanks and drops the trailing-newline phantom" {
    const rows = try splitRows(testing.allocator, "a\n\nb\n");
    defer testing.allocator.free(rows);
    try testing.expectEqualDeep(&[_][]const u8{ "a", "", "b" }, rows);

    const no_trail = try splitRows(testing.allocator, "a\nb");
    defer testing.allocator.free(no_trail);
    try testing.expectEqualDeep(&[_][]const u8{ "a", "b" }, no_trail);

    const empty = try splitRows(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 1), empty.len);
    try testing.expectEqualStrings("", empty[0]);
}

test "diffRows reports only changed rows, treating trimmed tails as blank" {
    const prev = [_][]const u8{ "one", "two", "three" };
    const cur = [_][]const u8{ "one", "TWO" };
    const diff = try diffRows(testing.allocator, &prev, &cur, 24, 0.6);
    switch (diff) {
        .rows => |rows| {
            defer testing.allocator.free(rows);
            try testing.expectEqual(@as(usize, 2), rows.len);
            try testing.expectEqual(@as(u16, 1), rows[0].r);
            try testing.expectEqualStrings("TWO", rows[0].text);
            try testing.expectEqual(@as(u16, 2), rows[1].r);
            try testing.expectEqualStrings("", rows[1].text);
        },
        else => return error.TestUnexpectedResult,
    }

    const same = try diffRows(testing.allocator, &prev, &prev, 24, 0.6);
    try testing.expect(same == .none);
}

test "diffRows falls back to snap past the threshold" {
    const prev = [_][]const u8{ "a", "b", "c", "d" };
    const cur = [_][]const u8{ "A", "B", "C", "d" };
    // 3 of 4 rows changed on a 4-row grid: 0.75 > 0.6 -> snap.
    const diff = try diffRows(testing.allocator, &prev, &cur, 4, 0.6);
    defer if (diff == .rows) testing.allocator.free(diff.rows);
    try testing.expect(diff == .snap);
}

test "event formatters emit valid JSON lines" {
    const start = try formatStart(testing.allocator, 80, 24, "demo");
    defer testing.allocator.free(start);
    try testing.expectEqualStrings("{\"t\":0.000000,\"ev\":\"start\",\"cols\":80,\"rows\":24,\"name\":\"demo\"}\n", start);

    const rows = [_][]const u8{ "$ vim", "quote: \"" };
    const snap = try formatSnap(testing.allocator, 0.5, &rows);
    defer testing.allocator.free(snap);
    try testing.expectEqualStrings("{\"t\":0.500000,\"ev\":\"snap\",\"screen\":[\"$ vim\",\"quote: \\\"\"]}\n", snap);

    const changes = [_]RowChange{.{ .r = 23, .text = ":q!" }};
    const diff_line = try formatDiff(testing.allocator, 1.25, &changes);
    defer testing.allocator.free(diff_line);
    try testing.expectEqualStrings("{\"t\":1.250000,\"ev\":\"diff\",\"rows\":[{\"r\":23,\"text\":\":q!\"}]}\n", diff_line);

    const stop = try formatStop(testing.allocator, 2.0, "match", "written", null);
    defer testing.allocator.free(stop);
    try testing.expectEqualStrings("{\"t\":2.000000,\"ev\":\"stop\",\"reason\":\"match\",\"match\":\"written\"}\n", stop);

    const in_line = try formatIn(testing.allocator, 0.1, .{ .key = .{ .keys = &.{ "<Esc>", "q" }, .encoded = "\x1bq" } });
    defer testing.allocator.free(in_line);
    try testing.expectEqualStrings("{\"t\":0.100000,\"ev\":\"in\",\"kind\":\"key\",\"keys\":[\"<Esc>\",\"q\"]}\n", in_line);

    const cast_line = try formatCastInput(testing.allocator, 0.1, .{ .key = .{ .keys = &.{"<Esc>"}, .encoded = "\x1b" } });
    defer testing.allocator.free(cast_line);
    try testing.expectEqualStrings("[0.100000,\"i\",\"\\u001b\"]\n", cast_line);
}

test "cast output stays a JSON string for invalid and split UTF-8" {
    var carry: Utf8Carry = .{};
    // Invalid byte, then "€" (e2 82 ac) split across two reads.
    const first = (try formatCastOutput(testing.allocator, 0.5, "bad:\xff split:\xe2\x82", &carry, false)).?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("[0.500000,\"o\",\"bad:\\ufffd split:\"]\n", first);
    try testing.expectEqual(@as(u8, 2), carry.len);
    const second = (try formatCastOutput(testing.allocator, 0.6, "\xac!", &carry, false)).?;
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("[0.600000,\"o\",\"\xe2\x82\xac!\"]\n", second);

    // A chunk that is only the start of a character emits nothing yet;
    // a final flush turns the leftover into U+FFFD.
    try testing.expect((try formatCastOutput(testing.allocator, 0.7, "\xf0\x9f", &carry, false)) == null);
    const last = (try formatCastOutput(testing.allocator, 0.8, "", &carry, true)).?;
    defer testing.allocator.free(last);
    try testing.expectEqualStrings("[0.800000,\"o\",\"\\ufffd\\ufffd\"]\n", last);
}
