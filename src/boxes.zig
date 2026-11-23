//! Boxes over the session that a drawn attach shows (docs/design.md,
//! "Boxes"): which box is open, which one tuppet's line shows, when the
//! keyboard moves to a box and back, and where each of the person's keys
//! goes. Nothing here reads a terminal or a socket. The drawing client
//! (drawn.zig) feeds it the boxes it learns of, where each box fits in
//! the window, keys with the time they were read, cursor reports, and the
//! time; it paints, attaches, and passes keys as this says.

const std = @import("std");
const status = @import("status.zig");

pub const Grab = status.Grab;

const ms = std.time.ns_per_ms;
/// Keys reach a `--grab pause` box once they paused this long after the
/// cursor report, and any session once they paused this long after such
/// a box closed.
pub const settle_ns: i64 = 500 * ms;
/// A cursor report that has not come by then will not.
pub const answer_ns: i64 = 2000 * ms;
/// A box that has the keyboard sleeps after this long without a key.
pub const sleep_ns: i64 = 60 * std.time.ns_per_s;
/// tuppet's key does nothing this soon after it opened or set aside a
/// box, or dismissed a receipt, nor this soon after such a press that did
/// nothing: pressed over and over, it acts once.
pub const quiet_ns: i64 = 1000 * ms;
/// How long a receipt stays, once a key went to the box.
pub const receipt_ns: i64 = 2000 * ms;
/// The daemon runs at most 16 boxes over a session; this leaves room for
/// boxes that ended and are not yet removed here.
pub const max_boxes = 32;

/// Long before any time the client passes.
const long_ago: i64 = std.math.minInt(i64) / 4;

/// A unit of the person's input, as far as boxes care.
pub const Kind = union(enum) {
    /// A pressed key, or a mouse button or wheel report.
    key,
    /// A piece of a paste; all pieces of one go where its first went.
    paste: struct { first: bool, last: bool },
    /// A focus report or mouse motion: no key, so it ends no pause, and
    /// it passes only where keys count.
    quiet,
};

pub const Route = union(enum) {
    drop,
    /// The session underneath.
    under,
    box: u64,
};

/// The role the client holds a box's attach stream in.
pub const Role = enum { none, preview, read, write };

/// A cell of the window as a cursor report names it, counted from 1.
pub const Cell = struct { row: u32, col: u32 };

/// A box's program area in the window, counted from 0.
pub const Place = struct {
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,

    /// The cell a cursor report names when the cursor is on the area's
    /// first cell.
    pub fn first(p: Place) Cell {
        return .{ .row = @as(u32, p.y) + 1, .col = @as(u32, p.x) + 1 };
    }
};

/// Where a box can be shown whole.
pub const Fit = union(enum) {
    /// Not yet: the client has no screen of it, or resizes it to fit.
    pending,
    place: Place,
    /// Not even at the smallest size it may have.
    too_small,

    fn eql(a: Fit, b: Fit) bool {
        return std.meta.eql(a, b);
    }
};

/// The hand-over of the open box, in order.
pub const Phase = enum {
    /// The opening frame, or a change of size or place: the client paints
    /// and asks for a cursor report on the program area's first cell.
    opening,
    /// The report is asked for.
    wait,
    /// The report came; keys wait for a pause (`--grab pause`).
    settle,
    /// Keys count: `keys here`.
    keys,
    /// No key for a minute: any key wakes the box and is dropped.
    asleep,
};

pub const Open = struct {
    id: u64,
    phase: Phase = .opening,
    /// Counts openings, so the client tells one from an ask again.
    serial: u32,
    asked: ?Cell = null,
    asked_at: i64 = 0,
    /// When the report was read.
    report_at: i64 = 0,
    /// When keys came to count.
    keys_at: i64 = 0,
};

/// What tuppet's line says about the box it shows.
pub const LineKind = enum {
    /// It arrived and opens when the person pauses.
    arrived,
    /// The person set it aside; only tuppet's key opens it.
    aside,
    /// The terminal did not answer the cursor report.
    no_answer,
    /// Another client has the box's writer role.
    elsewhere,
    /// It does not fit in the window.
    too_small,
    /// This client does not have the writer role of the session
    /// underneath.
    other_terminal,
};

pub const Line = struct {
    id: u64,
    kind: LineKind,
    /// The other boxes that wait.
    more: usize,
};

/// A box's title, kept for its receipt.
pub const Title = struct {
    buf: [64]u8 = undefined,
    len: u8 = 0,

    /// `s` cut to 64 bytes at a character boundary.
    pub fn of(s: []const u8) Title {
        var n = @min(s.len, 64);
        if (n < s.len) while (n > 0 and s[n] & 0xc0 == 0x80) {
            n -= 1;
        };
        var t: Title = .{ .len = @intCast(n) };
        @memcpy(t.buf[0..n], s[0..n]);
        return t;
    }

    pub fn text(t: *const Title) []const u8 {
        return t.buf[0..t.len];
    }
};

/// The line that tells how a box ended.
pub const Receipt = struct {
    title: Title,
    /// When it goes; null: by a key, as `by_key` says, or, `aside`, only
    /// by tuppet's key.
    until: ?i64,
    /// The box got no key: the receipt goes at the first key after the
    /// dropped ones, or 2 seconds after a box waits.
    by_key: bool = false,
    /// The box ended while set aside.
    aside: bool,
};

pub const Action = enum { none, detach };

const Box = struct {
    id: u64,
    grab: Grab,
    title: Title,
    fit: Fit = .pending,
    /// Another client has its writer role.
    elsewhere: bool = false,
    /// Its program asked for bracketed paste.
    brackets: bool = false,
    no_answer: bool = false,
    /// The person set it aside: it opens only by tuppet's key.
    aside: bool = false,
    /// It was open when the window became too small: it opens again once
    /// it fits.
    refit: bool = false,
    /// A key went to it.
    keyed: bool = false,
    /// The bell rang for its arrival.
    rang: bool = false,
    /// A `--grab now` box set it aside: it arrives again, with a bell,
    /// when it is next the line.
    again: bool = false,
};

