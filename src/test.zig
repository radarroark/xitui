const std = @import("std");
const xitui = @import("xitui");
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    scroll: wgt.Scroll(Widget),

    pub fn deinit(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }

    pub fn build(self: *Widget, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, key: inp.Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(key, root_focus),
        }
    }

    pub fn clearGrid(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.clearGrid(),
        }
    }

    pub fn getGrid(self: Widget) ?Grid {
        switch (self) {
            inline else => |*case| return case.getGrid(),
        }
    }

    pub fn getFocus(self: *Widget) *Focus {
        switch (self.*) {
            inline else => |*case| return case.getFocus(),
        }
    }
};

test "text box" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox(Widget).init(allocator, "Hello, world!", .single, .none) };
    defer widget.deinit();

    try widget.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings(
        \\┌─────────────┐
        \\│Hello, world!│
        \\└─────────────┘
    , str);
}

test "text box with wrapping" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox(Widget).init(allocator, "Hello, world!\nGoodbye, world!", .single, .char) };
    defer widget.deinit();

    try widget.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 10, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\┌────────┐
            \\│Hello, w│
            \\│orld!   │
            \\│Goodbye,│
            \\│ world! │
            \\└────────┘
        , str);
    }

    try widget.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 12, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\┌──────────┐
            \\│Hello, wor│
            \\│ld!       │
            \\│Goodbye, w│
            \\│orld!     │
            \\└──────────┘
        , str);
    }

    try widget.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 12, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\┌──────────┐
            \\│Hello, wor│
            \\│ld!       │
            \\│Goodbye, w│
            \\│orld!     │
            \\└──────────┘
        , str);
    }
}
