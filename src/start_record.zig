//! `tuppet start --record`: write a start block from a login done once by
//! hand. The session records a trace (the screen as it changes, and each
//! input) into a file in tuppet's private runtime directory that is
//! unlinked at once, so typed passwords never stay on disk; the steps
//! come from it after the person detaches.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const names = @import("names.zig");
const status = @import("status.zig");
const client = @import("client.zig");
const attach_client = @import("attach_client.zig");
const start = @import("start.zig");
const start_run = @import("start_run.zig");

const cliFail = client.cliFail;
const runtimeFail = client.runtimeFail;
const errPrint = start_run.errPrint;

pub fn record(gpa: std.mem.Allocator, id: []const u8, command: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (names.kind(id) == .pattern) return cliFail("--record needs an id, not a pattern ('{s}')", .{id});
    if (builtin.os.tag == .windows or std.c.isatty(0) != 1 or std.c.isatty(1) != 1)
        runtimeFail("--record needs a terminal: you log in by hand while it records", .{});
    const old = try start_run.loadText(a, false, true);
    if (old.path.len == 0) runtimeFail("no start file to write to (TUPPET_START is empty, or HOME is not set)", .{});
    if (hasId(&try start.parse(a, old.path, old.text), id))
        runtimeFail("{s} has a start block for '{s}' already: pick another id, or edit the file", .{ old.path, id });

    var sock_buf: [ipc.max_path_len:0]u8 = undefined;
    const sock = ipc.socketPath(&sock_buf) catch |err| runtimeFail("no private directory for the recording: {s}", .{@errorName(err)});
    const private = std.fs.path.dirname(sock) orelse runtimeFail("no private directory for the recording", .{});
    const trace_path = try std.fmt.allocPrintSentinel(a, "{s}/tuppet-record-{d}.trace", .{ private, std.c.getpid() }, 0);
    // Made here, new and only this user's, before the daemon writes keys
    // into it: never a file someone else put in its place.
    const trace_fd = std.c.open(trace_path, .{ .ACCMODE = .RDONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (trace_fd < 0) runtimeFail("cannot make the recording file {s}", .{trace_path});
    defer _ = std.c.close(trace_fd);
    var made = true;
    defer if (made) {
        _ = std.c.unlink(trace_path);
    };
    if (ipc.untrusted(trace_fd)) |why| runtimeFail("{s}: refused, because {s}", .{ trace_path, why });

    const shell: []const u8 = if (std.c.getenv("SHELL")) |sh| std.mem.span(sh) else "/bin/sh";
    const default_argv = [_][]const u8{if (shell.len > 0) shell else "/bin/sh"};
    const argv: []const []const u8 = if (command.len > 0) command else &default_argv;
    const cwd = try client.absolutePath(a, ".");
    const size = attach_client.terminalSize() orelse .{ client.default_cols, client.default_rows };
    const env = try client.currentEnv(a, true);

    var name: []const u8 = id;
    var n: u32 = 1;
    const session: u64 = while (true) {
        const reply = try client.request(gpa, protocol.RunReq{
            .name = name,
            .cols = size[0],
            .rows = size[1],
            .cwd = cwd,
            .env = env,
            .argv = argv,
            .record = .{ .path = trace_path, .format = .trace },
        }, protocol.StatusResp);
        defer reply.deinit();
        if (reply.parsed.value.ok) break client.replyStatus(reply.parsed.value.status).id;
        const failure = std.json.parseFromSliceLeaky(protocol.ErrorReply, a, reply.line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            _ = std.c.unlink(trace_path);
            runtimeFail("the daemon sent a malformed reply", .{});
        };
        if (!std.mem.eql(u8, failure.code, @tagName(protocol.Code.exists))) {
            _ = std.c.unlink(trace_path);
            runtimeFail("{f}", .{status.cleaned(failure.err)});
        }
        n += 1;
        name = try std.fmt.allocPrint(a, "{s}-{d}", .{ id, n });
    };
    const session_text = try std.fmt.allocPrint(a, "{d}", .{session});

    // Only this process can read it from here on.
    _ = std.c.unlink(trace_path);
    made = false;

    try errPrint("tuppet: recording session {s} ({s}): log in by hand, then press the detach key\n", .{ session_text, name });
    try attachChild(a, session_text);
    const stopped = client.request(gpa, protocol.RecordReq{ .session = session_text, .stop = true }, protocol.RecordResp) catch null;
    if (stopped) |s| s.deinit();
    const trace = try readAll(a, trace_fd);

    var lines = try draft(a, trace);
    if (stepCount(lines.items) == 0) {
        try errPrint("tuppet: nothing was typed; no block written\n", .{});
        return attachAgain(gpa, session_text);
    }
    const file = try start.parse(a, old.path, old.text);
    try useBlocks(a, &file, &lines);
    var block = try compose(a, id, command, cwd, lines.items);
    if (try validate(a, old, block)) |problem| block = try addCheck(a, block, problem);

    while (true) {
        try errPrint("\n{s}\n", .{block});
        const checks = std.mem.count(u8, block, "# CHECK:");
        const problem = if (checks == 0) try validate(a, old, block) else null;
        if (problem) |p| try errPrint("tuppet: {s}\n", .{p});
        const question = if (checks > 0)
            try std.fmt.allocPrint(a, "{d} line{s} marked CHECK: [e]dit the block, or [d]rop it? ", .{ checks, if (checks == 1) "" else "s" })
        else if (problem != null)
            "[e]dit the block, or [d]rop it? "
        else
            try std.fmt.allocPrint(a, "[a]ppend it to {s}, [e]dit it first, or [d]rop it? ", .{old.path});
        const answer = try start_run.askLine(a, question, true) orelse break;
        const word = std.mem.trim(u8, answer, " ");
        if (word.len == 0) continue;
        switch (std.ascii.toLower(word[0])) {
            'a' => if (checks == 0 and problem == null) {
                try append(a, block);
                try errPrint("tuppet: appended; 'tuppet start {s}' runs it\n", .{id});
                break;
            },
            'e' => block = try editBlock(a, private, block),
            'd' => break,
            else => {},
        }
    }
    attachAgain(gpa, session_text);
}

fn hasId(file: *const start.File, id: []const u8) bool {
    for (file.blocks) |b| switch (b.kind) {
        .start => for (b.names) |n| if (std.mem.eql(u8, n, id)) return true,
        .group => if (std.mem.eql(u8, b.names[0], id)) return true,
        .steps => {},
    };
    return false;
}

/// Run `tuppet attach` on the terminal until it ends.
fn attachChild(a: std.mem.Allocator, session: []const u8) !void {
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io_mod.io(), &exe_buf);
    const exe = try a.dupeSentinel(u8, exe_buf[0..exe_len], 0);
    const ref = try a.dupeSentinel(u8, session, 0);
    const argv = [_:null]?[*:0]const u8{ exe.ptr, "attach", ref.ptr };
    const pid = std.c.fork();
    if (pid < 0) runtimeFail("cannot start the attach", .{});
    if (pid == 0) {
        _ = std.c.execve(exe.ptr, &argv, std.c.environ);
        std.c._exit(127);
    }
    var st: c_int = 0;
    while (std.c.waitpid(pid, &st, 0) < 0) {}
}

fn attachAgain(gpa: std.mem.Allocator, session: []const u8) void {
    const reply = client.request(gpa, protocol.ListReq{ .sessions = &.{session} }, protocol.ListResp) catch return;
    defer reply.deinit();
    const running = reply.parsed.value.ok and reply.parsed.value.sessions.len == 1 and reply.parsed.value.sessions[0].state == .running;
    if (!running) return;
    const settings = attach_client.settingsFor(gpa, null) catch return;
    start_run.attachTo(gpa, session, settings);
}

fn readAll(a: std.mem.Allocator, fd: std.c.fd_t) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const got = std.c.read(fd, &buf, buf.len);
        if (got <= 0) break;
        try out.appendSlice(a, buf[0..@intCast(got)]);
    }
    return out.items;
}

