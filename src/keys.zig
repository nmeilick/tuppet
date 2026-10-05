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
            return key.KeyEvent{ .key = @enumFromInt(@intFromEnum(key.Key.f1) + (n - 1)), .mods = mods };
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
    if (info == null and !mods.empty()) return error.UnknownKey;

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
        'a'...'z' => asciiKeyInfo(cp, cp - 'a' + 'A', @enumFromInt(@intFromEnum(key.Key.key_a) + (cp - 'a')), cp),
        'A'...'Z' => asciiKeyInfo(cp - 'A' + 'a', cp, @enumFromInt(@intFromEnum(key.Key.key_a) + (cp - 'A')), cp),
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
) ![]u8 {
    const opts = optionsFromTerminal(t);

    var out: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(gpa, &out);
    defer w.deinit();

    for (tokens) |tok| {
        if (tok.len == 0) continue;
        var scratch: [4]u8 = undefined;
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

    var list = std.Io.Writer.Allocating.toArrayList(&w);
    return list.toOwnedSlice(gpa);
}

/// A key the keyboard mode cannot express (F13 and up in legacy mode)
/// encodes to nothing; that must fail rather than vanish from the input.
fn encodeKey(w: *std.Io.Writer, ev: anytype, opts: anytype) !void {
    const before = w.end;
    try key_encode.encode(w, ev, opts);
    if (w.end == before) return error.KeyNotEncodable;
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

// ---- tests ------------------------------------------------------------

const testing = std.testing;

fn encodeFor(t: *vt.Terminal, tokens: []const []const u8) ![]u8 {
    // Callers free the result with testing.allocator.
    return encodeAll(testing.allocator, t, tokens);
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
    try testing.expectError(error.KeyNotEncodable, encodeFor(&term, &.{ "x", "<F13>", "y" }));
}

test "legacy ctrl combos outside the C0 table use fixterms CSI-u" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    // <C-i>, <C-m>, and <C-[> are deliberately absent from the C0 table
    // (fixterms); they must encode as CSI-u, not vanish.
    const ctrl_i = try encodeFor(&term, &.{"<C-i>"});
    defer testing.allocator.free(ctrl_i);
    try testing.expectEqualStrings("\x1b[105;5u", ctrl_i);

    const ctrl_m = try encodeFor(&term, &.{"<C-m>"});
    defer testing.allocator.free(ctrl_m);
    try testing.expectEqualStrings("\x1b[109;5u", ctrl_m);

    const ctrl_bracket = try encodeFor(&term, &.{"<C-[>"});
    defer testing.allocator.free(ctrl_bracket);
    try testing.expectEqualStrings("\x1b[91;5u", ctrl_bracket);

    // ctrl+shift+letter: the base letter, shift+ctrl modifiers.
    const ctrl_shift_b = try encodeFor(&term, &.{"<C-S-b>"});
    defer testing.allocator.free(ctrl_shift_b);
    try testing.expectEqualStrings("\x1b[98;6u", ctrl_shift_b);

    // ctrl+symbol: no C0 mapping, so CSI-u.
    const ctrl_semi = try encodeFor(&term, &.{"<C-;>"});
    defer testing.allocator.free(ctrl_semi);
    try testing.expectEqualStrings("\x1b[59;5u", ctrl_semi);

    // C0-table combos are unchanged.
    const ctrl_a = try encodeFor(&term, &.{"<C-a>"});
    defer testing.allocator.free(ctrl_a);
    try testing.expectEqualStrings("\x01", ctrl_a);
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

    const legacy = try encodeFor(&term, &.{ "<C-C>", "<C-->", "a\tb\n" });
    defer testing.allocator.free(legacy);
    try testing.expectEqualStrings("\x03\x1b[45;5ua\tb\r", legacy);

    term.screens.active.kitty_keyboard.push(.{
        .disambiguate = true,
        .report_events = false,
        .report_alternates = false,
        .report_all = false,
        .report_associated = false,
    });
    const kitty = try encodeFor(&term, &.{ "<C-Space>", "\t", "\x01" });
    defer testing.allocator.free(kitty);
    try testing.expectEqualStrings("\x1b[32;5u\t\x1b[97;5u", kitty);
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
