//! Mouse and focus event encoding against live terminal state.
//! Wraps the vendored ghostty mouse encoder (src/input/mouse_encode.zig).

const std = @import("std");
const vt = @import("vt");
const mouse_encode = @import("input/mouse_encode.zig");
const mouse = @import("input/mouse.zig");
const key = @import("input/key.zig");

/// Keyboard modifiers carried by mouse events.
pub const Mods = key.Mods;

/// Mouse buttons and actions, re-exported for the session layer.
pub const Button = mouse.Button;
pub const Action = mouse.Action;

/// Build encoding options from live terminal state. We map one cell to one
/// "pixel" (cell = 1x1, no padding), so surface-space positions in the
/// event are cell coordinates, zero-based.
fn optionsFromTerminal(t: *const vt.Terminal, cols: u16, rows: u16) mouse_encode.Options {
    // Name-based bridges: a compile error here beats a silent reordering
    // if the vendored enums ever change.
    return .{
        .event = switch (t.flags.mouse_event) {
            .none => .none,
            .x10 => .x10,
            .normal => .normal,
            .button => .button,
            .any => .any,
        },
        .format = switch (t.flags.mouse_format) {
            .x10 => .x10,
            .utf8 => .utf8,
            .sgr => .sgr,
            .urxvt => .urxvt,
            .sgr_pixels => .sgr_pixels,
        },
        .size = .{
            .screen = .{ .width = cols, .height = rows },
            .cell = .{ .width = 1, .height = 1 },
            .padding = .{},
        },
    };
}

/// Parse a button name ("left", "right", "middle", "up", "down", or
/// "1".."9") into the button enum. Wheel buttons map to four/five.
pub fn parseButton(name: []const u8) ?mouse.Button {
    const Buttons = std.StaticStringMap(mouse.Button).initComptime(.{
        .{ "left", .left },
        .{ "right", .right },
        .{ "middle", .middle },
        .{ "up", .four },
        .{ "down", .five },
        .{ "1", .left },
        .{ "2", .right },
        .{ "3", .middle },
        .{ "4", .four },
        .{ "5", .five },
        .{ "6", .six },
        .{ "7", .seven },
        .{ "8", .eight },
        .{ "9", .nine },
    });
    return Buttons.get(name);
}

/// Parse an action name ("press", "release", "motion").
pub fn parseAction(name: []const u8) ?mouse.Action {
    const Actions = std.StaticStringMap(mouse.Action).initComptime(.{
        .{ "press", .press },
        .{ "release", .release },
        .{ "motion", .motion },
    });
    return Actions.get(name);
}

/// Parse modifier letters ("c" ctrl, "a"/"m" alt, "s" shift) into key
/// mods. Each modifier may appear once.
pub fn parseMods(spec: []const u8) ?key.Mods {
    var mods: key.Mods = .{};
    for (spec) |ch| switch (std.ascii.toLower(ch)) {
        'c' => {
            if (mods.ctrl) return null;
            mods.ctrl = true;
        },
        'a', 'm' => {
            if (mods.alt) return null;
            mods.alt = true;
        },
        's' => {
            if (mods.shift) return null;
            mods.shift = true;
        },
        else => return null,
    };
    return mods;
}

/// A validated mouse event; `button` is null for motion with no button
/// held (hover).
pub const Event = struct {
    button: ?mouse.Button,
    action: mouse.Action,
    mods: key.Mods,
};

pub const EventError = error{
    InvalidButton,
    InvalidAction,
    InvalidMods,
    NoButtonNeedsMotion,
    WheelHasNoRelease,
};

/// Validate a mouse event as the CLI and the daemon accept it: button
/// "none" is hover motion, and the wheel only presses (terminals never
/// report a wheel release).
pub fn parseEvent(button_name: []const u8, action_name: []const u8, mods_spec: []const u8) EventError!Event {
    const action = parseAction(action_name) orelse return error.InvalidAction;
    const mods = parseMods(mods_spec) orelse return error.InvalidMods;
    if (std.mem.eql(u8, button_name, "none")) {
        if (action != .motion) return error.NoButtonNeedsMotion;
        return .{ .button = null, .action = action, .mods = mods };
    }
    const button = parseButton(button_name) orelse return error.InvalidButton;
    if ((button == .four or button == .five) and action == .release) return error.WheelHasNoRelease;
    return .{ .button = button, .action = action, .mods = mods };
}

pub fn eventErrorText(err: EventError) []const u8 {
    return switch (err) {
        error.InvalidButton => "invalid button (choose left, right, middle, up, down, none, or 1..9)",
        error.InvalidAction => "invalid action (choose press, release, or motion)",
        error.InvalidMods => "invalid modifiers (use each of c, a or m, and s at most once)",
        error.NoButtonNeedsMotion => "button 'none' is only valid with --action motion",
        error.WheelHasNoRelease => "the wheel (up, down, 4, 5) has no release event",
    };
}

/// Encode one mouse event. `x`/`y` are zero-based cell coordinates.
/// Returns empty output when the terminal has no mouse reporting enabled
/// or the event is filtered by the reporting mode.
pub fn encodeMouse(
    gpa: std.mem.Allocator,
    t: *const vt.Terminal,
    cols: u16,
    rows: u16,
    button: ?mouse.Button,
    action: mouse.Action,
    mods: key.Mods,
    x: u16,
    y: u16,
) ![]u8 {
    const opts = optionsFromTerminal(t, cols, rows);

    var out: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(gpa, &out);
    defer w.deinit();
    try mouse_encode.encode(&w.writer, .{
        .action = action,
        .button = button,
        .mods = mods,
        .pos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) },
    }, opts);
    var list = std.Io.Writer.Allocating.toArrayList(&w);
    return list.toOwnedSlice(gpa);
}