// ---- from the trace to steps -----------------------------------------------

/// A line of the block: a keyword and its value, with notes that become
/// `# CHECK:` comments above it.
pub const Line = struct {
    keyword: []const u8,
    value: []const u8 = "",
    notes: []const []const u8 = &.{},
    /// A slow check's time, in seconds, written as expect(14s).
    timeout_s: ?u64 = null,
    /// A `fail` line under a check: the prompt the command was typed at,
    /// which coming back means the command did not get where it went.
    fail: []const u8 = "",
    /// The answer of the `when` above it, indented deeper.
    answer: bool = false,
    /// A plain comment above it, for what needs no checking.
    comment: []const u8 = "",
};

fn stepCount(lines: []const Line) usize {
    var n: usize = 0;
    for (lines) |l| if (!std.mem.eql(u8, l.keyword, "expect") and !std.mem.eql(u8, l.keyword, "when")) {
        n += 1;
    };
    return n;
}

const Frame = struct { t: f64, last: []const u8 };

const Drafter = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(Line) = .empty,
    screen: std.ArrayList([]const u8) = .empty,
    cols: usize = 0,
    started: bool = false,
    // The line being typed.
    typing: bool = false,
    keys: std.ArrayList(u8) = .empty,
    secret: bool = false,
    pasted: bool = false,
    /// Inputs of this line before the one with its Enter.
    chunks: usize = 0,
    prompt: []const u8 = "",
    prompt_row: ?usize = null,
    // After an Enter, until the next prompt.
    waiting: bool = false,
    enter_t: f64 = 0,
    command: []const u8 = "",
    frames: std.ArrayList(Frame) = .empty,
    notes: std.ArrayList([]const u8) = .empty,
    /// A line typed in one go with its Enter at an unchanged prompt: a
    /// command when its echo follows, else a password. Its place in
    /// `out`, and the prompt it was typed at.
    unsure: ?usize = null,
    unsure_prompt: []const u8 = "",

    fn last(d: *Drafter) []const u8 {
        const i = d.lastRow() orelse return "";
        return std.mem.trimEnd(u8, d.screen.items[i], " ");
    }

    fn lastRow(d: *Drafter) ?usize {
        var i = d.screen.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.trim(u8, d.screen.items[i], " ").len > 0) return i;
        }
        return null;
    }

    fn changed(d: *Drafter, t: f64, rows: []const []const u8) !void {
        // Hidden input shows in the trace only as a marker, its Enter
        // too: the line ends when the screen moves on from its prompt.
        if (d.typing and d.secret and (d.lastRow() != d.prompt_row or !std.mem.startsWith(u8, d.last(), d.prompt))) try d.enter(t);
        if (!d.waiting) return;
        if (d.unsure) |at| if (try d.echoed(d.out.items[at].value)) {
            d.unsure = null;
        };
        try d.frames.append(d.a, .{ .t = t, .last = d.last() });
        for (rows) |row| for (start.builtin_failures) |f| {
            if (std.mem.indexOf(u8, row, f) == null or std.mem.indexOf(u8, d.command, f) != null) continue;
            const note = try std.fmt.allocPrint(d.a, "the output showed '{s}'", .{f});
            for (d.notes.items) |seen| {
                if (std.mem.eql(u8, seen, note)) break;
            } else try d.notes.append(d.a, note);
        };
    }

    /// The prompt is on the screen: the check after the last command.
    fn finish(d: *Drafter, now: f64) !void {
        if (d.unsure) |at| {
            // No echo: it was a password, which stays here.
            const notes = try std.mem.concat(d.a, []const u8, &.{ d.out.items[at].notes, &.{unshown_note} });
            d.out.items[at] = .{ .keyword = "secret", .notes = notes };
            d.unsure = null;
            d.command = "";
        }
        const prompt = d.last();
        if (!d.started) {
            d.started = true;
            if (prompt.len > 0) try d.out.append(d.a, .{ .keyword = "expect", .value = prompt });
            return;
        }
        if (!d.waiting) return;
        d.waiting = false;
        var took = now - d.enter_t;
        for (d.frames.items) |f| if (std.mem.eql(u8, f.last, prompt)) {
            took = f.t - d.enter_t;
            break;
        };
        if (prompt.len == 0) try d.notes.append(d.a, "the screen showed no prompt here");
        const default_s = @as(f64, @floatFromInt(start.default_timeout_ms)) / 1000;
        const max_s = start.max_timeout_ms / 1000;
        const slow: ?u64 = if (took > default_s / 3) @min(max_s, @as(u64, @intFromFloat(@ceil(took * 3)))) else null;
        // A command that moved on to another prompt failed if the one it
        // was typed at comes back instead.
        const back = if (d.prompt.len > 0 and prompt.len > 0 and std.mem.indexOf(u8, d.prompt, prompt) == null and std.mem.indexOf(u8, prompt, d.prompt) == null) d.prompt else "";
        try d.out.append(d.a, .{ .keyword = "expect", .value = prompt, .notes = try d.notes.toOwnedSlice(d.a), .timeout_s = slow, .fail = back });
    }

    fn begin(d: *Drafter, now: f64) !void {
        if (d.typing) return;
        try d.finish(now);
        d.typing = true;
        d.prompt = d.last();
        d.prompt_row = d.lastRow();
        d.keys.clearRetainingCapacity();
        d.secret = false;
        d.pasted = false;
        d.chunks = 0;
    }

    /// Whether the screen shows `keys` after the prompt they were typed
    /// at, also when the line wraps.
    fn echoed(d: *Drafter, keys: []const u8) !bool {
        const want = try spaceless(d.a, keys);
        // Without a prompt every row would start like the echo.
        if (want.len == 0 or d.unsure_prompt.len == 0) return false;
        for (d.screen.items, 0..) |row, j| {
            if (!std.mem.startsWith(u8, row, d.unsure_prompt)) continue;
            // The rest of the prompt's row, and the rows it wraps onto:
            // output below it is no echo.
            var joined: std.ArrayList(u8) = .empty;
            try joined.appendSlice(d.a, row[d.unsure_prompt.len..]);
            var k = j;
            while (k + 1 < d.screen.items.len and d.cols > 0 and cells(d.screen.items[k]) >= d.cols) : (k += 1)
                try joined.appendSlice(d.a, d.screen.items[k + 1]);
            if (std.mem.startsWith(u8, try spaceless(d.a, joined.items), want)) return true;
        }
        return false;
    }

    fn enter(d: *Drafter, now: f64) !void {
        d.typing = false;
        if (d.keys.items.len == 0 and !d.secret) return;
        var notes: std.ArrayList([]const u8) = .empty;
        if (d.pasted) try notes.append(d.a, "pasted; check the command");
        const keys = d.keys.items;
        const line = d.last();
        const rest: ?[]const u8 = if (std.mem.startsWith(u8, line, d.prompt)) std.mem.trim(u8, line[d.prompt.len..], " ") else null;
        const changed_line = !std.mem.eql(u8, line, d.prompt);
        var keyword: []const u8 = "send";
        var value: []const u8 = "";
        if (d.secret or asks(d.prompt, &password_words)) {
            // The keys of a password stay here.
            keyword = "secret";
        } else if (asks(d.prompt, &code_words)) {
            // A one-time code is asked anew each time.
            keyword = "ask";
        } else if (printable(keys) and rest != null and std.mem.indexOf(u8, rest.?, keys) != null) {
            value = try d.a.dupe(u8, keys);
        } else if (!printable(keys) and changed_line and !stars(rest)) {
            // Edited with keys (Tab, history): the line as it shows.
            if (rest) |r| {
                value = r;
            } else {
                value = std.mem.trim(u8, line, " ");
                try notes.append(d.a, "edited with keys, and the line no longer starts with the prompt; check the command");
            }
            if (value.len == 0) try notes.append(d.a, "the command could not be read from the screen");
        } else if (printable(keys)) {
            // The screen does not show the keys (yet): a command when its
            // echo follows the Enter, else a password.
            d.unsure = d.out.items.len;
            d.unsure_prompt = d.prompt;
            value = try d.a.dupe(u8, keys);
        } else {
            keyword = "secret";
            try notes.append(d.a, unshown_note);
        }
        try d.out.append(d.a, .{ .keyword = keyword, .value = value, .notes = try notes.toOwnedSlice(d.a) });
        d.command = value;
        d.waiting = true;
        d.enter_t = now;
        d.frames.clearRetainingCapacity();
    }

    fn input(d: *Drafter, now: f64, text: []const u8) !void {
        var rest = text;
        if (std.mem.indexOf(u8, rest, "\x1b[200~") != null) {
            rest = try std.mem.replaceOwned(u8, d.a, rest, "\x1b[200~", "");
            rest = try std.mem.replaceOwned(u8, d.a, rest, "\x1b[201~", "");
            try d.begin(now);
            d.pasted = true;
        }
        while (rest.len > 0) {
            try d.begin(now);
            const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse {
                try d.keys.appendSlice(d.a, rest);
                d.chunks += 1;
                return;
            };
            try d.keys.appendSlice(d.a, rest[0..end]);
            try d.enter(now);
            rest = rest[end + 1 ..];
        }
    }
};

