//! `tuppet play`: play an asciicast v2 recording into the terminal it runs
//! in, through the attach filter, at the recording's size.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const plat = @import("plat.zig");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const attach_client = @import("attach_client.zig");
const attach_filter = @import("attach_filter.zig");
const limits = @import("limits.zig");

const usage = "usage: tuppet play FILE.cast [--speed N] [--max-pause DUR]";

/// A line of the recording longer than this is refused.
const max_line = 16 << 20;

/// How long a notice that the window is too small stays before the
/// recording goes on.
const notice_pause_ns: i64 = 1500 * std.time.ns_per_ms;

/// The longest pause between two frames without --max-pause.
const longest_pause_ns: u64 = 24 * std.time.ns_per_hour;

pub fn cmdPlay(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var path: ?[]const u8 = null;
    var speed: f64 = 1;
    var max_pause_ms: ?u64 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--speed")) {
            const value = try client.optValue(args, &i);
            speed = parseSpeed(value) orelse return client.cliFail("invalid --speed '{s}' (expected a number above 0, such as 2 or 0.5)", .{value});
        } else if (std.mem.eql(u8, a, "--max-pause")) {
            max_pause_ms = try client.durationValue(args, &i, 0);
        } else if (a.len > 1 and a[0] == '-') {
            return client.unknownOption(a, usage);
        } else if (path != null) {
            return client.cliFail("play takes one recording (got '{s}' and '{s}')", .{ path.?, a });
        } else {
            path = a;
        }
    }
    const file = path orelse return client.cliFail("{s}", .{usage});
    if (builtin.os.tag == .windows) client.runtimeFail("play is not supported on Windows", .{});

    const name = try gpa.dupeSentinel(u8, file, 0);
    defer gpa.free(name);
    const fd = std.c.open(name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) client.runtimeFail("cannot open {s}: {s}", .{ file, switch (std.posix.errno(fd)) {
        .NOENT => "no such file",
        .ACCES => "permission denied",
        else => |e| @tagName(e),
    } });
    defer _ = std.c.close(fd);
    var reader: LineReader = .{ .fd = fd };
    defer reader.deinit(gpa);
    // The header comes before the terminal is raw: Ctrl-C ends a wait.
    const blocking = struct {
        fn awaitData(_: @This(), _: std.c.fd_t) bool {
            return true;
        }
    }{};
    const first = reader.next(gpa, blocking) catch |err| client.runtimeFail("cannot read {s}: {s}", .{ file, readError(err) });
    const header = parseHeader(gpa, first orelse "") orelse
        client.runtimeFail("{s} is not an asciicast v2 recording with a size in {s}", .{ file, limits.size_range });

    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1)
        return client.cliFail("play needs a terminal for its input and output; to play a recording from a script, play it in a session: tuppet run -- tuppet play {s}", .{file});

    var p: Player = .{ .gpa = gpa, .reader = &reader, .file = file, .speed = speed, .max_pause_ms = max_pause_ms orelse header.idle_ms, .size = header.size };
    defer p.filter.deinit(gpa);
    p.own = Own.find(gpa);
    p.resizing = p.own != null;
    const code = p.run();
    if (p.failure) |msg| {
        plat.stderrWriteAll(msg) catch {};
        gpa.free(msg);
    }
    std.process.exit(code);
}

fn readError(err: anyerror) []const u8 {
    return switch (err) {
        error.IsDir => "it is a directory",
        error.LineTooLong => "a line is longer than 16 MiB",
        error.OutOfMemory => "out of memory",
        else => "read error",
    };
}

/// A --speed value: a finite number above 0.
fn parseSpeed(text: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(v) or v <= 0) return null;
    return v;
}

const Header = struct {
    size: [2]u16,
    /// The longest pause the recording asks a player to keep.
    idle_ms: ?u64 = null,
};

