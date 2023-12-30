const std = @import("std");
const wgt = @import("./widget.zig");
const grd = @import("./grid.zig");
const layout = @import("./layout.zig");
const inp = @import("./input.zig");
const g_diff = @import("./git_diff.zig");

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
                try inner_box.children.append(.{ .widget = .{ .text_box = text_box }, .rect = null, .visibility = null });
            }

            // init scroll
            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = inner_box }, .vert);
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
            for (self.scroll.child.box.children.items, 0..) |*commit, i| {
                commit.widget.text_box.border_style = if (self.selected == i)
                    (if (self.focused) .double else .single)
                else
                    .hidden;
            }
        }

        fn updateScroll(self: *GitCommitList(Widget)) void {
            const left_box = &self.scroll.child.box;
            if (left_box.children.items.len > self.selected) {
                if (left_box.children.items[self.selected].rect) |rect| {
                    self.scroll.scrollToRect(rect);
                }
            }
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
                try box.children.append(.{ .widget = .{ .git_commit_list = commit_list }, .rect = null, .visibility = .{ .min_size = .{ .width = 30, .height = null }, .priority = 1 } });
            }

            // add diff
            {
                var diff = try g_diff.GitDiff(Widget).init(allocator, repo);
                errdefer diff.deinit();
                try box.children.append(.{ .widget = .{ .git_diff = diff }, .rect = null, .visibility = .{ .min_size = .{ .width = 60, .height = null }, .priority = 0 } });
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
            const diff_scroll_x = self.box.children.items[1].widget.git_diff.box.children.items[0].widget.scroll.x;

            switch (self.selected) {
                .commit_list => {
                    try self.box.children.items[0].widget.input(key);
                    try self.updateDiff();
                },
                .diff => {
                    try self.box.children.items[1].widget.input(key);
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
                    var commit_list = &self.box.children.items[0].widget.git_commit_list;
                    commit_list.focused = self.focused;
                    commit_list.refresh();
                    var diff = &self.box.children.items[1].widget.git_diff;
                    diff.focused = false;
                    diff.refresh();
                },
                .diff => {
                    var commit_list = &self.box.children.items[0].widget.git_commit_list;
                    commit_list.focused = false;
                    commit_list.refresh();
                    var diff = &self.box.children.items[1].widget.git_diff;
                    diff.focused = self.focused;
                    diff.refresh();
                },
            }
        }

        pub fn scrolledToTop(self: GitLog(Widget)) bool {
            switch (self.selected) {
                .commit_list => {
                    const commit_list = &self.box.children.items[0].widget.git_commit_list;
                    return commit_list.selected == 0;
                },
                .diff => {
                    const diff = &self.box.children.items[1].widget.git_diff;
                    return diff.getScrollY() == 0;
                },
            }
        }

        fn updateDiff(self: *GitLog(Widget)) !void {
            const commit_list = &self.box.children.items[0].widget.git_commit_list;

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

            var diff = &self.box.children.items[1].widget.git_diff;
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
