//! The tuppet CLI: connects to the daemon (auto-starting it), sends a
//! JSON-lines request, prints the reply.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const keys = @import("keys.zig");
const mouse = @import("mouse.zig");
const protocol = @import("protocol.zig");
const plat = @import("plat.zig");
const attach_client = @import("attach_client.zig");
const names = @import("names.zig");
const status = @import("status.zig");
const units = @import("units.zig");
const words = @import("words.zig");
const cond = @import("cond.zig");
const batch = @import("batch.zig");
const alert = @import("alert.zig");
const config_mod = @import("config.zig");
const store = @import("store.zig");
const fonts = @import("fonts.zig");
const limits = @import("limits.zig");

const Status = status.Status;

/// Sentinel for argument/usage mistakes; main maps it to exit code 2.
pub const UsageError = error{UsageError};

/// Exit codes shared by every command.
pub const exit_code = struct {
    pub const ok = 0;
    pub const failed = 1;
    pub const usage = 2;
    pub const timeout = 3;
    /// The session ended (or was removed) before the command could do its
    /// part.
    pub const ended = 4;
    pub const guard = 5;
};

/// The exit code for a failed reply's code.
pub fn exitFor(code: []const u8) u8 {
    if (std.mem.eql(u8, code, @tagName(protocol.Code.ended))) return exit_code.ended;
    if (std.mem.eql(u8, code, @tagName(protocol.Code.guard))) return exit_code.guard;
    return exit_code.failed;
}

/// Print `tuppet: <message>` plus a usage hint to stderr and turn into the
/// usage-error sentinel. Every CLI parse failure funnels through here
/// so errors are consistent and never raw Zig error names.
pub fn cliFail(comptime fmt: []const u8, args: anytype) error{UsageError} {
    // Allocated because messages embed user input of unbounded length;
    // this path runs once per failed command. On OOM the exit code is
    // still correct, only the message is missing.
    const s = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return error.UsageError;
    defer std.heap.page_allocator.free(s);
    plat.stderrWriteAll("tuppet: ") catch {};
    plat.stderrWriteAll(s) catch {};
    plat.stderrWriteAll("\n") catch {};
    plat.stderrWriteAll(usageHint()) catch {};
    return error.UsageError;
}

/// The command being parsed, which usage errors point to the help of.
pub var command: ?[]const u8 = null;

/// The help of the command being parsed.
pub var command_help: ?[]const u8 = null;

/// Fail on the unknown option `a`, unless it is --help or -h: then print
/// the command's help and exit. So help works wherever an option may go,
/// while text the command types or runs is never taken for it.
pub fn unknownOption(a: []const u8, usage: []const u8) error{UsageError} {
    if (command_help) |text| if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
        plat.stdoutWriteAll(text) catch {};
        std.process.exit(0);
    };
    return cliFail("unknown option '{s}' ({s})", .{ a, usage });
}

/// Where a usage error sends the reader: the help of the command at
/// hand, else the overview.
pub fn usageHint() []const u8 {
    const cmd = command orelse return "run 'tuppet help' for usage\n";
    const hint = std.fmt.bufPrint(&usage_hint_buf, "see 'tuppet help {s}'\n", .{cmd}) catch return "run 'tuppet help' for usage\n";
    return hint;
}

var usage_hint_buf: [64]u8 = undefined;

/// Print `tuppet: <message>` to stderr and exit 1: a runtime failure, such
/// as an unusable environment, that no change of arguments fixes.
pub fn runtimeFail(comptime fmt: []const u8, args: anytype) noreturn {
    attach_client.restoreTerminal();
    stderrPrint("tuppet: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(exit_code.failed);
}

/// Anchor a possibly-relative path at the client's working directory.
/// Paths are used by the daemon, whose cwd is unrelated to the caller's
/// (it is auto-started once and outlives the terminal that spawned it).
pub fn absolutePath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return cliFail("empty path argument", .{});
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io_mod.io(), &cwd_buf) catch
        runtimeFail("cannot determine the working directory", .{});
    return std.fs.path.resolve(gpa, &.{ cwd_buf[0..cwd_len], path });
}

/// The `n` operands of a command without options, in order; after `--`
/// they may start with a dash.
fn takeOperands(args: []const []const u8, comptime n: usize, usage: []const u8) error{UsageError}![n][]const u8 {
    var out: [n][]const u8 = undefined;
    var count: usize = 0;
    var dashes = false;
    for (args) |a| {
        if (!dashes and std.mem.eql(u8, a, "--")) {
            dashes = true;
            continue;
        }
        if (!dashes and a.len > 1 and a[0] == '-') return unknownOption(a, usage);
        if (count == n) return cliFail("unexpected argument '{s}' ({s})", .{ a, usage });
        out[count] = a;
        count += 1;
    }
    if (count < n) return cliFail("{s}", .{usage});
    return out;
}

/// Whether `arg` is the option spelled `long` or `short`.
pub fn isOpt(arg: []const u8, long: []const u8, short: []const u8) bool {
    return std.mem.eql(u8, arg, long) or std.mem.eql(u8, arg, short);
}

/// The value of the option at `args[i.*]`; `i` then points at it.
pub fn optValue(args: []const []const u8, i: *usize) error{UsageError}![]const u8 {
    if (i.* + 1 >= args.len) return cliFail("missing value for {s}", .{args[i.*]});
    i.* += 1;
    return args[i.*];
}

/// The duration value of the option at `args[i.*]`, in milliseconds, at
/// least `minimum`.
pub fn durationValue(args: []const []const u8, i: *usize, minimum: u64) error{UsageError}!u64 {
    const flag = args[i.*];
    const value = try optValue(args, i);
    const ms = units.parseDuration(value, .no_days) orelse
        return cliFail("invalid {s} '{s}' (expected {s})", .{ flag, value, units.durationHint(.no_days) });
    if (ms < minimum) return cliFail("{s} must be at least {d}ms", .{ flag, minimum });
    return ms;
}

/// Check a session reference before it goes to the daemon.
fn checkRef(ref: []const u8) error{UsageError}!void {
    if (names.refError(ref)) |why| return cliFail("invalid session '{s}': {s}", .{ ref, why });
}

const run_usage = "usage: tuppet run [-a] [-n NAME] [-s WxH] [-C DIR] [--scrollback SIZE] [-r [--record-format cast|trace] | --record-file FILE] [--alert NAME=TEXT]... [--no-default-alerts] [--if-exists fail|keep|replace] [conditions] [--stats] [-j] [--] <cmd...>";

pub fn cmdRun(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var name: ?[]const u8 = null;
    var cols: u16 = default_cols;
    var rows: u16 = default_rows;
    var cwd: ?[]const u8 = null;
    var sized = false;
    var attach_now = false;
    var json = false;
    var scrollback: ?u64 = null;
    var record = false;
    var record_path: ?[]const u8 = null;
    var record_format: ?protocol.RecordFormat = null;
    var if_exists: protocol.IfExists = .fail;
    var flags: ConditionFlags = .{};
    defer flags.deinit(gpa);
    var rest: []const []const u8 = &.{};
    var alerts: std.ArrayList(alert.Rule) = .empty;
    defer alerts.deinit(gpa);
    var default_alerts = true;
    var stats = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (try flags.take(gpa, args, &i)) continue;
        if (std.mem.eql(u8, a, "--")) {
            // Everything after `--` is the command, even if it starts
            // with a dash.
            rest = args[i + 1 ..];
            break;
        } else if (isOpt(a, "--name", "-n")) {
            const n = try optValue(args, &i);
            if (n.len == 0) return cliFail("{s} needs a non-empty value", .{a});
            if (names.nameError(n)) |why| return cliFail("invalid session name '{s}': {s}", .{ n, why });
            name = n;
        } else if (isOpt(a, "--size", "-s")) {
            const size = try parseSize(try optValue(args, &i));
            cols = size[0];
            rows = size[1];
            sized = true;
        } else if (isOpt(a, "--cwd", "-C")) {
            cwd = try optValue(args, &i);
        } else if (isOpt(a, "--attach", "-a")) {
            attach_now = true;
        } else if (isOpt(a, "--json", "-j")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--scrollback")) {
            const value = try optValue(args, &i);
            scrollback = units.parseByteSize(value) orelse return cliFail("invalid scrollback '{s}' (expected bytes, optionally with K, M, or G)", .{value});
        } else if (isOpt(a, "--record", "-r")) {
            record = true;
        } else if (std.mem.eql(u8, a, "--record-file")) {
            record = true;
            record_path = try optValue(args, &i);
        } else if (std.mem.eql(u8, a, "--record-format")) {
            const value = try optValue(args, &i);
            record_format = std.meta.stringToEnum(protocol.RecordFormat, value) orelse
                return cliFail("unknown recording format '{s}' (choose cast or trace)", .{value});
        } else if (std.mem.eql(u8, a, "--if-exists")) {
            const value = try optValue(args, &i);
            if_exists = std.meta.stringToEnum(protocol.IfExists, value) orelse
                return cliFail("invalid --if-exists '{s}' (choose fail, keep, or replace)", .{value});
        } else if (std.mem.eql(u8, a, "--alert")) {
            const rule = try alertValue(args, &i);
            for (alerts.items) |given| if (std.mem.eql(u8, given.name, rule.name)) return cliFail("--alert {s} is given twice", .{rule.name});
            try alerts.append(gpa, rule);
        } else if (std.mem.eql(u8, a, "--no-default-alerts")) {
            default_alerts = false;
        } else if (std.mem.eql(u8, a, "--stats")) {
            stats = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return unknownOption(a, run_usage);
        } else {
            rest = args[i..];
            break;
        }
    }
    if (rest.len == 0) return cliFail("missing command to run", .{});
    if (rest[0].len == 0) return cliFail("the command to run is empty", .{});
    if (attach_now and json) return cliFail("--json prints the status, which an attach cannot; use one or the other", .{});
    const until = try flags.finish(gpa);
    if (attach_now and until.len > 0) return cliFail("-a attaches instead of waiting; drop -a or the conditions", .{});
    if (stats and until.len == 0) return cliFail("--stats counts while run waits: give it a condition", .{});
    if (attach_now) try attach_client.checkWriterTerminal("run -a");
    if (flags.since != null) return cliFail("--since needs a session that has started; use it with tuppet wait", .{});
    if (if_exists != .fail and name == null) return cliFail("--if-exists needs --name", .{});
    if (scrollback) |bytes| {
        if (bytes > limits.max_scrollback) return cliFail("scrollback must be at most 1G", .{});
    } else if (std.c.getenv("TUPPET_SCROLLBACK")) |env| {
        const value = std.mem.span(env);
        const bytes = units.parseByteSize(value) orelse return cliFail("invalid TUPPET_SCROLLBACK '{s}' (expected bytes, optionally with K, M, or G)", .{value});
        if (bytes > limits.max_scrollback) return cliFail("TUPPET_SCROLLBACK must be at most 1G", .{});
        scrollback = bytes;
    }
    if (record_format != null and (!record or record_path != null)) return cliFail("--record-format goes with -r; --record-file takes the format from the file name", .{});
    if (record_path) |path| record_format = try recordFileFormat("--record-file", path);
    var config: ?config_mod.Config = null;
    defer if (config) |*c| c.deinit();
    if (default_alerts) {
        var diag: config_mod.Diagnostic = .{};
        config = config_mod.load(gpa, &diag) catch |err| switch (err) {
            error.BadConfig => runtimeFail("{s}", .{diag.message}),
            else => return err,
        };
        // --alert wins over a default of the same name.
        for (config.?.alerts) |rule| {
            for (alerts.items) |given| {
                if (std.mem.eql(u8, given.name, rule.name)) break;
            } else try alerts.append(gpa, rule);
        }
    }
    if (alerts.items.len > alert.max_alerts) return cliFail("a session takes at most {d} alerts, defaults included", .{alert.max_alerts});
    // The size: --size, else this terminal's for -a (instead of a resize
    // right away), else TUPPET_SIZE, else 120x40.
    if (attach_now) attach_client.checkSupported();
    const attach_settings = if (attach_now) try attach_client.settingsFor(gpa, null) else null;
    // An explicit --size stays; attaching must not resize to the terminal.
    const keep_size = sized;
    if (!sized) {
        if (attach_now) if (attach_client.terminalSize()) |size| {
            cols = size[0];
            rows = size[1];
            sized = true;
        };
        if (!sized) if (std.c.getenv("TUPPET_SIZE")) |env| {
            const value = std.mem.span(env);
            const size = sizeValue(value) orelse return cliFail("invalid TUPPET_SIZE '{s}' (expected WxH, each " ++ limits.size_range ++ ")", .{value});
            cols = size[0];
            rows = size[1];
        };
    }

    // The session runs where and with what this command runs, not with
    // whatever the long-lived daemon inherited when it was started.
    const cwd_abs = try absolutePath(gpa, cwd orelse ".");
    defer gpa.free(cwd_abs);
    const env = try currentEnv(gpa, true);
    defer freeEnv(gpa, env);

    const record_abs = if (record_path) |p| try absolutePath(gpa, p) else null;
    defer if (record_abs) |p| gpa.free(p);
    const req: protocol.RunReq = .{
        .name = name,
        .cols = cols,
        .rows = rows,
        .cwd = cwd_abs,
        .env = env,
        .scrollback = scrollback,
        .record = if (record) .{ .path = record_abs, .format = record_format orelse .cast } else null,
        .if_exists = if_exists,
        .argv = rest,
        .until = if (until.len > 0) until else null,
        .timeout_ms = if (until.len > 0) flags.timeout() else null,
        .alerts = if (alerts.items.len > 0) alerts.items else null,
    };
    if (until.len > 0) return runAndWait(gpa, req, json, stats);
    const reply = try call(gpa, req, protocol.StatusResp);
    defer reply.deinit();
    if (json) return printJson(gpa, reply.line);
    var buf: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{d}", .{reply.parsed.value.status.?.id}) catch unreachable;
    if (attach_now) {
        const hint = try std.fmt.allocPrint(gpa, "tuppet: session {s} is running, but attaching to it failed; 'tuppet attach {s}' retries\n", .{ id, id });
        defer gpa.free(hint);
        var settings = attach_settings.?;
        settings.resize = !keep_size;
        attach_client.warnNested(settings.detach_key);
        attach_client.attachSession(gpa, id, settings, false, hint) catch |err| {
            plat.stderrWriteAll(hint) catch {};
            return err;
        };
    }
    try stdoutPrint("{s}\n", .{id});
}

/// Start a session, print its id, and wait for the request's conditions:
/// the daemon answers with the session's status first and the wait's
/// outcome on a second line.
fn runAndWait(gpa: std.mem.Allocator, req: protocol.RunReq, json: bool, stats: bool) !void {
    var retried = false;
    var conn, const sent_ns, const first, const started = while (true) {
        try checkProtocol(gpa);
        var conn = try ensureDaemon(gpa);
        errdefer conn.deinit();
        const sent_ns = io_mod.nowNanos();
        try sendRequest(gpa, &conn, req);
        const first = try conn.recvLineAfter(gpa, max_reply, "", ipc.request_timeout_ns);
        errdefer gpa.free(first.rest);
        const started = try parseReply(gpa, protocol.StatusResp, first.line);
        if (started.parsed.value.ok or retried or !try nextDaemon(gpa, started.line, namesSessions(req))) break .{ conn, sent_ns, first, started };
        // Refused by a daemon that was shutting down: start in the next.
        started.deinit();
        gpa.free(first.rest);
        conn.deinit();
        retried = true;
    };
    defer conn.deinit();
    defer gpa.free(first.rest);
    defer started.deinit();
    if (!started.parsed.value.ok) failReply(gpa, started.line, false);
    const id = started.parsed.value.status.?.id;
    if (json) try printJson(gpa, started.line) else try stdoutPrint("{d}\n", .{id});
    var id_buf: [20]u8 = undefined;
    const ref = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
    const hint = "tuppet: session {d} keeps running; 'tuppet stop {d}' ends it\n";
    const second = conn.recvLineAfter(gpa, max_reply, first.rest, waitReplyNs(req.timeout_ms.?)) catch |err| {
        stderrPrint(hint, .{ id, id }) catch {};
        return err;
    };
    gpa.free(second.rest);
    const waited = try parseReply(gpa, protocol.WaitResp, second.line);
    defer waited.deinit();
    const resp = waited.parsed.value;
    const running = if (resp.status) |st| st.state == .running else resp.ok;
    if (!resp.ok) {
        const text = try failureText(gpa, waited.line);
        defer gpa.free(text);
        try stderrPrint("tuppet: {s}\n", .{text});
        if (running) try stderrPrint(hint, .{ id, id });
        std.process.exit(failureExit(gpa, waited.line));
    }
    // A new session's counters start at 0; one that if_exists kept
    // counts from its status in the first reply.
    const first_status = started.parsed.value.status.?;
    const base: ?StatsBase = if (!stats) null else if (req.if_exists == .keep) .{
        .out_bytes = first_status.out_bytes,
        .draws = first_status.draws,
        .full_clears = first_status.full_clears,
        .since = first_status.seq orelse first_status.start_seq,
        .sent_ns = sent_ns,
    } else .{ .since = first_status.start_seq, .sent_ns = sent_ns };
    const code = try reportWait(gpa, waited, .{ .session = ref, .until = req.until.?, .timeout_ms = req.timeout_ms.? }, .{ .json = json, .stats = base });
    if (code == exit_code.ok) return;
    if (running) try stderrPrint(hint, .{ id, id });
    std.process.exit(code);
}

/// The daemon's sessions, for the picker.
pub fn listSessions(gpa: std.mem.Allocator) !Reply(protocol.ListResp) {
    return request(gpa, protocol.ListReq{}, protocol.ListResp);
}

pub fn cmdList(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var json = false;
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(gpa);
    for (args) |a| {
        if (isOpt(a, "--json", "-j")) {
            json = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return unknownOption(a, "usage: tuppet list [<session>...] [-j]");
        } else {
            try checkRef(a);
            try refs.append(gpa, a);
        }
    }
    const reply = try call(gpa, protocol.ListReq{ .sessions = if (refs.items.len > 0) refs.items else null }, protocol.ListResp);
    defer reply.deinit();
    if (json) return printJson(gpa, reply.line);
    const table = try listTable(gpa, reply.parsed.value.sessions, nowMillis());
    defer gpa.free(table);
    try stdoutWrite(table);
}

