//! The drawn attach (`tuppet attach --drawn`): tuppet paints the person's
//! terminal itself from copies of sessions' screens, and passes the
//! person's input to the programs in whole units.
//!
//! The client keeps the session's attach stream in the `write` role and
//! feeds its `screen` and `out` frames into a terminal of its own; the
//! program's output never reaches the person's terminal as written. What
//! does reach it is the painter's output (paint.zig), the input modes the
//! session that has the keyboard asked for, and the bell, notifications,
//! and clipboard writes the programs sent.
//!
//! Boxes over the session (docs/design.md, "Boxes") are found through
//! the events stream and attached in the role that boxes.zig gives them.
//! Each session's copy is painted into a layer of its own, which keeps its
//! last good state while the copy waits for a screen or the end of a
//! synchronized update, and a frame is composed from the layers: the
//! session underneath or its backdrop, a `--grab never` box, the open box,
//! tuppet's line. Nothing in the loop waits for the daemon: streams are
//! read and written without blocking, opened without waiting for their
//! reply, and fed into their copies a slice at a time.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const plat = @import("plat.zig");
const client = @import("client.zig");
const attach_client = @import("attach_client.zig");
const attach_filter = @import("attach_filter.zig");
const config_mod = @import("config.zig");
const paint = @import("paint.zig");
const copy = @import("copy.zig");
const boxes = @import("boxes.zig");
const status = @import("status.zig");
const store = @import("store.zig");
const words = @import("words.zig");
const limits = @import("limits.zig");
const group_mod = @import("group.zig");
const picker = @import("picker.zig");

const Outcome = attach_client.Outcome;
const Settings = attach_client.Settings;
const Role = boxes.Role;

/// Output that arrives this long after the last paint is painted at once.
const frame_ns: i64 = 33 * std.time.ns_per_ms;
/// A lone ESC is the Escape key once nothing follows it for this long.
const esc_wait_ns: i64 = 30 * std.time.ns_per_ms;
/// How long the rest of a sequence that has begun may take to arrive
/// before what came of it is passed on as it is.
const seq_wait_ns: i64 = 500 * std.time.ns_per_ms;
/// What came of a paste goes on after this long without input.
const paste_wait_ns: i64 = 1000 * std.time.ns_per_ms;
/// At the end, how long to wait for the terminal's answer to tuppet's
/// query, so it never reaches the shell.
const answer_wait_ns: i64 = 150 * std.time.ns_per_ms;
/// A broken stream is attached again every this long, for at most
/// `retry_for_ns`.
const retry_every_ns: i64 = 200 * std.time.ns_per_ms;
const retry_for_ns: i64 = 5000 * std.time.ns_per_ms;
/// How long a notice stays.
const notice_ns: i64 = 5000 * std.time.ns_per_ms;
/// How long the daemon may take to answer a request or an attach.
const reply_ns: i64 = ipc.request_timeout_ns;
/// After the window is resized, the normal screen waits this long at
/// most for the session's screen at the new size.
const resize_hold_ns: i64 = 500 * std.time.ns_per_ms;
/// How many older rows an attach that broke asks for again.
const catch_up_rows = 4096;
/// A box resized to fit is not asked again before this.
const resize_again_ns: i64 = 2000 * std.time.ns_per_ms;
/// A paste longer than this goes to the session in pieces of this size,
/// one right behind the other.
const max_paste = 256 * 1024;
/// Input is sent in data frames of at most this much, which holds the
/// largest unit.
const max_data = 512 * 1024;
/// An escape sequence that grows this long without ending is passed on.
const max_seq = 256;
/// How long one pass may spend on a stream's output, and on all of them,
/// so no stream holds up the painting of the others or the person's
/// input: some output takes far longer to apply than to read.
const stream_ns: i64 = 3 * std.time.ns_per_ms;
const pass_ns: i64 = 6 * std.time.ns_per_ms;
/// Output is fed into a copy this much at a time, with the clock read
/// between.
const feed_slice = 128;
/// A stream is not read while this much of it waits to be applied, and
/// takes no more data while this much waits to be sent.
const max_inbuf = 8 << 20;
const max_outq = 8 << 20;

/// Fails openly when the daemon cannot serve a drawn attach: a message
/// for the person, owned by `gpa`, or null when it can.
pub fn unsupported(gpa: std.mem.Allocator) !?[]u8 {
    if (builtin.os.tag == .windows) return try gpa.dupe(u8, "tuppet: --drawn is not available on Windows\n");
    if (try client.daemonSupports(gpa, "redraw_on_resize")) return null;
    return try gpa.dupe(u8, "tuppet: the daemon is an older tuppet without redraw_on_resize, which a drawn attach needs; attach without --drawn, or stop that daemon and let this tuppet start its own\n");
}

/// Attach this terminal to the session `ref` picks in a drawn attach,
/// until it detaches or the session ends. The terminal is restored
/// before this returns.
pub fn attach(gpa: std.mem.Allocator, ref: []const u8, settings: Settings, force: bool) !Outcome {
    if (builtin.os.tag == .windows) return error.Unsupported;
    if (try unsupported(gpa)) |message| return .{ .kind = .refused, .code = client.exit_code.failed, .message = message };
    const window = attach_client.terminalSize() orelse
        return .{ .kind = .refused, .code = client.exit_code.failed, .message = try gpa.dupe(u8, "tuppet: --drawn cannot tell this terminal's size\n") };
    // A group's members are sized with resize requests, never by this
    // attach's stream, so no writer's detach gives one its old size back.
    const size: ?[2]u16 = if (settings.resize and settings.group == null) window else null;
    var start: ?GroupStart = null;
    errdefer if (start) |*gs| gs.deinit(gpa);
    if (settings.group) |name| start = switch (try startGroup(gpa, name, ref, settings.end_with)) {
        .ok => |gs| gs,
        .refused => |message| return .{ .kind = .refused, .code = client.exit_code.failed, .message = message },
    };
    var front_buf: [20]u8 = undefined;
    const target = if (start) |gs| std.fmt.bufPrint(&front_buf, "{d}", .{gs.front}) catch unreachable else ref;
    const role: Role = if (start) |gs| (if (gs.elsewhere) .read else .write) else .write;
    var label_buf: [64]u8 = undefined;
    const label = settings.label orelse attach_client.terminalLabel(&label_buf);
    const normal = !settings.alt_screen and !settings.paint_alt;
    const has_history = normal and client.daemonSupports(gpa, "history") catch false;
    var history = settings.history;
    if (history > 0 and !has_history) {
        plat.stderrWriteAll(if (normal) "tuppet: the daemon is an older tuppet without --history; attaching without older lines\n" else "tuppet: --history needs the normal screen; attaching without older lines\n") catch {};
        history = 0;
    }
    const main = View.startWith(gpa, target, role, force, size, label, .{ .track = normal, .history = history, .pass = settings.pass }) catch |err| return err;
    if (main.wait()) |refused| {
        defer main.deinit();
        if (start) |*gs| gs.deinit(gpa);
        return .{ .kind = .refused, .code = refused.code, .message = try gpa.dupe(u8, refused.message) };
    }
    const file = if (settings.box_pause_ms == null or settings.set_aside == null) boxConfig(gpa) else null;
    var settled = settings;
    settled.set_aside = settings.set_aside orelse file.?.set_aside;
    var d: Drawn = .{
        .gpa = gpa,
        .settings = settled,
        .label = label,
        .main = .{ .id = main.id, .view = main, .layer = .init(gpa) },
        .main_role = role,
        .input = .{
            .detach_key = settings.detach_key,
            .switch_key = if (start != null) settings.switch_key else null,
            .side_key = if (start != null) settings.side.key else null,
        },
        // In a group the menu key opens the switcher, whose d detaches.
        .m = .{ .pause_ns = @intCast((settings.box_pause_ms orelse file.?.pause_ms) * std.time.ns_per_ms), .no_detach = settings.no_detach and start == null, .aside = settled.set_aside.? },
        .switcher = .{ .gpa = gpa, .no_detach = settings.no_detach },
        .ascii = !utf8Locale(),
        .color = colorWanted(),
        .pending = .init(gpa),
        .on_alt = !normal,
        .has_history = has_history,
    };
    defer d.deinit();
    if (d.color and d.settings.colors == null) d.settings.colors = queryColors();
    if (main.name) |name| d.under_name = gpa.dupe(u8, name) catch null;
    attach_client.ack(gpa, main.id, main.opened);
    if (start) |gs| {
        start = null;
        d.group = gs.group;
        d.events = gs.events;
        d.end_with = gs.end_with;
        d.front_elsewhere = gs.elsewhere;
        d.bar = gs.group.members.items.len > 1;
        d.m.setSynced(true, io_mod.nowNanos());
        if (gs.group.get(main.id)) |m| d.visit(m);
        d.addBoxes(io_mod.nowNanos());
    } else {
        d.events = Events.start(gpa) catch null;
        if (d.events == null or !d.events.?.wait()) {
            main.queue("{\"detach\":true}");
            return .{ .kind = .failed, .code = client.exit_code.failed, .message = try gpa.dupe(u8, "tuppet: cannot follow the daemon's events, which a drawn attach needs\n") };
        }
    }
    d.id_text = std.fmt.bufPrint(&d.id_buf, "{d}", .{main.id}) catch unreachable;
    if (!settings.resize and (main.terminal.cols > window[0] or main.terminal.rows > window[1]))
        d.setNotice("session {d} ({d}x{d}) is larger than this terminal ({d}x{d})", .{ main.id, main.terminal.cols, main.terminal.rows, window[0], window[1] });
    d.sent_size = size;
    var outcome = d.run();
    if (d.small) {
        // Its last screen is not on the normal screen.
        const note = "tuppet: the window was smaller than the session, so the attach ended on the alternate screen\n";
        const message = std.mem.concat(gpa, u8, &.{ note, outcome.message orelse "" }) catch null;
        if (message) |m| {
            if (outcome.message) |old| gpa.free(old);
            outcome.message = m;
        }
    }
    attach_client.settle(gpa, d.main.id, true, outcome, d.final);
    return outcome;
}

/// A group attach's members and events, before its first stream.
const GroupStart = struct {
    group: *group_mod.Group,
    events: *Events,
    /// The member in front first, and whether another client writes to it.
    front: u64,
    elsewhere: bool,
    end_with: ?u64,

    fn deinit(gs: *GroupStart, gpa: std.mem.Allocator) void {
        gs.group.deinit();
        gpa.destroy(gs.group);
        gs.events.deinit();
    }
};

/// Follow the events until they synced, which lists the group's members,
/// and pick the one in front: the one `ref` names, else the lowest
/// number. A message says why when there is none to show.
fn startGroup(gpa: std.mem.Allocator, name: []const u8, ref: []const u8, end_with: ?[]const u8) !union(enum) { ok: GroupStart, refused: []u8 } {
    const g = try gpa.create(group_mod.Group);
    g.* = .{ .gpa = gpa, .name = name };
    const events = Events.start(gpa) catch null;
    if (events == null or !events.?.wait()) {
        if (events) |e| e.deinit();
        g.deinit();
        gpa.destroy(g);
        return .{ .refused = try gpa.dupe(u8, "tuppet: cannot follow the daemon's events, which a drawn attach needs\n") };
    }
    var gs: GroupStart = .{ .group = g, .events = events.?, .front = 0, .elsewhere = false, .end_with = null };
    errdefer gs.deinit(gpa);
    const self = attach_client.selfSession(gpa) catch null;
    const until = io_mod.nowNanos() + reply_ns;
    while (!gs.events.synced) {
        const now = io_mod.nowNanos();
        if (now >= until or gs.events.ended) {
            gs.deinit(gpa);
            return .{ .refused = try gpa.dupe(u8, "tuppet: the daemon did not list its sessions\n") };
        }
        // Lines that came with the reply are taken before waiting for more.
        if (std.mem.indexOfScalarPos(u8, gs.events.in.items, gs.events.in_at, '\n') == null) {
            var fds = [1]std.c.pollfd{.{ .fd = gs.events.fd(), .events = std.c.POLL.IN, .revents = 0 }};
            _ = std.c.poll(&fds, 1, @intCast(@divTrunc(until - now, std.time.ns_per_ms) + 1));
            _ = gs.events.pump();
        }
        while (gs.events.nextLine()) |line| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const Frame = struct { type: []const u8 = "", status: ?protocol.Status = null };
            const f = std.json.parseFromSliceLeaky(Frame, arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
            if (std.mem.eql(u8, f.type, "synced")) {
                gs.events.synced = true;
                break;
            }
            const st = f.status orelse continue;
            _ = try g.seen(st);
            if (end_with) |e| if (picksStatus(e, st)) {
                gs.end_with = st.id;
            };
        }
    }
    if (end_with != null and gs.end_with == null) {
        const message = try std.fmt.allocPrint(gpa, "tuppet: no session '{s}' to end with\n", .{end_with.?});
        gs.deinit(gpa);
        return .{ .refused = message };
    }
    const front = if (ref.len == 0) (if (g.members.items.len > 0) g.members.items[0] else null) else for (g.members.items) |m| {
        if (picksStatus(ref, m.st().*)) break m;
    } else null;
    const m = front orelse {
        const message = if (ref.len == 0)
            try std.fmt.allocPrint(gpa, "tuppet: group '{s}' has no sessions\n", .{name})
        else
            try std.fmt.allocPrint(gpa, "tuppet: '{s}' is no member of group '{s}'\n", .{ ref, name });
        gs.deinit(gpa);
        return .{ .refused = message };
    };
    if (self) |id| if (g.get(id) != null) {
        const message = try std.fmt.allocPrint(gpa, "tuppet: session {d} is this terminal and a member of group '{s}'; showing it here would feed its screen back into itself\n", .{ id, name });
        gs.deinit(gpa);
        return .{ .refused = message };
    };
    gs.front = m.id;
    gs.elsewhere = m.st().writer != null;
    return .{ .ok = gs };
}

/// Whether `ref`, an id or a name, picks the session `st` describes.
fn picksStatus(ref: []const u8, st: protocol.Status) bool {
    if (protocol.parseDecimal(u64, ref)) |id| return id == st.id;
    return if (st.name) |n| std.mem.eql(u8, n, ref) else false;
}

/// `[attach] box_pause` and `set_aside` from the config file, for an
/// attach whose settings did not come from it.
fn boxConfig(gpa: std.mem.Allocator) struct { pause_ms: u64, set_aside: bool } {
    var diag: config_mod.Diagnostic = .{};
    var config = config_mod.load(gpa, &diag) catch return .{ .pause_ms = config_mod.default_box_pause_ms, .set_aside = true };
    defer config.deinit();
    return .{ .pause_ms = config.box_pause_ms, .set_aside = config.set_aside };
}

/// Keys typed while `queryColors` waited, which the attach reads first.
var typed_ahead: [512]u8 = undefined;
var typed_len: usize = 0;
/// `queryColors` asked already, in this process.
var colors_asked = false;
/// The terminal did not answer in time: its answers may still come, and
/// the attach drops them instead of passing them on as keys.
var answers_late = false;
const colors_wait_ns: i64 = 1000 * std.time.ns_per_ms;

/// The terminal's default foreground and background, asked once with OSC
/// 10 and 11 behind a DA1 query that every terminal answers last; null
/// when it did not tell both. What else was read is kept for the attach.
pub fn queryColors() ?[2]vt.color.RGB {
    if (builtin.os.tag == .windows or colors_asked) return null;
    colors_asked = true;
    const saved = plat.tcgetattr(0) catch return null;
    attach_client.setRaw(saved);
    defer {
        plat.tcsetattr(0, .NOW, saved) catch {};
        attach_client.forgetRaw();
    }
    plat.stdoutWriteAll("\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b[c") catch return null;
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    var answered = false;
    var until = io_mod.nowNanos() + colors_wait_ns;
    var extended = false;
    while (len < buf.len and !answered) {
        const now = io_mod.nowNanos();
        if (now >= until) {
            // An answer that has begun ends soon: its rest must not reach
            // the session as keys.
            if (extended or !splitAnswers(buf[0..len], null).cut) break;
            extended = true;
            until = now + colors_wait_ns;
        }
        var fds = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, @intCast(@divTrunc(until - now, std.time.ns_per_ms) + 1)) <= 0) continue;
        const n = std.c.read(0, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        answered = splitAnswers(buf[0..len], null).attributes;
    }
    answers_late = !answered;
    const got = splitAnswers(buf[0..len], &typed_ahead);
    typed_len = got.typed;
    const fg = got.fg orelse return null;
    const bg = got.bg orelse return null;
    return .{ fg, bg };
}

const Answers = struct {
    fg: ?vt.color.RGB = null,
    bg: ?vt.color.RGB = null,
    attributes: bool = false,
    /// The bytes end inside an answer.
    cut: bool = false,
    typed: usize = 0,
};

/// The terminal's answers among `bytes`, and with `typed` the bytes that
/// are not answers, copied there.
fn splitAnswers(bytes: []const u8, typed: ?[]u8) Answers {
    var out: Answers = .{};
    var i: usize = 0;
    while (i < bytes.len) {
        const rest = bytes[i..];
        if (std.mem.startsWith(u8, rest, "\x1b]10;") or std.mem.startsWith(u8, rest, "\x1b]11;")) {
            const bel = std.mem.indexOfScalar(u8, rest, 0x07);
            const st = std.mem.indexOf(u8, rest, "\x1b\\");
            const stop = if (bel != null and (st == null or bel.? < st.?)) bel.? + 1 else if (st) |e| e + 2 else blk: {
                out.cut = true;
                break :blk rest.len;
            };
            const color = colorAnswer(rest[0..stop], rest[0..5]);
            if (rest[3] == '0') out.fg = color else out.bg = color;
            i += stop;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "\x1b[?")) {
            var j: usize = 3;
            while (j < rest.len and (rest[j] < 0x40 or rest[j] > 0x7e)) j += 1;
            if (j < rest.len and rest[j] == 'c') {
                out.attributes = true;
                i += j + 1;
                continue;
            }
            if (j == rest.len) {
                out.cut = true;
                break;
            }
        }
        if (typed) |t| if (out.typed < t.len) {
            t[out.typed] = bytes[i];
            out.typed += 1;
        };
        i += 1;
    }
    return out;
}

/// The color in an answer such as "ESC ]11;rgb:ffff/ffff/eeee ST".
fn colorAnswer(bytes: []const u8, prefix: []const u8) ?vt.color.RGB {
    const at = std.mem.indexOf(u8, bytes, prefix) orelse return null;
    var rest = bytes[at + prefix.len ..];
    if (!std.mem.startsWith(u8, rest, "rgb:")) return null;
    rest = rest[4..];
    var out: [3]u8 = undefined;
    for (&out, 0..) |*channel, i| {
        var n: usize = 0;
        while (n < rest.len and n < 4 and std.ascii.isHex(rest[n])) n += 1;
        if (n == 0) return null;
        const v = std.fmt.parseInt(u16, rest[0..n], 16) catch return null;
        channel.* = switch (n) {
            1 => @intCast(v * 17),
            2 => @intCast(v),
            3 => @intCast(v >> 4),
            else => @intCast(v >> 8),
        };
        rest = rest[n..];
        if (i < 2) {
            if (rest.len == 0 or rest[0] != '/') return null;
            rest = rest[1..];
        }
    }
    return .{ .r = out[0], .g = out[1], .b = out[2] };
}

/// `a` moved toward `b` by `part`/255.
fn mixColor(a: vt.color.RGB, b: vt.color.RGB, part: u8) paint.Color {
    const mix = struct {
        fn mix(x: u8, y: u8, p: u8) u8 {
            const from: i32 = x;
            return @intCast(from + @divTrunc((@as(i32, y) - from) * p, 255));
        }
    }.mix;
    return .rgb(.{ .r = mix(a.r, b.r, part), .g = mix(a.g, b.g, part), .b = mix(a.b, b.b, part) });
}

/// Halfway between the terminal's foreground and background: the color
/// of the session behind a box.
fn dimColor(colors: [2]vt.color.RGB) paint.Color {
    const mix = struct {
        fn mix(a: u8, b: u8) u8 {
            return @intCast((@as(u16, a) + b) / 2);
        }
    }.mix;
    return .rgb(.{ .r = mix(colors[0].r, colors[1].r), .g = mix(colors[0].g, colors[1].g), .b = mix(colors[0].b, colors[1].b) });
}

/// NO_COLOR, when set and not empty, turns colors off.
fn colorWanted() bool {
    const env = std.c.getenv("NO_COLOR") orelse return true;
    return std.mem.span(env).len == 0;
}

/// Whether the locale says the terminal takes UTF-8; without one, tuppet's
/// own text is drawn in ASCII.
fn utf8Locale() bool {
    for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        const value = std.mem.span(std.c.getenv(name) orelse continue);
        if (value.len == 0) continue;
        return std.ascii.findIgnoreCase(value, "utf-8") != null or std.ascii.findIgnoreCase(value, "utf8") != null;
    }
    return false;
}

// ---- streams ------------------------------------------------------------

fn setNonblocking(fd: std.posix.fd_t) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags >= 0) _ = std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
}

/// Send what `q` holds without waiting; false when the stream broke.
fn flushQueue(fd: std.posix.fd_t, q: *std.ArrayList(u8), at: *usize) bool {
    while (at.* < q.items.len) {
        const flags = std.c.MSG.DONTWAIT | (if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0);
        const n = std.c.send(fd, q.items[at.*..].ptr, q.items.len - at.*, flags);
        if (n < 0) switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => break,
            else => return false,
        };
        if (n == 0) return false;
        at.* += @intCast(n);
    }
    if (at.* == q.items.len) {
        q.clearRetainingCapacity();
        at.* = 0;
    }
    return true;
}

/// Read what a stream has without waiting; false when it ended.
fn readInto(gpa: std.mem.Allocator, fd: std.posix.fd_t, buf: *std.ArrayList(u8)) bool {
    var chunk: [64 * 1024]u8 = undefined;
    const n = std.c.read(fd, &chunk, chunk.len);
    if (n < 0) return switch (std.posix.errno(n)) {
        .INTR, .AGAIN => true,
        else => false,
    };
    if (n == 0) return false;
    buf.appendSlice(gpa, chunk[0..@intCast(n)]) catch return false;
    return true;
}

/// Wait, before the loop runs, for a stream's first line.
fn awaitLine(fd: std.posix.fd_t, ctx: anytype, comptime pump: fn (@TypeOf(ctx)) bool, comptime done: fn (@TypeOf(ctx)) bool) bool {
    const until = io_mod.nowNanos() + reply_ns;
    while (!done(ctx)) {
        const now = io_mod.nowNanos();
        if (now >= until) return false;
        var fds = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, @intCast(@divTrunc(until - now, std.time.ns_per_ms) + 1)) < 0) continue;
        if (fds[0].revents != 0 and !pump(ctx)) return done(ctx);
    }
    return true;
}

