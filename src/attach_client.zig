//! `tuppet attach`: connect the local terminal to a session as a live
//! viewer, or as its writer.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const plat = @import("plat.zig");
const client = @import("client.zig");
const attach_filter = @import("attach_filter.zig");
const picker = @import("picker.zig");

const usage = "usage: tuppet attach <id> [--read-only] [--force] [--detach-key KEY] [--no-resize]";

/// Set from signal handlers; the main loop acts on them.
pub var got_winch: std.atomic.Value(bool) = .{ .raw = false };
pub var got_quit: std.atomic.Value(u8) = .{ .raw = 0 };

fn onWinch(_: std.posix.SIG) callconv(.c) void {
    got_winch.store(true, .release);
}

fn onQuit(sig: std.posix.SIG) callconv(.c) void {
    got_quit.store(@intCast(@intFromEnum(sig)), .release);
}

/// Parse a detach key: ^X (caret notation), <C-x>, or a single
/// character. Returns the byte the terminal sends for it.
fn parseDetachKey(spec: []const u8) ?u8 {
    if (spec.len == 2 and spec[0] == '^') return controlByte(spec[1]);
    if (spec.len == 5 and std.ascii.startsWithIgnoreCase(spec, "<c-") and spec[4] == '>') return controlByte(spec[3]);
    if (spec.len == 1) return spec[0];
    return null;
}

fn controlByte(ch: u8) ?u8 {
    if (ch == '?') return 0x7f;
    const up = std.ascii.toUpper(ch);
    if (up < '@' or up > '_') return null;
    return up - '@';
}

pub fn cmdAttach(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) return pick(gpa);
    if (std.mem.startsWith(u8, args[0], "-")) {
        return client.cliFail("the session id comes first: tuppet attach <id> {s} (without an id, attach opens the picker)", .{args[0]});
    }
    const id = args[0];
    var read_only = false;
    var force = false;
    var resize = true;
    var detach_key: u8 = 0x1d; // Ctrl-]
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--read-only")) {
            read_only = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--no-resize")) {
            resize = false;
        } else if (std.mem.eql(u8, a, "--detach-key")) {
            if (i + 1 >= args.len) return client.cliFail("missing value for --detach-key", .{});
            i += 1;
            detach_key = parseDetachKey(args[i]) orelse
                return client.cliFail("invalid detach key '{s}' (use ^X, <C-x>, or one character)", .{args[i]});
        } else {
            return client.cliFail("unknown argument '{s}' ({s})", .{ a, usage });
        }
    }
    if (read_only and force) return client.cliFail("--force takes over writing and cannot be combined with --read-only", .{});
    if (protocol.parseDecimal(u64, id) == null) return client.cliFail("invalid session id '{s}'", .{id});
    try attachSession(gpa, id, .{ .write = !read_only, .resize = resize and !read_only, .detach_key = detach_key }, force);
}

/// `tuppet attach` without an id: the session picker in a terminal; else
/// the sessions to choose from.
fn pick(gpa: std.mem.Allocator) !void {
    // Written out, not checkSupported(): the compiler must see that the
    // POSIX code below is unreachable on Windows.
    if (builtin.os.tag == .windows) client.runtimeFail("attach is not supported on Windows", .{});
    if (std.c.isatty(0) == 1 and std.c.isatty(1) == 1) std.process.exit(try picker.run(gpa));
    const parsed = try client.listSessions(gpa);
    defer parsed.deinit();
    var msg: std.Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    try msg.writer.writeAll("tuppet: attach needs a session id outside a terminal");
    const sessions = parsed.value.sessions orelse &.{};
    if (sessions.len > 0) try msg.writer.writeAll("; sessions:");
    for (sessions) |s| {
        try msg.writer.print("\n  {d}\t{s}\t", .{ s.id, s.state });
        try client.writeEscaped(&msg.writer, s.name);
        for (s.argv, 0..) |arg, i| {
            try msg.writer.writeAll(if (i == 0) "\t" else " ");
            try client.writeEscaped(&msg.writer, arg);
        }
    }
    try msg.writer.writeAll("\nrun 'tuppet help attach' for usage\n");
    plat.stderrWriteAll(msg.written()) catch {};
    return error.UsageError;
}

