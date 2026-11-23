//! A small regular expression engine for matching patterns from users
//! against lines from programs. It simulates a Thompson NFA, so a match
//! takes time linear in the text for any pattern and never backtracks.
//!
//! Matches are leftmost-longest: the earliest start, then the longest end
//! from there, regardless of the order of alternatives. A match starts
//! only where a character does, never inside a UTF-8 sequence. Negated
//! classes and `.` take one whole UTF-8 code point (a malformed byte
//! counts as one), and so does a class that holds non-ASCII characters; a
//! class without either compares single ASCII bytes.

const std = @import("std");

/// The longest pattern `compile` takes.
pub const max_pattern_len = 256;
/// The most NFA states a pattern compiles to.
pub const max_states = 512;
/// The largest count in `{n}`, `{n,}`, and `{n,m}`.
pub const max_count = 32;

/// A match: `text[start..end]`, never empty.
pub const Span = struct { start: usize, end: usize };

pub const Options = struct {
    /// Compare ASCII letters regardless of case.
    icase: bool = false,
};

const ByteSet = std.StaticBitSet(256);

const Op = enum(u8) {
    /// Takes the byte `arg`.
    byte,
    /// Takes a byte in `classes[arg].set`.
    set,
    /// Takes a code point in `classes[arg]`; the three states after it
    /// skip its remaining bytes.
    class,
    /// Takes any byte.
    skip,
    split,
    jmp,
    bol,
    eol,
    match,
};

const Inst = struct {
    op: Op,
    arg: u16 = 0,
    out: u16 = 0,
    out2: u16 = 0,
};

const Class = struct {
    /// ASCII members.
    set: ByteSet = .empty,
    /// Every non-ASCII code point and malformed byte is a member.
    wide_all: bool = false,
    negate: bool = false,
    /// Non-ASCII members in `Regex.wide`.
    wide_start: u16 = 0,
    wide_len: u16 = 0,

    fn matches(class: Class, ch: Char, wide: []const u21) bool {
        const member = if (ch.cp) |cp|
            if (cp < 0x80)
                class.set.isSet(cp)
            else
                class.wide_all or std.mem.findScalar(u21, wide[class.wide_start..][0..class.wide_len], cp) != null
        else
            class.wide_all;
        return member != class.negate;
    }
};

const Char = struct { len: u3, cp: ?u21 };

fn charAt(text: []const u8, i: usize) Char {
    const b = text[i];
    if (b < 0x80) return .{ .len = 1, .cp = b };
    const malformed: Char = .{ .len = 1, .cp = null };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return malformed;
    if (text.len - i < n) return malformed;
    const cp = std.unicode.utf8Decode(text[i..][0..n]) catch return malformed;
    return .{ .len = n, .cp = cp };
}

/// Whether a character starts at `text[i]`: it is no continuation byte of
/// a well-formed UTF-8 sequence that starts before it.
fn startsChar(text: []const u8, i: usize) bool {
    if (text[i] & 0xc0 != 0x80) return true;
    var j = i;
    while (j > 0 and i - j < 3) {
        j -= 1;
        if (text[j] & 0xc0 != 0x80) return charAt(text, j).len <= i - j;
    }
    return true;
}