/// An attach stream to one session, kept as a local terminal.
pub const View = struct {
    gpa: std.mem.Allocator,
    id: u64 = 0,
    role: Role,
    conn: ipc.Conn,
    /// The attach reply has not come yet.
    opening: bool = true,
    /// What was read and not yet applied, from `in_at` on; no newline
    /// before `scanned`.
    in: std.ArrayList(u8) = .empty,
    in_at: usize = 0,
    scanned: usize = 0,
    /// A frame's output, fed into the copy a slice at a time.
    feed: std.ArrayList(u8) = .empty,
    feed_at: usize = 0,
    feed_screen: bool = false,
    feed_history: bool = false,
    /// The rows of the screen being fed that the session wrapped, and
    /// whether its top row continues the row above.
    wrapped: std.ArrayList(u16) = .empty,
    continued: bool = false,
    /// No row has left this copy yet: the first that does continues
    /// what the view before it held, if that wrapped, as the copy cannot
    /// tell.
    first_row: bool = true,
    /// Frames waiting to be sent.
    outq: std.ArrayList(u8) = .empty,
    out_at: usize = 0,
    terminal: vt.Terminal = undefined,
    stream: copy.Stream = undefined,
    has_terminal: bool = false,
    /// The rows that leave the copy's primary screen are kept in `left`
    /// (the session underneath, for the person's scrollback).
    track: bool = false,
    left: paint.Lines = undefined,
    /// The number of the copy's top row among the session's rows, once a
    /// screen said it; `want` is the next row this copy expects, while it
    /// waits for older rows and its screen.
    top: ?u64 = null,
    want: ?u64 = null,
    /// History frames were fed into the copy.
    history_fed: bool = false,
    /// Which of the program's effects reach the person's terminal.
    pass: config_mod.Pass = .{},
    /// What the program sent for the person's terminal itself: bells,
    /// notifications, and clipboard writes, ready to write.
    effects: std.ArrayList(u8) = .empty,
    /// The screen frame being fed, which only rebuilds state.
    replaying: bool = false,
    /// The copy waits for a screen: the first, or the one after a resize.
    awaiting_screen: bool = true,
    /// What the attach reply showed, which the writer acks.
    opened: status.Shown = .{},
    name: ?[]u8 = null,
    /// The screen changed since the client looked.
    changed: bool = false,
    /// Set from the frames, for the client to act on.
    exit: ?Exit = null,
    /// The client acted on `exit` already.
    exit_seen: bool = false,
    end: ?End = null,
    taken: bool = false,
    hold: ?bool = null,
    err: ?[]u8 = null,
    refused: ?Refused = null,

    pub const Exit = struct { code: u8, message: []u8, final: ?status.Shown };
    pub const End = enum { exited, detach, too_slow, shutdown, other, broken };
    pub const Refused = struct {
        code: u8,
        message: []u8,
        /// The session has another writer.
        busy: bool = false,
    };

    /// Ask to attach to the session `ref` picks, with a fresh screen after
    /// every resize; the reply comes through `work`.
    pub fn start(gpa: std.mem.Allocator, ref: []const u8, role: Role, force: bool, size: ?[2]u16, label: ?[]const u8) !*View {
        return startWith(gpa, ref, role, force, size, label, .{});
    }

    /// What a stream of the session underneath asks for besides.
    pub const Extra = struct {
        /// Keep the rows that leave the copy.
        track: bool = false,
        history: u32 = 0,
        history_from: ?u64 = null,
        pass: config_mod.Pass = .{},
    };

    pub fn startWith(gpa: std.mem.Allocator, ref: []const u8, role: Role, force: bool, size: ?[2]u16, label: ?[]const u8, extra: Extra) !*View {
        var conn = try client.connect(gpa);
        errdefer conn.deinit();
        const req = try protocol.stringifyRequest(gpa, protocol.AttachReq{
            .session = ref,
            .mode = switch (role) {
                .write => .write,
                .read => .read,
                .preview, .none => .preview,
            },
            .force = force,
            .label = if (role == .write) label else null,
            .cols = if (size) |sz| sz[0] else null,
            .rows = if (size) |sz| sz[1] else null,
            .redraw_on_resize = true,
            .history = if (extra.history > 0) extra.history else null,
            .history_from = if (extra.history > 0) extra.history_from else null,
        });
        defer gpa.free(req);
        try conn.sendLine(req);
        setNonblocking(conn.posix.socket.handle);
        const v = try gpa.create(View);
        v.* = .{ .gpa = gpa, .role = role, .conn = conn, .track = extra.track, .want = extra.history_from, .pass = extra.pass };
        if (v.track) v.left = .init(gpa);
        return v;
    }

    /// Wait for the reply, before the loop runs: what refused the attach,
    /// or null when it is open.
    pub fn wait(v: *View) ?Refused {
        const Ctx = struct {
            fn pump(view: *View) bool {
                if (!view.pump()) return false;
                view.workAll();
                return true;
            }
            fn done(view: *View) bool {
                return !view.opening or view.refused != null or view.end != null;
            }
        };
        if (!awaitLine(v.fd(), v, Ctx.pump, Ctx.done) or v.opening) {
            if (v.refused == null) v.refused = .{ .code = client.exit_code.failed, .message = v.gpa.dupe(u8, "tuppet: the daemon did not answer the attach\n") catch &.{} };
        }
        return v.refused;
    }

    pub fn deinit(v: *View) void {
        const gpa = v.gpa;
        v.conn.deinit();
        v.in.deinit(gpa);
        v.feed.deinit(gpa);
        v.outq.deinit(gpa);
        v.effects.deinit(gpa);
        v.wrapped.deinit(gpa);
        if (v.name) |n| gpa.free(n);
        if (v.err) |e| gpa.free(e);
        if (v.exit) |e| gpa.free(e.message);
        if (v.refused) |r| gpa.free(r.message);
        if (v.has_terminal) {
            v.stream.deinit();
            v.terminal.deinit(gpa);
        }
        if (v.track) v.left.deinit();
        gpa.destroy(v);
    }

    pub fn fd(v: *View) std.posix.fd_t {
        return v.conn.posix.socket.handle;
    }

    /// Whether the copy holds a screen that can be painted.
    pub fn ready(v: *const View) bool {
        return v.has_terminal and !v.awaiting_screen and !v.feed_screen;
    }

    /// Whether `work` has more to do now.
    pub fn busy(v: *const View) bool {
        return v.end == null and v.refused == null and (v.feeding() or std.mem.indexOfScalarPos(u8, v.in.items, @max(v.in_at, v.scanned), '\n') != null);
    }

    /// Whether a frame's output is still to be fed; an empty screen still
    /// has to finish.
    fn feeding(v: *const View) bool {
        return v.feed_at < v.feed.items.len or v.feed_screen or v.feed_history;
    }

    /// Whether to poll the stream for reading.
    pub fn wantsInput(v: *const View) bool {
        return v.end == null and v.refused == null and v.in.items.len - v.in_at < max_inbuf;
    }

    /// Read what the daemon sent; false when the stream ended.
    pub fn pump(v: *View) bool {
        if (readInto(v.gpa, v.fd(), &v.in)) return true;
        if (v.end == null) v.end = .broken;
        return false;
    }

    /// Send what waits to be sent.
    pub fn flush(v: *View) void {
        if (!flushQueue(v.fd(), &v.outq, &v.out_at) and v.end == null) v.end = .broken;
    }

    /// A screen frame ends every row: mark those the session wrapped, so
    /// they leave the copy as one line.
    fn markWrapped(v: *View) void {
        const pages = &v.terminal.screens.active.pages;
        if (v.continued) if (pages.pin(.{ .active = .{} })) |top| {
            top.rowAndCell().row.wrap_continuation = true;
        };
        v.continued = false;
        for (v.wrapped.items) |y| {
            if (y +| 1 >= v.terminal.rows) continue;
            const pin = pages.pin(.{ .active = .{ .y = y } }) orelse continue;
            const next = pages.pin(.{ .active = .{ .y = y + 1 } }) orelse continue;
            pin.rowAndCell().row.wrap = true;
            next.rowAndCell().row.wrap_continuation = true;
        }
        v.wrapped.clearRetainingCapacity();
    }

    /// Apply what the daemon sent until `until`, and at least a slice.
    pub fn work(v: *View, until: i64) void {
        var first = true;
        while (v.end == null and (first or io_mod.nowNanos() < until)) {
            first = false;
            if (v.feeding()) {
                v.replaying = v.feed_screen or v.feed_history;
                v.feed_at += feedUntil(&v.stream, v.feed.items[v.feed_at..], until);
                v.replaying = false;
                if (v.feed_at == v.feed.items.len) {
                    v.feed.clearRetainingCapacity();
                    v.feed_at = 0;
                    // A screen only redraws: nothing it moves to history
                    // is a row of the session's.
                    if (v.feed_screen) {
                        v.awaiting_screen = false;
                        v.discardHistory();
                        v.markWrapped();
                    } else v.harvest();
                    v.feed_screen = false;
                    v.feed_history = false;
                    v.changed = true;
                } else {
                    if (!v.feed_screen) v.harvest();
                    if (!v.feed_screen and !v.feed_history) v.changed = true;
                }
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, v.in.items, @max(v.in_at, v.scanned), '\n') orelse {
                v.scanned = v.in.items.len;
                break;
            };
            const line = v.in.items[v.in_at..end];
            v.in_at = end + 1;
            if (v.opening) v.reply(line) else v.frame(line);
            if (v.refused != null) break;
        }
        if (v.in_at > 0 and (v.in_at == v.in.items.len or v.in_at > 1 << 20)) {
            v.in.replaceRange(v.gpa, 0, v.in_at, &.{}) catch {};
            v.scanned -|= v.in_at;
            v.in_at = 0;
        }
    }

    /// Wait, before the loop runs, for everything that came so far.
    fn workAll(v: *View) void {
        while (v.busy()) v.work(std.math.maxInt(i64));
    }

    fn reply(v: *View, line: []const u8) void {
        const gpa = v.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = std.json.parseFromSliceLeaky(struct { ok: bool, status: ?protocol.Status = null, code: []const u8 = "", err: []const u8 = "" }, a, line, .{ .ignore_unknown_fields = true }) catch {
            v.refuse(client.exit_code.failed, "tuppet: the daemon sent a malformed reply\n", .{});
            return;
        };
        if (!r.ok) {
            v.refuse(client.exitFor(r.code), "tuppet: {f}\n", .{status.cleaned(r.err)});
            v.refused.?.busy = std.mem.eql(u8, r.code, @tagName(protocol.Code.busy));
            return;
        }
        const st = r.status orelse {
            v.refuse(client.exit_code.failed, "tuppet: the daemon sent a malformed reply\n", .{});
            return;
        };
        if (limits.sizeError(st.cols, st.rows)) |why| {
            v.refuse(client.exit_code.failed, "tuppet: the session's size {d}x{d} cannot be shown: {s}\n", .{ st.cols, st.rows, why });
            return;
        }
        v.terminal = vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{
            .cols = st.cols,
            .rows = st.rows,
            // Rows that leave the copy are taken out after every slice.
            .max_scrollback_bytes = if (v.track) 64 << 20 else 0,
            .kitty_image_storage_limit = 0,
        }) catch {
            v.refuse(client.exit_code.failed, "tuppet: out of memory\n", .{});
            return;
        };
        var handler = v.terminal.vtHandler();
        handler.effects = .readonly;
        handler.effects.bell = &onBell;
        handler.effects.desktop_notification = &onNotification;
        handler.effects.clipboard_write = &onClipboardWrite;
        // Kitty clipboard writes are answered by the daemon, which has no
        // clipboard; only OSC 52 writes are passed on, as by a raw attach.
        handler.kitty_clipboard_write_max_bytes = 0;
        v.stream = copy.Stream.init(.{ .handler = .{ .inner = handler, .before_loss = &beforeLoss, .ctx = v }, .allocator = gpa });
        v.has_terminal = true;
        v.id = st.id;
        v.opened = status.shownOf(st);
        if (st.name) |n| v.name = gpa.dupe(u8, n) catch null;
        v.opening = false;
    }

    fn refuse(v: *View, code: u8, comptime fmt: []const u8, args: anytype) void {
        v.refused = .{ .code = code, .message = std.fmt.allocPrint(v.gpa, fmt, args) catch &.{} };
    }

    fn beforeLoss(ctx: *anyopaque) void {
        const v: *View = @ptrCast(@alignCast(ctx));
        // What a screen moves to history is dropped when it is fed.
        if (!v.feed_screen) v.harvest();
    }

    /// Move the rows that left the copy's primary screen into `left`.
    fn harvest(v: *View) void {
        if (!v.track) return;
        const screen = v.terminal.screens.get(.primary) orelse return;
        const pages = &screen.pages;
        const n = pages.total_rows - pages.rows;
        if (n == 0) return;
        for (0..n) |i| {
            const pin = pages.pin(.{ .history = .{ .y = @intCast(i) } }) orelse continue;
            v.left.push(&v.terminal, pin, v.first_row);
            v.first_row = false;
        }
        screen.eraseHistory(null);
        if (v.top) |*t| t.* +|= n;
    }

    /// Drop the rows in the copy's history, which are no rows of the
    /// session's.
    fn discardHistory(v: *View) void {
        if (!v.track) return;
        const screen = v.terminal.screens.get(.primary) orelse return;
        const pages = &screen.pages;
        if (pages.total_rows > pages.rows) screen.eraseHistory(null);
    }

    const Frame = struct {
        history: ?[]const u8 = null,
        row: ?u64 = null,
        rows: ?u64 = null,
        screen: ?[]const u8 = null,
        /// The screen's rows that the session wrapped into the next.
        wrapped: ?[]const u16 = null,
        /// The screen's top row continues the row above it.
        continued: bool = false,
        out: ?[]const u8 = null,
        resize: ?struct { cols: u16, rows: u16 } = null,
        exit: ?struct { code: ?i32 = null, signal: ?[]const u8 = null } = null,
        status: ?protocol.Status = null,
        writer: ?[]const u8 = null,
        hold: ?bool = null,
        @"error": ?struct { code: []const u8 = "", err: []const u8 = "" } = null,
        end: ?struct { reason: []const u8 = "" } = null,
    };

    fn frame(v: *View, line: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(v.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const f = std.json.parseFromSliceLeaky(Frame, a, line, .{ .ignore_unknown_fields = true }) catch return;
        if (f.resize) |r| {
            // The copy has no history to reflow from: the daemon sends a
            // fresh screen next, which rebuilds it at this size. What the
            // copy's own reflow moves into history left the session's
            // screen too, and is held for the scrollback as any row that
            // leaves: the person's terminal may show other rows by now.
            if (limits.sizeError(r.cols, r.rows) == null and (r.cols != v.terminal.cols or r.rows != v.terminal.rows)) {
                v.harvest();
                v.terminal.resize(v.gpa, .{ .cols = r.cols, .rows = r.rows }) catch {};
                v.harvest();
            }
            v.awaiting_screen = true;
        }
        if (f.history != null and v.track) {
            // Older rows of the session: fed into the copy from its top,
            // they scroll into its history as rows on a terminal would.
            if (v.want) |want| if (f.row) |row| if (row > want) v.left.leftOut(row - want);
            if (f.row) |row| v.want = row +| (f.rows orelse 0);
            v.history_fed = true;
        }
        if (f.screen != null and v.track) {
            if (v.history_fed) {
                v.pushHistory();
                v.history_fed = false;
            }
            v.harvest();
            if (f.row) |row| {
                // Rows the copy never had: left out, said here.
                if (v.want) |want| if (row > want) v.left.leftOut(row - want);
                v.top = row;
            }
            v.want = null;
        }
        if (f.screen orelse f.out orelse (if (v.track) f.history else null)) |b64| {
            const dec = std.base64.standard.Decoder;
            const len = dec.calcSizeForSlice(b64) catch return;
            v.feed.resize(v.gpa, len) catch return;
            dec.decode(v.feed.items, b64) catch {
                v.feed.clearRetainingCapacity();
                return;
            };
            v.feed_at = 0;
            v.feed_screen = f.screen != null;
            v.feed_history = f.history != null;
            v.wrapped.clearRetainingCapacity();
            v.continued = f.screen != null and f.continued;
            if (f.screen != null) if (f.wrapped) |rows| v.wrapped.appendSlice(v.gpa, rows) catch {};
        }
        if (f.writer != null) {
            v.role = .read;
            v.taken = true;
        }
        if (f.hold) |h| v.hold = h;
        if (f.@"error") |e| {
            if (v.err) |old| v.gpa.free(old);
            v.err = v.gpa.dupe(u8, e.err) catch null;
        }
        if (f.exit) |e| if (v.exit == null) {
            const final = if (f.status) |st| status.shownOf(st) else null;
            if (e.code) |c| {
                const message = std.fmt.allocPrint(v.gpa, "tuppet: session exited with code {d}\n", .{c}) catch return;
                v.exit = .{ .code = @intCast(@as(u32, @bitCast(c)) & 0xff), .message = message, .final = final };
            } else {
                const sig = e.signal orelse "unknown signal";
                const message = std.fmt.allocPrint(v.gpa, "tuppet: session killed by {f}\n", .{status.cleaned(sig)}) catch return;
                v.exit = .{ .code = @truncate(128 + attach_client.signalNumber(sig)), .message = message, .final = final };
            }
        };
        if (f.end) |e| if (v.end == null) {
            v.end = std.meta.stringToEnum(End, e.reason) orelse .other;
        };
    }

    /// The older rows fed so far that are still on the copy's screen go
    /// into its history: from the bottom row, a line feed for each.
    fn pushHistory(v: *View) void {
        const cur = v.terminal.screens.active.cursor;
        const n = cur.y + @intFromBool(cur.x > 0 or cur.pending_wrap);
        if (n == 0) return;
        // The newest older row wraps into the screen's top row: the wrap
        // is only pending, and moving the cursor would forget it.
        if (cur.pending_wrap) if (v.terminal.screens.active.pages.pin(.{ .active = .{ .y = cur.y } })) |pin| {
            pin.rowAndCell().row.wrap = true;
        };
        var buf: [32]u8 = undefined;
        v.stream.nextSlice(std.fmt.bufPrint(&buf, "\x1b[0m\x1b[{d};1H", .{v.terminal.rows}) catch return);
        for (0..n) |_| v.stream.nextSlice("\n");
        v.harvest();
    }

    /// Queue a frame for the daemon; it goes as the stream takes it.
    pub fn queue(v: *View, line: []const u8) void {
        if (v.end != null) return;
        if (v.outq.items.len + line.len + 1 > max_outq) return;
        v.outq.ensureUnusedCapacity(v.gpa, line.len + 1) catch return;
        v.outq.appendSliceAssumeCapacity(line);
        v.outq.appendAssumeCapacity('\n');
        v.flush();
    }

    /// Send input to the session, in data frames the daemon takes.
    pub fn sendData(v: *View, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const part = rest[0..@min(rest.len, max_data)];
            rest = rest[part.len..];
            const enc = std.base64.standard.Encoder;
            const line = v.gpa.alloc(u8, "{\"data\":\"\"}".len + enc.calcSize(part.len)) catch return;
            defer v.gpa.free(line);
            @memcpy(line[0..9], "{\"data\":\"");
            _ = enc.encode(line[9 .. line.len - 2], part);
            @memcpy(line[line.len - 2 ..], "\"}");
            v.queue(line);
        }
    }

    fn of(h: *vt.TerminalStream.Handler) ?*View {
        const v: *View = @fieldParentPtr("terminal", h.terminal);
        return if (v.replaying) null else v;
    }

    fn onBell(h: *vt.TerminalStream.Handler) void {
        const v = of(h) orelse return;
        if (!v.pass.bell) return;
        v.effects.append(v.gpa, 0x07) catch {};
    }

    /// Notifications pass with their text cleaned as titles are.
    fn onNotification(h: *vt.TerminalStream.Handler, n: vt.StreamAction.ShowDesktopNotification) void {
        const v = of(h) orelse return;
        if (!v.pass.notifications) return;
        const note = status.notificationOf(v.gpa, n.title, n.body, 0) catch return;
        defer status.freeNotification(v.gpa, note);
        var w: std.Io.Writer.Allocating = .fromArrayList(v.gpa, &v.effects);
        defer v.effects = w.toArrayList();
        if (note.title) |title| {
            w.writer.print("\x1b]777;notify;{s};{s}\x1b\\", .{ title, note.text }) catch {};
        } else w.writer.print("\x1b]9;{s}\x1b\\", .{note.text}) catch {};
    }

    /// Clipboard writes pass as OSC 52; a request to read it never does,
    /// since no read effect is set.
    fn onClipboardWrite(h: *vt.TerminalStream.Handler, req: vt.clipboard.Write) void {
        defer req.reply(.{ .success = .{} });
        const v = of(h) orelse return;
        if (!v.pass.clipboard) return;
        const where: u8 = switch (req.location) {
            .selection => 's',
            .primary => 'p',
            else => 'c',
        };
        // No contents clears the clipboard.
        var text: ?[]const u8 = if (req.contents.len == 0) "" else null;
        for (req.contents) |c| {
            if (vt.clipboard.isTextMime(c.mime)) {
                text = c.data;
                break;
            }
        }
        const data = text orelse return;
        const enc = std.base64.standard.Encoder;
        v.effects.ensureUnusedCapacity(v.gpa, 16 + enc.calcSize(data.len)) catch return;
        v.effects.appendSliceAssumeCapacity("\x1b]52;");
        v.effects.appendAssumeCapacity(where);
        v.effects.appendAssumeCapacity(';');
        const at = v.effects.items.len;
        v.effects.items.len += enc.calcSize(data.len);
        _ = enc.encode(v.effects.items[at..], data);
        v.effects.appendSliceAssumeCapacity("\x1b\\");
    }
};

/// The daemon's events about every session: the bell when another session
/// comes to need attention, and the boxes over the attached one.
const Events = struct {
    gpa: std.mem.Allocator,
    conn: ipc.Conn,
    opening: bool = true,
    in: std.ArrayList(u8) = .empty,
    in_at: usize = 0,
    ended: bool = false,
    synced: bool = false,
    /// When the tries to open it again began, until it syncs.
    retry_since: ?i64 = null,
    /// The sessions that need attention now.
    marked: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn start(gpa: std.mem.Allocator) !*Events {
        var conn = try client.connect(gpa);
        errdefer conn.deinit();
        try client.sendRequest(gpa, &conn, protocol.EventsReq{});
        setNonblocking(conn.posix.socket.handle);
        const e = try gpa.create(Events);
        e.* = .{ .gpa = gpa, .conn = conn };
        return e;
    }

    /// Wait for the reply, before the loop runs.
    fn wait(e: *Events) bool {
        const Ctx = struct {
            fn pump(ev: *Events) bool {
                return ev.pump();
            }
            fn done(ev: *Events) bool {
                return !ev.opening or ev.ended;
            }
        };
        _ = awaitLine(e.fd(), e, Ctx.pump, Ctx.done);
        return !e.opening and !e.ended;
    }

    fn deinit(e: *Events) void {
        e.conn.deinit();
        e.in.deinit(e.gpa);
        e.marked.deinit(e.gpa);
        e.gpa.destroy(e);
    }

    fn fd(e: *Events) std.posix.fd_t {
        return e.conn.posix.socket.handle;
    }

    /// Read what the daemon sent and take the reply; false once the stream
    /// is over.
    fn pump(e: *Events) bool {
        if (!readInto(e.gpa, e.fd(), &e.in)) e.ended = true;
        if (e.opening) if (e.nextLine()) |line| {
            const ok = std.json.parseFromSlice(struct { ok: bool = false }, e.gpa, line, .{ .ignore_unknown_fields = true }) catch null;
            defer if (ok) |r| r.deinit();
            if (ok == null or !ok.?.value.ok) e.ended = true;
            e.opening = false;
        };
        return !e.ended;
    }

    fn nextLine(e: *Events) ?[]const u8 {
        const end = std.mem.indexOfScalarPos(u8, e.in.items, e.in_at, '\n') orelse {
            if (e.in_at > 0) {
                e.in.replaceRange(e.gpa, 0, e.in_at, &.{}) catch {};
                e.in_at = 0;
            }
            return null;
        };
        const line = e.in.items[e.in_at..end];
        e.in_at = end + 1;
        return line;
    }
};

/// A request whose reply nobody waits for, such as a box's resize; it is
/// read and dropped when it comes.
const Request = struct {
    gpa: std.mem.Allocator,
    conn: ipc.Conn,
    started: i64,
    in: std.ArrayList(u8) = .empty,

    fn start(gpa: std.mem.Allocator, req: anytype, now: i64) !*Request {
        var conn = try client.connect(gpa);
        errdefer conn.deinit();
        try client.sendRequest(gpa, &conn, req);
        setNonblocking(conn.posix.socket.handle);
        const r = try gpa.create(Request);
        r.* = .{ .gpa = gpa, .conn = conn, .started = now };
        return r;
    }

    fn deinit(r: *Request) void {
        r.conn.deinit();
        r.in.deinit(r.gpa);
        r.gpa.destroy(r);
    }

    fn fd(r: *Request) std.posix.fd_t {
        return r.conn.posix.socket.handle;
    }

    /// Read what came: true once the reply is in or the stream is over.
    fn pump(r: *Request) bool {
        if (!readInto(r.gpa, r.fd(), &r.in)) return true;
        return std.mem.indexOfScalar(u8, r.in.items, '\n') != null;
    }
};

// ---- the client ------------------------------------------------------

const Retry = struct { since: i64, next: i64 };
/// The switcher previews at most this many members.
const max_previews = 32;
/// After a switch, keys are dropped at most this long while the terminal
/// does not answer.
const hold_ns: i64 = 2000 * std.time.ns_per_ms;
/// How long the bar says how many keys were dropped.
const dropped_ns: i64 = 2000 * std.time.ns_per_ms;

/// A session the client shows: the attached one or a box, with its
/// stream, the stream it opens in another role, and its layer.
const Slot = struct {
    id: u64,
    view: ?*View = null,
    /// Opening in another role, or again after a break; it replaces
    /// `view` when its reply has come.
    next: ?*View = null,
    /// The copy as last painted, kept while the copy waits.
    layer: paint.Canvas,
    cursor: paint.Cursor = .{},
    /// The row the program's cursor is in, also when it is hidden.
    cursor_row: usize = 0,
    /// The layer holds a screen of the session.
    shown: bool = false,
    /// Since when the copy has changes the layer does not show.
    dirty_at: ?i64 = null,
    /// When the stream may be opened again after it broke.
    retry_at: i64 = 0,
    /// A box's: how it was started, and the size it started with.
    grab: status.Grab = .pause,
    backdrop: ?status.Backdrop = null,
    title: boxes.Title = .{},
    start: [2]u16 = .{ 0, 0 },
    placed: ?boxes.Placed = null,
    resized_to: ?[2]u16 = null,
    resized_at: i64 = 0,
    /// The size before this client shrank the box to fit the window: it
    /// grows back to it as far as the window allows.
    shrunk_from: ?[2]u16 = null,
    /// Listed again since the events stream started over.
    confirmed: bool = true,

    /// The stream that takes the session's input, if any.
    fn writer(s: *Slot) ?*View {
        if (s.next) |n| if (n.role == .write and n.end == null) return n;
        if (s.view) |v| if (v.role == .write and v.end == null and !v.opening) return v;
        return null;
    }
};

