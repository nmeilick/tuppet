//! The start file: blocks of steps that log a new session in somewhere,
//! for `tuppet start` (docs/design.md, "tuppet start"). This file reads it, puts the
//! steps of `use` together, and checks the rules that keep a run from
//! typing blind; src/start_run.zig runs the result.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const names = @import("names.zig");
const units = @import("units.zig");
const keys = @import("keys.zig");
const limits = @import("limits.zig");
const protocol = @import("protocol.zig");
const regex = @import("regex.zig");

/// How long a check waits unless its block or its own time says otherwise.
pub const default_timeout_ms: u64 = 10 * std.time.ms_per_s;
/// The daemon's limit for a wait.
pub const max_timeout_ms: u64 = 10 * std.time.ms_per_min;
/// How deep blocks may use blocks.
pub const max_depth = 8;

/// Text that fails a check when it appears after the input, unless a bare
/// `nofail` turns them off.
pub const builtin_failures = [_][]const u8{
    "Permission denied",
    "Connection refused",
    "Connection closed by",
    "Connection reset",
    "Connection timed out",
    "No route to host",
    "Network is unreachable",
    "Could not resolve hostname",
    "Name or service not known",
    "Host key verification failed",
    "Too many authentication failures",
    "Sorry, try again",
    "is not in the sudoers file",
    "incorrect password attempt",
    "Authentication failure",
    "command not found",
    "No such file or directory",
};

pub const Keyword = enum {
    send,
    type,
    keys,
    secret,
    ask,
    expect,
    @"or",
    gone,
    settle,
    ended,
    when,
    use,
    command,
    dir,
    size,
    timeout,
    fail,
    nofail,

    fn setting(k: Keyword) bool {
        return switch (k) {
            .command, .dir, .size, .timeout, .fail, .nofail => true,
            else => false,
        };
    }

    /// A setting a block gives at most once.
    fn single(k: Keyword) bool {
        return switch (k) {
            .command, .dir, .size, .timeout => true,
            else => false,
        };
    }
};

/// A line of a block: a keyword, its parameters, and its value, unquoted
/// but not expanded.
pub const Item = struct {
    keyword: Keyword,
    value: []const u8,
    line: u32,
    /// The time in the check's parentheses, as in expect(30s).
    timeout_ms: ?u64 = null,
    /// The value is a regex, as in expect(re).
    regex: bool = false,
    /// How many blanks the line starts with: the answer of a `when` is
    /// indented deeper than it.
    indent: u32 = 0,
    /// A `fail` right under a check, for that check only.
    under_check: bool = false,
};

/// Text that a check, a failure, or a question waits for.
pub const Pattern = struct {
    text: []const u8,
    regex: bool = false,
};

pub const Param = struct {
    name: []const u8,
    default: ?[]const u8,
};

pub const BlockKind = enum { start, steps, group };

pub const Block = struct {
    kind: BlockKind,
    /// The ids and patterns of a start block, the steps block's name, or a
    /// group's name and then its ids.
    names: []const []const u8,
    params: []const Param = &.{},
    line: u32,
    items: []const Item = &.{},
    /// The first thing wrong in the block, if any.
    problem: ?Problem = null,

    /// The block's id when it names exactly one and no pattern.
    pub fn singleId(b: *const Block) ?[]const u8 {
        if (b.kind != .start or b.names.len != 1 or names.kind(b.names[0]) == .pattern) return null;
        return b.names[0];
    }

    pub fn setting(b: *const Block, k: Keyword) ?Item {
        var found: ?Item = null;
        for (b.items) |it| if (it.keyword == k) {
            found = it;
        };
        return found;
    }
};

pub const Problem = struct {
    line: u32,
    text: []const u8,
};

pub const File = struct {
    /// The path, as messages show it.
    path: []const u8,
    blocks: []const Block,
    /// Problems outside any block.
    stray: []const Problem,
    /// The `fail` and `nofail` lines before the first block, for every
    /// block of the file.
    fails: []const Item = &.{},

    /// The start block for `id`: the one that names it exactly, else the
    /// first whose pattern matches it.
    pub fn startFor(f: *const File, id: []const u8) ?*const Block {
        for (f.blocks) |*b| if (b.kind == .start) for (b.names) |n| {
            if (names.kind(n) != .pattern and std.mem.eql(u8, n, id)) return b;
        };
        for (f.blocks) |*b| if (b.kind == .start) for (b.names) |n| {
            if (names.kind(n) == .pattern and names.globMatch(n, id)) return b;
        };
        return null;
    }

    /// The block `use NAME` puts in: a steps block, or a start block with
    /// that single id.
    pub fn usable(f: *const File, name: []const u8) ?*const Block {
        for (f.blocks) |*b| if (b.kind == .steps and std.mem.eql(u8, b.names[0], name)) return b;
        for (f.blocks) |*b| if (b.singleId()) |id| if (std.mem.eql(u8, id, name)) return b;
        return null;
    }

    /// The group named `name`, if any; a group goes before a start
    /// pattern that matches its name.
    pub fn groupFor(f: *const File, name: []const u8) ?*const Block {
        for (f.blocks) |*b| if (b.kind == .group and std.mem.eql(u8, b.names[0], name)) return b;
        return null;
    }
};

// ---- reading -------------------------------------------------------------

/// Read the file's text. Problems are kept with their block, so a broken
/// block other than the one started is only a warning.
pub fn parse(a: std.mem.Allocator, path: []const u8, text: []const u8) !File {
    var blocks: std.ArrayList(Block) = .empty;
    var stray: std.ArrayList(Problem) = .empty;
    var items: std.ArrayList(Item) = .empty;
    var current: ?Block = null;
    var file_fails: std.ArrayList(Item) = .empty;
    var number: u32 = 0;
    const body = if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (!std.unicode.utf8ValidateSlice(line)) {
            try noteProblem(a, &current, &stray, number, "the line is not valid UTF-8");
            continue;
        }
        if (line[0] != ' ' and line[0] != '\t') {
            if (failWord(trimmed)) {
                if (current != null or blocks.items.len > 0) {
                    try noteProblem(a, &current, &stray, number, "a 'fail' or 'nofail' at the left margin goes before the first block, for the whole file; in a block, indent it");
                    continue;
                }
                const top: Block = .{ .kind = .steps, .names = &.{""}, .line = number };
                const item = itemOf(a, &top, trimmed, number) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.Bad => {
                        try stray.append(a, .{ .line = number, .text = bad_text });
                        continue;
                    },
                };
                try file_fails.append(a, item);
                continue;
            }
            if (current) |*b| {
                b.items = try items.toOwnedSlice(a);
                try blocks.append(a, b.*);
            }
            current = null;
            items = .empty;
            current = header(a, trimmed, number) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Bad => blk: {
                    // A broken header still starts a block, so its lines do
                    // not land in the block before. A broken group keeps its
                    // name, so that starting it fails rather than falling to
                    // a pattern.
                    const why = bad_text;
                    const ws = words(a, trimmed) catch &.{};
                    if (ws.len >= 2 and std.mem.eql(u8, ws[0], "group") and names.kind(ws[1]) != .pattern and names.nameError(ws[1]) == null)
                        break :blk .{ .kind = .group, .names = ws[1..2], .line = number, .problem = .{ .line = number, .text = why } };
                    break :blk .{ .kind = .steps, .names = &.{""}, .line = number, .problem = .{ .line = number, .text = why } };
                },
            };
            continue;
        }
        const b = if (current) |*b| b else {
            try stray.append(a, .{ .line = number, .text = "an indented line must belong to a 'start' or 'steps' block" });
            continue;
        };
        if (b.kind == .group) {
            if (b.problem == null) b.problem = .{ .line = number, .text = "a group lists its ids on its own line and has no steps: steps go in a start block" };
            continue;
        }
        var item = itemOf(a, b, trimmed, number) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Bad => {
                if (b.problem == null) b.problem = .{ .line = number, .text = bad_text };
                continue;
            },
        };
        item.indent = @intCast(line.len - std.mem.trimStart(u8, line, " \t").len);
        if (try placeProblem(a, items.items, &item)) |why| {
            if (b.problem == null) b.problem = .{ .line = number, .text = why };
        }
        try items.append(a, item);
    }
    if (current) |*b| {
        b.items = try items.toOwnedSlice(a);
        try blocks.append(a, b.*);
    }
    try checkNames(a, blocks.items);
    try checkGroups(a, blocks.items);
    return .{ .path = path, .blocks = try blocks.toOwnedSlice(a), .stray = try stray.toOwnedSlice(a), .fails = try file_fails.toOwnedSlice(a) };
}

/// Whether a line at the left margin is a `fail` or `nofail` line.
fn failWord(text: []const u8) bool {
    const end = std.mem.indexOfAny(u8, text, " \t(") orelse text.len;
    return std.mem.eql(u8, text[0..end], "fail") or std.mem.eql(u8, text[0..end], "nofail");
}

/// The text of the latest error.Bad; it lives in the parse's arena.
threadlocal var bad_text: []const u8 = "";

