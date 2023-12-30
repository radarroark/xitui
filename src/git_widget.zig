const std = @import("std");
const term = @import("./terminal.zig");
const wgt = @import("./widget.zig");
const grd = @import("./grid.zig");
const layout = @import("./layout.zig");
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

        pub fn build(self: *GitCommitList(Widget), constraint: layout.Constraint) !void {
            self.clear();
            try self.scroll.build(constraint);
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
            const left_box = &self.scroll.child.widget.box;
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

            var outer_box = try wgt.Box(Widget).init(allocator, .single, .vert);
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

        pub fn build(self: *GitDiff(Widget), constraint: layout.Constraint) !void {
            self.clear();
            if (self.bufs.items.len > 0) {
                try self.box.build(constraint);
                self.grid = self.box.grid;
            }
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
            self.box.border_style = if (self.focused) .double else .single;
        }

        pub fn clearDiffs(self: *GitDiff(Widget)) !void {
            // clear buffers
            for (self.bufs.items) |*buf| {
                c.git_buf_dispose(buf);
            }
            self.bufs.clearAndFree();

            // remove old diff widgets
            for (self.box.children.items[0].any.widget.scroll.child.widget.box.children.items) |*child| {
                child.any.deinit();
            }
            self.box.children.items[0].any.widget.scroll.child.widget.box.children.clearAndFree();

            // reset scroll position
            self.box.children.items[0].any.widget.scroll.x = 0;
            self.box.children.items[0].any.widget.scroll.y = 0;
        }

        pub fn addDiff(self: *GitDiff(Widget), patch: ?*c.git_patch) !void {
            // add new buffer
            var buf: c.git_buf = std.mem.zeroes(c.git_buf);
            std.debug.assert(0 == c.git_patch_to_buf(&buf, patch));
            {
                errdefer c.git_buf_dispose(&buf);
                try self.bufs.append(buf);
            }

            // add new diff widget
            var text_box = try wgt.TextBox(Widget).init(self.allocator, std.mem.sliceTo(buf.ptr, 0), .hidden);
            errdefer text_box.deinit();
            try self.box.children.items[0].any.widget.scroll.child.widget.box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = text_box }), .rect = null, .visibility = null });
        }

        pub fn getScrollX(self: GitDiff(Widget)) isize {
            return self.box.children.items[0].any.widget.scroll.x;
        }

        pub fn getScrollY(self: GitDiff(Widget)) isize {
            return self.box.children.items[0].any.widget.scroll.y;
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

        pub fn build(self: *GitLog(Widget), constraint: layout.Constraint) !void {
            self.clear();
            try self.box.build(constraint);
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

        pub fn scrolledToTop(self: GitLog(Widget)) bool {
            switch (self.selected) {
                .commit_list => {
                    const commit_list = &self.box.children.items[0].any.widget.git_commit_list;
                    return commit_list.selected == 0;
                },
                .diff => {
                    const diff = &self.box.children.items[1].any.widget.git_diff;
                    return diff.getScrollY() == 0;
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
            try diff.clearDiffs();

            const delta_count = c.git_diff_num_deltas(commit_diff);
            for (0..delta_count) |delta_index| {
                var patch: ?*c.git_patch = null;
                std.debug.assert(0 == c.git_patch_from_diff(&patch, commit_diff, delta_index));
                defer c.git_patch_free(patch);
                try diff.addDiff(patch);
            }
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

pub fn GitStatusListItem(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),

        pub fn init(allocator: std.mem.Allocator, status: Status) !GitStatusListItem(Widget) {
            const status_kind_sym = switch (status.kind) {
                .staged => switch (status.kind.staged) {
                    .added => "+",
                    .modified => "±",
                    .deleted => "-",
                },
                .unstaged => switch (status.kind.unstaged) {
                    .modified => "±",
                    .deleted => "-",
                },
                .untracked => "?",
            };
            var status_text = try wgt.TextBox(Widget).init(allocator, status_kind_sym, .hidden);
            errdefer status_text.deinit();

            var path_text = try wgt.TextBox(Widget).init(allocator, status.path, .hidden);
            errdefer path_text.deinit();

            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();
            try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = status_text }), .rect = null, .visibility = null });
            try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = path_text }), .rect = null, .visibility = null });

            return .{
                .grid = null,
                .box = box,
            };
        }

        pub fn deinit(self: *GitStatusListItem(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitStatusListItem(Widget), constraint: layout.Constraint) !void {
            self.clear();
            try self.box.build(constraint);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitStatusListItem(Widget), key: inp.Key) !void {
            _ = self;
            _ = key;
        }

        pub fn clear(self: *GitStatusListItem(Widget)) void {
            self.grid = null;
        }

        pub fn setBorder(self: *GitStatusListItem(Widget), border_style: ?wgt.Box(Widget).BorderStyle) void {
            self.box.children.items[1].any.widget.text_box.border_style = border_style;
        }
    };
}

