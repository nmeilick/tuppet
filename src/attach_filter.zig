//! Keeps the user's terminal from talking back to the session during
//! `tuppet attach`. The daemon already answers every query the program
//! sends and reports size changes to it; if the user's terminal answered
//! too, its replies would reach the program a second time, or the shell
//! once the attach has ended. So before session output is shown, this
//! removes queries, ENQ, window operations, kitty graphics, kitty
//! clipboard and drag and drop requests, and the modes that make a
//! terminal send reports on its own (in-band resize 2048, color scheme
//! updates 2031, kitty paste events 5522). A full reset (RIS) becomes a
//! soft reset and a cleared screen, which keep the terminal's history.
//!
//! Sequences are delimited the way a terminal's parser delimits them:
//! control characters inside a sequence are executed without ending it,
//! CAN and SUB abort it, ESC starts a new one, and strings (OSC, DCS,
//! APC, PM, SOS) end with ST or BEL. An aborted sequence has no effect
//! on a terminal, so it is dropped, apart from the control characters it
//! carried; passing it on could join it with what follows a removed
//! query. Parameters are compared by value, as a terminal reads them:
//! leading zeros and sub-parameters do not hide a mode or a query.
//!
//! The user's terminal is assumed to decode UTF-8, and it is kept that
//! way. Some terminals act on C1 controls encoded in UTF-8, so the
//! encoded sequence introducers (DCS, SOS, CSI, OSC, PM, APC), ST, and
//! DECID are rewritten to their ESC forms and filtered like them. A raw byte
//! 0x80..0x9f that does not continue a UTF-8 character becomes U+FFFD,
//! so it can never act as a C1 control, and character set changes that
//! could leave UTF-8 (ESC %) are removed.
//!
//! The result does not depend on how the output is split into chunks.

const std = @import("std");

/// A sequence that reaches this size unfinished is cut there: anything
/// but a string is aborted; a string that would be removed is discarded
/// up to its end, and any other string is passed on. Whether it is
/// removed is decided from what has arrived: APC, DCS queries, OSC color
/// queries, and kitty clipboard and drag and drop requests always are,
/// and OSC 52 when it asks for the clipboard.
const max_pending = 64 * 1024;

/// Modes whose reports the daemon sends itself, and kitty paste events,
/// which it does not support.
const reporting_modes = [_]u32{ 2031, 2048, 5522 };

/// Modes that switch between the main and the alternate screen.
const screen_modes = [_]u32{ 47, 1047, 1049 };

const replacement_char = "\xef\xbf\xbd";

