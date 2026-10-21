//! Glyphs drawn from geometry rather than taken from a font: box drawing,
//! block elements, braille, Powerline separators, and sextants. Every position
//! comes from the box size alone, so strokes and blocks join across cells.

const std = @import("std");

/// Whether `cp` is one of the drawn code points.
pub fn covers(cp: u21) bool {
    return switch (cp) {
        0x2500...0x259F, 0x2800...0x28FF, 0xE0B0...0xE0BF, 0x1FB00...0x1FB3B => true,
        else => false,
    };
}

/// Draw `cp` into `out`: coverage, `w * h` bytes, row-major, which the caller zeroed; 255 is fully covered.
/// Returns false, leaving `out` untouched, when `cp` is not drawn.
pub fn draw(cp: u21, w: u16, h: u16, out: []u8) bool {
    if (!covers(cp)) return false;
    std.debug.assert(out.len >= @as(usize, w) * h);
    const c: Canvas = .{ .w = w, .h = h, .t = @max(1, h / 18), .out = out };
    switch (cp) {
        0x2504...0x250B, 0x254C...0x254F => c.dashes(cp),
        0x256D...0x2570 => c.arc(cp),
        0x2571...0x2573 => c.diagonal(cp),
        0x2500...0x2503, 0x250C...0x254B, 0x2550...0x256C, 0x2574...0x257F => c.box(arms[cp - 0x2500]),
        0x2580...0x259F => c.block(cp),
        0x2800...0x28FF => c.braille(@truncate(cp)),
        0xE0B0...0xE0BF => c.powerline(cp),
        else => {
            var v: u8 = @intCast(cp - 0x1FB00 + 1);
            if (v >= 21) v += 1;
            if (v >= 42) v += 1;
            c.mosaic(v, 3);
        },
    }
    return true;
}

const Weight = enum { none, light, heavy, double };

/// Arms up, right, down, left of each box drawing character made of arms:
/// a start code point, then one entry per code point from it.
const arm_src =
    \\2500 0l0l 0h0h l0l0 h0h0
    \\250C 0ll0 0hl0 0lh0 0hh0 00ll 00lh 00hl 00hh ll00 lh00 hl00 hh00 l00l l00h h00l h00h
    \\251C lll0 lhl0 hll0 llh0 hlh0 hhl0 lhh0 hhh0 l0ll l0lh h0ll l0hl h0hl h0lh l0hh h0hh
    \\252C 0lll 0llh 0hll 0hlh 0lhl 0lhh 0hhl 0hhh ll0l ll0h lh0l lh0h hl0l hl0h hh0l hh0h
    \\253C llll lllh lhll lhlh hlll llhl hlhl hllh hhll llhh lhhl hhlh lhhh hlhh hhhl hhhh
    \\2550 0d0d d0d0 0dl0 0ld0 0dd0 00ld 00dl 00dd ld00 dl00 dd00 l00d d00l d00d ldl0 dld0
    \\2560 ddd0 l0ld d0dl d0dd 0dld 0ldl 0ddd ld0d dl0l dd0d ldld dldl dddd
    \\2574 000l l000 0l00 00l0 000h h000 0h00 00h0 0h0l l0h0 0l0h h0l0
;

const arms: [128][4]Weight = blk: {
    @setEvalBranchQuota(20000);
    var table: [128][4]Weight = @splat(@splat(.none));
    var lines = std.mem.tokenizeScalar(u8, arm_src, '\n');
    while (lines.next()) |line| {
        var codes = std.mem.tokenizeScalar(u8, line, ' ');
        var i = (std.fmt.parseInt(u21, codes.next().?, 16) catch unreachable) - 0x2500;
        while (codes.next()) |code| : (i += 1) {
            for (code, 0..) |ch, k| table[i][k] = switch (ch) {
                '0' => .none,
                'l' => .light,
                'h' => .heavy,
                'd' => .double,
                else => unreachable,
            };
        }
    }
    break :blk table;
};

const Span = struct { lo: i32, hi: i32 };