pub fn GitStatusList(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        scroll: wgt.Scroll(Widget),
        statuses: []Status,
        selected: usize = 0,
        focused: bool,

        pub fn init(allocator: std.mem.Allocator, statuses: []Status) !GitStatusList(Widget) {
            // init inner_box
            var inner_box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer inner_box.deinit();
            for (statuses) |item| {
                var list_item = try GitStatusListItem(Widget).init(allocator, item);
                errdefer list_item.deinit();
                try inner_box.children.append(.{ .any = wgt.Any(Widget).init(.{ .git_status_list_item = list_item }), .rect = null, .visibility = null });
            }

            // init scroll
            var scroll = try wgt.Scroll(Widget).init(allocator, wgt.Any(Widget).init(.{ .box = inner_box }), .vert);
            errdefer scroll.deinit();

            return .{
                .grid = null,
                .scroll = scroll,
                .statuses = statuses,
                .selected = 0,
                .focused = false,
            };
        }

        pub fn deinit(self: *GitStatusList(Widget)) void {
            self.scroll.deinit();
        }

        pub fn build(self: *GitStatusList(Widget), constraint: layout.Constraint) !void {
            self.clear();
            try self.scroll.build(constraint);
            self.grid = self.scroll.grid;
        }

        pub fn input(self: *GitStatusList(Widget), key: inp.Key) !void {
            switch (key) {
                .arrow_up => {
                    self.selected -|= 1;
                    self.updateScroll();
                },
                .arrow_down => {
                    if (self.selected + 1 < self.statuses.len) {
                        self.selected += 1;
                        self.updateScroll();
                    }
                },
                .home => {
                    self.selected = 0;
                    self.updateScroll();
                },
                .end => {
                    if (self.statuses.len > 0) {
                        self.selected = self.statuses.len - 1;
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
                        if (self.statuses.len > 0) {
                            const half_count = (grid.size.height / 3) / 2;
                            self.selected = @min(self.selected + half_count, self.statuses.len - 1);
                            self.updateScroll();
                        }
                    }
                },
                else => {},
            }

            self.refresh();
        }

        pub fn clear(self: *GitStatusList(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitStatusList(Widget)) void {
            for (self.scroll.child.widget.box.children.items, 0..) |*item, i| {
                item.any.widget.git_status_list_item.setBorder(if (self.selected == i)
                    (if (self.focused) .double else .single)
                else
                    .hidden);
            }
        }

        fn updateScroll(self: *GitStatusList(Widget)) void {
            const left_box = &self.scroll.child.widget.box;
            if (left_box.children.items.len > self.selected) {
                if (left_box.children.items[self.selected].rect) |rect| {
                    self.scroll.scrollToRect(rect);
                }
            }
        }
    };
}

