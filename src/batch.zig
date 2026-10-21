//! Input batches: the steps of one `input` request (text, pastes, keys,
//! mouse and focus events, short sleeps), typed in order while the batch
//! holds the session's write lock, so no other input lands in between.
//! Its guards are checked under that lock before the first byte, and keys
//! and events are encoded when their step runs, against the terminal state
//! of that moment. One batch runs per session at a time.
//!
//! While a batch sleeps it still sends the replies the parser queues for
//! the program's queries (a counter wakes it), and it stops when the
//! program exits or, between steps, when its client hangs up.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const io_mod = @import("io.zig");
const protocol = @import("protocol.zig");
const keys_mod = @import("keys.zig");
const mouse_mod = @import("mouse.zig");
const trace_mod = @import("trace.zig");
const ptyio = @import("ptyio.zig");
const record = @import("record.zig");
const sample = @import("sample.zig");
const evaluator = @import("evaluator.zig");
const hangup = @import("hangup.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;

pub const max_steps = 1024;
pub const max_sleep_ms = 1000;
pub const max_sleeps_ms = 2000;
/// A batch writes for at most this long, the wait for the write lock
/// included; its sleeps come on top.
pub const write_budget_ns: i64 = 5 * std.time.ns_per_s;

/// The batch a session runs, if any.
pub const State = struct {
    active: std.atomic.Value(bool) = .init(false),
    /// Monotonic nanoseconds by which the running batch is over; 0 when
    /// none runs.
    deadline: std.atomic.Value(i64) = .init(0),
    /// Bumped and woken whenever a batch ends.
    ended: std.atomic.Value(u32) = .init(0),
    /// Bumped whenever the parser queues a reply; woken while a batch runs.
    replies: std.atomic.Value(u32) = .init(0),
};

/// A step that passed its checks.
pub const Plan = union(enum) {
    text: Text,
    paste: Text,
    keys: []const []const u8,
    mouse: Mouse,
    focus: bool,
    sleep_ms: u64,

    pub const Text = struct { bytes: []const u8, secret: bool = false };
    pub const Mouse = struct { event: mouse_mod.Event, x: u16, y: u16 };
};

pub const Checked = union(enum) {
    plans: []const Plan,
    /// Why the steps cannot run.
    bad: []const u8,
};

/// Check the steps of a request; strings alias `steps`, the rest lives in
/// `gpa`.
pub fn check(gpa: std.mem.Allocator, steps: []const protocol.Step) !Checked {
    if (steps.len == 0) return .{ .bad = "steps must not be empty" };
    if (steps.len > max_steps) return .{ .bad = try std.fmt.allocPrint(gpa, "steps takes at most {d} steps", .{max_steps}) };
    const plans = try gpa.alloc(Plan, steps.len);
    var sleeps: u64 = 0;
    for (steps, plans, 0..) |st, *p, i| {
        const kinds = @as(u8, @intFromBool(st.text != null)) + @intFromBool(st.paste != null) + @intFromBool(st.keys != null) +
            @intFromBool(st.mouse != null) + @intFromBool(st.focus != null) + @intFromBool(st.sleep_ms != null);
        if (kinds != 1) return .{ .bad = try std.fmt.allocPrint(gpa, "steps[{d}] needs exactly one of text, paste, keys, mouse, focus, and sleep_ms", .{i}) };
        if (st.secret and st.text == null and st.paste == null) return .{ .bad = try std.fmt.allocPrint(gpa, "steps[{d}].secret needs text or paste", .{i}) };
        if (st.text orelse st.paste) |text| {
            if (text.len == 0) return .{ .bad = try std.fmt.allocPrint(gpa, "steps[{d}].{s} must not be empty", .{ i, if (st.text != null) "text" else "paste" }) };
            p.* = if (st.text != null) .{ .text = .{ .bytes = text, .secret = st.secret } } else .{ .paste = .{ .bytes = text, .secret = st.secret } };
        } else if (st.keys) |tokens| {
            if (tokens.len == 0) return .{ .bad = try std.fmt.allocPrint(gpa, "steps[{d}].keys must not be empty", .{i}) };
            for (tokens, 0..) |tok, j| keys_mod.checkToken(tok) catch |err| {
                return .{ .bad = try std.fmt.allocPrint(gpa, "steps[{d}].keys[{d}] '{s}': {s}", .{ i, j, tok, keys_mod.errorText(err) }) };
            };
            p.* = .{ .keys = tokens };
        } else if (st.mouse) |m| {
            const event = mouse_mod.parseEvent(m.button, m.action, m.mods) catch |err| {
                return .{ .bad = try std.fmt.allocPrint(gpa, "steps[{d}].mouse: {s}", .{ i, mouse_mod.eventErrorText(err) }) };
            };
            p.* = .{ .mouse = .{ .event = event, .x = m.x, .y = m.y } };
        } else if (st.focus) |focused| {
            p.* = .{ .focus = focused };
        } else {
            const ms = st.sleep_ms.?;
            if (ms > max_sleep_ms) return .{ .bad = try std.fmt.allocPrint(gpa, "steps[{d}].sleep_ms must be at most {d}", .{ i, max_sleep_ms }) };
            sleeps += ms;
            if (sleeps > max_sleeps_ms) return .{ .bad = try std.fmt.allocPrint(gpa, "the sleeps add up to more than {d} ms", .{max_sleeps_ms}) };
            p.* = .{ .sleep_ms = ms };
        }
    }
    return .{ .plans = plans };
}

pub const Options = struct {
    require: protocol.Require = .{},
    /// The client's connection: the batch stops when it hangs up.
    client: ?std.posix.fd_t = null,
    /// Put on the session's evaluator right before the first byte, so it
    /// knows its needle before the input it waits after.
    waiter: ?*evaluator.Waiter = null,
};

pub const Guard = enum { unattended, input_seq, hidden_input, hit_seq, reply_to };

pub const Outcome = struct {
    /// Steps that ran.
    done: u32 = 0,
    err: ?anyerror = null,
    /// The key token `err` is about, when a key failed to encode.
    key: []const u8 = "",
    guard: ?Guard = null,
    /// The client went away; nobody gets a reply.
    hung_up: bool = false,
    /// The waiter is on the evaluator.
    registered: bool = false,
};

/// Run `plans` on `s`.
pub fn run(s: *Session, gpa: std.mem.Allocator, plans: []const Plan, opts: Options) Outcome {
    var out: Outcome = .{};
    if (s.state.load(.acquire) == .exited) {
        out.err = error.SessionExited;
        return out;
    }
    if (s.batch.active.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        out.err = error.BatchBusy;
        return out;
    }
    defer finish(s);
    const start = io_mod.nowNanos();
    var sleeps: i64 = 0;
    for (plans) |p| if (p == .sleep_ms) {
        sleeps += @as(i64, @intCast(p.sleep_ms)) * std.time.ns_per_ms;
    };
    s.batch.deadline.store(start + write_budget_ns + sleeps, .release);

    const io = io_mod.io();
    ptyio.lockWrite(s, start + write_budget_ns, false) catch |err| {
        out.err = err;
        return out;
    };
    defer ptyio.flushAfterWrite(s);
    defer s.write_mutex.unlock(io);
    if (refused(s, opts.require)) |guard| {
        out.guard = guard;
        return out;
    }
    if (!fitsGrid(s, plans)) {
        out.err = error.CoordinatesOutsideGrid;
        return out;
    }
    ptyio.markInput(s);
    if (opts.waiter) |w| out.registered = evaluator.register(s, w, false) catch |err| {
        out.err = err;
        return out;
    };
    var slept: i64 = 0;
    for (plans, 0..) |p, i| {
        if (i > 0 and builtin.os.tag == .linux) if (opts.client) |fd| if (hangup.hungUp(fd)) {
            out.hung_up = true;
            return out;
        };
        runStep(s, gpa, p, start + write_budget_ns, &slept, &out.key) catch |err| {
            out.err = err;
            return out;
        };
        out.done += 1;
    }
    return out;
}

fn finish(s: *Session) void {
    s.batch.deadline.store(0, .release);
    s.batch.active.store(false, .release);
    _ = s.batch.ended.fetchAdd(1, .release);
    io_mod.io().futexWake(u32, &s.batch.ended.raw, std.math.maxInt(u32));
}

/// The first guard of `req` that refuses the batch.
fn refused(s: *Session, req: protocol.Require) ?Guard {
    if (req.unattended) {
        s.lockTerminal();
        const attended = s.writer != null;
        s.unlockTerminal();
        if (attended) return .unattended;
    }
    if (req.input_seq) |seq| if (s.track.input_seq.load(.acquire) != seq) return .input_seq;
    if (req.hit_seq != null or req.reply_to != null) {
        s.lockTerminal();
        defer s.unlockTerminal();
        if (req.hit_seq) |n| if (s.hits.latest() != n) return .hit_seq;
        // An input at or after the hit's settle came after the hit.
        if (req.reply_to) |n| {
            const hit = s.hits.get(n) orelse return .reply_to;
            const input_seq = s.track.input_seq.load(.acquire);
            if (input_seq != 0 and input_seq >= hit.seq) return .reply_to;
        }
    }
    if (req.hidden_input) {
        sample.refresh(s, false);
        if (!sample.latest(s).hidden()) return .hidden_input;
    }
    return null;
}

/// Whether every mouse step lies inside the grid as it is now.
fn fitsGrid(s: *Session, plans: []const Plan) bool {
    s.lockTerminal();
    defer s.unlockTerminal();
    for (plans) |p| if (p == .mouse and (p.mouse.x >= s.cols or p.mouse.y >= s.rows)) return false;
    return true;
}

/// Run one step; `budget_end` is when writing must be done, not counting
/// the sleeps, which `slept` adds up.
fn runStep(s: *Session, gpa: std.mem.Allocator, p: Plan, budget_end: i64, slept: *i64, bad_key: *[]const u8) !void {
    if (s.child_exited.load(.acquire)) return error.SessionExited;
    if (p == .sleep_ms) {
        const before = io_mod.nowNanos();
        defer slept.* += io_mod.nowNanos() - before;
        return sleepFlushing(s, p.sleep_ms, budget_end + slept.* + @as(i64, @intCast(p.sleep_ms)) * std.time.ns_per_ms);
    }
    const bytes = blk: {
        s.lockTerminal();
        defer s.unlockTerminal();
        break :blk try encode(gpa, &s.terminal, s.cols, s.rows, p, bad_key);
    };
    defer gpa.free(bytes);
    // The program has mouse or focus reporting off.
    if (bytes.len == 0) return;
    var mods_buf: [4]u8 = undefined;
    record.recordInput(s, switch (p) {
        .text, .paste => |t| if (t.secret) .secret else .{ .send = bytes },
        .keys => |tokens| .{ .key = .{ .keys = tokens, .encoded = bytes } },
        .mouse => |m| .{ .mouse = .{
            .button = record.canonicalButtonName(m.event.button),
            .action = @tagName(m.event.action),
            .mods = record.modsString(&mods_buf, m.event.mods),
            .x = m.x,
            .y = m.y,
        } },
        .focus => |focused| .{ .focus = focused },
        .sleep_ms => unreachable,
    });
    ptyio.writeLocked(s, bytes, budget_end + slept.*) catch |err| {
        record.recordMark(s, "input not delivered") catch {};
        return err;
    };
}

/// The bytes a step writes, as the terminal `t` of `cols` x `rows` wants
/// them now; empty for an event the program does not ask for. A key that
/// fails leaves its token in `bad_key`. Caller owns the result.
pub fn encode(gpa: std.mem.Allocator, t: *const vt.Terminal, cols: u16, rows: u16, p: Plan, bad_key: *[]const u8) ![]u8 {
    switch (p) {
        .text => |text| return gpa.dupe(u8, text.bytes),
        .paste => |text| return ptyio.pasteBytes(gpa, text.bytes, t.modes.get(.bracketed_paste)),
        .keys => |tokens| {
            const bytes = try keys_mod.encodeAll(gpa, t, tokens, bad_key);
            if (bytes.len == 0) {
                gpa.free(bytes);
                return error.KeyNotEncodable;
            }
            return bytes;
        },
        .mouse => |m| {
            if (m.x >= cols or m.y >= rows) return error.CoordinatesOutsideGrid;
            const bytes = try mouse_mod.encodeMouse(gpa, t, cols, rows, m.event.button, m.event.action, m.event.mods, m.x, m.y);
            if (bytes.len == 0 and t.flags.mouse_event != .none) {
                gpa.free(bytes);
                return error.MouseEventNotReportable;
            }
            return bytes;
        },
        .focus => |focused| return mouse_mod.encodeFocus(gpa, t, focused),
        .sleep_ms => return &.{},
    }
}

/// Sleep `ms` while holding the write lock, sending the replies the parser
/// queues meanwhile by `deadline`; ends early with error.SessionExited.
fn sleepFlushing(s: *Session, ms: u64, deadline: i64) !void {
    const io = io_mod.io();
    const end = io_mod.nowNanos() + @as(i64, @intCast(ms)) * std.time.ns_per_ms;
    while (true) {
        if (s.child_exited.load(.acquire)) return error.SessionExited;
        const seen = s.batch.replies.load(.acquire);
        try ptyio.flushRepliesBlocking(s, deadline);
        const left = end - io_mod.nowNanos();
        if (left <= 0) return;
        // Also wakes now and then to notice that the program exited.
        io.futexWaitTimeout(u32, &s.batch.replies.raw, seen, .{
            .duration = .{ .raw = .fromNanoseconds(@min(left, 50 * std.time.ns_per_ms)), .clock = .boot },
        }) catch {};
    }
}

/// Wait until no batch runs on `s` or until `deadline` (monotonic);
/// returns whether none runs.
pub fn awaitIdle(s: *Session, deadline: i64) bool {
    const io = io_mod.io();
    while (true) {
        const seen = s.batch.ended.load(.acquire);
        if (!s.batch.active.load(.acquire)) return true;
        const left = deadline - io_mod.nowNanos();
        if (left <= 0) return false;
        io.futexWaitTimeout(u32, &s.batch.ended.raw, seen, .{
            .duration = .{ .raw = .fromNanoseconds(@min(left, 100 * std.time.ns_per_ms)), .clock = .boot },
        }) catch {};
    }
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

fn checked(a: std.mem.Allocator, json: []const u8) !Checked {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    var problem: protocol.Problem = .{};
    return check(a, try protocol.decode([]const protocol.Step, a, value, &problem));
}

test "steps are checked before anything runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try checked(a,
        \\[{"text":"ls","secret":true},{"keys":["<Enter>","x"]},{"mouse":{"button":"left","x":1,"y":2}},
        \\ {"focus":false},{"sleep_ms":1000},{"paste":"a\nb"},{"sleep_ms":1000}]
    );
    const plans = good.plans;
    try testing.expectEqual(@as(usize, 7), plans.len);
    try testing.expect(plans[0].text.secret);
    try testing.expectEqual(mouse_mod.Action.press, plans[2].mouse.event.action);
    try testing.expectEqual(@as(u64, 1000), plans[6].sleep_ms);

    const bad = [_]struct { json: []const u8, text: []const u8 }{
        .{ .json = "[]", .text = "steps must not be empty" },
        .{ .json = "[{\"text\":\"a\",\"keys\":[\"b\"]}]", .text = "steps[0] needs exactly one of" },
        .{ .json = "[{}]", .text = "steps[0] needs exactly one of" },
        .{ .json = "[{\"focus\":true,\"secret\":true}]", .text = "steps[0].secret needs text or paste" },
        .{ .json = "[{\"text\":\"\"}]", .text = "steps[0].text must not be empty" },
        .{ .json = "[{\"text\":\"a\"},{\"keys\":[\"<Bogus>\"]}]", .text = "steps[1].keys[0] '<Bogus>': unknown key name" },
        .{ .json = "[{\"mouse\":{\"button\":\"up\",\"action\":\"release\",\"x\":0,\"y\":0}}]", .text = "steps[0].mouse: the wheel" },
        .{ .json = "[{\"sleep_ms\":1001}]", .text = "steps[0].sleep_ms must be at most 1000" },
        .{ .json = "[{\"sleep_ms\":1000},{\"sleep_ms\":900},{\"sleep_ms\":101}]", .text = "the sleeps add up to more than 2000 ms" },
    };
    for (bad) |case| {
        const why = (try checked(a, case.json)).bad;
        if (!std.mem.startsWith(u8, why, case.text)) {
            std.debug.print("{s}: {s}\n", .{ case.json, why });
            return error.TestUnexpectedResult;
        }
    }
}

