//! `tuppet sweep`: resize a session through many sizes as its writer and
//! report, size by size, what its program drew and where the texts it was
//! asked to find sit. It reports facts and never judges a layout.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const io_mod = @import("io.zig");
const ipc = @import("ipc.zig");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const names = @import("names.zig");
const plat = @import("plat.zig");
const status = @import("status.zig");
const styles_mod = @import("styles.zig");
const limits = @import("limits.zig");
const units = @import("units.zig");

const Status = status.Status;
const exit_code = client.exit_code;
const cliFail = client.cliFail;
const unknownOption = client.unknownOption;

const usage = "usage: tuppet sweep <session> -s SIZES [--step N] [--find NAME=TEXT]... [--icase] [--settled DUR] [-t DUR] [--refine] [--save DIR] [--view] [--min-size WxH] [--max-time DUR] [-f] [-j], or tuppet sweep -s SIZES [options] [-C DIR] -- <cmd...>";

pub const Size = struct {
    cols: u16,
    rows: u16,

    fn eql(a: Size, b: Size) bool {
        return a.cols == b.cols and a.rows == b.rows;
    }
};

/// A sweep takes at most this many sizes.
pub const max_sizes = 256;
/// Below this a live session is refused unless --min-size lowers it.
const floor: Size = .{ .cols = 20, .rows = 5 };
const default_settled_ms: u64 = 200;
const default_timeout_ms: u64 = 2 * std.time.ms_per_s;
const default_max_ms: u64 = 90 * std.time.ms_per_s;
/// The baseline is read twice at least this far apart.
const min_baseline_ms: u64 = std.time.ms_per_s;
/// How long the daemon may take to answer a resize frame.
const resize_answer_ns: i64 = 5 * std.time.ns_per_s;

pub const Find = struct { name: []const u8, text: []const u8 };

const Options = struct {
    ref: ?[]const u8 = null,
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    sizes: []const Size = &.{},
    step: u16 = 1,
    finds: []const Find = &.{},
    icase: bool = false,
    settled_ms: u64 = default_settled_ms,
    timeout_ms: u64 = default_timeout_ms,
    refine: bool = false,
    save: ?[]const u8 = null,
    view: bool = false,
    min_size: ?Size = null,
    max_ms: u64 = default_max_ms,
    force: bool = false,
    json: bool = false,
};

pub fn cmdSweep(gpa: std.mem.Allocator, args: []const []const u8) !void {
    // Written out, not checkSupported(): the compiler must see that the
    // POSIX code below is unreachable on Windows.
    if (builtin.os.tag == .windows) client.runtimeFail("sweep is not supported on Windows", .{});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const o = try parseArgs(a, args);
    if (o.save) |dir| try prepareDir(a, dir);
    client.installInterruptHandlers();
    var sw: Sweep = .{ .a = a, .o = o };
    const code = sw.run() catch |err| {
        sw.cleanup();
        return err;
    };
    sw.cleanup();
    if (code != exit_code.ok) std.process.exit(code);
}

fn parseArgs(a: std.mem.Allocator, args: []const []const u8) !Options {
    var o: Options = .{};
    var spec: ?[]const u8 = null;
    var finds: std.ArrayList(Find) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            o.argv = args[i + 1 ..];
            break;
        } else if (client.isOpt(arg, "--sizes", "-s")) {
            spec = try client.optValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--step")) {
            const value = try client.optValue(args, &i);
            o.step = protocol.parseDecimal(u16, value) orelse 0;
            if (o.step == 0 or o.step > limits.max_side) return cliFail("invalid --step '{s}' (expected a number of cells, " ++ limits.size_range ++ ")", .{value});
        } else if (std.mem.eql(u8, arg, "--find")) {
            const value = try client.optValue(args, &i);
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse return cliFail("--find '{s}': expected NAME=TEXT", .{value});
            const find: Find = .{ .name = value[0..eq], .text = value[eq + 1 ..] };
            if (names.nameErrorOf(find.name, "the name")) |why| return cliFail("--find '{s}': {s}", .{ value, why });
            if (find.text.len == 0) return cliFail("--find '{s}': the text is empty", .{value});
            if (std.mem.findAny(u8, find.text, "\r\n") != null) return cliFail("--find '{s}': the text cannot contain a line break: a find sits on one row", .{value});
            if (std.ascii.isWhitespace(find.text[find.text.len - 1])) return cliFail("--find '{s}': the text cannot end in a space: rows are read with their trailing spaces trimmed", .{value});
            for (finds.items) |given| if (std.mem.eql(u8, given.name, find.name)) return cliFail("--find {s} is given twice", .{find.name});
            try finds.append(a, find);
        } else if (std.mem.eql(u8, arg, "--icase")) {
            o.icase = true;
        } else if (std.mem.eql(u8, arg, "--settled")) {
            o.settled_ms = try client.waitDuration(args, &i);
        } else if (client.isOpt(arg, "--timeout", "-t")) {
            o.timeout_ms = try client.waitDuration(args, &i);
        } else if (std.mem.eql(u8, arg, "--refine")) {
            o.refine = true;
        } else if (std.mem.eql(u8, arg, "--save")) {
            o.save = try client.absolutePath(a, try client.optValue(args, &i));
        } else if (std.mem.eql(u8, arg, "--view")) {
            o.view = true;
        } else if (std.mem.eql(u8, arg, "--min-size")) {
            const size = try client.parseSize(try client.optValue(args, &i));
            o.min_size = .{ .cols = size[0], .rows = size[1] };
        } else if (std.mem.eql(u8, arg, "--max-time")) {
            o.max_ms = try client.durationValue(args, &i, 1);
            if (o.max_ms > std.time.ms_per_hour) return cliFail("--max-time must be at most 1h", .{});
        } else if (client.isOpt(arg, "--force", "-f")) {
            o.force = true;
        } else if (client.isOpt(arg, "--json", "-j")) {
            o.json = true;
        } else if (client.isOpt(arg, "--cwd", "-C")) {
            o.cwd = try client.optValue(args, &i);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownOption(arg, usage);
        } else if (o.ref != null) {
            return cliFail("unexpected argument '{s}' ({s})", .{ arg, usage });
        } else {
            if (names.refError(arg)) |why| return cliFail("invalid session '{s}': {s}", .{ arg, why });
            o.ref = arg;
        }
    }
    o.finds = finds.items;
    const scratch = o.argv.len > 0;
    if (o.ref != null and scratch) return cliFail("sweep takes a session or a command after --, not both", .{});
    if (o.ref == null and !scratch) return cliFail("{s}", .{usage});
    if (o.cwd != null and !scratch) return cliFail("-C goes with a command after --; a session has its directory", .{});
    if (o.min_size != null and scratch) return cliFail("--min-size lowers the floor of a live session; a sweep of a command has none", .{});
    const given = spec orelse return cliFail("sweep needs -s SIZES, such as -s 60..160x40", .{});
    var why: []const u8 = "";
    o.sizes = parseSizes(a, given, o.step, &why) catch |err| switch (err) {
        error.InvalidSizes => return cliFail("invalid -s '{s}': {s}", .{ given, why }),
        error.OutOfMemory => return err,
    };
    if (!scratch) {
        const least = o.min_size orelse floor;
        for (o.sizes) |size| if (size.cols < least.cols or size.rows < least.rows) {
            refuse("{d}x{d} is below {d}x{d}, the smallest size a sweep gives a live session; --min-size {d}x{d} allows it", .{ size.cols, size.rows, least.cols, least.rows, size.cols, size.rows });
        };
    }
    return o;
}

/// Refuse the sweep (exit 5) before it changed anything.
fn refuse(comptime fmt: []const u8, args: anytype) noreturn {
    client.runtimeFailWith(exit_code.guard, fmt, args);
}

/// The sizes `spec` gives: comma-separated WxH, where either side may be a
/// range A..B taken every `step` cells (B included); both ranges give
/// every pair, the widths first. `why` says what is wrong.
pub fn parseSizes(a: std.mem.Allocator, spec: []const u8, step: u16, why: *[]const u8) error{ InvalidSizes, OutOfMemory }![]const Size {
    var out: std.ArrayList(Size) = .empty;
    var items = std.mem.splitScalar(u8, spec, ',');
    while (items.next()) |item| {
        const x = std.mem.indexOfScalar(u8, item, 'x') orelse {
            why.* = "expected WxH, such as 80x24, 60..160x40, or 80x24,120x40";
            return error.InvalidSizes;
        };
        const widths = try side(a, item[0..x], step, why);
        const heights = try side(a, item[x + 1 ..], step, why);
        for (heights) |rows| for (widths) |cols| {
            const size: Size = .{ .cols = cols, .rows = rows };
            for (out.items) |had| if (had.eql(size)) {
                why.* = try std.fmt.allocPrint(a, "{d}x{d} comes twice", .{ cols, rows });
                return error.InvalidSizes;
            };
            if (out.items.len == max_sizes) {
                why.* = std.fmt.comptimePrint("a sweep takes at most {d} sizes (a larger --step takes fewer)", .{max_sizes});
                return error.InvalidSizes;
            }
            try out.append(a, size);
        };
    }
    return out.items;
}

/// The values of one side of WxH: N, or A..B every `step` with B last.
fn side(a: std.mem.Allocator, text: []const u8, step: u16, why: *[]const u8) error{ InvalidSizes, OutOfMemory }![]const u16 {
    const dots = std.mem.indexOf(u8, text, "..");
    const lo = sideCells(if (dots) |d| text[0..d] else text) orelse {
        why.* = "each side is a number " ++ limits.size_range ++ " or a range A..B of them";
        return error.InvalidSizes;
    };
    const hi = if (dots) |d| sideCells(text[d + 2 ..]) orelse {
        why.* = "each side is a number " ++ limits.size_range ++ " or a range A..B of them";
        return error.InvalidSizes;
    } else lo;
    var out: std.ArrayList(u16) = .empty;
    var v: i32 = lo;
    const dir: i32 = if (hi >= lo) step else -@as(i32, step);
    while ((dir > 0 and v < hi) or (dir < 0 and v > hi)) : (v += dir) {
        if (out.items.len == max_sizes) break;
        try out.append(a, @intCast(v));
    }
    try out.append(a, hi);
    return out.items;
}

