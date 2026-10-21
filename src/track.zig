//! Change tracking. Once the reader has parsed a burst of output it
//! settles the terminal: each row that changed since the last settle is
//! hashed, and rows whose hash changed are stamped with a seq from the
//! daemon-wide counter. Rows keep their identity while they scroll, across
//! a reflow, and into history, so waits, `view --since`, and status can ask
//! what changed after a seq or after the latest input.
//!
//! A settle also matches the session's alerts against the lines that
//! changed (see alert.zig): a line that comes to show an alert's text is
//! due to fire, and the evaluator takes it as a hit. That is the one
//! matching on the output path, bounded by 32 texts of 256 bytes.
//!
//! A Tracker belongs to one session and is guarded by its terminal_mutex,
//! except for the atomic fields, which are read without it.

const std = @import("std");
const vt = @import("vt");
const io_mod = @import("io.zig");
const alert = @import("alert.zig");

const Key = vt.ScreenSet.Key;
const Pin = vt.Pin;
const Page = vt.Page;
const Row = vt.page.Row;
const Cell = vt.Cell;
const PageList = vt.PageList;

/// A settle waits for the pty to drain, but no longer than this, and no
/// longer than this many bytes, after the first unsettled chunk.
pub const settle_max_ns: i64 = 20 * std.time.ns_per_ms;
pub const settle_max_bytes: usize = 1 << 20;
/// Synchronized output (mode 2026) holds a settle back at most this long.
pub const sync_max_ns: i64 = 1 * std.time.ns_per_s;
/// The input snapshot keeps at most this much text.
pub const snapshot_cap: usize = 256 * 1024;
/// Rows that scrolled into history most recently keep their state.
const history_cap: usize = 1024;
/// How many lines ahead a reflow looks for a line's old position.
const reflow_window: usize = 256;
/// Lines that leave the screen while an alert is due to fire on them wait
/// here for the evaluator; more are only counted.
const queue_cap = 64;
/// A run of resizes ends this long after its last resize, and with the
/// next input; until then lines that a reflow placed do not fire again
/// while no more of them show an alert than at the run's first resize.
const held_ns: i64 = 5 * std.time.ns_per_s;
const all_alerts: alert.Mask = std.math.maxInt(alert.Mask);

/// The daemon-wide seq counter. A settle that changes something takes the
/// next seq, so seqs order changes across sessions. Seqs are handed out
/// from blocks that `reserve` has recorded first, so a restarted daemon
/// starts above every seq an earlier one may have used.
pub const Counter = struct {
    lock: std.atomic.Mutex = .unlocked,
    value: u64 = 0,
    limit: u64 = std.math.maxInt(u64),
    block: u64 = 1 << 20,
    /// Records that seqs up to the returned mark plus `n` may be in use,
    /// and returns the mark: the highest seq handed out before.
    reserve: ?*const fn (n: u64) anyerror!u64 = null,
    /// The mark of the next block, reserved while this one lasted.
    ahead: ?u64 = null,
    reserving: bool = false,

    pub fn start(self: *Counter, reserve: *const fn (n: u64) anyerror!u64) !void {
        const mark = try reserve(self.block);
        self.value = mark;
        self.limit = mark + self.block;
        self.reserve = reserve;
    }

    pub fn next(self: *Counter) u64 {
        self.lockSpin();
        while (self.value >= self.limit) {
            if (self.ahead) |mark| {
                self.value = @max(self.value, mark);
                self.limit = mark + self.block;
                self.ahead = null;
            } else {
                const reserve = !self.reserving;
                self.reserving = true;
                self.lock.unlock();
                if (reserve) self.extend() else std.Thread.yield() catch {};
                self.lockSpin();
            }
        }
        self.value += 1;
        const seq = self.value;
        // The next block is reserved halfway through this one, on a thread
        // of its own: callers hold a session's terminal_mutex, and the
        // store's boot lock may be held for a while. The half block left
        // is the headroom.
        const early = self.reserve != null and !self.reserving and self.ahead == null and self.limit - seq <= self.block / 2;
        if (early) self.reserving = true;
        self.lock.unlock();
        if (early) {
            if (std.Thread.spawn(.{}, extend, .{self})) |thread| thread.detach() else |_| self.extend();
        }
        return seq;
    }

    fn lockSpin(self: *Counter) void {
        while (!self.lock.tryLock()) std.Thread.yield() catch {};
    }

    fn extend(self: *Counter) void {
        const result = self.reserve.?(self.block);
        self.lockSpin();
        defer self.lock.unlock();
        self.reserving = false;
        self.ahead = result catch |err| blk: {
            std.log.err("cannot reserve change seqs in the store: {}", .{err});
            break :blk self.limit;
        };
    }
};

/// The daemon's counter, started from the store.
pub var counter: Counter = .{};

/// The change seq of a row whose last change the tracker does not know: a
/// resize brought it back from history it no longer tracked.
pub const unknown_seq: u64 = std.math.maxInt(u64);

/// What the tracker knows about one row. Seqs are those of the settles
/// that last saw the row change; per-row alert state belongs here too.
pub const RowState = struct {
    /// Everything visible: text, resolved style, width, hyperlink; 0 until
    /// the row has been hashed.
    hash: u64 = 0,
    /// What plain text shows.
    text_hash: u64 = 0,
    change_seq: u64 = 0,
    text_change_seq: u64 = 0,
    /// The last settle that found the row's text gone.
    blank_seq: u64 = 0,
    /// The alerts whose text the row's line shows, kept on the line's
    /// first row.
    alerts: alert.Mask = 0,
    /// The alerts that may fire on the row: their bit was 0 at a settle
    /// since the evaluator last took a hit of them here. An alert is due
    /// to fire where its bit is set in both.
    rearm: alert.Mask = all_alerts,
    /// The settle at which an alert last became due here.
    alert_seq: u64 = 0,
    /// The alerts whose text starts in the row's part of its line's text,
    /// once `starts_known`; a settle matches only the rows that changed
    /// and those whose matches may reach them.
    starts: alert.Mask = 0,
    starts_known: bool = false,
    /// The row was on the screen at the latest reflow, rather than
    /// scrolled in by output since.
    reflowed: bool = false,

    fn merge(self: *RowState, other: RowState) void {
        self.change_seq = @max(self.change_seq, other.change_seq);
        self.text_change_seq = @max(self.text_change_seq, other.text_change_seq);
        self.blank_seq = @max(self.blank_seq, other.blank_seq);
    }
};

const ScreenTrack = struct {
    rows: std.ArrayListUnmanaged(RowState) = .empty,
    /// The ScreenSet generation `rows` describe; null while untracked.
    generation: ?usize = null,
    /// The absolute number of the top active row. Rows keep their number
    /// as they scroll into history.
    top: i64 = 0,
    /// Primary screen only: the rows that scrolled into history last, by
    /// absolute number modulo the capacity; the newest is `top - 1`.
    history: []RowState = &.{},
    history_len: usize = 0,
    /// Match the alerts against every line at the next settle.
    rescan: bool = false,
    /// A reflow could not carry the rows over: the rows tracked anew at
    /// the next settle count as reflowed.
    reflow_lost: bool = false,

    fn historyAt(self: *const ScreenTrack, abs: i64) ?*RowState {
        if (abs >= self.top or abs < self.top - @as(i64, @intCast(self.history_len))) return null;
        return &self.history[ringIndex(abs, self.history.len)];
    }
};

fn ringIndex(abs: i64, len: usize) usize {
    return @intCast(@mod(abs, @as(i64, @intCast(len))));
}

/// The text of the screen at the latest input, line by line, so a wait can
/// tell text that was already there from text that is new.
pub const Snapshot = struct {
    key: Key = .primary,
    generation: usize = 0,
    /// The input_seq it was taken at; 0 before the first input.
    seq: u64 = 0,
    /// Bumped by every input, so a copy of `text` can tell it is current.
    version: u64 = 0,
    /// Text past `snapshot_cap` is missing.
    truncated: bool = false,
    text: std.ArrayListUnmanaged(u8) = .empty,
    /// Ordered by `top`; lines never overlap.
    lines: std.ArrayListUnmanaged(SnapLine) = .empty,
    /// The text of lines that a resize since the input took off the
    /// screen, or merged into the line above: it was on the screen at the
    /// input, though on no row now.
    displaced: std.ArrayListUnmanaged(SnapText) = .empty,

    pub fn lineText(self: *const Snapshot, line: SnapLine) []const u8 {
        return self.text.items[line.start..][0..line.len];
    }

    fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.lines.deinit(gpa);
        self.displaced.deinit(gpa);
    }

    fn displace(self: *Snapshot, gpa: std.mem.Allocator, line: SnapLine) void {
        if (line.len == 0) return;
        self.displaced.append(gpa, .{ .start = line.start, .len = line.len }) catch {
            self.truncated = true;
        };
    }
};

/// A tracker's alerts, the lines that left the screen while one was due
/// to fire on them, and how many lines a run of resizes must not fire
/// again.
const Watch = struct {
    set: alert.Set,
    queue: []Queued = &.{},
    queued: usize = 0,
    /// Per slot: lines the queue had no room for.
    dropped: [alert.max_alerts]u32 = @splat(0),
    /// Scratch for the text of one line, the offsets of its rows in it,
    /// and the rows to match again.
    text: std.ArrayListUnmanaged(u8) = .empty,
    offsets: std.ArrayListUnmanaged(usize) = .empty,
    redo: std.ArrayListUnmanaged(bool) = .empty,
    /// Per screen and slot, the lines that showed the alert at the first
    /// resize of the run that lasts until `held_until`: a program that
    /// redraws them after the resize is not showing them anew.
    held: std.EnumArray(Key, [alert.max_alerts]u16) = .initFill(@splat(0)),
    held_until: i64 = 0,
    /// Per slot, the lines of the screen being matched that show the
    /// alert, from its top down to the line at hand.
    showing: [alert.max_alerts]u16 = @splat(0),
    /// Lines a reflow placed that came to show alerts during a run of
    /// resizes; whether they fire is decided once the screen's lines are
    /// counted.
    held_lines: std.ArrayListUnmanaged(HeldLine) = .empty,

    const HeldLine = struct { y: usize, due: alert.Mask };

    fn deinit(w: *Watch, gpa: std.mem.Allocator) void {
        w.set.deinit();
        gpa.free(w.queue);
        w.text.deinit(gpa);
        w.offsets.deinit(gpa);
        w.redo.deinit(gpa);
        w.held_lines.deinit(gpa);
    }

    /// The bits of `due`, due on a line that a reflow placed, whose alert
    /// more lines show now than at the start of the run of resizes; the
    /// line at hand is the next of them.
    fn beyondHeld(w: *const Watch, key: Key, due: alert.Mask) alert.Mask {
        const held = w.held.getPtrConst(key);
        var out = due;
        var bits = due;
        while (bits != 0) : (bits &= bits - 1) {
            const slot = @ctz(bits);
            if (w.showing[slot] < held[slot]) out &= ~alert.bit(slot);
        }
        return out;
    }

    /// One more line shows the alerts of `mask`.
    fn count(w: *Watch, mask: alert.Mask) void {
        var bits = mask;
        while (bits != 0) : (bits &= bits - 1) w.showing[@ctz(bits)] +|= 1;
    }
};

const Queued = struct {
    mask: alert.Mask,
    seq: u64,
    region: alert.Region,
    row: ?i64,
    len: u16,
    text: [alert.max_line_len]u8,
};

