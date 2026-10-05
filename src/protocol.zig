//! JSON-lines protocol between the tuppet CLI and the daemon.

const std = @import("std");

/// The tuppet release version, reported by --version, XTVERSION, and hello.
pub const version = @import("build_options").version;

/// The wire protocol revision reported by hello. Additions that old
/// clients can ignore keep it; any incompatible change bumps it.
pub const protocol_version = 1;

/// Optional capabilities reported by hello, so clients can check before
/// using them.
pub const features = [_][]const u8{ "attach", "paste", "store", "scrollback", "run-record" };

pub const HelloResp = struct {
    ok: bool = true,
    version: []const u8 = version,
    protocol: u32 = protocol_version,
    features: []const []const u8 = &features,
    /// The boot the daemon runs in; session ids are unique within it.
    boot: []const u8 = "",
};

pub const RunReq = struct {
    cmd: []const u8 = "run",
    name: ?[]const u8 = null,
    cols: u16 = 120,
    rows: u16 = 40,
    cwd: ?[]const u8 = null,
    /// "NAME=value" entries for the child; null uses the daemon's own
    /// environment. TERM is always xterm-256color.
    env: ?[]const []const u8 = null,
    /// History limit in bytes; null means the daemon's default.
    scrollback: ?u64 = null,
    /// Record from the program's first byte.
    record: ?RunRecord = null,
    argv: []const []const u8,
};

pub const RunRecord = struct {
    /// Absolute path; null records into the session's store directory.
    path: ?[]const u8 = null,
    format: []const u8 = "cast",
};

pub const ListReq = struct {
    cmd: []const u8 = "list",
};

pub const SendReq = struct {
    cmd: []const u8 = "send",
    id: []const u8,
    data: []const u8,
    /// Deliver `data` as a paste: line endings become CR, and it is
    /// wrapped in bracketed-paste markers when the application enabled
    /// mode 2004.
    paste: bool = false,
};

pub const PasteResp = struct {
    ok: bool,
    err: ?[]const u8 = null,
    /// Whether the paste was wrapped in ESC[200~ ... ESC[201~.
    bracketed: bool = false,
};

pub const KeyReq = struct {
    cmd: []const u8 = "key",
    id: []const u8,
    keys: []const []const u8,
};

pub const MouseReq = struct {
    cmd: []const u8 = "mouse",
    id: []const u8,
    button: []const u8,
    action: []const u8 = "press",
    mods: []const u8 = "",
    x: u16 = 0,
    y: u16 = 0,
};

pub const FocusReq = struct {
    cmd: []const u8 = "focus",
    id: []const u8,
    focused: bool,
};

pub const ResizeReq = struct {
    cmd: []const u8 = "resize",
    id: []const u8,
    cols: u16,
    rows: u16,
};

pub const ViewReq = struct {
    cmd: []const u8 = "view",
    id: []const u8,
    format: []const u8 = "plain",
    /// Include the scrollback history above the screen (not with json).
    scrollback: bool = false,
};

pub const PngReq = struct {
    cmd: []const u8 = "png",
    id: []const u8,
};

pub const RecordReq = struct {
    cmd: []const u8 = "record",
    id: []const u8,
    /// Recording file path; null stops the active recording (unless
    /// `mark` is set).
    path: ?[]const u8 = null,
    /// Append a marker event to the active recording without stopping it.
    mark: ?[]const u8 = null,
    /// "cast" (asciicast v2) or "trace" (JSONL event timeline).
    format: []const u8 = "cast",
    /// Also log input events (key/send/mouse/focus/resize). Always on
    /// for the trace format.
    input: bool = false,
    /// Stop the recording once this text appears on the rendered screen.
    until_match: ?[]const u8 = null,
    /// Stop the recording this many milliseconds after it started.
    until_timeout_ms: ?u64 = null,
};

pub const RecordResp = struct {
    ok: bool,
    err: ?[]const u8 = null,
    /// Whether a recording is active after the request.
    active: bool = false,
    /// How the last recording stopped: "request", "match", "timeout",
    /// or "exit". Null when no recording has stopped yet.
    reason: ?[]const u8 = null,
};

