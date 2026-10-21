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
const names = @import("names.zig");
const words = @import("words.zig");
const status = @import("status.zig");
const store = @import("store.zig");
const config_mod = @import("config.zig");
const limits = @import("limits.zig");

const usage = "usage: tuppet attach [<session> | -] [-r] [-f] [-k KEY] [--no-resize]";

/// Set from signal handlers; the main loop acts on them.
pub var got_winch: std.atomic.Value(bool) = .{ .raw = false };
pub var got_quit: std.atomic.Value(u8) = .{ .raw = 0 };

fn onWinch(_: std.posix.SIG) callconv(.c) void {
    got_winch.store(true, .release);
}

fn onQuit(sig: std.posix.SIG) callconv(.c) void {
    got_quit.store(@intCast(@backingInt(sig)), .release);
}

/// Ctrl-], unless -k, TUPPET_DETACH_KEY, or the config file says
/// otherwise.
pub const default_detach_key: u8 = 0x1d;

pub fn cmdAttach(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var ref: ?[]const u8 = null;
    var i: usize = 0;
    var read_only = false;
    var force = false;
    var resize = true;
    var key_flag: ?u8 = null;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (client.isOpt(a, "--read-only", "-r")) {
            read_only = true;
        } else if (client.isOpt(a, "--force", "-f")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--no-resize")) {
            resize = false;
        } else if (client.isOpt(a, "--detach-key", "-k")) {
            const spec = try client.optValue(args, &i);
            key_flag = config_mod.parseDetachKey(spec) orelse
                return client.cliFail("invalid detach key '{s}' (use ^X, <C-x>, or one character)", .{spec});
        } else if (std.mem.eql(u8, a, "-") or !std.mem.startsWith(u8, a, "-")) {
            if (ref != null) return client.cliFail("attach takes one session (got '{s}' and '{s}')", .{ ref.?, a });
            ref = a;
        } else {
            return client.unknownOption(a, usage);
        }
    }
    if (read_only and force) return client.cliFail("--force takes over writing and cannot be combined with --read-only", .{});
    const defaults = try settingsFor(gpa, key_flag);
    const given = ref orelse {
        if (read_only or force) return client.cliFail("{s} needs a session: tuppet attach <session> {s}", .{ if (read_only) "--read-only" else "--force", if (read_only) "-r" else "-f" });
        return pick(gpa, .{ .detach_key = defaults.detach_key, .resize = resize, .bell = defaults.bell });
    };
    if (!read_only) try checkWriterTerminal("attach");
    var id_buf: [24]u8 = undefined;
    const target = if (std.mem.eql(u8, given, "-")) blk: {
        const id = store.lastDetached(gpa) orelse
            client.runtimeFail("no session to return to: none was detached from since the machine started", .{});
        break :blk std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
    } else given;
    if (names.refError(target)) |why| return client.cliFail("invalid session '{s}': {s}", .{ target, why });
    // In a terminal, a read-only attach is the picker's viewer for that
    // one session: it fits the session to this terminal and labels the
    // crop.
    if (builtin.os.tag != .windows and read_only and std.c.isatty(0) == 1 and std.c.isatty(1) == 1) {
        const id = try client.resolveOne(gpa, target);
        if (try selfSession(gpa) == id) client.runtimeFail("session {d} is this terminal; showing it here would feed its screen back into itself", .{id});
        std.process.exit(try picker.run(gpa, .{ .detach_key = defaults.detach_key, .bell = defaults.bell, .only = id }));
    }
    var settings = defaults;
    settings.write = !read_only;
    settings.resize = resize and !read_only;
    warnNested(settings.detach_key);
    try attachSession(gpa, target, settings, force, null);
}

/// Attach settings from the environment and the config file: the detach
/// key from `flag`, else TUPPET_DETACH_KEY, else [attach] detach_key, else
/// Ctrl-]; and whether to ring the bell for other sessions.
pub fn settingsFor(gpa: std.mem.Allocator, flag: ?u8) !Settings {
    var diag: config_mod.Diagnostic = .{};
    var config = config_mod.load(gpa, &diag) catch |err| switch (err) {
        error.BadConfig => client.runtimeFail("{s}", .{diag.message}),
        else => return err,
    };
    defer config.deinit();
    var key = flag orelse config.detach_key orelse default_detach_key;
    if (flag == null) if (std.c.getenv("TUPPET_DETACH_KEY")) |env| {
        const value = std.mem.span(env);
        if (value.len > 0) key = config_mod.parseDetachKey(value) orelse
            return client.cliFail("invalid TUPPET_DETACH_KEY '{s}' (use ^X, <C-x>, or one character)", .{value});
    };
    return .{ .detach_key = key, .bell = config.bell };
}

