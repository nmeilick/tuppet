//! JSON-lines protocol between the tuppet CLI and the daemon, revision 2
//! (see docs/protocol.md).

const std = @import("std");
const status = @import("status.zig");
const cond = @import("cond.zig");
const alert = @import("alert.zig");

pub const Status = status.Status;
pub const Condition = cond.Condition;

/// The tuppet release version, reported by --version, XTVERSION, and hello.
pub const version = @import("build_options").version;

/// The built-in fonts of this build (lean, medium, or full), reported by
/// --version and hello.
pub const variant: []const u8 = @tagName(@import("build_options").variant);

/// The wire protocol revision reported by hello. Additions that old
/// clients can ignore keep it; any incompatible change bumps it.
pub const protocol_version = 2;

/// Optional capabilities reported by hello, so clients can check before
/// using them.
pub const features = [_][]const u8{ "alerts", "shutdown", "limits", "fonts" };

/// Why a request failed, for programs to act on; `err` says it for people.
pub const Code = enum {
    bad_request,
    no_session,
    ambiguous,
    elsewhere,
    ended,
    running,
    stale,
    guard,
    stalled,
    busy,
    limit,
    exists,
    no_alert,
    unsupported,
    /// The daemon is shutting down and takes no more work.
    stopping,
    /// The stored session cannot be loaded; its status says why.
    damaged,
    internal,
};

pub const RecordFormat = enum { cast, trace };
pub const ViewFormat = enum { plain, vt, html };
/// `preview`: watch without counting among the session's viewers.
pub const AttachMode = enum { read, write, preview };

/// What `run` does when a running session already has the name.
pub const IfExists = enum { fail, keep, replace };

pub const HelloReq = struct {
    cmd: []const u8 = "hello",
};

pub const RunReq = struct {
    cmd: []const u8 = "run",
    /// Required unless `like` gives it.
    argv: ?[]const []const u8 = null,
    name: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    cwd: ?[]const u8 = null,
    /// "NAME=value" entries for the child; null uses the daemon's own
    /// environment. TERM is always xterm-256color.
    env: ?[]const []const u8 = null,
    /// History limit in bytes; null means the daemon's default.
    scrollback: ?u64 = null,
    /// Record from the program's first byte.
    record: ?RunRecord = null,
    if_exists: IfExists = .fail,
    /// Wait for these conditions too: a second reply line follows, as
    /// `wait` replies. Needs `timeout_ms`.
    until: ?[]const Condition = null,
    timeout_ms: ?u64 = null,
    /// A session to copy argv, cwd, name, size, scrollback, and alerts
    /// from; the fields given here win.
    like: ?[]const u8 = null,
    /// Alerts that watch from the program's first byte.
    alerts: ?[]const Alert = null,
};

pub const Alert = alert.Rule;

pub const RunRecord = struct {
    /// Absolute path; null records into the session's store directory.
    path: ?[]const u8 = null,
    format: RecordFormat = .cast,
};

pub const ListReq = struct {
    cmd: []const u8 = "list",
    /// References that pick the sessions to list; null lists all.
    sessions: ?[]const []const u8 = null,
};

pub const ViewReq = struct {
    cmd: []const u8 = "view",
    session: []const u8,
    format: ViewFormat = .plain,
    /// Include the scrollback history above the screen.
    scrollback: bool = false,
    /// Join soft-wrapped rows into one line.
    unwrap: bool = false,
    /// Only the rows that changed after this seq.
    since: ?u64 = null,
    /// Add the styles of the rows shown; plain format only.
    styles: bool = false,
};

pub const PngReq = struct {
    cmd: []const u8 = "png",
    session: []const u8,
    /// Built-in font names, `default`, and absolute paths, tried in order;
    /// left out or empty means `default`.
    fonts: ?[]const []const u8 = null,
    /// Leave out TrueType faces: Unifont's look with 8x16 cells.
    bitmap: ?bool = null,
    /// Pixels per em of TrueType faces; bitmap faces keep their size.
    font_size: ?u16 = null,
};