/// The sessions as `tuppet list` prints them: one aligned table with a
/// header, the same in a terminal and in a pipe.
fn listTable(gpa: std.mem.Allocator, sessions: []const Status, now_ms: i64) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const header: TableRow = .{ .mark = "!", .id = "ID", .name = "NAME", .state = "STATE", .age = "AGE", .cmd = "CMD" };
    const rows = try a.alloc(TableRow, sessions.len);
    var widths = header;
    for (sessions, rows) |s, *row| {
        var buf: [64]u8 = undefined;
        var cmd_buf: [4096]u8 = undefined;
        row.* = .{
            .mark = if (words.needsAttention(s)) "!" else "",
            .id = try std.fmt.allocPrint(a, "{d}", .{s.id}),
            .name = s.name orelse "-",
            .state = try a.dupe(u8, words.stateWord(&buf, s)),
            .age = try a.dupe(u8, words.ageSince(&buf, s.started_ms, now_ms)),
            .cmd = try a.dupe(u8, words.commandText(&cmd_buf, s.argv)),
        };
        inline for (.{ "id", "name", "state", "age" }) |f| {
            if (@field(row, f).len > @field(widths, f).len) @field(widths, f) = @field(row, f);
        }
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try header.write(&out.writer, widths);
    for (rows) |row| try row.write(&out.writer, widths);
    return out.toOwnedSlice();
}

const TableRow = struct {
    mark: []const u8,
    id: []const u8,
    name: []const u8,
    state: []const u8,
    age: []const u8,
    cmd: []const u8,

    /// Numbers right-aligned, text left-aligned, the command last as it is.
    fn write(row: TableRow, w: *std.Io.Writer, widths: TableRow) !void {
        try w.writeAll(row.mark);
        try w.splatByteAll(' ', 1 - row.mark.len + 2 + widths.id.len - row.id.len);
        try w.print("{s}  {s}", .{ row.id, row.name });
        try w.splatByteAll(' ', widths.name.len - row.name.len + 2);
        try w.writeAll(row.state);
        try w.splatByteAll(' ', widths.state.len - row.state.len + 2 + widths.age.len - row.age.len);
        try w.print("{s}  {s}\n", .{ row.age, row.cmd });
    }
};

test "the list table aligns its columns" {
    const gpa = std.testing.allocator;
    const now: i64 = 1_000_000;
    const table = try listTable(gpa, &.{
        .{ .id = 3, .name = "web", .state = .running, .argv = &.{ "npm", "start" }, .started_ms = now - 120_000 },
        .{ .id = 12, .state = .exited, .exit = .{ .code = 2 }, .argv = &.{"make"}, .started_ms = now - 5_000 },
    }, now);
    defer gpa.free(table);
    try std.testing.expectEqualStrings(
        \\!  ID  NAME  STATE     AGE  CMD
        \\    3  web   running    2m  npm start
        \\!  12  -     failed 2   5s  make
        \\
    , table);
}

const key_usage = "usage: tuppet key <session> <keys...> (e.g. <C-c>, <Esc>, ':q!<Enter>')";

/// Type keys: one input, encoded against the program's keyboard mode.
/// There are no options, so text that starts with a dash is typed too;
/// a `--` before the session or right after it is not.
pub fn cmdKey(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var rest = args;
    const separated = rest.len > 0 and std.mem.eql(u8, rest[0], "--");
    if (separated) rest = rest[1..];
    if (rest.len == 0) return cliFail(key_usage, .{});
    if (std.mem.startsWith(u8, rest[0], "-")) return cliFail("key takes no options, so the session comes first ({s}); after it, '{s}' is typed", .{ key_usage, rest[0] });
    try checkRef(rest[0]);
    var typed = rest[1..];
    if (!separated and typed.len > 0 and std.mem.eql(u8, typed[0], "--")) typed = typed[1..];
    if (typed.len == 0) return cliFail(key_usage, .{});
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(gpa);
    for (typed) |arg| try appendKeys(gpa, &tokens, arg);
    const steps = [_]protocol.Step{.{ .keys = tokens.items }};
    const reply = try call(gpa, protocol.InputReq{ .session = rest[0], .steps = &steps }, protocol.InputResp);
    reply.deinit();
}

/// Add the keys in `text` as `key` and `do -k` take them: `<...>` names a
/// key, the rest is typed. Malformed notation is a usage error.
fn appendKeys(gpa: std.mem.Allocator, tokens: *std.ArrayList([]const u8), text: []const u8) !void {
    if (text.len == 0) return cliFail("an empty argument has no keys to type", .{});
    var bad: []const u8 = text;
    const split = keys.split(gpa, text, &bad) catch |err| {
        if (err == error.OutOfMemory) return err;
        return cliFail("invalid key '{s}': {s}", .{ bad, keys.errorText(err) });
    };
    defer gpa.free(split);
    for (split) |tok| keys.checkToken(tok) catch |err|
        return cliFail("invalid key '{s}': {s}", .{ tok, keys.errorText(err) });
    try tokens.appendSlice(gpa, split);
}

pub fn cmdRename(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var json = false;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(gpa);
    for (args) |a| {
        if (isOpt(a, "--json", "-j")) json = true else try rest.append(gpa, a);
    }
    const ops = try takeOperands(rest.items, 2, "usage: tuppet rename <session> <name> [-j] ('' takes the name away)");
    try checkRef(ops[0]);
    const name = ops[1];
    if (name.len > 0) if (names.nameError(name)) |why| return cliFail("invalid session name '{s}': {s}", .{ name, why });
    const reply = try call(gpa, protocol.RenameReq{ .session = ops[0], .name = name }, protocol.StatusResp);
    defer reply.deinit();
    if (json) return printJson(gpa, reply.line);
}

const alert_usage = "usage: tuppet alert add <session> NAME=TEXT [--icase] [-j] | alert list [<session>...] [-j] | alert remove <session> NAME [-j]";

/// Add, list, or remove a session's alerts.
pub fn cmdAlert(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) return cliFail(alert_usage, .{});
    var json = false;
    var icase = false;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(gpa);
    for (args[1..]) |a| {
        if (isOpt(a, "--json", "-j")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--icase") and std.mem.eql(u8, args[0], "add")) {
            icase = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return unknownOption(a, alert_usage);
        } else try rest.append(gpa, a);
    }
    const operands = rest.items;
    if (std.mem.eql(u8, args[0], "list")) {
        for (operands) |ref| try checkRef(ref);
        return listAlerts(gpa, operands, json);
    }
    var req: protocol.AlertReq = .{ .session = "" };
    if (std.mem.eql(u8, args[0], "add")) {
        if (operands.len != 2) return cliFail("usage: tuppet alert add <session> NAME=TEXT [--icase] [-j]", .{});
        const eq = std.mem.indexOfScalar(u8, operands[1], '=') orelse return cliFail("alert add '{s}': expected NAME=TEXT", .{operands[1]});
        const rule: alert.Rule = .{ .name = operands[1][0..eq], .match = operands[1][eq + 1 ..], .icase = icase };
        if (alert.ruleError(rule)) |why| return cliFail("alert add '{s}': {s}", .{ operands[1], why });
        req.add = rule;
    } else if (std.mem.eql(u8, args[0], "remove")) {
        if (operands.len != 2) return cliFail("usage: tuppet alert remove <session> NAME [-j]", .{});
        req.remove = operands[1];
    } else return cliFail("unknown alert command '{s}' ({s})", .{ args[0], alert_usage });
    try checkRef(operands[0]);
    req.session = operands[0];
    const reply = try call(gpa, req, protocol.AlertResp);
    defer reply.deinit();
    if (json) try printJson(gpa, reply.line);
}

/// The alerts of the sessions `refs` pick (every session without any), as
/// a table or, with `json`, as {"sessions":[{"id":N,"alerts":[...]}]}.
fn listAlerts(gpa: std.mem.Allocator, refs: []const []const u8, json: bool) !void {
    const listed = try call(gpa, protocol.ListReq{ .sessions = if (refs.len > 0) refs else null }, protocol.ListResp);
    defer listed.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Entry = struct { id: u64, alerts: []const protocol.Alert };
    var entries: std.ArrayList(Entry) = .empty;
    for (listed.parsed.value.sessions) |st| {
        var alerts: []const protocol.Alert = &.{};
        if (st.alerts.len > 0) {
            const id = try std.fmt.allocPrint(a, "{d}", .{st.id});
            const reply = try request(a, protocol.AlertReq{ .session = id, .list = true }, protocol.AlertResp);
            // Removed meanwhile.
            if (reply.parsed.value.ok) alerts = reply.parsed.value.alerts;
        }
        try entries.append(a, .{ .id = st.id, .alerts = alerts });
    }
    if (json) {
        const line = try protocol.stringifyAlloc(a, .{ .sessions = entries.items });
        try stdoutWrite(line);
        return stdoutWrite("\n");
    }
    var width: usize = "NAME".len;
    var id_width: usize = "ID".len;
    for (entries.items) |e| for (e.alerts) |rule| {
        width = @max(width, rule.name.len);
        id_width = @max(id_width, std.fmt.count("{d}", .{e.id}));
    };
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.splatByteAll(' ', id_width - 2);
    try w.writeAll("ID  NAME");
    try w.splatByteAll(' ', width - 4);
    try w.writeAll("  TEXT\n");
    for (entries.items) |e| for (e.alerts) |rule| {
        try w.splatByteAll(' ', id_width - std.fmt.count("{d}", .{e.id}));
        try w.print("{d}  {s}", .{ e.id, rule.name });
        try w.splatByteAll(' ', width - rule.name.len);
        try w.print("  {s}{s}\n", .{ rule.match, if (rule.icase) "  (icase)" else "" });
    };
    try stdoutWrite(out.written());
}

/// Start an ended session's command again, as `run` does, with what it
/// had (directory, name, size, history size) and this command's
/// environment.
pub fn cmdRestart(gpa: std.mem.Allocator, args: []const []const u8) !void {
    const usage = "usage: tuppet restart <session> [-j]";
    var json = false;
    var ref: ?[]const u8 = null;
    for (args) |a| {
        if (isOpt(a, "--json", "-j")) {
            json = true;
        } else if (std.mem.startsWith(u8, a, "-") or ref != null) {
            return cliFail("unexpected argument '{s}' ({s})", .{ a, usage });
        } else ref = a;
    }
    const given = ref orelse return cliFail(usage, .{});
    try checkRef(given);
    const listed = try call(gpa, protocol.ListReq{ .sessions = &.{given} }, protocol.ListResp);
    defer listed.deinit();
    const old = try onlyOne(gpa, given, listed.parsed.value.sessions);
    if (old.state == .running) runtimeFail("session {d} is still running; restart starts an ended session again ('tuppet stop {d}' ends it)", .{ old.id, old.id });
    var id_buf: [20]u8 = undefined;
    const env = try currentEnv(gpa, true);
    defer freeEnv(gpa, env);
    const reply = try call(gpa, protocol.RunReq{ .like = std.fmt.bufPrint(&id_buf, "{d}", .{old.id}) catch unreachable, .env = env }, protocol.StatusResp);
    defer reply.deinit();
    if (json) return printJson(gpa, reply.line);
    try stdoutPrint("{d}\n", .{reply.parsed.value.status.?.id});
}

/// The one session `ref` picks among `found`, or a failure that says why.
pub fn onlyOne(gpa: std.mem.Allocator, ref: []const u8, found: []const Status) !Status {
    if (found.len == 0) {
        if (names.kind(ref) == .id) runtimeFail("no session with id {s}", .{ref});
        const text = try names.noMatch(gpa, ref);
        defer gpa.free(text);
        runtimeFail("{s}", .{text});
    }
    if (found.len > 1) {
        const text = try names.tooMany(gpa, ref, found);
        defer gpa.free(text);
        runtimeFail("{s}", .{text});
    }
    return found[0];
}

/// The id of the one session `ref` picks; fails the command otherwise.
pub fn resolveOne(gpa: std.mem.Allocator, ref: []const u8) !u64 {
    const listed = try call(gpa, protocol.ListReq{ .sessions = &.{ref} }, protocol.ListResp);
    defer listed.deinit();
    return (try onlyOne(gpa, ref, listed.parsed.value.sessions)).id;
}

/// This command's environment as "NAME=value" entries for a session. A
/// variable that is not UTF-8 cannot travel in a JSON string, so it is
/// left out, with a warning on stderr when `warn` is set.
pub fn currentEnv(gpa: std.mem.Allocator, warn: bool) ![]const []const u8 {
    var env_map = try std.process.Environ.createMap(io_mod.environ, gpa);
    defer env_map.deinit();
    var env: std.ArrayList([]const u8) = .empty;
    errdefer freeEnv(gpa, env.items);
    var env_it = env_map.iterator();
    while (env_it.next()) |entry| {
        // Windows' hidden per-drive entries ("=C:=C:\dir") are not
        // variables a child can be given.
        if (entry.key_ptr.len == 0 or entry.key_ptr.*[0] == '=') continue;
        if (!std.unicode.utf8ValidateSlice(entry.key_ptr.*) or !std.unicode.utf8ValidateSlice(entry.value_ptr.*)) {
            if (warn) stderrPrint("tuppet: warning: leaving out the environment variable {f}, which is not UTF-8\n", .{std.unicode.fmtUtf8(entry.key_ptr.*)}) catch {};
            continue;
        }
        try env.ensureUnusedCapacity(gpa, 1);
        env.appendAssumeCapacity(try std.fmt.allocPrint(gpa, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }));
    }
    return env.toOwnedSlice(gpa);
}

pub fn freeEnv(gpa: std.mem.Allocator, env: []const []const u8) void {
    for (env) |entry| gpa.free(entry);
    gpa.free(env);
}

pub fn cmdResize(gpa: std.mem.Allocator, args: []const []const u8) !void {
    const usage = "usage: tuppet resize <session> WxH [-j]";
    var json = false;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(gpa);
    for (args) |a| {
        if (isOpt(a, "--json", "-j")) json = true else try rest.append(gpa, a);
    }
    const ops = try takeOperands(rest.items, 2, usage);
    try checkRef(ops[0]);
    const size = try parseSize(ops[1]);
    const reply = try call(gpa, protocol.ResizeReq{ .session = ops[0], .cols = size[0], .rows = size[1] }, protocol.ResizeResp);
    defer reply.deinit();
    if (json) return printJson(gpa, reply.line);
    if (reply.parsed.value.resize_seq) |seq| try stdoutPrint("{d}\n", .{seq}) else try stdoutWrite("-\n");
}

const view_usage = "usage: tuppet view <session> [-f plain|vt|html] [-s] [--unwrap] [--since SEQ] [--styles] [-j]";

pub fn cmdView(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var req: protocol.ViewReq = .{ .session = "" };
    var ref: ?[]const u8 = null;
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isOpt(a, "--format", "-f")) {
            const value = try optValue(args, &i);
            req.format = std.meta.stringToEnum(protocol.ViewFormat, value) orelse
                return cliFail("unknown format '{s}' (choose plain, vt, or html; --json gives JSON)", .{value});
        } else if (isOpt(a, "--scrollback", "-s")) {
            req.scrollback = true;
        } else if (std.mem.eql(u8, a, "--unwrap")) {
            req.unwrap = true;
        } else if (std.mem.eql(u8, a, "--since")) {
            const value = try optValue(args, &i);
            req.since = protocol.parseDecimal(u64, value) orelse return cliFail("invalid --since '{s}' (expected a seq, such as a status's seq)", .{value});
        } else if (std.mem.eql(u8, a, "--styles")) {
            req.styles = true;
        } else if (isOpt(a, "--json", "-j")) {
            json = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return unknownOption(a, view_usage);
        } else if (ref != null) {
            return cliFail("unexpected argument '{s}' ({s})", .{ a, view_usage });
        } else {
            try checkRef(a);
            ref = a;
        }
    }
    req.session = ref orelse return cliFail(view_usage, .{});
    if (req.styles and req.format != .plain) return cliFail("--styles goes with plain text; -f vt and -f html carry the styles already", .{});
    const reply = try call(gpa, req, protocol.ViewResp);
    defer reply.deinit();
    if (json) return printJson(gpa, reply.line);
    const text = reply.parsed.value.text;
    try stdoutWrite(text);
    // With --since every line ends in a newline, and no change prints nothing.
    if (req.since == null and !std.mem.endsWith(u8, text, "\n")) try stdoutWrite("\n");
    if (reply.parsed.value.styles) |st| {
        const out = try stylesText(gpa, st, max_printed_runs);
        defer gpa.free(out);
        try stdoutWrite(out);
    }
}

/// At most this many runs print; -j has them all.
const max_printed_runs = 200;

/// `base: key=value…`, then a line `row:c1-c2 key=value… "text"` per run
/// with the keys whose values differ from the base, for the first `limit`
/// runs.
pub fn stylesText(gpa: std.mem.Allocator, st: protocol.Styles, limit: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("base:");
    if (!try writeAttrs(w, st.base, .{})) try w.writeAll(" default");
    try w.writeAll("\n");
    if (st.truncated) try w.writeAll("(runs of the rows above were left out to fit the reply)\n");
    for (st.runs[0..@min(st.runs.len, limit)]) |run| {
        try w.print("{d}:{d}-{d}", .{ run.row, run.col, run.col + run.cols -| 1 });
        _ = try writeAttrs(w, run.attrs, st.base);
        try w.writeAll(" \"");
        for (run.text) |c| {
            if (c == '"' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
        try w.writeAll("\"\n");
    }
    if (st.runs.len > limit) try w.print("... {d} more runs; 'tuppet view --styles -j' lists them all\n", .{st.runs.len - limit});
    return out.toOwnedSlice();
}

/// ` key=value` for each attribute of `attrs` that differs from `base`;
/// whether there was any.
fn writeAttrs(w: *std.Io.Writer, attrs: protocol.Attrs, base: protocol.Attrs) !bool {
    var any = false;
    inline for (@typeInfo(protocol.Attrs).@"struct".field_names) |name| {
        const v = @field(attrs, name);
        const b = @field(base, name);
        switch (@TypeOf(v)) {
            ?[]const u8 => {
                const same = if (v) |x| (if (b) |y| std.mem.eql(u8, x, y) else false) else b == null;
                if (!same) try w.print(" {s}={s}", .{ name, v orelse "none" });
                any = any or !same;
            },
            else => if (!std.meta.eql(v, b)) {
                any = true;
                switch (@TypeOf(v)) {
                    // A flag that is on is its bare name.
                    bool => if (v) try w.print(" {s}", .{name}) else try w.print(" {s}=false", .{name}),
                    protocol.Underline => try w.print(" {s}={s}", .{ name, @tagName(v) }),
                    else => try w.print(" {s}={f}", .{ name, v }),
                }
            },
        }
    }
    return any;
}

const png_usage = "usage: tuppet png <session> <file.png> [-f SPEC] [--font-size N] [-j]";

/// Render the session screen as a PNG and write it to `path`.
pub fn cmdPng(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var spec: ?[]const u8 = null;
    var size: ?u16 = null;
    var json = false;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isOpt(a, "--fonts", "-f")) {
            spec = try optValue(args, &i);
        } else if (std.mem.eql(u8, a, "--font-size")) {
            const value = try optValue(args, &i);
            size = fontSize(value) orelse return cliFail("invalid --font-size '{s}' (expected {d} to {d} pixels)", .{ value, fonts.min_font_size, fonts.max_font_size });
        } else if (isOpt(a, "--json", "-j")) {
            json = true;
        } else try rest.append(gpa, a);
    }
    const ops = try takeOperands(rest.items, 2, png_usage);
    try checkRef(ops[0]);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const chosen = try pngFonts(arena.allocator(), spec, size);
    try checkProtocol(gpa);
    // The defaults go unsaid, so an older daemon still draws them.
    const default = chosen.fonts.len == 1 and std.mem.eql(u8, chosen.fonts[0], "default") and !chosen.bitmap and chosen.font_size == null;
    if (!default and !daemonHas("fonts")) {
        runtimeFail("the daemon on {s} is an older tuppet that draws only its own font; " ++ old_daemon_hint ++ " (ended sessions are kept, running programs end)", .{daemon_path});
    }
    const req: protocol.PngReq = if (default) .{ .session = ops[0] } else .{ .session = ops[0], .fonts = chosen.fonts, .bitmap = chosen.bitmap, .font_size = chosen.font_size };
    const reply = try request(gpa, req, protocol.PngResp);
    defer reply.deinit();
    if (!reply.parsed.value.ok) {
        // The daemon's build decides which fonts there are.
        if (daemon_variant.len > 0 and !std.mem.eql(u8, daemon_variant, protocol.variant) and failedWith(gpa, reply.line, .bad_request)) {
            const text = try failureText(gpa, reply.line);
            runtimeFail("{s}; the running daemon is a {s} build and this tuppet a {s} one, so 'tuppet shutdown' lets this one start its own", .{ text, daemon_variant, protocol.variant });
        }
        failReply(gpa, reply.line, false);
    }
    const b64 = reply.parsed.value.png_b64;
    if (b64.len == 0) return error.MissingPng;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    const decoded = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, b64);

    // plat.create needs a sentinel-terminated path.
    const path = try gpa.dupeSentinel(u8, ops[1], 0);
    defer gpa.free(path);
    const file = plat.create(path, .blocking) catch |err| runtimeFail("cannot create '{s}': {s}", .{ ops[1], plat.createErrorText(err) });
    defer plat.close(file);
    plat.writeAll(file, decoded) catch runtimeFail("cannot write '{s}'", .{ops[1]});
    if (json) {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, reply.line, .{});
        defer parsed.deinit();
        if (parsed.value == .object) {
            _ = parsed.value.object.orderedRemove("ok");
            _ = parsed.value.object.orderedRemove("png_b64");
        }
        const out = try protocol.stringifyAlloc(gpa, parsed.value);
        defer gpa.free(out);
        try stdoutWrite(out);
        try stdoutWrite("\n");
    }
}

