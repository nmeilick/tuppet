//! Shell marks (OSC 133): where a shell's primary prompt waits, the
//! commands it ran, and how they ended, as the marks it prints say. The
//! daemon takes the marks as they come and checks nothing about who
//! printed them. Everything here is guarded by the session's
//! terminal_mutex.

const std = @import("std");
const vt = @import("vt");
const status = @import("status.zig");
const store = @import("store.zig");

const Pin = vt.Pin;
const Mark = vt.TerminalStream.Action.Value(.semantic_prompt);

/// A session keeps this many commands.
pub const max_commands = 50;
/// A command's line and output are kept up to these sizes; of the output,
/// its end.
pub const max_command_line = 4096;
pub const max_output = 64 * 1024;
/// An output's text is read from at most this many rows before its end.
const max_output_rows = 4096;

/// A command the marks reported: its line from B to C, its output from C
/// to D, and its exit code from D.
pub const Command = struct {
    /// Counts from 1 in each session.
    n: u64,
    command: []const u8,
    output: []const u8,
    /// Older output was left out to keep the last `max_output` bytes.
    output_cut: bool = false,
    /// Null when the command ended without a D, or D carried no code.
    exit: ?i32 = null,
    started_ms: i64,
    ended_ms: i64,
};

pub const Marks = struct {
    shell: status.Shell = .unknown,
    prompt_seq: u64 = 0,
    /// The session's input_seq when the latest primary prompt's B came.
    prompt_input_seq: u64 = 0,
    last_exit: ?i32 = null,
    /// The kind the latest prompt start named: a B after a continuation
    /// or right prompt is no primary prompt.
    primary: bool = true,
    /// Where input starts (B) and output starts (C), on the primary
    /// screen; tracked, so they move with scrolling and reflow.
    input_at: ?*Pin = null,
    output_at: ?*Pin = null,
    /// The command line taken at C, until D.
    line: ?[]u8 = null,
    started_ms: i64 = 0,
    commands: std.ArrayList(Command) = .empty,
    count: u64 = 0,

    pub fn deinit(m: *Marks, gpa: std.mem.Allocator) void {
        for (m.commands.items) |c| free(gpa, c);
        m.commands.deinit(gpa);
        if (m.line) |l| gpa.free(l);
        m.* = .{};
    }

    /// A command ended: what to report.
    pub const Ended = struct { code: ?i32 };

    /// Take one mark, after the terminal applied it; `input_seq` is the
    /// session's latest. Returns a command that ended.
    pub fn take(m: *Marks, gpa: std.mem.Allocator, t: *vt.Terminal, cmd: Mark, input_seq: u64) ?Ended {
        switch (cmd.action) {
            .fresh_line_new_prompt, .new_command, .prompt_start => {
                const kind = cmd.readOption(.prompt_kind) orelse .initial;
                m.primary = kind == .initial;
                // A new prompt ends a command that had no D.
                const ended = if (m.shell == .running) m.finish(gpa, t, null) else null;
                if (cmd.action != .prompt_start or m.primary) m.shell = .unknown;
                return ended;
            },
            .end_prompt_start_input, .end_prompt_start_input_terminate_eol => {
                if (!m.primary) {
                    m.shell = .unknown;
                    return null;
                }
                m.shell = .prompt;
                m.prompt_seq += 1;
                m.prompt_input_seq = input_seq;
                m.place(t, &m.input_at);
            },
            .end_input_start_output => {
                if (m.shell != .prompt) return null;
                m.shell = .running;
                if (m.line) |l| gpa.free(l);
                m.line = m.textFrom(gpa, t, m.input_at, max_command_line, .start);
                m.started_ms = store.nowMillis();
                m.place(t, &m.output_at);
            },
            .end_command => {
                if (m.shell != .running) return null;
                const code = cmd.readOption(.exit_code);
                m.shell = .unknown;
                return m.finish(gpa, t, code);
            },
            .fresh_line => {},
        }
        return null;
    }

    /// Record the running command as ended with `code`.
    fn finish(m: *Marks, gpa: std.mem.Allocator, t: *vt.Terminal, code: ?i32) Ended {
        m.shell = .unknown;
        m.last_exit = code;
        var cut = false;
        const output = m.outputText(gpa, t, &cut);
        const line = m.line orelse gpa.dupe(u8, "") catch null;
        m.line = null;
        m.count += 1;
        if (line != null and output != null) {
            if (m.commands.items.len == max_commands) free(gpa, m.commands.orderedRemove(0));
            m.commands.append(gpa, .{
                .n = m.count,
                .command = line.?,
                .output = output.?,
                .output_cut = cut,
                .exit = code,
                .started_ms = m.started_ms,
                .ended_ms = store.nowMillis(),
            }) catch {
                gpa.free(line.?);
                gpa.free(output.?);
            };
        } else {
            if (line) |l| gpa.free(l);
            if (output) |o| gpa.free(o);
        }
        return .{ .code = code };
    }

    /// Put `pin` where the cursor is, on the primary screen only.
    fn place(m: *Marks, t: *vt.Terminal, pin: *?*Pin) void {
        _ = m;
        if (t.screens.active_key != .primary) {
            if (pin.*) |p| t.screens.get(.primary).?.pages.untrackPin(p);
            pin.* = null;
            return;
        }
        const pages = &t.screens.active.pages;
        const at = t.screens.active.cursor.page_pin.*;
        if (pin.*) |p| {
            p.* = at;
            return;
        }
        pin.* = pages.trackPin(at) catch null;
    }

    fn outputText(m: *Marks, gpa: std.mem.Allocator, t: *vt.Terminal, cut: *bool) ?[]u8 {
        const text = m.textFrom(gpa, t, m.output_at, max_output, .end) orelse return null;
        cut.* = text.len == max_output;
        return text;
    }

    const Keep = enum { start, end };

    /// The text from `from` to the cursor, plain, soft wraps joined,
    /// trailing blanks dropped, and at most `cap` bytes of its start or
    /// end; empty when the mark was not on the primary screen.
    fn textFrom(m: *Marks, gpa: std.mem.Allocator, t: *vt.Terminal, from: ?*Pin, cap: usize, keep: Keep) ?[]u8 {
        _ = m;
        const p = from orelse return gpa.dupe(u8, "") catch null;
        const screen = t.screens.get(.primary) orelse return null;
        const pages = &screen.pages;
        var start = if (p.garbage) pages.getTopLeft(.screen) else p.*;
        const end = screen.cursor.page_pin.*;
        const start_y = (pages.pointFromPin(.screen, start) orelse return null).coord().y;
        const end_y = (pages.pointFromPin(.screen, end) orelse return null).coord().y;
        if (end_y < start_y or (end_y == start_y and end.x <= start.x)) return gpa.dupe(u8, "") catch null;
        if (end_y - start_y > max_output_rows) start = pages.pin(.{ .screen = .{ .y = end_y - max_output_rows } }) orelse start;
        var w: std.Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        var f = vt.formatter.ScreenFormatter.init(screen, .{ .emit = .plain, .unwrap = true });
        f.content = .{ .selection = vt.Selection.init(start, end, false) };
        f.format(&w.writer) catch return null;
        var text = std.mem.trimEnd(u8, w.written(), " \n\r\t");
        if (text.len > cap) text = switch (keep) {
            .start => text[0..utf8Start(text, cap)],
            .end => text[utf8End(text, text.len - cap)..],
        };
        return gpa.dupe(u8, text) catch null;
    }

    /// The last `n` commands, oldest first; they alias the marks.
    pub fn last(m: *const Marks, n: usize) []const Command {
        const items = m.commands.items;
        return items[items.len - @min(n, items.len) ..];
    }
};