pub fn GitStatusTabs(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        arena: std.heap.ArenaAllocator,
        selected: IndexKind,
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
                if (selected_maybe == null and counts[i] > 0) {
                    selected_maybe = @enumFromInt(field.value);
                }
                const label = try std.fmt.allocPrint(arena.allocator(), "{s} ({})", .{ field.name, counts[i] });
                var text_box = try wgt.TextBox(Widget).init(allocator, label, .single);
                errdefer text_box.deinit();
                try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = text_box }), .rect = null, .visibility = null });
            }

            return .{
                .grid = null,
                .box = box,
                .arena = arena,
                .selected = selected_maybe orelse .staged,
                .focused = false,
            };
        }

        pub fn deinit(self: *GitStatusTabs(Widget)) void {
            self.box.deinit();
            self.arena.deinit();
        }

        pub fn build(self: *GitStatusTabs(Widget), constraint: layout.Constraint) !void {
            self.clear();
            try self.box.build(constraint);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitStatusTabs(Widget), key: inp.Key) !void {
            switch (key) {
                .arrow_left => {
                    self.selected = @enumFromInt(@intFromEnum(self.selected) -| 1);
                },
                .arrow_right => {
                    if (@intFromEnum(self.selected) + 1 < tab_count) {
                        self.selected = @enumFromInt(@intFromEnum(self.selected) + 1);
                    }
                },
                else => {},
            }
        }

        pub fn clear(self: *GitStatusTabs(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitStatusTabs(Widget)) void {
            for (self.box.children.items, 0..) |*tab, i| {
                tab.any.widget.text_box.border_style = if (@intFromEnum(self.selected) == i)
                    (if (self.focused) .double else .single)
                else
                    .hidden;
            }
        }
    };
}