/// A compiled pattern. `find` and `count` do not allocate.
pub const Regex = struct {
    insts: []const Inst,
    classes: []const Class,
    wide: []const u21,
    /// The bytes a match can start with, at the text's start and after.
    lead0: ByteSet,
    lead: ByteSet,

    pub fn deinit(re: *Regex, gpa: std.mem.Allocator) void {
        gpa.free(re.insts);
        gpa.free(re.classes);
        gpa.free(re.wide);
        re.* = undefined;
    }

    /// The leftmost-longest match starting at or after `from`. It takes
    /// time linear in the text after `from`.
    pub fn find(re: *const Regex, text: []const u8, from: usize) ?Span {
        if (from >= text.len) return null;
        var lists: [2]List = undefined;
        var cur = &lists[0];
        var next = &lists[1];
        cur.reset();
        var best: ?Span = null;
        var i = from;
        while (true) : (i += 1) {
            if (best == null) {
                if (cur.len == 0) i = re.nextLead(text, i) orelse return null;
                if (i == text.len or startsChar(text, i)) re.add(cur, 0, i, i, text.len);
            } else if (cur.len == 0) break;
            next.reset();
            // Threads are in order of their start, and one that reaches a
            // state first has the earliest start of all that do.
            for (cur.pcs[0..cur.len], cur.starts[0..cur.len]) |pc, start| {
                if (best) |b| if (start > b.start) break;
                const in = re.insts[pc];
                if (in.op == .match) {
                    best = .{ .start = start, .end = i };
                    continue;
                }
                if (i == text.len) continue;
                switch (in.op) {
                    .byte => if (text[i] == in.arg) re.add(next, in.out, i + 1, start, text.len),
                    .set => if (re.classes[in.arg].set.isSet(text[i])) re.add(next, in.out, i + 1, start, text.len),
                    .class => {
                        const ch = charAt(text, i);
                        if (re.classes[in.arg].matches(ch, re.wide)) {
                            re.add(next, if (ch.len == 1) in.out else pc + ch.len - 1, i + 1, start, text.len);
                        }
                    },
                    .skip => re.add(next, in.out, i + 1, start, text.len),
                    else => unreachable,
                }
            }
            if (i == text.len) break;
            std.mem.swap(*List, &cur, &next);
        }
        return best;
    }

    /// How many matches `text` holds, each searched for after the end of
    /// the one before. It can take time quadratic in the text when a
    /// pattern keeps searching far beyond where its matches end, as
    /// `a.*b|a` does on a line of `a`s.
    pub fn count(re: *const Regex, text: []const u8) usize {
        var n: usize = 0;
        var at: usize = 0;
        while (re.find(text, at)) |m| : (at = m.end) n += 1;
        return n;
    }

    fn nextLead(re: *const Regex, text: []const u8, from: usize) ?usize {
        if (from == 0 and re.lead0.isSet(text[0])) return 0;
        if (re.lead.count() == 0) return null;
        var i = @max(from, 1);
        while (i < text.len) : (i += 1) if (re.lead.isSet(text[i]) and startsChar(text, i)) return i;
        return null;
    }

    /// Adds the states `pc` leads to at `pos` without taking a byte.
    fn add(re: *const Regex, list: *List, pc: u16, pos: usize, start: usize, len: usize) void {
        var stack: [2 * max_states + 1]u16 = undefined;
        stack[0] = pc;
        var n: usize = 1;
        while (n > 0) {
            n -= 1;
            const at = stack[n];
            if (list.seen.isSet(at)) continue;
            list.seen.set(at);
            const in = re.insts[at];
            switch (in.op) {
                .jmp => {
                    stack[n] = in.out;
                    n += 1;
                },
                .split => {
                    stack[n] = in.out2;
                    stack[n + 1] = in.out;
                    n += 2;
                },
                .bol, .eol => if ((in.op == .bol and pos == 0) or (in.op == .eol and pos == len)) {
                    stack[n] = in.out;
                    n += 1;
                },
                else => {
                    list.pcs[list.len] = at;
                    list.starts[list.len] = start;
                    list.len += 1;
                },
            }
        }
    }
};

const List = struct {
    pcs: [max_states]u16,
    starts: [max_states]usize,
    len: usize,
    seen: std.StaticBitSet(max_states),

    fn reset(list: *List) void {
        list.len = 0;
        list.seen = .empty;
    }
};

/// The message for a quantifier character `q` followed by `what`, as a
/// static string.
fn quantifierText(comptime what: []const u8, q: u8) []const u8 {
    return switch (q) {
        inline '*', '+', '?', '{' => |c| "'" ++ [_]u8{c} ++ "' " ++ what,
        else => unreachable,
    };
}

/// Compiles `pattern`. It refuses with error.BadPattern a pattern that is
/// malformed, uses syntax beyond this subset, is too long or complex, or
/// can match an empty text, which every line holds; then it sets `why`, if
/// given, to a static text saying what is wrong, such as "a '(' is not
/// closed".
pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, options: Options, why: ?*[]const u8) error{ OutOfMemory, BadPattern }!Regex {
    var p: Parser = .{ .pattern = pattern, .icase = options.icase };
    return p.compile(gpa) catch |err| {
        if (err == error.BadPattern) if (why) |w| {
            w.* = p.why;
        };
        return err;
    };
}