/// `text` cut to at most `max` bytes at a character boundary.
fn cut(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

pub const SnapLine = struct {
    /// Absolute number of the line's first row and its row count.
    top: i64,
    rows: u32,
    start: u32,
    len: u32,
};

/// Text in `Snapshot.text`.
pub const SnapText = struct { start: u32, len: u32 };

/// What shows besides the rows' cells.
const Shown = struct {
    key: Key,
    x: u16,
    y: u16,
    visible: bool,
    reverse: bool,
    fg: ?vt.color.RGB,
    bg: ?vt.color.RGB,
};

pub const Tracker = struct {
    gpa: std.mem.Allocator,
    counter: *Counter,
    screens: std.EnumArray(Key, ScreenTrack) = .initFill(.{}),
    /// The bottom-left cell of the primary screen at the last settle. Once
    /// history lost rows at its front, how far it moved up is how many rows
    /// scrolled into history. Its column is 1 so a pin that Ghostty moved
    /// to a row start (the row was erased) is told apart.
    pin: ?*Pin = null,
    /// The primary screen's first row and history rows at the last settle.
    /// While that row stays first, history grew by exactly the rows that
    /// scrolled into it.
    oldest: ?*Pin = null,
    history_rows: usize = 0,
    /// The primary screen's history dropped rows at its front, to its
    /// limit or erased, since the session started.
    history_dropped: bool = false,
    shown: Shown,
    unsettled_since: ?i64 = null,
    unsettled_bytes: usize = 0,
    sync_since: ?i64 = null,
    parsed_bytes: u64 = 0,
    /// Bumped whenever absolute row numbers start over: a resize, a
    /// re-created screen, or rows that scrolled past unseen.
    epoch: u64 = 0,
    /// Rows that changed without a settle seeing them, because the
    /// scrollback dropped them before it could.
    lost: u64 = 0,
    /// Rows that went by while it was unknown how far the screen scrolled,
    /// since the session started; it only grows. A wait adds what it grew
    /// by while it waited to the rows it reports lost.
    given_up: u64 = 0,
    /// How far the primary screen's top row jumped when rows went by
    /// unseen, since the session started; those rows are in `given_up`.
    jumped: i64 = 0,
    /// The primary screen's top row and `jumped` right before the latest
    /// epoch bump, and the top row right after it, so a wait can tell
    /// which rows it had not checked and where to go on.
    renumbered: struct { before: i64 = 0, jumped: i64 = 0, after: i64 = 0 } = .{},
    snapshot: Snapshot = .{},
    watch: Watch,

    start_seq: u64,
    /// The seq of the latest settle that changed something.
    seq: std.atomic.Value(u64),
    /// `seq` when the latest input was written; 0 before any input.
    input_seq: std.atomic.Value(u64) = .init(0),
    /// Bumped (and woken) at every settle and when the session ends.
    settles: std.atomic.Value(u32) = .init(0),
    /// Bytes the reader has read from the pty, and how many of them the
    /// latest settle covers.
    read_bytes: std.atomic.Value(u64) = .init(0),
    /// Bumped before and after every read from the pty, so it is odd while
    /// the reader holds bytes that neither the pty nor `read_bytes` counts.
    reads: std.atomic.Value(u64) = .init(0),
    settled_bytes: std.atomic.Value(u64) = .init(0),
    /// Monotonic nanoseconds; last_input_ns is 0 before any input.
    last_change_ns: std.atomic.Value(i64),
    last_text_change_ns: std.atomic.Value(i64),
    last_input_ns: std.atomic.Value(i64) = .init(0),
    /// A settle found hits for the evaluator to take.
    hits_due: std.atomic.Value(bool) = .init(false),
    /// Settles of the program's output that took a seq.
    draws: std.atomic.Value(u64) = .init(0),

    /// Track `t`, whose current content counts as changed at `seq`.
    pub fn init(gpa: std.mem.Allocator, seqs: *Counter, t: *vt.Terminal, start_seq: u64, seq: u64, now: i64) !Tracker {
        var self: Tracker = .{
            .gpa = gpa,
            .counter = seqs,
            .shown = shownOf(t),
            .watch = .{ .set = .{ .gpa = gpa } },
            .start_seq = start_seq,
            .seq = .init(seq),
            .last_change_ns = .init(now),
            .last_text_change_ns = .init(now),
        };
        errdefer self.deinit(t);
        const pages = &t.screens.get(.primary).?.pages;
        self.pin = try pages.trackPin(bottomLeft(pages));
        self.oldest = try pages.trackPin(pages.getTopLeft(.screen));
        self.markBottom(pages);
        var stamp: Stamp = .{ .counter = seqs, .seq = seq, .now = now };
        for ([_]Key{ .primary, .alternate }) |key| self.settleScreen(t, key, &stamp);
        return self;
    }

    pub fn deinit(self: *Tracker, t: *vt.Terminal) void {
        for ([_]?*Pin{ self.pin, self.oldest }) |pin| if (pin) |p| t.screens.get(.primary).?.pages.untrackPin(p);
        self.pin = null;
        self.oldest = null;
        for (&self.screens.values) |*st| {
            st.rows.deinit(self.gpa);
            self.gpa.free(st.history);
            st.* = .{};
        }
        self.snapshot.deinit(self.gpa);
        self.watch.deinit(self.gpa);
    }

    /// Reader thread, right before reading from the pty.
    pub fn beginRead(self: *Tracker) void {
        _ = self.reads.fetchAdd(1, .seq_cst);
    }

    /// Reader thread, after reading `n` bytes and before parsing them.
    pub fn endRead(self: *Tracker, n: usize) void {
        _ = self.read_bytes.fetchAdd(n, .seq_cst);
        _ = self.reads.fetchAdd(1, .seq_cst);
    }

    pub fn noteParsed(self: *Tracker, n: usize, now: i64) void {
        if (self.unsettled_since == null) self.unsettled_since = now;
        self.unsettled_bytes += n;
        self.parsed_bytes += n;
    }

    /// Whether parsed output should be settled now; `drained` says the pty
    /// has nothing more to read.
    pub fn settleDue(self: *Tracker, t: *const vt.Terminal, now: i64, drained: bool) bool {
        const since = self.unsettled_since orelse return false;
        if (t.modes.get(.synchronized_output)) {
            const sync = self.sync_since orelse blk: {
                self.sync_since = now;
                break :blk now;
            };
            if (now - sync < sync_max_ns) return false;
        } else self.sync_since = null;
        return drained or now - since >= settle_max_ns or self.unsettled_bytes >= settle_max_bytes;
    }

    /// When unsettled output must be settled even if nothing more arrives.
    pub fn settleDeadline(self: *const Tracker) ?i64 {
        const since = self.unsettled_since orelse return null;
        if (self.sync_since) |sync| return sync + sync_max_ns;
        return since + settle_max_ns;
    }

    pub fn unsettled(self: *const Tracker) bool {
        return self.unsettled_since != null;
    }

    /// Record what the terminal shows now. Callers `notify` after
    /// releasing terminal_mutex.
    pub fn settle(self: *Tracker, t: *vt.Terminal, now: i64) void {
        var stamp: Stamp = .{ .counter = self.counter, .now = now };
        const key = t.screens.active_key;
        // Output may have changed the screen it just left.
        if (self.shown.key != key) {
            self.settleScreen(t, self.shown.key, &stamp);
            // A program that switches to the alternate screen draws on it
            // anew: what it shows there is new to the alerts.
            if (key == .alternate) self.resetWatch(.alternate);
        }
        self.settleScreen(t, key, &stamp);
        const shown = shownOf(t);
        // Ghostty leaves the palette's dirty flag to its renderer, which
        // tuppet does not have.
        if (!std.meta.eql(shown, self.shown) or t.flags.dirty.palette) _ = stamp.get();
        t.flags.dirty.palette = false;
        self.shown = shown;
        if (stamp.seq != null) _ = self.draws.fetchAdd(1, .monotonic);
        self.finish(&stamp, now);
    }

    fn finish(self: *Tracker, stamp: *const Stamp, now: i64) void {
        self.unsettled_since = null;
        self.unsettled_bytes = 0;
        if (stamp.seq) |seq| {
            self.seq.store(seq, .release);
            self.last_change_ns.store(now, .release);
            if (stamp.text) self.last_text_change_ns.store(now, .release);
        }
        self.settled_bytes.store(self.parsed_bytes, .release);
    }

    /// Wake everyone waiting on `settles`. Takes no lock.
    pub fn notify(self: *Tracker) void {
        _ = self.settles.fetchAdd(1, .release);
        io_mod.io().futexWake(u32, &self.settles.raw, std.math.maxInt(u32));
    }

    /// Wait until `settles` is no longer `seen` or until `deadline`
    /// (monotonic); wakeups may be spurious. Takes no lock.
    pub fn waitNotified(self: *Tracker, seen: u32, deadline: i64) void {
        const left = deadline - io_mod.nowNanos();
        if (left <= 0) return;
        io_mod.io().futexWaitTimeout(u32, &self.settles.raw, seen, .{
            .duration = .{ .raw = .fromNanoseconds(left), .clock = .boot },
        }) catch {};
    }

    /// Wait until the output among the first `target` bytes read from the
    /// pty is settled, or until `deadline`. Takes no lock.
    pub fn waitSettled(self: *Tracker, target: u64, deadline: i64) void {
        while (io_mod.nowNanos() < deadline) {
            const seen = self.settles.load(.acquire);
            if (self.settled_bytes.load(.acquire) >= target) return;
            self.waitNotified(seen, deadline);
        }
    }

    /// Record an input about to be written: settle what was parsed before
    /// it, take input_seq, and snapshot the screen text. Returns whether it
    /// settled, in which case the caller notifies.
    pub fn takeInput(self: *Tracker, t: *vt.Terminal, now: i64) bool {
        const settled = self.unsettled();
        if (settled) self.settle(t, now);
        var seq = self.seq.load(.monotonic);
        // Each input gets a seq of its own, also when nothing changed since
        // the one before (no echo), so a guard on an input_seq sees it.
        if (seq == self.input_seq.load(.monotonic)) {
            seq = self.counter.next();
            self.seq.store(seq, .release);
        }
        self.takeSnapshot(t, seq);
        self.watch.held_until = 0;
        self.input_seq.store(seq, .release);
        self.last_input_ns.store(now, .release);
        return settled;
    }

    fn settleScreen(self: *Tracker, t: *vt.Terminal, key: Key, stamp: *Stamp) void {
        const screen = t.screens.get(key) orelse return;
        const pages = &screen.pages;
        const st = self.screens.getPtr(key);
        const generation = t.screens.generation(key);
        if (st.generation != generation or st.rows.items.len != pages.rows) {
            self.watchGone(st.rows.items);
            st.rows.resize(self.gpa, pages.rows) catch {
                st.generation = null;
                _ = stamp.get();
                stamp.text = true;
                return;
            };
            @memset(st.rows.items, .{ .reflowed = st.reflow_lost });
            st.reflow_lost = false;
            if (st.generation != null) self.renumber(self.screens.get(.primary).top, self.jumped);
            st.generation = generation;
        }
        if (key == .primary) self.measureScroll(t, st, stamp);
        // Ghostty does not mark a row dirty when a combining mark joins a
        // cell left of the cursor, so the cursor's rows are always hashed.
        const cursor_y = screen.cursor.y;
        const shown_y = if (self.shown.key == key) self.shown.y else cursor_y;
        var it = pages.getTopLeft(.active).rowIterator(.right_down, null);
        for (st.rows.items, 0..) |*rs, y| {
            const p = it.next() orelse break;
            const page = p.node.page();
            const row = pageRow(p);
            if (!row.dirty and !page.dirty and rs.hash != 0 and y != cursor_y and y != shown_y) continue;
            row.dirty = false;
            update(rs, hashRow(page, row), stamp);
        }
        clearPageDirty(pages);
        if (self.watching()) self.watchScreen(key, pages, st, stamp);
    }

    fn measureScroll(self: *Tracker, t: *const vt.Terminal, st: *ScreenTrack, stamp: *Stamp) void {
        const pin = self.pin orelse return;
        const screen = t.screens.get(.primary).?;
        const pages = &screen.pages;
        defer self.markBottom(pages);
        const history = pages.total_rows - pages.rows;
        defer st.history_len = @min(st.history_len, history);
        const n = st.rows.items.len;
        // A scroll region at the top scrolls into history too, and the rows
        // below it stay where they are.
        const region = t.scrolling_region;
        const h = if (t.screens.active_key == .primary and region.top == 0) @min(region.bottom + 1, n) else n;
        if (screen.no_scrollback) {
            // Rows scroll out and are dropped, and only a full-screen
            // region moves the bottom row with them.
            if (region.top != 0 or h < n) return;
            const k = scrolledRows(pin.*, bottomLeft(pages)) orelse return self.forget(st, pages, pin.garbage);
            if (k == 0) return;
            self.history_dropped = true;
            self.watchGone(st.rows.items[0..@min(k, n)]);
            shift(st, k, n, stamp);
            return;
        }
        const oldest = self.oldest.?.*;
        const first = pages.getTopLeft(.screen);
        // History grew by the rows that scrolled into it unless it also lost
        // rows at its front. Only then does the bottom pin tell, though it
        // also moves with rows that a scroll region moved up in place.
        const kept = !oldest.garbage and oldest.node == first.node and oldest.y == first.y;
        if (!kept) self.history_dropped = true;
        const k = if (kept and history >= self.history_rows)
            history - self.history_rows
        else
            scrolledRows(pin.*, bottomLeft(pages)) orelse return self.forget(st, pages, pin.garbage);
        if (k == 0) return;
        if (st.history.len == 0) {
            // Without it rows that scroll away are simply forgotten.
            st.history = self.gpa.alloc(RowState, history_cap) catch &.{};
        }
        if (h < n) self.keepBelow(st.top + @as(i64, @intCast(h)), k);
        self.settleLeaving(st, pages, k, h, stamp);
        if (self.watching()) self.watchLeaving(st, pages, k, h, stamp);
        shift(st, k, h, stamp);
        if (self.watching()) self.watchCutTop(st, pages);
    }

    /// Start over when it is unknown how far the screen scrolled. At least
    /// a screen went by, and when history `pruned` the page of the bottom
    /// row, every row history keeps now came after it.
    fn forget(self: *Tracker, st: *ScreenTrack, pages: *const PageList, pruned: bool) void {
        self.watchGone(st.rows.items);
        const n = st.rows.items.len;
        const unseen = if (pruned) @max(n, pages.total_rows - pages.rows) else n;
        self.lost += unseen;
        self.given_up += unseen;
        const before = st.top;
        const jumped = self.jumped;
        st.top += @intCast(n);
        self.jumped += @intCast(n);
        st.history_len = 0;
        @memset(st.rows.items, .{});
        self.renumber(before, jumped);
    }

    /// Rows are numbered anew from here on; `before` and `jumped` are the
    /// primary screen's top row and `jumped` before.
    fn renumber(self: *Tracker, before: i64, jumped: i64) void {
        self.epoch += 1;
        self.renumbered = .{ .before = before, .jumped = jumped, .after = self.screens.get(.primary).top };
    }

    /// Keep the snapshot lines from `abs` on at their screen rows while the
    /// rows above them scroll `k` rows into history.
    fn keepBelow(self: *Tracker, abs: i64, k: usize) void {
        if (self.snapshot.key != .primary) return;
        for (self.snapshot.lines.items) |*line| {
            if (line.top >= abs) {
                line.top += @intCast(k);
            } else if (line.top + line.rows > abs) {
                line.rows = @intCast(abs - line.top);
            }
        }
    }

    /// Hash the rows that scrolled away from the top `h` rows once more:
    /// output may have changed them after the last settle and before they
    /// left.
    fn settleLeaving(self: *Tracker, st: *ScreenTrack, pages: *PageList, k: usize, h: usize, stamp: *Stamp) void {
        // Rows the scrollback dropped already.
        const gone = @min(k -| (pages.total_rows - pages.rows), h);
        self.lost += gone;
        const leaving = @min(k, h);
        if (gone >= leaving) return;
        const start = pages.getTopLeft(.active).up(k - gone) orelse return;
        const shown_y: ?usize = if (self.shown.key == .primary) self.shown.y else null;
        var it = start.rowIterator(.right_down, null);
        for (st.rows.items[gone..leaving], gone..) |*rs, y| {
            const p = it.next() orelse break;
            const page = p.node.page();
            const row = pageRow(p);
            if (!row.dirty and !page.dirty and shown_y != y) continue;
            row.dirty = false;
            update(rs, hashRow(page, row), stamp);
        }
    }

    fn markBottom(self: *Tracker, pages: *PageList) void {
        if (self.pin) |p| p.* = bottomLeft(pages);
        if (self.oldest) |p| p.* = pages.getTopLeft(.screen);
        self.history_rows = pages.total_rows - pages.rows;
    }

    // ---- reflow --------------------------------------------------------

    /// Before a resize (terminal_mutex held): settle, and remember where
    /// each tracked line is so `endReflow` can carry row seqs over.
    pub fn beginReflow(self: *Tracker, t: *vt.Terminal, now: i64) Reflow {
        if (self.unsettled()) self.settle(t, now);
        if (self.watching()) self.watchBeforeReflow(t, now);
        // Ghostty keeps blank rows that hold a tracked pin, so a pin on the
        // bottom row would push the text up into history when the screen
        // gets shorter. endReflow puts it back.
        if (self.pin) |p| p.* = t.screens.get(.primary).?.pages.getTopLeft(.screen);
        var reflow: Reflow = .{};
        for ([_]Key{ .primary, .alternate }) |key| {
            const screen = t.screens.get(key) orelse continue;
            const st = self.screens.getPtr(key);
            const generation = t.screens.generation(key);
            if (st.generation != generation or st.rows.items.len != screen.pages.rows) continue;
            var layout = self.layoutOf(st, &screen.pages) catch |err| {
                std.log.err("cannot keep row changes across a resize: {}", .{err});
                continue;
            };
            layout.generation = generation;
            reflow.layouts.set(key, layout);
        }
        return reflow;
    }

    /// The tracked lines of a screen, from the first line start among the
    /// tracked history rows, with an anchor pin on that row: the resize
    /// moves it to where those lines start afterwards.
    fn layoutOf(self: *Tracker, st: *ScreenTrack, pages: *PageList) !Layout {
        const active = pages.getTopLeft(.active);
        var above = @min(st.history_len, pages.total_rows - pages.rows);
        while (above > 0) : (above -= 1) {
            const prev = active.up(above + 1) orelse break;
            if (!pageRow(prev).wrap) break;
        }
        const start = if (above > 0) active.up(above).? else active;
        var layout = try collect(self.gpa, start, st.top - @as(i64, @intCast(above)), pages.cols);
        errdefer layout.deinit(self.gpa);
        for (layout.states.items, 0..) |*state, i| {
            const abs = layout.top + @as(i64, @intCast(i));
            state.* = if (abs < st.top) st.historyAt(abs).?.* else st.rows.items[@intCast(abs - st.top)];
        }
        layout.anchor = try pages.trackPin(.{ .node = start.node, .y = start.y, .x = 0 });
        return layout;
    }

    /// After the resize: match lines by their text, give rows of unchanged
    /// lines their old seqs and every other row a new one, and move the
    /// input snapshot along. A resize that took place is a visible change;
    /// returns the seq of the reflow, null when nothing changed.
    pub fn endReflow(self: *Tracker, t: *vt.Terminal, reflow: *Reflow, now: i64, resized: bool) ?u64 {
        var stamp: Stamp = .{ .counter = self.counter, .now = now };
        if (resized) _ = stamp.get();
        for ([_]Key{ .primary, .alternate }) |key| {
            const st = self.screens.getPtr(key);
            const screen = t.screens.get(key) orelse {
                st.generation = null;
                continue;
            };
            const old = if (reflow.layouts.getPtr(key).*) |*layout| layout else {
                st.generation = null;
                st.reflow_lost = true;
                continue;
            };
            // A new screen took the anchor along with the old one.
            if (old.generation != t.screens.generation(key)) {
                st.generation = null;
                continue;
            }
            defer screen.pages.untrackPin(old.anchor.?);
            defer if (st.generation != null and self.watching()) self.watchReflowed(&screen.pages, st);
            self.remap(key, st, &screen.pages, old, &stamp) catch |err| {
                // A small scrollback drops the rows a resize pushes out.
                if (err == error.ScrollbackDropped)
                    std.log.info("cannot keep row changes across a resize: {}", .{err})
                else
                    std.log.err("cannot keep row changes across a resize: {}", .{err});
                st.generation = null;
                st.reflow_lost = true;
                stamp.text = true;
                if (self.snapshot.key == key) {
                    self.snapshot.lines.clearRetainingCapacity();
                    self.snapshot.truncated = true;
                }
            };
        }
        // A reflow keeps the top row's number, not those of the rows
        // above it.
        self.renumber(self.screens.get(.primary).top, self.jumped);
        self.markBottom(&t.screens.get(.primary).?.pages);
        self.shown = shownOf(t);
        self.finish(&stamp, now);
        return stamp.seq;
    }

    fn remap(self: *Tracker, key: Key, st: *ScreenTrack, pages: *PageList, old: *Layout, stamp: *Stamp) !void {
        const gpa = self.gpa;
        const anchor = old.anchor.?.*;
        if (anchor.garbage) return error.ScrollbackDropped;
        const anchor_y = (pages.pointFromPin(.screen, anchor) orelse return error.ScrollbackDropped).coord().y;
        const active_y = pages.total_rows - pages.rows;
        // The old lines start at the anchor. Rows above it that a resize
        // pulled into the active area are older than any tracked row.
        const above: usize = active_y -| anchor_y;
        const older: usize = anchor_y -| active_y;
        const start = if (above > 0) Pin{ .node = anchor.node, .y = anchor.y } else pages.getTopLeft(.active);
        var new = try collect(gpa, start, st.top - @as(i64, @intCast(above)), pages.cols);
        defer new.deinit(gpa);
        const old_to_new = try gpa.alloc(?usize, old.lines.items.len);
        defer gpa.free(old_to_new);
        @memset(old_to_new, null);

        var next_old: usize = 0;
        for (new.lines.items, 0..) |nl, ni| {
            const states = new.states.items[nl.first..][0..nl.rows];
            const end = @min(old.lines.items.len, next_old + reflow_window);
            const match = if (nl.first < older) null else for (old.lines.items[next_old..end], next_old..) |ol, oi| {
                if (ol.hash == nl.hash) break oi;
            } else null;
            if (match) |oi| {
                old_to_new[oi] = ni;
                next_old = oi + 1;
                carry(old, old.lines.items[oi], states, new.cols);
            } else if (nl.first < older) {
                @memset(states, .{ .change_seq = unknown_seq, .text_change_seq = unknown_seq });
            } else {
                const seq = stamp.get();
                if (nl.hash != blank_text) stamp.text = true;
                @memset(states, .{ .change_seq = seq, .text_change_seq = seq });
            }
        }

        var it = start.rowIterator(.right_down, null);
        for (new.states.items) |*state| {
            const p = it.next() orelse break;
            const page = p.node.page();
            const row = pageRow(p);
            row.dirty = false;
            const h = hashRow(page, row);
            state.hash = h.full;
            state.text_hash = h.text;
            state.reflowed = true;
            if (state.text_change_seq == stamp.seq and h.text == blank_text) state.blank_seq = stamp.seq.?;
        }
        clearPageDirty(pages);

        try st.rows.resize(gpa, pages.rows);
        @memcpy(st.rows.items, new.states.items[above..][0..pages.rows]);
        if (above > 0 and st.history.len == 0) st.history = gpa.alloc(RowState, history_cap) catch &.{};
        if (st.history.len > 0) {
            for (new.states.items[0..above], 0..) |state, i| {
                st.history[ringIndex(new.top + @as(i64, @intCast(i)), st.history.len)] = state;
            }
        }
        st.history_len = @min(above, st.history.len);

        const snap = &self.snapshot;
        if (snap.key != key or snap.generation != old.generation) return;
        var kept: usize = 0;
        for (snap.lines.items) |line| {
            const index = line.top - old.top;
            if (index < 0 or index >= old.states.items.len) continue;
            const oi = old.lineOf(@intCast(index));
            const ni = old_to_new[oi] orelse {
                snap.displace(gpa, line);
                continue;
            };
            const ol = old.lines.items[oi];
            const nl = new.lines.items[ni];
            const offset = (@as(usize, @intCast(index)) - ol.first) * old.cols / new.cols;
            var moved = line;
            moved.top = new.top + @as(i64, @intCast(nl.first + @min(offset, nl.rows - 1)));
            moved.rows = @intCast(@max(1, std.math.divCeil(usize, line.rows * old.cols, new.cols) catch 1));
            // Lines joined since the input share rows now; they must not overlap.
            if (kept > 0) {
                const prev = &snap.lines.items[kept - 1];
                if (moved.top <= prev.top) {
                    snap.displace(gpa, line);
                    continue;
                }
                prev.rows = @intCast(@min(prev.rows, moved.top - prev.top));
            }
            snap.lines.items[kept] = moved;
            kept += 1;
        }
        snap.lines.shrinkRetainingCapacity(kept);
    }

    // ---- alerts --------------------------------------------------------

    fn watching(self: *const Tracker) bool {
        return self.watch.set.len > 0;
    }

    /// The text of `line` in the scratch buffer; null without memory.
    fn lineText(self: *Tracker, line: Line) ?[]const u8 {
        const w = &self.watch;
        w.text.clearRetainingCapacity();
        appendLineText(self.gpa, &w.text, line) catch return null;
        return w.text.items;
    }

    /// The alerts whose text `line` shows, from those that start on each
    /// of its rows, `line_rows`. With `seq`, only the rows that changed at
    /// that settle or whose starts are unknown are matched again, with
    /// those whose matches may reach them; without, all are. Null without
    /// memory.
    fn lineMask(self: *Tracker, line: Line, line_rows: []RowState, cols: usize, seq: ?u64) ?alert.Mask {
        const gpa = self.gpa;
        const w = &self.watch;
        const n = line_rows.len;
        // The line's text ends on the last row with any.
        const last = for (0..n) |i| {
            if (line_rows[n - 1 - i].text_hash != blank_text) break n - 1 - i;
        } else {
            for (line_rows) |*rs| {
                rs.starts = 0;
                rs.starts_known = true;
            }
            return 0;
        };
        w.redo.resize(gpa, last + 1) catch return forgetStarts(line_rows);
        const redo = w.redo.items;
        @memset(redo, seq == null);
        if (seq) |at| {
            // Blank cells are spaces in the text only when text follows
            // them: a row that changed takes along the blank rows above it
            // and the row with text above those.
            var above: usize = 0;
            var marked: usize = 0;
            for (line_rows, 0..) |rs, i| {
                defer if (rs.text_hash != blank_text) {
                    above = i;
                };
                if (rs.starts_known and rs.change_seq != at) continue;
                const to = @min(i, last) + 1;
                for (@max(above, marked)..to) |j| redo[j] = true;
                marked = @max(marked, to);
            }
        }
        for (line_rows[last + 1 ..]) |*rs| {
            rs.starts = 0;
            rs.starts_known = true;
        }
        // A match starts at most `longest - 1` bytes before its end, and a
        // row has a byte for every cell but the second halves of wide
        // characters (and a wide character wrapped onto the next row).
        const reach = blk: {
            const min_bytes = (cols -| 1) / 2;
            if (min_bytes == 0) break :blk n;
            break :blk std.math.divCeil(usize, w.set.longest() -| 1, min_bytes) catch unreachable;
        };
        var left: usize = 0;
        var i = last + 1;
        while (i > 0) {
            i -= 1;
            if (redo[i]) {
                left = reach;
            } else if (left > 0) {
                redo[i] = true;
                left -= 1;
            }
        }
        var a: usize = 0;
        while (a <= last) {
            if (!redo[a]) {
                a += 1;
                continue;
            }
            var b = a;
            while (b < last and redo[b + 1]) b += 1;
            self.matchRows(line, line_rows, a, b, @min(last, b + reach), last) catch return forgetStarts(line_rows);
            a = b + 1;
        }
        var m: alert.Mask = 0;
        for (line_rows) |rs| m |= rs.starts;
        return m;
    }

    /// Without memory to match `line_rows`, their starts are unknown until
    /// a later settle matches them; returns null.
    fn forgetStarts(line_rows: []RowState) ?alert.Mask {
        for (line_rows) |*rs| rs.starts_known = false;
        return null;
    }

    /// Find the alerts that start on rows `a..b` of `line` in the text of
    /// its rows `a..end`; `last` is the last row with text.
    fn matchRows(self: *Tracker, line: Line, line_rows: []RowState, a: usize, b: usize, end: usize, last: usize) !void {
        const gpa = self.gpa;
        const w = &self.watch;
        w.text.clearRetainingCapacity();
        w.offsets.clearRetainingCapacity();
        var sink: TextSink = .{ .gpa = gpa, .out = &w.text };
        var it = line.first.rowIterator(.right_down, null);
        for (0..a) |_| _ = it.next();
        for (a..end + 1) |r| {
            const p = it.next() orelse break;
            // A row's blank cells before more text are its own spaces.
            if (r <= b + 1) try w.offsets.append(gpa, w.text.items.len + sink.blanks);
            feedRow(p.node.page(), pageRow(p), &sink);
        }
        if (sink.failed) return error.OutOfMemory;
        if (end < last) try w.text.appendNTimes(gpa, ' ', sink.blanks);
        if (w.offsets.items.len == b - a + 1) try w.offsets.append(gpa, w.text.items.len);
        const text = w.text.items;
        const offsets = w.offsets.items;
        for (line_rows[a .. b + 1]) |*rs| {
            rs.starts = 0;
            rs.starts_known = true;
        }
        var r: usize = 0;
        for (offsets[0]..offsets[offsets.len - 1]) |pos| {
            while (pos >= offsets[r + 1]) r += 1;
            line_rows[a + r].starts |= w.set.startsAt(text, pos);
        }
    }

    /// Note the alerts `m` that `line` of the screen `key` shows, whose
    /// rows are `line_rows`, and the ones that are due to fire on it now.
    /// During a run of resizes, a line that a reflow placed may show its
    /// alerts again: with `later`, whether they fire is left to
    /// `fireHeld`, else it depends on the lines above it.
    fn watchLine(self: *Tracker, key: Key, line: Line, line_rows: []RowState, m: alert.Mask, stamp: *Stamp, later: bool) void {
        const w = &self.watch;
        const first = &line_rows[0];
        const due = m & first.rearm & ~(first.alerts & first.rearm);
        var fresh = due;
        if (due != 0 and first.reflowed and stamp.now < w.held_until) {
            fresh = if (later) blk: {
                w.held_lines.append(self.gpa, .{ .y = line.y, .due = due }) catch break :blk w.beyondHeld(key, due);
                break :blk 0;
            } else w.beyondHeld(key, due);
        }
        // What waits for fireHeld stays armed.
        const held_back = if (later) due & ~fresh else 0;
        first.rearm &= ~(due & ~fresh & ~held_back);
        first.rearm |= ~m;
        first.alerts = m;
        if (fresh != 0) {
            first.alert_seq = stamp.get();
            self.hits_due.store(true, .release);
        }
        for (line_rows[1..]) |*rs| {
            rs.alerts = 0;
            rs.rearm = all_alerts;
        }
    }

    /// After a settle hashed a screen: match the alerts against the lines
    /// that changed, or against all of them once `rescan` asks for it.
    fn watchScreen(self: *Tracker, key: Key, pages: *PageList, st: *ScreenTrack, stamp: *Stamp) void {
        const all = st.rescan;
        st.rescan = false;
        const seq = stamp.seq;
        if (!all and seq == null) return;
        self.watch.showing = @splat(0);
        self.watch.held_lines.clearRetainingCapacity();
        defer self.fireHeld(key, st, stamp);
        var it = LineIterator.init(pages.getTopLeft(.active));
        // A line right after one that changed may start where a wrap went
        // away.
        var after_change = false;
        while (it.next()) |line| {
            if (line.y + line.rows > st.rows.items.len) break;
            const line_rows = st.rows.items[line.y..][0..line.rows];
            const changed = all or changedAt(line_rows, seq.?);
            if (changed or after_change) if (self.lineMask(line, line_rows, pages.cols, if (all) null else seq)) |m| {
                self.watchLine(key, line, line_rows, m, stamp, true);
            };
            self.watch.count(line_rows[0].alerts);
            after_change = changed;
        }
    }

    /// The lines that `watchScreen` held back fire for the alerts that
    /// more lines show than at the start of the run of resizes, the
    /// lowest of them first; the others count as seen.
    fn fireHeld(self: *Tracker, key: Key, st: *ScreenTrack, stamp: *Stamp) void {
        const w = &self.watch;
        if (w.held_lines.items.len == 0) return;
        const held = w.held.getPtrConst(key);
        var excess: [alert.max_alerts]u16 = undefined;
        for (&excess, w.showing, held) |*e, n, h| e.* = n -| h;
        var i = w.held_lines.items.len;
        while (i > 0) {
            i -= 1;
            const line = w.held_lines.items[i];
            const first = &st.rows.items[line.y];
            var fire: alert.Mask = 0;
            var bits = line.due;
            while (bits != 0) : (bits &= bits - 1) {
                const slot = @ctz(bits);
                if (excess[slot] > 0) {
                    excess[slot] -= 1;
                    fire |= alert.bit(slot);
                } else first.rearm &= ~alert.bit(slot);
            }
            if (fire == 0) continue;
            first.alert_seq = stamp.get();
            self.hits_due.store(true, .release);
        }
        w.held_lines.clearRetainingCapacity();
    }

    /// Rows that scroll into history are never matched again: queue the
    /// lines of the top `h` rows that leave while an alert is due on
    /// them, and match the alerts once against the rows that came and
    /// went since the last settle. The screen scrolled `k` rows.
    fn watchLeaving(self: *Tracker, st: *ScreenTrack, pages: *PageList, k: usize, h: usize, stamp: *Stamp) void {
        const history = pages.total_rows - pages.rows;
        const gone = @min(k -| history, h);
        const leaving = @min(k, h);
        const n = st.rows.items.len;
        self.watchGone(st.rows.items[0..gone]);
        self.watch.showing = @splat(0);
        if (gone < leaving) if (pages.getTopLeft(.active).up(k - gone)) |start| {
            var it = LineIterator.init(start);
            while (it.next()) |line| {
                const y = gone + line.y;
                if (y >= leaving) break;
                const line_rows = st.rows.items[y..@min(y + line.rows, n)];
                if (stamp.seq) |seq| if (changedAt(line_rows, seq)) if (self.lineText(line)) |text| {
                    self.watchLine(.primary, line, line_rows, self.watch.set.mask(text), stamp, false);
                };
                const first = &line_rows[0];
                self.watch.count(first.alerts);
                const due = first.alerts & first.rearm;
                if (due == 0) continue;
                first.rearm &= ~due;
                self.enqueue(due, first.alert_seq, .scrollback, rowNumber(y, k), self.lineText(line) orelse "");
            }
        };
        if (k <= h) return;
        // The rows that scrolled past between two settles that the
        // history still has.
        const from = @max(h, k -| history);
        if (from >= k) return;
        const start = pages.getTopLeft(.active).up(k - from) orelse return;
        var it = LineIterator.init(start);
        while (it.next()) |line| {
            if (from + line.y >= k) break;
            const text = self.lineText(line) orelse continue;
            const due = self.watch.set.mask(text);
            if (due != 0) self.enqueue(due, stamp.get(), .scrollback, rowNumber(from + line.y, k), text);
        }
    }

    /// After a scroll: when the top row continues a line whose first row
    /// went into the history and was matched with the whole line, what the
    /// part left on the screen shows counts as seen.
    fn watchCutTop(self: *Tracker, st: *ScreenTrack, pages: *PageList) void {
        const first = pages.getTopLeft(.active);
        const above = first.up(1) orelse return;
        if (!pageRow(above).wrap or st.rows.items.len == 0) return;
        var it = LineIterator.init(first);
        const line = it.next() orelse return;
        const text = self.lineText(line) orelse return;
        const m = self.watch.set.mask(text);
        const line_rows = st.rows.items[0..@min(line.rows, st.rows.items.len)];
        line_rows[0].rearm &= ~(m & ~line_rows[0].alerts);
        line_rows[0].rearm |= ~m;
        line_rows[0].alerts = m;
        for (line_rows[1..]) |*rs| {
            rs.alerts = 0;
            rs.rearm = all_alerts;
        }
    }

    /// Rows whose text is gone: what was due on them is lost.
    fn watchGone(self: *Tracker, states: []RowState) void {
        for (states) |*rs| {
            const due = rs.alerts & rs.rearm;
            if (due == 0) continue;
            rs.rearm &= ~due;
            self.enqueue(due, rs.alert_seq, .lost, null, "");
        }
    }

    fn enqueue(self: *Tracker, mask: alert.Mask, seq: u64, region: alert.Region, row: ?i64, text: []const u8) void {
        const w = &self.watch;
        self.hits_due.store(true, .release);
        if (w.queue.len == 0) w.queue = self.gpa.alloc(Queued, queue_cap) catch &.{};
        if (w.queued == w.queue.len) {
            var bits = mask;
            while (bits != 0) : (bits &= bits - 1) w.dropped[@ctz(bits)] +|= 1;
            return;
        }
        const kept = cut(text, alert.max_line_len);
        const q = &w.queue[w.queued];
        q.* = .{ .mask = mask, .seq = seq, .region = region, .row = row, .len = @intCast(kept.len), .text = undefined };
        @memcpy(q.text[0..kept.len], kept);
        w.queued += 1;
    }

    /// The tracked rows of the screen `key` and its pages; null while the
    /// screen is untracked.
    fn trackedScreen(self: *Tracker, t: *vt.Terminal, key: Key) ?struct { *ScreenTrack, *PageList } {
        const screen = t.screens.get(key) orelse return null;
        const st = self.screens.getPtr(key);
        if (st.generation != t.screens.generation(key) or st.rows.items.len != screen.pages.rows) return null;
        return .{ st, &screen.pages };
    }

    /// The program switched to the alternate screen: nothing on it has
    /// fired yet.
    fn resetWatch(self: *Tracker, key: Key) void {
        const st = self.screens.getPtr(key);
        for (st.rows.items) |*rs| {
            rs.alerts = 0;
            rs.rearm = all_alerts;
            rs.reflowed = false;
        }
        st.rescan = true;
    }

    /// Before a resize: what is due fires from where it is now. Each
    /// resize of a run counts the lines that show each alert, and the run
    /// keeps the most: the program may draw them again after each resize.
    fn watchBeforeReflow(self: *Tracker, t: *vt.Terminal, now: i64) void {
        const w = &self.watch;
        if (now >= w.held_until) w.held = .initFill(@splat(0));
        for ([_]Key{ .primary, .alternate }) |key| {
            const st, const pages = self.trackedScreen(t, key) orelse continue;
            w.showing = @splat(0);
            defer for (w.held.getPtr(key), w.showing) |*held, n| {
                held.* = @max(held.*, n);
            };
            var it = LineIterator.init(pages.getTopLeft(.active));
            while (it.next()) |line| {
                const first = &st.rows.items[line.y];
                if (first.alerts == 0) continue;
                w.count(first.alerts);
                const due = first.alerts & first.rearm;
                if (due == 0) continue;
                first.rearm &= ~due;
                self.enqueue(due, first.alert_seq, .visible, @intCast(line.y + 1), self.lineText(line) orelse "");
            }
        }
        w.held_until = now + held_ns;
    }

    /// After a resize: the text a reflow shows was there before it, so
    /// what the alerts find on the lines now counts as seen.
    fn watchReflowed(self: *Tracker, pages: *PageList, st: *ScreenTrack) void {
        var it = LineIterator.init(pages.getTopLeft(.active));
        while (it.next()) |line| {
            if (line.y + line.rows > st.rows.items.len) break;
            const line_rows = st.rows.items[line.y..][0..line.rows];
            const text = self.lineText(line) orelse continue;
            const m = self.watch.set.mask(text);
            const first = &line_rows[0];
            first.rearm &= ~(m & ~first.alerts);
            first.rearm |= ~m;
            first.alerts = m;
            for (line_rows[1..]) |*rs| {
                rs.alerts = 0;
                rs.rearm = all_alerts;
            }
        }
    }

    /// Add an alert, checked with alert.ruleError; parsed output must be
    /// settled. The text it finds on the screens now counts as seen.
    pub fn addAlert(self: *Tracker, t: *vt.Terminal, rule: alert.Rule) !u5 {
        const slot = try self.watch.set.add(rule);
        const b = alert.bit(slot);
        for (&self.screens.values) |*st| for (st.rows.items) |*rs| {
            rs.starts_known = false;
        };
        for ([_]Key{ .primary, .alternate }) |key| {
            const st, const pages = self.trackedScreen(t, key) orelse continue;
            var it = LineIterator.init(pages.getTopLeft(.active));
            while (it.next()) |line| {
                const line_rows = st.rows.items[line.y..][0..@min(line.rows, st.rows.items.len - line.y)];
                const found = if (self.lineText(line)) |text| self.watch.set.mask(text) & b else 0;
                for (line_rows, 0..) |*rs, i| {
                    rs.alerts = (rs.alerts & ~b) | (if (i == 0) found else 0);
                    if (i == 0 and found != 0) rs.rearm &= ~b else rs.rearm |= b;
                }
            }
        }
        return slot;
    }

    /// Remove the alert named `name`; returns its slot.
    pub fn removeAlert(self: *Tracker, name: []const u8) ?u5 {
        const slot = self.watch.set.remove(name) orelse return null;
        const b = alert.bit(slot);
        for (&self.screens.values) |*st| {
            for (st.rows.items) |*rs| {
                rs.alerts &= ~b;
                rs.rearm |= b;
                rs.starts &= ~b;
            }
            for (st.history) |*rs| {
                rs.alerts &= ~b;
                rs.rearm |= b;
            }
        }
        const w = &self.watch;
        var kept: usize = 0;
        for (w.queue[0..w.queued]) |q| {
            if (q.mask & ~b == 0) continue;
            w.queue[kept] = q;
            w.queue[kept].mask &= ~b;
            kept += 1;
        }
        w.queued = kept;
        w.dropped[slot] = 0;
        for (&w.held.values) |*held| held[slot] = 0;
        return slot;
    }

    /// The alerts, in the order they were added.
    pub fn alerts(self: *const Tracker) *const alert.Set {
        return &self.watch.set;
    }

    /// For the evaluator: take the hits the settles found, the lines that
    /// left the screen while due and the lines where an alert is due now,
    /// whose bits it consumes. Their text, cut to a hit's length, goes
    /// into `text`; `dropped` gets per slot the lines the queue had no
    /// room for. Parsed output must be settled.
    pub fn takeHits(self: *Tracker, t: *vt.Terminal, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(alert.Candidate), text: *std.ArrayListUnmanaged(u8), dropped: *[alert.max_alerts]u32) !void {
        self.hits_due.store(false, .release);
        const w = &self.watch;
        dropped.* = w.dropped;
        w.dropped = @splat(0);
        const queue = w.queue[0..w.queued];
        w.queued = 0;
        for (queue) |q| {
            const start = text.items.len;
            try text.appendSlice(gpa, q.text[0..q.len]);
            try out.append(gpa, .{ .mask = q.mask, .seq = q.seq, .region = q.region, .row = q.row, .start = start, .len = q.len });
        }
        for ([_]Key{ .primary, .alternate }) |key| {
            const st, const pages = self.trackedScreen(t, key) orelse continue;
            var it = LineIterator.init(pages.getTopLeft(.active));
            while (it.next()) |line| {
                const first = &st.rows.items[line.y];
                const due = first.alerts & first.rearm;
                if (due == 0) continue;
                first.rearm &= ~due;
                const start = text.items.len;
                try appendLineText(gpa, text, line);
                text.shrinkRetainingCapacity(start + cut(text.items[start..], alert.max_line_len).len);
                try out.append(gpa, .{ .mask = due, .seq = first.alert_seq, .region = .visible, .row = @intCast(line.y + 1), .start = start, .len = text.items.len - start });
            }
        }
    }

    // ---- snapshot and queries ------------------------------------------

    fn takeSnapshot(self: *Tracker, t: *vt.Terminal, seq: u64) void {
        const snap = &self.snapshot;
        const key = t.screens.active_key;
        const st = self.screens.getPtr(key);
        snap.text.clearRetainingCapacity();
        snap.lines.clearRetainingCapacity();
        snap.displaced.clearRetainingCapacity();
        snap.key = key;
        snap.generation = st.generation orelse t.screens.generation(key);
        snap.seq = seq;
        snap.version +%= 1;
        snap.truncated = false;
        var it = LineIterator.init(t.screens.active.pages.getTopLeft(.active));
        while (it.next()) |line| {
            const start = snap.text.items.len;
            appendLineText(self.gpa, &snap.text, line) catch {
                snap.text.shrinkRetainingCapacity(start);
                snap.truncated = true;
                break;
            };
            if (snap.text.items.len > snapshot_cap) {
                snap.text.shrinkRetainingCapacity(start);
                snap.truncated = true;
                break;
            }
            snap.lines.append(self.gpa, .{
                .top = st.top + @as(i64, @intCast(line.y)),
                .rows = @intCast(line.rows),
                .start = @intCast(start),
                .len = @intCast(snap.text.items.len - start),
            }) catch {
                snap.truncated = true;
                break;
            };
        }
    }

    /// The per-row state of the active rows of the screen `key`.
    pub fn rows(self: *const Tracker, key: Key) []const RowState {
        return self.screens.getPtrConst(key).rows.items;
    }

    /// The absolute number of the top active row of the screen `key`.
    pub fn top(self: *const Tracker, key: Key) i64 {
        return self.screens.getPtrConst(key).top;
    }

    /// The state of a row by absolute number: an active row, or one of the
    /// rows that scrolled into history last. Null for older rows.
    pub fn rowAt(self: *const Tracker, key: Key, abs: i64) ?RowState {
        const st = self.screens.getPtrConst(key);
        if (abs >= st.top) {
            if (abs - st.top >= st.rows.items.len) return null;
            return st.rows.items[@intCast(abs - st.top)];
        }
        return if (st.historyAt(abs)) |state| state.* else null;
    }

    /// The newest change among the rows of an active line.
    pub fn lineState(self: *const Tracker, key: Key, line: Line) RowState {
        var state: RowState = .{};
        for (self.rows(key)[line.y..][0..line.rows]) |rs| state.merge(rs);
        return state;
    }

    /// The snapshot lines that overlap active rows [y, y + n) of the screen
    /// `key`, in order; none when the snapshot was taken on another screen.
    pub fn snapshotLines(self: *const Tracker, t: *const vt.Terminal, key: Key, y: usize, n: usize) []const SnapLine {
        const snap = &self.snapshot;
        const st = self.screens.getPtrConst(key);
        if (snap.seq == 0 or snap.key != key or snap.generation != t.screens.generation(key)) return &.{};
        const from = st.top + @as(i64, @intCast(y));
        const to = from + @as(i64, @intCast(n));
        const lines = snap.lines.items;
        const first = std.sort.partitionPoint(SnapLine, lines, from, struct {
            fn before(abs: i64, line: SnapLine) bool {
                return line.top + line.rows <= abs;
            }
        }.before);
        var last = first;
        while (last < lines.len and lines[last].top < to) last += 1;
        return lines[first..last];
    }
};

const Stamp = struct {
    counter: *Counter,
    seq: ?u64 = null,
    text: bool = false,
    /// Monotonic nanoseconds of the settle.
    now: i64 = 0,

    fn get(self: *Stamp) u64 {
        if (self.seq == null) self.seq = self.counter.next();
        return self.seq.?;
    }
};

/// Whether a row of `rows` changed at `seq`.
fn changedAt(rows: []const RowState, seq: u64) bool {
    for (rows) |rs| if (rs.change_seq == seq) return true;
    return false;
}

/// The row of old screen row `y` once the screen scrolled `k` rows, as
/// hits count rows.
fn rowNumber(y: usize, k: usize) i64 {
    return @as(i64, @intCast(y)) - @as(i64, @intCast(k)) + 1;
}

fn update(rs: *RowState, h: Hashes, stamp: *Stamp) void {
    if (h.full == rs.hash) return;
    const seq = stamp.get();
    rs.change_seq = seq;
    if (h.text != rs.text_hash) {
        rs.text_change_seq = seq;
        stamp.text = true;
        if (h.text == blank_text) rs.blank_seq = seq;
    }
    rs.hash = h.full;
    rs.text_hash = h.text;
}

/// Move the top `h` rows of a screen, which scrolled `k` rows into
/// history; the rows below them stay.
fn shift(st: *ScreenTrack, k: usize, h: usize, stamp: *Stamp) void {
    const states = st.rows.items[0..h];
    const n = states.len;
    if (k > n) stamp.text = true;
    if (st.history.len > 0) {
        var i = k -| st.history.len;
        while (i < k) : (i += 1) {
            // Rows past the screen's height came and went unseen.
            const state: RowState = if (i < n) states[i] else .{ .change_seq = stamp.get(), .text_change_seq = stamp.get() };
            st.history[ringIndex(st.top + @as(i64, @intCast(i)), st.history.len)] = state;
        }
        st.history_len = @min(st.history.len, st.history_len + k);
    }
    st.top += @intCast(k);
    if (k < n) std.mem.copyForwards(RowState, states[0 .. n - k], states[k..]);
    @memset(states[n - @min(k, n) ..], .{});
}

/// Give the rows of a line that kept its text the seqs of the old rows
/// that held the same part of it.
fn carry(old: *const Layout, ol: LayoutLine, states: []RowState, cols: usize) void {
    for (states, 0..) |*state, j| {
        state.* = .{};
        const lo = @min(j * cols / old.cols, ol.rows - 1);
        const hi = @min(((j + 1) * cols - 1) / old.cols, ol.rows - 1);
        for (old.states.items[ol.first + lo .. ol.first + hi + 1]) |o| state.merge(o);
    }
    const first = old.states.items[ol.first];
    states[0].alerts = first.alerts;
    states[0].rearm = first.rearm;
    states[0].alert_seq = first.alert_seq;
}

fn shownOf(t: *const vt.Terminal) Shown {
    const cursor = t.screens.active.cursor;
    return .{
        .key = t.screens.active_key,
        .x = cursor.x,
        .y = cursor.y,
        .visible = t.modes.get(.cursor_visible),
        .reverse = t.modes.get(.reverse_colors),
        .fg = t.colors.foreground.get(),
        .bg = t.colors.background.get(),
    };
}

fn bottomLeft(pages: *const PageList) Pin {
    const node = pages.pages.last.?;
    return .{ .node = node, .y = node.rows() - 1, .x = if (pages.cols > 1) 1 else 0 };
}

/// How many rows the bottom row moved up since `pin` was at the bottom;
/// null when the pin cannot tell (its rows were pruned or erased).
fn scrolledRows(pin: Pin, bottom: Pin) ?usize {
    if (pin.garbage or pin.x != bottom.x) return null;
    var n: usize = 0;
    var node = pin.node;
    var y: usize = pin.y;
    while (node != bottom.node) {
        n += std.math.sub(usize, node.rows(), y) catch return null;
        y = 0;
        node = node.next orelse return null;
    }
    if (y > bottom.y) return null;
    return n + bottom.y - y;
}

fn pageRow(p: Pin) *Row {
    const page = p.node.page();
    return &page.rows.ptr(page.memory)[p.y];
}

fn clearPageDirty(pages: *PageList) void {
    var node: ?*PageList.List.Node = pages.getTopLeft(.active).node;
    while (node) |n| : (node = n.next) n.page().dirty = false;
}

// ---- lines ------------------------------------------------------------

/// A logical line: rows joined by soft wraps.
pub const Line = struct {
    /// The first row, counted from where the iteration started, and the
    /// number of rows. A line that started above that point begins there.
    y: usize,
    rows: usize,
    first: Pin,
};

/// The logical lines from a row down to the bottom of the screen.
pub const LineIterator = struct {
    it: PageList.RowIterator,
    y: usize = 0,

    pub fn init(start: Pin) LineIterator {
        return .{ .it = start.rowIterator(.right_down, null) };
    }

    /// The lines of the active area of `screen`.
    pub fn active(screen: *vt.Screen) LineIterator {
        return init(screen.pages.getTopLeft(.active));
    }

    pub fn next(self: *LineIterator) ?Line {
        const first = self.it.next() orelse return null;
        var line: Line = .{ .y = self.y, .rows = 1, .first = first };
        var p = first;
        while (pageRow(p).wrap) {
            p = self.it.next() orelse break;
            line.rows += 1;
        }
        self.y += line.rows;
        return line;
    }
};

/// Append a line's text as UTF-8, the way plain text shows it: spacer
/// cells skipped, empty cells as spaces, trailing empty cells dropped.
pub fn appendLineText(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), line: Line) !void {
    var sink: TextSink = .{ .gpa = gpa, .out = out };
    var it = line.first.rowIterator(.right_down, null);
    for (0..line.rows) |_| {
        const p = it.next() orelse break;
        feedRow(p.node.page(), pageRow(p), &sink);
    }
    if (sink.failed) return error.OutOfMemory;
}