pub const Filter = struct {
    /// The unfinished escape sequence the previous chunk ended in.
    pending: std.ArrayList(u8) = .empty,
    /// Where scanning `pending` resumes.
    scanned: usize = 1,
    /// Discarding an oversized string up to its terminator.
    discarding: bool = false,
    /// While discarding: the previous chunk ended in ESC.
    discard_esc: bool = false,
    /// Continuation bytes the current UTF-8 character still needs.
    utf8_left: u2 = 0,
    /// The range the next continuation byte must be in; narrower than
    /// 0x80..0xbf after some lead bytes, which UTF-8 restricts.
    utf8_min: u8 = 0x80,
    utf8_max: u8 = 0xbf,
    /// The previous chunk ended in 0xc2, which may encode a C1 control.
    held_c2: bool = false,
    /// Keep the terminal on the alternate screen it is on: drop screen
    /// switches (modes 47, 1047, 1049).
    stay_on_screen: bool = false,
    /// The session's output switched the terminal to the alternate
    /// screen, and not back yet.
    alt_screen: bool = false,
    /// Before the first full reset, scroll this many rows into the
    /// terminal's history, so what it showed before the attach is kept.
    history_rows: u16 = 0,

    pub fn deinit(self: *Filter, gpa: std.mem.Allocator) void {
        self.pending.deinit(gpa);
    }

    /// Whether the output so far ends between sequences and characters,
    /// where this terminal can be written to.
    pub fn idle(self: *const Filter) bool {
        return self.pending.items.len == 0 and !self.discarding and self.utf8_left == 0 and !self.held_c2;
    }

    /// Filter the next chunk of session output. The caller frees the
    /// result.
    pub fn feed(self: *Filter, gpa: std.mem.Allocator, chunk: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const decoded = try self.decode(gpa, chunk);
        defer gpa.free(decoded);
        var input: []const u8 = decoded;
        if (self.discarding) input = input[try self.skipDiscarded(gpa, input)..];

        // Bytes that followed a held sequence once it is resolved.
        var rest: ?[]u8 = null;
        defer if (rest) |r| gpa.free(r);
        if (self.pending.items.len > 0) {
            try self.pending.appendSlice(gpa, input);
            const held = self.pending.items;
            const len = try self.resolve(gpa, &out, held, self.scanned) orelse return out.toOwnedSlice(gpa);
            rest = try gpa.dupe(u8, held[len..]);
            self.pending.clearRetainingCapacity();
            input = rest.?;
        }

        var i: usize = 0;
        while (i < input.len) {
            if (self.discarding) {
                i += try self.skipDiscarded(gpa, input[i..]);
                continue;
            }
            if (input[i] != 0x1b) {
                const end = std.mem.indexOfScalarPos(u8, input, i, 0x1b) orelse input.len;
                try appendText(gpa, &out, input[i..end]);
                i = end;
                continue;
            }
            const seq = input[i..];
            i += try self.resolve(gpa, &out, seq, 1) orelse {
                try self.pending.appendSlice(gpa, seq);
                break;
            };
        }
        return out.toOwnedSlice(gpa);
    }

    /// Filter the escape sequence at the start of `seq` into `out`, and
    /// return its length; null while it continues past the end.
    fn resolve(self: *Filter, gpa: std.mem.Allocator, out: *std.ArrayList(u8), seq: []const u8, from: usize) !?usize {
        switch (scan(seq, from)) {
            inline .complete, .aborted => |len, result| {
                try emit(self, gpa, out, seq[0..len], result == .complete);
                return len;
            },
            .oversized => |len| {
                var stack_buf: [256]u8 = undefined;
                var stack: std.heap.BufferFirstAllocator = .init(&stack_buf, gpa);
                const scratch = stack.allocator();
                var clean: std.ArrayList(u8) = .empty;
                defer clean.deinit(scratch);
                try splitControls(gpa, out, scratch, &clean, seq[0..len]);
                const body = try ignoredRemoved(scratch, clean.items[2..]);
                defer scratch.free(body);
                if (removedString(clean.items[1], body, false)) {
                    self.discarding = true;
                    self.discard_esc = false;
                } else {
                    try out.appendSlice(gpa, clean.items);
                }
                return len;
            },
            .incomplete => |at| {
                self.scanned = at;
                return null;
            },
        }
    }

    /// Make the chunk well-behaved for a UTF-8 terminal: encoded C1
    /// introducers and ST become their ESC forms, and raw C1 bytes become
    /// U+FFFD. The caller frees the result.
    fn decode(self: *Filter, gpa: std.mem.Allocator, chunk: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = try .initCapacity(gpa, chunk.len + 1);
        errdefer out.deinit(gpa);
        for (chunk) |c| {
            if (self.held_c2) {
                self.held_c2 = false;
                switch (c) {
                    0x90, 0x98, 0x9a...0x9f => {
                        try out.appendSlice(gpa, &.{ 0x1b, c - 0x40 });
                        continue;
                    },
                    0x80...0x8f, 0x91...0x97, 0x99, 0xa0...0xbf => {
                        try out.appendSlice(gpa, &.{ 0xc2, c });
                        continue;
                    },
                    // Not a character after all; `c` starts afresh.
                    else => try out.append(gpa, 0xc2),
                }
            }
            switch (c) {
                0x80...0xbf => if (self.utf8_left > 0 and c >= self.utf8_min and c <= self.utf8_max) {
                    self.utf8_left -= 1;
                    self.utf8_min = 0x80;
                    self.utf8_max = 0xbf;
                    try out.append(gpa, c);
                } else {
                    // Not a continuation: the character is broken, and
                    // the byte stands alone.
                    self.utf8_left = 0;
                    try out.appendSlice(gpa, if (c <= 0x9f) replacement_char else &.{c});
                },
                0xc2 => {
                    self.utf8_left = 0;
                    self.held_c2 = true;
                },
                0xc3...0xf4 => {
                    self.utf8_left = if (c < 0xe0) 1 else if (c < 0xf0) 2 else 3;
                    self.utf8_min = switch (c) {
                        0xe0 => 0xa0,
                        0xf0 => 0x90,
                        else => 0x80,
                    };
                    self.utf8_max = switch (c) {
                        0xed => 0x9f,
                        0xf4 => 0x8f,
                        else => 0xbf,
                    };
                    try out.append(gpa, c);
                },
                else => {
                    self.utf8_left = 0;
                    try out.append(gpa, c);
                },
            }
        }
        return out.toOwnedSlice(gpa);
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

/// Text outside sequences passes, except ENQ, which makes many terminals
/// send an answerback message.
fn appendText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var parts = std.mem.splitScalar(u8, text, 0x05);
    while (parts.next()) |part| try out.appendSlice(gpa, part);
}

const Scan = union(enum) {
    /// The sequence's length.
    complete: usize,
    /// The length a terminal discards, cut short by CAN, SUB, ESC, or a
    /// byte that cannot appear in the sequence.
    aborted: usize,
    /// A string that reached `max_pending` unfinished; the length is
    /// that limit.
    oversized: usize,
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
/// (at least 1). Only the bytes themselves decide the result, never where
/// `s` ends, so it is the same however the output was split.
fn scan(s: []const u8, from: usize) Scan {
    const k = introIndex(s);
    const intro: u8 = if (k < s.len) s[k] else 0;
    const string = isString(intro);
    var j = from;
    while (j < s.len) : (j += 1) {
        if (j >= max_pending) return if (string and j > k) .{ .oversized = j } else .{ .aborted = j };
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
                // Only ASCII appears inside a sequence.
                if (c >= 0x80) return .{ .aborted = j };
                if (j == k and (string or c == '[')) continue;
                const csi = intro == '[' and j > k;
                if (c >= 0x20 and c <= (if (csi) @as(u8, 0x3f) else 0x2f)) continue;
                return .{ .complete = j + 1 };
            },
        }
    }
    return .{ .incomplete = j };
}

