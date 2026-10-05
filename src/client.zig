//! The tuppet CLI: connects to the daemon (auto-starting it), sends a
//! JSON-lines request, prints the response.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const keys = @import("keys.zig");
const mouse = @import("mouse.zig");
const protocol = @import("protocol.zig");
const plat = @import("plat.zig");
const attach_client = @import("attach_client.zig");
const attach = @import("attach.zig");

/// Sentinel for argument/usage mistakes; main maps it to exit code 2.
pub const UsageError = error{UsageError};

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
    plat.stderrWriteAll("\nrun 'tuppet help' for usage\n") catch {};
    return error.UsageError;
}

/// Print `tuppet: <message>` to stderr and exit 1: a runtime failure, such
/// as an unusable environment, that no change of arguments fixes.
pub fn runtimeFail(comptime fmt: []const u8, args: anytype) noreturn {
    stderrPrint("tuppet: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(1);
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

/// Reject trailing arguments after the command's expected shape.
fn expectNoMore(args: []const []const u8, at: usize) error{UsageError}!void {
    if (at >= args.len) return;
    return cliFail("unexpected argument '{s}'", .{args[at]});
}

const run_usage = "usage: tuppet run [-a] [--name n] [--size WxH] [--cwd dir] [--scrollback SIZE] [--record] [--record-file FILE] [--record-format cast|trace] <cmd...>";

/// A byte count with an optional K, M, or G suffix (powers of 1024).
fn parseByteSize(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    const shift: u6 = switch (std.ascii.toUpper(text[text.len - 1])) {
        'K' => 10,
        'M' => 20,
        'G' => 30,
        else => 0,
    };
    const digits = if (shift == 0) text else text[0 .. text.len - 1];
    const n = protocol.parseDecimal(u64, digits) orelse return null;
    return std.math.shlExact(u64, n, shift) catch null;
}

test "byte sizes take K, M, and G suffixes" {
    try std.testing.expectEqual(@as(?u64, 512 * 1024), parseByteSize("512K"));
    try std.testing.expectEqual(@as(?u64, 2 << 20), parseByteSize("2m"));
    try std.testing.expectEqual(@as(?u64, 0), parseByteSize("0"));
    try std.testing.expectEqual(@as(?u64, null), parseByteSize("1.5M"));
    try std.testing.expectEqual(@as(?u64, null), parseByteSize("K"));
}

pub fn cmdRun(gpa: std.mem.Allocator, args: []const []const u8) !void {
    var name: ?[]const u8 = null;
    var cols: u16 = default_cols;
    var rows: u16 = default_rows;
    var cwd: ?[]const u8 = null;
    var sized = false;
    var attach_now = false;
    var scrollback: ?u64 = null;
    var record = false;
    var record_path: ?[]const u8 = null;
    var record_format: []const u8 = "cast";
    var rest: []const []const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            // Everything after `--` is the command, even if it starts
            // with a dash.
            rest = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, a, "--name")) {
            if (i + 1 >= args.len) return cliFail("missing value for --name", .{});
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, a, "--size")) {
            if (i + 1 >= args.len) return cliFail("missing value for --size", .{});
            i += 1;
            const size = try parseSize(args[i]);
            cols = size[0];
            rows = size[1];
            sized = true;
        } else if (std.mem.eql(u8, a, "--cwd")) {
            if (i + 1 >= args.len) return cliFail("missing value for --cwd", .{});
            i += 1;
            cwd = args[i];
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--attach")) {
            attach_now = true;
        } else if (std.mem.eql(u8, a, "--scrollback")) {
            if (i + 1 >= args.len) return cliFail("missing value for --scrollback", .{});
            i += 1;
            scrollback = parseByteSize(args[i]) orelse return cliFail("invalid scrollback '{s}' (expected bytes, optionally with K, M, or G)", .{args[i]});
        } else if (std.mem.eql(u8, a, "--record")) {
            record = true;
        } else if (std.mem.eql(u8, a, "--record-file")) {
            if (i + 1 >= args.len) return cliFail("missing value for --record-file", .{});
            i += 1;
            record = true;
            record_path = args[i];
        } else if (std.mem.eql(u8, a, "--record-format")) {
            if (i + 1 >= args.len) return cliFail("missing value for --record-format", .{});
            i += 1;
            record_format = args[i];
            if (!std.mem.eql(u8, record_format, "cast") and !std.mem.eql(u8, record_format, "trace")) {
                return cliFail("unknown recording format '{s}' (choose cast or trace)", .{record_format});
            }
        } else if (std.mem.startsWith(u8, a, "-")) {
            return cliFail("unknown option '{s}' ({s})", .{ a, run_usage });
        } else {
            rest = args[i..];
            break;
        }
    }
    if (rest.len == 0) return cliFail("missing command to run", .{});
    if (scrollback) |bytes| {
        if (bytes > 1 << 30) return cliFail("scrollback must be at most 1G", .{});
    } else if (std.c.getenv("TUPPET_SCROLLBACK")) |env| {
        const value = std.mem.span(env);
        const bytes = parseByteSize(value) orelse return cliFail("invalid TUPPET_SCROLLBACK '{s}' (expected bytes, optionally with K, M, or G)", .{value});
        if (bytes > 1 << 30) return cliFail("TUPPET_SCROLLBACK must be at most 1G", .{});
        scrollback = bytes;
    }
    if (!record and !std.mem.eql(u8, record_format, "cast")) return cliFail("--record-format needs --record or --record-file", .{});
    // The size: --size, else this terminal's for -a (instead of a resize
    // right away), else TUPPET_SIZE, else 120x40.
    if (attach_now) attach_client.checkSupported();
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
            const size = sizeValue(value) orelse return cliFail("invalid TUPPET_SIZE '{s}' (expected WxH, each 1..1000)", .{value});
            cols = size[0];
            rows = size[1];
        };
    }

    // The session runs where and with what this command runs, not with
    // whatever the long-lived daemon inherited when it was started.
    const cwd_abs = try absolutePath(gpa, cwd orelse ".");
    defer gpa.free(cwd_abs);
    var env_map = try std.process.Environ.createMap(io_mod.environ, gpa);
    defer env_map.deinit();
    var env: std.ArrayList([]const u8) = .empty;
    defer {
        for (env.items) |entry| gpa.free(entry);
        env.deinit(gpa);
    }
    var env_it = env_map.iterator();
    while (env_it.next()) |entry| {
        // Windows' hidden per-drive entries ("=C:=C:\dir") are not
        // variables a child can be given.
        if (entry.key_ptr.len == 0 or entry.key_ptr.*[0] == '=') continue;
        try env.ensureUnusedCapacity(gpa, 1);
        env.appendAssumeCapacity(try std.fmt.allocPrint(gpa, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }));
    }

    const record_abs = if (record_path) |p| try absolutePath(gpa, p) else null;
    defer if (record_abs) |p| gpa.free(p);
    const parsed = try request(gpa, protocol.RunReq{
        .name = name,
        .cols = cols,
        .rows = rows,
        .cwd = cwd_abs,
        .env = env.items,
        .scrollback = scrollback,
        .record = if (record) .{ .path = record_abs, .format = record_format } else null,
        .argv = rest,
    }, protocol.RunResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "run failed"});
        std.process.exit(1);
    }
    var buf: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{d}", .{resp.id.?}) catch unreachable;
    if (attach_now) attach_client.attachSession(gpa, id, .{ .resize = !keep_size }, false) catch |err| {
        stderrPrint("tuppet: session {s} is running, but attaching to it failed; 'tuppet attach {s}' retries\n", .{ id, id }) catch {};
        return err;
    };
    try stdoutPrint("{s}\n", .{id});
}