fn fontSize(text: []const u8) ?u16 {
    const n = protocol.parseDecimal(u16, text) orelse return null;
    return if (n >= fonts.min_font_size and n <= fonts.max_font_size) n else null;
}

/// The fonts of a png request, resolved here because the daemon renders:
/// `-f`, else TUPPET_PNG_FONTS, else `[png] fonts`, else `default`; presets
/// expanded, paths made absolute, from the config file's directory when
/// the config gives them. The size: --font-size, else the size of a preset
/// `-f` names, else TUPPET_PNG_FONT_SIZE, else the size of a preset in the
/// list, else `[png] font_size`.
fn pngFonts(a: std.mem.Allocator, flag: ?[]const u8, flag_size: ?u16) !struct { fonts: []const []const u8, bitmap: bool, font_size: ?u16 } {
    var diag: config_mod.Diagnostic = .{};
    const config = config_mod.load(a, &diag) catch |err| switch (err) {
        error.BadConfig => runtimeFail("{s}", .{diag.message}),
        else => return err,
    };
    // The entries live in `a`, past the config.
    const env_spec: ?[]const u8 = if (std.c.getenv("TUPPET_PNG_FONTS")) |v| std.mem.span(v) else null;
    const source: []const u8, const entries: []const []const u8 = if (flag) |f|
        .{ "-f", try splitSpec(a, f, "-f") }
    else if (env_spec != null and env_spec.?.len > 0)
        .{ "TUPPET_PNG_FONTS", try splitSpec(a, env_spec.?, "TUPPET_PNG_FONTS") }
    else if (config.png_fonts) |list|
        .{ "[png] fonts", list }
    else
        .{ "", &.{"default"} };

    var out: std.ArrayList([]const u8) = .empty;
    var bitmap = false;
    var preset_size: ?u16 = null;
    for (entries) |entry| {
        if (std.meta.stringToEnum(fonts.Builtin, entry) != null or std.mem.eql(u8, entry, "default")) {
            try out.append(a, entry);
        } else if (std.mem.eql(u8, entry, "bitmap")) {
            bitmap = true;
        } else if (fonts.isPath(entry)) {
            try out.append(a, try fontPath(a, entry, if (std.mem.eql(u8, source, "[png] fonts")) config.dir else null));
        } else for (config.png_presets) |preset| {
            if (!std.mem.eql(u8, preset.name, entry)) continue;
            if (preset_size == null) preset_size = preset.size;
            for (preset.fonts) |e| {
                if (std.mem.eql(u8, e, "bitmap")) {
                    bitmap = true;
                } else try out.append(a, if (fonts.isPath(e)) try fontPath(a, e, config.dir) else e);
            }
            break;
        } else {
            var known: std.ArrayList(u8) = .empty;
            for (config.png_presets) |preset| try known.print(a, "{s}{s}", .{ if (known.items.len == 0) "" else ", ", preset.name });
            return cliFail("unknown font '{s}' in {s} (built-in: {s}; presets: {s}; a path needs a / or a dot)", .{ entry, source, fonts.builtinNames(), if (known.items.len == 0) "none" else known.items });
        }
    }
    // A preset named on the command line is as explicit as --font-size.
    var size = flag_size orelse if (flag != null) preset_size else null;
    if (size == null) if (std.c.getenv("TUPPET_PNG_FONT_SIZE")) |v| {
        const value = std.mem.span(v);
        if (value.len > 0) size = fontSize(value) orelse return cliFail("invalid TUPPET_PNG_FONT_SIZE '{s}' (expected {d} to {d} pixels)", .{ value, fonts.min_font_size, fonts.max_font_size });
    };
    return .{ .fonts = out.items, .bitmap = bitmap, .font_size = size orelse preset_size orelse config.png_font_size };
}

fn splitSpec(a: std.mem.Allocator, spec: []const u8, source: []const u8) ![]const []const u8 {
    var empty: usize = 0;
    return config_mod.splitFonts(a, spec, &empty) catch |err| switch (err) {
        error.EmptyEntry => cliFail("{s}: font {d} of '{s}' is empty", .{ source, empty, spec }),
        else => err,
    };
}

/// A font file's path for the daemon: `~` is the home directory, and a
/// relative path is anchored at `base`, else the working directory.
fn fontPath(a: std.mem.Allocator, path: []const u8, base: ?[]const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const name = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        const home = std.mem.span(std.c.getenv(name) orelse "");
        if (!std.fs.path.isAbsolute(home)) return cliFail("cannot expand '{s}': {s} is not set to an absolute path", .{ path, name });
        return std.fs.path.join(a, &.{ home, path[@min(path.len, 2)..] });
    }
    if (path[0] == '~') return cliFail("cannot expand '{s}': only ~/ is understood", .{path});
    if (base) |dir| if (!std.fs.path.isAbsolute(path)) return std.fs.path.resolve(a, &.{ dir, path });
    return absolutePath(a, path);
}

/// The presets of the config file, for `tuppet help fonts`.
pub fn printFontPresets(gpa: std.mem.Allocator) !void {
    var diag: config_mod.Diagnostic = .{};
    var config = config_mod.load(gpa, &diag) catch |err| switch (err) {
        error.BadConfig => runtimeFail("{s}", .{diag.message}),
        else => return err,
    };
    defer config.deinit();
    if (config.png_presets.len == 0) return stdoutWrite("\npresets in your config: none\n");
    try stdoutWrite("\npresets in your config:\n");
    for (config.png_presets) |preset| {
        try stdoutPrint("  {s} = ", .{preset.name});
        for (preset.fonts, 0..) |e, n| try stdoutPrint("{s}{s}", .{ if (n == 0) "" else ",", e });
        if (preset.size) |size| try stdoutPrint(" (size {d})", .{size});
        try stdoutWrite("\n");
    }
}

/// The format a recording file's name asks for: .cast or .trace.
fn recordFormat(path: []const u8) ?protocol.RecordFormat {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".cast")) return .cast;
    if (std.mem.eql(u8, ext, ".trace")) return .trace;
    return null;
}

fn recordFileFormat(flag: []const u8, path: []const u8) !protocol.RecordFormat {
    return recordFormat(path) orelse cliFail("{s} '{s}': name the file .cast (asciicast) or .trace (trace)", .{ flag, path });
}

/// A recording runs this long at most with -t.
const max_record_ms: u64 = 24 * std.time.ms_per_hour;

const record_usage = "usage: tuppet record <session> (--start FILE [conditions] [-t DUR] [--input] | --mark LABEL | --stop) [-j]";

/// Start, annotate, or stop a recording. Two formats: "cast" (asciicast
/// v2) and "trace" (a JSONL timeline of input, screen-diff, and stop
/// events).
pub fn cmdRecord(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var ref: ?[]const u8 = null;
    var flags: ConditionFlags = .{};
    defer flags.deinit(gpa);
    var start: ?[]const u8 = null;
    var mark: ?[]const u8 = null;
    var stop = false;
    var input = false;
    var json = false;
    var max_ms: ?u64 = null;
    var conditions = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isOpt(a, "--timeout", "-t")) {
            const ms = try durationValue(args, &i, 1);
            if (ms > max_record_ms) return cliFail("{s} must be at most 24h", .{a});
            max_ms = ms;
        } else if (try flags.take(gpa, args, &i)) {
            conditions = true;
        } else if (std.mem.eql(u8, a, "--start")) {
            start = try optValue(args, &i);
        } else if (std.mem.eql(u8, a, "--mark")) {
            mark = try optValue(args, &i);
        } else if (std.mem.eql(u8, a, "--stop")) {
            stop = true;
        } else if (std.mem.eql(u8, a, "--input")) {
            input = true;
        } else if (isOpt(a, "--json", "-j")) {
            json = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return unknownOption(a, record_usage);
        } else if (ref != null) {
            return cliFail("unexpected argument '{s}' ({s})", .{ a, record_usage });
        } else {
            try checkRef(a);
            ref = a;
        }
    }
    const session = ref orelse return cliFail(record_usage, .{});
    var actions: [3][]const u8 = undefined;
    var n: usize = 0;
    for ([_]struct { []const u8, bool }{ .{ "--start", start != null }, .{ "--mark", mark != null }, .{ "--stop", stop } }) |action| {
        if (!action[1]) continue;
        actions[n] = action[0];
        n += 1;
    }
    switch (n) {
        0 => return cliFail("record needs one of --start FILE, --mark LABEL, and --stop", .{}),
        1 => {},
        2 => return cliFail("{s} and {s} conflict: give one of them", .{ actions[0], actions[1] }),
        else => return cliFail("--start, --mark, and --stop conflict: give one of them", .{}),
    }
    if (start == null and (conditions or max_ms != null or input)) {
        return cliFail("conditions, -t, and --input go with --start", .{});
    }
    var req: protocol.RecordReq = .{ .session = session, .mark = mark, .stop = stop };
    if (start) |path| {
        const format = try recordFileFormat("--start", path);
        const until = try flags.finish(gpa);
        req.start = .{
            .path = try absolutePath(gpa, path),
            .format = format,
            .input = input,
            .until = if (until.len > 0) until else null,
            .max_ms = max_ms,
        };
    }
    defer if (req.start) |st| gpa.free(st.path.?);
    const reply = try call(gpa, req, protocol.RecordResp);
    defer reply.deinit();
    if (json) return printJson(gpa, reply.line);
    const resp = reply.parsed.value;
    if (stop) try stdoutPrint("{s} {s}\n", .{ if (resp.reason) |why| @tagName(why) else "-", resp.path orelse "-" });
}

/// A reference that is looked up once: the first reply's id is used from
/// then on.
const SessionTarget = struct {
    given: []const u8,
    id_buf: [20]u8 = undefined,
    id: ?[]const u8 = null,

    fn init(given: []const u8) SessionTarget {
        return .{ .given = given };
    }

    fn ref(t: *const SessionTarget) []const u8 {
        return t.id orelse t.given;
    }

    fn pin(t: *SessionTarget, id: u64) void {
        if (t.id == null) t.id = std.fmt.bufPrint(&t.id_buf, "{d}", .{id}) catch unreachable;
    }

    /// `call`, where a session removed after the id was pinned exits 4.
    fn call(t: *const SessionTarget, gpa: std.mem.Allocator, req: anytype, comptime Resp: type) !Reply(Resp) {
        const reply = try request(gpa, req, Resp);
        if (reply.parsed.value.ok) return reply;
        failReply(gpa, reply.line, t.id != null);
    }
};

/// How long a wait waits unless -t says otherwise, and at most.
const default_wait_ms: u64 = 30 * std.time.ms_per_s;
const max_wait_ms: u64 = 10 * std.time.ms_per_min;

/// The NAME=TEXT value of the option at `args[i.*]`, an alert.
fn alertValue(args: []const []const u8, i: *usize) !alert.Rule {
    const flag = args[i.*];
    const value = try optValue(args, i);
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return cliFail("{s} '{s}': expected NAME=TEXT", .{ flag, value });
    const rule: alert.Rule = .{ .name = value[0..eq], .match = value[eq + 1 ..] };
    if (alert.ruleError(rule)) |why| return cliFail("{s} '{s}': {s}", .{ flag, value, why });
    return rule;
}

/// The alert name of the --hit option at `args[i.*]`: a name or '*'.
fn hitValue(args: []const []const u8, i: *usize) ![]const u8 {
    const flag = args[i.*];
    const name = try optValue(args, i);
    if (std.mem.eql(u8, name, "*")) return name;
    if (names.nameError(name)) |why| return cliFail("{s} '{s}' is not an alert's name or '*': {s}", .{ flag, name, why });
    return name;
}

/// The hit number of the option at `args[i.*]`.
fn hitNumber(args: []const []const u8, i: *usize) !u64 {
    const flag = args[i.*];
    const value = try optValue(args, i);
    return protocol.parseDecimal(u64, value) orelse cliFail("invalid {s} '{s}' (expected a hit's number, such as an outcome line's hit_seq)", .{ flag, value });
}

/// The text of the -m option at `args[i.*]`.
fn matchValue(args: []const []const u8, i: *usize) ![]const u8 {
    const flag = args[i.*];
    const text = try optValue(args, i);
    if (text.len == 0) return cliFail("{s} needs a non-empty value", .{flag});
    if (text.len > cond.max_match_len) return cliFail("{s} takes at most {d} bytes", .{ flag, cond.max_match_len });
    if (std.mem.findAny(u8, text, "\r\n") != null) return cliFail("{s} cannot contain a line break: text is matched one line at a time", .{flag});
    return text;
}

/// The duration of a wait's deadline option at `args[i.*]`.
pub fn waitDuration(args: []const []const u8, i: *usize) !u64 {
    const flag = args[i.*];
    const ms = try durationValue(args, i, 0);
    if (ms > max_wait_ms) return cliFail("{s} must be at most 10m", .{flag});
    return ms;
}

/// The condition flags that wait and run share. Consecutive conditions
/// are alternatives; the modifiers apply to every one of them.
const ConditionFlags = struct {
    until: std.ArrayList(protocol.Condition) = .empty,
    icase: bool = false,
    after_input: bool = false,
    since: ?u64 = null,
    after_hit: ?u64 = null,
    timeout_ms: ?u64 = null,

    fn deinit(f: *ConditionFlags, gpa: std.mem.Allocator) void {
        f.until.deinit(gpa);
    }

    /// Take the flag at `args[i.*]` if it is one of them; `i` then points
    /// at its value.
    fn take(f: *ConditionFlags, gpa: std.mem.Allocator, args: []const []const u8, i: *usize) !bool {
        const a = args[i.*];
        if (isOpt(a, "--match", "-m")) {
            try f.until.append(gpa, .{ .match = try matchValue(args, i) });
        } else if (isOpt(a, "--ended", "-e")) {
            try f.until.append(gpa, .{ .ended = true });
        } else if (isOpt(a, "--idle", "-i")) {
            try f.until.append(gpa, .{ .idle_ms = try durationValue(args, i, 0) });
        } else if (std.mem.eql(u8, a, "--settled")) {
            try f.until.append(gpa, .{ .settled_ms = try durationValue(args, i, 0) });
        } else if (std.mem.eql(u8, a, "--gone")) {
            try f.until.append(gpa, .{ .match = try matchValue(args, i), .absent = true });
        } else if (std.mem.eql(u8, a, "--hidden-input")) {
            try f.until.append(gpa, .{ .hidden_input = true });
        } else if (std.mem.eql(u8, a, "--hit")) {
            try f.until.append(gpa, .{ .hit = .{ .name = try hitValue(args, i) } });
        } else if (std.mem.eql(u8, a, "--after-hit")) {
            f.after_hit = try hitNumber(args, i);
        } else if (std.mem.eql(u8, a, "--icase")) {
            f.icase = true;
        } else if (std.mem.eql(u8, a, "--after-input")) {
            f.after_input = true;
        } else if (std.mem.eql(u8, a, "--since")) {
            const value = try optValue(args, i);
            f.since = protocol.parseDecimal(u64, value) orelse return cliFail("invalid --since '{s}' (expected a seq, such as a status's seq)", .{value});
        } else if (isOpt(a, "--timeout", "-t")) {
            f.timeout_ms = try waitDuration(args, i);
        } else return false;
        return true;
    }

    /// The conditions with the modifiers applied; empty without any.
    fn finish(f: *ConditionFlags, gpa: std.mem.Allocator) ![]const protocol.Condition {
        if (f.after_input and f.since != null) return cliFail("--after-input and --since cannot be combined", .{});
        if (f.until.items.len == 0) {
            if (f.icase) return cliFail("--icase needs -m TEXT or --gone TEXT", .{});
            // Alone, they wait for any text change after that point.
            if (f.after_input or f.since != null) {
                try f.until.append(gpa, .{});
            } else if (f.after_hit != null) {
                return cliFail("--after-hit needs --hit NAME", .{});
            } else if (f.timeout_ms != null) {
                return cliFail("--timeout needs a condition: -m TEXT, --gone TEXT, -e, -i DUR, --settled DUR, --hidden-input, --hit NAME, --since SEQ, or --after-input", .{});
            } else return &.{};
        }
        if (f.icase) for (f.until.items) |c| {
            if (c.match != null) break;
        } else return cliFail("--icase needs -m TEXT or --gone TEXT", .{});
        if (f.after_hit != null) for (f.until.items) |c| {
            if (c.hit != null) break;
        } else return cliFail("--after-hit needs --hit NAME", .{});
        if (f.after_input or f.since != null) for (f.until.items) |c| {
            if (c.absent) return cliFail("--gone counts from the wait's start; it cannot be combined with {s}", .{if (f.after_input) "--after-input" else "--since"});
        };
        for (f.until.items) |*c| {
            if (c.match != null) c.icase = f.icase;
            if (c.hit) |*h| h.after_hit = f.after_hit;
            if (f.after_input) c.after_input = .latest;
            c.since = f.since;
        }
        return f.until.items;
    }

    fn timeout(f: *const ConditionFlags) u64 {
        return f.timeout_ms orelse default_wait_ms;
    }
};