/// Whether a string, with the controls a terminal ignores in it removed,
/// is removed. `body` follows the introducer, without the terminator;
/// an incomplete string is judged by what has arrived.
fn removedString(intro: u8, body: []const u8, complete: bool) bool {
    return switch (intro) {
        '_' => true,
        'P' => std.mem.startsWith(u8, body, "+q") or std.mem.startsWith(u8, body, "$q"),
        ']' => if (complete) isOscQuery(body) else oscQueryPrefix(body),
        else => false,
    };
}

/// Split a sequence into the controls a terminal executes inside it,
/// which go to `out` first, and the sequence without them, which goes to
/// `clean`. ENQ and DEL are dropped; so are CAN and SUB, which only abort.
fn splitControls(gpa: std.mem.Allocator, out: *std.ArrayList(u8), scratch: std.mem.Allocator, clean: *std.ArrayList(u8), seq: []const u8) !void {
    const k = introIndex(seq);
    const string = k < seq.len and isString(seq[k]);
    try clean.append(scratch, 0x1b);
    for (seq[1..], 1..) |c, i| {
        if ((i < k or !string) and isExecuted(c)) {
            if (c != 0x7f and c != 0x05) try out.append(gpa, c);
        } else if (c != 0x18 and c != 0x1a and c != 0x05) {
            try clean.append(scratch, c);
        }
    }
}

/// `text` without the controls a terminal ignores inside a string. The
/// caller frees the result.
fn ignoredRemoved(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const kept = try gpa.alloc(u8, text.len);
    var n: usize = 0;
    for (text) |c| {
        if (c < 0x20 or c == 0x7f) continue;
        kept[n] = c;
        n += 1;
    }
    return gpa.realloc(kept, n);
}

