const std = @import("std");
const layout = @import("./layout.zig");
const wth = @import("./width.zig");

pub const Grid = struct {
    allocator: std.mem.Allocator,
    size: layout.Size,
    cells: []Cell,

    pub const Color = struct {
        r: u8,
        g: u8,
        b: u8,

        pub fn eql(self: Color, other: Color) bool {
            return self.r == other.r and self.g == other.g and self.b == other.b;
        }
    };

    pub const Style = struct {
        inverted: bool = false,
        // truecolor foreground/background. null means "leave the terminal
        // default", which is how transparency is expressed: a cell with no bg
        // lets whatever is behind it (the terminal background) show through.
        fg: ?Color = null,
        bg: ?Color = null,

        pub fn eql(self: Style, other: Style) bool {
            if (self.inverted != other.inverted) return false;
            if (!optColorEql(self.fg, other.fg)) return false;
            if (!optColorEql(self.bg, other.bg)) return false;
            return true;
        }

        fn optColorEql(a: ?Color, b: ?Color) bool {
            if (a) |av| {
                return if (b) |bv| av.eql(bv) else false;
            }
            return b == null;
        }
    };

    pub const Cell = struct {
        rune: ?u21,
        style: Style = .{},
        // this cell is the second column of a double-width rune held by the
        // cell to its left. rune is always null, but the column is occupied,
        // not empty — the renderer must neither draw nor clear it.
        continuation: bool = false,

        pub fn eql(self: Cell, other: Cell) bool {
            if (self.continuation != other.continuation) return false;
            if (!self.style.eql(other.style)) return false;
            return self.rune == other.rune;
        }
    };
    pub fn init(allocator: std.mem.Allocator, size: layout.Size) !Grid {
        const cells = try allocator.alloc(Cell, size.width * size.height);
        @memset(cells, .{ .rune = null });
        return .{
            .allocator = allocator,
            .size = size,
            .cells = cells,
        };
    }

    pub fn cell(self: Grid, x: usize, y: usize) error{IndexOutOfBounds}!*Cell {
        if (x >= self.size.width or y >= self.size.height) return error.IndexOutOfBounds;
        return &self.cells[y * self.size.width + x];
    }

    pub fn clone(self: Grid, allocator: std.mem.Allocator) !Grid {
        return .{
            .allocator = allocator,
            .size = self.size,
            .cells = try allocator.dupe(Cell, self.cells),
        };
    }

    pub fn initFromGrid(allocator: std.mem.Allocator, grid: Grid, size: layout.Size, grid_x: isize, grid_y: isize) !Grid {
        var new_grid = try Grid.init(allocator, size);
        new_grid.drawGridView(grid, size, grid_x, grid_y);
        return new_grid;
    }

    // copy a source view into the top-left corner; the view size can
    // exclude space reserved for scroll bars
    pub fn drawGridView(self: *Grid, grid: Grid, view_size: layout.Size, grid_x: isize, grid_y: isize) void {
        const size: layout.Size = .{
            .width = @min(view_size.width, self.size.width),
            .height = @min(view_size.height, self.size.height),
        };
        const ugrid_x: usize = if (grid_x < 0) 0 else @intCast(grid_x);
        const ugrid_y: usize = if (grid_y < 0) 0 else @intCast(grid_y);
        var dest_y: usize = if (grid_y < 0) @abs(grid_y) else 0;
        for (ugrid_y..ugrid_y + size.height) |source_y| {
            if (dest_y >= size.height) break;
            var dest_x: usize = if (grid_x < 0) @abs(grid_x) else 0;
            for (ugrid_x..ugrid_x + size.width) |source_x| {
                if (dest_x >= size.width) break;
                if (self.cell(dest_x, dest_y)) |dest_cell| {
                    if (grid.cell(source_x, source_y)) |source_cell| {
                        var src = source_cell.*;
                        // a wide pair split by the view's left or right edge
                        // renders as a blank column — half a glyph can't be
                        // drawn
                        if (src.continuation and source_x == ugrid_x) {
                            src = .{ .rune = ' ', .style = src.style };
                        } else if (dest_x + 1 == size.width) {
                            if (grid.cell(source_x + 1, source_y)) |next_cell| {
                                if (next_cell.continuation) {
                                    src = .{ .rune = ' ', .style = src.style };
                                }
                            } else |_| {}
                        }
                        self.blankPartner(dest_x, dest_y);
                        dest_cell.* = src;
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
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.cells);
    }

    // blank the surviving half of any wide-rune pair the cell at (x, y)
    // belongs to, in preparation for overwriting that cell. the orphaned half
    // becomes a space — the column stays occupied, but half a glyph can't be
    // drawn. the cell itself is left for the caller to overwrite.
    fn blankPartner(self: *Grid, x: usize, y: usize) void {
        const target = self.cell(x, y) catch return;
        if (target.continuation) {
            // (x - 1) holds the wide rune this cell completes. a continuation
            // never sits in column 0, but stay safe against hand-built grids.
            if (x == 0) return;
            const lead = self.cell(x - 1, y) catch return;
            lead.rune = ' ';
            lead.continuation = false;
        } else {
            // if (x + 1) is a continuation, this cell is its wide lead
            const continuation = self.cell(x + 1, y) catch return;
            if (continuation.continuation) {
                continuation.rune = ' ';
                continuation.continuation = false;
            }
        }
    }

    // write `rune` (null to empty the cell) at column x, row y, keeping
    // double-width pairs consistent: a wide rune claims (x + 1) as a
    // continuation cell, and overwriting either half of an existing pair
    // blanks the orphaned half to a space. a wide rune against the right
    // edge, with no room for its continuation, becomes a space too. the
    // cell's style is left untouched.
    pub fn setRune(self: *Grid, x: usize, y: usize, rune: ?u21) !void {
        const target = try self.cell(x, y);
        self.blankPartner(x, y);
        target.continuation = false;
        const is_wide = if (rune) |cp| wth.cellWidth(cp) == 2 else false;
        if (is_wide) {
            if (self.cell(x + 1, y)) |continuation| {
                self.blankPartner(x + 1, y);
                target.rune = rune;
                continuation.rune = null;
                continuation.continuation = true;
                continuation.style = target.style;
            } else |_| {
                target.rune = ' ';
            }
        } else {
            target.rune = rune;
        }
    }

    pub fn drawGrid(self: *Grid, child_grid: Grid, target_x: usize, target_y: usize) !void {
        for (0..child_grid.size.height) |y| {
            for (0..child_grid.size.width) |x| {
                const src = (try child_grid.cell(x, y)).*;
                if (self.cell(x + target_x, y + target_y)) |target| {
                    // blank the outside half of any wide pair this write
                    // splits (the inside half is overwritten by the copy)
                    self.blankPartner(x + target_x, y + target_y);
                    target.* = src;
                } else |_| {
                    // clipped by our right edge: if the cell that didn't fit
                    // was a continuation, its wide lead landed in our last
                    // column as half a glyph — blank it
                    if (src.continuation and x > 0) {
                        if (self.cell(x + target_x - 1, y + target_y)) |lead| {
                            lead.rune = ' ';
                            lead.continuation = false;
                        } else |_| {}
                    }
                    break;
                }
            }
        }
    }

    pub fn toString(self: Grid, allocator: std.mem.Allocator) ![]const u8 {
        if (self.size.width == 0 or self.size.height == 0) {
            return error.EmptyGrid;
        }

        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        for (0..self.size.height) |y| {
            for (0..self.size.width) |x| {
                const current = (try self.cell(x, y)).*;
                // the wide rune to the left already covers this column
                if (current.continuation) continue;
                if (current.rune) |rune| {
                    var encoded: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(rune, &encoded);
                    try buffer.appendSlice(allocator, encoded[0..len]);
                } else {
                    try buffer.append(allocator, ' ');
                }
            }
            if (y + 1 < self.size.height) {
                try buffer.append(allocator, '\n');
            }
        }

        return try buffer.toOwnedSlice(allocator);
    }
};

test {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, .{ .width = 10, .height = 10 });
    defer grid.deinit();
    try std.testing.expectEqual(null, (try grid.cell(0, 0)).rune);
}

test "setRune keeps wide pairs consistent" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, .{ .width = 4, .height = 1 });
    defer grid.deinit();

    // a wide rune claims its continuation cell
    try grid.setRune(0, 0, '中');
    try std.testing.expectEqual(@as(u21, '中'), grid.cells[0].rune.?);
    try std.testing.expect(grid.cells[1].continuation);
    try std.testing.expectEqual(null, grid.cells[1].rune);

    // overwriting the continuation blanks the orphaned lead
    try grid.setRune(1, 0, 'x');
    try std.testing.expectEqual(@as(u21, ' '), grid.cells[0].rune.?);
    try std.testing.expect(!grid.cells[1].continuation);
    try std.testing.expectEqual(@as(u21, 'x'), grid.cells[1].rune.?);

    // overwriting the lead blanks the orphaned continuation
    try grid.setRune(0, 0, '中');
    try grid.setRune(0, 0, 'y');
    try std.testing.expectEqual(@as(u21, 'y'), grid.cells[0].rune.?);
    try std.testing.expect(!grid.cells[1].continuation);
    try std.testing.expectEqual(@as(u21, ' '), grid.cells[1].rune.?);

    // a wide rune against the right edge has no room for its continuation
    try grid.setRune(3, 0, '中');
    try std.testing.expectEqual(@as(u21, ' '), grid.cells[3].rune.?);
}

test "toString skips continuation cells" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, .{ .width = 3, .height = 1 });
    defer grid.deinit();
    try grid.setRune(0, 0, '中');
    try grid.setRune(2, 0, 'a');

    const str = try grid.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("中a", str);
}

test "initFromGrid blanks wide pairs split by the view edge" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, .{ .width = 6, .height = 1 });
    defer grid.deinit();
    // 你(0,1) 好(2,3) a(4)
    try grid.setRune(0, 0, '你');
    try grid.setRune(2, 0, '好');
    try grid.setRune(4, 0, 'a');

    // view [1, 4): 你's continuation at the left edge, 好 intact
    var view = try Grid.initFromGrid(allocator, grid, .{ .width = 3, .height = 1 }, 1, 0);
    defer view.deinit();
    const left = try view.toString(allocator);
    defer allocator.free(left);
    try std.testing.expectEqualStrings(" 好", left);

    // view [0, 3): 好's lead at the right edge loses its continuation
    var view2 = try Grid.initFromGrid(allocator, grid, .{ .width = 3, .height = 1 }, 0, 0);
    defer view2.deinit();
    const right = try view2.toString(allocator);
    defer allocator.free(right);
    try std.testing.expectEqualStrings("你 ", right);
}