/// `n * k / d`, rounded half up, so fractions of a cell tile.
fn part(n: i32, k: i32, d: i32) i32 {
    return @divFloor(2 * n * k + d, 2 * d);
}

const Canvas = struct {
    w: i32,
    h: i32,
    t: i32,
    out: []u8,

    fn size(c: Canvas) [2]f32 {
        return .{ @floatFromInt(c.w), @floatFromInt(c.h) };
    }

    fn radius(c: Canvas) f32 {
        return @as(f32, @floatFromInt(c.t)) / 2;
    }

    fn rect(c: Canvas, x0: i32, y0: i32, x1: i32, y1: i32) void {
        const xa: usize = @intCast(std.math.clamp(x0, 0, c.w));
        const xb: usize = @intCast(std.math.clamp(x1, 0, c.w));
        const ya: usize = @intCast(std.math.clamp(y0, 0, c.h));
        const yb: usize = @intCast(std.math.clamp(y1, 0, c.h));
        if (xa >= xb or ya >= yb) return;
        const w: usize = @intCast(c.w);
        for (ya..yb) |y| @memset(c.out[y * w + xa .. y * w + xb], 255);
    }

    fn shade(c: Canvas, shape: anytype) void {
        const w: usize = @intCast(c.w);
        for (0..@intCast(c.h)) |y| {
            for (0..w) |x| {
                var n: u32 = 0;
                for (0..4) |j| {
                    for (0..4) |i| {
                        const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(i)) + 0.5) / 4;
                        const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(j)) + 0.5) / 4;
                        if (shape.in(px, py)) n += 1;
                    }
                }
                const p = &c.out[y * w + x];
                p.* = @max(p.*, @as(u8, @intCast((n * 255 + 8) / 16)));
            }
        }
    }

    /// The strokes of a line of weight `wt` across an axis of length `n`; both are the same unless double.
    fn bands(c: Canvas, wt: Weight, n: i32) [2]Span {
        const k: i32 = switch (wt) {
            .light => 1,
            .heavy => 2,
            .double => 3,
            .none => unreachable,
        };
        const lo = @divFloor(n - k * c.t, 2);
        if (wt == .double) return .{ .{ .lo = lo, .hi = lo + c.t }, .{ .lo = lo + 2 * c.t, .hi = lo + 3 * c.t } };
        return @splat(.{ .lo = lo, .hi = lo + k * c.t });
    }

    fn mid(c: Canvas, n: i32) f32 {
        return @as(f32, @floatFromInt(c.bands(.light, n)[0].lo)) + c.radius();
    }

    fn box(c: Canvas, a: [4]Weight) void {
        const u, const r, const d, const l = a;
        c.arm(false, false, l, r, u, d);
        c.arm(false, true, r, l, u, d);
        c.arm(true, false, u, d, l, r);
        c.arm(true, true, d, u, l, r);
    }

    /// Draw one arm of weight `wt`, from the low edge (or to the high edge when `pos`) of its axis, given the
    /// opposite arm `opp` and the perpendicular arms on the low (`pn`) and high (`pp`) side.
    fn arm(c: Canvas, vertical: bool, pos: bool, wt: Weight, opp: Weight, pn: Weight, pp: Weight) void {
        if (wt == .none) return;
        const len = if (vertical) c.h else c.w;
        var ends: [2]i32 = @splat(@divFloor(len, 2));
        if (pn == .double or pp == .double) {
            const d = c.bands(.double, len);
            const inner = if (pos) d[1].lo else d[0].hi;
            const outer = if (pos) d[0].lo else d[1].hi;
            if (wt == .double) {
                ends = .{ if (pn != .none) inner else outer, if (pp != .none) inner else outer };
            } else {
                ends = @splat(if (opp == .none and pn != .none and pp != .none) inner else outer);
            }
        } else if (pn != .none or pp != .none) {
            var u: Span = .{ .lo = len, .hi = 0 };
            for ([_]Weight{ pn, pp }) |p| {
                if (p == .none) continue;
                const b = c.bands(p, len);
                u = .{ .lo = @min(u.lo, b[0].lo), .hi = @max(u.hi, b[1].hi) };
            }
            ends = @splat(if (pos) u.lo else u.hi);
        }
        for (c.bands(wt, if (vertical) c.w else c.h), ends) |b, e| {
            const s: Span = if (pos) .{ .lo = e, .hi = len } else .{ .lo = 0, .hi = e };
            if (vertical) c.rect(b.lo, s.lo, b.hi, s.hi) else c.rect(s.lo, b.lo, s.hi, b.hi);
        }
    }

    fn dashes(c: Canvas, cp: u21) void {
        const i = if (cp >= 0x254C) cp - 0x254C else cp - 0x2504;
        const n: i32 = if (cp >= 0x254C) 2 else if (i < 4) 3 else 4;
        const vertical = i & 2 != 0;
        const len = if (vertical) c.h else c.w;
        const b = c.bands(if (i & 1 != 0) .heavy else .light, if (vertical) c.w else c.h)[0];
        const gap = @max(1, @divFloor(len, 3 * n));
        var k: i32 = 0;
        while (k < n) : (k += 1) {
            const lo = part(len, k, n) + @divFloor(gap, 2);
            const hi = part(len, k + 1, n) - (gap - @divFloor(gap, 2));
            if (vertical) c.rect(b.lo, lo, b.hi, hi) else c.rect(lo, b.lo, hi, b.hi);
        }
    }

    fn arc(c: Canvas, cp: u21) void {
        const w, const h = c.size();
        const cx = c.mid(c.w);
        const cy = c.mid(c.h);
        c.shade(Arc{
            .cx = cx,
            .cy = cy,
            // One pixel short of the edges, which the straight strokes reach.
            .r = @max(0.5, @min(@min(cx, w - cx), @min(cy, h - cy)) - 1),
            .dx = if (cp == 0x256D or cp == 0x2570) 1 else -1,
            .dy = if (cp <= 0x256E) 1 else -1,
            .half = c.radius(),
        });
    }

    fn diagonal(c: Canvas, cp: u21) void {
        const w, const h = c.size();
        const back: [4]f32 = .{ -w, -h, 2 * w, 2 * h };
        const fwd: [4]f32 = .{ 2 * w, -h, -w, 2 * h };
        c.shade(Lines{ .seg = .{ if (cp == 0x2572) back else fwd, back }, .n = if (cp == 0x2573) 2 else 1, .half = c.radius() });
    }

    fn block(c: Canvas, cp: u21) void {
        const w = c.w;
        const h = c.h;
        switch (cp) {
            0x2580 => c.rect(0, 0, w, part(h, 4, 8)),
            0x2581...0x2588 => c.rect(0, part(h, 0x2588 - @as(i32, cp), 8), w, h),
            0x2589...0x258F => c.rect(0, 0, part(w, 0x2590 - @as(i32, cp), 8), h),
            0x2590 => c.rect(part(w, 4, 8), 0, w, h),
            0x2591...0x2593 => @memset(c.out[0 .. @as(usize, @intCast(w)) * @as(usize, @intCast(h))], @intCast((cp - 0x2590) * 64)),
            0x2594 => c.rect(0, 0, w, part(h, 1, 8)),
            0x2595 => c.rect(part(w, 7, 8), 0, w, h),
            else => c.mosaic(([_]u8{ 4, 8, 1, 13, 9, 7, 11, 2, 6, 14 })[cp - 0x2596], 2),
        }
    }

    /// Fill the cells of a two-column mosaic with `rows` rows; bit `i` is row `i / 2`, column `i % 2`.
    fn mosaic(c: Canvas, bits: u8, rows: i32) void {
        const xs = [3]i32{ 0, part(c.w, 1, 2), c.w };
        var i: u3 = 0;
        while (i < 2 * rows) : (i += 1) {
            if (bits >> i & 1 == 0) continue;
            const row: i32 = i / 2;
            c.rect(xs[i % 2], part(c.h, row, rows), xs[i % 2 + 1], part(c.h, row + 1, rows));
        }
    }

    fn braille(c: Canvas, bits: u8) void {
        const dots = [8][2]i32{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 1, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 3 }, .{ 1, 3 } };
        const s = @max(1, @min(@divFloor(c.w, 4), @divFloor(c.h, 8)));
        for (dots, 0..) |d, i| {
            if (bits >> @intCast(i) & 1 == 0) continue;
            const x = @divFloor(c.w * (2 * d[0] + 1), 4) - @divFloor(s, 2);
            const y = @divFloor(c.h * (2 * d[1] + 1), 8) - @divFloor(s, 2);
            c.rect(x, y, x + s, y + s);
        }
    }

    fn powerline(c: Canvas, cp: u21) void {
        const w, const h = c.size();
        const half = c.radius();
        const back: [4]f32 = .{ -w, -h, 2 * w, 2 * h };
        const fwd: [4]f32 = .{ 2 * w, -h, -w, 2 * h };
        switch (cp) {
            0xE0B1, 0xE0B3 => {
                const tx = if (cp == 0xE0B1) w - half else half;
                const ex = if (cp == 0xE0B1) 0 else 2 * w;
                c.shade(Lines{ .seg = .{ .{ ex - tx, -h / 2, tx, h / 2 }, .{ tx, h / 2, ex - tx, 3 * h / 2 } }, .n = 2, .half = half });
            },
            0xE0B5, 0xE0B7 => c.shade(Ring{
                .cx = if (cp == 0xE0B5) 0 else w,
                .cy = h / 2,
                .rx = @max(half, w - half),
                .ry = h / 2,
                .half = half,
            }),
            0xE0B9, 0xE0BF => c.shade(Lines{ .seg = .{ back, back }, .n = 1, .half = half }),
            0xE0BB, 0xE0BD => c.shade(Lines{ .seg = .{ fwd, fwd }, .n = 1, .half = half }),
            else => c.shade(Solid{ .cp = cp, .w = w, .h = h }),
        }
    }
};

