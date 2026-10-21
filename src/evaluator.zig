//! The evaluator: one thread per session that answers the session's waits.
//! It sleeps on the tracker's notifier; after a settle (at most every
//! 50 ms), at a wait's deadline, or when the session ends, it scans the
//! screen once and checks every wait against the copy. The screen it
//! answers with is rendered when a wait is met.
//!
//! It also samples the pty (see sample.zig): at most every 50 ms after a
//! settle or an input, and every 250 ms while someone wants samples, such
//! as a wait for hidden input or an events subscriber. It finds the
//! changes that events report (see events.zig), writes the frames of a
//! trace recording (see record.zig), and takes the alert hits that
//! settles found (see alert.zig), at most every 50 ms.
//!
//! Each wait is a refcounted Waiter. The request thread that blocks on
//! it (or the recording whose conditions it checks), the evaluator while
//! it is registered, and the hang-up watcher each hold a reference; none of them holds the session meanwhile, so
//! removing a session never waits for its waits.

const std = @import("std");
const io_mod = @import("io.zig");
const vt = @import("vt");
const cond = @import("cond.zig");
const protocol = @import("protocol.zig");
const status = @import("status.zig");
const view = @import("view.zig");
const registry = @import("registry.zig");
const session_mod = @import("session.zig");
const track = @import("track.zig");
const sample = @import("sample.zig");
const events = @import("events.zig");
const record = @import("record.zig");
const alert = @import("alert.zig");
const ptyio = @import("ptyio.zig");

const Session = session_mod.Session;

/// Passes start at most this often, except at deadlines and the end.
const pass_interval_ns: i64 = 50 * std.time.ns_per_ms;
/// Samples follow settles and inputs at most this often, and come this
/// often without them while wanted.
const sample_interval_ns: i64 = 50 * std.time.ns_per_ms;
const sample_tick_ns: i64 = 250 * std.time.ns_per_ms;
/// A wait the evaluator has not answered this long after its deadline is
/// answered by its own request.
const answer_grace_ns: i64 = 2 * std.time.ns_per_s;

pub const Options = struct {
    until: []const cond.Condition,
    timeout_ms: u64,
    /// Render the screen this way with the outcome.
    view: ?view.Options = null,
    /// The wait came with its input, so it knows the needle before the
    /// first byte: a needle that goes away and comes back on a row is new.
    bundled: bool = false,
    /// Rows count from the session's first one, not from the wait's start.
    from_start: bool = false,
    /// Called on the evaluator's thread once it answers the wait, instead
    /// of rendering an answer: nobody blocks on the wait.
    on_answer: ?*const fn (s: *Session, w: *Waiter) void = null,
};

pub const State = enum(u32) { waiting, answering, answered, cancelled };

pub const Result = struct {
    outcome: protocol.Outcome = .timeout,
    met: ?u32 = null,
    text: ?[]const u8 = null,
    cursor: ?protocol.Cursor = null,
    status: ?status.Status = null,
    /// The screen did not fit into a reply.
    too_large: bool = false,
    hits: []const protocol.Hit = &.{},
    missed: u64 = 0,
};