/// Fail early where attach cannot work.
pub fn checkSupported() void {
    if (builtin.os.tag == .windows) client.runtimeFail("attach is not supported on Windows", .{});
}

/// This terminal's size, when standard output is one.
pub fn terminalSize() ?[2]u16 {
    if (builtin.os.tag == .windows) return null;
    var ws: std.posix.winsize = undefined;
    if (std.c.ioctl(1, std.c.T.IOCGWINSZ, &ws) != 0 or ws.col == 0 or ws.row == 0) return null;
    return .{ @min(ws.col, 1000), @min(ws.row, 1000) };
}

/// Attach this terminal to session `id` until it detaches or the session
/// ends, then exit with the matching code.
pub fn attachSession(gpa: std.mem.Allocator, id: []const u8, settings: Settings, force: bool) !noreturn {
    // Written out, not checkSupported(): the compiler must see that the
    // POSIX code below is unreachable on Windows.
    if (builtin.os.tag == .windows) client.runtimeFail("attach is not supported on Windows", .{});
    const outcome = try attach(gpa, id, settings, force);
    if (outcome.message) |msg| {
        plat.stderrWriteAll(msg) catch {};
        gpa.free(msg);
    }
    if (outcome.kind == .refused) return error.AttachRefused;
    std.process.exit(outcome.code);
}

/// How an attach ended. `message` (owned by the caller's allocator) says
/// so in a line for the user.
pub const Outcome = struct {
    kind: Kind,
    code: u8,
    message: ?[]u8 = null,

    pub const Kind = enum {
        /// The user detached; the session keeps running.
        detached,
        /// The session's program ended; `code` is its exit status.
        exited,
        /// The daemon refused the attach, for example because another
        /// client controls the session.
        refused,
        /// The stream broke, or a signal ended the attach.
        failed,
    };
};

/// Attach this terminal to session `id` until it detaches or the session
/// ends. The terminal is restored before this returns.
pub fn attach(gpa: std.mem.Allocator, id: []const u8, settings: Settings, force: bool) !Outcome {
    if (builtin.os.tag == .windows) return error.Unsupported;
    var conn = try client.connect(gpa);
    defer conn.deinit();
    const req = try protocol.stringifyRequest(gpa, .{ .cmd = "attach", .id = id, .mode = if (settings.write) "write" else "read", .force = force });
    defer gpa.free(req);
    try conn.sendLine(req);
    // The redraw usually arrives in the same read as the reply.
    var rest: []u8 = &.{};
    defer gpa.free(rest);
    {
        const split = try conn.recvLineSplit(gpa, 1 << 20);
        const line = split.line;
        rest = split.rest;
        defer gpa.free(line);
        const reply = std.json.parseFromSlice(struct { ok: bool, err: ?[]const u8 = null }, gpa, line, .{ .ignore_unknown_fields = true }) catch
            return error.BadReply;
        defer reply.deinit();
        if (!reply.value.ok) {
            return .{ .kind = .refused, .code = 1, .message = try std.fmt.allocPrint(gpa, "tuppet: {s}\n", .{reply.value.err orelse "attach failed"}) };
        }
    }
    return run(gpa, &conn, id, settings, rest);
}

pub const Settings = struct {
    write: bool = true,
    resize: bool = true,
    detach_key: u8 = 0x1d,
    /// Show the session on the alternate screen and stay there after it
    /// ends: the picker, which is on it already, draws itself again, and
    /// the shell's screen underneath is left alone.
    alt_screen: bool = false,
};