/// A rounded corner: straight light strokes from two edges joined by a quarter circle of radius `r`, the arms
/// pointing along `dx` and `dy` from the stroke centres `cx`, `cy`.
const Arc = struct {
    cx: f32,
    cy: f32,
    r: f32,
    dx: f32,
    dy: f32,
    half: f32,

    fn in(a: Arc, x: f32, y: f32) bool {
        const ox = a.cx + a.dx * a.r;
        const oy = a.cy + a.dy * a.r;
        if ((x - ox) * a.dx >= 0 and @abs(y - a.cy) <= a.half) return true;
        if ((y - oy) * a.dy >= 0 and @abs(x - a.cx) <= a.half) return true;
        if ((x - ox) * a.dx > 0 or (y - oy) * a.dy > 0) return false;
        return @abs(@sqrt((x - ox) * (x - ox) + (y - oy) * (y - oy)) - a.r) <= a.half;
    }
};

/// Up to two segments, each `x0, y0, x1, y1`, stroked `2 * half` wide.
const Lines = struct {
    seg: [2][4]f32,
    n: usize,
    half: f32,

    fn in(s: Lines, x: f32, y: f32) bool {
        for (s.seg[0..s.n]) |g| {
            const vx = g[2] - g[0];
            const vy = g[3] - g[1];
            const px = x - g[0];
            const py = y - g[1];
            const len2 = vx * vx + vy * vy;
            const k = if (len2 == 0) 0 else std.math.clamp((px * vx + py * vy) / len2, 0, 1);
            const ex = px - k * vx;
            const ey = py - k * vy;
            if (ex * ex + ey * ey <= s.half * s.half) return true;
        }
        return false;
    }
};