pub const Waiter = struct {
    gpa: std.mem.Allocator,
    /// The conditions and the result live here.
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u32) = .init(1),
    state: std.atomic.Value(State) = .init(.waiting),
    until: []cond.Condition = &.{},
    /// One per condition; used by bundled waits.
    absent: []cond.Absent = &.{},
    /// One per condition: what its earlier checks found.
    memory: []cond.Memory = &.{},
    /// The session's seq when the wait started.
    start_seq: u64 = 0,
    bundled: bool = false,
    /// Some condition looks for text.
    matches: bool = false,
    /// Some condition needs the pty sampled.
    samples: bool = false,
    /// Some condition waits for a hit.
    hits: bool = false,
    /// The latest input_seq when a condition held, which its hits count
    /// from.
    met_input_seq: ?u64 = null,
    view: ?view.Options = null,
    on_answer: ?*const fn (s: *Session, w: *Waiter) void = null,
    /// Monotonic nanoseconds.
    start: i64 = 0,
    deadline: i64 = 0,
    /// History rows from here on, numbered as in `epoch`, are unchecked.
    from: i64 = 0,
    epoch: u64 = 0,
    /// The tracker's `given_up` and `jumped` as of `epoch`.
    given_up: u64 = 0,
    jumped: i64 = 0,
    /// The latest check skipped lines whose change the tracker no longer
    /// knew.
    unknown: bool = false,
    /// The epoch whose skipped screen lines `lost` counts already: a
    /// screen line becomes unknown only at a resize, and stays so until it
    /// changes.
    unknown_epoch: ?u64 = null,
    truncated: bool = false,
    lost: u64 = 0,
    dropped: u64 = 0,
    result: Result = .{},

    pub fn create(gpa: std.mem.Allocator, opts: Options) !*Waiter {
        const w = try gpa.create(Waiter);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .arena = .init(gpa) };
        errdefer w.arena.deinit();
        const a = w.arena.allocator();
        w.until = try a.dupe(cond.Condition, opts.until);
        for (w.until) |*c| {
            if (c.match) |text| c.match = try a.dupe(u8, text);
            if (c.hit) |*h| h.name = try a.dupe(u8, h.name);
            if (c.needsScan()) w.matches = true;
            if (c.hidden_input) w.samples = true;
            if (c.hit != null) w.hits = true;
        }
        w.absent = try a.alloc(cond.Absent, w.until.len);
        for (w.absent) |*abs| abs.* = .{ .gpa = gpa };
        w.memory = try a.alloc(cond.Memory, w.until.len);
        @memset(w.memory, .{});
        w.bundled = opts.bundled;
        w.view = opts.view;
        w.on_answer = opts.on_answer;
        w.start = io_mod.nowNanos();
        const timeout_ns = std.math.mul(i64, @intCast(@min(opts.timeout_ms, std.math.maxInt(i32))), std.time.ns_per_ms) catch unreachable;
        w.deadline = w.start + timeout_ns;
        return w;
    }

    pub fn retain(w: *Waiter) void {
        _ = w.refs.fetchAdd(1, .acq_rel);
    }

    pub fn release(w: *Waiter) void {
        if (w.refs.fetchSub(1, .acq_rel) != 1) return;
        for (w.absent) |*abs| abs.deinit();
        w.arena.deinit();
        w.gpa.destroy(w);
    }

    /// Its client hung up: the wait ends without an answer.
    pub fn cancel(w: *Waiter) void {
        if (w.state.cmpxchgStrong(.waiting, .cancelled, .acq_rel, .acquire) == null) wake(w);
    }

    /// The reply for an answered wait; it lives as long as `w`.
    pub fn reply(w: *const Waiter) protocol.WaitResp {
        const res = w.result;
        return .{
            .outcome = res.outcome,
            .met = res.met,
            .text = res.text,
            .cursor = res.cursor,
            .text_too_large = res.too_large,
            .hits = res.hits,
            .missed = res.missed,
            .snapshot_truncated = w.truncated,
            .lost = w.lost + w.dropped,
            .status = res.status,
        };
    }

    /// The first condition that holds.
    fn check(w: *Waiter, scan: ?*const cond.Scan, facts: cond.Facts) ?u32 {
        w.unknown = false;
        for (w.until, 0..) |*c, i| {
            if (c.needsScan() and scan == null) continue;
            const v = cond.check(c, scan, facts, .{ .start = w.start, .from = w.from, .start_seq = w.start_seq }, if (w.bundled) &w.absent[i] else null, &w.memory[i]);
            if (v.truncated) w.truncated = true;
            if (v.unknown) w.unknown = true;
            if (v.met) return @intCast(i);
        }
        return null;
    }

    /// What the wait starts from on `s`: its seq, or with `from_start` the
    /// session's first, and the texts that absent conditions find on the
    /// screen; terminal_mutex must be held.
    fn begin(w: *Waiter, s: *Session, from_start: bool) void {
        w.start_seq = if (from_start and s.track.epoch == 0) s.track.start_seq else s.track.seq.load(.acquire);
        for (w.until, w.memory) |c, *m| {
            if (c.absent) m.seen = cond.onScreen(w.gpa, &s.terminal, c.match.?, c.icase);
        }
    }

    /// The scan checked the history rows up to its screen.
    fn covered(w: *Waiter, scan: *const cond.Scan) void {
        if (scan.key == .primary and w.from < scan.first) w.lost += @intCast(scan.first - w.from);
        if (w.unknown) {
            for (scan.lines.items[0..scan.history]) |line| {
                if (line.unknown and line.top >= w.from) w.lost += line.rows;
            }
            if (w.unknown_epoch != scan.epoch) {
                w.unknown_epoch = scan.epoch;
                for (scan.lines.items[scan.history..]) |line| if (line.unknown) {
                    w.lost += line.rows;
                };
            }
        }
        w.dropped = @max(w.dropped, scan.dropped);
        w.from = @max(w.from, scan.primary_top);
    }

    /// The session's status and the screen, as of the answer.
    fn render(w: *Waiter, s: *Session) !void {
        const a = w.arena.allocator();
        const recording = try status.recordingOf(a, s);
        sample.refresh(s, true);
        s.lockTerminal();
        defer s.unlockTerminal();
        if (w.view) |opts| {
            if (view.renderLocked(a, s, opts)) |v| {
                w.result.text = v.text;
                w.result.cursor = v.cursor;
            } else |err| switch (err) {
                error.ViewTooLarge => w.result.too_large = true,
                else => return err,
            }
        }
        if (w.hits) try w.collectHits(s);
        var st = try status.ofLocked(a, s, recording);
        // The session may be gone by the time the reply is written.
        const argv = try a.alloc([]const u8, st.argv.len);
        for (st.argv, argv) |arg, *copy| copy.* = try a.dupe(u8, arg);
        st.argv = argv;
        w.result.status = st;
    }

    /// The hits that meet the hit conditions, and how many of those after an
    /// after_hit the log dropped; terminal_mutex must be held.
    fn collectHits(w: *Waiter, s: *Session) !void {
        const a = w.arena.allocator();
        const input_seq = w.met_input_seq orelse s.track.input_seq.load(.acquire);
        var list: std.ArrayListUnmanaged(protocol.Hit) = .empty;
        var it = s.hits.each();
        while (it.next()) |h| {
            const info: cond.HitInfo = .{ .n = h.n, .seq = h.seq, .alerts = h.alerts };
            for (w.until) |*c| {
                if (!cond.hitCounts(c, info, input_seq)) continue;
                try list.append(a, try h.dupe(a));
                break;
            }
        }
        w.result.hits = list.items;
        const oldest = s.hits.oldest();
        for (w.until) |c| if (c.hit) |h| if (h.after_hit) |n| {
            w.result.missed = @max(w.result.missed, oldest -| (n +| 1));
        };
    }
};