const unshown_note = "the screen did not show what was typed, so it is written as a password; if it was a command, write it with send";

const password_words = [_][]const u8{ "passw", "pass phrase", "passphrase", "passcode", "kennwort", "pin" };
const code_words = [_][]const u8{ "code", "token", "otp", "one-time", "verification" };

/// Whether a prompt is a question (it ends with `:` or `?`, unlike a
/// shell prompt) with one of `words`: then what is typed at it must not
/// be written down, even when the screen shows something for it.
fn asks(prompt: []const u8, words: []const []const u8) bool {
    if (prompt.len == 0 or (prompt[prompt.len - 1] != ':' and prompt[prompt.len - 1] != '?')) return false;
    for (words) |word| if (std.ascii.findIgnoreCase(prompt, word) != null) return true;
    return false;
}

fn cells(row: []const u8) usize {
    return std.unicode.utf8CountCodepoints(row) catch row.len;
}

fn spaceless(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| if (c != ' ') try out.append(a, c);
    return out.items;
}

/// Text a person types: no control characters or escape sequences.
fn printable(keys: []const u8) bool {
    for (keys) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Whether the line after a prompt shows only the stars a password
/// prompt echoes, also after Backspace.
fn stars(rest: ?[]const u8) bool {
    const r = rest orelse return false;
    return r.len > 0 and std.mem.trim(u8, r, "*").len == 0;
}

fn number(v: ?std.json.Value) f64 {
    return switch (v orelse return 0) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

/// The steps a trace shows: the prompt, then each command typed and the
/// prompt after it.
pub fn draft(a: std.mem.Allocator, trace: []const u8) !std.ArrayList(Line) {
    var d: Drafter = .{ .a = a };
    var t: f64 = 0;
    var it = std.mem.splitScalar(u8, trace, '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch continue;
        if (v != .object) continue;
        const obj = v.object;
        const ev = (obj.get("ev") orelse continue);
        if (ev != .string) continue;
        t = number(obj.get("t"));
        if (std.mem.eql(u8, ev.string, "start")) {
            d.cols = @intFromFloat(@max(0, number(obj.get("cols"))));
        } else if (std.mem.eql(u8, ev.string, "snap")) {
            const screen = obj.get("screen") orelse continue;
            if (screen != .array) continue;
            d.screen.clearRetainingCapacity();
            for (screen.array.items) |row| try d.screen.append(a, if (row == .string) row.string else "");
            try d.changed(t, d.screen.items);
        } else if (std.mem.eql(u8, ev.string, "diff")) {
            const rows = obj.get("rows") orelse continue;
            if (rows != .array) continue;
            var texts: std.ArrayList([]const u8) = .empty;
            for (rows.array.items) |row| {
                if (row != .object) continue;
                const r: usize = @intFromFloat(@max(0, number(row.object.get("r"))));
                const text = if (row.object.get("text")) |x| (if (x == .string) x.string else "") else "";
                while (d.screen.items.len <= r) try d.screen.append(a, "");
                d.screen.items[r] = text;
                try texts.append(a, text);
            }
            try d.changed(t, texts.items);
        } else if (std.mem.eql(u8, ev.string, "in")) {
            const kind = obj.get("kind") orelse continue;
            if (kind != .string) continue;
            if (std.mem.eql(u8, kind.string, "send")) {
                const text = obj.get("text") orelse continue;
                if (text == .string) try d.input(t, text.string);
            } else if (std.mem.eql(u8, kind.string, "secret")) {
                try d.begin(t);
                d.secret = true;
                d.chunks += 1;
            } else if (std.mem.eql(u8, kind.string, "resize")) {
                d.cols = @intFromFloat(@max(0, number(obj.get("cols"))));
            } else if (std.mem.eql(u8, kind.string, "key")) {
                // Keys from a batch: count as keys that are not text.
                try d.begin(t);
                try d.keys.append(a, 0x1b);
                d.chunks += 1;
            }
        }
    }
    try d.finish(t);
    try hostKeys(a, d.out.items);
    sudoPrompts(d.out.items);
    return d.out;
}

const host_key_question = "continue connecting (yes/no";

/// ssh asks about a host's key only the first time it connects to it: the
/// question and its answer become a `when`, which answers only when asked.
fn hostKeys(a: std.mem.Allocator, lines: []Line) !void {
    if (lines.len < 3) return;
    for (lines[1 .. lines.len - 1], 1..) |*l, i| {
        if (!std.mem.eql(u8, l.keyword, "expect")) continue;
        const at = std.mem.indexOf(u8, l.value, host_key_question) orelse continue;
        const answer = lines[i + 1];
        if (!std.mem.eql(u8, lines[i - 1].keyword, "send") or !std.mem.eql(u8, answer.keyword, "send") or !std.mem.eql(u8, answer.value, "yes")) continue;
        answered(lines, i, try std.mem.concat(a, []const u8, &.{ l.notes, &.{host_key_note} }), l.value[at..], "");
    }
}

/// Make the check at `i` a `when` with `value` that the input after it
/// answers; the check after the answer fails on the prompt the question
/// came after instead.
fn answered(lines: []Line, i: usize, notes: []const []const u8, value: []const u8, comment: []const u8) void {
    const fail = lines[i].fail;
    lines[i] = .{ .keyword = "when", .value = value, .notes = notes, .comment = comment };
    lines[i + 1].answer = true;
    if (i + 2 < lines.len and std.mem.eql(u8, lines[i + 2].keyword, "expect")) lines[i + 2].fail = fail;
}

const sudo_prompt = "[sudo] password for";

/// sudo asks for a password only when it has none cached: its prompt and
/// the password become a `when`, which types it only when asked.
fn sudoPrompts(lines: []Line) void {
    if (lines.len < 3) return;
    for (lines[1 .. lines.len - 1], 1..) |*l, i| {
        if (!std.mem.eql(u8, l.keyword, "expect")) continue;
        const at = std.mem.indexOf(u8, l.value, sudo_prompt) orelse continue;
        if (!std.mem.eql(u8, lines[i + 1].keyword, "secret") or lines[i + 1].notes.len > 0) continue;
        answered(lines, i, l.notes, l.value[at..], sudo_note);
    }
}

const sudo_note = "this types the password only when sudo asks for it, as it does when it has none cached";

const host_key_note = "this answers yes when ssh asks about the key of a host it does not know yet; a changed key still fails";

/// Put `use NAME` for the first steps when a block without parameters has
/// just those.
fn useBlocks(a: std.mem.Allocator, file: *const start.File, lines: *std.ArrayList(Line)) !void {
    var best: ?struct { at: usize, len: usize, name: []const u8 } = null;
    for (file.blocks) |*b| {
        if (b.problem != null or b.params.len > 0 or b.kind == .group) continue;
        // Its own uses, checks other than a plain expect, and alternatives
        // would run steps the recording did not have, and its questions be
        // answered where the recording had none.
        const extra = for (b.items) |item| switch (item.keyword) {
            .use, .when, .gone, .settle, .ended, .@"or" => break true,
            .expect => if (item.regex) break true,
            else => {},
        } else false;
        if (extra) continue;
        if (b.kind == .start and (b.names.len != 1 or names.kind(b.names[0]) == .pattern or b.setting(.command) != null or b.setting(.dir) != null or b.setting(.size) != null or b.setting(.timeout) != null)) continue;
        var steps: std.ArrayList(start.Item) = .empty;
        for (b.items) |item| switch (item.keyword) {
            .send, .type, .keys, .secret, .ask, .expect => try steps.append(a, item),
            else => {},
        };
        if (steps.items.len < 2) continue;
        for ([_]usize{ 0, 1 }) |at| {
            if (at + steps.items.len > lines.items.len) continue;
            const same = for (steps.items, lines.items[at .. at + steps.items.len]) |s, l| {
                if (l.notes.len > 0 or !std.mem.eql(u8, @tagName(s.keyword), l.keyword)) break false;
                if (s.keyword != .secret and !std.mem.eql(u8, s.value, l.value)) break false;
            } else true;
            if (same and (best == null or steps.items.len > best.?.len)) best = .{ .at = at, .len = steps.items.len, .name = b.names[0] };
        }
    }
    const use = best orelse return;
    try lines.replaceRange(a, use.at, use.len, &.{.{ .keyword = "use", .value = use.name }});
}

fn compose(a: std.mem.Allocator, id: []const u8, command: []const []const u8, cwd: []const u8, lines: []const Line) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "start {s}\n", .{id});
    if (command.len > 0) {
        try out.appendSlice(a, "    command  ");
        for (command, 0..) |word, i| {
            if (i > 0) try out.append(a, ' ');
            const w = try percents(a, word);
            if (w.len > 0 and std.mem.indexOfAny(u8, w, " \t\"\\") == null) {
                try out.appendSlice(a, w);
            } else try quoted(a, &out, w);
        }
        try out.append(a, '\n');
    }
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    const dir = if (home.len > 1 and std.mem.startsWith(u8, cwd, home) and (cwd.len == home.len or cwd[home.len] == '/'))
        try std.mem.concat(a, u8, &.{ "~", cwd[home.len..] })
    else
        cwd;
    try out.appendSlice(a, "    dir      ");
    try writeValue(a, &out, dir);
    try out.append(a, '\n');
    for (lines) |l| {
        const indent: []const u8 = if (l.answer) "        " else "    ";
        if (l.comment.len > 0) try out.print(a, "{s}# {s}\n", .{ indent, l.comment });
        for (l.notes) |note| try out.print(a, "{s}# CHECK: {s}\n", .{ indent, note });
        if (l.timeout_s) |t| {
            const head = try std.fmt.allocPrint(a, "{s}({d}s)", .{ l.keyword, t });
            try out.print(a, "{s}{s: <8} ", .{ indent, head });
        } else try out.print(a, "{s}{s: <8} ", .{ indent, l.keyword });
        try writeValue(a, &out, l.value);
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        try out.append(a, '\n');
        if (l.fail.len > 0) {
            try out.print(a, "{s}fail     ", .{indent});
            try writeValue(a, &out, l.fail);
            try out.append(a, '\n');
        }
    }
    return out.items;
}

