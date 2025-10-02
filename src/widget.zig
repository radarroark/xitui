const std = @import("std");
const Grid = @import("./grid.zig").Grid;
const Focus = @import("./focus.zig").Focus;
const layout = @import("./layout.zig");
const inp = @import("./input.zig");

pub fn Text(comptime Widget: type) type {
    return struct {
        allocator: std.mem.Allocator,
        focus: Focus,
        grid: ?Grid,
        content: []const u8,

        pub fn init(allocator: std.mem.Allocator, content: []const u8) Text(Widget) {
            return .{
                .allocator = allocator,
                .focus = Focus.init(allocator),
                .grid = null,
                .content = content,
            };
        }

        pub fn deinit(self: *Text(Widget)) void {
            self.focus.deinit();
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn build(self: *Text(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            _ = root_focus;
            self.clearGrid();
            const width = try std.unicode.utf8CountCodepoints(self.content);
            var grid = try Grid.init(self.allocator, .{ .width = @max(1, @min(width, constraint.max_size.width orelse width)), .height = 1 });
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

        pub fn input(self: *Text(Widget), key: inp.Key, root_focus: *Focus) !void {
            _ = self;
            _ = key;
            _ = root_focus;
        }

        pub fn clearGrid(self: *Text(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn getGrid(self: Text(Widget)) ?Grid {
            return self.grid;
        }

        pub fn getFocus(self: *Text(Widget)) *Focus {
            return &self.focus;
        }
    };
}

pub const BorderStyle = enum {
    hidden,
    single,
    double,
    single_dashed,
    double_dashed,
};

pub fn Box(comptime Widget: type) type {
    return struct {
        focus: Focus,
        grid: ?Grid,
        allocator: std.mem.Allocator,
        children: std.AutoArrayHashMap(usize, Child),
        border_style: ?BorderStyle,
        direction: Direction,

        pub const Child = struct {
            widget: Widget,
            rect: ?layout.IRect,
            min_size: ?layout.MaybeSize,
        };

        pub const Direction = enum {
            vert,
            horiz,
        };

        pub fn init(allocator: std.mem.Allocator, border_style: ?BorderStyle, direction: Direction) !Box(Widget) {
            return .{
                .focus = Focus.init(allocator),
                .grid = null,
                .allocator = allocator,
                .children = std.AutoArrayHashMap(usize, Child).init(allocator),
                .border_style = border_style,
                .direction = direction,
            };
        }

        pub fn deinit(self: *Box(Widget)) void {
            self.focus.deinit();
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            for (self.children.values()) |*child| {
                child.widget.deinit();
            }
            self.children.deinit();
        }

        pub fn build(self: *Box(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();

            const border_size: usize = if (self.border_style) |_| 1 else 0;
            if (constraint.max_size.width) |max_width| {
                if (max_width <= border_size * 2) return;
            }
            if (constraint.max_size.height) |max_height| {
                if (max_height <= border_size * 2) return;
            }

            var sorted_children = std.AutoArrayHashMap(usize, void).init(self.allocator);
            defer sorted_children.deinit();
            var should_sort = false;
            for (self.children.values(), 0..) |child, i| {
                try sorted_children.put(i, {});
                if (child.min_size != null) {
                    should_sort = true;
                }
            }
            if (should_sort) {
                const SortCtx = struct {
                    selected_index: usize,

                    pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                        const ia: isize = @intCast(a_index);
                        const ib: isize = @intCast(b_index);
                        const a_priority = if (ia <= ctx.selected_index) ia else -ia;
                        const b_priority = if (ib <= ctx.selected_index) ib else -ib;
                        return a_priority > b_priority;
                    }
                };
                if (self.getFocus().child_id) |child_id| {
                    if (self.children.getIndex(child_id)) |index| {
                        sorted_children.sort(SortCtx{ .selected_index = index });
                    }
                }
            }

            var width: usize = 0;
            var height: usize = 0;
            var remaining_width_maybe = if (constraint.max_size.width) |max_width| max_width - (border_size * 2) else null;
            var remaining_height_maybe = if (constraint.max_size.height) |max_height| max_height - (border_size * 2) else null;

            for (sorted_children.keys(), 0..) |child_index, sorted_child_index| {
                var child = &self.children.values()[child_index];
                child.widget.clearGrid();

                // skip any children after the first if their min size is too large
                if (sorted_child_index > 0) {
                    if (remaining_width_maybe) |remaining_width| {
                        if (remaining_width <= 0) continue;
                        if (child.min_size) |min_size| {
                            if (min_size.width) |min_width| {
                                if (remaining_width < min_width) continue;
                            }
                        }
                    }
                    if (remaining_height_maybe) |remaining_height| {
                        if (remaining_height <= 0) continue;
                        if (child.min_size) |min_size| {
                            if (min_size.height) |min_height| {
                                if (remaining_height < min_height) continue;
                            }
                        }
                    }
                }

                // make room for the next children if they have min sizes
                var expected_remaining_width_maybe = remaining_width_maybe;
                var expected_remaining_height_maybe = remaining_height_maybe;
                var child_min_size: layout.MaybeSize = .{ .width = null, .height = null };
                if (child.min_size) |min_size| {
                    child_min_size = min_size;
                    if (expected_remaining_width_maybe) |*expected_remaining_width| {
                        if (min_size.width) |min_width| {
                            for (sorted_child_index + 1..sorted_children.count()) |next_sorted_child_index| {
                                const next_child_index = sorted_children.keys()[next_sorted_child_index];
                                const next_child = &self.children.values()[next_child_index];
                                if (next_child.min_size) |next_min_size| {
                                    if (next_min_size.width) |next_min_width| {
                                        if (expected_remaining_width.* >= min_width + next_min_width) {
                                            expected_remaining_width.* -= next_min_width;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (expected_remaining_height_maybe) |*expected_remaining_height| {
                        if (min_size.height) |min_height| {
                            for (sorted_child_index + 1..sorted_children.count()) |next_sorted_child_index| {
                                const next_child_index = sorted_children.keys()[next_sorted_child_index];
                                const next_child = &self.children.values()[next_child_index];
                                if (next_child.min_size) |next_min_size| {
                                    if (next_min_size.height) |next_min_height| {
                                        if (expected_remaining_height.* >= min_height + next_min_height) {
                                            expected_remaining_height.* -= next_min_height;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                try child.widget.build(.{
                    .min_size = child_min_size,
                    .max_size = .{ .width = expected_remaining_width_maybe, .height = expected_remaining_height_maybe },
                }, root_focus);

                if (child.widget.getGrid()) |child_grid| {
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
            width = @max(width, constraint.min_size.width orelse width);
            height += border_size * 2;
            height = @max(height, constraint.min_size.height orelse height);

            var grid = try Grid.init(self.allocator, .{ .width = width, .height = height });
            errdefer grid.deinit();

            self.getFocus().clear();

            switch (self.direction) {
                .vert => {
                    var line: usize = 0;
                    for (self.children.values()) |*child| {
                        if (child.widget.getGrid()) |child_grid| {
                            child.rect = .{ .x = 0, .y = @as(isize, @intCast(line + border_size)), .size = child_grid.size };
                            try grid.drawGrid(child_grid, border_size, line + border_size);
                            try self.getFocus().addChild(child.widget.getFocus(), child_grid.size, border_size, line + border_size);
                            line += child_grid.size.height;
                        } else {
                            try self.getFocus().addChild(child.widget.getFocus(), .{ .width = 0, .height = 0 }, 0, 0);
                        }
                    }
                },
                .horiz => {
                    var col: usize = 0;
                    for (self.children.values()) |*child| {
                        if (child.widget.getGrid()) |child_grid| {
                            child.rect = .{ .x = @as(isize, @intCast(col + border_size)), .y = 0, .size = child_grid.size };
                            try grid.drawGrid(child_grid, col + border_size, border_size);
                            try self.getFocus().addChild(child.widget.getFocus(), child_grid.size, col + border_size, border_size);
                            col += child_grid.size.width;
                        } else {
                            try self.getFocus().addChild(child.widget.getFocus(), .{ .width = 0, .height = 0 }, 0, 0);
                        }
                    }
                },
            }

            // border style
            if (self.border_style) |border_style| {
                const horiz_line = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "─",
                    .double, .double_dashed => "═",
                };
                const vert_line = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "│",
                    .double, .double_dashed => "║",
                };
                const top_left_corner = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "┌",
                    .double, .double_dashed => "╔",
                };
                const top_right_corner = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "┐",
                    .double, .double_dashed => "╗",
                };
                const bottom_left_corner = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "└",
                    .double, .double_dashed => "╚",
                };
                const bottom_right_corner = switch (border_style) {
                    .hidden => " ",
                    .single, .single_dashed => "┘",
                    .double, .double_dashed => "╝",
                };
                // top and bottom border
                for (1..grid.size.width - 1) |x| {
                    if ((border_style == .single_dashed or border_style == .double_dashed) and x % 2 == 1) continue;
                    grid.cells.items[try grid.cells.at(.{ 0, x })].rune = horiz_line;
                    grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, x })].rune = horiz_line;
                }
                // left and right border
                for (1..grid.size.height - 1) |y| {
                    if ((border_style == .single_dashed or border_style == .double_dashed) and y % 2 == 1) continue;
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

        pub fn input(self: *Box(Widget), key: inp.Key, root_focus: *Focus) !void {
            for (self.children.values()) |*child| {
                try child.widget.input(key, root_focus);
            }
        }

        pub fn clearGrid(self: *Box(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn getGrid(self: Box(Widget)) ?Grid {
            return self.grid;
        }

        pub fn getFocus(self: *Box(Widget)) *Focus {
            return &self.focus;
        }
    };
}

pub const WrapKind = enum {
    none,
    char,
};

pub fn TextBox(comptime Widget: type) type {
    return struct {
        allocator: std.mem.Allocator,
        box: Box(Widget),
        border_style: ?BorderStyle,
        wrap_kind: WrapKind,
        last_wrap_width: ?usize,
        content: []const u8,
        lines: std.ArrayList([]const u8),

        pub fn init(
            allocator: std.mem.Allocator,
            content: []const u8,
            border_style: ?BorderStyle,
            wrap_kind: WrapKind,
        ) !TextBox(Widget) {
            var lines = std.ArrayList([]const u8){};
            errdefer {
                for (lines.items) |line| {
                    allocator.free(line);
                }
                lines.deinit(allocator);
            }

            {
                var line = std.ArrayList(u8){};
                errdefer line.deinit(allocator);

                var utf8 = (try std.unicode.Utf8View.init(content)).iterator();
                while (utf8.nextCodepointSlice()) |char| {
                    if (std.mem.eql(u8, char, "\n")) {
                        try lines.append(allocator, try line.toOwnedSlice(allocator));
                    } else {
                        try line.appendSlice(allocator, char);
                    }
                }
                try lines.append(allocator, try line.toOwnedSlice(allocator));
            }

            var box = try Box(Widget).init(allocator, border_style, .vert);
            errdefer box.deinit();
            for (lines.items) |line| {
                var text = Text(Widget).init(allocator, line);
                errdefer text.deinit();
                try box.children.put(text.getFocus().id, .{ .widget = .{ .text = text }, .rect = null, .min_size = null });
            }

            return .{
                .allocator = allocator,
                .box = box,
                .border_style = border_style,
                .wrap_kind = wrap_kind,
                .last_wrap_width = null,
                .content = content,
                .lines = lines,
            };
        }

        pub fn deinit(self: *TextBox(Widget)) void {
            self.box.deinit();
            for (self.lines.items) |line| {
                self.allocator.free(line);
            }
            self.lines.deinit(self.allocator);
        }

        pub fn build(self: *TextBox(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            if (.char == self.wrap_kind) {
                if (constraint.max_size.width) |max_width| {
                    const should_rewrap = if (self.last_wrap_width) |last_wrap_width| last_wrap_width != max_width else true;
                    self.last_wrap_width = max_width;

                    if (should_rewrap) {
                        const border_size: usize = if (self.border_style) |_| 1 else 0;

                        {
                            for (self.lines.items) |line| {
                                self.allocator.free(line);
                            }
                            self.lines.clearAndFree(self.allocator);

                            var line = std.ArrayList(u8){};
                            errdefer line.deinit(self.allocator);

                            var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
                            while (utf8.nextCodepointSlice()) |char| {
                                if (std.mem.eql(u8, char, "\n")) {
                                    try self.lines.append(self.allocator, try line.toOwnedSlice(self.allocator));
                                } else {
                                    try line.appendSlice(self.allocator, char);
                                }

                                if (std.mem.eql(u8, utf8.peek(1), "")) {
                                    try self.lines.append(self.allocator, try line.toOwnedSlice(self.allocator));
                                } else if (try std.unicode.utf8CountCodepoints(line.items) + (border_size * 2) == max_width) {
                                    try self.lines.append(self.allocator, try line.toOwnedSlice(self.allocator));
                                }
                            }
                        }

                        const box = try Box(Widget).init(self.allocator, self.border_style, .vert);
                        self.box.deinit();
                        self.box = box;
                        for (self.lines.items) |line| {
                            var text = Text(Widget).init(self.allocator, line);
                            errdefer text.deinit();
                            try self.box.children.put(text.getFocus().id, .{ .widget = .{ .text = text }, .rect = null, .min_size = null });
                        }
                    }
                }
            }

            self.clearGrid();
            self.box.border_style = self.border_style;
            try self.box.build(constraint, root_focus);
        }

        pub fn input(self: *TextBox(Widget), key: inp.Key, root_focus: *Focus) !void {
            switch (self.getFocus().focus_kind) {
                .none, .focusable => try self.box.input(key, root_focus),
                .editable => |*cursor| {
                    const border_size: usize = if (self.border_style) |_| 1 else 0;
                    const grid_size = (self.getGrid() orelse return error.GridNotFound).size;

                    switch (key) {
                        .arrow_right => if (cursor.x < grid_size.width - border_size - 1) {
                            cursor.x += 1;
                        } else if (cursor.y < grid_size.height - border_size - 1) {
                            cursor.x = border_size;
                            cursor.y += 1;
                        },
                        .arrow_left => if (cursor.x > border_size) {
                            cursor.x -= 1;
                        } else if (cursor.y > border_size) {
                            cursor.x = grid_size.width - border_size - 1;
                            cursor.y -= 1;
                        },
                        else => {},
                    }
                },
            }
        }

        pub fn clearGrid(self: *TextBox(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: TextBox(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *TextBox(Widget)) *Focus {
            return self.box.getFocus();
        }
    };
}

pub fn Scroll(comptime Widget: type) type {
    return struct {
        allocator: std.mem.Allocator,
        grid: ?Grid,
        child: *Widget,
        x: isize,
        y: isize,
        direction: Direction,

        pub const Direction = enum {
            vert,
            horiz,
            both,
        };

        pub fn init(allocator: std.mem.Allocator, widget: Widget, direction: Direction) !Scroll(Widget) {
            const child = try allocator.create(Widget);
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
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
            self.child.deinit();
            self.allocator.destroy(self.child);
        }

        pub fn build(self: *Scroll(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            const child_constraint: layout.Constraint = switch (self.direction) {
                .vert => .{
                    .min_size = constraint.min_size,
                    .max_size = .{ .width = constraint.max_size.width, .height = null },
                },
                .horiz => .{
                    .min_size = constraint.min_size,
                    .max_size = .{ .width = null, .height = constraint.max_size.height },
                },
                .both => .{
                    .min_size = constraint.min_size,
                    .max_size = .{ .width = null, .height = null },
                },
            };
            try self.child.build(child_constraint, root_focus);
            if (self.child.getGrid()) |child_grid| {
                self.grid = try Grid.initFromGrid(self.allocator, child_grid, .{
                    .width = @max(1, @min(child_grid.size.width, constraint.max_size.width orelse child_grid.size.width)),
                    .height = @max(1, @min(child_grid.size.height, constraint.max_size.height orelse child_grid.size.height)),
                }, self.x, self.y);
            }
        }

        pub fn input(self: *Scroll(Widget), key: inp.Key, root_focus: *Focus) !void {
            try self.child.input(key, root_focus);
        }

        pub fn clearGrid(self: *Scroll(Widget)) void {
            if (self.grid) |*grid| {
                grid.deinit();
                self.grid = null;
            }
        }

        pub fn getGrid(self: Scroll(Widget)) ?Grid {
            return self.grid;
        }

        pub fn scrollToRect(self: *Scroll(Widget), rect: layout.IRect) void {
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

        pub fn getFocus(self: *Scroll(Widget)) *Focus {
            return self.child.getFocus();
        }
    };
}

pub fn Stack(comptime Widget: type) type {
    return struct {
        focus: Focus,
        children: std.AutoArrayHashMap(usize, Widget),

        pub fn init(allocator: std.mem.Allocator) Stack(Widget) {
            return .{
                .focus = Focus.init(allocator),
                .children = std.AutoArrayHashMap(usize, Widget).init(allocator),
            };
        }

        pub fn deinit(self: *Stack(Widget)) void {
            self.focus.deinit();
            for (self.children.values()) |*child| {
                child.deinit();
            }
            self.children.deinit();
        }

        pub fn build(self: *Stack(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            self.getFocus().clear();
            if (self.getSelected()) |selected_widget| {
                try selected_widget.build(constraint, root_focus);
                if (selected_widget.getGrid()) |child_grid| {
                    try self.getFocus().addChild(selected_widget.getFocus(), child_grid.size, 0, 0);
                }
            }
        }

        pub fn input(self: *Stack(Widget), key: inp.Key, root_focus: *Focus) !void {
            if (self.getSelected()) |selected_widget| {
                try selected_widget.input(key, root_focus);
            }
        }

        pub fn clearGrid(self: *Stack(Widget)) void {
            if (self.getSelected()) |selected_widget| {
                selected_widget.clearGrid();
            }
        }

        pub fn getGrid(self: Stack(Widget)) ?Grid {
            if (self.getSelected()) |selected_widget| {
                return selected_widget.getGrid();
            } else {
                return null;
            }
        }

        pub fn getFocus(self: *Stack(Widget)) *Focus {
            return &self.focus;
        }

        pub fn getSelected(self: Stack(Widget)) ?*Widget {
            if (self.focus.child_id) |child_id| {
                if (self.children.getIndex(child_id)) |current_index| {
                    return &self.children.values()[current_index];
                }
            }
            return null;
        }
    };
}
