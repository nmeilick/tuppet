//! `tuppet start`: open a session and log it in through the steps of the
//! start file (src/start.zig), then attach; and `--check` and the list of
//! ids. Everything goes through requests that exist: run, input with
//! until, wait, view, list, and stop.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const plat = @import("plat.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const names = @import("names.zig");
const units = @import("units.zig");
const status = @import("status.zig");
const client = @import("client.zig");
const attach_client = @import("attach_client.zig");
const drawn_mod = @import("drawn.zig");
const start = @import("start.zig");
const start_record = @import("start_record.zig");
const store = @import("store.zig");
const AfterInput = @import("cond.zig").AfterInput;
const regex = @import("regex.zig");
const vt = @import("vt");

const exit_code = client.exit_code;
const cliFail = client.cliFail;
const runtimeFail = client.runtimeFail;

pub const usage = "usage: tuppet start [<id>...] [-d] [--new] [-A] | --check [<id>] | --record <id> [-- <command>...]";

pub fn cmdStart(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ids: std.ArrayList([]const u8) = .empty;
    var check = false;
    var opts: Opts = .{};
    var rec = false;
    var command: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (client.isOpt(arg, "--detached", "-d")) {
            opts.detached = true;
        } else if (std.mem.eql(u8, arg, "--new")) {
            opts.new = true;
        } else if (client.isOpt(arg, "--atomic", "-A")) {
            opts.atomic = true;
        } else if (std.mem.eql(u8, arg, "--record")) {
            rec = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            if (!rec) return cliFail("'--' and a command go with --record", .{});
            command = args[i + 1 ..];
            break;
        } else if (arg.len > 1 and arg[0] == '-') {
            return cliFail("unknown option '{s}'\n{s}", .{ arg, usage });
        } else try ids.append(a, arg);
    }
    if (check and rec) return cliFail("--check and --record do not go together", .{});
    if ((check or rec) and (opts.detached or opts.new or opts.atomic)) return cliFail("{s} goes with none of --detached, --new, and --atomic", .{if (check) "--check" else "--record"});
    if ((check or rec) and ids.items.len > 1) return cliFail("{s} takes one id", .{if (check) "--check" else "--record"});
    for (ids.items) |given| {
        if (names.kind(given) == .pattern) return cliFail("'{s}' is a pattern: patterns go in the start file; name each id, or a group", .{given});
        if (names.nameError(given)) |why| return cliFail("invalid id '{s}': {s}", .{ given, why });
    }
    if (rec) {
        if (ids.items.len == 0) return cliFail("--record needs the id to record: tuppet start --record <id>", .{});
        return start_record.record(gpa, ids.items[0], command);
    }
    const file = try load(a, check or ids.items.len > 0);
    if (check) return checkFile(a, &file, if (ids.items.len > 0) ids.items[0] else null);
    if (ids.items.len == 0) return listIds(gpa, a, &file);
    // A group opens into its ids; an id given twice starts once.
    var started: std.ArrayList([]const u8) = .empty;
    var group = false;
    for (ids.items) |given| {
        if (groupNamed(&file, given)) |g| {
            group = true;
            for (g.names[1..]) |m| try addOnce(a, &started, m);
        } else try addOnce(a, &started, given);
    }
    return run(gpa, a, &file, started.items, group or started.items.len > 1, opts);
}

/// The group `name` names, failing on a broken one, unless a start block
/// names `name` exactly: then the broken group is only a warning.
fn groupNamed(file: *const start.File, name: []const u8) ?*const start.Block {
    const g = file.groupFor(name) orelse return null;
    const pr = g.problem orelse return g;
    if (file.startFor(name)) |b| for (b.names) |n| if (std.mem.eql(u8, n, name)) return null;
    runtimeFail("{s}:{d}: {s}", .{ file.path, pr.line, pr.text });
}

fn addOnce(a: std.mem.Allocator, list: *std.ArrayList([]const u8), id: []const u8) !void {
    for (list.items) |had| if (std.mem.eql(u8, had, id)) return;
    try list.append(a, id);
}

/// The start file, read and checked for who may change it. Without one,
/// an empty file; `needed` fails instead.
pub fn load(a: std.mem.Allocator, needed: bool) !start.File {
    const text = try loadText(a, needed, false);
    return start.parse(a, text.path, text.text);
}

/// The start file's path and text.
pub const Text = struct { path: []const u8, text: []const u8 };

/// Read the start file, refused when others may change it. Without one,
/// an empty text, unless `needed`; `absent_ok` takes even a file that
/// TUPPET_START names but does not exist yet as empty.
pub fn loadText(a: std.mem.Allocator, needed: bool, absent_ok: bool) !Text {
    const found = try start.filePath(a) orelse {
        if (needed) runtimeFail("no start file to read (TUPPET_START is empty, or HOME is not set)", .{});
        return .{ .path = "", .text = "" };
    };
    const io = io_mod.io();
    const file = std.Io.Dir.cwd().openFile(io, found.path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            if (absent_ok or (!needed and !found.given)) return .{ .path = found.path, .text = "" };
            runtimeFail("{s}: no such file; 'tuppet start --record <id>' writes a first block", .{found.path});
        }
        runtimeFail("{s}: cannot open it: {s}", .{ found.path, @errorName(err) });
    };
    defer file.close(io);
    if (ipc.untrusted(file.handle)) |why|
        runtimeFail("{s}: refused, because {s}: its steps type into your sessions ('chmod go-w {s}' if it is yours)", .{ found.path, why, found.path });
    const st = file.stat(io) catch |err| runtimeFail("{s}: cannot read it: {s}", .{ found.path, @errorName(err) });
    if (st.size > 1 << 20) runtimeFail("{s}: larger than 1 MiB", .{found.path});
    const bytes = try a.alloc(u8, @intCast(st.size));
    const n = file.readPositionalAll(io, bytes, 0) catch |err| runtimeFail("{s}: cannot read it: {s}", .{ found.path, @errorName(err) });
    return .{ .path = found.path, .text = bytes[0..n] };
}

// ---- --check and the list ------------------------------------------------

fn checkFile(a: std.mem.Allocator, file: *const start.File, id: ?[]const u8) !void {
    var problems: usize = 0;
    for (file.stray) |p| {
        try errPrint("{s}:{d}: {s}\n", .{ file.path, p.line, p.text });
        problems += 1;
    }
    if (id) |given| {
        var members: []const []const u8 = &.{given};
        if (groupNamed(file, given)) |g| {
            try outPrint("{s} ({s}:{d}), a group, one after another:\n", .{ given, file.path, g.line });
            members = g.names[1..];
        }
        for (members) |m| {
            const p = start.plan(a, file, m) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Bad => runtimeFail("{s}", .{start.badText()}),
            };
            try printPlan(a, file, &p);
            for (p.notes) |n| try errPrint("note: {s}\n", .{n});
            for (p.secrets) |v| if (envValue(v) == null)
                try errPrint("note: ${s} is not set; in a terminal tuppet asks for it\n", .{v});
        }
        if (problems > 0) std.process.exit(exit_code.failed);
        return;
    }
    var used: std.ArrayList([]const u8) = .empty;
    for (file.blocks) |*b| {
        if (b.problem) |p| {
            try errPrint("{s}:{d}: {s}\n", .{ file.path, p.line, p.text });
            problems += 1;
            continue;
        }
        for (b.items) |it| if (it.keyword == .use) {
            // A `use` that does not split is reported with its block.
            const ws = start.words(a, it.value) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Bad => continue,
            };
            if (ws.len > 0) try used.append(a, ws[0]);
        };
        if (b.kind != .start) continue;
        const p = start.planBlock(a, file, b, b.names[0]) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Bad => {
                try errPrint("{s}\n", .{start.badText()});
                problems += 1;
                continue;
            },
        };
        for (p.notes) |n| try errPrint("note: {s}\n", .{n});
    }
    for (file.blocks) |*b| for (b.items) |it| switch (it.keyword) {
        .expect, .@"or", .gone, .when => {
            if (std.mem.indexOf(u8, it.value, " #") != null)
                try errPrint("{s}:{d}: note: ' #' is part of the text '{s}': a comment goes on a line of its own\n", .{ file.path, it.line, it.value });
            if (!it.regex and std.mem.indexOfScalar(u8, it.value, '*') != null)
                try errPrint("{s}:{d}: note: '*' in '{s}' is matched as it is: for a pattern, write {s}(re)\n", .{ file.path, it.line, it.value, @tagName(it.keyword) });
        },
        else => {},
    };
    for (file.blocks) |*b| if (b.kind == .steps and b.problem == null) {
        for (used.items) |u| {
            if (std.mem.eql(u8, u, b.names[0])) break;
        } else try errPrint("{s}:{d}: note: no block uses the steps '{s}'\n", .{ file.path, b.line, b.names[0] });
    };
    if (problems > 0) std.process.exit(exit_code.failed);
    try outPrint("{s}: {d} block{s}, no problems\n", .{ file.path, file.blocks.len, if (file.blocks.len == 1) "" else "s" });
}

fn printPlan(a: std.mem.Allocator, file: *const start.File, p: *const start.Plan) !void {
    try outPrint("{s} ({s}:{d}), {d} steps:\n", .{ p.id, file.path, p.block_line, p.steps.len });
    if (p.command) |c| try outPrint("  command  {s}\n", .{try std.mem.join(a, " ", c)});
    if (p.dir) |d| try outPrint("  dir      {s}\n", .{d});
    if (p.size) |s| try outPrint("  size     {d}x{d}\n", .{ s[0], s[1] });
    // Each `when` once, where it stands: under the input it follows, or
    // above the first check that watches for it. Their origins only grow.
    var shown: ?u32 = null;
    for (p.steps, 0..) |s, n| {
        if (s.check()) try printWhens(a, p, s.whens, &shown);
        const o = p.origins[s.origin];
        var line: std.ArrayList(u8) = .empty;
        try line.print(a, "  {d: >4}  {s: <7}  {s}", .{ o.line, @tagName(s.kind), try stepText(a, s) });
        if (s.check()) {
            var buf: [32]u8 = undefined;
            try line.print(a, "   ({s})", .{units.durationText(&buf, s.timeout_ms)});
        } else if (n + 1 == p.steps.len or !p.steps[n + 1].check()) try line.appendSlice(a, "   (no check: pauses)");
        if (o.block) |b| {
            try line.print(a, "   in {s}", .{b});
            var at = o.parent;
            var first = true;
            while (at) |pi| : (first = false) {
                const po = p.origins[pi];
                try line.print(a, "{s} line {d}", .{ if (first) ", used at" else ",", po.line });
                at = po.parent;
            }
        }
        try outPrint("{s}\n", .{line.items});
        if (!s.check()) try printWhens(a, p, s.whens, &shown);
    }
}