/// A value as the file reads it back: quoted when it has blanks at an
/// end or starts with a quote or '(', and with `%` doubled where it would be
/// read as `%i`, `%{`, or `%%`.
fn writeValue(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const v = try percents(a, text);
    const needs = v.len > 0 and (v[0] == '"' or v[0] == '(' or v[0] == ' ' or v[0] == '\t' or v[v.len - 1] == ' ' or v[v.len - 1] == '\t');
    if (needs) try quoted(a, out, v) else try out.appendSlice(a, v);
}

/// `text` with `%` doubled where it would be read as `%i`, `%{`, or `%%`.
fn percents(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (text, 0..) |c, i| {
        try escaped.append(a, c);
        if (c == '%' and i + 1 < text.len and std.mem.indexOfScalar(u8, "i{%", text[i + 1]) != null) try escaped.append(a, '%');
    }
    return escaped.items;
}

fn quoted(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(a, '"');
    for (text) |c| {
        if (c == '"' or c == '\\') try out.append(a, '\\');
        try out.append(a, c);
    }
    try out.append(a, '"');
}

/// The first `# CHECK:` line, under the header.
fn addCheck(a: std.mem.Allocator, block: []const u8, note: []const u8) ![]const u8 {
    const nl = (std.mem.indexOfScalar(u8, block, '\n') orelse block.len - 1) + 1;
    const flat = try std.mem.replaceOwned(u8, a, note, "\n", " ");
    return std.mem.concat(a, u8, &.{ block[0..nl], "    # CHECK: ", flat, "\n", block[nl..] });
}