fn wake(w: *Waiter) void {
    io_mod.io().futexWake(State, &w.state.raw, std.math.maxInt(u32));
}

/// Settle `w` with `outcome`, unless it is settled already. Without a
/// session (it was removed) the answer has no status.
fn answer(s: ?*Session, w: *Waiter, outcome: protocol.Outcome, met: ?u32) void {
    if (w.state.cmpxchgStrong(.waiting, .answering, .acq_rel, .acquire) != null) return;
    w.result = .{ .outcome = outcome, .met = met };
    const hook = w.on_answer;
    if (hook == null) if (s) |session| w.render(session) catch |err| {
        std.log.err("session {d}: cannot render a wait's answer: {}", .{ session.id, err });
    };
    w.state.store(.answered, .release);
    wake(w);
    if (hook) |f| if (s) |session| f(session, w);
}

/// The waits of one session; part of the Session.
pub const Evaluator = struct {
    mutex: std.Io.Mutex = .init,
    waiters: std.ArrayListUnmanaged(*Waiter) = .empty,
    thread: ?std.Thread = null,
    /// The session has ended: one last pass, then the thread exits.
    finishing: bool = false,
    /// No thread answers waits: the session has ended, or came from the
    /// store. A wait is checked at once instead.
    done: bool = true,
    /// Waits came since the last pass.
    changed: bool = false,
    /// How many want the pty sampled every 250 ms: waits for hidden input.
    wanted: u32 = 0,

    /// `w` leaves `waiters`; the mutex must be held.
    fn left(e: *Evaluator, w: *Waiter) void {
        if (w.samples) e.wanted -= 1;
        w.release();
    }
};

/// Start the evaluator of a session that is starting.
pub fn start(s: *Session) !void {
    s.eval.done = false;
    s.eval.thread = std.Thread.spawn(.{}, run, .{s}) catch |err| {
        s.eval.done = true;
        return err;
    };
}

/// The session has ended: answer every wait after one last check, and
/// stop the thread.
pub fn finish(s: *Session) void {
    const e = &s.eval;
    const thread = e.thread orelse return;
    const io = io_mod.io();
    e.mutex.lockUncancelable(io);
    e.finishing = true;
    e.mutex.unlock(io);
    s.track.notify();
    thread.join();
    e.thread = null;
}