fn bad(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{ Bad, OutOfMemory } {
    bad_text = try std.fmt.allocPrint(a, fmt, args);
    return error.Bad;
}

/// What is wrong with where setting `item` stands: after a step, or a
/// second time. A `fail` right under a check is that check's.
fn placeProblem(a: std.mem.Allocator, earlier: []const Item, item: *Item) !?[]const u8 {
    if (!item.keyword.setting()) return null;
    if (item.keyword == .fail) {
        for (earlier) |e| {
            if (!e.keyword.setting()) break;
        } else return null;
        const prev = earlier[earlier.len - 1];
        const under = switch (prev.keyword) {
            .expect, .@"or", .gone, .settle, .ended => true,
            .fail => prev.under_check,
            else => false,
        };
        if (!under) return "'fail' goes in one of three places: at the left margin before the first block, for the whole file; before a block's first step, for that block; or right under a check (expect, or, gone, settle, ended), for that check";
        item.under_check = true;
        return null;
    }
    for (earlier) |e| {
        if (!e.keyword.setting())
            return try std.fmt.allocPrint(a, "'{s}' is a setting: move it above line {d}, the block's first step", .{ @tagName(item.keyword), e.line });
        if (e.keyword == item.keyword and item.keyword.single())
            return try std.fmt.allocPrint(a, "'{s}' is given twice, at line {d} and here", .{ @tagName(item.keyword), e.line });
    }
    return null;
}

fn noteProblem(a: std.mem.Allocator, current: *?Block, stray: *std.ArrayList(Problem), line: u32, text: []const u8) !void {
    if (current.*) |*b| {
        if (b.problem == null) b.problem = .{ .line = line, .text = text };
    } else try stray.append(a, .{ .line = line, .text = text });
}

fn header(a: std.mem.Allocator, text: []const u8, line: u32) error{ Bad, OutOfMemory }!Block {
    const ws = try words(a, text);
    if (ws.len == 0) return bad(a, "expected 'start', 'steps', or 'group'", .{});
    if (std.mem.eql(u8, ws[0], "start")) {
        if (ws.len == 1) return bad(a, "'start' needs one or more ids", .{});
        for (ws[1..], 1..) |id, i| {
            const why = switch (names.kind(id)) {
                .pattern => names.refError(id),
                .id, .name => names.nameError(id),
            };
            if (why) |w| return bad(a, "invalid id '{s}': {s}", .{ id, w });
            for (ws[1..i]) |earlier| if (std.mem.eql(u8, earlier, id)) return bad(a, "'{s}' is named twice", .{id});
        }
        return .{ .kind = .start, .names = ws[1..], .line = line };
    }
    if (std.mem.eql(u8, ws[0], "steps")) {
        if (ws.len == 1) return bad(a, "'steps' needs a name", .{});
        if (names.nameError(ws[1])) |w| return bad(a, "invalid steps name '{s}': {s}", .{ ws[1], w });
        var params: std.ArrayList(Param) = .empty;
        for (ws[2..]) |w| {
            const eq = std.mem.indexOfScalar(u8, w, '=');
            const name = if (eq) |e| w[0..e] else w;
            if (!paramName(name)) return bad(a, "invalid parameter '{s}': use letters, digits, and '_', not starting with a digit", .{name});
            if (std.mem.eql(u8, name, "id")) return bad(a, "a parameter cannot be named 'id': %{{id}} is the started id", .{});
            for (params.items) |p| if (std.mem.eql(u8, p.name, name)) return bad(a, "the parameter '{s}' is declared twice", .{name});
            try params.append(a, .{ .name = name, .default = if (eq) |e| w[e + 1 ..] else null });
        }
        return .{ .kind = .steps, .names = ws[1..2], .params = try params.toOwnedSlice(a), .line = line };
    }
    if (std.mem.eql(u8, ws[0], "group")) {
        if (ws.len < 3) return bad(a, "'group' needs a name and the ids it starts: group NAME ID...", .{});
        if (names.kind(ws[1]) == .pattern) return bad(a, "invalid group name '{s}': a group's name is a plain name", .{ws[1]});
        if (names.nameError(ws[1])) |w| return bad(a, "invalid group name '{s}': {s}", .{ ws[1], w });
        for (ws[2..], 2..) |id, i| {
            if (names.kind(id) == .pattern) return bad(a, "'{s}' is a pattern: a group names each id it starts", .{id});
            if (names.nameError(id)) |w| return bad(a, "invalid id '{s}': {s}", .{ id, w });
            for (ws[2..i]) |earlier| if (std.mem.eql(u8, earlier, id)) return bad(a, "'{s}' is in the group twice", .{id});
        }
        return .{ .kind = .group, .names = ws[1..], .line = line };
    }
    return bad(a, "expected 'start', 'steps', or 'group', not '{s}'", .{ws[0]});
}

fn paramName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn itemOf(a: std.mem.Allocator, b: *const Block, text: []const u8, line: u32) error{ Bad, OutOfMemory }!Item {
    const end = std.mem.indexOfAny(u8, text, " \t(") orelse text.len;
    const word = text[0..end];
    if (std.mem.eql(u8, word, "within")) return bad(a, "'within' is gone: put the time on the check, as in expect(30s) TEXT", .{});
    const keyword = std.meta.stringToEnum(Keyword, word) orelse
        return bad(a, "unknown keyword '{s}'", .{word});
    var rest = text[end..];
    var params: Params = .{};
    if (rest.len > 0 and rest[0] == '(') {
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse return bad(a, "'{s}(' has no closing ')'", .{word});
        params = try checkParams(a, keyword, rest[1..close]);
        rest = rest[close + 1 ..];
        if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return bad(a, "a blank must follow '{s}({s})'", .{ word, text[end + 1 .. end + close] });
    }
    rest = std.mem.trim(u8, rest, " \t");
    // A regex is taken as written: quotes and backslashes are its own.
    if (!params.regex) if (timeGroup(rest)) |group|
        return bad(a, "'{s}' after a blank is text: write {s}{s} for how long it waits, or quote the text", .{ group, word, group });
    // `command` and `use` are split into words, whose quotes keep each together.
    const value = if (params.regex or keyword == .command or keyword == .use) rest else try unquote(a, rest);
    const empty_ok = switch (keyword) {
        .secret, .ask, .ended, .nofail => true,
        else => false,
    };
    if (value.len == 0 and !empty_ok) return bad(a, "'{s}' needs a value", .{word});
    if (keyword == .ask and value.len > 0) return bad(a, "'ask' takes no value", .{});
    if (keyword == .ended and value.len > 0 and protocol.parseDecimal(u8, value) == null)
        return bad(a, "'ended' takes nothing, or the exit status the program must end with (0 to 255), not '{s}'", .{value});
    if (b.kind != .start) switch (keyword) {
        .command, .dir, .size, .timeout => return bad(a, "'{s}' is a setting of a start block; in a steps block a check takes its own time, as in expect(30s)", .{word}),
        else => {},
    };
    switch (keyword) {
        .settle, .timeout => _ = try duration(a, word, value),
        .size => if (sizeOf(value) == null) return bad(a, "invalid size '{s}' (expected WxH, each " ++ limits.size_range ++ ")", .{value}),
        else => {},
    }
    return .{ .keyword = keyword, .value = value, .line = line, .timeout_ms = params.timeout_ms, .regex = params.regex };
}

/// Why `pattern` is no regex the daemon takes; null when it is one.
pub fn regexProblem(a: std.mem.Allocator, pattern: []const u8) ?[]const u8 {
    var why: []const u8 = "";
    var re = regex.compile(a, pattern, .{}, &why) catch |err| return switch (err) {
        error.OutOfMemory => "out of memory",
        error.BadPattern => why,
    };
    re.deinit(a);
    return null;
}

const Params = struct {
    timeout_ms: ?u64 = null,
    regex: bool = false,
};

/// The parameters in `keyword(...)`: the time a check waits, which starts
/// with a digit, and `re`, which makes the value a regex.
fn checkParams(a: std.mem.Allocator, keyword: Keyword, text: []const u8) error{ Bad, OutOfMemory }!Params {
    const word = @tagName(keyword);
    const timed = switch (keyword) {
        .expect, .gone, .settle, .ended => true,
        else => false,
    };
    const texts = switch (keyword) {
        .expect, .@"or", .gone, .fail, .when => true,
        else => false,
    };
    if (!timed and !texts) return bad(a, "'{s}' takes no parameters", .{word});
    var out: Params = .{};
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) return bad(a, "'{s}({s})' has an empty parameter", .{ word, text });
        if (std.ascii.isDigit(p[0])) {
            if (!timed) return if (keyword == .@"or")
                bad(a, "'or' takes no time: it waits as long as its 'expect'", .{})
            else
                bad(a, "'{s}' takes no time: only a check waits", .{word});
            if (out.timeout_ms != null) return bad(a, "'{s}({s})' gives two times", .{ word, text });
            out.timeout_ms = try duration(a, word, p);
        } else if (std.mem.eql(u8, p, "re")) {
            if (!texts) return bad(a, "'{s}' takes no 're': it waits for no text", .{word});
            if (out.regex) return bad(a, "'{s}({s})' gives 're' twice", .{ word, text });
            out.regex = true;
        } else if (std.ascii.isAlphabetic(p[0])) {
            return bad(a, "unknown parameter '{s}' for '{s}': a check takes how long it waits, as in expect(30s), and 're' for a regex, as in expect(re)", .{ p, word });
        } else return bad(a, "invalid parameter '{s}' for '{s}': give how long it waits, as in expect(30s), or 're'", .{ p, word });
    }
    return out;
}

/// The leading "(...)" of an unquoted value when it holds only times a
/// check may wait, as in "(30s)": a check's time with a blank before it.
fn timeGroup(text: []const u8) ?[]const u8 {
    if (text.len == 0 or text[0] != '(') return null;
    const close = std.mem.indexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.splitScalar(u8, text[1..close], ',');
    while (it.next()) |p| {
        const ms = units.parseDuration(std.mem.trim(u8, p, " \t"), .no_days) orelse return null;
        if (ms == 0 or ms > max_timeout_ms) return null;
    }
    return text[0 .. close + 1];
}

