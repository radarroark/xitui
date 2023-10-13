const std = @import("std");
const term = @import("./terminal.zig");
const wgt = @import("./widget.zig");
const grd = @import("./grid.zig");
const MaybeSize = @import("./layout.zig").MaybeSize;
const inp = @import("./input.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn GitCommitList(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        scroll: wgt.Scroll(Widget),
        repo: ?*c.git_repository,
        commits: std.ArrayList(?*c.git_commit),
        selected: usize = 0,
        focused: bool,

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitCommitList(Widget) {
            // init walker
            var walker: ?*c.git_revwalk = null;
            std.debug.assert(0 == c.git_revwalk_new(&walker, repo));
            defer c.git_revwalk_free(walker);
            std.debug.assert(0 == c.git_revwalk_sorting(walker, c.GIT_SORT_TIME));
            std.debug.assert(0 == c.git_revwalk_push_head(walker));

            // init commits
            var commits = std.ArrayList(?*c.git_commit).init(allocator);
            errdefer commits.deinit();

            // walk the commits
            var oid: c.git_oid = undefined;
            while (0 == c.git_revwalk_next(&oid, walker)) {
                var commit: ?*c.git_commit = null;
                std.debug.assert(0 == c.git_commit_lookup(&commit, repo, &oid));
                errdefer c.git_commit_free(commit);
                try commits.append(commit);
            }

            var inner_box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer inner_box.deinit();
            for (commits.items) |commit| {
                const line = std.mem.sliceTo(c.git_commit_message(commit), '\n');
                var text_box = try wgt.TextBox(Widget).init(allocator, line, .hidden);
                errdefer text_box.deinit();
                try inner_box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = text_box }), .rect = null, .visibility = null });
            }

            // init scroll
            var scroll = try wgt.Scroll(Widget).init(allocator, wgt.Any(Widget).init(.{ .box = inner_box }), .vert);
            errdefer scroll.deinit();

            return .{
                .grid = null,
                .scroll = scroll,
                .repo = repo,
                .commits = commits,
                .selected = 0,
                .focused = false,
            };
        }

        pub fn deinit(self: *GitCommitList(Widget)) void {
            for (self.commits.items) |commit| {
                c.git_commit_free(commit);
            }
            self.commits.deinit();
            self.scroll.deinit();
        }

        pub fn build(self: *GitCommitList(Widget), max_size: MaybeSize) !void {
            self.clear();
            try self.scroll.build(max_size);
            self.grid = self.scroll.grid;
        }

        pub fn input(self: *GitCommitList(Widget), key: inp.Key) !void {
            switch (key) {
                .arrow_up => {
                    self.selected -|= 1;
                    self.updateScroll();
                },
                .arrow_down => {
                    if (self.selected + 1 < self.commits.items.len) {
                        self.selected += 1;
                        self.updateScroll();
                    }
                },
                .home => {
                    self.selected = 0;
                    self.updateScroll();
                },
                .end => {
                    if (self.commits.items.len > 0) {
                        self.selected = self.commits.items.len - 1;
                        self.updateScroll();
                    }
                },
                .page_up => {
                    if (self.grid) |grid| {
                        const half_count = (grid.size.height / 3) / 2;
                        self.selected -|= half_count;
                        self.updateScroll();
                    }
                },
                .page_down => {
                    if (self.grid) |grid| {
                        if (self.commits.items.len > 0) {
                            const half_count = (grid.size.height / 3) / 2;
                            self.selected = @min(self.selected + half_count, self.commits.items.len - 1);
                            self.updateScroll();
                        }
                    }
                },
                else => {},
            }

            self.refresh();
        }

        pub fn clear(self: *GitCommitList(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitCommitList(Widget)) void {
            for (self.scroll.child.widget.box.children.items, 0..) |*commit, i| {
                commit.any.widget.text_box.border_style = if (self.selected == i)
                    (if (self.focused) .double else .single)
                else
                    .hidden;
            }
        }

        fn updateScroll(self: *GitCommitList(Widget)) void {
            var left_box = &self.scroll.child.widget.box;
            if (left_box.children.items.len > self.selected) {
                if (left_box.children.items[self.selected].rect) |rect| {
                    self.scroll.scrollToRect(rect);
                }
            }
        }
    };
}