const TextSink = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    blanks: usize = 0,
    failed: bool = false,

    fn blank(self: *TextSink) void {
        self.blanks += 1;
    }

    fn codepoint(self: *TextSink, cp: u21) void {
        if (self.failed) return;
        if (cp < 0x80 and self.blanks == 0) {
            self.out.append(self.gpa, @intCast(cp)) catch {
                self.failed = true;
            };
            return;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(std.unicode.replacement_character, &buf) catch unreachable;
        self.out.ensureUnusedCapacity(self.gpa, self.blanks + n) catch {
            self.failed = true;
            return;
        };
        self.out.appendNTimesAssumeCapacity(' ', self.blanks);
        self.out.appendSliceAssumeCapacity(buf[0..n]);
        self.blanks = 0;
    }
};

fn feedRow(page: *const Page, row: *Row, sink: anytype) void {
    for (page.getCells(row)) |*cell| feedCell(page, cell, sink);
}

/// The one rule for plain text, which snapshots, line hashes, and row
/// text hashes share.
inline fn feedCell(page: *const Page, cell: *const Cell, sink: anytype) void {
    if (cell.wide == .spacer_tail or cell.wide == .spacer_head) return;
    if (!cell.hasText()) return sink.blank();
    sink.codepoint(cell.codepoint());
    if (cell.hasGrapheme()) if (page.lookupGrapheme(cell)) |cps| for (cps) |cp| sink.codepoint(cp);
}