fn sizeOf(text: []const u8) ?[2]u16 {
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse return null;
    const cols = protocol.parseDecimal(u16, text[0..x]) orelse return null;
    const rows = protocol.parseDecimal(u16, text[x + 1 ..]) orelse return null;
    if (!limits.validSize(cols, rows)) return null;
    return .{ cols, rows };
}

fn duration(a: std.mem.Allocator, word: []const u8, text: []const u8) error{ Bad, OutOfMemory }!u64 {
    const ms = units.parseDuration(text, .no_days) orelse
        return bad(a, "invalid duration '{s}' for '{s}' ({s})", .{ text, word, units.durationHint(.no_days) });
    if (ms == 0 or ms > max_timeout_ms) return bad(a, "'{s}' must be more than 0 and at most 10m", .{word});
    return ms;
}

/// A value as written: one quoted string, with \" and \\, or the text.
fn unquote(a: std.mem.Allocator, text: []const u8) error{ Bad, OutOfMemory }![]const u8 {
    if (text.len == 0 or text[0] != '"') return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\') {
            if (i + 1 == text.len or (text[i + 1] != '"' and text[i + 1] != '\\')) return badBackslash(a);
            i += 1;
            try out.append(a, text[i]);
        } else if (c == '"') {
            if (i + 1 != text.len) return bad(a, "nothing may follow the closing quote", .{});
            return out.toOwnedSlice(a);
        } else try out.append(a, c);
    }
    return bad(a, "the quote is not closed", .{});
}

fn badBackslash(a: std.mem.Allocator) error{ Bad, OutOfMemory } {
    return bad(a, "inside quotes a backslash comes only before '\"' or another backslash: write \\\\ for one", .{});
}

/// Words split at blanks; double quotes keep a word together, with \"
/// and \\ inside.
pub fn words(a: std.mem.Allocator, text: []const u8) error{ Bad, OutOfMemory }![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i == text.len) break;
        var word: std.ArrayList(u8) = .empty;
        var quoted = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (quoted) {
                if (c == '\\') {
                    if (i + 1 == text.len or (text[i + 1] != '"' and text[i + 1] != '\\')) return badBackslash(a);
                    i += 1;
                    try word.append(a, text[i]);
                } else if (c == '"') quoted = false else try word.append(a, c);
            } else if (c == ' ' or c == '\t') {
                break;
            } else if (c == '"') quoted = true else try word.append(a, c);
        }
        if (quoted) return bad(a, "the quote is not closed", .{});
        try out.append(a, try word.toOwnedSlice(a));
    }
    return out.toOwnedSlice(a);
}

/// Ids given twice, and names of steps blocks given twice, are problems
/// of the later block. Groups and start blocks share their names, since
/// both are what `tuppet start` takes.
fn checkNames(a: std.mem.Allocator, blocks: []Block) !void {
    for (blocks, 0..) |*b, i| {
        if (b.problem != null) continue;
        for (blocks[0..i]) |*earlier| {
            if (earlier.problem != null and (earlier.kind == .group or earlier.names[0].len == 0)) continue;
            if ((b.kind == .steps) != (earlier.kind == .steps)) continue;
            for (declared(b)) |n| for (declared(earlier)) |m| if (std.mem.eql(u8, n, m)) {
                const what = switch (earlier.kind) {
                    .start => "start id",
                    .steps => "steps name",
                    .group => "group",
                };
                b.problem = .{ .line = b.line, .text = try std.fmt.allocPrint(a, "'{s}' is already a {s} at line {d}", .{ n, what, earlier.line }) };
            };
        }
    }
}

/// The names a block gives: a group's members are not among them.
fn declared(b: *const Block) []const []const u8 {
    return if (b.kind == .start) b.names else b.names[0..1];
}

/// A group's ids must each have a start block, and none may be a group.
fn checkGroups(a: std.mem.Allocator, blocks: []Block) !void {
    const file: File = .{ .path = "", .blocks = blocks, .stray = &.{} };
    for (blocks) |*b| {
        if (b.kind != .group or b.problem != null) continue;
        for (b.names[1..]) |id| {
            if (file.groupFor(id) != null) {
                b.problem = .{ .line = b.line, .text = try std.fmt.allocPrint(a, "'{s}' is a group: a group holds ids, not groups", .{id}) };
                break;
            }
            if (file.startFor(id) == null) {
                b.problem = .{ .line = b.line, .text = try std.fmt.allocPrint(a, "no start block for '{s}'", .{id}) };
                break;
            }
        }
    }
}

// ---- putting the steps together -------------------------------------------

pub const StepKind = enum {
    send,
    type,
    keys,
    secret,
    ask,
    expect,
    gone,
    settle,
    ended,

    pub fn input(k: StepKind) bool {
        return switch (k) {
            .send, .type, .keys, .secret, .ask => true,
            else => false,
        };
    }
};

/// Where a step comes from: its line, and the `use` it was put in by.
pub const Origin = struct {
    line: u32,
    keyword: Keyword,
    /// The value as written.
    value: []const u8,
    /// The steps block it is in; null in the started block.
    block: ?[]const u8,
    /// The origin of the `use` line that put it in.
    parent: ?u32,
};

pub const Step = struct {
    kind: StepKind,
    /// send and type: the text; keys: as written; secret: the variable's
    /// name, empty to ask.
    text: []const u8 = "",
    /// expect: its pattern, then those of its `or` lines; gone: its
    /// pattern.
    alts: []const Pattern = &.{},
    keys: []const []const u8 = &.{},
    /// settle: how long the screen stays unchanged.
    settle_ms: u64 = 0,
    /// ended: the exit status the program must end with, if any.
    status: ?u8 = null,
    /// A check's deadline.
    timeout_ms: u64 = 0,
    /// A check that follows an input: only what is new after it counts.
    after_input: bool = false,
    /// What the input before the check typed, whose echo does not count;
    /// empty when it typed nothing that shows.
    typed: []const u8 = "",
    /// What fails the check: the failure texts of the file and the block,
    /// then its own `fail` lines.
    fails: []const Pattern = &.{},
    /// The check's own `fail` lines, until `rules` puts them in `fails`.
    own_fails: []const Pattern = &.{},
    /// The questions that may come, each answered at most once per input:
    /// for a check, those since the latest input; for an input, those
    /// right after it, watched while it pauses when no check follows.
    whens: []const When = &.{},
    origin: u32,
    /// Made by the runner for an input with no check after it: a settle
    /// that ends the pause, and its time running out goes on too.
    pause: bool = false,

    pub fn check(s: Step) bool {
        return !s.kind.input();
    }
};

/// A `when` line and the line after it, which answers its question.
pub const When = struct {
    pattern: Pattern,
    /// send, type, keys, or secret.
    answer: StepKind,
    /// send and type: the text; keys: as written; secret: the variable's
    /// name, empty to ask.
    answer_text: []const u8,
    answer_keys: []const []const u8 = &.{},
    /// The `when` line's origin; it also tells one `when` from another.
    origin: u32,
    answer_origin: u32,
};

pub const Plan = struct {
    id: []const u8,
    block_line: u32,
    command: ?[]const []const u8 = null,
    dir: ?[]const u8 = null,
    size: ?[2]u16 = null,
    steps: []const Step,
    origins: []const Origin,
    /// The variables secret steps and answers read.
    secrets: []const []const u8,
    /// What --check points out, as FILE:LINE: text.
    notes: []const []const u8 = &.{},
    /// Some input has no check after it, or a check's text is part of
    /// the input before it, so the daemon must know the input's echo.
    needs_echo: bool = false,
    needs_regex: bool = false,
};

/// What is wrong with a plan: the line it is on and the chain of `use`
/// that led there, said in `text`.
pub const PlanError = error{ Bad, OutOfMemory };

const Ctx = struct {
    id: []const u8,
    params: []const Param = &.{},
    values: []const []const u8 = &.{},
    block: ?[]const u8 = null,
    parent: ?u32 = null,
    depth: u32 = 0,
    /// The failure texts of the block's checks.
    fails: []const Pattern,
    /// The failure texts the blocks it uses inherit.
    passed: []const Pattern = &.{},
};

