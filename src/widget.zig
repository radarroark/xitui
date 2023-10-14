const std = @import("std");
const grd = @import("./grid.zig");
const layout = @import("./layout.zig");
const MaybeSize = layout.MaybeSize;
const inp = @import("./input.zig");

pub fn Any(comptime Widget: type) type {
    return struct {
        widget: Widget,

        pub fn init(widget: Widget) Any(Widget) {
            return .{
                .widget = widget,
            };
        }

        pub fn deinit(self: *Any(Widget)) void {
            switch (self.widget) {
                inline else => |*case| case.deinit(),
            }
        }

        pub fn build(self: *Any(Widget), max_size: MaybeSize) anyerror!void {
            switch (self.widget) {
                inline else => |*case| try case.build(max_size),
            }
        }

        pub fn input(self: *Any(Widget), key: inp.Key) anyerror!void {
            switch (self.widget) {
                inline else => |*case| try case.input(key),
            }
        }

        pub fn grid(self: *Any(Widget)) ?grd.Grid {
            switch (self.widget) {
                inline else => |*case| return case.grid,
            }
        }

        pub fn clear(self: *Any(Widget)) void {
            switch (self.widget) {
                inline else => |*case| case.clear(),
            }
        }
    };
}

pub const Text = struct {
    allocator: std.mem.Allocator,
    grid: ?grd.Grid,
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) Text {
        return .{
            .allocator = allocator,
            .grid = null,
            .content = content,
        };
    }

    pub fn deinit(self: *Text) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }

    pub fn build(self: *Text, max_size: MaybeSize) !void {
        self.clear();
        const width = try std.unicode.utf8CountCodepoints(self.content);
        var grid = try grd.Grid.init(self.allocator, .{ .width = @max(1, @min(width, max_size.width orelse width)), .height = 1 });
        errdefer grid.deinit();
        var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
        var i: u32 = 0;
        while (utf8.nextCodepointSlice()) |char| {
            if (i == grid.size.width) {
                break;
            }
            grid.cells.items[try grid.cells.at(.{ 0, i })].rune = char;
            i += 1;
        }
        self.grid = grid;
    }

    pub fn input(self: *Text, key: inp.Key) !void {
        _ = self;
        _ = key;
    }

    pub fn clear(self: *Text) void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
    }
};