/// What an asciicast v2 header line says.
fn parseHeader(gpa: std.mem.Allocator, line: []const u8) ?Header {
    const Fields = struct { version: u32 = 0, width: u32 = 0, height: u32 = 0, idle_time_limit: ?f64 = null };
    const h = std.json.parseFromSlice(Fields, gpa, line, .{ .ignore_unknown_fields = true }) catch return null;
    defer h.deinit();
    if (h.value.version != 2) return null;
    var header: Header = .{ .size = checkedSize(h.value.width, h.value.height) orelse return null };
    if (h.value.idle_time_limit) |s| if (s >= 0 and s < longest_pause_ns / std.time.ns_per_s) {
        header.idle_ms = @intFromFloat(s * std.time.ms_per_s);
    };
    return header;
}

fn checkedSize(cols: u32, rows: u32) ?[2]u16 {
    if (cols < 1 or cols > limits.max_side or rows < 1 or rows > limits.max_side) return null;
    return .{ @intCast(cols), @intCast(rows) };
}

/// A resize event's "WxH".
fn parseCastSize(text: []const u8) ?[2]u16 {
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse return null;
    const cols = protocol.parseDecimal(u32, text[0..x]) orelse return null;
    const rows = protocol.parseDecimal(u32, text[x + 1 ..]) orelse return null;
    return checkedSize(cols, rows);
}

/// An asciicast v2 event: [time, code, data].
const Event = struct { f64, []const u8, []const u8 };

fn parseEvent(gpa: std.mem.Allocator, line: []const u8) ?std.json.Parsed(Event) {
    const ev = std.json.parseFromSlice(Event, gpa, line, .{}) catch return null;
    if (!std.math.isFinite(ev.value[0])) {
        ev.deinit();
        return null;
    }
    return ev;
}

/// How long to wait between two frames `gap_s` seconds apart in the
/// recording: the gap at `speed`, at most `max_pause_ms`.
fn pauseNs(gap_s: f64, speed: f64, max_pause_ms: ?u64) u64 {
    if (!(gap_s > 0)) return 0;
    const cap: f64 = @floatFromInt(if (max_pause_ms) |ms| @min(ms * std.time.ns_per_ms, longest_pause_ns) else longest_pause_ns);
    return @intFromFloat(@min(gap_s / speed * std.time.ns_per_s, cap));
}

/// What a key the person pressed does.
pub const Key = enum { pause, quit, other };