const Builder = struct {
    a: std.mem.Allocator,
    file: *const File,
    steps: std.ArrayList(Step) = .empty,
    origins: std.ArrayList(Origin) = .empty,
    notes: std.ArrayList([]const u8) = .empty,
    /// The blocks being put in, to find cycles.
    stack: std.ArrayList([]const u8) = .empty,
    timeout_ms: u64,

    fn origin(bd: *Builder, it: Item, ctx: Ctx) !u32 {
        try bd.origins.append(bd.a, .{ .line = it.line, .keyword = it.keyword, .value = it.value, .block = ctx.block, .parent = ctx.parent });
        return @intCast(bd.origins.items.len - 1);
    }

    fn fail(bd: *Builder, line: u32, parent: ?u32, comptime fmt: []const u8, args: anytype) PlanError {
        bad_text = try bd.located(line, parent, fmt, args);
        return error.Bad;
    }

    /// Something `--check` points out, though the steps run.
    fn note(bd: *Builder, line: u32, parent: ?u32, comptime fmt: []const u8, args: anytype) !void {
        try bd.notes.append(bd.a, try bd.located(line, parent, fmt, args));
    }

    fn located(bd: *Builder, line: u32, parent: ?u32, comptime fmt: []const u8, args: anytype) ![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        try text.print(bd.a, "{s}:{d}: " ++ fmt, .{ bd.file.path, line } ++ args);
        try bd.chain(&text, parent);
        return text.toOwnedSlice(bd.a);
    }

    /// ", in NAME used at FILE:LINE" for each `use` that led here.
    fn chain(bd: *Builder, text: *std.ArrayList(u8), parent: ?u32) !void {
        var at = parent;
        while (at) |p| {
            const o = bd.origins.items[p];
            try text.print(bd.a, " (in {s}, used at line {d})", .{ o.value, o.line });
            at = o.parent;
        }
    }

    fn put(bd: *Builder, block: *const Block, ctx: Ctx) PlanError!void {
        // The `when` lines since the latest input, which its checks watch
        // for; and the answer of the latest one when no check or input
        // watches for its question.
        var whens: std.ArrayList(When) = .empty;
        var open_when: ?u32 = null;
        // The line before, less a check's own `fail` lines: an `or` must
        // follow an `expect` or `or` of this block.
        var prev: ?Keyword = null;
        var k: usize = 0;
        while (k < block.items.len) : (k += 1) {
            const it = block.items[k];
            if (it.keyword.setting() and !it.under_check) continue;
            defer prev = if (it.keyword == .fail) prev else it.keyword;
            switch (it.keyword) {
                .send, .type, .keys, .secret, .ask, .use => {
                    try bd.unwatched(open_when, ctx);
                    open_when = null;
                    whens = .empty;
                },
                else => {},
            }
            switch (it.keyword) {
                .when => {
                    const next = if (k + 1 < block.items.len) block.items[k + 1] else return bd.fail(it.line, ctx.parent, "'when' must be followed by its answer: a send, type, keys, or secret line indented deeper than it", .{});
                    const answer: StepKind = switch (next.keyword) {
                        .send => .send,
                        .type => .type,
                        .keys => .keys,
                        .secret => .secret,
                        else => return bd.fail(next.line, ctx.parent, "'when' must be followed by its answer, a send, type, keys, or secret line, not '{s}'", .{@tagName(next.keyword)}),
                    };
                    if (next.indent <= it.indent) return bd.fail(next.line, ctx.parent, "the answer to the 'when' at line {d} must be indented deeper than it", .{it.line});
                    const text = if (answer == .secret) try bd.secretName(next, ctx) else try bd.filled(next, ctx);
                    const w: When = .{
                        .pattern = try bd.pattern(it, ctx),
                        .answer = answer,
                        .answer_text = text,
                        .answer_keys = if (answer == .keys) try bd.keysOf(next, text, ctx) else &.{},
                        .origin = try bd.origin(it, ctx),
                        .answer_origin = try bd.origin(next, ctx),
                    };
                    try whens.append(bd.a, w);
                    // Right after an input, its pause watches for it too.
                    const last = if (bd.steps.items.len > 0) &bd.steps.items[bd.steps.items.len - 1] else null;
                    if (last != null and last.?.kind.input()) {
                        last.?.whens = try std.mem.concat(bd.a, When, &.{ last.?.whens, &.{w} });
                        open_when = null;
                    } else open_when = w.origin;
                    k += 1;
                    continue;
                },
                .fail => {
                    // The parser put it right under a check of this block.
                    const last = &bd.steps.items[bd.steps.items.len - 1];
                    last.own_fails = try std.mem.concat(bd.a, Pattern, &.{ last.own_fails, &.{try bd.pattern(it, ctx)} });
                },
                .@"or" => {
                    if (prev != .expect and prev != .@"or") return bd.fail(it.line, ctx.parent, "'or' must follow an 'expect' of the same block, or another 'or'", .{});
                    const last = &bd.steps.items[bd.steps.items.len - 1];
                    last.alts = try std.mem.concat(bd.a, Pattern, &.{ last.alts, &.{try bd.pattern(it, ctx)} });
                },
                .use => try bd.use(it, ctx),
                .secret => try bd.steps.append(bd.a, .{ .kind = .secret, .text = try bd.secretName(it, ctx), .origin = try bd.origin(it, ctx) }),
                .ask => try bd.steps.append(bd.a, .{ .kind = .ask, .origin = try bd.origin(it, ctx) }),
                .send, .type => try bd.steps.append(bd.a, .{
                    .kind = if (it.keyword == .send) .send else .type,
                    .text = try bd.filled(it, ctx),
                    .origin = try bd.origin(it, ctx),
                }),
                .keys => {
                    const text = try bd.filled(it, ctx);
                    try bd.steps.append(bd.a, .{ .kind = .keys, .keys = try bd.keysOf(it, text, ctx), .text = text, .origin = try bd.origin(it, ctx) });
                },
                .expect, .gone, .settle, .ended => {
                    var step: Step = .{
                        .kind = switch (it.keyword) {
                            .expect => .expect,
                            .gone => .gone,
                            .settle => .settle,
                            else => .ended,
                        },
                        .timeout_ms = it.timeout_ms orelse bd.timeout_ms,
                        .fails = ctx.fails,
                        .whens = whens.items,
                        .origin = try bd.origin(it, ctx),
                    };
                    switch (it.keyword) {
                        .expect, .gone => step.alts = try bd.a.dupe(Pattern, &.{try bd.pattern(it, ctx)}),
                        .settle => step.settle_ms = units.parseDuration(it.value, .no_days).?,
                        else => step.status = if (it.value.len > 0) protocol.parseDecimal(u8, it.value).? else null,
                    }
                    try bd.steps.append(bd.a, step);
                    open_when = null;
                },
                else => unreachable,
            }
        }
        try bd.unwatched(open_when, ctx);
    }

    /// A `when` whose question nothing watches for: no check follows it
    /// before the next input, and no input right before it pauses.
    fn unwatched(bd: *Builder, when_origin: ?u32, ctx: Ctx) !void {
        const o = bd.origins.items[when_origin orelse return];
        try bd.note(o.line, ctx.parent, "no check follows this 'when' before the next input, so nothing watches for its question", .{});
    }

    /// The variable a `secret` line reads: empty to ask.
    fn secretName(bd: *Builder, it: Item, ctx: Ctx) PlanError![]const u8 {
        const text = try bd.expand(it, ctx);
        if (text.len == 0) return "";
        if (text[0] == '$' and envName(text[1..])) return text[1..];
        return bd.fail(it.line, ctx.parent, "'secret' takes nothing or $VARIABLE, never the password itself", .{});
    }

    /// The text a line waits for, expanded; a regex must compile.
    fn pattern(bd: *Builder, it: Item, ctx: Ctx) PlanError!Pattern {
        const text = try bd.filled(it, ctx);
        if (it.regex) if (regexProblem(bd.a, text)) |why| return bd.fail(it.line, ctx.parent, "invalid regex '{s}': {s}", .{ text, why });
        return .{ .text = text, .regex = it.regex };
    }

    /// The keys of a `keys` line whose value expanded to `text`.
    fn keysOf(bd: *Builder, it: Item, text: []const u8, ctx: Ctx) PlanError![]const []const u8 {
        var bad_key: []const u8 = text;
        const split = keys.split(bd.a, text, &bad_key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return bd.fail(it.line, ctx.parent, "invalid key '{s}': {s}", .{ bad_key, keys.errorText(err) }),
        };
        for (split) |tok| keys.checkToken(tok) catch |err|
            return bd.fail(it.line, ctx.parent, "invalid key '{s}': {s}", .{ tok, keys.errorText(err) });
        return split;
    }

    fn use(bd: *Builder, it: Item, ctx: Ctx) PlanError!void {
        const ws = words(bd.a, it.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Bad => return bd.fail(it.line, ctx.parent, "{s}", .{bad_text}),
        };
        if (ws.len == 0) return bd.fail(it.line, ctx.parent, "'use' needs the name of a block", .{});
        const name = ws[0];
        const block = bd.file.usable(name) orelse {
            if (bd.file.groupFor(name) != null) return bd.fail(it.line, ctx.parent, "'use {s}': that is a group, and 'use' takes a steps block or a start block", .{name});
            return bd.fail(it.line, ctx.parent, "'use {s}': no steps block, and no start block with that single id", .{name});
        };
        if (block.problem) |p| return bd.fail(p.line, null, "{s} (in '{s}', used at line {d})", .{ p.text, name, it.line });
        if (block.kind == .start) for ([_]Keyword{ .command, .dir, .size, .timeout }) |k| {
            if (block.setting(k)) |s| return bd.fail(it.line, ctx.parent, "'use {s}': that start block sets '{s}' (line {d}), which a use would leave out", .{ name, @tagName(k), s.line });
        };
        for (bd.stack.items) |open| if (std.mem.eql(u8, open, name)) {
            var cycle: std.ArrayList(u8) = .empty;
            for (bd.stack.items) |n| try cycle.print(bd.a, "{s} -> ", .{n});
            try cycle.appendSlice(bd.a, name);
            return bd.fail(it.line, ctx.parent, "'use' goes round: {s}", .{cycle.items});
        };
        if (ctx.depth + 1 > max_depth) return bd.fail(it.line, ctx.parent, "blocks use blocks more than {d} deep", .{max_depth});
        const args = ws[1..];
        if (args.len > block.params.len) return bd.fail(it.line, ctx.parent, "'{s}' takes {d} argument{s}, not {d}", .{ name, block.params.len, if (block.params.len == 1) "" else "s", args.len });
        const values = try bd.a.alloc([]const u8, block.params.len);
        for (block.params, 0..) |p, i| {
            if (i < args.len) {
                values[i] = try bd.expandText(args[i], it, ctx);
            } else if (p.default) |d| {
                // A default is the block's own text: %i, but no parameters.
                values[i] = try bd.expandText(d, it, .{ .id = ctx.id, .fails = ctx.fails, .parent = ctx.parent });
            } else return bd.fail(it.line, ctx.parent, "'{s}' needs a value for its parameter '{s}'", .{ name, p.name });
        }
        var inner: Ctx = .{
            .id = ctx.id,
            .params = block.params,
            .values = values,
            .block = name,
            .parent = try bd.origin(it, ctx),
            .depth = ctx.depth + 1,
            .fails = &.{},
        };
        const fails = try bd.failsOf(block.items, ctx.passed, inner);
        inner.fails = fails.own;
        inner.passed = fails.passed;
        try bd.stack.append(bd.a, name);
        defer _ = bd.stack.pop();
        try bd.put(block, inner);
    }

    /// The failure texts of a block: those it inherits and its `fail` lines
    /// before its first step, expanded as its other lines are. Its
    /// `nofail` lines take texts out of its own checks only, so a block
    /// cannot quiet the failures of the blocks it uses; a bare `nofail`
    /// takes out the built-in texts. The lines before the file's first
    /// block work the same way for the whole file.
    fn failsOf(bd: *Builder, items: []const Item, inherited: []const Pattern, ctx: Ctx) PlanError!Fails {
        var passed: std.ArrayList(Pattern) = .empty;
        try passed.appendSlice(bd.a, inherited);
        for (items) |it| if (it.keyword == .fail and !it.under_check) try passed.append(bd.a, try bd.pattern(it, ctx));
        var own: std.ArrayList(Pattern) = .empty;
        each: for (passed.items, 0..) |t, i| {
            for (items) |it| if (it.keyword == .nofail) {
                if (it.value.len == 0) {
                    if (i < inherited.len and !t.regex and isBuiltin(t.text)) continue :each;
                } else {
                    // Expanded as the fail it names was, escaped for a regex.
                    var as = it;
                    as.regex = t.regex;
                    if (std.mem.eql(u8, try bd.expand(as, ctx), t.text)) continue :each;
                }
            };
            try own.append(bd.a, t);
        }
        return .{ .own = try own.toOwnedSlice(bd.a), .passed = try passed.toOwnedSlice(bd.a) };
    }

    /// The failure texts every block starts from: the built-in ones and
    /// the file's own, less what the file's `nofail` lines take out.
    fn fileFails(bd: *Builder, id: []const u8) PlanError![]const Pattern {
        var builtins: [builtin_failures.len]Pattern = undefined;
        for (&builtins, builtin_failures) |*p, t| p.* = .{ .text = t };
        return (try bd.failsOf(bd.file.fails, &builtins, .{ .id = id, .fails = &.{} })).own;
    }

    fn expand(bd: *Builder, it: Item, ctx: Ctx) PlanError![]const u8 {
        return bd.expandText(it.value, it, ctx);
    }

    /// The value of a line that needs one, expanded: a parameter may not
    /// leave it empty.
    fn filled(bd: *Builder, it: Item, ctx: Ctx) PlanError![]const u8 {
        const text = try bd.expand(it, ctx);
        if (text.len == 0) return bd.fail(it.line, ctx.parent, "'{s}' needs a value, and its parameters put in none", .{@tagName(it.keyword)});
        return text;
    }

    /// `text` with %i or %{id}, %{param}, and %% put in; any other % stays.
    /// In a regex, what is put in matches as written.
    fn expandText(bd: *Builder, text: []const u8, it: Item, ctx: Ctx) PlanError![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '%') == null) {
            if (text.len > max_text) return bd.fail(it.line, ctx.parent, "the text is longer than 4096 bytes", .{});
            return text;
        }
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (c != '%' or i + 1 == text.len) {
                try out.append(bd.a, c);
                continue;
            }
            switch (text[i + 1]) {
                'i' => {
                    try putIn(bd.a, &out, ctx.id, it.regex);
                    i += 1;
                },
                '%' => {
                    try out.append(bd.a, '%');
                    i += 1;
                },
                '{' => {
                    const close = std.mem.indexOfScalarPos(u8, text, i + 2, '}') orelse
                        return bd.fail(it.line, ctx.parent, "'%{{' has no closing '}}'", .{});
                    const name = text[i + 2 .. close];
                    i = close;
                    if (std.mem.eql(u8, name, "id")) {
                        try putIn(bd.a, &out, ctx.id, it.regex);
                        continue;
                    }
                    const k = for (ctx.params, 0..) |p, k| {
                        if (std.mem.eql(u8, p.name, name)) break k;
                    } else return bd.fail(it.line, ctx.parent, "'%{{{s}}}' is no parameter of {s}", .{ name, if (ctx.block) |b| b else "a start block, which has none" });
                    try putIn(bd.a, &out, ctx.values[k], it.regex);
                },
                else => try out.append(bd.a, c),
            }
        }
        if (out.items.len > max_text) return bd.fail(it.line, ctx.parent, "the text is longer than 4096 bytes", .{});
        return out.toOwnedSlice(bd.a);
    }
};