fn printWhens(a: std.mem.Allocator, p: *const start.Plan, whens: []const start.When, shown: *?u32) !void {
    for (whens) |w| {
        if (shown.* != null and w.origin <= shown.*.?) continue;
        shown.* = w.origin;
        const ao = p.origins[w.answer_origin];
        try outPrint("  {d: >4}  when     {s}   answered: {s} {s}\n", .{ p.origins[w.origin].line, try patternText(a, w.pattern), @tagName(ao.keyword), ao.value });
    }
}

fn patternText(a: std.mem.Allocator, p: start.Pattern) ![]const u8 {
    return if (p.regex) try std.fmt.allocPrint(a, "(re) {s}", .{p.text}) else p.text;
}

/// A step as it will run, in one line.
fn stepText(a: std.mem.Allocator, s: start.Step) ![]const u8 {
    return switch (s.kind) {
        .send, .type, .keys => s.text,
        .gone => patternText(a, s.alts[0]),
        .secret => if (s.text.len > 0) try std.fmt.allocPrint(a, "${s}", .{s.text}) else "(asks you)",
        .ask => "(asks you)",
        .expect => blk: {
            var texts: std.ArrayList([]const u8) = .empty;
            for (s.alts) |t| try texts.append(a, try patternText(a, t));
            break :blk try std.mem.join(a, "  or  ", texts.items);
        },
        .settle => blk: {
            var buf: [32]u8 = undefined;
            break :blk try a.dupe(u8, units.durationText(&buf, s.settle_ms));
        },
        .ended => if (s.status) |code| try std.fmt.allocPrint(a, "(exit status {d})", .{code}) else "(the program ends)",
    };
}

fn listIds(gpa: std.mem.Allocator, a: std.mem.Allocator, file: *const start.File) !void {
    if (file.blocks.len == 0) {
        try errPrint("tuppet: {s}: no start blocks yet; 'tuppet start --record <id>' writes one\n", .{if (file.path.len > 0) file.path else "the start file"});
        return;
    }
    const listed = try client.request(gpa, protocol.ListReq{}, protocol.ListResp);
    defer listed.deinit();
    const sessions = if (listed.parsed.value.ok) listed.parsed.value.sessions else &.{};
    for ([_]bool{ false, true }) |patterns| for (file.blocks) |*b| {
        if (b.kind != .start or b.problem != null) continue;
        for (b.names) |n| {
            if ((names.kind(n) == .pattern) != patterns) continue;
            var line: std.ArrayList(u8) = .empty;
            try line.print(a, "{s}", .{n});
            for (sessions) |st| if (st.state == .running) if (st.name) |sn| {
                if (patterns) continue;
                if (std.mem.eql(u8, sn, n) or (std.mem.startsWith(u8, sn, n) and sn.len > n.len + 1 and sn[n.len] == '-' and allDigits(sn[n.len + 1 ..])))
                    try line.print(a, "  running: {s} (session {d})", .{ sn, st.id });
            };
            try outPrint("{s}\n", .{line.items});
        }
    };
    for (file.blocks) |*b| {
        if (b.kind != .group or b.problem != null) continue;
        var running: usize = 0;
        for (b.names[1..]) |m| for (sessions) |st| if (st.state == .running) if (st.name) |sn| {
            if (std.mem.eql(u8, sn, m)) running += 1;
        };
        try outPrint("{s}  group: {s}  ({d} of {d} running)\n", .{ b.names[0], try std.mem.join(a, " ", b.names[1..]), running, b.names.len - 1 });
    }
}

fn allDigits(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return text.len > 0;
}

// ---- running ---------------------------------------------------------------

const Opts = struct {
    detached: bool = false,
    new: bool = false,
    /// When one start fails, stop every session the run opened.
    atomic: bool = false,
};

/// What a start needs before its session opens.
const Prepared = struct {
    id: []const u8,
    plan: start.Plan,
    argv: []const []const u8,
    cwd: []const u8,
    env: []const []const u8,
    size: [2]u16,
};

fn prepare(a: std.mem.Allocator, file: *const start.File, id: []const u8, terminal: bool) !Prepared {
    const p = start.plan(a, file, id) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Bad => runtimeFail("{s}", .{start.badText()}),
    };
    if (!terminal) for (p.secrets) |v| if (envValue(v) == null)
        runtimeFail("${s} is not set: set it, or start in a terminal, where tuppet asks for it", .{v});
    if (!terminal) if (asksYou(&p)) |line|
        runtimeFail("{s}:{d}: this asks you, which needs a terminal", .{ file.path, line });
    const shell: []const u8 = if (std.c.getenv("SHELL")) |sh| std.mem.span(sh) else "/bin/sh";
    const default_argv = try a.dupe([]const u8, &.{if (shell.len > 0) shell else "/bin/sh"});
    const all_env = try client.currentEnv(a, true);
    var env: std.ArrayList([]const u8) = .empty;
    for (all_env) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        for (p.secrets) |v| {
            if (std.mem.eql(u8, entry[0..eq], v)) break;
        } else try env.append(a, entry);
    }
    return .{
        .id = id,
        .plan = p,
        .argv = p.command orelse default_argv,
        .cwd = try client.absolutePath(a, if (p.dir) |d| try homePath(a, d) else "."),
        .env = env.items,
        .size = p.size orelse (if (terminal) attach_client.terminalSize() else null) orelse envSize() orelse .{ client.default_cols, client.default_rows },
    };
}

/// The line of the first step or answer of `p` that asks the person.
fn asksYou(p: *const start.Plan) ?u32 {
    for (p.steps) |s| {
        if (s.kind == .ask or (s.kind == .secret and s.text.len == 0)) return p.origins[s.origin].line;
        for (s.whens) |w| if (w.answer == .secret and w.answer_text.len == 0) return p.origins[w.answer_origin].line;
    }
    return null;
}

fn run(gpa: std.mem.Allocator, a: std.mem.Allocator, file: *const start.File, ids: []const []const u8, many: bool, opts: Opts) !void {
    const terminal = !opts.detached and builtin.os.tag != .windows and std.c.isatty(0) == 1 and std.c.isatty(1) == 1;
    // Every plan first: a broken one opens no session.
    const preps = try a.alloc(Prepared, ids.len);
    var drop: std.ArrayList([]const u8) = .empty;
    for (ids, preps) |id, *pr| {
        pr.* = try prepare(a, file, id, terminal);
        try drop.appendSlice(a, pr.plan.secrets);
    }
    // Other broken blocks do not stop these.
    for (file.stray) |pr| try errPrint("tuppet: warning: {s}:{d}: {s}\n", .{ file.path, pr.line, pr.text });
    for (file.blocks) |*b| if (b.problem) |pr| {
        for (ids) |id| {
            if (file.startFor(id).? == b) break;
        } else try errPrint("tuppet: warning: {s}:{d}: {s}\n", .{ file.path, pr.line, pr.text });
    };
    client.daemon_env_drop = drop.items;
    for (preps) |*pr| try checkDaemon(gpa, file, &pr.plan);
    if (many) return runMany(gpa, a, file, preps, terminal, opts);

    var settings: ?attach_client.Settings = null;
    if (terminal) {
        attach_client.checkSupported();
        var s = try attach_client.settingsFor(gpa, null);
        if (s.drawn) if (try drawn_mod.unsupported(gpa)) |message| {
            plat.stderrWriteAll(message) catch {};
            std.process.exit(exit_code.failed);
        };
        if (s.drawn) s.colors = drawn_mod.queryColors();
        s.resize = preps[0].plan.size == null;
        settings = s;
    }
    var color_text: [2][7]u8 = undefined;
    const colors: ?protocol.RunColors = if (settings) |s| if (s.colors) |c| (if (try client.daemonSupports(gpa, "colors")) .{
        .fg = std.fmt.bufPrint(&color_text[0], "#{x:0>2}{x:0>2}{x:0>2}", .{ c[0].r, c[0].g, c[0].b }) catch unreachable,
        .bg = std.fmt.bufPrint(&color_text[1], "#{x:0>2}{x:0>2}{x:0>2}", .{ c[1].r, c[1].g, c[1].b }) catch unreachable,
    } else null) else null else null;

    const pr = &preps[0];
    const p = &pr.plan;
    const opened = try openSession(gpa, a, pr, colors, opts, if (terminal) settings.? else null, false);
    const session_text = opened.session;
    const name = opened.name;

    var runner: Runner = .{ .gpa = gpa, .plan = p, .file = file, .session = session_text, .name = name, .terminal = terminal, .start_seq = opened.start_seq };
    const outcome = runner.go();
    clearProgress(terminal);
    switch (outcome) {
        .done => {
            // After `ended` there is nothing to attach to.
            const ended = p.steps.len > 0 and p.steps[p.steps.len - 1].kind == .ended;
            if (terminal and ended) try errPrint("tuppet: {s}: the program ended as it should\n", .{name});
            if (terminal and !ended) {
                flushInput();
                attachTo(gpa, session_text, settings.?);
            }
            try outPrint("{s}\n", .{session_text});
        },
        .cancelled => {
            if (opts.atomic) {
                try stopSessions(gpa, &.{session_text});
                try errPrint("tuppet: {s}: stopped at step {d} of {d}; --atomic stopped the session\n", .{ name, runner.reachedNow() + 1, p.steps.len });
                std.process.exit(130);
            }
            markFailed(gpa, a, session_text);
            try errPrint("tuppet: {s}: stopped at step {d} of {d}; the session is yours\n", .{ name, runner.reachedNow() + 1, p.steps.len });
            if (terminal) {
                flushInput();
                attachTo(gpa, session_text, settings.?);
            }
            try outPrint("{s}\n", .{session_text});
            std.process.exit(130);
        },
        .failed => |f| {
            try runner.report(a, f);
            const gone = f.why == .ended or f.why == .status;
            if (opts.atomic) {
                if (!gone) {
                    try stopSessions(gpa, &.{session_text});
                    try errPrint("tuppet: {s}: --atomic stopped session {s}\n", .{ name, session_text });
                }
                std.process.exit(f.code());
            }
            if (!gone) markFailed(gpa, a, session_text);
            if (!terminal or gone) {
                if (!gone) {
                    try errPrint("tuppet: session {s} ({s}) keeps running: 'tuppet attach {s}' takes it over, 'tuppet stop {s}' ends it", .{ session_text, name, name, name });
                    if (std.mem.eql(u8, name, pr.id) and !opts.new) try errPrint(", and starting {s} again replaces it", .{pr.id});
                    try errPrint("\n", .{});
                }
                try outPrint("{s}\n", .{session_text});
                std.process.exit(f.code());
            }
            const o = p.origins[p.steps[f.step].origin];
            while (true) {
                const question = try std.fmt.allocPrint(a, "[Enter] attach   [e] edit {s}:{d}   [q] stop the session: ", .{ file.path, o.line });
                const answer = try askLine(a, question, true) orelse std.process.exit(f.code());
                const word = std.mem.trim(u8, answer, " ");
                if (word.len == 0) {
                    flushInput();
                    attachTo(gpa, session_text, settings.?);
                }
                if (word[0] == 'e' or word[0] == 'E') {
                    edit(a, file.path, o.line);
                    continue;
                }
                if (word[0] == 'q' or word[0] == 'Q') {
                    try stopSessions(gpa, &.{session_text});
                    std.process.exit(f.code());
                }
            }
        },
    }
}