fn free(gpa: std.mem.Allocator, c: Command) void {
    gpa.free(c.command);
    gpa.free(c.output);
}

/// The longest start of `text` of at most `len` bytes that ends on a
/// character boundary.
fn utf8Start(text: []const u8, len: usize) usize {
    var n = len;
    while (n > 0 and n < text.len and text[n] & 0xc0 == 0x80) n -= 1;
    return n;
}

/// The first character boundary at or after `at`.
fn utf8End(text: []const u8, at: usize) usize {
    var n = at;
    while (n < text.len and text[n] & 0xc0 == 0x80) n += 1;
    return n;
}

const testing = std.testing;

const Terminal = vt.Terminal;
const Inner = vt.TerminalStream.Handler;
const Action = vt.TerminalStream.Action;
const Stream = vt.Stream;

fn feed(t: *Terminal, m: *Marks, bytes: []const u8, input_seq: u64, ended: *?Marks.Ended) void {
    const Handler = struct {
        inner: Inner,
        marks: *Marks,
        input_seq: u64,
        ended: *?Marks.Ended,

        pub fn vt(h: *@This(), comptime action: Action.Tag, value: Action.Value(action)) void {
            h.inner.vt(action, value);
            if (action == .semantic_prompt) if (h.marks.take(testing.allocator, h.inner.terminal, value, h.input_seq)) |e| {
                h.ended.* = e;
            };
        }

        pub fn deinit(h: *@This()) void {
            h.inner.deinit();
        }
    };
    var inner = t.vtHandler();
    inner.effects = .readonly;
    var stream = Stream(Handler).init(.{ .handler = .{ .inner = inner, .marks = m, .input_seq = input_seq, .ended = ended }, .allocator = testing.allocator });
    defer stream.deinit();
    stream.nextSlice(bytes);
}