fn sideCells(text: []const u8) ?u16 {
    const n = protocol.parseDecimal(u16, text) orelse return null;
    return if (n >= 1 and n <= limits.max_side) n else null;
}

/// --save needs a directory of its own: a new one, or one that is empty.
fn prepareDir(a: std.mem.Allocator, path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const z = try a.dupeSentinel(u8, path, 0);
    const rc = std.c.mkdir(z, 0o700);
    if (rc == 0) return;
    if (std.posix.errno(rc) != .EXIST) return cliFail("--save {s}: cannot create the directory", .{path});
    const dir = std.c.opendir(z) orelse return cliFail("--save {s}: not a directory", .{path});
    defer _ = std.c.closedir(dir);
    while (std.c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        return cliFail("--save {s}: the directory is not empty; give a new or an empty one", .{path});
    }
}

// ---- finds -------------------------------------------------------------

pub const State = enum { at, absent, prefix, split };

/// Where a find's text sits at one size. Cells count from 1: `col` from
/// the left edge to its first cell, `right` from the right edge to its
/// last. `prefix` is the part found for `prefix` and `split`.
pub const Spot = struct {
    state: State = .absent,
    row: ?u16 = null,
    col: ?u16 = null,
    right: ?u16 = null,
    prefix: ?[]const u8 = null,
    count: u32 = 0,
    /// The row did not change after the resize: what is there is the
    /// terminal's leftover, not the program's layout. Null without a
    /// resize and for an absent text.
    stale: ?bool = null,
};

/// Where a find sat at a neighbouring size.
pub const Anchor = struct { row: u16, col: u16, cols: u16 };

/// The cells a codepoint takes, as Ghostty counts them.
fn cpWidth(cp: u21) u32 {
    return vt.unicode.codepointWidth(cp);
}

/// The cells `s` takes.
pub fn cellsOf(s: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const cp = if (i + len <= s.len) std.unicode.utf8Decode(s[i..][0..len]) catch null else null;
        n += if (cp) |c| cpWidth(c) else 1;
        i += if (cp != null) len else 1;
    }
    return n;
}

/// The byte where cell `cell` (from 0) of `line` starts; null inside a
/// wide character or past the end.
fn byteAtCell(line: []const u8, cell: u32) ?usize {
    var n: u32 = 0;
    var i: usize = 0;
    while (true) {
        // Zero-width codepoints belong to the cell before them.
        while (i < line.len) {
            const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            const cp = if (i + len <= line.len) std.unicode.utf8Decode(line[i..][0..len]) catch null else null;
            if (cp == null or cpWidth(cp.?) != 0 or i == 0) break;
            i += len;
        }
        if (n == cell) return i;
        if (n > cell or i >= line.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const cp = if (i + len <= line.len) std.unicode.utf8Decode(line[i..][0..len]) catch null else null;
        n += if (cp) |c| cpWidth(c) else 1;
        i += if (cp != null) len else 1;
    }
}

fn startsWith(haystack: []const u8, needle: []const u8, icase: bool) bool {
    return if (icase) std.ascii.startsWithIgnoreCase(haystack, needle) else std.mem.startsWith(u8, haystack, needle);
}

fn findFrom(line: []const u8, from: usize, text: []const u8, icase: bool) ?usize {
    if (!icase) return std.mem.indexOfPos(u8, line, from, text);
    var i = from;
    while (i + text.len <= line.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(line[i..], text)) return i;
    }
    return null;
}

/// Counted from 1 at the right edge: the cell of `width` cells starting
/// at `col` ends there.
fn rightOf(cols: u16, col: u32, width: u32) u16 {
    const end = col + width -| 1;
    return @intCast(@max(1, @as(i64, cols) + 1 - @as(i64, end)));
}

/// The first place `text` sits on `lines` in reading order, and how often
/// it does; absent when it does not.
pub fn locate(lines: []const []const u8, cols: u16, text: []const u8, icase: bool) Spot {
    var spot: Spot = .{};
    for (lines, 0..) |line, r| {
        var from: usize = 0;
        while (findFrom(line, from, text, icase)) |at| {
            if (spot.count == 0) {
                const col = cellsOf(line[0..at]) + 1;
                spot = .{ .state = .at, .row = @intCast(r + 1), .col = @intCast(col), .right = rightOf(cols, col, cellsOf(text)) };
            }
            spot.count += 1;
            from = at + text.len;
        }
    }
    return spot;
}

/// For a text that is absent: its first part where `anchor` had the text,
/// on the same row at the same distance from the left or the right edge.
/// `split` when the rest continues at the first non-blank cell of the
/// next row; `prefix` when the part has at least max(3, half) of the
/// text's characters; else absent.
pub fn near(lines: []const []const u8, cols: u16, text: []const u8, icase: bool, anchor: Anchor) Spot {
    if (anchor.row == 0 or anchor.row > lines.len) return .{};
    const line = lines[anchor.row - 1];
    var starts: [2]u32 = .{ anchor.col, 0 };
    var n: usize = 1;
    const from_right = @as(i64, cols) - (@as(i64, anchor.cols) - anchor.col);
    if (from_right >= 1 and from_right != anchor.col) {
        starts[1] = @intCast(from_right);
        n = 2;
    }
    for (starts[0..n]) |start| {
        const off = byteAtCell(line, start - 1) orelse continue;
        const part = line[off..];
        if (part.len == 0 or part.len >= text.len or !startsWith(text, part, icase)) continue;
        const rest = std.mem.trimStart(u8, text[part.len..], " ");
        if (rest.len == 0 or anchor.row >= lines.len) continue;
        if (!startsWith(std.mem.trimStart(u8, lines[anchor.row], " "), rest, icase)) continue;
        return .{ .state = .split, .row = anchor.row, .col = @intCast(start), .right = rightOf(cols, start, cellsOf(part)), .prefix = part, .count = 1 };
    }
    const total = std.unicode.utf8CountCodepoints(text) catch text.len;
    const least = @max(3, (total + 1) / 2);
    var best: Spot = .{};
    var best_len: usize = 0;
    for (starts[0..n]) |start| {
        const off = byteAtCell(line, start - 1) orelse continue;
        const there = line[off..];
        var k: usize = 0;
        while (k < text.len and k < there.len) : (k += 1) {
            const same = if (icase) std.ascii.toLower(text[k]) == std.ascii.toLower(there[k]) else text[k] == there[k];
            if (!same) break;
        }
        // Whole characters only.
        while (k > 0 and k < text.len and text[k] & 0xc0 == 0x80) k -= 1;
        const chars = std.unicode.utf8CountCodepoints(text[0..k]) catch k;
        if (chars < least or k >= text.len or k <= best_len) continue;
        best_len = k;
        best = .{ .state = .prefix, .row = anchor.row, .col = @intCast(start), .right = rightOf(cols, start, cellsOf(text[0..k])), .prefix = text[0..k], .count = 1 };
    }
    return best;
}

fn anchorOf(spot: Spot, cols: u16) ?Anchor {
    if (spot.state == .absent) return null;
    return .{ .row = spot.row.?, .col = spot.col.?, .cols = cols };
}

// ---- the attach stream ---------------------------------------------------