/// Several ids, one after another, none attached: tuppet prints the
/// sessions' ids and exits with the code of the first that failed.
fn runMany(gpa: std.mem.Allocator, a: std.mem.Allocator, file: *const start.File, preps: []const Prepared, terminal: bool, opts: Opts) !void {
    const Result = struct {
        id: []const u8,
        name: []const u8,
        /// Null when the session ended, or was never opened.
        session: ?[]const u8,
        /// This run opened it, rather than finding it running.
        opened: bool,
        failed: bool = false,
    };
    var results: std.ArrayList(Result) = .empty;
    var code: ?u8 = null;
    var cancelled = false;
    for (preps) |*pr| {
        const opened = tryOpen(gpa, a, pr, null, opts, null, true) catch |err| switch (err) {
            error.Refused => {
                try errPrint("tuppet: {s}: no session: {s}\n", .{ pr.id, refusal });
                try results.append(a, .{ .id = pr.id, .name = pr.id, .session = null, .opened = false, .failed = true });
                code = code orelse exit_code.failed;
                if (opts.atomic) break;
                continue;
            },
            else => return err,
        };
        if (opened.existing) {
            try results.append(a, .{ .id = pr.id, .name = opened.name, .session = opened.session, .opened = false });
            continue;
        }
        // A thread left behind by Ctrl-C may still use its runner.
        const runner = try shared.create(Runner);
        runner.* = .{ .gpa = gpa, .plan = &pr.plan, .file = file, .session = opened.session, .name = opened.name, .terminal = terminal, .start_seq = opened.start_seq };
        const outcome = runner.go();
        clearProgress(terminal);
        switch (outcome) {
            .done => {
                const p = &pr.plan;
                const ended = p.steps.len > 0 and p.steps[p.steps.len - 1].kind == .ended;
                if (ended) {
                    try errPrint("tuppet: {s}: the program ended as it should\n", .{opened.name});
                } else try errPrint("tuppet: {s}: ready (session {s})\n", .{ opened.name, opened.session });
                try results.append(a, .{ .id = pr.id, .name = opened.name, .session = if (ended) null else opened.session, .opened = true });
            },
            .cancelled => {
                try errPrint("tuppet: {s}: stopped at step {d} of {d}\n", .{ opened.name, runner.reachedNow() + 1, pr.plan.steps.len });
                if (!opts.atomic) markFailed(gpa, a, opened.session);
                try results.append(a, .{ .id = pr.id, .name = opened.name, .session = opened.session, .opened = true, .failed = true });
                cancelled = true;
                break;
            },
            .failed => |f| {
                try runner.report(a, f);
                const gone = f.why == .ended or f.why == .status;
                if (!gone and !opts.atomic) markFailed(gpa, a, opened.session);
                try results.append(a, .{ .id = pr.id, .name = opened.name, .session = if (gone) null else opened.session, .opened = true, .failed = true });
                code = code orelse f.code();
                if (opts.atomic) break;
            },
        }
    }
    const unstarted = preps.len - results.items.len;
    if (opts.atomic and (cancelled or code != null)) {
        var stop: std.ArrayList([]const u8) = .empty;
        var stopped_names: std.ArrayList(u8) = .empty;
        for (results.items) |r| if (r.opened) if (r.session) |s| {
            try stop.append(a, s);
            try stopped_names.print(a, " {s}", .{r.name});
        };
        try stopSessions(gpa, stop.items);
        if (stop.items.len > 0) try errPrint("tuppet: --atomic stopped what this run opened:{s}\n", .{stopped_names.items});
        if (unstarted > 0) try errPrint("tuppet: --atomic: {d} not started\n", .{unstarted});
        std.process.exit(if (cancelled) 130 else code.?);
    }
    for (results.items) |r| if (r.session) |s| try outPrint("{s}\n", .{s});
    if (!cancelled and code == null) return;
    var failed: std.ArrayList(u8) = .empty;
    var ready: usize = 0;
    for (results.items) |r| {
        if (r.failed) try failed.print(a, " {s}", .{r.name}) else ready += 1;
    }
    try errPrint("tuppet: {d} of {d} ready; did not finish:{s}", .{ ready, preps.len, failed.items });
    if (unstarted > 0) {
        try errPrint("; not started:", .{});
        for (preps[results.items.len..]) |pr| try errPrint(" {s}", .{pr.id});
    }
    try errPrint("\n", .{});
    const replaceable = for (results.items) |r| {
        if (r.failed and r.session != null and !std.mem.eql(u8, r.id, r.name)) break false;
    } else !opts.new;
    if (replaceable) try errPrint("  running the same start again replaces what did not finish, unless someone typed into it or is attached\n", .{});
    std.process.exit(if (cancelled) 130 else code.?);
}

const Opened = struct {
    session: []const u8,
    name: []const u8,
    /// It ran already, and is left as it is.
    existing: bool = false,
    /// The seq the new session started at.
    start_seq: ?u64 = null,
};

/// Open the session for `pr`. A session of that name whose start did not
/// finish, and that nobody typed into since, is replaced. Another running
/// one is kept with several ids (`many`), asked about in a terminal
/// (`settings`), and else left for one named ID-2.
fn openSession(gpa: std.mem.Allocator, a: std.mem.Allocator, pr: *const Prepared, colors: ?protocol.RunColors, opts: Opts, settings: ?attach_client.Settings, many: bool) !Opened {
    return tryOpen(gpa, a, pr, colors, opts, settings, many) catch |err| switch (err) {
        error.Refused => runtimeFail("{s}", .{refusal}),
        else => return err,
    };
}

/// The daemon's message when it refused to open a session.
var refusal: []const u8 = "";