/// The session is being removed: every wait still on it is removed too.
pub fn close(s: *Session) void {
    const e = &s.eval;
    const io = io_mod.io();
    e.mutex.lockUncancelable(io);
    e.done = true;
    var waiters = e.waiters;
    e.waiters = .empty;
    e.wanted = 0;
    e.mutex.unlock(io);
    defer waiters.deinit(s.gpa);
    for (waiters.items) |w| {
        answer(null, w, .removed, null);
        w.release();
    }
}

/// Put `w` on `s`, whose reference the caller holds. Returns false when
/// no thread answers waits on `s` any more; `answerNow` answers it then.
pub fn register(s: *Session, w: *Waiter, from_start: bool) !bool {
    const io = io_mod.io();
    const e = &s.eval;
    {
        s.terminal_mutex.lockUncancelable(io);
        defer s.terminal_mutex.unlock(io);
        w.epoch = s.track.epoch;
        w.given_up = s.track.given_up;
        w.jumped = s.track.jumped;
        w.from = if (from_start and w.epoch == 0) 0 else s.track.top(.primary);
        w.begin(s, from_start);
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        if (e.done or e.finishing) return false;
        try e.waiters.append(s.gpa, w);
        w.retain();
        if (w.samples) e.wanted += 1;
        e.changed = true;
    }
    s.track.notify();
    return true;
}

/// Check `w` once on `s`, which has ended, and answer it.
pub fn answerNow(s: *Session, w: *Waiter) void {
    s.lockTerminal();
    w.begin(s, false);
    s.unlockTerminal();
    var scan: cond.Scan = .{ .gpa = w.gpa };
    defer scan.deinit();
    evaluate(s, &scan, &.{w}, true);
}

/// Block until `w` is answered (true) or its client hung up (false). The
/// caller holds no reference on the session, whose id is `id`.
pub fn block(w: *Waiter, id: u64) bool {
    const io = io_mod.io();
    while (true) {
        const state = w.state.load(.acquire);
        switch (state) {
            .answered => return true,
            .cancelled => {
                const s = registry.acquireLoaded(id) orelse return false;
                defer registry.release(s);
                unregister(s, w);
                return false;
            },
            .waiting, .answering => {},
        }
        const late = w.deadline +| answer_grace_ns;
        const now = io_mod.nowNanos();
        if (state == .waiting and now >= late) {
            if (registry.acquireLoaded(id)) |s| {
                defer registry.release(s);
                std.log.err("session {d}: a wait was not answered in time", .{id});
                answer(s, w, .timeout, null);
                unregister(s, w);
            } else answer(null, w, .removed, null);
            continue;
        }
        const left = if (state == .answering) std.time.ns_per_s else late - now;
        io.futexWaitTimeout(State, &w.state.raw, state, .{
            .duration = .{ .raw = .fromNanoseconds(left), .clock = .boot },
        }) catch {};
    }
}

/// Take `w` off the evaluator of `s` unanswered: its input failed, or its
/// recording stopped.
pub fn withdraw(s: *Session, w: *Waiter) void {
    unregister(s, w);
}

fn unregister(s: *Session, w: *Waiter) void {
    const e = &s.eval;
    const io = io_mod.io();
    e.mutex.lockUncancelable(io);
    defer e.mutex.unlock(io);
    for (e.waiters.items, 0..) |item, i| {
        if (item != w) continue;
        _ = e.waiters.swapRemove(i);
        e.left(w);
        return;
    }
}