const Drawn = struct {
    gpa: std.mem.Allocator,
    settings: Settings,
    label: ?[]const u8 = null,
    id_text: []const u8 = "",
    /// The session underneath.
    main: Slot,
    /// The role the session underneath is attached in: write, or read once
    /// another client took over.
    main_role: Role = .write,
    under_name: ?[]u8 = null,
    slots: std.ArrayList(*Slot) = .empty,
    m: boxes.Boxes,
    events: ?*Events = null,
    events_retry: ?Retry = null,
    requests: std.ArrayList(*Request) = .empty,
    input: Input,
    canvas: ?paint.Canvas = null,
    /// The input modes the person's terminal has now.
    shown_modes: InputModes = .{},
    /// The box last told it has the keys.
    focused: ?u64 = null,
    /// What a DECRQM query found for alternate scroll (1007).
    alt_scroll: ?u32 = null,
    /// What a DECRQM query found for scrolling to the bottom on output
    /// (1010, xterm's and rxvt's).
    scroll_output: ?u32 = null,
    /// Until when the terminal's answers to tuppet's queries are looked
    /// for among the input.
    answers_until: i64 = std.math.maxInt(i64),
    /// The cursor style the terminal had, from a DECRQSS query; a drawn
    /// attach leaves that one, not the terminal's default, which xterm
    /// makes blink.
    own_style: ?u8 = null,
    sent_size: ?[2]u16 = null,
    /// Data for `out_to`, sent at the end of each pass over input.
    out: std.ArrayList(u8) = .empty,
    out_to: ?*View = null,
    /// The stream the paste being passed goes to, fixed at its first
    /// piece, and whether it goes with its brackets.
    paste_to: ?*View = null,
    paste_brackets: bool = false,
    pacer: Pacer = .{ .dirty_at = 0 },
    notice: ?[]u8 = null,
    notice_until: ?i64 = null,
    retry: ?Retry = null,
    final: ?status.Shown = null,
    /// How the attach ends once the session underneath ended and keys
    /// paused.
    ended: ?Outcome = null,
    /// The backdrop of the open box, as the session was at its opening
    /// frame, and when that was.
    frozen: ?paint.Canvas = null,
    frozen_serial: u32 = 0,
    frozen_ms: i64 = 0,
    retake_until: ?i64 = null,
    /// The window was resized: the frozen backdrop is taken again.
    retake: bool = false,
    /// What the boxes showed at the last look, to paint on a change.
    look: u64 = 0,
    ascii: bool = false,
    color: bool = true,
    /// A box's background, and its shadow's, when the terminal told its
    /// colors.
    fill: ?paint.Color = null,
    shadow: ?paint.Color = null,
    /// The last Esc pressed acted on a box, so its release goes nowhere.
    esc_taken: bool = false,
    /// Rows of the session underneath due for the person's scrollback.
    pending: paint.Lines,
    /// The person's terminal shows the alternate screen.
    on_alt: bool,
    /// It does because the window is smaller than the session.
    small: bool = false,
    /// After a resize, the normal screen is not painted until the
    /// session's screen at the new size came, or until then.
    hold_until: ?i64 = null,
    /// Rows the person's terminal may have taken back from its scrollback
    /// onto the top of its normal screen when the window was resized.
    pulled: usize = 0,
    /// Rows the window grew while the alternate screen showed: a terminal
    /// may take as many from its scrollback onto that screen, where they
    /// are lost (xterm does).
    alt_grown: usize = 0,
    /// The daemon sends older rows, so an attach that broke catches up.
    has_history: bool = false,
    id_buf: [20]u8 = undefined,
    /// A group attach: its members, of which `main` is the one in front.
    group: ?*group_mod.Group = null,
    switcher: group_mod.Switcher,
    /// Preview streams of the members, while the switcher is open.
    previews: std.AutoArrayHashMapUnmanaged(u64, *View) = .empty,
    /// The member in front before this one.
    prev_front: ?u64 = null,
    /// The attach ends when this session ends.
    end_with: ?u64 = null,
    /// The bar shows, from the second member on, for good.
    bar: bool = false,
    /// Another client writes to the member in front: it is shown read-only
    /// until Enter takes it over.
    front_elsewhere: bool = false,
    /// Keys are dropped after the screen in front changed, until the
    /// terminal answered a cursor report asked after it was painted.
    hold: ?Hold = null,
    /// Keys dropped, and until when the bar says so.
    dropped: usize = 0,
    dropped_until: i64 = 0,
    /// A dim line that goes into the scrollback right before the next line
    /// of the member in front.
    mark_due: ?[]u8 = null,
    /// The sizes asked of the members and the side session.
    sized: std.AutoHashMapUnmanaged(u64, [2]u16) = .empty,
    /// The side session of the member in front, while it has one.
    side: ?*Slot = null,
    /// After the side pane went back to compact, keys reach the front only
    /// once they paused; until then they are dropped.
    side_quiet: ?i64 = null,
    side_was: status.SideView = .compact,
    /// What the switch key sent last, for `\\` in the switcher.
    switch_bytes: [32]u8 = undefined,
    switch_len: usize = 0,
    /// The terminal's state as the run found it, for the pager.
    saved: ?std.posix.termios = null,

    const Hold = struct {
        since: i64,
        /// The cell the cursor report was asked at.
        cell: ?boxes.Cell = null,
    };

    fn deinit(d: *Drawn) void {
        d.paste_to = null;
        d.out_to = null;
        d.closeSlotViews(&d.main);
        d.main.layer.deinit();
        for (d.slots.items) |s| d.freeSlot(s);
        d.slots.deinit(d.gpa);
        if (d.events) |e| e.deinit();
        for (d.requests.items) |r| r.deinit();
        d.requests.deinit(d.gpa);
        d.input.deinit(d.gpa);
        if (d.canvas) |*c| c.deinit();
        if (d.frozen) |*f| f.deinit();
        d.out.deinit(d.gpa);
        if (d.notice) |n| d.gpa.free(n);
        d.pending.deinit();
        if (d.under_name) |n| d.gpa.free(n);
        if (d.ended) |e| if (e.message) |msg| d.gpa.free(msg);
        d.closePreviews();
        d.previews.deinit(d.gpa);
        if (d.side) |s| d.freeSlot(s);
        d.sized.deinit(d.gpa);
        if (d.mark_due) |t| d.gpa.free(t);
        d.switcher.deinit();
        if (d.group) |g| {
            g.deinit();
            d.gpa.destroy(g);
        }
    }

    fn done(d: *Drawn, kind: Outcome.Kind, code: u8, comptime fmt: []const u8, args: anytype) Outcome {
        return .{ .kind = kind, .code = code, .message = std.fmt.allocPrint(d.gpa, fmt, args) catch null };
    }

    /// Show tuppet's own line over the session for a while.
    fn setNotice(d: *Drawn, comptime fmt: []const u8, args: anytype) void {
        d.setNoticeFor(notice_ns, fmt, args);
    }

    /// Show tuppet's own line for `ns`, or until it is cleared.
    fn setNoticeFor(d: *Drawn, ns: ?i64, comptime fmt: []const u8, args: anytype) void {
        if (d.notice) |n| d.gpa.free(n);
        d.notice = std.fmt.allocPrint(d.gpa, "tuppet: " ++ fmt, args) catch null;
        d.notice_until = if (ns) |t| io_mod.nowNanos() + t else null;
        d.pacer.changed(io_mod.nowNanos());
    }

    fn clearNotice(d: *Drawn) void {
        if (d.notice) |n| d.gpa.free(n);
        d.notice = null;
        d.notice_until = null;
        d.pacer.changed(io_mod.nowNanos());
    }

    // ---- streams --------------------------------------------------------

    /// Close a stream; what goes to it stops, and a paste that it took is
    /// closed first.
    fn closeView(d: *Drawn, v: *View) void {
        if (d.out_to == v) d.flushOut();
        if (d.paste_to == v) {
            if (d.paste_brackets) v.sendData("\x1b[201~");
            d.paste_to = null;
        }
        if (v.role == .write and v.end == null and !v.opening) v.queue("{\"detach\":true}");
        v.deinit();
    }

    fn closeSlotViews(d: *Drawn, s: *Slot) void {
        if (s.next) |n| d.closeView(n);
        if (s.view) |v| d.closeView(v);
        s.next = null;
        s.view = null;
    }

    fn freeSlot(d: *Drawn, s: *Slot) void {
        d.closeSlotViews(s);
        s.layer.deinit();
        d.gpa.destroy(s);
    }

    /// The new stream's copy has its screen: it replaces the old one,
    /// which served the session's input modes until then.
    fn swap(d: *Drawn, s: *Slot) void {
        const n = s.next.?;
        s.next = null;
        if (s.view) |old| {
            // The same session again: a paste cut by the change is
            // closed on the new stream.
            if (d.paste_to == old and n.role == .write) d.paste_to = n;
            if (old.track) {
                old.harvest();
                d.pending.take(&old.left);
            }
            d.closeView(old);
        }
        s.view = n;
        s.dirty_at = s.dirty_at orelse io_mod.nowNanos();
    }

    fn slotOf(d: *Drawn, id: u64) ?*Slot {
        for (d.slots.items) |s| if (s.id == id) return s;
        return null;
    }

    /// Feed each stream a slice of what it brought, and act on it.
    /// The boxes go first, so the output of the session underneath never
    /// holds up a box.
    fn serviceStreams(d: *Drawn, now: i64) ?Outcome {
        const pass_until = now + pass_ns;
        var i: usize = 0;
        while (i < d.slots.items.len) {
            const s = d.slots.items[i];
            if (d.serviceBox(s, pass_until, now)) {
                i += 1;
            } else {
                d.m.remove(s.id, now);
                _ = d.slots.orderedRemove(i);
                d.freeSlot(s);
            }
        }
        if (d.side) |s| d.serviceSide(s, pass_until, now);
        for (d.previews.values()) |v| {
            v.work(untilFor(pass_until));
            v.effects.clearRetainingCapacity();
            if (v.changed) {
                v.changed = false;
                d.pacer.changed(now);
            }
        }
        if (d.main.next) |n| next: {
            n.work(untilFor(pass_until));
            if (n.refused) |r| {
                // The daemon may not have let go of the broken stream's
                // writer yet: the next try may find it gone.
                if (!(r.busy and d.retry != null and now - d.retry.?.since < retry_for_ns)) return .{ .kind = .refused, .code = r.code, .message = d.gpa.dupe(u8, r.message) catch null };
                d.closeView(n);
                d.main.next = null;
                break :next;
            }
            // An exit that comes before the first screen ends the attach
            // with the program's code all the same.
            if (n.ready() or n.exit != null) {
                d.swap(&d.main);
                d.retry = null;
                // What was typed for the session underneath meanwhile is
                // dropped; a box's input and hand-over are left alone.
                if (d.m.keyboard() == null) d.dropTypedAhead();
                if (d.canvas) |*c| c.invalidate();
                d.clearNotice();
            } else if (n.end != null) {
                d.closeView(n);
                d.main.next = null;
            }
        }
        if (d.main.view) |v| {
            v.work(untilFor(pass_until));
            if (d.afterMain(v, now)) |outcome| return outcome;
        }
        if (d.events) |e| {
            while (e.nextLine()) |line| {
                if (!d.eventFrame(e, line, now)) {
                    e.ended = true;
                    break;
                }
            }
            if (e.ended) {
                // A stream opened again that ended before it synced is no
                // reason to try at once and for longer.
                d.events_retry = if (e.retry_since) |since| .{ .since = since, .next = now + retry_every_ns } else .{ .since = now, .next = now };
                e.deinit();
                d.events = null;
                d.m.setSynced(false, now);
            }
        }
        return null;
    }

    /// Act on what the stream of the session underneath brought.
    fn afterMain(d: *Drawn, v: *View, now: i64) ?Outcome {
        d.passEffects(v);
        if (v.changed) {
            v.changed = false;
            d.main.dirty_at = d.main.dirty_at orelse now;
            d.pacer.changed(now);
        }
        d.syncModes();
        if (v.exit) |e| if (d.ended == null) {
            if (d.group != null and d.end_with != d.main.id) {
                // The member stays in front, dimmed, until it is closed;
                // keys typed before that shows are dropped.
                if (!v.exit_seen) {
                    v.exit_seen = true;
                    d.hold = .{ .since = now };
                    d.m.underEnded(now);
                    d.main.dirty_at = d.main.dirty_at orelse now;
                    d.pacer.changed(now);
                }
            } else {
                d.final = e.final;
                d.ended = .{ .kind = .exited, .code = e.code, .message = d.gpa.dupe(u8, e.message) catch null };
                d.m.underEnded(now);
            }
        };
        if (d.group != null and v.refused != null) {
            // Another client took the writer role since the status said.
            const busy = v.refused.?.busy;
            d.closeView(v);
            d.main.view = null;
            if (busy) if (d.front()) |m| d.openFront(m, .watch, now);
            return null;
        }
        if (v.taken) {
            v.taken = false;
            if (d.settings.end_on_takeover) {
                v.queue("{\"detach\":true}");
                return .{ .kind = .taken, .code = 0 };
            }
            d.main_role = .read;
            // In a group, Enter takes the member back.
            if (d.group != null) d.front_elsewhere = true else d.settings.resize = false;
            d.m.setWriter(false, now);
            // A paste cut here cannot be closed: this attach no longer
            // writes.
            if (d.paste_to == v) d.paste_to = null;
            d.discardInput(now);
            d.setNotice("another client took over writing; this attach is now read-only", .{});
        }
        if (v.hold) |h| {
            v.hold = null;
            if (h) d.setNoticeFor(null, "held: automation is typing", .{}) else d.clearNotice();
        }
        if (v.err) |e| {
            d.setNotice("{s}", .{e});
            d.gpa.free(e);
            v.err = null;
        }
        if (d.ended == null and d.retry == null and !(d.group != null and v.exit != null)) if (v.end) |end| switch (end) {
            .too_slow, .broken => {
                // The daemon lets go of the writer once it sees the end.
                _ = std.c.shutdown(v.fd(), std.c.SHUT.RDWR);
                d.retry = .{ .since = now, .next = now };
                d.setNoticeFor(null, "the attach stream broke; attaching again", .{});
            },
            .exited => return d.done(.failed, client.exit_code.failed, "tuppet: the attach ended without the program's exit\n", .{}),
            else => return d.done(.failed, client.exit_code.failed, "tuppet: the daemon ended the attach ({s})\n", .{@tagName(end)}),
        };
        return null;
    }

    /// Act on what a box's streams brought; false once the box ended.
    fn serviceBox(d: *Drawn, s: *Slot, pass_until: i64, now: i64) bool {
        if (s.next) |n| {
            n.work(untilFor(pass_until));
            if (n.refused != null or n.end != null) {
                if (n.refused != null and n.role == .write) d.m.refused(s.id, now);
                d.closeView(n);
                s.next = null;
                s.retry_at = now + retry_every_ns;
            } else if (n.ready()) d.swap(s);
        }
        const v = s.view orelse return true;
        v.work(untilFor(pass_until));
        if (v.role == .preview) v.effects.clearRetainingCapacity() else d.passEffects(v);
        if (v.changed) {
            v.changed = false;
            s.dirty_at = s.dirty_at orelse now;
            if (d.m.keyboard() == s.id or d.m.never() == s.id) d.pacer.changed(now);
        }
        if (v.has_terminal) d.m.setBrackets(s.id, v.terminal.modes.get(.bracketed_paste));
        if (v.exit != null) return false;
        if (v.taken) {
            v.taken = false;
            d.m.setElsewhere(s.id, true, now);
        }
        if (v.err) |e| {
            d.gpa.free(e);
            v.err = null;
        }
        if (v.end != null) {
            if (v.end != .broken and v.end != .too_slow) return false;
            d.closeView(v);
            s.view = null;
            s.retry_at = now + retry_every_ns;
        }
        return true;
    }

    /// Act on what the side session's streams brought.
    fn serviceSide(d: *Drawn, s: *Slot, pass_until: i64, now: i64) void {
        if (s.next) |n| {
            n.work(untilFor(pass_until));
            if (n.refused != null or n.end != null) {
                d.closeView(n);
                s.next = null;
                s.retry_at = now + retry_every_ns;
            } else if (n.ready()) d.swap(s);
        }
        const v = s.view orelse return;
        v.work(untilFor(pass_until));
        d.passEffects(v);
        if (v.changed) {
            v.changed = false;
            s.dirty_at = s.dirty_at orelse now;
            d.pacer.changed(now);
        }
        v.taken = false;
        if (v.err) |e| {
            d.gpa.free(e);
            v.err = null;
        }
        if (v.end != null and v.exit == null) {
            d.closeView(v);
            s.view = null;
            s.retry_at = now + retry_every_ns;
        }
    }

    fn passEffects(d: *Drawn, v: *View) void {
        _ = d;
        if (v.effects.items.len == 0) return;
        plat.stdoutWriteAll(v.effects.items) catch {};
        v.effects.clearRetainingCapacity();
    }

    /// Attach again after the stream broke, without force; keys read
    /// meanwhile are dropped.
    fn reattach(d: *Drawn, now: i64) ?Outcome {
        const r = d.retry.?;
        if (now - r.since >= retry_for_ns) return d.done(.failed, client.exit_code.failed, "tuppet: lost the attach stream and could not attach again within 5 s\n", .{});
        d.retry.?.next = now + retry_every_ns;
        if (d.main.next != null) return null;
        const size = if (d.main_role == .write and d.settings.resize) attach_client.terminalSize() else null;
        const old = d.main.view;
        const track = if (old) |v| v.track else false;
        // The rows that went by meanwhile, once the daemon can send them.
        const from: ?u64 = if (old) |v| v.top else null;
        const extra: View.Extra = .{
            .track = track,
            .history = if (track and d.has_history and from != null) catch_up_rows else 0,
            .history_from = from,
            .pass = d.settings.pass,
        };
        d.main.next = View.startWith(d.gpa, d.id_text, d.main_role, false, size, d.label, extra) catch return null;
        d.sent_size = size;
        return null;
    }

    fn reopenEvents(d: *Drawn, now: i64) ?Outcome {
        const r = d.events_retry.?;
        if (now - r.since >= retry_for_ns) {
            if (d.main.view) |v| v.queue("{\"detach\":true}");
            return d.done(.failed, client.exit_code.failed, "tuppet: lost the daemon's events and could not follow them again within 5 s\n", .{});
        }
        if (Events.start(d.gpa)) |e| {
            e.retry_since = r.since;
            d.events = e;
            d.events_retry = null;
            // The boxes are listed again; those not listed ended.
            for (d.slots.items) |s| s.confirmed = false;
        } else |_| {
            d.events_retry.?.next = now + retry_every_ns;
        }
        return null;
    }

    /// One frame of the events stream; false once it is over.
    fn eventFrame(d: *Drawn, e: *Events, line: []const u8, now: i64) bool {
        var arena = std.heap.ArenaAllocator.init(d.gpa);
        defer arena.deinit();
        const Frame = struct { ok: ?bool = null, type: []const u8 = "", id: ?u64 = null, status: ?protocol.Status = null };
        const f = std.json.parseFromSliceLeaky(Frame, arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch return true;
        if (f.ok == false or std.mem.eql(u8, f.type, "end")) return false;
        if (std.mem.eql(u8, f.type, "synced")) {
            e.synced = true;
            e.retry_since = null;
            var i: usize = 0;
            while (i < d.slots.items.len) {
                const s = d.slots.items[i];
                if (s.confirmed) {
                    i += 1;
                    continue;
                }
                d.m.remove(s.id, now);
                _ = d.slots.orderedRemove(i);
                d.freeSlot(s);
            }
            d.m.setSynced(true, now);
        } else if (std.mem.eql(u8, f.type, "resync")) {
            e.synced = false;
            e.marked.clearRetainingCapacity();
            for (d.slots.items) |s| s.confirmed = false;
            d.m.setSynced(false, now);
        } else if (d.group != null and std.mem.eql(u8, f.type, "removed")) {
            if (f.id) |id| {
                _ = e.marked.remove(id);
                d.boxGone(id, now);
                d.group.?.gone(id);
                if (id == d.main.id) d.frontGone(now);
                if (id == d.end_with) return d.endWith(null);
                d.pacer.changed(now);
            }
        } else if (d.group != null and f.status != null and f.id != null) {
            const st = f.status.?;
            d.groupSeen(st, now);
            if (st.over != null) {
                if (st.state == .running) d.boxSeen(st, now) else d.boxGone(st.id, now);
            }
            if (f.id.? == d.end_with and st.state != .running) return d.endWith(st);
        } else if (std.mem.eql(u8, f.type, "removed") or std.mem.eql(u8, f.type, "left") or std.mem.eql(u8, f.type, "ended")) {
            if (f.id) |id| {
                _ = e.marked.remove(id);
                d.boxGone(id, now);
            }
        } else if (f.id) |id| if (f.status) |st| {
            if (id == d.main.id) if (st.name) |name| {
                if (d.under_name) |old| d.gpa.free(old);
                d.under_name = d.gpa.dupe(u8, name) catch null;
            };
            if (st.over != null) {
                d.boxSeen(st, now);
            } else {
                const needs = words.needsAttention(st, &.{});
                const was = e.marked.contains(id);
                if (needs) e.marked.put(d.gpa, id, {}) catch {} else _ = e.marked.remove(id);
                if (e.synced and needs and !was and id != d.main.id and d.settings.bell) plat.stdoutWriteAll("\x07") catch {};
            }
        };
        return true;
    }

    /// A box's status: a new box over the session underneath, or what
    /// changed about one.
    fn boxSeen(d: *Drawn, st: protocol.Status, now: i64) void {
        const over = st.over.?;
        if (over.id != d.main.id) return d.boxGone(st.id, now);
        if (st.state != .running) return d.boxGone(st.id, now);
        const s = d.slotOf(st.id) orelse blk: {
            const s = d.gpa.create(Slot) catch return;
            var id_buf: [24]u8 = undefined;
            const title = over.title orelse st.name orelse (std.fmt.bufPrint(&id_buf, "#{d}", .{st.id}) catch unreachable);
            s.* = .{ .id = st.id, .layer = .init(d.gpa), .grab = over.grab, .backdrop = over.backdrop, .title = .of(title), .start = .{ st.cols, st.rows } };
            d.slots.append(d.gpa, s) catch {
                d.gpa.destroy(s);
                return;
            };
            d.m.add(st.id, over.grab, title, now);
            break :blk s;
        };
        s.confirmed = true;
        const ours = if (st.writer) |w| s.writer() != null or (w.label != null and d.label != null and std.mem.eql(u8, w.label.?, d.label.?)) else false;
        d.m.setElsewhere(st.id, st.writer != null and !ours, now);
    }

    fn boxGone(d: *Drawn, id: u64, now: i64) void {
        for (d.slots.items, 0..) |s, i| if (s.id == id) {
            d.m.remove(id, now);
            _ = d.slots.orderedRemove(i);
            d.freeSlot(s);
            return;
        };
    }

    /// Hold each box's stream in the role the boxes call for: the new
    /// stream first, the old one closed when the new one's reply came.
    fn applyRoles(d: *Drawn, now: i64) void {
        for (d.slots.items) |s| {
            const want = d.m.role(s.id);
            if (s.next) |n| if (n.role != want) {
                d.closeView(n);
                s.next = null;
            };
            if (want == .none) {
                d.closeSlotViews(s);
                continue;
            }
            if (s.next != null) continue;
            if (s.view) |v| if (v.role == want) continue;
            if (now < s.retry_at) continue;
            var id_buf: [20]u8 = undefined;
            const ref = std.fmt.bufPrint(&id_buf, "{d}", .{s.id}) catch unreachable;
            s.next = View.startWith(d.gpa, ref, want, false, null, d.label, .{ .pass = d.settings.pass }) catch {
                s.retry_at = now + retry_every_ns;
                continue;
            };
        }
    }

    // ---- a group ----------------------------------------------------------

    /// The member in front, in a group attach.
    fn front(d: *Drawn) ?*group_mod.Member {
        const g = d.group orelse return null;
        return g.get(d.main.id);
    }

    /// The member in front ended and the attach goes on: its last screen
    /// stays, dimmed, until the person closes it.
    fn frontEnded(d: *Drawn) bool {
        if (d.group == null) return false;
        const v = d.main.view orelse return false;
        return v.exit != null;
    }

    /// Send a request whose reply nobody waits for.
    fn request(d: *Drawn, req: anytype) void {
        const r = Request.start(d.gpa, req, io_mod.nowNanos()) catch return;
        d.requests.append(d.gpa, r) catch r.deinit();
    }

    /// The member came to the front: its bell is heard, its flag cleared.
    fn visit(d: *Drawn, m: *group_mod.Member) void {
        m.visited = true;
        m.bells_seen = m.st().bell_count;
        if (m.st().attention == null) return;
        var buf: [20]u8 = undefined;
        d.request(protocol.FlagReq{ .session = std.fmt.bufPrint(&buf, "{d}", .{m.id}) catch unreachable, .clear = true });
    }

    /// Put member `id` in front, remembering where the one before was.
    fn switchTo(d: *Drawn, id: u64, now: i64) void {
        const g = d.group orelse return;
        d.closeSwitcher();
        if (id == d.main.id) return;
        const m = g.get(id) orelse return;
        if (g.get(d.main.id)) |old| {
            if (d.main.view) |v| if (v.top) |t| {
                old.top_row = t;
            };
            old.bells_seen = old.st().bell_count;
        }
        d.prev_front = d.main.id;
        d.openFront(m, .usual, now);
        if (d.settings.switch_marks and !d.settings.alt_screen and !d.settings.paint_alt) {
            var name_buf: [24]u8 = undefined;
            var clock: [8]u8 = undefined;
            const hhmm = clockText(&clock, store.nowMillis());
            if (d.mark_due) |t| d.gpa.free(t);
            const line = if (d.ascii) "--" else "\u{2500}\u{2500}";
            const dot = if (d.ascii) "-" else "\u{00b7}";
            d.mark_due = std.fmt.allocPrint(d.gpa, "{s} {s} {s} {s} {s}", .{ line, m.name(&name_buf), dot, hhmm[0..@min(hhmm.len, 5)], line }) catch null;
        }
    }

    /// How the member in front is attached: as the writer unless another
    /// client writes to it, taking the writer role over, or watching.
    const Open = enum { usual, take, watch };

    /// Show member `m` in front with a stream of its own, which catches
    /// up on the rows it printed since it was last in front.
    fn openFront(d: *Drawn, m: *group_mod.Member, how: Open, now: i64) void {
        if (d.main.next) |n| d.closeView(n);
        d.main.next = null;
        if (d.main.view) |v| {
            // What left the old copy is still due for the scrollback.
            if (v.track) {
                v.harvest();
                d.pending.take(&v.left);
            }
            d.closeView(v);
        }
        d.main.view = null;
        d.retry = null;
        d.main.id = m.id;
        d.id_text = std.fmt.bufPrint(&d.id_buf, "{d}", .{m.id}) catch unreachable;
        d.front_elsewhere = how == .watch or (how == .usual and m.st().writer != null);
        d.main_role = if (d.front_elsewhere) .read else .write;
        const force = how == .take;
        const track = !d.settings.alt_screen and !d.settings.paint_alt;
        d.main.view = View.startWith(d.gpa, d.id_text, d.main_role, force, null, d.label, .{
            .track = track,
            .history = if (track and d.has_history and m.top_row != null) catch_up_rows else 0,
            .history_from = m.top_row,
            .pass = d.settings.pass,
        }) catch null;
        d.main.dirty_at = now;
        if (d.under_name) |n| d.gpa.free(n);
        d.under_name = if (m.st().name) |n| d.gpa.dupe(u8, n) catch null else null;
        d.visit(m);
        d.resetBoxes(now);
        d.hold = .{ .since = now };
        d.syncSide(now);
        d.pacer.changed(now);
    }

    /// Forget the boxes of the member that was in front, and take those
    /// over the one in front now.
    fn resetBoxes(d: *Drawn, now: i64) void {
        for (d.slots.items) |s| d.freeSlot(s);
        d.slots.clearRetainingCapacity();
        d.focused = null;
        d.m = .{ .pause_ns = d.m.pause_ns, .no_detach = d.m.no_detach, .aside = d.m.aside, .writer = d.main_role == .write, .synced = d.m.synced };
        d.addBoxes(now);
    }

    /// The boxes over the member in front that the group knows of.
    fn addBoxes(d: *Drawn, now: i64) void {
        const g = d.group orelse return;
        var it = g.others.valueIterator();
        while (it.next()) |k| if (k.*.st.over) |o| if (o.id == d.main.id and k.*.st.state == .running) d.boxSeen(k.*.st, now);
    }

    /// Close the member in front, which ended: remove it, and go back to
    /// the one in front before, or the first. Without another member the
    /// attach ends with the program's code.
    fn closeFront(d: *Drawn, now: i64) ?Outcome {
        const g = d.group orelse return null;
        const id = d.main.id;
        var buf: [20]u8 = undefined;
        d.request(protocol.RemoveReq{ .sessions = &.{std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable} });
        const back = if (d.prev_front) |p| (if (p != id and g.get(p) != null) p else null) else null;
        const next = back orelse for (g.members.items) |m| {
            if (m.id != id) break m.id;
        } else null;
        g.gone(id);
        const to = next orelse {
            const code = if (d.main.view) |v| (if (v.exit) |e| e.code else 0) else 0;
            return d.done(.exited, code, "", .{});
        };
        d.prev_front = null;
        d.switchTo(to, now);
        return null;
    }

    /// Open the switcher, with the member in front before selected.
    fn openSwitcher(d: *Drawn, now: i64) void {
        const g = d.group orelse return;
        const select = if (d.prev_front) |p| (if (g.get(p) != null) p else d.main.id) else d.main.id;
        d.switcher.show(select, now);
        for (g.members.items) |m| {
            if (m.id == d.main.id or d.previews.count() >= max_previews) continue;
            var buf: [20]u8 = undefined;
            const v = View.start(d.gpa, std.fmt.bufPrint(&buf, "{d}", .{m.id}) catch unreachable, .preview, false, null, null) catch continue;
            d.previews.put(d.gpa, m.id, v) catch v.deinit();
        }
        d.pacer.changed(now);
    }

    fn closeSwitcher(d: *Drawn) void {
        if (!d.switcher.open) return;
        d.switcher.hide();
        d.closePreviews();
        d.pacer.changed(io_mod.nowNanos());
    }

    fn closePreviews(d: *Drawn) void {
        for (d.previews.values()) |v| v.deinit();
        d.previews.clearRetainingCapacity();
    }

    /// Act on what the switcher asks for.
    fn doSwitcher(d: *Drawn, what: group_mod.Do, now: i64) ?Outcome {
        switch (what) {
            .none => {},
            .close => d.closeSwitcher(),
            .go => |id| d.switchTo(id, now),
            .detach => {
                d.closeSwitcher();
                d.leave();
                if (d.settings.quiet_detach) return .{ .kind = .detached, .code = 0 };
                return d.done(.detached, 0, "tuppet: detached from group {s}; its sessions keep running ('tuppet attach --drawn --group {s}' to return)\n", .{ d.group.?.name, d.group.?.name });
            },
            .send_switch_key => {
                d.closeSwitcher();
                d.pass(.{ .key = d.switch_bytes[0..d.switch_len] }, d.underSlot(), null, now);
            },
            .send_menu_key => {
                d.closeSwitcher();
                d.pass(.{ .key = &.{d.settings.detach_key} }, d.underSlot(), null, now);
            },
            .side_step => |id| d.sideStep(id),
            .history => |id| d.showHistory(id),
            .action => |a| {
                var buf: [20]u8 = undefined;
                d.request(protocol.ActionReq{ .session = std.fmt.bufPrint(&buf, "{d}", .{a.id}) catch unreachable, .key = &.{a.key}, .value = a.value });
                d.closeSwitcher();
            },
        }
        return null;
    }

    /// Member `id`'s history in $PAGER, then back.
    fn showHistory(d: *Drawn, id: u64) void {
        d.closeSwitcher();
        var buf: [20]u8 = undefined;
        const ref = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable;
        const reply = client.request(d.gpa, protocol.ViewReq{ .session = ref, .scrollback = true }, protocol.ViewResp) catch return d.setNotice("cannot read the history of #{d}", .{id});
        defer reply.deinit();
        if (!reply.parsed.value.ok) return d.setNotice("cannot read the history of #{d}", .{id});
        var filter: attach_filter.Filter = .{};
        defer filter.deinit(d.gpa);
        const shown = filter.feed(d.gpa, reply.parsed.value.text) catch return;
        defer d.gpa.free(shown);
        const header = std.fmt.allocPrint(d.gpa, "history of #{d}\n", .{id}) catch return;
        defer d.gpa.free(header);
        // The pager gets the terminal as the attach found it.
        plat.stdoutWriteAll(modes_off ++ "\x1b[?2004l" ++ paint.leave) catch {};
        if (!d.on_alt) plat.stdoutWriteAll("\x1b[?1049h") catch {};
        if (d.saved) |orig| plat.tcsetattr(0, .NOW, orig) catch {};
        picker.page(d.gpa, header, std.mem.trimEnd(u8, shown, "\n"));
        if (d.saved) |orig| attach_client.setRaw(orig);
        if (!d.on_alt) plat.stdoutWriteAll("\x1b[?1049l") catch {};
        plat.stdoutWriteAll(paint.enter_modes ++ "\x1b[?2004h") catch {};
        d.shown_modes = .{};
        if (d.canvas) |*c| c.invalidate();
        d.dropTypedAhead();
        d.pacer.changed(io_mod.nowNanos());
    }

    /// The view of the side session of the member in front.
    fn sideView(d: *Drawn) status.SideView {
        const s = d.side orelse return .compact;
        const st = d.group.?.other(s.id) orelse return .compact;
        return st.side_view orelse .compact;
    }

    /// Step the side pane of member `id` to its next size, or ask for a
    /// side session when it has none.
    fn sideStep(d: *Drawn, id: u64) void {
        const g = d.group orelse return;
        d.closeSwitcher();
        const m = g.get(id) orelse return;
        var buf: [20]u8 = undefined;
        const side_id = m.st().side orelse {
            d.request(protocol.SideReq{ .session = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable, .request = true });
            return;
        };
        const now_view = if (g.other(side_id)) |st| st.side_view orelse .compact else .compact;
        const sizes = d.settings.side.sizes;
        var next: status.SideView = .compact;
        for (sizes, 0..) |s, i| if (s == now_view) {
            next = if (i + 1 < sizes.len) sizes[i + 1] else .compact;
        };
        d.setSideView(side_id, next);
    }

    fn setSideView(d: *Drawn, side_id: u64, view: status.SideView) void {
        var buf: [20]u8 = undefined;
        d.request(protocol.SideReq{ .session = std.fmt.bufPrint(&buf, "{d}", .{side_id}) catch unreachable, .view = view });
    }

    /// Follow the side session of the member in front: a slot for it while
    /// there is one, attached as a viewer in compact and as the writer in
    /// half and full.
    fn syncSide(d: *Drawn, now: i64) void {
        const want: ?u64 = if (d.front()) |m| m.st().side else null;
        if (d.side) |s| if (want != s.id) {
            d.freeSlot(s);
            d.side = null;
            d.side_quiet = null;
            d.pacer.changed(now);
        };
        const id = want orelse return;
        if (d.side == null) {
            const s = d.gpa.create(Slot) catch return;
            s.* = .{ .id = id, .layer = .init(d.gpa) };
            d.side = s;
            d.pacer.changed(now);
        }
        const s = d.side.?;
        const role: Role = if (d.sideView() == .compact) .read else .write;
        if (s.next) |n| if (n.role != role) {
            d.closeView(n);
            s.next = null;
        };
        if (s.next != null) return;
        if (s.view) |v| if (v.role == role and v.end == null) return;
        if (now < s.retry_at) return;
        var buf: [20]u8 = undefined;
        s.next = View.startWith(d.gpa, std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable, role, false, null, d.label, .{ .pass = d.settings.pass }) catch {
            s.retry_at = now + retry_every_ns;
            return;
        };
    }

    /// Where the keys that no box takes go: the side session in half and
    /// full, else the member in front.
    fn underSlot(d: *Drawn) *Slot {
        if (d.side) |s| if (d.sideView() != .compact) return s;
        return &d.main;
    }

    /// How a group attach splits the window: the front's size, where the
    /// side session shows in compact (below, beside, or a strip in the
    /// bar) and in half and full, and the bar's row.
    const Split = struct {
        front: [2]u16,
        area_rows: usize,
        bar_row: ?usize = null,
        pane: ?paint.Rect = null,
        beside: bool = false,
        strip: bool = false,
        over: ?paint.Rect = null,
    };

    fn split(d: *Drawn) Split {
        const c = d.canvas orelse return .{ .front = .{ 1, 1 }, .area_rows = 1 };
        const cols = @max(c.cols, 1);
        const rows = @max(c.rows, 1);
        const bar: usize = @intFromBool(d.bar and rows > 1);
        const area = rows - bar;
        var out: Split = .{ .front = .{ @intCast(@min(cols, limits.max_side)), @intCast(@min(area, limits.max_side)) }, .area_rows = area, .bar_row = if (bar == 1) rows - 1 else null };
        if (d.side == null) return out;
        const cfg = d.settings.side;
        // The front gives the pane its room for as long as there is a side
        // session, also while that is drawn over it in half or full.
        const below = (cfg.layout == .below or (cfg.layout == .auto and rows >= cfg.below_min)) and area > cfg.rows + 1;
        const beside = !below and (cfg.layout == .side or cfg.layout == .auto) and cols > cfg.front_min + cfg.pane_min;
        if (below) {
            out.front[1] = @intCast(area - cfg.rows);
            out.pane = .{ .x = 0, .y = area - cfg.rows, .cols = cols, .rows = cfg.rows };
        } else if (beside) {
            const pane = paneCols(cols, cfg.front_min, cfg.pane_min);
            out.front[0] = @intCast(cols - pane - 1);
            out.pane = .{ .x = cols - pane, .y = 0, .cols = pane, .rows = area };
            out.beside = true;
        } else out.strip = true;
        switch (d.sideView()) {
            .compact => {},
            .half => out.over = .{ .x = 0, .y = area - area / 2, .cols = cols, .rows = @max(area / 2, 1) },
            .full => out.over = .{ .x = 0, .y = 0, .cols = cols, .rows = area },
        }
        return out;
    }

    /// The size the side session is given for its view.
    fn sideSize(d: *Drawn, sp: Split) [2]u16 {
        const r = sp.over orelse sp.pane orelse paint.Rect{ .x = 0, .y = 0, .cols = sp.front[0], .rows = d.settings.side.rows };
        return .{ @intCast(@min(@max(r.cols, 1), limits.max_side)), @intCast(@min(@max(r.rows, 1), limits.max_side)) };
    }

    /// Size every member to the front's area and the side session to its
    /// view, with resize requests, never the attach's stream; a member
    /// another client writes to keeps that client's size.
    fn sizeMembers(d: *Drawn) void {
        const g = d.group orelse return;
        if (!d.settings.resize) return;
        const sp = d.split();
        for (g.members.items) |m| {
            if (!m.running()) continue;
            const ours = m.id == d.main.id and d.main_role == .write;
            if (m.st().writer != null and !ours) continue;
            d.sizeTo(m.id, .{ m.st().cols, m.st().rows }, sp.front);
        }
        if (d.side) |s| if (g.other(s.id)) |st| if (st.state == .running) d.sizeTo(s.id, .{ st.cols, st.rows }, d.sideSize(sp));
    }

    fn sizeTo(d: *Drawn, id: u64, have: [2]u16, want: [2]u16) void {
        if (std.mem.eql(u16, &have, &want)) {
            _ = d.sized.remove(id);
            return;
        }
        if (d.sized.get(id)) |asked| if (std.mem.eql(u16, &asked, &want)) return;
        var buf: [20]u8 = undefined;
        d.request(protocol.ResizeReq{ .session = std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable, .cols = want[0], .rows = want[1] });
        d.sized.put(d.gpa, id, want) catch {};
    }

    /// A status of the events stream, in a group attach.
    fn groupSeen(d: *Drawn, st: protocol.Status, now: i64) void {
        const g = d.group orelse return;
        const seen = g.seen(st) catch return;
        // The bell rings once when a member that is not in front comes to
        // need attention.
        for (g.members.items) |m| {
            const needs = m.id != d.main.id and g.attention(m) != null;
            if (needs and !m.rang and d.settings.bell) plat.stdoutWriteAll("\x07") catch {};
            m.rang = needs;
        }
        switch (seen) {
            .joined => {
                if (g.members.items.len > 1) d.bar = true;
                const m = g.get(st.id).?;
                // A respawned member takes the place of the ended one in
                // front, which has its number.
                if (d.front()) |f| if (f.id != m.id and d.frontEnded() and f.st().number == m.st().number) {
                    g.gone(f.id);
                    d.openFront(m, .usual, now);
                };
            },
            .left => if (st.id == d.main.id) d.frontGone(now),
            .changed, .other => {},
        }
        d.pacer.changed(now);
    }

    /// The session the attach ends with ended (`st`, null when it was
    /// removed): the attach ends at once with its exit status. Returns
    /// true, for the events stream, which goes on until then.
    fn endWith(d: *Drawn, st: ?protocol.Status) bool {
        if (d.ended != null) return true;
        const now = io_mod.nowNanos();
        const exit = if (st) |s| s.exit else null;
        var code: u8 = 0;
        var message: ?[]u8 = null;
        if (exit) |x| {
            if (x.code) |c| {
                code = @truncate(@as(u32, @bitCast(c)));
                message = std.fmt.allocPrint(d.gpa, "tuppet: session {d} exited with code {d}\n", .{ d.end_with.?, c }) catch null;
            } else if (x.signal) |sig| {
                code = @truncate(128 + attach_client.signalNumber(sig));
                message = std.fmt.allocPrint(d.gpa, "tuppet: session {d} killed by {f}\n", .{ d.end_with.?, status.cleaned(sig) }) catch null;
            }
        }
        if (st) |s| if (s.id == d.main.id) {
            d.final = status.shownOf(s);
        };
        d.ended = .{ .kind = .exited, .code = code, .message = message };
        d.m.underEnded(now);
        return true;
    }

    /// The member in front left the group or was removed: the one in front
    /// before, or the first, comes to the front.
    fn frontGone(d: *Drawn, now: i64) void {
        const g = d.group orelse return;
        if (g.get(d.main.id) != null) return;
        const back = if (d.prev_front) |p| (if (g.get(p) != null) p else null) else null;
        const next = back orelse if (g.members.items.len > 0) g.members.items[0].id else null;
        if (next) |id| {
            d.prev_front = null;
            const m = g.get(id).?;
            d.openFront(m, .usual, now);
        }
    }

    /// The last line with text of a copy's screen, in `buf`.
    fn lastLine(v: *View, buf: []u8) []const u8 {
        if (!v.has_terminal) return "";
        const t = &v.terminal;
        var y: usize = t.rows;
        while (y > 0) {
            y -= 1;
            const pin = t.screens.active.pages.pin(.{ .active = .{ .y = @intCast(y) } }) orelse continue;
            var w: std.Io.Writer = .fixed(buf);
            for (pin.cells(.all)) |cell| {
                const cp = cell.codepoint();
                if (cp == 0) w.writeByte(' ') catch break else if (!status.isControl(cp)) w.print("{u}", .{cp}) catch break;
            }
            const text = std.mem.trim(u8, w.buffered(), " ");
            if (text.len > 0) return text;
        }
        return "";
    }

    // ---- the loop -------------------------------------------------------

    /// The attached session loop, on the alternate screen; the terminal is
    /// restored before it returns.
    fn run(d: *Drawn) Outcome {
        attach_client.installHandlers();
        const saved = plat.tcgetattr(0) catch null;
        d.saved = saved;
        if (saved) |orig| attach_client.setRaw(orig);
        // Sized in the loop's first pass, after the handlers, so a resize
        // during the attach's setup is not missed.
        d.canvas = paint.Canvas.init(d.gpa);
        d.canvas.?.links = d.settings.pass.links;
        if (!d.settings.alt_screen) d.canvas.?.keep = limits.max_side;
        if (d.color) if (d.settings.colors) |colors| {
            d.canvas.?.dim = dimColor(colors);
            // A shade of the terminal's own background, so a program that
            // picks its colors for that background reads well in a box.
            d.fill = mixColor(colors[1], colors[0], 40);
            d.shadow = mixColor(colors[1], .{ .r = 0, .g = 0, .b = 0 }, 128);
        };
        d.canvas.?.marks = !d.on_alt;
        // Alternate scroll off, so the wheel is not sent as arrow keys,
        // after asking what it was; bracketed paste always on.
        const take = modes_off ++ "\x1b[?2004h\x1bP$q q\x1b\\\x1b[?1007$p\x1b[?1007l\x1b[?1010$p";
        d.input.style_due = true;
        d.input.osc_due = answers_late;
        d.answers_until = io_mod.nowNanos() + 2 * std.time.ns_per_s;
        if (typed_len > 0) {
            d.input.feed(d.gpa, typed_ahead[0..typed_len], io_mod.nowNanos()) catch {};
            typed_len = 0;
        }
        if (d.settings.alt_screen) {
            plat.stdoutWriteAll(paint.enter ++ take) catch {};
        } else if (d.on_alt) {
            plat.stdoutWriteAll("\x1b[?1049h" ++ paint.enter ++ take) catch {};
        } else {
            // The normal screen: what it showed goes into the scrollback
            // first, as a raw attach does, and its rows are erased one by
            // one, which VTE needs to take reordering off them.
            var start: std.ArrayList(u8) = .empty;
            defer start.deinit(d.gpa);
            const rows: usize = if (attach_client.terminalSize()) |size| size[1] else 24;
            start.appendSlice(d.gpa, "\x1b[0m") catch {};
            start.appendNTimes(d.gpa, '\n', rows) catch {};
            start.appendSlice(d.gpa, paint.enter_modes ++ take) catch {};
            for (0..rows) |y| {
                var buf: [24]u8 = undefined;
                start.appendSlice(d.gpa, std.fmt.bufPrint(&buf, "\x1b[{d};1H\x1b[2K", .{y + 1}) catch "") catch {};
            }
            plat.stdoutWriteAll(start.items) catch {};
        }
        const outcome = d.loop();
        if (d.alt_scroll == null) d.awaitAnswer();
        d.finish();
        var tail: std.ArrayList(u8) = .empty;
        defer tail.deinit(d.gpa);
        tail.appendSlice(d.gpa, modes_off ++ "\x1b[?2004l") catch {};
        if (d.alt_scroll) |v| switch (v) {
            1 => tail.appendSlice(d.gpa, "\x1b[?1007h") catch {},
            2 => tail.appendSlice(d.gpa, "\x1b[?1007l") catch {},
            else => {},
        } else if (d.shown_modes.alt_scroll) tail.appendSlice(d.gpa, "\x1b[?1007l") catch {};
        // Scrolling on output goes back off only where it was found off.
        if (d.shown_modes.scroll_output and d.scroll_output == 2) tail.appendSlice(d.gpa, "\x1b[?1010l") catch {};
        tail.appendSlice(d.gpa, paint.leave) catch {};
        if (d.own_style) |n| {
            var buf: [8]u8 = undefined;
            tail.appendSlice(d.gpa, std.fmt.bufPrint(&buf, "\x1b[{d} q", .{n}) catch "") catch {};
        }
        if (d.on_alt and !d.settings.alt_screen) {
            tail.appendSlice(d.gpa, "\x1b[?1049l") catch {};
            // Back where the normal screen's painting left the cursor: the
            // closing line goes below it.
            if (!d.settings.paint_alt) tail.appendSlice(d.gpa, "\r\n") catch {};
        }
        plat.stdoutWriteAll(tail.items) catch {};
        if (saved) |orig| plat.tcsetattr(0, .FLUSH, orig) catch {};
        attach_client.forgetRaw();
        return outcome;
    }

    /// Wait briefly for the terminal's answer to the alternate scroll
    /// query, behind a DA1 query that every terminal answers, so neither
    /// answer reaches the shell after the attach.
    fn awaitAnswer(d: *Drawn) void {
        plat.stdoutWriteAll("\x1b[c") catch return;
        var in: Input = .{ .detach_key = 0, .style_due = d.input.style_due };
        defer in.deinit(d.gpa);
        const until = io_mod.nowNanos() + answer_wait_ns;
        while (true) {
            const now = io_mod.nowNanos();
            if (now >= until) return;
            var fds = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, @intCast(@divTrunc(until - now, std.time.ns_per_ms) + 1)) <= 0) continue;
            var chunk: [1024]u8 = undefined;
            const n = std.c.read(0, &chunk, chunk.len);
            if (n <= 0) return;
            in.feed(d.gpa, chunk[0..@intCast(n)], now) catch return;
            while (in.next(now)) |unit| switch (unit) {
                .mode_report => |m| switch (m.mode) {
                    1007 => d.foundAltScroll(m.value),
                    1010 => d.scroll_output = m.value,
                    else => {},
                },
                .cursor_style => |style| d.foundStyle(style),
                .attributes => return,
                else => {},
            };
        }
    }

    fn foundStyle(d: *Drawn, style: ?u8) void {
        d.input.style_due = false;
        const n = style orelse return;
        d.own_style = n;
        if (d.canvas) |*c| {
            c.own_shape = n;
            c.shape_due = true;
        }
    }

    fn foundAltScroll(d: *Drawn, value: u32) void {
        // Terminals answer in order: one that answered this and not the
        // style query has none to give.
        d.input.style_due = false;
        d.alt_scroll = value;
        attach_client.alt_scroll_found.store(value, .release);
    }

    /// End the attach on the person's word, leaving the session running.
    fn leave(d: *Drawn) void {
        // A box that had the keys hears that it lost them.
        if (d.focused) |old| if (d.slotOf(old)) |s| d.pass(.{ .focus = "\x1b[O" }, s, null, io_mod.nowNanos());
        d.focused = null;
        d.flushOut();
        if (d.main.view) |v| {
            v.queue("{\"detach\":true}");
        }
    }

    const Polled = union(enum) { stdin, view: *View, events, request: *Request };
    const max_polled = 2 * boxes.max_boxes + 8 + boxes.max_boxes + 4 + max_previews;

    fn loop(d: *Drawn) Outcome {
        d.onWinch();
        while (true) {
            const sig = attach_client.got_quit.load(.acquire);
            if (sig != 0) {
                d.leave();
                return d.done(.failed, 128 + sig, "tuppet: interrupted; detached from session {s}\n", .{d.id_text});
            }
            if (attach_client.got_winch.swap(false, .acq_rel)) d.onWinch();
            const now = io_mod.nowNanos();
            if (d.retry) |r| if (now >= r.next) {
                if (d.reattach(now)) |outcome| return outcome;
            };
            if (d.events_retry) |r| if (now >= r.next) {
                if (d.reopenEvents(now)) |outcome| return outcome;
            };
            if (d.notice_until) |until| if (now >= until) d.clearNotice();
            if (d.takeInput(now)) |outcome| return outcome;
            if (d.serviceStreams(now)) |outcome| return outcome;
            if (d.ended) |e| if (d.m.finished(now, d.input.pending())) {
                d.ended = null;
                return e;
            };
            d.steer(now);
            d.maybePaint(now);
            if (d.pollOnce()) |outcome| return outcome;
        }
    }

    /// Wait for input, a stream, or the next deadline, and read what came.
    fn pollOnce(d: *Drawn) ?Outcome {
        var fds: [max_polled]std.c.pollfd = undefined;
        var what: [max_polled]Polled = undefined;
        var n: usize = 0;
        var busy = false;
        const add = struct {
            fn add(f: *[max_polled]std.c.pollfd, w: *[max_polled]Polled, count: *usize, fd: std.posix.fd_t, events: i16, p: Polled) void {
                if (count.* == max_polled or events == 0) return;
                f[count.*] = .{ .fd = fd, .events = events, .revents = 0 };
                w[count.*] = p;
                count.* += 1;
            }
        }.add;
        add(&fds, &what, &n, 0, std.c.POLL.IN, .stdin);
        var views: [2 * boxes.max_boxes + 4 + max_previews]*View = undefined;
        var nv: usize = 0;
        const side_view: ?*View = if (d.side) |s| s.view else null;
        const side_next: ?*View = if (d.side) |s| s.next else null;
        for ([_]?*View{ d.main.view, d.main.next, side_view, side_next }) |v| if (v) |x| {
            views[nv] = x;
            nv += 1;
        };
        for (d.previews.values()) |v| if (nv < views.len) {
            views[nv] = v;
            nv += 1;
        };
        for (d.slots.items) |s| for ([_]?*View{ s.view, s.next }) |v| if (v) |x| if (nv < views.len) {
            views[nv] = x;
            nv += 1;
        };
        for (views[0..nv]) |v| {
            if (v.end != null) continue;
            busy = busy or v.busy();
            var events: i16 = 0;
            if (v.wantsInput()) events |= std.c.POLL.IN;
            if (v.outq.items.len > 0) events |= std.c.POLL.OUT;
            add(&fds, &what, &n, v.fd(), events, .{ .view = v });
        }
        if (d.events) |e| {
            busy = busy or std.mem.indexOfScalarPos(u8, e.in.items, e.in_at, '\n') != null;
            add(&fds, &what, &n, e.fd(), std.c.POLL.IN, .events);
        }
        for (d.requests.items) |r| add(&fds, &what, &n, r.fd(), std.c.POLL.IN, .{ .request = r });
        const now = io_mod.nowNanos();
        if (std.c.poll(&fds, @intCast(n), if (busy) 0 else d.timeout(now)) < 0) return null;
        for (fds[0..n], what[0..n]) |f, w| {
            if (f.revents == 0) continue;
            switch (w) {
                .stdin => {
                    var chunk: [4096]u8 = undefined;
                    const got = std.c.read(0, &chunk, chunk.len);
                    if (got < 0) switch (std.posix.errno(got)) {
                        .INTR, .AGAIN => continue,
                        else => {},
                    };
                    if (got <= 0) {
                        d.leave();
                        return d.done(.failed, client.exit_code.failed, "tuppet: this terminal's input ended; detached from session {s}\n", .{d.id_text});
                    }
                    const at = io_mod.nowNanos();
                    d.input.feed(d.gpa, chunk[0..@intCast(got)], at) catch {};
                    if (d.takeInput(at)) |outcome| return outcome;
                },
                .view => |v| {
                    if (f.revents & std.c.POLL.OUT != 0) v.flush();
                    if (f.revents & ~@as(i16, std.c.POLL.OUT) != 0) _ = v.pump();
                },
                .events => if (d.events) |e| {
                    _ = e.pump();
                },
                .request => |r| if (r.pump()) {
                    for (d.requests.items, 0..) |x, i| if (x == r) {
                        _ = d.requests.swapRemove(i);
                        break;
                    };
                    r.deinit();
                },
            }
        }
        // A request the daemon never answers goes after the deadline.
        var i: usize = 0;
        while (i < d.requests.items.len) {
            const r = d.requests.items[i];
            if (now - r.started < reply_ns) {
                i += 1;
                continue;
            }
            _ = d.requests.swapRemove(i);
            r.deinit();
        }
        return null;
    }

    /// How long poll may sleep: until the frame's end when a paint waits,
    /// a sequence's wait, a box's next step, a notice's end, or the next
    /// retry.
    fn timeout(d: *Drawn, now: i64) c_int {
        var until: i64 = now + 200 * std.time.ns_per_ms;
        if (d.paintDue()) |t| until = @min(until, if (d.hold_until) |h| @max(t, @min(h, now + frame_ns)) else t);
        if (d.input.deadline()) |t| until = @min(until, t);
        if (d.m.deadline(d.input.pending())) |t| until = @min(until, t);
        if (d.notice_until) |t| until = @min(until, t);
        if (d.retry) |r| until = @min(until, r.next);
        if (d.events_retry) |r| until = @min(until, r.next);
        if (d.switcher.deadline()) |t| until = @min(until, t);
        if (d.hold) |h| until = @min(until, h.since + hold_ns);
        if (d.dropped_until > now) until = @min(until, d.dropped_until);
        if (d.side) |s| if (s.retry_at > now) {
            until = @min(until, s.retry_at);
        };
        for (d.slots.items) |s| if (s.retry_at > now) {
            until = @min(until, s.retry_at);
        };
        const ms = std.time.ns_per_ms;
        return @intCast(std.math.clamp(@divTrunc(until - now + ms - 1, ms), 0, 200));
    }

    /// Bring the boxes up to date: where they fit, the time, the roles
    /// their streams hold, the bell, and the cursor report of an opening.
    fn steer(d: *Drawn, now: i64) void {
        if (d.group) |g| {
            d.syncSide(now);
            d.sizeMembers();
            if (d.hold) |h| if (now - h.since >= hold_ns) {
                d.hold = null;
            };
            _ = d.doSwitcher(d.switcher.tick(g, now), now);
            // Back to compact: the front takes keys once they paused.
            const view = d.sideView();
            if (view == .compact and d.side_was != .compact) d.side_quiet = now;
            if (view != d.side_was) d.pacer.changed(now);
            d.side_was = view;
        }
        // Twice: what the time changes moves boxes, and the reverse.
        for (0..2) |_| {
            d.placeBoxes(now);
            d.m.tick(now, d.input.pending());
        }
        d.applyRoles(now);
        if (d.m.takeBell()) plat.stdoutWriteAll("\x07") catch {};
        d.syncModes();
        d.tellFocus(now);
        if (d.m.ask() != null) d.askReport(now);
        const look = d.lookOf();
        if (look != d.look) {
            d.look = look;
            d.pacer.changed(now);
        }
    }

    /// Tell the boxes where each fits in the window, resizing the one that
    /// is shown when it does not fit, and back toward the size it had
    /// before once the window allows.
    fn placeBoxes(d: *Drawn, now: i64) void {
        const c = &(d.canvas orelse return);
        const window: [2]u16 = if (d.group != null) d.split().front else .{ @intCast(c.cols), @intCast(c.rows) };
        const below: u16 = if (d.lineRow()) |row| @intFromBool(row == 0) else 0;
        for (d.slots.items) |s| {
            s.placed = null;
            var fit: boxes.Fit = .pending;
            const shown = d.m.keyboard() == s.id or d.m.line_id == s.id or d.m.never() == s.id or d.m.opensAtOnce(s.id);
            if (shown) d.refresh(s, now);
            if (shown and s.shown) {
                const size: [2]u16 = .{ @intCast(s.layer.cols), @intCast(s.layer.rows) };
                if (s.shrunk_from) |from| if (std.mem.eql(u16, &from, &size)) {
                    s.shrunk_from = null;
                };
                const wanted = s.shrunk_from orelse size;
                const to: ?[2]u16 = switch (place(s, window, wanted, below)) {
                    .placed => wanted,
                    .resize => |to| to,
                    .too_small => null,
                };
                if (to) |t| {
                    if (!std.mem.eql(u16, &t, &size) and d.m.writer and d.resizeBox(s, t, now)) {
                        if (s.shrunk_from == null) s.shrunk_from = size;
                        fit = .pending;
                    } else switch (place(s, window, size, below)) {
                        .placed => |p| {
                            fit = .{ .place = p.place };
                            s.placed = p;
                        },
                        else => fit = .too_small,
                    }
                } else fit = .too_small;
            }
            d.m.setFit(s.id, fit, now);
        }
    }

    fn place(s: *const Slot, window: [2]u16, size: [2]u16, below: u16) boxes.Placement {
        return if (s.grab == .never) boxes.placeNever(window, size, s.start, below) else boxes.placeOpen(window, size, s.start);
    }

    /// Resize a box's session with the `resize` request, never with its
    /// attach stream, so no writer's detach gives it its size back.
    fn resizeBox(d: *Drawn, s: *Slot, to: [2]u16, now: i64) bool {
        if (s.resized_to) |was| if (std.mem.eql(u16, &was, &to) and now - s.resized_at < resize_again_ns) return true;
        var id_buf: [20]u8 = undefined;
        const ref = std.fmt.bufPrint(&id_buf, "{d}", .{s.id}) catch unreachable;
        const r = Request.start(d.gpa, protocol.ResizeReq{ .session = ref, .cols = to[0], .rows = to[1] }, now) catch return false;
        d.requests.append(d.gpa, r) catch {
            r.deinit();
            return false;
        };
        s.resized_to = to;
        s.resized_at = now;
        return true;
    }

    /// What the boxes show, to tell when a paint is due.
    fn lookOf(d: *Drawn) u64 {
        var h = std.hash.Wyhash.init(0);
        const add = struct {
            fn add(hash: *std.hash.Wyhash, v: u64) void {
                hash.update(std.mem.asBytes(&v));
            }
        }.add;
        if (d.m.open) |o| {
            add(&h, o.id);
            add(&h, @backingInt(o.phase));
            add(&h, o.serial);
        }
        if (d.m.line()) |l| {
            add(&h, l.id);
            add(&h, @backingInt(l.kind));
            add(&h, l.more);
        }
        if (d.m.receipt) |*r| h.update(r.title.text());
        add(&h, d.m.never() orelse 0);
        add(&h, d.m.waiting());
        add(&h, @intFromBool(d.m.writer));
        for (d.slots.items) |s| if (s.placed) |p| {
            add(&h, s.id);
            add(&h, @as(u64, p.place.x) << 48 | @as(u64, p.place.y) << 32 | @as(u64, p.place.cols) << 16 | p.place.rows);
            add(&h, p.margin);
        };
        return h.final();
    }

    /// After the opening frame, or a change of the open box's size or
    /// place: its input modes, the frame, then the cursor on the box's
    /// first program cell and a cursor report asked for.
    fn askReport(d: *Drawn, now: i64) void {
        const cell = d.m.ask() orelse return;
        d.syncModes();
        d.repaint(now);
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("\x1b[{d};{d}H\x1b[6n", .{ cell.row, cell.col }) catch return;
        if (d.canvas) |c| if (c.shown_cursor.at) |p| w.print("\x1b[{d};{d}H", .{ p.y + 1, p.x + 1 }) catch {};
        plat.stdoutWriteAll(w.buffered()) catch {};
        d.m.asked(now);
    }

    // ---- input ----------------------------------------------------------

    /// The stream of the session that has the keyboard, for its input
    /// modes; null while none takes keys.
    fn keyboardView(d: *Drawn) ?*View {
        if (d.m.keyboard()) |id| {
            const s = d.slotOf(id) orelse return null;
            const v = s.view orelse return null;
            return if (v.has_terminal) v else null;
        }
        const under = d.underSlot();
        if (under == &d.main and (d.main_role != .write or d.frontEnded())) return null;
        const v = under.view orelse return null;
        return if (v.has_terminal and v.role == .write) v else null;
    }

    const Taken = union(enum) { taken, outcome: Outcome };

    /// What a group attach does with a unit before the boxes and the
    /// session see it: drop it while a new screen is not answered yet, or
    /// while keys must pause, give it to the switcher, take its own keys,
    /// close an ended member, or take a member over. Null passes it on.
    fn groupKey(d: *Drawn, unit: Unit, at: i64, now: i64) ?Taken {
        const key_like = switch (unit) {
            .key, .paste, .named, .detach => true,
            .mouse => |bytes| mouseIsKey(bytes),
            .focus => false,
            else => return switch (unit) {
                .report => |r| if (d.hold) |h| (if (h.cell) |c| (if (c.row == r.row and c.col == r.col) blk: {
                    d.hold = null;
                    break :blk .taken;
                } else null) else null) else null,
                else => null,
            },
        };
        if (d.hold != null) {
            if (key_like) d.countDropped(at);
            return .taken;
        }
        if (d.switcher.open) {
            const g = d.group.?;
            const k: group_mod.Key = switch (unit) {
                .named => |n| if (n.which == .switch_key) .switch_key else return .taken,
                .detach => .menu_key,
                .key => |bytes| .{ .bytes = bytes },
                else => return .taken,
            };
            var att: [256]bool = undefined;
            for (g.members.items, 0..) |m, i| if (i < att.len) {
                att[i] = m.id != d.main.id and g.attention(m) != null;
            };
            const what = d.switcher.key(g, k, now, att[0..@min(g.members.items.len, att.len)]);
            d.pacer.changed(now);
            if (d.doSwitcher(what, now)) |o| return .{ .outcome = o };
            return .taken;
        }
        // A box that has the keys gets them all, as without a group.
        if (d.m.keyboard() != null) return null;
        switch (unit) {
            .detach => {
                if (d.m.press(at) == .detach) d.openSwitcher(now);
                return .taken;
            },
            .named => |n| {
                switch (n.which) {
                    .switch_key => {
                        d.switch_len = @min(n.bytes.len, d.switch_bytes.len);
                        @memcpy(d.switch_bytes[0..d.switch_len], n.bytes[0..d.switch_len]);
                        d.openSwitcher(now);
                    },
                    .side_key => d.sideStep(d.main.id),
                }
                return .taken;
            },
            else => {},
        }
        if (d.frontEnded()) {
            const bytes = if (unit == .key) unit.key else return .taken;
            if (d.end_with == d.main.id) return .taken;
            if (std.mem.eql(u8, bytes, "\r") or std.mem.eql(u8, bytes, "x")) {
                if (d.closeFront(now)) |o| return .{ .outcome = o };
                return .taken;
            }
            const m = d.front() orelse return .taken;
            const letter = if (bytes.len == 1) bytes[0] else return .taken;
            const registered = for (m.st().actions) |a| {
                if (a.key.len == 1 and a.key[0] == letter) break true;
            } else false;
            if (registered or letter == 'r') {
                var buf: [20]u8 = undefined;
                d.request(protocol.ActionReq{ .session = std.fmt.bufPrint(&buf, "{d}", .{m.id}) catch unreachable, .key = &.{letter} });
            }
            return .taken;
        }
        if (d.front_elsewhere) {
            if (unit == .key and std.mem.eql(u8, unit.key, "\r")) if (d.front()) |m| d.openFront(m, .take, now);
            return .taken;
        }
        if (d.side) |s| if (d.sideView() != .compact and unit == .key and escapeKey(unit.key) == .press) {
            d.setSideView(s.id, .compact);
            return .taken;
        };
        if (d.side_quiet) |*since| if (key_like) {
            if (at - since.* < d.m.pause_ns) {
                since.* = at;
                d.countDropped(at);
                return .taken;
            }
            d.side_quiet = null;
        };
        return null;
    }

    fn countDropped(d: *Drawn, at: i64) void {
        d.dropped += 1;
        d.dropped_until = at + dropped_ns;
        d.pacer.changed(at);
    }

    /// Pass the input units that are whole to the sessions.
    fn takeInput(d: *Drawn, now: i64) ?Outcome {
        // A terminal that answers neither query never ends the wait.
        if (now > d.answers_until) {
            d.input.style_due = false;
            d.input.osc_due = false;
        }
        if (d.keyboardView()) |k| d.input.utf8_mouse = k.terminal.flags.mouse_format == .utf8;
        defer d.flushOut();
        while (d.input.next(now)) |unit| {
            const at = d.input.unit_at;
            if (d.group != null) if (d.groupKey(unit, at, now)) |taken| switch (taken) {
                .taken => continue,
                .outcome => |o| return o,
            };
            switch (unit) {
                .named => |n| d.route(.{ .key = n.bytes }, at),
                .detach => {
                    // Without the writer role nothing ends the attach but
                    // this key, so it detaches also with --no-detach.
                    if (d.m.press(at) == .detach) {
                        d.leave();
                        return d.done(.detached, 0, "tuppet: detached; session {s} keeps running ('tuppet attach {s}' to return)\n", .{ d.id_text, d.id_text });
                    }
                },
                .report => |r| if (!d.m.report(.{ .row = r.row, .col = r.col }, at)) d.route(.{ .key = r.bytes }, at),
                .mode_report => |m| switch (m.mode) {
                    1007 => d.foundAltScroll(m.value),
                    1010 => d.scroll_output = m.value,
                    else => {},
                },
                .cursor_style => |style| d.foundStyle(style),
                .attributes, .dropped => {},
                .key => |bytes| switch (escapeKey(bytes)) {
                    .no => d.route(unit, at),
                    .press => {
                        d.esc_taken = d.m.escape(at);
                        if (!d.esc_taken) d.route(unit, at);
                    },
                    // Where its press went.
                    .release => if (!d.esc_taken) d.route(unit, at),
                },
                .paste, .mouse, .focus => d.route(unit, at),
            }
        }
        return null;
    }

    /// Pass a unit where the boxes say.
    fn route(d: *Drawn, unit: Unit, at: i64) void {
        if (unit == .paste and unit.paste.first) d.paste_to = null;
        const kind: boxes.Kind = switch (unit) {
            .key => .key,
            .paste => |p| .{ .paste = .{ .first = p.first, .last = p.last } },
            .mouse => |bytes| if (mouseIsKey(bytes)) .key else .quiet,
            else => .quiet,
        };
        switch (d.m.route(kind, at)) {
            // The keyboard moved during a paste: the part that went is
            // closed.
            .drop => if (unit == .paste) if (d.paste_to) |v| {
                if (d.paste_brackets) {
                    if (d.out_to == v) d.flushOut();
                    v.sendData("\x1b[201~");
                }
                d.paste_to = null;
            },
            .under => d.pass(unit, d.underSlot(), null, at),
            .box => |id| if (d.slotOf(id)) |s| d.pass(unit, s, s.placed, at),
        }
    }

    /// Forget the input read and not yet passed, and what the person typed
    /// ahead and tuppet has not read yet; the rest of a paste that has
    /// begun is dropped up to its end.
    fn dropTypedAhead(d: *Drawn) void {
        var chunk: [4096]u8 = undefined;
        while (true) {
            var fds = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 0) <= 0) break;
            const n = std.c.read(0, &chunk, chunk.len);
            if (n <= 0) break;
            d.input.feed(d.gpa, chunk[0..@intCast(n)], io_mod.nowNanos()) catch break;
        }
        d.discardInput(io_mod.nowNanos());
    }

    /// Drop the input read and not yet passed. Cursor reports in it still
    /// answer tuppet's asks, which the terminal answers in order.
    fn discardInput(d: *Drawn, now: i64) void {
        discard(&d.input, &d.m, now);
    }

    /// Add a unit to the data for the session of `s`: a paste's pieces all
    /// go where its first went, and a unit never spans two data frames.
    /// `placed`: a box's place, whose mouse reports are moved into it.
    fn pass(d: *Drawn, unit: Unit, s: *Slot, placed: ?boxes.Placed, now: i64) void {
        // Keys read while the stream is attached again are dropped.
        if (s == &d.main and d.retry != null) return;
        var to = s.writer() orelse return;
        // A stream opening in the write role has no copy yet: the modes
        // are those of the one it replaces.
        const t: *vt.Terminal = if (to.ready()) &to.terminal else if (s.view) |v| (if (v.has_terminal) &v.terminal else return) else return;
        var parts: [3][]const u8 = .{ "", "", "" };
        var moved: [64]u8 = undefined;
        switch (unit) {
            .key => |bytes| parts[1] = bytes,
            .paste => |p| {
                if (p.first) {
                    d.paste_to = to;
                    d.paste_brackets = t.modes.get(.bracketed_paste);
                }
                to = d.paste_to orelse return;
                parts = .{
                    if (p.first and d.paste_brackets) "\x1b[200~" else "",
                    p.text,
                    if (p.last and d.paste_brackets) "\x1b[201~" else "",
                };
                if (p.last) d.paste_to = null;
            },
            .mouse => |bytes| {
                if (t.flags.mouse_event == .none) return;
                parts[1] = if (placed) |p| moveMouse(&moved, bytes, p.place, t.flags.mouse_format == .sgr_pixels) orelse return else bytes;
            },
            .focus => |bytes| {
                if (!t.modes.get(.focus_event)) return;
                parts[1] = bytes;
            },
            else => return,
        }
        const len = parts[0].len + parts[1].len + parts[2].len;
        if (len == 0) return;
        if (d.out_to != to or d.out.items.len + len > max_data) d.flushOut();
        d.out_to = to;
        d.out.ensureUnusedCapacity(d.gpa, len) catch return;
        for (parts) |part| d.out.appendSliceAssumeCapacity(part);
        if (unit != .focus) d.pacer.key(now);
    }

    fn flushOut(d: *Drawn) void {
        if (d.out.items.len == 0) return;
        if (d.out_to) |v| v.sendData(d.out.items);
        d.out.clearRetainingCapacity();
    }

    /// Tell a box's program that asked for focus reports when its box
    /// takes the keys (CSI I) and when it loses them (CSI O).
    fn tellFocus(d: *Drawn, now: i64) void {
        const id: ?u64 = if (d.m.keyboard()) |k| (if (d.m.role(k) == .write) k else null) else null;
        if (id == d.focused) return;
        if (d.focused) |old| if (d.slotOf(old)) |s| d.pass(.{ .focus = "\x1b[O" }, s, null, now);
        if (id) |new| if (d.slotOf(new)) |s| d.pass(.{ .focus = "\x1b[I" }, s, null, now);
        d.focused = id;
        d.flushOut();
    }

    /// Give the person's terminal the input modes of the session that has
    /// the keyboard; none while it takes no keys.
    fn syncModes(d: *Drawn) void {
        var want: InputModes = if (d.keyboardView()) |k| .of(&k.terminal) else .{};
        // Reports moved into a box come in cells: tuppet does not know
        // the size of a cell in pixels.
        if (d.m.keyboard() != null and want.mouse_format == .sgr_pixels) want.mouse_format = .sgr;
        // The wheel scrolls a full-screen program that did not ask for
        // the mouse, as arrow keys, while no box waits or has the keys.
        if (d.keyboardView()) |k| want.alt_scroll = k == d.main.view and d.m.waiting() == 0 and
            want.mouse == .none and k.terminal.screens.active_key == .alternate;
        // A box is shown, not left above a view scrolled back: a terminal
        // set not to scroll on output (xterm -si) keeps that view.
        want.scroll_output = d.shown_modes.scroll_output or (d.m.keyboard() != null and d.scroll_output != 1 and d.scroll_output != 3);
        if (d.m.keyboard() == null and d.scroll_output == 2) want.scroll_output = false;
        if (std.meta.eql(want, d.shown_modes)) return;
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        InputModes.change(&w, d.shown_modes, want) catch return;
        plat.stdoutWriteAll(w.buffered()) catch {};
        d.shown_modes = want;
    }

    fn onWinch(d: *Drawn) void {
        const size = attach_client.terminalSize() orelse return;
        const c = &(d.canvas orelse return);
        if (c.cols != size[0] or c.rows != size[1]) {
            const now = io_mod.nowNanos();
            const first = c.cols == 0;
            if (!first) d.pulled = @min(d.pulled + d.mayPull(c, size), size[1] -| 1);
            if (!first and d.on_alt) d.alt_grown += size[1] -| c.rows;
            c.resize(size[0], size[1]) catch return;
            d.pacer.changed(now);
            if (d.frozen != null) {
                d.retake = true;
                d.retake_until = now + resize_hold_ns;
            }
            if (!first and !d.on_alt and d.settings.resize and d.main_role == .write) d.hold_until = now + resize_hold_ns;
        }
        if (d.settings.resize and d.main_role == .write and d.group == null) d.sendSize();
    }

    /// How many rows a terminal may take back from its scrollback when its
    /// window goes from the canvas's size to `size`: one for each row it
    /// grew, and with more columns, each row that joins the next.
    fn mayPull(d: *const Drawn, c: *const paint.Canvas, size: [2]u16) usize {
        var n: usize = size[1] -| c.rows;
        if (size[0] > c.cols) {
            // The rows marked as wrapped, and the row above the window,
            // which a held line may have wrapped into its top row. On the
            // alternate screen the normal screen's marks are not known.
            if (d.on_alt) return size[1];
            n += 1;
            for (c.shown_wrap) |m| n += @intFromBool(m != .off);
        }
        return n;
    }

    /// Write the rows a resize may have brought back from the scrollback
    /// into it again, before anything is painted over them; on the normal
    /// screen only. They may repeat there, but none is lost.
    fn pushPulled(d: *Drawn, w: *std.Io.Writer) void {
        const c = &(d.canvas orelse return);
        if (d.on_alt or d.pulled == 0) return;
        // The bar and tuppet's lines never go into the scrollback.
        c.eraseOwn(w) catch return;
        c.pushUp(w, d.pulled) catch return;
        d.pulled = 0;
    }

    /// Send this terminal's size, unless the daemon has it already.
    fn sendSize(d: *Drawn) void {
        const size = attach_client.terminalSize() orelse return;
        if (d.sent_size) |sent| if (std.mem.eql(u16, &sent, &size)) return;
        d.sent_size = size;
        var buf: [64]u8 = undefined;
        const v = d.main.view orelse return;
        v.queue(std.fmt.bufPrint(&buf, "{{\"resize\":{{\"cols\":{d},\"rows\":{d}}}}}", .{ size[0], size[1] }) catch return);
    }

    // ---- painting -------------------------------------------------------

    /// The slots painted now: the session underneath, the open box, and
    /// the `--grab never` box.
    fn visible(d: *Drawn, buf: *[4]*Slot) []*Slot {
        buf[0] = &d.main;
        var n: usize = 1;
        if (d.side) |s| {
            buf[n] = s;
            n += 1;
        }
        for ([_]?u64{ d.m.keyboard(), d.m.never() }) |id| if (id) |i| if (d.slotOf(i)) |s| {
            buf[n] = s;
            n += 1;
        };
        return buf[0..n];
    }

    /// Whether a layer keeps its last copy a while longer: its program is
    /// inside a synchronized update, which holds the layer at most a frame
    /// and never the echo of a key.
    fn syncHeld(d: *Drawn, s: *Slot, now: i64) bool {
        const v = s.view orelse return false;
        const since = s.dirty_at orelse return false;
        return v.ready() and v.terminal.modes.get(.synchronized_output) and !d.pacer.echo and now - since < frame_ns;
    }

    /// When the waiting paint is due; null when none waits.
    fn paintDue(d: *Drawn) ?i64 {
        var due = d.pacer.due(false);
        var buf: [4]*Slot = undefined;
        const now = io_mod.nowNanos();
        for (d.visible(&buf)) |s| if (d.syncHeld(s, now)) {
            const at = s.dirty_at.? + frame_ns;
            due = if (due) |x| @min(x, at) else at;
        };
        return due;
    }

    fn maybePaint(d: *Drawn, now: i64) void {
        const due = d.paintDue() orelse return;
        if (due > now) return;
        // A resize whose signal is not handled yet: the frame is for the
        // window's size, and what the terminal took back goes back first.
        const c = &(d.canvas orelse return);
        const size: [2]usize = .{ c.cols, c.rows };
        d.onWinch();
        // The boxes are placed in the window as it is now.
        if (c.cols != size[0] or c.rows != size[1]) d.steer(now);
        if (d.holding(now)) return;
        d.repaint(now);
    }

    /// Bring a slot's layer up to date with its copy, unless the copy
    /// waits: for a screen, or a while for a synchronized update to end.
    fn refresh(d: *Drawn, s: *Slot, now: i64) void {
        if (!d.syncHeld(s, now)) d.redraw(s);
    }

    /// Bring a slot's layer up to date with its copy, unless the copy
    /// waits for a screen.
    fn redraw(d: *Drawn, s: *Slot) void {
        const v = s.view orelse return;
        if (!v.ready() or (s.shown and s.dirty_at == null)) return;
        const t = &v.terminal;
        if (s.layer.cols != t.cols or s.layer.rows != t.rows) s.layer.resize(t.cols, t.rows) catch return;
        s.layer.clear();
        s.cursor = s.layer.drawScreen(t, .{ .x = 0, .y = 0, .cols = t.cols, .rows = t.rows });
        s.cursor_row = t.screens.active.cursor.y;
        s.shown = true;
        s.dirty_at = null;
        // The rows that left the copy left the layer now, after the mark
        // of a switch.
        if (s == &d.main and v.track) {
            if (v.left.len() > 0) if (d.mark_due) |mark| {
                d.pending.note(mark, .{ .faint = true });
                d.gpa.free(mark);
                d.mark_due = null;
            };
            d.pending.take(&v.left);
        }
    }

    /// The row tuppet's line shows in, while it shows: the top row, or the
    /// bottom row while the program underneath has its cursor in the top
    /// row.
    fn lineRow(d: *Drawn) ?usize {
        if (d.m.line() == null and d.m.receipt == null) return null;
        // The bar carries it.
        if (d.split().bar_row != null) return null;
        const c = d.canvas orelse return null;
        if (d.on_alt) return if (d.main.cursor_row == 0 and c.rows > 1) c.rows - 1 else 0;
        // On the normal screen, a window that shrinks moves its top rows
        // into the scrollback: the line keeps to the bottom, at or below
        // the cursor's row where it can.
        const bottom = c.rows -| 1;
        return if (d.main.cursor_row == bottom and bottom > 0) bottom - 1 else bottom;
    }

    /// Compose the frame, layer by layer, and write what changed.
    fn repaint(d: *Drawn, now: i64) void {
        const c = &(d.canvas orelse return);
        d.pacer.painted(now);
        var buf: [4]*Slot = undefined;
        for (d.visible(&buf)) |s| d.refresh(s, now);
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(d.gpa);
        d.chooseScreen(&head);
        {
            var w: std.Io.Writer.Allocating = .fromArrayList(d.gpa, &head);
            d.pushPulled(&w.writer);
            head = w.toArrayList();
        }
        c.clear();
        var cursor: paint.Cursor = .{};
        const open: ?*Slot = if (d.m.keyboard()) |id| d.slotOf(id) else null;
        // The session underneath, or its backdrop while a box has the
        // keyboard.
        if (if (open) |s| s.backdrop else null) |backdrop| switch (backdrop) {
            .frozen => if (d.freeze()) |f| c.blit(f, 0, 0, .same),
            .live => c.blit(&d.main.layer, 0, 0, .faded),
        } else if (d.frontEnded()) {
            c.blit(&d.main.layer, 0, 0, .faded);
        } else if (d.front_elsewhere) {
            c.blit(&d.main.layer, 0, 0, .same);
        } else {
            c.blit(&d.main.layer, 0, 0, .same);
            cursor = d.main.cursor;
        }
        if (!d.on_alt) c.park = d.main.cursor.park;
        // The side session's cursor shows where it has the keys.
        var side_keys = false;
        if (d.group != null) {
            const sp = d.split();
            // Rows of a larger copy than the front's area stay hidden.
            if (sp.front[1] < c.rows) for (sp.front[1]..c.rows) |y| c.blank(y, 0, c.cols, .{});
            if (sp.front[0] < c.cols) for (0..sp.area_rows) |y| c.blank(y, sp.front[0], c.cols, .{});
            if (d.side) |s| if (d.drawSide(c, s, sp)) |side_cursor| {
                if (open == null and d.m.keyboard() == null) {
                    cursor = side_cursor;
                    side_keys = true;
                }
            };
            if (d.switcher.open) {
                d.drawSwitcher(c, sp);
                cursor.at = null;
            }
        }
        if (d.m.never()) |id| if (d.slotOf(id)) |s| if (s.placed) |p| d.drawNever(c, s, p);
        if (open) |s| if (s.placed) |p| {
            d.drawOpen(c, s, p);
            cursor = .{ .shape = s.cursor.shape };
            if (s.cursor.at) |at| cursor.at = .{ .x = p.place.x + at.x, .y = p.place.y + at.y };
        };
        if (d.lineRow()) |y| {
            var text_buf: [512]u8 = undefined;
            if (d.lineText(&text_buf, c.cols)) |text| d.drawLine(c, y, text);
        }
        var note_buf: [512]u8 = undefined;
        if (d.split().bar_row) |y| {
            d.drawBar(c, y, now);
        } else if ((if (d.group != null) d.frontNote(&note_buf, now) else null) orelse d.notice) |text| {
            const avoid: ?usize = if (open == null) if (cursor.at) |at| at.y else null else null;
            const bottom = c.rows -| 1;
            const want: usize = if (d.lineRow()) |l|
                (if (l == 0) 1 else l -| 1)
            else if (d.on_alt)
                (if (avoid == 0) bottom else 0)
            else if (avoid == bottom) bottom -| 1 else bottom;
            if (noticeRow(c, want, avoid)) |y| d.drawLine(c, y, text);
        }
        // A cursor that a box or a line covers is hidden.
        if (cursor.at) |at| if (at.y >= c.rows or at.x >= c.cols or (open == null and !side_keys and c.row(at.y)[at.x].top)) {
            cursor.at = null;
        };
        c.cursor = cursor;
        const bytes = c.emit(if (d.on_alt) null else &d.pending, std.math.maxInt(usize)) catch return;
        if (head.items.len > 0) plat.stdoutWriteAll(head.items) catch {};
        plat.stdoutWriteAll(bytes) catch {};
        // After a new screen in front: a cursor report, and keys count
        // only once it is answered.
        if (d.hold) |*h| if (h.cell == null and (d.main.shown or d.frontEnded())) {
            var ask: [48]u8 = undefined;
            var w: std.Io.Writer = .fixed(&ask);
            w.print("\x1b[{d};1H\x1b[6n", .{c.rows}) catch {};
            if (c.shown_cursor.at orelse c.park) |p| w.print("\x1b[{d};{d}H", .{ p.y + 1, p.x + 1 }) catch {};
            plat.stdoutWriteAll(w.buffered()) catch {};
            h.cell = .{ .row = @intCast(c.rows), .col = 1 };
        };
        // Rows that did not fit in this frame go in the next ones.
        if (!d.on_alt and d.pending.len() > 0) d.pacer.changed(now);
    }

    const small_notice = "the window is smaller than the session: shown on the alternate screen until it fits";

    /// Whether to paint on the alternate screen: by choice, while the
    /// program is on its own, while a box has the keyboard, and while the
    /// window is smaller than the session.
    fn wantAlt(d: *Drawn) bool {
        if (d.settings.alt_screen or d.settings.paint_alt) return true;
        if (d.m.keyboard() != null) return true;
        // Rows beside a pane would carry its cells into the scrollback.
        if (d.group != null and d.side != null and d.split().beside) return true;
        const v = d.main.view orelse return d.on_alt;
        if (!v.ready()) return d.on_alt;
        if (v.terminal.screens.active_key == .alternate) return true;
        const c = d.canvas orelse return d.on_alt;
        const small = v.terminal.cols > c.cols or v.terminal.rows > c.rows;
        if (small != d.small) {
            d.small = small;
            if (small) {
                d.setNotice(small_notice, .{});
            } else if (d.notice) |n| if (std.mem.endsWith(u8, n, small_notice)) d.clearNotice();
        }
        return small;
    }

    /// Switch the person's terminal to the screen to paint on.
    fn chooseScreen(d: *Drawn, out: *std.ArrayList(u8)) void {
        const alt = d.wantAlt();
        if (alt == d.on_alt) return;
        const c = &(d.canvas orelse return);
        // A window that grows while the alternate screen shows may have
        // the normal screen's rows pushed into the scrollback on return:
        // tuppet's own line goes first.
        if (alt) {
            var w: std.Io.Writer.Allocating = .fromArrayList(d.gpa, out);
            c.eraseOwn(&w.writer) catch {};
            out.* = w.toArrayList();
        }
        out.appendSlice(d.gpa, if (alt) "\x1b[?1049h" ++ paint.enter else "\x1b[?1049l" ++ paint.enter_modes) catch return;
        d.on_alt = alt;
        c.invalidate();
        // Back on the normal screen, its rows' marks are unknown.
        c.setMarks(!alt, false);
        if (alt) d.alt_grown = 0 else d.writeLostAgain();
    }

    /// Back on the normal screen: the lines last written into the
    /// scrollback that the terminal may have moved onto the alternate
    /// screen while it grew are written again, before the held ones.
    fn writeLostAgain(d: *Drawn) void {
        const c = &(d.canvas orelse return);
        c.writeAgain(d.alt_grown, &d.pending);
        d.alt_grown = 0;
    }

    /// Before the attach ends: on the normal screen, the session's last
    /// screen without tuppet's own cells, every row due for the
    /// scrollback, and the cursor below them.
    fn finish(d: *Drawn) void {
        const c = &(d.canvas orelse return);
        if (d.settings.alt_screen or d.settings.paint_alt) return;
        const v = d.main.view orelse return;
        // The window may be smaller than the session, also while a box
        // had the keys and this was not looked at.
        if (v.ready()) d.small = v.terminal.cols > c.cols or v.terminal.rows > c.rows;
        if (d.on_alt) {
            // Back to the normal screen, unless the program or the
            // window keeps the attach off it.
            if (!v.ready() or v.terminal.screens.active_key == .alternate or d.small) return;
            plat.stdoutWriteAll("\x1b[?1049l" ++ paint.enter_modes) catch {};
            d.on_alt = false;
            c.invalidate();
            c.setMarks(true, false);
            d.writeLostAgain();
        }
        if (d.small) return;
        {
            var w: std.Io.Writer.Allocating = .init(d.gpa);
            defer w.deinit();
            d.pushPulled(&w.writer);
            plat.stdoutWriteAll(w.written()) catch {};
        }
        // The last frame, even in the middle of a synchronized update.
        d.main.dirty_at = d.main.dirty_at orelse io_mod.nowNanos();
        d.redraw(&d.main);
        // Each round writes at least one held line.
        const most = d.pending.len() + 2;
        var rounds: usize = 0;
        while (true) : (rounds += 1) {
            c.clear();
            c.blit(&d.main.layer, 0, 0, .same);
            c.cursor = .{ .shape = d.main.cursor.shape };
            const bytes = c.emit(&d.pending, std.math.maxInt(usize)) catch return;
            plat.stdoutWriteAll(bytes) catch {};
            if (d.pending.len() == 0 or rounds > most) break;
        }
        var last: usize = d.main.cursor_row;
        for (0..c.rows) |y| {
            for (c.shown[y * c.cols ..][0..c.cols]) |cell| if (cell != paint.Cell{}) {
                last = @max(last, y);
                break;
            };
        }
        var buf: [32]u8 = undefined;
        const tail = if (last + 1 < c.rows)
            std.fmt.bufPrint(&buf, "\x1b[0m\x1b[{d};1H", .{last + 2}) catch return
        else
            std.fmt.bufPrint(&buf, "\x1b[0m\x1b[{d};1H\r\n", .{c.rows}) catch return;
        plat.stdoutWriteAll(tail) catch {};
    }

    /// Whether the normal screen waits for the session's screen at the
    /// window's new size.
    fn holding(d: *Drawn, now: i64) bool {
        const until = d.hold_until orelse return false;
        const c = d.canvas orelse return false;
        const ready = if (d.main.view) |v| v.ready() and v.terminal.cols == c.cols and v.terminal.rows == c.rows else true;
        if (d.on_alt or ready or now >= until) {
            d.hold_until = null;
            return false;
        }
        return true;
    }

    /// A row for a notice: `want`, or else the first row that none of
    /// tuppet's boxes or lines cover and the program's cursor is not in;
    /// null when there is none.
    fn noticeRow(c: *const paint.Canvas, want: usize, avoid: ?usize) ?usize {
        const free = struct {
            fn free(canvas: *const paint.Canvas, y: usize, not: ?usize) bool {
                if (y >= canvas.rows or y == not) return false;
                for (canvas.cells[y * canvas.cols ..][0..canvas.cols]) |cell| if (cell.top) return false;
                return true;
            }
        }.free;
        if (free(c, want, avoid)) return want;
        for (0..c.rows) |y| if (free(c, y, avoid)) return y;
        return null;
    }

    /// The backdrop as the session was at the open box's opening frame,
    /// taken again once after the window was resized.
    fn freeze(d: *Drawn) ?*paint.Canvas {
        const o = d.m.open orelse return null;
        // After a resize, once the copy has the size asked for: before,
        // it still shows the session at its old size.
        const settled = if (d.main.view) |v| v.ready() and (if (d.sent_size) |want|
            !d.settings.resize or d.main_role != .write or (v.terminal.cols == want[0] and v.terminal.rows == want[1])
        else
            true) else false;
        const late = if (d.retake_until) |until| io_mod.nowNanos() >= until else false;
        if (d.frozen == null or d.frozen_serial != o.serial or (d.retake and (settled or late))) {
            if (d.frozen == null) d.frozen = paint.Canvas.init(d.gpa);
            const f = &d.frozen.?;
            f.dim = if (d.canvas) |c| c.dim else null;
            f.resize(d.main.layer.cols, d.main.layer.rows) catch return null;
            f.blit(&d.main.layer, 0, 0, .faded);
            d.frozen_serial = o.serial;
            d.frozen_ms = store.nowMillis();
            d.retake = false;
            d.retake_until = null;
        }
        return &d.frozen.?;
    }

    const heavy = struct {
        const top_left = "\u{250f}";
        const top_right = "\u{2513}";
        const bottom_left = "\u{2517}";
        const bottom_right = "\u{251b}";
        const across = "\u{2501}";
        const down = "\u{2503}";
    };

    /// A box that takes keys: its border and margin blanked, its border,
    /// and its session. Beside it, the rows it sits on keep no character
    /// that a terminal would reorder right to left, which could move the
    /// box's cells.
    fn drawOpen(d: *Drawn, c: *paint.Canvas, s: *Slot, p: boxes.Placed) void {
        const a = p.place;
        const top: usize = a.y - 1 - p.margin;
        const left: usize = a.x - 1 - p.margin;
        const right: usize = @as(usize, a.x) + a.cols + 1 + p.margin;
        for (top..@min(@as(usize, a.y) + a.rows + 1 + p.margin, c.rows)) |y| {
            c.leftToRight(y, 0, left);
            c.blank(y, left, right, .{});
            c.leftToRight(y, right, c.cols);
        }
        const o = d.m.open.?;
        var key_buf: [16]u8 = undefined;
        var short_buf: [8]u8 = undefined;
        var hint_buf: [32]u8 = undefined;
        var short_hint_buf: [32]u8 = undefined;
        var count_buf: [32]u8 = undefined;
        var behind_buf: [64]u8 = undefined;
        const pos = d.m.position();
        const count: ?[]const u8 = if (pos.of > 1) std.fmt.bufPrint(&count_buf, "{d} of {d}", .{ pos.at, pos.of }) catch null else null;
        const state = switch (o.phase) {
            .opening, .wait, .settle => "wait\u{2026}",
            .keys => "keys here",
            .asleep => "asleep: any key wakes",
        };
        const behind: ?[]const u8 = if (s.backdrop == .frozen) blk: {
            var clock: [8]u8 = undefined;
            break :blk std.fmt.bufPrint(&behind_buf, "behind: {s}, still runs", .{clockText(&clock, d.frozen_ms)}) catch null;
        } else null;
        const hint: ?[]const u8 = if (o.phase == .asleep) null else if (d.m.aside) (if (o.phase == .keys) "Esc later" else null) else if (d.settings.no_detach) null else std.fmt.bufPrint(&hint_buf, "{s} detach", .{keyName(&key_buf, d.settings.detach_key)}) catch null;
        const short_hint: ?[]const u8 = if (o.phase == .asleep) null else if (d.m.aside) (if (o.phase == .keys) "Esc later" else null) else if (d.settings.no_detach) null else std.fmt.bufPrint(&short_hint_buf, "{s} detach", .{keyShort(&short_buf, d.settings.detach_key)}) catch null;
        const style: paint.Style = if (!d.color) .{} else switch (o.phase) {
            .keys => .{ .fg = .palette(2) },
            .asleep => .{ .faint = true },
            else => .{ .fg = .palette(3) },
        };
        const w = @as(usize, a.cols) + 2;
        const title = s.title.text();
        // On a narrow border the frozen time goes first, then the key hint
        // shrinks, then the count; the title is cut last.
        var level: usize = 0;
        while (level < 3) : (level += 1) {
            const top_need = 4 + textWidth(title) + 2 + (if (level < 3 and count != null) textWidth(count.?) + 3 else 0);
            const k = if (level >= 2) short_hint else hint;
            const bottom_need = 4 + textWidth(state) + 2 + (if (level < 1 and behind != null) textWidth(behind.?) + 3 else 0) + (if (k) |x| textWidth(x) + 3 else 0);
            if (top_need <= w and bottom_need <= w) break;
        }
        const bold = blk: {
            var b = style;
            b.bold = true;
            break :blk b;
        };
        d.drawBorder(c, a.x - 1, a.y - 1, w, @as(usize, a.rows) + 2, style, &.{.{ .text = title, .style = .{ .bold = true } }}, if (level < 3) count else null);
        var parts: [2]Part = undefined;
        var np: usize = 0;
        parts[np] = .{ .text = state, .style = bold };
        np += 1;
        if (level < 1) if (behind) |b| {
            parts[np] = .{ .text = b, .style = style };
            np += 1;
        };
        d.borderRow(c, @as(usize, a.y) + a.rows, a.x - 1, w, heavy.bottom_left, heavy.bottom_right, style, parts[0..np], if (level >= 2) short_hint else hint);
        d.content(c, s, a);
        d.fillBox(c, a.x - 1, a.y - 1, w, @as(usize, a.rows) + 2);
        // The shadow falls into the margin, to the right and below.
        if (d.shadow) |shade| if (p.margin > 0) {
            const side = @as(usize, a.x) + a.cols + 1;
            const below = @as(usize, a.y) + a.rows + 1;
            for (a.y..below + 1) |y| c.blank(y, side, side + 1, .{ .bg = shade });
            c.blank(below, a.x, side + 1, .{ .bg = shade });
        };
    }

    /// Paint the box from column `x` and row `y`, `w` by `h` cells, on its
    /// background where the program left the terminal's own.
    fn fillBox(d: *Drawn, c: *paint.Canvas, x: usize, y: usize, w: usize, h: usize) void {
        const fill = d.fill orelse return;
        for (y..y + h) |row| c.fillBackground(row, x, x + w, fill);
    }

    /// A `--grab never` box: its border and its session, with a blank
    /// before it, and one code point per cell in the rows around it.
    fn drawNever(d: *Drawn, c: *paint.Canvas, s: *Slot, p: boxes.Placed) void {
        const a = p.place;
        const h = @as(usize, a.rows) + 2;
        const x = a.x - 1;
        const y = a.y - 1;
        if (x > 0) for (y..y + h) |row| c.blank(row, x - 1, x, .{});
        if (y > 0) c.plainRow(y - 1);
        c.plainRow(y + h);
        d.drawBorder(c, x, y, @as(usize, a.cols) + 2, h, .{}, &.{.{ .text = s.title.text(), .style = .{ .bold = true } }}, null);
        d.borderRow(c, y + h - 1, x, @as(usize, a.cols) + 2, heavy.bottom_left, heavy.bottom_right, .{}, &.{}, null);
        d.content(c, s, a);
        d.fillBox(c, x, y, @as(usize, a.cols) + 2, h);
    }

    /// A box's session in its program area.
    fn content(d: *Drawn, c: *paint.Canvas, s: *Slot, a: boxes.Place) void {
        _ = d;
        c.blit(&s.layer, a.x, a.y, .same);
        for (a.y..@as(usize, a.y) + a.rows) |y| c.setTop(y, a.x, @as(usize, a.x) + a.cols);
    }

    const Part = struct { text: []const u8, style: paint.Style };

    /// A box's border from column `x` and row `y`, `w` by `h` cells, with
    /// texts on its top row.
    fn drawBorder(d: *Drawn, c: *paint.Canvas, x: usize, y: usize, w: usize, h: usize, style: paint.Style, left: []const Part, right: ?[]const u8) void {
        d.borderRow(c, y, x, w, heavy.top_left, heavy.top_right, style, left, right);
        for (y + 1..y + h - 1) |row| {
            _ = c.text(row, x, 1, heavy.down, style);
            _ = c.text(row, x + w - 1, 1, heavy.down, style);
            c.setTop(row, x, x + 1);
            c.setTop(row, x + w - 1, x + w);
            if (d.ascii) {
                asciiCells(c, row, x, x + 1);
                asciiCells(c, row, x + w - 1, x + w);
            }
        }
    }

    /// One row of a border: its corners, a line across, texts from the
    /// left, and one at the right.
    fn borderRow(d: *Drawn, c: *paint.Canvas, y: usize, x: usize, w: usize, left_corner: []const u8, right_corner: []const u8, style: paint.Style, left: []const Part, right: ?[]const u8) void {
        if (w < 2 or y >= c.rows) return;
        _ = c.text(y, x, 1, left_corner, style);
        for (x + 1..x + w - 1) |col| _ = c.text(y, col, 1, heavy.across, style);
        _ = c.text(y, x + w - 1, 1, right_corner, style);
        // ━ text ━ text ━…━ right ━
        var limit = x + w - 2;
        if (right) |r| {
            const rw = textWidth(r);
            if (limit >= x + 2 + rw + 2) {
                const at = limit - rw - 1;
                _ = c.text(y, at - 1, 1, " ", style);
                _ = c.text(y, at, rw, r, style);
                _ = c.text(y, at + rw, 1, " ", style);
                limit = at - 2;
            }
        }
        var col = x + 2;
        for (left, 0..) |part, i| {
            if (col + 2 >= limit) break;
            if (i > 0) col += 1;
            _ = c.text(y, col, 1, " ", style);
            const end = c.text(y, col + 1, limit - col - 2, part.text, part.style);
            _ = c.text(y, end, 1, " ", style);
            col = end + 1;
        }
        c.setTop(y, x, x + w);
        if (d.ascii) asciiCells(c, y, x, x + w);
    }

    /// tuppet's line at the right of row `y`, with a blank first, so no
    /// character of the session joins it, and one code point per cell in
    /// the rows above and below.
    fn drawLine(d: *Drawn, c: *paint.Canvas, y: usize, text: []const u8) void {
        if (c.cols == 0 or y >= c.rows) return;
        const width = @min(textWidth(text) + 2, c.cols);
        const x = c.cols - width;
        const style: paint.Style = .{ .inverse = true };
        _ = c.text(y, x, 1, " ", style);
        const end = c.text(y, x + 1, width -| 1, text, style);
        c.blank(y, end, c.cols, style);
        c.setTop(y, x, c.cols);
        if (d.ascii) asciiCells(c, y, x, c.cols);
        if (y > 0) c.plainRow(y - 1);
        c.plainRow(y + 1);
    }

    /// The side session: in its pane below or beside the front in compact,
    /// over the front in half and full; nothing in the bar's strip.
    /// Returns its cursor where it has the keys.
    fn drawSide(d: *Drawn, c: *paint.Canvas, s: *Slot, sp: Split) ?paint.Cursor {
        if (!s.shown) return null;
        const rect = sp.over orelse sp.pane orelse return null;
        const bottom = @min(rect.y + rect.rows, c.rows);
        for (rect.y..bottom) |y| c.blank(y, rect.x, rect.x + rect.cols, .{});
        c.blit(&s.layer, rect.x, rect.y, .same);
        for (rect.y..bottom) |y| c.setTop(y, rect.x, rect.x + rect.cols);
        if (sp.beside and sp.over == null and rect.x > 0) for (rect.y..bottom) |y| {
            _ = c.text(y, rect.x - 1, 1, if (d.ascii) "|" else "\u{2502}", .{ .faint = true });
            c.setTop(y, rect.x - 1, rect.x);
        };
        if (sp.over == null) return null;
        var cur: paint.Cursor = .{ .shape = s.cursor.shape };
        if (s.cursor.at) |at| if (at.x < rect.cols and at.y < rect.rows) {
            cur.at = .{ .x = rect.x + at.x, .y = rect.y + at.y };
        };
        return cur;
    }

    /// What a member's state says on the bar and in the switcher.
    fn stateWord(buf: []u8, st: *const protocol.Status) []const u8 {
        if (st.state == .lost) return "lost";
        if (st.state != .running) {
            const e = st.exit orelse return "ended";
            if (e.code) |code| return std.fmt.bufPrint(buf, "ended {d}", .{code}) catch "ended";
            return std.fmt.bufPrint(buf, "ended {s}", .{e.signal orelse "?"}) catch "ended";
        }
        if (st.hidden_input == true) return "password?";
        return "";
    }

    /// The bar: where the keys go, then the members (or what tuppet has to
    /// say), and the switch key at the right end.
    fn drawBar(d: *Drawn, c: *paint.Canvas, y: usize, now: i64) void {
        const g = d.group orelse return;
        c.blank(y, 0, c.cols, .{});
        var key_buf: [16]u8 = undefined;
        const key = d.settings.switch_key.name(&key_buf);
        const right = c.cols -| (textWidth(key) + 2);
        // Where the keys go: the front, or its side session.
        var name_buf: [24]u8 = undefined;
        var head_buf: [160]u8 = undefined;
        const fm = d.front();
        const front_name = if (fm) |m| m.name(&name_buf) else d.id_text;
        var side_buf: [24]u8 = undefined;
        const side_name: ?[]const u8 = if (d.side) |s| (if (d.sideView() != .compact) blk: {
            const st = g.other(s.id) orelse break :blk null;
            break :blk st.name orelse (std.fmt.bufPrint(&side_buf, "#{d}", .{s.id}) catch null);
        } else null) else null;
        const open_mark = if (d.ascii) ">" else "\u{25b8}";
        const close_mark = if (d.ascii) "<" else "\u{25c2}";
        const label = if (fm) |m| m.st().label else null;
        const head = (if (side_name) |sn|
            std.fmt.bufPrint(&head_buf, " {s} {s} {s} {s} ", .{ open_mark, sn, if (d.ascii) "-" else "\u{00b7}", front_name })
        else if (label) |l|
            std.fmt.bufPrint(&head_buf, " {s} {s} {s} {s} ", .{ open_mark, front_name, l, close_mark })
        else
            std.fmt.bufPrint(&head_buf, " {s} {s} {s} ", .{ open_mark, front_name, close_mark })) catch " ";
        const accent = if (fm) |m| m.st().accent else false;
        var x = c.text(y, 0, right, head, if (accent) .{ .inverse = true, .bold = true } else .{ .bold = true });
        const sep = if (d.ascii) " | " else " \u{2502} ";
        // What tuppet has to say goes before the members.
        var msg_buf: [512]u8 = undefined;
        const msg = d.frontNote(&msg_buf, now) orelse d.lineText(&msg_buf, right -| x) orelse d.notice;
        if (msg) |text| {
            x = c.text(y, x, right -| x, sep, .{ .faint = true });
            _ = c.text(y, x, right -| x, text, .{ .bold = true });
        } else {
            if (d.split().strip) if (d.side) |s| if (s.view) |v| {
                var line_buf: [256]u8 = undefined;
                const line = lastLine(v, &line_buf);
                x = c.text(y, x, right -| x, sep, .{ .faint = true });
                x = c.text(y, x, @min(right -| x, 40), line, .{});
            };
            d.drawMembers(c, y, x, right, sep);
        }
        _ = c.text(y, right + 1, key.len + 1, key, .{ .faint = true });
        c.setTop(y, 0, c.cols);
        if (d.ascii) asciiCells(c, y, 0, c.cols);
    }

    /// What a group attach says of the member in front: that another
    /// window types in it, that it ended, or that keys were dropped.
    fn frontNote(d: *Drawn, buf: []u8, now: i64) ?[]const u8 {
        const dot = if (d.ascii) "-" else "\u{00b7}";
        if (d.front_elsewhere) return std.fmt.bufPrint(buf, "typing in another window {s} Enter takes over", .{dot}) catch null;
        if (d.frontEnded() and d.end_with != d.main.id) {
            var word: [32]u8 = undefined;
            const w = if (d.front()) |m| stateWord(&word, m.st()) else "ended";
            return std.fmt.bufPrint(buf, "{s} {s} Enter close {s} r", .{ if (w.len > 0) w else "ended", dot, dot }) catch null;
        }
        if (now < d.dropped_until) return std.fmt.bufPrint(buf, "{d} key{s} dropped", .{ d.dropped, if (d.dropped == 1) "" else "s" }) catch null;
        return null;
    }

    /// The members on the bar from column `x` up to `end`: those that fit,
    /// else the front, those needing attention, and a count of the rest.
    fn drawMembers(d: *Drawn, c: *paint.Canvas, y: usize, x0: usize, end: usize, sep: []const u8) void {
        const g = d.group orelse return;
        const n = @min(g.members.items.len, 64);
        var texts: [64][96]u8 = undefined;
        var lens: [64]usize = undefined;
        var widths: [64]usize = undefined;
        var wanted: [64]bool = undefined;
        var at_front: ?usize = null;
        for (g.members.items[0..n], 0..) |m, i| {
            var name_buf: [24]u8 = undefined;
            var word_buf: [32]u8 = undefined;
            const word = stateWord(&word_buf, m.st());
            const attention = if (m.id == d.main.id) null else g.attention(m);
            var w: std.Io.Writer = .fixed(&texts[i]);
            w.print("{d} {s}", .{ m.number(), m.name(&name_buf) }) catch {};
            if (word.len > 0) w.print(" {s}", .{word}) catch {};
            if (m.st().mark) |mark| w.print(" {s}", .{mark}) catch {};
            if (attention) |a| if (!std.mem.eql(u8, a, word)) w.print(" ! {s}", .{a}) catch {};
            lens[i] = w.end;
            widths[i] = textWidth(texts[i][0..w.end]);
            wanted[i] = attention != null;
            if (m.id == d.main.id) at_front = i;
        }
        var shown: [64]bool = undefined;
        const room = end -| x0;
        const sep_w = textWidth(sep);
        const left = group_mod.fitBar(widths[0..n], wanted[0..n], at_front, room, sep_w, 6, shown[0..n]);
        var x = x0;
        for (0..n) |i| if (shown[i]) {
            x = c.text(y, x, end -| x, sep, .{ .faint = true });
            const style: paint.Style = if (i == at_front) .{ .bold = true, .underline = .single } else if (wanted[i] and d.color) .{ .fg = .palette(3) } else .{};
            x = c.text(y, x, end -| x, texts[i][0..lens[i]], style);
        };
        if (left > 0) {
            var count_buf: [16]u8 = undefined;
            x = c.text(y, x, end -| x, sep, .{ .faint = true });
            _ = c.text(y, x, end -| x, std.fmt.bufPrint(&count_buf, "+{d}", .{left}) catch "+", .{});
        }
    }

    /// The switcher over the front: a row per member, with its number,
    /// name, label, state, and last line, and what its keys do.
    fn drawSwitcher(d: *Drawn, c: *paint.Canvas, sp: Split) void {
        const g = d.group orelse return;
        var list_buf: [256]*group_mod.Member = undefined;
        const list = d.switcher.shown(g, &list_buf);
        if (sp.area_rows < 3 or c.cols < 8) return;
        // The footer wraps onto rows above the bottom border, as many as
        // leave three members in view.
        var part_buf: [32][]const u8 = undefined;
        var foot_buf: [1024]u8 = undefined;
        const dot = if (d.ascii) " - " else " \u{00b7} ";
        const parts = d.switcherFooter(&foot_buf, &part_buf, dot);
        var widths: [32]usize = undefined;
        for (parts, 0..) |p, i| widths[i] = textWidth(p);
        var starts: [32]usize = undefined;
        const most = 1 + ((sp.area_rows - 2) -| @min(list.len, 3));
        const foot_rows = @max(group_mod.wrapFooter(widths[0..parts.len], c.cols -| 6, textWidth(dot), most, &starts), 1);
        const rows = @min(list.len, sp.area_rows - 1 - foot_rows);
        const h = rows + 1 + foot_rows;
        const top = sp.area_rows - h;
        const w = c.cols;
        for (top..top + h) |yy| c.blank(yy, 0, w, .{});
        var title_buf: [96]u8 = undefined;
        const name = d.settings.title orelse g.name;
        const title = if (d.switcher.filtering or d.switcher.filter.items.len > 0)
            std.fmt.bufPrint(&title_buf, "{s} /{s}", .{ name, d.switcher.filter.items }) catch name
        else
            name;
        d.drawBorder(c, 0, top, w, h, .{}, &.{.{ .text = title, .style = .{ .bold = true } }}, null);
        // The selected row is kept in view.
        var first: usize = 0;
        if (d.switcher.selected) |id| for (list, 0..) |m, i| if (m.id == id and i >= rows) {
            first = i + 1 - rows;
        };
        for (list[first..][0..rows], 0..) |m, r| {
            const yy = top + 1 + r;
            var name_buf: [24]u8 = undefined;
            var word_buf: [32]u8 = undefined;
            var line_buf: [256]u8 = undefined;
            const view: ?*View = if (m.id == d.main.id) d.main.view else d.previews.get(m.id);
            const line = if (view) |v| lastLine(v, &line_buf) else "";
            var row_buf: [512]u8 = undefined;
            const word = stateWord(&word_buf, m.st());
            const att = if (m.id == d.main.id) null else g.attention(m);
            const text = std.fmt.bufPrint(&row_buf, "{s}{d: >3}  {s: <14} {s: <14} {s: <12} {s}", .{
                if (m.id == d.main.id) "*" else " ",
                m.number(),
                m.name(&name_buf),
                m.st().label orelse "",
                if (att) |a| a else word,
                line,
            }) catch "";
            const selected = d.switcher.selected == m.id;
            _ = c.text(yy, 1, w -| 2, text, if (selected) .{ .inverse = true } else .{});
            if (selected) c.blank(yy, 1 + @min(textWidth(text), w -| 2), w -| 1, .{ .inverse = true });
        }
        for (0..foot_rows) |r| {
            var row_buf: [1024]u8 = undefined;
            var row: std.Io.Writer = .fixed(&row_buf);
            if (parts.len > 0) {
                const end = if (r + 1 < foot_rows) starts[r + 1] else parts.len;
                for (parts[starts[r]..end], 0..) |p, i| row.print("{s}{s}", .{ if (i > 0) dot else "", p }) catch {};
            }
            const yy = top + 1 + rows + r;
            if (r + 1 < foot_rows)
                _ = c.text(yy, 3, w -| 6, row.buffered(), .{})
            else
                d.borderRow(c, yy, 0, w, heavy.bottom_left, heavy.bottom_right, .{}, &.{.{ .text = row.buffered(), .style = .{} }}, null);
        }
        for (top..top + h) |yy| c.setTop(yy, 0, w);
        if (d.ascii) for (top..top + h) |yy| asciiCells(c, yy, 0, w);
    }

    /// What the switcher's keys do now, for its footer: one part per key,
    /// or one for a question.
    fn switcherFooter(d: *Drawn, buf: []u8, parts: *[32][]const u8, dot: []const u8) []const []const u8 {
        const g = d.group.?;
        var w: std.Io.Writer = .fixed(buf);
        if (d.switcher.pending) |p| {
            const a = d.switcher.pendingAction(g) orelse return parts[0..0];
            var name_buf: [24]u8 = undefined;
            const m = g.get(p.id);
            switch (p.kind) {
                .confirm => w.print("{c} again: {s} {s}", .{ p.key, a.name, if (m) |x| x.name(&name_buf) else "" }) catch {},
                .choice => {
                    w.print("{s}:", .{a.name}) catch {};
                    for (a.choices, 0..) |choice, i| (if (i == p.choice) w.print(" [{s}]", .{choice}) else w.print(" {s}", .{choice})) catch {};
                    w.print("{s}Enter{s}Esc", .{ dot, dot }) catch {};
                },
                .input => w.print("{s} {s}: {s}_{s}Enter{s}Esc", .{ a.name, a.input orelse "", d.switcher.text.items, dot, dot }) catch {},
            }
            parts[0] = w.buffered();
            return parts[0..1];
        }
        if (d.switcher.filtering) {
            w.print("filter: {s}_{s}Enter go{s}Esc", .{ d.switcher.filter.items, dot, dot }) catch {};
            parts[0] = w.buffered();
            return parts[0..1];
        }
        var n: usize = 0;
        for ([_][]const u8{ "digits", "/ filter", "Space next", "Enter go", "Esc stay" }) |p| {
            parts[n] = p;
            n += 1;
        }
        // The caller's actions before tuppet's own keys, which the bottom
        // border keeps.
        if (d.switcher.selected) |id| if (g.get(id)) |m| for (m.st().actions) |a| {
            if (n + 4 >= parts.len) break;
            const start = w.end;
            w.print("{s} {s}", .{ a.key, a.name }) catch break;
            parts[n] = buf[start..w.end];
            n += 1;
        };
        if (!d.settings.no_detach) {
            parts[n] = "d detach";
            n += 1;
        }
        parts[n] = "f side";
        parts[n + 1] = "h history";
        var key_buf: [16]u8 = undefined;
        const start = w.end;
        w.print("{s} back", .{d.settings.switch_key.name(&key_buf)}) catch {};
        parts[n + 2] = buf[start..w.end];
        return parts[0 .. n + 3];
    }

    /// What tuppet's line says: a box that waits, or how one ended, made
    /// to fit `cols` with its blanks: the title is cut first, then only
    /// a short form shows.
    fn lineText(d: *Drawn, buf: []u8, cols: usize) ?[]const u8 {
        var key_buf: [16]u8 = undefined;
        const key = keyName(&key_buf, d.settings.detach_key);
        var rest_buf: [256]u8 = undefined;
        var title: []const u8 = undefined;
        var short: []const u8 = "box waits";
        const rest = if (d.m.receipt) |*r| rest: {
            title = r.title.text();
            short = "box closed";
            const more = d.m.waiting();
            var id_buf: [24]u8 = undefined;
            const under = d.under_name orelse (std.fmt.bufPrint(&id_buf, "#{d}", .{d.main.id}) catch "");
            break :rest (if (more == 0)
                std.fmt.bufPrint(&rest_buf, " closed \u{00b7} keys go to {s}", .{under})
            else
                std.fmt.bufPrint(&rest_buf, " closed \u{00b7} {d} more wait", .{more})) catch return null;
        } else rest: {
            const l = d.m.line() orelse return null;
            const s = d.slotOf(l.id) orelse return null;
            title = s.title.text();
            var more_buf: [32]u8 = undefined;
            const more = if (l.more > 0) std.fmt.bufPrint(&more_buf, " \u{00b7} {d} more", .{l.more}) catch "" else "";
            if (l.kind == .too_small) short = "window too small";
            break :rest (switch (l.kind) {
                .arrived => std.fmt.bufPrint(&rest_buf, " waits \u{00b7} opens when you pause \u{00b7} {s} now", .{key}),
                .aside => std.fmt.bufPrint(&rest_buf, " waits{s} \u{00b7} {s} opens it", .{ more, key }),
                .no_answer => std.fmt.bufPrint(&rest_buf, " waits \u{00b7} terminal did not answer \u{00b7} {s} opens it", .{key}),
                .elsewhere => std.fmt.bufPrint(&rest_buf, " waits \u{00b7} controlled elsewhere", .{}),
                .too_small => std.fmt.bufPrint(&rest_buf, " waits \u{00b7} window too small", .{}),
                .other_terminal => std.fmt.bufPrint(&rest_buf, " waits \u{00b7} another terminal has the keyboard", .{}),
            }) catch return null;
        };
        return fitLine(buf, title, rest, short, cols -| 2);
    }
};

