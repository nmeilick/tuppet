//! Key input: vim-style notation (e.g. `<C-a>`, `<M-x>`, `<Up>`) parsed
//! into ghostty KeyEvents and encoded into the byte sequences the session
//! should write to its PTY. Encoding is state-aware: it reads the current
//! terminal state (kitty keyboard protocol flags, DECCKM, DECBKM,
//! modifyOtherKeys) so the same notation produces the right sequence for
//! whatever the child program has negotiated.

const std = @import("std");
const vt = @import("vt");
const key = @import("input/key.zig");
const key_encode = @import("input/key_encode.zig");

/// Build encoder options from the live terminal state.
pub fn optionsFromTerminal(t: *const vt.Terminal) key_encode.Options {
    return .{
        .alt_esc_prefix = t.modes.get(.alt_esc_prefix),
        .cursor_key_application = t.modes.get(.cursor_keys),
        .keypad_key_application = t.modes.get(.keypad_keys),
        .backarrow_key_mode = t.modes.get(.backarrow_key_mode),
        .ignore_keypad_with_numlock = t.modes.get(.ignore_keypad_with_numlock),
        .modify_other_keys_state_2 = t.flags.modify_other_keys_2,
        .kitty_flags = @bitCast(t.screens.active.kitty_keyboard.current().int()),
        // No physical keyboard: Alt in the notation always means Alt,
        // never a macOS Option compose key.
        .macos_option_as_alt = .true,
    };
}

/// Parse one vim-notation token into a KeyEvent. Any text carried by the
/// event points into `scratch`, which must outlive the call to `encodeAll`.
pub fn parseToken(token: []const u8, scratch: *[4]u8) !key.KeyEvent {
    if (token.len >= 2 and token[0] == '<' and token[token.len - 1] == '>') {
        return parseAngle(token[1 .. token.len - 1], scratch);
    }
    // Plain text: one codepoint per event.
    var view = std.unicode.Utf8View.init(token) catch return error.BadUtf8;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return error.EmptyToken;
    if (it.nextCodepoint() != null) return error.MultiCodepointToken;

    return eventForChar(cp, .{}, scratch);
}

fn parseAngle(inner_full: []const u8, scratch: *[4]u8) !key.KeyEvent {
    // A trailing "--" is a modifier followed by the minus key: <C-->.
    var inner = inner_full;
    var minus_key = false;
    if (inner.len >= 3 and std.mem.endsWith(u8, inner, "--")) {
        inner = inner[0 .. inner.len - 2];
        minus_key = true;
    }
    // Split on '-' into modifier segments and the final key name.
    var mods: key.Mods = .{};
    var keyname: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, inner, '-');
    while (it.next()) |part| {
        if (part.len == 0) return error.EmptyKeySegment;
        if (it.peek() == null and !minus_key) {
            // Last segment is the key name.
            keyname = part;
            break;
        }
        if (part.len != 1) return error.UnknownModifier;
        switch (std.ascii.toLower(part[0])) {
            'c' => {
                if (mods.ctrl) return error.DuplicateModifier;
                mods.ctrl = true;
            },
            'm', 'a' => {
                if (mods.alt) return error.DuplicateModifier;
                mods.alt = true;
            },
            's' => {
                if (mods.shift) return error.DuplicateModifier;
                mods.shift = true;
            },
            'd' => {
                if (mods.super) return error.DuplicateModifier;
                mods.super = true;
            },
            else => return error.UnknownModifier,
        }
    }
    if (minus_key) return eventForChar('-', mods, scratch);
    return eventForName(keyname orelse return error.EmptyToken, mods, scratch);
}