/// The attached session loop. The terminal is restored before it
/// returns, whatever ended the stream.
fn run(gpa: std.mem.Allocator, conn: *ipc.Conn, id: []const u8, settings: Settings, pending: []const u8) Outcome {
    const sock = conn.posix.socket.handle;
    var no_timeout: std.posix.timeval = .{ .sec = 0, .usec = 0 };
    _ = std.c.setsockopt(sock, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&no_timeout), @sizeOf(std.posix.timeval));

    const stdin_tty = std.c.isatty(0) == 1;
    const stdout_tty = std.c.isatty(1) == 1;
    // Handlers first: a signal must never leave the terminal raw.
    installHandlers();
    const saved = if (stdin_tty) std.posix.tcgetattr(0) catch null else null;
    if (saved) |orig| setRaw(orig);
    if (settings.alt_screen and stdout_tty) plat.stdoutWriteAll("\x1b[?1049h") catch {};
    var state: Loop = .{ .gpa = gpa, .sock = sock, .id = id, .settings = settings };
    state.filter.stay_on_screen = settings.alt_screen;
    defer state.buf.deinit(gpa);
    defer state.filter.deinit(gpa);
    state.buf.appendSlice(gpa, pending) catch {};
    const outcome = state.loop();
    if (saved) |orig| std.posix.tcsetattr(0, .FLUSH, orig) catch {};
    if (stdout_tty) {
        // Leave the session's state behind: the alternate screen, a soft
        // reset (scroll region, origin, insert, cursor and keypad modes,
        // attributes), autowrap, colors and cursor style, mouse and focus
        // reporting, bracketed paste, and keyboard protocols.
        const restore = "\x1b[!p\x1b[?7h\x1b[?25h\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07\x1b[0 q" ++
            "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?2004l\x1b[<99u\x1b[=0;1u\x1b[>4m";
        // Each screen has its own keyboard-protocol stack: clear the
        // alternate one before leaving it.
        plat.stdoutWriteAll(if (settings.alt_screen) restore else "\x1b[<99u\x1b[=0;1u\x1b[?1049l" ++ restore ++ "\r\n") catch {};
    }
    return outcome;
}

/// The terminal settings to put back if tuppet panics while the terminal
/// is raw.
var raw_saved: std.atomic.Value(?*const std.posix.termios) = .{ .raw = null };
var raw_saved_copy: std.posix.termios = undefined;

/// Put the terminal back after a panic: cooked mode, the main screen, a
/// visible cursor, and autowrap. Does nothing unless tuppet made it raw.
pub fn restoreAfterPanic() void {
    if (builtin.os.tag == .windows) return;
    const saved = raw_saved.load(.acquire) orelse return;
    plat.stdoutWriteAll("\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l\r\n") catch {};
    std.posix.tcsetattr(0, .FLUSH, saved.*) catch {};
}

pub fn setRaw(orig: std.posix.termios) void {
    raw_saved_copy = orig;
    raw_saved.store(&raw_saved_copy, .release);
    var raw = orig;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    // .NOW keeps keys typed ahead; leaving raw mode flushes instead, so
    // terminal replies that arrive late never reach the shell.
    std.posix.tcsetattr(0, .NOW, raw) catch {};
}

/// SA_RESTART: a resize during a blocked write must not cut a frame.
pub fn installHandlers() void {
    var winch: std.posix.Sigaction = .{ .handler = .{ .handler = onWinch }, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESTART };
    std.posix.sigaction(.WINCH, &winch, null);
    var quit: std.posix.Sigaction = .{ .handler = .{ .handler = onQuit }, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESTART };
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP, .QUIT }) |sig| std.posix.sigaction(sig, &quit, null);
}