test "steps are encoded against the terminal state when they run" {
    const gpa = testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{ .cols = 20, .rows = 5 });
    defer term.deinit(gpa);
    var stream = vt.TerminalStream.init(.{ .handler = term.vtHandler(), .allocator = gpa });
    defer stream.deinit();
    const keys: Plan = .{ .keys = &.{ "<Up>", "x" } };
    const paste: Plan = .{ .paste = .{ .bytes = "a\nb" } };
    const click: Plan = .{ .mouse = .{ .event = try mouse_mod.parseEvent("left", "press", ""), .x = 2, .y = 1 } };
    const expect = struct {
        fn bytes(t: *const vt.Terminal, p: Plan, want: []const u8) !void {
            var bad: []const u8 = "";
            const got = try encode(testing.allocator, t, 20, 5, p, &bad);
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(want, got);
        }
    }.bytes;
    try expect(&term, keys, "\x1b[Ax");
    try expect(&term, paste, "a\rb");
    try expect(&term, click, "");
    try expect(&term, .{ .focus = true }, "");
    // The program asks for application cursor keys, bracketed paste,
    // SGR mouse reports, and focus events.
    stream.nextSlice("\x1b[?1h\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[?1004h");
    try expect(&term, keys, "\x1bOAx");
    try expect(&term, paste, "\x1b[200~a\rb\x1b[201~");
    try expect(&term, click, "\x1b[<0;3;2M");
    try expect(&term, .{ .focus = true }, "\x1b[I");
    var bad: []const u8 = "";
    try testing.expectError(error.CoordinatesOutsideGrid, encode(gpa, &term, 20, 5, .{ .mouse = .{ .event = click.mouse.event, .x = 20, .y = 0 } }, &bad));
    try testing.expectError(error.KeyNeedsKittyProtocol, encode(gpa, &term, 20, 5, .{ .keys = &.{ "x", "<C-S-Space>" } }, &bad));
    try testing.expectEqualStrings("<C-S-Space>", bad);
}
