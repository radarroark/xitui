const std = @import("std");
const wgt = @import("./widget.zig");
const grd = @import("./grid.zig");
const layout = @import("./layout.zig");
const inp = @import("./input.zig");
const g_stat = @import("./git_status.zig");
const g_log = @import("./git_log.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn GitUITabs(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        selected: usize,
        focused: bool,

        pub fn init(allocator: std.mem.Allocator) !GitUITabs(Widget) {
            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();

            {
                var text_box = try wgt.TextBox(Widget).init(allocator, "log", .single);
                errdefer text_box.deinit();
                try box.children.append(.{ .widget = .{ .text_box = text_box }, .rect = null, .visibility = null });
            }

            {
                var text_box = try wgt.TextBox(Widget).init(allocator, "status", .hidden);
                errdefer text_box.deinit();
                try box.children.append(.{ .widget = .{ .text_box = text_box }, .rect = null, .visibility = null });
            }

            return .{
                .grid = null,
                .box = box,
                .selected = 0,
                .focused = false,
            };
        }

        pub fn deinit(self: *GitUITabs(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitUITabs(Widget), constraint: layout.Constraint) !void {
            self.clear();
            for (self.box.children.items, 0..) |*tab, i| {
                tab.widget.text_box.border_style = if (self.selected == i)
                    (if (self.focused) .double else .single)
                else
                    .hidden;
            }
            try self.box.build(constraint);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitUITabs(Widget), key: inp.Key) !void {
            switch (key) {
                .arrow_left => {
                    self.selected -|= 1;
                },
                .arrow_right => {
                    if (self.selected + 1 < self.box.children.items.len) {
                        self.selected += 1;
                    }
                },
                else => {},
            }
        }

        pub fn clear(self: *GitUITabs(Widget)) void {
            self.grid = null;
        }
    };
}

pub fn GitUIStack(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        children: std.ArrayList(Widget),
        selected: usize,
        focused: bool,

        pub fn init(allocator: std.mem.Allocator) GitUIStack(Widget) {
            return .{
                .grid = null,
                .children = std.ArrayList(Widget).init(allocator),
                .selected = 0,
                .focused = false,
            };
        }

        pub fn deinit(self: *GitUIStack(Widget)) void {
            for (self.children.items) |*child| {
                child.deinit();
            }
            self.children.deinit();
        }

        pub fn build(self: *GitUIStack(Widget), constraint: layout.Constraint) !void {
            self.clear();
            for (self.children.items, 0..) |*child, i| {
                switch (child.*) {
                    inline else => |*case| {
                        if (@hasField(@TypeOf(case.*), "focused")) {
                            case.focused = self.focused and i == self.selected;
                        }
                    },
                }
            }
            var widget = &self.children.items[self.selected];
            try widget.build(constraint);
            self.grid = widget.grid();
        }

        pub fn input(self: *GitUIStack(Widget), key: inp.Key) !void {
            try self.children.items[self.selected].input(key);
        }

        pub fn clear(self: *GitUIStack(Widget)) void {
            self.grid = null;
        }

        pub fn getSelected(self: GitUIStack(Widget)) *Widget {
            return &self.children.items[self.selected];
        }
    };
}

pub fn GitUI(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        selected: union(enum) { tabs, stack },

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitUI(Widget) {
            var box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer box.deinit();

            {
                var git_ui_tabs = try GitUITabs(Widget).init(allocator);
                errdefer git_ui_tabs.deinit();
                try box.children.append(.{ .widget = .{ .git_ui_tabs = git_ui_tabs }, .rect = null, .visibility = null });
            }

            {
                var stack = GitUIStack(Widget).init(allocator);
                errdefer stack.deinit();

                {
                    var git_log = try g_log.GitLog(Widget).init(allocator, repo);
                    errdefer git_log.deinit();
                    git_log.focused = true;
                    try stack.children.append(.{ .git_log = git_log });
                }

                {
                    var git_status = try g_stat.GitStatus(Widget).init(allocator, repo);
                    errdefer git_status.deinit();
                    git_status.focused = false;
                    try stack.children.append(.{ .git_status = git_status });
                }

                try box.children.append(.{ .widget = .{ .git_ui_stack = stack }, .rect = null, .visibility = null });
            }

            return .{
                .grid = null,
                .box = box,
                .selected = .stack,
            };
        }

        pub fn deinit(self: *GitUI(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitUI(Widget), constraint: layout.Constraint) !void {
            self.clear();
            var git_ui_tabs = &self.box.children.items[0].widget.git_ui_tabs;
            git_ui_tabs.focused = self.selected == .tabs;
            var git_ui_stack = &self.box.children.items[1].widget.git_ui_stack;
            git_ui_stack.focused = self.selected == .stack;
            git_ui_stack.selected = git_ui_tabs.selected;
            try self.box.build(constraint);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitUI(Widget), key: inp.Key) !void {
            switch (key) {
                .arrow_up => {
                    switch (self.selected) {
                        .tabs => {
                            try self.box.children.items[0].widget.input(key);
                        },
                        .stack => {
                            var selected_widget = self.box.children.items[1].widget.git_ui_stack.getSelected();
                            switch (selected_widget.*) {
                                .git_log => {
                                    if (selected_widget.git_log.scrolledToTop()) {
                                        self.selected = .tabs;
                                    } else {
                                        try self.box.children.items[1].widget.input(key);
                                    }
                                },
                                .git_status => {
                                    if (selected_widget.git_status.selected == .status_tabs) {
                                        self.selected = .tabs;
                                    } else {
                                        try self.box.children.items[1].widget.input(key);
                                    }
                                },
                                else => {},
                            }
                        },
                    }
                },
                .arrow_down => {
                    switch (self.selected) {
                        .tabs => {
                            self.selected = .stack;
                        },
                        .stack => {
                            try self.box.children.items[1].widget.input(key);
                        },
                    }
                },
                else => {
                    switch (self.selected) {
                        .tabs => {
                            try self.box.children.items[0].widget.input(key);
                        },
                        .stack => {
                            try self.box.children.items[1].widget.input(key);
                        },
                    }
                },
            }
        }

        pub fn clear(self: *GitUI(Widget)) void {
            self.grid = null;
        }
    };
}
