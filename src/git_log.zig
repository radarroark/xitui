const std = @import("std");
const wgt = @import("./widget.zig");
const Grid = @import("./grid.zig").Grid;
const Focus = @import("./focus.zig").Focus;
const layout = @import("./layout.zig");
const inp = @import("./input.zig");
const g_diff = @import("./git_diff.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn GitCommitList(comptime Widget: type) type {
    return struct {
        scroll: wgt.Scroll(Widget),
        repo: ?*c.git_repository,
        commits: std.ArrayList(?*c.git_commit),
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
                const line = std.mem.sliceTo(std.mem.sliceTo(c.git_commit_message(commit), 0), '\n');
                var text_box = try wgt.TextBox(Widget).init(allocator, line, .hidden);
                errdefer text_box.deinit();
                text_box.getFocus().focusable = true;
                try inner_box.children.put(text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
            }

            // init scroll
            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = inner_box }, .vert);
            errdefer scroll.deinit();
            if (inner_box.children.count() > 0) {
                scroll.getFocus().child_id = inner_box.children.keys()[0];
            }

            return .{
                .scroll = scroll,
                .repo = repo,
                .commits = commits,
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
            self.clearGrid();
            const children = &self.scroll.child.box.children;
            for (children.keys(), children.values()) |id, *commit| {
                commit.widget.text_box.border_style = if (self.getFocus().child_id == id)
                    (if (self.focused) .double else .single)
                else
                    .hidden;
            }
            try self.scroll.build(constraint);
        }

        pub fn input(self: *GitCommitList(Widget), key: inp.Key) !void {
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

        pub fn clearGrid(self: *GitCommitList(Widget)) void {
            self.scroll.clearGrid();
        }

        pub fn getGrid(self: GitCommitList(Widget)) ?Grid {
            return self.scroll.getGrid();
        }

        pub fn getFocus(self: *GitCommitList(Widget)) *Focus {
            return self.scroll.getFocus();
        }

        pub fn getSelectedIndex(self: GitCommitList(Widget)) ?usize {
            if (self.scroll.child.box.focus.child_id) |child_id| {
                const children = &self.scroll.child.box.children;
                return children.getIndex(child_id);
            } else {
                return null;
            }
        }

        fn updateScroll(self: *GitCommitList(Widget), index: usize) void {
            const left_box = &self.scroll.child.box;
            if (left_box.children.values()[index].rect) |rect| {
                self.scroll.scrollToRect(rect);
            }
        }
    };
}

pub fn GitLog(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),
        repo: ?*c.git_repository,
        focused: bool,

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitLog(Widget) {
            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();

            // add commit list
            {
                var commit_list = try GitCommitList(Widget).init(allocator, repo);
                errdefer commit_list.deinit();
                try box.children.put(commit_list.getFocus().id, .{ .widget = .{ .git_commit_list = commit_list }, .rect = null, .min_size = .{ .width = 30, .height = null } });
            }

            // add diff
            {
                var diff = try g_diff.GitDiff(Widget).init(allocator, repo);
                errdefer diff.deinit();
                diff.getFocus().focusable = true;
                try box.children.put(diff.getFocus().id, .{ .widget = .{ .git_diff = diff }, .rect = null, .min_size = .{ .width = 60, .height = null } });
            }

            var git_log = GitLog(Widget){
                .box = box,
                .repo = repo,
                .focused = false,
            };
            git_log.getFocus().child_id = box.children.keys()[0];
            try git_log.updateDiff();

            return git_log;
        }

        pub fn deinit(self: *GitLog(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitLog(Widget), constraint: layout.Constraint) !void {
            self.clearGrid();
            for (self.box.children.values()) |*child| {
                switch (child.widget) {
                    .git_commit_list => {
                        child.widget.git_commit_list.focused = (self.getFocus().child_id == child.widget.getFocus().id) and self.focused;
                    },
                    .git_diff => {
                        child.widget.git_diff.focused = (self.getFocus().child_id == child.widget.getFocus().id) and self.focused;
                    },
                    else => {},
                }
            }
            try self.box.build(constraint);
        }

        pub fn input(self: *GitLog(Widget), key: inp.Key) !void {
            const diff_scroll_x = self.box.children.values()[1].widget.git_diff.box.children.values()[0].widget.scroll.x;

            if (self.getFocus().child_id) |child_id| {
                if (self.box.children.getIndex(child_id)) |current_index| {
                    const child = &self.box.children.values()[current_index].widget;

                    const index = blk: {
                        switch (key) {
                            .arrow_left => {
                                if (child.* == .git_diff and diff_scroll_x == 0) {
                                    break :blk 0;
                                }
                            },
                            .arrow_right => {
                                if (child.* == .git_commit_list) {
                                    break :blk 1;
                                }
                            },
                            .codepoint => {
                                switch (key.codepoint) {
                                    13 => {
                                        if (child.* == .git_commit_list) {
                                            break :blk 1;
                                        }
                                    },
                                    127, '\x1B' => {
                                        if (child.* == .git_diff) {
                                            break :blk 0;
                                        }
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                        try child.input(key);
                        if (child.* == .git_commit_list) {
                            try self.updateDiff();
                        }
                        break :blk current_index;
                    };

                    if (index != current_index) {
                        self.getFocus().child_id = self.box.children.keys()[index];
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitLog(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitLog(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitLog(Widget)) *Focus {
            return self.box.getFocus();
        }

        pub fn scrolledToTop(self: GitLog(Widget)) bool {
            if (self.box.focus.child_id) |child_id| {
                if (self.box.children.getIndex(child_id)) |current_index| {
                    const child = &self.box.children.values()[current_index].widget;
                    switch (child.*) {
                        .git_commit_list => {
                            const commit_list = &child.git_commit_list;
                            if (commit_list.getSelectedIndex()) |commit_index| {
                                return commit_index == 0;
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

        fn updateDiff(self: *GitLog(Widget)) !void {
            const commit_list = &self.box.children.values()[0].widget.git_commit_list;
            if (commit_list.getSelectedIndex()) |commit_index| {
                const commit = commit_list.commits.items[commit_index];

                const commit_oid = c.git_commit_tree_id(commit);
                var commit_tree: ?*c.git_tree = null;
                std.debug.assert(0 == c.git_tree_lookup(&commit_tree, self.repo, commit_oid));
                defer c.git_tree_free(commit_tree);

                var prev_commit_tree: ?*c.git_tree = null;

                if (commit_index < commit_list.commits.items.len - 1) {
                    const prev_commit = commit_list.commits.items[commit_index + 1];
                    const prev_commit_oid = c.git_commit_tree_id(prev_commit);
                    std.debug.assert(0 == c.git_tree_lookup(&prev_commit_tree, self.repo, prev_commit_oid));
                }
                defer if (prev_commit_tree) |ptr| c.git_tree_free(ptr);

                var commit_diff: ?*c.git_diff = null;
                std.debug.assert(0 == c.git_diff_tree_to_tree(&commit_diff, self.repo, prev_commit_tree, commit_tree, null));
                defer c.git_diff_free(commit_diff);

                var diff = &self.box.children.values()[1].widget.git_diff;
                try diff.clearDiffs();

                const delta_count = c.git_diff_num_deltas(commit_diff);
                for (0..delta_count) |delta_index| {
                    var patch: ?*c.git_patch = null;
                    std.debug.assert(0 == c.git_patch_from_diff(&patch, commit_diff, delta_index));
                    defer c.git_patch_free(patch);
                    try diff.addDiff(patch);
                }
            }
        }
    };
}