/// Append a delimited sequence to `out`, or only the control characters a
/// terminal executes inside it when the sequence is removed or aborted.
fn emit(f: *Filter, gpa: std.mem.Allocator, out: *std.ArrayList(u8), seq: []const u8, complete: bool) !void {
    var stack_buf: [256]u8 = undefined;
    var stack: std.heap.BufferFirstAllocator = .init(&stack_buf, gpa);
    const scratch = stack.allocator();
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(scratch);
    try splitControls(gpa, out, scratch, &clean, seq);
    if (!complete) return;
    const s = clean.items;
    switch (s[1]) {
        '[' => return emitCsi(f, gpa, out, s),
        ']', 'P', '_' => {
            const body = try ignoredRemoved(scratch, stringBody(s));
            defer scratch.free(body);
            if (removedString(s[1], body, true)) return;
        },
        // DOCS: a character set change could leave UTF-8.
        '%' => return,
        // DECID
        'Z' => if (s.len == 2) return,
        // RIS: some terminals (VTE) clear their scrollback on it, and it
        // would leave the alternate screen the picker stays on.
        'c' => if (s.len == 2) return softReset(f, gpa, out),
        else => {},
    }
    try out.appendSlice(gpa, s);
}

/// What a full reset becomes: a soft reset and a cleared screen. The
/// first one scrolls what the terminal shows into its history first.
fn softReset(f: *Filter, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    if (f.history_rows > 0) {
        // Line feeds from the cursor: past the bottom row each one
        // scrolls a row into the history, so every row from the top down
        // to the cursor's ends up there.
        try out.appendSlice(gpa, "\x1b[0m");
        try out.appendNTimes(gpa, '\n', f.history_rows);
        f.history_rows = 0;
    }
    try out.appendSlice(gpa, "\x1b[!p\x1b[0m\x1b[H\x1b[2J");
}

fn emitCsi(f: *Filter, gpa: std.mem.Allocator, out: *std.ArrayList(u8), seq: []const u8) !void {
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
        return emitModes(f, gpa, out, params, final);
    }
    const first = paramValue(std.mem.sliceTo(params, ';'));
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
        't' => plain and prefix == 0 and !(first == 22 or first == 23),
        // XTSMGRAPHICS, XTQMODKEYS
        'S', 'm' => plain and prefix == '?',
        // DECREQTPARM
        'x' => plain and prefix == 0 and (first == 0 or first == 1),
        else => false,
    };
    if (!removed) try out.appendSlice(gpa, seq);
}

fn emitModes(f: *Filter, gpa: std.mem.Allocator, out: *std.ArrayList(u8), params: []const u8, final: u8) !void {
    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(gpa);
    var modes = std.mem.splitScalar(u8, params, ';');
    while (modes.next()) |mode| {
        if (paramValue(mode)) |value| {
            if (std.mem.indexOfScalar(u32, &reporting_modes, value) != null) continue;
            if (std.mem.indexOfScalar(u32, &screen_modes, value) != null) {
                if (f.stay_on_screen) continue;
                if (final == 'h' or final == 'l') f.alt_screen = final == 'h';
            }
        }
        if (kept.items.len > 0) try kept.append(gpa, ';');
        try kept.appendSlice(gpa, mode);
    }
    // A list of only removed modes is dropped; an empty one stays.
    if (kept.items.len == 0 and params.len > 0) return;
    try out.print(gpa, "\x1b[?{s}{c}", .{ kept.items, final });
}

/// A parameter's value as a terminal reads it: leading zeros and
/// sub-parameters (from ':') do not count, and empty means 0. Null when
/// it is not a number.
fn paramValue(param: []const u8) ?u32 {
    var value: u32 = 0;
    for (std.mem.sliceTo(param, ':')) |c| {
        if (!std.ascii.isDigit(c)) return null;
        value = value *| 10 +| (c - '0');
    }
    return value;
}

/// Color, palette, pointer, and clipboard queries put "?" where a value
/// would go; kitty's color and notification protocols use "key=?". The
/// daemon answers every kitty clipboard request (5522), writes included,
/// and keeps the kitty drag and drop state (72) itself.
fn isOscQuery(body: []const u8) bool {
    const number = paramValue(std.mem.sliceTo(body, ';')) orelse return false;
    switch (number) {
        4, 5, 10...19, 22, 52 => {
            var fields = std.mem.splitScalar(u8, body, ';');
            while (fields.next()) |field| if (std.mem.eql(u8, field, "?")) return true;
            return false;
        },
        21, 99 => return std.mem.indexOf(u8, body, "=?") != null,
        72, 5522 => return true,
        else => return false,
    }
}