pub const ResizeReq = struct {
    cmd: []const u8 = "resize",
    session: []const u8,
    cols: u16,
    rows: u16,
    require: ResizeRequire = .{},
};

/// The guard of a resize, checked under the lock the resize takes.
pub const ResizeRequire = struct {
    /// No writer is attached.
    unattended: bool = false,
};

pub const RenameReq = struct {
    cmd: []const u8 = "rename",
    session: []const u8,
    /// The new name; empty takes the name away.
    name: []const u8,
};

pub const InputReq = struct {
    cmd: []const u8 = "input",
    session: []const u8,
    steps: []const Step,
    require: Require = .{},
    /// Wait for these conditions too, as `run` does: a second reply line
    /// follows. Needs `timeout_ms`.
    until: ?[]const Condition = null,
    timeout_ms: ?u64 = null,
};

/// One step of an input batch; exactly one of its kinds is set.
pub const Step = struct {
    /// Written as it is.
    text: ?[]const u8 = null,
    /// Written the way a terminal pastes it.
    paste: ?[]const u8 = null,
    /// With text or paste: kept out of recordings.
    secret: bool = false,
    /// Keys in vim notation, encoded when the step runs.
    keys: ?[]const []const u8 = null,
    mouse: ?MouseStep = null,
    /// A focus-in (true) or focus-out event.
    focus: ?bool = null,
    sleep_ms: ?u64 = null,
};

pub const MouseStep = struct {
    button: []const u8,
    action: []const u8 = "press",
    mods: []const u8 = "",
    x: u16,
    y: u16,
};

/// Guards checked under the write lock before the first byte: a guard
/// that fails refuses the whole batch.
pub const Require = struct {
    /// No writer is attached.
    unattended: bool = false,
    /// No input came after the one with this input_seq.
    input_seq: ?u64 = null,
    /// The terminal reads input without echo.
    hidden_input: bool = false,
    /// The latest hit is the one with this number.
    hit_seq: ?u64 = null,
    /// No input came after the hit with this number, which the log still
    /// has.
    reply_to: ?u64 = null,
};

pub const AlertReq = struct {
    cmd: []const u8 = "alert",
    session: []const u8,
    /// Exactly one of add, remove, and list.
    add: ?Alert = null,
    /// The name of the alert to remove.
    remove: ?[]const u8 = null,
    list: bool = false,
};

pub const RecordReq = struct {
    cmd: []const u8 = "record",
    session: []const u8,
    /// Exactly one of start, mark, and stop.
    start: ?RecordStart = null,
    /// Append a marker to the active recording.
    mark: ?[]const u8 = null,
    stop: bool = false,
};

pub const RecordStart = struct {
    /// Absolute path; null records into the session's store directory.
    path: ?[]const u8 = null,
    format: RecordFormat,
    /// Also record input events in a cast; a trace always has them.
    input: bool = false,
    /// Stop once one of these conditions holds.
    until: ?[]const Condition = null,
    /// Stop this many milliseconds after the start.
    max_ms: ?u64 = null,
};

pub const WaitReq = struct {
    cmd: []const u8 = "wait",
    session: []const u8,
    /// Met when any of the conditions holds.
    until: []const Condition,
    timeout_ms: u64,
    /// Return the screen in this format with the outcome.
    format: ?ViewFormat = null,
    scrollback: bool = false,
    unwrap: bool = false,
};

pub const StopReq = struct {
    cmd: []const u8 = "stop",
    sessions: []const []const u8,
};

pub const RemoveReq = struct {
    cmd: []const u8 = "remove",
    sessions: []const []const u8,
    /// Stop running sessions first.
    force: bool = false,
};

/// Stop every session and the daemon; with `reset`, also delete the
/// stored sessions no live daemon serves and count ids from 1 again.
pub const ShutdownReq = struct {
    cmd: []const u8 = "shutdown",
    reset: bool = false,
};