/// Finds Space, q, and Ctrl-C in terminal input, in whatever form the
/// keyboard modes of the recording make the terminal send them, and
/// skips mouse reports, focus reports, and pastes.
pub const Keys = struct {
    state: enum { ground, esc, csi, ss3, mouse } = .ground,
    params: [32]u8 = undefined,
    len: u8 = 0,
    mouse_left: u8 = 0,
    /// The last coordinate byte may start a two-byte UTF-8 character.
    mouse_lead: bool = false,
    paste: bool = false,

    pub fn feed(k: *Keys, c: u8) ?Key {
        switch (k.state) {
            .ground => {
                if (c == 0x1b) {
                    k.state = .esc;
                    return null;
                }
                if (k.paste) return null;
                return switch (c) {
                    ' ' => .pause,
                    'q', 'Q', 0x03 => .quit,
                    // The rest of a character whose first byte counted.
                    0x80...0xbf => null,
                    else => .other,
                };
            },
            .esc => switch (c) {
                '[' => {
                    k.state = .csi;
                    k.len = 0;
                    return null;
                },
                'O' => {
                    k.state = .ss3;
                    return null;
                },
                0x1b => return null,
                else => {
                    k.state = .ground;
                    return if (k.paste) null else .other;
                },
            },
            .ss3 => {
                k.state = .ground;
                return if (k.paste) null else .other;
            },
            .mouse => {
                // With UTF-8 coordinates (mode 1005) a coordinate can
                // take two bytes.
                if (k.mouse_lead and c >= 0x80 and c <= 0xbf) {
                    k.mouse_lead = false;
                    return null;
                }
                k.mouse_lead = c >= 0xc2 and c <= 0xdf;
                k.mouse_left -= 1;
                if (k.mouse_left == 0) k.state = .ground;
                return null;
            },
            .csi => {
                if (c >= 0x20 and c <= 0x3f) {
                    if (k.len < k.params.len) {
                        k.params[k.len] = c;
                        k.len += 1;
                    }
                    return null;
                }
                k.state = if (c == 0x1b) .esc else .ground;
                if (c < 0x40 or c > 0x7e) return null;
                return k.csiKey(k.params[0..k.len], c);
            },
        }
    }

    /// A read that did not fill its buffer ended: a terminal writes a key
    /// at once, so an unfinished sequence at its end was a key of its own,
    /// such as Escape or Alt-[.
    pub fn endOfRead(k: *Keys) ?Key {
        switch (k.state) {
            .esc, .csi, .ss3 => {
                k.state = .ground;
                return if (k.paste) null else .other;
            },
            .ground, .mouse => return null,
        }
    }

    fn csiKey(k: *Keys, params: []const u8, final: u8) ?Key {
        // X10 mouse reports: three coordinates follow.
        if (final == 'M' and params.len == 0) {
            k.state = .mouse;
            k.mouse_left = 3;
            k.mouse_lead = false;
            return null;
        }
        if (final == '~' and std.mem.eql(u8, params, "200")) {
            k.paste = true;
            return null;
        }
        if (final == '~' and std.mem.eql(u8, params, "201")) {
            k.paste = false;
            return null;
        }
        if (k.paste) return null;
        // SGR and urxvt mouse reports, focus reports.
        if (final == 'M' or final == 'm' or (params.len > 0 and params[0] == '<')) return null;
        if ((final == 'I' or final == 'O') and params.len == 0) return null;
        if (final != 'u' and final != '~') return .other;
        // Kitty keyboard protocol: code[:alternates];mods[:event];text.
        // modifyOtherKeys: 27;mods;code~.
        var v: [3][2]?u32 = .{ .{ null, null }, .{ null, null }, .{ null, null } };
        var f: usize = 0;
        var s: usize = 0;
        for (params) |c| switch (c) {
            '0'...'9' => if (f < 3 and s < 2) {
                const old = v[f][s] orelse 0;
                if (old > 1_000_000) return .other;
                v[f][s] = old * 10 + (c - '0');
            },
            ':' => s += 1,
            ';' => {
                f += 1;
                s = 0;
            },
            else => return .other,
        };
        const code: u32, const mods: u32, const event: u32 = if (final == 'u')
            .{ v[0][0] orelse return .other, v[1][0] orelse 1, v[1][1] orelse 1 }
        else if (v[0][0] == 27 and v[2][0] != null)
            .{ v[2][0].?, v[1][0] orelse 1, 1 }
        else
            return .other;
        // A key's release.
        if (event == 3) return null;
        if (mods == 0) return .other;
        // Shift, Caps Lock, and Num Lock do not count.
        const held = (mods - 1) & ~@as(u32, 1 | 64 | 128);
        if (held == 4 and code == 'c') return .quit;
        if (held != 0) return .other;
        return switch (code) {
            ' ' => .pause,
            'q', 'Q' => .quit,
            else => .other,
        };
    }
};

/// The recording's lines, read as they are needed.
const LineReader = struct {
    fd: std.c.fd_t,
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,
    eof: bool = false,
    number: usize = 0,

    fn deinit(r: *LineReader, gpa: std.mem.Allocator) void {
        r.buf.deinit(gpa);
    }

    /// The next line, valid until the next call; null at the end. Before
    /// each read, `waiter.awaitData(fd)` waits until the file has data;
    /// false stops the reading with error.Stopped.
    fn next(r: *LineReader, gpa: std.mem.Allocator, waiter: anytype) !?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, r.buf.items, r.start, '\n')) |nl| {
                const line = r.buf.items[r.start..nl];
                r.start = nl + 1;
                r.number += 1;
                return std.mem.trimEnd(u8, line, "\r");
            }
            if (r.eof) {
                if (r.start == r.buf.items.len) return null;
                const line = r.buf.items[r.start..];
                r.start = r.buf.items.len;
                r.number += 1;
                return line;
            }
            if (r.start > 0) {
                const rest = r.buf.items.len - r.start;
                std.mem.copyForwards(u8, r.buf.items[0..rest], r.buf.items[r.start..]);
                r.buf.shrinkRetainingCapacity(rest);
                r.start = 0;
            }
            if (r.buf.items.len >= max_line) return error.LineTooLong;
            try r.buf.ensureUnusedCapacity(gpa, 64 * 1024);
            if (!waiter.awaitData(r.fd)) return error.Stopped;
            const room = r.buf.unusedCapacitySlice();
            const n = std.c.read(r.fd, room.ptr, room.len);
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR, .AGAIN => continue,
                .ISDIR => return error.IsDir,
                else => return error.ReadFailed,
            };
            if (n == 0) r.eof = true else r.buf.items.len += @intCast(n);
        }
    }
};