/// The columns of a side pane beside the front, in a window of `cols` that
/// is wider than `front_min + pane_min`: a third of the window, at least
/// `pane_min`, and never so much that the front keeps less than
/// `front_min` beside the pane and its separator.
fn paneCols(cols: usize, front_min: usize, pane_min: usize) usize {
    return @max(pane_min, @min((cols - 1) / 3, cols - 1 - front_min));
}

/// `title` and `rest` in `room` cells: the title cut, with an ellipsis,
/// when both do not fit, and `short` when not even one cell of it would.
fn fitLine(buf: []u8, title: []const u8, rest: []const u8, short: []const u8, room: usize) ?[]const u8 {
    const need = textWidth(rest);
    if (textWidth(title) + need <= room) return std.fmt.bufPrint(buf, "{s}{s}", .{ title, rest }) catch null;
    if (need + 2 > room) return short;
    return std.fmt.bufPrint(buf, "{s}\u{2026}{s}", .{ cutCells(title, room - need - 1), rest }) catch null;
}

/// The longest start of `s` that takes at most `cells` cells.
fn cutCells(s: []const u8, cells: usize) []const u8 {
    const view = std.unicode.Utf8View.init(s) catch return s[0..@min(s.len, cells)];
    var it = view.iterator();
    var n: usize = 0;
    var end: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        n += @min(vt.unicode.codepointWidth(std.unicode.utf8Decode(cp) catch 0xfffd), 2);
        if (n > cells) break;
        end = it.i;
    }
    return s[0..end];
}