pub const Boxes = struct {
    /// `[attach] box_pause`.
    pause_ns: i64 = 1000 * ms,
    /// tuppet's key never detaches while this client has the writer role.
    no_detach: bool = false,
    /// The person may set an open box aside, with tuppet's key or Esc;
    /// without, tuppet's key detaches from an open box.
    aside: bool = true,
    list: [max_boxes]Box = undefined,
    len: usize = 0,
    /// This client has the writer role of the session underneath.
    writer: bool = true,
    /// The events stream has sent `synced`: until then no box opens.
    synced: bool = false,
    open: ?Open = null,
    serial: u32 = 0,
    line_id: ?u64 = null,
    line_since: i64 = 0,
    receipt: ?Receipt = null,
    /// The box the person set aside: while it lasts, no `--grab pause`
    /// box opens by itself.
    hold: ?u64 = null,
    /// Since when keys are dropped after an open box closed, until they
    /// pause. Only a key read after the pause ends it: one read before
    /// and taken late is still dropped.
    dropping: ?i64 = null,
    /// When the latest key was read.
    last_key: i64 = long_ago,
    /// When Esc last set a box aside, or was dropped after that.
    last_escape: i64 = long_ago,
    /// When tuppet's key last opened or set aside a box, or dismissed a
    /// receipt, or was pressed again within `quiet_ns` of that.
    last_press: i64 = long_ago,
    /// Where the paste that has begun goes.
    paste: ?Route = null,
    /// Asks given up on before their answer came. The terminal answers in
    /// order, so the next this many answers are theirs: each is dropped,
    /// and only the answer after them counts for the open box's ask.
    stale: u64 = 0,
    /// The session underneath ended: since when, and whether keys are
    /// dropped before the attach ends.
    ending: ?struct { at: i64, drop: bool } = null,
    /// The bell is due.
    bell: bool = false,
    /// The next box on the line arrives as a new one, with the bell: a
    /// `--grab pause` box closed, or the receipt of one set aside went.
    arrives: bool = false,

    pub fn get(m: *Boxes, id: u64) ?*Box {
        for (m.list[0..m.len]) |*b| if (b.id == id) return b;
        return null;
    }

    fn openId(m: *const Boxes) ?u64 {
        return if (m.open) |o| o.id else null;
    }

    // ---- what the client learns -----------------------------------------

    /// A box over the session underneath; `title` as its border shows it.
    pub fn add(m: *Boxes, id: u64, grab: Grab, title: []const u8, now: i64) void {
        if (m.get(id) != null or m.len == max_boxes) return;
        m.list[m.len] = .{ .id = id, .grab = grab, .title = .of(title) };
        m.len += 1;
        m.update(now);
    }

    /// The box ended or was removed.
    pub fn remove(m: *Boxes, id: u64, now: i64) void {
        const b = m.get(id) orelse return;
        if (m.openId() == id) {
            m.leave();
            if (b.grab == .pause) {
                m.arrives = true;
                m.dropping = now;
                m.setReceipt(.{ .title = b.title, .until = if (b.keyed) now + receipt_ns else null, .by_key = !b.keyed, .aside = false });
            }
            if (m.hold == id) m.hold = null;
        } else if (m.hold == id) {
            m.hold = null;
            // A box still set aside leaves a receipt, and the hold lasts
            // until that is dismissed.
            if (b.aside) {
                m.setReceipt(.{ .title = b.title, .until = null, .aside = true });
                m.hold = id;
            }
        }
        const i = b - &m.list[0];
        std.mem.copyForwards(Box, m.list[i .. m.len - 1], m.list[i + 1 .. m.len]);
        m.len -= 1;
        m.update(now);
    }

    /// Where the box can be shown whole now. A change while it is open
    /// runs the cursor report, and its pause, again.
    pub fn setFit(m: *Boxes, id: u64, fit: Fit, now: i64) void {
        const b = m.get(id) orelse return;
        if (b.fit.eql(fit)) return;
        b.fit = fit;
        if (m.open) |*o| if (o.id == id) switch (fit) {
            .too_small => {
                m.leave();
                b.refit = true;
            },
            else => if (o.phase != .asleep) m.again(o),
        };
        m.update(now);
    }

    /// Whether another client has the box's writer role.
    pub fn setElsewhere(m: *Boxes, id: u64, on: bool, now: i64) void {
        const b = m.get(id) orelse return;
        if (b.elsewhere == on) return;
        b.elsewhere = on;
        if (on and m.openId() == id) m.leave();
        // Without that writer the box arrives again.
        if (!on and m.line_id == id) m.line_since = now;
        m.update(now);
    }

    /// Whether the box's program asked for bracketed paste.
    pub fn setBrackets(m: *Boxes, id: u64, on: bool) void {
        if (m.get(id)) |b| b.brackets = on;
    }

    /// The daemon refused this client the box's writer role.
    pub fn refused(m: *Boxes, id: u64, now: i64) void {
        m.setElsewhere(id, true, now);
    }

    /// Whether this client has the writer role of the session underneath.
    pub fn setWriter(m: *Boxes, on: bool, now: i64) void {
        if (m.writer == on) return;
        m.writer = on;
        if (!on) m.leave();
        m.update(now);
    }

    /// Whether the events stream is synced: no box opens until it is.
    pub fn setSynced(m: *Boxes, on: bool, now: i64) void {
        m.synced = on;
        m.update(now);
    }

    /// The session underneath ended. When a box was open, keys are
    /// dropped until they pause before the attach ends.
    pub fn underEnded(m: *Boxes, now: i64) void {
        if (m.ending != null) return;
        // Keys meant for a box that is open, or closed moments ago, never
        // reach the person's shell.
        m.ending = .{ .at = now, .drop = m.open != null or m.inDrop(now) };
        m.leave();
        if (m.paste != null) m.paste = .drop;
        m.receipt = null;
        m.update(now);
    }

    /// The attach may end: the session underneath ended, and keys paused
    /// if they had to.
    pub fn finished(m: *const Boxes, now: i64, typing: ?i64) bool {
        const e = m.ending orelse return false;
        return !e.drop or now - @max(e.at, m.quietFrom(typing)) >= settle_ns;
    }

    // ---- time -----------------------------------------------------------

    /// Act on the time. `typing`: when the client read input that is not
    /// a whole unit yet, which counts as a key.
    pub fn tick(m: *Boxes, now: i64, typing: ?i64) void {
        const quiet = m.quietFrom(typing);
        if (m.receipt) |r| if (r.until) |until| if (now >= until) m.dismiss();
        if (m.open) |*o| switch (o.phase) {
            .wait => if (now - o.asked_at >= answer_ns) m.noAnswer(),
            .settle => if (now - @max(o.report_at, quiet) >= settle_ns) {
                o.phase = .keys;
                o.keys_at = now;
            },
            .keys => if (m.get(o.id).?.grab == .pause and now - @max(o.keys_at, quiet) >= sleep_ns) {
                o.phase = .asleep;
                m.cutPaste();
            },
            .opening, .asleep => {},
        };
        m.update(now);
        m.openDue(now, quiet);
        m.update(now);
    }

    /// When `tick` next has something to do.
    pub fn deadline(m: *const Boxes, typing: ?i64) ?i64 {
        const quiet = m.quietFrom(typing);
        var at: ?i64 = null;
        if (m.receipt) |r| if (r.until) |until| {
            at = earliest(at, until);
        };
        if (m.ending) |e| if (e.drop) {
            at = earliest(at, @max(e.at, quiet) + settle_ns);
        };
        if (m.open) |o| switch (o.phase) {
            .wait => at = earliest(at, o.asked_at + answer_ns),
            .settle => at = earliest(at, @max(o.report_at, quiet) + settle_ns),
            .keys => if (m.getConst(o.id).?.grab == .pause) {
                at = earliest(at, @max(o.keys_at, quiet) + sleep_ns);
            },
            .opening, .asleep => {},
        } else if (m.receipt == null) if (m.line_id) |id| {
            const b = m.getConst(id).?;
            if (m.writer and ready(b) and b.grab == .pause and m.hold == null and !b.aside) at = earliest(at, @max(m.line_since, quiet) + m.pause_ns);
        };
        return at;
    }

    fn earliest(a: ?i64, b: i64) i64 {
        return if (a) |x| @min(x, b) else b;
    }

    fn quietFrom(m: *const Boxes, typing: ?i64) i64 {
        return @max(m.last_key, typing orelse long_ago);
    }

    // ---- the person's input ---------------------------------------------

    /// Where a unit read at `at` goes.
    pub fn route(m: *Boxes, kind: Kind, at: i64) Route {
        switch (kind) {
            .quiet => {
                if (m.ending != null or m.inDrop(at)) return .drop;
                if (m.open) |*o| return if (o.phase == .keys and at >= o.keys_at and !m.sleepsBy(o, at)) .{ .box = o.id } else .drop;
                return .under;
            },
            .key => return m.keyRoute(at, false),
            .paste => |p| {
                if (!p.first) {
                    const r = m.paste orelse return .drop;
                    if (p.last) m.paste = null;
                    m.noteKey(at);
                    return r;
                }
                const r = m.keyRoute(at, true);
                m.paste = if (p.last) null else r;
                return r;
            },
        }
    }

    fn keyRoute(m: *Boxes, at: i64, paste: bool) Route {
        defer m.noteKey(at);
        if (m.ending != null or m.inDrop(at)) return .drop;
        if (m.open) |*o| {
            const b = m.get(o.id).?;
            switch (o.phase) {
                .keys => {
                    if (m.sleepsBy(o, at)) {
                        m.again(o);
                        return .drop;
                    }
                    // Read before keys came to count, which this key would
                    // have prevented: the pause starts over.
                    if (b.grab == .pause and at < o.keys_at and at - @max(o.report_at, m.last_key) < settle_ns) {
                        o.phase = .settle;
                        return .drop;
                    }
                    if (paste and !b.brackets) return .drop;
                    b.keyed = true;
                    return .{ .box = b.id };
                },
                .asleep => {
                    m.again(o);
                    return .drop;
                },
                .opening, .wait, .settle => return .drop,
            }
        }
        // A receipt of a box that got no key stays until this key, which
        // goes on.
        if (m.receipt) |r| if (r.by_key) m.dismiss();
        return .under;
    }

    /// Whether the open box slept before `at`, though no tick said so yet.
    fn sleepsBy(m: *Boxes, o: *Open, at: i64) bool {
        return m.get(o.id).?.grab == .pause and at - @max(o.keys_at, m.last_key) >= sleep_ns;
    }

    fn noteKey(m: *Boxes, at: i64) void {
        m.last_key = @max(m.last_key, at);
    }

    /// Whether keys are dropped after a box closed; ends the dropping once
    /// they paused.
    fn inDrop(m: *Boxes, at: i64) bool {
        const d = m.dropping orelse return false;
        if (at - @max(d, m.last_key) < settle_ns) return true;
        m.dropping = null;
        return false;
    }

    /// tuppet's key, read at `at`.
    pub fn press(m: *Boxes, at: i64) Action {
        defer m.noteKey(at);
        if (m.ending != null or m.inDrop(at)) return .none;
        if (at - m.last_press < quiet_ns) {
            m.last_press = at;
            return .none;
        }
        if (m.open) |*o| {
            if (o.phase == .asleep or (o.phase == .keys and m.sleepsBy(o, at))) {
                m.again(o);
                return .none;
            }
            if (!m.aside) return if (m.no_detach and m.writer) .none else .detach;
            m.setAside(at);
            return .none;
        }
        if (m.receipt != null) {
            m.dismiss();
            m.last_press = at;
            m.update(at);
            return .none;
        }
        if (m.line_id) |id| {
            const b = m.get(id).?;
            if (m.writer and b.fit == .place and !b.elsewhere) {
                m.openBox(b);
                m.last_press = at;
                m.update(at);
                return .none;
            }
        }
        return if (m.no_detach and m.writer) .none else .detach;
    }

    /// Esc, read at `at`: true when it set the open box aside, or came
    /// within `quiet_ns` of an Esc that did, or of one dropped this way;
    /// false when it is a key like any other. It acts only on a box that
    /// takes keys: one typed during the hand-over is dropped as any key.
    pub fn escape(m: *Boxes, at: i64) bool {
        if (!m.aside or m.ending != null) return false;
        if (m.open) |*o| {
            if (o.phase != .keys or at < o.keys_at or m.sleepsBy(o, at)) return false;
            m.noteKey(at);
            m.setAside(at);
            m.last_escape = at;
            return true;
        }
        if (at - m.last_escape >= quiet_ns) return false;
        m.noteKey(at);
        m.last_escape = at;
        return true;
    }

    fn setAside(m: *Boxes, at: i64) void {
        const b = m.get(m.open.?.id).?;
        b.aside = true;
        m.hold = b.id;
        m.leave();
        m.last_press = at;
        m.update(at);
    }

    /// A cursor report naming `cell`, read at `at`: true when it was
    /// tuppet's, false when it is a key (as F3 with a modifier is).
    pub fn report(m: *Boxes, cell: Cell, at: i64) bool {
        // A box's first program cell is never in the top row, where F3
        // with a modifier reports.
        if (cell.row <= 1) return false;
        if (m.stale > 0) {
            m.stale -= 1;
            return true;
        }
        const o = &(m.open orelse return false);
        if (o.phase != .wait) return false;
        const asked_cell = o.asked orelse return false;
        // The answer to this ask, but not naming its cell: the box keeps
        // waiting, and goes back to the line if no answer comes.
        if (!std.meta.eql(asked_cell, cell) or at < o.asked_at) {
            o.asked = null;
            return true;
        }
        {
            o.report_at = at;
            if (m.get(o.id).?.grab == .now) {
                o.phase = .keys;
                o.keys_at = at;
            } else o.phase = .settle;
            return true;
        }
    }

    /// The cell to ask a cursor report about, once the client has painted
    /// the frame; null when none is due.
    pub fn ask(m: *const Boxes) ?Cell {
        const o = m.open orelse return null;
        if (o.phase != .opening) return null;
        return switch (m.getConst(o.id).?.fit) {
            .place => |p| p.first(),
            else => null,
        };
    }

    /// The client asked for the report.
    pub fn asked(m: *Boxes, now: i64) void {
        const cell = m.ask() orelse return;
        const o = &m.open.?;
        o.phase = .wait;
        o.asked = cell;
        o.asked_at = now;
    }

    // ---- what the client shows ------------------------------------------

    pub fn takeBell(m: *Boxes) bool {
        defer m.bell = false;
        return m.bell;
    }

    /// The role to hold the box's stream in.
    pub fn role(m: *const Boxes, id: u64) Role {
        const b = m.getConst(id) orelse return .none;
        if (b.grab == .never) return if (m.never() == id and b.fit == .place) .read else .preview;
        if (m.open) |o| if (o.id == id) return if (o.phase == .keys) .write else .read;
        return .preview;
    }

    /// The box that has the keyboard, whose input modes the person's
    /// terminal gets.
    pub fn keyboard(m: *const Boxes) ?u64 {
        return m.openId();
    }

    /// Whether the box opens as soon as it fits, so the client finds
    /// where it fits though nothing shows it yet.
    pub fn opensAtOnce(m: *const Boxes, id: u64) bool {
        if (!m.synced or !m.writer or m.ending != null) return false;
        const b = m.getConst(id) orelse return false;
        return m.preempts(b);
    }

    /// The `--grab never` box that is painted: the oldest.
    pub fn never(m: *const Boxes) ?u64 {
        var oldest: ?u64 = null;
        for (m.list[0..m.len]) |b| if (b.grab == .never and (oldest == null or b.id < oldest.?)) {
            oldest = b.id;
        };
        return oldest;
    }

    pub fn line(m: *const Boxes) ?Line {
        const id = m.line_id orelse return null;
        const b = m.getConst(id).?;
        const kind: LineKind = if (!m.writer)
            .other_terminal
        else if (b.elsewhere)
            .elsewhere
        else if (b.fit == .too_small)
            .too_small
        else if (b.no_answer)
            .no_answer
        else if (b.aside or m.hold != null)
            .aside
        else
            .arrived;
        return .{ .id = id, .kind = kind, .more = m.waiting() -| 1 };
    }

    /// The open box's place in the order, from 1, and how many boxes the
    /// order holds.
    pub fn position(m: *const Boxes) struct { at: usize, of: usize } {
        var ids: [max_boxes]u64 = undefined;
        const all = m.order(&ids);
        const id = m.openId() orelse return .{ .at = 0, .of = all.len };
        const at = std.mem.indexOfScalar(u64, all, id) orelse 0;
        return .{ .at = at + 1, .of = all.len };
    }

    /// The boxes that take keys and are not open.
    pub fn waiting(m: *const Boxes) usize {
        var n: usize = 0;
        for (m.list[0..m.len]) |b| if (b.grab != .never and m.openId() != b.id) {
            n += 1;
        };
        return n;
    }

    // ---- inside ---------------------------------------------------------

    fn getConst(m: *const Boxes, id: u64) ?*const Box {
        for (m.list[0..m.len]) |*b| if (b.id == id) return b;
        return null;
    }

    /// The boxes that take keys, in order: `--grab now` newest first,
    /// then `--grab pause` oldest first.
    fn order(m: *const Boxes, buf: *[max_boxes]u64) []u64 {
        var n: usize = 0;
        for ([_]Grab{ .now, .pause }) |grab| {
            const from = n;
            for (m.list[0..m.len]) |b| if (b.grab == grab) {
                buf[n] = b.id;
                n += 1;
            };
            const part = buf[from..n];
            if (grab == .now) std.mem.sort(u64, part, {}, std.sort.desc(u64)) else std.mem.sort(u64, part, {}, std.sort.asc(u64));
        }
        return buf[0..n];
    }

    /// The box tuppet's line shows.
    fn lineBox(m: *const Boxes) ?u64 {
        if (!m.synced or m.open != null or m.receipt != null or m.ending != null) return null;
        if (m.hold) |h| if (m.getConst(h) != null) return h;
        var ids: [max_boxes]u64 = undefined;
        const all = m.order(&ids);
        return if (all.len > 0) all[0] else null;
    }

    /// Follow a change: which box the line shows, and the bell for
    /// arrivals.
    fn update(m: *Boxes, now: i64) void {
        // A receipt that stays until a key gives way to a box that waits.
        if (m.receipt) |*r| if (r.by_key and r.until == null and m.waiting() > 0) {
            r.until = now + receipt_ns;
        };
        const id = m.lineBox();
        if (id != m.line_id) {
            m.line_id = id;
            m.line_since = now;
            if (id) |i| {
                const b = m.get(i).?;
                if (b.again or m.arrives) {
                    b.again = false;
                    m.arrives = false;
                    if (m.writer) m.bell = true;
                }
            }
        }
        if (m.synced and m.writer) for (m.list[0..m.len]) |*b| if (b.grab == .pause and !b.rang) {
            b.rang = true;
            m.bell = true;
        };
    }

    fn ready(b: *const Box) bool {
        return b.fit == .place and !b.elsewhere and !b.no_answer;
    }

    /// Whether `b` is a `--grab now` box that opens as soon as it fits,
    /// whatever else shows: over any open box but a newer `--grab now`
    /// box, a box set aside, or a receipt.
    fn preempts(m: *const Boxes, b: *const Box) bool {
        if (b.grab != .now or b.aside or b.elsewhere or b.no_answer or m.openId() == b.id) return false;
        const o = m.open orelse return true;
        return !(m.getConst(o.id).?.grab == .now and o.id > b.id);
    }

    /// Open what opens by itself.
    fn openDue(m: *Boxes, now: i64, quiet: i64) void {
        if (!m.synced or !m.writer or m.ending != null) return;
        var newest: ?*Box = null;
        for (m.list[0..m.len]) |*b| if (m.preempts(b) and ready(b)) {
            if (newest == null or b.id > newest.?.id) newest = b;
        };
        if (newest) |b| {
            if (m.open) |o| m.displace(o.id);
            m.openBox(b);
            return;
        }
        if (m.open != null or m.receipt != null) return;
        const id = m.lineBox() orelse return;
        const b = m.get(id).?;
        if (!ready(b)) return;
        if (b.refit or (b.grab == .pause and m.hold == null and !b.aside and now - @max(m.line_since, quiet) >= m.pause_ns)) m.openBox(b);
    }

    fn openBox(m: *Boxes, b: *Box) void {
        m.leave();
        m.cutPaste();
        m.arrives = false;
        m.serial +%= 1;
        m.open = .{ .id = b.id, .serial = m.serial };
        b.no_answer = false;
        b.refit = false;
        b.aside = false;
        m.dismiss();
    }

    /// A `--grab now` box opens over the open one, which waits again
    /// without a hold.
    fn displace(m: *Boxes, id: u64) void {
        const b = m.get(id).?;
        b.aside = false;
        b.again = b.grab == .pause;
        if (m.hold == id) m.hold = null;
        m.leave();
    }

    /// Run the cursor report, and its pause, again.
    fn again(m: *Boxes, o: *Open) void {
        m.giveUp(o);
        m.cutPaste();
        o.phase = .opening;
    }

    fn noAnswer(m: *Boxes) void {
        m.get(m.open.?.id).?.no_answer = true;
        m.leave();
    }

    /// The open box no longer has the keyboard, however that came about:
    /// the paste that went to it ends, and an answer to its ask that is
    /// still to come is tuppet's, not a key.
    fn leave(m: *Boxes) void {
        const o = &(m.open orelse return);
        m.giveUp(o);
        m.cutPaste();
        m.open = null;
    }

    fn giveUp(m: *Boxes, o: *Open) void {
        if (o.phase != .wait or o.asked == null) return;
        m.stale += 1;
    }

    /// The keyboard moves: the rest of a paste that has begun is dropped.
    fn cutPaste(m: *Boxes) void {
        if (m.paste != null) m.paste = .drop;
    }

    fn setReceipt(m: *Boxes, r: Receipt) void {
        m.dismiss();
        m.receipt = r;
    }

    fn dismiss(m: *Boxes) void {
        const r = m.receipt orelse return;
        if (r.aside) {
            m.hold = null;
            m.arrives = true;
        }
        m.receipt = null;
    }
};