fn tryOpen(gpa: std.mem.Allocator, a: std.mem.Allocator, pr: *const Prepared, colors: ?protocol.RunColors, opts: Opts, settings: ?attach_client.Settings, many: bool) !Opened {
    var name: []const u8 = pr.id;
    var n: u32 = 1;
    var replace = false;
    while (true) {
        const reply = try client.request(gpa, protocol.RunReq{
            .name = name,
            .cols = pr.size[0],
            .rows = pr.size[1],
            .cwd = pr.cwd,
            .env = pr.env,
            .argv = pr.argv,
            .colors = colors,
            .if_exists = if (replace) .replace else .fail,
        }, protocol.StatusResp);
        defer reply.deinit();
        if (reply.parsed.value.ok) {
            const st = client.replyStatus(reply.parsed.value.status);
            return .{ .session = try std.fmt.allocPrint(a, "{d}", .{st.id}), .name = name, .start_seq = st.start_seq };
        }
        const failure = std.json.parseFromSliceLeaky(protocol.ErrorReply, a, reply.line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            runtimeFail("the daemon sent a malformed reply", .{});
        if (!std.mem.eql(u8, failure.code, @tagName(protocol.Code.exists))) {
            refusal = try std.fmt.allocPrint(a, "{f}", .{status.cleaned(failure.err)});
            return error.Refused;
        }
        if (n == 1 and !opts.new) {
            if (failure.status) |st| {
                if (!replace and untouchedFailure(gpa, st)) {
                    try errPrint("tuppet: {s}: replacing session {d}, whose start did not finish\n", .{ name, st.id });
                    replace = true;
                    continue;
                }
                if (many) {
                    try errPrint("tuppet: {s}: runs already (session {d})\n", .{ name, st.id });
                    return .{ .session = try std.fmt.allocPrint(a, "{d}", .{st.id}), .name = name, .existing = true };
                }
            }
            if (settings) |s| {
                const running = if (failure.status) |st| st.id else null;
                var question: std.ArrayList(u8) = .empty;
                try question.print(a, "tuppet: {s} is running", .{name});
                if (running) |rid| try question.print(a, " (session {d})", .{rid});
                try question.appendSlice(a, ": [a]ttach to it, start a [n]ew one, or [q]uit? ");
                const answer = try askLine(a, question.items, true) orelse std.process.exit(exit_code.failed);
                const word = std.mem.trim(u8, answer, " ");
                if (word.len > 0 and (word[0] == 'a' or word[0] == 'A')) {
                    attachTo(gpa, if (running) |rid| try std.fmt.allocPrint(a, "{d}", .{rid}) else name, s);
                } else if (word.len == 0 or (word[0] != 'n' and word[0] != 'N')) std.process.exit(exit_code.ok);
            }
        }
        n += 1;
        replace = false;
        name = try std.fmt.allocPrint(a, "{s}-{d}", .{ pr.id, n });
        if (names.nameError(name)) |why| runtimeFail("cannot name the next session '{s}': {s}", .{ name, why });
    }
}

/// Whether `st` is a session whose start did not finish, nothing was
/// typed into it since, and nobody is attached to it.
fn untouchedFailure(gpa: std.mem.Allocator, st: status.Status) bool {
    if (st.writer != null or st.viewers > 0 or st.previews > 0) return false;
    const mark = store.startFailed(gpa, st.id) orelse return false;
    if (mark.input_seq) |m| return st.input_seq != null and st.input_seq.? == m;
    return st.input_seq == null;
}

/// Note that the start of `session` did not finish, so that starting it
/// again replaces it.
fn markFailed(gpa: std.mem.Allocator, a: std.mem.Allocator, session: []const u8) void {
    const viewed = client.request(a, protocol.ViewReq{ .session = session }, protocol.ViewResp) catch return;
    if (!viewed.parsed.value.ok) return;
    const st = viewed.parsed.value.status orelse return;
    if (st.state != .running) return;
    store.markStartFailed(gpa, st.id, st.input_seq);
}

fn stopSessions(gpa: std.mem.Allocator, sessions: []const []const u8) !void {
    if (sessions.len == 0) return;
    const stopped = client.request(gpa, protocol.StopReq{ .sessions = sessions }, protocol.ResultsResp) catch |err| {
        try errPrint("tuppet: stopping session {s} failed ({s}); 'tuppet stop {s}' retries\n", .{ sessions[0], @errorName(err), sessions[0] });
        return;
    };
    stopped.deinit();
}

/// `tuppet do SESSION --use NAME [ARG...]`: the steps of a block in a
/// session that runs already. Exits as `tuppet start -d` does, without
/// stopping the session.
pub fn doUse(gpa: std.mem.Allocator, ref: []const u8, name: []const u8, args: []const []const u8, timeout_ms: ?u64, unless_attached: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const file = try load(a, true);
    const viewed = try client.request(a, protocol.ViewReq{ .session = ref }, protocol.ViewResp);
    if (!viewed.parsed.value.ok) {
        const failure = std.json.parseFromSliceLeaky(protocol.ErrorReply, a, viewed.line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
            runtimeFail("the daemon sent a malformed reply", .{});
        runtimeFail("{f}", .{status.cleaned(failure.err)});
    }
    const st = viewed.parsed.value.status orelse runtimeFail("the daemon sent no status for session {s}", .{ref});
    const session = try std.fmt.allocPrint(a, "{d}", .{st.id});
    const id = st.name orelse session;
    const p = start.planUse(a, &file, name, args, id, timeout_ms) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Bad => runtimeFail("{s}", .{start.badText()}),
    };
    const terminal = builtin.os.tag != .windows and std.c.isatty(0) == 1 and std.c.isatty(1) == 1;
    if (!terminal) for (p.secrets) |v| if (envValue(v) == null)
        runtimeFail("${s} is not set: set it, or run this in a terminal, where tuppet asks for it", .{v});
    if (!terminal) if (asksYou(&p)) |line|
        runtimeFail("{s}:{d}: this asks you, which needs a terminal", .{ file.path, line });
    try checkDaemon(gpa, &file, &p);

    var runner: Runner = .{ .gpa = gpa, .plan = &p, .file = &file, .session = session, .name = id, .terminal = terminal, .gate = true, .unattended = unless_attached };
    const outcome = runner.go();
    clearProgress(terminal);
    switch (outcome) {
        .done => {},
        .cancelled => {
            try errPrint("tuppet: {s}: stopped at step {d} of {d}\n", .{ id, runner.reachedNow() + 1, p.steps.len });
            std.process.exit(130);
        },
        .failed => |f| {
            try runner.report(a, f);
            std.process.exit(f.code());
        },
    }
}

pub fn attachTo(gpa: std.mem.Allocator, ref: []const u8, settings: attach_client.Settings) noreturn {
    attach_client.warnNested(settings.detach_key);
    attach_client.attachSession(gpa, ref, settings, false, null) catch |err|
        runtimeFail("attaching to session {s} failed ({s}); 'tuppet attach {s}' retries", .{ ref, @errorName(err), ref });
}

fn envSize() ?[2]u16 {
    const env = std.c.getenv("TUPPET_SIZE") orelse return null;
    return client.sizeValue(std.mem.span(env));
}

/// `~` and `~/...` in `path` from HOME.
pub fn homePath(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!(std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/"))) return path;
    const home = std.mem.span(std.c.getenv("HOME") orelse return path);
    return std.mem.concat(a, u8, &.{ home, path[1..] });
}

fn envValue(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const v = std.mem.span(std.c.getenv(@ptrCast(&buf)) orelse return null);
    return if (v.len > 0) v else null;
}

const Why = enum {
    /// A failure text appeared.
    failure_text,
    /// No output during the whole wait.
    quiet,
    /// Output came, but not what the check waits for.
    timeout,
    ended,
    /// The daemon refused to type the password.
    guard,
    /// The prompt changed while the person typed the answer.
    moved,
    /// The password prompt is not on the cursor's line.
    not_prompt,
    /// The cursor's line does not end with the prompt `do --use` starts at.
    not_ready,
    /// The program ended with another exit status.
    status,
    /// A request failed.
    failed,
};

const Failure = struct {
    /// The check (or the input) that failed.
    step: usize,
    why: Why,
    /// The failure text that appeared, or the daemon's message.
    detail: []const u8 = "",

    fn code(f: Failure) u8 {
        return switch (f.why) {
            .failure_text, .failed, .status => exit_code.failed,
            .quiet, .timeout => exit_code.timeout,
            .ended => exit_code.ended,
            .guard, .moved, .not_prompt, .not_ready => exit_code.guard,
        };
    }
};

/// An input with no check after it waits until the screen changed past
/// the input's line and then stayed still this long, at most
/// `pause_max_ms`, and goes on either way.
const pause_ms = 300;
const pause_max_ms = 2000;

/// How long the output of a program that reads whole lines stays still
/// before a block's first input takes it as ready, and how long that
/// input waits at most.
const line_quiet_ms = 1000;
const ready_max_ms = 5000;

/// Whether the daemon leaves out an input's echo; set once per run.
var daemon_echo = false;

/// Fail unless the daemon can run `p`, and learn whether it leaves out
/// echoes. An older daemon would match the echo of a check's text, or
/// not know a regex.
fn checkDaemon(gpa: std.mem.Allocator, file: *const start.File, p: *const start.Plan) !void {
    daemon_echo = try client.daemonSupports(gpa, "echo");
    const hint = "restart it when your sessions may stop ('tuppet shutdown'), and run this again";
    if (p.needs_regex and !try client.daemonSupports(gpa, "regex"))
        runtimeFail("{s}: '{s}' has a regex, which the running daemon, an older tuppet, cannot match; {s}", .{ file.path, p.id, hint });
    if (p.needs_echo and !daemon_echo)
        runtimeFail("{s}: '{s}' has an input without a check, or a check whose text is part of the input before it; the running daemon, an older tuppet, cannot leave out what an input echoes; {s}", .{ file.path, p.id, hint });
}

const Outcome = union(enum) {
    done,
    cancelled,
    failed: Failure,
};

const Ask = enum { none, secret, visible };

/// For what both threads hand each other; it lives until the process
/// ends.
const shared = std.heap.page_allocator;

/// The passwords of unset variables typed so far, by variable: asked once
/// in a run, however many sessions read them. Only the steps' threads use
/// it, one at a time.
var remembered: std.StringHashMapUnmanaged([]const u8) = .empty;

/// Runs the steps on a thread of its own, since requests block in reads
/// that a signal does not end, while this thread draws the progress line,
/// asks on the terminal, and watches for Ctrl-C.
const Runner = struct {
    gpa: std.mem.Allocator,
    plan: *const start.Plan,
    file: *const start.File,
    session: []const u8,
    name: []const u8,
    terminal: bool,
    /// For `do --use`: the first check must find its prompt ending the
    /// cursor's line, and each input requires that nothing else was typed
    /// since the one before.
    gate: bool = false,
    /// Every input requires that no writer is attached.
    unattended: bool = false,
    /// The seq the session started at, when this run started it: an input
    /// first in the block waits until the program takes input.
    start_seq: ?u64 = null,

    mutex: std.Io.Mutex = .init,
    /// Taken while input goes out, so none does after `cancel`.
    send_mutex: std.Io.Mutex = .init,
    // Set by the steps' thread.
    reached: usize = 0,
    step_ns: i64 = 0,
    asking: Ask = .none,
    /// The session's line where the answer goes.
    ask_line: []const u8 = "",
    outcome: Outcome = .done,
    // Set by this thread.
    answer: ?[]const u8 = null,
    cancel: bool = false,
    /// Secret values typed so far, kept out of what is printed.
    secrets: std.ArrayList([]const u8) = .empty,
    changes: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    /// The steps' thread: the `when` lines met since the latest input.
    asked: std.ArrayList(Asked) = .empty,
    /// What the latest input typed that its echo shows.
    typed: []const u8 = "",
    /// Passwords typed by the person for variables since the latest
    /// input step, and kept ones it reused.
    learned: std.ArrayList([2][]const u8) = .empty,
    reused: std.ArrayList([]const u8) = .empty,

    fn go(r: *Runner) Outcome {
        client.installInterruptHandlers();
        r.step_ns = io_mod.nowNanos();
        const thread = std.Thread.spawn(.{}, steps, .{r}) catch |err| runtimeFail("cannot start a thread: {s}", .{@errorName(err)});
        var screen: []const u8 = "";
        var arena = std.heap.ArenaAllocator.init(r.gpa);
        defer arena.deinit();
        var last_view: i64 = 0;
        while (true) {
            if (client.interrupt_signal.load(.acquire) != 0) {
                r.stop();
                thread.detach();
                return .cancelled;
            }
            if (r.finished.load(.acquire) != 0) break;
            const io = io_mod.io();
            r.mutex.lockUncancelable(io);
            const asking = r.asking;
            const line = r.ask_line;
            r.mutex.unlock(io);
            if (asking != .none) {
                clearProgress(r.terminal);
                const question = if (asking == .secret) "password (not shown)" else "answer";
                const text = std.fmt.allocPrint(arena.allocator(), "tuppet: {s} asks: {s}\n  {s}: ", .{ r.name, r.mask(arena.allocator(), line), question }) catch "tuppet: ";
                const got = askLine(shared, text, asking == .visible) catch null;
                r.mutex.lockUncancelable(io);
                if (got) |g| r.answer = g else r.cancel = true;
                r.asking = .none;
                r.mutex.unlock(io);
                _ = r.changes.fetchAdd(1, .release);
                io.futexWake(u32, &r.changes.raw, 1);
                if (got == null) {
                    thread.detach();
                    return .cancelled;
                }
                continue;
            }
            if (r.terminal and io_mod.nowNanos() - last_view > 300 * std.time.ns_per_ms) {
                last_view = io_mod.nowNanos();
                _ = arena.reset(.retain_capacity);
                screen = cursorLine(arena.allocator(), r.session, false) catch "";
                r.drawProgress(arena.allocator(), screen);
            }
            io.futexWaitTimeout(u32, &r.finished.raw, 0, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .boot } }) catch {};
        }
        thread.join();
        return r.outcome;
    }

    fn stop(r: *Runner) void {
        const io = io_mod.io();
        r.send_mutex.lockUncancelable(io);
        r.mutex.lockUncancelable(io);
        r.cancel = true;
        r.mutex.unlock(io);
        r.send_mutex.unlock(io);
        _ = r.changes.fetchAdd(1, .release);
        io.futexWake(u32, &r.changes.raw, 1);
    }

    /// The step the steps' thread reached; it may still run after Ctrl-C.
    fn reachedNow(r: *Runner) usize {
        const io = io_mod.io();
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        return r.reached;
    }

    fn cancelled(r: *Runner) bool {
        const io = io_mod.io();
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        return r.cancel;
    }

    fn drawProgress(r: *Runner, a: std.mem.Allocator, screen: []const u8) void {
        const io = io_mod.io();
        r.mutex.lockUncancelable(io);
        const reached = r.reached;
        const since = r.step_ns;
        r.mutex.unlock(io);
        // A block of only settings has no step to show.
        if (reached >= r.plan.steps.len) return;
        const s = r.plan.steps[reached];
        const width: usize = if (attach_client.terminalSize()) |sz| sz[0] else 80;
        var buf: [32]u8 = undefined;
        var tbuf: [32]u8 = undefined;
        const elapsed: u64 = @intCast(@divTrunc(@max(0, io_mod.nowNanos() - since), std.time.ns_per_ms));
        const label = stepText(a, s) catch "";
        const line = std.fmt.allocPrint(a, "{s} {d}/{d} {s} {s} {s}/{s} | {s}", .{
            r.name,
            reached + 1,
            r.plan.steps.len,
            @tagName(s.kind),
            label,
            units.durationText(&buf, elapsed / 1000 * 1000),
            units.durationText(&tbuf, s.timeout_ms),
            r.mask(a, screen),
        }) catch return;
        var shown: []const u8 = line;
        if (displayWidth(shown) > width -| 1) shown = truncate(shown, width -| 1);
        errPrint("\r\x1b[K{s}", .{shown}) catch {};
    }

    /// `text` with every secret typed so far put as ***.
    fn mask(r: *Runner, a: std.mem.Allocator, text: []const u8) []const u8 {
        const io = io_mod.io();
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        var out = text;
        for (r.secrets.items) |v| {
            if (v.len == 0) continue;
            out = std.mem.replaceOwned(u8, a, out, v, "***") catch out;
        }
        return out;
    }

    // -- the steps' thread --

    fn steps(r: *Runner) void {
        var arena = std.heap.ArenaAllocator.init(r.gpa);
        defer arena.deinit();
        var outcome = r.all(arena.allocator()) catch |err| Outcome{ .failed = .{ .step = r.reached, .why = .failed, .detail = @errorName(err) } };
        // The arena goes with this thread; the message must not.
        if (outcome == .failed) outcome.failed.detail = shared.dupe(u8, outcome.failed.detail) catch "";
        const io = io_mod.io();
        r.mutex.lockUncancelable(io);
        r.outcome = outcome;
        r.mutex.unlock(io);
        r.finished.store(1, .release);
        io.futexWake(u32, &r.finished.raw, 1);
    }

    fn reach(r: *Runner, i: usize) void {
        const io = io_mod.io();
        r.mutex.lockUncancelable(io);
        r.reached = i;
        r.step_ns = io_mod.nowNanos();
        r.mutex.unlock(io);
    }

    fn all(r: *Runner, a: std.mem.Allocator) !Outcome {
        const steps_ = r.plan.steps;
        var i: usize = 0;
        // The input_seq of the latest input: an input goes only where
        // nothing else was typed since, when it requires that.
        var input_seq: ?u64 = null;
        while (i < steps_.len) {
            if (r.cancelled()) return .cancelled;
            const s = steps_[i];
            if (!s.kind.input()) {
                r.reach(i);
                const conds = try conditions(a, s, r.asked.items, r.mode(s));
                const reply = try waitFor(a, r.session, conds.list, s.timeout_ms);
                switch (try r.checked(a, i, s, conds, reply, &input_seq) orelse return .cancelled) {
                    .met => try r.keepLearned(),
                    .failed => |f| {
                        r.dropReused();
                        return .{ .failed = f };
                    },
                    .when => unreachable,
                }
                if (r.gate and i == 0) {
                    // Nothing typed this check's prompt: it must be where
                    // the cursor waits, with nothing typed after it.
                    const at = try r.rest(a);
                    if (at.ended) return .{ .failed = .{ .step = i, .why = .ended } };
                    if (!endsLine(a, at.line, s.alts)) return .{ .failed = .{ .step = i, .why = .not_ready, .detail = at.line } };
                    // Before any input there is no input_seq: 0 stands for
                    // that, so keys typed from now on stop the run.
                    input_seq = at.input_seq orelse 0;
                }
                i += 1;
                continue;
            }
            r.asked.clearRetainingCapacity();
            r.learned.clearRetainingCapacity();
            r.reused.clearRetainingCapacity();
            if (i == 0) if (r.start_seq) |seq| {
                r.reach(i);
                if (!try r.awaitReady(a, seq)) {
                    const o = r.plan.origins[s.origin];
                    try errPrint("{s}tuppet: {s}: no sign within {d}s that the program takes input; typing line {d} anyway\n", .{
                        if (r.terminal) "\r\x1b[K" else "",
                        r.name,
                        ready_max_ms / 1000,
                        o.line,
                    });
                }
            };
            // Without a check, the input pauses until its output does.
            const has_check = i + 1 < steps_.len and steps_[i + 1].check();
            const chk: start.Step = if (has_check) steps_[i + 1] else .{
                .kind = .settle,
                .settle_ms = pause_ms,
                .timeout_ms = pause_max_ms,
                .after_input = true,
                .whens = s.whens,
                .origin = s.origin,
                .pause = true,
            };
            const at_step = if (has_check) i + 1 else i;
            var batch: std.ArrayList(protocol.Step) = .empty;
            var require: protocol.Require = .{};
            switch (s.kind) {
                .send => {
                    try batch.append(a, .{ .text = s.text });
                    try batch.append(a, .{ .keys = &.{"<Enter>"} });
                    r.typed = s.text;
                },
                .type => {
                    try batch.append(a, .{ .text = s.text });
                    r.typed = s.text;
                },
                .keys => {
                    try batch.append(a, .{ .keys = s.keys });
                    r.typed = "";
                },
                .secret, .ask => {
                    var prompt_seq: u64 = 0;
                    if (s.kind == .secret) if (try r.atPrompt(a, i, steps_[i - 1].alts, &prompt_seq)) |f| return .{ .failed = f };
                    const value = switch (try r.valueFor(a, i, if (s.kind == .secret) s.text else "", if (s.kind == .secret) .secret else .visible)) {
                        .value => |v| v,
                        .cancelled => return .cancelled,
                        .failed => |f| return .{ .failed = f },
                    };
                    try appendAnswer(a, &batch, value, s.kind == .secret);
                    // A password must not go where something else was
                    // typed since its prompt came, or where a person types.
                    if (s.kind == .secret) require = .{ .input_seq = input_seq orelse prompt_seq, .unattended = true };
                    r.typed = if (s.kind == .ask) value else "";
                },
                else => unreachable,
            }
            if (r.gate) require.input_seq = input_seq;
            if (r.unattended) require.unattended = true;
            r.reach(at_step);
            const conds = try conditions(a, chk, r.asked.items, r.mode(chk));
            const sent = try r.input(a, .{
                .session = r.session,
                .steps = batch.items,
                .require = require,
                .until = conds.list,
                .timeout_ms = chk.timeout_ms,
            }, chk.timeout_ms) orelse return .cancelled;
            if (!sent.input.ok) return .{ .failed = refused(i, sent) };
            input_seq = sent.input_seq;
            const result = try r.checked(a, at_step, chk, conds, sent.wait, &input_seq) orelse return .cancelled;
            switch (result) {
                .met => try r.keepLearned(),
                .failed => |f| {
                    r.dropReused();
                    return .{ .failed = f };
                },
                .when => unreachable,
            }
            i += if (has_check) 2 else 1;
        }
        return .done;
    }

    /// Wait until the program in the session this run started, at seq
    /// `start_seq`, takes input: a line editor or a full-screen program
    /// once it reads keys one by one and its output pauses; a program
    /// that reads whole lines once its output, after some came, stayed
    /// still for `line_quiet_ms`. A program that prints nothing waits the
    /// whole `ready_max_ms`. Typed earlier, a line editor draws its prompt
    /// again after what was typed, where checks would see it. False when
    /// `ready_max_ms` ran out first and the run was not cancelled.
    fn awaitReady(r: *Runner, a: std.mem.Allocator, start_seq: u64) !bool {
        const deadline = io_mod.nowNanos() +| ready_max_ms * std.time.ns_per_ms;
        var from = start_seq;
        while (!r.cancelled()) {
            const left = deadline - io_mod.nowNanos();
            if (left <= 0) return r.cancelled();
            const until: []const protocol.Condition = &.{
                .{ .settled_ms = pause_ms, .since = from },
                .{ .idle_ms = line_quiet_ms },
            };
            // Before any output, a shell may still be reading its startup
            // files: quiet does not count yet.
            const reply = try waitFor(a, r.session, if (from == start_seq) until[0..1] else until, @intCast(@divTrunc(left, std.time.ns_per_ms) + 1));
            // An end or a failed wait shows at the input.
            if (reply != .resp) return true;
            const got = reply.resp;
            if (got.outcome == .timeout) return r.cancelled();
            if (got.outcome != .met) return true;
            const st = got.status orelse return true;
            const tty = st.tty orelse return true;
            if (!tty.canonical or got.met == 1) return true;
            from = st.seq orelse return true;
        }
        return true;
    }

    /// How check `s` counts what is new: after the input before it,
    /// without its echo.
    fn mode(r: *const Runner, s: start.Step) Mode {
        if (!s.after_input) return .{};
        return .{ .after = .latest, .typed = r.typed };
    }

    /// A typed password is kept for the next session only once the check
    /// after it is met; a kept one that fails is dropped.
    fn keepLearned(r: *Runner) !void {
        for (r.learned.items) |l| try remembered.put(shared, l[0], l[1]);
        r.learned.clearRetainingCapacity();
    }

    fn dropReused(r: *Runner) void {
        for (r.reused.items) |v| _ = remembered.remove(v);
        r.reused.clearRetainingCapacity();
    }

    /// What check `s`, step `i`, came to from `first`, the wait for
    /// `first_conds`. A question of its `when` lines that came is
    /// answered once output pauses, and the check waits on; null when
    /// stopped.
    fn checked(r: *Runner, a: std.mem.Allocator, i: usize, s: start.Step, first_conds: Conditions, first: WaitReply, input_seq: *?u64) !?Judged {
        var conds = first_conds;
        var reply = first;
        while (true) {
            const wi = switch (judge(i, s, conds, reply)) {
                .when => |wi| wi,
                .met => return .met,
                .failed => |f| return .{ .failed = f },
            };
            const w = s.whens[wi];
            (try r.askedFor(a, w.origin)).answered = true;
            var batch: std.ArrayList(protocol.Step) = .empty;
            var require: protocol.Require = .{ .input_seq = input_seq.*, .unattended = r.unattended };
            switch (w.answer) {
                .send, .type, .keys => {
                    const at = try r.rest(a);
                    if (at.ended) return r.failedAt(a, i, s, .{ .step = i, .why = .ended });
                    switch (w.answer) {
                        .send => {
                            try batch.append(a, .{ .text = w.answer_text });
                            try batch.append(a, .{ .keys = &.{"<Enter>"} });
                        },
                        .type => try batch.append(a, .{ .text = w.answer_text }),
                        else => try batch.append(a, .{ .keys = w.answer_keys }),
                    }
                    r.typed = if (w.answer == .keys) "" else w.answer_text;
                },
                .secret => {
                    var prompt_seq: u64 = 0;
                    if (try r.atPrompt(a, i, &.{w.pattern}, &prompt_seq)) |f| return r.failedAt(a, i, s, f);
                    const value = switch (try r.valueFor(a, i, w.answer_text, .secret)) {
                        .value => |v| v,
                        .cancelled => return null,
                        .failed => |f| return .{ .failed = f },
                    };
                    try appendAnswer(a, &batch, value, true);
                    require.input_seq = input_seq.* orelse prompt_seq;
                    require.unattended = true;
                    r.typed = "";
                },
                else => unreachable,
            }
            // The answer is an input too: only what comes after it counts.
            conds = try conditions(a, s, r.asked.items, .{ .after = .latest, .typed = r.typed });
            const sent = try r.input(a, .{
                .session = r.session,
                .steps = batch.items,
                .require = require,
                .until = conds.list,
                .timeout_ms = s.timeout_ms,
            }, s.timeout_ms) orelse return null;
            if (!sent.input.ok) return r.failedAt(a, i, s, refused(i, sent));
            r.told(a, w);
            input_seq.* = sent.input_seq;
            reply = sent.wait;
        }
    }

    fn askedFor(r: *Runner, a: std.mem.Allocator, origin: u32) !*Asked {
        for (r.asked.items) |*q| if (q.origin == origin) return q;
        try r.asked.append(a, .{ .origin = origin });
        return &r.asked.items[r.asked.items.len - 1];
    }

    fn isAnswered(r: *Runner, origin: u32) bool {
        for (r.asked.items) |q| if (q.origin == origin) return q.answered;
        return false;
    }

    /// Say that a `when` line's question came and is answered.
    fn told(r: *Runner, a: std.mem.Allocator, w: start.When) void {
        const o = r.plan.origins[w.origin];
        const ao = r.plan.origins[w.answer_origin];
        errPrint("{s}tuppet: {s}: '{s}' came (line {d}); answered: {s} {s}\n", .{
            if (r.terminal) "\r\x1b[K" else "",
            r.name,
            r.mask(a, w.pattern.text),
            o.line,
            @tagName(ao.keyword),
            r.mask(a, ao.value),
        }) catch {};
    }

    /// Ask the person on the terminal for step `i`'s answer, with the
    /// session's prompt line; null when stopped.
    fn askFor(r: *Runner, a: std.mem.Allocator, i: usize, kind: Ask) !?[]const u8 {
        const line = cursorLine(a, r.session, true) catch "";
        const io = io_mod.io();
        r.mutex.lockUncancelable(io);
        r.reached = i;
        r.ask_line = line;
        r.answer = null;
        r.asking = kind;
        r.mutex.unlock(io);
        while (true) {
            const seen = r.changes.load(.acquire);
            r.mutex.lockUncancelable(io);
            const done = r.asking == .none;
            const answer = r.answer;
            const stopped = r.cancel;
            r.mutex.unlock(io);
            if (stopped) return null;
            if (done) return answer;
            io.futexWaitTimeout(u32, &r.changes.raw, seen, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .boot } }) catch {};
        }
    }

    /// The session once no output came for a moment: the cursor's line
    /// left of the cursor.
    const Rest = struct {
        line: []const u8 = "",
        ended: bool = false,
        input_seq: ?u64 = null,
    };

    fn rest(r: *Runner, a: std.mem.Allocator) !Rest {
        var out: Rest = .{};
        const reply = try waitFor(a, r.session, &.{.{ .idle_ms = 300 }}, 2000);
        if (reply == .ended or (reply == .resp and (reply.resp.outcome == .ended or reply.resp.outcome == .removed)))
            return .{ .ended = true };
        if (reply == .resp) if (reply.resp.status) |st| {
            out.input_seq = st.input_seq;
        };
        out.line = cursorLine(a, r.session, true) catch "";
        return out;
    }

    /// Why a password for step `i` must not be typed now: it goes only to
    /// a program whose prompt is on the cursor's line once output pauses.
    /// Else `input_seq` is the session's then, 0 before any input.
    fn atPrompt(r: *Runner, a: std.mem.Allocator, i: usize, prompt: []const start.Pattern, input_seq: *u64) !?Failure {
        const at = try r.rest(a);
        if (at.ended) return .{ .step = i, .why = .ended };
        if (!onLine(a, at.line, prompt)) return .{ .step = i, .why = .not_prompt, .detail = at.line };
        input_seq.* = at.input_seq orelse 0;
        return null;
    }

    const Got = union(enum) {
        value: []const u8,
        failed: Failure,
        cancelled,
    };

    /// The value to type at step `i`: the variable `name`, a password
    /// typed earlier in this run, or what the person answers.
    fn valueFor(r: *Runner, a: std.mem.Allocator, i: usize, name: []const u8, kind: Ask) !Got {
        const kept = if (name.len > 0 and envValue(name) == null) remembered.get(name) else null;
        if (kept != null) try r.reused.append(a, name);
        const from_env = if (name.len > 0) envValue(name) orelse kept else null;
        const value = from_env orelse (try r.askFor(a, i, kind)) orelse return .cancelled;
        if (from_env == null) {
            // The prompt may have timed out while the person typed: then
            // the answer would go to whatever came.
            const io = io_mod.io();
            r.mutex.lockUncancelable(io);
            const asked = r.ask_line;
            r.mutex.unlock(io);
            const now = cursorLine(a, r.session, true) catch "";
            if (!std.mem.eql(u8, asked, now))
                return .{ .failed = .{ .step = i, .why = .moved, .detail = shared.dupe(u8, now) catch "" } };
            if (name.len > 0) try r.learned.append(a, .{ name, try shared.dupe(u8, value) });
        }
        if (kind == .secret) {
            const io = io_mod.io();
            r.mutex.lockUncancelable(io);
            defer r.mutex.unlock(io);
            try r.secrets.append(shared, try shared.dupe(u8, value));
        }
        return .{ .value = value };
    }

    const Sent = struct {
        input: struct { ok: bool, code: []const u8 = "", err: []const u8 = "", guard: []const u8 = "" },
        input_seq: ?u64 = null,
        wait: WaitReply = .{ .failed = "" },
    };

    /// Send an input batch with its check; null when stopped first.
    fn input(r: *Runner, a: std.mem.Allocator, req: protocol.InputReq, timeout_ms: u64) !?Sent {
        const io = io_mod.io();
        var conn = try client.connect(a);
        defer conn.deinit();
        {
            r.send_mutex.lockUncancelable(io);
            defer r.send_mutex.unlock(io);
            if (r.cancelled()) return null;
            try client.sendRequest(a, &conn, req);
        }
        const first = try conn.recvLineAfter(a, client.max_reply, "", ipc.request_timeout_ns);
        const typed = try client.parseReply(a, protocol.InputResp, first.line);
        if (!typed.parsed.value.ok) {
            const failure = std.json.parseFromSliceLeaky(protocol.ErrorReply, a, first.line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
                return .{ .input = .{ .ok = false, .code = "internal", .err = "the daemon sent a malformed reply" } };
            return .{ .input = .{ .ok = false, .code = failure.code, .err = failure.err, .guard = failure.guard orelse "" } };
        }
        const st = typed.parsed.value.status;
        const second = try conn.recvLineAfter(a, client.max_reply, first.rest, client.waitReplyNs(timeout_ms));
        return .{
            .input = .{ .ok = true },
            .input_seq = if (st) |x| x.input_seq else null,
            .wait = waitReplyOf(a, second.line),
        };
    }

    const Judged = union(enum) {
        met,
        failed: Failure,
        /// The question of `when` line `s.whens[n]` came.
        when: usize,
    };

    /// Why the daemon typed nothing of input step `i`.
    fn refused(i: usize, sent: Sent) Failure {
        const code = sent.input.code;
        const why: Why = if (std.mem.eql(u8, code, "guard"))
            .guard
        else if (std.mem.eql(u8, code, "ended") or std.mem.eql(u8, code, "no_session"))
            .ended
        else
            .failed;
        return .{ .step = i, .why = why, .detail = sent.input.err };
    }

    /// What a check's wait came to.
    fn judge(i: usize, s: start.Step, conds: Conditions, reply: WaitReply) Judged {
        const resp = switch (reply) {
            .failed => |text| return .{ .failed = .{ .step = i, .why = .failed, .detail = text } },
            .ended => |exit| return if (s.kind == .ended) endedWith(i, s, exit) else .{ .failed = .{ .step = i, .why = .ended } },
            .resp => |x| x,
        };
        const exit = if (resp.status) |st| st.exit else null;
        switch (resp.outcome) {
            .ended, .removed => return if (s.kind == .ended) endedWith(i, s, exit) else .{ .failed = .{ .step = i, .why = .ended } },
            .timeout => {
                if (s.pause) return .met;
                const idle = if (resp.status) |st| st.output_idle_ms else 0;
                var buf: [32]u8 = undefined;
                // The echo of the input comes just after the wait starts.
                const quiet = idle + @min(1000, s.timeout_ms / 4) >= s.timeout_ms;
                return .{ .failed = .{ .step = i, .why = if (quiet) .quiet else .timeout, .detail = shared.dupe(u8, units.durationText(&buf, idle / 100 * 100)) catch "" } };
            },
            .met => {},
        }
        const met = resp.met orelse return .met;
        if (met < conds.fails) return .{ .failed = .{ .step = i, .why = .failure_text, .detail = s.fails[met].text } };
        if (met < conds.questions) return .{ .when = conds.whens[met - conds.fails] };
        return if (s.kind == .ended) endedWith(i, s, exit) else .met;
    }

    /// `f`, unless check `s`, step `i`, is an `ended` and the session
    /// ended while a `when` question was answered: then whether it ended
    /// with the status it should.
    fn failedAt(r: *Runner, a: std.mem.Allocator, i: usize, s: start.Step, f: Failure) Judged {
        if (f.why != .ended or s.kind != .ended) return .{ .failed = f };
        const viewed = client.request(a, protocol.ViewReq{ .session = r.session }, protocol.ViewResp) catch return endedWith(i, s, null);
        const st = if (viewed.parsed.value.ok) viewed.parsed.value.status else null;
        return endedWith(i, s, if (st) |x| x.exit else null);
    }

    /// Check `i`, an `ended`, saw the program end with `exit`.
    fn endedWith(i: usize, s: start.Step, exit: ?status.Exit) Judged {
        const want = s.status orelse return .met;
        const e = exit orelse return .{ .failed = .{ .step = i, .why = .status, .detail = "an unknown status" } };
        if (e.code) |code| if (code == want) return .met;
        const detail = if (e.signal) |sig|
            std.fmt.allocPrint(shared, "signal {s}", .{sig}) catch ""
        else
            std.fmt.allocPrint(shared, "exit status {d}", .{e.code orelse -1}) catch "";
        return .{ .failed = .{ .step = i, .why = .status, .detail = detail } };
    }

    /// Print what went wrong, where, and the session's last lines.
    fn report(r: *Runner, a: std.mem.Allocator, f: Failure) !void {
        const p = r.plan;
        const s = p.steps[f.step];
        var out: std.ArrayList(u8) = .empty;
        var buf: [32]u8 = undefined;
        const what: []const u8 = switch (f.why) {
            .failure_text => try std.fmt.allocPrint(a, "'{s}' appeared", .{f.detail}),
            .quiet => try std.fmt.allocPrint(a, "the session went quiet: no output for {s} of the {s} it waited", .{ f.detail, units.durationText(&buf, s.timeout_ms) }),
            .timeout => try std.fmt.allocPrint(a, "what it waited for did not come within {s} (the last output was {s} ago); a time on the check, as in expect(1m), waits longer", .{ units.durationText(&buf, s.timeout_ms), f.detail }),
            .ended => "the session ended",
            .guard => "nothing was typed, because something else was typed into the session, or a writer attached, since its prompt came",
            .not_prompt => try std.fmt.allocPrint(a, "the password was not typed: its prompt is not on the cursor's line, which shows '{s}'", .{r.mask(a, f.detail)}),
            .status => try std.fmt.allocPrint(a, "the program ended with {s}, not exit status {d}", .{ f.detail, s.status orelse 0 }),
            .not_ready => try std.fmt.allocPrint(a, "nothing was typed: the cursor's line does not end with the prompt the steps start at, but shows '{s}'", .{r.mask(a, f.detail)}),
            .moved => try std.fmt.allocPrint(a, "nothing was typed: the session's line changed while you answered, to '{s}'", .{r.mask(a, f.detail)}),
            .failed => try std.fmt.allocPrint(a, "{f}", .{status.cleaned(f.detail)}),
        };
        try out.print(a, "tuppet: {s}: step {d} of {d} failed: {s}\n", .{ r.name, f.step + 1, p.steps.len, what });
        // The input before a check, then the check.
        const first = if (s.check() and f.step > 0 and p.steps[f.step - 1].kind.input()) f.step - 1 else f.step;
        for (p.steps[first .. f.step + 1]) |st| {
            const o = p.origins[st.origin];
            try out.print(a, "  {s}:{d}  {s} {s}\n", .{ r.file.path, o.line, @tagName(o.keyword), o.value });
            const expanded = try stepText(a, st);
            if (!std.mem.eql(u8, expanded, o.value) and st.kind != .secret) try out.print(a, "      = {s}\n", .{expanded});
            if (o.block) |b| {
                try out.print(a, "      in {s}", .{b});
                var at_ = o.parent;
                var first_ = true;
                while (at_) |pi| : (first_ = false) {
                    try out.print(a, "{s} line {d}", .{ if (first_) ", used at" else ",", p.origins[pi].line });
                    at_ = p.origins[pi].parent;
                }
                try out.appendSlice(a, "\n");
            }
        }
        var lines: []const []const u8 = &.{};
        if (f.why != .ended) {
            lines = lastLines(a, r.session, 6) catch &.{};
            if (lines.len > 0) {
                try out.appendSlice(a, "  the session's last lines:\n");
                for (lines) |l| try out.print(a, "  | {s}\n", .{r.mask(a, l)});
            }
        }
        // A question on the screen that came before the input is not new.
        if (f.why == .timeout or f.why == .quiet) for (s.whens) |w| {
            if (r.isAnswered(w.origin)) continue;
            for (lines) |l| if (onLine(a, l, &.{w.pattern})) {
                try out.print(a, "  note: '{s}' (line {d}) is on the screen, but its 'when' did not answer it: it answers only what comes after the input\n", .{ r.mask(a, w.pattern.text), p.origins[w.origin].line });
                break;
            };
        };
        var unchecked: usize = 0;
        for (p.steps[0..f.step], 0..) |st, n| {
            if (st.kind.input() and (n + 1 == p.steps.len or !p.steps[n + 1].check())) unchecked += 1;
        }
        if (unchecked > 0) try out.print(a, "  note: {d} input{s} before this step had no check after {s}, so where {s} went is not known; an expect after each hop tells\n", .{
            unchecked,
            if (unchecked == 1) "" else "s",
            if (unchecked == 1) "it" else "them",
            if (unchecked == 1) "it" else "they",
        });
        try errPrint("{s}", .{out.items});
    }
};

