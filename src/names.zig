//! Session names, and the references that pick sessions in requests and
//! on the command line: an id (digits only), a name, or a pattern with `*`
//! and `?` that is matched against names. The daemon resolves them.

const std = @import("std");
const protocol = @import("protocol.zig");
const Status = @import("status.zig").Status;

pub const max_name_len = 64;

/// Why `name` cannot name a session, or null when it can. A name starts
/// with a letter or digit, continues with letters, digits, '.', '_', and
/// '-', and is not all digits, so it never reads as an id or a pattern.
pub fn nameError(name: []const u8) ?[]const u8 {
    return nameErrorOf(name, "it");
}

/// `nameError`, saying what the name is of: `subject` begins the
/// sentence, as in "the alert name is empty".
pub fn nameErrorOf(name: []const u8, comptime subject: []const u8) ?[]const u8 {
    if (name.len == 0) return subject ++ " is empty";
    if (name.len > max_name_len) return subject ++ " is longer than 64 characters";
    if (!std.ascii.isAlphanumeric(name[0])) return subject ++ " must start with a letter or digit";
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') {
            return "only letters, digits, '.', '_', and '-' are allowed";
        }
    }
    if (allDigits(name)) return "a name of digits only would read as a session id";
    return null;
}

fn allDigits(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return text.len > 0;
}

pub const Kind = enum { id, name, pattern };

/// How a reference picks sessions: digits are an id, text with `*` or
/// `?` is a pattern, anything else a name.
pub fn kind(ref: []const u8) Kind {
    if (allDigits(ref)) return .id;
    if (std.mem.indexOfAny(u8, ref, "*?") != null) return .pattern;
    return .name;
}

/// Why `ref` cannot pick a session, or null when it can.
pub fn refError(ref: []const u8) ?[]const u8 {
    switch (kind(ref)) {
        .id => if (protocol.parseDecimal(u64, ref) == null) return "the id is too large",
        .name => return nameError(ref),
        .pattern => for (ref) |c| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._-*?", c) == null) {
                return "only letters, digits, '.', '_', '-', '*', and '?' are allowed";
            }
        },
    }
    return null;
}

/// Whether `text` matches `pattern`, where `*` stands for any run of
/// characters (also none) and `?` for one.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    // Where the last `*` was, and the text position it now covers up to.
    var star: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_t = t;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_t += 1;
            t = star_t;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Which of the sessions a pattern matches a command that acts on
/// several applies to: `stop` to running ones, `remove` to ended ones.
/// Ids and names pick their session whatever its state, and the daemon
/// explains a mismatch.
pub const Filter = enum {
    any,
    running,
    ended,

    fn admits(f: Filter, running: bool) bool {
        return switch (f) {
            .any => true,
            .running => running,
            .ended => !running,
        };
    }
};

/// Whether the name or pattern `ref` picks a session named `name` (empty
/// when unnamed, so `*` picks it too).
pub fn picks(ref: []const u8, name: []const u8, running: bool, filter: Filter) bool {
    if (kind(ref) == .pattern) return globMatch(ref, name) and filter.admits(running);
    return std.mem.eql(u8, ref, name);
}

/// Why a name or pattern picked nothing, for an error message.
pub fn noMatch(gpa: std.mem.Allocator, ref: []const u8) ![]u8 {
    if (kind(ref) == .name) return std.fmt.allocPrint(gpa, "no session named '{s}'", .{ref});
    return std.fmt.allocPrint(gpa, "no session matches '{s}'", .{ref});
}

/// Why a reference that must pick one session picked several.
pub fn tooMany(gpa: std.mem.Allocator, ref: []const u8, matches: []const Status) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    try w.writer.print("'{s}' matches {d} sessions (", .{ ref, matches.len });
    for (matches, 0..) |s, i| {
        if (i > 0) try w.writer.writeAll(", ");
        try w.writer.print("{d}", .{s.id});
        if (s.name) |name| try w.writer.print(" {s}", .{name});
    }
    try w.writer.writeAll("); use a name or an id");
    return w.toOwnedSlice();
}

const testing = std.testing;

test "names start with a letter or digit, use a small alphabet, and are not ids" {
    try testing.expectEqual(@as(?[]const u8, null), nameError("build-1.2_x"));
    try testing.expectEqual(@as(?[]const u8, null), nameError("1st"));
    try testing.expect(nameError("") != null);
    try testing.expect(nameError("42") != null);
    try testing.expect(nameError("-x") != null);
    try testing.expect(nameError("a b") != null);
    try testing.expect(nameError("web*") != null);
    const long: [65]u8 = @splat('a');
    try testing.expect(nameError(&long) != null);
}

test "references are ids, names, or patterns" {
    try testing.expectEqual(Kind.id, kind("12"));
    try testing.expectEqual(Kind.name, kind("1st"));
    try testing.expectEqual(Kind.pattern, kind("ci-*"));
    try testing.expectEqual(Kind.pattern, kind("v?m"));
}

test "glob patterns" {
    try testing.expect(globMatch("*", ""));
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("ci-*", "ci-build"));
    try testing.expect(!globMatch("ci-*", "xci-build"));
    try testing.expect(globMatch("*-test", "unit-test"));
    try testing.expect(globMatch("a*b*c", "a-b-b-c"));
    try testing.expect(!globMatch("a*b*c", "a-b-b-"));
    try testing.expect(globMatch("v?m", "vim"));
    try testing.expect(!globMatch("v?m", "vm"));
    try testing.expect(!globMatch("?*", ""));
}

test "patterns honor the filter, names do not" {
    try testing.expect(picks("*", "ci-b", false, .ended));
    try testing.expect(picks("*", "", false, .ended));
    try testing.expect(!picks("*", "ci-a", true, .ended));
    try testing.expect(picks("ci-a", "ci-a", true, .ended));
    try testing.expect(!picks("ci", "ci-a", true, .any));
}