/// Append `value`, with a backslash before what a regex takes for syntax
/// when `escape`.
fn putIn(a: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8, escape: bool) !void {
    for (value) |c| {
        if (escape and std.mem.indexOfScalar(u8, "\\.^$|?*+()[]{}/", c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
}

const max_text = 4096;

fn envName(name: []const u8) bool {
    return paramName(name);
}

const Fails = struct {
    /// What the block's own checks watch for.
    own: []const Pattern,
    /// What the blocks it uses inherit.
    passed: []const Pattern,
};

fn isBuiltin(text: []const u8) bool {
    for (builtin_failures) |b| if (std.mem.eql(u8, b, text)) return true;
    return false;
}

/// The steps for `id`, put together and checked. On error.Bad,
/// `badText()` says what is wrong.
pub fn plan(a: std.mem.Allocator, file: *const File, id: []const u8) PlanError!Plan {
    const block = file.startFor(id) orelse {
        bad_text = try std.fmt.allocPrint(a, "{s}: no start block for '{s}'", .{ file.path, id });
        return error.Bad;
    };
    return planBlock(a, file, block, id);
}

/// The steps of `block`, started as `id`.
pub fn planBlock(a: std.mem.Allocator, file: *const File, block: *const Block, id: []const u8) PlanError!Plan {
    var bd: Builder = .{ .a = a, .file = file, .timeout_ms = default_timeout_ms };
    if (block.problem) |p| return bd.fail(p.line, null, "{s}", .{p.text});
    if (block.setting(.timeout)) |t| bd.timeout_ms = units.parseDuration(t.value, .no_days).?;
    var ctx: Ctx = .{ .id = id, .fails = &.{} };
    const fails = try bd.failsOf(block.items, try bd.fileFails(id), ctx);
    ctx.fails = fails.own;
    ctx.passed = fails.passed;
    if (block.singleId()) |single| try bd.stack.append(a, single);
    try bd.put(block, ctx);
    var p: Plan = .{
        .id = id,
        .block_line = block.line,
        .steps = bd.steps.items,
        .origins = bd.origins.items,
        .secrets = &.{},
    };
    if (block.setting(.command)) |c| {
        const ws = words(a, try bd.expand(c, ctx)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Bad => return bd.fail(c.line, null, "{s}", .{bad_text}),
        };
        if (ws.len == 0) return bd.fail(c.line, null, "'command' needs a program", .{});
        p.command = ws;
    }
    if (block.setting(.dir)) |d| p.dir = try bd.expand(d, ctx);
    if (block.setting(.size)) |s| p.size = sizeOf(s.value).?;
    try rules(&bd, &p);
    return p;
}

/// The steps of block `name` with `args`, in a session that runs already
/// as `id`: what `tuppet do --use` runs. The block must start with the
/// check of the prompt it is used at, since nothing typed it.
pub fn planUse(a: std.mem.Allocator, file: *const File, name: []const u8, args: []const []const u8, id: []const u8, timeout_ms: ?u64) PlanError!Plan {
    var bd: Builder = .{ .a = a, .file = file, .timeout_ms = timeout_ms orelse default_timeout_ms };
    const block = file.usable(name) orelse {
        bad_text = try std.fmt.allocPrint(a, "{s}: no steps block '{s}', and no start block with that single id", .{ file.path, name });
        return error.Bad;
    };
    if (block.problem) |p| return bd.fail(p.line, null, "{s}", .{p.text});
    if (block.kind == .start) for ([_]Keyword{ .command, .dir, .size, .timeout }) |k| {
        if (block.setting(k)) |st| return bd.fail(st.line, null, "'{s}' sets '{s}', which a session that runs already cannot take", .{ name, @tagName(k) });
    };
    if (args.len > block.params.len) return bd.fail(block.line, null, "'{s}' takes {d} argument{s}, not {d}", .{ name, block.params.len, if (block.params.len == 1) "" else "s", args.len });
    const values = try a.alloc([]const u8, block.params.len);
    for (block.params, 0..) |p, i| {
        if (i < args.len) {
            if (std.mem.indexOfAny(u8, args[i], "\r\n") != null) return bd.fail(block.line, null, "the value for '{s}' holds a line break", .{p.name});
            values[i] = args[i];
        } else if (p.default) |d| {
            values[i] = try bd.expandText(d, .{ .keyword = .use, .value = d, .line = block.line }, .{ .id = id, .fails = &.{} });
        } else return bd.fail(block.line, null, "'{s}' needs a value for its parameter '{s}'", .{ name, p.name });
    }
    var ctx: Ctx = .{ .id = id, .params = block.params, .values = values, .block = name, .fails = &.{} };
    const fails = try bd.failsOf(block.items, try bd.fileFails(id), ctx);
    ctx.fails = fails.own;
    ctx.passed = fails.passed;
    try bd.stack.append(bd.a, name);
    try bd.put(block, ctx);
    const steps = bd.steps.items;
    if (steps.len == 0 or steps[0].kind != .expect)
        return bd.fail(block.line, null, "'{s}' must start with an 'expect' of the prompt it is used at: nothing is typed before the screen is known", .{name});
    var p: Plan = .{ .id = id, .block_line = block.line, .steps = steps, .origins = bd.origins.items, .secrets = &.{} };
    try rules(&bd, &p);
    // A failure text on the screen before anything was typed is old.
    steps[0].fails = &.{};
    return p;
}

pub fn badText() []const u8 {
    return bad_text;
}

/// Commands that change where the next input goes; an expect text that
/// is part of one is noted, since an error that names it meets it too.
const hops = [_][]const u8{ "ssh", "mosh", "telnet", "sudo", "su", "docker", "kubectl", "podman" };

/// The structural rules on the steps as they will run; they also fill in
/// what each check watches for besides its text, and what --check notes.
fn rules(bd: *Builder, p: *Plan) PlanError!void {
    const a = bd.a;
    const steps = bd.steps.items;
    var secrets: std.ArrayList([]const u8) = .empty;
    // The checks that inputs were typed after: the prompts of the hops.
    var prompts: std.ArrayList([]const Pattern) = .empty;
    var last_input: ?usize = null;
    for (steps, 0..) |*s, i| {
        const o = bd.origins.items[s.origin];
        for (s.whens) |w| if (w.answer == .secret) try addSecret(a, &secrets, w.answer_text);
        for (s.whens) |w| if (w.pattern.regex) {
            p.needs_regex = true;
        };
        if (s.kind.input()) {
            if (s.kind == .secret) {
                if (i == 0 or steps[i - 1].kind != .expect)
                    return bd.fail(o.line, o.parent, "'secret' must follow the 'expect' of its password prompt, or answer a 'when' that waits for it", .{});
                if (i >= 3 and steps[i - 2].kind.input() and !steps[i - 3].check()) {
                    const c = bd.origins.items[steps[i - 2].origin];
                    try bd.note(c.line, c.parent, "no check comes before this command, which brings a password prompt: if a hop before it failed, the password would go to the host before", .{});
                }
                try addSecret(a, &secrets, s.text);
            }
            if (i > 0 and steps[i - 1].kind == .expect) try prompts.append(a, steps[i - 1].alts);
            if (i + 1 == steps.len or steps[i + 1].kind.input()) p.needs_echo = true;
            last_input = i;
            continue;
        }
        for (s.alts) |t| if (t.regex) {
            p.needs_regex = true;
        };
        for (s.own_fails) |t| if (t.regex) {
            p.needs_regex = true;
        };
        s.after_input = last_input != null;
        const typed = if (last_input) |at| switch (steps[at].kind) {
            .send, .type => steps[at].text,
            else => "",
        } else "";
        s.typed = typed;
        // The file's and the block's failure texts leave out those that
        // are part of the typed text or of what the check waits for.
        var fails: std.ArrayList(Pattern) = .empty;
        for (s.fails) |f| {
            if (f.regex) p.needs_regex = true;
            if (!f.regex and (partOf(typed, f.text) or related(s.alts, f.text))) continue;
            try fails.append(a, f);
        }
        try fails.appendSlice(a, s.own_fails);
        s.fails = try fails.toOwnedSlice(a);
        for (s.alts) |t| if (!t.regex and partOf(typed, t.text)) {
            p.needs_echo = true;
            if (t.text.len < typed.len and hop(typed))
                try bd.note(o.line, o.parent, "'{s}' is part of the command before it ('{s}'): its echo does not count, but an error that names it would meet the check; more of the prompt is safer", .{ t.text, typed });
        };
        for (s.fails) |f| if (!f.regex and partOf(typed, f.text)) {
            p.needs_echo = true;
        };
        for (s.whens) |w| if (!w.pattern.regex and partOf(typed, w.pattern.text)) {
            p.needs_echo = true;
        };
        // An earlier hop's prompt that comes back, as when a hop failed,
        // would meet a text that is part of it. The prompt the input was
        // typed at comes back after a command that stays.
        const li = last_input orelse 0;
        const earlier = if (li > 0 and steps[li - 1].kind == .expect) prompts.items[0 .. prompts.items.len - 1] else prompts.items;
        if (s.kind == .expect) for (s.alts) |t| if (!t.regex) for (earlier) |prompt| for (prompt) |pt| {
            if (!pt.regex and std.mem.indexOf(u8, pt.text, t.text) != null) {
                try bd.note(o.line, o.parent, "'{s}' is part of the earlier prompt '{s}', so that prompt coming back, as when a hop fails, would meet the check: give more of the prompt, or put 'fail {s}' under it", .{ t.text, pt.text, pt.text });
                break;
            }
        };
    }
    for (steps[0..steps.len -| 1]) |s| if (s.kind == .ended) {
        const o = bd.origins.items[s.origin];
        return bd.fail(o.line, o.parent, "'ended' must be the last step: nothing can follow the end of the program", .{});
    };
    p.secrets = try secrets.toOwnedSlice(a);
    p.notes = try bd.notes.toOwnedSlice(a);
}

fn addSecret(a: std.mem.Allocator, secrets: *std.ArrayList([]const u8), name: []const u8) !void {
    if (name.len == 0) return;
    for (secrets.items) |v| if (std.mem.eql(u8, v, name)) return;
    try secrets.append(a, name);
}

/// Whether `text` occurs in `typed`.
fn partOf(typed: []const u8, text: []const u8) bool {
    return typed.len > 0 and std.mem.indexOf(u8, typed, text) != null;
}

/// Whether `typed` runs a command that changes where input goes.
fn hop(typed: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, typed, " \t;&|");
    while (it.next()) |w| for (hops) |h| if (std.mem.eql(u8, w, h)) return true;
    return false;
}

/// Whether `text` is part of one of the plain `alts`, or one of them part
/// of it.
fn related(alts: []const Pattern, text: []const u8) bool {
    for (alts) |t| {
        if (t.regex) continue;
        if (std.mem.indexOf(u8, t.text, text) != null or std.mem.indexOf(u8, text, t.text) != null) return true;
    }
    return false;
}

// ---- finding the file ----------------------------------------------------

pub const Found = struct {
    path: []u8,
    /// TUPPET_START named it, so it must exist.
    given: bool = false,
};

/// The start file's path in `gpa`; null when there is none to read.
pub fn filePath(gpa: std.mem.Allocator) !?Found {
    const env = io_mod.environ;
    if (env.getAlloc(gpa, "TUPPET_START")) |given| {
        if (given.len > 0) return .{ .path = given, .given = true };
        gpa.free(given);
        return null;
    } else |_| {}
    if (builtin.os.tag == .windows) {
        const appdata = env.getAlloc(gpa, "APPDATA") catch return null;
        defer gpa.free(appdata);
        return .{ .path = try std.mem.concat(gpa, u8, &.{ appdata, "\\tuppet\\start" }) };
    }
    if (env.getAlloc(gpa, "XDG_CONFIG_HOME")) |dir| {
        defer gpa.free(dir);
        if (std.fs.path.isAbsolute(dir)) return .{ .path = try std.mem.concat(gpa, u8, &.{ dir, "/tuppet/start" }) };
    } else |_| {}
    const home = env.getAlloc(gpa, "HOME") catch return null;
    defer gpa.free(home);
    if (!std.fs.path.isAbsolute(home)) return null;
    return .{ .path = try std.mem.concat(gpa, u8, &.{ home, "/.config/tuppet/start" }) };
}

// ---- tests -----------------------------------------------------------------

const example =
    \\steps jump
    \\    send     ssh jump.example.com
    \\    expect   ops@jump:~$
    \\
    \\# Become another user with sudo.
    \\steps become user pw=$SUDO_PW
    \\    send     sudo -iu %{user}
    \\    expect   [sudo] password for ops:
    \\    secret   %{pw}
    \\    expect   %{user}@
    \\
    \\start db1 db2 db*
    \\    timeout  15s
    \\    use      jump
    \\    send     ssh %i.internal
    \\    expect(1m) ops@%i:~$
    \\    use      become app $APP_PW
    \\    send     cd /srv/app
    \\    expect   app@%i:/srv/app$
    \\
;

fn testPlan(a: std.mem.Allocator, text: []const u8, id: []const u8) !Plan {
    const file = try a.create(File);
    file.* = try parse(a, "start", text);
    return plan(a, file, id);
}

fn expectBad(text: []const u8, id: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (testPlan(arena.allocator(), text, id)) |_| {
        std.debug.print("expected an error with '{s}'\n", .{needle});
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.Bad, err);
        if (std.mem.indexOf(u8, badText(), needle) == null) {
            std.debug.print("got '{s}', expected '{s}'\n", .{ badText(), needle });
            return error.TestUnexpectedError;
        }
    }
}

test "a start block puts its steps and those it uses together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try testPlan(arena.allocator(), example, "db3");
    const kinds = [_]StepKind{ .send, .expect, .send, .expect, .send, .expect, .secret, .expect, .send, .expect };
    try std.testing.expectEqual(kinds.len, p.steps.len);
    for (kinds, p.steps) |k, s| try std.testing.expectEqual(k, s.kind);
    try std.testing.expectEqualStrings("ssh db3.internal", p.steps[2].text);
    try std.testing.expectEqualStrings("ops@db3:~$", p.steps[3].alts[0].text);
    try std.testing.expectEqual(@as(u64, 60_000), p.steps[3].timeout_ms);
    try std.testing.expectEqual(@as(u64, 15_000), p.steps[1].timeout_ms);
    try std.testing.expectEqualStrings("sudo -iu app", p.steps[4].text);
    try std.testing.expectEqualStrings("APP_PW", p.steps[6].text);
    try std.testing.expectEqualStrings("app@", p.steps[7].alts[0].text);
    try std.testing.expectEqualSlices(u8, "APP_PW", p.secrets[0]);
    try std.testing.expect(p.steps[1].after_input);
    try std.testing.expectEqualStrings("ssh db3.internal", p.steps[3].typed);
    // Where steps come from.
    const o = p.origins[p.steps[0].origin];
    try std.testing.expectEqual(@as(u32, 2), o.line);
    try std.testing.expectEqualStrings("jump", o.block.?);
    try std.testing.expectEqual(@as(u32, 14), p.origins[o.parent.?].line);
    try std.testing.expect(p.command == null);
}