/// The session this terminal runs in, of whichever daemon.
pub fn nestedSession() ?u64 {
    const env = std.c.getenv("TUPPET_SESSION") orelse return null;
    return protocol.parseDecimal(u64, std.mem.span(env));
}

/// The session this terminal runs in, when it is one of the daemon this
/// client talks to: another daemon's sessions share only the ids.
pub fn selfSession(gpa: std.mem.Allocator) !?u64 {
    const id = nestedSession() orelse return null;
    // Sessions of daemons before TUPPET_SESSION_SOCKET have only the id.
    const socket = std.c.getenv("TUPPET_SESSION_SOCKET") orelse return id;
    const mine = try client.daemonEndpoint(gpa);
    defer gpa.free(mine);
    return if (std.mem.eql(u8, std.mem.span(socket), mine)) id else null;
}

/// Inside a session, an attach around this terminal sees the detach key
/// first; say so once, when it is the default.
pub fn warnNested(detach_key: u8) void {
    const id = nestedSession() orelse return;
    if (detach_key != default_detach_key) return;
    var buf: [200]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "tuppet: this terminal is tuppet session {d}; an attach around it takes Ctrl-] first (-k or TUPPET_DETACH_KEY sets another key)\n", .{id}) catch return;
    plat.stderrWriteAll(msg) catch {};
}

/// `tuppet attach` without an id: the session picker in a terminal; else
/// the sessions to choose from.
fn pick(gpa: std.mem.Allocator, opts: picker.Options) !void {
    // Written out, not checkSupported(): the compiler must see that the
    // POSIX code below is unreachable on Windows.
    if (builtin.os.tag == .windows) client.runtimeFail("attach is not supported on Windows", .{});
    if (std.c.isatty(0) == 1 and std.c.isatty(1) == 1) std.process.exit(try picker.run(gpa, opts));
    const reply = try client.listSessions(gpa);
    defer reply.deinit();
    var msg: std.Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    try msg.writer.writeAll("tuppet: attach needs a session outside a terminal");
    const sessions = reply.parsed.value.sessions;
    if (sessions.len > 0) try msg.writer.writeAll("; sessions:");
    for (sessions) |s| {
        var state_buf: [32]u8 = undefined;
        var cmd_buf: [512]u8 = undefined;
        try msg.writer.print("\n  {d}  {s}  {s}  {s}", .{ s.id, s.name orelse "-", words.stateWord(&state_buf, s), words.commandText(&cmd_buf, s.argv) });
    }
    try msg.writer.writeAll("\nrun 'tuppet help attach' for usage\n");
    plat.stderrWriteAll(msg.written()) catch {};
    return error.UsageError;
}

/// Fail early where attach cannot work.
pub fn checkSupported() void {
    if (builtin.os.tag == .windows) client.runtimeFail("attach is not supported on Windows", .{});
}

/// A writer types into the session from this terminal and draws it
/// there: outside a terminal (a script, an agent's pipe) that is a usage
/// error.
pub fn checkWriterTerminal(what: []const u8) error{UsageError}!void {
    if (builtin.os.tag == .windows) return;
    if (std.c.isatty(0) == 1 and std.c.isatty(1) == 1) return;
    return client.cliFail("{s} needs a terminal for its input and output; from a script, read the screen with 'tuppet view', wait for it with 'tuppet wait', follow it with 'tuppet events', or stream its output with 'tuppet attach -r'", .{what});
}

/// This terminal's size, when standard output is one.
pub fn terminalSize() ?[2]u16 {
    if (builtin.os.tag == .windows) return null;
    var ws: std.posix.winsize = undefined;
    if (std.c.ioctl(1, std.c.T.IOCGWINSZ, &ws) != 0 or ws.col == 0 or ws.row == 0) return null;
    return .{ @min(ws.col, limits.max_side), @min(ws.row, limits.max_side) };
}