/// The tuppet session play runs in, which it resizes to the recording.
const Own = struct {
    id_text: [20]u8 = undefined,
    id_len: usize = 0,
    /// The size to give back at the end: the session's before play, or
    /// the one an attach asked for since.
    restore: [2]u16,
    /// The size play last gave the session.
    set: ?[2]u16 = null,

    /// The session this terminal is, from TUPPET_SESSION and
    /// TUPPET_SESSION_SOCKET. A terminal that inherited them, such as a
    /// tmux pane in a session, has another size than the session, and is
    /// not taken for it.
    fn find(gpa: std.mem.Allocator) ?Own {
        const session = attach_client.nestedSession() orelse return null;
        const socket = std.mem.span(std.c.getenv("TUPPET_SESSION_SOCKET") orelse return null);
        if (socket.len == 0) return null;
        const window = attach_client.terminalSize() orelse return null;
        client.socket_override = socket;
        var own: Own = .{ .restore = window };
        own.id_len = (std.fmt.bufPrint(&own.id_text, "{d}", .{session}) catch unreachable).len;
        const listed = client.request(gpa, protocol.ListReq{ .sessions = &.{own.id()} }, protocol.ListResp) catch return null;
        defer listed.deinit();
        const found = listed.parsed.value.sessions;
        if (found.len != 1 or found[0].cols != window[0] or found[0].rows != window[1]) return null;
        return own;
    }

    fn id(own: *const Own) []const u8 {
        return own.id_text[0..own.id_len];
    }

    /// Resize the session; the daemon's reason on failure, owned by the
    /// caller.
    fn resize(own: *Own, gpa: std.mem.Allocator, size: [2]u16) ?[]u8 {
        const reply = client.request(gpa, protocol.ResizeReq{ .session = own.id(), .cols = size[0], .rows = size[1] }, protocol.ResizeResp) catch |err|
            return std.fmt.allocPrint(gpa, "{s}", .{client.errorText(err) orelse @errorName(err)}) catch null;
        defer reply.deinit();
        if (!reply.parsed.value.ok) return client.failureText(gpa, reply.line) catch null;
        own.set = size;
        return null;
    }
};