/// The detach key as people write it: "Ctrl-]" for 0x1d.
fn keyName(buf: []u8, key: u8) []const u8 {
    return (if (key == 0x7f)
        std.fmt.bufPrint(buf, "Ctrl-?", .{})
    else if (key < 0x20)
        std.fmt.bufPrint(buf, "Ctrl-{c}", .{key + '@'})
    else
        std.fmt.bufPrint(buf, "{c}", .{key})) catch "";
}

/// The detach key in short: "^]" for 0x1d.
fn keyShort(buf: []u8, key: u8) []const u8 {
    return (if (key == 0x7f)
        std.fmt.bufPrint(buf, "^?", .{})
    else if (key < 0x20)
        std.fmt.bufPrint(buf, "^{c}", .{key + '@'})
    else
        std.fmt.bufPrint(buf, "{c}", .{key})) catch "";
}

/// tuppet's own cells from `x` up to `end` in ASCII, for a terminal
/// without UTF-8.
fn asciiCells(c: *paint.Canvas, y: usize, x: usize, end: usize) void {
    if (y >= c.rows) return;
    for (c.row(y)[@min(x, c.cols)..@min(end, c.cols)]) |*cell| {
        if (!cell.grapheme and cell.cp < 0x80 and cell.width == .narrow) continue;
        const cp: u21 = if (cell.grapheme) '?' else switch (cell.cp) {
            0x250f, 0x2513, 0x2517, 0x251b => '+',
            0x2501 => '-',
            0x2503 => '|',
            0x00b7 => '-',
            0x2026 => '~',
            else => '?',
        };
        cell.* = .{ .cp = cp, .style = cell.style, .top = cell.top };
    }
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    /// tm_gmtoff and tm_zone where the C library has them.
    rest: [4]usize,
};
extern "c" fn localtime_r(t: *const std.c.time_t, tm: *Tm) ?*Tm;