fn leadOf(re: *const Regex, at_start: bool) ByteSet {
    var lead: ByteSet = .empty;
    var seen: std.StaticBitSet(max_states) = .empty;
    var stack: [2 * max_states + 1]u16 = undefined;
    stack[0] = 0;
    var n: usize = 1;
    while (n > 0) {
        n -= 1;
        const pc = stack[n];
        if (seen.isSet(pc)) continue;
        seen.set(pc);
        const in = re.insts[pc];
        switch (in.op) {
            .byte => lead.set(in.arg),
            .set => lead.setUnion(re.classes[in.arg].set),
            .class => {
                const class = re.classes[in.arg];
                for (0..0x80) |b| if (class.set.isSet(b) != class.negate) lead.set(b);
                if (class.negate or class.wide_all or class.wide_len > 0) lead.setRangeValue(.{ .start = 0x80, .end = 0x100 }, true);
            },
            .split => {
                stack[n] = in.out2;
                stack[n + 1] = in.out;
                n += 2;
            },
            .jmp, .eol => {
                stack[n] = in.out;
                n += 1;
            },
            .bol => if (at_start) {
                stack[n] = in.out;
                n += 1;
            },
            .skip, .match => {},
        }
    }
    return lead;
}

const none = std.math.maxInt(u16);
const unbounded = std.math.maxInt(u8);
const max_nodes = 3 * max_pattern_len + 4;

const Node = struct {
    kind: enum { byte, set, class, bol, eol, cat, alt, repeat },
    /// The byte, or the index in `Parser.classes`.
    arg: u16 = 0,
    min: u8 = 0,
    max: u8 = 0,
    child: u16 = none,
    next: u16 = none,
};