const wait_usage = "usage: tuppet wait <session>... [-m TEXT] [--gone TEXT] [-e] [-i DUR] [--settled DUR] [--hidden-input] [--hit NAME] [--icase] [--after-input] [--since SEQ] [--after-hit N] [-t DUR] [--any] [--view] [--stats] [-j]";

pub fn cmdWait(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var flags: ConditionFlags = .{};
    defer flags.deinit(gpa);
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(gpa);
    var any = false;
    var show = false;
    var json = false;
    var stats = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (try flags.take(gpa, args, &i)) continue;
        if (std.mem.eql(u8, a, "--any")) {
            any = true;
        } else if (std.mem.eql(u8, a, "--view")) {
            show = true;
        } else if (std.mem.eql(u8, a, "--stats")) {
            stats = true;
        } else if (isOpt(a, "--json", "-j")) {
            json = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return unknownOption(a, wait_usage);
        } else {
            try checkRef(a);
            try refs.append(gpa, a);
        }
    }
    if (refs.items.len == 0) return cliFail(wait_usage, .{});
    const until = try flags.finish(gpa);
    if (until.len == 0) return cliFail("wait needs a condition: -m TEXT, --gone TEXT, -e, -i DUR, --settled DUR, --hidden-input, --hit NAME, --since SEQ, or --after-input", .{});
    if (refs.items.len > 1 and !any) return cliFail("waiting on several sessions needs --any (the first to meet a condition wins)", .{});
    if (stats and any) return cliFail("--stats counts for one session; drop --any or --stats", .{});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sessions = if (any) try expandPatterns(arena_state.allocator(), refs.items) else refs.items;
    const req: protocol.WaitReq = .{
        .session = sessions[0],
        .until = until,
        .timeout_ms = flags.timeout(),
        .format = if (show) .plain else null,
    };
    var out: WaitOutput = .{ .json = json, .show = show };
    if (stats) out.stats = try StatsBase.of(gpa, sessions[0], flags.since, flags.after_input);
    if (sessions.len == 1) {
        const reply = try requestWait(gpa, req);
        defer reply.deinit();
        const code = try reportWait(gpa, reply, req, out);
        if (code != exit_code.ok) std.process.exit(code);
        return;
    }
    return waitAny(gpa, req, sessions, out);
}

/// For --any: each pattern among `refs` stands for the sessions it
/// matches now, by id; ids and names stay as they are, and no reference
/// comes twice. A pattern that matches nothing fails the command.
fn expandPatterns(a: std.mem.Allocator, refs: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (refs) |ref| {
        if (names.kind(ref) != .pattern) {
            try appendNew(a, &out, ref);
            continue;
        }
        const listed = try call(a, protocol.ListReq{ .sessions = &.{ref} }, protocol.ListResp);
        const found = listed.parsed.value.sessions;
        if (found.len == 0) runtimeFail("{s}", .{try names.noMatch(a, ref)});
        for (found) |st| try appendNew(a, &out, try std.fmt.allocPrint(a, "{d}", .{st.id}));
    }
    return out.items;
}

fn appendNew(a: std.mem.Allocator, list: *std.ArrayList([]const u8), ref: []const u8) !void {
    for (list.items) |have| if (std.mem.eql(u8, have, ref)) return;
    try list.append(a, ref);
}

const WaitOutput = struct {
    json: bool = false,
    /// Print the screen after the outcome line.
    show: bool = false,
    /// Ends the outcome line when no condition was met.
    failed_suffix: []const u8 = "",
    /// Add what --stats counts, from here.
    stats: ?StatsBase = null,
};

/// Where --stats counts from: the counters of the session's status before
/// the request, and when it was sent.
const StatsBase = struct {
    out_bytes: ?u64 = 0,
    draws: ?u64 = 0,
    full_clears: ?u64 = 0,
    /// rows_changed counts the rows of the screen that changed after this
    /// seq.
    since: u64,
    /// Monotonic nanoseconds.
    sent_ns: i64,
    /// first_change_ms counts from the latest input, not from the request.
    from_input: bool = false,

    /// The base for a request about `ref` sent now; `since` overrides
    /// the status's seq.
    fn of(gpa: std.mem.Allocator, ref: []const u8, since: ?u64, after_input: bool) !StatsBase {
        const listed = try call(gpa, protocol.ListReq{ .sessions = &.{ref} }, protocol.ListResp);
        defer listed.deinit();
        const st = try onlyOne(gpa, ref, listed.parsed.value.sessions);
        const seq = st.seq orelse st.start_seq;
        return .{
            .out_bytes = st.out_bytes,
            .draws = st.draws,
            .full_clears = st.full_clears,
            .since = since orelse if (after_input) st.input_seq orelse st.start_seq else seq,
            .sent_ns = io_mod.nowNanos(),
        };
    }
};

/// What --stats adds to an outcome line, for a session whose status `st`
/// came with the reply: the deltas of its counters, the rows of the
/// screen that changed, and when the screen last changed, all sampled
/// around the request, so approximate.
const Stats = struct {
    out_bytes: ?u64 = null,
    draws: ?u64 = null,
    full_clears: ?u64 = null,
    rows_changed: ?u64 = null,
    rows: u64 = 0,
    first_change_ms: ?u64 = null,

    fn of(gpa: std.mem.Allocator, base: StatsBase, st: Status) Stats {
        var out: Stats = .{ .rows = st.rows };
        inline for (.{ "out_bytes", "draws", "full_clears" }) |f| {
            if (@field(st, f)) |now| if (@field(base, f)) |was| {
                @field(out, f) = now -| was;
            };
        }
        const elapsed: ?u64 = if (base.from_input)
            st.input_idle_ms
        else
            @intCast(@divTrunc(@max(0, io_mod.nowNanos() - base.sent_ns), std.time.ns_per_ms));
        // Within the same millisecond as the start, a draw tells a change
        // from none.
        const drew = if (out.draws) |n| n > 0 else false;
        if (elapsed) |ms| if (st.change_idle_ms < ms or (st.change_idle_ms == ms and drew)) {
            out.first_change_ms = ms - st.change_idle_ms;
        };
        var id_buf: [20]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{st.id}) catch unreachable;
        if (request(gpa, protocol.ViewReq{ .session = id, .since = base.since }, protocol.ViewResp)) |reply| {
            defer reply.deinit();
            if (reply.parsed.value.ok) {
                var n: u64 = 0;
                for (reply.parsed.value.rows orelse &.{}) |row| n += @intFromBool(row >= 1);
                out.rows_changed = n;
            }
        } else |_| {}
        return out;
    }

    /// ` out_bytes=N draws=N full_clears=N rows_changed=k/N
    /// first_change_ms=N`, with `-` for what is not known.
    fn text(s: Stats, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        inline for (.{ "out_bytes", "draws", "full_clears" }) |f| {
            try w.writeAll(" " ++ f ++ "=");
            try printOptional(w, @field(s, f));
        }
        try w.writeAll(" rows_changed=");
        try printOptional(w, s.rows_changed);
        try w.print("/{d} first_change_ms=", .{s.rows});
        try printOptional(w, s.first_change_ms);
        return out.toOwnedSlice();
    }
};

/// One wait per session, each on its own connection; the first session
/// to meet a condition wins, and leaving closes the others' connections,
/// which ends their waits.
fn waitAny(gpa: std.mem.Allocator, template: protocol.WaitReq, refs: []const []const u8, out: WaitOutput) !void {
    // Checked once, before the threads share the connection state.
    try checkProtocol(gpa);
    const Slot = struct {
        req: protocol.WaitReq,
        reply: ?Reply(protocol.WaitResp) = null,
        err: ?anyerror = null,
        ready: std.atomic.Value(bool) = .init(false),
        seen: bool = false,
    };
    const Finished = struct {
        count: std.atomic.Value(u32) = .init(0),

        fn one(finished: *@This(), slot: *Slot, a: std.mem.Allocator) void {
            if (requestWait(a, slot.req)) |reply| slot.reply = reply else |err| slot.err = err;
            slot.ready.store(true, .release);
            _ = finished.count.fetchAdd(1, .acq_rel);
            io_mod.io().futexWake(u32, &finished.count.raw, 1);
        }
    };
    const slots = try gpa.alloc(Slot, refs.len);
    defer gpa.free(slots);
    var finished: Finished = .{};
    for (refs, slots) |ref, *slot| {
        slot.* = .{ .req = template };
        slot.req.session = ref;
        const thread = try std.Thread.spawn(.{}, Finished.one, .{ &finished, slot, gpa });
        thread.detach();
    }
    var exit: u8 = exit_code.ended;
    var left = refs.len;
    while (left > 0) {
        const count = finished.count.load(.acquire);
        for (slots) |*slot| {
            if (slot.seen or !slot.ready.load(.acquire)) continue;
            slot.seen = true;
            left -= 1;
            if (slot.err) |err| return err;
            const reply = slot.reply.?;
            if (!reply.parsed.value.ok) failReply(gpa, reply.line, false);
            // The other waits end with their connections.
            if (reply.parsed.value.outcome == .met) std.process.exit(try reportWait(gpa, reply, slot.req, out));
        }
        if (left == 0) break;
        io_mod.io().futexWaitTimeout(u32, &finished.count.raw, count, .{
            .duration = .{ .raw = .fromMilliseconds(100), .clock = .boot },
        }) catch {};
    }
    // None was met: each session's outcome, in order.
    for (slots) |*slot| {
        if (try reportWait(gpa, slot.reply.?, slot.req, out) == exit_code.timeout) exit = exit_code.timeout;
    }
    std.process.exit(exit);
}

/// Send a wait request, whose reply may take as long as its timeout.
fn requestWait(gpa: std.mem.Allocator, req: protocol.WaitReq) !Reply(protocol.WaitResp) {
    try checkProtocol(gpa);
    return requestRetried(gpa, req, protocol.WaitResp, waitReplyNs(req.timeout_ms));
}

/// How long the reply to a wait may take: its timeout, and some slack.
fn waitReplyNs(timeout_ms: u64) i64 {
    return @as(i64, @intCast(timeout_ms)) * std.time.ns_per_ms + 10 * std.time.ns_per_s;
}

/// Print a wait's outcome as wait and run do, and return the exit code it
/// calls for. A failed reply ends the command.
fn reportWait(gpa: std.mem.Allocator, reply: Reply(protocol.WaitResp), req: protocol.WaitReq, out: WaitOutput) !u8 {
    const resp = reply.parsed.value;
    if (!resp.ok) failReply(gpa, reply.line, false);
    const stats: ?Stats = if (out.stats) |base| if (resp.status) |st| Stats.of(gpa, base, st) else null else null;
    if (out.json) {
        if (stats) |s| try printJsonWith(gpa, reply.line, "stats", s) else try printJson(gpa, reply.line);
    } else {
        const stats_text = if (stats) |s| try s.text(gpa) else try gpa.dupe(u8, "");
        defer gpa.free(stats_text);
        const suffix = try std.mem.concat(gpa, u8, &.{ if (resp.outcome == .met) "" else out.failed_suffix, stats_text });
        defer gpa.free(suffix);
        const line = try outcomeLine(gpa, resp, req.until, req.session, suffix);
        defer gpa.free(line);
        try stdoutWrite(line);
        for (resp.hits) |hit| {
            const text = try hitLine(gpa, hit);
            defer gpa.free(text);
            try stdoutWrite(text);
        }
        if (out.show) if (resp.text) |text| {
            try stdoutWrite(text);
            if (!std.mem.endsWith(u8, text, "\n")) try stdoutWrite("\n");
        };
    }
    const st = resp.status;
    var id_buf: [20]u8 = undefined;
    const who = if (st) |known| std.fmt.bufPrint(&id_buf, "{d}", .{known.id}) catch unreachable else req.session;
    switch (resp.outcome) {
        .met => return exit_code.ok,
        .timeout => {
            var dur_buf: [24]u8 = undefined;
            try stderrPrint("tuppet: session {s}: no condition was met within {s}\n", .{ who, units.durationText(&dur_buf, req.timeout_ms) });
            if (st) |known| printChangedRows(gpa, known);
            return exit_code.timeout;
        },
        .ended => {
            try stderrPrint("tuppet: session {s} ended before a condition was met\n", .{who});
            if (st) |known| printChangedRows(gpa, known);
            return exit_code.ended;
        },
        .removed => {
            try stderrPrint("tuppet: session {s} was removed during the wait\n", .{who});
            return exit_code.ended;
        },
    }
}

/// The line a wait prints: `<outcome> <kind>#<index> <session> seq=N
/// input_seq=N hit_seq=N`, with `-` for what is unknown, `exit=` once the
/// session has ended, and then `suffix`.
fn outcomeLine(gpa: std.mem.Allocator, resp: protocol.WaitResp, until: []const protocol.Condition, ref: []const u8, suffix: []const u8) ![]u8 {
    var what_buf: [32]u8 = undefined;
    const what = if (resp.met) |i|
        std.fmt.bufPrint(&what_buf, "{s}#{d}", .{ if (i < until.len) until[i].kind() else "-", i }) catch unreachable
    else
        "-";
    return statusLine(gpa, @tagName(resp.outcome), what, resp.status, ref, suffix);
}

/// `<word> <what> <session> seq=N input_seq=N hit_seq=N[ exit=X]<suffix>`.
pub fn statusLine(gpa: std.mem.Allocator, word: []const u8, what: []const u8, status_: ?Status, ref: []const u8, suffix: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{s} {s} ", .{ word, what });
    const st = status_ orelse {
        try w.print("{s} seq=- input_seq=- hit_seq=-{s}\n", .{ ref, suffix });
        return out.toOwnedSlice();
    };
    try w.print("{d} seq=", .{st.id});
    try printOptional(w, st.seq);
    try w.writeAll(" input_seq=");
    try printOptional(w, st.input_seq);
    try w.writeAll(" hit_seq=");
    try printOptional(w, st.hit_seq);
    if (st.exit) |exit| {
        // As list says it: whoever stopped it knows the signal.
        if (exit.stopped) {
            try w.writeAll(" exit=stopped");
        } else if (exit.code) |code| try w.print(" exit={d}", .{code}) else try w.print(" exit={s}", .{exit.signal orelse "-"});
    }
    try w.print("{s}\n", .{suffix});
    return out.toOwnedSlice();
}

/// `hit N <alerts> <line>`, the line wait and do print for a hit.
pub fn hitLine(gpa: std.mem.Allocator, hit: protocol.Hit) ![]u8 {
    const alerts = try std.mem.join(gpa, ",", hit.alerts);
    defer gpa.free(alerts);
    return std.fmt.allocPrint(gpa, "hit {d} {s} {s}\n", .{ hit.n, alerts, hit.line });
}

fn printOptional(w: *std.Io.Writer, value: ?u64) !void {
    if (value) |v| try w.print("{d}", .{v}) else try w.writeAll("-");
}

/// The last few lines that changed since the session's latest input (or
/// its start), on stderr, so a failed wait shows what happened.
fn printChangedRows(gpa: std.mem.Allocator, st: Status) void {
    const shown_lines = 5;
    var id_buf: [20]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}", .{st.id}) catch unreachable;
    const since = st.input_seq orelse st.start_seq;
    const reply = request(gpa, protocol.ViewReq{ .session = id, .since = since }, protocol.ViewResp) catch return;
    defer reply.deinit();
    if (!reply.parsed.value.ok) return;
    const text = reply.parsed.value.text;
    const what = if (st.input_seq != null) "the latest input" else "the start";
    if (text.len == 0) {
        stderrPrint("tuppet: nothing changed on the screen since {s}\n", .{what}) catch {};
        return;
    }
    var start = text.len - 1;
    var n: usize = 0;
    while (start > 0) : (start -= 1) {
        if (text[start - 1] != '\n') continue;
        n += 1;
        if (n == shown_lines) break;
    }
    stderrPrint("tuppet: the last lines that changed since {s}:\n{s}", .{ what, text[start..] }) catch {};
}

pub fn cmdStop(gpa: std.mem.Allocator, args: []const []const u8) !void {
    return eachSession(gpa, args, .stop);
}

pub fn cmdRemove(gpa: std.mem.Allocator, args: []const []const u8) !void {
    return eachSession(gpa, args, .remove);
}

pub fn cmdAck(gpa: std.mem.Allocator, args: []const []const u8) !void {
    return eachSession(gpa, args, .ack);
}

/// Stop, remove, or acknowledge every session `args` picks, in one
/// request. The daemon reports each failure and still does the rest. The
/// exit code is the one the failures' codes agree on (4 when each session
/// had ended), else 1. With -f, remove stops running sessions first, and a
/// reference that picks nothing is no failure.
fn eachSession(gpa: std.mem.Allocator, args: []const []const u8, comptime action: enum { stop, remove, ack }) !void {
    const usage = switch (action) {
        .stop => "usage: tuppet stop <session>... [-j]",
        .remove => "usage: tuppet remove <session>... [-f] [-j]",
        .ack => "usage: tuppet ack <session>... [-j]",
    };
    var force = false;
    var json = false;
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(gpa);
    for (args) |a| {
        if (isOpt(a, "--json", "-j")) {
            json = true;
        } else if (action == .remove and isOpt(a, "--force", "-f")) {
            force = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return unknownOption(a, usage);
        } else {
            try checkRef(a);
            try refs.append(gpa, a);
        }
    }
    if (refs.items.len == 0) return cliFail(usage, .{});
    const reply = try switch (action) {
        .stop => call(gpa, protocol.StopReq{ .sessions = refs.items }, protocol.ResultsResp),
        .remove => call(gpa, protocol.RemoveReq{ .sessions = refs.items, .force = force }, protocol.ResultsResp),
        .ack => call(gpa, protocol.AckReq{ .sessions = refs.items }, protocol.ResultsResp),
    };
    defer reply.deinit();
    var exit: u8 = exit_code.ok;
    for (reply.parsed.value.results) |result| {
        if (result.ok) continue;
        const code = result.code orelse .internal;
        if (force and code == .no_session) continue;
        const this = exitFor(@tagName(code));
        exit = if (exit == exit_code.ok or exit == this) this else exit_code.failed;
        if (!json) try stderrPrint("tuppet: {s}\n", .{result.err orelse @tagName(action) ++ " failed"});
    }
    if (json) try printJson(gpa, reply.line);
    if (exit != exit_code.ok) std.process.exit(exit);
}