/// The sweep's attach stream, read on its own thread all the time, so the
/// daemon never finds it too slow and every frame is seen as it comes.
const Stream = struct {
    conn: ipc.Conn,
    mutex: std.Io.Mutex = .init,
    /// Counts frames, for waiters.
    frames: std.atomic.Value(u32) = .init(0),
    // Under the mutex:
    out_bytes: u64 = 0,
    last_out_ns: i64 = 0,
    resizes: std.ArrayList(Resize) = .empty,
    errors: u32 = 0,
    error_buf: [200]u8 = undefined,
    error_len: usize = 0,
    exit_buf: [48]u8 = undefined,
    exit_len: ?usize = null,
    end_buf: [32]u8 = undefined,
    end_len: ?usize = null,
    taken: bool = false,
    closed: bool = false,

    const Resize = struct {
        cols: u16,
        rows: u16,
        /// Null when the size stayed.
        seq: ?u64,
        /// out_bytes when it came.
        bytes_before: u64,
        at_ns: i64,
    };

    /// What the stream has brought so far.
    const Seen = struct {
        frames: u32 = 0,
        resizes: usize = 0,
        errors: u32 = 0,
        error_buf: [200]u8 = undefined,
        error_len: usize = 0,
        exit_buf: [48]u8 = undefined,
        exit_len: ?usize = null,
        end_buf: [32]u8 = undefined,
        end_len: ?usize = null,
        taken: bool = false,
        closed: bool = false,

        fn errorText(x: *const Seen) []const u8 {
            return x.error_buf[0..x.error_len];
        }

        fn exit(x: *const Seen) ?[]const u8 {
            return if (x.exit_len) |n| x.exit_buf[0..n] else null;
        }

        fn end(x: *const Seen) ?[]const u8 {
            return if (x.end_len) |n| x.end_buf[0..n] else null;
        }
    };

    const page = std.heap.page_allocator;

    fn readLoop(s: *Stream, pending: []const u8) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(page);
        buf.appendSlice(page, pending) catch {};
        var chunk: [65536]u8 = undefined;
        while (true) {
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, buf.items, start, '\n')) |end| {
                s.frame(buf.items[start..end]);
                start = end + 1;
            }
            buf.replaceRange(page, 0, start, &.{}) catch break;
            const n = std.c.read(s.conn.posix.socket.handle, &chunk, chunk.len);
            if (n <= 0) {
                if (n < 0 and std.posix.errno(n) == .INTR) continue;
                break;
            }
            buf.appendSlice(page, chunk[0..@intCast(n)]) catch break;
        }
        s.lock();
        s.closed = true;
        s.unlock();
        s.bump();
    }

    fn lock(s: *Stream) void {
        s.mutex.lockUncancelable(io_mod.io());
    }

    fn unlock(s: *Stream) void {
        s.mutex.unlock(io_mod.io());
    }

    fn bump(s: *Stream) void {
        _ = s.frames.fetchAdd(1, .acq_rel);
        io_mod.io().futexWake(u32, &s.frames.raw, std.math.maxInt(u32));
    }

    const Frame = struct {
        resize: ?struct { cols: u16 = 0, rows: u16 = 0, seq: ?u64 = null } = null,
        exit: ?struct { code: ?i32 = null, signal: ?[]const u8 = null, stopped: bool = false } = null,
        writer: ?[]const u8 = null,
        @"error": ?struct { code: []const u8 = "", err: []const u8 = "" } = null,
        end: ?struct { reason: []const u8 = "" } = null,
    };

    fn frame(s: *Stream, line: []const u8) void {
        const now = io_mod.nowNanos();
        const out_prefix = "{\"out\":\"";
        if (std.mem.startsWith(u8, line, out_prefix) and std.mem.endsWith(u8, line, "\"}")) {
            const n = std.base64.standard.Decoder.calcSizeForSlice(line[out_prefix.len .. line.len - 2]) catch 0;
            s.lock();
            s.out_bytes += n;
            s.last_out_ns = now;
            s.unlock();
            return s.bump();
        }
        // A full redraw for the writer after each resize; not output.
        if (std.mem.startsWith(u8, line, "{\"screen\":")) return;
        var arena = std.heap.ArenaAllocator.init(page);
        defer arena.deinit();
        const f = std.json.parseFromSliceLeaky(Frame, arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch return;
        s.lock();
        if (f.resize) |r| s.resizes.append(page, .{ .cols = r.cols, .rows = r.rows, .seq = r.seq, .bytes_before = s.out_bytes, .at_ns = now }) catch {
            s.closed = true;
        };
        if (f.exit) |e| {
            var w: std.Io.Writer = .fixed(&s.exit_buf);
            if (e.stopped) {
                w.writeAll("exit=stopped") catch {};
            } else if (e.code) |code| {
                w.print("exit={d}", .{code}) catch {};
            } else w.print("exit={s}", .{e.signal orelse "-"}) catch {};
            s.exit_len = w.end;
        }
        if (f.writer != null) s.taken = true;
        if (f.@"error") |e| {
            s.errors += 1;
            s.error_len = @min(e.err.len, s.error_buf.len);
            @memcpy(s.error_buf[0..s.error_len], e.err[0..s.error_len]);
        }
        if (f.end) |e| {
            const n = @min(e.reason.len, s.end_buf.len);
            @memcpy(s.end_buf[0..n], e.reason[0..n]);
            s.end_len = n;
        }
        s.unlock();
        s.bump();
    }

    /// A copy of what the stream brought.
    fn seen(s: *Stream) Seen {
        s.lock();
        defer s.unlock();
        var x: Seen = .{
            .frames = s.frames.load(.acquire),
            .resizes = s.resizes.items.len,
            .errors = s.errors,
            .error_len = s.error_len,
            .exit_len = s.exit_len,
            .end_len = s.end_len,
            .taken = s.taken,
            .closed = s.closed,
        };
        x.error_buf = s.error_buf;
        x.exit_buf = s.exit_buf;
        x.end_buf = s.end_buf;
        return x;
    }

    fn resizeAt(s: *Stream, i: usize) Resize {
        s.lock();
        defer s.unlock();
        return s.resizes.items[i];
    }

    /// The bytes of output after `r` came.
    fn bytesAfter(s: *Stream, r: Resize) u64 {
        s.lock();
        defer s.unlock();
        return s.out_bytes - r.bytes_before;
    }

    /// Output came after `r`, and then none for `ms`.
    fn quietAfter(s: *Stream, r: Resize, ms: u64) bool {
        s.lock();
        defer s.unlock();
        if (s.out_bytes == r.bytes_before) return false;
        return io_mod.nowNanos() - s.last_out_ns >= @as(i64, @intCast(ms)) * std.time.ns_per_ms;
    }

    /// Wait until a frame after `frames` came, at most `ms`.
    fn waitFrame(s: *Stream, frames: u32, ms: u64) void {
        io_mod.io().futexWaitTimeout(u32, &s.frames.raw, frames, .{
            .duration = .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .boot },
        }) catch {};
    }
};

// ---- the sweep ------------------------------------------------------------

const Screen = enum { same_size, changed, unchanged, wrote_nothing, still_changing, ended };

const Sample = struct {
    size: Size,
    screen: Screen = .same_size,
    /// Rows that changed after the resize's reflow, of `size.rows`.
    rows_changed: u32 = 0,
    /// Output after the resize.
    bytes: u64 = 0,
    /// For `ended`: exit=N.
    exit: []const u8 = "",
    late: bool = false,
    blank: bool = false,
    resize_seq: ?u64 = null,
    /// The seq of the read.
    seq: u64 = 0,
    text: []const u8 = "",
    /// The rows that changed after the resize's reflow.
    changed: []const i64 = &.{},
    spots: []Spot = &.{},
};

const StopCode = enum { max_time, interrupted, ended, removed, taken, input, resize, stream, failed };

const Stop = struct {
    code: StopCode,
    why: []const u8,
};

/// The screen before the sweep, the rows that change on their own, and
/// where the finds sat.
const Baseline = struct {
    text: []const u8 = "",
    styles: protocol.Styles = .{},
    own_rows: []const i64 = &.{},
    spots: []Spot = &.{},
};

const Abort = error{ Stopped, Ended };

const Settle = enum { met, quiet, timeout };