/// The daemon's sessions, for the picker.
pub fn listSessions(gpa: std.mem.Allocator) !std.json.Parsed(protocol.ListResp) {
    return request(gpa, protocol.ListReq{}, protocol.ListResp);
}

pub fn cmdList(gpa: std.mem.Allocator, args: []const []const u8) !void {
    try expectNoMore(args, 0);
    const parsed = try request(gpa, protocol.ListReq{}, protocol.ListResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "list failed"});
        std.process.exit(1);
    }
    for (resp.sessions orelse &.{}) |s| {
        // The session name is unbounded user data, so write the row in
        // pieces instead of formatting it into a fixed-size buffer.
        var num_buf: [64]u8 = undefined;
        const head = std.fmt.bufPrint(&num_buf, "{d}\t{d}\t", .{ s.id, s.pid }) catch unreachable;
        try stdoutWrite(head);
        try writeEscaped(StdoutSink{}, s.name);
        const tail = std.fmt.bufPrint(&num_buf, "\t{s}\t{d}x{d}\t", .{ s.state, s.cols, s.rows }) catch unreachable;
        try stdoutWrite(tail);
        // How the program ended: its exit code, or the signal that killed it.
        if (s.exit_code) |code| {
            var status_buf: [32]u8 = undefined;
            const status = attach.exitText(&status_buf, code);
            // "exited 7" lists as 7, "killed SIGTERM" as SIGTERM.
            try stdoutWrite(status[std.mem.indexOfScalar(u8, status, ' ').? + 1 ..]);
        }
        try stdoutWrite("\n");
    }
}

const StdoutSink = struct {
    fn writeAll(_: StdoutSink, bytes: []const u8) !void {
        return stdoutWrite(bytes);
    }
};

/// Write `text` to `sink` (anything with writeAll) with tabs, newlines,
/// and other control characters escaped (`\t`, `\n`, `\xNN`), so a
/// session name or command stays one field of one row and never reaches
/// the terminal as a control sequence.
pub fn writeEscaped(sink: anytype, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch >= 0x20 and ch != 0x7f and ch != '\\') continue;
        try sink.writeAll(text[start..i]);
        var esc_buf: [4]u8 = undefined;
        const esc = switch (ch) {
            '\t' => "\\t",
            '\n' => "\\n",
            '\\' => "\\\\",
            else => std.fmt.bufPrint(&esc_buf, "\\x{x:0>2}", .{ch}) catch unreachable,
        };
        try sink.writeAll(esc);
        start = i + 1;
    }
    try sink.writeAll(text[start..]);
}

pub fn cmdKey(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) return cliFail("usage: tuppet key <id> [--delay ms] <keys...> (e.g. <C-c>, <Esc>, <Up>)", .{});
    var delay_ms: i64 = 0;
    var toks: std.ArrayList([]const u8) = .empty;
    defer toks.deinit(gpa);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        // Options come before the first key; after it, everything is a key.
        if (toks.items.len == 0 and std.mem.eql(u8, a, "--delay")) {
            if (i + 1 >= args.len) return cliFail("missing value for --delay", .{});
            i += 1;
            delay_ms = try parseDuration("delay", args[i], 0);
        } else {
            try toks.append(gpa, a);
        }
    }
    if (toks.items.len == 0) return cliFail("usage: tuppet key <id> [--delay ms] <keys...> (e.g. <C-c>, <Esc>, <Up>)", .{});
    // Notation is validated here so malformed keys get the usage-error
    // treatment (clear message, exit 2) instead of a daemon error name.
    for (toks.items) |tok| {
        keys.checkToken(tok) catch |err|
            return cliFail("invalid key '{s}': {s}", .{ tok, keyErrorText(err) });
    }
    if (delay_ms > 0) std.Io.sleep(io_mod.io(), .fromMilliseconds(@intCast(delay_ms)), .boot) catch {};
    const parsed = try request(gpa, protocol.KeyReq{ .id = args[0], .keys = toks.items }, protocol.SendResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "key failed"});
        std.process.exit(1);
    }
}

pub fn cmdMouse(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 4) {
        return cliFail("usage: tuppet mouse <id> <button> <x> <y> [--action press|release|motion] [--mods cas] [--delay ms]", .{});
    }
    const id = args[0];
    const button = args[1];
    const x = try parseCoordinate("x", args[2]);
    const y = try parseCoordinate("y", args[3]);
    var action: []const u8 = "press";
    var mods: []const u8 = "";
    var delay_ms: i64 = 0;
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--action")) {
            if (i + 1 >= args.len) return cliFail("missing value for --action", .{});
            i += 1;
            action = args[i];
        } else if (std.mem.eql(u8, a, "--mods")) {
            if (i + 1 >= args.len) return cliFail("missing value for --mods", .{});
            i += 1;
            mods = args[i];
        } else if (std.mem.eql(u8, a, "--delay")) {
            if (i + 1 >= args.len) return cliFail("missing value for --delay", .{});
            i += 1;
            delay_ms = try parseDuration("delay", args[i], 0);
        } else {
            return cliFail("unknown argument '{s}' (usage: tuppet mouse <id> <button> <x> <y> [--action ...] [--mods ...] [--delay ms])", .{a});
        }
    }
    _ = mouse.parseEvent(button, action, mods) catch |err|
        return cliFail("{s}", .{mouse.eventErrorText(err)});
    if (delay_ms > 0) std.Io.sleep(io_mod.io(), .fromMilliseconds(@intCast(delay_ms)), .boot) catch {};
    const parsed = try request(gpa, protocol.MouseReq{
        .id = id,
        .button = button,
        .action = action,
        .mods = mods,
        .x = x,
        .y = y,
    }, protocol.SendResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "mouse failed"});
        std.process.exit(1);
    }
}

pub fn cmdFocus(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) return cliFail("usage: tuppet focus <id> <on|off>", .{});
    try expectNoMore(args, 2);
    const focused = if (std.mem.eql(u8, args[1], "on"))
        true
    else if (std.mem.eql(u8, args[1], "off"))
        false
    else
        return cliFail("invalid focus value '{s}' (use 'on' or 'off')", .{args[1]});
    const parsed = try request(gpa, protocol.FocusReq{ .id = args[0], .focused = focused }, protocol.SendResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "focus failed"});
        std.process.exit(1);
    }
}