/// Map a key name (case-insensitive) to a KeyEvent. Special names first,
/// then single characters.
fn eventForName(name: []const u8, mods: key.Mods, scratch: *[4]u8) !key.KeyEvent {
    const Special = struct { name: []const u8, k: key.Key, utf8: []const u8 = "", cp: u21 = 0 };
    const specials = [_]Special{
        .{ .name = "cr", .k = .enter },
        .{ .name = "enter", .k = .enter },
        .{ .name = "return", .k = .enter },
        .{ .name = "esc", .k = .escape },
        .{ .name = "escape", .k = .escape },
        .{ .name = "tab", .k = .tab },
        .{ .name = "space", .k = .space, .utf8 = " ", .cp = ' ' },
        .{ .name = "bs", .k = .backspace },
        .{ .name = "backspace", .k = .backspace },
        .{ .name = "del", .k = .delete },
        .{ .name = "delete", .k = .delete },
        .{ .name = "home", .k = .home },
        .{ .name = "end", .k = .end },
        .{ .name = "ins", .k = .insert },
        .{ .name = "insert", .k = .insert },
        .{ .name = "up", .k = .arrow_up },
        .{ .name = "down", .k = .arrow_down },
        .{ .name = "left", .k = .arrow_left },
        .{ .name = "right", .k = .arrow_right },
        .{ .name = "pgup", .k = .page_up },
        .{ .name = "pageup", .k = .page_up },
        .{ .name = "pgdown", .k = .page_down },
        .{ .name = "pagedown", .k = .page_down },
    };
    var lower: [32]u8 = undefined;
    if (name.len > lower.len) return error.UnknownKey;
    for (name, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const lname = lower[0..name.len];

    for (specials) |s| {
        if (std.mem.eql(u8, lname, s.name)) {
            var ev = key.KeyEvent{ .key = s.k, .mods = mods, .unshifted_codepoint = s.cp };
            if (s.utf8.len > 0 and !mods.ctrl) ev.utf8 = s.utf8;
            return ev;
        }
    }

    if (lname.len >= 2 and lname[0] == 'f' and lname[1] >= '1' and lname[1] <= '9') {
        const n = std.fmt.parseInt(u8, lname[1..], 10) catch return error.UnknownKey;
        // key.Key declares f1..f25 as contiguous values.
        if (n >= 1 and n <= 25) {
            return key.KeyEvent{ .key = @fromBackingInt(@intCast(@backingInt(key.Key.f1) + (n - 1))), .mods = mods };
        }
    }

    var view = std.unicode.Utf8View.init(name) catch return error.UnknownKey;
    var it = view.iterator();
    var cp = it.nextCodepoint() orelse return error.UnknownKey;
    if (it.nextCodepoint() != null) return error.UnknownKey;
    // As in vim, <C-C> is <C-c>; Shift must be explicit (<C-S-c>).
    if (mods.ctrl and !mods.shift and cp >= 'A' and cp <= 'Z') cp += 'a' - 'A';
    return eventForChar(cp, mods, scratch);
}

/// Build a KeyEvent for a codepoint. Control characters in plain text
/// are the keys that type them: tab, enter, escape, backspace, or Ctrl
/// plus a letter or symbol.
fn eventForChar(cp: u21, mods: key.Mods, scratch: *[4]u8) !key.KeyEvent {
    if (cp < 0x20 or cp == 0x7f) {
        if (!mods.empty()) return error.UnknownKey;
        return switch (cp) {
            '\t' => .{ .key = .tab },
            '\r', '\n' => .{ .key = .enter },
            0x1b => .{ .key = .escape },
            0x7f, 0x08 => .{ .key = .backspace },
            0 => .{ .key = .space, .mods = .{ .ctrl = true }, .unshifted_codepoint = ' ' },
            else => eventForChar(if (cp <= 0x1a) cp + 'a' - 1 else cp + '@', .{ .ctrl = true }, scratch),
        };
    }
    const info = asciiKey(cp);
    // Alt is the one modifier a character without a US key can carry: it
    // types the character with an ESC prefix.
    if (info == null and !mods.empty() and !mods.equal(.{ .alt = true })) return error.UnknownKey;

    var event_mods = mods;
    var consumed_mods: key.Mods = .{};
    var produced = cp;
    if (info) |ascii| {
        if (ascii.is_shifted) {
            event_mods.shift = true;
            consumed_mods.shift = true;
        } else if (event_mods.shift) {
            produced = ascii.shifted;
            consumed_mods.shift = true;
        }
    }

    var ev = key.KeyEvent{
        .key = if (info) |ascii| ascii.key else .unidentified,
        .mods = event_mods,
        .consumed_mods = consumed_mods,
        .unshifted_codepoint = if (info) |ascii| ascii.unshifted else cp,
    };
    // Fill utf8 even with ctrl held: the encoder's ctrlSeq and fixterms
    // CSI-u paths key off it, and without it combos like <C-i> or
    // <C-S-b> would encode to nothing at all.
    const n = std.unicode.utf8Encode(produced, scratch) catch return error.BadChar;
    ev.utf8 = scratch[0..n];
    return ev;
}

const AsciiKey = struct {
    key: key.Key,
    unshifted: u21,
    shifted: u21,
    is_shifted: bool,
};

fn asciiKey(cp: u21) ?AsciiKey {
    return switch (cp) {
        'a'...'z' => asciiKeyInfo(cp, cp - 'a' + 'A', @fromBackingInt(@intCast(@backingInt(key.Key.key_a) + (cp - 'a'))), cp),
        'A'...'Z' => asciiKeyInfo(cp - 'A' + 'a', cp, @fromBackingInt(@intCast(@backingInt(key.Key.key_a) + (cp - 'A'))), cp),
        '0', ')' => asciiKeyInfo('0', ')', .digit_0, cp),
        '1', '!' => asciiKeyInfo('1', '!', .digit_1, cp),
        '2', '@' => asciiKeyInfo('2', '@', .digit_2, cp),
        '3', '#' => asciiKeyInfo('3', '#', .digit_3, cp),
        '4', '$' => asciiKeyInfo('4', '$', .digit_4, cp),
        '5', '%' => asciiKeyInfo('5', '%', .digit_5, cp),
        '6', '^' => asciiKeyInfo('6', '^', .digit_6, cp),
        '7', '&' => asciiKeyInfo('7', '&', .digit_7, cp),
        '8', '*' => asciiKeyInfo('8', '*', .digit_8, cp),
        '9', '(' => asciiKeyInfo('9', '(', .digit_9, cp),
        '`', '~' => asciiKeyInfo('`', '~', .backquote, cp),
        '\\', '|' => asciiKeyInfo('\\', '|', .backslash, cp),
        '[', '{' => asciiKeyInfo('[', '{', .bracket_left, cp),
        ']', '}' => asciiKeyInfo(']', '}', .bracket_right, cp),
        ',', '<' => asciiKeyInfo(',', '<', .comma, cp),
        '=', '+' => asciiKeyInfo('=', '+', .equal, cp),
        '-', '_' => asciiKeyInfo('-', '_', .minus, cp),
        '.', '>' => asciiKeyInfo('.', '>', .period, cp),
        '\'', '"' => asciiKeyInfo('\'', '"', .quote, cp),
        ';', ':' => asciiKeyInfo(';', ':', .semicolon, cp),
        '/', '?' => asciiKeyInfo('/', '?', .slash, cp),
        ' ' => asciiKeyInfo(' ', ' ', .space, cp),
        else => null,
    };
}

fn asciiKeyInfo(unshifted: u21, shifted: u21, k: key.Key, cp: u21) AsciiKey {
    return .{ .key = k, .unshifted = unshifted, .shifted = shifted, .is_shifted = cp == shifted and shifted != unshifted };
}

/// Parse all tokens and encode them into the byte sequence to send.
pub fn encodeAll(
    gpa: std.mem.Allocator,
    t: *const vt.Terminal,
    tokens: []const []const u8,
    bad: *[]const u8,
) ![]u8 {
    const opts = optionsFromTerminal(t);

    var out: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(gpa, &out);
    defer w.deinit();

    for (tokens) |tok| {
        if (tok.len == 0) continue;
        var scratch: [4]u8 = undefined;
        bad.* = tok;
        if (tok.len >= 2 and tok[0] == '<' and tok[tok.len - 1] == '>') {
            try encodeKey(&w.writer, try parseToken(tok, &scratch), opts);
            continue;
        }
        // Plain text: one key event per codepoint.
        var view = std.unicode.Utf8View.init(tok) catch return error.BadUtf8;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            try encodeKey(&w.writer, try eventForChar(cp, .{}, &scratch), opts);
        }
    }
    bad.* = "";

    var list = std.Io.Writer.Allocating.toArrayList(&w);
    return list.toOwnedSlice(gpa);
}