// ---- hashing ----------------------------------------------------------

fn mix(h: u64, v: u64) u64 {
    const p = @as(u128, h ^ v) * 0x9e3779b97f4a7c15;
    return @as(u64, @truncate(p)) ^ @as(u64, @truncate(p >> 64)) ^ 0xa0761d6478bd642f;
}

/// The bits of a cell that show: content and width; style and hyperlink
/// ids are page-local, so their values are hashed instead.
const cell_shape: u64 = @bitCast(Cell{
    .content_tag = @fromBackingInt(3),
    .content = .{ .color_rgb = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
    .wide = @fromBackingInt(3),
});
const cell_shown: u64 = cell_shape | @as(u64, @bitCast(Cell{ .style_id = std.math.maxInt(@FieldType(Cell, "style_id")), .hyperlink = true }));

/// A cheap running hash over words; `final` mixes it well.
const Words = struct {
    h: u64,

    fn add(self: *Words, word: u64) void {
        self.h = (self.h ^ word) *% 0x9e3779b97f4a7c15;
    }

    fn final(self: Words) u64 {
        return mix(self.h, 0) | 1;
    }
};

/// Hashes text the way TextSink writes it, so equal text hashes equal.
const TextHash = struct {
    words: Words = .{ .h = 0x452821e638d01377 },
    blanks: usize = 0,

    fn blank(self: *TextHash) void {
        self.blanks += 1;
    }

    fn codepoint(self: *TextHash, cp: u21) void {
        while (self.blanks > 0) : (self.blanks -= 1) self.words.add(' ');
        self.words.add(cp);
    }

    fn finish(self: TextHash) u64 {
        return self.words.final();
    }
};

const blank_text: u64 = (TextHash{}).finish();

const Hashes = struct { full: u64, text: u64 };

/// Both hashes of a row. Cells that show nothing at its end are left out.
fn hashRow(page: *const Page, row: *Row) Hashes {
    const all = page.getCells(row);
    var end = all.len;
    while (end > 0 and @as(u64, @bitCast(all[end - 1])) & cell_shown == 0) end -= 1;
    if (!row.styled and !row.hyperlink and !row.grapheme) return hashCells(true, page, all[0..end], row.wrap);
    return hashCells(false, page, all[0..end], row.wrap);
}

/// `plain`: the row has no styles, links, or extra codepoints, which gives
/// the same hashes without looking for them.
fn hashCells(comptime plain: bool, page: *const Page, cells: []const Cell, wrap: bool) Hashes {
    var full: Words = .{ .h = 0x243f6a8885a308d3 ^ @as(u64, @intFromBool(wrap)) };
    var text: TextHash = .{};
    var style_id: @FieldType(Cell, "style_id") = 0;
    var style_hash: u64 = 0;
    for (cells) |*cell| {
        full.add(@as(u64, @bitCast(cell.*)) & cell_shape);
        if (!plain) {
            if (cell.hasStyling()) {
                if (cell.style_id != style_id) {
                    style_id = cell.style_id;
                    style_hash = page.styles.get(page.memory, style_id).hash();
                }
                full.add(style_hash);
            }
            if (cell.hyperlink) full.add(hyperlinkHash(page, cell));
            if (cell.hasGrapheme()) if (page.lookupGrapheme(cell)) |cps| for (cps) |cp| full.add(cp);
        }
        feedCell(page, cell, &text);
    }
    return .{ .full = full.final(), .text = text.finish() };
}

/// The link's URI and explicit id; implicit ids are counters that differ
/// for every repaint of the same link.
fn hyperlinkHash(page: *const Page, cell: *const Cell) u64 {
    const id = page.lookupHyperlink(cell) orelse return 0;
    const entry = page.hyperlink_set.get(page.memory, id);
    var h = std.hash.Wyhash.hash(0, entry.uri.slice(page.memory));
    switch (entry.id) {
        .explicit => |name| h = mix(h, std.hash.Wyhash.hash(1, name.slice(page.memory))),
        .implicit => {},
    }
    return h;
}

// ---- reflow layouts ---------------------------------------------------

/// Where each tracked line was before a resize; `Tracker.beginReflow`.
pub const Reflow = struct {
    layouts: std.EnumArray(Key, ?Layout) = .initFill(null),

    pub fn deinit(self: *Reflow, gpa: std.mem.Allocator) void {
        for (&self.layouts.values) |*layout| if (layout.*) |*l| l.deinit(gpa);
    }
};

const LayoutLine = struct {
    /// Index of the first row in `Layout.states`.
    first: usize,
    rows: usize,
    hash: u64,
};

const Layout = struct {
    /// The absolute number of the first row.
    top: i64,
    cols: usize,
    generation: usize = 0,
    /// Tracked on the first row; `Tracker.endReflow` untracks it.
    anchor: ?*Pin = null,
    states: std.ArrayListUnmanaged(RowState) = .empty,
    lines: std.ArrayListUnmanaged(LayoutLine) = .empty,

    fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        self.states.deinit(gpa);
        self.lines.deinit(gpa);
    }

    fn lineOf(self: *const Layout, index: usize) usize {
        return std.sort.partitionPoint(LayoutLine, self.lines.items, index, struct {
            fn before(i: usize, line: LayoutLine) bool {
                return line.first + line.rows <= i;
            }
        }.before);
    }
};

