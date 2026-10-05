//! Minimal geometry types for the vendored mouse encoder: a faithful
//! subset of ghostty's renderer/size.zig + terminal/point.zig, with a
//! 1:1 cell/pixel mapping (we have no real renderer).

const std = @import("std");

pub const CellCountInt = u16;

/// The dimensions of a single "cell" in the terminal grid.
pub const CellSize = extern struct {
    width: u32,
    height: u32,
};

/// The dimensions of the screen that the grid is rendered to.
pub const ScreenSize = extern struct {
    width: u32,
    height: u32,

    pub fn subPadding(self: ScreenSize, padding: Padding) ScreenSize {
        return .{
            .width = self.width -| padding.left -| padding.right,
            .height = self.height -| padding.top -| padding.bottom,
        };
    }
};

/// The dimensions of the grid itself, in rows/columns units.
pub const GridSize = extern struct {
    pub const Unit = CellCountInt;

    columns: Unit = 0,
    rows: Unit = 0,

    pub fn init(screen: ScreenSize, cell: CellSize) GridSize {
        var result: GridSize = undefined;
        result.update(screen, cell);
        return result;
    }

    pub fn update(self: *GridSize, screen: ScreenSize, cell: CellSize) void {
        const cell_width: f32 = @floatFromInt(cell.width);
        const cell_height: f32 = @floatFromInt(cell.height);
        const screen_width: f32 = @floatFromInt(screen.width);
        const screen_height: f32 = @floatFromInt(screen.height);
        const calc_cols: Unit = @intFromFloat(screen_width / cell_width);
        const calc_rows: Unit = @intFromFloat(screen_height / cell_height);
        self.columns = @max(1, calc_cols);
        self.rows = @max(1, calc_rows);
    }
};

pub const Padding = extern struct {
    top: u32 = 0,
    bottom: u32 = 0,
    right: u32 = 0,
    left: u32 = 0,
};

/// All relevant sizes for a rendered terminal.
pub const Size = struct {
    screen: ScreenSize,
    cell: CellSize,
    padding: Padding,

    pub fn grid(self: Size) GridSize {
        return .init(self.screen.subPadding(self.padding), self.cell);
    }

    pub fn terminal(self: Size) ScreenSize {
        return self.screen.subPadding(self.padding);
    }
};

/// A coordinate in one of several spaces (surface px, terminal px, grid
/// cells). Conversions mirror ghostty's renderer/size.zig.
pub const Coordinate = union(enum) {
    surface: Surface,
    terminal: Terminal,
    grid: Grid,

    pub const Tag = @typeInfo(Coordinate).@"union".tag_type.?;
    pub const Surface = struct { x: f64, y: f64 };
    pub const Terminal = struct { x: f64, y: f64 };
    pub const Grid = struct { x: GridSize.Unit, y: GridSize.Unit };

    pub fn convert(self: Coordinate, to: Tag, size: Size) Coordinate {
        if (@as(Tag, self) == to) return self;

        const surface = self.convertToSurface(size);

        return switch (to) {
            .surface => .{ .surface = surface },
            .terminal => .{ .terminal = .{
                .x = surface.x - @as(f64, @floatFromInt(size.padding.left)),
                .y = surface.y - @as(f64, @floatFromInt(size.padding.top)),
            } },
            .grid => grid: {
                const term = (Coordinate{ .surface = surface }).convert(
                    .terminal,
                    size,
                ).terminal;

                const grid = size.grid();

                const cell_width: f64 = @as(f64, @floatFromInt(size.cell.width));
                const cell_height: f64 = @as(f64, @floatFromInt(size.cell.height));
                const clamped_x: f64 = @max(0, term.x);
                const clamped_y: f64 = @max(0, term.y);
                const col: GridSize.Unit = @intFromFloat(clamped_x / cell_width);
                const row: GridSize.Unit = @intFromFloat(clamped_y / cell_height);
                const clamped_col: GridSize.Unit = @min(col, grid.columns - 1);
                const clamped_row: GridSize.Unit = @min(row, grid.rows - 1);
                break :grid .{ .grid = .{ .x = clamped_col, .y = clamped_row } };
            },
        };
    }

    fn convertToSurface(self: Coordinate, size: Size) Surface {
        return switch (self) {
            .surface => |v| v,
            .terminal => |v| .{
                .x = v.x + @as(f64, @floatFromInt(size.padding.left)),
                .y = v.y + @as(f64, @floatFromInt(size.padding.top)),
            },
            .grid => |v| grid: {
                const col: f64 = @floatFromInt(v.x);
                const row: f64 = @floatFromInt(v.y);
                const cell_width: f64 = @floatFromInt(size.cell.width);
                const cell_height: f64 = @floatFromInt(size.cell.height);
                const padding_left: f64 = @floatFromInt(size.padding.left);
                const padding_top: f64 = @floatFromInt(size.padding.top);
                break :grid .{
                    .x = col * cell_width + padding_left,
                    .y = row * cell_height + padding_top,
                };
            },
        };
    }
};

/// A grid cell coordinate (zero-based column, row).
pub const Cell = struct {
    x: u32,
    y: u32,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.x == other.x and self.y == other.y;
    }
};