pub const AckReq = struct {
    cmd: []const u8 = "ack",
    sessions: []const []const u8,
    /// What the client showed; null acknowledges everything there is.
    shown: ?status.Shown = null,
};

pub const EventsReq = struct {
    cmd: []const u8 = "events",
    /// References that pick the sessions, also ones renamed or started
    /// later; null or empty picks all.
    sessions: ?[]const []const u8 = null,
    /// Send idle and active edges for this much screen-text quiet.
    idle_ms: ?u64 = null,
};

pub const AttachReq = struct {
    cmd: []const u8 = "attach",
    session: []const u8,
    mode: AttachMode = .read,
    /// Take the writer role from the current writer.
    force: bool = false,
    /// What a writer calls itself, shown as the status's writer label.
    label: ?[]const u8 = null,
    /// A writer's terminal size, applied before the first redraw.
    cols: ?u16 = null,
    rows: ?u16 = null,
};

// ---- replies -------------------------------------------------------------

pub const HelloResp = struct {
    ok: bool = true,
    version: []const u8 = version,
    protocol: u32 = protocol_version,
    features: []const []const u8 = &features,
    variant: []const u8 = variant,
    /// The boot the daemon runs in; session ids are unique within it.
    boot: []const u8 = "",
};

/// The reply to `events`, before its frames.
pub const EventsResp = struct {
    ok: bool = true,
    boot: []const u8 = "",
};

/// A reply that only reports the session's status.
pub const StatusResp = struct {
    ok: bool = true,
    status: ?Status = null,
};

/// The reply to `run`: the session's status, and the boot its id is
/// unique in.
pub const RunResp = struct {
    ok: bool = true,
    status: ?Status = null,
    boot: []const u8 = "",
};

/// A session that `shutdown` could not stop.
pub const StopFailure = struct {
    id: u64,
    code: Code,
    err: []const u8,
    status: ?Status = null,
};

/// The reply to `shutdown`, sent right before the daemon exits.
pub const ShutdownResp = struct {
    ok: bool = true,
    /// The daemon's endpoint.
    socket: []const u8 = "",
    /// The sessions it stopped, with their status after the stop.
    stopped: []const Status = &.{},
    failed: []const StopFailure = &.{},
    /// The sessions a reset deleted; 0 without reset.
    removed: u64 = 0,
    /// The sessions left in the store: this endpoint's without reset,
    /// those of other live daemons after one.
    kept: u64 = 0,
    /// The id the next session gets.
    next_id: u64 = 1,
    boot: []const u8 = "",
};

/// The reply to `resize`.
pub const ResizeResp = struct {
    ok: bool = true,
    /// The seq of the reflow: what the program draws after the resize
    /// has a higher one. Null when the size did not change.
    resize_seq: ?u64 = null,
    status: ?Status = null,
};

pub const InputResp = struct {
    ok: bool = true,
    /// How many steps ran.
    done: u32 = 0,
    status: ?Status = null,
};

/// A request that a guard refused, and the guard.
pub const GuardFailure = struct {
    ok: bool = false,
    code: Code = .guard,
    err: []const u8,
    status: ?Status = null,
    guard: []const u8,
};

/// A failed input request: it says how many steps ran, and which guard
/// refused it.
pub const InputFailure = struct {
    ok: bool = false,
    code: Code,
    err: []const u8,
    status: ?Status = null,
    done: u32 = 0,
    guard: ?[]const u8 = null,
    matches: ?[]const Status = null,
};

pub const ListResp = struct {
    ok: bool = true,
    sessions: []const Status = &.{},
};

pub const Cursor = struct {
    /// 1-based, within the active screen.
    row: u16 = 1,
    col: u16 = 1,
};

pub const ViewResp = struct {
    ok: bool = true,
    text: []const u8 = "",
    cursor: Cursor = .{},
    /// Older lines were left out to fit the reply limit.
    truncated: bool = false,
    /// With `since`: the screen row of each line of `text`.
    rows: ?[]const i64 = null,
    /// The history lost older lines, to the scrollback limit or erased.
    history_dropped: bool = false,
    /// With `styles`: the base style and the runs that differ from it.
    styles: ?Styles = null,
    status: ?Status = null,
};