fn run(s: *Session) void {
    const e = &s.eval;
    const io = io_mod.io();
    var scan: cond.Scan = .{ .gpa = s.gpa };
    defer scan.deinit();
    var list: std.ArrayListUnmanaged(*Waiter) = .empty;
    defer list.deinit(s.gpa);
    var passed: ?u32 = null;
    var last_pass: i64 = std.math.minInt(i64) / 2;
    // The settles and the input the latest sample followed.
    var sampled: ?u32 = null;
    var sampled_input: i64 = 0;
    var last_sample: i64 = std.math.minInt(i64) / 2;
    var detector: events.Detector = .{};
    // The settles the latest trace frame covers.
    var framed: ?u32 = null;
    var last_frame: i64 = std.math.minInt(i64) / 2;
    var hits: Hits = .{ .gpa = s.gpa };
    defer hits.deinit();
    var last_hits: i64 = std.math.minInt(i64) / 2;
    while (true) {
        const seen = s.track.settles.load(.acquire);
        e.mutex.lockUncancelable(io);
        const finishing = e.finishing;
        const changed = e.changed;
        const idle = e.waiters.items.len == 0;
        const wanted = e.wanted > 0 or events.watching();
        const due = nextDue(e.waiters.items, s.track.last_text_change_ns.load(.acquire), last_pass);
        e.mutex.unlock(io);
        if (finishing) {
            // Hits in the last output count for the last pass, and so does
            // the end of a burst the rate limit held back.
            if (s.track.hits_due.load(.acquire) or s.hits.flushDue() < std.math.maxInt(i64)) _ = hits.take(s, true);
            pass(s, &scan, &list, true);
            // The last changes go out before the end.
            _ = detector.step(s, s.track.settles.load(.acquire), false, io_mod.nowNanos(), true);
            return;
        }
        var now = io_mod.nowNanos();
        const input = s.track.last_input_ns.load(.acquire);
        const moved = sampled != seen or sampled_input != input;
        // A new wait for hidden input checks a fresh sample.
        var took_sample = false;
        if ((changed and wanted) or now >= nextSample(last_sample, moved, wanted)) {
            sample.refresh(s, true);
            sampled = seen;
            sampled_input = input;
            last_sample = now;
            took_sample = true;
            now = io_mod.nowNanos();
        }
        const look = detector.step(s, seen, took_sample, now, false) orelse std.math.maxInt(i64);
        var later = @min(now + std.time.ns_per_hour, nextSample(last_sample, sampled != seen or sampled_input != input, wanted), look);
        var took_hits = false;
        const flush_at = s.hits.flushDue();
        if (s.track.hits_due.load(.acquire) or now >= flush_at) {
            if (now >= last_hits + pass_interval_ns) {
                took_hits = hits.take(s, false);
                last_hits = now;
            } else later = @min(later, last_hits + pass_interval_ns);
        } else later = @min(later, flush_at);
        if (s.recording_trace.load(.acquire) and framed != seen) {
            if (now >= last_frame + pass_interval_ns) {
                // A settle without a visible text change keeps the slot.
                if (record.traceFrame(s)) last_frame = now;
                framed = s.track.settles.load(.acquire);
            } else later = @min(later, last_frame + pass_interval_ns);
        }
        if (idle) {
            s.track.waitNotified(seen, later);
            continue;
        }
        const fresh = changed or took_hits or passed != seen;
        const next = last_pass + pass_interval_ns;
        if (now < due and (!fresh or now < next)) {
            s.track.waitNotified(seen, @min(later, due, if (fresh) next else later));
            continue;
        }
        passed = seen;
        last_pass = now;
        pass(s, &scan, &list, false);
    }
}

/// What the evaluator needs to take hits, kept between its turns.
const Hits = struct {
    gpa: std.mem.Allocator,
    found: std.ArrayListUnmanaged(alert.Candidate) = .empty,
    text: std.ArrayListUnmanaged(u8) = .empty,
    logged: std.ArrayListUnmanaged(Logged) = .empty,

    const Logged = struct { n: u64, label: []u8 };

    fn deinit(h: *Hits) void {
        h.found.deinit(h.gpa);
        h.text.deinit(h.gpa);
        h.clearLogged();
        h.logged.deinit(h.gpa);
    }

    fn clearLogged(h: *Hits) void {
        for (h.logged.items) |l| h.gpa.free(l.label);
        h.logged.clearRetainingCapacity();
    }

    /// Log the hits the settles found, and the latest one the rate limit
    /// left out of a burst once its window is over (with `final` at
    /// once), mark them in an active recording, and tell the subscribers.
    /// Returns whether there were any.
    fn take(h: *Hits, s: *Session, final: bool) bool {
        h.found.clearRetainingCapacity();
        h.text.clearRetainingCapacity();
        h.clearLogged();
        const now = io_mod.nowNanos();
        var settled = false;
        {
            s.lockTerminal();
            defer s.unlockTerminal();
            const t = &s.terminal;
            settled = s.track.settleDue(t, now, true);
            if (settled) s.track.settle(t, now);
            // Synchronized output holds back the rows the hits are on; the
            // last take still logs what bursts left out.
            if (s.track.unsettled()) {
                if (!final) return false;
                h.flush(s, now, true);
            } else {
                var dropped: [alert.max_alerts]u32 = undefined;
                s.track.takeHits(t, h.gpa, &h.found, &h.text, &dropped) catch |err| {
                    std.log.err("session {d}: cannot take its alert hits: {}", .{ s.id, err });
                };
                for (dropped, 0..) |n, slot| if (n > 0) s.hits.suppress(@intCast(slot), n);
                // A burst's end comes before what followed it.
                h.flush(s, now, false);
                for (h.found.items) |c| {
                    const hit = s.hits.add(s.track.alerts(), c, h.text.items[c.start..][0..c.len], now) catch |err| {
                        std.log.err("session {d}: cannot log an alert hit: {}", .{ s.id, err });
                        continue;
                    } orelse continue;
                    h.note(hit);
                }
                if (final) h.flush(s, now, true);
            }
        }
        if (settled) s.track.notify();
        for (h.logged.items) |l| {
            var buf: [alert.max_alerts * 72]u8 = undefined;
            record.markHit(s, std.fmt.bufPrint(&buf, "hit {d} {s}", .{ l.n, l.label }) catch l.label);
            events.publishHit(s.id, l.n);
        }
        return h.logged.items.len > 0;
    }

    /// Log the ends of bursts that are due; terminal_mutex must be held.
    fn flush(h: *Hits, s: *Session, now: i64, all: bool) void {
        while (s.hits.flush(s.track.alerts(), now, all) catch |err| {
            std.log.err("session {d}: cannot log an alert hit: {}", .{ s.id, err });
            return;
        }) |hit| h.note(hit);
    }

    fn note(h: *Hits, hit: *const alert.Hit) void {
        const label = std.mem.join(h.gpa, ",", hit.alerts) catch return;
        h.logged.append(h.gpa, .{ .n = hit.n, .label = label }) catch h.gpa.free(label);
    }
};