/// The lines from `start` to the bottom of the screen, with their text
/// hashes; `top` is the absolute number of the row at `start`.
fn collect(gpa: std.mem.Allocator, start: Pin, top_abs: i64, cols: usize) !Layout {
    var layout: Layout = .{ .top = top_abs, .cols = cols };
    errdefer layout.deinit(gpa);
    var it = LineIterator.init(start);
    while (it.next()) |line| {
        var hash: TextHash = .{};
        var rit = line.first.rowIterator(.right_down, null);
        for (0..line.rows) |_| {
            const p = rit.next() orelse break;
            feedRow(p.node.page(), pageRow(p), &hash);
        }
        try layout.lines.append(gpa, .{ .first = line.y, .rows = line.rows, .hash = hash.finish() });
    }
    try layout.states.appendNTimes(gpa, .{}, it.y);
    return layout;
}

// ---- tests ------------------------------------------------------------

const Fixture = struct {
    term: vt.Terminal,
    stream: vt.TerminalStream,
    seqs: Counter = .{},
    tracker: Tracker,

    fn create(cols: u16, rows_: u16, scrollback: usize) !*Fixture {
        const gpa = std.testing.allocator;
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);
        f.* = .{ .term = undefined, .stream = undefined, .tracker = undefined };
        f.term = try vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{ .cols = cols, .rows = rows_, .max_scrollback_bytes = scrollback });
        errdefer f.term.deinit(gpa);
        var handler = f.term.vtHandler();
        handler.effects = .readonly;
        f.stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = gpa });
        const start = f.seqs.next();
        f.tracker = try .init(gpa, &f.seqs, &f.term, start, start, 0);
        return f;
    }

    fn destroy(f: *Fixture) void {
        const gpa = std.testing.allocator;
        f.tracker.deinit(&f.term);
        f.stream.deinit();
        f.term.deinit(gpa);
        gpa.destroy(f);
    }

    /// Parse `bytes` and settle; returns the session seq.
    fn feed(f: *Fixture, bytes: []const u8) u64 {
        return f.feedAt(bytes, 0);
    }

    /// `feed` at monotonic time `now`.
    fn feedAt(f: *Fixture, bytes: []const u8, now: i64) u64 {
        f.stream.nextSlice(bytes);
        f.tracker.noteParsed(bytes.len, now);
        f.tracker.settle(&f.term, now);
        return f.tracker.seq.raw;
    }

    fn row(f: *Fixture, y: usize) RowState {
        return f.tracker.rows(f.term.screens.active_key)[y];
    }

    fn resize(f: *Fixture, cols: u16, rows_: u16) !void {
        var reflow = f.tracker.beginReflow(&f.term, 0);
        defer reflow.deinit(std.testing.allocator);
        try f.term.resize(std.testing.allocator, .{ .cols = cols, .rows = rows_ });
        _ = f.tracker.endReflow(&f.term, &reflow, 0, true);
    }

    /// Every active row's state matches what it shows.
    fn expectConsistent(f: *Fixture) !void {
        const pages = &f.term.screens.active.pages;
        const states = f.tracker.rows(f.term.screens.active_key);
        try std.testing.expectEqual(@as(usize, pages.rows), states.len);
        var it = pages.getTopLeft(.active).rowIterator(.right_down, null);
        for (states) |rs| {
            const p = it.next().?;
            try std.testing.expectEqual(hashRow(p.node.page(), pageRow(p)).full, rs.hash);
        }
    }
};