pub const Styles = @import("styles.zig").Styles;
pub const Attrs = @import("styles.zig").Attrs;
pub const Underline = @import("styles.zig").Underline;

/// The session's alerts after an alert request.
pub const AlertResp = struct {
    ok: bool = true,
    alerts: []const Alert = &.{},
    status: ?Status = null,
};

pub const PngResp = struct {
    ok: bool = true,
    /// Base64-encoded PNG of the active screen.
    png_b64: []const u8 = "",
    /// `bitmap`, or `ttf` when a TrueType face took part.
    renderer: []const u8 = "",
    /// The cell size in pixels, "WxH".
    cell: []const u8 = "",
    /// The faces that drew something: "drawn", built-in names, paths, "emoji".
    faces: []const []const u8 = &.{},
    status: ?Status = null,
};

/// How a recording stopped: a stop request, a condition of its `until`,
/// its `max_ms`, or the end of the session.
pub const StopReason = enum { request, met, max_ms, ended };

/// What a record request leaves: the session's latest recording.
pub const RecordResp = struct {
    ok: bool = true,
    /// Whether it is still recording.
    active: bool = false,
    /// How it stopped; null while it records.
    reason: ?StopReason = null,
    path: ?[]const u8 = null,
    status: ?Status = null,
};

/// How a wait ended: a condition was met, the time ran out, or the
/// session ended or was removed first.
pub const Outcome = enum { met, timeout, ended, removed };

pub const Hit = alert.Hit;

pub const WaitResp = struct {
    ok: bool = true,
    outcome: Outcome = .met,
    /// The index in `until` of the condition that was met.
    met: ?u32 = null,
    /// The screen, when the request asked for a format.
    text: ?[]const u8 = null,
    cursor: ?Cursor = null,
    /// The screen in that format did not fit the reply limit, so `text`
    /// and `cursor` are null.
    text_too_large: bool = false,
    /// The hits that meet the wait's hit conditions.
    hits: []const Hit = &.{},
    /// Hits after a condition's after_hit that the log dropped before the
    /// wait could see them.
    missed: u64 = 0,
    /// The input snapshot was truncated, so after_input matched the lines
    /// that changed after the input instead.
    snapshot_truncated: bool = false,
    /// Rows the wait could not check: they scrolled out of the history
    /// before a check, or a check had too many.
    lost: u64 = 0,
    status: ?Status = null,
};

/// The outcome for each session a stop or remove picked.
pub const Result = struct {
    /// The reference that picked it, as the request gave it.
    ref: []const u8 = "",
    id: ?u64 = null,
    ok: bool = false,
    code: ?Code = null,
    err: ?[]const u8 = null,
    status: ?Status = null,
};

pub const ResultsResp = struct {
    ok: bool = true,
    results: []const Result = &.{},
};

pub const Failure = struct {
    ok: bool = false,
    code: Code,
    err: []const u8,
    status: ?Status = null,
};

/// A reference that must pick one session picked several.
pub const Ambiguous = struct {
    ok: bool = false,
    code: Code = .ambiguous,
    err: []const u8,
    status: ?Status = null,
    matches: []const Status,
};

/// A failed reply as a client reads it.
pub const ErrorReply = struct {
    ok: bool = false,
    code: []const u8 = @tagName(Code.internal),
    err: []const u8 = "",
    status: ?Status = null,
    matches: ?[]const Status = null,
    done: ?u32 = null,
    guard: ?[]const u8 = null,
};

// ---- requests on the wire ------------------------------------------------

pub const EnvelopeError = error{
    RequestMustBeObject,
    MissingCommand,
    CommandMustBeString,
};

pub const Envelope = struct {
    cmd: []const u8,
    value: std.json.Value,
};