const Sweep = struct {
    a: std.mem.Allocator,
    o: Options,
    id: u64 = 0,
    ref: []const u8 = "",
    /// Started for this sweep, and removed after it.
    scratch: bool = false,
    stream: ?*Stream = null,
    reader: ?std.Thread = null,
    start: Status = .{},
    start_size: Size = .{ .cols = 0, .rows = 0 },
    input_seq: ?u64 = null,
    resize_seq: ?u64 = null,
    resizes_seen: usize = 0,
    errors_seen: u32 = 0,
    started_ns: i64 = 0,
    /// --max-time counts while set.
    deadline_ns: ?i64 = null,
    samples: std.ArrayList(Sample) = .empty,
    /// Samples before this one are final and reported.
    finalized: usize = 0,
    /// The sample measured last, whose late check is due.
    last: ?usize = null,
    stop: ?Stop = null,
    baseline: Baseline = .{},
    /// The baseline was read, so the way back can be compared with it.
    based: bool = false,
    final: ?Status = null,
    report: Report = .{},

    fn run(sw: *Sweep) !u8 {
        sw.started_ns = io_mod.nowNanos();
        sw.begin() catch |err| switch (err) {
            error.Ended => {
                try stderrPrint("tuppet: session {d} ended before the sweep began\n", .{sw.id});
                return exit_code.ended;
            },
            else => return err,
        };
        sw.deadline_ns = sw.started_ns + @as(i64, @intCast(sw.o.max_ms)) * std.time.ns_per_ms;
        try sw.estimate();
        sw.prepare() catch |err| switch (err) {
            error.Stopped => {},
            error.Ended => sw.note(.ended, "the program ended before the sweep began", .{}),
            else => return err,
        };
        sw.report.init(sw);
        if (sw.stop == null) sw.sizes() catch |err| switch (err) {
            error.Stopped => {},
            else => return err,
        };
        // The last sample's late check is due before it is reported.
        if (sw.stop == null or sw.stop.?.code == .max_time) sw.lateCheck() catch |err| switch (err) {
            error.Stopped => {},
            error.Ended => sw.note(.ended, "the program ended", .{}),
        };
        try sw.finalizeUpTo(sw.samples.items.len);
        try sw.report.close(sw);
        sw.deadline_ns = null;
        var back: ?Back = null;
        if (sw.based and (sw.stop == null or sw.stop.?.code == .max_time)) back = sw.goBack() catch |err| switch (err) {
            error.Stopped => null,
            error.Ended => blk: {
                sw.note(.ended, "the program ended on the way back", .{});
                break :blk null;
            },
            else => return err,
        };
        try sw.summary(back);
        const stop = sw.stop orelse return exit_code.ok;
        return switch (stop.code) {
            .max_time => exit_code.ok,
            .ended, .removed => exit_code.ended,
            .interrupted => 128 + client.interrupt_signal.load(.acquire),
            else => exit_code.failed,
        };
    }

    /// Start the scratch session, or check the session; attach as its
    /// writer. Refusals end the command.
    fn begin(sw: *Sweep) !void {
        if (sw.o.argv.len > 0) {
            var cols = client.default_cols;
            var rows = client.default_rows;
            if (std.c.getenv("TUPPET_SIZE")) |env| {
                const value = std.mem.span(env);
                const size = client.sizeValue(value) orelse return cliFail("invalid TUPPET_SIZE '{s}' (expected WxH, each 1..1000)", .{value});
                cols = size[0];
                rows = size[1];
            }
            const env = try client.currentEnv(sw.a, true);
            const req: protocol.RunReq = .{ .argv = sw.o.argv, .cols = cols, .rows = rows, .cwd = try client.absolutePath(sw.a, sw.o.cwd orelse "."), .env = env };
            const reply = try client.request(sw.a, req, protocol.StatusResp);
            if (!reply.parsed.value.ok) failed(sw.a, reply.line);
            sw.scratch = true;
            sw.id = reply.parsed.value.status.?.id;
            sw.ref = try std.fmt.allocPrint(sw.a, "{d}", .{sw.id});
        } else {
            const listed = try client.request(sw.a, protocol.ListReq{ .sessions = &.{sw.o.ref.?} }, protocol.ListResp);
            if (!listed.parsed.value.ok) failed(sw.a, listed.line);
            const st = try client.onlyOne(sw.a, sw.o.ref.?, listed.parsed.value.sessions);
            sw.id = st.id;
            sw.ref = try std.fmt.allocPrint(sw.a, "{d}", .{sw.id});
            if (st.state != .running) client.runtimeFailWith(exit_code.ended, "session {d} has ended; a sweep needs a running program", .{st.id});
            if (st.writer) |w| refuseWriter(st.id, w.label);
            sw.checkWatchers(st);
        }
        try sw.attach();
    }

    fn checkWatchers(sw: *Sweep, st: Status) void {
        if (sw.scratch or sw.o.force or (st.viewers == 0 and st.previews == 0)) return;
        if (sw.stream) |s| s.conn.sendLine("{\"detach\":true}") catch {};
        refuse("session {d} has viewers or previews attached ({d} and {d}), who would see every size; -f sweeps anyway", .{ st.id, st.viewers, st.previews });
    }

    fn attach(sw: *Sweep) !void {
        var conn = try client.connect(sw.a);
        errdefer conn.deinit();
        try client.sendRequest(sw.a, &conn, protocol.AttachReq{ .session = sw.ref, .mode = .write, .label = "sweep" });
        const split = try conn.recvLineSplit(sw.a, client.max_reply);
        const reply = try client.parseReply(sw.a, protocol.StatusResp, split.line);
        if (!reply.parsed.value.ok) {
            sw.cleanup();
            const failure = std.json.parseFromSliceLeaky(protocol.ErrorReply, sw.a, reply.line, .{ .ignore_unknown_fields = true }) catch
                client.runtimeFail("the daemon sent a malformed reply", .{});
            if (std.mem.eql(u8, failure.code, @tagName(protocol.Code.busy))) {
                const label = if (failure.status) |st| if (st.writer) |w| w.label else null else null;
                refuseWriter(sw.id, label);
            }
            failed(sw.a, reply.line);
        }
        const st = reply.parsed.value.status.?;
        var no_timeout: std.posix.timeval = .{ .sec = 0, .usec = 0 };
        _ = std.c.setsockopt(conn.posix.socket.handle, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&no_timeout), @sizeOf(std.posix.timeval));
        const s = try sw.a.create(Stream);
        s.* = .{ .conn = conn };
        sw.stream = s;
        // The reply counts this attach: a viewer that came meanwhile is
        // in it.
        sw.checkWatchers(st);
        sw.reader = try std.Thread.spawn(.{}, Stream.readLoop, .{ s, split.rest });
        sw.start = st;
        sw.start_size = .{ .cols = st.cols, .rows = st.rows };
        sw.input_seq = st.input_seq;
        sw.resize_seq = st.resize_seq;
        if (st.state != .running) return error.Ended;
    }

    /// Detach, which gives the session back the size it had unless a
    /// resize request set one since, and remove a scratch session.
    fn cleanup(sw: *Sweep) void {
        if (sw.stream) |s| {
            s.conn.sendLine("{\"detach\":true}") catch {};
            _ = std.c.shutdown(s.conn.posix.socket.handle, 2);
            if (sw.reader) |t| t.join();
            s.conn.deinit();
            sw.stream = null;
        }
        if (sw.scratch) {
            sw.scratch = false;
            if (client.request(std.heap.page_allocator, protocol.RemoveReq{ .sessions = &.{sw.ref}, .force = true }, protocol.ResultsResp)) |reply| reply.deinit() else |_| {}
        }
    }

    /// An estimate to a tenth of a second, or a second from a minute.
    fn rounded(ms: u64) u64 {
        const unit: u64 = if (ms < std.time.ms_per_s) 1 else if (ms < std.time.ms_per_min) 100 else 1000;
        return ms / unit * unit;
    }

    fn estimate(sw: *Sweep) !void {
        const n = sw.o.sizes.len;
        const fixed = @max(sw.o.settled_ms, min_baseline_ms) + sw.o.settled_ms;
        const low = fixed + n * sw.o.settled_ms;
        const high = fixed + sw.o.timeout_ms + n * (sw.o.timeout_ms + 50);
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        var b3: [32]u8 = undefined;
        const tail = if (high > sw.o.max_ms) try std.fmt.allocPrint(sw.a, "; --max-time {s} ends it sooner", .{units.durationText(&b3, sw.o.max_ms)}) else "";
        try stderrPrint("tuppet: sweeping session {d} through {d} sizes takes {s} to {s}{s}\n", .{ sw.id, n, units.durationText(&b1, rounded(low)), units.durationText(&b2, rounded(high)), tail });
    }

    /// The scratch session's first screen, then the baseline: two reads
    /// max(--settled, 1s) apart, so the rows that change on their own are
    /// known.
    fn prepare(sw: *Sweep) !void {
        if (sw.scratch) _ = try sw.settle(sw.start.start_seq, null);
        const first = try sw.view(null, false);
        const pause_until = io_mod.nowNanos() + @as(i64, @intCast(@max(sw.o.settled_ms, min_baseline_ms))) * std.time.ns_per_ms;
        while (io_mod.nowNanos() < pause_until) {
            const seen = try sw.check();
            sw.stream.?.waitFrame(seen.frames, 20);
        }
        const moved = try sw.view(first.status.?.seq, false);
        const second = try sw.view(null, true);
        sw.baseline = .{ .text = second.text, .styles = second.styles orelse .{}, .own_rows = try screenRows(sw.a, moved.rows) };
        const lines = try splitLines(sw.a, second.text);
        sw.baseline.spots = try sw.a.alloc(Spot, sw.o.finds.len);
        for (sw.o.finds, sw.baseline.spots) |find, *spot| spot.* = locate(lines, sw.start_size.cols, find.text, sw.o.icase);
        for (sw.o.finds, sw.baseline.spots) |find, spot| if (spot.state == .absent) {
            stderrPrint("tuppet: find {s}: '{s}' is not on the screen at {d}x{d}, where the sweep starts\n", .{ find.name, find.text, sw.start_size.cols, sw.start_size.rows }) catch {};
        };
        sw.based = true;
        if (sw.o.save) |dir| try sw.save(dir, "baseline", second.text, second.styles);
    }

    fn oom(sw: *Sweep) Abort {
        return sw.halt(.failed, "out of memory", .{});
    }

    /// Every size, with --refine the edges between them.
    fn sizes(sw: *Sweep) !void {
        for (sw.o.sizes) |size| {
            try sw.measureAt(sw.samples.items.len, size);
            const at = sw.samples.items.len - 1;
            if (sw.samples.items[at].screen == .ended) return sw.halt(.ended, "the program ended", .{});
            if (sw.o.refine and at > 0) {
                _ = try sw.bisect(at - 1);
            }
            // Every sample before the newest has both its neighbours; the
            // one measured last waits for its late check too.
            try sw.finalizeUpTo(@min(sw.samples.items.len - 1, sw.last orelse sw.samples.items.len));
        }
    }

    /// Measure between samples `lo` and `lo + 1` while their facts differ
    /// and a size lies between them; how many samples it added.
    fn bisect(sw: *Sweep, lo: usize) !usize {
        const x = sw.samples.items[lo];
        const y = sw.samples.items[lo + 1];
        if (x.screen == .ended or y.screen == .ended or sameFacts(x, y)) return 0;
        const mid: Size = if (x.size.rows == y.size.rows and absDiff(x.size.cols, y.size.cols) > 1)
            .{ .cols = @intCast((@as(u32, x.size.cols) + y.size.cols) / 2), .rows = x.size.rows }
        else if (x.size.cols == y.size.cols and absDiff(x.size.rows, y.size.rows) > 1)
            .{ .cols = x.size.cols, .rows = @intCast((@as(u32, x.size.rows) + y.size.rows) / 2) }
        else
            return 0;
        for (sw.samples.items) |s| if (s.size.eql(mid)) return 0;
        try sw.measureAt(lo + 1, mid);
        if (sw.samples.items[lo + 1].screen == .ended) return sw.halt(.ended, "the program ended", .{});
        const left = try sw.bisect(lo);
        const right = try sw.bisect(lo + 1 + left);
        return 1 + left + right;
    }

    /// Measure `size` and insert the sample at `at`.
    fn measureAt(sw: *Sweep, at: usize, size: Size) !void {
        // An end seen before the resize belongs to no new size.
        sw.lateCheck() catch |err| switch (err) {
            error.Ended => return sw.halt(.ended, "the program ended", .{}),
            else => return err,
        };
        _ = sw.check() catch |err| switch (err) {
            error.Ended => return sw.halt(.ended, "the program ended", .{}),
            else => return err,
        };
        const sample = sw.measure(size) catch |err| switch (err) {
            error.Ended => try sw.endedSample(size),
            else => return err,
        };
        try sw.samples.insert(sw.a, at, sample);
        sw.last = at;
    }

    /// Resize, wait for the program to settle, and read what it drew.
    fn measure(sw: *Sweep, size: Size) !Sample {
        var sample: Sample = .{ .size = size };
        const own = try sw.resizeTo(size);
        sample.resize_seq = own.seq;
        var how: Settle = .met;
        if (own.seq) |seq| how = try sw.settle(seq, own);
        const read = try sw.view(null, sw.o.save != null);
        sample.text = read.text;
        sample.seq = read.status.?.seq orelse 0;
        sample.bytes = sw.stream.?.bytesAfter(own);
        if (own.seq) |seq| {
            const since = try sw.view(seq, false);
            sample.changed = try screenRows(sw.a, since.rows);
            sample.rows_changed = @intCast(sample.changed.len);
            sample.screen = switch (how) {
                .met => .changed,
                .quiet => if (sample.changed.len > 0) .changed else .unchanged,
                .timeout => if (sample.changed.len > 0) .still_changing else if (sample.bytes > 0) .unchanged else .wrote_nothing,
            };
        }
        sample.blank = std.mem.trim(u8, sample.text, " \n").len == 0;
        const lines = try splitLines(sw.a, sample.text);
        sample.spots = try sw.a.alloc(Spot, sw.o.finds.len);
        for (sw.o.finds, sample.spots) |find, *spot| spot.* = locate(lines, size.cols, find.text, sw.o.icase);
        if (sw.o.save) |dir| {
            const name = try std.fmt.allocPrint(sw.a, "{d}x{d}", .{ size.cols, size.rows });
            try sw.save(dir, name, read.text, read.styles);
        }
        return sample;
    }

    fn endedSample(sw: *Sweep, size: Size) !Sample {
        const seen = sw.stream.?.seen();
        var sample: Sample = .{ .size = size, .screen = .ended, .exit = try sw.a.dupe(u8, seen.exit() orelse "exit=-") };
        if (client.request(sw.a, protocol.ViewReq{ .session = sw.ref }, protocol.ViewResp)) |reply| {
            if (reply.parsed.value.ok) {
                sample.text = reply.parsed.value.text;
                if (seen.exit() == null) if (reply.parsed.value.status) |st| {
                    sample.exit = try exitText(sw.a, st.exit);
                };
            }
        } else |_| {}
        const lines = try splitLines(sw.a, sample.text);
        sample.spots = try sw.a.alloc(Spot, sw.o.finds.len);
        for (sw.o.finds, sample.spots) |find, *spot| spot.* = locate(lines, size.cols, find.text, sw.o.icase);
        return sample;
    }

    /// Before the next resize: whether the screen changed after the last
    /// sample's read.
    fn lateCheck(sw: *Sweep) Abort!void {
        const at = sw.last orelse return;
        sw.last = null;
        const sample = &sw.samples.items[at];
        if (sample.screen == .ended) return;
        const since = try sw.view(sample.seq, false);
        for (since.rows orelse &.{}) |row| if (row >= 1) {
            sample.late = true;
        };
    }

    /// Resize through the stream and take the seq of its own resize frame.
    fn resizeTo(sw: *Sweep, size: Size) Abort!Stream.Resize {
        const s = sw.stream.?;
        var buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"resize\":{{\"cols\":{d},\"rows\":{d}}}}}", .{ size.cols, size.rows }) catch unreachable;
        s.conn.sendLine(line) catch return sw.halt(.stream, "the daemon closed the stream", .{});
        const sent = io_mod.nowNanos();
        while (true) {
            const seen = s.seen();
            if (seen.resizes > sw.resizes_seen) {
                const r = s.resizeAt(sw.resizes_seen);
                sw.resizes_seen += 1;
                if (r.cols != size.cols or r.rows != size.rows) return sw.halt(.resize, "another client resized the session to {d}x{d}", .{ r.cols, r.rows });
                if (r.seq) |seq| sw.resize_seq = seq;
                return r;
            }
            if (seen.errors > sw.errors_seen) return sw.halt(.failed, "the resize to {d}x{d} failed: {s}", .{ size.cols, size.rows, seen.errorText() });
            _ = try sw.check();
            if (io_mod.nowNanos() - sent > resize_answer_ns) return sw.halt(.failed, "the daemon did not answer the resize to {d}x{d}", .{ size.cols, size.rows });
            s.waitFrame(seen.frames, 20);
        }
    }

    /// Wait until the screen changed after `since` and settled, within -t.
    /// With `own`, the resize it follows: output after it and then none
    /// for --settled ends the wait too (a redraw of the same text changes
    /// nothing, so the settle would wait for the deadline).
    fn settle(sw: *Sweep, since: u64, own: ?Stream.Resize) Abort!Settle {
        var conn = client.connect(sw.a) catch |err| return sw.halt(.failed, "{s}", .{client.errorText(err) orelse @errorName(err)});
        defer conn.deinit();
        const until = [_]protocol.Condition{.{ .since = since, .settled_ms = sw.o.settled_ms }};
        client.sendRequest(sw.a, &conn, protocol.WaitReq{ .session = sw.ref, .until = &until, .timeout_ms = sw.o.timeout_ms }) catch |err|
            return sw.halt(.failed, "{s}", .{client.errorText(err) orelse @errorName(err)});
        const fd = conn.posix.socket.handle;
        while (true) {
            _ = try sw.check();
            if (own) |r| if (sw.stream.?.quietAfter(r, sw.o.settled_ms)) return .quiet;
            var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&pfd, 1, 10) <= 0) continue;
            const split = conn.recvLineAfter(sw.a, client.max_reply, "", ipc.request_timeout_ns) catch |err|
                return sw.halt(.failed, "{s}", .{client.errorText(err) orelse @errorName(err)});
            const reply = client.parseReply(sw.a, protocol.WaitResp, split.line) catch return sw.oom();
            const r = reply.parsed.value;
            if (!r.ok) return sw.refused(reply.line);
            if (r.status) |st| try sw.checkStatus(st);
            return switch (r.outcome) {
                .met => .met,
                .timeout => .timeout,
                .ended => error.Ended,
                .removed => sw.halt(.removed, "the session was removed", .{}),
            };
        }
    }

    const Read = struct {
        text: []const u8,
        rows: ?[]const i64,
        styles: ?protocol.Styles,
        status: ?Status,
    };

    /// The screen, or with `since` the lines that changed after it.
    fn view(sw: *Sweep, since: ?u64, styles: bool) Abort!Read {
        const reply = client.request(sw.a, protocol.ViewReq{ .session = sw.ref, .since = since, .styles = styles }, protocol.ViewResp) catch |err|
            return sw.halt(.failed, "{s}", .{client.errorText(err) orelse @errorName(err)});
        const r = reply.parsed.value;
        if (!r.ok) return sw.refused(reply.line);
        try sw.checkStatus(r.status.?);
        return .{ .text = r.text, .rows = r.rows, .styles = r.styles, .status = r.status };
    }

    /// Stop on another client's input or resize, and on the end.
    fn checkStatus(sw: *Sweep, st: Status) Abort!void {
        sw.final = st;
        if (st.state != .running) return error.Ended;
        if (!std.meta.eql(st.input_seq, sw.input_seq)) return sw.halt(.input, "another client typed into the session (input_seq {d})", .{st.input_seq orelse 0});
        if (!std.meta.eql(st.resize_seq, sw.resize_seq)) return sw.halt(.resize, "another client resized the session", .{});
    }

    /// What ends the sweep early, checked while it waits.
    fn check(sw: *Sweep) Abort!Stream.Seen {
        const sig = client.interrupt_signal.load(.acquire);
        if (sig != 0) return sw.halt(.interrupted, "interrupted", .{});
        if (sw.deadline_ns) |d| if (io_mod.nowNanos() >= d) {
            var buf: [32]u8 = undefined;
            return sw.halt(.max_time, "--max-time {s} ran out", .{units.durationText(&buf, sw.o.max_ms)});
        };
        const s = sw.stream.?;
        const seen = s.seen();
        if (seen.exit() != null) return error.Ended;
        if (seen.taken) return sw.halt(.taken, "another client took over writing (attach -f)", .{});
        if (seen.errors > sw.errors_seen) return sw.halt(.failed, "the daemon refused a frame: {s}", .{seen.errorText()});
        if (seen.resizes > sw.resizes_seen) {
            const r = s.resizeAt(sw.resizes_seen);
            return sw.halt(.resize, "another client resized the session to {d}x{d}", .{ r.cols, r.rows });
        }
        if (seen.end()) |reason| {
            if (std.mem.eql(u8, reason, "shutdown")) return sw.halt(.ended, "the daemon is shutting down", .{});
            if (std.mem.eql(u8, reason, "too_slow")) return sw.halt(.stream, "the daemon ended the stream: the sweep read it too slowly", .{});
            return sw.halt(.stream, "the daemon ended the stream ({s})", .{reason});
        }
        if (seen.closed) return sw.halt(.stream, "the daemon closed the stream", .{});
        return seen;
    }

    /// A failed reply, as a reason to stop.
    fn refused(sw: *Sweep, line: []const u8) Abort {
        const failure = std.json.parseFromSliceLeaky(protocol.ErrorReply, sw.a, line, .{ .ignore_unknown_fields = true }) catch
            return sw.halt(.failed, "the daemon sent a malformed reply", .{});
        if (std.mem.eql(u8, failure.code, @tagName(protocol.Code.ended))) return error.Ended;
        if (std.mem.eql(u8, failure.code, @tagName(protocol.Code.no_session))) return sw.halt(.removed, "the session was removed", .{});
        return sw.halt(.failed, "{s}", .{failure.err});
    }

    /// Stop, for the first reason only.
    fn note(sw: *Sweep, code: StopCode, comptime fmt: []const u8, args: anytype) void {
        if (sw.stop == null) sw.stop = .{ .code = code, .why = std.fmt.allocPrint(sw.a, fmt, args) catch "out of memory" };
    }

    fn halt(sw: *Sweep, code: StopCode, comptime fmt: []const u8, args: anytype) Abort {
        sw.note(code, fmt, args);
        return error.Stopped;
    }

    fn save(sw: *Sweep, dir: []const u8, name: []const u8, text: []const u8, styles: ?protocol.Styles) !void {
        const txt = try std.fmt.allocPrint(sw.a, "{s}/{s}.txt", .{ dir, name });
        const body = if (std.mem.endsWith(u8, text, "\n") or text.len == 0) text else try std.mem.concat(sw.a, u8, &.{ text, "\n" });
        try writeFile(sw, txt, body);
        const sty = try std.fmt.allocPrint(sw.a, "{s}/{s}.styles", .{ dir, name });
        try writeFile(sw, sty, try client.stylesText(sw.a, styles orelse .{}, std.math.maxInt(usize)));
    }

    fn writeFile(sw: *Sweep, path: []const u8, data: []const u8) !void {
        const z = try sw.a.dupeSentinel(u8, path, 0);
        const file = plat.create(z, .blocking) catch |err| return sw.halt(.failed, "cannot create '{s}': {s}", .{ path, plat.createErrorText(err) });
        defer plat.close(file);
        plat.writeAll(file, data) catch return sw.halt(.failed, "cannot write '{s}'", .{path});
    }

    /// Derive the samples before `end` that are not final yet: an absent
    /// find gets its first part where a neighbouring size had the text (or
    /// the start, so that a sweep from a narrow size finds a cut text too),
    /// and every find whether its row changed after the resize. Then
    /// report them.
    fn finalizeUpTo(sw: *Sweep, end: usize) !void {
        while (sw.finalized < end) : (sw.finalized += 1) {
            const i = sw.finalized;
            const s = &sw.samples.items[i];
            const lines = try splitLines(sw.a, s.text);
            for (sw.o.finds, s.spots, 0..) |find, *spot, f| {
                if (spot.state == .absent) {
                    const before: ?Anchor = if (i > 0) anchorOf(sw.samples.items[i - 1].spots[f], sw.samples.items[i - 1].size.cols) else null;
                    const after: ?Anchor = if (i + 1 < sw.samples.items.len) anchorOf(sw.samples.items[i + 1].spots[f], sw.samples.items[i + 1].size.cols) else null;
                    const start: ?Anchor = if (f < sw.baseline.spots.len) anchorOf(sw.baseline.spots[f], sw.start_size.cols) else null;
                    for ([_]?Anchor{ before, after, start }) |anchor| if (anchor) |an| {
                        const got = near(lines, s.size.cols, find.text, sw.o.icase, an);
                        if (got.state != .absent) {
                            spot.* = got;
                            break;
                        }
                    };
                }
                if (spot.state != .absent and s.resize_seq != null and s.screen != .ended) spot.stale = staleAt(s.*, spot.row.?);
            }
            try sw.report.add(sw, s.*);
        }
    }

    const Back = struct {
        size: Size,
        /// Rows whose text or styles differ from the baseline.
        rows: []const i64,
        base_differs: bool,
    };

    /// Resize back to where the sweep started and compare with the
    /// baseline, leaving out the rows that change on their own.
    fn goBack(sw: *Sweep) !Back {
        try sw.lateCheck();
        const own = try sw.resizeTo(sw.start_size);
        if (own.seq) |seq| _ = try sw.settle(seq, own);
        const read = try sw.view(null, true);
        const now_lines = try splitLines(sw.a, read.text);
        const was_lines = try splitLines(sw.a, sw.baseline.text);
        const now_styles = read.styles orelse protocol.Styles{};
        var rows: std.ArrayList(i64) = .empty;
        var r: i64 = 1;
        while (r <= sw.start_size.rows) : (r += 1) {
            if (std.mem.indexOfScalar(i64, sw.baseline.own_rows, r) != null) continue;
            const i: usize = @intCast(r - 1);
            const a_line = if (i < now_lines.len) now_lines[i] else "";
            const b_line = if (i < was_lines.len) was_lines[i] else "";
            if (!std.mem.eql(u8, a_line, b_line) or !sameRuns(now_styles.runs, sw.baseline.styles.runs, r)) try rows.append(sw.a, r);
        }
        return .{ .size = sw.start_size, .rows = rows.items, .base_differs = !now_styles.base.eql(sw.baseline.styles.base) };
    }

    /// The hits the session took during the sweep.
    fn hits(sw: *Sweep, st: Status) ![]const protocol.Hit {
        if (st.alerts.len == 0 or st.hit_seq == null or std.meta.eql(st.hit_seq, sw.start.hit_seq)) return &.{};
        const until = [_]protocol.Condition{.{ .hit = .{ .name = "*", .after_hit = sw.start.hit_seq orelse 0 } }};
        const reply = client.request(sw.a, protocol.WaitReq{ .session = sw.ref, .until = &until, .timeout_ms = 0 }, protocol.WaitResp) catch return &.{};
        if (!reply.parsed.value.ok) return &.{};
        return reply.parsed.value.hits;
    }

    /// After the table: the way back, what the sweep caused, and what it
    /// did not check; or the end line with -j.
    fn summary(sw: *Sweep, back: ?Back) !void {
        const st = sw.final orelse sw.start;
        const hit_list = try sw.hits(st);
        const bells = st.bell_count -| sw.start.bell_count;
        const notes = st.notification_count -| sw.start.notification_count;
        var absent: std.ArrayList([]const u8) = .empty;
        var stale: usize = 0;
        var still: usize = 0;
        var stale_sizes: usize = 0;
        for (sw.o.finds, 0..) |find, f| {
            var seen = false;
            for (sw.samples.items) |s| {
                if (s.spots[f].state != .absent) seen = true;
            }
            if (!seen and sw.samples.items.len > 0) try absent.append(sw.a, find.name);
        }
        for (sw.samples.items) |s| {
            if (s.screen == .still_changing) still += 1;
            var any = false;
            for (s.spots) |spot| {
                stale += @intFromBool(spot.stale == true);
                any = any or spot.stale == true;
            }
            stale_sizes += @intFromBool(any);
        }
        const elapsed_ms: u64 = @intCast(@divTrunc(io_mod.nowNanos() - sw.started_ns, std.time.ns_per_ms));
        var out: std.Io.Writer.Allocating = .init(sw.a);
        const w = &out.writer;
        if (sw.o.json) {
            var js: std.json.Stringify = .{ .writer = w };
            try js.beginObject();
            try js.objectField("type");
            try js.write("end");
            try js.objectField("sizes");
            try js.write(sw.samples.items.len);
            try js.objectField("planned");
            try js.write(sw.o.sizes.len);
            try js.objectField("ms");
            try js.write(elapsed_ms);
            try js.objectField("start");
            try js.write(sw.start_size);
            try js.objectField("back");
            try js.write(if (back) |b| (if (b.rows.len == 0 and !b.base_differs) "same" else "differs") else null);
            try js.objectField("back_rows");
            try js.write(if (back) |b| b.rows else null);
            try js.objectField("back_base_differs");
            try js.write(if (back) |b| b.base_differs else null);
            try js.objectField("own_rows");
            try js.write(sw.baseline.own_rows);
            try js.objectField("hits");
            try js.write(hit_list);
            try js.objectField("bells");
            try js.write(bells);
            try js.objectField("notifications");
            try js.write(notes);
            try js.objectField("stopped");
            try js.write(if (sw.stop) |s| @tagName(s.code) else null);
            try js.objectField("why");
            try js.write(if (sw.stop) |s| s.why else null);
            try js.objectField("absent");
            try js.write(absent.items);
            try js.objectField("stale");
            try js.write(stale);
            try js.objectField("settled_ms");
            try js.write(sw.o.settled_ms);
            try js.objectField("timeout_ms");
            try js.write(sw.o.timeout_ms);
            try js.objectField("step");
            try js.write(sw.o.step);
            try js.objectField("refined");
            try js.write(sw.o.refine);
            try js.endObject();
            try w.writeAll("\n");
            return plat.stdoutWriteAll(out.written());
        }
        if (back) |b| {
            try w.print("back at {d}x{d}: ", .{ b.size.cols, b.size.rows });
            if (b.rows.len == 0 and !b.base_differs) try w.writeAll("same") else {
                try w.writeAll("differs");
                if (b.rows.len > 0) {
                    try w.writeAll(" in rows ");
                    try writeRows(w, b.rows);
                }
                if (b.base_differs) try w.print("{s}in the base style", .{if (b.rows.len > 0) " and " else " "});
            }
            if (sw.baseline.own_rows.len > 0) {
                try w.writeAll(" (rows ");
                try writeRows(w, sw.baseline.own_rows);
                try w.writeAll(" change on their own and were not compared)");
            }
            try w.writeAll("\n");
        }
        try w.print("during the sweep: hits {d}, bells {d}, notifications {d}\n", .{ hit_list.len, bells, notes });
        for (hit_list) |hit| try w.writeAll(try client.hitLine(sw.a, hit));
        if (sw.stop) |s| try w.print("partial: stopped after {d} sizes ({d} planned): {s}\n", .{ sw.samples.items.len, sw.o.sizes.len, s.why });
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        try w.print("not checked: only finds and the return screen were compared; settle {s}, deadline {s}, sizes sampled every {d}{s}; {d} stale\n", .{
            units.durationText(&b1, sw.o.settled_ms),                           units.durationText(&b2, sw.o.timeout_ms), sw.o.step,
            if (sw.o.refine) ", edges exact between differing samples" else "", stale,
        });
        for (absent.items) |name| try w.print("{s} absent at every size\n", .{name});
        const n = sw.samples.items.len;
        if (n > 0 and (still * 2 > n or stale_sizes * 2 > n)) {
            try w.print("{s}: a shorter --settled reads a busy program sooner; a slow one needs a longer -t\n", .{if (still * 2 > n) "most sizes were still changing" else "most sizes had stale finds (rows left alone after the resize, or drawn again the same)"});
        }
        try plat.stdoutWriteAll(out.written());
    }
};