const Player = struct {
    gpa: std.mem.Allocator,
    reader: *LineReader,
    file: []const u8,
    speed: f64,
    max_pause_ms: ?u64,
    /// The recording's size now.
    size: [2]u16,
    own: ?Own = null,
    /// Play resizes its session to the recording; false once that failed.
    resizing: bool = false,
    filter: attach_filter.Filter = .{},
    keys: Keys = .{},
    /// When Space paused the playback.
    paused_at: ?i64 = null,
    /// The next frame's time, which a pause moves on.
    due: i64 = 0,
    said_small: bool = false,
    /// The exit code that stopped a wait for the recording's data.
    stopped: ?u8 = null,
    /// Why play stopped early, for after the terminal is restored.
    failure: ?[]u8 = null,

    const Until = union(enum) {
        /// The next frame's time.
        due,
        /// Any key.
        key,
        /// Data to read on the file.
        data: std.c.fd_t,
    };

    /// Play the recording and wait for a key after its last frame; the
    /// exit code. The terminal is restored before this returns.
    fn run(p: *Player) u8 {
        attach_client.installHandlers();
        const saved = plat.tcgetattr(0) catch null;
        if (saved) |orig| attach_client.setRaw(orig);
        // What the terminal shows goes into its history first.
        var start: std.ArrayList(u8) = .empty;
        defer start.deinit(p.gpa);
        if (attach_client.terminalSize()) |now| {
            start.appendSlice(p.gpa, "\x1b[0m") catch {};
            start.appendNTimes(p.gpa, '\n', now[1]) catch {};
        }
        start.appendSlice(p.gpa, "\x1b[H\x1b[2J") catch {};
        plat.stdoutWriteAll(start.items) catch {};
        const code = p.play();
        // The modes go first: a report the terminal sends before they are
        // off is flushed with the raw mode.
        p.leave();
        if (saved) |orig| plat.tcsetattr(0, .FLUSH, orig) catch {};
        attach_client.forgetRaw();
        if (p.own) |*own| if (own.set) |set| if (!std.mem.eql(u16, &set, &own.restore)) {
            if (own.resize(p.gpa, own.restore)) |msg| p.gpa.free(msg);
        };
        return code;
    }

    fn play(p: *Player) u8 {
        p.due = io_mod.nowNanos();
        if (p.follow()) |code| return code;
        var prev: f64 = 0;
        while (true) {
            const next = p.reader.next(p.gpa, p) catch |err| {
                if (err == error.Stopped) return p.stopped.?;
                return p.fail("cannot read {s}: {s}", .{ p.file, readError(err) });
            };
            const line = next orelse break;
            if (line.len == 0) continue;
            const ev = parseEvent(p.gpa, line) orelse return p.fail("{s}: line {d} is not an asciicast v2 event", .{ p.file, p.reader.number });
            defer ev.deinit();
            const t, const kind, const data = ev.value;
            // Recorded input and markers are left out.
            const output = std.mem.eql(u8, kind, "o");
            if (!output and !std.mem.eql(u8, kind, "r")) continue;
            p.due += @intCast(pauseNs(t - prev, p.speed, p.max_pause_ms));
            prev = @max(prev, t);
            if (p.wait(.due)) |code| return code;
            if (output) {
                const shown = p.filter.feed(p.gpa, data) catch return p.fail("out of memory", .{});
                defer p.gpa.free(shown);
                plat.stdoutWriteAll(shown) catch {};
            } else {
                p.size = parseCastSize(data) orelse return p.fail("{s}: line {d} has a size that is not WxH in {s}", .{ p.file, p.reader.number, limits.size_range });
                if (p.follow()) |code| return code;
            }
        }
        // The last frame stays until a key.
        return p.wait(.key).?;
    }

    /// For the reader: wait until the recording has data, reading keys
    /// meanwhile, so a source that stalls does not hold q and signals up.
    fn awaitData(p: *Player, fd: std.c.fd_t) bool {
        p.stopped = p.wait(.{ .data = fd });
        return p.stopped == null;
    }

    fn fail(p: *Player, comptime fmt: []const u8, args: anytype) u8 {
        p.failure = std.fmt.allocPrint(p.gpa, "tuppet: " ++ fmt ++ "\n", args) catch null;
        return client.exit_code.failed;
    }

    /// Take the recording's size: resize the session play runs in, or say
    /// once that the window is smaller, and pause for the notice.
    fn follow(p: *Player) ?u8 {
        if (p.resizing) {
            const own = &p.own.?;
            const msg = own.resize(p.gpa, p.size) orelse return null;
            defer p.gpa.free(msg);
            p.resizing = false;
            p.say("tuppet: cannot resize session {s} to {d}x{d} ({s}); the recording plays as it is\r\n", .{ own.id(), p.size[0], p.size[1], msg });
            return p.pauseFor();
        }
        const now = attach_client.terminalSize() orelse return null;
        if (p.said_small or (p.size[0] <= now[0] and p.size[1] <= now[1])) return null;
        p.said_small = true;
        p.say("tuppet: the recording is {d}x{d}, larger than this terminal ({d}x{d}); it plays as it is\r\n", .{ p.size[0], p.size[1], now[0], now[1] });
        return p.pauseFor();
    }

    fn say(p: *Player, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(p.gpa, fmt, args) catch return;
        defer p.gpa.free(text);
        plat.stderrWriteAll(text) catch {};
    }

    /// Hold the playback for a notice, and the time paused meanwhile.
    fn pauseFor(p: *Player) ?u8 {
        const due = p.due;
        p.due = io_mod.nowNanos() + notice_pause_ns;
        const start = p.due;
        const code = p.wait(.due);
        p.due = due + (p.due - start) + notice_pause_ns;
        return code;
    }

    /// The window changed: in its session, an attach resized it, so take
    /// the recording's size again and give the session the attach's size
    /// at the end.
    fn resized(p: *Player) void {
        const now = attach_client.terminalSize() orelse return;
        if (p.resizing) {
            const own = &p.own.?;
            if (std.mem.eql(u16, &now, &p.size)) return;
            own.restore = now;
            if (own.resize(p.gpa, p.size)) |msg| p.gpa.free(msg);
        } else if (!p.said_small and (p.size[0] > now[0] or p.size[1] > now[1])) {
            p.said_small = true;
            p.say("\r\ntuppet: the recording is {d}x{d}, larger than this terminal ({d}x{d}); it plays as it is\r\n", .{ p.size[0], p.size[1], now[0], now[1] });
        }
    }

    /// Wait for `until` while reading keys: Space pauses, which moves the
    /// next frame's time on by the time paused, and q quits. An exit code
    /// ends the playback.
    fn wait(p: *Player, until: Until) ?u8 {
        while (true) {
            const sig = attach_client.got_quit.load(.acquire);
            if (sig != 0) return 128 + sig;
            if (attach_client.got_winch.swap(false, .acq_rel)) p.resized();
            const now = io_mod.nowNanos();
            const timed = until == .due and p.paused_at == null;
            // Behind time, keys are still read before the frame.
            const late = timed and now >= p.due;
            const timeout: c_int = if (late) 0 else if (timed) @intCast(@min(200, @divTrunc(p.due - now + std.time.ns_per_ms - 1, std.time.ns_per_ms))) else 200;
            const source: std.c.fd_t = switch (until) {
                .data => |fd| fd,
                else => -1,
            };
            var fds = [2]std.c.pollfd{
                .{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = source, .events = std.c.POLL.IN, .revents = 0 },
            };
            const ready = std.c.poll(&fds, fds.len, timeout);
            if (ready < 0) continue;
            if (fds[0].revents != 0) if (p.readKeys(until == .key)) |code| return code;
            if (fds[1].revents != 0) return null;
            if (ready == 0 and late) return null;
        }
    }

    fn readKeys(p: *Player, any_key: bool) ?u8 {
        var chunk: [512]u8 = undefined;
        const n = std.c.read(0, &chunk, chunk.len);
        if (n < 0) switch (std.posix.errno(n)) {
            .INTR, .AGAIN => return null,
            else => {},
        };
        if (n <= 0) return p.fail("the terminal closed", .{});
        const len: usize = @intCast(n);
        for (chunk[0..len]) |c| if (p.keys.feed(c)) |key| {
            if (p.press(key, any_key)) |code| return code;
        };
        if (len < chunk.len) if (p.keys.endOfRead()) |key| return p.press(key, any_key);
        return null;
    }

    fn press(p: *Player, key: Key, any_key: bool) ?u8 {
        if (any_key or key == .quit) return 0;
        if (key != .pause) return null;
        const now = io_mod.nowNanos();
        if (p.paused_at) |at| {
            p.due += now - at;
            p.paused_at = null;
        } else {
            p.paused_at = now;
        }
        return null;
    }

    /// Put the terminal back: off the alternate screen, the modes the
    /// recording may have set reset, and the cursor below the last frame.
    fn leave(p: *Player) void {
        // Also an open link, X10 and highlight mouse tracking, their
        // encodings, and reverse video.
        const more = "\x1b]8;;\x1b\\\x1b[?9l\x1b[?1001l\x1b[?1005l\x1b[?1015l\x1b[?1016l\x1b[?5l";
        if (p.filter.alt_screen) {
            plat.stdoutWriteAll("\x1b[<99u\x1b[=0;1u\x1b[?1049l" ++ attach_client.reset_modes ++ more ++ "\r\n") catch {};
            return;
        }
        var buf: [32]u8 = undefined;
        const below = std.fmt.bufPrint(&buf, "\x1b[{d};1H\r\n", .{p.size[1]}) catch "\r\n";
        plat.stdoutWriteAll(attach_client.reset_modes ++ more) catch {};
        plat.stdoutWriteAll(below) catch {};
    }
};

