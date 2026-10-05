const std = @import("std");

/// The type of action associated with a mouse event. This is different
/// from ButtonState because button state is simply the current state
/// of a mouse button but an action is something that triggers via
/// an GUI event and supports more.
pub const Action = enum(c_int) { press, release, motion };

/// The state of a mouse button.
pub const ButtonState = enum(c_int) {
    release,
    press,
};

/// Possible mouse buttons. We only track up to 11 because that's the maximum
/// button input that terminal mouse tracking handles without becoming
/// ambiguous.
pub const Button = enum(c_int) {
    const Self = @This();

    /// The maximum value in this enum. This can be used to create a densely
    /// packed array, for example.
    pub const max = max: {
        var cur = 0;
        for (@typeInfo(Self).@"enum".fields) |field| {
            if (field.value > cur) cur = field.value;
        }

        break :max cur;
    };

    unknown = 0,
    left = 1,
    right = 2,
    middle = 3,
    four = 4,
    five = 5,
    six = 6,
    seven = 7,
    eight = 8,
    nine = 9,
    ten = 10,
    eleven = 11,
};

/// The "momentum" of a mouse scroll event. This matches the macOS events
/// because it is the only reliable source right now of momentum events.
/// This is used to handle "inertial scrolling" (i.e. flicking).
pub const Momentum = enum(u3) {
    none = 0,
    began = 1,
    stationary = 2,
    changed = 3,
    ended = 4,
    cancelled = 5,
    may_begin = 6,
};

/// The pressure stage of a pressure-sensitive input device.
pub const PressureStage = enum(u2) {
    none = 0,
    normal = 1,
    deep = 2,
};

/// The bitmask for mods for scroll events.
pub const ScrollMods = packed struct(u8) {
    precision: bool = false,
    momentum: Momentum = .none,
    _padding: u4 = 0,
};