/// When the next sample is due: soon after a settle or an input, at the
/// tick while samples are wanted, else never.
fn nextSample(last: i64, moved: bool, wanted: bool) i64 {
    if (moved) return last + sample_interval_ns;
    if (wanted) return last + sample_tick_ns;
    return std.math.maxInt(i64);
}

/// When the next pass is due without a settle: a wait's deadline, or the
/// moment an idle condition would hold, unless a pass saw that already.
fn nextDue(waiters: []const *Waiter, last_text_change: i64, last_pass: i64) i64 {
    var due: i64 = std.math.maxInt(i64);
    for (waiters) |w| {
        due = @min(due, w.deadline);
        for (w.until) |c| {
            for ([_]?i64{ c.idleDeadline(last_text_change, w.start), c.settledDeadline(last_text_change, w.start) }) |deadline| {
                const at = deadline orelse continue;
                if (at > last_pass) due = @min(due, at);
            }
        }
    }
    return due;
}

fn pass(s: *Session, scan: *cond.Scan, list: *std.ArrayListUnmanaged(*Waiter), final: bool) void {
    const e = &s.eval;
    const io = io_mod.io();
    list.clearRetainingCapacity();
    {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        e.changed = false;
        if (final) e.done = true;
        list.appendSlice(s.gpa, e.waiters.items) catch {
            std.log.err("session {d}: out of memory while checking its waits", .{s.id});
            if (final) for (e.waiters.items) |w| answer(null, w, .ended, null);
            return;
        };
        for (list.items) |w| w.retain();
    }
    defer for (list.items) |w| w.release();
    evaluate(s, scan, list.items, final);

    e.mutex.lockUncancelable(io);
    defer e.mutex.unlock(io);
    var i: usize = 0;
    while (i < e.waiters.items.len) {
        const w = e.waiters.items[i];
        if (w.state.load(.acquire) == .waiting) {
            i += 1;
            continue;
        }
        _ = e.waiters.swapRemove(i);
        e.left(w);
    }
}