pub fn cmdSend(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) return cliFail("usage: tuppet send <id> [--paste] <text...> (joined with spaces)", .{});
    const id = args[0];
    // Only directly after the id, so any other "--paste" is text.
    const paste = std.mem.eql(u8, args[1], "--paste");
    const words = if (paste) args[2..] else args[1..];
    if (words.len == 0) return cliFail("usage: tuppet send <id> [--paste] <text...> (joined with spaces)", .{});
    var data = try std.ArrayList(u8).initCapacity(gpa, 64);
    defer data.deinit(gpa);
    for (words, 0..) |a, idx| {
        if (idx > 0) try data.append(gpa, ' ');
        try data.appendSlice(gpa, a);
    }
    const parsed = try request(gpa, protocol.SendReq{ .id = id, .data = data.items, .paste = paste }, protocol.SendResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "send failed"});
        std.process.exit(1);
    }
}

pub fn cmdResize(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) return cliFail("usage: tuppet resize <id> WxH", .{});
    try expectNoMore(args, 2);
    const size = try parseSize(args[1]);
    const parsed = try request(gpa, protocol.ResizeReq{
        .id = args[0],
        .cols = size[0],
        .rows = size[1],
    }, protocol.SendResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "resize failed"});
        std.process.exit(1);
    }
}

pub fn cmdView(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) return cliFail("usage: tuppet view <id> [--format plain|vt|html|json] [--scrollback]", .{});
    const id = args[0];
    var format: []const u8 = "plain";
    var scrollback = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--format")) {
            if (i + 1 >= args.len) return cliFail("missing value for --format", .{});
            i += 1;
            format = args[i];
        } else if (std.mem.eql(u8, a, "--scrollback")) {
            scrollback = true;
        } else {
            return cliFail("unknown argument '{s}' (usage: tuppet view <id> [--format plain|vt|html|json] [--scrollback])", .{a});
        }
    }
    if (!validFormat(format)) return cliFail("unknown format '{s}' (choose plain, vt, html, or json)", .{format});
    if (scrollback and std.mem.eql(u8, format, "json")) return cliFail("--scrollback is not available with --format json", .{});
    const parsed = try request(gpa, protocol.ViewReq{ .id = id, .format = format, .scrollback = scrollback }, protocol.ViewResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "view failed"});
        std.process.exit(1);
    }
    if (std.mem.eql(u8, format, "json")) {
        const json = try screenJson(gpa, resp);
        defer gpa.free(json);
        try stdoutWrite(json);
        try stdoutWrite("\n");
        return;
    }
    try stdoutWrite(resp.text orelse "");
    if (!std.mem.endsWith(u8, resp.text orelse "", "\n")) try stdoutWrite("\n");
}

/// The screen as `view --format json` and `watch --format json` print it.
fn screenJson(gpa: std.mem.Allocator, resp: protocol.ViewResp) ![]u8 {
    return protocol.stringifyAlloc(gpa, .{
        .cols = resp.cols,
        .rows = resp.rows,
        .cursor = .{ .row = resp.cursor_row, .col = resp.cursor_col },
        .exited = resp.exited,
        .exit_code = resp.exit_code,
        .idle_ms = resp.idle_ms,
        .recording = resp.recording,
        .text = resp.text orelse "",
    });
}

/// Render the session screen as a PNG and write it to `path`.
pub fn cmdPng(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) return cliFail("usage: tuppet png <id> <file.png>", .{});
    try expectNoMore(args, 2);
    const parsed = try request(gpa, protocol.PngReq{ .id = args[0] }, protocol.PngResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "png failed"});
        std.process.exit(1);
    }
    const b64 = resp.png_b64 orelse return error.MissingPng;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    const decoded = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, b64);

    // plat.create needs a sentinel-terminated path.
    const path = try gpa.dupeZ(u8, args[1]);
    defer gpa.free(path);
    const file = plat.create(path, .blocking) catch {
        try stderrPrint("tuppet: cannot create '{s}'\n", .{args[1]});
        std.process.exit(1);
    };
    defer plat.close(file);
    plat.writeAll(file, decoded) catch {
        try stderrPrint("tuppet: cannot write '{s}'\n", .{args[1]});
        std.process.exit(1);
    };
}

/// Start (with a path), annotate (with --mark), or stop (with neither)
/// a recording. Two formats: "cast" (asciicast v2) and "trace" (a JSONL
/// timeline of input, screen-diff, and stop events).
pub fn cmdRecord(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        return cliFail("usage: tuppet record <id> [<file>] [--format cast|trace] [--input] [--until-match s] [--until-timeout ms] [--mark label]", .{});
    }
    const id = args[0];
    var path: ?[]const u8 = null;
    var mark: ?[]const u8 = null;
    var format: []const u8 = "cast";
    var input = false;
    var until_match: ?[]const u8 = null;
    var until_timeout_ms: ?i64 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--format")) {
            if (i + 1 >= args.len) return cliFail("missing value for --format", .{});
            i += 1;
            format = args[i];
        } else if (std.mem.eql(u8, a, "--input")) {
            input = true;
        } else if (std.mem.eql(u8, a, "--until-match")) {
            if (i + 1 >= args.len) return cliFail("missing value for --until-match", .{});
            i += 1;
            until_match = args[i];
        } else if (std.mem.eql(u8, a, "--until-timeout")) {
            if (i + 1 >= args.len) return cliFail("missing value for --until-timeout", .{});
            i += 1;
            until_timeout_ms = try parseDuration("until-timeout", args[i], 1);
        } else if (std.mem.eql(u8, a, "--mark")) {
            if (i + 1 >= args.len) return cliFail("missing value for --mark", .{});
            i += 1;
            mark = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return cliFail("unknown option '{s}' (usage: tuppet record <id> [<file>] [--format cast|trace] [--input] [--until-match s] [--until-timeout ms] [--mark label])", .{a});
        } else if (path == null) {
            path = a;
        } else {
            return cliFail("unexpected argument '{s}'", .{a});
        }
    }
    if (!std.mem.eql(u8, format, "cast") and !std.mem.eql(u8, format, "trace")) {
        return cliFail("unknown format '{s}' (choose cast or trace)", .{format});
    }
    if (mark != null and (path != null or input or until_match != null or until_timeout_ms != null or !std.mem.eql(u8, format, "cast"))) {
        return cliFail("--mark appends to the active recording and takes no other options", .{});
    }
    if (path == null and mark == null and (input or until_match != null or until_timeout_ms != null or !std.mem.eql(u8, format, "cast"))) {
        return cliFail("stopping a recording takes no options", .{});
    }
    if (until_match != null and until_match.?.len == 0) {
        return cliFail("--until-match needs a non-empty value", .{});
    }

    var path_abs: ?[]u8 = null;
    defer if (path_abs) |p| gpa.free(p);
    if (path) |p| path_abs = try absolutePath(gpa, p);
    const parsed = try request(gpa, protocol.RecordReq{
        .id = id,
        .path = path_abs,
        .mark = mark,
        .format = format,
        .input = input,
        .until_match = until_match,
        .until_timeout_ms = if (until_timeout_ms) |ms| @intCast(ms) else null,
    }, protocol.RecordResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "record failed"});
        std.process.exit(1);
    }
}

