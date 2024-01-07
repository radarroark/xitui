const std = @import("std");
const wgt = @import("./widget.zig");
const Grid = @import("./grid.zig").Grid;
const Focus = @import("./focus.zig").Focus;
const layout = @import("./layout.zig");
const inp = @import("./input.zig");
const g_diff = @import("./git_diff.zig");
const g_ui = @import("./git_ui.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub const IndexKind = enum {
    added,
    not_added,
    not_tracked,
};

pub const StatusKind = union(IndexKind) {
    added: enum {
        created,
        modified,
        deleted,
    },
    not_added: enum {
        modified,
        deleted,
    },
    not_tracked,
};

pub const Status = struct {
    kind: StatusKind,
    path: []const u8,
};

pub fn GitStatusListItem(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),

        pub fn init(allocator: std.mem.Allocator, status: Status) !GitStatusListItem(Widget) {
            const status_kind_sym = switch (status.kind) {
                .added => switch (status.kind.added) {
                    .created => "+",
                    .modified => "±",
                    .deleted => "-",
                },
                .not_added => switch (status.kind.not_added) {
                    .modified => "±",
                    .deleted => "-",
                },
                .not_tracked => "?",
            };
            var status_text = try wgt.TextBox(Widget).init(allocator, status_kind_sym, .hidden);
            errdefer status_text.deinit();

            var path_text = try wgt.TextBox(Widget).init(allocator, status.path, .hidden);
            errdefer path_text.deinit();

            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();
            try box.children.put(status_text.getFocus().id, .{ .widget = .{ .text_box = status_text }, .rect = null, .visibility = null });
            try box.children.put(path_text.getFocus().id, .{ .widget = .{ .text_box = path_text }, .rect = null, .visibility = null });

            return .{
                .box = box,
            };
        }

        pub fn deinit(self: *GitStatusListItem(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitStatusListItem(Widget), constraint: layout.Constraint) !void {
            self.clearGrid();
            try self.box.build(constraint);
        }

        pub fn input(self: *GitStatusListItem(Widget), key: inp.Key) !void {
            _ = self;
            _ = key;
        }

        pub fn clearGrid(self: *GitStatusListItem(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitStatusListItem(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitStatusListItem(Widget)) *Focus {
            return self.box.getFocus();
        }

        pub fn setBorder(self: *GitStatusListItem(Widget), border_style: ?wgt.Box(Widget).BorderStyle) void {
            self.box.children.values()[1].widget.text_box.border_style = border_style;
        }
    };
}

pub fn GitStatusList(comptime Widget: type) type {
    return struct {
        scroll: wgt.Scroll(Widget),
        statuses: []Status,
        focused: bool,

        pub fn init(allocator: std.mem.Allocator, statuses: []Status) !GitStatusList(Widget) {
            // init inner_box
            var inner_box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer inner_box.deinit();
            for (statuses) |item| {
                var list_item = try GitStatusListItem(Widget).init(allocator, item);
                errdefer list_item.deinit();
                list_item.getFocus().focusable = true;
                try inner_box.children.put(list_item.getFocus().id, .{ .widget = .{ .git_status_list_item = list_item }, .rect = null, .visibility = null });
            }

            // init scroll
            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = inner_box }, .vert);
            errdefer scroll.deinit();
            if (inner_box.children.count() > 0) {
                scroll.getFocus().child_id = inner_box.children.keys()[0];
            }

            return .{
                .scroll = scroll,
                .statuses = statuses,
                .focused = false,
            };
        }

        pub fn deinit(self: *GitStatusList(Widget)) void {
            self.scroll.deinit();
        }

        pub fn build(self: *GitStatusList(Widget), constraint: layout.Constraint) !void {
            self.clearGrid();
            const children = &self.scroll.child.box.children;
            for (children.keys(), children.values()) |id, *item| {
                item.widget.git_status_list_item.setBorder(if (self.getFocus().child_id == id)
                    (if (self.focused) .double else .single)
                else
                    .hidden);
            }
            try self.scroll.build(constraint);
        }

        pub fn input(self: *GitStatusList(Widget), key: inp.Key) !void {
            if (self.getFocus().child_id) |child_id| {
                const children = &self.scroll.child.box.children;
                if (children.getIndex(child_id)) |current_index| {
                    var index = current_index;

                    switch (key) {
                        .arrow_up => {
                            index -|= 1;
                        },
                        .arrow_down => {
                            if (index + 1 < children.count()) {
                                index += 1;
                            }
                        },
                        .home => {
                            index = 0;
                        },
                        .end => {
                            if (children.count() > 0) {
                                index = children.count() - 1;
                            }
                        },
                        .page_up => {
                            if (self.getGrid()) |grid| {
                                const half_count = (grid.size.height / 3) / 2;
                                index -|= half_count;
                            }
                        },
                        .page_down => {
                            if (self.getGrid()) |grid| {
                                if (children.count() > 0) {
                                    const half_count = (grid.size.height / 3) / 2;
                                    index = @min(index + half_count, children.count() - 1);
                                }
                            }
                        },
                        else => {},
                    }

                    if (index != current_index) {
                        self.getFocus().child_id = children.keys()[index];
                        self.updateScroll(index);
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitStatusList(Widget)) void {
            self.scroll.clearGrid();
        }

        pub fn getGrid(self: GitStatusList(Widget)) ?Grid {
            return self.scroll.getGrid();
        }

        pub fn getFocus(self: *GitStatusList(Widget)) *Focus {
            return self.scroll.getFocus();
        }

        pub fn getSelectedIndex(self: GitStatusList(Widget)) ?usize {
            if (self.scroll.child.box.focus.child_id) |child_id| {
                const children = &self.scroll.child.box.children;
                return children.getIndex(child_id);
            } else {
                return null;
            }
        }

        fn updateScroll(self: *GitStatusList(Widget), index: usize) void {
            const left_box = &self.scroll.child.box;
            if (left_box.children.values()[index].rect) |rect| {
                self.scroll.scrollToRect(rect);
            }
        }
    };
}

pub fn GitStatusTabs(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),
        arena: std.heap.ArenaAllocator,
        focused: bool,

        const tab_count = @typeInfo(IndexKind).Enum.fields.len;

        pub fn init(allocator: std.mem.Allocator, statuses: []Status) !GitStatusTabs(Widget) {
            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();

            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            var counts: [tab_count]usize = [_]usize{0} ** tab_count;
            for (statuses) |status| {
                counts[@intFromEnum(status.kind)] += 1;
            }

            var selected_maybe: ?IndexKind = null;

            inline for (@typeInfo(IndexKind).Enum.fields, 0..) |field, i| {
                const index_kind: IndexKind = @enumFromInt(field.value);
                if (selected_maybe == null and counts[i] > 0) {
                    selected_maybe = index_kind;
                }
                const name = switch (index_kind) {
                    .added => "added",
                    .not_added => "not added",
                    .not_tracked => "not tracked",
                };
                const label = try std.fmt.allocPrint(arena.allocator(), "{s} ({})", .{ name, counts[i] });
                var text_box = try wgt.TextBox(Widget).init(allocator, label, .single);
                errdefer text_box.deinit();
                text_box.getFocus().focusable = true;
                try box.children.put(text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .visibility = null });
            }

            var git_status_tabs = GitStatusTabs(Widget){
                .box = box,
                .arena = arena,
                .focused = false,
            };
            git_status_tabs.getFocus().child_id = box.children.keys()[@intFromEnum(selected_maybe orelse .added)];
            return git_status_tabs;
        }

        pub fn deinit(self: *GitStatusTabs(Widget)) void {
            self.box.deinit();
            self.arena.deinit();
        }

        pub fn build(self: *GitStatusTabs(Widget), constraint: layout.Constraint) !void {
            self.clearGrid();
            for (self.box.children.keys(), self.box.children.values()) |id, *tab| {
                tab.widget.text_box.border_style = if (self.getFocus().child_id == id)
                    (if (self.focused) .double else .single)
                else
                    .hidden;
            }
            try self.box.build(constraint);
        }

        pub fn input(self: *GitStatusTabs(Widget), key: inp.Key) !void {
            if (self.getFocus().child_id) |child_id| {
                const children = &self.box.children;
                if (children.getIndex(child_id)) |current_index| {
                    var index = current_index;

                    switch (key) {
                        .arrow_left => {
                            index -|= 1;
                        },
                        .arrow_right => {
                            if (index + 1 < children.count()) {
                                index +|= 1;
                            }
                        },
                        else => {},
                    }

                    if (index != current_index) {
                        self.getFocus().child_id = children.keys()[index];
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitStatusTabs(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitStatusTabs(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitStatusTabs(Widget)) *Focus {
            return self.box.getFocus();
        }

        pub fn getSelectedIndex(self: GitStatusTabs(Widget)) ?usize {
            if (self.box.focus.child_id) |child_id| {
                const children = &self.box.children;
                return children.getIndex(child_id);
            } else {
                return null;
            }
        }
    };
}

pub fn GitStatusContent(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),
        filtered_statuses: std.ArrayList(Status),
        repo: ?*c.git_repository,
        focused: bool,

        const FocusKind = enum { status_list, diff };

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository, statuses: []Status, selected: IndexKind) !GitStatusContent(Widget) {
            var filtered_statuses = std.ArrayList(Status).init(allocator);
            errdefer filtered_statuses.deinit();
            for (statuses) |status| {
                if (status.kind == selected) {
                    try filtered_statuses.append(status);
                }
            }

            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();

            inline for (@typeInfo(FocusKind).Enum.fields) |focus_kind_field| {
                const focus_kind: FocusKind = @enumFromInt(focus_kind_field.value);
                switch (focus_kind) {
                    .status_list => {
                        var status_list = try GitStatusList(Widget).init(allocator, filtered_statuses.items);
                        errdefer status_list.deinit();
                        status_list.focused = true;
                        try box.children.put(status_list.getFocus().id, .{ .widget = .{ .git_status_list = status_list }, .rect = null, .visibility = .{ .min_size = .{ .width = 20, .height = null }, .priority = 1 } });
                    },
                    .diff => {
                        var diff = try g_diff.GitDiff(Widget).init(allocator, repo);
                        errdefer diff.deinit();
                        diff.getFocus().focusable = true;
                        diff.focused = false;
                        try box.children.put(diff.getFocus().id, .{ .widget = .{ .git_diff = diff }, .rect = null, .visibility = .{ .min_size = .{ .width = 60, .height = null }, .priority = 0 } });
                    },
                }
            }

            var status_content = GitStatusContent(Widget){
                .box = box,
                .filtered_statuses = filtered_statuses,
                .repo = repo,
                .focused = false,
            };
            status_content.getFocus().child_id = box.children.keys()[0];
            try status_content.updateDiff();
            return status_content;
        }

        pub fn deinit(self: *GitStatusContent(Widget)) void {
            self.box.deinit();
            self.filtered_statuses.deinit();
        }

        pub fn build(self: *GitStatusContent(Widget), constraint: layout.Constraint) !void {
            self.clearGrid();
            for (self.box.children.values()) |*child| {
                switch (child.widget) {
                    .git_status_list => {
                        child.widget.git_status_list.focused = (self.getFocus().child_id == child.widget.getFocus().id) and self.focused;
                    },
                    .git_diff => {
                        child.widget.git_diff.focused = (self.getFocus().child_id == child.widget.getFocus().id) and self.focused;
                    },
                    else => {},
                }
            }
            if (self.filtered_statuses.items.len > 0) {
                try self.box.build(constraint);
            }
        }

        pub fn input(self: *GitStatusContent(Widget), key: inp.Key) !void {
            const diff_scroll_x = self.box.children.values()[1].widget.git_diff.getScrollX();

            if (self.getFocus().child_id) |child_id| {
                if (self.box.children.getIndex(child_id)) |current_index| {
                    const child = &self.box.children.values()[current_index].widget;
                    var index = current_index;

                    switch (key) {
                        .arrow_left => {
                            if (child.* == .git_diff and diff_scroll_x == 0) {
                                index = @intFromEnum(FocusKind.status_list);
                            }
                        },
                        .arrow_right => {
                            if (child.* == .git_status_list) {
                                index = @intFromEnum(FocusKind.diff);
                            }
                        },
                        .codepoint => {
                            switch (key.codepoint) {
                                13 => {
                                    if (child.* == .git_status_list) {
                                        index = @intFromEnum(FocusKind.status_list);
                                    }
                                },
                                127, '\x1B' => {
                                    if (child.* == .git_diff) {
                                        index = @intFromEnum(FocusKind.diff);
                                    }
                                },
                                else => {},
                            }
                        },
                        else => {
                            try child.input(key);
                            if (child.* == .git_status_list) {
                                try self.updateDiff();
                            }
                        },
                    }

                    if (index == @intFromEnum(FocusKind.diff) and self.box.children.values()[1].widget.git_diff.getGrid() == null) {
                        index = @intFromEnum(FocusKind.status_list);
                    }

                    if (index != current_index) {
                        self.getFocus().child_id = self.box.children.keys()[index];
                        self.updatePriority(index);
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitStatusContent(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitStatusContent(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitStatusContent(Widget)) *Focus {
            return self.box.getFocus();
        }

        pub fn scrolledToTop(self: GitStatusContent(Widget)) bool {
            if (self.box.focus.child_id) |child_id| {
                if (self.box.children.getIndex(child_id)) |current_index| {
                    const child = &self.box.children.values()[current_index].widget;
                    switch (child.*) {
                        .git_status_list => {
                            const status_list = &child.git_status_list;
                            if (status_list.getSelectedIndex()) |status_index| {
                                return status_index == 0;
                            }
                        },
                        .git_diff => {
                            const diff = &child.git_diff;
                            return diff.getScrollY() == 0;
                        },
                        else => {},
                    }
                }
            }
            return true;
        }

        fn updateDiff(self: *GitStatusContent(Widget)) !void {
            const status_list = &self.box.children.values()[0].widget.git_status_list;
            if (status_list.getSelectedIndex()) |status_index| {
                const status = status_list.statuses[status_index];

                // index
                var index: ?*c.git_index = null;
                std.debug.assert(0 == c.git_repository_index(&index, self.repo));
                defer c.git_index_free(index);

                // get widget
                var diff = &self.box.children.values()[1].widget.git_diff;
                try diff.clearDiffs();

                // status diff
                var status_diff: ?*c.git_diff = null;
                switch (status.kind) {
                    .added => {
                        // head oid
                        var head_object: ?*c.git_object = null;
                        std.debug.assert(0 == c.git_revparse_single(&head_object, self.repo, "HEAD"));
                        defer c.git_object_free(head_object);
                        const head_oid = c.git_object_id(head_object);

                        // commit
                        var commit: ?*c.git_commit = null;
                        std.debug.assert(0 == c.git_commit_lookup(&commit, self.repo, head_oid));
                        defer c.git_commit_free(commit);

                        // commit tree
                        const commit_oid = c.git_commit_tree_id(commit);
                        var commit_tree: ?*c.git_tree = null;
                        std.debug.assert(0 == c.git_tree_lookup(&commit_tree, self.repo, commit_oid));
                        defer c.git_tree_free(commit_tree);

                        std.debug.assert(0 == c.git_diff_tree_to_index(&status_diff, self.repo, commit_tree, index, null));
                    },
                    .not_added => {
                        std.debug.assert(0 == c.git_diff_index_to_workdir(&status_diff, self.repo, index, null));
                    },
                    .not_tracked => return,
                }
                defer c.git_diff_free(status_diff);

                // patch
                var patch_maybe: ?*c.git_patch = null;
                defer if (patch_maybe) |patch| c.git_patch_free(patch);
                const delta_count = c.git_diff_num_deltas(status_diff);
                for (0..delta_count) |delta_index| {
                    const delta = c.git_diff_get_delta(status_diff, delta_index);
                    const path = std.mem.sliceTo(delta.*.old_file.path, 0);
                    if (std.mem.eql(u8, path, status.path)) {
                        std.debug.assert(0 == c.git_patch_from_diff(&patch_maybe, status_diff, delta_index));
                        break;
                    }
                }

                // update widget
                if (patch_maybe) |patch| {
                    try diff.addDiff(patch);
                }
            }
        }

        fn updatePriority(self: *GitStatusContent(Widget), selected_index: usize) void {
            for (self.box.children.values(), 0..) |*child, i| {
                if (child.visibility) |*vis| {
                    const ii: isize = @intCast(i);
                    vis.priority = if (ii <= selected_index) ii else -ii;
                }
            }
        }
    };
}

pub fn GitStatus(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),
        status_list: *c.git_status_list,
        statuses: std.ArrayList(Status),
        focused: bool,

        const FocusKind = enum { status_tabs, status_content };

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitStatus(Widget) {
            // get status
            var status_list: ?*c.git_status_list = null;
            var status_options: c.git_status_options = undefined;
            std.debug.assert(0 == c.git_status_options_init(&status_options, c.GIT_STATUS_OPTIONS_VERSION));
            status_options.show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
            status_options.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED;
            std.debug.assert(0 == c.git_status_list_new(&status_list, repo, &status_options));
            errdefer c.git_status_list_free(status_list);
            const entry_count = c.git_status_list_entrycount(status_list);

            // loop over results
            var statuses = std.ArrayList(Status).init(allocator);
            errdefer statuses.deinit();
            for (0..entry_count) |i| {
                const entry = c.git_status_byindex(status_list, i);
                try std.testing.expect(null != entry);
                const status_kind: c_int = @intCast(entry.*.status);
                if (c.GIT_STATUS_INDEX_NEW & status_kind != 0) {
                    const old_path = entry.*.head_to_index.*.old_file.path;
                    try statuses.append(.{ .kind = .{ .added = .created }, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_INDEX_MODIFIED & status_kind != 0) {
                    const old_path = entry.*.head_to_index.*.old_file.path;
                    try statuses.append(.{ .kind = .{ .added = .modified }, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_INDEX_DELETED & status_kind != 0) {
                    const old_path = entry.*.head_to_index.*.old_file.path;
                    try statuses.append(.{ .kind = .{ .added = .deleted }, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_WT_NEW & status_kind != 0) {
                    const old_path = entry.*.index_to_workdir.*.old_file.path;
                    try statuses.append(.{ .kind = .not_tracked, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_WT_MODIFIED & status_kind != 0) {
                    const old_path = entry.*.index_to_workdir.*.old_file.path;
                    try statuses.append(.{ .kind = .{ .not_added = .modified }, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_WT_DELETED & status_kind != 0) {
                    const old_path = entry.*.index_to_workdir.*.old_file.path;
                    try statuses.append(.{ .kind = .{ .not_added = .deleted }, .path = std.mem.sliceTo(old_path, 0) });
                }
            }

            // init box
            var box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer box.deinit();

            inline for (@typeInfo(FocusKind).Enum.fields) |focus_kind_field| {
                const focus_kind: FocusKind = @enumFromInt(focus_kind_field.value);
                switch (focus_kind) {
                    .status_tabs => {
                        var status_tabs = try GitStatusTabs(Widget).init(allocator, statuses.items);
                        errdefer status_tabs.deinit();
                        try box.children.put(status_tabs.getFocus().id, .{ .widget = .{ .git_status_tabs = status_tabs }, .rect = null, .visibility = null });
                    },
                    .status_content => {
                        var stack = g_ui.GitUIStack(Widget).init(allocator);
                        errdefer stack.deinit();

                        inline for (@typeInfo(IndexKind).Enum.fields) |index_kind_field| {
                            const index_kind: IndexKind = @enumFromInt(index_kind_field.value);
                            var status_content = try GitStatusContent(Widget).init(allocator, repo, statuses.items, index_kind);
                            errdefer status_content.deinit();
                            try stack.children.put(status_content.getFocus().id, .{ .git_status_content = status_content });
                        }

                        try box.children.put(stack.getFocus().id, .{ .widget = .{ .git_ui_stack = stack }, .rect = null, .visibility = null });
                    },
                }
            }

            var git_status = GitStatus(Widget){
                .box = box,
                .statuses = statuses,
                .status_list = status_list.?,
                .focused = false,
            };
            git_status.getFocus().child_id = box.children.keys()[0];
            return git_status;
        }

        pub fn deinit(self: *GitStatus(Widget)) void {
            self.box.deinit();
            self.statuses.deinit();
            c.git_status_list_free(self.status_list);
        }

        pub fn build(self: *GitStatus(Widget), constraint: layout.Constraint) !void {
            self.clearGrid();
            var status_tabs = &self.box.children.values()[0].widget.git_status_tabs;
            status_tabs.focused = (self.getFocus().child_id == status_tabs.getFocus().id) and self.focused;
            var stack = &self.box.children.values()[1].widget.git_ui_stack;
            stack.focused = (self.getFocus().child_id == stack.getFocus().id) and self.focused;
            if (status_tabs.getSelectedIndex()) |index| {
                stack.getFocus().child_id = stack.children.keys()[index];
            }
            try self.box.build(constraint);
        }

        pub fn input(self: *GitStatus(Widget), key: inp.Key) !void {
            if (self.getFocus().child_id) |child_id| {
                if (self.box.children.getIndex(child_id)) |current_index| {
                    const child = &self.box.children.values()[current_index].widget;
                    var index = current_index;

                    switch (child.*) {
                        .git_status_tabs => {
                            const status_tabs = &child.git_status_tabs;
                            if (key == .arrow_down) {
                                index = @intFromEnum(FocusKind.status_content);
                            } else {
                                try status_tabs.input(key);
                            }
                        },
                        .git_ui_stack => {
                            const stack = &child.git_ui_stack;
                            if (stack.getSelected()) |selected_widget| {
                                if (key == .arrow_up and selected_widget.git_status_content.scrolledToTop()) {
                                    index = @intFromEnum(FocusKind.status_tabs);
                                } else {
                                    try stack.input(key);
                                }
                            }
                        },
                        else => {},
                    }

                    if (index == @intFromEnum(FocusKind.status_content)) {
                        if (self.box.children.values()[@intFromEnum(FocusKind.status_content)].widget.git_ui_stack.getSelected()) |selected_widget| {
                            if (selected_widget.git_status_content.getGrid() == null) {
                                index = @intFromEnum(FocusKind.status_tabs);
                            }
                        }
                    }

                    if (index != current_index) {
                        self.getFocus().child_id = self.box.children.keys()[index];
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitStatus(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitStatus(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitStatus(Widget)) *Focus {
            return self.box.getFocus();
        }

        pub fn getSelectedIndex(self: GitStatus(Widget)) ?usize {
            if (self.box.focus.child_id) |child_id| {
                const children = &self.box.children;
                return children.getIndex(child_id);
            } else {
                return null;
            }
        }
    };
}
