//! Keeps the user's terminal from talking back to the session during
//! `tuppet attach`. The daemon already answers every query the program
//! sends and reports size changes to it; if the user's terminal answered
//! too, its replies would reach the program a second time, or the shell
//! once the attach has ended. So before session output is shown, this
//! removes queries, window operations, kitty graphics, and the modes
//! that make a terminal send reports on its own (in-band resize 2048,
//! color scheme updates 2031).
//!
//! Sequences are delimited the way a terminal's parser delimits them:
//! control characters inside a sequence are executed without ending it,
//! CAN and SUB abort it, ESC starts a new one, and strings (OSC, DCS,
//! APC, PM, SOS) end with ST or BEL. An aborted sequence has no effect
//! on a terminal, so it is dropped, apart from the control characters it
//! carried; passing it on could join it with what follows a removed
//! query.

const std = @import("std");

/// A sequence still unfinished at this size stops being held back: a
/// string that would be removed is discarded up to its end, anything
/// else is passed on.
const max_pending = 64 * 1024;

/// Modes whose reports the daemon sends itself.
const reporting_modes = [_][]const u8{ "2031", "2048" };

pub const Filter = struct {
    /// The unfinished escape sequence the previous chunk ended in.
    pending: std.ArrayList(u8) = .empty,
    /// Where scanning `pending` resumes.
    scanned: usize = 1,
    /// Discarding an oversized string up to its terminator.
    discarding: bool = false,
    /// While discarding: the previous chunk ended in ESC.
    discard_esc: bool = false,
    /// Keep the terminal on the alternate screen it is on: drop screen
    /// switches (modes 47, 1047, 1049) and turn a full reset into a soft
    /// reset and clear, which do not leave it.
    stay_on_screen: bool = false,

    pub fn deinit(self: *Filter, gpa: std.mem.Allocator) void {
        self.pending.deinit(gpa);
    }

    /// Filter the next chunk of session output. The caller frees the
    /// result.
    pub fn feed(self: *Filter, gpa: std.mem.Allocator, chunk: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var input = chunk;
        if (self.discarding) input = input[try self.skipDiscarded(gpa, input)..];

        // Bytes that followed a held sequence once it is resolved.
        var rest: ?[]u8 = null;
        defer if (rest) |r| gpa.free(r);
        if (self.pending.items.len > 0) {
            try self.pending.appendSlice(gpa, input);
            const held = self.pending.items;
            switch (scan(held, self.scanned)) {
                .incomplete => |at| {
                    self.scanned = at;
                    try self.limitPending(gpa, &out);
                    return out.toOwnedSlice(gpa);
                },
                inline .complete, .aborted => |len, result| {
                    try emit(gpa, &out, held[0..len], result == .complete, self.stay_on_screen);
                    rest = try gpa.dupe(u8, held[len..]);
                    self.pending.clearRetainingCapacity();
                    input = rest.?;
                },
            }
        }

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] != 0x1b) {
                const end = std.mem.indexOfScalarPos(u8, input, i, 0x1b) orelse input.len;
                try out.appendSlice(gpa, input[i..end]);
                i = end;
                continue;
            }
            const seq = input[i..];
            switch (scan(seq, 1)) {
                inline .complete, .aborted => |len, result| {
                    try emit(gpa, &out, seq[0..len], result == .complete, self.stay_on_screen);
                    i += len;
                },
                .incomplete => |at| {
                    try self.pending.appendSlice(gpa, seq);
                    self.scanned = at;
                    try self.limitPending(gpa, &out);
                    break;
                },
            }
        }
        return out.toOwnedSlice(gpa);
    }

    fn limitPending(self: *Filter, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (self.pending.items.len <= max_pending) return;
        if (removedWhole(self.pending.items)) {
            self.discarding = true;
            self.discard_esc = false;
        } else {
            try out.appendSlice(gpa, self.pending.items);
        }
        self.pending.clearRetainingCapacity();
    }

    /// Skip the rest of a discarded string. Returns where its terminator
    /// ends, or `bytes.len` while it continues.
    fn skipDiscarded(self: *Filter, gpa: std.mem.Allocator, bytes: []const u8) !usize {
        if (self.discard_esc and bytes.len > 0) {
            self.discard_esc = false;
            self.discarding = false;
            if (bytes[0] == '\\') return 1;
            // That ESC starts a new sequence.
            try self.pending.append(gpa, 0x1b);
            self.scanned = 1;
            return 0;
        }
        for (bytes, 0..) |c, j| switch (c) {
            0x07, 0x18, 0x1a => {
                self.discarding = false;
                return j + 1;
            },
            0x1b => {
                if (j + 1 == bytes.len) {
                    self.discard_esc = true;
                    return bytes.len;
                }
                self.discarding = false;
                // ST ends the string; any other ESC starts a new sequence.
                return if (bytes[j + 1] == '\\') j + 2 else j;
            },
            else => {},
        };
        return bytes.len;
    }
};