/// Repeatedly print the session snapshot until it exits.
pub fn cmdWatch(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) return cliFail("usage: tuppet watch <id> [--format plain|json] [--interval ms]", .{});
    const id = args[0];
    var format: []const u8 = "plain";
    var interval_ms: i64 = 500;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--format")) {
            if (i + 1 >= args.len) return cliFail("missing value for --format", .{});
            i += 1;
            format = args[i];
        } else if (std.mem.eql(u8, a, "--interval")) {
            if (i + 1 >= args.len) return cliFail("missing value for --interval", .{});
            i += 1;
            interval_ms = try parseDuration("interval", args[i], 1);
        } else {
            return cliFail("unknown argument '{s}' (usage: tuppet watch <id> [--format plain|json] [--interval ms])", .{a});
        }
    }
    if (!std.mem.eql(u8, format, "plain") and !std.mem.eql(u8, format, "json")) {
        return cliFail("unknown format '{s}' (choose plain or json)", .{format});
    }
    const io = io_mod.io();
    while (true) {
        const parsed = try request(gpa, protocol.ViewReq{ .id = id, .format = format }, protocol.ViewResp);
        defer parsed.deinit();
        const resp = parsed.value;
        if (!resp.ok) {
            try stderrPrint("tuppet: {s}\n", .{resp.err orelse "watch failed"});
            std.process.exit(1);
        }
        if (std.mem.eql(u8, format, "json")) {
            const json = try screenJson(gpa, resp);
            defer gpa.free(json);
            try stdoutWrite(json);
            try stdoutWrite("\n");
        } else {
            try stdoutWrite(resp.text orelse "");
            try stdoutWrite("\n");
        }
        if (resp.exited) return;
        std.Io.sleep(io, .fromMilliseconds(interval_ms), .boot) catch {};
    }
}

pub fn cmdWait(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) return cliFail("usage: tuppet wait <id> [--exit] [--match s] [--idle ms] [--timeout ms]", .{});
    const id = args[0];
    var want_exit = false;
    var match: ?[]const u8 = null;
    var idle_ms: ?i64 = null;
    var timeout_ms: i64 = 30_000;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--exit")) {
            want_exit = true;
        } else if (std.mem.eql(u8, a, "--match")) {
            if (i + 1 >= args.len) return cliFail("missing value for --match", .{});
            i += 1;
            if (args[i].len == 0) return cliFail("--match needs a non-empty value", .{});
            match = args[i];
        } else if (std.mem.eql(u8, a, "--idle")) {
            if (i + 1 >= args.len) return cliFail("missing value for --idle", .{});
            i += 1;
            idle_ms = try parseDuration("idle", args[i], 0);
        } else if (std.mem.eql(u8, a, "--timeout")) {
            if (i + 1 >= args.len) return cliFail("missing value for --timeout", .{});
            i += 1;
            timeout_ms = try parseDuration("timeout", args[i], 0);
        } else {
            return cliFail("unknown argument '{s}' (usage: tuppet wait <id> [--exit] [--match s] [--idle ms] [--timeout ms])", .{a});
        }
    }
    if (!want_exit and match == null and idle_ms == null) {
        return cliFail("wait needs at least one of --exit, --match, or --idle", .{});
    }

    const io = io_mod.io();
    const started = io_mod.nowNanos();
    while (true) {
        const parsed = try request(gpa, protocol.ViewReq{ .id = id }, protocol.ViewResp);
        defer parsed.deinit();
        const resp = parsed.value;
        if (!resp.ok) {
            try stderrPrint("tuppet: {s}\n", .{resp.err orelse "wait failed"});
            std.process.exit(1);
        }
        if (want_exit and resp.exited) return;
        if (match) |needle| {
            if (std.mem.indexOf(u8, resp.text orelse "", screenNeedle(needle)) != null) return;
        }
        if (idle_ms) |ms| {
            if (resp.idle_ms >= @as(u64, @intCast(ms))) return;
        }
        // An exited session never prints the needle; only --idle can
        // still be met.
        if (resp.exited and idle_ms == null) {
            try stderrPrint("tuppet: the session exited before '{s}' appeared; final screen:\n", .{match.?});
            const text = resp.text orelse "";
            try plat.stderrWriteAll(text);
            if (!std.mem.endsWith(u8, text, "\n")) try plat.stderrWriteAll("\n");
            std.process.exit(1);
        }
        const elapsed_ns = std.math.sub(i64, io_mod.nowNanos(), started) catch std.math.maxInt(i64);
        const elapsed_ms = @divTrunc(@max(elapsed_ns, 0), std.time.ns_per_ms);
        if (elapsed_ms >= timeout_ms) {
            try stderrPrint("tuppet: wait timed out after {d} ms; current screen:\n", .{timeout_ms});
            const text = resp.text orelse "";
            try plat.stderrWriteAll(text);
            if (!std.mem.endsWith(u8, text, "\n")) try plat.stderrWriteAll("\n");
            std.process.exit(1);
        }
        std.Io.sleep(io, .fromMilliseconds(100), .boot) catch {};
    }
}

// ---- trace -----------------------------------------------------------

const trace_max_steps = 500;

const TraceStep = union(enum) {
    key: []const u8,
    send: []const u8,
    mouse: struct { button: []const u8, x: u16, y: u16 },
    sleep_ms: i64,
    /// within_ms of -1 means "use the --timeout value" (filled after
    /// parsing, so --timeout may appear anywhere).
    expect: struct { needle: []const u8, within_ms: i64 },
    mark: []const u8,
};

/// How a trace run ended. Every outcome stops the recording and prints
/// a JSON summary.
const TraceOutcome = union(enum) {
    ok,
    /// An expect did not match: exit 3.
    expect_failed: struct { step: usize, needle: []const u8, within_ms: i64, exited: bool, screen: []const u8 },
    /// A daemon request failed: exit 1.
    step_failed: struct { step: usize, what: []const u8, message: []const u8 },
    /// SIGINT/SIGTERM/SIGHUP (Ctrl-C on Windows): exit 128 + signal.
    interrupted: struct { step: usize, signal: u8 },
};

/// Signal number that interrupted `tuppet trace`, 0 while none has.
var trace_interrupt: std.atomic.Value(u8) = .{ .raw = 0 };

fn onTraceSignal(sig: std.posix.SIG) callconv(.c) void {
    trace_interrupt.store(@intCast(@intFromEnum(sig)), .release);
}