test "a cast's header, events, and sizes are read" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?Header, .{ .size = .{ 80, 24 } }), parseHeader(gpa, "{\"version\":2,\"width\":80,\"height\":24,\"env\":{\"TERM\":\"xterm\"}}"));
    try std.testing.expectEqual(@as(?Header, .{ .size = .{ 80, 24 }, .idle_ms = 1500 }), parseHeader(gpa, "{\"version\":2,\"width\":80,\"height\":24,\"idle_time_limit\":1.5}"));
    try std.testing.expectEqual(@as(?Header, null), parseHeader(gpa, "{\"version\":3,\"term\":{\"cols\":80,\"rows\":24}}"));
    try std.testing.expectEqual(@as(?Header, null), parseHeader(gpa, "{\"version\":2,\"width\":0,\"height\":24}"));
    const ev = parseEvent(gpa, "[1.5, \"o\", \"hi\\u001b[m\"]").?;
    defer ev.deinit();
    try std.testing.expectEqual(@as(f64, 1.5), ev.value[0]);
    try std.testing.expectEqualStrings("o", ev.value[1]);
    try std.testing.expectEqualStrings("hi\x1b[m", ev.value[2]);
    try std.testing.expect(parseEvent(gpa, "[1.5, \"o\"") == null);
    try std.testing.expectEqual(@as(?[2]u16, .{ 100, 30 }), parseCastSize("100x30"));
    try std.testing.expectEqual(@as(?[2]u16, null), parseCastSize("100x1001"));
}