/// A key the keyboard mode cannot express (Ctrl+Shift+Space in legacy
/// mode) encodes to nothing; that must fail rather than vanish from the
/// input. Outside the kitty protocol, Ctrl combos without a C0 byte (such
/// as Ctrl+Shift+c) would go out as fixterms CSI u, which a program that
/// did not ask for it reads as stray text, so they fail too.
fn encodeKey(w: *std.Io.Writer, ev: key.KeyEvent, opts: key_encode.Options) !void {
    const legacy = opts.kitty_flags.int() == 0;
    if (legacy and !opts.modify_other_keys_state_2) if (legacyControl(ev)) |byte| {
        if (ev.mods.alt) try w.writeByte(0x1b);
        return w.writeByte(byte);
    };
    const before = w.end;
    try key_encode.encode(w, ev, opts);
    const out = w.buffered()[before..];
    const csi_u = ev.mods.ctrl and out.len > 3 and std.mem.startsWith(u8, out, "\x1b[") and out[out.len - 1] == 'u';
    if (legacy and (out.len == 0 or csi_u))
        return if (opts.modify_other_keys_state_2) error.KeyNotEncodable else error.KeyNeedsKittyProtocol;
    if (out.len == 0) return error.KeyNotEncodable;
}

/// The C0 byte a legacy terminal sends for Ctrl+i, Ctrl+m, Ctrl+[, or
/// Ctrl+@ (Tab, CR, Esc, NUL); the encoder keeps them apart as CSI u,
/// following fixterms.
fn legacyControl(ev: key.KeyEvent) ?u8 {
    var mods = ev.mods.binding();
    mods.alt = false;
    if (ev.utf8.len != 1) return null;
    const ch = ev.utf8[0];
    // '@' is shifted, so its event carries Shift.
    if (ch == '@') mods.shift = false;
    if (!mods.equal(.{ .ctrl = true })) return null;
    return switch (ch) {
        'i' => '\t',
        'm' => '\r',
        '[' => 0x1b,
        '@' => 0,
        else => null,
    };
}