fn onTraceCtrl(ctrl_type: u32) callconv(.winapi) c_int {
    _ = ctrl_type;
    trace_interrupt.store(2, .release);
    return 1;
}

/// Catch interruption so `tuppet trace` can stop its recording on the way
/// out instead of leaving it running in the daemon.
fn installTraceInterruptHandlers() void {
    switch (builtin.os.tag) {
        .windows => _ = SetConsoleCtrlHandler(&onTraceCtrl, 1),
        else => {
            var act: std.posix.Sigaction = .{
                .handler = .{ .handler = onTraceSignal },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |sig| std.posix.sigaction(sig, &act, null);
        },
    }
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (u32) callconv(.winapi) c_int,
    add: c_int,
) callconv(.winapi) c_int;

/// Sleep in short slices so an interrupt is noticed promptly.
fn traceSleep(ms: i64) void {
    const io = io_mod.io();
    const end = io_mod.nowNanos() +| @min(ms, std.math.maxInt(i64) / std.time.ns_per_ms) * std.time.ns_per_ms;
    while (trace_interrupt.load(.acquire) == 0) {
        const left = end - io_mod.nowNanos();
        if (left <= 0) return;
        std.Io.sleep(io, .fromNanoseconds(@min(left, 50 * std.time.ns_per_ms)), .boot) catch {};
    }
}

/// Record a whole interaction flow in one invocation: start a recording,
/// run the steps in order (keys, text, mouse clicks, sleeps, expects,
/// marks), then stop the recording. The recording is stopped and a JSON
/// summary printed on every path, including Ctrl-C.
pub fn cmdTrace(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) return cliFail("usage: tuppet trace <id> <file> [--format trace|cast] [--timeout ms] <steps...>", .{});
    const id = args[0];
    const file = args[1];
    var format: []const u8 = "trace";
    var timeout_ms: i64 = 10_000;
    var steps: std.ArrayList(TraceStep) = .empty;
    defer steps.deinit(gpa);

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--key")) {
            if (i + 1 >= args.len) return cliFail("missing value for --key", .{});
            i += 1;
            keys.checkToken(args[i]) catch |err|
                return cliFail("invalid key '{s}': {s}", .{ args[i], keyErrorText(err) });
            try steps.append(gpa, .{ .key = args[i] });
        } else if (std.mem.eql(u8, a, "--send")) {
            if (i + 1 >= args.len) return cliFail("missing value for --send", .{});
            i += 1;
            try steps.append(gpa, .{ .send = args[i] });
        } else if (std.mem.eql(u8, a, "--mouse")) {
            if (i + 3 >= args.len) return cliFail("--mouse needs <button> <x> <y>", .{});
            const button = args[i + 1];
            _ = mouse.parseEvent(button, "press", "") catch |err|
                return cliFail("{s}", .{mouse.eventErrorText(err)});
            const x = try parseCoordinate("x", args[i + 2]);
            const y = try parseCoordinate("y", args[i + 3]);
            i += 3;
            try steps.append(gpa, .{ .mouse = .{ .button = button, .x = x, .y = y } });
        } else if (std.mem.eql(u8, a, "--sleep")) {
            if (i + 1 >= args.len) return cliFail("missing value for --sleep", .{});
            i += 1;
            try steps.append(gpa, .{ .sleep_ms = try parseDuration("sleep", args[i], 0) });
        } else if (std.mem.eql(u8, a, "--expect")) {
            if (i + 1 >= args.len) return cliFail("missing value for --expect", .{});
            i += 1;
            if (args[i].len == 0) return cliFail("--expect needs a non-empty value", .{});
            try steps.append(gpa, .{ .expect = .{ .needle = args[i], .within_ms = -1 } });
        } else if (std.mem.eql(u8, a, "--within")) {
            if (i + 1 >= args.len) return cliFail("missing value for --within", .{});
            i += 1;
            const within = try parseDuration("within", args[i], 0);
            if (steps.items.len == 0) return cliFail("--within must follow an --expect step", .{});
            const last = &steps.items[steps.items.len - 1];
            if (last.* != .expect or last.expect.within_ms != -1) {
                return cliFail("--within must follow an --expect step", .{});
            }
            last.expect.within_ms = within;
        } else if (std.mem.eql(u8, a, "--mark")) {
            if (i + 1 >= args.len) return cliFail("missing value for --mark", .{});
            i += 1;
            try steps.append(gpa, .{ .mark = args[i] });
        } else if (std.mem.eql(u8, a, "--format")) {
            if (i + 1 >= args.len) return cliFail("missing value for --format", .{});
            i += 1;
            format = args[i];
        } else if (std.mem.eql(u8, a, "--timeout")) {
            if (i + 1 >= args.len) return cliFail("missing value for --timeout", .{});
            i += 1;
            timeout_ms = try parseDuration("timeout", args[i], 1);
        } else {
            return cliFail("unknown argument '{s}' (usage: tuppet trace <id> <file> [--format trace|cast] [--timeout ms] <steps...>; steps: --key k, --send t, --mouse b x y, --sleep ms, --expect s [--within ms], --mark label)", .{a});
        }
    }
    if (!std.mem.eql(u8, format, "trace") and !std.mem.eql(u8, format, "cast")) {
        return cliFail("unknown format '{s}' (choose trace or cast)", .{format});
    }
    if (steps.items.len == 0) return cliFail("trace needs at least one step", .{});
    if (steps.items.len > trace_max_steps) return cliFail("too many steps (max {d})", .{trace_max_steps});
    for (steps.items) |*step| {
        if (step.* == .expect and step.expect.within_ms == -1) step.expect.within_ms = timeout_ms;
    }

    const path_abs = try absolutePath(gpa, file);
    defer gpa.free(path_abs);

    // Mouse coordinates need the session's size: a read-only view, so a
    // trace that cannot run fails before anything reaches the session.
    {
        const parsed = request(gpa, protocol.ViewReq{ .id = id }, protocol.ViewResp) catch |err| {
            if (err == error.UsageError or err == error.OutOfMemory) return err;
            traceSetupFail(gpa, errorMessage(err));
        };
        defer parsed.deinit();
        if (!parsed.value.ok) traceSetupFail(gpa, parsed.value.err orelse "view failed");
        for (steps.items) |step| {
            if (step != .mouse) continue;
            if (step.mouse.x >= parsed.value.cols or step.mouse.y >= parsed.value.rows) {
                return cliFail("--mouse {d} {d} is outside the session's {d}x{d} grid", .{ step.mouse.x, step.mouse.y, parsed.value.cols, parsed.value.rows });
            }
        }
    }

    installTraceInterruptHandlers();
    const started = io_mod.nowNanos();
    {
        const parsed = request(gpa, protocol.RecordReq{
            .id = id,
            .path = path_abs,
            .format = format,
            .input = true,
        }, protocol.RecordResp) catch |err| {
            // The daemon may have started recording before the reply
            // was lost.
            traceStop(gpa, id);
            if (err == error.UsageError or err == error.OutOfMemory) return err;
            traceSetupFail(gpa, errorMessage(err));
        };
        defer parsed.deinit();
        if (!parsed.value.ok) traceSetupFail(gpa, parsed.value.err orelse "record failed");
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const outcome = runTraceSteps(arena_state.allocator(), id, steps.items) catch |err| {
        traceStop(gpa, id);
        return err;
    };
    switch (outcome) {
        .ok => {},
        .expect_failed => |f| {
            const label = std.fmt.allocPrint(gpa, "expect failed: {s} ({d} ms)", .{ f.needle, f.within_ms }) catch null;
            defer if (label) |l| gpa.free(l);
            if (label) |l| traceMark(gpa, id, l);
        },
        .interrupted => traceMark(gpa, id, "interrupted"),
        .step_failed => {},
    }
    traceStop(gpa, id);

    const elapsed_ms = elapsedMsSince(started);
    switch (outcome) {
        .ok => {
            try printSummary(gpa, .{ .ok = true, .steps = steps.items.len, .elapsed_ms = elapsed_ms });
        },
        .expect_failed => |f| {
            if (f.exited) {
                try stderrPrint("tuppet: trace failed at step {d}: the session exited before '{s}' appeared; final screen:\n", .{ f.step, f.needle });
            } else {
                try stderrPrint("tuppet: trace failed at step {d}: '{s}' did not appear within {d} ms; current screen:\n", .{ f.step, f.needle, f.within_ms });
            }
            plat.stderrWriteAll(f.screen) catch {};
            if (!std.mem.endsWith(u8, f.screen, "\n")) plat.stderrWriteAll("\n") catch {};
            try printSummary(gpa, .{
                .ok = false,
                .failed_step = f.step,
                .needle = f.needle,
                .reason = if (f.exited) "exited" else "timeout",
                .elapsed_ms = elapsed_ms,
            });
            std.process.exit(3);
        },
        .step_failed => |f| {
            try stderrPrint("tuppet: trace step {d} ({s}) failed: {s}\n", .{ f.step, f.what, f.message });
            try printSummary(gpa, .{ .ok = false, .failed_step = f.step, .@"error" = f.message, .elapsed_ms = elapsed_ms });
            std.process.exit(1);
        },
        .interrupted => |f| {
            try stderrPrint("tuppet: trace interrupted at step {d}; recording stopped\n", .{f.step});
            try printSummary(gpa, .{ .ok = false, .interrupted = true, .failed_step = f.step, .elapsed_ms = elapsed_ms });
            std.process.exit(128 + f.signal);
        },
    }
}