// ---- shutdown --------------------------------------------------------

const shutdown_usage = "usage: tuppet shutdown [--reset] [--all] [-j]";

/// A daemon replies to a shutdown once its sessions stopped and its
/// streams ended.
const shutdown_reply_ns: i64 = 30 * std.time.ns_per_s;

/// Stop every session and the daemon; with --all the other daemons the
/// store names first; with --reset delete the stored sessions and start
/// the ids over, in the daemon, or here when none runs.
pub fn cmdShutdown(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var reset = false;
    var all = false;
    var json = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--reset")) {
            reset = true;
        } else if (std.mem.eql(u8, a, "--all")) {
            all = true;
        } else if (isOpt(a, "--json", "-j")) {
            json = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return unknownOption(a, shutdown_usage);
        } else {
            return cliFail("unexpected argument '{s}' ({s})", .{ a, shutdown_usage });
        }
    }
    const target = try daemonEndpoint(gpa);
    defer gpa.free(target);
    var exit: u8 = exit_code.ok;
    if (all) {
        openStore(gpa);
        const others = try store.endpoints(gpa);
        defer {
            for (others) |path| gpa.free(path);
            gpa.free(others);
        }
        for (others) |path| {
            if (std.mem.eql(u8, path, target) or !ipc.answersHello(path)) continue;
            exit = @max(exit, try shutdownOn(gpa, path, false, json));
        }
    }
    exit = @max(exit, try shutdownOn(gpa, target, reset, json));
    if (exit != exit_code.ok) std.process.exit(exit);
}

/// Shut down the daemon on `path`, or with `reset` and no daemon there,
/// reset the store here. Prints what happened and returns the exit code.
fn shutdownOn(gpa: std.mem.Allocator, path: []const u8, reset: bool, json: bool) !u8 {
    const Hello = struct { ok: bool = false, features: []const []const u8 = &.{} };
    const hello = try requestOn(gpa, path, protocol.HelloReq{}, Hello, ipc.request_timeout_ns) orelse return noDaemon(gpa, path, reset, json);
    defer hello.deinit();
    for (hello.parsed.value.features) |feature| {
        if (std.mem.eql(u8, feature, "shutdown")) break;
    } else {
        try stderrPrint("tuppet: the daemon on {s} is an older tuppet that cannot shut down on request; stop its process instead (running programs end, ended sessions are kept)\n", .{path});
        return exit_code.failed;
    }
    const reply = try requestOn(gpa, path, protocol.ShutdownReq{ .reset = reset }, protocol.ShutdownResp, shutdown_reply_ns) orelse
        return noDaemon(gpa, path, reset, json);
    defer reply.deinit();
    const resp = reply.parsed.value;
    if (!resp.ok) {
        if (!failedWith(gpa, reply.line, .stopping)) failReply(gpa, reply.line, false);
        // Another shutdown is under way; once it is done, so is this one.
        if (!awaitGone(path)) return notGone(path);
        return noDaemon(gpa, path, reset, json);
    }
    const gone = awaitGone(path);
    if (json) {
        try printJsonWith(gpa, reply.line, "daemon", true);
    } else {
        const text = try shutdownText(gpa, resp, reset, true);
        defer gpa.free(text);
        try stdoutPrint("{s}\n", .{text});
    }
    for (resp.failed) |failure| try stderrPrint("tuppet: {s}\n", .{failure.err});
    if (!gone) return notGone(path);
    return if (resp.failed.len > 0) exit_code.failed else exit_code.ok;
}

/// Nothing answers on `path`: say so, or with `reset`, reset the store
/// here, under the same lock a daemon takes.
fn noDaemon(gpa: std.mem.Allocator, path: []const u8, reset: bool, json: bool) !u8 {
    if (!reset) {
        if (json) {
            const line = try protocol.stringifyAlloc(gpa, .{ .socket = path, .daemon = false });
            defer gpa.free(line);
            try stdoutPrint("{s}\n", .{line});
        } else try stdoutPrint("no daemon on {s}\n", .{path});
        return exit_code.ok;
    }
    // Holding the endpoint keeps a daemon from starting there meanwhile.
    var server = ipc.listen(path) catch |err| switch (err) {
        error.AddressInUse => runtimeFail("a daemon started on {s} meanwhile; run 'tuppet shutdown --reset' again", .{path}),
        else => return err,
    };
    defer server.deinit();
    openStore(gpa);
    const done = try store.reset(gpa, path, ipc.answersHello);
    const boot = try store.bootLabel(gpa);
    defer gpa.free(boot);
    const resp: protocol.ShutdownResp = .{ .socket = path, .removed = done.removed, .kept = done.kept, .next_id = done.next_id, .boot = boot };
    if (json) {
        const line = try protocol.stringifyAlloc(gpa, resp);
        defer gpa.free(line);
        try printJsonWith(gpa, line, "daemon", false);
    } else {
        const text = try shutdownText(gpa, resp, true, false);
        defer gpa.free(text);
        try stdoutPrint("{s}\n", .{text});
    }
    return exit_code.ok;
}

fn notGone(path: []const u8) u8 {
    stderrPrint("tuppet: the daemon on {s} did not exit within 30 s\n", .{path}) catch {};
    return exit_code.timeout;
}

fn openStore(gpa: std.mem.Allocator) void {
    store.open(gpa) catch |err| runtimeFail("cannot use the session store in {s}: {s}", .{ store.rootDir(), @errorName(err) });
}

/// One line about a shutdown: what stopped, and what the store keeps.
fn shutdownText(gpa: std.mem.Allocator, resp: protocol.ShutdownResp, reset: bool, daemon: bool) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    const out = &w.writer;
    if (!daemon) {
        try out.print("no daemon on {s}", .{resp.socket});
    } else if (resp.stopped.len == 0) {
        try out.print("stopped the daemon on {s}", .{resp.socket});
    } else {
        try out.print("stopped {d} running session{s} (", .{ resp.stopped.len, plural(resp.stopped.len) });
        for (resp.stopped, 0..) |st, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("{d}", .{st.id});
            if (st.name) |name| try out.print(" {s}", .{name});
        }
        try out.print(") and the daemon on {s}", .{resp.socket});
    }
    if (!reset) {
        try out.print("; kept {d} ended session{s}", .{ resp.kept, plural(resp.kept) });
    } else {
        try out.print("; deleted {d} session{s} and the recordings kept with them; ", .{ resp.removed, plural(resp.removed) });
        if (resp.kept == 0) {
            try out.writeAll("ids start at 1 again");
        } else {
            try out.print("kept {d} session{s} of other daemons, so ids continue at {d}", .{ resp.kept, plural(resp.kept), resp.next_id });
        }
    }
    return w.toOwnedSlice();
}

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

/// One request to the daemon on `path`, which this never starts; null
/// when nothing answers there.
fn requestOn(gpa: std.mem.Allocator, path: []const u8, req: anytype, comptime Resp: type, timeout_ns: i64) !?Reply(Resp) {
    var conn = ipc.Conn.connect(path) catch |err| switch (err) {
        error.UntrustedDaemon => runtimeFail("the socket {s} is served by another user's process; refusing to use it", .{path}),
        error.BadPath => return cliFail("socket path '{s}' is empty or too long", .{path}),
        else => return null,
    };
    defer conn.deinit();
    sendRequest(gpa, &conn, req) catch return null;
    const split = conn.recvLineAfter(gpa, max_reply, "", timeout_ns) catch |err| {
        // It exited before it read the request.
        const ended: anyerror = err;
        if (ended == error.Eof or ended == error.ConnectionResetByPeer) return null;
        return err;
    };
    gpa.free(split.rest);
    return try parseReply(gpa, Resp, split.line);
}

// ---- events ----------------------------------------------------------

const events_usage = "usage: tuppet events [<session>...] [-i DUR] [--count N] [-t DUR] [-v] [-j]";

/// A frame of an events stream, as far as the CLI reads it.
const EventFrame = struct {
    type: []const u8 = "",
    id: ?u64 = null,
    fields: ?[]const []const u8 = null,
    status: ?Status = null,
    reason: ?[]const u8 = null,
    hit: ?protocol.Hit = null,
};

const EventsOutput = struct {
    json: bool,
    verbose: bool,
};

/// Follow what happens to sessions: one line per event, or the daemon's
/// frames with -j, until --count events came, -t ran out (exit 3 when
/// --count was not reached), or the daemon shut down (exit 4 then).
pub fn cmdEvents(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(gpa);
    var idle_ms: ?u64 = null;
    var count: ?u64 = null;
    var timeout_ms: ?u64 = null;
    var out: EventsOutput = .{ .json = false, .verbose = false };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isOpt(a, "--idle", "-i")) {
            idle_ms = try durationValue(args, &i, 1);
            if (idle_ms.? > std.time.ms_per_day) return cliFail("{s} must be at most 1d", .{a});
        } else if (std.mem.eql(u8, a, "--count")) {
            const value = try optValue(args, &i);
            count = protocol.parseDecimal(u64, value) orelse 0;
            if (count.? == 0) return cliFail("invalid --count '{s}' (expected a number of events, at least 1)", .{value});
        } else if (isOpt(a, "--timeout", "-t")) {
            timeout_ms = try durationValue(args, &i, 0);
        } else if (isOpt(a, "--verbose", "-v")) {
            out.verbose = true;
        } else if (isOpt(a, "--json", "-j")) {
            out.json = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return unknownOption(a, events_usage);
        } else {
            try checkRef(a);
            try refs.append(gpa, a);
        }
    }
    const deadline: ?i64 = if (timeout_ms) |ms| io_mod.nowNanos() + @as(i64, @intCast(@min(ms, std.math.maxInt(i32)))) * std.time.ns_per_ms else null;
    var conn = try connect(gpa);
    defer conn.deinit();
    try sendRequest(gpa, &conn, protocol.EventsReq{ .sessions = if (refs.items.len > 0) refs.items else null, .idle_ms = idle_ms });
    const first = try conn.recvLineAfter(gpa, max_reply, "", ipc.request_timeout_ns);
    var rest = first.rest;
    defer gpa.free(rest);
    {
        const reply = try parseReply(gpa, protocol.EventsResp, first.line);
        defer reply.deinit();
        if (!reply.parsed.value.ok) failReply(gpa, reply.line, false);
    }
    var known: std.AutoHashMapUnmanaged(u64, []u8) = .empty;
    defer {
        var it = known.valueIterator();
        while (it.next()) |name| gpa.free(name.*);
        known.deinit(gpa);
    }
    var synced = false;
    var changes: u64 = 0;
    while (true) {
        const left = if (deadline) |d| d - io_mod.nowNanos() else std.time.ns_per_day;
        if (left <= 0) eventsTimedOut(count, changes, timeout_ms.?);
        const split = conn.recvLineAfter(gpa, max_reply, rest, left) catch |err| switch (err) {
            error.ReadTimeout => {
                if (deadline != null) eventsTimedOut(count, changes, timeout_ms.?);
                gpa.free(rest);
                rest = try gpa.alloc(u8, 0);
                continue;
            },
            else => return err,
        };
        gpa.free(rest);
        rest = split.rest;
        defer gpa.free(split.line);
        const parsed = std.json.parseFromSlice(EventFrame, gpa, split.line, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch
            runtimeFail("the daemon sent a malformed event", .{});
        defer parsed.deinit();
        const frame = parsed.value;
        if (out.json) {
            try stdoutWrite(split.line);
            try stdoutWrite("\n");
        }
        if (std.mem.eql(u8, frame.type, "end")) {
            const reason = frame.reason orelse "";
            if (std.mem.eql(u8, reason, "too_slow")) runtimeFail("the daemon ended the stream: this command took too long to read it", .{});
            if (std.mem.eql(u8, reason, "shutdown")) eventsShutDown(count, changes);
            runtimeFail("the daemon ended the stream ({s})", .{reason});
        }
        if (std.mem.eql(u8, frame.type, "synced")) {
            synced = true;
            continue;
        }
        if (std.mem.eql(u8, frame.type, "resync")) {
            synced = false;
            if (!out.json) try stderrPrint("tuppet: this command fell behind; events in between were missed\n", .{});
            continue;
        }
        if (frame.status) |st| try rememberName(gpa, &known, st);
        if (!synced) continue;
        // Without -j an event is what prints a line.
        const shown = if (out.json) true else blk: {
            const text = try eventText(gpa, frame, known, out.verbose);
            defer gpa.free(text);
            try stdoutWrite(text);
            break :blk text.len > 0;
        };
        if (std.mem.eql(u8, frame.type, "removed")) if (frame.id) |id| if (known.fetchRemove(id)) |kv| gpa.free(kv.value);
        if (!shown) continue;
        changes += 1;
        if (count) |n| if (changes >= n) return;
    }
}

/// -t ran out: exit 0, or 3 with a line on stderr when --count events
/// did not all come.
fn eventsTimedOut(count: ?u64, came: u64, timeout_ms: u64) noreturn {
    const n = count orelse std.process.exit(exit_code.ok);
    var dur_buf: [24]u8 = undefined;
    stderrPrint("tuppet: {d} of {d} events came within {s}\n", .{ came, n, units.durationText(&dur_buf, timeout_ms) }) catch {};
    std.process.exit(exit_code.timeout);
}

/// The daemon shut down: exit 0, or 4 when --count events did not all
/// come; a line on stderr says so.
fn eventsShutDown(count: ?u64, came: u64) noreturn {
    const n = count orelse {
        stderrPrint("tuppet: the daemon shut down\n", .{}) catch {};
        std.process.exit(exit_code.ok);
    };
    stderrPrint("tuppet: the daemon shut down after {d} of {d} events\n", .{ came, n }) catch {};
    std.process.exit(exit_code.ended);
}

fn rememberName(gpa: std.mem.Allocator, known: *std.AutoHashMapUnmanaged(u64, []u8), st: Status) !void {
    const name = try gpa.dupe(u8, st.name orelse "-");
    errdefer gpa.free(name);
    const entry = try known.getOrPut(gpa, st.id);
    if (entry.found_existing) gpa.free(entry.value_ptr.*);
    entry.value_ptr.* = name;
}

/// The lines `events` prints for one frame: the time, the session, and
/// what happened; nothing for changes it does not show.
fn eventText(gpa: std.mem.Allocator, frame: EventFrame, known: std.AutoHashMapUnmanaged(u64, []u8), verbose: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var clock_buf: [16]u8 = undefined;
    const id = frame.id orelse 0;
    var who_buf: [96]u8 = undefined;
    const who = std.fmt.bufPrint(&who_buf, "{s}  {d} {s}  ", .{ clockText(&clock_buf), id, known.get(id) orelse "-" }) catch unreachable;
    const kind = frame.type;
    const st = frame.status orelse Status{};
    var buf: [4096]u8 = undefined;
    if (std.mem.eql(u8, kind, "started")) {
        try w.print("{s}started: {s}\n", .{ who, words.commandText(&buf, st.argv) });
    } else if (std.mem.eql(u8, kind, "ended")) {
        try w.print("{s}{s}\n", .{ who, words.endWord(&buf, st) });
    } else if (std.mem.eql(u8, kind, "removed")) {
        try w.print("{s}removed\n", .{who});
    } else if (std.mem.eql(u8, kind, "renamed") or std.mem.eql(u8, kind, "snapshot")) {
        try w.print("{s}renamed to {s}\n", .{ who, st.name orelse "(no name)" });
    } else if (std.mem.eql(u8, kind, "left")) {
        try w.print("{s}renamed to {s}, no longer picked\n", .{ who, st.name orelse "(no name)" });
    } else if (std.mem.eql(u8, kind, "idle")) {
        try w.print("{s}idle {s}\n", .{ who, words.age(&buf, st.idle_ms) });
    } else if (std.mem.eql(u8, kind, "active")) {
        try w.print("{s}active\n", .{who});
    } else if (std.mem.eql(u8, kind, "hit")) {
        const hit = frame.hit orelse return out.toOwnedSlice();
        const alerts = try std.mem.join(gpa, ",", hit.alerts);
        defer gpa.free(alerts);
        try w.print("{s}hit {d} {s}: {s}\n", .{ who, hit.n, alerts, hit.line });
    } else if (std.mem.eql(u8, kind, "seen")) {
        if (verbose) try w.print("{s}seen\n", .{who});
    } else if (std.mem.eql(u8, kind, "changed")) {
        for (frame.fields orelse &.{}) |field| try changedText(w, who, field, st, verbose);
    } else if (verbose) {
        try w.print("{s}{s}\n", .{ who, kind });
    }
    return out.toOwnedSlice();
}

fn changedText(w: *std.Io.Writer, who: []const u8, field: []const u8, st: Status, verbose: bool) !void {
    const is = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    if (is(field, "bell")) {
        try w.print("{s}bell\n", .{who});
    } else if (is(field, "notification")) {
        const n = st.notification orelse return;
        if (n.title) |title| try w.print("{s}notification: {s}: {s}\n", .{ who, title, n.text }) else try w.print("{s}notification: {s}\n", .{ who, n.text });
    } else if (is(field, "tty")) {
        if (st.hidden_input == true) try w.print("{s}password?\n", .{who});
    } else if (is(field, "writer")) {
        if (st.writer) |writer| try w.print("{s}attached: {s}\n", .{ who, writer.label orelse "a writer" }) else try w.print("{s}detached\n", .{who});
    } else if (!verbose) {
        return;
    } else if (is(field, "title")) {
        try w.print("{s}title: {s}\n", .{ who, st.title orelse "" });
    } else if (is(field, "cwd")) {
        try w.print("{s}cwd: {s}\n", .{ who, if (st.cwd) |cwd| cwd.path else "" });
    } else if (is(field, "foreground")) {
        const fg = st.foreground orelse return w.print("{s}foreground: none\n", .{who});
        if (fg.name) |name| try w.print("{s}foreground: {s}\n", .{ who, name }) else try w.print("{s}foreground: group {d}\n", .{ who, fg.pgid });
    } else if (is(field, "size")) {
        try w.print("{s}size {d}x{d}\n", .{ who, st.cols, st.rows });
    } else if (is(field, "viewers")) {
        try w.print("{s}viewers: {d}\n", .{ who, st.viewers });
    }
}

extern "c" fn localtime_r(t: *const std.c.time_t, tm: *Tm) ?*Tm;
/// The start of libc's struct tm, with room for the rest.
const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, rest: [16]c_long };