const Conditions = struct {
    list: []const protocol.Condition,
    /// Where each part of `list` ends: failure texts, then the questions
    /// of `when` lines, then the check itself. The daemon reports the
    /// first that holds, so a failure wins over the rest, and a question
    /// is answered before the check counts as met.
    fails: usize,
    questions: usize,
    /// The `when` line, in the check's `whens`, of each question.
    whens: []const usize,
};

/// What became of a `when` line since the latest input.
const Asked = struct {
    origin: u32,
    answered: bool = false,
};

/// What counts as new for a check: after an input, without the echo of
/// `typed`.
const Mode = struct {
    after: ?AfterInput = null,
    typed: []const u8 = "",
};

/// Type what the person or a variable answered, then Enter; an empty
/// answer is Enter alone, as on the program's own prompt.
fn appendAnswer(a: std.mem.Allocator, batch: *std.ArrayList(protocol.Step), value: []const u8, secret: bool) !void {
    if (value.len > 0) try batch.append(a, .{ .text = value, .secret = secret });
    try batch.append(a, .{ .keys = &.{"<Enter>"} });
}

/// The conditions of check `s`, failures first, then questions.
fn conditions(a: std.mem.Allocator, s: start.Step, asked: []const Asked, m: Mode) !Conditions {
    var list: std.ArrayList(protocol.Condition) = .empty;
    const typed: ?[]const u8 = if (daemon_echo and m.after != null and m.typed.len > 0 and m.typed.len <= 4096 and std.mem.indexOfAny(u8, m.typed, "\r\n") == null) m.typed else null;
    const match = struct {
        fn f(p: start.Pattern, mode: Mode, t: ?[]const u8) protocol.Condition {
            return .{ .match = p.text, .regex = p.regex, .after_input = mode.after, .typed = t };
        }
    }.f;
    for (s.fails) |t| try list.append(a, match(t, m, typed));
    const fails = list.items.len;
    var whens: std.ArrayList(usize) = .empty;
    for (s.whens, 0..) |w, n| {
        for (asked) |q| {
            if (q.origin == w.origin and q.answered) break;
        } else {
            try list.append(a, match(w.pattern, m, typed));
            try whens.append(a, n);
        }
    }
    const questions = list.items.len;
    switch (s.kind) {
        .expect => for (s.alts) |t| try list.append(a, match(t, m, typed)),
        .gone => try list.append(a, .{ .match = s.alts[0].text, .regex = s.alts[0].regex, .absent = true }),
        .settle => try list.append(a, if (s.pause)
            .{ .settled_ms = s.settle_ms, .after_input = .latest, .past_input_line = true }
        else
            .{ .settled_ms = s.settle_ms, .after_input = m.after }),
        .ended => try list.append(a, .{ .ended = true }),
        else => unreachable,
    }
    return .{ .list = list.items, .fails = fails, .questions = questions, .whens = whens.items };
}