/// The trace could not start (unknown session, recording refused):
/// nothing was sent. Exit 1 with the usual summary on stdout.
fn traceSetupFail(gpa: std.mem.Allocator, message: []const u8) noreturn {
    stderrPrint("tuppet: {s}\n", .{message}) catch {};
    printSummary(gpa, .{ .ok = false, .failed_step = null, .@"error" = message, .elapsed_ms = 0 }) catch {};
    std.process.exit(1);
}

fn printSummary(gpa: std.mem.Allocator, value: anytype) !void {
    const summary = try protocol.stringifyAlloc(gpa, value);
    defer gpa.free(summary);
    try stdoutWrite(summary);
    try stdoutWrite("\n");
}

/// Run the steps; failures and interruption become outcomes. Strings in
/// the outcome live in `arena`.
fn runTraceSteps(arena: std.mem.Allocator, id: []const u8, steps: []const TraceStep) !TraceOutcome {
    const early = trace_interrupt.load(.acquire);
    if (early != 0) return .{ .interrupted = .{ .step = 1, .signal = early } };
    for (steps, 1..) |step, idx| {
        if (try runTraceStep(arena, id, idx, step)) |outcome| return outcome;
        // Checked after every step, the last included, so an interrupt
        // is reported against the step it cut short.
        const sig = trace_interrupt.load(.acquire);
        if (sig != 0) return .{ .interrupted = .{ .step = idx, .signal = sig } };
    }
    return .ok;
}

fn runTraceStep(arena: std.mem.Allocator, id: []const u8, idx: usize, step: TraceStep) !?TraceOutcome {
    switch (step) {
        .key => |tok| {
            const toks = [_][]const u8{tok};
            if (try traceInput(arena, idx, "key", protocol.KeyReq{ .id = id, .keys = &toks })) |o| return o;
        },
        .send => |text| {
            if (try traceInput(arena, idx, "send", protocol.SendReq{ .id = id, .data = text })) |o| return o;
        },
        .mouse => |m| {
            // A click: press, then release at the same cell.
            if (try traceInput(arena, idx, "mouse", protocol.MouseReq{ .id = id, .button = m.button, .x = m.x, .y = m.y })) |o| return o;
            if (std.mem.eql(u8, m.button, "up") or std.mem.eql(u8, m.button, "down") or
                std.mem.eql(u8, m.button, "4") or std.mem.eql(u8, m.button, "5")) return null;
            if (try traceInput(arena, idx, "mouse", protocol.MouseReq{ .id = id, .button = m.button, .action = "release", .x = m.x, .y = m.y })) |o| return o;
        },
        .sleep_ms => |ms| traceSleep(ms),
        .mark => |label| traceMark(arena, id, label),
        .expect => |ex| {
            const expect_started = io_mod.nowNanos();
            while (true) {
                const parsed = request(arena, protocol.ViewReq{ .id = id }, protocol.ViewResp) catch |err| {
                    if (err == error.UsageError or err == error.OutOfMemory) return err;
                    return .{ .step_failed = .{ .step = idx, .what = "expect", .message = errorMessage(err) } };
                };
                defer parsed.deinit();
                const resp = parsed.value;
                if (!resp.ok) {
                    return .{ .step_failed = .{ .step = idx, .what = "expect", .message = try arena.dupe(u8, resp.err orelse "view failed") } };
                }
                const text = resp.text orelse "";
                if (std.mem.indexOf(u8, text, screenNeedle(ex.needle)) != null) {
                    const label = try std.fmt.allocPrint(arena, "expect ok: {s} ({d} ms)", .{ ex.needle, elapsedMsSince(expect_started) });
                    traceMark(arena, id, label);
                    break;
                }
                // An exited session will never produce the needle.
                if (resp.exited or elapsedMsSince(expect_started) >= ex.within_ms) {
                    return .{ .expect_failed = .{
                        .step = idx,
                        .needle = ex.needle,
                        .within_ms = ex.within_ms,
                        .exited = resp.exited,
                        .screen = try arena.dupe(u8, text),
                    } };
                }
                const sig2 = trace_interrupt.load(.acquire);
                if (sig2 != 0) return .{ .interrupted = .{ .step = idx, .signal = sig2 } };
                traceSleep(100);
            }
        },
    }
    return null;
}