/// Whether an OSC cut off at `max_pending` is a query, judged by what has
/// arrived: color values are never that long, so a color query's "?"
/// may still follow; OSC 52 reads the clipboard when its data starts
/// with "?". A number that has not ended yet counts as a query.
fn oscQueryPrefix(body: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, body, ';') orelse return true;
    const number = paramValue(body[0..semi]) orelse return false;
    switch (number) {
        4, 5, 10...19, 21, 22, 72, 99, 5522 => return true,
        52 => {
            const rest = body[semi + 1 ..];
            const data = std.mem.indexOfScalar(u8, rest, ';') orelse return true;
            return std.mem.startsWith(u8, rest[data + 1 ..], "?");
        },
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
    try expectFiltered(&.{"\x1b]5522;type=read\x1b\\\x1b]5522;type=write\x07\x1b]72;t=q\x1b\\\x1b]72;t=a;text/plain\x07ok"}, "ok");
    // Not queries: kitty flag changes, titles (even "?"), cursor style,
    // keypad, charset, an empty mode list, DECCARA, and DECSWBV.
    const passing = "\x1b[>1u\x1b[<u\x1b]0;title\x07\x1b]2;?\x07\x1b[2 q\x1b>\x1b(B\x1b[?h\x1b[1;1;5;5;1$t\x1b[3 t";
    try expectFiltered(&.{passing}, passing);
}

test "reporting modes are removed from mode changes" {
    try expectFiltered(&.{"\x1b[?2048h\x1b[?1049;2048;2004h\x1b[?2031l\x1b[?2048s\x1b[?5522h\x1b[?2048\rh"}, "\x1b[?1049;2004h\r");
}

test "aborted sequences are dropped, keeping the controls they carried" {
    // A wrapped query inside tmux passthrough leaves no open string.
    try expectFiltered(&.{"\x1bPtmux;\x1b\x1b[c\x1b\\A"}, "\x1b\\A");
    // A cut-short sequence cannot join what follows a removed query.
    try expectFiltered(&.{"\x1b[>\x1b[?2048hc\x1b[6\r\x1b]11;?\x07n"}, "c\rn");
    // CAN aborts; a control inside a query still takes effect; an
    // encoded C1 introducer inside a sequence starts a new one.
    try expectFiltered(&.{"a\x1b[6\x18n\x1b[6\rnb\x1b[6\xc2\x9b6n"}, "an\rb");
    // Controls between ESC and the sequence's kind are executed too.
    try expectFiltered(&.{"\x1b\r[6nx\x1b\r[31my"}, "\rx\r\x1b[31my");
}

test "controls a terminal ignores in a string do not hide a query" {
    try expectFiltered(&.{"\x1b]1\r1;?\x07\x1b]4;1;\x00?\x07\x1bP\x7f$qm\x1b\\\x1bP\r+q544e\x1b\\ok"}, "ok");
}

test "modes and parameters are compared by value" {
    try expectFiltered(&.{"\x1b[?02048h\x1b[?2048:1h\x1b[?1049;02031h\x1b[022;0t"}, "\x1b[?1049h\x1b[022;0t");
    try expectFiltered(&.{"\x1b[x\x1b[0x\x1b[1x\x1b[01xok\x1b[2x"}, "ok\x1b[2x");
}

test "the terminal stays in UTF-8 and C1 controls stay inert" {
    try expectFiltered(&.{"\xc2\x9b6nok"}, "ok");
    try expectFiltered(&.{"\xc2\x9d11;?\xc2\x9cok"}, "ok");
    try expectFiltered(&.{"\x9b6nok"}, "\xef\xbf\xbd6nok");
    try expectFiltered(&.{"\xe0\x9b6n"}, "\xe0\xef\xbf\xbd6n");
    try expectFiltered(&.{"\xc2\x9aok"}, "ok");
    try expectFiltered(&.{"\x1b%@ok"}, "ok");
    const text = "┐ Ý ¢";
    try expectFiltered(&.{text}, text);
    for (1..text.len) |cut| try expectFiltered(&.{ text[0..cut], text[cut..] }, text);
}