/// The text between the old file and `block` when it is appended.
fn separator(old: []const u8) []const u8 {
    if (old.len == 0) return "";
    if (!std.mem.endsWith(u8, old, "\n")) return "\n\n";
    if (!std.mem.endsWith(u8, old, "\n\n")) return "\n";
    return "";
}

/// What is wrong with `block` appended to the file, or null.
fn validate(a: std.mem.Allocator, old: start_run.Text, block: []const u8) !?[]const u8 {
    const before = try std.mem.concat(a, u8, &.{ old.text, separator(old.text) });
    const first_line: u32 = @intCast(std.mem.count(u8, before, "\n") + 1);
    const file = try start.parse(a, old.path, try std.mem.concat(a, u8, &.{ before, block }));
    for (file.stray) |p| if (p.line >= first_line) return try std.fmt.allocPrint(a, "line {d}: {s}", .{ p.line - first_line + 1, p.text });
    var any = false;
    for (file.blocks) |*b| {
        if (b.line < first_line) continue;
        if (b.problem) |p| return try std.fmt.allocPrint(a, "line {d}: {s}", .{ p.line - first_line + 1, p.text });
        if (b.kind != .start) continue;
        any = true;
        _ = start.planBlock(a, &file, b, b.names[0]) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Bad => return try a.dupe(u8, start.badText()),
        };
    }
    if (!any) return "the text has no start block";
    return null;
}