const Ring = struct {
    cx: f32,
    cy: f32,
    rx: f32,
    ry: f32,
    half: f32,

    fn in(e: Ring, x: f32, y: f32) bool {
        const qx = (x - e.cx) / e.rx;
        const qy = (y - e.cy) / e.ry;
        const k = @sqrt(qx * qx + qy * qy);
        const gx = qx / e.rx;
        const gy = qy / e.ry;
        const g = @sqrt(gx * gx + gy * gy);
        return g > 0 and @abs(k - 1) * k / g <= e.half;
    }
};

const Solid = struct {
    cp: u21,
    w: f32,
    h: f32,

    fn in(s: Solid, x: f32, y: f32) bool {
        const u = x / s.w;
        const v = y / s.h;
        const m = 2 * v - 1;
        return switch (s.cp) {
            0xE0B0 => u <= 1 - @abs(m),
            0xE0B2 => u >= @abs(m),
            0xE0B4 => u * u + m * m <= 1,
            0xE0B6 => (1 - u) * (1 - u) + m * m <= 1,
            0xE0B8 => u <= v,
            0xE0BA => u >= 1 - v,
            0xE0BC => u <= 1 - v,
            0xE0BE => u >= v,
            else => unreachable,
        };
    }
};

fn render(cp: u21, w: u16, h: u16, buf: []u8) []u8 {
    const out = buf[0 .. @as(usize, w) * h];
    @memset(out, 0);
    std.debug.assert(draw(cp, w, h, out));
    return out;
}