test "ENQ is removed" {
    try expectFiltered(&.{"a\x05b"}, "ab");
    try expectFiltered(&.{"\x1b[6\x05n"}, "");
    try expectFiltered(&.{"\x1b\x05]0;t\x07"}, "\x1b]0;t\x07");
}

test "staying on the alternate screen drops screen switches and full resets" {
    const gpa = std.testing.allocator;
    var filter: Filter = .{ .stay_on_screen = true };
    defer filter.deinit(gpa);
    const out = try filter.feed(gpa, "\x1b[?1049;25h\x1bca\x1b[?47l");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("\x1b[?25h\x1b[!p\x1b[0m\x1b[H\x1b[2Ja", out);
}

test "a full reset keeps the terminal's history, and screen switches are tracked" {
    const gpa = std.testing.allocator;
    var filter: Filter = .{ .history_rows = 3 };
    defer filter.deinit(gpa);
    const out = try filter.feed(gpa, "a\x1bc\x1b[?25;1049hb\x1bc");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a\x1b[0m\n\n\n\x1b[!p\x1b[0m\x1b[H\x1b[2J\x1b[?25;1049hb\x1b[!p\x1b[0m\x1b[H\x1b[2J", out);
    try std.testing.expect(filter.alt_screen);
    const back = try filter.feed(gpa, "\x1b[?1049l");
    defer gpa.free(back);
    try std.testing.expect(!filter.alt_screen);
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

    // A color query padded past the limit is still a query.
    const zeros = try gpa.alloc(u8, max_pending);
    defer gpa.free(zeros);
    @memset(zeros, '0');
    try expectFiltered(&.{ "\x1b]4;", zeros, "1;?\x07ok" }, "ok");

    // Anything but a string is cut at the limit wherever chunks end.
    const query = try gpa.alloc(u8, 70 * 1024);
    defer gpa.free(query);
    @memset(query, '1');
    query[0] = 0x1b;
    query[1] = '[';
    @memcpy(query[query.len - 4 ..], "6nok");
    const whole = try filterChunks(gpa, &.{query});
    defer gpa.free(whole);
    for ([_]usize{ 1, 4096, max_pending - 1, max_pending, max_pending + 1 }) |cut| {
        const split = try filterChunks(gpa, &.{ query[0..cut], query[cut..] });
        defer gpa.free(split);
        try std.testing.expectEqualStrings(whole, split);
    }
}

test "output does not depend on how it is split into chunks" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x747570);
    const random = prng.random();
    const alphabet = "\x1b\x1b\x1b[[]P_\\?;>=$%12046ctnhpqux\x07\x18\x05\r\xc2\xc2\x9b\x9c\xa2abc";
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    for (0..100) |_| {
        stream.clearRetainingCapacity();
        for (0..400) |_| {
            // Now and then a digit run long enough to reach the limit.
            if (random.uintLessThan(usize, 200) == 0) {
                try stream.appendNTimes(gpa, '1', random.uintLessThan(usize, max_pending + 4096));
            } else {
                try stream.append(gpa, alphabet[random.uintLessThan(usize, alphabet.len)]);
            }
        }
        const whole = try filterChunks(gpa, &.{stream.items});
        defer gpa.free(whole);
        var chunks: std.ArrayList([]const u8) = .empty;
        defer chunks.deinit(gpa);
        var at: usize = 0;
        while (at < stream.items.len) {
            // Mostly tiny chunks; now and then a large one, so long runs
            // cross the limit at varied points without a million feeds.
            const max: usize = if (random.uintLessThan(usize, 8) == 0) 8192 else 8;
            const n = @min(stream.items.len - at, 1 + random.uintLessThan(usize, max));
            try chunks.append(gpa, stream.items[at .. at + n]);
            at += n;
        }
        const split = try filterChunks(gpa, chunks.items);
        defer gpa.free(split);
        try std.testing.expectEqualStrings(whole, split);
    }
}