pub fn Box(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        allocator: std.mem.Allocator,
        children: std.ArrayList(Child),
        border_style: ?BorderStyle,
        direction: Direction,

        pub const Child = struct {
            any: Any(Widget),
            rect: ?layout.Rect,
            visibility: ?struct {
                min_size: MaybeSize,
                priority: isize,
            },
        };

        pub const BorderStyle = enum {
            hidden,
            single,
            double,
        };

        pub const Direction = enum {
            vert,
            horiz,
        };

        pub fn init(allocator: std.mem.Allocator, border_style: ?BorderStyle, direction: Direction) !Box(Widget) {
            return .{
                .grid = null,
                .allocator = allocator,
                .children = std.ArrayList(Child).init(allocator),
                .border_style = border_style,
                .direction = direction,
            };
        }

        pub fn deinit(self: *Box(Widget)) void {
            for (self.children.items) |*child| {
                child.any.deinit();
            }
            self.children.deinit();
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn build(self: *Box(Widget), max_size: MaybeSize) !void {
            self.clear();

            const border_size: usize = if (self.border_style) |_| 1 else 0;
            if (max_size.width) |max_width| {
                if (max_width <= border_size * 2) return;
            }
            if (max_size.height) |max_height| {
                if (max_height <= border_size * 2) return;
            }

            var sorted_children = std.AutoArrayHashMap(usize, Child).init(self.allocator);
            defer sorted_children.deinit();
            for (self.children.items, 0..) |child, i| {
                try sorted_children.put(i, child);
            }
            const SortCtx = struct {
                values: []Child,
                pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                    const a = &ctx.values[a_index];
                    const b = &ctx.values[b_index];
                    if (a.visibility) |a_vis| {
                        if (b.visibility) |b_vis| {
                            return a_vis.priority > b_vis.priority;
                        }
                    }
                    return false;
                }
            };
            sorted_children.sort(SortCtx{ .values = sorted_children.values() });

            var width: usize = 0;
            var height: usize = 0;
            var remaining_width_maybe = if (max_size.width) |max_width| max_width - (border_size * 2) else null;
            var remaining_height_maybe = if (max_size.height) |max_height| max_height - (border_size * 2) else null;

            for (sorted_children.keys(), 0..) |child_index, sorted_child_index| {
                var child = &self.children.items[child_index];
                child.any.clear();

                if (remaining_width_maybe) |remaining_width| {
                    if (remaining_width <= 0) continue;
                    if (child.visibility) |vis| {
                        if (vis.min_size.width) |min_width| {
                            if (remaining_width < min_width) continue;
                        }
                    }
                }
                if (remaining_height_maybe) |remaining_height| {
                    if (remaining_height <= 0) continue;
                    if (child.visibility) |vis| {
                        if (vis.min_size.height) |min_height| {
                            if (remaining_height < min_height) continue;
                        }
                    }
                }

                // make room for the next children if they have min sizes
                var expected_remaining_width_maybe = remaining_width_maybe;
                var expected_remaining_height_maybe = remaining_height_maybe;
                if (child.visibility) |vis| {
                    if (expected_remaining_width_maybe) |*expected_remaining_width| {
                        if (vis.min_size.width) |min_width| {
                            for (sorted_child_index + 1..sorted_children.count()) |next_sorted_child_index| {
                                const next_child_index = sorted_children.keys()[next_sorted_child_index];
                                const next_child = &self.children.items[next_child_index];
                                if (next_child.visibility) |next_vis| {
                                    if (next_vis.min_size.width) |next_min_width| {
                                        if (expected_remaining_width.* >= min_width + next_min_width) {
                                            expected_remaining_width.* -= next_min_width;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (expected_remaining_height_maybe) |*expected_remaining_height| {
                        if (vis.min_size.height) |min_height| {
                            for (sorted_child_index + 1..sorted_children.count()) |next_sorted_child_index| {
                                const next_child_index = sorted_children.keys()[next_sorted_child_index];
                                const next_child = &self.children.items[next_child_index];
                                if (next_child.visibility) |next_vis| {
                                    if (next_vis.min_size.height) |next_min_height| {
                                        if (expected_remaining_height.* >= min_height + next_min_height) {
                                            expected_remaining_height.* -= next_min_height;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                try child.any.build(.{ .width = expected_remaining_width_maybe, .height = expected_remaining_height_maybe });

                if (child.any.grid()) |child_grid| {
                    switch (self.direction) {
                        .vert => {
                            if (remaining_height_maybe) |*remaining_height| remaining_height.* -|= child_grid.size.height;
                            width = @max(width, child_grid.size.width);
                            height += child_grid.size.height;
                        },
                        .horiz => {
                            if (remaining_width_maybe) |*remaining_width| remaining_width.* -|= child_grid.size.width;
                            width += child_grid.size.width;
                            height = @max(height, child_grid.size.height);
                        },
                    }
                }
            }

            width += border_size * 2;
            height += border_size * 2;

            var grid = try grd.Grid.init(self.allocator, .{ .width = width, .height = height });
            errdefer grid.deinit();

            switch (self.direction) {
                .vert => {
                    var line: usize = 0;
                    for (self.children.items) |*child| {
                        if (child.any.grid()) |child_grid| {
                            child.rect = .{ .x = 0, .y = @as(isize, @intCast(line + border_size)), .size = child_grid.size };
                            for (0..child_grid.size.height) |y| {
                                for (0..child_grid.size.width) |x| {
                                    const rune = child_grid.cells.items[try child_grid.cells.at(.{ y, x })].rune;
                                    if (grid.cells.at(.{ line + border_size, x + border_size })) |index| {
                                        grid.cells.items[index].rune = rune;
                                    } else |_| {
                                        break;
                                    }
                                }
                                line += 1;
                            }
                        }
                    }
                },
                .horiz => {
                    var col: usize = 0;
                    for (self.children.items) |*child| {
                        if (child.any.grid()) |child_grid| {
                            child.rect = .{ .x = @as(isize, @intCast(col + border_size)), .y = 0, .size = child_grid.size };
                            for (0..child_grid.size.width) |x| {
                                for (0..child_grid.size.height) |y| {
                                    const rune = child_grid.cells.items[try child_grid.cells.at(.{ y, x })].rune;
                                    if (grid.cells.at(.{ y + border_size, col + border_size })) |index| {
                                        grid.cells.items[index].rune = rune;
                                    } else |_| {
                                        break;
                                    }
                                }
                                col += 1;
                            }
                        }
                    }
                },
            }

            // border style
            if (self.border_style) |border_style| {
                const horiz_line = switch (border_style) {
                    .hidden => " ",
                    .single => "─",
                    .double => "═",
                };
                const vert_line = switch (border_style) {
                    .hidden => " ",
                    .single => "│",
                    .double => "║",
                };
                const top_left_corner = switch (border_style) {
                    .hidden => " ",
                    .single => "┌",
                    .double => "╔",
                };
                const top_right_corner = switch (border_style) {
                    .hidden => " ",
                    .single => "┐",
                    .double => "╗",
                };
                const bottom_left_corner = switch (border_style) {
                    .hidden => " ",
                    .single => "└",
                    .double => "╚",
                };
                const bottom_right_corner = switch (border_style) {
                    .hidden => " ",
                    .single => "┘",
                    .double => "╝",
                };
                // top and bottom border
                for (1..grid.size.width - 1) |x| {
                    grid.cells.items[try grid.cells.at(.{ 0, x })].rune = horiz_line;
                    grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, x })].rune = horiz_line;
                }
                // left and right border
                for (1..grid.size.height - 1) |y| {
                    grid.cells.items[try grid.cells.at(.{ y, 0 })].rune = vert_line;
                    grid.cells.items[try grid.cells.at(.{ y, grid.size.width - 1 })].rune = vert_line;
                }
                // corners
                grid.cells.items[try grid.cells.at(.{ 0, 0 })].rune = top_left_corner;
                grid.cells.items[try grid.cells.at(.{ 0, grid.size.width - 1 })].rune = top_right_corner;
                grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, 0 })].rune = bottom_left_corner;
                grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, grid.size.width - 1 })].rune = bottom_right_corner;
            }

            // set grid
            self.grid = grid;
        }

        pub fn input(self: *Box(Widget), key: inp.Key) !void {
            for (self.children.items) |*child| {
                try child.any.input(key);
            }
        }

        pub fn clear(self: *Box(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }
    };
}

pub fn TextBox(comptime Widget: type) type {
    return struct {
        allocator: std.mem.Allocator,
        grid: ?grd.Grid,
        box: Box(Widget),
        border_style: ?Box(Widget).BorderStyle,
        lines: std.ArrayList(std.ArrayList(u8)),

        pub fn init(allocator: std.mem.Allocator, content: []const u8, border_style: ?Box(Widget).BorderStyle) !TextBox(Widget) {
            var lines = std.ArrayList(std.ArrayList(u8)).init(allocator);
            errdefer {
                for (lines.items) |*line| {
                    line.deinit();
                }
                lines.deinit();
            }
            var fbs = std.io.fixedBufferStream(content);
            var reader = fbs.reader();
            while (true) {
                var line = std.ArrayList(u8).init(allocator);
                errdefer line.deinit();
                if (reader.streamUntilDelimiter(line.writer(), '\n', null)) {
                    try lines.append(line);
                } else |err| {
                    if (err == error.EndOfStream) {
                        try lines.append(line);
                        break;
                    } else {
                        return err;
                    }
                }
            }

            var box = try Box(Widget).init(allocator, border_style, .vert);
            errdefer box.deinit();
            for (lines.items) |line| {
                var text = Text.init(allocator, line.items);
                errdefer text.deinit();
                try box.children.append(.{ .any = Any(Widget).init(.{ .text = text }), .rect = null, .visibility = null });
            }

            return .{
                .allocator = allocator,
                .grid = null,
                .box = box,
                .border_style = border_style,
                .lines = lines,
            };
        }

        pub fn deinit(self: *TextBox(Widget)) void {
            self.box.deinit();
            for (self.lines.items) |*line| {
                line.deinit();
            }
            self.lines.deinit();
        }

        pub fn build(self: *TextBox(Widget), max_size: MaybeSize) !void {
            self.clear();
            self.box.border_style = self.border_style;
            try self.box.build(max_size);
            self.grid = self.box.grid;
        }

        pub fn input(self: *TextBox(Widget), key: inp.Key) !void {
            try self.box.input(key);
        }

        pub fn clear(self: *TextBox(Widget)) void {
            self.grid = null;
        }
    };
}

pub fn Scroll(comptime Widget: type) type {
    return struct {
        allocator: std.mem.Allocator,
        grid: ?grd.Grid,
        child: *Any(Widget),
        x: isize,
        y: isize,
        direction: Direction,

        pub const Direction = enum {
            vert,
            horiz,
            both,
        };

        pub fn init(allocator: std.mem.Allocator, widget: Any(Widget), direction: Direction) !Scroll(Widget) {
            var child = try allocator.create(Any(Widget));
            errdefer allocator.destroy(child);
            child.* = widget;
            return .{
                .allocator = allocator,
                .grid = null,
                .child = child,
                .x = 0,
                .y = 0,
                .direction = direction,
            };
        }

        pub fn deinit(self: *Scroll(Widget)) void {
            self.child.deinit();
            self.allocator.destroy(self.child);
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn build(self: *Scroll(Widget), max_size: MaybeSize) !void {
            self.clear();
            const child_max_size: MaybeSize = switch (self.direction) {
                .vert => .{ .width = max_size.width, .height = null },
                .horiz => .{ .width = null, .height = max_size.height },
                .both => .{ .width = null, .height = null },
            };
            try self.child.build(child_max_size);
            if (self.child.grid()) |child_grid| {
                self.grid = try grd.Grid.initFromGrid(self.allocator, child_grid, .{
                    .width = @max(1, @min(child_grid.size.width, max_size.width orelse child_grid.size.width)),
                    .height = @max(1, @min(child_grid.size.height, max_size.height orelse child_grid.size.height)),
                }, self.x, self.y);
            }
        }

        pub fn input(self: *Scroll(Widget), key: inp.Key) !void {
            try self.child.input(key);
        }

        pub fn clear(self: *Scroll(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn scrollToRect(self: *Scroll(Widget), rect: layout.Rect) void {
            if (self.grid) |grid| {
                if (self.direction == .horiz or self.direction == .both) {
                    if (rect.x < self.x) {
                        self.x -= self.x - rect.x;
                    } else {
                        const rect_x = rect.x + @as(isize, @intCast(rect.size.width));
                        const self_x = self.x + @as(isize, @intCast(grid.size.width));
                        self.x += if (rect_x > self_x)
                            rect_x - self_x
                        else
                            0;
                    }
                }
                if (self.direction == .vert or self.direction == .both) {
                    if (rect.y < self.y) {
                        self.y -= self.y - rect.y;
                    } else {
                        const rect_y = rect.y + @as(isize, @intCast(rect.size.height));
                        const self_y = self.y + @as(isize, @intCast(grid.size.height));
                        self.y += if (rect_y > self_y)
                            rect_y - self_y
                        else
                            0;
                    }
                }
            }
        }
    };
}