const Scan = union(enum) {
    /// The sequence's length.
    complete: usize,
    /// The length a terminal discards, cut short by CAN, SUB, ESC, or a
    /// byte that cannot appear in the sequence.
    aborted: usize,
    /// The sequence continues past the end; scanning resumes here.
    incomplete: usize,
};

fn isString(intro: u8) bool {
    return std.mem.indexOfScalar(u8, "]P_^X", intro) != null;
}

/// A control character that a terminal executes in the middle of a
/// sequence without ending it.
fn isExecuted(c: u8) bool {
    return (c < 0x20 and c != 0x18 and c != 0x1a and c != 0x1b) or c == 0x7f;
}

/// The index of the byte after ESC that decides the sequence's kind: the
/// first one that is not an executed control.
fn introIndex(s: []const u8) usize {
    var k: usize = 1;
    while (k < s.len and isExecuted(s[k])) k += 1;
    return k;
}

/// Delimit the escape sequence at the start of `s`, scanning from `from`
/// (at least 1).
fn scan(s: []const u8, from: usize) Scan {
    const k = introIndex(s);
    const intro: u8 = if (k < s.len) s[k] else 0;
    const string = isString(intro);
    var j = from;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        switch (c) {
            0x18, 0x1a => return .{ .aborted = j + 1 },
            0x1b => {
                if (string and j > k) {
                    if (j + 1 >= s.len) return .{ .incomplete = j };
                    if (s[j + 1] == '\\') return .{ .complete = j + 2 };
                }
                return .{ .aborted = j };
            },
            0x07 => if (string and j > k) return .{ .complete = j + 1 },
            0x00...0x06, 0x08...0x17, 0x19, 0x1c...0x1f, 0x7f => {},
            else => {
                if (string and j > k) continue;
                // C1 controls cannot appear inside a sequence; some
                // terminals would start a new one, so drop them with it.
                if (c >= 0x80) return .{ .aborted = if (c <= 0x9f) j + 1 else j };
                if (j == k and (string or c == '[')) continue;
                const csi = intro == '[' and j > k;
                if (c >= 0x20 and c <= (if (csi) @as(u8, 0x3f) else 0x2f)) continue;
                return .{ .complete = j + 1 };
            },
        }
    }
    return .{ .incomplete = j };
}

/// Whether a sequence, finished or not, is a string that is removed
/// whatever its end holds.
fn removedWhole(seq: []const u8) bool {
    const k = introIndex(seq);
    if (k >= seq.len) return false;
    const text = seq[k + 1 ..];
    return seq[k] == '_' or (seq[k] == 'P' and (std.mem.startsWith(u8, text, "+q") or std.mem.startsWith(u8, text, "$q")));
}

/// Append a delimited sequence to `out`, or only the control characters a
/// terminal executes inside it when the sequence is removed or aborted.
fn emit(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seq: []const u8, complete: bool, stay: bool) !void {
    const k = introIndex(seq);
    const string = k < seq.len and isString(seq[k]);
    // Executed controls go out first, ahead of the sequence they were
    // found in; strings ignore controls in their text.
    var stack = std.heap.stackFallback(256, gpa);
    const scratch = stack.get();
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(scratch);
    try clean.append(scratch, 0x1b);
    for (seq[1..], 1..) |c, i| {
        if ((i < k or !string) and isExecuted(c)) {
            if (c != 0x7f) try out.append(gpa, c);
        } else if (c != 0x18 and c != 0x1a) {
            try clean.append(scratch, c);
        }
    }
    if (!complete) return;
    const s = clean.items;
    switch (s[1]) {
        '[' => return emitCsi(gpa, out, s, stay),
        ']' => if (isOscQuery(stringBody(s))) return,
        'P' => if (removedWhole(s)) return,
        '_' => return,
        // DECID
        'Z' => if (s.len == 2) return,
        // RIS
        'c' => if (s.len == 2 and stay) return out.appendSlice(gpa, "\x1b[!p\x1b[0m\x1b[H\x1b[2J"),
        else => {},
    }
    try out.appendSlice(gpa, s);
}