fn editBlock(a: std.mem.Allocator, private: []const u8, block: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/tuppet-record-{d}.start", .{ private, std.c.getpid() }, 0);
    _ = std.c.unlink(path);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) {
        try errPrint("tuppet: cannot write {s} to edit\n", .{path});
        return block;
    }
    defer _ = std.c.unlink(path);
    _ = std.c.write(fd, block.ptr, block.len);
    _ = std.c.close(fd);
    start_run.edit(a, path, 2);
    const back = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (back < 0) return block;
    defer _ = std.c.close(back);
    const text = try readAll(a, back);
    return if (std.mem.endsWith(u8, text, "\n")) text else try std.mem.concat(a, u8, &.{ text, "\n" });
}

/// Append `block` to the start file, as it is now.
fn append(a: std.mem.Allocator, block: []const u8) !void {
    const now = try start_run.loadText(a, false, true);
    const file = try start.parse(a, now.path, now.text);
    const added = try start.parse(a, now.path, block);
    for (added.blocks) |b| if (b.kind == .start) for (b.names) |n| if (hasId(&file, n))
        runtimeFail("{s} has a start block for '{s}' meanwhile; nothing appended", .{ now.path, n });
    const dir = std.fs.path.dirname(now.path) orelse ".";
    try makePrivateDir(a, dir);
    const path = try a.dupeSentinel(u8, now.path, 0);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) runtimeFail("{s}: cannot write to it", .{now.path});
    defer _ = std.c.close(fd);
    if (ipc.untrusted(fd)) |why| runtimeFail("{s}: refused, because {s}", .{ now.path, why });
    const text = try std.mem.concat(a, u8, &.{ separator(now.text), block });
    if (std.c.write(fd, text.ptr, text.len) != @as(isize, @intCast(text.len))) runtimeFail("{s}: the write failed", .{now.path});
}