/// The local time of a Unix time in milliseconds, as HH:MM:SS.
fn clockText(buf: *[8]u8, ms: i64) []const u8 {
    const t: std.c.time_t = @intCast(@divFloor(ms, std.time.ms_per_s));
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return "";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.hour)), @as(u32, @intCast(tm.min)), @as(u32, @intCast(tm.sec)) }) catch "";
}

/// Drop what `in` holds, passing the cursor reports in it to `m`.
fn discard(in: *Input, m: *boxes.Boxes, now: i64) void {
    while (in.next(now)) |unit| switch (unit) {
        .report => |r| _ = m.report(.{ .row = r.row, .col = r.col }, in.unit_at),
        else => {},
    };
    in.clear();
}

/// The end of a stream's turn in a pass that ends at `pass_until`.
fn untilFor(pass_until: i64) i64 {
    return @min(pass_until, io_mod.nowNanos() + stream_ns);
}

/// Feed output into a copy a slice at a time, until `until` and at least
/// one slice: how much went.
fn feedUntil(stream: anytype, bytes: []const u8, until: i64) usize {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = @min(feed_slice, bytes.len - at);
        stream.nextSlice(bytes[at..][0..n]);
        at += n;
        if (io_mod.nowNanos() >= until) break;
    }
    return at;
}