/// Attach this terminal to the session `ref` picks until it detaches or
/// the session ends, then exit with the matching code. `refused_hint`
/// follows the daemon's message when it refuses the attach.
pub fn attachSession(gpa: std.mem.Allocator, ref: []const u8, settings: Settings, force: bool, refused_hint: ?[]const u8) !noreturn {
    // Written out, not checkSupported(): the compiler must see that the
    // POSIX code below is unreachable on Windows.
    if (builtin.os.tag == .windows) client.runtimeFail("attach is not supported on Windows", .{});
    const outcome = try attach(gpa, ref, settings, force);
    if (outcome.message) |msg| {
        plat.stderrWriteAll(msg) catch {};
        gpa.free(msg);
    }
    if (outcome.kind == .refused) if (refused_hint) |hint| plat.stderrWriteAll(hint) catch {};
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
        /// Another client took over writing, with `end_on_takeover`.
        taken,
        /// The daemon refused the attach, for example because another
        /// client controls the session.
        refused,
        /// The stream broke, or a signal ended the attach.
        failed,
    };
};

/// Attach this terminal to the session `ref` picks until it detaches or
/// the session ends. The terminal is restored before this returns. A
/// writer acks what it showed at the start, the detach, and the exit.
pub fn attach(gpa: std.mem.Allocator, ref: []const u8, settings: Settings, force: bool) !Outcome {
    if (builtin.os.tag == .windows) return error.Unsupported;
    // Checked before the attach: a forced one would take the writer role
    // from the terminal this one runs in.
    if (try selfSession(gpa)) |self| if (try picks(gpa, ref, self)) {
        return .{ .kind = .refused, .code = client.exit_code.failed, .message = try std.fmt.allocPrint(gpa, "tuppet: session {d} is this terminal; attaching to it would feed its screen back into itself\n", .{self}) };
    };
    var label_buf: [64]u8 = undefined;
    // The first redraw comes at this terminal's size, not the session's.
    var size = if (settings.write and settings.resize) terminalSize() else null;
    var conn: ipc.Conn = undefined;
    // The redraw usually arrives in the same read as the reply.
    var rest: []u8 = &.{};
    defer gpa.free(rest);
    var session_size: [2]u16 = undefined;
    const id = while (true) {
        conn = try client.connect(gpa);
        errdefer conn.deinit();
        const req = try protocol.stringifyRequest(gpa, protocol.AttachReq{
            .session = ref,
            .mode = if (settings.write) .write else .read,
            .force = force,
            .label = if (settings.write) terminalLabel(&label_buf) else null,
            .cols = if (size) |sz| sz[0] else null,
            .rows = if (size) |sz| sz[1] else null,
        });
        defer gpa.free(req);
        try conn.sendLine(req);
        const split = try conn.recvLineSplit(gpa, 1 << 20);
        const line = split.line;
        rest = split.rest;
        defer gpa.free(line);
        const reply = std.json.parseFromSlice(struct { ok: bool, status: ?protocol.Status = null }, gpa, line, .{ .ignore_unknown_fields = true }) catch
            return error.BadReply;
        defer reply.deinit();
        if (!reply.value.ok) {
            const parsed = std.json.parseFromSlice(protocol.ErrorReply, gpa, line, .{ .ignore_unknown_fields = true }) catch return error.BadReply;
            defer parsed.deinit();
            // A daemon from before attach requests carried a size refuses
            // it: attach without, and send the size in a frame after.
            if (size != null and std.mem.eql(u8, parsed.value.code, @tagName(protocol.Code.bad_request))) {
                size = null;
                conn.deinit();
                gpa.free(rest);
                rest = &.{};
                continue;
            }
            const message = try std.fmt.allocPrint(gpa, "tuppet: {s}\n", .{parsed.value.err});
            conn.deinit();
            return .{ .kind = .refused, .code = client.exitFor(parsed.value.code), .message = message };
        }
        const st = reply.value.status orelse return error.BadReply;
        if (settings.write) ack(gpa, st.id, status.shownOf(st));
        session_size = .{ st.cols, st.rows };
        break st.id;
    };
    defer conn.deinit();
    var id_buf: [20]u8 = undefined;
    const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
    var final: ?status.Shown = null;
    const outcome = run(gpa, &conn, id, id_text, settings, size, session_size, rest, &final);
    switch (outcome.kind) {
        .detached, .taken => store.setLastDetached(gpa, id),
        else => {},
    }
    if (settings.write) switch (outcome.kind) {
        .exited => ack(gpa, id, final),
        .detached, .taken => ack(gpa, id, null),
        .failed => if (outcome.code > 128) ack(gpa, id, null),
        .refused => {},
    };
    return outcome;
}