const Loop = struct {
    gpa: std.mem.Allocator,
    sock: std.posix.fd_t,
    id: []const u8,
    settings: Settings,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// The user's terminal must not answer the program's queries.
    filter: attach_filter.Filter = .{},
    stdin_open: bool = true,

    fn loop(self: *Loop) Outcome {
        if (self.settings.resize) self.sendSize();
        if (self.drainFrames()) |outcome| return outcome;
        while (true) {
            const sig = got_quit.load(.acquire);
            if (sig != 0) {
                self.sendFrame("{\"detach\":true}");
                return self.done(.failed, 128 + sig, "tuppet: interrupted; detached from session {s}\n", .{self.id});
            }
            if (got_winch.swap(false, .acq_rel) and self.settings.resize) self.sendSize();
            var fds = [2]std.c.pollfd{
                .{ .fd = self.sock, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 },
            };
            const nfds: std.c.nfds_t = if (self.stdin_open) 2 else 1;
            if (std.c.poll(&fds, nfds, 200) < 0) continue;
            if (fds[0].revents != 0) {
                if (self.readSocket()) |outcome| return outcome;
            }
            if (nfds == 2 and fds[1].revents != 0) {
                if (self.readStdin()) |outcome| return outcome;
            }
        }
    }

    fn done(self: *Loop, kind: Outcome.Kind, code: u8, comptime fmt: []const u8, args: anytype) Outcome {
        return .{ .kind = kind, .code = code, .message = std.fmt.allocPrint(self.gpa, fmt, args) catch null };
    }

    fn readStdin(self: *Loop) ?Outcome {
        var chunk: [4096]u8 = undefined;
        const n = std.c.read(0, &chunk, chunk.len);
        if (n <= 0) {
            // Input ended (not a terminal): keep showing the session.
            self.stdin_open = false;
            return null;
        }
        const input = chunk[0..@intCast(n)];
        const cut = findDetachKey(input, self.settings.detach_key);
        // The detach key never reaches the child; read-only input is
        // ignored apart from it.
        if (self.settings.write) self.sendData(input[0 .. cut orelse input.len]);
        if (cut != null) {
            self.sendFrame("{\"detach\":true}");
            return self.done(.detached, 0, "tuppet: detached; session {s} keeps running ('tuppet attach {s}' to return)\n", .{ self.id, self.id });
        }
        return null;
    }

    fn readSocket(self: *Loop) ?Outcome {
        var chunk: [16384]u8 = undefined;
        const n = std.c.read(self.sock, &chunk, chunk.len);
        if (n <= 0) return self.done(.failed, 1, "tuppet: the daemon closed the attach stream\n", .{});
        self.buf.appendSlice(self.gpa, chunk[0..@intCast(n)]) catch return self.done(.failed, 1, "tuppet: out of memory\n", .{});
        return self.drainFrames();
    }

    fn drainFrames(self: *Loop) ?Outcome {
        while (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |end| {
            const outcome = self.handleFrame(self.buf.items[0..end]);
            self.buf.replaceRange(self.gpa, 0, end + 1, &.{}) catch {};
            if (outcome) |o| return o;
        }
        return null;
    }

    const Frame = struct {
        screen: ?[]const u8 = null,
        out: ?[]const u8 = null,
        exit: ?struct { code: ?i32 = null, signal: ?[]const u8 = null } = null,
        writer: ?[]const u8 = null,
        @"error": ?[]const u8 = null,
    };

    fn handleFrame(self: *Loop, line: []const u8) ?Outcome {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const frame = std.json.parseFromSliceLeaky(Frame, a, line, .{ .ignore_unknown_fields = true }) catch return null;
        if (frame.screen orelse frame.out) |b64| {
            const dec = std.base64.standard.Decoder;
            const len = dec.calcSizeForSlice(b64) catch return null;
            const bytes = a.alloc(u8, len) catch return null;
            dec.decode(bytes, b64) catch return null;
            const shown = self.filter.feed(self.gpa, bytes) catch return self.done(.failed, 1, "tuppet: out of memory\n", .{});
            defer self.gpa.free(shown);
            plat.stdoutWriteAll(shown) catch {};
        }
        if (frame.writer != null) {
            self.settings.write = false;
            self.settings.resize = false;
            plat.stderrWriteAll("\r\ntuppet: another client took over writing; this attach is now read-only\r\n") catch {};
        }
        if (frame.@"error") |msg| {
            if (std.mem.startsWith(u8, msg, "too slow")) return self.done(.failed, 1, "tuppet: {s}\n", .{msg});
            const note = std.fmt.allocPrint(a, "\r\ntuppet: {s}\r\n", .{msg}) catch return null;
            plat.stderrWriteAll(note) catch {};
        }
        if (frame.exit) |exit| {
            if (exit.code) |code| return self.done(.exited, @intCast(@as(u32, @bitCast(code)) & 0xff), "tuppet: session exited with code {d}\n", .{code});
            const sig = exit.signal orelse "unknown signal";
            return self.done(.exited, @truncate(128 + signalNumber(sig)), "tuppet: session killed by {s}\n", .{sig});
        }
        return null;
    }

    fn sendData(self: *Loop, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const enc = std.base64.standard.Encoder;
        const b64 = self.gpa.alloc(u8, enc.calcSize(bytes.len)) catch return;
        defer self.gpa.free(b64);
        _ = enc.encode(b64, bytes);
        const line = std.fmt.allocPrint(self.gpa, "{{\"data\":\"{s}\"}}", .{b64}) catch return;
        defer self.gpa.free(line);
        self.sendFrame(line);
    }

    fn sendSize(self: *Loop) void {
        const size = terminalSize() orelse return;
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"resize\":{{\"cols\":{d},\"rows\":{d}}}}}", .{ size[0], size[1] }) catch return;
        self.sendFrame(line);
    }

    fn sendFrame(self: *Loop, line: []const u8) void {
        var conn: ipc.Conn = .{ .posix = .{ .socket = .{ .handle = self.sock, .address = undefined } } };
        conn.sendLine(line) catch {};
    }
};