// ---- where a box goes ---------------------------------------------------

/// A box placed in the window: its program area, and the margin around
/// its border.
pub const Placed = struct { place: Place, margin: u16 };

pub const Placement = union(enum) {
    placed: Placed,
    /// The box's session is to be resized to this, to fit.
    resize: [2]u16,
    too_small,
};

/// The smallest a box is resized to: 20x5, or its starting size where
/// that is smaller.
fn minSize(start: [2]u16) [2]u16 {
    return .{ @min(20, start[0]), @min(5, start[1]) };
}

/// Where a box of `size` that takes keys sits in a window of `window`:
/// its left column is floor((C - W) / 2) and its top row floor((R - H) /
/// 3), W and H with its border and margin. In a window that is too small,
/// the margin goes first, then the box is resized to fit.
pub fn placeOpen(window: [2]u16, size: [2]u16, start: [2]u16) Placement {
    const c: u32 = window[0];
    const r: u32 = window[1];
    for ([_]u16{ 1, 0 }) |margin| {
        const w = @as(u32, size[0]) + 2 + 2 * @as(u32, margin);
        const h = @as(u32, size[1]) + 2 + 2 * @as(u32, margin);
        if (w <= c and h <= r) return .{ .placed = .{ .margin = margin, .place = .{
            .x = @intCast((c - w) / 2 + 1 + margin),
            .y = @intCast((r - h) / 3 + 1 + margin),
            .cols = size[0],
            .rows = size[1],
        } } };
    }
    return shrink(window, size, start);
}