/// Check `waiters` against the session as it is now, and answer those
/// that are met, timed out, or (when `final`) can no longer be met.
fn evaluate(s: *Session, scan: *cond.Scan, waiters: []const *Waiter, final: bool) void {
    const io = io_mod.io();
    var looks = false;
    for (waiters) |w| {
        if (w.matches and w.state.load(.acquire) == .waiting) looks = true;
    }
    var scanned: ?*const cond.Scan = null;
    var settled = false;
    if (looks) {
        s.terminal_mutex.lockUncancelable(io);
        defer s.terminal_mutex.unlock(io);
        if (scanLocked(&s.track, &s.terminal, scan, waiters, io_mod.nowNanos(), &settled)) |copied| {
            if (copied) {
                scan.output_pending = ptyio.outputPendingLocked(s);
                scanned = scan;
            }
        } else |err| std.log.err("session {d}: cannot copy the screen for its waits: {}", .{ s.id, err });
    }
    if (settled) s.track.notify();
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const hits = for (waiters) |w| {
        if (w.hits and w.state.load(.acquire) == .waiting) break copyHits(s, arena.allocator()) catch &.{};
    } else &.{};
    const ended = s.state.load(.acquire) == .exited;
    const smp = sample.latest(s);
    const facts: cond.Facts = .{
        .hits = hits,
        .now = io_mod.nowNanos(),
        .last_text_change = s.track.last_text_change_ns.load(.acquire),
        .end_seq = if (ended) s.end_seq.load(.acquire) else null,
        .input_seq = s.track.input_seq.load(.acquire),
        .input_ns = s.track.last_input_ns.load(.acquire),
        .hidden = if (!ended and smp.hidden()) .{ .seq = smp.hidden_seq, .ns = smp.hidden_ns } else null,
    };
    for (waiters) |w| {
        if (w.state.load(.acquire) != .waiting) continue;
        if (w.check(scanned, facts)) |i| {
            w.met_input_seq = facts.input_seq;
            answer(s, w, .met, i);
            continue;
        }
        if (w.matches) if (scanned) |sc| w.covered(sc);
        if (final) {
            answer(s, w, .ended, null);
        } else if (facts.now >= w.deadline) {
            answer(s, w, .timeout, null);
        }
    }
}

/// What the conditions need to know about the hits of `s`, in `gpa`.
fn copyHits(s: *Session, gpa: std.mem.Allocator) ![]const cond.HitInfo {
    s.lockTerminal();
    defer s.unlockTerminal();
    var out: std.ArrayListUnmanaged(cond.HitInfo) = .empty;
    var it = s.hits.each();
    while (it.next()) |h| {
        const alerts = try gpa.alloc([]const u8, h.alerts.len);
        for (h.alerts, alerts) |name, *copy| copy.* = try gpa.dupe(u8, name);
        try out.append(gpa, .{ .n = h.n, .seq = h.seq, .alerts = alerts });
    }
    return out.items;
}

/// Copy the screen for `waiters` into `scan`; terminal_mutex must be held.
/// The tracker numbers rows as of its last settle, so parsed output is
/// settled first; while synchronized output holds the settle back,
/// nothing is copied and it returns false. `settled` tells the caller to
/// notify.
fn scanLocked(tracker: *track.Tracker, t: *vt.Terminal, scan: *cond.Scan, waiters: []const *Waiter, now: i64, settled: *bool) !bool {
    settled.* = tracker.settleDue(t, now, true);
    if (settled.*) tracker.settle(t, now);
    if (tracker.unsettled()) return false;
    const epoch = tracker.epoch;
    var from: ?i64 = null;
    for (waiters) |w| {
        if (!w.matches or w.state.load(.acquire) != .waiting) continue;
        // Rows were numbered anew (a resize, a lost scroll): the rows it
        // had not checked yet and those that went by unseen are lost.
        if (w.epoch != epoch) {
            // The rows the top jumped over are in given_up already.
            const renumbered = tracker.renumbered;
            const unchecked = renumbered.before - (renumbered.jumped - w.jumped) - w.from;
            w.lost += tracker.given_up - w.given_up + @as(u64, @intCast(@max(0, unchecked)));
            w.given_up = tracker.given_up;
            w.jumped = tracker.jumped;
            w.epoch = epoch;
            w.from = renumbered.after;
            for (w.absent) |*abs| abs.reset();
        }
        from = if (from) |f| @min(f, w.from) else w.from;
    }
    try scan.collect(tracker, t, from);
    return true;
}

test "a scan settles parsed output first, unless synchronized output holds it back" {
    const gpa = std.testing.allocator;
    var term = try vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10_000 });
    defer term.deinit(gpa);
    var handler = term.vtHandler();
    handler.effects = .readonly;
    var stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = gpa });
    defer stream.deinit();
    var seqs: track.Counter = .{};
    const first = seqs.next();
    var tracker = try track.Tracker.init(gpa, &seqs, &term, first, first, 0);
    defer tracker.deinit(&term);
    var scan: cond.Scan = .{ .gpa = gpa };
    defer scan.deinit();
    const w = try Waiter.create(gpa, .{ .until = &[_]cond.Condition{.{ .match = "NEEDLE" }}, .timeout_ms = 0 });
    defer w.release();
    w.from = tracker.top(.primary);
    const facts: cond.Facts = .{ .now = 0, .last_text_change = 0, .end_seq = null, .input_seq = 0 };
    var settled = false;

    // NEEDLE scrolled into the history after the last settle.
    const burst = "NEEDLE\r\n1\r\n2\r\n3\r\n4";
    stream.nextSlice(burst);
    tracker.noteParsed(burst.len, 0);
    try std.testing.expect(try scanLocked(&tracker, &term, &scan, &.{w}, 0, &settled));
    try std.testing.expect(settled);
    try std.testing.expectEqual(@as(?u32, 0), w.check(&scan, facts));

    const frame = "\x1b[?2026h\r\n5";
    stream.nextSlice(frame);
    tracker.noteParsed(frame.len, 0);
    try std.testing.expect(!try scanLocked(&tracker, &term, &scan, &.{w}, 0, &settled));
    try std.testing.expect(!settled);
}