/// Validate one token the way encodeAll parses it, without needing
/// terminal state. Lets the CLI reject malformed notation before
/// sending it to the daemon.
pub fn checkToken(tok: []const u8) !void {
    var scratch: [4]u8 = undefined;
    if (tok.len >= 2 and tok[0] == '<' and tok[tok.len - 1] == '>') {
        _ = try parseToken(tok, &scratch);
        return;
    }
    // Plain text: any valid UTF-8 is encodable.
    var view = std.unicode.Utf8View.init(tok) catch return error.BadUtf8;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        _ = try eventForChar(cp, .{}, &scratch);
    }
}

/// Split `text` into the tokens `encodeAll` takes: a `<` starts a key when
/// a `>` follows and what lies between is a key name of at least two
/// characters (`<Esc>`, `<C-c>`); the rest is typed as text. A name made
/// of letters, digits, and `-` that is no key is an error, so a typo is
/// never typed; `bad` then holds it. Tokens alias `text`.
pub fn split(gpa: std.mem.Allocator, text: []const u8, bad: *[]const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer tokens.deinit(gpa);
    var run: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '<') {
            i += 1;
            continue;
        }
        if (i > run) try tokens.append(gpa, text[run..i]);
        const close = std.mem.indexOfScalarPos(u8, text, i + 1, '>');
        const group: ?[]const u8 = if (close) |c| text[i .. c + 1] else null;
        if (group) |g| key: {
            const inner = g[1 .. g.len - 1];
            if (inner.len < 2 or std.mem.indexOfAny(u8, inner, " \t<") != null) break :key;
            var scratch: [4]u8 = undefined;
            if (parseToken(g, &scratch)) |_| {
                try tokens.append(gpa, g);
            } else |err| {
                for (inner) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') break :key;
                bad.* = g;
                return err;
            }
            i += g.len;
            run = i;
            continue;
        }
        // A lone '<' is typed; as a token of its own it never reads as a key.
        try tokens.append(gpa, text[i .. i + 1]);
        i += 1;
        run = i;
    }
    if (run < text.len) try tokens.append(gpa, text[run..]);
    return tokens.toOwnedSlice(gpa);
}