const WaitReply = union(enum) {
    resp: protocol.WaitResp,
    /// The session had ended; its exit, when the reply said.
    ended: ?status.Exit,
    failed: []const u8,
};

fn waitReplyOf(a: std.mem.Allocator, line: []u8) WaitReply {
    const reply = client.parseReply(a, protocol.WaitResp, line) catch return .{ .failed = "the daemon sent a malformed reply" };
    if (reply.parsed.value.ok) return .{ .resp = reply.parsed.value };
    const failure = std.json.parseFromSliceLeaky(protocol.ErrorReply, a, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return .{ .failed = "the daemon sent a malformed reply" };
    if (std.mem.eql(u8, failure.code, "ended") or std.mem.eql(u8, failure.code, "no_session"))
        return .{ .ended = if (failure.status) |st| st.exit else null };
    return .{ .failed = failure.err };
}

fn waitFor(a: std.mem.Allocator, session: []const u8, until: []const protocol.Condition, timeout_ms: u64) !WaitReply {
    var conn = try client.connect(a);
    defer conn.deinit();
    try client.sendRequest(a, &conn, protocol.WaitReq{ .session = session, .until = until, .timeout_ms = timeout_ms });
    const got = try conn.recvLineAfter(a, client.max_reply, "", client.waitReplyNs(timeout_ms));
    return waitReplyOf(a, got.line);
}

/// Whether `line` holds one of `patterns`, plain ones without their
/// trailing blanks.
fn onLine(a: std.mem.Allocator, line: []const u8, patterns: []const start.Pattern) bool {
    for (patterns) |p| {
        if (p.regex) {
            var re = regex.compile(a, p.text, .{}, null) catch continue;
            defer re.deinit(a);
            if (re.find(line, 0) != null) return true;
            continue;
        }
        const want = std.mem.trimEnd(u8, p.text, " ");
        if (want.len > 0 and std.mem.indexOf(u8, line, want) != null) return true;
    }
    return false;
}

/// Whether `line`, the cursor's line left of the cursor, ends with one of
/// `patterns`, but for blanks, plain ones without their trailing blanks.
fn endsLine(a: std.mem.Allocator, line: []const u8, patterns: []const start.Pattern) bool {
    const text = std.mem.trimEnd(u8, line, " ");
    for (patterns) |p| {
        if (p.regex) {
            var re = regex.compile(a, p.text, .{}, null) catch continue;
            defer re.deinit(a);
            var from: usize = 0;
            while (re.find(line, from)) |span| : (from = span.start + 1) {
                if (span.end >= text.len) return true;
            }
            continue;
        }
        const want = std.mem.trimEnd(u8, p.text, " ");
        if (want.len > 0 and std.mem.endsWith(u8, text, want)) return true;
    }
    return false;
}

/// The session's cursor line: all of it, or with `left` only what is left
/// of the cursor, with the rows above that it wraps from: a full row goes
/// on in the next.
fn cursorLine(a: std.mem.Allocator, session: []const u8, left: bool) ![]const u8 {
    const reply = try client.request(a, protocol.ViewReq{ .session = session }, protocol.ViewResp);
    if (!reply.parsed.value.ok) return "";
    const v = reply.parsed.value;
    var rows: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, v.text, '\n');
    while (it.next()) |line| try rows.append(a, line);
    if (v.cursor.row == 0 or v.cursor.row > rows.items.len) return "";
    const at = v.cursor.row - 1;
    const line = rows.items[at];
    if (!left) return std.mem.trimEnd(u8, line, " ");
    const cols: usize = if (v.status) |st| st.cols else 0;
    var first = at;
    while (cols > 0 and first > 0 and displayWidth(rows.items[first - 1]) >= cols) first -= 1;
    const joined = try std.mem.concat(a, u8, rows.items[first..at]);
    return std.mem.concat(a, u8, &.{ joined, try leftOf(a, line, v.cursor.col -| 1) });
}