/// Encode a focus event (mode 1004): ESC [ I on focus, ESC [ O on blur.
/// Returns empty output when focus reporting is not enabled.
pub fn encodeFocus(
    gpa: std.mem.Allocator,
    t: *const vt.Terminal,
    focused: bool,
) ![]u8 {
    // Mode 1004 (focus event) is looked up through the call's parameter
    // type; @enumFromInt infers the enum from the get() signature.
    if (!t.modes.get(@enumFromInt(1004))) return &.{};

    var out: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(gpa, &out);
    defer w.deinit();
    try w.writer.writeAll(if (focused) "\x1b[I" else "\x1b[O");
    var list = std.Io.Writer.Allocating.toArrayList(&w);
    return list.toOwnedSlice(gpa);
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "parseButton and parseAction" {
    try testing.expectEqual(mouse.Button.left, parseButton("left").?);
    try testing.expectEqual(mouse.Button.four, parseButton("up").?);
    try testing.expectEqual(mouse.Button.nine, parseButton("9").?);
    try testing.expectEqual(@as(?mouse.Button, null), parseButton("10"));
    try testing.expectEqual(@as(?mouse.Button, null), parseButton("11"));
    try testing.expectEqual(@as(?mouse.Button, null), parseButton("nope"));
    try testing.expectEqual(mouse.Action.release, parseAction("release").?);
    try testing.expectEqual(@as(?mouse.Action, null), parseAction("drag"));
    const mods = parseMods("cs").?;
    try testing.expect(mods.ctrl and mods.shift and !mods.alt);
    try testing.expectEqual(@as(?key.Mods, null), parseMods("cx"));
}

test "parseEvent validates button and action combinations" {
    const hover = try parseEvent("none", "motion", "");
    try testing.expectEqual(@as(?mouse.Button, null), hover.button);
    try testing.expectError(error.NoButtonNeedsMotion, parseEvent("none", "press", ""));
    try testing.expectError(error.WheelHasNoRelease, parseEvent("up", "release", ""));
    try testing.expectError(error.InvalidMods, parseEvent("left", "press", "cc"));
}

test "no mouse reporting yields empty encoding" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    const out = try encodeMouse(testing.allocator, &term, 80, 24, .left, .press, .{}, 5, 3);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "sgr mouse press and release" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    // Enable SGR + button-event tracking via the real escape sequences.
    var stream = vt.TerminalStream.init(.{ .handler = term.vtHandler(), .allocator = testing.allocator });
    defer stream.deinit();
    stream.nextSlice("\x1b[?1002h\x1b[?1006h");

    const press = try encodeMouse(testing.allocator, &term, 80, 24, .left, .press, .{}, 5, 3);
    defer testing.allocator.free(press);
    try testing.expectEqualStrings("\x1b[<0;6;4M", press);

    const release = try encodeMouse(testing.allocator, &term, 80, 24, .left, .release, .{}, 5, 3);
    defer testing.allocator.free(release);
    try testing.expectEqualStrings("\x1b[<0;6;4m", release);
}

test "sgr modifiers and wheel" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    var stream = vt.TerminalStream.init(.{ .handler = term.vtHandler(), .allocator = testing.allocator });
    defer stream.deinit();
    stream.nextSlice("\x1b[?1000h\x1b[?1006h");

    const ctrl_shift = try encodeMouse(testing.allocator, &term, 80, 24, .right, .press, .{ .ctrl = true, .shift = true }, 10, 10);
    defer testing.allocator.free(ctrl_shift);
    try testing.expectEqualStrings("\x1b[<22;11;11M", ctrl_shift);

    const wheel = try encodeMouse(testing.allocator, &term, 80, 24, .four, .press, .{}, 1, 1);
    defer testing.allocator.free(wheel);
    try testing.expectEqualStrings("\x1b[<64;2;2M", wheel);
}

test "x10 format with no modifiers" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    var stream = vt.TerminalStream.init(.{ .handler = term.vtHandler(), .allocator = testing.allocator });
    defer stream.deinit();
    stream.nextSlice("\x1b[?9h");

    const press = try encodeMouse(testing.allocator, &term, 80, 24, .left, .press, .{ .ctrl = true }, 5, 3);
    defer testing.allocator.free(press);
    // X10: ESC [ M b+32 x+33 y+33; modifiers are not included.
    try testing.expectEqualStrings("\x1b[M\x20\x26\x24", press);
}

test "focus events require mode 1004" {
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);

    const off = try encodeFocus(testing.allocator, &term, true);
    defer testing.allocator.free(off);
    try testing.expectEqual(@as(usize, 0), off.len);

    var stream = vt.TerminalStream.init(.{ .handler = term.vtHandler(), .allocator = testing.allocator });
    defer stream.deinit();
    stream.nextSlice("\x1b[?1004h");

    const on = try encodeFocus(testing.allocator, &term, true);
    defer testing.allocator.free(on);
    try testing.expectEqualStrings("\x1b[I", on);

    const blur = try encodeFocus(testing.allocator, &term, false);
    defer testing.allocator.free(blur);
    try testing.expectEqualStrings("\x1b[O", blur);
}