/// What a failed `checkToken` means, in words.
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyToken => "empty token",
        error.EmptyKeySegment => "empty modifier or key segment",
        error.UnknownModifier => "unknown modifier (use C, M, A, S, or D)",
        error.DuplicateModifier => "modifier repeated",
        error.UnknownKey => "unknown key name",
        error.BadUtf8 => "invalid UTF-8",
        error.BadChar => "character is not encodable",
        error.MultiCodepointToken => "more than one character inside <>",
        else => "invalid notation",
    };
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

fn encodeFor(t: *vt.Terminal, tokens: []const []const u8) ![]u8 {
    // Callers free the result with testing.allocator.
    var bad: []const u8 = "";
    return encodeAll(testing.allocator, t, tokens, &bad);
}

test "a string splits into keys and text" {
    const gpa = testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{ .cols = 80, .rows = 24 });
    defer term.deinit(gpa);
    var bad: []const u8 = "";
    const cases = [_]struct { text: []const u8, tokens: []const []const u8 }{
        .{ .text = ":q!<Enter>", .tokens = &.{ ":q!", "<Enter>" } },
        .{ .text = "<C-c><Esc>ihi", .tokens = &.{ "<C-c>", "<Esc>", "ihi" } },
        .{ .text = "<M-->x", .tokens = &.{ "<M-->", "x" } },
        .{ .text = "a <=> b <x> <", .tokens = &.{ "a ", "<", "=> b ", "<", "x> ", "<" } },
        .{ .text = "<a b>", .tokens = &.{ "<", "a b>" } },
        .{ .text = "-v", .tokens = &.{"-v"} },
    };
    for (cases) |case| {
        const tokens = try split(gpa, case.text, &bad);
        defer gpa.free(tokens);
        try testing.expectEqualDeep(case.tokens, tokens);
        // Text tokens never read as keys.
        const bytes = try encodeFor(&term, tokens);
        gpa.free(bytes);
    }
    try testing.expectError(error.UnknownKey, split(gpa, "x<Ener>", &bad));
    try testing.expectEqualStrings("<Ener>", bad);
}

test "legacy control key encoding" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    const ctrl_a = try encodeFor(&term, &.{"<C-a>"});
    defer testing.allocator.free(ctrl_a);
    try testing.expectEqualStrings("\x01", ctrl_a);

    const esc = try encodeFor(&term, &.{"<Esc>"});
    defer testing.allocator.free(esc);
    try testing.expectEqualStrings("\x1b", esc);

    const cr = try encodeFor(&term, &.{"<CR>"});
    defer testing.allocator.free(cr);
    try testing.expectEqualStrings("\r", cr);

    const tab = try encodeFor(&term, &.{"<Tab>"});
    defer testing.allocator.free(tab);
    try testing.expectEqualStrings("\t", tab);

    const st = try encodeFor(&term, &.{"<S-Tab>"});
    defer testing.allocator.free(st);
    try testing.expectEqualStrings("\x1b[Z", st);

    const f1 = try encodeFor(&term, &.{"<F1>"});
    defer testing.allocator.free(f1);
    try testing.expectEqualStrings("\x1bOP", f1);
}

test "a key the mode cannot express fails even among other keys" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);
    var bad: []const u8 = "";
    try testing.expectError(error.KeyNeedsKittyProtocol, encodeAll(testing.allocator, &term, &.{ "x", "<C-S-Space>", "y" }, &bad));
    try testing.expectEqualStrings("<C-S-Space>", bad);
}

test "legacy ctrl combos are C0 bytes or need the kitty protocol" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    const c0 = try encodeFor(&term, &.{ "<C-i>", "<C-m>", "<C-[>", "<C-@>", "<C-M-i>", "<C-a>" });
    defer testing.allocator.free(c0);
    try testing.expectEqualStrings("\t\r\x1b\x00\x1b\t\x01", c0);

    // Fixterms CSI u is no legacy encoding.
    for ([_][]const u8{ "<C-S-b>", "<C-;>", "<C-->", "<C-S-i>" }) |tok| {
        try testing.expectError(error.KeyNeedsKittyProtocol, encodeFor(&term, &.{tok}));
    }

    term.screens.active.kitty_keyboard.push(.{
        .disambiguate = true,
        .report_events = false,
        .report_alternates = false,
        .report_all = false,
        .report_associated = false,
    });
    const kitty = try encodeFor(&term, &.{ "<C-i>", "<C-S-b>" });
    defer testing.allocator.free(kitty);
    try testing.expectEqualStrings("\x1b[105;5u\x1b[98;6u", kitty);
}