/// The start of `line` left of a cursor `cells` cells in, with the blanks
/// up to the cursor that the view leaves out, as a prompt ends with.
fn leftOf(a: std.mem.Allocator, line: []const u8, cells: usize) ![]const u8 {
    const cut = cutCells(line, cells);
    const blanks = try a.alloc(u8, cells -| displayWidth(cut));
    @memset(blanks, ' ');
    return std.mem.concat(a, u8, &.{ cut, blanks });
}

/// The start of `line` that fills at most `cells` cells.
fn cutCells(line: []const u8, cells: usize) []const u8 {
    var view = std.unicode.Utf8View.init(line) catch return line;
    var it = view.iterator();
    var n: usize = 0;
    while (true) {
        const at = it.i;
        const cp = it.nextCodepoint() orelse return line;
        const w = cellWidth(cp);
        if (n + w > cells) return line[0..at];
        n += w;
    }
}

fn cellWidth(cp: u21) usize {
    return @min(vt.unicode.codepointWidth(cp), 2);
}

/// The last `count` lines up to the cursor that are not blank.
fn lastLines(a: std.mem.Allocator, session: []const u8, count: usize) ![]const []const u8 {
    const reply = try client.request(a, protocol.ViewReq{ .session = session }, protocol.ViewResp);
    if (!reply.parsed.value.ok) return &.{};
    const v = reply.parsed.value;
    var all: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, v.text, '\n');
    var row: u16 = 1;
    while (it.next()) |line| : (row += 1) {
        if (row > v.cursor.row) break;
        const trimmed = std.mem.trimEnd(u8, line, " ");
        if (trimmed.len > 0) try all.append(a, trimmed);
    }
    return all.items[all.items.len -| count..];
}