test "an exact id goes before a pattern, wherever it is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\start db*
        \\    send a
        \\    expect b
        \\start db9
        \\    send c
        \\    expect d
        \\
    ;
    try std.testing.expectEqualStrings("c", (try testPlan(arena.allocator(), text, "db9")).steps[0].text);
    try std.testing.expectEqualStrings("a", (try testPlan(arena.allocator(), text, "db1")).steps[0].text);
}

test "values: quotes, comments, and percent signs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\start x
        \\    # a comment
        \\    send echo # not a comment
        \\    expect "100% \"done\" "
        \\    type %%i 50%
        \\    settle 200ms
        \\
    ;
    const p = try testPlan(arena.allocator(), text, "x");
    try std.testing.expectEqualStrings("echo # not a comment", p.steps[0].text);
    try std.testing.expectEqualStrings("100% \"done\" ", p.steps[1].alts[0].text);
    try std.testing.expectEqualStrings("%i 50%", p.steps[2].text);
    try std.testing.expectEqual(@as(u64, 200), p.steps[3].settle_ms);
}

test "failure texts leave out what the input or the check holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\start x
        \\    nofail command not found
        \\    fail Account locked
        \\    send grep "Permission denied" log
        \\    expect done
        \\    send ls missing
        \\    expect No such file or directory
        \\
    ;
    const p = try testPlan(arena.allocator(), text, "x");
    const has = struct {
        fn f(list: []const Pattern, t: []const u8) bool {
            for (list) |x| if (std.mem.eql(u8, x.text, t)) return true;
            return false;
        }
    }.f;
    try std.testing.expect(!has(p.steps[1].fails, "Permission denied"));
    try std.testing.expect(!has(p.steps[1].fails, "command not found"));
    try std.testing.expect(has(p.steps[1].fails, "Account locked"));
    try std.testing.expect(has(p.steps[1].fails, "Connection refused"));
    try std.testing.expect(!has(p.steps[3].fails, "No such file or directory"));

    // The same for a check before the first input.
    const first = try testPlan(arena.allocator(), "fail(re) ^locked\nstart y\n    expect No such file or directory\n", "y");
    try std.testing.expect(!has(first.steps[0].fails, "No such file or directory"));
    try std.testing.expect(first.needs_regex);
}