/// Whether `ref` picks session `id` alone.
fn picks(gpa: std.mem.Allocator, ref: []const u8, id: u64) !bool {
    if (names.kind(ref) == .id) return protocol.parseDecimal(u64, ref) == id;
    const listed = try client.request(gpa, protocol.ListReq{ .sessions = &.{ref} }, protocol.ListResp);
    defer listed.deinit();
    const found = listed.parsed.value.sessions;
    return found.len == 1 and found[0].id == id;
}

/// Tell the daemon what this terminal showed of session `id`: `shown`,
/// or, without it, the session as it is now, all of which a writer has
/// had on its screen.
fn ack(gpa: std.mem.Allocator, id: u64, shown: ?status.Shown) void {
    var id_buf: [20]u8 = undefined;
    const ref = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
    const values = shown orelse blk: {
        const listed = client.request(gpa, protocol.ListReq{ .sessions = &.{ref} }, protocol.ListResp) catch return;
        defer listed.deinit();
        const found = listed.parsed.value.sessions;
        if (found.len != 1) return;
        break :blk status.shownOf(found[0]);
    };
    const reply = client.request(gpa, protocol.AckReq{ .sessions = &.{ref}, .shown = values }, protocol.ResultsResp) catch return;
    reply.deinit();
}

extern "c" fn ttyname(fd: c_int) ?[*:0]const u8;

/// The terminal this attach runs in, such as "pts/3", as its writer label.
fn terminalLabel(buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const name = ttyname(0) orelse return null;
    const path = std.mem.span(name);
    const short = if (std.mem.startsWith(u8, path, "/dev/")) path["/dev/".len..] else path;
    return std.fmt.bufPrint(buf, "{s}", .{short[0..@min(short.len, buf.len)]}) catch null;
}

pub const Settings = struct {
    write: bool = true,
    resize: bool = true,
    detach_key: u8 = default_detach_key,
    /// Show the session on the alternate screen and stay there after it
    /// ends: the picker, which is on it already, draws itself again, and
    /// the shell's screen underneath is left alone.
    alt_screen: bool = false,
    /// Ring this terminal's bell once when another session comes to need
    /// attention.
    bell: bool = true,
    /// End the attach when another client takes over writing, instead of
    /// going on read-only (the picker shows the session in its viewer).
    end_on_takeover: bool = false,
};

/// How long the session's screen waits after a takeover notice, so it
/// can be read before the fresh screen replaces it.
const notice_pause_ns: i64 = 1500 * std.time.ns_per_ms;