/// Parse a request line and its command name. The result may alias
/// `bytes` or live in `gpa`; callers must not free it.
pub fn parseEnvelope(gpa: std.mem.Allocator, bytes: []const u8) !Envelope {
    const req = try std.json.parseFromSliceLeaky(std.json.Value, gpa, bytes, .{});
    if (req != .object) return error.RequestMustBeObject;
    const cmd = req.object.get("cmd") orelse return error.MissingCommand;
    if (cmd != .string) return error.CommandMustBeString;
    return .{ .cmd = cmd.string, .value = req };
}

/// Where decoding a request failed, and how.
pub const Problem = struct {
    kind: enum { unknown, missing, invalid } = .invalid,
    /// Dotted path of the field, such as "record.path" or "argv[2]".
    path: std.ArrayListUnmanaged(u8) = .empty,
    /// What the field must be, for `invalid`.
    expected: []const u8 = "",

    /// The problem in words; allocated in `gpa`.
    pub fn message(p: *const Problem, gpa: std.mem.Allocator) ![]u8 {
        return switch (p.kind) {
            .unknown => std.fmt.allocPrint(gpa, "unknown field '{s}'", .{p.path.items}),
            .missing => std.fmt.allocPrint(gpa, "missing field '{s}'", .{p.path.items}),
            .invalid => if (p.path.items.len == 0)
                std.fmt.allocPrint(gpa, "the request must be {s}", .{p.expected})
            else
                std.fmt.allocPrint(gpa, "field '{s}' must be {s}", .{ p.path.items, p.expected }),
        };
    }
};

/// Decode `value` into `T` strictly: every field it has must be one of
/// `T`'s, also in nested objects, and every field of `T` without a
/// default must be there. On error.BadRequest, `problem` says why.
/// Strings alias `value`.
pub fn decode(comptime T: type, gpa: std.mem.Allocator, value: std.json.Value, problem: *Problem) !T {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (value == .null) return null;
            return try decode(o.child, gpa, value, problem);
        },
        .@"struct" => |s| {
            if (value != .object) return invalid(T, problem);
            var it = value.object.iterator();
            while (it.next()) |entry| {
                const known = inline for (s.field_names) |name| {
                    if (std.mem.eql(u8, name, entry.key_ptr.*)) break true;
                } else false;
                if (!known) {
                    try pushField(gpa, problem, entry.key_ptr.*);
                    problem.kind = .unknown;
                    return error.BadRequest;
                }
            }
            var out: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                if (value.object.get(name)) |field| {
                    const mark = problem.path.items.len;
                    try pushField(gpa, problem, name);
                    @field(out, name) = try decode(F, gpa, field, problem);
                    problem.path.shrinkRetainingCapacity(mark);
                } else if (attrs.defaultValue(F)) |default| {
                    @field(out, name) = default;
                } else {
                    try pushField(gpa, problem, name);
                    problem.kind = .missing;
                    return error.BadRequest;
                }
            }
            return out;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                if (value != .string) return invalid(T, problem);
                return value.string;
            }
            if (p.size != .slice or value != .array) return invalid(T, problem);
            const items = try gpa.alloc(p.child, value.array.items.len);
            for (value.array.items, 0..) |item, i| {
                const mark = problem.path.items.len;
                try problem.path.print(gpa, "[{d}]", .{i});
                items[i] = try decode(p.child, gpa, item, problem);
                problem.path.shrinkRetainingCapacity(mark);
            }
            return items;
        },
        .bool => {
            if (value != .bool) return invalid(T, problem);
            return value.bool;
        },
        .int => return switch (value) {
            .integer => |n| std.math.cast(T, n),
            // Integers past i64, such as a u64 above 2^63 - 1.
            .number_string => |text| parseDecimal(T, text),
            else => null,
        } orelse invalid(T, problem),
        .@"enum" => {
            if (value != .string) return invalid(T, problem);
            return std.meta.stringToEnum(T, value.string) orelse return invalid(T, problem);
        },
        // A union says itself which values it takes.
        .@"union" => return T.fromJson(value) orelse invalid(T, problem),
        else => @compileError("cannot decode " ++ @typeName(T)),
    }
}