fn refuseWriter(id: u64, label: ?[]const u8) noreturn {
    refuse("session {d} has a writer ({s}); a sweep resizes as the writer and never takes over", .{ id, label orelse "unlabelled" });
}

/// Report a failed reply and exit, as `call` does.
fn failed(a: std.mem.Allocator, line: []const u8) noreturn {
    const text = client.failureText(a, line) catch "the request failed";
    client.runtimeFailWith(client.failureExit(a, line), "{s}", .{text});
}

fn exitText(a: std.mem.Allocator, exit: ?status.Exit) ![]const u8 {
    const e = exit orelse return "exit=-";
    if (e.stopped) return "exit=stopped";
    if (e.code) |code| return std.fmt.allocPrint(a, "exit={d}", .{code});
    return std.fmt.allocPrint(a, "exit={s}", .{e.signal orelse "-"});
}

/// The rows of the screen among a since view's rows.
fn screenRows(a: std.mem.Allocator, rows: ?[]const i64) ![]const i64 {
    var out: std.ArrayList(i64) = .empty;
    for (rows orelse &.{}) |r| if (r >= 1) try out.append(a, r);
    return out.items;
}

fn splitLines(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| try out.append(a, line);
    return out.items;
}

/// Whether row `row` has the same runs in both.
fn sameRuns(x: []const styles_mod.Run, y: []const styles_mod.Run, row: i64) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < x.len and x[i].row != row) i += 1;
        while (j < y.len and y[j].row != row) j += 1;
        if (i == x.len or j == y.len) return i == x.len and j == y.len;
        const p = x[i];
        const q = y[j];
        if (p.col != q.col or p.cols != q.cols or !std.mem.eql(u8, p.text, q.text) or !p.attrs.eql(q.attrs)) return false;
        i += 1;
        j += 1;
    }
}