const Parser = struct {
    pattern: []const u8,
    icase: bool,
    pos: usize = 0,
    why: []const u8 = "",
    nodes: [max_nodes]Node = undefined,
    n_nodes: u16 = 0,
    classes: [max_pattern_len]Class = undefined,
    n_classes: u16 = 0,
    wide: [max_pattern_len]u21 = undefined,
    n_wide: u16 = 0,
    insts: [max_states]Inst = undefined,
    n_insts: u16 = 0,

    fn node(p: *Parser, n: Node) u16 {
        p.nodes[p.n_nodes] = n;
        p.n_nodes += 1;
        return p.n_nodes - 1;
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.pattern.len) p.pattern[p.pos] else null;
    }

    fn fail(p: *Parser, why: []const u8) error{BadPattern} {
        p.why = why;
        return error.BadPattern;
    }

    fn compile(p: *Parser, gpa: std.mem.Allocator) error{ OutOfMemory, BadPattern }!Regex {
        if (p.pattern.len == 0) return p.fail("it is empty");
        if (p.pattern.len > max_pattern_len) return p.fail(std.fmt.comptimePrint("it is longer than {d} bytes", .{max_pattern_len}));
        const root = try p.parseAlt();
        if (p.pos < p.pattern.len) return p.fail("a ')' has no '('");
        if (p.nullable(root)) return p.fail("it matches an empty text");
        try p.emit(root);
        _ = try p.inst(.{ .op = .match });

        const insts = try gpa.dupe(Inst, p.insts[0..p.n_insts]);
        errdefer gpa.free(insts);
        const classes = try gpa.dupe(Class, p.classes[0..p.n_classes]);
        errdefer gpa.free(classes);
        const wide = try gpa.dupe(u21, p.wide[0..p.n_wide]);
        var re: Regex = .{ .insts = insts, .classes = classes, .wide = wide, .lead0 = .empty, .lead = .empty };
        re.lead0 = leadOf(&re, true);
        re.lead = leadOf(&re, false);
        return re;
    }

    fn parseAlt(p: *Parser) error{BadPattern}!u16 {
        const alt = p.node(.{ .kind = .alt });
        var tail: u16 = none;
        while (true) {
            const cat = try p.parseCat();
            if (tail == none) p.nodes[alt].child = cat else p.nodes[tail].next = cat;
            tail = cat;
            if (p.peek() != '|') return alt;
            p.pos += 1;
        }
    }

    fn parseCat(p: *Parser) error{BadPattern}!u16 {
        const cat = p.node(.{ .kind = .cat });
        var tail: u16 = none;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            var atom = try p.parseAtom();
            if (p.peek()) |q| if (isQuantifier(q)) {
                const kind = p.nodes[atom].kind;
                if (kind == .bol or kind == .eol) return p.fail(quantifierText("follows an anchor", q));
                atom = try p.parseQuantifier(atom);
                if (p.peek()) |again| if (isQuantifier(again)) return p.fail(quantifierText("follows another quantifier", again));
            };
            if (tail == none) p.nodes[cat].child = atom else p.nodes[tail].next = atom;
            tail = atom;
        }
        return cat;
    }

    fn isQuantifier(c: u8) bool {
        return c == '*' or c == '+' or c == '?' or c == '{';
    }

    fn parseQuantifier(p: *Parser, atom: u16) error{BadPattern}!u16 {
        const c = p.pattern[p.pos];
        p.pos += 1;
        var min: u8 = 0;
        var max: u8 = unbounded;
        switch (c) {
            '*' => {},
            '+' => min = 1,
            '?' => max = 1,
            else => {
                const form = "a '{' must start '{n}', '{n,}', or '{n,m}'";
                min = try p.parseCount() orelse return p.fail(form);
                if (p.peek() == ',') {
                    p.pos += 1;
                    if (p.peek() != '}') max = try p.parseCount() orelse return p.fail(form);
                } else max = min;
                if (p.peek() != '}') return p.fail(form);
                p.pos += 1;
                if (max < min) return p.fail("in '{n,m}' m is below n");
            },
        }
        return p.node(.{ .kind = .repeat, .min = min, .max = max, .child = atom });
    }

    fn parseCount(p: *Parser) error{BadPattern}!?u8 {
        const start = p.pos;
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            p.pos += 1;
        }
        if (p.pos == start) return null;
        const n = std.fmt.parseInt(u8, p.pattern[start..p.pos], 10) catch max_count + 1;
        if (n > max_count) return p.fail(std.fmt.comptimePrint("a count in '{{...}}' is above {d}", .{max_count}));
        return n;
    }

    fn parseAtom(p: *Parser) error{BadPattern}!u16 {
        const c = p.pattern[p.pos];
        p.pos += 1;
        switch (c) {
            '(' => {
                const alt = try p.parseAlt();
                if (p.peek() != ')') return p.fail("a '(' is not closed");
                p.pos += 1;
                return alt;
            },
            '[' => return p.classNode(try p.parseClass()),
            '.' => return p.classNode(.{ .negate = true }),
            '^' => return p.node(.{ .kind = .bol }),
            '$' => return p.node(.{ .kind = .eol }),
            '*', '+', '?', '{' => return p.fail(quantifierText("follows nothing", c)),
            ']', '}' => return p.fail(if (c == ']') "a ']' has no '['" else "a '}' has no '{'"),
            '\\' => {
                const e = try p.parseEscape(false);
                return switch (e) {
                    .char => |b| p.byteNode(@intCast(b)),
                    .class => |class| p.classNode(class),
                };
            },
            else => {
                // A UTF-8 character is one atom, so a quantifier takes all
                // of it.
                const n = charAt(p.pattern, p.pos - 1).len;
                if (n == 1) return p.byteNode(c);
                const cat = p.node(.{ .kind = .cat });
                var tail: u16 = none;
                for (p.pattern[p.pos - 1 ..][0..n]) |b| {
                    const leaf = p.node(.{ .kind = .byte, .arg = b });
                    if (tail == none) p.nodes[cat].child = leaf else p.nodes[tail].next = leaf;
                    tail = leaf;
                }
                p.pos += n - 1;
                return cat;
            },
        }
    }

    fn byteNode(p: *Parser, b: u8) error{BadPattern}!u16 {
        if (p.icase and std.ascii.isAlphabetic(b)) {
            var class: Class = .{};
            class.set.set(b);
            return p.classNode(class);
        }
        return p.node(.{ .kind = .byte, .arg = b });
    }

    fn classNode(p: *Parser, class: Class) error{BadPattern}!u16 {
        var c = class;
        if (p.icase) for ('a'..'z' + 1) |lower| {
            const upper = std.ascii.toUpper(@intCast(lower));
            if (c.set.isSet(lower) or c.set.isSet(upper)) {
                c.set.set(lower);
                c.set.set(upper);
            }
        };
        p.classes[p.n_classes] = c;
        p.n_classes += 1;
        const simple = !c.negate and !c.wide_all and c.wide_len == 0;
        return p.node(.{ .kind = if (simple) .set else .class, .arg = p.n_classes - 1 });
    }

    const Escape = union(enum) { char: u21, class: Class };

    /// The escape after a `\`; `-` is one too inside brackets.
    fn parseEscape(p: *Parser, in_brackets: bool) error{BadPattern}!Escape {
        const e = p.peek() orelse return p.fail("it ends in a lone '\\'");
        const n = charAt(p.pattern, p.pos).len;
        p.pos += n;
        if (std.mem.findScalar(u8, "\\.^$|?*+()[]{}/", e) != null or (in_brackets and e == '-')) return .{ .char = e };
        if (e == 't') return .{ .char = '\t' };
        var class: Class = .{};
        switch (std.ascii.toLower(e)) {
            'd' => class.set.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true),
            'w' => {
                class.set.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true);
                class.set.setRangeValue(.{ .start = 'a', .end = 'z' + 1 }, true);
                class.set.setRangeValue(.{ .start = 'A', .end = 'Z' + 1 }, true);
                class.set.set('_');
            },
            's' => for (" \t\n\x0b\x0c\r") |b| class.set.set(b),
            else => return p.fail("an unknown escape follows a '\\'"),
        }
        class.negate = std.ascii.isUpper(e);
        return .{ .class = class };
    }

    /// The class after a `[`.
    fn parseClass(p: *Parser) error{BadPattern}!Class {
        var class: Class = .{ .wide_start = p.n_wide };
        if (p.peek() == '^') {
            class.negate = true;
            p.pos += 1;
        }
        var first = true;
        while (true) {
            const c = p.peek() orelse return p.fail("a '[' is not closed");
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            const item = try p.parseClassItem();
            const range = p.pos + 1 < p.pattern.len and p.pattern[p.pos] == '-' and p.pattern[p.pos + 1] != ']';
            const lo = switch (item) {
                .char => |cp| cp,
                .class => |inner| {
                    if (range) return p.fail("a range in '[...]' must be between two characters");
                    var set = inner.set;
                    if (inner.negate) {
                        set.toggleAll();
                        set.setRangeValue(.{ .start = 0x80, .end = 0x100 }, false);
                        class.wide_all = true;
                    }
                    class.set.setUnion(set);
                    continue;
                },
            };
            if (!range) {
                if (lo < 0x80) class.set.set(lo) else {
                    p.wide[p.n_wide] = lo;
                    p.n_wide += 1;
                }
                continue;
            }
            p.pos += 1;
            const hi = switch (try p.parseClassItem()) {
                .char => |cp| cp,
                .class => return p.fail("a range in '[...]' must be between two characters"),
            };
            if (lo >= 0x80 or hi >= 0x80) return p.fail("a range in '[...]' must be between ASCII characters");
            if (hi < lo) return p.fail("a range in '[...]' runs backwards");
            class.set.setRangeValue(.{ .start = lo, .end = hi + 1 }, true);
        }
        class.wide_len = p.n_wide - class.wide_start;
        return class;
    }

    fn parseClassItem(p: *Parser) error{BadPattern}!Escape {
        const c = p.pattern[p.pos];
        if (c == '\\') {
            p.pos += 1;
            return p.parseEscape(true);
        }
        const ch = charAt(p.pattern, p.pos);
        p.pos += ch.len;
        return .{ .char = ch.cp orelse return p.fail("a byte in '[...]' is not UTF-8") };
    }

    fn nullable(p: *const Parser, n: u16) bool {
        const nd = p.nodes[n];
        return switch (nd.kind) {
            .byte, .set, .class => false,
            .bol, .eol => true,
            .cat => {
                var c = nd.child;
                while (c != none) : (c = p.nodes[c].next) if (!p.nullable(c)) return false;
                return true;
            },
            .alt => {
                var c = nd.child;
                while (c != none) : (c = p.nodes[c].next) if (p.nullable(c)) return true;
                return false;
            },
            .repeat => nd.min == 0 or p.nullable(nd.child),
        };
    }

    fn inst(p: *Parser, in: Inst) error{BadPattern}!u16 {
        if (p.n_insts == max_states) return p.fail(std.fmt.comptimePrint("it is too complex: it needs more than {d} states", .{max_states}));
        p.insts[p.n_insts] = in;
        p.n_insts += 1;
        return p.n_insts - 1;
    }

    /// Emits `n` so that it continues at the state after its last.
    fn emit(p: *Parser, n: u16) error{BadPattern}!void {
        const nd = p.nodes[n];
        switch (nd.kind) {
            .byte, .set => _ = try p.inst(.{ .op = if (nd.kind == .byte) .byte else .set, .arg = nd.arg, .out = p.n_insts + 1 }),
            .bol, .eol => _ = try p.inst(.{ .op = if (nd.kind == .bol) .bol else .eol, .out = p.n_insts + 1 }),
            .class => {
                const pc = p.n_insts;
                _ = try p.inst(.{ .op = .class, .arg = nd.arg, .out = pc + 4 });
                _ = try p.inst(.{ .op = .skip, .out = pc + 4 });
                _ = try p.inst(.{ .op = .skip, .out = pc + 1 });
                _ = try p.inst(.{ .op = .skip, .out = pc + 2 });
            },
            .cat => {
                var c = nd.child;
                while (c != none) : (c = p.nodes[c].next) try p.emit(c);
            },
            .alt => try p.emitAlt(nd.child),
            .repeat => try p.emitRepeat(nd),
        }
    }

    fn emitAlt(p: *Parser, first: u16) error{BadPattern}!void {
        if (p.nodes[first].next == none) return p.emit(first);
        const split = try p.inst(.{ .op = .split, .out = p.n_insts + 1 });
        try p.emit(first);
        const jmp = try p.inst(.{ .op = .jmp });
        p.insts[split].out2 = p.n_insts;
        try p.emitAlt(p.nodes[first].next);
        p.insts[jmp].out = p.n_insts;
    }

    fn emitRepeat(p: *Parser, nd: Node) error{BadPattern}!void {
        const before = p.n_insts;
        const copies = if (nd.max == unbounded and nd.min > 0) nd.min - 1 else nd.min;
        for (0..copies) |_| {
            try p.emit(nd.child);
            // A child without states has none in every copy.
            if (p.n_insts == before) return;
        }
        if (nd.max == unbounded) {
            if (nd.min == 0) {
                const split = try p.inst(.{ .op = .split, .out = p.n_insts + 1 });
                try p.emit(nd.child);
                _ = try p.inst(.{ .op = .jmp, .out = split });
                p.insts[split].out2 = p.n_insts;
            } else {
                const loop = p.n_insts;
                try p.emit(nd.child);
                _ = try p.inst(.{ .op = .split, .out = loop, .out2 = p.n_insts + 1 });
            }
            return;
        }
        var splits: [max_count]u16 = undefined;
        for (splits[0 .. nd.max - nd.min]) |*split| {
            split.* = try p.inst(.{ .op = .split, .out = p.n_insts + 1 });
            try p.emit(nd.child);
        }
        for (splits[0 .. nd.max - nd.min]) |split| p.insts[split].out2 = p.n_insts;
    }
};