fn displayWidth(text: []const u8) usize {
    var view = std.unicode.Utf8View.init(text) catch return text.len;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| n += cellWidth(cp);
    return n;
}

fn truncate(text: []const u8, cells: usize) []const u8 {
    return cutCells(text, cells);
}

fn clearProgress(terminal: bool) void {
    if (terminal) errPrint("\r\x1b[K", .{}) catch {};
}

/// Drop what was typed ahead, so it does not land in the session.
fn flushInput() void {
    if (builtin.os.tag == .windows) return;
    const t = plat.tcgetattr(0) catch return;
    plat.tcsetattr(0, .FLUSH, t) catch {};
}

/// Ask on the terminal and read a line; without `echo`, what is typed is
/// not shown. Null when interrupted or at the end of input.
pub fn askLine(a: std.mem.Allocator, question: []const u8, echo: bool) !?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    try errPrint("{s}", .{question});
    const saved = plat.tcgetattr(0) catch null;
    if (saved) |orig| {
        var t = orig;
        t.lflag.ECHO = echo;
        t.lflag.ICANON = true;
        plat.tcsetattr(0, .FLUSH, t) catch {};
    }
    defer if (saved) |orig| {
        plat.tcsetattr(0, .NOW, orig) catch {};
        if (!echo) errPrint("\n", .{}) catch {};
    };
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        if (client.interrupt_signal.load(.acquire) != 0) return null;
        var fds = [1]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 100) <= 0) continue;
        var byte: [1]u8 = undefined;
        const n = std.c.read(0, &byte, 1);
        if (n <= 0) return null;
        if (byte[0] == '\n' or byte[0] == '\r') return try line.toOwnedSlice(a);
        try line.append(a, byte[0]);
    }
}

/// Open the start file in the person's editor at `line`. Ctrl-C and
/// Ctrl-\ are the editor's meanwhile, as with system().
pub fn edit(a: std.mem.Allocator, path: []const u8, line: u32) void {
    if (builtin.os.tag == .windows) return;
    const at = std.fmt.allocPrintSentinel(a, "+{d}", .{line}, 0) catch return;
    const file = a.dupeSentinel(u8, path, 0) catch return;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "exec ${VISUAL:-${EDITOR:-vi}} \"$@\"", "tuppet", at.ptr, file.ptr };
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    const default: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    const sigs = [_]std.posix.SIG{ .INT, .QUIT };
    var old: [sigs.len]std.posix.Sigaction = undefined;
    for (sigs, &old) |sig, *o| std.posix.sigaction(sig, &ignore, o);
    defer for (sigs, &old) |sig, *o| std.posix.sigaction(sig, o, null);
    const pid = std.c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        for (sigs) |sig| std.posix.sigaction(sig, &default, null);
        _ = std.c.execve("/bin/sh", &argv, std.c.environ);
        std.c._exit(127);
    }
    var st: c_int = 0;
    _ = std.c.waitpid(pid, &st, 0);
}

pub fn outPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return plat.stdoutWriteAll("(line too long)\n");
    try plat.stdoutWriteAll(text);
}

pub fn errPrint(comptime fmt: []const u8, args: anytype) !void {
    var buf: [16384]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return plat.stderrWriteAll("(message too long)\n");
    try plat.stderrWriteAll(text);
}

test "a block of only settings draws no progress" {
    const plan: start.Plan = .{ .id = "b", .block_line = 1, .steps = &.{}, .origins = &.{}, .secrets = &.{} };
    const file: start.File = .{ .path = "start", .blocks = &.{}, .stray = &.{} };
    var r: Runner = .{ .gpa = std.testing.allocator, .plan = &plan, .file = &file, .session = "1", .name = "b", .terminal = true };
    r.drawProgress(std.testing.allocator, "");
}

test "an empty answer is Enter alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var batch: std.ArrayList(protocol.Step) = .empty;
    try appendAnswer(arena.allocator(), &batch, "", true);
    try std.testing.expect(try @import("batch.zig").check(arena.allocator(), batch.items) == .plans);
    try std.testing.expectEqual(1, batch.items.len);
}

test "a prompt ending in a blank ends the cursor's line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Password: ", try leftOf(arena.allocator(), "Password:", 10));
    try std.testing.expectEqualStrings("ab", try leftOf(arena.allocator(), "abc", 2));
    const a = std.testing.allocator;
    try std.testing.expect(endsLine(a, "Password: ", &.{.{ .text = "Password: $", .regex = true }}));
    try std.testing.expect(endsLine(a, "me@db1:~$ ", &.{.{ .text = "me@db1:~$" }}));
    try std.testing.expect(endsLine(a, "me@db1:~$ ", &.{.{ .text = "~\\$", .regex = true }}));
    try std.testing.expect(!endsLine(a, "me@db1:~$ ls", &.{.{ .text = "~\\$", .regex = true }}));
}