test "lines join across cells" {
    var a: [10 * 22]u8 = undefined;
    var b: [10 * 22]u8 = undefined;
    for ([_][2]u16{ .{ 8, 16 }, .{ 10, 22 } }) |size| {
        const w, const h = size;
        for ([_][2]u21{ .{ '─', '─' }, .{ '─', '┼' }, .{ '┌', '─' }, .{ '═', '╦' }, .{ '━', '┳' } }) |pair| {
            const left = render(pair[0], w, h, &a);
            const right = render(pair[1], w, h, &b);
            var any = false;
            for (0..h) |y| {
                try std.testing.expectEqual(left[y * w + w - 1], right[y * w]);
                any = any or right[y * w] != 0;
            }
            try std.testing.expect(any);
        }
        for ([_][2]u21{ .{ '│', '│' }, .{ '┌', '│' }, .{ '║', '╠' }, .{ '┃', '┫' } }) |pair| {
            const upper = render(pair[0], w, h, &a);
            const lower = render(pair[1], w, h, &b);
            try std.testing.expectEqualSlices(u8, upper[(h - 1) * w ..][0..w], lower[0..w]);
            try std.testing.expect(std.mem.indexOfNone(u8, lower[0..w], &.{0}) != null);
        }
    }
}

test "left and right half blocks cover a cell exactly once" {
    var a: [10 * 22]u8 = undefined;
    var b: [10 * 22]u8 = undefined;
    for ([_][2]u16{ .{ 8, 16 }, .{ 9, 17 } }) |size| {
        const left = render('▌', size[0], size[1], &a);
        const right = render('▐', size[0], size[1], &b);
        for (left, right) |l, r| try std.testing.expectEqual(255, @as(u16, l) + r);
    }
}

test "every drawn code point fits odd and tiny boxes" {
    var buf: [40 * 40]u8 = undefined;
    for ([_][2]u16{ .{ 1, 1 }, .{ 1, 40 }, .{ 40, 1 }, .{ 3, 5 }, .{ 17, 37 } }) |size| {
        for ([_][2]u21{ .{ 0x2500, 0x259F }, .{ 0x2800, 0x28FF }, .{ 0xE0B0, 0xE0BF }, .{ 0x1FB00, 0x1FB3B } }) |r| {
            for (r[0]..r[1] + 1) |cp| _ = render(@intCast(cp), size[0], size[1], &buf);
        }
    }
}

test "code points outside the drawn ranges are left to the font" {
    var buf: [4]u8 = @splat(7);
    try std.testing.expect(!covers('A'));
    try std.testing.expect(!draw('A', 2, 2, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 7 }, &buf);
}