/// The attached session loop. The terminal is restored before it
/// returns, whatever ended the stream. `final` gets what the exit frame
/// showed.
fn run(gpa: std.mem.Allocator, conn: *ipc.Conn, id: u64, id_text: []const u8, settings: Settings, size: ?[2]u16, session_size: [2]u16, pending: []const u8, final: *?status.Shown) Outcome {
    const sock = conn.posix.socket.handle;
    var no_timeout: std.posix.timeval = .{ .sec = 0, .usec = 0 };
    _ = std.c.setsockopt(sock, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&no_timeout), @sizeOf(std.posix.timeval));

    const stdin_tty = std.c.isatty(0) == 1;
    const stdout_tty = std.c.isatty(1) == 1;
    // Handlers first: a signal must never leave the terminal raw.
    installHandlers();
    const saved = if (stdin_tty) plat.tcgetattr(0) catch null else null;
    if (saved) |orig| setRaw(orig);
    if (settings.alt_screen and stdout_tty) plat.stdoutWriteAll("\x1b[?1049h") catch {};
    var state: Loop = .{ .gpa = gpa, .sock = sock, .id = id, .id_text = id_text, .settings = settings, .sent_size = size };
    state.filter.stay_on_screen = settings.alt_screen;
    // On the normal screen, the session's first screen replaces what the
    // terminal shows: that goes into its history instead of away.
    if (!settings.alt_screen and stdout_tty) if (terminalSize()) |now| {
        state.filter.history_rows = now[1];
    };
    defer state.buf.deinit(gpa);
    defer state.filter.deinit(gpa);
    state.marks = if (settings.bell and stdout_tty) Marks.open(gpa) else null;
    defer if (state.marks) |*m| m.deinit(gpa);
    state.buf.appendSlice(gpa, pending) catch {};
    // Without resizing, a session larger than this terminal does not fit;
    // its screen waits a moment so the notice can be read.
    if (settings.write and !settings.resize and stdout_tty and std.c.isatty(2) == 1) if (terminalSize()) |now| if (session_size[0] > now[0] or session_size[1] > now[1]) {
        const note = std.fmt.allocPrint(gpa, "tuppet: session {s} ({d}x{d}) is larger than this terminal ({d}x{d})\r\n", .{ id_text, session_size[0], session_size[1], now[0], now[1] }) catch null;
        if (note) |text| {
            defer gpa.free(text);
            plat.stderrWriteAll(text) catch {};
            state.paused_until = io_mod.nowNanos() + notice_pause_ns;
        }
    };
    const outcome = state.loop();
    final.* = state.final;
    if (saved) |orig| plat.tcsetattr(0, .FLUSH, orig) catch {};
    forgetRaw();
    if (stdout_tty) {
        // Leave the session's state behind: the alternate screen, a soft
        // reset (scroll region, origin, insert, cursor and keypad modes,
        // attributes), autowrap, colors and cursor style, mouse and focus
        // reporting, bracketed paste, and keyboard protocols. Each screen
        // has its own keyboard-protocol stack: clear the alternate one
        // before leaving it. On the normal screen the session's content
        // stays, and what follows starts on a line below it.
        const tail = if (settings.alt_screen)
            reset_modes
        else if (state.filter.alt_screen)
            "\x1b[<99u\x1b[=0;1u\x1b[?1049l" ++ reset_modes ++ "\r\n"
        else
            reset_modes ++ "\r\n";
        plat.stdoutWriteAll(tail) catch {};
    }
    return outcome;
}

/// The terminal settings to put back if tuppet panics or fails while the
/// terminal is raw.
var raw_saved: std.atomic.Value(?*const std.posix.termios) = .{ .raw = null };
var raw_saved_copy: std.posix.termios = undefined;

