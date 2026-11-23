//! For tests of clients against a daemon that is not trusted: the lines
//! it may send instead of its replies, statuses, and frames, and an
//! allocator that tells when they made a client allocate without bound.

const std = @import("std");
const status = @import("status.zig");

/// In a template, each `$value$` is a value that may be swapped for an
/// odd one.
const status_tpl = "{\"id\":$3$,\"name\":$\"build\"$,\"state\":$\"running\"$,\"pid\":$42$,\"argv\":$[\"sh\",\"-c\",\"make\"]$," ++
    "\"cols\":$80$,\"rows\":$24$,\"started_ms\":$1700000000000$,\"ended_ms\":$null$," ++
    "\"exit\":{\"code\":$null$,\"signal\":$null$,\"stopped\":$false$},\"seq\":$7$,\"title\":$\"vim\"$," ++
    "\"cwd\":{\"path\":$\"/tmp\"$,\"host\":$null$},\"writer\":{\"label\":$\"pts/3\"$},\"viewers\":$1$," ++
    "\"bell_count\":$2$,\"notification\":{\"title\":$null$,\"text\":$\"done\"$,\"at_ms\":$1$},\"seen\":{\"seq\":$1$}," ++
    "\"hit_alerts\":$[]$,\"over\":$null$,\"under\":$[]$,\"damaged\":$null$}";

/// What the line stands for.
pub const Kind = enum { reply, list, frame, event };

const replies = [_][]const u8{
    "{\"ok\":$true$,\"status\":" ++ status_tpl ++ "}",
    "{\"ok\":$false$,\"code\":$\"busy\"$,\"err\":$\"another client controls the session\"$}",
    "{\"ok\":$false$,\"code\":$\"bad_request\"$,\"err\":$\"unknown field\"$,\"status\":$null$}",
};

const lists = [_][]const u8{
    "{\"ok\":$true$,\"sessions\":[" ++ status_tpl ++ "," ++ status_tpl ++ "]}",
    "{\"ok\":$true$,\"sessions\":$[]$}",
};

const frames = [_][]const u8{
    // ESC c, then "hi".
    "{\"screen\":$\"G2NoaQ==\"$}",
    "{\"out\":$\"aGkNCg==\"$}",
    "{\"resize\":{\"cols\":$100$,\"rows\":$30$,\"seq\":$5$}}",
    "{\"exit\":{\"code\":$0$,\"signal\":$null$},\"status\":" ++ status_tpl ++ "}",
    "{\"exit\":{\"code\":$null$,\"signal\":$\"SIGKILL\"$}}",
    "{\"writer\":$\"taken\"$}",
    "{\"hold\":$true$}",
    "{\"error\":{\"code\":$\"bad_request\"$,\"err\":$\"unknown frame\"$}}",
    "{\"end\":{\"reason\":$\"too_slow\"$}}",
    "{\"status\":" ++ status_tpl ++ "}",
};

const events = [_][]const u8{
    "{\"type\":$\"changed\"$,\"id\":$5$,\"status\":" ++ status_tpl ++ "}",
    "{\"type\":$\"synced\"$}",
    "{\"type\":$\"removed\"$,\"id\":$5$,\"status\":$null$}",
};

const odd = [_][]const u8{
    "null",                                   "true",                                "false",                                     "0",
    "-1",                                     "1.5",                                 "1e309",                                     "-1e309",
    "255",                                    "256",                                 "65535",                                     "65536",
    "4294967296",                             "18446744073709551615",                "18446744073709551616",                      "-9223372036854775809",
    "\"\"",                                   "\"x\"",                               "\"!!!!\"",                                  "\"A\"",
    "\"====\"",                               "\"QQ\"",                              "\"SIG255\"",                                "\"SIG200\"",
    "\"SIG\"",                                "\"exited\"",                          "\"broken\"",                                "\"\\ud800\"",
    "\"\\u001b]52;c;aGk=\\u0007\\u001b[2J\"", "\"\\u009b31m\\u202e\\u2066\\u0085\"", "[]",                                        "{}",
    "[1,\"a\",null]",                         "{\"x\":{\"y\":[null]}}",              "[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]", "\"" ++ repeat("a", 5000) ++ "\"",
    "\"" ++ repeat("AAAA", 1000) ++ "\"",
};

fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime {
        @setEvalBranchQuota(n * 2);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const done = out;
        return &done;
    }
}

const inserts = [_][]const u8{ ",\"zz\":1", "}", "{", "\"", "\\", ",", ":", "[", "]", "\\u0000", "\xff", "\xc3", "\x1b" };

/// A line in `out` for `kind`: a template with odd values, often mutated
/// further, or now and then bytes at random. It holds no newline.
pub fn line(rand: std.Random, kind: Kind, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    out.clearRetainingCapacity();
    if (rand.uintLessThan(u8, 20) == 0) {
        const n = rand.uintLessThan(usize, 300);
        try out.ensureUnusedCapacity(gpa, n);
        for (0..n) |_| out.appendAssumeCapacity(rand.int(u8));
    } else {
        const templates: []const []const u8 = switch (kind) {
            .reply => &replies,
            .list => &lists,
            .frame => &frames,
            .event => &events,
        };
        try expand(rand, templates[rand.uintLessThan(usize, templates.len)], out, gpa);
        if (rand.uintLessThan(u8, 3) == 0) for (0..1 + rand.uintLessThan(usize, 3)) |_| try mutate(rand, out, gpa);
    }
    for (out.items) |*b| if (b.* == '\n') {
        b.* = ' ';
    };
}

fn expand(rand: std.Random, template: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var rest = template;
    while (std.mem.indexOfScalar(u8, rest, '$')) |start| {
        try out.appendSlice(gpa, rest[0..start]);
        const len = std.mem.indexOfScalar(u8, rest[start + 1 ..], '$').?;
        const value = rest[start + 1 ..][0..len];
        try out.appendSlice(gpa, if (rand.uintLessThan(u8, 4) == 0) odd[rand.uintLessThan(usize, odd.len)] else value);
        rest = rest[start + 1 + len + 1 ..];
    }
    try out.appendSlice(gpa, rest);
}

fn mutate(rand: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    if (out.items.len == 0) return;
    const at = rand.uintLessThan(usize, out.items.len);
    switch (rand.uintLessThan(u8, 4)) {
        0 => out.shrinkRetainingCapacity(at),
        1 => out.items[at] = rand.int(u8),
        2 => try out.insertSlice(gpa, at, inserts[rand.uintLessThan(usize, inserts.len)]),
        else => {
            const len = @min(out.items.len - at, rand.uintLessThan(usize, 64));
            const copy = try gpa.dupe(u8, out.items[at..][0..len]);
            defer gpa.free(copy);
            try out.insertSlice(gpa, at, copy);
        },
    }
}

/// An allocator that refuses any allocation that would take what is
/// held past `limit` bytes, and remembers that one was.
pub const Bounded = struct {
    child: std.mem.Allocator,
    limit: usize,
    held: usize = 0,
    exceeded: bool = false,

    pub fn allocator(b: *Bounded) std.mem.Allocator {
        return .{ .ptr = b, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn take(b: *Bounded, more: usize) bool {
        if (b.held + more > b.limit) {
            b.exceeded = true;
            return false;
        }
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const b: *Bounded = @ptrCast(@alignCast(ctx));
        if (!b.take(len)) return null;
        const p = b.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        b.held += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const b: *Bounded = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !b.take(new_len - memory.len)) return false;
        if (!b.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        b.held = b.held - memory.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const b: *Bounded = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !b.take(new_len - memory.len)) return null;
        const p = b.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        b.held = b.held - memory.len + new_len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const b: *Bounded = @ptrCast(@alignCast(ctx));
        b.child.rawFree(memory, alignment, ret_addr);
        b.held -= memory.len;
    }
};

/// Whether `text` has no control characters but line ends: what a
/// client may print of text that came from the daemon.
pub fn printable(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| if (cp != '\n' and cp != '\r' and status.isControl(cp)) return false;
    return true;
}