fn pushField(gpa: std.mem.Allocator, problem: *Problem, name: []const u8) !void {
    if (problem.path.items.len > 0) try problem.path.append(gpa, '.');
    try problem.path.appendSlice(gpa, name);
}

fn invalid(comptime T: type, problem: *Problem) error{BadRequest} {
    problem.kind = .invalid;
    problem.expected = comptime expectedText(T);
    return error.BadRequest;
}

fn expectedText(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .@"struct" => "an object",
        .pointer => |p| if (p.child == u8) "a string" else "an array",
        .bool => "true or false",
        .int => std.fmt.comptimePrint("an integer from {d} to {d}", .{ std.math.minInt(T), std.math.maxInt(T) }),
        .@"enum" => |e| blk: {
            var text: []const u8 = "one of";
            for (e.field_names, 0..) |name, i| text = text ++ (if (i == 0) " " else ", ") ++ name;
            break :blk text;
        },
        .@"union" => T.expected,
        else => "a value",
    };
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

/// Requests leave unset optional fields out.
pub fn stringifyRequest(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
}

const testing = std.testing;

test "request envelope rejects invalid command shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try testing.expectError(error.RequestMustBeObject, parseEnvelope(gpa, "[]"));
    try testing.expectError(error.MissingCommand, parseEnvelope(gpa, "{}"));
    try testing.expectError(error.CommandMustBeString, parseEnvelope(gpa, "{\"cmd\":1}"));
    try testing.expectEqualStrings("list", (try parseEnvelope(gpa, "{\"cmd\":\"list\"}")).cmd);
}

test "requests are decoded strictly, naming the field at fault" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cases = [_]struct { line: []const u8, message: []const u8 }{
        .{ .line = "{\"cmd\":\"run\",\"argv\":[\"sh\"],\"record\":{\"pathx\":\"/a\"}}", .message = "unknown field 'record.pathx'" },
        .{ .line = "{\"cmd\":\"run\",\"argv\":[\"sh\"],\"until\":[{}],\"like\":3}", .message = "field 'like' must be a string" },
        .{ .line = "{\"cmd\":\"run\",\"argv\":[\"sh\",1]}", .message = "field 'argv[1]' must be a string" },
        .{ .line = "{\"cmd\":\"run\",\"argv\":[],\"cols\":70000}", .message = "field 'cols' must be an integer from 0 to 65535" },
        .{ .line = "{\"cmd\":\"run\",\"argv\":[],\"if_exists\":\"maybe\"}", .message = "field 'if_exists' must be one of fail, keep, replace" },
    };
    for (cases) |case| {
        const env = try parseEnvelope(gpa, case.line);
        var problem: Problem = .{};
        try testing.expectError(error.BadRequest, decode(RunReq, gpa, env.value, &problem));
        try testing.expectEqualStrings(case.message, try problem.message(gpa));
    }
    const env = try parseEnvelope(gpa, "{\"cmd\":\"run\",\"argv\":[\"sh\"],\"record\":{\"format\":\"trace\"}}");
    var problem: Problem = .{};
    const req = try decode(RunReq, gpa, env.value, &problem);
    try testing.expectEqual(RecordFormat.trace, req.record.?.format);
    try testing.expectEqual(IfExists.fail, req.if_exists);
    // A u64 takes what its error message promises.
    const big = try parseEnvelope(gpa, "{\"cmd\":\"run\",\"argv\":[\"sh\"],\"scrollback\":18446744073709551615}");
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), (try decode(RunReq, gpa, big.value, &problem)).scrollback);
}

test "decimal parsing accepts digits only" {
    try testing.expectEqual(@as(?u64, 10), parseDecimal(u64, "10"));
    try testing.expectEqual(@as(?u64, null), parseDecimal(u64, "+10"));
    try testing.expectEqual(@as(?u64, null), parseDecimal(u64, "1_0"));
}