test "checks are optional, and a password follows its prompt's expect or answers a when" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\start x
        \\    expect   me@laptop$
        \\    send     cd /opt/app && pwd
        \\    expect   /opt/app
        \\    send     sudo -i
        \\    when     [sudo] password
        \\        secret $PW
        \\    expect   root@
        \\    send     make
        \\    send     tail -f log
        \\
    ;
    const p = try testPlan(arena.allocator(), text, "x");
    try std.testing.expectEqualStrings("cd /opt/app && pwd", p.steps[2].typed);
    try std.testing.expect(p.needs_echo);
    try std.testing.expectEqual(StepKind.secret, p.steps[4].whens[0].answer);
    try std.testing.expectEqualStrings("PW", p.secrets[0]);
    try std.testing.expectEqual(StepKind.send, p.steps[6].kind);
    try expectBad("start y\n    send sudo -i\n    secret\n    expect #\n", "y", "'secret' must follow the 'expect' of its password prompt");
    try expectBad("start y\n    send sudo -i\n    when Password\n    secret\n", "y", "must be indented deeper");
    try expectBad("start y\n    send sudo -i\n    secret hunter2\n", "y", "never the password itself");
    try std.testing.expectError(error.Bad, testPlan(arena.allocator(), "start y\n    use \" \"\n", "y"));

    // What --check points out, without refusing.
    const notes = try testPlan(arena.allocator(),
        \\start z
        \\    expect   me@j:~$
        \\    send     ssh db1
        \\    expect   db1
        \\    send     ssh d2
        \\    expect   $
        \\    send     cd /
        \\    send     sudo -i
        \\    expect   password:
        \\    secret
        \\    expect   ok
        \\    send     ls
        \\    expect   x
        \\    when     Q
        \\        send y
        \\    send     z
        \\
    , "z");
    const wanted = [_][]const u8{ "an error that names it", "part of the earlier prompt 'me@j:~$'", "no check comes before this command", "nothing watches for its question" };
    for (wanted) |w| {
        for (notes.notes) |n| {
            if (std.mem.indexOf(u8, n, w) != null) break;
        } else {
            std.debug.print("no note with '{s}'\n", .{w});
            return error.TestExpectedNote;
        }
    }
}

test "fail: for the file, a block, or one check, and regex anywhere a text is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\fail     Account locked
        \\nofail
        \\start db*
        \\    send     ssh %i
        \\    expect(re, 30s) ^%i:[~/]\w*\$ $
        \\    fail     me@jump
        \\    fail(re) ^Last login: .*1970
        \\    or(re)   a{2,3}
        \\    gone(re) ^Loading\.+$
        \\
    ;
    const p = try testPlan(arena.allocator(), text, "db.1");
    const e = p.steps[1];
    try std.testing.expectEqualStrings("^db\\.1:[~/]\\w*\\$ $", e.alts[0].text);
    try std.testing.expect(e.alts[0].regex and e.alts[1].regex and p.steps[2].alts[0].regex);
    try std.testing.expectEqual(@as(u64, 30_000), e.timeout_ms);
    try std.testing.expectEqual(@as(usize, 3), e.fails.len);
    try std.testing.expectEqualStrings("Account locked", e.fails[0].text);
    try std.testing.expectEqualStrings("me@jump", e.fails[1].text);
    try std.testing.expect(e.fails[2].regex);
    try std.testing.expect(p.needs_regex);
    // The file's fail lines reach every block; the gone has no own ones.
    try std.testing.expectEqual(@as(usize, 1), p.steps[2].fails.len);

    try expectBad("start x\n    send a\n    fail Nope\n    expect b\n", "x", "'fail' goes in one of three places");
    try expectBad("start x\n    send a\n    expect(re) a*\n", "x", "invalid regex 'a*': it matches an empty text");
    try expectBad("start x\n    send a\n    expect b\n    or(5s) c\n", "x", "'or' takes no time");
    try expectBad("start x\n    send a\n    settle(re) 1s\n", "x", "'settle' takes no 're'");
    const late = try parse(arena.allocator(), "start", "start x\n    send a\nfail late\n");
    try std.testing.expect(std.mem.indexOf(u8, late.blocks[0].problem.?.text, "before the first block") != null);
}

test "fail reaches the blocks a block uses, nofail stays in its own block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\steps inner
        \\    fail Account locked
        \\    nofail Sorry, try again
        \\    send a
        \\    expect b
        \\start x
        \\    fail Kaputt
        \\    nofail
        \\    use inner
        \\    send c
        \\    expect(3s) d
        \\
    ;
    const p = try testPlan(arena.allocator(), text, "x");
    const has = struct {
        fn f(list: []const Pattern, t: []const u8) bool {
            for (list) |x| if (std.mem.eql(u8, x.text, t)) return true;
            return false;
        }
    }.f;
    try std.testing.expect(has(p.steps[1].fails, "Account locked"));
    try std.testing.expect(!has(p.steps[1].fails, "Sorry, try again"));
    try std.testing.expect(!has(p.steps[3].fails, "Account locked"));
    // The bare nofail takes the built-in texts out of x's own checks only.
    try std.testing.expect(!has(p.steps[3].fails, "Permission denied"));
    try std.testing.expect(has(p.steps[1].fails, "Permission denied"));
    try std.testing.expect(has(p.steps[1].fails, "Kaputt") and has(p.steps[3].fails, "Kaputt"));
    try std.testing.expectEqual(default_timeout_ms, p.steps[1].timeout_ms);
    try std.testing.expectEqual(@as(u64, 3000), p.steps[3].timeout_ms);
}

test "parameters, ended, and the syntax kept for later" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\steps s v=%{id}
        \\    send echo %{v}
        \\    settle(1m) 2s
        \\start x
        \\    send a
        \\    expect(30s) (venv) me@host
        \\    use s
        \\    send exit 3
        \\    ended(5s) 3
        \\
    ;
    const p = try testPlan(arena.allocator(), text, "x");
    try std.testing.expectEqual(@as(u64, 30_000), p.steps[1].timeout_ms);
    try std.testing.expectEqualStrings("(venv) me@host", p.steps[1].alts[0].text);
    try std.testing.expectEqualStrings("echo x", p.steps[2].text);
    try std.testing.expectEqual(@as(u64, 60_000), p.steps[3].timeout_ms);
    try std.testing.expectEqual(@as(u64, 2000), p.steps[3].settle_ms);
    try std.testing.expectEqual(StepKind.ended, p.steps[5].kind);
    try std.testing.expectEqual(@as(?u8, 3), p.steps[5].status);
    try std.testing.expectEqual(@as(u64, 5000), p.steps[5].timeout_ms);

    const ok = "    send a\n    expect b\n";
    try expectBad("start x\n    send a\n    expect b\n    within 3s\n", "x", "'within' is gone");
    try expectBad("start x\n    send a\n    expect (30s) b\n", "x", "'(30s)' after a blank is text: write expect(30s)");
    _ = try testPlan(arena.allocator(), "start x\n    send a\n    expect (0) Exit\n", "x");
    try expectBad("start x\n    send a\n    expect(wild) b\n", "x", "unknown parameter 'wild'");
    try expectBad("start x\n    send(5s) a\n    expect b\n", "x", "'send' takes no parameters");
    try expectBad("start x\n    send \"a\\tb\"\n    expect b\n", "x", "a backslash comes only before");
    try expectBad("start x\n" ++ ok ++ "    nofail Nope\n", "x", "move it above line 2");
    try expectBad("start x\n    dir /a\n    dir /b\n" ++ ok, "x", "'dir' is given twice, at line 2");
    try expectBad("start x\n    send a\n    ended\n" ++ ok, "x", "'ended' must be the last step");
    try expectBad("start x\n    send a\n    ended zero\n", "x", "the exit status");
    const f = try parse(arena.allocator(), "start", "steps s id\n" ++ ok);
    try std.testing.expect(std.mem.indexOf(u8, f.blocks[0].problem.?.text, "cannot be named 'id'") != null);
}