/// Where the detach key starts in a chunk of terminal input. Besides its
/// plain byte, a control key is also recognized in the encodings a
/// terminal uses once the session enables the kitty keyboard protocol
/// (CSI code;mods u) or modifyOtherKeys (CSI 27;mods;code ~).
fn findDetachKey(input: []const u8, key: u8) ?usize {
    for (input, 0..) |b, i| {
        if (b == key) return i;
        if (b == 0x1b and key < 0x20 and isCtrlSequence(input[i + 1 ..], key)) return i;
    }
    return null;
}

fn isCtrlSequence(seq: []const u8, key: u8) bool {
    if (seq.len < 2 or seq[0] != '[') return false;
    var params: [3]u32 = .{ 0, 0, 0 };
    var count: usize = 0;
    var sub = false; // inside a ':' sub-parameter
    var event: u32 = 1;
    for (seq[1..]) |c| switch (c) {
        '0'...'9' => {
            if (sub) {
                // The modifier's sub-parameter is the event type.
                if (count == 1) event = c - '0';
            } else if (params[count] > 1000) {
                return false;
            } else {
                params[count] = params[count] * 10 + (c - '0');
            }
        },
        ':' => sub = true,
        ';' => {
            count += 1;
            sub = false;
            if (count >= params.len) return false;
        },
        'u', '~' => {
            const code, const mods = if (c == 'u')
                .{ params[0], params[1] }
            else if (params[0] == 27 and count == 2)
                .{ params[2], params[1] }
            else
                return false;
            // Ctrl alone, ignoring Caps Lock and Num Lock; not a release.
            if (mods == 0 or (mods - 1) & ~@as(u32, 64 | 128) != 4 or event == 3) return false;
            return code < 0x80 and controlByte(@intCast(code)) == key;
        },
        else => return false,
    };
    return false;
}

test "detach key is found as a byte and in kitty and modifyOtherKeys form" {
    try std.testing.expectEqual(@as(?usize, 2), findDetachKey("ab\x1dc", 0x1d));
    try std.testing.expectEqual(@as(?usize, 1), findDetachKey("a\x1b[93;5u", 0x1d));
    try std.testing.expectEqual(@as(?usize, 0), findDetachKey("\x1b[93;69:1u", 0x1d));
    try std.testing.expectEqual(@as(?usize, 0), findDetachKey("\x1b[27;5;93~", 0x1d));
    try std.testing.expectEqual(@as(?usize, 0), findDetachKey("\x1b[120;5u", 0x18));
    try std.testing.expectEqual(@as(?usize, null), findDetachKey("\x1b[93;5:3u\x1b[93;7u\x1b[91;5u\x1b[A", 0x1d));
}

fn signalNumber(name: []const u8) u8 {
    if (!std.mem.startsWith(u8, name, "SIG")) return 0;
    if (builtin.os.tag != .windows) {
        if (std.meta.stringToEnum(std.posix.SIG, name[3..])) |sig| return @intCast(@intFromEnum(sig));
    }
    return std.fmt.parseInt(u8, name[3..], 10) catch 0;
}