pub fn GitDiff(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        allocator: std.mem.Allocator,
        repo: ?*c.git_repository,
        bufs: std.ArrayList(c.git_buf),
        focused: bool,

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitDiff(Widget) {
            var inner_box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer inner_box.deinit();

            var scroll = try wgt.Scroll(Widget).init(allocator, wgt.Any(Widget).init(.{ .box = inner_box }), .both);
            errdefer scroll.deinit();

            var outer_box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer outer_box.deinit();
            try outer_box.children.append(.{ .any = wgt.Any(Widget).init(.{ .scroll = scroll }), .rect = null, .visibility = null });

            return .{
                .grid = null,
                .box = outer_box,
                .allocator = allocator,
                .repo = repo,
                .bufs = std.ArrayList(c.git_buf).init(allocator),
                .focused = false,
            };
        }

        pub fn deinit(self: *GitDiff(Widget)) void {
            for (self.bufs.items) |*buf| {
                c.git_buf_dispose(buf);
            }
            self.bufs.deinit();
            self.box.deinit();
        }

        pub fn build(self: *GitDiff(Widget), max_size: MaybeSize) !void {
            self.clear();
            try self.box.build(max_size);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitDiff(Widget), key: inp.Key) !void {
            switch (key) {
                .arrow_up => {
                    if (self.box.children.items[0].any.widget.scroll.y > 0) {
                        self.box.children.items[0].any.widget.scroll.y -= 1;
                    }
                },
                .arrow_down => {
                    if (self.box.grid) |outer_box_grid| {
                        const outer_box_height = outer_box_grid.size.height - 2;
                        const scroll_y = self.box.children.items[0].any.widget.scroll.y;
                        const u_scroll_y: usize = if (scroll_y >= 0) @intCast(scroll_y) else 0;
                        if (self.box.children.items[0].any.widget.scroll.child.widget.box.grid) |inner_box_grid| {
                            const inner_box_height = inner_box_grid.size.height;
                            if (outer_box_height + u_scroll_y < inner_box_height) {
                                self.box.children.items[0].any.widget.scroll.y += 1;
                            }
                        }
                    }
                },
                .arrow_left => {
                    if (self.box.children.items[0].any.widget.scroll.x > 0) {
                        self.box.children.items[0].any.widget.scroll.x -= 1;
                    }
                },
                .arrow_right => {
                    if (self.box.grid) |outer_box_grid| {
                        const outer_box_width = outer_box_grid.size.width - 2;
                        const scroll_x = self.box.children.items[0].any.widget.scroll.x;
                        const u_scroll_x: usize = if (scroll_x >= 0) @intCast(scroll_x) else 0;
                        if (self.box.children.items[0].any.widget.scroll.child.widget.box.grid) |inner_box_grid| {
                            const inner_box_width = inner_box_grid.size.width;
                            if (outer_box_width + u_scroll_x < inner_box_width) {
                                self.box.children.items[0].any.widget.scroll.x += 1;
                            }
                        }
                    }
                },
                .home => {
                    self.box.children.items[0].any.widget.scroll.y = 0;
                },
                .end => {
                    if (self.box.grid) |outer_box_grid| {
                        if (self.box.children.items[0].any.widget.scroll.child.widget.box.grid) |inner_box_grid| {
                            const outer_box_height = outer_box_grid.size.height - 2;
                            const inner_box_height = inner_box_grid.size.height;
                            const max_scroll: isize = if (inner_box_height > outer_box_height) @intCast(inner_box_height - outer_box_height) else 0;
                            self.box.children.items[0].any.widget.scroll.y = max_scroll;
                        }
                    }
                },
                .page_up => {
                    if (self.box.grid) |outer_box_grid| {
                        const outer_box_height = outer_box_grid.size.height - 2;
                        const scroll_y = self.box.children.items[0].any.widget.scroll.y;
                        const scroll_change: isize = @intCast(outer_box_height / 2);
                        self.box.children.items[0].any.widget.scroll.y = @max(0, scroll_y - scroll_change);
                    }
                },
                .page_down => {
                    if (self.box.grid) |outer_box_grid| {
                        if (self.box.children.items[0].any.widget.scroll.child.widget.box.grid) |inner_box_grid| {
                            const outer_box_height = outer_box_grid.size.height - 2;
                            const inner_box_height = inner_box_grid.size.height;
                            const max_scroll: isize = if (inner_box_height > outer_box_height) @intCast(inner_box_height - outer_box_height) else 0;
                            const scroll_y = self.box.children.items[0].any.widget.scroll.y;
                            const scroll_change: isize = @intCast(outer_box_height / 2);
                            self.box.children.items[0].any.widget.scroll.y = @min(scroll_y + scroll_change, max_scroll);
                        }
                    }
                },
                else => {},
            }
        }

        pub fn clear(self: *GitDiff(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitDiff(Widget)) void {
            self.box.border_style = if (self.focused) .double else .hidden;
        }

        pub fn updateDiff(self: *GitDiff(Widget), commit_diff: ?*c.git_diff) !void {
            for (self.bufs.items) |*buf| {
                c.git_buf_dispose(buf);
            }
            self.bufs.clearAndFree();

            const delta_count = c.git_diff_num_deltas(commit_diff);
            for (0..delta_count) |delta_index| {
                var commit_patch: ?*c.git_patch = null;
                std.debug.assert(0 == c.git_patch_from_diff(&commit_patch, commit_diff, delta_index));
                defer c.git_patch_free(commit_patch);

                var commit_buf: c.git_buf = std.mem.zeroes(c.git_buf);
                std.debug.assert(0 == c.git_patch_to_buf(&commit_buf, commit_patch));
                {
                    errdefer c.git_buf_dispose(&commit_buf);
                    try self.bufs.append(commit_buf);
                }
            }

            // remove old diff widgets
            for (self.box.children.items[0].any.widget.scroll.child.widget.box.children.items) |*child| {
                child.any.deinit();
            }
            self.box.children.items[0].any.widget.scroll.child.widget.box.children.clearAndFree();

            // add new diff widgets
            for (self.bufs.items) |buf| {
                var text_box = try wgt.TextBox(Widget).init(self.allocator, std.mem.sliceTo(buf.ptr, 0), .hidden);
                errdefer text_box.deinit();
                try self.box.children.items[0].any.widget.scroll.child.widget.box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = text_box }), .rect = null, .visibility = null });
            }

            // reset scroll position
            self.box.children.items[0].any.widget.scroll.x = 0;
            self.box.children.items[0].any.widget.scroll.y = 0;
        }
    };
}