/// A terminal with a tracker, and one wait on it, registered now.
const TestWait = struct {
    term: vt.Terminal,
    stream: vt.TerminalStream,
    seqs: track.Counter = .{},
    tracker: track.Tracker,
    scan: cond.Scan,
    w: *Waiter,

    fn create(rows: u16, scrollback: usize) !*TestWait {
        const gpa = std.testing.allocator;
        const f = try gpa.create(TestWait);
        errdefer gpa.destroy(f);
        f.* = .{ .term = undefined, .stream = undefined, .tracker = undefined, .scan = .{ .gpa = gpa }, .w = undefined };
        f.term = try vt.Terminal.init((vt.TinyIo.init).io(), gpa, .{ .cols = 20, .rows = rows, .max_scrollback_bytes = scrollback });
        errdefer f.term.deinit(gpa);
        var handler = f.term.vtHandler();
        handler.effects = .readonly;
        f.stream = vt.TerminalStream.init(.{ .handler = handler, .allocator = gpa });
        const first = f.seqs.next();
        f.tracker = try .init(gpa, &f.seqs, &f.term, first, first, 0);
        return f;
    }

    fn destroy(f: *TestWait) void {
        const gpa = std.testing.allocator;
        f.w.release();
        f.scan.deinit();
        f.tracker.deinit(&f.term);
        f.stream.deinit();
        f.term.deinit(gpa);
        gpa.destroy(f);
    }

    /// Start waiting for `c`, as `register` does.
    fn wait(f: *TestWait, c: cond.Condition) !void {
        f.w = try Waiter.create(std.testing.allocator, .{ .until = &.{c}, .timeout_ms = 0 });
        f.w.epoch = f.tracker.epoch;
        f.w.given_up = f.tracker.given_up;
        f.w.jumped = f.tracker.jumped;
        f.w.from = f.tracker.top(.primary);
    }

    fn feed(f: *TestWait, bytes: []const u8) void {
        f.stream.nextSlice(bytes);
        f.tracker.noteParsed(bytes.len, 0);
    }

    /// One pass: whether the wait is met.
    fn pass(f: *TestWait) !bool {
        var settled = false;
        try std.testing.expect(try scanLocked(&f.tracker, &f.term, &f.scan, &.{f.w}, 0, &settled));
        const facts: cond.Facts = .{ .now = 0, .last_text_change = 0, .end_seq = null, .input_seq = 0 };
        if (f.w.check(&f.scan, facts) != null) return true;
        f.w.covered(&f.scan);
        return false;
    }
};

test "rows that went by while it was unknown how far they scrolled count as lost" {
    const f = try TestWait.create(3, 0);
    defer f.destroy();
    try f.wait(.{ .match = "NEEDLE" });
    f.feed("1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8");
    try std.testing.expect(!try f.pass());
    try std.testing.expect(f.w.reply().lost >= 3);
}

test "since skips rows whose change the tracker no longer knows, and counts them as lost" {
    const gpa = std.testing.allocator;
    const f = try TestWait.create(3, 10_000_000);
    defer f.destroy();
    f.feed("OLDNEEDLE\r\n");
    f.tracker.settle(&f.term, 0);
    try f.wait(.{ .match = "OLDNEEDLE", .since = f.tracker.seq.raw });
    // More rows scroll by than the tracker keeps the state of.
    var flood: std.ArrayListUnmanaged(u8) = .empty;
    defer flood.deinit(gpa);
    for (0..1500) |i| try flood.print(gpa, "{d}\r\n", .{i});
    f.feed(flood.items);
    try std.testing.expect(!try f.pass());
    try std.testing.expect(f.w.reply().lost > 0);
}