/// Modes a session or the picker may have set, as a terminal had them
/// before: mouse and focus reporting, bracketed paste, keyboard
/// protocols, synchronized output, autowrap, the cursor, colors.
const reset_modes = "\x1b[?2026l\x1b[0m\x1b[!p\x1b[?7h\x1b[?25h\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07\x1b[0 q" ++
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?2004l\x1b[<99u\x1b[=0;1u\x1b[>4m";

/// Put the terminal back after a panic or a failure that ends tuppet
/// while the picker or an attach holds it: cooked mode, the main screen,
/// and the modes above. Does nothing unless tuppet made it raw.
pub fn restoreTerminal() void {
    if (builtin.os.tag == .windows) return;
    const saved = raw_saved.swap(null, .acq_rel) orelse return;
    plat.stdoutWriteAll(reset_modes ++ "\x1b[<99u\x1b[=0;1u\x1b[?1049l\r\n") catch {};
    plat.tcsetattr(0, .FLUSH, saved.*) catch {};
}

/// The terminal is cooked again: nothing to restore.
pub fn forgetRaw() void {
    raw_saved.store(null, .release);
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
    raw.cc[@backingInt(std.posix.V.MIN)] = 1;
    raw.cc[@backingInt(std.posix.V.TIME)] = 0;
    // .NOW keeps keys typed ahead; leaving raw mode flushes instead, so
    // terminal replies that arrive late never reach the shell.
    plat.tcsetattr(0, .NOW, raw) catch {};
}

/// SA_RESTART: a resize during a blocked write must not cut a frame.
pub fn installHandlers() void {
    var winch: std.posix.Sigaction = .{ .handler = .{ .handler = onWinch }, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESTART };
    std.posix.sigaction(.WINCH, &winch, null);
    var quit: std.posix.Sigaction = .{ .handler = .{ .handler = onQuit }, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESTART };
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP, .QUIT }) |sig| std.posix.sigaction(sig, &quit, null);
}

/// Follows what needs attention through an events stream, to ring this
/// terminal's bell once each time a session other than the attached one
/// comes to need it.
const Marks = struct {
    conn: ipc.Conn,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// The sessions that need attention now.
    marked: std.AutoHashMapUnmanaged(u64, void) = .empty,
    synced: bool = false,

    fn open(gpa: std.mem.Allocator) ?Marks {
        var conn = client.connect(gpa) catch return null;
        const req = protocol.stringifyRequest(gpa, protocol.EventsReq{}) catch {
            conn.deinit();
            return null;
        };
        defer gpa.free(req);
        conn.sendLine(req) catch {
            conn.deinit();
            return null;
        };
        var no_timeout: std.posix.timeval = .{ .sec = 0, .usec = 0 };
        _ = std.c.setsockopt(conn.posix.socket.handle, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&no_timeout), @sizeOf(std.posix.timeval));
        return .{ .conn = conn };
    }

    fn deinit(m: *Marks, gpa: std.mem.Allocator) void {
        m.conn.deinit();
        m.buf.deinit(gpa);
        m.marked.deinit(gpa);
    }

    fn fd(m: *Marks) std.posix.fd_t {
        return m.conn.posix.socket.handle;
    }

    /// Read what the daemon sent: whether the bell is due, or null once
    /// the stream is over.
    fn pump(m: *Marks, gpa: std.mem.Allocator, own: u64) ?bool {
        var chunk: [16384]u8 = undefined;
        const n = std.c.read(m.fd(), &chunk, chunk.len);
        if (n <= 0) return null;
        m.buf.appendSlice(gpa, chunk[0..@intCast(n)]) catch return null;
        var ring = false;
        while (std.mem.indexOfScalar(u8, m.buf.items, '\n')) |end| {
            defer m.buf.replaceRange(gpa, 0, end + 1, &.{}) catch {};
            ring = (m.frame(gpa, m.buf.items[0..end], own) orelse return null) or ring;
        }
        return ring;
    }

    fn frame(m: *Marks, gpa: std.mem.Allocator, line: []const u8, own: u64) ?bool {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const Frame = struct { ok: ?bool = null, type: []const u8 = "", id: ?u64 = null, status: ?protocol.Status = null };
        const f = std.json.parseFromSliceLeaky(Frame, arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch return false;
        if (f.ok == false or std.mem.eql(u8, f.type, "end")) return null;
        if (std.mem.eql(u8, f.type, "synced")) {
            m.synced = true;
        } else if (std.mem.eql(u8, f.type, "resync")) {
            m.synced = false;
            m.marked.clearRetainingCapacity();
        } else if (std.mem.eql(u8, f.type, "removed") or std.mem.eql(u8, f.type, "left")) {
            if (f.id) |id| _ = m.marked.remove(id);
        } else if (f.id) |id| if (f.status) |st| {
            const now = words.needsAttention(st);
            const was = m.marked.contains(id);
            if (now) m.marked.put(gpa, id, {}) catch {} else _ = m.marked.remove(id);
            return m.synced and now and !was and id != own;
        };
        return false;
    }
};

const Loop = struct {
    gpa: std.mem.Allocator,
    sock: std.posix.fd_t,
    id: u64,
    id_text: []const u8,
    settings: Settings,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// The user's terminal must not answer the program's queries.
    filter: attach_filter.Filter = .{},
    stdin_open: bool = true,
    marks: ?Marks = null,
    /// A bell waits for the session's output to finish its sequence.
    bell_due: bool = false,
    /// Session output waits until then, after a notice.
    paused_until: i64 = 0,
    final: ?status.Shown = null,
    /// The size last sent to the daemon, with the attach request or after.
    sent_size: ?[2]u16 = null,
    /// The end of the last input read, held back because it may start an
    /// encoded detach key that the next read completes.
    carry: [max_carry]u8 = undefined,
    carry_len: usize = 0,
    carry_since: i64 = 0,

    const max_carry = 32;
    /// A held-back end goes to the program when nothing completes it in
    /// this time.
    const carry_wait_ns: i64 = 50 * std.time.ns_per_ms;

    fn loop(self: *Loop) Outcome {
        // The terminal may have changed size since the attach request.
        if (self.settings.resize) self.sendSize();
        if (self.drainFrames()) |outcome| return outcome;
        while (true) {
            const sig = got_quit.load(.acquire);
            if (sig != 0) {
                self.sendFrame("{\"detach\":true}");
                return self.done(.failed, 128 + sig, "tuppet: interrupted; detached from session {s}\n", .{self.id_text});
            }
            if (got_winch.swap(false, .acq_rel) and self.settings.resize) self.sendSize();
            const marks_fd: std.posix.fd_t = if (self.marks) |*m| m.fd() else -1;
            var fds = [3]std.c.pollfd{
                .{ .fd = self.sock, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = if (self.stdin_open) 0 else -1, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = marks_fd, .events = std.c.POLL.IN, .revents = 0 },
            };
            const now = io_mod.nowNanos();
            const paused = now < self.paused_until;
            var timeout: c_int = if (paused) @intCast(@min(200, @divTrunc(self.paused_until - now, std.time.ns_per_ms) + 1)) else 200;
            if (self.carry_len > 0) timeout = @min(timeout, @as(c_int, @intCast(@max(0, @divTrunc(self.carry_since + carry_wait_ns - now, std.time.ns_per_ms) + 1))));
            if (std.c.poll(&fds, fds.len, timeout) < 0) continue;
            if (fds[1].revents == 0 and self.carry_len > 0 and io_mod.nowNanos() - self.carry_since >= carry_wait_ns) {
                if (self.settings.write) self.sendData(self.carry[0..self.carry_len]);
                self.carry_len = 0;
            }
            if (fds[0].revents != 0) {
                if (self.readSocket()) |outcome| return outcome;
            } else if (self.paused_until != 0 and io_mod.nowNanos() >= self.paused_until) {
                // The pause is over, also when other events took the
                // pass it ended in: show the frames it held back.
                self.paused_until = 0;
                if (self.drainFrames()) |outcome| return outcome;
            }
            if (fds[1].revents != 0) {
                if (self.readStdin()) |outcome| return outcome;
            }
            if (fds[2].revents != 0) if (self.marks) |*m| {
                if (m.pump(self.gpa, self.id)) |due| {
                    if (due) self.ring();
                } else {
                    m.deinit(self.gpa);
                    self.marks = null;
                }
            };
        }
    }

    fn done(self: *Loop, kind: Outcome.Kind, code: u8, comptime fmt: []const u8, args: anytype) Outcome {
        return .{ .kind = kind, .code = code, .message = std.fmt.allocPrint(self.gpa, fmt, args) catch null };
    }

    /// Ring the bell between the session's escape sequences, never inside
    /// one (a BEL ends an OSC string).
    fn ring(self: *Loop) void {
        if (!self.filter.idle()) {
            self.bell_due = true;
            return;
        }
        self.bell_due = false;
        plat.stdoutWriteAll("\x07") catch {};
    }

    fn readStdin(self: *Loop) ?Outcome {
        var chunk: [max_carry + 4096]u8 = undefined;
        @memcpy(chunk[0..self.carry_len], self.carry[0..self.carry_len]);
        const n = std.c.read(0, chunk[self.carry_len..].ptr, chunk.len - self.carry_len);
        if (n <= 0) {
            // Input ended (not a terminal): keep showing the session.
            self.stdin_open = false;
            if (self.settings.write) self.sendData(chunk[0..self.carry_len]);
            self.carry_len = 0;
            return null;
        }
        const input = chunk[0 .. self.carry_len + @as(usize, @intCast(n))];
        self.carry_len = 0;
        const cut = findDetachKey(input, self.settings.detach_key);
        // An encoded detach key cut off at the end of this read waits
        // for the next one.
        const held = if (cut == null) detachKeyStart(input, self.settings.detach_key) else null;
        // The detach key never reaches the child; read-only input is
        // ignored apart from it.
        if (self.settings.write) self.sendData(input[0 .. cut orelse held orelse input.len]);
        if (held) |at| {
            self.carry_len = input.len - at;
            @memcpy(self.carry[0..self.carry_len], input[at..]);
            self.carry_since = io_mod.nowNanos();
        }
        if (cut != null) {
            self.sendFrame("{\"detach\":true}");
            return self.done(.detached, 0, "tuppet: detached; session {s} keeps running ('tuppet attach {s}' to return)\n", .{ self.id_text, self.id_text });
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
            if (io_mod.nowNanos() < self.paused_until) return null;
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
        status: ?protocol.Status = null,
        writer: ?[]const u8 = null,
        hold: ?bool = null,
        @"error": ?struct { code: []const u8 = "", err: []const u8 = "" } = null,
        end: ?struct { reason: []const u8 = "" } = null,
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
            if (self.bell_due) self.ring();
        }
        if (frame.writer != null) {
            self.settings.write = false;
            self.settings.resize = false;
            if (self.settings.end_on_takeover) {
                self.sendFrame("{\"detach\":true}");
                return .{ .kind = .taken, .code = 0 };
            }
            // The daemon follows with a fresh screen; it waits a moment
            // so the notice can be read.
            plat.stderrWriteAll("\r\ntuppet: another client took over writing; this attach is now read-only\r\n") catch {};
            self.paused_until = io_mod.nowNanos() + notice_pause_ns;
        }
        // What this terminal types waits for an input batch to finish; a
        // fresh screen follows the hold.
        if (frame.hold == true) plat.stderrWriteAll("\r\ntuppet: held: automation is typing\r\n") catch {};
        if (frame.@"error") |e| {
            const note = std.fmt.allocPrint(a, "\r\ntuppet: {s}\r\n", .{e.err}) catch return null;
            plat.stderrWriteAll(note) catch {};
        }
        if (frame.end) |end| {
            if (std.mem.eql(u8, end.reason, "too_slow")) return self.done(.failed, 1, "tuppet: this attach fell too far behind the session's output; attach again\n", .{});
            if (!std.mem.eql(u8, end.reason, "exited")) return self.done(.failed, 1, "tuppet: the daemon ended the attach ({s})\n", .{end.reason});
        }
        if (frame.exit) |exit| {
            if (frame.status) |st| self.final = status.shownOf(st);
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

    /// Send this terminal's size, unless the daemon has it already.
    fn sendSize(self: *Loop) void {
        const size = terminalSize() orelse return;
        if (self.sent_size) |sent| if (std.mem.eql(u16, &sent, &size)) return;
        self.sent_size = size;
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

/// Where an unfinished CSI sequence that may still encode the detach key
/// starts at the end of `input`: ESC [ and parameters, short of the
/// final byte. A lone ESC does not count; it is the Escape key as often.
fn detachKeyStart(input: []const u8, key: u8) ?usize {
    if (key >= 0x20) return null;
    const from = input.len -| Loop.max_carry;
    const at = std.mem.lastIndexOfScalar(u8, input[from..], 0x1b) orelse return null;
    const seq = input[from + at + 1 ..];
    if (seq.len == 0 or seq[0] != '[') return null;
    for (seq[1..]) |c| switch (c) {
        '0'...'9', ';', ':' => {},
        else => return null,
    };
    return from + at;
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
            return code < 0x80 and config_mod.controlByte(@intCast(code)) == key;
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

test "a detach key split across reads is held until it is complete" {
    try std.testing.expectEqual(@as(?usize, 1), detachKeyStart("a\x1b[93;", 0x1d));
    try std.testing.expectEqual(@as(?usize, 0), detachKeyStart("\x1b[", 0x1d));
    try std.testing.expectEqual(@as(?usize, null), detachKeyStart("a\x1b", 0x1d));
    try std.testing.expectEqual(@as(?usize, null), detachKeyStart("\x1b[93;5u", 0x1d));
    try std.testing.expectEqual(@as(?usize, null), detachKeyStart("\x1b[9", 'q'));
}

fn signalNumber(name: []const u8) u8 {
    if (!std.mem.startsWith(u8, name, "SIG")) return 0;
    if (builtin.os.tag != .windows) {
        if (std.meta.stringToEnum(std.posix.SIG, name[3..])) |sig| return @intCast(@backingInt(sig));
    }
    return std.fmt.parseInt(u8, name[3..], 10) catch 0;
}