fn absDiff(x: u16, y: u16) u16 {
    return if (x > y) x - y else y - x;
}

/// Whether two samples' facts are equal, as --refine compares them: the
/// kind of screen and, for each find, its state, row, count, and
/// staleness.
fn sameFacts(x: Sample, y: Sample) bool {
    if (x.screen != y.screen or x.blank != y.blank) return false;
    for (x.spots, y.spots) |p, q| {
        if (p.state != q.state or p.count != q.count or !std.meta.eql(p.row, q.row)) return false;
        if (p.state != .absent and staleAt(x, p.row.?) != staleAt(y, q.row.?)) return false;
    }
    return true;
}

/// Whether row `row` did not change after the sample's resize.
fn staleAt(s: Sample, row: u16) bool {
    return s.resize_seq != null and std.mem.indexOfScalar(i64, s.changed, row) == null;
}

/// `3, 5-7`.
fn writeRows(w: *std.Io.Writer, rows: []const i64) !void {
    var i: usize = 0;
    while (i < rows.len) {
        var j = i;
        while (j + 1 < rows.len and rows[j + 1] == rows[j] + 1) j += 1;
        if (i > 0) try w.writeAll(", ");
        if (j > i) try w.print("{d}-{d}", .{ rows[i], rows[j] }) else try w.print("{d}", .{rows[i]});
        i = j + 1;
    }
}

fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(s);
    try plat.stderrWriteAll(s);
}

// ---- the report ----------------------------------------------------------

/// The table, a range of sizes per line, each printed once it closes; or
/// a JSON line per size with -j.
const Report = struct {
    run: ?Range = null,
    cols_width: usize = 4,
    rows_width: usize = 4,
    find_widths: []usize = &.{},

    const screen_width = 36;

    const Mode = enum { col, right, moves };

    /// Consecutive sizes whose facts are equal.
    const Range = struct {
        first: Sample,
        last: Sample,
        /// Which side of the size varies: unknown while it has one size.
        axis: enum { none, cols, rows } = .none,
        /// Per find: whether its col, and its right edge, stayed as at
        /// the first size.
        col_stays: []bool,
        right_stays: []bool,
        rows_lo: u32,
        rows_hi: u32,
        bytes_lo: u64,
        bytes_hi: u64,
        col_lo: []u16,
        col_hi: []u16,

        /// How find `f`'s position is compared over the range.
        fn mode(run: *const Range, f: usize) Mode {
            if (run.col_stays[f]) return .col;
            if (run.right_stays[f]) return .right;
            return .moves;
        }
    };

    fn init(r: *Report, sw: *Sweep) void {
        if (sw.o.json) return;
        var max_cols: u16 = sw.start_size.cols;
        var max_rows: u16 = sw.start_size.rows;
        for (sw.o.sizes) |s| {
            max_cols = @max(max_cols, s.cols);
            max_rows = @max(max_rows, s.rows);
        }
        r.cols_width = @max(4, 2 * std.fmt.count("{d}", .{max_cols}) + 2);
        r.rows_width = @max(4, 2 * std.fmt.count("{d}", .{max_rows}) + 2);
        r.find_widths = sw.a.alloc(usize, sw.o.finds.len) catch &.{};
        for (sw.o.finds, r.find_widths) |f, *width| width.* = @max(f.name.len, 18);
        var out: std.Io.Writer.Allocating = .init(sw.a);
        const w = &out.writer;
        r.cell(w, "COLS", r.cols_width) catch return;
        r.cell(w, "ROWS", r.rows_width) catch return;
        r.cell(w, "SCREEN", if (sw.o.finds.len > 0) screen_width else 0) catch return;
        for (sw.o.finds, r.find_widths, 0..) |f, width, i| r.cell(w, f.name, if (i + 1 < sw.o.finds.len) width else 0) catch return;
        w.writeAll("\n") catch return;
        plat.stdoutWriteAll(out.written()) catch {};
    }

    fn cell(r: *Report, w: *std.Io.Writer, text: []const u8, width: usize) !void {
        _ = r;
        try w.writeAll(text);
        if (width > 0) try w.splatByteAll(' ', @max(width, text.len) - text.len + 2);
    }

    /// A final sample, in order of size.
    fn add(r: *Report, sw: *Sweep, s: Sample) !void {
        if (sw.o.json) return r.json(sw, s);
        if (r.run) |*run| if (r.fits(run, s)) {
            r.extend(run, s);
            return;
        };
        try r.close(sw);
        r.run = try r.open(sw, s);
    }

    fn open(r: *Report, sw: *Sweep, s: Sample) !Range {
        _ = r;
        const n = s.spots.len;
        const run: Range = .{
            .first = s,
            .last = s,
            .col_stays = try sw.a.alloc(bool, n),
            .right_stays = try sw.a.alloc(bool, n),
            .rows_lo = s.rows_changed,
            .rows_hi = s.rows_changed,
            .bytes_lo = s.bytes,
            .bytes_hi = s.bytes,
            .col_lo = try sw.a.alloc(u16, n),
            .col_hi = try sw.a.alloc(u16, n),
        };
        for (run.col_stays, run.right_stays, run.col_lo, run.col_hi, s.spots) |*c, *right, *lo, *hi, spot| {
            c.* = true;
            right.* = true;
            lo.* = spot.col orelse 0;
            hi.* = spot.col orelse 0;
        }
        return run;
    }

    /// Whether `s` continues the range: the same facts, each find on the
    /// same row, and only one side of the size varying. A position that
    /// moves does not end it; it is told by whichever of col or right
    /// stays over the range, else as moving.
    fn fits(r: *Report, run: *const Range, s: Sample) bool {
        _ = r;
        const p = run.last;
        if (p.screen == .ended or s.screen == .ended) return false;
        if (s.screen != p.screen or s.late != p.late or s.blank != p.blank) return false;
        switch (run.axis) {
            .none => if (s.size.rows != p.size.rows and s.size.cols != p.size.cols) return false,
            .cols => if (s.size.rows != p.size.rows) return false,
            .rows => if (s.size.cols != p.size.cols) return false,
        }
        for (p.spots, s.spots) |x, y| {
            if (x.state != y.state or x.count != y.count or !std.meta.eql(x.stale, y.stale) or !std.meta.eql(x.row, y.row)) return false;
            if (x.state == .prefix or x.state == .split) if (!std.mem.eql(u8, x.prefix.?, y.prefix.?)) return false;
        }
        return true;
    }

    fn extend(r: *Report, run: *Range, s: Sample) void {
        _ = r;
        const p = run.last;
        if (run.axis == .none) run.axis = if (s.size.rows == p.size.rows) .cols else .rows;
        for (run.first.spots, s.spots, run.col_stays, run.right_stays, run.col_lo, run.col_hi) |x, y, *c, *right, *lo, *hi| {
            if (x.state == .absent) continue;
            c.* = c.* and x.col.? == y.col.?;
            right.* = right.* and x.right.? == y.right.?;
            lo.* = @min(lo.*, y.col.?);
            hi.* = @max(hi.*, y.col.?);
        }
        run.rows_lo = @min(run.rows_lo, s.rows_changed);
        run.rows_hi = @max(run.rows_hi, s.rows_changed);
        run.bytes_lo = @min(run.bytes_lo, s.bytes);
        run.bytes_hi = @max(run.bytes_hi, s.bytes);
        run.last = s;
    }

    /// Print the open range.
    fn close(r: *Report, sw: *Sweep) !void {
        const run = r.run orelse return;
        r.run = null;
        var out: std.Io.Writer.Allocating = .init(sw.a);
        const w = &out.writer;
        const a = sw.a;
        try r.cell(w, try span(a, run.first.size.cols, run.last.size.cols), r.cols_width);
        try r.cell(w, try span(a, run.first.size.rows, run.last.size.rows), r.rows_width);
        try r.cell(w, try screenText(a, run), if (sw.o.finds.len > 0) screen_width else 0);
        for (run.first.spots, run.last.spots, run.col_lo, run.col_hi, r.find_widths, 0..) |first, last, lo, hi, width, i| {
            try r.cell(w, try spotText(a, run.mode(i), first, last, lo, hi), if (i + 1 < sw.o.finds.len) width else 0);
        }
        try w.writeAll("\n");
        if (sw.o.view) {
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, run.first.text, "\n"), '\n');
            while (lines.next()) |line| if (line.len > 0) try w.print("  {s}\n", .{line}) else try w.writeAll("\n");
        }
        try plat.stdoutWriteAll(out.written());
    }

    fn json(r: *Report, sw: *Sweep, s: Sample) !void {
        _ = r;
        var out: std.Io.Writer.Allocating = .init(sw.a);
        var js: std.json.Stringify = .{ .writer = &out.writer };
        try js.beginObject();
        try js.objectField("type");
        try js.write("size");
        try js.objectField("cols");
        try js.write(s.size.cols);
        try js.objectField("rows");
        try js.write(s.size.rows);
        try js.objectField("screen");
        try js.write(@tagName(s.screen));
        try js.objectField("rows_changed");
        try js.write(if (s.resize_seq != null and s.screen != .ended) @as(?u32, s.rows_changed) else null);
        try js.objectField("bytes");
        try js.write(s.bytes);
        try js.objectField("exit");
        try js.write(if (s.screen == .ended) @as(?[]const u8, s.exit) else null);
        try js.objectField("late");
        try js.write(s.late);
        try js.objectField("blank");
        try js.write(s.blank);
        try js.objectField("resize_seq");
        try js.write(s.resize_seq);
        try js.objectField("seq");
        try js.write(s.seq);
        try js.objectField("finds");
        try js.beginObject();
        for (sw.o.finds, s.spots) |f, spot| {
            try js.objectField(f.name);
            try js.write(spot);
        }
        try js.endObject();
        try js.endObject();
        try out.writer.writeAll("\n");
        try plat.stdoutWriteAll(out.written());
    }
};

