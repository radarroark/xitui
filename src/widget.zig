const std = @import("std");
const grd = @import("./grid.zig");
const size = @import("./size.zig");
const MaxSize = size.MaxSize;
const Rect = size.Rect;
const inp = @import("./input.zig");

pub fn Any(comptime Widget: type) type {
    return struct {
        widget: Widget,

        pub fn deinit(self: *Any(Widget)) void {
            switch (self.widget) {
                inline else => |*case| case.deinit(),
            }
        }

        pub fn build(self: *Any(Widget), max_size: MaxSize) anyerror!void {
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

    pub fn build(self: *Text, max_size: MaxSize) !void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        const width = try std.unicode.utf8CountCodepoints(self.content);
        var grid = try grd.Grid.init(self.allocator, .{ .width = std.math.clamp(width, 1, max_size.width orelse width), .height = 1 });
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
};

pub fn Box(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        allocator: std.mem.Allocator,
        children: std.ArrayList(Any(Widget)),
        child_rects: std.ArrayList(Rect),
        border_style: ?BorderStyle,
        direction: Direction,

        pub const BorderStyle = enum {
            hidden,
            single,
            double,
        };

        pub const Direction = enum {
            vert,
            horiz,
        };

        pub fn init(allocator: std.mem.Allocator, widgets: []Any(Widget), border_style: ?BorderStyle, direction: Direction) !Box(Widget) {
            var children = std.ArrayList(Any(Widget)).init(allocator);
            errdefer children.deinit();
            for (widgets) |widget| {
                try children.append(widget);
            }
            return .{
                .grid = null,
                .allocator = allocator,
                .children = children,
                .child_rects = std.ArrayList(Rect).init(allocator),
                .border_style = border_style,
                .direction = direction,
            };
        }

        pub fn deinit(self: *Box(Widget)) void {
            for (self.children.items) |*child| {
                child.deinit();
            }
            self.children.deinit();
            self.child_rects.deinit();
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn build(self: *Box(Widget), max_size: MaxSize) !void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            self.child_rects.clearAndFree();
            const border_size: usize = if (self.border_style) |_| 1 else 0;
            if (max_size.width) |max_width| {
                if (max_width <= border_size * 2) return;
            }
            if (max_size.height) |max_height| {
                if (max_height <= border_size * 2) return;
            }
            var width: usize = 0;
            var height: usize = 0;
            var remaining_width_maybe = if (max_size.width) |max_width| max_width - (border_size * 2) else null;
            var remaining_height_maybe = if (max_size.height) |max_height| max_height - (border_size * 2) else null;
            for (self.children.items) |*child| {
                if (remaining_width_maybe) |remaining_width| {
                    if (remaining_width <= 0) break;
                }
                if (remaining_height_maybe) |remaining_height| {
                    if (remaining_height <= 0) break;
                }
                try child.build(.{ .width = remaining_width_maybe, .height = remaining_height_maybe });
                if (child.grid()) |child_grid| {
                    switch (self.direction) {
                        .vert => {
                            if (remaining_height_maybe) |*remaining_height| remaining_height.* -= child_grid.size.height;
                            width = @max(width, child_grid.size.width);
                            height += child_grid.size.height;
                        },
                        .horiz => {
                            if (remaining_width_maybe) |*remaining_width| remaining_width.* -= child_grid.size.width;
                            width += child_grid.size.width;
                            height = @max(height, child_grid.size.height);
                        },
                    }
                } else {
                    break;
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
                        if (child.grid()) |child_grid| {
                            try self.child_rects.append(.{ .x = 0, .y = @as(isize, @intCast(line + border_size)), .size = child_grid.size });
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
                        if (child.grid()) |child_grid| {
                            try self.child_rects.append(.{ .x = @as(isize, @intCast(col + border_size)), .y = 0, .size = child_grid.size });
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
                try child.input(key);
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

            var widgets = std.ArrayList(Any(Widget)).init(allocator);
            defer widgets.deinit();
            for (lines.items) |line| {
                var text = Text.init(allocator, line.items);
                errdefer text.deinit();
                try widgets.append(Any(Widget){ .widget = .{ .text = text } });
            }

            var box = try Box(Widget).init(allocator, widgets.items, border_style, .vert);
            errdefer box.deinit();

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

        pub fn build(self: *TextBox(Widget), max_size: MaxSize) !void {
            self.grid = null;
            self.box.border_style = self.border_style;
            try self.box.build(max_size);
            self.grid = self.box.grid;
        }

        pub fn input(self: *TextBox(Widget), key: inp.Key) !void {
            try self.box.input(key);
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
            var ptr = try allocator.create(Any(Widget));
            ptr.* = widget;
            return .{
                .allocator = allocator,
                .grid = null,
                .child = ptr,
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

        pub fn build(self: *Scroll(Widget), max_size: MaxSize) !void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            const child_max_size: MaxSize = switch (self.direction) {
                .vert => .{ .width = max_size.width, .height = null },
                .horiz => .{ .width = null, .height = max_size.height },
                .both => .{ .width = null, .height = null },
            };
            try self.child.build(child_max_size);
            if (self.child.grid()) |child_grid| {
                self.grid = try grd.Grid.initFromGrid(self.allocator, child_grid, .{ .width = std.math.clamp(child_grid.size.width, 1, max_size.width orelse child_grid.size.width), .height = std.math.clamp(child_grid.size.height, 1, max_size.height orelse child_grid.size.height) }, self.x, self.y);
            }
        }

        pub fn input(self: *Scroll(Widget), key: inp.Key) !void {
            try self.child.input(key);
        }

        pub fn scrollToRect(self: *Scroll(Widget), rect: Rect) void {
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