pub fn GitLog(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        repo: ?*c.git_repository,
        selected: union(enum) { commit_list, diff },
        focused: bool,

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitLog(Widget) {
            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();

            // add commit list
            {
                var commit_list = try GitCommitList(Widget).init(allocator, repo);
                errdefer commit_list.deinit();
                try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .git_commit_list = commit_list }), .rect = null, .visibility = .{ .min_size = .{ .width = 30, .height = null }, .priority = 1 } });
            }

            // add diff
            {
                var diff = try GitDiff(Widget).init(allocator, repo);
                errdefer diff.deinit();
                try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .git_diff = diff }), .rect = null, .visibility = .{ .min_size = .{ .width = 60, .height = null }, .priority = 0 } });
            }

            var git_log = GitLog(Widget){
                .grid = null,
                .box = box,
                .repo = repo,
                .selected = .commit_list,
                .focused = false,
            };
            try git_log.updateDiff();

            return git_log;
        }

        pub fn deinit(self: *GitLog(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitLog(Widget), max_size: MaybeSize) !void {
            self.clear();
            try self.box.build(max_size);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitLog(Widget), key: inp.Key) !void {
            const diff_scroll_x = self.box.children.items[1].any.widget.git_diff.box.children.items[0].any.widget.scroll.x;

            switch (self.selected) {
                .commit_list => {
                    try self.box.children.items[0].any.input(key);
                    try self.updateDiff();
                },
                .diff => {
                    try self.box.children.items[1].any.input(key);
                },
            }

            switch (key) {
                .arrow_left => {
                    switch (self.selected) {
                        .commit_list => {},
                        .diff => {
                            if (diff_scroll_x == 0) {
                                self.selected = .commit_list;
                                self.updatePriority();
                            }
                        },
                    }
                },
                .arrow_right => {
                    switch (self.selected) {
                        .commit_list => {
                            self.selected = .diff;
                            self.updatePriority();
                        },
                        .diff => {},
                    }
                },
                .codepoint => {
                    switch (key.codepoint) {
                        13 => {
                            switch (self.selected) {
                                .commit_list => {
                                    self.selected = .diff;
                                    self.updatePriority();
                                },
                                .diff => {},
                            }
                        },
                        127, '\x1B' => {
                            switch (self.selected) {
                                .commit_list => {},
                                .diff => {
                                    self.selected = .commit_list;
                                    self.updatePriority();
                                },
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }

            self.refresh();
        }

        pub fn clear(self: *GitLog(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitLog(Widget)) void {
            switch (self.selected) {
                .commit_list => {
                    var commit_list = &self.box.children.items[0].any.widget.git_commit_list;
                    commit_list.focused = self.focused;
                    commit_list.refresh();
                    var diff = &self.box.children.items[1].any.widget.git_diff;
                    diff.focused = false;
                    diff.refresh();
                },
                .diff => {
                    var commit_list = &self.box.children.items[0].any.widget.git_commit_list;
                    commit_list.focused = false;
                    commit_list.refresh();
                    var diff = &self.box.children.items[1].any.widget.git_diff;
                    diff.focused = self.focused;
                    diff.refresh();
                },
            }
        }

        fn updateDiff(self: *GitLog(Widget)) !void {
            const commit_list = &self.box.children.items[0].any.widget.git_commit_list;

            const commit = commit_list.commits.items[commit_list.selected];

            const commit_oid = c.git_commit_tree_id(commit);
            var commit_tree: ?*c.git_tree = null;
            std.debug.assert(0 == c.git_tree_lookup(&commit_tree, self.repo, commit_oid));
            defer c.git_tree_free(commit_tree);

            var prev_commit_tree: ?*c.git_tree = null;

            if (commit_list.selected < commit_list.commits.items.len - 1) {
                const prev_commit = commit_list.commits.items[commit_list.selected + 1];
                const prev_commit_oid = c.git_commit_tree_id(prev_commit);
                std.debug.assert(0 == c.git_tree_lookup(&prev_commit_tree, self.repo, prev_commit_oid));
            }
            defer if (prev_commit_tree) |ptr| c.git_tree_free(ptr);

            var commit_diff: ?*c.git_diff = null;
            std.debug.assert(0 == c.git_diff_tree_to_tree(&commit_diff, self.repo, prev_commit_tree, commit_tree, null));
            defer c.git_diff_free(commit_diff);

            var diff = &self.box.children.items[1].any.widget.git_diff;
            try diff.updateDiff(commit_diff);
        }

        fn updatePriority(self: *GitLog(Widget)) void {
            const selected_index = @intFromEnum(self.selected);
            for (self.box.children.items, 0..) |*child, i| {
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
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        selected: usize,
        focused: bool,

        pub fn init(allocator: std.mem.Allocator) !GitStatus(Widget) {
            var box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer box.deinit();

            {
                var text_box = try wgt.TextBox(Widget).init(allocator, "hello world", .single);
                errdefer text_box.deinit();
                try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = text_box }), .rect = null, .visibility = null });
            }

            return .{
                .grid = null,
                .box = box,
                .selected = 0,
                .focused = false,
            };
        }

        pub fn deinit(self: *GitStatus(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitStatus(Widget), max_size: MaybeSize) !void {
            self.clear();
            try self.box.build(max_size);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitStatus(Widget), key: inp.Key) !void {
            _ = self;
            _ = key;
        }

        pub fn clear(self: *GitStatus(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitStatus(Widget)) void {
            for (self.box.children.items, 0..) |*child, i| {
                child.any.widget.text_box.border_style = if (self.selected == i)
                    (if (self.focused) .double else .single)
                else
                    .hidden;
            }
        }
    };
}

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
                try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = text_box }), .rect = null, .visibility = null });
            }

            {
                var text_box = try wgt.TextBox(Widget).init(allocator, "status", .hidden);
                errdefer text_box.deinit();
                try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = text_box }), .rect = null, .visibility = null });
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

        pub fn build(self: *GitUITabs(Widget), max_size: MaybeSize) !void {
            self.clear();
            try self.box.build(max_size);
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

        pub fn refresh(self: *GitUITabs(Widget)) void {
            for (self.box.children.items, 0..) |*tab, i| {
                tab.any.widget.text_box.border_style = if (self.selected == i)
                    (if (self.focused) .double else .single)
                else
                    .hidden;
            }
        }
    };
}