/// Whether a key is Esc without modifiers: the byte, or as the kitty
/// keyboard protocol reports it, Caps Lock and Num Lock aside.
fn escapeKey(bytes: []const u8) enum { no, press, release } {
    if (std.mem.eql(u8, bytes, "\x1b")) return .press;
    if (!std.mem.startsWith(u8, bytes, "\x1b[27") or bytes[bytes.len - 1] != 'u') return .no;
    const rest = bytes[4 .. bytes.len - 1];
    if (rest.len == 0) return .press;
    if (rest[0] != ';') return .no;
    var parts = std.mem.splitScalar(u8, rest[1..], ':');
    const mods = std.fmt.parseInt(u32, parts.next().?, 10) catch return .no;
    const event = if (parts.next()) |e| std.fmt.parseInt(u32, e, 10) catch return .no else 1;
    if (parts.next() != null or mods == 0 or (mods - 1) & ~@as(u32, 64 | 128) != 0) return .no;
    return switch (event) {
        1, 2 => .press,
        3 => .release,
        else => .no,
    };
}

test "Esc is the byte, or kitty's report of it with locks but no other modifier" {
    try testing.expectEqual(.press, escapeKey("\x1b"));
    try testing.expectEqual(.press, escapeKey("\x1b[27u"));
    try testing.expectEqual(.press, escapeKey("\x1b[27;129u"));
    try testing.expectEqual(.press, escapeKey("\x1b[27;65:2u"));
    try testing.expectEqual(.release, escapeKey("\x1b[27;1:3u"));
    for ([_][]const u8{ "\x1bx", "\x1b[27;3u", "\x1b[27;5u", "\x1b[270u", "\x1b[27;1;27u", "\x1b[27~", "\x1b[A" }) |other| {
        try testing.expectEqual(.no, escapeKey(other));
    }
}

/// Whether `bytes` is `key` without modifiers, Caps Lock and Num Lock
/// aside: its byte, its kitty or modifyOtherKeys form, or for a function
/// key its legacy, xterm, or kitty sequence; and whether pressed or
/// released.
fn keyEvent(key: config_mod.Key, bytes: []const u8) enum { no, press, release } {
    switch (key) {
        .byte => |b| {
            if (bytes.len == 1) return if (bytes[0] == b) .press else .no;
            if (b < 0x20 and bytes.len > 2 and bytes[0] == 0x1b and attach_client.isCtrlSequence(bytes[1..], b)) return .press;
            return .no;
        },
        .function => |n| {
            if (bytes.len == 3 and std.mem.startsWith(u8, bytes, "\x1bO") and n <= 4) return if (bytes[2] == @as(u8, 'O') + n) .press else .no;
            if (bytes.len < 3 or !std.mem.startsWith(u8, bytes, "\x1b[")) return .no;
            const final = bytes[bytes.len - 1];
            var params = std.mem.splitScalar(u8, bytes[2 .. bytes.len - 1], ';');
            const code = params.next().?;
            const which: ?u4 = if (final >= 'P' and final <= 'S' and (code.len == 0 or std.mem.eql(u8, code, "1")))
                @intCast(final - 'P' + 1)
            else if (final == '~') switch (std.fmt.parseInt(u8, code, 10) catch return .no) {
                11...15 => |c| @intCast(c - 10),
                17...21 => |c| @intCast(c - 11),
                23, 24 => |c| @intCast(c - 12),
                else => null,
            } else null;
            if (which != n) return .no;
            const mods_text = params.next() orelse return .press;
            if (params.next() != null) return .no;
            var parts = std.mem.splitScalar(u8, mods_text, ':');
            const mods = std.fmt.parseInt(u32, parts.next().?, 10) catch return .no;
            if (mods == 0 or (mods - 1) & ~@as(u32, 64 | 128) != 0) return .no;
            const event = if (parts.next()) |e| std.fmt.parseInt(u32, e, 10) catch return .no else 1;
            return switch (event) {
                1, 2 => .press,
                3 => .release,
                else => .no,
            };
        },
    }
}

test "a named key in every encoding, and not with a modifier" {
    const f12: config_mod.Key = .{ .function = 12 };
    const f1: config_mod.Key = .{ .function = 1 };
    const ctrl: config_mod.Key = .{ .byte = 0x1d };
    try testing.expectEqual(.press, keyEvent(f12, "\x1b[24~"));
    try testing.expectEqual(.press, keyEvent(f12, "\x1b[24;1:2~"));
    try testing.expectEqual(.release, keyEvent(f12, "\x1b[24;1:3~"));
    try testing.expectEqual(.no, keyEvent(f12, "\x1b[24;5~"));
    try testing.expectEqual(.no, keyEvent(f12, "\x1b[23~"));
    try testing.expectEqual(.press, keyEvent(f1, "\x1bOP"));
    try testing.expectEqual(.press, keyEvent(f1, "\x1b[P"));
    try testing.expectEqual(.press, keyEvent(f1, "\x1b[1;1P"));
    try testing.expectEqual(.press, keyEvent(f1, "\x1b[11~"));
    try testing.expectEqual(.no, keyEvent(f1, "\x1b[1;2P"));
    try testing.expectEqual(.press, keyEvent(ctrl, "\x1d"));
    try testing.expectEqual(.press, keyEvent(ctrl, "\x1b[93;5u"));
    var in: Input = .{ .detach_key = 0x1d, .switch_key = f12, .side_key = .{ .function = 11 } };
    defer in.deinit(testing.allocator);
    try in.feed(testing.allocator, "a\x1b[24~\x1b[23;1:3~\x1bOP", 0);
    try testing.expectEqualStrings("a", in.next(0).?.key);
    try testing.expectEqual(Named.switch_key, in.next(0).?.named.which);
    try testing.expectEqual(Unit.dropped, in.next(0).?);
    try testing.expectEqualStrings("\x1bOP", in.next(0).?.key);
}

/// Whether a mouse report is a button or the wheel, which count as keys,
/// rather than motion.
fn mouseIsKey(bytes: []const u8) bool {
    const r = MouseReport.parse(bytes) orelse return true;
    return r.button & 32 == 0;
}

/// A mouse report moved into a box's program area, in the encoding it
/// came in; null when it lies outside the area. `pixels`: the box's
/// program asked for SGR pixel reports, which the person's terminal sends
/// in cells while a box has the keyboard; a session's cell is one pixel,
/// counted from 0, as its size reports and `tuppet mouse` have it.
fn moveMouse(buf: *[64]u8, bytes: []const u8, place: boxes.Place, pixels: bool) ?[]const u8 {
    var r = MouseReport.parse(bytes) orelse return null;
    if (r.x <= place.x or r.y <= place.y) return null;
    r.x -= place.x;
    r.y -= place.y;
    if (r.x > place.cols or r.y > place.rows) return null;
    if (pixels and r.format == .sgr) {
        r.x -= 1;
        r.y -= 1;
    }
    return r.write(buf);
}

/// A mouse report: its button byte and its cell, counted from 1.
const MouseReport = struct {
    format: enum { x10, utf8, sgr, urxvt },
    button: u32,
    x: u32,
    y: u32,
    /// SGR's final byte: M on press, m on release.
    final: u8 = 'M',

    fn parse(bytes: []const u8) ?MouseReport {
        if (std.mem.startsWith(u8, bytes, "\x1b[M")) {
            const rest = bytes[3..];
            if (rest.len == 3) return if (rest[0] < 32) null else .{ .format = .x10, .button = rest[0] - 32, .x = rest[1] -| 32, .y = rest[2] -| 32 };
            const view = std.unicode.Utf8View.init(rest) catch return null;
            var it = view.iterator();
            var v: [3]u32 = undefined;
            for (&v) |*x| x.* = it.nextCodepoint() orelse return null;
            return .{ .format = .utf8, .button = v[0] -| 32, .x = v[1] -| 32, .y = v[2] -| 32 };
        }
        if (bytes.len < 4) return null;
        const sgr = bytes[2] == '<';
        var it = std.mem.splitScalar(u8, bytes[if (sgr) 3 else 2 .. bytes.len - 1], ';');
        var v: [3]u32 = undefined;
        for (&v) |*x| x.* = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        if (sgr) return .{ .format = .sgr, .button = v[0], .x = v[1], .y = v[2], .final = bytes[bytes.len - 1] };
        return .{ .format = .urxvt, .button = v[0] -| 32, .x = v[1], .y = v[2] };
    }

    fn write(r: MouseReport, buf: *[64]u8) ?[]const u8 {
        return switch (r.format) {
            .x10 => if (r.x + 32 > 255 or r.y + 32 > 255) null else std.fmt.bufPrint(buf, "\x1b[M{c}{c}{c}", .{ @as(u8, @intCast(r.button + 32)), @as(u8, @intCast(r.x + 32)), @as(u8, @intCast(r.y + 32)) }) catch null,
            .utf8 => std.fmt.bufPrint(buf, "\x1b[M{u}{u}{u}", .{ @as(u21, @intCast(r.button + 32)), @as(u21, @intCast(r.x + 32)), @as(u21, @intCast(r.y + 32)) }) catch null,
            .sgr => std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{ r.button, r.x, r.y, r.final }) catch null,
            .urxvt => std.fmt.bufPrint(buf, "\x1b[{d};{d};{d}M", .{ r.button + 32, r.x, r.y }) catch null,
        };
    }
};

test "a mouse report moved into a box keeps its encoding, SGR pixels are the box's cells from 0, and an X10 report no terminal sends goes nowhere" {
    var buf: [64]u8 = undefined;
    const place: boxes.Place = .{ .x = 10, .y = 3, .cols = 30, .rows = 6 };
    try testing.expectEqualStrings("\x1b[<0;2;1M", moveMouse(&buf, "\x1b[<0;12;4M", place, false).?);
    try testing.expectEqualStrings("\x1b[<0;1;0M", moveMouse(&buf, "\x1b[<0;12;4M", place, true).?);
    try testing.expectEqualStrings("\x1b[M +!", moveMouse(&buf, "\x1b[M 5$", place, false).?);
    try testing.expect(moveMouse(&buf, "\x1b[M\x1f5$", place, false) == null);
}

/// When to paint. Output is painted once the last paint is a frame old;
/// the first output within a frame after a key at once. A program's
/// synchronized update holds a paint at most one frame beyond that, never
/// the echo of a key. A paint is due at a fixed time, so a loop that
/// sleeps until then never spins.
pub const Pacer = struct {
    last_paint: i64 = 0,
    /// When what waits for a paint first changed; null when nothing does.
    dirty_at: ?i64 = null,
    /// When a key last went to a session, until the next paint.
    key_at: ?i64 = null,
    /// A change came within a frame after that key.
    echo: bool = false,

    pub fn changed(p: *Pacer, now: i64) void {
        if (p.key_at) |k| if (now - k < frame_ns) {
            p.echo = true;
        };
        if (p.dirty_at == null) p.dirty_at = now;
    }

    pub fn key(p: *Pacer, now: i64) void {
        p.key_at = now;
    }

    pub fn painted(p: *Pacer, now: i64) void {
        p.* = .{ .last_paint = now };
    }

    /// `sync`: the program is inside a synchronized update.
    pub fn due(p: Pacer, sync: bool) ?i64 {
        const since = p.dirty_at orelse return null;
        if (p.echo) return since;
        const at = @max(p.last_paint + frame_ns, since);
        return if (sync) at + frame_ns else at;
    }
};

fn textWidth(s: []const u8) usize {
    const view = std.unicode.Utf8View.init(s) catch return s.len;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| n += @min(vt.unicode.codepointWidth(cp), 2);
    return n;
}

// ---- input modes ------------------------------------------------------

/// Every input mode tuppet may set on the person's terminal, off: cursor
/// keys and keypad normal, no mouse reports in any encoding, no focus
/// reports, no kitty keyboard flags, no modifyOtherKeys.
pub const modes_off = "\x1b[?1l\x1b>\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l" ++
    "\x1b[?1004l\x1b[=0;1u\x1b[>4m";

/// The input modes a session asked its terminal for, from a fixed list,
/// which the person's terminal is given while that session has the
/// keyboard.
pub const InputModes = struct {
    cursor_keys: bool = false,
    keypad: bool = false,
    mouse: Mouse = .none,
    mouse_format: MouseFormat = .x10,
    focus: bool = false,
    kitty_flags: u5 = 0,
    modify_other_keys: bool = false,
    /// The terminal sends the wheel as arrow keys on its alternate
    /// screen (1007). Not the session's mode: tuppet's own choice.
    alt_scroll: bool = false,
    /// The terminal scrolls to the bottom when output comes (1010), set
    /// while a box is open; tuppet's own choice too.
    scroll_output: bool = false,

    pub const Mouse = enum(u16) { none = 0, x10 = 9, normal = 1000, button = 1002, any = 1003 };
    pub const MouseFormat = enum(u16) { x10 = 0, utf8 = 1005, sgr = 1006, urxvt = 1015, sgr_pixels = 1016 };

    pub fn of(t: *const vt.Terminal) InputModes {
        return .{
            .cursor_keys = t.modes.get(.cursor_keys),
            .keypad = t.modes.get(.keypad_keys),
            .mouse = switch (t.flags.mouse_event) {
                .none => .none,
                .x10 => .x10,
                .normal => .normal,
                .button => .button,
                .any => .any,
            },
            .mouse_format = switch (t.flags.mouse_format) {
                .utf8 => .utf8,
                .sgr => .sgr,
                .urxvt => .urxvt,
                .sgr_pixels => .sgr_pixels,
                .x10 => .x10,
            },
            .focus = t.modes.get(.focus_event),
            .kitty_flags = t.screens.active.kitty_keyboard.current().int(),
            .modify_other_keys = t.flags.modify_other_keys_2,
        };
    }

    /// Write what brings the person's terminal from `old` to `new`.
    pub fn change(w: *std.Io.Writer, old: InputModes, new: InputModes) !void {
        if (old.cursor_keys != new.cursor_keys) try w.writeAll(if (new.cursor_keys) "\x1b[?1h" else "\x1b[?1l");
        if (old.keypad != new.keypad) try w.writeAll(if (new.keypad) "\x1b=" else "\x1b>");
        if (old.mouse_format != new.mouse_format) {
            if (old.mouse_format != .x10) try w.print("\x1b[?{d}l", .{@backingInt(old.mouse_format)});
            if (new.mouse_format != .x10) try w.print("\x1b[?{d}h", .{@backingInt(new.mouse_format)});
        }
        if (old.mouse != new.mouse) {
            if (old.mouse != .none) try w.print("\x1b[?{d}l", .{@backingInt(old.mouse)});
            if (new.mouse != .none) try w.print("\x1b[?{d}h", .{@backingInt(new.mouse)});
        }
        if (old.focus != new.focus) try w.writeAll(if (new.focus) "\x1b[?1004h" else "\x1b[?1004l");
        if (old.kitty_flags != new.kitty_flags) try w.print("\x1b[={d};1u", .{new.kitty_flags});
        if (old.modify_other_keys != new.modify_other_keys) try w.writeAll(if (new.modify_other_keys) "\x1b[>4;2m" else "\x1b[>4m");
        if (old.alt_scroll != new.alt_scroll) try w.writeAll(if (new.alt_scroll) "\x1b[?1007h" else "\x1b[?1007l");
        if (old.scroll_output != new.scroll_output) try w.writeAll(if (new.scroll_output) "\x1b[?1010h" else "\x1b[?1010l");
    }
};

// ---- input ------------------------------------------------------------

/// One whole unit of the person's input.
pub const Unit = union(enum) {
    /// A character, a control, or an escape sequence, as it came.
    key: []const u8,
    /// A paste's text, without its brackets. A paste longer than
    /// `max_paste` comes in pieces; `first` and `last` mark its ends.
    paste: struct { text: []const u8, first: bool, last: bool },
    /// A mouse report, in whichever encoding.
    mouse: []const u8,
    /// A focus report (CSI I, CSI O).
    focus: []const u8,
    /// The terminal's answer to a DECRQM query of tuppet's.
    mode_report: struct { mode: u32, value: u32 },
    /// The terminal's answer to tuppet's DECRQSS query of the cursor
    /// style (DECSCUSR); null when it has none.
    cursor_style: ?u8,
    /// The terminal's answer to a DA1 query of tuppet's.
    attributes,
    /// A cursor report (CSI row;col R). It is tuppet's only while one is
    /// expected and it names the expected cell; otherwise it is the key
    /// in `bytes`, as F3 with a modifier sends the same.
    report: struct { row: u32, col: u32, bytes: []const u8 },
    /// tuppet's key.
    detach,
    /// A key that a group attach takes: the switch key or the side key,
    /// and how it came.
    named: struct { which: Named, bytes: []const u8 },
    /// Bytes no session gets, such as the end of a paste that never began.
    dropped,
};

pub const Named = enum { switch_key, side_key };

/// Splits the person's input into whole units. What it returns depends
/// only on the bytes, never on how they were split into reads, apart
/// from the waits: a lone ESC becomes the Escape key after `esc_wait_ns`,
/// a sequence that has begun is passed on as it is after `seq_wait_ns`,
/// and what came of a paste goes on after `paste_wait_ns` without input.
/// Each unit comes with the time its last byte was read.
pub const Input = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Where the next unit starts in `buf`.
    at: usize = 0,
    /// When the bytes of `buf` were read: each up to its `end`.
    marks: std.ArrayList(Mark) = .empty,
    /// When the unit `next` returned last was read.
    unit_at: i64 = 0,
    detach_key: u8,
    /// The keys a group attach takes; null outside one.
    switch_key: ?config_mod.Key = null,
    side_key: ?config_mod.Key = null,
    /// X10 mouse reports carry their cells as UTF-8 (mode 1005).
    utf8_mouse: bool = false,
    /// tuppet asked for the cursor style and has no answer yet: until
    /// then ESC P starts that answer, not Alt-P.
    style_due: bool = false,
    /// The terminal's color answers may still come: until then ESC ]
    /// starts one, dropped, not Alt-].
    osc_due: bool = false,
    in_paste: bool = false,
    paste_first: bool = false,
    /// The rest of the paste is dropped up to its end.
    paste_dropped: bool = false,
    /// A paste was cut after a piece of it was taken; the next unit is
    /// its empty last piece, so it can be closed.
    close_due: bool = false,
    /// The paste waited `paste_wait_ns` without input.
    stalled: bool = false,
    /// Where tuppet's key, read on its own while the paste stalled, ends
    /// the paste.
    hatch_at: ?usize = null,
    /// Since when the unit at `at` has waited for its end, and how long
    /// it may.
    since: ?i64 = null,
    wait: i64 = 0,

    const Mark = struct { end: usize, at: i64 };

    pub fn deinit(in: *Input, gpa: std.mem.Allocator) void {
        in.buf.deinit(gpa);
        in.marks.deinit(gpa);
    }

    /// Bytes read at `at`.
    pub fn feed(in: *Input, gpa: std.mem.Allocator, bytes: []const u8, at: i64) !void {
        if (bytes.len == 0) return;
        if (in.at > 0) {
            in.buf.replaceRange(gpa, 0, in.at, &.{}) catch unreachable;
            if (in.hatch_at) |*h| h.* -= in.at;
            in.dropMarks(in.at);
            in.at = 0;
        }
        try in.marks.ensureUnusedCapacity(gpa, 1);
        if (in.in_paste) {
            if (in.stalled and in.isDetachKey(bytes)) in.hatch_at = in.buf.items.len;
            in.stalled = false;
            // A paste waits for its end only while nothing comes.
            in.since = null;
        }
        try in.buf.appendSlice(gpa, bytes);
        in.marks.appendAssumeCapacity(.{ .end = in.buf.items.len, .at = at });
    }

    /// Whether a read is tuppet's key alone: its byte, or its kitty
    /// keyboard protocol or modifyOtherKeys form.
    fn isDetachKey(in: *const Input, bytes: []const u8) bool {
        if (bytes.len == 1) return bytes[0] == in.detach_key;
        return in.detach_key < 0x20 and bytes[0] == 0x1b and std.mem.indexOfAny(u8, bytes, "u~") == bytes.len - 1 and
            attach_client.isCtrlSequence(bytes[1..], in.detach_key);
    }

    /// The first `n` bytes of `buf` went.
    fn dropMarks(in: *Input, n: usize) void {
        var keep: usize = 0;
        for (in.marks.items) |mark| if (mark.end > n) {
            in.marks.items[keep] = .{ .end = mark.end - n, .at = mark.at };
            keep += 1;
        };
        in.marks.items.len = keep;
    }

    /// When the byte at `offset` of `buf` was read.
    fn readAt(in: *const Input, offset: usize) i64 {
        const marks = in.marks.items;
        if (marks.len == 0) return 0;
        const Order = struct {
            fn order(o: usize, mark: Mark) std.math.Order {
                return if (o < mark.end) .lt else .gt;
            }
        };
        const i = std.sort.lowerBound(Mark, marks, offset, Order.order);
        return marks[@min(i, marks.len - 1)].at;
    }

    /// When input that is no whole unit yet was read; null without any.
    pub fn pending(in: *const Input) ?i64 {
        return if (in.at < in.buf.items.len) in.readAt(in.at) else null;
    }

    /// Forget everything read and not yet taken: its units are parsed and
    /// dropped, the rest of a paste that has begun is dropped up to its
    /// end, so it never arrives as keys, and a sequence that has begun is
    /// kept. A paste cut after a piece of it was taken gets its last
    /// piece next.
    pub fn clear(in: *Input) void {
        const close = in.close_due or (in.in_paste and !in.paste_first and !in.paste_dropped);
        in.close_due = false;
        // Waits never end here.
        const now = in.since orelse 0;
        while (in.next(now)) |_| {}
        in.close_due = close;
        in.since = null;
        in.stalled = false;
        const rest = in.buf.items[in.at..];
        // A paste keeps only what may begin its end mark.
        const keep = if (in.in_paste) @min(rest.len, end_mark.len - 1) else rest.len;
        std.mem.copyForwards(u8, in.buf.items[0..keep], rest[rest.len - keep ..]);
        in.dropMarks(in.buf.items.len - keep);
        in.buf.items.len = keep;
        in.at = 0;
        if (in.in_paste) in.paste_dropped = true;
    }

    /// When the waiting unit is taken as it is, unless more comes first.
    pub fn deadline(in: *const Input) ?i64 {
        const since = in.since orelse return null;
        return since + in.wait;
    }

    /// The next whole unit, or null while what is left waits for more.
    /// A unit's bytes stay valid until the next `feed`.
    pub fn next(in: *Input, now: i64) ?Unit {
        if (in.close_due) {
            in.close_due = false;
            in.unit_at = in.readAt(in.at);
            return .{ .paste = .{ .text = "", .first = false, .last = true } };
        }
        while (true) {
            const rest = in.buf.items[in.at..];
            if (in.in_paste) return in.pasted(rest, now);
            if (rest.len == 0) {
                in.since = null;
                return null;
            }
            const found = in.scan(rest);
            switch (found) {
                .unit => |u| {
                    in.at += u.len;
                    in.since = null;
                    in.unit_at = in.readAt(in.at - 1);
                    return u.unit;
                },
                .paste_start => |len| {
                    in.at += len;
                    in.in_paste = true;
                    in.paste_first = true;
                    in.paste_dropped = false;
                    in.stalled = false;
                    in.hatch_at = null;
                    in.since = null;
                },
                .wait => |wait| {
                    // The wait counts from the unit's first byte.
                    if (in.since == null) in.since = now;
                    in.wait = wait;
                    if (now - in.since.? < wait) return null;
                    // Nothing completed it: a lone ESC is the Escape key,
                    // and anything else goes as it came.
                    in.at = in.buf.items.len;
                    in.since = null;
                    in.unit_at = in.readAt(in.at - 1);
                    return if (rest.len >= 3 and std.mem.startsWith(u8, rest, "\x1b[M")) .dropped else .{ .key = rest };
                },
            }
        }
    }

    /// The paste's next text: up to its end, in pieces of at most
    /// max_paste so where reads end does not matter. Only its end mark
    /// ends it, or tuppet's key read on its own once it stalled; what came
    /// before a stall goes on as a piece, and the rest of a paste never
    /// becomes keys.
    fn pasted(in: *Input, rest: []const u8, now: i64) ?Unit {
        if (std.mem.indexOf(u8, rest, end_mark)) |end| if (end <= max_paste) {
            in.at += end + end_mark.len;
            return in.piece(rest[0..end], true);
        };
        if (in.hatch_at) |h| {
            const text = in.buf.items[in.at..h];
            in.at = h;
            return in.piece(text, true);
        }
        // Without its end among the first bytes, a full piece goes.
        if (rest.len >= max_paste + end_mark.len) {
            in.at += max_paste;
            return in.piece(rest[0..max_paste], false);
        }
        if (in.since == null) in.since = now;
        in.wait = paste_wait_ns;
        if (now - in.since.? < paste_wait_ns) return null;
        in.since = null;
        in.stalled = true;
        // What came goes on, but what may begin the end mark.
        var keep = @min(rest.len, end_mark.len - 1);
        while (keep > 0 and !std.mem.endsWith(u8, rest, end_mark[0..keep])) keep -= 1;
        if (keep == rest.len) return null;
        in.at += rest.len - keep;
        return in.piece(rest[0 .. rest.len - keep], false);
    }

    fn piece(in: *Input, text: []const u8, last: bool) Unit {
        in.unit_at = in.readAt(in.at -| 1);
        const first = in.paste_first;
        in.paste_first = false;
        in.since = null;
        if (last) {
            in.in_paste = false;
            in.stalled = false;
            in.hatch_at = null;
        }
        if (in.paste_dropped) {
            if (last) in.paste_dropped = false;
            return .dropped;
        }
        return .{ .paste = .{ .text = text, .first = first, .last = last } };
    }

    const Scan = union(enum) {
        unit: struct { unit: Unit, len: usize },
        paste_start: usize,
        /// More bytes are needed; take what came after this long.
        wait: i64,
    };

    fn one(unit: Unit, len: usize) Scan {
        return .{ .unit = .{ .unit = unit, .len = len } };
    }

    fn scan(in: *const Input, s: []const u8) Scan {
        const b = s[0];
        if (b == 0x1b) {
            if (s.len == 1) return .{ .wait = esc_wait_ns };
            const c = s[1];
            switch (c) {
                '[' => return in.scanCsi(s),
                'P' => if (in.style_due) {
                    const end = std.mem.indexOf(u8, s, "\x1b\\") orelse
                        return if (s.len < max_seq) .{ .wait = seq_wait_ns } else one(.{ .key = s[0..2] }, 2);
                    return one(.{ .cursor_style = cursorStyle(s[2..end]) }, end + 2);
                } else return one(.{ .key = s[0..2] }, 2),
                ']' => if (in.osc_due) {
                    const bel = std.mem.indexOfScalar(u8, s, 0x07);
                    const st = std.mem.indexOf(u8, s, "\x1b\\");
                    const stop = if (bel != null and (st == null or bel.? < st.?)) bel.? + 1 else if (st) |e| e + 2 else return if (s.len < max_seq) .{ .wait = seq_wait_ns } else one(.{ .key = s[0..2] }, 2);
                    return one(.dropped, stop);
                } else return one(.{ .key = s[0..2] }, 2),
                'O' => {
                    if (s.len == 2) return .{ .wait = seq_wait_ns };
                    // SS3 and its final byte, or Alt-O.
                    const n: usize = if (s[2] >= 0x20 and s[2] < 0x7f) 3 else 2;
                    return in.namedOr(s[0..n]);
                },
                // The first ESC is the Escape key.
                0x1b => return one(.{ .key = s[0..1] }, 1),
                0x80...0xff => {
                    // Alt with a character.
                    const n = utf8Len(s[1..]) orelse return .{ .wait = seq_wait_ns };
                    return one(.{ .key = s[0 .. 1 + n] }, 1 + n);
                },
                // Alt with a character or a control.
                else => return one(.{ .key = s[0..2] }, 2),
            }
        }
        if (b == in.detach_key) return one(.detach, 1);
        if (b < 0x80) return in.namedOr(s[0..1]);
        const n = utf8Len(s) orelse return .{ .wait = seq_wait_ns };
        return one(.{ .key = s[0..n] }, n);
    }

    fn scanCsi(in: *const Input, s: []const u8) Scan {
        if (s.len == 2) return .{ .wait = seq_wait_ns };
        if (s[2] == 'M') {
            // An X10 mouse report: three bytes, or three UTF-8 characters
            // with mode 1005.
            var i: usize = 3;
            for (0..3) |_| {
                if (i >= s.len) return .{ .wait = seq_wait_ns };
                const n: usize = if (in.utf8_mouse) (utf8Len(s[i..]) orelse return .{ .wait = seq_wait_ns }) else 1;
                i += n;
            }
            return one(.{ .mouse = s[0..i] }, i);
        }
        var i: usize = 2;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c >= 0x40 and c <= 0x7e) return in.csiUnit(s[0 .. i + 1]);
            // Cut short: what came goes as it is.
            if (c < 0x20 or c > 0x7e or i >= max_seq) return one(.{ .key = s[0..i] }, i);
        }
        return .{ .wait = seq_wait_ns };
    }

    fn csiUnit(in: *const Input, seq: []const u8) Scan {
        const final = seq[seq.len - 1];
        const body = seq[2 .. seq.len - 1];
        if (final == '~' and std.mem.eql(u8, body, "200")) return .{ .paste_start = seq.len };
        if (final == '~' and std.mem.eql(u8, body, "201")) return one(.dropped, seq.len);
        if (body.len == 0 and (final == 'I' or final == 'O')) return one(.{ .focus = seq }, seq.len);
        if ((final == 'M' or final == 'm') and body.len > 0 and body[0] == '<') return one(.{ .mouse = seq }, seq.len);
        if (final == 'M' and isUrxvtMouse(body)) return one(.{ .mouse = seq }, seq.len);
        if (final == 'c' and body.len > 0 and body[0] == '?') return one(.attributes, seq.len);
        if (final == 'R') if (cursorReport(body)) |cell| return one(.{ .report = .{ .row = cell[0], .col = cell[1], .bytes = seq } }, seq.len);
        if (final == 'y' and body.len > 2 and body[0] == '?' and body[body.len - 1] == '$') {
            var it = std.mem.splitScalar(u8, body[1 .. body.len - 1], ';');
            const mode = std.fmt.parseInt(u32, it.next() orelse "", 10) catch return one(.dropped, seq.len);
            const value = std.fmt.parseInt(u32, it.next() orelse "", 10) catch return one(.dropped, seq.len);
            return one(.{ .mode_report = .{ .mode = mode, .value = value } }, seq.len);
        }
        if (in.detach_key < 0x20 and attach_client.isCtrlSequence(seq[1..], in.detach_key)) return one(.detach, seq.len);
        return in.namedOr(seq);
    }

    /// `bytes` as the switch or the side key when it is one (its release
    /// goes nowhere), else as the key it is.
    fn namedOr(in: *const Input, bytes: []const u8) Scan {
        for ([_]?config_mod.Key{ in.switch_key, in.side_key }, [_]Named{ .switch_key, .side_key }) |k, which| {
            const key = k orelse continue;
            switch (keyEvent(key, bytes)) {
                .no => {},
                .press => return one(.{ .named = .{ .which = which, .bytes = bytes } }, bytes.len),
                .release => return one(.dropped, bytes.len),
            }
        }
        return one(.{ .key = bytes }, bytes.len);
    }
};