test "alt types a non-ASCII character with an ESC prefix" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    const alt = try encodeFor(&term, &.{ "<A-é>", "<M-界>" });
    defer testing.allocator.free(alt);
    try testing.expectEqualStrings("\x1bé\x1b界", alt);

    var scratch: [4]u8 = undefined;
    try testing.expectError(error.UnknownKey, parseToken("<C-é>", &scratch));
    try testing.expectError(error.UnknownKey, parseToken("<S-é>", &scratch));
}

test "F13 through F25 parse and encode in kitty mode" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    var scratch: [4]u8 = undefined;
    const f25 = try parseToken("<F25>", &scratch);
    try testing.expectEqual(key.Key.f25, f25.key);
    try testing.expectError(error.UnknownKey, parseToken("<F26>", &scratch));

    term.screens.active.kitty_keyboard.push(.{
        .disambiguate = true,
        .report_events = false,
        .report_alternates = false,
        .report_all = false,
        .report_associated = false,
    });

    const f20 = try encodeFor(&term, &.{"<F20>"});
    defer testing.allocator.free(f20);
    try testing.expectEqualStrings("\x1b[57383u", f20);
}

test "legacy arrow and modifier encoding" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    const up = try encodeFor(&term, &.{"<Up>"});
    defer testing.allocator.free(up);
    try testing.expectEqualStrings("\x1b[A", up);

    const ctrl_up = try encodeFor(&term, &.{"<C-Up>"});
    defer testing.allocator.free(ctrl_up);
    try testing.expectEqualStrings("\x1b[1;5A", ctrl_up);

    const alt_x = try encodeFor(&term, &.{"<M-x>"});
    defer testing.allocator.free(alt_x);
    try testing.expectEqualStrings("\x1bx", alt_x);
}

test "cursor application mode changes arrow encoding" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    // DECCKM: ESC [ ? 1 h enables cursor key application mode.
    var stream = vt.TerminalStream.init(.{ .handler = term.vtHandler(), .allocator = testing.allocator });
    defer stream.deinit();
    stream.nextSlice("\x1b[?1h");

    const up = try encodeFor(&term, &.{"<Up>"});
    defer testing.allocator.free(up);
    try testing.expectEqualStrings("\x1bOA", up);
}

test "plain text encoding" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    const hello = try encodeFor(&term, &.{"hello"});
    defer testing.allocator.free(hello);
    try testing.expectEqualStrings("hello", hello);

    // Colon has no logical key in ghostty's table; it must still encode
    // as plain text (needed for commands like :q).
    const colon = try encodeFor(&term, &.{":"});
    defer testing.allocator.free(colon);
    try testing.expectEqualStrings(":", colon);
}

test "all printable US ASCII and Unicode encode as text" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    var printable: [95]u8 = undefined;
    for (&printable, 0..) |*byte, i| byte.* = @intCast(0x20 + i);

    const ascii = try encodeFor(&term, &.{&printable});
    defer testing.allocator.free(ascii);
    try testing.expectEqualStrings(&printable, ascii);

    const unicode = try encodeFor(&term, &.{"é界🙂"});
    defer testing.allocator.free(unicode);
    try testing.expectEqualStrings("é界🙂", unicode);

    const angles = try encodeFor(&term, &.{ "<", ">", "<not-notation", "a>b" });
    defer testing.allocator.free(angles);
    try testing.expectEqualStrings("<><not-notationa>b", angles);
}

test "shifted printable keys retain base key and produced text" {
    var scratch: [4]u8 = undefined;

    const at = try parseToken("@", &scratch);
    try testing.expectEqual(key.Key.digit_2, at.key);
    try testing.expect(at.mods.shift and at.consumed_mods.shift);
    try testing.expectEqual(@as(u21, '2'), at.unshifted_codepoint);
    try testing.expectEqualStrings("@", at.utf8);

    const shifted_one = try parseToken("<S-1>", &scratch);
    try testing.expectEqual(key.Key.digit_1, shifted_one.key);
    try testing.expectEqual(@as(u21, '1'), shifted_one.unshifted_codepoint);
    try testing.expectEqualStrings("!", shifted_one.utf8);

    const less_than = try parseToken("<", &scratch);
    try testing.expectEqual(key.Key.comma, less_than.key);
    try testing.expect(less_than.mods.shift and less_than.consumed_mods.shift);
    try testing.expectEqualStrings("<", less_than.utf8);
}