pub fn GitUIStack(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        children: std.ArrayList(wgt.Any(Widget)),
        selected: usize,
        focused: bool,

        pub fn init(allocator: std.mem.Allocator) GitUIStack(Widget) {
            return .{
                .grid = null,
                .children = std.ArrayList(wgt.Any(Widget)).init(allocator),
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

        pub fn build(self: *GitUIStack(Widget), max_size: MaybeSize) !void {
            self.clear();
            var widget = &self.children.items[self.selected];
            try widget.build(max_size);
            self.grid = widget.grid();
        }

        pub fn input(self: *GitUIStack(Widget), key: inp.Key) !void {
            try self.children.items[self.selected].input(key);
        }

        pub fn clear(self: *GitUIStack(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitUIStack(Widget)) void {
            for (self.children.items, 0..) |*child, i| {
                switch (child.widget) {
                    .git_status => {
                        child.widget.git_status.focused = self.focused and i == self.selected;
                        child.widget.git_status.refresh();
                    },
                    .git_log => {
                        child.widget.git_log.focused = self.focused and i == self.selected;
                        child.widget.git_log.refresh();
                    },
                    else => {},
                }
            }
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
                try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .git_ui_tabs = git_ui_tabs }), .rect = null, .visibility = null });
            }

            {
                var stack = GitUIStack(Widget).init(allocator);
                errdefer stack.deinit();

                {
                    var git_log = try GitLog(Widget).init(allocator, repo);
                    errdefer git_log.deinit();
                    git_log.focused = true;
                    git_log.refresh();
                    try stack.children.append(wgt.Any(Widget).init(.{ .git_log = git_log }));
                }

                {
                    var git_status = try GitStatus(Widget).init(allocator);
                    errdefer git_status.deinit();
                    git_status.focused = false;
                    git_status.refresh();
                    try stack.children.append(wgt.Any(Widget).init(.{ .git_status = git_status }));
                }

                try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .git_ui_stack = stack }), .rect = null, .visibility = null });
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

        pub fn build(self: *GitUI(Widget), max_size: MaybeSize) !void {
            self.clear();
            try self.box.build(max_size);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitUI(Widget), key: inp.Key) !void {
            switch (key) {
                .arrow_up => {
                    switch (self.selected) {
                        .tabs => {
                            try self.box.children.items[0].any.input(key);
                        },
                        .stack => {
                            var git_ui_stack = &self.box.children.items[1].any.widget.git_ui_stack;
                            var selected_widget = &git_ui_stack.children.items[git_ui_stack.selected].widget;
                            switch (selected_widget.*) {
                                .git_log => {
                                    const log_selected = selected_widget.git_log.box.children.items[0].any.widget.git_commit_list.selected;
                                    try self.box.children.items[1].any.input(key);
                                    if (log_selected == 0) {
                                        self.selected = .tabs;
                                    }
                                },
                                .git_status => {
                                    self.selected = .tabs;
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
                            try self.box.children.items[1].any.input(key);
                        },
                    }
                },
                else => {
                    switch (self.selected) {
                        .tabs => {
                            try self.box.children.items[0].any.input(key);
                        },
                        .stack => {
                            try self.box.children.items[1].any.input(key);
                        },
                    }
                },
            }

            self.refresh();
        }

        pub fn clear(self: *GitUI(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitUI(Widget)) void {
            var git_ui_tabs = &self.box.children.items[0].any.widget.git_ui_tabs;
            git_ui_tabs.focused = self.selected == .tabs;
            git_ui_tabs.refresh();
            var git_ui_stack = &self.box.children.items[1].any.widget.git_ui_stack;
            git_ui_stack.focused = self.selected == .stack;
            git_ui_stack.selected = git_ui_tabs.selected;
            git_ui_stack.refresh();
        }
    };
}