const testing = std.testing;

fn expectFind(pattern: []const u8, options: Options, text: []const u8, want: ?[]const u8) !void {
    var re = try compile(testing.allocator, pattern, options, null);
    defer re.deinit(testing.allocator);
    const got = re.find(text, 0);
    if (want) |w| {
        const m = got orelse return error.TestExpectedMatch;
        try testing.expectEqualStrings(w, text[m.start..m.end]);
    } else try testing.expectEqual(null, got);
}

fn expectBad(pattern: []const u8, why: []const u8) !void {
    var got: []const u8 = "";
    try testing.expectError(error.BadPattern, compile(testing.allocator, pattern, .{}, &got));
    try testing.expectEqualStrings(why, got);
}

test "literals and escapes" {
    try expectFind("me@app", .{}, "ssh me@app1:", "me@app");
    try expectFind("a\\.b", .{}, "axb a.b", "a.b");
    try expectFind("\\(\\[\\{\\}\\]\\)\\\\\\/\\^\\$\\|\\?\\*\\+", .{}, "x([{}])\\/^$|?*+", "([{}])\\/^$|?*+");
    try expectFind("a\\tb", .{}, "a\tb", "a\tb");
    try expectFind("grün", .{}, "ist grün.", "grün");
    try expectFind("ü+", .{}, "xüüüy", "üüü");
    try expectFind("me@app\\d+:", .{}, "me@app:  me@app42:", "me@app42:");
    try expectFind("\\w+\\s\\S", .{}, "-- foo_1 bar", "foo_1 b");
    try expectFind("\\D\\W", .{}, "1ä!", "ä!");
}