/// The time of day, HH:MM:SS, local where libc knows the zone.
fn clockText(buf: []u8) []const u8 {
    const secs = @divFloor(nowMillis(), std.time.ms_per_s);
    var of_day: u64 = @intCast(@mod(secs, std.time.s_per_day));
    if (builtin.os.tag != .windows) {
        const t: std.c.time_t = @intCast(secs);
        var tm: Tm = undefined;
        if (localtime_r(&t, &tm) != null) of_day = @intCast(@max(0, @as(i64, tm.hour) * 3600 + @as(i64, tm.min) * 60 + tm.sec));
    }
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ of_day / 3600, of_day % 3600 / 60, of_day % 60 }) catch "";
}

/// `printJson`, with `value` added as the field `name`.
fn printJsonWith(gpa: std.mem.Allocator, line: []const u8, comptime name: []const u8, value: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    const extra_line = try protocol.stringifyAlloc(gpa, value);
    defer gpa.free(extra_line);
    var extra = try std.json.parseFromSlice(std.json.Value, gpa, extra_line, .{});
    defer extra.deinit();
    if (parsed.value == .object) {
        _ = parsed.value.object.orderedRemove("ok");
        try parsed.value.object.put(parsed.arena.allocator(), name, extra.value);
    }
    const out = try protocol.stringifyAlloc(gpa, parsed.value);
    defer gpa.free(out);
    try stdoutWrite(out);
    try stdoutWrite("\n");
}

/// Print a reply as JSON, without its "ok" (the exit code says that).
fn printJson(gpa: std.mem.Allocator, line: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    if (parsed.value == .object) _ = parsed.value.object.orderedRemove("ok");
    const out = try protocol.stringifyAlloc(gpa, parsed.value);
    defer gpa.free(out);
    try stdoutWrite(out);
    try stdoutWrite("\n");
}

// ---- do --------------------------------------------------------------

const do_usage = "usage: tuppet do <session> STEP... [-t DUR] [--if-input-seq N] [--reply-to N] [--unless-attached] [--any-input] [--record-file FILE] [--stats] [-j]";

/// What `do` runs, in order.
const Unit = union(enum) {
    /// One input request, and the wait that follows it.
    batch: DoBatch,
    /// A sleep too long for a batch, in this process.
    sleep: struct { ms: u64, step: u32 },
    /// A wait without input right before it.
    wait: DoWait,
    /// A resize, and the wait that follows it.
    resize: DoResize,
};

const DoResize = struct {
    cols: u16,
    rows: u16,
    /// The command-line step, counted from 1.
    step: u32,
    until: ?DoWait,
};

const DoBatch = struct {
    steps: []const protocol.Step,
    /// The command-line step each step comes from, counted from 1.
    origins: []const u32,
    /// It types a secret.
    secret: bool,
    until: ?DoWait,
};

const DoWait = struct {
    until: []const protocol.Condition,
    /// Null for the default deadline.
    within_ms: ?u64,
    /// The command-line step, counted from 1.
    step: u32,
};

/// The units of a `do`, built step by step: consecutive input steps share
/// a batch, and the condition step after them waits in it.
const DoPlan = struct {
    a: std.mem.Allocator,
    units: std.ArrayList(Unit) = .empty,
    steps: std.ArrayList(protocol.Step) = .empty,
    origins: std.ArrayList(u32) = .empty,
    /// The batch being built types something.
    typed: bool = false,
    secret: bool = false,
    sleeps_ms: u64 = 0,
    /// Command-line steps so far.
    count: u32 = 0,
    conds: ?Conds = null,
    /// A resize waiting for the condition step after it.
    resizing: ?DoResize = null,

    const Conds = struct {
        until: std.ArrayList(protocol.Condition) = .empty,
        icase: bool = false,
        after_hit: ?u64 = null,
        within_ms: ?u64 = null,
    };

    fn input(p: *DoPlan, steps: []const protocol.Step, secret: bool) !void {
        try p.closeConds();
        if (p.resizing != null) try p.flush(null);
        p.count += 1;
        // A secret starts a batch of its own: the hidden-input guard is
        // checked right before its first byte.
        if (secret or p.steps.items.len + steps.len > batch.max_steps) try p.flush(null);
        for (steps) |st| {
            try p.steps.append(p.a, st);
            try p.origins.append(p.a, p.count);
        }
        p.typed = true;
        if (secret) p.secret = true;
    }

    fn sleep(p: *DoPlan, ms: u64) !void {
        try p.closeConds();
        p.count += 1;
        // A batch sleeps between its keys within its limits; other sleeps
        // run here, between batches.
        if (p.typed and ms <= batch.max_sleep_ms and p.sleeps_ms + ms <= batch.max_sleeps_ms and p.steps.items.len < batch.max_steps) {
            try p.steps.append(p.a, .{ .sleep_ms = ms });
            try p.origins.append(p.a, p.count);
            p.sleeps_ms += ms;
            return;
        }
        try p.flush(null);
        try p.units.append(p.a, .{ .sleep = .{ .ms = ms, .step = p.count } });
    }

    /// A resize is a step of its own, never part of a batch.
    fn resize(p: *DoPlan, size: [2]u16) !void {
        try p.closeConds();
        try p.flush(null);
        p.count += 1;
        p.resizing = .{ .cols = size[0], .rows = size[1], .step = p.count, .until = null };
    }

    fn condition(p: *DoPlan, c: protocol.Condition) !void {
        if (p.conds == null) {
            p.count += 1;
            p.conds = .{};
        }
        try p.conds.?.until.append(p.a, c);
    }

    /// The condition step being built, for `flag`.
    fn open(p: *DoPlan, flag: []const u8) !*Conds {
        if (p.conds) |*c| return c;
        return cliFail("{s} belongs to a condition step: give it after -m, --gone, -e, -i, --settled, --hidden-input, or --hit", .{flag});
    }

    fn closeConds(p: *DoPlan) !void {
        const c = p.conds orelse return;
        p.conds = null;
        if (c.icase) for (c.until.items) |x| {
            if (x.match != null) break;
        } else return cliFail("--icase needs -m TEXT or --gone TEXT in its condition step", .{});
        if (c.after_hit != null) for (c.until.items) |x| {
            if (x.hit != null) break;
        } else return cliFail("--after-hit needs --hit NAME in its condition step", .{});
        for (c.until.items) |*x| {
            if (x.match != null) x.icase = c.icase;
            if (x.hit) |*h| h.after_hit = c.after_hit;
            // Gone counts from the wait's start, which is before the input.
            // After a resize, the run counts from its reflow instead.
            if (!x.absent) x.after_input = .latest;
        }
        const wait: DoWait = .{ .until = c.until.items, .within_ms = c.within_ms, .step = p.count };
        if (p.typed or p.resizing != null) return p.flush(wait);
        try p.units.append(p.a, .{ .wait = wait });
    }

    fn flush(p: *DoPlan, until: ?DoWait) !void {
        if (p.resizing) |r| {
            p.resizing = null;
            var unit = r;
            unit.until = until;
            return p.units.append(p.a, .{ .resize = unit });
        }
        if (p.typed) try p.units.append(p.a, .{ .batch = .{ .steps = p.steps.items, .origins = p.origins.items, .secret = p.secret, .until = until } });
        p.steps = .empty;
        p.origins = .empty;
        p.typed = false;
        p.secret = false;
        p.sleeps_ms = 0;
    }

    fn finish(p: *DoPlan) ![]const Unit {
        try p.closeConds();
        try p.flush(null);
        return p.units.items;
    }
};

/// The most text --stdin pastes: what fits into a request.
const max_stdin = 768 << 10;

/// Type, paste, click, and wait for what follows, step by step: input
/// steps go to the daemon in batches, each typed without other input in
/// between, and a condition step after them waits from before their first
/// byte on.
pub fn cmdDo(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var plan: DoPlan = .{ .a = a };
    var run: DoRun = .{ .gpa = a, .target = undefined };
    var ref: ?[]const u8 = null;
    var record_path: ?[]const u8 = null;
    var stdin_taken = false;
    // Reported once the arguments are known to be well-formed.
    var unset_secret: ?struct { name: []const u8, empty: bool } = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isOpt(arg, "--keys", "-k")) {
            var tokens: std.ArrayList([]const u8) = .empty;
            try appendKeys(a, &tokens, try optValue(args, &i));
            try plan.input(&.{.{ .keys = tokens.items }}, false);
        } else if (isOpt(arg, "--text", "-s") or isOpt(arg, "--paste", "-p")) {
            const text = try optValue(args, &i);
            if (text.len == 0) return cliFail("{s} needs a non-empty value", .{arg});
            try plan.input(&.{if (isOpt(arg, "--paste", "-p")) .{ .paste = text } else .{ .text = text }}, false);
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            if (stdin_taken) return cliFail("--stdin can be given once", .{});
            stdin_taken = true;
            const text = plat.stdinReadAll(a, max_stdin) catch |err| switch (err) {
                error.StreamTooLong => return cliFail("--stdin pastes at most {d} KiB", .{max_stdin >> 10}),
                error.OutOfMemory => return err,
                else => runtimeFail("cannot read standard input", .{}),
            };
            if (text.len == 0) return cliFail("--stdin has nothing to paste: standard input is empty", .{});
            try plan.input(&.{.{ .paste = text }}, false);
        } else if (std.mem.eql(u8, arg, "--secret")) {
            const name = try optValue(args, &i);
            const env = std.c.getenv(try a.dupeSentinel(u8, name, 0));
            const value: []const u8 = if (env) |v| std.mem.span(v) else "";
            if (value.len == 0 and unset_secret == null) unset_secret = .{ .name = name, .empty = env != null };
            try plan.input(&.{.{ .text = value, .secret = true }}, true);
        } else if (std.mem.eql(u8, arg, "--sleep")) {
            try plan.sleep(try durationValue(args, &i, 0));
        } else if (std.mem.eql(u8, arg, "--mouse")) {
            if (i + 3 >= args.len) return cliFail("--mouse needs SPEC X Y, such as --mouse left 10 3", .{});
            const steps = try mouseSteps(a, args[i + 1], args[i + 2], args[i + 3]);
            i += 3;
            try plan.input(steps, false);
        } else if (std.mem.eql(u8, arg, "--focus")) {
            const value = try optValue(args, &i);
            const focused = if (std.mem.eql(u8, value, "on")) true else if (std.mem.eql(u8, value, "off")) false else return cliFail("invalid --focus '{s}' (use on or off)", .{value});
            try plan.input(&.{.{ .focus = focused }}, false);
        } else if (std.mem.eql(u8, arg, "--resize")) {
            try plan.resize(try parseSize(try optValue(args, &i)));
        } else if (isOpt(arg, "--match", "-m")) {
            try plan.condition(.{ .match = try matchValue(args, &i) });
        } else if (isOpt(arg, "--ended", "-e")) {
            try plan.condition(.{ .ended = true });
        } else if (isOpt(arg, "--idle", "-i")) {
            try plan.condition(.{ .idle_ms = try durationValue(args, &i, 0) });
        } else if (std.mem.eql(u8, arg, "--settled")) {
            try plan.condition(.{ .settled_ms = try durationValue(args, &i, 0) });
        } else if (std.mem.eql(u8, arg, "--gone")) {
            try plan.condition(.{ .match = try matchValue(args, &i), .absent = true });
        } else if (std.mem.eql(u8, arg, "--hidden-input")) {
            try plan.condition(.{ .hidden_input = true });
        } else if (std.mem.eql(u8, arg, "--hit")) {
            try plan.condition(.{ .hit = .{ .name = try hitValue(args, &i) } });
        } else if (std.mem.eql(u8, arg, "--after-hit")) {
            const c = try plan.open(arg);
            if (c.after_hit != null) return cliFail("{s} is given twice for one condition step", .{arg});
            c.after_hit = try hitNumber(args, &i);
        } else if (std.mem.eql(u8, arg, "--icase")) {
            (try plan.open(arg)).icase = true;
        } else if (isOpt(arg, "--within", "-w")) {
            const c = try plan.open(arg);
            if (c.within_ms != null) return cliFail("{s} is given twice for one condition step", .{arg});
            c.within_ms = try waitDuration(args, &i);
        } else if (isOpt(arg, "--timeout", "-t")) {
            run.timeout_ms = try waitDuration(args, &i);
        } else if (std.mem.eql(u8, arg, "--if-input-seq")) {
            const value = try optValue(args, &i);
            run.if_input_seq = protocol.parseDecimal(u64, value) orelse return cliFail("invalid --if-input-seq '{s}' (expected an input_seq, such as one a wait printed)", .{value});
        } else if (std.mem.eql(u8, arg, "--reply-to")) {
            run.reply_to = try hitNumber(args, &i);
        } else if (std.mem.eql(u8, arg, "--unless-attached")) {
            run.unless_attached = true;
        } else if (std.mem.eql(u8, arg, "--any-input")) {
            run.any_input = true;
        } else if (std.mem.eql(u8, arg, "--record-file")) {
            record_path = try optValue(args, &i);
        } else if (isOpt(arg, "--json", "-j")) {
            run.json = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            run.stats = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownOption(arg, do_usage);
        } else if (ref != null) {
            return cliFail("'{s}' is not a step: do takes options, such as -s TEXT to type text or -k KEYS for keys", .{arg});
        } else {
            try checkRef(arg);
            ref = arg;
        }
    }
    run.target = SessionTarget.init(ref orelse return cliFail(do_usage, .{}));
    run.units = try plan.finish();
    if (run.units.len == 0) return cliFail("do needs a step: -k KEYS, -s TEXT, -p TEXT, --stdin, --secret VAR, --sleep DUR, --mouse SPEC X Y, --focus on|off, --resize WxH, or a condition", .{});
    if (record_path) |path| _ = try recordFileFormat("--record-file", path);
    if (unset_secret) |s| runtimeFail("--secret {s}: environment variable {s} is {s}", .{ s.name, s.name, if (s.empty) "empty" else "not set" });
    const path = record_path orelse {
        const code = try run.all();
        if (code != exit_code.ok) std.process.exit(code);
        return;
    };
    try recordDo(a, &run, try absolutePath(a, path));
}

/// Run `run` while recording to `path` (asciicast for .cast, a trace for .trace),
/// and stop the recording on every way out, Ctrl-C included.
fn recordDo(a: std.mem.Allocator, run: *DoRun, path: []const u8) !void {
    const format = try recordFileFormat("--record-file", path);
    const started = try call(a, protocol.RecordReq{ .session = run.target.ref(), .start = .{ .path = path, .format = format, .input = true } }, protocol.RecordResp);
    run.target.pin(started.parsed.value.status.?.id);
    installInterruptHandlers();
    // Requests block in reads that a signal does not end: the steps run on
    // their own thread, and this one stops the recording.
    const Worker = struct {
        run: *DoRun,
        code: u8 = exit_code.failed,
        finished: std.atomic.Value(u32) = .init(0),

        fn main(w: *@This()) void {
            w.code = w.run.all() catch |err| blk: {
                if (errorText(err)) |text| {
                    if (text.len > 0) stderrPrint("tuppet: {s}\n", .{text}) catch {};
                } else stderrPrint("tuppet: {s}\n", .{@errorName(err)}) catch {};
                break :blk exit_code.failed;
            };
            w.finished.store(1, .release);
            io_mod.io().futexWake(u32, &w.finished.raw, 1);
        }
    };
    var worker: Worker = .{ .run = run };
    const thread = try std.Thread.spawn(.{}, Worker.main, .{&worker});
    const code = while (true) {
        const sig = interrupt_signal.load(.acquire);
        if (sig != 0) {
            recordRequest(.{ .session = run.target.ref(), .mark = "interrupted" });
            recordRequest(.{ .session = run.target.ref(), .stop = true });
            stderrPrint("tuppet: interrupted; the recording is stopped\n", .{}) catch {};
            std.process.exit(128 + sig);
        }
        if (worker.finished.load(.acquire) != 0) break worker.code;
        io_mod.io().futexWaitTimeout(u32, &worker.finished.raw, 0, .{
            .duration = .{ .raw = .fromMilliseconds(50), .clock = .boot },
        }) catch {};
    };
    thread.join();
    recordRequest(.{ .session = run.target.ref(), .stop = true });
    if (code != exit_code.ok) std.process.exit(code);
}

/// A record request whose failure must not hide what went wrong before.
/// The steps' thread may still use their arena: this one allocates apart.
fn recordRequest(req: protocol.RecordReq) void {
    const reply = request(std.heap.page_allocator, req, protocol.RecordResp) catch return;
    reply.deinit();
}

/// The signal that interrupted a recording `do` or a sweep, 0 while none
/// has.
pub var interrupt_signal: std.atomic.Value(u8) = .{ .raw = 0 };

fn onInterrupt(sig: std.posix.SIG) callconv(.c) void {
    interrupt_signal.store(@intCast(@backingInt(sig)), .release);
}

fn onCtrl(ctrl_type: u32) callconv(.winapi) c_int {
    _ = ctrl_type;
    interrupt_signal.store(2, .release);
    return 1;
}

pub fn installInterruptHandlers() void {
    switch (builtin.os.tag) {
        .windows => _ = SetConsoleCtrlHandler(&onCtrl, 1),
        else => {
            var act: std.posix.Sigaction = .{
                .handler = .{ .handler = onInterrupt },
                .mask = std.posix.sigemptyset(),
                .flags = std.posix.SA.RESTART,
            };
            for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |sig| std.posix.sigaction(sig, &act, null);
        },
    }
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (u32) callconv(.winapi) c_int,
    add: c_int,
) callconv(.winapi) c_int;

/// The steps of --mouse SPEC X Y, where SPEC is BUTTON[:ACTION[:MODS]];
/// without an action, a click: press and release (the wheel only presses).
fn mouseSteps(a: std.mem.Allocator, spec: []const u8, x_text: []const u8, y_text: []const u8) ![]const protocol.Step {
    var parts = std.mem.splitScalar(u8, spec, ':');
    const button = parts.next().?;
    const action = parts.next();
    const mods = parts.next() orelse "";
    if (parts.next() != null) return cliFail("invalid --mouse '{s}' (expected BUTTON[:ACTION[:MODS]], such as left or left:release:c)", .{spec});
    const x = try parseCoordinate("x", x_text);
    const y = try parseCoordinate("y", y_text);
    const event = mouse.parseEvent(button, action orelse "press", mods) catch |err| return cliFail("{s}", .{mouse.eventErrorText(err)});
    const step = struct {
        fn of(b: []const u8, act: []const u8, m: []const u8, at_x: u16, at_y: u16) protocol.Step {
            return .{ .mouse = .{ .button = b, .action = act, .mods = m, .x = at_x, .y = at_y } };
        }
    }.of;
    if (action) |act| return a.dupe(protocol.Step, &.{step(button, act, mods, x, y)});
    if (event.button == .four or event.button == .five) return a.dupe(protocol.Step, &.{step(button, "press", mods, x, y)});
    return a.dupe(protocol.Step, &.{ step(button, "press", mods, x, y), step(button, "release", mods, x, y) });
}