fn span(a: std.mem.Allocator, lo: u16, hi: u16) ![]const u8 {
    if (lo == hi) return std.fmt.allocPrint(a, "{d}", .{lo});
    return std.fmt.allocPrint(a, "{d}..{d}", .{ lo, hi });
}

fn spanU64(a: std.mem.Allocator, lo: u64, hi: u64) ![]const u8 {
    if (lo == hi) return std.fmt.allocPrint(a, "{d}", .{lo});
    return std.fmt.allocPrint(a, "{d}..{d}", .{ lo, hi });
}

/// What the program did at the sizes of a range.
fn screenText(a: std.mem.Allocator, run: Report.Range) ![]const u8 {
    const s = run.first;
    const main = switch (s.screen) {
        .same_size => "same size",
        .changed => try std.fmt.allocPrint(a, "changed {s}/{s} rows, {s} bytes", .{
            try spanU64(a, run.rows_lo, run.rows_hi), try span(a, run.first.size.rows, run.last.size.rows), try spanU64(a, run.bytes_lo, run.bytes_hi),
        }),
        .unchanged => try std.fmt.allocPrint(a, "unchanged, wrote {s} bytes", .{try spanU64(a, run.bytes_lo, run.bytes_hi)}),
        .wrote_nothing => "wrote nothing",
        .still_changing => "still changing",
        .ended => try std.fmt.allocPrint(a, "ended {s}", .{s.exit}),
    };
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ main, if (s.late) ", late" else "", if (s.blank) ", blank" else "" });
}

/// Where a find sat over a range: `R:C`, `R:C1..C2 right=N` where its
/// right edge stays, `moves R:C1..C2`, `prefix "X" at …`, `split …`,
/// `absent`; then `xN` and `stale`.
fn spotText(a: std.mem.Allocator, mode: Report.Mode, first: Spot, last: Spot, lo: u16, hi: u16) ![]const u8 {
    if (first.state == .absent) return "absent";
    const where = switch (mode) {
        .col => try std.fmt.allocPrint(a, "{d}:{d}", .{ first.row.?, first.col.? }),
        .right => try std.fmt.allocPrint(a, "{d}:{s} right={d}", .{ first.row.?, try span(a, lo, hi), last.right.? }),
        .moves => try std.fmt.allocPrint(a, "moves {d}:{s}", .{ first.row.?, try span(a, lo, hi) }),
    };
    const what = switch (first.state) {
        .at => where,
        .prefix => try std.fmt.allocPrint(a, "prefix \"{s}\" at {s}", .{ first.prefix.?, where }),
        .split => try std.fmt.allocPrint(a, "split {s}", .{where}),
        .absent => unreachable,
    };
    var count_buf: [16]u8 = undefined;
    const count = if (first.count > 1) std.fmt.bufPrint(&count_buf, " x{d}", .{first.count}) catch "" else "";
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ what, count, if (first.stale == true) " stale" else "" });
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "sizes take ranges on either side, every step, widths first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const got = try parseSizes(a, "60..64x20..21", 2, &why);
    const want = [_]Size{
        .{ .cols = 60, .rows = 20 }, .{ .cols = 62, .rows = 20 }, .{ .cols = 64, .rows = 20 },
        .{ .cols = 60, .rows = 21 }, .{ .cols = 62, .rows = 21 }, .{ .cols = 64, .rows = 21 },
    };
    try testing.expectEqualSlices(Size, &want, got);
    // The end of a range is sampled even off the step.
    try testing.expectEqualSlices(Size, &.{ .{ .cols = 80, .rows = 24 }, .{ .cols = 83, .rows = 24 }, .{ .cols = 84, .rows = 24 } }, try parseSizes(a, "80..84x24", 3, &why));
    try testing.expectEqualSlices(Size, &.{ .{ .cols = 80, .rows = 24 }, .{ .cols = 120, .rows = 40 } }, try parseSizes(a, "80x24,120x40", 1, &why));
    try testing.expectEqualSlices(Size, &.{ .{ .cols = 3, .rows = 9 }, .{ .cols = 2, .rows = 9 }, .{ .cols = 1, .rows = 9 } }, try parseSizes(a, "3..1x9", 1, &why));
    for ([_][]const u8{ "80", "0x24", "1001x24", "80x", "a..bx3", "80x24,80x24", "1..300x1" }) |bad| {
        try testing.expectError(error.InvalidSizes, parseSizes(a, bad, 1, &why));
    }
    try testing.expectEqual(@as(usize, 256), (try parseSizes(a, "1..256x1", 1, &why)).len);
}

test "a find is located in cells, wide characters counted as Ghostty counts them" {
    const lines = [_][]const u8{ "日本 title", "", "  title" };
    const spot = locate(&lines, 20, "title", false);
    try testing.expectEqual(State.at, spot.state);
    try testing.expectEqual(@as(?u16, 1), spot.row);
    try testing.expectEqual(@as(?u16, 6), spot.col);
    // Its last cell, 10, is 11 cells from the right edge of 20, counting from 1.
    try testing.expectEqual(@as(?u16, 11), spot.right);
    try testing.expectEqual(@as(u32, 2), spot.count);
    try testing.expectEqual(State.absent, locate(&lines, 20, "TITLE", false).state);
    try testing.expectEqual(State.at, locate(&lines, 20, "TITLE", true).state);
}

test "an absent find is a prefix or a split where a neighbour had it" {
    const text = "Review PR #42 (picker preview)";
    // Cut at the same distance from the left edge.
    const cut = [_][]const u8{ "", "   Review PR #42 (pi" };
    const prefix = near(&cut, 20, text, false, .{ .row = 2, .col = 4, .cols = 60 });
    try testing.expectEqual(State.prefix, prefix.state);
    try testing.expectEqualStrings("Review PR #42 (pi", prefix.prefix.?);
    try testing.expectEqual(@as(?u16, 4), prefix.col);
    // Too short a part is no prefix: at least max(3, half) characters.
    const short = [_][]const u8{ "", "   Review PR" };
    try testing.expectEqual(State.absent, near(&short, 14, text, false, .{ .row = 2, .col = 4, .cols = 60 }).state);
    // The rest continues at the first non-blank cell of the next row.
    const wrapped = [_][]const u8{ "   Review PR #42 (picker", "     preview)" };
    const split = near(&wrapped, 24, text, false, .{ .row = 1, .col = 4, .cols = 60 });
    try testing.expectEqual(State.split, split.state);
    try testing.expectEqualStrings("Review PR #42 (picker", split.prefix.?);
    // From the right edge: column 31 of 40 is column 21 of 30.
    const right = [_][]const u8{"                    [3 open |"};
    const from_right = near(&right, 30, "[3 open | 12 done]", false, .{ .row = 1, .col = 31, .cols = 40 });
    try testing.expectEqual(State.prefix, from_right.state);
    try testing.expectEqual(@as(?u16, 21), from_right.col);
}

test "a range collapses by whichever of col or right stays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sw: Sweep = .{ .a = a, .o = .{ .json = true } };
    var r: Report = .{};
    const at = struct {
        fn sample(al: std.mem.Allocator, cols: u16, col: u16, right: u16) !Sample {
            const spots = try al.alloc(Spot, 1);
            spots[0] = .{ .state = .at, .row = 1, .col = col, .right = right, .count = 1, .stale = false };
            return .{ .size = .{ .cols = cols, .rows = 10 }, .screen = .changed, .resize_seq = 1, .spots = spots };
        }
    }.sample;
    // Right-aligned: col moves with the width, right stays.
    var run = try r.open(&sw, try at(a, 60, 41, 2));
    for ([_]u16{ 61, 62, 63 }) |cols| {
        const s = try at(a, cols, cols - 19, 2);
        try testing.expect(r.fits(&run, s));
        r.extend(&run, s);
    }
    try testing.expectEqual(Report.Mode.right, run.mode(0));
    try testing.expectEqualStrings("1:41..44 right=2", try spotText(a, run.mode(0), run.first.spots[0], run.last.spots[0], run.col_lo[0], run.col_hi[0]));
    // Centred text keeps its col at one size and its right edge at the
    // next, and collapses as moving.
    var centred = try r.open(&sw, try at(a, 60, 25, 26));
    for ([_][2]u16{ .{ 25, 27 }, .{ 26, 27 }, .{ 26, 28 } }, 61..) |pos, cols| {
        const next = try at(a, @intCast(cols), pos[0], pos[1]);
        try testing.expect(r.fits(&centred, next));
        r.extend(&centred, next);
    }
    try testing.expectEqual(Report.Mode.moves, centred.mode(0));
    try testing.expectEqualStrings("moves 1:25..26", try spotText(a, centred.mode(0), centred.first.spots[0], centred.last.spots[0], centred.col_lo[0], centred.col_hi[0]));
    // Another row ends the range.
    var moved = try at(a, 64, 26, 28);
    moved.spots[0].row = 2;
    try testing.expect(!r.fits(&centred, moved));
}