test "classes and negation" {
    try expectFind("[abc]+", .{}, "xxbcay", "bca");
    try expectFind("[a-z0-9]+", .{}, "AB x9z!", "x9z");
    try expectFind("[^ab]", .{}, "abäc", "ä");
    try expectFind("[]x]+", .{}, "a]x]b", "]x]");
    try expectFind("[-a]+ [a-]+", .{}, "-a- a-a", "-a- a-a");
    try expectFind("[\\d_]+", .{}, "a1_2b", "1_2");
    try expectFind("[äö]", .{}, "aöä", "ö");
    try expectFind("[^\\d]", .{}, "12ä3", "ä");
    try expectFind("[\\D]", .{}, "12é", "é");
    try expectFind("[\\]\\-]+", .{}, "a]-]b", "]-]");
    // A negated class takes a malformed byte as one character.
    try expectFind("x[^a]y", .{}, "x\xffy", "x\xffy");
}

test "quantifiers" {
    try expectFind("ab*c", .{}, "ac abbbc", "ac");
    try expectFind("ab+c", .{}, "ac abbbc", "abbbc");
    try expectFind("colou?r", .{}, "colour", "colour");
    try expectFind("a{3}", .{}, "aa aaaa", "aaa");
    try expectFind("a{2,}", .{}, "a aaaaa", "aaaaa");
    try expectFind("a{2,3}", .{}, "aaaaa", "aaa");
    try expectFind("x(ab){1,2}", .{}, "xababab", "xabab");
    try expectFind("a{0}b", .{}, "ab", "b");
    try expectFind("\\d{1,32}", .{}, "n=" ++ @as([40]u8, @splat('7')), &@as([32]u8, @splat('7')));
}