test "pauses follow --speed and stop at --max-pause" {
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), pauseNs(2, 1, null));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), pauseNs(2, 2, null));
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), pauseNs(60, 1, 500));
    try std.testing.expectEqual(@as(u64, 0), pauseNs(-1, 1, null));
    try std.testing.expectEqual(longest_pause_ns, pauseNs(1e9, 0.001, null));
    try std.testing.expectEqual(@as(?f64, null), parseSpeed("0"));
    try std.testing.expectEqual(@as(?f64, null), parseSpeed("nan"));
}

test "Space and q are found in every keyboard mode, and not in mouse reports or pastes" {
    const cases = [_]struct { []const u8, ?Key }{
        .{ " ", .pause },
        .{ "q", .quit },
        .{ "\x03", .quit },
        .{ "\x1b[32u", .pause },
        .{ "\x1b[113;1:1u", .quit },
        .{ "\x1b[113:81;2u", .quit },
        .{ "\x1b[99;5u", .quit },
        .{ "\x1b[27;1;32~", .pause },
        .{ "\x1b[113;1:3u", null },
        .{ "\x1b[113;3u", .other },
        .{ "\x1b[<0;32;113M\x1b[<0;32;113m", null },
        .{ "\x1b[M q ", null },
        .{ "\x1b[M \xc2\x80q", null },
        .{ "\x1b[", .other },
        .{ "\x1b[I\x1b[O", null },
        .{ "\x1b[200~q \x1b[201~", null },
        .{ "\x1b[A", .other },
        .{ "\x1b", .other },
    };
    for (cases) |case| {
        var k: Keys = .{};
        var got: ?Key = null;
        for (case[0]) |c| if (k.feed(c)) |key| {
            got = key;
        };
        if (k.endOfRead()) |key| got = key;
        std.testing.expectEqual(case[1], got) catch |err| {
            std.debug.print("input {any}\n", .{case[0]});
            return err;
        };
    }
}
