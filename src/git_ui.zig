const std = @import("std");
const wgt = @import("./widget.zig");
const Grid = @import("./grid.zig").Grid;
const Focus = @import("./focus.zig").Focus;
const layout = @import("./layout.zig");
const inp = @import("./input.zig");
const g_stat = @import("./git_status.zig");
const g_log = @import("./git_log.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn GitUITabs(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),

        const FocusKind = enum { log, status };

        pub fn init(allocator: std.mem.Allocator) !GitUITabs(Widget) {
            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();

            inline for (@typeInfo(FocusKind).Enum.fields) |focus_kind_field| {
                const focus_kind: FocusKind = @enumFromInt(focus_kind_field.value);
                const name = switch (focus_kind) {
                    .log => "log",
                    .status => "status",
                };
                var text_box = try wgt.TextBox(Widget).init(allocator, name, .single);
                errdefer text_box.deinit();
                text_box.getFocus().focusable = true;
                try box.children.put(text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
            }

            var git_ui_tabs = GitUITabs(Widget){
                .box = box,
            };
            git_ui_tabs.getFocus().child_id = box.children.keys()[0];
            return git_ui_tabs;
        }

        pub fn deinit(self: *GitUITabs(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitUITabs(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            for (self.box.children.keys(), self.box.children.values()) |id, *tab| {
                tab.widget.text_box.border_style = if (self.getFocus().child_id == id)
                    (if (root_focus.grandchild_id == id) .double else .single)
                else
                    .hidden;
            }
            try self.box.build(constraint, root_focus);
        }

        pub fn input(self: *GitUITabs(Widget), key: inp.Key, root_focus: *Focus) !void {
            if (self.getFocus().child_id) |child_id| {
                const children = &self.box.children;
                if (children.getIndex(child_id)) |current_index| {
                    var index = current_index;

                    switch (key) {
                        .arrow_left => {
                            index -|= 1;
                        },
                        .arrow_right => {
                            if (index + 1 < self.box.children.count()) {
                                index += 1;
                            }
                        },
                        else => {},
                    }

                    if (index != current_index) {
                        try root_focus.setFocus(children.keys()[index]);
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitUITabs(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitUITabs(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitUITabs(Widget)) *Focus {
            return self.box.getFocus();
        }

        pub fn getSelectedIndex(self: GitUITabs(Widget)) ?usize {
            if (self.box.focus.child_id) |child_id| {
                const children = &self.box.children;
                return children.getIndex(child_id);
            } else {
                return null;
            }
        }
    };
}

pub fn GitUIStack(comptime Widget: type) type {
    return struct {
        focus: Focus,
        children: std.AutoArrayHashMap(usize, Widget),

        pub fn init(allocator: std.mem.Allocator) GitUIStack(Widget) {
            return .{
                .focus = Focus.init(allocator),
                .children = std.AutoArrayHashMap(usize, Widget).init(allocator),
            };
        }

        pub fn deinit(self: *GitUIStack(Widget)) void {
            self.focus.deinit();
            for (self.children.values()) |*child| {
                child.deinit();
            }
            self.children.deinit();
        }

        pub fn build(self: *GitUIStack(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            self.getFocus().clear();
            if (self.getSelected()) |selected_widget| {
                try selected_widget.build(constraint, root_focus);
                if (selected_widget.getGrid()) |child_grid| {
                    try self.getFocus().addChild(selected_widget.getFocus(), child_grid.size, 0, 0);
                }
            }
        }

        pub fn input(self: *GitUIStack(Widget), key: inp.Key, root_focus: *Focus) !void {
            if (self.getSelected()) |selected_widget| {
                try selected_widget.input(key, root_focus);
            }
        }

        pub fn clearGrid(self: *GitUIStack(Widget)) void {
            if (self.getSelected()) |selected_widget| {
                selected_widget.clearGrid();
            }
        }

        pub fn getGrid(self: GitUIStack(Widget)) ?Grid {
            if (self.getSelected()) |selected_widget| {
                return selected_widget.getGrid();
            } else {
                return null;
            }
        }

        pub fn getFocus(self: *GitUIStack(Widget)) *Focus {
            return &self.focus;
        }

        pub fn getSelected(self: GitUIStack(Widget)) ?*Widget {
            if (self.focus.child_id) |child_id| {
                if (self.children.getIndex(child_id)) |current_index| {
                    return &self.children.values()[current_index];
                }
            }
            return null;
        }
    };
}

pub fn GitUI(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),

        const FocusKind = enum { tabs, stack };

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitUI(Widget) {
            var box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer box.deinit();

            inline for (@typeInfo(FocusKind).Enum.fields) |focus_kind_field| {
                const focus_kind: FocusKind = @enumFromInt(focus_kind_field.value);
                switch (focus_kind) {
                    .tabs => {
                        var git_ui_tabs = try GitUITabs(Widget).init(allocator);
                        errdefer git_ui_tabs.deinit();
                        try box.children.put(git_ui_tabs.getFocus().id, .{ .widget = .{ .git_ui_tabs = git_ui_tabs }, .rect = null, .min_size = null });
                    },
                    .stack => {
                        var stack = GitUIStack(Widget).init(allocator);
                        errdefer stack.deinit();

                        {
                            var git_log = try g_log.GitLog(Widget).init(allocator, repo);
                            errdefer git_log.deinit();
                            try stack.children.put(git_log.getFocus().id, .{ .git_log = git_log });
                        }

                        {
                            var git_status = try g_stat.GitStatus(Widget).init(allocator, repo);
                            errdefer git_status.deinit();
                            try stack.children.put(git_status.getFocus().id, .{ .git_status = git_status });
                        }

                        try box.children.put(stack.getFocus().id, .{ .widget = .{ .git_ui_stack = stack }, .rect = null, .min_size = null });
                    },
                }
            }

            var git_ui = GitUI(Widget){
                .box = box,
            };
            git_ui.getFocus().child_id = box.children.keys()[0];
            return git_ui;
        }

        pub fn deinit(self: *GitUI(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitUI(Widget), constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            const git_ui_tabs = &self.box.children.values()[@intFromEnum(FocusKind.tabs)].widget.git_ui_tabs;
            const git_ui_stack = &self.box.children.values()[@intFromEnum(FocusKind.stack)].widget.git_ui_stack;
            if (git_ui_tabs.getSelectedIndex()) |index| {
                git_ui_stack.getFocus().child_id = git_ui_stack.children.keys()[index];
            }
            try self.box.build(constraint, root_focus);
        }

        pub fn input(self: *GitUI(Widget), key: inp.Key, root_focus: *Focus) !void {
            if (self.getFocus().child_id) |child_id| {
                if (self.box.children.getIndex(child_id)) |current_index| {
                    const child = &self.box.children.values()[current_index].widget;
                    var index = current_index;

                    switch (key) {
                        .arrow_up => {
                            switch (child.*) {
                                .git_ui_tabs => {
                                    try child.input(key, root_focus);
                                },
                                .git_ui_stack => {
                                    if (child.git_ui_stack.getSelected()) |selected_widget| {
                                        switch (selected_widget.*) {
                                            .git_log => {
                                                if (selected_widget.git_log.scrolledToTop()) {
                                                    index = @intFromEnum(FocusKind.tabs);
                                                } else {
                                                    try child.input(key, root_focus);
                                                }
                                            },
                                            .git_status => {
                                                if (selected_widget.git_status.getSelectedIndex() == 0) {
                                                    index = @intFromEnum(FocusKind.tabs);
                                                } else {
                                                    try child.input(key, root_focus);
                                                }
                                            },
                                            else => {},
                                        }
                                    }
                                },
                                else => {},
                            }
                        },
                        .arrow_down => {
                            switch (child.*) {
                                .git_ui_tabs => {
                                    index = @intFromEnum(FocusKind.stack);
                                },
                                .git_ui_stack => {
                                    try child.input(key, root_focus);
                                },
                                else => {},
                            }
                        },
                        else => {
                            try child.input(key, root_focus);
                        },
                    }

                    if (index != current_index) {
                        try root_focus.setFocus(self.box.children.keys()[index]);
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitUI(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitUI(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitUI(Widget)) *Focus {
            return self.box.getFocus();
        }
    };
}