test "alternation and groups: leftmost, then longest" {
    try expectFind("cat|dog", .{}, "hotdog cat", "dog");
    try expectFind("a|ab|abc", .{}, "xabcd", "abc");
    try expectFind("(foo|bar)+baz", .{}, "foobarfoobaz", "foobarfoobaz");
    try expectFind("(a|b)(c|d)", .{}, "aabd", "bd");
    try expectFind("x(|y)z", .{}, "xz xyz", "xz");
}

test "anchors" {
    try expectFind("^\\$ ", .{}, "$ ls", "$ ");
    try expectFind("^ls", .{}, "$ ls", null);
    try expectFind("done$", .{}, "done and done", "done");
    try expectFind("^a+$", .{}, "aaa", "aaa");
    try expectFind("^a+$", .{}, "aaab", null);
    try expectFind("x|^y", .{}, "yx", "y");
    var re = try compile(testing.allocator, "^a", .{}, null);
    defer re.deinit(testing.allocator);
    try testing.expectEqual(null, re.find("aa", 1));
}

test "dot takes one UTF-8 code point" {
    try expectFind("a.c", .{}, "a€c", "a€c");
    try expectFind("a..c", .{}, "a€c", null);
    try expectFind("^.{3}$", .{}, "äöü", "äöü");
    try expectFind("a.b", .{}, "a\xe2\x82b", null);
    try expectFind("a..b", .{}, "a\xe2\x82b", "a\xe2\x82b");
}

test "a match never starts inside a UTF-8 character" {
    try expectFind("[^ä]", .{}, "ä", null);
    try expectFind("..", .{}, "€", null);
    try expectFind("..c", .{}, "a€c", "a€c");
    var re = try compile(testing.allocator, "..c", .{}, null);
    defer re.deinit(testing.allocator);
    try testing.expectEqual(null, re.find("a€c", 1));
    // A stray continuation byte is a character of its own.
    try expectFind("[^a]", .{}, "a\x82", "\x82");
}