/// Send one input request; a failed request becomes a step failure.
fn traceInput(arena: std.mem.Allocator, step: usize, what: []const u8, req: anytype) !?TraceOutcome {
    const parsed = request(arena, req, protocol.SendResp) catch |err| {
        if (err == error.UsageError or err == error.OutOfMemory) return err;
        return .{ .step_failed = .{ .step = step, .what = what, .message = errorMessage(err) } };
    };
    defer parsed.deinit();
    if (parsed.value.ok) return null;
    return .{ .step_failed = .{ .step = step, .what = what, .message = try arena.dupe(u8, parsed.value.err orelse "request failed") } };
}

/// Screen rows are compared with their trailing spaces trimmed, so a
/// needle such as a '>>> ' prompt must lose its trailing spaces to match.
fn screenNeedle(needle: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, needle, " ");
    return if (trimmed.len == 0) needle else trimmed;
}

fn elapsedMsSince(started: i64) i64 {
    const elapsed_ns = std.math.sub(i64, io_mod.nowNanos(), started) catch std.math.maxInt(i64);
    return @divTrunc(@max(elapsed_ns, 0), std.time.ns_per_ms);
}

/// Append a marker to the trace recording; a mark failure does not
/// abort the trace.
fn traceMark(gpa: std.mem.Allocator, id: []const u8, label: []const u8) void {
    const parsed = request(gpa, protocol.RecordReq{ .id = id, .mark = label }, protocol.RecordResp) catch return;
    defer parsed.deinit();
}

/// Stop the trace recording; failure here must not mask the real error.
fn traceStop(gpa: std.mem.Allocator, id: []const u8) void {
    const parsed = request(gpa, protocol.RecordReq{ .id = id }, protocol.RecordResp) catch return;
    defer parsed.deinit();
}

pub fn cmdStop(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) return cliFail("usage: tuppet stop <id>", .{});
    try expectNoMore(args, 1);
    const parsed = try request(gpa, protocol.StopReq{ .id = args[0] }, protocol.SendResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "stop failed"});
        std.process.exit(1);
    }
}

pub fn cmdRemove(gpa: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) return cliFail("usage: tuppet remove <id>", .{});
    try expectNoMore(args, 1);
    const parsed = try request(gpa, protocol.RemoveReq{ .id = args[0] }, protocol.SendResp);
    defer parsed.deinit();
    const resp = parsed.value;
    if (!resp.ok) {
        try stderrPrint("tuppet: {s}\n", .{resp.err orelse "remove failed"});
        std.process.exit(1);
    }
}

// ---- plumbing ----------------------------------------------------------

/// The daemon endpoint from --socket or TUPPET_SOCKET. With it set, the
/// client talks only to that daemon and never starts one.
pub var socket_override: ?[]const u8 = null;

/// Set after the first reply. Later requests of the same command
/// (polling in wait, watch, trace) never start a daemon: if the daemon
/// died meanwhile, a fresh empty one would only hide that.
var daemon_contacted = false;

/// Let the next request start a daemon again: for the picker, which
/// outlives a daemon that died.
pub fn forgetDaemon() void {
    daemon_contacted = false;
}

/// A connection to the daemon (starting it if needed), for streams.
pub fn connect(gpa: std.mem.Allocator) !ipc.Conn {
    const conn = try ensureDaemon(gpa);
    daemon_contacted = true;
    return conn;
}

fn request(gpa: std.mem.Allocator, req: anytype, comptime Resp: type) !std.json.Parsed(Resp) {
    return requestOnce(gpa, req, Resp) catch |err| {
        // An idle daemon that exits resets the connections it had not
        // accepted yet, so it never read this request. The retry starts
        // a new daemon.
        if (err != error.ConnectionResetByPeer or daemon_contacted) return err;
        return requestOnce(gpa, req, Resp);
    };
}

fn requestOnce(gpa: std.mem.Allocator, req: anytype, comptime Resp: type) !std.json.Parsed(Resp) {
    var conn = try ensureDaemon(gpa);
    defer conn.deinit();

    const line = try protocol.stringifyRequest(gpa, req);
    defer gpa.free(line);
    // The daemon's request buffer is 1 MiB; fail fast instead of
    // leaving the connection in a broken state.
    if (line.len >= 1 << 20) return cliFail("request too large (daemon limit is 1 MiB)", .{});
    try conn.sendLine(line);

    // 16 MiB cap matches the daemon's response limit (enough for
    // base64-encoded PNG snapshots); the buffer grows with the actual
    // response instead of pre-allocating the cap.
    const resp_line = try conn.recvLineAlloc(gpa, 1 << 24);
    defer gpa.free(resp_line);
    daemon_contacted = true;
    // alloc_always: response strings (e.g. png_b64) must survive the
    // line buffer being freed above. ignore_unknown_fields tolerates
    // responses from a newer daemon.
    return std.json.parseFromSlice(Resp, gpa, resp_line, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

fn ensureDaemon(gpa: std.mem.Allocator) !ipc.Conn {
    if (socket_override) |path| {
        if (ipc.Conn.connect(path)) |conn| return conn else |err| switch (err) {
            error.UntrustedDaemon => runtimeFail("the socket {s} is served by another user's process; refusing to use it", .{path}),
            error.BadPath => return cliFail("socket path '{s}' is empty or too long", .{path}),
            else => return error.NoDaemon,
        }
    }
    var path_buf: [ipc.max_path_len:0]u8 = undefined;
    const path = ipc.socketPath(&path_buf) catch |err| switch (err) {
        error.SocketPathTooLong => runtimeFail("XDG_RUNTIME_DIR is too long for a socket path; use a shorter directory", .{}),
        error.UnsafeRuntimeDir => runtimeFail("cannot use the private runtime directory /tmp/tuppet-<uid> (it must be a directory owned by you)", .{}),
        error.UnknownUser => return err,
    };

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
        const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir}) catch unreachable;
        if (std.c.access(dir_z, std.c.F_OK) != 0) {
            try stderrPrint("tuppet: runtime directory {s} does not exist\n", .{dir});
            std.process.exit(1);
        }
    }

    var log_buf: [ipc.max_path_len:0]u8 = undefined;
    const log_path = ipc.logPath(&log_buf, path);
    try spawnDaemon(gpa, log_path);

    const io = io_mod.io();
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        std.Io.sleep(io, .fromMilliseconds(50), .boot) catch {};
        if (ipc.Conn.connect(path)) |conn| return conn else |_| {}
    }
    // The daemon's own error (stderr) explains why it did not come up.
    if (log_path) |lp| reportDaemonLog(lp);
    return error.DaemonStartTimeout;
}