fn emitCsi(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seq: []const u8, stay: bool) !void {
    const final = seq[seq.len - 1];
    var body = seq[2 .. seq.len - 1];
    const prefix: u8 = if (body.len > 0 and body[0] >= '<' and body[0] <= '?') body[0] else 0;
    if (prefix != 0) body = body[1..];
    var split = body.len;
    while (split > 0 and body[split - 1] >= 0x20 and body[split - 1] <= 0x2f) split -= 1;
    const params = body[0..split];
    const intermediates = body[split..];
    const plain = intermediates.len == 0;

    if (prefix == '?' and plain and std.mem.indexOfScalar(u8, "hlsr", final) != null) {
        return emitModes(gpa, out, params, final, stay);
    }
    const removed = switch (final) {
        // DA1, DA2, DA3
        'c' => plain and (prefix == 0 or prefix == '>' or prefix == '='),
        // DSR, including cursor position and color scheme
        'n' => plain and (prefix == 0 or prefix == '?'),
        // DECRQM, DECRQPSR
        'p', 'w' => std.mem.eql(u8, intermediates, "$"),
        // XTVERSION
        'q' => plain and prefix == '>',
        // Kitty keyboard flags query
        'u' => plain and prefix == '?',
        // Window operations and reports; the title stack (22, 23) stays.
        't' => plain and prefix == 0 and !isTitleStack(params),
        // XTSMGRAPHICS, XTQMODKEYS
        'S', 'm' => plain and prefix == '?',
        // DECREQTPARM
        'x' => plain and prefix == 0 and params.len <= 1,
        else => false,
    };
    if (!removed) try out.appendSlice(gpa, seq);
}

fn emitModes(gpa: std.mem.Allocator, out: *std.ArrayList(u8), params: []const u8, final: u8, stay: bool) !void {
    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(gpa);
    var modes = std.mem.splitScalar(u8, params, ';');
    while (modes.next()) |mode| {
        const reporting = for (reporting_modes) |m| {
            if (std.mem.eql(u8, mode, m)) break true;
        } else false;
        if (reporting) continue;
        const screen_switch = std.mem.eql(u8, mode, "47") or std.mem.eql(u8, mode, "1047") or std.mem.eql(u8, mode, "1049");
        if (stay and screen_switch) continue;
        if (kept.items.len > 0) try kept.append(gpa, ';');
        try kept.appendSlice(gpa, mode);
    }
    // A list of only reporting modes is dropped; an empty one stays.
    if (kept.items.len == 0 and params.len > 0) return;
    try out.print(gpa, "\x1b[?{s}{c}", .{ kept.items, final });
}

fn isTitleStack(params: []const u8) bool {
    const op = std.mem.sliceTo(params, ';');
    return std.mem.eql(u8, op, "22") or std.mem.eql(u8, op, "23");
}

/// Color, palette, pointer, and clipboard queries put "?" where a value
/// would go; kitty's color and notification protocols use "key=?".
fn isOscQuery(body: []const u8) bool {
    const number = std.fmt.parseInt(u16, std.mem.sliceTo(body, ';'), 10) catch return false;
    switch (number) {
        4, 5, 10...19, 22, 52 => {
            var fields = std.mem.splitScalar(u8, body, ';');
            while (fields.next()) |field| if (std.mem.eql(u8, field, "?")) return true;
            return false;
        },
        21, 99 => return std.mem.indexOf(u8, body, "=?") != null,
        else => return false,
    }
}

fn stringBody(seq: []const u8) []const u8 {
    const body = seq[2..];
    if (std.mem.endsWith(u8, body, "\x1b\\")) return body[0 .. body.len - 2];
    if (std.mem.endsWith(u8, body, "\x07")) return body[0 .. body.len - 1];
    return body;
}

fn filterChunks(gpa: std.mem.Allocator, chunks: []const []const u8) ![]u8 {
    var filter: Filter = .{};
    defer filter.deinit(gpa);
    var got: std.ArrayList(u8) = .empty;
    errdefer got.deinit(gpa);
    for (chunks) |chunk| {
        const out = try filter.feed(gpa, chunk);
        defer gpa.free(out);
        try got.appendSlice(gpa, out);
    }
    return got.toOwnedSlice(gpa);
}