/// `dir` and its missing parents; the last one only its owner may use.
fn makePrivateDir(a: std.mem.Allocator, dir: []const u8) !void {
    var end: usize = 0;
    while (end < dir.len) {
        end = std.mem.indexOfScalarPos(u8, dir, end + 1, '/') orelse dir.len;
        const part = try a.dupeSentinel(u8, dir[0..end], 0);
        _ = std.c.mkdir(part, if (end == dir.len) 0o700 else 0o755);
    }
}

test "a password that the output after its prompt repeats is no command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const trace =
        \\{"t":0,"ev":"start","cols":40,"rows":4,"name":"x"}
        \\{"t":0,"ev":"snap","screen":["Say it:","","",""]}
        \\{"t":1.0,"ev":"in","kind":"send","text":"vagrant\r"}
        \\{"t":1.1,"ev":"snap","screen":["Say it: *******","vagrant@vm:~$","",""]}
        \\{"t":2.0,"ev":"in","kind":"send","text":"openssl rsa -in k -out k2\r"}
        \\{"t":2.1,"ev":"diff","rows":[{"r":1,"text":"vagrant@vm:~$ openssl rsa -in k -out k2"},{"r":2,"text":"Enter it now:"}]}
        \\{"t":3.0,"ev":"in","kind":"send","text":"writing\r"}
        \\{"t":3.1,"ev":"diff","rows":[{"r":3,"text":"writing RSA key"}]}
        \\{"t":3.5,"ev":"stop","reason":"request"}
    ;
    const lines = try draft(arena.allocator(), trace);
    const block = try compose(arena.allocator(), "x", &.{}, "/", lines.items);
    for ([_][]const u8{ "send     vagrant", "send     writing" }) |typed| try std.testing.expect(std.mem.indexOf(u8, block, typed) == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "send     openssl rsa -in k -out k2") != null);
}

test "the host-key question of a first ssh login becomes a when" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const trace =
        \\{"t":0,"ev":"start","cols":80,"rows":4,"name":"x"}
        \\{"t":0,"ev":"snap","screen":["me@laptop:~$","","",""]}
        \\{"t":1.0,"ev":"in","kind":"send","text":"ssh web1\r"}
        \\{"t":1.1,"ev":"snap","screen":["me@laptop:~$ ssh web1","Are you sure you want to continue connecting (yes/no/[fingerprint])?","",""]}
        \\{"t":2.0,"ev":"in","kind":"send","text":"yes\r"}
        \\{"t":2.1,"ev":"snap","screen":["me@laptop:~$ ssh web1","Are you sure you want to continue connecting (yes/no/[fingerprint])? yes","me@web1:~$",""]}
        \\{"t":2.5,"ev":"stop","reason":"request"}
    ;
    const lines = try draft(arena.allocator(), trace);
    const block = try compose(arena.allocator(), "x", &.{}, "/", lines.items);
    try std.testing.expect(std.mem.indexOf(u8, block,
        \\    send     ssh web1
        \\    # CHECK: this answers yes when ssh asks about the key of a host it does not know yet; a changed key still fails
        \\    when     continue connecting (yes/no/[fingerprint])?
        \\        send     yes
        \\    expect   me@web1:~$
        \\    fail     me@laptop:~$
    ) != null);
}