pub fn GitStatusContent(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        repo: ?*c.git_repository,
        filtered_statuses: std.ArrayList(Status),
        allocator: std.mem.Allocator,
        selected: enum { status_list, diff },
        focused: bool,

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository, statuses: []Status, selected: IndexKind) !GitStatusContent(Widget) {
            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();

            var status_content = GitStatusContent(Widget){
                .grid = null,
                .box = box,
                .repo = repo,
                .filtered_statuses = std.ArrayList(Status).init(allocator),
                .allocator = allocator,
                .selected = .status_list,
                .focused = false,
            };
            try status_content.update(statuses, selected);
            return status_content;
        }

        pub fn deinit(self: *GitStatusContent(Widget)) void {
            self.box.deinit();
            self.filtered_statuses.deinit();
        }

        pub fn build(self: *GitStatusContent(Widget), constraint: layout.Constraint) !void {
            self.clear();
            if (self.filtered_statuses.items.len > 0) {
                try self.box.build(constraint);
                self.grid = self.box.grid;
            }
        }

        pub fn input(self: *GitStatusContent(Widget), key: inp.Key) !void {
            const diff_scroll_x = self.box.children.items[1].any.widget.git_diff.getScrollX();

            switch (self.selected) {
                .status_list => {
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
                        .status_list => {},
                        .diff => {
                            if (diff_scroll_x == 0) {
                                self.selected = .status_list;
                                self.updatePriority();
                            }
                        },
                    }
                },
                .arrow_right => {
                    switch (self.selected) {
                        .status_list => {
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
                                .status_list => {
                                    self.selected = .diff;
                                    self.updatePriority();
                                },
                                .diff => {},
                            }
                        },
                        127, '\x1B' => {
                            switch (self.selected) {
                                .status_list => {},
                                .diff => {
                                    self.selected = .status_list;
                                    self.updatePriority();
                                },
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }

            if (self.selected == .diff and self.box.children.items[1].any.widget.git_diff.grid == null) {
                self.selected = .status_list;
            }

            self.refresh();
        }

        pub fn clear(self: *GitStatusContent(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitStatusContent(Widget)) void {
            for (self.box.children.items) |*item| {
                switch (item.any.widget) {
                    .git_status_list => {
                        var status_list = &self.box.children.items[0].any.widget.git_status_list;
                        status_list.focused = self.selected == .status_list and self.focused;
                        status_list.refresh();
                    },
                    .git_diff => {
                        var diff = &self.box.children.items[1].any.widget.git_diff;
                        diff.focused = self.selected == .diff and self.focused;
                        diff.refresh();
                    },
                    else => {},
                }
            }
        }

        pub fn scrolledToTop(self: GitStatusContent(Widget)) bool {
            switch (self.selected) {
                .status_list => {
                    const status_list = &self.box.children.items[0].any.widget.git_status_list;
                    return status_list.selected == 0;
                },
                .diff => {
                    const diff = &self.box.children.items[1].any.widget.git_diff;
                    return diff.getScrollY() == 0;
                },
            }
        }

        fn update(self: *GitStatusContent(Widget), statuses: []Status, selected: IndexKind) !void {
            for (self.box.children.items) |*child| {
                child.any.deinit();
            }
            self.box.children.clearAndFree();

            self.filtered_statuses.clearAndFree();
            for (statuses) |status| {
                if (status.kind == selected) {
                    try self.filtered_statuses.append(status);
                }
            }

            // add status list
            {
                var status_list = try GitStatusList(Widget).init(self.allocator, self.filtered_statuses.items);
                errdefer status_list.deinit();
                try self.box.children.append(.{ .any = wgt.Any(Widget).init(.{ .git_status_list = status_list }), .rect = null, .visibility = .{ .min_size = .{ .width = 20, .height = null }, .priority = 1 } });
            }

            // add diff
            {
                var diff = try GitDiff(Widget).init(self.allocator, self.repo);
                errdefer diff.deinit();
                try self.box.children.append(.{ .any = wgt.Any(Widget).init(.{ .git_diff = diff }), .rect = null, .visibility = .{ .min_size = .{ .width = 60, .height = null }, .priority = 0 } });
            }

            try self.updateDiff();
        }

        fn updateDiff(self: *GitStatusContent(Widget)) !void {
            const status_list = &self.box.children.items[0].any.widget.git_status_list;

            if (status_list.statuses.len == 0) {
                return;
            }
            const status = status_list.statuses[status_list.selected];

            // index
            var index: ?*c.git_index = null;
            std.debug.assert(0 == c.git_repository_index(&index, self.repo));
            defer c.git_index_free(index);

            // get widget
            var diff = &self.box.children.items[1].any.widget.git_diff;
            try diff.clearDiffs();

            // status diff
            var status_diff: ?*c.git_diff = null;
            switch (status.kind) {
                .staged => {
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
                .unstaged => {
                    std.debug.assert(0 == c.git_diff_index_to_workdir(&status_diff, self.repo, index, null));
                },
                .untracked => return,
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

        fn updatePriority(self: *GitStatusContent(Widget)) void {
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

pub const IndexKind = enum {
    staged,
    unstaged,
    untracked,
};

pub const StatusKind = union(IndexKind) {
    staged: enum {
        added,
        modified,
        deleted,
    },
    unstaged: enum {
        modified,
        deleted,
    },
    untracked,
};

pub const Status = struct {
    kind: StatusKind,
    path: []const u8,
};

pub fn GitStatus(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        status_list: *c.git_status_list,
        statuses: std.ArrayList(Status),
        selected: enum { status_tabs, status_content },
        focused: bool,

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
                    try statuses.append(.{ .kind = .{ .staged = .added }, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_INDEX_MODIFIED & status_kind != 0) {
                    const old_path = entry.*.head_to_index.*.old_file.path;
                    try statuses.append(.{ .kind = .{ .staged = .modified }, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_INDEX_DELETED & status_kind != 0) {
                    const old_path = entry.*.head_to_index.*.old_file.path;
                    try statuses.append(.{ .kind = .{ .staged = .deleted }, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_WT_NEW & status_kind != 0) {
                    const old_path = entry.*.index_to_workdir.*.old_file.path;
                    try statuses.append(.{ .kind = .untracked, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_WT_MODIFIED & status_kind != 0) {
                    const old_path = entry.*.index_to_workdir.*.old_file.path;
                    try statuses.append(.{ .kind = .{ .unstaged = .modified }, .path = std.mem.sliceTo(old_path, 0) });
                }
                if (c.GIT_STATUS_WT_DELETED & status_kind != 0) {
                    const old_path = entry.*.index_to_workdir.*.old_file.path;
                    try statuses.append(.{ .kind = .{ .unstaged = .deleted }, .path = std.mem.sliceTo(old_path, 0) });
                }
            }

            // init box
            var box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer box.deinit();

            // add status tabs
            var status_tabs = try GitStatusTabs(Widget).init(allocator, statuses.items);
            errdefer status_tabs.deinit();
            try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .git_status_tabs = status_tabs }), .rect = null, .visibility = null });

            // add status content
            var status_content = try GitStatusContent(Widget).init(allocator, repo, statuses.items, status_tabs.selected);
            errdefer status_content.deinit();
            try box.children.append(.{ .any = wgt.Any(Widget).init(.{ .git_status_content = status_content }), .rect = null, .visibility = null });

            return GitStatus(Widget){
                .grid = null,
                .box = box,
                .statuses = statuses,
                .status_list = status_list.?,
                .selected = .status_tabs,
                .focused = false,
            };
        }

        pub fn deinit(self: *GitStatus(Widget)) void {
            self.box.deinit();
            self.statuses.deinit();
            c.git_status_list_free(self.status_list);
        }

        pub fn build(self: *GitStatus(Widget), constraint: layout.Constraint) !void {
            self.clear();
            try self.box.build(constraint);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitStatus(Widget), key: inp.Key) !void {
            switch (self.selected) {
                .status_tabs => {
                    const status_tabs = &self.box.children.items[0].any.widget.git_status_tabs;
                    if (key == .arrow_down) {
                        self.selected = .status_content;
                    } else {
                        try status_tabs.input(key);

                        var status_content = &self.box.children.items[1].any.widget.git_status_content;
                        try status_content.update(self.statuses.items, status_tabs.selected);
                    }
                },
                .status_content => {
                    const status_content = &self.box.children.items[1].any.widget.git_status_content;
                    if (key == .arrow_up and status_content.scrolledToTop()) {
                        self.selected = .status_tabs;
                    } else {
                        try status_content.input(key);
                    }
                },
            }

            if (self.selected == .status_content and self.box.children.items[1].any.widget.git_status_content.grid == null) {
                self.selected = .status_tabs;
            }

            self.refresh();
        }

        pub fn clear(self: *GitStatus(Widget)) void {
            self.grid = null;
        }

        pub fn refresh(self: *GitStatus(Widget)) void {
            for (self.box.children.items) |*item| {
                switch (item.any.widget) {
                    .git_status_tabs => {
                        var status_tabs = &item.any.widget.git_status_tabs;
                        status_tabs.focused = self.selected == .status_tabs and self.focused;
                        status_tabs.refresh();
                    },
                    .git_status_content => {
                        var status_content = &item.any.widget.git_status_content;
                        status_content.focused = self.selected == .status_content and self.focused;
                        status_content.refresh();
                    },
                    else => {},
                }
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

        pub fn build(self: *GitUITabs(Widget), constraint: layout.Constraint) !void {
            self.clear();
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

        pub fn build(self: *GitUIStack(Widget), constraint: layout.Constraint) !void {
            self.clear();
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
                    var git_status = try GitStatus(Widget).init(allocator, repo);
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

        pub fn build(self: *GitUI(Widget), constraint: layout.Constraint) !void {
            self.clear();
            try self.box.build(constraint);
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
                                    if (selected_widget.git_log.scrolledToTop()) {
                                        self.selected = .tabs;
                                    } else {
                                        try self.box.children.items[1].any.input(key);
                                    }
                                },
                                .git_status => {
                                    if (selected_widget.git_status.selected == .status_tabs) {
                                        self.selected = .tabs;
                                    } else {
                                        try self.box.children.items[1].any.input(key);
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