test "modifier segments require exact non-duplicated tokens" {
    var scratch: [4]u8 = undefined;
    try testing.expectError(error.UnknownModifier, parseToken("<Cats-a>", &scratch));
    try testing.expectError(error.EmptyKeySegment, parseToken("<C--a>", &scratch));
    try testing.expectError(error.EmptyKeySegment, parseToken("<-a>", &scratch));
    try testing.expectError(error.EmptyKeySegment, parseToken("<C-a->", &scratch));
    try testing.expectError(error.DuplicateModifier, parseToken("<C-C-a>", &scratch));
    try testing.expectError(error.EmptyKeySegment, parseToken("<C->", &scratch));
}

test "ctrl letters, ctrl-space, control characters, and minus encode as keys" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    const legacy = try encodeFor(&term, &.{ "<C-C>", "<C-Space>", "a\tb\n" });
    defer testing.allocator.free(legacy);
    try testing.expectEqualStrings("\x03\x00a\tb\r", legacy);

    term.screens.active.kitty_keyboard.push(.{
        .disambiguate = true,
        .report_events = false,
        .report_alternates = false,
        .report_all = false,
        .report_associated = false,
    });
    const kitty = try encodeFor(&term, &.{ "<C-Space>", "<C-->", "\t", "\x01" });
    defer testing.allocator.free(kitty);
    try testing.expectEqualStrings("\x1b[32;5u\x1b[45;5u\t\x1b[97;5u", kitty);
}

test "failed key encoding frees partial output" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    try testing.expectError(error.EmptyKeySegment, encodeFor(&term, &.{
        "this text allocates output before the malformed token",
        "<C--a>",
    }));
}

test "kitty keyboard progressive enhancement encodes CSI-u" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    // Progressive enhancement: CSI > 3 u = disambiguate + report-event-types.
    term.screens.active.kitty_keyboard.push(.{
        .disambiguate = true,
        .report_events = true,
        .report_alternates = false,
        .report_all = false,
        .report_associated = false,
    });

    const ctrl_a = try encodeFor(&term, &.{"<C-a>"});
    defer testing.allocator.free(ctrl_a);
    try testing.expectEqualStrings("\x1b[97;5u", ctrl_a);

    const up = try encodeFor(&term, &.{"<Up>"});
    defer testing.allocator.free(up);
    try testing.expectEqualStrings("\x1b[1;1:1A", up);

    const ctrl_up = try encodeFor(&term, &.{"<C-Up>"});
    defer testing.allocator.free(ctrl_up);
    try testing.expectEqualStrings("\x1b[1;5:1A", ctrl_up);

    const f1 = try encodeFor(&term, &.{"<F1>"});
    defer testing.allocator.free(f1);
    try testing.expectEqualStrings("\x1b[1;1:1P", f1);

    const shift_tab = try encodeFor(&term, &.{"<S-Tab>"});
    defer testing.allocator.free(shift_tab);
    try testing.expectEqualStrings("\x1b[9;2u", shift_tab);

    // Plain text is unchanged by kitty mode.
    const x = try encodeFor(&term, &.{"x"});
    defer testing.allocator.free(x);
    try testing.expectEqualStrings("x", x);

    var printable: [95]u8 = undefined;
    for (&printable, 0..) |*byte, i| byte.* = @intCast(0x20 + i);
    const ascii = try encodeFor(&term, &.{&printable});
    defer testing.allocator.free(ascii);
    try testing.expectEqualStrings(&printable, ascii);
}

test "kitty report-all identifies shifted printable keys by their base key" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    term.screens.active.kitty_keyboard.push(.{
        .disambiguate = false,
        .report_events = false,
        .report_alternates = false,
        .report_all = true,
        .report_associated = false,
    });

    const shifted = try encodeFor(&term, &.{ "@", "A", "<" });
    defer testing.allocator.free(shifted);
    try testing.expectEqualStrings("\x1b[50;2u\x1b[97;2u\x1b[44;2u", shifted);
}