const end_mark = "\x1b[201~";

/// The style in a DECRQSS answer for DECSCUSR, "1$r2 q", as 2.
fn cursorStyle(body: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, body, "1$r") or !std.mem.endsWith(u8, body, " q")) return null;
    const n = std.fmt.parseInt(u8, body[3 .. body.len - 2], 10) catch return null;
    return if (n <= 6) n else null;
}

/// "row;col" of a cursor report.
fn cursorReport(body: []const u8) ?[2]u32 {
    var it = std.mem.splitScalar(u8, body, ';');
    const row = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const col = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return .{ row, col };
}

/// "b;x;y" with three numbers: an urxvt (1015) mouse report.
fn isUrxvtMouse(body: []const u8) bool {
    var it = std.mem.splitScalar(u8, body, ';');
    var count: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
        count += 1;
    }
    return count == 3;
}

/// The length of the UTF-8 character at the start of `s`; null while it
/// is incomplete. A byte that starts no character, or a broken one,
/// counts alone.
fn utf8Len(s: []const u8) ?usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 1;
    for (1..n) |i| {
        if (i >= s.len) return null;
        if (s[i] & 0xc0 != 0x80) return 1;
    }
    _ = std.unicode.utf8Decode(s[0..n]) catch return 1;
    return n;
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

/// The units of `chunks`, fed one after another, as text.
fn unitsOf(gpa: std.mem.Allocator, chunks: []const []const u8) ![]u8 {
    return unitsWith(gpa, .{ .detach_key = 0x1d }, chunks);
}

fn unitsWith(gpa: std.mem.Allocator, start: Input, chunks: []const []const u8) ![]u8 {
    var in = start;
    defer in.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // No time passes between reads; after the last, the waits end.
    for (0..chunks.len + 1) |i| {
        if (i < chunks.len) try in.feed(gpa, chunks[i], 0);
        const now: i64 = if (i == chunks.len) std.math.maxInt(i64) / 2 else 0;
        while (in.next(now)) |unit| try describe(&out.writer, unit);
    }
    return out.toOwnedSlice();
}

fn describe(w: *std.Io.Writer, unit: Unit) !void {
    switch (unit) {
        .key => |b| try w.print("key {s}\n", .{b}),
        .paste => |p| try w.print("paste {} {} {s}\n", .{ p.first, p.last, p.text }),
        .mouse => |b| try w.print("mouse {s}\n", .{b}),
        .focus => |b| try w.print("focus {s}\n", .{b}),
        .mode_report => |m| try w.print("mode {d} {d}\n", .{ m.mode, m.value }),
        .cursor_style => |n| try w.print("style {?d}\n", .{n}),
        .attributes => try w.writeAll("attributes\n"),
        .report => |r| try w.print("report {d} {d}\n", .{ r.row, r.col }),
        .detach => try w.writeAll("detach\n"),
        .named => |n| try w.print("{s}\n", .{@tagName(n.which)}),
        .dropped => try w.writeAll("dropped\n"),
    }
}

/// Feed `bytes`, then expect the units taken at `now`.
fn expectUnits(in: *Input, bytes: []const u8, now: i64, want: []const u8) !void {
    const gpa = testing.allocator;
    try in.feed(gpa, bytes, now);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    while (in.next(now)) |unit| try describe(&out.writer, unit);
    try testing.expectEqualStrings(want, out.written());
}

test "a side pane beside the front leaves the front its front_min columns" {
    for (145..400) |cols| {
        const pane = paneCols(cols, 100, 44);
        try testing.expect(pane >= 44);
        try testing.expect(cols - pane - 1 >= 100);
    }
    try testing.expectEqual(@as(usize, 44), paneCols(145, 100, 44));
    try testing.expectEqual(@as(usize, 99), paneCols(300, 100, 44));
}

test "input units do not depend on how the input is split into reads" {
    const gpa = testing.allocator;
    const pieces = [_][]const u8{
        "a",            "\x1b",         "\x1b[A",       "\x1bOP",        "\x1b[1;5C",          "\x1b[200~pa\x1b[A\x1dste\x1b[201~",
        "\x1b[<0;3;4M", "\x1b[M !!",    "\x1b[32;5;6M", "\x1b[I",        "\x1b[?1007;2$y",     "\x1b[93;5u",
        "\x1d",         "\xe4\xb8\x80", "\xc3",         "\x1b\xc3\xa4",  "\x1bx",              "\x1b[201~",
        "\x1b[1;2\r",   "\xff",         "\x1b\x1b[B",   "\x1b[27;5;93~", "\x1b[200~\x1b[201~", "\x1bO",
        "\x1b[12;40R",  "\x1b[1;5R",
    };
    var prng: std.Random.DefaultPrng = .init(0x64726177);
    const random = prng.random();
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    for (0..200) |_| {
        stream.clearRetainingCapacity();
        for (0..40) |_| try stream.appendSlice(gpa, pieces[random.uintLessThan(usize, pieces.len)]);
        const whole = try unitsOf(gpa, &.{stream.items});
        defer gpa.free(whole);
        var chunks: std.ArrayList([]const u8) = .empty;
        defer chunks.deinit(gpa);
        var at: usize = 0;
        while (at < stream.items.len) {
            const n = @min(stream.items.len - at, 1 + random.uintLessThan(usize, if (random.boolean()) 4 else 4096));
            try chunks.append(gpa, stream.items[at .. at + n]);
            at += n;
        }
        const split = try unitsOf(gpa, chunks.items);
        defer gpa.free(split);
        try testing.expectEqualStrings(whole, split);
    }
    // Pastes about as long as a piece, read a few bytes at a time around
    // the piece's end and the end mark, and in large reads elsewhere.
    const open_mark = "a\x1b[200~";
    for (max_paste - 2..max_paste + 9) |len| {
        stream.clearRetainingCapacity();
        try stream.appendSlice(gpa, open_mark);
        try stream.appendNTimes(gpa, 'p', len);
        try stream.appendSlice(gpa, "\x1b[201~b");
        const whole = try unitsOf(gpa, &.{stream.items});
        defer gpa.free(whole);
        const edges = [_]usize{ open_mark.len + max_paste, open_mark.len + len };
        var chunks: std.ArrayList([]const u8) = .empty;
        defer chunks.deinit(gpa);
        var at: usize = 0;
        while (at < stream.items.len) {
            const near = for (edges) |e| {
                if (at + 16 >= e and at < e + 16) break true;
            } else false;
            var n = if (near) 1 + random.uintLessThan(usize, 4) else 64 * 1024;
            // A large read stops short of the next edge.
            if (!near) for (edges) |e| if (e > at + 16) {
                n = @min(n, e - 16 - at);
            };
            n = @min(n, stream.items.len - at);
            try chunks.append(gpa, stream.items[at .. at + n]);
            at += n;
        }
        const split = try unitsOf(gpa, chunks.items);
        defer gpa.free(split);
        try testing.expectEqualStrings(whole, split);
    }
    // A paste of exactly one piece, its end mark cut one byte short.
    stream.clearRetainingCapacity();
    try stream.appendSlice(gpa, "\x1b[200~");
    try stream.appendNTimes(gpa, 'p', max_paste);
    try stream.appendSlice(gpa, "\x1b[201~");
    const whole = try unitsOf(gpa, &.{stream.items});
    defer gpa.free(whole);
    const cut = stream.items.len - 1;
    const split = try unitsOf(gpa, &.{ stream.items[0..cut], stream.items[cut..] });
    defer gpa.free(split);
    try testing.expectEqualStrings(whole, split);
}

test "input splits into keys, pastes, mouse and focus reports, answers, and tuppet's key, each with its read time" {
    const got = try unitsOf(testing.allocator, &.{ "a\x1b[A\x1b[200~x\x1b[201~\x1b[<0;1;1M\x1b[O\x1b[?1007;1$y\x1b[93;5u\x1b[4;7R", "\x1b" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("key a\nkey \x1b[A\npaste true true x\nmouse \x1b[<0;1;1M\nfocus \x1b[O\nmode 1007 1\ndetach\nreport 4 7\nkey \x1b\n", got);
    // A unit is read when its last byte is.
    var in: Input = .{ .detach_key = 0x1d };
    defer in.deinit(testing.allocator);
    try in.feed(testing.allocator, "a\x1b[", 5);
    try testing.expectEqualStrings("a", in.next(5).?.key);
    try testing.expectEqual(@as(i64, 5), in.unit_at);
    try testing.expect(in.next(5) == null);
    try testing.expectEqual(@as(?i64, 5), in.pending());
    try in.feed(testing.allocator, "A", 7);
    try testing.expectEqualStrings("\x1b[A", in.next(7).?.key);
    try testing.expectEqual(@as(i64, 7), in.unit_at);
    try testing.expectEqual(@as(?i64, null), in.pending());
}

test "a paste goes to its session closed and never as keys" {
    const gpa = testing.allocator;
    const w = paste_wait_ns;
    var in: Input = .{ .detach_key = 0x1d };
    defer in.deinit(gpa);
    // A stall passes on what came; only the end mark ends the paste.
    try expectUnits(&in, "\x1b[200~line one\r", 0, "");
    try expectUnits(&in, "", w, "paste true false line one\r\n");
    try expectUnits(&in, "rm -rf typed\r\x1b[201~k", w, "paste false true rm -rf typed\r\nkey k\n");
    // A stall keeps what may begin the end mark.
    try expectUnits(&in, "\x1b[200~x\x1b[20", 2 * w, "");
    try expectUnits(&in, "", 3 * w, "paste true false x\n");
    try expectUnits(&in, "1~", 3 * w, "paste false true \n");
    // tuppet's key, read on its own once the paste stalled, ends it.
    try expectUnits(&in, "\x1b[200~y", 4 * w, "");
    try expectUnits(&in, "", 5 * w, "paste true false y\n");
    try expectUnits(&in, "\x1d", 5 * w, "paste false true \ndetach\n");
    // Also as the kitty keyboard protocol sends it.
    try expectUnits(&in, "\x1b[200~z", 5 * w, "");
    try expectUnits(&in, "", 6 * w, "paste true false z\n");
    try expectUnits(&in, "\x1b[93;5u", 6 * w, "paste false true \ndetach\n");
    // A paste cut after a piece went is closed. Bytes read but not taken,
    // its end and the start of a new paste among them, are parsed: the
    // new paste is dropped up to its end.
    try expectUnits(&in, "\x1b[200~first", 6 * w, "");
    try expectUnits(&in, "", 7 * w, "paste true false first\n");
    try in.feed(gpa, "more\x1b[201~\x1b[200~new", 7 * w);
    in.clear();
    try expectUnits(&in, "", 7 * w, "paste false true \n");
    try expectUnits(&in, "rest\x1d\x1b[201~k", 7 * w, "dropped\nkey k\n");
    // A paste cut before any piece went is only dropped.
    try expectUnits(&in, "\x1b[200~ab", 8 * w, "");
    in.clear();
    try expectUnits(&in, "c\x1b[201~k", 8 * w, "dropped\nkey k\n");
    // A sequence that has begun stays across a clear.
    try expectUnits(&in, "\x1b[20", 9 * w, "");
    in.clear();
    try expectUnits(&in, "0~text\x1b[201~", 9 * w, "paste true true text\n");
}

test "a paint waits at most a frame for a synchronized update and is due at a fixed time" {
    const ms = std.time.ns_per_ms;
    var p: Pacer = .{ .last_paint = 1000 * ms };
    try testing.expectEqual(@as(?i64, null), p.due(false));
    p.changed(1010 * ms);
    try testing.expectEqual(@as(?i64, 1033 * ms), p.due(false));
    try testing.expectEqual(@as(?i64, 1066 * ms), p.due(true));
    // Output after a quiet while is painted at once, or a frame later in
    // a synchronized update.
    p.painted(2000 * ms);
    p.changed(3000 * ms);
    try testing.expectEqual(@as(?i64, 3033 * ms), p.due(true));
    // The echo of a key is painted at once, also in a synchronized update.
    p.painted(4000 * ms);
    p.key(4001 * ms);
    p.changed(4003 * ms);
    try testing.expectEqual(@as(?i64, 4003 * ms), p.due(true));
    // A program that never leaves its synchronized update still gets a
    // paint every two frames, and a loop that sleeps until the due time
    // paints each time it wakes.
    p.painted(5000 * ms);
    var now: i64 = 5000 * ms;
    var paints: usize = 0;
    while (now < 6000 * ms) : (now += 2 * ms) {
        p.changed(now);
        const due = p.due(true).?;
        try testing.expect(due > p.last_paint);
        if (due <= now) {
            p.painted(now);
            paints += 1;
        }
    }
    try testing.expect(paints >= 14 and paints <= 16);
}

test "the person's terminal gets the session's input modes and gives them back" {
    var src = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 10, .rows = 2, .max_scrollback_bytes = 0 });
    defer src.deinit(testing.allocator);
    var dst = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 10, .rows = 2, .max_scrollback_bytes = 0 });
    defer dst.deinit(testing.allocator);
    var src_stream = vt.TerminalStream.init(.{ .handler = src.vtHandler(), .allocator = testing.allocator });
    defer src_stream.deinit();
    var dst_stream = vt.TerminalStream.init(.{ .handler = dst.vtHandler(), .allocator = testing.allocator });
    defer dst_stream.deinit();

    src_stream.nextSlice("\x1b[?1h\x1b=\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[=5;1u\x1b[>4;2m");
    const want = InputModes.of(&src);
    try testing.expect(want.cursor_keys and want.keypad and want.mouse == .button and want.mouse_format == .sgr and want.focus);
    try testing.expectEqual(@as(u5, 5), want.kitty_flags);
    try testing.expect(want.modify_other_keys);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try InputModes.change(&w, .{}, want);
    dst_stream.nextSlice(w.buffered());
    try testing.expectEqual(want, InputModes.of(&dst));

    // A change writes only what changed; the end puts everything back.
    src_stream.nextSlice("\x1b[?1003h\x1b[?1l");
    w = .fixed(&buf);
    try InputModes.change(&w, want, InputModes.of(&src));
    try testing.expectEqualStrings("\x1b[?1l\x1b[?1002l\x1b[?1003h", w.buffered());
    dst_stream.nextSlice(w.buffered());
    dst_stream.nextSlice(modes_off);
    try testing.expectEqual(InputModes{}, InputModes.of(&dst));
}

test "output that is slow to apply holds up the rest of the loop no longer than its turn" {
    const gpa = testing.allocator;
    var t = try vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{ .cols = 250, .rows = 80, .max_scrollback_bytes = 0, .kitty_image_storage_limit = 0 });
    defer t.deinit(gpa);
    var handler = t.vtHandler();
    handler.effects = .readonly;
    var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = gpa });
    defer stream.deinit();
    // Each repeats a character over the whole screen.
    var flood: std.ArrayList(u8) = .empty;
    defer flood.deinit(gpa);
    while (flood.items.len < 64 * 1024) try flood.appendSlice(gpa, "x\x1b[65535b");
    const start = io_mod.nowNanos();
    const fed = feedUntil(&stream, flood.items, start + stream_ns);
    const took = io_mod.nowNanos() - start;
    try testing.expect(fed < flood.items.len);
    try testing.expect(took < frame_ns);
}

/// A view the daemon's attach reply opened, fed frames by hand.
fn testView(track: bool, cols: u16, rows: u16) !*View {
    const gpa = testing.allocator;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    _ = std.c.close(fds[1]);
    const v = try gpa.create(View);
    v.* = .{ .gpa = gpa, .role = .read, .conn = .{ .posix = .{ .socket = .{ .handle = fds[0], .address = undefined } } }, .track = track };
    if (track) v.left = .init(gpa);
    var buf: [96]u8 = undefined;
    v.reply(try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"status\":{{\"id\":1,\"cols\":{d},\"rows\":{d}}}}}", .{ cols, rows }));
    try testing.expect(v.has_terminal);
    return v;
}

fn testFrame(v: *View, key: []const u8, bytes: []const u8) !void {
    var b64: [256]u8 = undefined;
    var buf: [320]u8 = undefined;
    v.frame(try std.fmt.bufPrint(&buf, "{{\"{s}\":\"{s}\"}}", .{ key, std.base64.standard.Encoder.encode(&b64, bytes) }));
    v.workAll();
}

test "an empty screen ends the wait for a screen" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const v = try testView(false, 10, 3);
    defer v.deinit();
    try testing.expect(!v.ready());
    try testFrame(v, "screen", "");
    try testing.expect(v.ready());
}

test "rows a screen moves into the copy's history stay out of the scrollback, also when it erases them" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const v = try testView(true, 10, 2);
    defer v.deinit();
    try testFrame(v, "screen", "a\r\nb\r\nc\x1b[3J");
    try testing.expectEqual(@as(usize, 0), v.left.len());
}

test "rows in the copy's history are kept when the program switches its width" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const v = try testView(true, 10, 2);
    defer v.deinit();
    // Joined at 132 columns, the wrapped row would take "b" back from the
    // history, and DECCOLM's erase would lose it.
    try testFrame(v, "out", "a\r\nb\r\n0123456789ABCDEFGHIJ\x1b[?40h\x1b[?3h");
    try testing.expectEqual(@as(usize, 2), v.left.len());
}

test "row numbers a daemon sends past what they can hold do not crash the view" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const v = try testView(true, 10, 2);
    defer v.deinit();
    for ([_][]const u8{
        "{\"history\":\"\",\"row\":0,\"rows\":0}",
        "{\"history\":\"\",\"row\":18446744073709551615,\"rows\":5}",
        "{\"screen\":\"\",\"row\":18446744073709551615,\"wrapped\":[65535]}",
        "{\"history\":\"\",\"row\":0,\"rows\":0}",
        "{\"history\":\"\",\"row\":5,\"rows\":0}",
    }) |line| {
        v.frame(line);
        v.workAll();
    }
    try testFrame(v, "out", "a\r\nb\r\nc");
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), v.top);
}

test "input dropped unread still answers tuppet's asks" {
    var in: Input = .{ .detach_key = 0x1d };
    defer in.deinit(testing.allocator);
    var m: boxes.Boxes = .{ .stale = 1 };
    try in.feed(testing.allocator, "x\x1b[5;7Ry", 0);
    discard(&in, &m, 0);
    try testing.expectEqual(@as(u64, 0), m.stale);
    try testing.expectEqual(@as(?i64, null), in.pending());
}

test "tuppet's line cuts the title before what it says, and says only the short form when even that does not fit" {
    var buf: [128]u8 = undefined;
    const rest = " waits \u{00b7} window too small";
    try testing.expectEqualStrings("deploy waits \u{00b7} window too small", fitLine(&buf, "deploy", rest, "window too small", 40).?);
    try testing.expectEqualStrings("de\u{2026} waits \u{00b7} window too small", fitLine(&buf, "deploy", rest, "window too small", 28).?);
    try testing.expectEqualStrings("\u{6f22}\u{2026} waits \u{00b7} window too small", fitLine(&buf, "\u{6f22}\u{5b57}", rest, "window too small", 28).?);
    try testing.expectEqualStrings("window too small", fitLine(&buf, "deploy", rest, "window too small", 16).?);
}

test "the answers to the color query, apart from what was typed" {
    var typed: [32]u8 = undefined;
    const got = splitAnswers("a\x1b]10;rgb:0/0/0\x07b\x1b]11;rgb:ffff/ffff/ffff\x1b\\\x1b[?62;22cc", &typed);
    try testing.expectEqualStrings("abc", typed[0..got.typed]);
    try testing.expect(got.attributes);
    try testing.expectEqual(vt.color.RGB{ .r = 0xff, .g = 0xff, .b = 0xff }, got.bg.?);
    try testing.expectEqual(vt.color.RGB{ .r = 0, .g = 0, .b = 0 }, got.fg.?);
    const late: Input = .{ .detach_key = 0x1d, .osc_due = true };
    const units = try unitsWith(testing.allocator, late, &.{ "\x1b]11;rgb:f", "/f/f\x07x" });
    defer testing.allocator.free(units);
    try testing.expectEqualStrings("dropped\nkey x\n", units);
}

test "the terminal's answers about its colors" {
    const answer = "\x1b]10;rgb:0000/1111/ffff\x1b\\\x1b]11;rgb:f/80/abc\x07\x1b[?62c";
    try testing.expectEqual(vt.color.RGB{ .r = 0, .g = 0x11, .b = 0xff }, colorAnswer(answer, "\x1b]10;").?);
    try testing.expectEqual(vt.color.RGB{ .r = 0xff, .g = 0x80, .b = 0xab }, colorAnswer(answer, "\x1b]11;").?);
    try testing.expect(colorAnswer("\x1b]11;#ffffff\x07", "\x1b]11;") == null);
    try testing.expect(colorAnswer("\x1b]11;rgb:ff/ff\x07", "\x1b]11;") == null);
    try testing.expectEqual(paint.Color.rgb(.{ .r = 0x7f, .g = 0x7f, .b = 0x7f }), dimColor(.{ .{ .r = 0, .g = 0, .b = 0 }, .{ .r = 0xff, .g = 0xff, .b = 0xff } }));
}

test "the answer to the cursor style query, only while one is due" {
    const due: Input = .{ .detach_key = 0x1d, .style_due = true };
    const got = try unitsWith(testing.allocator, due, &.{ "\x1bP1$r2", " q\x1b\\x", "\x1bP0$r\x1b\\" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("style 2\nkey x\nstyle null\n", got);
    const alt_p = try unitsOf(testing.allocator, &.{"\x1bP1"});
    defer testing.allocator.free(alt_p);
    try testing.expectEqualStrings("key \x1bP\nkey 1\n", alt_p);
}