test "icase" {
    try expectFind("error", .{ .icase = true }, "an ERROR here", "ERROR");
    try expectFind("[a-c]+", .{ .icase = true }, "xAbCd", "AbC");
    try expectFind("[^a]", .{ .icase = true }, "aAb", "b");
    try expectFind("error", .{}, "an ERROR here", null);
}

test "find from an offset, and count" {
    var re = try compile(testing.allocator, "ab+", .{}, null);
    defer re.deinit(testing.allocator);
    try testing.expectEqual(Span{ .start = 4, .end = 7 }, re.find("abb abb", 1).?);
    try testing.expectEqual(null, re.find("abb abb", 5));
    try testing.expectEqual(2, re.count("abb abb"));
    var aa = try compile(testing.allocator, "aa", .{}, null);
    defer aa.deinit(testing.allocator);
    try testing.expectEqual(2, aa.count("aaaaa"));
}

test "bad patterns say why" {
    try expectBad("", "it is empty");
    try expectBad(&@as([max_pattern_len + 1]u8, @splat('a')), "it is longer than 256 bytes");
    try expectBad("x(", "a '(' is not closed");
    try expectBad("x)", "a ')' has no '('");
    try expectBad("[ab", "a '[' is not closed");
    try expectBad("a]", "a ']' has no '['");
    try expectBad("a}", "a '}' has no '{'");
    try expectBad("*a", "'*' follows nothing");
    try expectBad("a|+b", "'+' follows nothing");
    try expectBad("^*a", "'*' follows an anchor");
    try expectBad("a*?", "'?' follows another quantifier");
    try expectBad("a{2", "a '{' must start '{n}', '{n,}', or '{n,m}'");
    try expectBad("a{,2}", "a '{' must start '{n}', '{n,}', or '{n,m}'");
    try expectBad("a{33}", "a count in '{...}' is above 32");
    try expectBad("a{3,2}", "in '{n,m}' m is below n");
    try expectBad("a\\", "it ends in a lone '\\'");
    try expectBad("\\q", "an unknown escape follows a '\\'");
    try expectBad("[\\d-z]", "a range in '[...]' must be between two characters");
    try expectBad("[a-ü]", "a range in '[...]' must be between ASCII characters");
    try expectBad("[z-a]", "a range in '[...]' runs backwards");
    try expectBad("[\xff]", "a byte in '[...]' is not UTF-8");
    try expectBad("(.{32}){32}", "it is too complex: it needs more than 512 states");
    for ([_][]const u8{ "a*", "x?", "()", "^", "$", "a|", "^$", "(a?){5}", "(|a)*" }) |pattern| {
        try expectBad(pattern, "it matches an empty text");
    }
}

test "a pathological pattern takes linear time" {
    const text = &@as([20000]u8, @splat('a'));
    var re = try compile(testing.allocator, "(a|aa)*b", .{}, null);
    defer re.deinit(testing.allocator);
    try testing.expectEqual(null, re.find(text, 0));
    var nested = try compile(testing.allocator, "(a+a+)+b", .{}, null);
    defer nested.deinit(testing.allocator);
    try testing.expectEqual(null, nested.find(text, 0));
}

test "plain patterns count like a naive substring search" {
    var prng: std.Random.DefaultPrng = .init(0x7265);
    const random = prng.random();
    var pattern: [4]u8 = undefined;
    var text: [64]u8 = undefined;
    for (0..2000) |_| {
        const needle = pattern[0 .. 1 + random.uintLessThan(usize, pattern.len)];
        for (needle) |*b| b.* = "ab"[random.uintLessThan(usize, 2)];
        const hay = text[0..random.uintLessThan(usize, text.len + 1)];
        for (hay) |*b| b.* = "ab"[random.uintLessThan(usize, 2)];
        var naive: usize = 0;
        var i: usize = 0;
        while (std.mem.findPos(u8, hay, i, needle)) |at| : (i = at + needle.len) naive += 1;
        var re = try compile(testing.allocator, needle, .{}, null);
        defer re.deinit(testing.allocator);
        try testing.expectEqual(naive, re.count(hay));
    }
}