test "a settle takes a seq for each visible change and none for an identical repaint" {
    const f = try Fixture.create(20, 4, 10_000);
    defer f.destroy();
    var seq = f.feed("hello");
    try std.testing.expectEqual(seq, f.row(0).text_change_seq);
    try std.testing.expectEqual(seq, f.feed("\rhello"));

    // Style alone changes the row, not its text.
    const text_seq = seq;
    seq = f.feed("\r\x1b[7mhello\x1b[m");
    try std.testing.expect(seq > text_seq);
    try std.testing.expectEqual(seq, f.row(0).change_seq);
    try std.testing.expectEqual(text_seq, f.row(0).text_change_seq);

    // A combining mark joins the cell before it; an emoji is replaced.
    var next = f.feed("\r\ne");
    try std.testing.expect(f.feed("\xcc\x81") > next);
    try std.testing.expectEqual(f.tracker.seq.raw, f.row(1).text_change_seq);
    next = f.feed("\r\n\xf0\x9f\x91\x8d");
    try std.testing.expect(f.feed("\r\xf0\x9f\x91\x8e") > next);

    // The cursor and the active screen are visible too.
    next = f.tracker.seq.raw;
    const rows_before = f.row(0);
    try std.testing.expect(f.feed("\x1b[1;3H") > next);
    try std.testing.expectEqual(rows_before, f.row(0));
    next = f.tracker.seq.raw;
    try std.testing.expect(f.feed("\x1b[?5h") > next);
    next = f.tracker.seq.raw;
    try std.testing.expect(f.feed("\x1b]4;1;rgb:ff/00/00\x1b\\") > next);
    next = f.tracker.seq.raw;
    try std.testing.expect(f.feed("\x1b[?1049h") > next);
    try std.testing.expectEqual(Key.alternate, f.term.screens.active_key);
}