test "marks follow a prompt, a command, and its end, and continuation prompts do not count" {
    var t = try vt.Terminal.init((vt.TinyIo.init).io(), testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit(testing.allocator);
    var m: Marks = .{};
    defer m.deinit(testing.allocator);
    var ended: ?Marks.Ended = null;
    feed(&t, &m, "\x1b]133;A\x07$ \x1b]133;B\x07", 7, &ended);
    try testing.expectEqual(status.Shell.prompt, m.shell);
    try testing.expectEqual(@as(u64, 1), m.prompt_seq);
    try testing.expectEqual(@as(u64, 7), m.prompt_input_seq);
    feed(&t, &m, "ls /nope\r\n\x1b]133;C\x07ls: cannot access\r\n\x1b]133;D;2\x07", 8, &ended);
    try testing.expectEqual(@as(?i32, 2), ended.?.code);
    try testing.expectEqual(@as(?i32, 2), m.last_exit);
    try testing.expectEqual(status.Shell.unknown, m.shell);
    const c = m.last(1)[0];
    try testing.expectEqualStrings("ls /nope", c.command);
    try testing.expectEqualStrings("ls: cannot access", c.output);
    // A continuation prompt's B neither counts nor waits.
    feed(&t, &m, "\x1b]133;A;k=c\x07> \x1b]133;B\x07", 9, &ended);
    try testing.expectEqual(status.Shell.unknown, m.shell);
    try testing.expectEqual(@as(u64, 1), m.prompt_seq);
    // A new prompt ends a command that had no D.
    ended = null;
    feed(&t, &m, "\x1b]133;A\x07$ \x1b]133;B\x07sleep 9\r\n\x1b]133;C\x07^C\r\n\x1b]133;A\x07$ \x1b]133;B\x07", 10, &ended);
    try testing.expectEqual(@as(?i32, null), ended.?.code);
    try testing.expectEqual(status.Shell.prompt, m.shell);
    try testing.expectEqual(@as(u64, 3), m.prompt_seq);
    try testing.expectEqualStrings("sleep 9", m.last(1)[0].command);
}