pub const StopReq = struct {
    cmd: []const u8 = "stop",
    id: []const u8,
};

pub const RemoveReq = struct {
    cmd: []const u8 = "remove",
    id: []const u8,
};

pub const SessionInfo = struct {
    id: u64,
    name: []const u8,
    /// "running", "exited", or "lost" (its daemon stopped while it ran).
    state: []const u8,
    pid: i32,
    cols: u16,
    rows: u16,
    /// Set once the program has exited; death by signal n is -n.
    exit_code: ?i32 = null,
    /// The command line, as `run` received it.
    argv: []const []const u8 = &.{},
    /// Unix time in milliseconds.
    started_ms: ?i64 = null,
    ended_ms: ?i64 = null,
    /// Attached clients: whether one controls the session, and how many
    /// only watch.
    writer: bool = false,
    viewers: u32 = 0,
};

pub const RunResp = struct {
    ok: bool,
    err: ?[]const u8 = null,
    id: ?u64 = null,
};

pub const ListResp = struct {
    ok: bool,
    err: ?[]const u8 = null,
    sessions: ?[]SessionInfo = null,
};

pub const SendResp = struct {
    ok: bool,
    err: ?[]const u8 = null,
};

pub const ViewResp = struct {
    ok: bool,
    err: ?[]const u8 = null,
    text: ?[]const u8 = null,
    cols: u16 = 0,
    rows: u16 = 0,
    /// 1-based cursor position within the active screen.
    cursor_row: u16 = 1,
    cursor_col: u16 = 1,
    exited: bool = false,
    exit_code: ?i32 = null,
    idle_ms: u64 = 0,
    /// The recording made with `tuppet run --record`, if any.
    recording: ?[]const u8 = null,
};

pub const PngResp = struct {
    ok: bool,
    err: ?[]const u8 = null,
    /// Base64-encoded PNG of the active screen.
    png_b64: ?[]const u8 = null,
    cols: u16 = 0,
    rows: u16 = 0,
};

pub const CommandError = error{
    RequestMustBeObject,
    MissingCommand,
    CommandMustBeString,
};

/// Parses and validates the common request envelope before dispatch touches
/// command-specific fields. The returned string may alias `bytes` or live
/// in `gpa`; callers must not free it.
pub fn parseCommand(gpa: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const req = try std.json.parseFromSliceLeaky(std.json.Value, gpa, bytes, .{
        .ignore_unknown_fields = true,
    });
    if (req != .object) return error.RequestMustBeObject;
    const cmd = req.object.get("cmd") orelse return error.MissingCommand;
    if (cmd != .string) return error.CommandMustBeString;
    return cmd.string;
}

/// Parse a decimal number made of ASCII digits only: no sign, no
/// underscores, no whitespace, nothing that does not fit `T`.
pub fn parseDecimal(comptime T: type, text: []const u8) ?T {
    if (text.len == 0) return null;
    for (text) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

pub fn stringifyAlloc(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}

/// Requests leave unset optional fields out, so a daemon that predates a
/// field still accepts requests that do not use it.
pub fn stringifyRequest(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
}

test "request envelope rejects invalid command shapes" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try testing.expectError(error.RequestMustBeObject, parseCommand(gpa, "[]"));
    try testing.expectError(error.MissingCommand, parseCommand(gpa, "{}"));
    try testing.expectError(error.CommandMustBeString, parseCommand(gpa, "{\"cmd\":1}"));
    try testing.expectEqualStrings("list", try parseCommand(arena.allocator(), "{\"cmd\":\"list\"}"));
}

test "decimal parsing accepts digits only" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u64, 10), parseDecimal(u64, "10"));
    try testing.expectEqual(@as(?u64, null), parseDecimal(u64, "+10"));
    try testing.expectEqual(@as(?u64, null), parseDecimal(u64, "1_0"));
}