/// Where a `--grab never` box sits: its border's top right corner in the
/// window's, `top` rows lower, with no margin.
pub fn placeNever(window: [2]u16, size: [2]u16, start: [2]u16, top: u16) Placement {
    const w = @as(u32, size[0]) + 2;
    const h = @as(u32, size[1]) + 2 + top;
    if (w <= window[0] and h <= window[1]) return .{ .placed = .{ .margin = 0, .place = .{
        .x = @intCast(window[0] - w + 1),
        .y = top + 1,
        .cols = size[0],
        .rows = size[1],
    } } };
    return shrink(.{ window[0], window[1] -| top }, size, start);
}

fn shrink(window: [2]u16, size: [2]u16, start: [2]u16) Placement {
    const least = minSize(start);
    if (window[0] < least[0] + 2 or window[1] < least[1] + 2) return .too_small;
    return .{ .resize = .{ @min(size[0], window[0] - 2), @min(size[1], window[1] - 2) } };
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;

test "a box sits above the middle, loses its margin first, and is resized no smaller than it may be" {
    const at = placeOpen(.{ 80, 24 }, .{ 30, 6 }, .{ 30, 6 }).placed;
    // W 34, H 10: left (80-34)/2 = 23, top (24-10)/3 = 4.
    try testing.expectEqual(Placed{ .margin = 1, .place = .{ .x = 25, .y = 6, .cols = 30, .rows = 6 } }, at);
    try testing.expectEqual(@as(u16, 0), placeOpen(.{ 33, 9 }, .{ 30, 6 }, .{ 30, 6 }).placed.margin);
    try testing.expectEqual(Placement{ .resize = .{ 22, 6 } }, placeOpen(.{ 24, 9 }, .{ 30, 6 }, .{ 30, 6 }));
    try testing.expectEqual(Placement.too_small, placeOpen(.{ 21, 9 }, .{ 30, 6 }, .{ 30, 6 }));
    // A box that started smaller than 20x5 may stay that small.
    try testing.expectEqual(Placement{ .resize = .{ 10, 3 } }, placeOpen(.{ 12, 5 }, .{ 10, 4 }, .{ 10, 3 }));
    try testing.expectEqual(Placed{ .margin = 0, .place = .{ .x = 69, .y = 2, .cols = 10, .rows = 3 } }, placeNever(.{ 80, 24 }, .{ 10, 3 }, .{ 10, 3 }, 1).placed);
}

test "each --grab pause box rings once as it arrives, also when it takes the line after another closed" {
    var m: Boxes = .{ .pause_ns = 100 * ms };
    const fit: Fit = .{ .place = .{ .x = 2, .y = 2, .cols = 20, .rows = 5 } };
    m.setSynced(true, 0);
    m.add(1, .pause, "one", 0);
    m.add(2, .pause, "two", 0);
    m.setFit(1, fit, 0);
    m.setFit(2, fit, 0);
    try testing.expect(m.takeBell());
    m.tick(200 * ms, null);
    try testing.expectEqual(@as(?u64, 1), m.keyboard());
    try testing.expect(!m.takeBell());
    m.remove(1, 300 * ms);
    try testing.expect(!m.takeBell());
    // The receipt goes at the first key after the dropped ones.
    try testing.expectEqual(Route.drop, m.route(.key, 310 * ms));
    try testing.expectEqual(Route.under, m.route(.key, 900 * ms));
    m.tick(900 * ms, null);
    try testing.expectEqual(@as(?u64, 2), m.line_id);
    try testing.expect(m.takeBell());
}

test "the receipt of a box that got no key gives way to a box that waits, without a key" {
    var m: Boxes = .{ .pause_ns = 100 * ms };
    const fit: Fit = .{ .place = .{ .x = 2, .y = 2, .cols = 20, .rows = 5 } };
    m.setSynced(true, 0);
    m.add(1, .pause, "one", 0);
    m.setFit(1, fit, 0);
    m.tick(200 * ms, null);
    try testing.expectEqual(@as(?u64, 1), m.keyboard());
    m.remove(1, 300 * ms);
    // Nothing waits: the receipt stays.
    m.tick(10_000 * ms, null);
    try testing.expect(m.receipt != null);
    m.add(2, .pause, "two", 10_000 * ms);
    m.setFit(2, fit, 10_000 * ms);
    m.tick(10_000 * ms + receipt_ns, null);
    try testing.expect(m.receipt == null);
    try testing.expectEqual(@as(?u64, 2), m.line_id);
    m.tick(10_000 * ms + receipt_ns + 100 * ms, null);
    try testing.expectEqual(@as(?u64, 2), m.keyboard());
}

const test_fit: Fit = .{ .place = .{ .x = 10, .y = 3, .cols = 30, .rows = 6 } };

/// Boxes with `grabs`, numbered from 1, that fit.
fn testBoxes(grabs: []const Grab) Boxes {
    var m: Boxes = .{ .pause_ns = 100 * ms };
    m.setSynced(true, 0);
    for (grabs, 1..) |grab, id| {
        m.add(id, grab, "box", 0);
        m.setFit(id, test_fit, 0);
    }
    return m;
}

/// The open box's hand-over from `at`: its report, then for `--grab
/// pause` the 500 ms; returns when keys count.
fn handOver(m: *Boxes, at: i64) !i64 {
    m.tick(at, null);
    m.asked(at);
    try testing.expect(m.report(test_fit.place.first(), at + ms));
    m.tick(at + 600 * ms, null);
    try testing.expectEqual(Phase.keys, m.open.?.phase);
    return at + 600 * ms;
}

test "an answer to an ask that was given up on is tuppet's, and never answers a newer ask" {
    const cell = test_fit.place.first();
    // Set aside before the terminal answered.
    var m = testBoxes(&.{.pause});
    m.tick(200 * ms, null);
    m.asked(200 * ms);
    _ = m.press(210 * ms);
    try testing.expect(m.report(cell, 250 * ms));
    // A --grab now box that ended while its answer was on the way.
    m = testBoxes(&.{.now});
    m.tick(0, null);
    m.asked(0);
    m.remove(1, 5 * ms);
    try testing.expect(m.report(cell, 20 * ms));
    // No answer in time; opened again at the same cell, the first answer
    // comes late and the box still waits for its own.
    m = testBoxes(&.{.now});
    m.tick(0, null);
    m.asked(0);
    m.tick(2100 * ms, null);
    try testing.expect(m.open == null);
    _ = m.press(3000 * ms);
    m.tick(3000 * ms, null);
    m.asked(3000 * ms);
    try testing.expect(m.report(cell, 3010 * ms));
    try testing.expectEqual(Phase.wait, m.open.?.phase);
    try testing.expect(m.report(cell, 3020 * ms));
    try testing.expectEqual(Phase.keys, m.open.?.phase);
    // A report no ask is waiting for is a key, as F3 with a modifier.
    try testing.expect(!m.report(.{ .row = 1, .col = 2 }, 3030 * ms));
}

test "however many asks were given up on, each answer is tuppet's and only the last counts" {
    var m = testBoxes(&.{.now});
    const other: Fit = .{ .place = .{ .x = 4, .y = 1, .cols = 30, .rows = 6 } };
    var cells: [21]Cell = undefined;
    for (&cells, 0..) |*cell, i| {
        const t: i64 = @intCast(i * ms);
        if (i > 0) m.setFit(1, if (i % 2 == 1) other else test_fit, t);
        m.tick(t, null);
        cell.* = m.ask().?;
        m.asked(t);
    }
    for (cells, 0..) |cell, i| {
        try testing.expectEqual(Phase.wait, m.open.?.phase);
        try testing.expect(m.report(cell, @intCast((100 + i) * ms)));
    }
    try testing.expectEqual(Phase.keys, m.open.?.phase);
}

test "the rest of a paste goes nowhere once the keyboard moves" {
    var m = testBoxes(&.{.now});
    m.setBrackets(1, true);
    m.tick(0, null);
    m.asked(0);
    _ = m.report(test_fit.place.first(), 10 * ms);
    try testing.expectEqual(Route{ .box = 1 }, m.route(.{ .paste = .{ .first = true, .last = false } }, 20 * ms));
    m.setFit(1, .too_small, 30 * ms);
    try testing.expectEqual(Route.drop, m.route(.{ .paste = .{ .first = false, .last = false } }, 40 * ms));
    // A paste going to the session underneath ends where a box opens.
    m = testBoxes(&.{});
    try testing.expectEqual(Route.under, m.route(.{ .paste = .{ .first = true, .last = false } }, 0));
    m.add(1, .now, "box", ms);
    m.setFit(1, test_fit, ms);
    m.tick(ms, null);
    try testing.expectEqual(Route.drop, m.route(.{ .paste = .{ .first = false, .last = true } }, 2 * ms));
}

test "when the session underneath ends, keys meant for a box are dropped until they pause" {
    // While the box is open.
    var m = testBoxes(&.{.pause});
    m.tick(200 * ms, null);
    var t = try handOver(&m, 200 * ms);
    try testing.expectEqual(Route{ .box = 1 }, m.route(.key, t));
    m.underEnded(t + 100 * ms);
    try testing.expectEqual(Route.drop, m.route(.key, t + 300 * ms));
    try testing.expect(!m.finished(t + 700 * ms, null));
    try testing.expect(m.finished(t + 800 * ms, null));
    // Moments after it closed.
    m = testBoxes(&.{.pause});
    m.tick(200 * ms, null);
    t = try handOver(&m, 200 * ms);
    m.remove(1, t);
    _ = m.route(.key, t + 50 * ms);
    m.underEnded(t + 100 * ms);
    try testing.expect(!m.finished(t + 150 * ms, null));
    // Long after it closed, the attach ends at once.
    m = testBoxes(&.{.pause});
    m.tick(200 * ms, null);
    t = try handOver(&m, 200 * ms);
    m.remove(1, t);
    m.underEnded(t + 10_000 * ms);
    try testing.expect(m.finished(t + 10_000 * ms, null));
    // With no box, the attach ends at once.
    m = testBoxes(&.{});
    m.underEnded(0);
    try testing.expect(m.finished(0, null));
}

test "tuppet's key sets a box aside and holds the others, never detaches while one is there, and dismisses a receipt" {
    var m = testBoxes(&.{ .pause, .pause });
    _ = m.takeBell();
    m.tick(200 * ms, null);
    try testing.expectEqual(@as(?u64, 1), m.keyboard());
    try testing.expectEqual(Action.none, m.press(300 * ms));
    try testing.expectEqual(@as(?u64, null), m.keyboard());
    try testing.expectEqual(Line{ .id = 1, .kind = .aside, .more = 1 }, m.line().?);
    // The hold: nothing opens by itself.
    m.tick(5000 * ms, null);
    try testing.expectEqual(@as(?u64, null), m.keyboard());
    try testing.expectEqual(Action.none, m.press(5100 * ms));
    try testing.expectEqual(@as(?u64, 1), m.keyboard());
    // Right after it opened the box, the key does nothing.
    try testing.expectEqual(Action.none, m.press(5600 * ms));
    try testing.expectEqual(@as(?u64, 1), m.keyboard());
    // Pressed over and over at the open box, it sets it aside once and
    // does nothing else.
    var at: i64 = 6700 * ms;
    while (at < 8000 * ms) : (at += 100 * ms) try testing.expectEqual(Action.none, m.press(at));
    try testing.expectEqual(Line{ .id = 1, .kind = .aside, .more = 1 }, m.line().?);
    // It ended while set aside: its receipt holds the others until the
    // key dismisses it, and the next box arrives with the bell.
    m.remove(1, 8100 * ms);
    m.tick(10_000 * ms, null);
    try testing.expectEqual(@as(?u64, null), m.keyboard());
    try testing.expect(m.receipt.?.aside);
    try testing.expectEqual(Action.none, m.press(10_500 * ms));
    try testing.expect(m.receipt == null);
    try testing.expectEqual(@as(?u64, 2), m.line_id);
    try testing.expect(m.takeBell());
    m.tick(10_650 * ms, null);
    try testing.expectEqual(@as(?u64, 2), m.keyboard());
}

test "Esc sets aside a box that takes keys, once; without setting aside, tuppet's key detaches from an open box and Esc is a key" {
    var m = testBoxes(&.{.pause});
    m.tick(200 * ms, null);
    // During the hand-over it is dropped as any key.
    try testing.expect(!m.escape(300 * ms));
    try testing.expectEqual(@as(?u64, 1), m.open.?.id);
    const t = try handOver(&m, 300 * ms);
    try testing.expect(m.escape(t));
    try testing.expectEqual(@as(?u64, null), m.keyboard());
    try testing.expectEqual(LineKind.aside, m.line().?.kind);
    // Pressed over and over, it reaches the session underneath only once
    // it paused for a second.
    try testing.expect(m.escape(t + 600 * ms));
    try testing.expect(m.escape(t + 1200 * ms));
    try testing.expect(!m.escape(t + 2300 * ms));

    m = testBoxes(&.{.pause});
    m.aside = false;
    m.tick(200 * ms, null);
    try testing.expect(!m.escape(300 * ms));
    try testing.expectEqual(Action.detach, m.press(400 * ms));
    try testing.expectEqual(@as(?u64, 1), m.keyboard());
}

test "--grab now boxes open at once, newest first, and a box they set aside arrives again" {
    var m = testBoxes(&.{.pause});
    m.tick(200 * ms, null);
    _ = try handOver(&m, 200 * ms);
    _ = m.takeBell();
    for ([_]u64{ 2, 3 }) |id| {
        m.add(id, .now, "now", 900 * ms);
        m.setFit(id, test_fit, 900 * ms);
        m.tick(900 * ms, null);
        try testing.expectEqual(@as(?u64, id), m.keyboard());
    }
    try testing.expectEqual(@as(usize, 1), m.position().at);
    try testing.expectEqual(@as(usize, 3), m.position().of);
    m.remove(3, 1000 * ms);
    m.tick(1000 * ms, null);
    try testing.expectEqual(@as(?u64, 2), m.keyboard());
    m.remove(2, 1100 * ms);
    m.tick(1100 * ms, null);
    try testing.expectEqual(@as(?u64, 1), m.line_id);
    try testing.expect(m.takeBell());
    m.tick(1250 * ms, null);
    try testing.expectEqual(@as(?u64, 1), m.keyboard());
}

test "a --grab now box opens at once over an open box, a box set aside, and a receipt" {
    for (0..3) |state| {
        var m = testBoxes(&.{.pause});
        m.tick(200 * ms, null);
        switch (state) {
            0 => {},
            1 => _ = m.press(300 * ms),
            else => m.remove(1, 300 * ms),
        }
        m.add(2, .now, "now", 400 * ms);
        // The client finds where it fits, though nothing shows it yet.
        try testing.expect(m.line_id != 2 and m.opensAtOnce(2));
        m.setFit(2, test_fit, 400 * ms);
        m.tick(400 * ms, null);
        try testing.expectEqual(@as(?u64, 2), m.keyboard());
    }
}

test "a box set aside and opened again that a --grab now box displaces arrives again unheld, and ends without a receipt" {
    var m = testBoxes(&.{.pause});
    m.tick(200 * ms, null);
    try testing.expectEqual(Action.none, m.press(300 * ms));
    try testing.expectEqual(Action.none, m.press(1400 * ms));
    try testing.expectEqual(@as(?u64, 1), m.keyboard());
    m.add(2, .now, "now", 1500 * ms);
    m.setFit(2, test_fit, 1500 * ms);
    m.tick(1500 * ms, null);
    try testing.expectEqual(@as(?u64, 2), m.keyboard());
    m.remove(2, 1600 * ms);
    m.tick(1600 * ms, null);
    try testing.expectEqual(Line{ .id = 1, .kind = .arrived, .more = 0 }, m.line().?);
    m.remove(1, 1650 * ms);
    try testing.expect(m.receipt == null and m.hold == null);
}

test "no deadline passes while nothing is due: a --grab now box that takes keys, or a line box that cannot open" {
    var m = testBoxes(&.{.now});
    m.tick(0, null);
    m.asked(0);
    try testing.expect(m.report(test_fit.place.first(), ms));
    try testing.expectEqual(Phase.keys, m.open.?.phase);
    try testing.expectEqual(@as(?i64, null), m.deadline(null));
    m = testBoxes(&.{.pause});
    m.setFit(1, .too_small, 0);
    try testing.expectEqual(@as(?i64, null), m.deadline(null));
    m.setFit(1, test_fit, 0);
    m.setWriter(false, 0);
    try testing.expectEqual(@as(?i64, null), m.deadline(null));
}

test "a box another client controls, or one shown by a client without the writer role, waits as the line" {
    var m = testBoxes(&.{.pause});
    m.tick(200 * ms, null);
    m.setElsewhere(1, true, 250 * ms);
    try testing.expectEqual(@as(?u64, null), m.keyboard());
    try testing.expectEqual(LineKind.elsewhere, m.line().?.kind);
    // The key cannot open it, so it acts as with no box.
    try testing.expectEqual(Action.detach, m.press(300 * ms));
    m.no_detach = true;
    try testing.expectEqual(Action.none, m.press(1000 * ms));
    m.setElsewhere(1, false, 1500 * ms);
    m.tick(1550 * ms, null);
    try testing.expectEqual(@as(?u64, null), m.keyboard());
    m.tick(1610 * ms, null);
    try testing.expectEqual(@as(?u64, 1), m.keyboard());
    // Another client took over writing the session underneath.
    const t = try handOver(&m, 1610 * ms);
    m.setWriter(false, t);
    try testing.expectEqual(@as(?u64, null), m.keyboard());
    try testing.expectEqual(LineKind.other_terminal, m.line().?.kind);
    try testing.expectEqual(Role.preview, m.role(1));
    try testing.expectEqual(Action.detach, m.press(t + 1000 * ms));
}

/// Checks the rules of docs/design.md, "Boxes", "Invariants", on
/// what the machine does, independently of how it does it.
const Oracle = struct {
    /// Per box: the latest ask, the correct report for it, and when keys
    /// first paused 500 ms after it.
    epochs: std.AutoHashMapUnmanaged(u64, Epoch) = .empty,
    last_key: i64 = long_ago,
    /// An open or asleep `--grab pause` box closed: since when keys go
    /// nowhere until they pause.
    closing: ?i64 = null,
    open: ?u64 = null,
    paste: ?Route = null,
    /// The session underneath ended: when, and whether keys are dropped
    /// until they pause before the attach may end.
    ending: ?struct { at: i64, drop: bool } = null,
    asks: u32 = 0,
    counts: struct { box_keys: usize = 0, now_keys: usize = 0, dropped_after_close: usize = 0, asleep: usize = 0, pastes_to_box: usize = 0, stale_answers: usize = 0, ending_drops: usize = 0, many_stale: usize = 0 } = .{},

    const Epoch = struct {
        /// Which ask, counted over all of them.
        ask: u32 = 0,
        asked: ?Cell = null,
        asked_at: i64 = 0,
        report_at: ?i64 = null,
        quiet_at: ?i64 = null,
        keys_at: ?i64 = null,
        fit: Fit = .pending,
    };

    fn epoch(o: *Oracle, id: u64) *Epoch {
        const e = o.epochs.getOrPut(testing.allocator, id) catch @panic("oom");
        if (!e.found_existing) e.value_ptr.* = .{};
        return e.value_ptr;
    }

    /// A pause of 500 ms after the report seen at `t`.
    fn quiet(o: *Oracle, e: *Epoch, t: i64) void {
        if (e.report_at) |r| if (e.quiet_at == null and t - @max(r, o.last_key) >= settle_ns) {
            e.quiet_at = @max(r, o.last_key) + settle_ns;
        };
    }

    /// The machine's state after a step at `now`.
    fn observe(o: *Oracle, m: *const Boxes, now: i64) !void {
        const open = m.openId();
        if (o.open != null and o.open != open) if (o.epochs.getPtr(o.open.?)) |e| {
            e.* = .{ .fit = e.fit };
        };
        o.open = open;
        const id = open orelse return;
        const b = m.getConst(id).?;
        const e = o.epoch(id);
        o.quiet(e, now);
        if (m.open.?.phase == .keys) {
            // keys here only after the report for the latest ask, and for
            // --grab pause a pause after it.
            try testing.expect(e.report_at != null);
            if (b.grab == .pause) try testing.expect(e.quiet_at != null);
            if (e.keys_at == null) e.keys_at = now;
        }
        if (m.open.?.phase == .asleep) o.counts.asleep += 1;
    }

    /// Returns the ask's number.
    fn asked(o: *Oracle, id: u64, cell: Cell, now: i64) u32 {
        o.asks += 1;
        const e = o.epoch(id);
        e.* = .{ .ask = o.asks, .asked = cell, .asked_at = now, .fit = e.fit };
        return o.asks;
    }

    /// The answer to ask number `ask` was read at `at`.
    fn reported(o: *Oracle, ask: u32, at: i64) void {
        const id = o.open orelse {
            o.counts.stale_answers += 1;
            return;
        };
        const e = o.epoch(id);
        if (e.ask == ask and e.report_at == null) e.report_at = at else o.counts.stale_answers += 1;
    }

    fn ended(o: *Oracle, m: *const Boxes, now: i64) void {
        const closing = if (o.closing) |c| now - @max(c, o.last_key) < settle_ns else false;
        o.ending = .{ .at = now, .drop = m.openId() != null or closing };
        if (o.ending.?.drop) o.counts.ending_drops += 1;
    }

    /// Whether the attach may end at `now`.
    fn mayFinish(o: *Oracle, now: i64, typing: ?i64) bool {
        const e = o.ending orelse return false;
        return !e.drop or now - @max(e.at, @max(o.last_key, typing orelse long_ago)) >= settle_ns;
    }

    fn fitChanged(o: *Oracle, id: u64, fit: Fit) void {
        const e = o.epoch(id);
        if (!e.fit.eql(fit)) e.* = .{ .fit = fit };
    }

    fn pressed(o: *Oracle, at: i64) void {
        o.late(at);
        if (o.closing) |c| if (at - @max(c, o.last_key) >= settle_ns) {
            o.closing = null;
        };
        o.last_key = @max(o.last_key, at);
    }

    /// A key read inside what looked like the pause after the report:
    /// there was no pause.
    fn late(o: *Oracle, at: i64) void {
        const id = o.open orelse return;
        const e = o.epochs.getPtr(id) orelse return;
        if (e.quiet_at) |q| if (at < q) {
            e.quiet_at = null;
            e.keys_at = null;
        };
    }

    fn closed(o: *Oracle, m: *const Boxes, id: u64, now: i64) void {
        if (m.openId() == id and m.getConst(id).?.grab == .pause) o.closing = now;
        _ = o.epochs.remove(id);
    }

    /// A unit read at `at` went to `r`.
    fn routed(o: *Oracle, m: *const Boxes, before_open: ?Phase, kind: Kind, at: i64, r: Route, brackets: bool) !void {
        const is_key = kind != .quiet;
        const continued = kind == .paste and !kind.paste.first;
        if (is_key) o.late(at);
        if (is_key) if (o.closing) |c| {
            if (at - @max(c, o.last_key) < settle_ns) {
                try testing.expectEqual(Route.drop, r);
                o.counts.dropped_after_close += 1;
            } else o.closing = null;
        };
        if (o.ending != null) try testing.expectEqual(Route.drop, r);
        // While a box has the keyboard the session underneath gets nothing.
        if (before_open != null) try testing.expect(r != .under);
        if (kind == .paste) {
            if (kind.paste.first) {
                o.paste = r;
            } else if (r != .drop) try testing.expectEqual(o.paste.?, r);
            if (kind.paste.last) o.paste = null;
        }
        if (r == .box) {
            const id = r.box;
            const b = m.getConst(id).?;
            const e = o.epoch(id);
            // Shown whole at the place the report was asked for.
            try testing.expect(e.fit == .place and e.asked != null and std.meta.eql(e.fit.place.first(), e.asked.?));
            try testing.expect(e.report_at != null and at >= e.report_at.?);
            if (kind == .quiet) {
                // Not a key: it passes once the border says keys here.
                try testing.expect(e.keys_at != null and at >= e.keys_at.?);
            } else if (b.grab == .pause) {
                o.quiet(e, at);
                try testing.expect(e.quiet_at != null and e.quiet_at.? <= at);
                try testing.expect(at - @max(o.last_key, e.keys_at orelse at) < sleep_ns);
            }
            // Brackets are decided at the first piece.
            if (kind == .paste and !continued) {
                try testing.expect(brackets);
                o.counts.pastes_to_box += 1;
            }
            if (kind != .quiet) {
                if (b.grab == .now) o.counts.now_keys += 1 else o.counts.box_keys += 1;
            }
        }
        if (is_key) o.last_key = @max(o.last_key, at);
    }
};

test "model: no key reaches a box before its hand-over, and none reaches a session right after one closed" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x626f786573);
    const random = prng.random();
    var total: @FieldType(Oracle, "counts") = .{};
    for (0..400) |_| {
        var m: Boxes = .{ .pause_ns = (100 + 100 * @as(i64, random.uintLessThan(u8, 10))) * ms, .no_detach = random.boolean() };
        var o: Oracle = .{};
        defer o.epochs.deinit(gpa);
        var now: i64 = 0;
        m.setSynced(true, now);
        var next_id: u64 = 1;
        // The terminal's answers, in the order it sends them.
        var answers: std.ArrayList(struct { at: i64, cell: Cell, ask: u32 }) = .empty;
        defer answers.deinit(gpa);
        var pending: ?struct { at: i64, kind: Kind } = null;
        const places = [_]Place{ .{ .x = 10, .y = 3, .cols = 30, .rows = 6 }, .{ .x = 4, .y = 1, .cols = 30, .rows = 6 } };
        for (0..300) |_| {
            now += switch (random.uintLessThan(u8, 20)) {
                0...11 => @as(i64, random.uintLessThan(u32, 60)) * ms,
                12...16 => (200 + @as(i64, random.uintLessThan(u32, 500))) * ms,
                17, 18 => (1000 + @as(i64, random.uintLessThan(u32, 1500))) * ms,
                else => 61 * std.time.ns_per_s,
            };
            // Units are taken in the order they were read. An answer to
            // tuppet's ask is tuppet's, however late it comes: it never
            // goes on as a key.
            while (answers.items.len > 0) {
                const rep = answers.items[0];
                if (rep.at > now or (pending != null and rep.at >= pending.?.at)) break;
                _ = answers.orderedRemove(0);
                o.reported(rep.ask, rep.at);
                try testing.expect(m.report(rep.cell, rep.at));
                try o.observe(&m, now);
            }
            const at = now;
            const action = random.uintLessThan(u8, 24);
            // Input read before, waiting for the rest of its unit, comes
            // first.
            if (pending) |p| if (action >= 6 and action <= 20) {
                pending = null;
                const before = if (m.open) |op| op.phase else null;
                try o.routed(&m, before, p.kind, p.at, m.route(p.kind, p.at), m.open != null and m.getConst(m.open.?.id).?.brackets);
                try o.observe(&m, now);
                m.tick(now, null);
                try o.observe(&m, now);
                continue;
            };
            switch (action) {
                0, 1 => {
                    const grab: Grab = switch (random.uintLessThan(u8, 5)) {
                        0, 1, 2 => .pause,
                        3 => .now,
                        else => .never,
                    };
                    m.add(next_id, grab, "box", now);
                    const fit: Fit = .{ .place = places[random.uintLessThan(usize, 2)] };
                    o.fitChanged(next_id, fit);
                    m.setFit(next_id, fit, now);
                    next_id += 1;
                },
                2 => if (m.len > 0) {
                    const id = m.list[random.uintLessThan(usize, m.len)].id;
                    o.closed(&m, id, now);
                    m.remove(id, now);
                },
                3 => if (m.len > 0) {
                    const id = m.list[random.uintLessThan(usize, m.len)].id;
                    const fit: Fit = switch (random.uintLessThan(u8, 6)) {
                        0 => .too_small,
                        1 => .pending,
                        else => .{ .place = places[random.uintLessThan(usize, 2)] },
                    };
                    o.fitChanged(id, fit);
                    m.setFit(id, fit, now);
                },
                4 => if (m.len > 0) {
                    const b = m.list[random.uintLessThan(usize, m.len)];
                    m.setBrackets(b.id, !b.brackets);
                },
                5 => if (m.len > 0) {
                    const b = m.list[random.uintLessThan(usize, m.len)];
                    if (random.boolean()) m.refused(b.id, now) else m.setElsewhere(b.id, false, now);
                },
                6 => {
                    // A report for a cell that was not asked about is a key.
                    const before = if (m.open) |op| op.phase else null;
                    const cell: Cell = .{ .row = 1, .col = 5 };
                    if (!m.report(cell, at)) try o.routed(&m, before, .key, at, m.route(.key, at), false);
                },
                7, 8 => {
                    o.pressed(at);
                    _ = m.press(at);
                },
                9...20 => {
                    const before = if (m.open) |op| op.phase else null;
                    const kind: Kind = switch (random.uintLessThan(u8, 8)) {
                        0 => .{ .paste = .{ .first = o.paste == null, .last = random.boolean() } },
                        1 => .quiet,
                        else => .key,
                    };
                    if (random.uintLessThan(u8, 5) == 0) {
                        pending = .{ .at = at, .kind = kind };
                    } else {
                        const r = m.route(kind, at);
                        const brackets = if (r == .box) m.getConst(r.box).?.brackets else false;
                        try o.routed(&m, before, kind, at, r, brackets);
                    }
                },
                21 => if (m.open) |op| if (random.uintLessThan(u8, 8) == 0) {
                    // The box moves to and fro faster than the terminal
                    // answers: many asks are given up on.
                    const id = op.id;
                    for (0..17 + random.uintLessThan(usize, 6)) |_| {
                        const b = m.getConst(id) orelse break;
                        const fit: Fit = .{ .place = if (b.fit == .place and std.meta.eql(b.fit.place, places[0])) places[1] else places[0] };
                        o.fitChanged(id, fit);
                        m.setFit(id, fit, now);
                        m.tick(now, if (pending) |p| p.at else null);
                        try o.observe(&m, now);
                        const cell = m.ask() orelse break;
                        m.asked(now);
                        const ask = o.asked(m.open.?.id, cell, now);
                        const after = if (answers.getLastOrNull()) |last| last.at else now;
                        try answers.append(gpa, .{ .at = @max(after, now + 50 * ms), .cell = cell, .ask = ask });
                    }
                    if (m.stale > 16) o.counts.many_stale += 1;
                },
                else => {},
            }
            try o.observe(&m, now);
            m.tick(now, if (pending) |p| p.at else null);
            try o.observe(&m, now);
            if (m.ask()) |cell| {
                const id = m.open.?.id;
                m.asked(now);
                const ask = o.asked(id, cell, now);
                // Most terminals answer within a frame or so; some late,
                // some never.
                const delay: i64 = if (random.uintLessThan(u8, 6) == 0) 1500 + @as(i64, random.uintLessThan(u32, 1500)) else random.uintLessThan(u32, 80);
                const after = if (answers.getLastOrNull()) |last| last.at else now;
                if (random.uintLessThan(u8, 8) != 0) try answers.append(gpa, .{ .at = @max(after, now + delay * ms), .cell = cell, .ask = ask });
            }
            if (m.ending == null and random.uintLessThan(u16, 1500) == 0) {
                o.ended(&m, now);
                m.underEnded(now);
            }
            // The attach ends once the machine says so, never before keys
            // meant for a box paused.
            const typing = if (pending) |p| p.at else null;
            if (m.finished(now, typing)) {
                try testing.expect(o.mayFinish(now, typing));
                break;
            }
        }
        inline for (@typeInfo(@TypeOf(total)).@"struct".field_names) |name| @field(total, name) += @field(o.counts, name);
    }
    // The run reached every rule it checks.
    try testing.expect(total.box_keys > 100 and total.now_keys > 100 and total.dropped_after_close > 10 and total.asleep > 0 and total.pastes_to_box > 10 and total.stale_answers > 10 and total.ending_drops > 0 and total.many_stale > 0);
}