/// The units of a `do` and how they run.
const DoRun = struct {
    gpa: std.mem.Allocator,
    target: SessionTarget,
    units: []const Unit = &.{},
    timeout_ms: u64 = default_wait_ms,
    if_input_seq: ?u64 = null,
    reply_to: ?u64 = null,
    unless_attached: bool = false,
    any_input: bool = false,
    /// Print each condition step's reply, and a failure, as JSON.
    json: bool = false,
    /// Add what --stats counts to each condition step's line.
    stats: bool = false,
    /// The reflow seq of the latest resize step since the latest batch:
    /// conditions count from it rather than from the input.
    resize_since: ?u64 = null,

    /// Run every unit, printing a line per condition step; the exit code.
    fn all(d: *DoRun) !u8 {
        var first = true;
        for (d.units) |unit| {
            const code = switch (unit) {
                .sleep => |s| blk: {
                    std.Io.sleep(io_mod.io(), .fromMilliseconds(@intCast(s.ms)), .boot) catch {};
                    break :blk exit_code.ok;
                },
                .wait => |w| try d.wait(w),
                .batch => |b| try d.batch(b, first),
                .resize => |r| try d.resize(r),
            };
            if (unit == .batch) first = false;
            if (code != exit_code.ok) return code;
        }
        return exit_code.ok;
    }

    fn batch(d: *DoRun, b: DoBatch, first: bool) !u8 {
        d.resize_since = null;
        const timeout_ms: ?u64 = if (b.until) |u| u.within_ms orelse d.timeout_ms else null;
        const req: protocol.InputReq = .{
            .session = d.target.ref(),
            .steps = b.steps,
            .require = .{
                .unattended = d.unless_attached,
                .input_seq = if (first) d.if_input_seq else null,
                .reply_to = if (first) d.reply_to else null,
                .hidden_input = b.secret and !d.any_input,
            },
            .until = if (b.until) |u| u.until else null,
            .timeout_ms = timeout_ms,
        };
        var base: ?StatsBase = null;
        if (d.stats and b.until != null) {
            base = try StatsBase.of(d.gpa, d.target.ref(), null, false);
            base.?.from_input = true;
        }
        var retried = false;
        var conn, const typed, const reply = while (true) {
            try checkProtocol(d.gpa);
            var conn = try ensureDaemon(d.gpa);
            errdefer conn.deinit();
            try sendRequest(d.gpa, &conn, req);
            const typed = try conn.recvLineAfter(d.gpa, max_reply, "", ipc.request_timeout_ns);
            daemon_contacted = true;
            const reply = try parseReply(d.gpa, protocol.InputResp, typed.line);
            if (reply.parsed.value.ok or retried or !try nextDaemon(d.gpa, reply.line, true)) break .{ conn, typed, reply };
            reply.deinit();
            d.gpa.free(typed.rest);
            conn.deinit();
            retried = true;
        };
        defer conn.deinit();
        if (!reply.parsed.value.ok) {
            const failure = parseFailure(d.gpa, reply.line);
            const done = failure.done orelse 0;
            return d.failed(failure, reply.line, b.origins[@min(done, b.origins.len - 1)]);
        }
        d.target.pin(reply.parsed.value.status.?.id);
        const until = b.until orelse return exit_code.ok;
        const second = try conn.recvLineAfter(d.gpa, max_reply, typed.rest, waitReplyNs(timeout_ms.?));
        return d.report(try parseReply(d.gpa, protocol.WaitResp, second.line), until, timeout_ms.?, base);
    }

    fn wait(d: *DoRun, w: DoWait) !u8 {
        const timeout_ms = w.within_ms orelse d.timeout_ms;
        const base: ?StatsBase = if (d.stats) try StatsBase.of(d.gpa, d.target.ref(), d.resize_since, false) else null;
        const until = if (d.resize_since) |seq| try d.sinceResize(w.until, seq) else w.until;
        return d.report(try requestWait(d.gpa, .{ .session = d.target.ref(), .until = until, .timeout_ms = timeout_ms }), w, timeout_ms, base);
    }

    /// Resize, and wait for the conditions after the resize from its
    /// reflow on. A resize that leaves the size as it is meets them at
    /// once: the program gets no SIGWINCH, so nothing would come.
    fn resize(d: *DoRun, r: DoResize) !u8 {
        var base: ?StatsBase = if (d.stats and r.until != null) try StatsBase.of(d.gpa, d.target.ref(), null, false) else null;
        const req: protocol.ResizeReq = .{
            .session = d.target.ref(),
            .cols = r.cols,
            .rows = r.rows,
            .require = .{ .unattended = d.unless_attached },
        };
        const reply = try request(d.gpa, req, protocol.ResizeResp);
        if (!reply.parsed.value.ok) return d.failed(parseFailure(d.gpa, reply.line), reply.line, r.step);
        const st = reply.parsed.value.status.?;
        d.target.pin(st.id);
        const seq = reply.parsed.value.resize_seq orelse {
            d.resize_since = null;
            // The resize's reply, marked as what the step came to.
            if (d.json) {
                try printJsonWith(d.gpa, reply.line, "outcome", "same_size");
            } else {
                try stdoutWrite(try statusLine(d.gpa, "same", "size", st, d.target.ref(), ""));
            }
            return exit_code.ok;
        };
        d.resize_since = seq;
        const w = r.until orelse return exit_code.ok;
        const timeout_ms = w.within_ms orelse d.timeout_ms;
        if (base) |*b| b.since = seq;
        const until = try d.sinceResize(w.until, seq);
        return d.report(try requestWait(d.gpa, .{ .session = d.target.ref(), .until = until, .timeout_ms = timeout_ms }), w, timeout_ms, base);
    }

    /// `until`, counting from the resize's reflow `seq` instead of the
    /// latest input; --gone keeps counting from the wait's start.
    fn sinceResize(d: *DoRun, until: []const protocol.Condition, seq: u64) ![]const protocol.Condition {
        const out = try d.gpa.dupe(protocol.Condition, until);
        for (out) |*c| if (!c.absent) {
            c.after_input = null;
            c.since = seq;
        };
        return out;
    }

    fn report(d: *DoRun, reply: Reply(protocol.WaitResp), w: DoWait, timeout_ms: u64, base: ?StatsBase) !u8 {
        if (!reply.parsed.value.ok) return d.failed(parseFailure(d.gpa, reply.line), reply.line, w.step);
        if (reply.parsed.value.status) |st| d.target.pin(st.id);
        const suffix = try std.fmt.allocPrint(d.gpa, " step={d} done={d}", .{ w.step, w.step - 1 });
        return reportWait(d.gpa, reply, .{ .session = d.target.ref(), .until = w.until, .timeout_ms = timeout_ms }, .{ .json = d.json, .failed_suffix = suffix, .stats = base });
    }

    /// Report a refused or failed request at command-line step `step`;
    /// `line` is the daemon's reply. Its `done` counts the command-line
    /// steps before `step`, as the text line's done= does.
    fn failed(d: *DoRun, failure: protocol.ErrorReply, line: []const u8, step: u32) !u8 {
        if (d.json) {
            var parsed = try std.json.parseFromSlice(std.json.Value, d.gpa, line, .{});
            defer parsed.deinit();
            if (parsed.value == .object) {
                const obj = &parsed.value.object;
                _ = obj.orderedRemove("ok");
                try obj.put(d.gpa, "step", .{ .integer = step });
                try obj.put(d.gpa, "done", .{ .integer = step - 1 });
            }
            const out = try protocol.stringifyAlloc(d.gpa, parsed.value);
            try stdoutWrite(out);
            try stdoutWrite("\n");
        } else {
            const suffix = try std.fmt.allocPrint(d.gpa, " step={d} done={d}", .{ step, step - 1 });
            const guard = std.mem.eql(u8, failure.code, @tagName(protocol.Code.guard));
            const text = try statusLine(d.gpa, if (guard) "guard" else "error", if (guard) failure.guard orelse "-" else failure.code, failure.status, d.target.ref(), suffix);
            try stdoutWrite(text);
        }
        try stderrPrint("tuppet: {s}\n", .{failure.err});
        const removed = d.target.id != null and std.mem.eql(u8, failure.code, @tagName(protocol.Code.no_session));
        return if (removed) exit_code.ended else exitFor(failure.code);
    }
};

fn parseFailure(a: std.mem.Allocator, line: []const u8) protocol.ErrorReply {
    return std.json.parseFromSliceLeaky(protocol.ErrorReply, a, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        runtimeFail("the daemon sent a malformed reply", .{});
}

test "do puts input steps into batches and waits after them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var plan: DoPlan = .{ .a = arena.allocator() };
    try plan.condition(.{ .match = "$ " });
    try plan.input(&.{.{ .text = "ls" }}, false);
    try plan.sleep(500);
    try plan.input(&.{ .{ .keys = &.{"<Enter>"} }, .{ .keys = &.{"x"} } }, false);
    try plan.condition(.{ .match = "$ " });
    try plan.condition(.{ .ended = true });
    try plan.sleep(800);
    try plan.input(&.{.{ .text = "pw", .secret = true }}, true);
    try plan.sleep(1500);
    const got = try plan.finish();
    try std.testing.expectEqual(@as(usize, 5), got.len);
    // A wait before any input stands alone.
    try std.testing.expectEqual(@as(u32, 1), got[0].wait.step);
    try std.testing.expectEqual(cond.AfterInput.latest, got[0].wait.until[0].after_input.?);
    // The text, the short sleep, and the keys share one batch; the two
    // conditions after them are its until, one step of alternatives.
    const first = got[1].batch;
    try std.testing.expectEqual(@as(usize, 4), first.steps.len);
    try std.testing.expectEqual(@as(?u64, 500), first.steps[1].sleep_ms);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 4 }, first.origins);
    try std.testing.expectEqual(@as(usize, 2), first.until.?.until.len);
    try std.testing.expectEqual(@as(u32, 5), first.until.?.step);
    try std.testing.expect(!first.secret);
    // A sleep before a batch's first key, and one past the limits, run in
    // the client.
    try std.testing.expectEqual(@as(u64, 800), got[2].sleep.ms);
    try std.testing.expect(got[3].batch.secret and got[3].batch.until == null);
    try std.testing.expectEqual(@as(u32, 8), got[4].sleep.step);

    // A secret after other input starts its own batch, guarded by itself.
    var typed: DoPlan = .{ .a = arena.allocator() };
    try typed.input(&.{.{ .text = "bob" }}, false);
    try typed.input(&.{.{ .text = "pw", .secret = true }}, true);
    try typed.input(&.{.{ .keys = &.{"<Enter>"} }}, false);
    const split = try typed.finish();
    try std.testing.expectEqual(@as(usize, 2), split.len);
    try std.testing.expect(!split[0].batch.secret and split[1].batch.secret);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, split[1].batch.origins);
}

test "do keeps a resize out of batches and waits after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var plan: DoPlan = .{ .a = arena.allocator() };
    try plan.input(&.{.{ .text = "a" }}, false);
    try plan.resize(.{ 60, 20 });
    try plan.condition(.{ .settled_ms = 200 });
    try plan.resize(.{ 80, 24 });
    try plan.input(&.{.{ .text = "b" }}, false);
    const got = try plan.finish();
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expect(got[0].batch.until == null);
    // The condition step after a resize is its wait.
    try std.testing.expectEqual(@as(u16, 60), got[1].resize.cols);
    try std.testing.expectEqual(@as(u32, 2), got[1].resize.step);
    try std.testing.expectEqual(@as(u32, 3), got[1].resize.until.?.step);
    try std.testing.expect(got[2].resize.until == null);
    try std.testing.expectEqualSlices(u32, &.{5}, got[3].batch.origins);
}

// ---- plumbing ----------------------------------------------------------

/// The daemon endpoint from --socket or TUPPET_SOCKET. With it set, the
/// client talks only to that daemon and never starts one.
pub var socket_override: ?[]const u8 = null;

/// Set after the first reply. Later requests of the same command
/// (polling in wait, watch, trace) never start a daemon: if the daemon
/// died meanwhile, a fresh empty one would only hide that.
var daemon_contacted = false;
/// Set once hello has shown that the daemon speaks this protocol.
var protocol_checked = false;
/// The endpoint of the daemon last connected to, for messages.
var daemon_path_buf: [ipc.max_path_len]u8 = undefined;
var daemon_path: []const u8 = "";
/// The boot the daemon last checked reported: ids name the same sessions
/// only while it stays.
var daemon_boot_buf: [96]u8 = undefined;
var daemon_boot: []const u8 = "";
/// The features and the build variant the daemon last checked reported.
var daemon_features_buf: [256]u8 = undefined;
var daemon_features: []const u8 = "";
var daemon_variant_buf: [16]u8 = undefined;
var daemon_variant: []const u8 = "";

/// Whether the daemon checked last reports `feature` in hello.
fn daemonHas(feature: []const u8) bool {
    var it = std.mem.splitScalar(u8, daemon_features, ',');
    while (it.next()) |name| if (std.mem.eql(u8, name, feature)) return true;
    return false;
}

/// How to get rid of an older daemon that still runs after an upgrade.
const old_daemon_hint = if (builtin.os.tag == .windows)
    "stop its tuppet.exe process (for example in Task Manager)"
else
    "it exits once no program has run for a while (30 s unless TUPPET_IDLE_EXIT says otherwise); to switch now, run 'pkill -u \"$USER\" -x tuppet'";

/// Let the next request start a daemon again: for the picker, which
/// outlives a daemon that died.
pub fn forgetDaemon() void {
    daemon_contacted = false;
    protocol_checked = false;
}

/// A connection to the daemon (starting it if needed), for streams.
pub fn connect(gpa: std.mem.Allocator) !ipc.Conn {
    try checkProtocol(gpa);
    const conn = try ensureDaemon(gpa);
    daemon_contacted = true;
    return conn;
}

/// A reply, and the line it came from (printed by --json, and read again
/// when it reports a failure).
pub fn Reply(comptime T: type) type {
    return struct {
        parsed: std.json.Parsed(T),
        line: []u8,
        gpa: std.mem.Allocator,

        pub fn deinit(self: @This()) void {
            self.parsed.deinit();
            self.gpa.free(self.line);
        }
    };
}

/// Send a request; a failed reply is reported on stderr and ends the
/// command with the exit code its code calls for.
fn call(gpa: std.mem.Allocator, req: anytype, comptime Resp: type) !Reply(Resp) {
    const reply = try request(gpa, req, Resp);
    if (reply.parsed.value.ok) return reply;
    failReply(gpa, reply.line, false);
}

/// Report a failed reply and exit with the code its code calls for.
/// With `pinned`, the request named a session by the id an earlier reply
/// gave, so no_session means it was removed meanwhile: exit 4.
fn failReply(gpa: std.mem.Allocator, line: []const u8, pinned: bool) noreturn {
    const parsed = std.json.parseFromSlice(protocol.ErrorReply, gpa, line, .{ .ignore_unknown_fields = true }) catch
        runtimeFail("the daemon sent a malformed reply", .{});
    const code = parsed.value.code;
    const removed = pinned and std.mem.eql(u8, code, @tagName(protocol.Code.no_session));
    runtimeFailWith(if (removed) exit_code.ended else exitFor(code), "{s}", .{parsed.value.err});
}

/// The exit code for a failed reply.
pub fn failureExit(gpa: std.mem.Allocator, line: []const u8) u8 {
    const parsed = std.json.parseFromSlice(protocol.ErrorReply, gpa, line, .{ .ignore_unknown_fields = true }) catch
        return exit_code.failed;
    defer parsed.deinit();
    return exitFor(parsed.value.code);
}