fn expectFiltered(chunks: []const []const u8, want: []const u8) !void {
    const got = try filterChunks(std.testing.allocator, chunks);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "queries are removed and everything else passes" {
    // vim's startup and exit: DA1, XTGETTCAP, the title stack, and modes.
    try expectFiltered(
        &.{"\x1b[chi\x1bP+q4D73\x1b\\\x1b[22;0t\x1b[?1049h\x1b[31mx\x1b[0m\x1b[23;0t\x1b[?1004l\x1b[c"},
        "hi\x1b[22;0t\x1b[?1049h\x1b[31mx\x1b[0m\x1b[23;0t\x1b[?1004l",
    );
    try expectFiltered(&.{"\x1b[6n\x1b[?u\x1b[>q\x1b[?2026$p\x1b[18t\x1b]11;?\x07\x1b]4;1;?\x1b\\\x1b_Gi=1,a=q;\x1b\\\x1bZ\x1b]21;foreground=?\x07ok"}, "ok");
    // Not queries: kitty flag changes, titles (even "?"), cursor style,
    // keypad, charset, an empty mode list, DECCARA, and DECSWBV.
    const passing = "\x1b[>1u\x1b[<u\x1b]0;title\x07\x1b]2;?\x07\x1b[2 q\x1b>\x1b(B\x1b[?h\x1b[1;1;5;5;1$t\x1b[3 t";
    try expectFiltered(&.{passing}, passing);
}

test "reporting modes are removed from mode changes" {
    try expectFiltered(&.{"\x1b[?2048h\x1b[?1049;2048;2004h\x1b[?2031l\x1b[?2048s\x1b[?2048\rh"}, "\x1b[?1049;2004h\r");
}

test "aborted sequences are dropped, keeping the controls they carried" {
    // A wrapped query inside tmux passthrough leaves no open string.
    try expectFiltered(&.{"\x1bPtmux;\x1b\x1b[c\x1b\\A"}, "\x1b\\A");
    // A cut-short sequence cannot join what follows a removed query.
    try expectFiltered(&.{"\x1b[>\x1b[?2048hc\x1b[6\r\x1b]11;?\x07n"}, "c\rn");
    // CAN aborts; a control inside a query still takes effect; C1 inside
    // a sequence is dropped with it.
    try expectFiltered(&.{"a\x1b[6\x18n\x1b[6\rnb\x1b\x9b6n"}, "an\rb6n");
    // Controls between ESC and the sequence's kind are executed too.
    try expectFiltered(&.{"\x1b\r[6nx\x1b\r[31my"}, "\rx\r\x1b[31my");
}

test "staying on the alternate screen drops screen switches and full resets" {
    const gpa = std.testing.allocator;
    var filter: Filter = .{ .stay_on_screen = true };
    defer filter.deinit(gpa);
    const out = try filter.feed(gpa, "\x1b[?1049;25h\x1bca\x1b[?47l");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("\x1b[?25h\x1b[!p\x1b[0m\x1b[H\x1b[2Ja", out);
}

test "a sequence split across chunks is held until it is complete" {
    try expectFiltered(&.{ "a\x1b", "[", "c", "b\x1b[3", "1mc" }, "ab\x1b[31mc");
    try expectFiltered(&.{ "\x1b]11;", "?\x1b", "\\x" }, "x");
}

test "an oversized string is discarded when removed and passed otherwise" {
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, max_pending + 10);
    defer gpa.free(big);
    @memset(big, 'A');
    try expectFiltered(&.{ "\x1b_Ga=T;", big, big, "\x1b\\ok" }, "ok");
    try expectFiltered(&.{ "\x1b_Ga=T;", big, "\x1b", "[1mok" }, "\x1b[1mok");
    const got = try filterChunks(gpa, &.{ "\x1b]52;c;", big, "\x07ok" });
    defer gpa.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "\x1b]52;c;AAA"));
    try std.testing.expect(std.mem.endsWith(u8, got, "\x07ok"));
}

test "output does not depend on how it is split into chunks" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x747570);
    const random = prng.random();
    const alphabet = "\x1b\x1b\x1b[[]P_\\?;>=$12046ctnhpqu\x07\x18\r\x9babc";
    var stream: [400]u8 = undefined;
    for (0..100) |_| {
        for (&stream) |*b| b.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const whole = try filterChunks(gpa, &.{&stream});
        defer gpa.free(whole);
        var chunks: std.ArrayList([]const u8) = .empty;
        defer chunks.deinit(gpa);
        var at: usize = 0;
        while (at < stream.len) {
            const n = @min(stream.len - at, 1 + random.uintLessThan(usize, 8));
            try chunks.append(gpa, stream[at .. at + n]);
            at += n;
        }
        const split = try filterChunks(gpa, chunks.items);
        defer gpa.free(split);
        try std.testing.expectEqualStrings(whole, split);
    }
}
