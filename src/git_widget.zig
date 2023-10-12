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
        allocator: std.mem.Allocator,
        repo: ?*c.git_repository,
        commits: std.ArrayList(?*c.git_commit),
        commit_index: usize = 0,
        scroll: wgt.Scroll(Widget),

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
                var text_box = try wgt.TextBox(Widget).init(allocator, line, .single);
                errdefer text_box.deinit();
                try inner_box.children.append(.{ .any = wgt.Any(Widget).init(.{ .text_box = text_box }), .rect = null, .visibility = null });
            }

            // init scroll
            var scroll = try wgt.Scroll(Widget).init(allocator, wgt.Any(Widget).init(.{ .box = inner_box }), .vert);
            errdefer scroll.deinit();

            return .{
                .grid = null,
                .allocator = allocator,
                .repo = repo,
                .commits = commits,
                .commit_index = 0,
                .scroll = scroll,
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
                    self.commit_index -|= 1;
                    self.updateScroll();
                },
                .arrow_down => {
                    if (self.commit_index + 1 < self.commits.items.len) {
                        self.commit_index += 1;
                        self.updateScroll();
                    }
                },
                .home => {
                    self.commit_index = 0;
                    self.updateScroll();
                },
                .end => {
                    if (self.commits.items.len > 0) {
                        self.commit_index = self.commits.items.len - 1;
                        self.updateScroll();
                    }
                },
                .page_up => {
                    if (self.grid) |grid| {
                        const half_count = (grid.size.height / 3) / 2;
                        self.commit_index -|= half_count;
                        self.updateScroll();
                    }
                },
                .page_down => {
                    if (self.grid) |grid| {
                        if (self.commits.items.len > 0) {
                            const half_count = (grid.size.height / 3) / 2;
                            self.commit_index = @min(self.commit_index + half_count, self.commits.items.len - 1);
                            self.updateScroll();
                        }
                    }
                },
                else => {},
            }
        }

        pub fn clear(self: *GitCommitList(Widget)) void {
            self.grid = null;
        }

        fn updateScroll(self: *GitCommitList(Widget)) void {
            var left_box = &self.scroll.child.widget.box;
            if (left_box.children.items.len > self.commit_index) {
                if (left_box.children.items[self.commit_index].rect) |rect| {
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

pub fn GitInfo(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        allocator: std.mem.Allocator,
        repo: ?*c.git_repository,
        page: union(enum) { commit_list, diff },

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitInfo(Widget) {
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

            var git_info = GitInfo(Widget){
                .grid = null,
                .box = box,
                .allocator = allocator,
                .repo = repo,
                .page = .commit_list,
            };
            try git_info.updateDiff();

            return git_info;
        }

        pub fn deinit(self: *GitInfo(Widget)) void {
            self.box.deinit();
        }

        pub fn build(self: *GitInfo(Widget), max_size: MaybeSize) !void {
            self.clear();

            switch (self.page) {
                .commit_list => {
                    var commit_list = &self.box.children.items[0].any.widget.git_commit_list;
                    for (commit_list.scroll.child.widget.box.children.items, 0..) |*commit, i| {
                        commit.any.widget.text_box.border_style = if (commit_list.commit_index == i) .double else .hidden;
                    }
                    var diff = &self.box.children.items[1].any.widget.git_diff;
                    diff.box.border_style = .hidden;
                },
                .diff => {
                    var commit_list = &self.box.children.items[0].any.widget.git_commit_list;
                    for (commit_list.scroll.child.widget.box.children.items, 0..) |*commit, i| {
                        commit.any.widget.text_box.border_style = if (commit_list.commit_index == i) .single else .hidden;
                    }
                    var diff = &self.box.children.items[1].any.widget.git_diff;
                    diff.box.border_style = .double;
                },
            }

            try self.box.build(max_size);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitInfo(Widget), key: inp.Key) !void {
            switch (self.page) {
                .commit_list => {
                    try self.box.children.items[0].any.input(key);
                    try self.updateDiff();
                },
                .diff => {
                    try self.box.children.items[1].any.input(key);
                },
            }

            switch (key) {
                .codepoint => {
                    switch (key.codepoint) {
                        13 => {
                            switch (self.page) {
                                .commit_list => {
                                    self.page = .diff;
                                    self.updatePriority();
                                },
                                .diff => {},
                            }
                        },
                        127 => {
                            switch (self.page) {
                                .commit_list => {},
                                .diff => {
                                    self.page = .commit_list;
                                    self.updatePriority();
                                },
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        pub fn clear(self: *GitInfo(Widget)) void {
            self.grid = null;
        }

        fn updateDiff(self: *GitInfo(Widget)) !void {
            const commit_list = &self.box.children.items[0].any.widget.git_commit_list;

            const commit = commit_list.commits.items[commit_list.commit_index];

            const commit_oid = c.git_commit_tree_id(commit);
            var commit_tree: ?*c.git_tree = null;
            std.debug.assert(0 == c.git_tree_lookup(&commit_tree, self.repo, commit_oid));
            defer c.git_tree_free(commit_tree);

            var prev_commit_tree: ?*c.git_tree = null;

            if (commit_list.commit_index < commit_list.commits.items.len - 1) {
                const prev_commit = commit_list.commits.items[commit_list.commit_index + 1];
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

        fn updatePriority(self: *GitInfo(Widget)) void {
            const page_index = @intFromEnum(self.page);
            for (self.box.children.items, 0..) |*child, i| {
                if (child.visibility) |*vis| {
                    const ii: isize = @intCast(i);
                    vis.priority = if (ii <= page_index) ii else -ii;
                }
            }
        }
    };
}