test "a row that loses its text records the settle" {
    const f = try Fixture.create(20, 4, 10_000);
    defer f.destroy();
    _ = f.feed("text");
    try std.testing.expect(f.row(0).blank_seq < f.tracker.seq.raw);
    const seq = f.feed("\r\x1b[2K");
    try std.testing.expectEqual(seq, f.row(0).blank_seq);
}

test "scrolling moves row state up and into history" {
    const f = try Fixture.create(20, 3, 10_000);
    defer f.destroy();
    const a = f.feed("a");
    const b = f.feed("\r\nb");
    const c = f.feed("\r\nc");
    const d = f.feed("\r\nd\r\ne");
    try std.testing.expectEqual(@as(i64, 2), f.tracker.top(.primary));
    try std.testing.expectEqual(c, f.row(0).change_seq);
    try std.testing.expectEqual(d, f.row(1).change_seq);
    try std.testing.expectEqual(d, f.row(2).change_seq);
    try std.testing.expectEqual(a, f.tracker.rowAt(.primary, 0).?.change_seq);
    try std.testing.expectEqual(b, f.tracker.rowAt(.primary, 1).?.change_seq);
    try f.expectConsistent();
    // A row that changed and scrolled away within one settle.
    const e = f.feed(" done\r\nf\r\ng\r\nh");
    try std.testing.expectEqual(@as(i64, 5), f.tracker.top(.primary));
    try std.testing.expectEqual(e, f.tracker.rowAt(.primary, 4).?.text_change_seq);
    try std.testing.expectEqual(c, f.tracker.rowAt(.primary, 2).?.change_seq);
}

test "a scroll region below a fixed header scrolls in place" {
    const f = try Fixture.create(20, 5, 10_000);
    defer f.destroy();
    const header = f.feed("HEADER\x1b[2;5r\x1b[5;1H$ ");
    _ = f.tracker.takeInput(&f.term, 0);
    _ = f.feed("a\r\nb\r\nc\r\n");
    try std.testing.expectEqual(@as(i64, 0), f.tracker.top(.primary));
    try std.testing.expectEqual(@as(u64, 0), f.tracker.lost);
    try std.testing.expectEqual(header, f.row(0).change_seq);
    const lines = f.tracker.snapshotLines(&f.term, .primary, 0, 1);
    try std.testing.expectEqualStrings("HEADER", f.tracker.snapshot.lineText(lines[0]));
    try f.expectConsistent();
}

test "a scroll region above a fixed footer leaves the footer in place" {
    const f = try Fixture.create(20, 5, 10_000);
    defer f.destroy();
    const footer = f.feed("x\r\ny\r\nz\r\n\x1b[5;1HFOOTER\x1b[1;4r\x1b[4;1H");
    _ = f.tracker.takeInput(&f.term, 0);
    _ = f.feed("a\r\nb\r\nc\r\n");
    try std.testing.expectEqual(@as(i64, 3), f.tracker.top(.primary));
    try std.testing.expectEqual(footer, f.row(4).change_seq);
    var lines = f.tracker.snapshotLines(&f.term, .primary, 4, 1);
    try std.testing.expectEqualStrings("FOOTER", f.tracker.snapshot.lineText(lines[0]));
    lines = f.tracker.snapshotLines(&f.term, .primary, 1, 1);
    try std.testing.expectEqual(@as(usize, 0), lines.len);
    try f.expectConsistent();
}

test "without scrollback the rows still move up as the screen scrolls" {
    const f = try Fixture.create(20, 3, 0);
    defer f.destroy();
    _ = f.feed("a");
    const b = f.feed("\r\nb");
    _ = f.feed("\r\nc");
    _ = f.tracker.takeInput(&f.term, 0);
    _ = f.feed("\r\nd");
    try std.testing.expectEqual(@as(i64, 1), f.tracker.top(.primary));
    try std.testing.expectEqual(b, f.row(0).change_seq);
    try std.testing.expectEqual(@as(u64, 0), f.tracker.lost);
    const lines = f.tracker.snapshotLines(&f.term, .primary, 0, 1);
    try std.testing.expectEqualStrings("b", f.tracker.snapshot.lineText(lines[0]));
    try f.expectConsistent();
}

test "the input snapshot keeps each row's text while it scrolls" {
    const f = try Fixture.create(20, 3, 10_000);
    defer f.destroy();
    _ = f.feed("$ ");
    _ = f.tracker.takeInput(&f.term, 0);
    _ = f.feed("ls\r\nout\r\nmore\r\n$ ");
    // The old prompt scrolled into history with its snapshot line; the
    // new one is on a row the snapshot never saw.
    try std.testing.expectEqual(@as(usize, 0), f.tracker.snapshotLines(&f.term, .primary, 2, 1).len);
    const snap = &f.tracker.snapshot;
    try std.testing.expectEqual(@as(i64, 0), snap.lines.items[0].top);
    try std.testing.expectEqualStrings("$ ", snap.lineText(snap.lines.items[0]));
    try std.testing.expect(f.tracker.top(.primary) > 0);
}

test "a reflow keeps the seqs of lines whose text stayed" {
    const f = try Fixture.create(10, 4, 10_000);
    defer f.destroy();
    const short = f.feed("short");
    const long = f.feed("\r\n0123456789abc");
    _ = f.feed("\r\n$ ");
    _ = f.tracker.takeInput(&f.term, 0);
    const before = f.tracker.seq.raw;
    try f.resize(20, 4);
    try std.testing.expect(f.tracker.seq.raw > before);
    try std.testing.expectEqual(short, f.row(0).change_seq);
    try std.testing.expectEqual(long, f.row(1).change_seq);
    try std.testing.expectEqual(long, f.row(1).text_change_seq);
    try f.expectConsistent();
    // The prompt's snapshot line moved up with its row.
    const lines = f.tracker.snapshotLines(&f.term, .primary, 2, 1);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("$ ", f.tracker.snapshot.lineText(lines[0]));
}

test "a reflow below deep history keeps the seqs of lines whose text stayed" {
    const gpa = std.testing.allocator;
    const f = try Fixture.create(10, 4, 10_000_000);
    defer f.destroy();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    // Repeated lines tempt a match against the wrong copy.
    for (0..1500) |_| try out.appendSlice(gpa, "$ make\r\nbuilding target\r\n");
    _ = f.feed(out.items);
    const seq = f.feed("$ make\r\nbuilding target\r\n$ ");
    _ = f.tracker.takeInput(&f.term, 0);
    const snapshot_lines = f.tracker.snapshotLines(&f.term, .primary, 0, 4).len;
    for ([_]u16{ 20, 10 }) |cols| {
        try f.resize(cols, 4);
        for (f.tracker.rows(.primary)) |rs| if (rs.text_hash != blank_text) try std.testing.expect(rs.change_seq <= seq);
        try std.testing.expectEqual(snapshot_lines, f.tracker.snapshotLines(&f.term, .primary, 0, 4).len);
        try f.expectConsistent();
    }
}

test "a shorter screen keeps its text, and a taller one brings back what it pushed into history" {
    const gpa = std.testing.allocator;
    const f = try Fixture.create(120, 40, 10_000_000);
    defer f.destroy();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    for (1..13) |i| try out.print(gpa, "{d}\r\n", .{i});
    const seq = f.feed(out.items);
    // Blank rows below the cursor go first; at 12 rows the cursor's row
    // pushes line 1 into history.
    const sizes = [_][3]u16{ .{ 100, 30, 1 }, .{ 120, 40, 1 }, .{ 80, 24, 1 }, .{ 80, 12, 2 }, .{ 80, 24, 1 } };
    for (sizes) |size| {
        try f.resize(size[0], size[1]);
        const top_line = size[2];
        out.clearRetainingCapacity();
        try appendLineText(gpa, &out, .{ .y = 0, .rows = 1, .first = f.term.screens.active.pages.getTopLeft(.active) });
        try std.testing.expectEqualStrings(&.{'0' + @as(u8, @intCast(top_line))}, out.items);
        try std.testing.expectEqual(@as(usize, 13 - top_line), f.term.screens.active.cursor.y);
        try std.testing.expectEqual(seq, f.row(0).text_change_seq);
        try f.expectConsistent();
    }
    // The bottom row is measured again: output scrolls by what it adds.
    const top = f.tracker.top(.primary);
    _ = f.feed("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\ni\r\nj\r\nk\r\nl\r\nm");
    try std.testing.expectEqual(top + 1, f.tracker.top(.primary));
    try std.testing.expectEqual(@as(u64, 0), f.tracker.lost);
    try f.expectConsistent();
}

test "a flood past a tiny scrollback reports lost rows and stays consistent" {
    // Wide rows fill the minimum scrollback (a page or two) quickly.
    const f = try Fixture.create(400, 5, 1);
    defer f.destroy();
    _ = f.feed("start");
    var flood: std.ArrayListUnmanaged(u8) = .empty;
    defer flood.deinit(std.testing.allocator);
    for (0..400) |i| try flood.print(std.testing.allocator, "line {d}\r\n", .{i});
    _ = f.feed(flood.items);
    try std.testing.expect(f.tracker.lost > 0);
    try f.expectConsistent();
    const lost = f.tracker.lost;
    const top = f.tracker.top(.primary);
    _ = f.feed("more\r\n");
    try std.testing.expectEqual(lost, f.tracker.lost);
    try std.testing.expectEqual(top + 1, f.tracker.top(.primary));
    try f.expectConsistent();
}