test "when: where it stands, what it may answer, and how far it reaches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\steps sub
        \\    send ls
        \\    expect done
        \\start x
        \\    expect me@jump$
        \\    send ssh web1
        \\    when (yes/no)?
        \\        send yes
        \\    when Press RETURN
        \\        keys <Enter>
        \\    expect me@web1$
        \\    gone Loading
        \\    use sub
        \\
    ;
    const p = try testPlan(arena.allocator(), text, "x");
    try std.testing.expectEqual(@as(usize, 2), p.steps[2].whens.len);
    try std.testing.expectEqualStrings("(yes/no)?", p.steps[2].whens[0].pattern.text);
    try std.testing.expectEqualStrings("yes", p.steps[2].whens[0].answer_text);
    try std.testing.expectEqual(StepKind.keys, p.steps[2].whens[1].answer);
    // Every check up to the next input, but none of a used block; the
    // input before them watches too, in case no check follows.
    try std.testing.expectEqual(p.steps[2].whens.ptr, p.steps[3].whens.ptr);
    try std.testing.expectEqual(@as(usize, 2), p.steps[1].whens.len);
    try std.testing.expectEqual(@as(usize, 0), p.steps[5].whens.len);

    // A block may start with one, for the program's first questions.
    const first = try testPlan(arena.allocator(), "start y\n    when(re) ^Pick \\d:\n        send 1\n    expect ok$\n", "y");
    try std.testing.expect(first.steps[0].whens[0].pattern.regex);
    const head = "start x\n    expect me@jump$\n    send ssh web1\n";
    try expectBad(head ++ "    when Q\n    expect ok$\n", "x", "followed by its answer, a send, type, keys, or secret line, not 'expect'");
    try expectBad(head ++ "    when Q\n    send y\n    expect ok$\n", "x", "must be indented deeper");
    try expectBad(head ++ "    when(5s) Q\n        send y\n    expect ok$\n", "x", "'when' takes no time");
    // The old overlap refusals are gone.
    _ = try testPlan(arena.allocator(), head ++ "    when web1\n        send say ok$\n    expect ok$\n", "x");

    // do --use: the block starts at the prompt it is used at.
    const file = try arena.allocator().create(File);
    file.* = try parse(arena.allocator(), "start", text ++ "steps hop host\n    expect me@jump$\n    send ssh %{host}\n    expect me@%{host}$\n");
    const used = try planUse(arena.allocator(), file, "hop", &.{"db1"}, "s", null);
    try std.testing.expectEqualStrings("ssh db1", used.steps[1].text);
    try std.testing.expect(!used.steps[0].after_input);
    try std.testing.expectEqual(@as(usize, 0), used.steps[0].fails.len);
    try std.testing.expectError(error.Bad, planUse(arena.allocator(), file, "sub", &.{}, "s", null));
    try std.testing.expect(std.mem.indexOf(u8, badText(), "must start with an 'expect'") != null);
    try std.testing.expectError(error.Bad, planUse(arena.allocator(), file, "hop", &.{}, "s", null));
    try std.testing.expectError(error.Bad, planUse(arena.allocator(), file, "hop", &.{"db1\nrm -rf x"}, "s", null));
    try std.testing.expect(std.mem.indexOf(u8, badText(), "holds a line break") != null);
}

test "the rules that stay are about structure" {
    try expectBad("steps s\n    or b\nstart x\n    send a\n    expect c\n    use s\n", "x", "must follow an 'expect' of the same block");
    try expectBad("steps s\n    send a\n    expect c\nstart x\n    use s\n    or b\n", "x", "must follow an 'expect' of the same block");
    try expectBad("start x\n    send a\n    expect c\n    when q\n        send y\n    or b\n", "x", "must follow an 'expect' of the same block");
    try expectBad("start x\n    send a\n    ended\n    send b\n", "x", "'ended' must be the last step");
    try expectBad("start x\n    expect(re) a(\n", "x", "invalid regex");
}

test "use: arguments, defaults, cycles, and blocks that cannot be used" {
    try expectBad("steps s p\n    send %{p}\n    expect z\nstart x\n    use s\n", "x", "needs a value for its parameter 'p'");
    try expectBad("steps s\n    send a\n    expect z\nstart x\n    use s 1\n", "x", "takes 0 arguments");
    try expectBad("steps s\n    send %{q}\n    expect z\nstart x\n    use s\n", "x", "'%{q}' is no parameter");
    try expectBad("steps a\n    use b\nsteps b\n    use a\nstart x\n    use a\n", "x", "a -> b -> a");
    try expectBad("start j\n    size 80x24\n    send a\n    expect b\nstart x\n    use j\n", "x", "sets 'size'");
    try expectBad("start x\n    use nothing\n", "x", "no steps block");
    try expectBad("start x\n    expect %{p}\n", "x", "no parameter of a start block");
    try expectBad("steps s p=\n    send a\n    expect %{p}\nstart x\n    use s\n", "x", "'expect' needs a value, and its parameters put in none");
    const long: [max_text + 1]u8 = @splat('a');
    try expectBad("start x\n    send " ++ long ++ "\n", "x", "longer than 4096 bytes");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\start jump
        \\    send ssh jump
        \\    expect me@jump
        \\steps go host="%i.internal" greeting
        \\    send ssh %{host}
        \\    expect %{greeting}
        \\start db*
        \\    use jump
        \\    use go %i.lan "me@%i 100%"
        \\
    ;
    const p = try testPlan(arena.allocator(), text, "db1");
    try std.testing.expectEqualStrings("ssh db1.lan", p.steps[2].text);
    try std.testing.expectEqualStrings("me@db1 100%", p.steps[3].alts[0].text);
    try expectBad("steps go host=%i.internal\n    send ssh %{host}\n    expect ok\nstart db1\n    use go\n    use go a b\n", "db1", "takes 1 argument, not 2");
}

test "problems stay with their block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\start broken
        \\    sned typo
        \\start fine
        \\    send a
        \\    expect b
        \\start fine
        \\    send c
        \\    expect d
        \\  stray
        \\
    ;
    const file = try parse(arena.allocator(), "start", text);
    try std.testing.expect(file.blocks[0].problem != null);
    try std.testing.expect(file.blocks[1].problem == null);
    try std.testing.expect(file.blocks[2].problem != null);
    _ = try plan(arena.allocator(), &file, "fine");
    try expectBad(text, "broken", "unknown keyword 'sned'");
    try expectBad("start x\n    send a\n    expect(0s) b\n", "x", "more than 0");
    try expectBad("steps s\n    size 80x24\n", "s", "no start block");
    try expectBad("start x\n    send \"a\" b\n    expect c\n", "x", "nothing may follow the closing quote");
    const twice = try parse(arena.allocator(), "start", "start x y x\n    send a\n    expect b\n");
    try std.testing.expect(std.mem.indexOf(u8, twice.blocks[0].problem.?.text, "'x' is named twice") != null);
}

test "a group names ids that start blocks have, on its own line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try parse(a, "start", "start web db*\n    send a\n    expect b\ngroup dev web db7\n");
    try std.testing.expect(good.blocks[1].problem == null);
    try std.testing.expectEqualStrings("db7", good.groupFor("dev").?.names[2]);
    const cases = [_]struct { text: []const u8, want: []const u8 }{
        .{ .text = "group dev db*\n", .want = "is a pattern" },
        .{ .text = "group dev web web\n", .want = "in the group twice" },
        .{ .text = "group dev web api\n", .want = "no start block for 'api'" },
        .{ .text = "group dev web\ngroup all dev\n", .want = "a group holds ids, not groups" },
        .{ .text = "group web db7\n", .want = "'web' is already a start id" },
        .{ .text = "group dev web\n    send x\n", .want = "has no steps" },
    };
    for (cases) |c| {
        const file = try parse(a, "start", try std.mem.concat(a, u8, &.{ "start web db*\n    send a\n    expect b\n", c.text }));
        const b = file.blocks[file.blocks.len - 1];
        if (b.problem == null or std.mem.indexOf(u8, b.problem.?.text, c.want) == null) {
            std.debug.print("{s}: {?s}\n", .{ c.text, if (b.problem) |p| p.text else null });
            return error.TestUnexpectedResult;
        }
    }
    try expectBad("start web\n    send a\n    expect b\n    use dev\ngroup dev web\n", "web", "that is a group");
    const broken = try parse(a, "start", "start d*\n    send a\n    expect b\ngroup dbs db1 db*\n");
    try std.testing.expect(broken.groupFor("dbs").?.problem != null);
}