pub fn runtimeFailWith(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    attach_client.restoreTerminal();
    stderrPrint("tuppet: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(code);
}

/// The message of a failed reply, owned by the caller.
pub fn failureText(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(protocol.ErrorReply, gpa, line, .{ .ignore_unknown_fields = true }) catch
        return gpa.dupe(u8, "the daemon sent a malformed reply");
    defer parsed.deinit();
    return gpa.dupe(u8, if (parsed.value.err.len > 0) parsed.value.err else "the request failed");
}

pub fn request(gpa: std.mem.Allocator, req: anytype, comptime Resp: type) !Reply(Resp) {
    try checkProtocol(gpa);
    return requestRetried(gpa, req, Resp, ipc.request_timeout_ns);
}

/// Send a request; one that a stopping daemon refused goes again, to the
/// next daemon.
fn requestRetried(gpa: std.mem.Allocator, req: anytype, comptime Resp: type, timeout_ns: i64) !Reply(Resp) {
    const reply = try requestResent(gpa, req, Resp, timeout_ns);
    if (reply.parsed.value.ok or !try nextDaemon(gpa, reply.line, namesSessions(req))) return reply;
    reply.deinit();
    return requestResent(gpa, req, Resp, timeout_ns);
}

fn requestResent(gpa: std.mem.Allocator, req: anytype, comptime Resp: type, timeout_ns: i64) !Reply(Resp) {
    return requestOnce(gpa, req, Resp, timeout_ns) catch |err| {
        // An idle daemon that exits resets the connections it had not
        // accepted yet, so it never read this request. The retry starts
        // a new daemon.
        if (err != error.ConnectionResetByPeer or daemon_contacted) return err;
        return requestOnce(gpa, req, Resp, timeout_ns);
    };
}

fn requestOnce(gpa: std.mem.Allocator, req: anytype, comptime Resp: type, timeout_ns: i64) !Reply(Resp) {
    var conn = try ensureDaemon(gpa);
    defer conn.deinit();
    try sendRequest(gpa, &conn, req);
    const split = try conn.recvLineAfter(gpa, max_reply, "", timeout_ns);
    gpa.free(split.rest);
    daemon_contacted = true;
    return parseReply(gpa, Resp, split.line);
}

/// 16 MiB matches the daemon's reply limit (enough for base64-encoded PNG
/// snapshots); a reply's buffer grows with the actual reply instead.
pub const max_reply = 1 << 24;

pub fn sendRequest(gpa: std.mem.Allocator, conn: *ipc.Conn, req: anytype) !void {
    const line = try protocol.stringifyRequest(gpa, req);
    defer gpa.free(line);
    // The daemon's request buffer is 1 MiB; fail fast instead of
    // leaving the connection in a broken state.
    if (line.len >= 1 << 20) return cliFail("request too large (daemon limit is 1 MiB)", .{});
    try conn.sendLine(line);
}

/// Parse a reply line, which the result owns.
pub fn parseReply(gpa: std.mem.Allocator, comptime Resp: type, line: []u8) !Reply(Resp) {
    errdefer gpa.free(line);
    // alloc_always: reply strings (e.g. png_b64) must not depend on
    // the line. ignore_unknown_fields tolerates replies from a newer
    // daemon.
    const parsed = std.json.parseFromSlice(Resp, gpa, line, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch
        runtimeFail("the daemon sent a malformed reply", .{});
    return .{ .parsed = parsed, .line = line, .gpa = gpa };
}

/// Make sure the daemon speaks this protocol revision before the first
/// request: an older daemon that is still running would misread it.
fn checkProtocol(gpa: std.mem.Allocator) !void {
    if (protocol_checked) return;
    const Hello = struct { ok: bool = false, protocol: u32 = 0, boot: []const u8 = "", features: []const []const u8 = &.{}, variant: []const u8 = "" };
    // Hello is never refused for a shutdown.
    const reply = try requestResent(gpa, protocol.HelloReq{}, Hello, ipc.request_timeout_ns);
    defer reply.deinit();
    const hello = reply.parsed.value;
    if (hello.ok and hello.protocol == protocol.protocol_version) {
        const n = @min(hello.boot.len, daemon_boot_buf.len);
        @memcpy(daemon_boot_buf[0..n], hello.boot[0..n]);
        daemon_boot = daemon_boot_buf[0..n];
        var w: std.Io.Writer = .fixed(&daemon_features_buf);
        for (hello.features, 0..) |feature, i| w.print("{s}{s}", .{ if (i > 0) "," else "", feature }) catch break;
        daemon_features = w.buffered();
        const v = @min(hello.variant.len, daemon_variant_buf.len);
        @memcpy(daemon_variant_buf[0..v], hello.variant[0..v]);
        daemon_variant = daemon_variant_buf[0..v];
        protocol_checked = true;
        return;
    }
    if (hello.ok and hello.protocol > protocol.protocol_version) {
        runtimeFail("the daemon on {s} speaks protocol {d}, but this tuppet speaks {d}; use the newer tuppet, or stop that daemon and let this one start its own", .{ daemon_path, hello.protocol, protocol.protocol_version });
    }
    if (socket_override != null) {
        runtimeFail("the daemon on {s} speaks protocol {d}, but this tuppet needs {d}; restart that daemon with this tuppet", .{ daemon_path, hello.protocol, protocol.protocol_version });
    }
    runtimeFail("the daemon on {s} is an older tuppet that speaks protocol {d}, but this tuppet needs {d}; " ++ old_daemon_hint ++ " (ended sessions are kept, running programs end)", .{ daemon_path, hello.protocol, protocol.protocol_version });
}

/// After a reply with code `stopping`: wait until that daemon is gone and
/// check the next one, which this may start, then return true. On an
/// explicit endpoint no daemon would start, so this fails instead, as it
/// does for a request that `names_sessions` when the store was reset
/// meanwhile, so that its ids may name other sessions now.
fn nextDaemon(gpa: std.mem.Allocator, line: []const u8, names_sessions: bool) !bool {
    if (!failedWith(gpa, line, .stopping)) return false;
    if (socket_override != null) runtimeFail("the daemon on {s} is shutting down", .{daemon_path});
    if (!awaitGone(daemon_path)) runtimeFail("the daemon on {s} is shutting down, but did not exit within 10 s", .{daemon_path});
    var old_buf: [96]u8 = undefined;
    const old = old_buf[0..daemon_boot.len];
    @memcpy(old, daemon_boot);
    daemon_contacted = false;
    protocol_checked = false;
    try checkProtocol(gpa);
    if (names_sessions and !std.mem.eql(u8, old, daemon_boot)) {
        runtimeFail("the daemon on {s} shut down and reset the session store, so session ids may name other sessions now; nothing was sent again", .{daemon_path});
    }
    return true;
}

/// Whether `req` picks sessions by reference, so that a reset of the
/// store can change what it acts on.
fn namesSessions(req: anytype) bool {
    const T = @TypeOf(req);
    if (T == protocol.HelloReq) return false;
    // A listed session is often acted on next.
    if (T == protocol.ListReq) return req.sessions != null;
    if (T == protocol.RunReq) return req.like != null;
    return true;
}

/// Whether `line` is a failed reply with `code`.
fn failedWith(gpa: std.mem.Allocator, line: []const u8, code: protocol.Code) bool {
    const parsed = std.json.parseFromSlice(protocol.ErrorReply, gpa, line, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    return !parsed.value.ok and std.mem.eql(u8, parsed.value.code, @tagName(code));
}

/// How long a daemon that is shutting down may take to exit.
const exit_wait_ns: i64 = 30 * std.time.ns_per_s;

/// Wait until nothing answers on `path` any more; false when something
/// still does after `exit_wait_ns`.
fn awaitGone(path: []const u8) bool {
    const deadline = io_mod.nowNanos() + exit_wait_ns;
    while (io_mod.nowNanos() < deadline) {
        var conn = ipc.Conn.connect(path) catch return true;
        conn.deinit();
        std.Io.sleep(io_mod.io(), .fromMilliseconds(20), .boot) catch {};
    }
    return false;
}

fn rememberPath(path: []const u8) void {
    const n = @min(path.len, daemon_path_buf.len);
    @memcpy(daemon_path_buf[0..n], path[0..n]);
    daemon_path = daemon_path_buf[0..n];
}

/// The endpoint of the daemon this client talks to, as the daemon names
/// it in the store and in TUPPET_SESSION_SOCKET. Caller owns the result.
pub fn daemonEndpoint(gpa: std.mem.Allocator) ![]u8 {
    if (socket_override) |path| return absolutePath(gpa, path);
    var path_buf: [ipc.max_path_len:0]u8 = undefined;
    return gpa.dupe(u8, try defaultPath(&path_buf));
}

/// The endpoint of the user's default daemon.
fn defaultPath(buf: *[ipc.max_path_len:0]u8) ![:0]const u8 {
    return ipc.socketPath(buf) catch |err| switch (err) {
        error.SocketPathTooLong => runtimeFail("XDG_RUNTIME_DIR is too long for a socket path; use a shorter directory", .{}),
        error.UnsafeRuntimeDir => runtimeFail("cannot use the private runtime directory /tmp/tuppet-<uid> (it must be a directory owned by you)", .{}),
        error.UnknownUser => return err,
    };
}

fn ensureDaemon(gpa: std.mem.Allocator) !ipc.Conn {
    if (socket_override) |path| {
        rememberPath(path);
        if (ipc.Conn.connect(path)) |conn| return conn else |err| switch (err) {
            error.UntrustedDaemon => runtimeFail("the socket {s} is served by another user's process; refusing to use it", .{path}),
            error.BadPath => return cliFail("socket path '{s}' is empty or too long", .{path}),
            else => return error.NoDaemon,
        }
    }
    var path_buf: [ipc.max_path_len:0]u8 = undefined;
    const path = try defaultPath(&path_buf);
    rememberPath(path);

    // A daemon between two connections can briefly refuse one; retry
    // before concluding that none is running.
    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        if (ipc.Conn.connect(path)) |conn| return conn else |err| {
            if (err == error.UntrustedDaemon) runtimeFail("the socket {s} is served by another user's process; refusing to use it", .{path});
        }
        if (daemon_contacted) break;
        std.Io.sleep(io_mod.io(), .fromMilliseconds(20), .boot) catch {};
    }
    if (daemon_contacted) return error.DaemonGone;

    // A daemon cannot create its socket in a missing directory; say so
    // instead of waiting for it.
    if (builtin.os.tag != .windows) {
        const dir = std.fs.path.dirname(path) orelse "/";
        var dir_buf: [ipc.max_path_len:0]u8 = undefined;
        const dir_z = std.mem.printSentinel(&dir_buf, "{s}", .{dir}, 0) catch unreachable;
        if (std.c.access(dir_z, std.c.F_OK) != 0) runtimeFail("runtime directory {s} does not exist", .{dir});
    }

    var log_buf: [ipc.max_path_len:0]u8 = undefined;
    const log_path = ipc.logPath(&log_buf, path);
    // The log is appended to across daemon starts: only what this start
    // adds is news.
    const log_start = if (log_path) |lp| logEnd(lp) else 0;
    const daemon = try spawnDaemon(gpa, log_path);

    const io = io_mod.io();
    var tries: u32 = 0;
    const exited = while (tries < 50) : (tries += 1) {
        std.Io.sleep(io, .fromMilliseconds(50), .boot) catch {};
        if (ipc.Conn.connect(path)) |conn| return conn else |_| {}
        const pid = daemon orelse continue;
        if (processGone(pid)) {
            // One that lost a start race exits once the winner answers.
            if (ipc.Conn.connect(path)) |conn| return conn else |_| {}
            break true;
        }
    } else false;
    // The daemon's own error (stderr) explains why it did not come up.
    if (exited) {
        if (log_path) |lp| if (reportDaemonLog(lp, log_start, "the daemon exited as it started")) return error.DaemonStartFailed;
        return error.DaemonExited;
    }
    if (log_path) |lp| _ = reportDaemonLog(lp, log_start, "daemon log");
    return error.DaemonStartTimeout;
}

fn processGone(pid: std.c.pid_t) bool {
    if (builtin.os.tag == .windows) return false;
    const alive = std.c.kill(pid, @fromBackingInt(0));
    return alive != 0 and std.posix.errno(alive) == .SRCH;
}

/// The size of the log at `log_path`; 0 when there is none.
fn logEnd(log_path: [:0]const u8) std.c.off_t {
    if (builtin.os.tag == .windows) return 0;
    const fd = std.c.open(log_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    return @max(0, std.c.lseek(fd, 0, std.c.SEEK.END));
}

/// Print what the daemon logged from offset `start` on, its last 4 KiB
/// at most, under `heading`; whether there was anything.
fn reportDaemonLog(log_path: [:0]const u8, start: std.c.off_t, heading: []const u8) bool {
    // The Windows daemon is started without a log file.
    if (builtin.os.tag == .windows) return false;
    // Plain open/read: Zig's readFileAlloc sizes the file with statx,
    // which kernels before 4.11 lack.
    const fd = std.c.open(log_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var buf: [4096]u8 = undefined;
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end <= start) return false;
    // Cut short, it begins after the byte before it, at a line.
    const from = @max(start, end - @as(std.c.off_t, buf.len - 1));
    const read_from = if (from > start) from - 1 else from;
    if (std.c.lseek(fd, read_from, std.c.SEEK.SET) != read_from) return false;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return false;
    var text = buf[0..@intCast(n)];
    if (from > start) if (std.mem.indexOfScalar(u8, text, '\n')) |nl| {
        // A line longer than all of it shows its end.
        if (nl + 1 < std.mem.trimEnd(u8, text, " \n").len) text = text[nl + 1 ..];
    };
    const trimmed = std.mem.trim(u8, text, " \n");
    if (trimmed.len == 0) return false;
    stderrPrint("tuppet: {s} ({s}):\n{s}\n", .{ heading, log_path, trimmed }) catch {};
    return true;
}

/// Start `tuppet daemon` fully detached: on POSIX in its own session (so the
/// caller's Ctrl-C, terminal hangup, or `timeout` cannot kill it with
/// every session in it), not a session leader (so it can never acquire
/// a session's pty as its controlling terminal), with only stdio open
/// and stderr in the log file. Windows: no console of its own, so the
/// caller's Ctrl-C does not reach it. Returns the daemon's pid when it is
/// known.
fn spawnDaemon(gpa: std.mem.Allocator, log_path: ?[:0]const u8) !?std.c.pid_t {
    const io = io_mod.io();
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    // Sessions started without a caller environment (raw protocol
    // clients) inherit the daemon's, so it gets a usable TERM too.
    var env_map = try std.process.Environ.createMap(io_mod.environ, gpa);
    defer env_map.deinit();
    try env_map.put("TERM", "xterm-256color");

    if (builtin.os.tag == .windows) {
        try spawnDaemonWindows(gpa, exe_buf[0..exe_len]);
        return null;
    }

    // Everything the child needs is prepared before fork; after it only
    // async-signal-safe calls run.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exe_z = try arena.dupeSentinel(u8, exe_buf[0..exe_len], 0);
    const argv = try arena.allocSentinel(?[*:0]const u8, 2, null);
    argv[0] = exe_z.ptr;
    argv[1] = "daemon";
    const envp = try arena.allocSentinel(?[*:0]const u8, env_map.count(), null);
    var env_it = env_map.iterator();
    var n: usize = 0;
    while (env_it.next()) |entry| : (n += 1) {
        envp[n] = (try arena.printSentinel("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0)).ptr;
    }
    var limit: std.c.rlimit = undefined;
    const max_fd: c_int = if (std.c.getrlimit(.NOFILE, &limit) == 0) @intCast(@min(limit.cur, 65536)) else 1024;

    // The intermediate child tells the daemon's pid through this.
    var pid_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pid_pipe) != 0) return error.ForkFailed;
    defer _ = std.c.close(pid_pipe[0]);
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pid_pipe[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        if (std.c.setsid() < 0) std.c._exit(1);
        const grandchild = std.c.fork();
        if (grandchild != 0) {
            if (grandchild > 0) _ = std.c.write(pid_pipe[1], std.mem.asBytes(&grandchild), @sizeOf(std.c.pid_t));
            std.c._exit(if (grandchild < 0) 1 else 0);
        }
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        const log_fd = if (log_path) |lp|
            // Append: a daemon that loses a start race must not truncate
            // the winner's log.
            std.c.open(lp, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600))
        else
            -1;
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 1);
        }
        _ = std.c.dup2(if (log_fd >= 0) log_fd else devnull, 2);
        var fd: c_int = 3;
        while (fd < max_fd) : (fd += 1) _ = std.c.close(fd);
        _ = std.c.execve(exe_z.ptr, argv.ptr, envp.ptr);
        std.c._exit(127);
    }
    _ = std.c.close(pid_pipe[1]);
    // The intermediate child exits at once; reap it.
    var wait_status: c_int = 0;
    _ = std.c.waitpid(pid, &wait_status, 0);
    var daemon: std.c.pid_t = 0;
    if (std.c.read(pid_pipe[0], std.mem.asBytes(&daemon), @sizeOf(std.c.pid_t)) != @sizeOf(std.c.pid_t)) return null;
    return daemon;
}

/// Windows: no console (the caller's Ctrl-C does not reach it), its own
/// process group, and out of the caller's job object when the job allows
/// it, so a CI runner or terminal that kills its job on exit does not
/// take the daemon along.
fn spawnDaemonWindows(gpa: std.mem.Allocator, exe: []const u8) !void {
    const win32 = @import("win32.zig");
    const cmd = try std.fmt.allocPrint(gpa, "\"{s}\" daemon", .{exe});
    defer gpa.free(cmd);
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, cmd);
    defer gpa.free(cmd_w);
    const breakaway: win32.DWORD = 0x01000000; // CREATE_BREAKAWAY_FROM_JOB
    const base = win32.CREATE_NO_WINDOW | win32.CREATE_NEW_PROCESS_GROUP;
    for ([_]win32.DWORD{ base | breakaway, base }) |flags| {
        var si = std.mem.zeroes(win32.STARTUPINFOW);
        si.cb = @sizeOf(win32.STARTUPINFOW);
        var pi = std.mem.zeroes(win32.PROCESS_INFORMATION);
        if (win32.CreateProcessW(null, cmd_w.ptr, null, null, 0, flags, null, null, &si, &pi) != 0) {
            _ = win32.CloseHandle(pi.hThread);
            _ = win32.CloseHandle(pi.hProcess);
            return;
        }
    }
    return error.DaemonSpawnFailed;
}

/// The size of a session started without --size or TUPPET_SIZE: wide enough
/// for the full layout of most current TUIs, and the same everywhere, so
/// screens do not depend on the terminal tuppet was run from.
pub const default_cols: u16 = 120;
pub const default_rows: u16 = 40;

pub fn sizeValue(s: []const u8) ?[2]u16 {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse return null;
    const cols = protocol.parseDecimal(u16, s[0..x]) orelse return null;
    const rows = protocol.parseDecimal(u16, s[x + 1 ..]) orelse return null;
    if (!limits.validSize(cols, rows)) return null;
    return .{ cols, rows };
}

/// Parse "WxH" into {cols, rows}, rejecting anything else. Both
/// dimensions must be in limits.size_range: zero or absurd sizes would
/// reach the pty and the emulated grid.
pub fn parseSize(s: []const u8) error{UsageError}![2]u16 {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse
        return cliFail("invalid size '{s}' (expected WxH, e.g. 120x40)", .{s});
    const cols = protocol.parseDecimal(u16, s[0..x]) orelse
        return cliFail("invalid size '{s}' (width must be a number)", .{s});
    const rows = protocol.parseDecimal(u16, s[x + 1 ..]) orelse
        return cliFail("invalid size '{s}' (height must be a number)", .{s});
    if (cols < 1 or cols > limits.max_side) return cliFail("invalid size '{s}' (width must be " ++ limits.size_range ++ ")", .{s});
    if (rows < 1 or rows > limits.max_side) return cliFail("invalid size '{s}' (height must be " ++ limits.size_range ++ ")", .{s});
    return .{ cols, rows };
}

fn parseCoordinate(name: []const u8, value: []const u8) error{UsageError}!u16 {
    return protocol.parseDecimal(u16, value) orelse
        cliFail("invalid {s} coordinate '{s}' (expected a number)", .{ name, value });
}

fn stdoutWrite(bytes: []const u8) !void {
    try plat.stdoutWriteAll(bytes);
}

fn stdoutPrint(comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(s);
    try plat.stdoutWriteAll(s);
}

fn nowMillis() i64 {
    const ts = std.Io.Clock.Timestamp.now(io_mod.io(), .real);
    return @intCast(@divFloor(ts.raw.nanoseconds, std.time.ns_per_ms));
}

/// Messages embed daemon errors and user input of any length.
fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(s);
    try plat.stderrWriteAll(s);
}

/// What a client-side error means, in words; "" when it was reported
/// already or there is no one to tell, null for errors without a text.
pub fn errorText(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.DaemonStartTimeout => "daemon did not start in time",
        error.DaemonStartFailed => "",
        error.DaemonExited => "the daemon exited as it started, without saying why",
        error.DaemonGone => "the daemon stopped running during this command",
        error.NoDaemon => "the daemon is not reachable",
        error.AddressInUse => "a daemon is already listening on that socket",
        error.EndpointPathOccupied => "the socket path is taken by something that is not this user's socket",
        error.CannotOpenLog => "cannot open the log file",
        error.SocketPathTooLong, error.BadPath => "the socket path is empty or too long",
        error.Eof, error.ConnectionResetByPeer => "daemon closed the connection",
        error.ReadTimeout, error.WriteTimeout => "daemon did not respond in time",
        error.WriteFailed, error.ReadFailed => "daemon connection failed",
        error.MissingPng => "daemon sent no PNG data",
        error.StoreUnavailable => "cannot use the session store; the message above says why",
        error.OutputFailed => "cannot write to standard output",
        // The reader went away: nothing left to report to.
        error.BrokenPipe => "",
        error.InvalidCharacter => "daemon sent a malformed PNG payload",
        error.OutOfMemory => "out of memory",
        else => null,
    };
}