test "a recorded login: commands, passwords, a code, prompts, and a slow hop" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // ssh typed key by key; sudo typed in one go, echoed only after its
    // Enter; a password the daemon saw as hidden; one at a prompt that
    // shows stars but does not say password; Tab completion; a code.
    const trace =
        \\{"t":0.000000,"ev":"start","cols":40,"rows":4,"name":"x"}
        \\{"t":0.000000,"ev":"snap","screen":["me@laptop:~$","","",""]}
        \\{"t":1.0,"ev":"in","kind":"send","text":"s"}
        \\{"t":1.1,"ev":"diff","rows":[{"r":0,"text":"me@laptop:~$ s"}]}
        \\{"t":1.2,"ev":"in","kind":"send","text":"sh jump"}
        \\{"t":1.3,"ev":"diff","rows":[{"r":0,"text":"me@laptop:~$ ssh jump"}]}
        \\{"t":1.4,"ev":"in","kind":"send","text":"\r"}
        \\{"t":6.0,"ev":"diff","rows":[{"r":1,"text":"me@jump:~$"}]}
        \\{"t":7.0,"ev":"in","kind":"send","text":"sudo -i\r"}
        \\{"t":7.2,"ev":"diff","rows":[{"r":1,"text":"me@jump:~$ sudo -i"},{"r":2,"text":"[sudo] password for me:"}]}
        \\{"t":8.0,"ev":"in","kind":"secret"}
        \\{"t":8.1,"ev":"in","kind":"secret"}
        \\{"t":8.3,"ev":"diff","rows":[{"r":3,"text":"Say it:"}]}
        \\{"t":8.5,"ev":"in","kind":"send","text":"hu"}
        \\{"t":8.6,"ev":"diff","rows":[{"r":3,"text":"Say it: **"}]}
        \\{"t":8.7,"ev":"in","kind":"send","text":"nter2"}
        \\{"t":8.8,"ev":"diff","rows":[{"r":3,"text":"Say it: *******"}]}
        \\{"t":8.9,"ev":"in","kind":"send","text":"\r"}
        \\{"t":9.0,"ev":"snap","screen":["me@jump:~$ sudo -i","[sudo] password for me:","Say it: *******","root@jump:~# 100%i"]}
        \\{"t":9.1,"ev":"in","kind":"send","text":"cd /t\t"}
        \\{"t":9.2,"ev":"diff","rows":[{"r":3,"text":"root@jump:~# 100%i cd /tmp/"}]}
        \\{"t":9.3,"ev":"in","kind":"send","text":"\r"}
        \\{"t":9.4,"ev":"snap","screen":["Say it: *******","root@jump:~# 100%i cd /tmp/","root@jump:/tmp# 100%i",""]}
        \\{"t":10.0,"ev":"in","kind":"send","text":"su - app\r"}
        \\{"t":10.1,"ev":"diff","rows":[{"r":2,"text":"root@jump:/tmp# 100%i su - app"},{"r":3,"text":"Code:"}]}
        \\{"t":11.0,"ev":"in","kind":"send","text":"481516\r"}
        \\{"t":11.2,"ev":"snap","screen":["root@jump:~# 100%i cd /tmp/","root@jump:/tmp# 100%i su - app","Code:","app@jump:~$"]}
        \\{"t":11.5,"ev":"stop","reason":"request"}
    ;
    const lines = try draft(arena.allocator(), trace);
    const block = try compose(arena.allocator(), "x", &.{}, "/srv", lines.items);
    try std.testing.expectEqualStrings(
        \\start x
        \\    dir      /srv
        \\    expect   me@laptop:~$
        \\    send     ssh jump
        \\    expect(14s) me@jump:~$
        \\    fail     me@laptop:~$
        \\    send     sudo -i
        \\    # this types the password only when sudo asks for it, as it does when it has none cached
        \\    when     [sudo] password for me:
        \\        secret
        \\    expect   Say it:
        \\    fail     me@jump:~$
        \\    # CHECK: the screen did not show what was typed, so it is written as a password; if it was a command, write it with send
        \\    secret
        \\    expect   root@jump:~# 100%%i
        \\    fail     Say it:
        \\    send     cd /tmp/
        \\    expect   root@jump:/tmp# 100%%i
        \\    fail     root@jump:~# 100%%i
        \\    send     su - app
        \\    expect   Code:
        \\    fail     root@jump:/tmp# 100%%i
        \\    ask
        \\    expect   app@jump:~$
        \\    fail     Code:
        \\
    , block);
    for ([_][]const u8{ "hunter", "481516" }) |typed| try std.testing.expect(std.mem.indexOf(u8, block, typed) == null);
}

test "a recorded command and directory read back as they were" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const command = [_][]const u8{ "/opt/my app/run", "--rate=50%i", "say \"hi\"" };
    const cwd = "/nonexistent-tuppet/50%i 100%{x} ";
    const lines = [_]Line{ .{ .keyword = "expect", .value = "$ " }, .{ .keyword = "send", .value = "echo 100%i" } };
    const block = try compose(a, "x", &command, cwd, &lines);
    const file = try start.parse(a, "start", block);
    const p = start.planBlock(a, &file, &file.blocks[0], "x") catch |err| {
        std.debug.print("{s}\n{s}\n", .{ block, start.badText() });
        return err;
    };
    try std.testing.expectEqualStrings(cwd, p.dir.?);
    try std.testing.expectEqual(command.len, p.command.?.len);
    for (command, p.command.?) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings("echo 100%i", p.steps[1].text);
}

test "no password as a command: a blank screen, stars after Backspace, and a used block's other steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const trace =
        \\{"t":0,"ev":"start","cols":40,"rows":3,"name":"x"}
        \\{"t":0,"ev":"snap","screen":["","",""]}
        \\{"t":1.0,"ev":"in","kind":"send","text":"hunter2\r"}
        \\{"t":1.1,"ev":"snap","screen":["hunter2 is no user","me@vm:~$",""]}
        \\{"t":2.0,"ev":"in","kind":"send","text":"login\r"}
        \\{"t":2.1,"ev":"snap","screen":["me@vm:~$ login","Say it:",""]}
        \\{"t":3.0,"ev":"in","kind":"send","text":"ab\u007fc"}
        \\{"t":3.1,"ev":"diff","rows":[{"r":1,"text":"Say it: **"}]}
        \\{"t":3.2,"ev":"in","kind":"send","text":"\r"}
        \\{"t":3.3,"ev":"snap","screen":["Say it: **","you@vm:~$",""]}
        \\{"t":3.5,"ev":"stop","reason":"request"}
    ;
    const lines = try draft(a, trace);
    const block = try compose(a, "x", &.{}, "/", lines.items);
    try std.testing.expect(std.mem.indexOf(u8, block, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "**") == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "send     login") != null);

    var hop: std.ArrayList(Line) = .empty;
    try hop.appendSlice(a, &.{ .{ .keyword = "expect", .value = "me@laptop:~$" }, .{ .keyword = "send", .value = "ssh jump" }, .{ .keyword = "expect", .value = "me@jump:~$" } });
    const file = try start.parse(a, "start", "steps jump\n    send ssh jump\n    expect me@jump:~$\n    gone Loading\n");
    try useBlocks(a, &file, &hop);
    try std.testing.expectEqual(@as(usize, 3), hop.items.len);
}
