const std = @import("std");
const layout = @import("./layout.zig");
const NDSlice = @import("./ndslice.zig").NDSlice;

pub const Grid = struct {
    allocator: std.mem.Allocator,
    size: layout.Size,
    cells: Cells,
    buffer: []Grid.Cell,

    pub const Cell = struct {
        rune: ?[]const u8,
    };
    pub const Cells = NDSlice(Cell, 2, .row_major);

    pub fn init(allocator: std.mem.Allocator, size: layout.Size) !Grid {
        const buffer = try allocator.alloc(Grid.Cell, size.width * size.height);
        errdefer allocator.free(buffer);
        for (buffer) |*cell| {
            cell.rune = null;
        }
        return .{
            .allocator = allocator,
            .size = size,
            .cells = try Grid.Cells.init(.{ size.height, size.width }, buffer),
            .buffer = buffer,
        };
    }

    pub fn initFromGrid(allocator: std.mem.Allocator, grid: Grid, size: layout.Size, grid_x: isize, grid_y: isize) !Grid {
        const buffer = try allocator.alloc(Grid.Cell, size.width * size.height);
        errdefer allocator.free(buffer);
        for (buffer) |*cell| {
            cell.rune = null;
        }
        const ugrid_x: usize = if (grid_x < 0) 0 else @intCast(grid_x);
        const ugrid_y: usize = if (grid_y < 0) 0 else @intCast(grid_y);
        var cells = try Grid.Cells.init(.{ size.height, size.width }, buffer);
        var dest_y: usize = if (grid_y < 0) @abs(grid_y) else 0;
        for (ugrid_y..ugrid_y + size.height) |source_y| {
            var dest_x: usize = if (grid_x < 0) @abs(grid_x) else 0;
            for (ugrid_x..ugrid_x + size.width) |source_x| {
                if (cells.at(.{ dest_y, dest_x })) |dest_index| {
                    if (grid.cells.at(.{ source_y, source_x })) |source_index| {
                        cells.items[dest_index].rune = grid.cells.items[source_index].rune;
                    } else |_| {
                        break;
                    }
                } else |_| {
                    break;
                }
                dest_x += 1;
            }
            dest_y += 1;
        }
        return .{
            .allocator = allocator,
            .size = size,
            .cells = cells,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.buffer);
    }

    pub fn drawGrid(self: *Grid, child_grid: Grid, target_x: usize, target_y: usize) !void {
        for (0..child_grid.size.height) |y| {
            for (0..child_grid.size.width) |x| {
                const rune = child_grid.cells.items[try child_grid.cells.at(.{ y, x })].rune;
                if (self.cells.at(.{ y + target_y, x + target_x })) |index| {
                    self.cells.items[index].rune = rune;
                } else |_| {
                    break;
                }
            }
        }
    }
};

test {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, .{ .width = 10, .height = 10 });
    defer grid.deinit();
    try std.testing.expectEqual(null, grid.cells.items[try grid.cells.at(.{ 0, 0 })].rune);
}