test "a settle waits for the pty to drain, within its bounds" {
    const f = try Fixture.create(20, 4, 10_000);
    defer f.destroy();
    const t = &f.tracker;
    try std.testing.expect(!t.settleDue(&f.term, 0, true));
    t.noteParsed(10, 0);
    try std.testing.expect(!t.settleDue(&f.term, 1, false));
    try std.testing.expect(t.settleDue(&f.term, 1, true));
    try std.testing.expect(t.settleDue(&f.term, settle_max_ns, false));
    t.noteParsed(settle_max_bytes, 1);
    try std.testing.expect(t.settleDue(&f.term, 1, false));
    // Synchronized output holds it back, but not for long.
    f.stream.nextSlice("\x1b[?2026h");
    try std.testing.expect(!t.settleDue(&f.term, 2, true));
    try std.testing.expectEqual(@as(?i64, 2 + sync_max_ns), t.settleDeadline());
    try std.testing.expect(t.settleDue(&f.term, 2 + sync_max_ns, true));
}

var test_mark: u64 = 0;

fn testReserve(n: u64) anyerror!u64 {
    const mark = test_mark;
    test_mark += n;
    return mark;
}

test "seqs continue above every reserved block after a restart" {
    test_mark = 0;
    var first: Counter = .{ .block = 4 };
    try first.start(testReserve);
    var last: u64 = 0;
    for (0..10) |_| {
        const seq = first.next();
        try std.testing.expect(seq > last);
        last = seq;
    }
    // The block reserved ahead on its own thread.
    while (true) {
        first.lockSpin();
        const reserving = first.reserving;
        first.lock.unlock();
        if (!reserving) break;
        std.Thread.yield() catch {};
    }
    var restarted: Counter = .{ .block = 4 };
    try restarted.start(testReserve);
    try std.testing.expect(restarted.next() > last);
}

// ---- alert tests --------------------------------------------------------

/// The hits the evaluator would take now, logged as it logs them.
fn takeLogged(f: *Fixture, log: *alert.Log, now: i64) !usize {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(alert.Candidate) = .empty;
    defer out.deinit(gpa);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    var dropped: [alert.max_alerts]u32 = undefined;
    try f.tracker.takeHits(&f.term, gpa, &out, &text, &dropped);
    for (dropped, 0..) |n, slot| log.suppress(@intCast(slot), n);
    var logged: usize = 0;
    for (out.items) |c| {
        if (try log.add(f.tracker.alerts(), c, text.items[c.start..][0..c.len], now)) |_| logged += 1;
    }
    return logged;
}

fn takeHitCount(f: *Fixture) !usize {
    var log: alert.Log = .{ .gpa = std.testing.allocator };
    defer log.deinit();
    return takeLogged(f, &log, 0);
}

test "a spinner or a timer on an alert's line gives one hit, and a typed answer none" {
    const f = try Fixture.create(40, 5, 10_000);
    defer f.destroy();
    _ = try f.tracker.addAlert(&f.term, .{ .name = "ask", .match = "Proceed?" });
    _ = f.feed("Proceed? [y/N] | 0s");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    for ([_][]const u8{ "\rProceed? [y/N] / 1s", "\rProceed? [y/N] - 2s", "\rProceed? [y/N] \\ 3s" }) |frame| {
        _ = f.feed(frame);
        try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    }
    _ = f.tracker.takeInput(&f.term, 0);
    _ = f.feed(" y");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    // The answer scrolls the dialog into the history; it stays one hit.
    _ = f.feed("\r\n1\r\n2\r\n3\r\n4\r\n5");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
}

test "an identical dialog drawn again after an erase gives a second hit" {
    const f = try Fixture.create(40, 5, 10_000);
    defer f.destroy();
    _ = try f.tracker.addAlert(&f.term, .{ .name = "ask", .match = "Allow?" });
    _ = f.feed("\x1b[3;1HAllow? (y/n)");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    _ = f.feed("\x1b[2J");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    _ = f.feed("\x1b[3;1HAllow? (y/n)");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    // Text that was there before the alert came counts as seen.
    _ = f.feed("\x1b[5;1HDeny?");
    _ = try f.tracker.addAlert(&f.term, .{ .name = "deny", .match = "Deny?" });
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
}

test "a resize and the program's redraw after it do not fire again" {
    const f = try Fixture.create(40, 5, 10_000);
    defer f.destroy();
    _ = try f.tracker.addAlert(&f.term, .{ .name = "ask", .match = "Allow edits to main.zig?" });
    _ = f.feed("$ agent\r\nAllow edits to main.zig? [y/n]");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    try f.resize(20, 6);
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    // The program clears its part of the screen and draws it again.
    _ = f.feed("\x1b[2;1H\x1b[J");
    _ = f.feed("Allow edits to main.zig? [y/n]");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    try f.resize(40, 5);
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    // After an input, the same dialog drawn anew is a new occurrence.
    _ = f.tracker.takeInput(&f.term, 0);
    _ = f.feed("\x1b[2;1H\x1b[J");
    _ = f.feed("Allow edits to main.zig? [y/n]");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
}

test "a window drag over a visible alert gives no hit, and more lines than before do" {
    const f = try Fixture.create(80, 5, 10_000);
    defer f.destroy();
    _ = try f.tracker.addAlert(&f.term, .{ .name = "quit", .match = "F10 Quit" });
    // A program that shows its status line from 40 columns on, with the
    // width in it, and draws its screen anew on each resize.
    _ = f.feed("\x1b[?1049h\x1b[5;1Hstatus F10 Quit cols=80");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    try f.resize(30, 5);
    _ = f.feed("\x1b[H\x1b[2Jnarrow");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    try f.resize(81, 5);
    _ = f.feed("\x1b[H\x1b[2J\x1b[5;1Hstatus F10 Quit cols=81");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    // A second line that shows it is more than the drag began with.
    _ = f.feed("\x1b[2;1HF10 Quit, really?");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
}

test "after a resize, new output fires, and so does a redraw once the run of resizes is over" {
    const f = try Fixture.create(40, 4, 10_000);
    defer f.destroy();
    _ = try f.tracker.addAlert(&f.term, .{ .name = "err", .match = "ERROR" });
    _ = f.feed("ERROR: first\r\n$ ");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    try f.resize(30, 4);
    // One more line than at the resize shows it.
    _ = f.feed("\r\nERROR: second\r\n$ ");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    // The next resize of the run counts it too.
    try f.resize(35, 4);
    _ = f.feed("\x1b[H\x1b[2JERROR: first\r\nERROR: second\r\n$ ");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    // The lines scroll away, and a new match comes on a row output added.
    _ = f.feed("\r\n1\r\n2\r\n3\r\n4\r\nERROR: third");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    // A redraw of a reflowed line fires again once the run is over.
    try f.resize(40, 4);
    _ = f.feedAt("\x1b[H\x1b[2J", held_ns);
    _ = f.feedAt("ERROR: fourth", held_ns);
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
}

test "a dialog drawn with the switch to the alternate screen fires each time" {
    const f = try Fixture.create(40, 5, 10_000);
    defer f.destroy();
    _ = try f.tracker.addAlert(&f.term, .{ .name = "ask", .match = "Quit?" });
    _ = f.feed("\x1b[?1049h\x1b[2;3HQuit?");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    _ = f.feed("\x1b[?1049l");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    _ = f.feed("\x1b[?1049h\x1b[2;3HQuit?");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
}

test "rows that scroll past are matched once, and the rate limit holds" {
    const gpa = std.testing.allocator;
    const f = try Fixture.create(40, 5, 1_000_000);
    defer f.destroy();
    _ = try f.tracker.addAlert(&f.term, .{ .name = "tick", .match = "tick" });
    var flood: std.ArrayListUnmanaged(u8) = .empty;
    defer flood.deinit(gpa);
    for (0..100) |i| try flood.print(gpa, "tick {d}\r\n", .{i});
    _ = f.feed(flood.items);
    var log: alert.Log = .{ .gpa = gpa };
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, alert.max_rate), try takeLogged(f, &log, 0));
    try std.testing.expectEqual(@as(usize, 0), try takeLogged(f, &log, 0));
    // A second later the next one goes in. The hits tell how many were
    // left out: the rest of the hundred, past the rate or the queue.
    _ = f.feed("tick again");
    try std.testing.expectEqual(@as(usize, 1), try takeLogged(f, &log, std.time.ns_per_s));
    var suppressed: u64 = 0;
    var it = log.each();
    while (it.next()) |h| suppressed += h.suppressed;
    try std.testing.expectEqual(@as(u64, 100 - alert.max_rate), suppressed);
}

test "a wrapped line fires once while its first row scrolls away, or scrolls past" {
    const f = try Fixture.create(10, 4, 10_000);
    defer f.destroy();
    _ = try f.tracker.addAlert(&f.term, .{ .name = "ask", .match = "ASK" });
    _ = f.feed("0123456789ASK 0s");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
    _ = f.feed("\r\n1\r\n2\r\n3");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    // The timer on the part left on the screen.
    _ = f.feed("\x1b[1;5H1s");
    try std.testing.expectEqual(@as(usize, 0), try takeHitCount(f));
    // A line that came and went in one burst, its end still on the screen.
    _ = f.feed("\x1b[4;1H\r\n1\r\n2\r\n3\r\n4\r\n0123456789abcdefghijASK\r\nq");
    try std.testing.expectEqual(@as(usize, 1), try takeHitCount(f));
}

/// The alerts each line of the screen shows are those its text shows.
fn expectLineAlerts(f: *Fixture) !void {
    const gpa = std.testing.allocator;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    const rows_ = f.tracker.rows(f.term.screens.active_key);
    var it = LineIterator.active(f.term.screens.active);
    while (it.next()) |line| {
        text.clearRetainingCapacity();
        try appendLineText(gpa, &text, line);
        try std.testing.expectEqual(f.tracker.alerts().mask(text.items), rows_[line.y].alerts);
    }
}

test "text that comes far below the end of a wrapped line makes the blanks after its end spaces" {
    const f = try Fixture.create(7, 6, 10_000);
    defer f.destroy();
    _ = try f.tracker.addAlert(&f.term, .{ .name = "gap", .match = "a " });
    // One line over four rows that shows only "a": inserted blanks keep
    // the rows wrapped.
    _ = f.feed("abcdefghijklmnopqrstuv\x1b[1;2H\x1b[6@\x1b[2;1H\x1b[7@\x1b[3;1H\x1b[7@\x1b[4;1H\x1b[7@");
    try expectLineAlerts(f);
    try std.testing.expectEqual(@as(alert.Mask, 0), f.tracker.rows(.primary)[0].alerts);
    _ = f.feed("\x1b[3;1Hx\x1b[4;1Hy");
    try expectLineAlerts(f);
    try std.testing.expect(f.tracker.rows(.primary)[0].alerts != 0);
}

test "matching only the rows that changed finds what matching whole lines finds" {
    const gpa = std.testing.allocator;
    const f = try Fixture.create(7, 12, 10_000);
    defer f.destroy();
    for ([_]alert.Rule{
        .{ .name = "ab", .match = "ab" },
        .{ .name = "gap", .match = "a b" },
        .{ .name = "spaces", .match = "   " },
        .{ .name = "long", .match = "aaaaaaaaaa" },
        .{ .name = "wide", .match = "\xe4\xb8\xadb" },
        .{ .name = "case", .match = "XB", .icase = true },
        .{ .name = "end", .match = "b    a" },
    }) |rule| _ = try f.tracker.addAlert(&f.term, rule);
    var prng = std.Random.DefaultPrng.init(0x7475707065);
    const random = prng.random();
    // Inserted blanks and erases keep a row's wrap, so lines with blank
    // rows come about too. Output stays above the bottom row: the screen
    // does not scroll.
    const pieces = [_][]const u8{ "a", "b", " ", "x", "B", "\xe4\xb8\xad", "aaaa", "\x1b[K", "\x1b[1K", "\x1b[2K", "\r\n", "\x1b[J", "\x1b[3@", "\x1b[7@", "\x1b[7G\x1b[1K", "\x1b[5X" };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    for (0..4000) |_| {
        out.clearRetainingCapacity();
        for (0..random.intRangeAtMost(usize, 1, 3)) |_| {
            try out.print(gpa, "\x1b[{d};{d}H", .{ random.intRangeAtMost(u8, 1, 4), random.intRangeAtMost(u8, 1, 7) });
            for (0..random.intRangeAtMost(usize, 1, 6)) |_| try out.appendSlice(gpa, pieces[random.uintLessThan(usize, pieces.len)]);
        }
        _ = f.feed(out.items);
        try expectLineAlerts(f);
    }
}