fn reportDaemonLog(log_path: []const u8) void {
    // The Windows daemon is started without a log file.
    if (builtin.os.tag == .windows) return;
    // Plain open/read: Zig's readFileAlloc sizes the file with statx,
    // which kernels before 4.11 lack.
    var path_buf: [ipc.max_path_len:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{log_path}) catch return;
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    // The log is appended to across daemon starts; show its end.
    var buf: [4096]u8 = undefined;
    _ = std.c.lseek(fd, -@as(std.c.off_t, buf.len), std.c.SEEK.END);
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return;
    const trimmed = std.mem.trim(u8, buf[0..@intCast(n)], " \n");
    if (trimmed.len == 0) return;
    stderrPrint("tuppet: daemon log ({s}):\n{s}\n", .{ log_path, trimmed }) catch {};
}

/// Start `tuppet daemon` fully detached: on POSIX in its own session (so the
/// caller's Ctrl-C, terminal hangup, or `timeout` cannot kill it with
/// every session in it), not a session leader (so it can never acquire
/// a session's pty as its controlling terminal), with only stdio open
/// and stderr in the log file. Windows: no console of its own, so the
/// caller's Ctrl-C does not reach it.
fn spawnDaemon(gpa: std.mem.Allocator, log_path: ?[:0]const u8) !void {
    const io = io_mod.io();
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    // Sessions started without a caller environment (raw protocol
    // clients) inherit the daemon's, so it gets a usable TERM too.
    var env_map = try std.process.Environ.createMap(io_mod.environ, gpa);
    defer env_map.deinit();
    try env_map.put("TERM", "xterm-256color");

    if (builtin.os.tag == .windows) return spawnDaemonWindows(gpa, exe_buf[0..exe_len]);

    // Everything the child needs is prepared before fork; after it only
    // async-signal-safe calls run.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exe_z = try arena.dupeZ(u8, exe_buf[0..exe_len]);
    const argv = try arena.allocSentinel(?[*:0]const u8, 2, null);
    argv[0] = exe_z.ptr;
    argv[1] = "daemon";
    const envp = try arena.allocSentinel(?[*:0]const u8, env_map.count(), null);
    var env_it = env_map.iterator();
    var n: usize = 0;
    while (env_it.next()) |entry| : (n += 1) {
        envp[n] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0)).ptr;
    }
    var limit: std.c.rlimit = undefined;
    const max_fd: c_int = if (std.c.getrlimit(.NOFILE, &limit) == 0) @intCast(@min(limit.cur, 65536)) else 1024;

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        if (std.c.setsid() < 0) std.c._exit(1);
        const grandchild = std.c.fork();
        if (grandchild != 0) std.c._exit(if (grandchild < 0) 1 else 0);
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
    // The intermediate child exits at once; reap it.
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
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
const default_cols: u16 = 120;
const default_rows: u16 = 40;

fn sizeValue(s: []const u8) ?[2]u16 {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse return null;
    const cols = protocol.parseDecimal(u16, s[0..x]) orelse return null;
    const rows = protocol.parseDecimal(u16, s[x + 1 ..]) orelse return null;
    if (cols < 1 or cols > 1000 or rows < 1 or rows > 1000) return null;
    return .{ cols, rows };
}

/// Parse "WxH" into {cols, rows}, rejecting anything else. Both
/// dimensions must be in 1..1000: zero or absurd sizes would reach the
/// pty and the emulated grid.
fn parseSize(s: []const u8) error{UsageError}![2]u16 {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse
        return cliFail("invalid size '{s}' (expected WxH, e.g. 120x40)", .{s});
    const cols = protocol.parseDecimal(u16, s[0..x]) orelse
        return cliFail("invalid size '{s}' (width must be a number)", .{s});
    const rows = protocol.parseDecimal(u16, s[x + 1 ..]) orelse
        return cliFail("invalid size '{s}' (height must be a number)", .{s});
    if (cols < 1 or cols > 1000) return cliFail("invalid size '{s}' (width must be 1..1000)", .{s});
    if (rows < 1 or rows > 1000) return cliFail("invalid size '{s}' (height must be 1..1000)", .{s});
    return .{ cols, rows };
}

fn parseCoordinate(name: []const u8, value: []const u8) error{UsageError}!u16 {
    return protocol.parseDecimal(u16, value) orelse
        cliFail("invalid {s} coordinate '{s}' (expected a number)", .{ name, value });
}

fn parseDuration(name: []const u8, value: []const u8, minimum: i64) error{UsageError}!i64 {
    return parseDurationValue(value, minimum) catch
        return cliFail("invalid {s} '{s}' (expected {d}..{d} milliseconds)", .{ name, value, minimum, std.math.maxInt(i64) });
}

fn parseDurationValue(value: []const u8, minimum: i64) error{InvalidDuration}!i64 {
    const parsed = protocol.parseDecimal(i64, value) orelse return error.InvalidDuration;
    if (parsed < minimum) return error.InvalidDuration;
    return parsed;
}

/// Short text for transport errors inside `tuppet trace`'s summary.
fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.Eof, error.ConnectionResetByPeer => "daemon closed the connection",
        error.ReadTimeout, error.WriteTimeout => "daemon did not respond in time",
        error.WriteFailed, error.ReadFailed => "daemon connection failed",
        error.DaemonGone => "daemon is no longer running",
        error.NoDaemon => "no tuppet daemon is listening on the socket",
        else => @errorName(err),
    };
}

const testing = std.testing;

test "duration parsing accepts safe bounds and rejects values that could trap" {
    try testing.expectEqual(@as(i64, 0), try parseDurationValue("0", 0));

    var max_buf: [32]u8 = undefined;
    const max = try std.fmt.bufPrint(&max_buf, "{d}", .{std.math.maxInt(i64)});
    try testing.expectEqual(std.math.maxInt(i64), try parseDurationValue(max, 0));

    try testing.expectError(error.InvalidDuration, parseDurationValue("9223372036854775808", 0));
    try testing.expectError(error.InvalidDuration, parseDurationValue("0", 1));
}

fn validFormat(format: []const u8) bool {
    return std.mem.eql(u8, format, "plain") or
        std.mem.eql(u8, format, "vt") or
        std.mem.eql(u8, format, "html") or
        std.mem.eql(u8, format, "json");
}

/// Human-readable text for key-notation parse failures (see keys.zig).
fn keyErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyToken => "empty token",
        error.EmptyKeySegment => "empty modifier or key segment",
        error.UnknownModifier => "unknown modifier (use C, M, A, S, or D)",
        error.DuplicateModifier => "modifier repeated",
        error.UnknownKey => "unknown key name",
        error.BadUtf8 => "invalid UTF-8",
        error.BadChar => "character is not encodable",
        error.MultiCodepointToken => "more than one character inside <>",
        else => "invalid notation",
    };
}

fn stdoutWrite(bytes: []const u8) !void {
    try plat.stdoutWriteAll(bytes);
}

fn stdoutPrint(comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(s);
    try plat.stdoutWriteAll(s);
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
        error.DaemonGone => "the daemon stopped running during this command",
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
        // The daemon's reason was printed already.
        error.AttachRefused => "",
        error.InvalidCharacter => "daemon sent a malformed PNG payload",
        error.OutOfMemory => "out of memory",
        else => null,
    };
}
