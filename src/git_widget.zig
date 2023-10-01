const std = @import("std");
const term = @import("./terminal.zig");
const wgt = @import("./widget.zig");
const grd = @import("./grid.zig");
const MaxSize = @import("./layout.zig").MaxSize;
const inp = @import("./input.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn GitInfo(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: wgt.Box(Widget),
        allocator: std.mem.Allocator,
        repo: ?*c.git_repository,
        bufs: std.ArrayList(c.git_buf),
        commits: std.ArrayList(?*c.git_commit),
        commit_index: usize = 0,
        page: union(enum) { commit_list, diff },

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitInfo(Widget) {
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

            // init left_box
            var left_box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer left_box.deinit();
            for (commits.items) |commit| {
                const line = std.mem.sliceTo(c.git_commit_message(commit), '\n');
                var text_box = try wgt.TextBox(Widget).init(allocator, line, .single);
                errdefer text_box.deinit();
                try left_box.children.append(wgt.Any(Widget).init(.{ .text_box = text_box }));
            }
            const size_fn = struct {
                fn size(max_size: MaxSize) MaxSize {
                    return .{
                        .width = if (max_size.width) |width| width / 2 else null,
                        .height = max_size.height,
                    };
                }
            }.size;

            // init left_scroll
            var left_scroll = try wgt.Scroll(Widget).init(allocator, wgt.Any(Widget).initWithSizeFn(.{ .box = left_box }, size_fn), .vert);
            errdefer left_scroll.deinit();

            // init right_box
            var right_box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer right_box.deinit();

            // init right_scroll
            var right_scroll = try wgt.Scroll(Widget).init(allocator, wgt.Any(Widget).init(.{ .box = right_box }), .vert);
            errdefer right_scroll.deinit();

            // init right_outer_box
            var right_outer_box = try wgt.Box(Widget).init(allocator, null, .vert);
            errdefer right_outer_box.deinit();
            try right_outer_box.children.append(wgt.Any(Widget).init(.{ .scroll = right_scroll }));

            // init box
            var box = try wgt.Box(Widget).init(allocator, null, .horiz);
            errdefer box.deinit();
            try box.children.append(wgt.Any(Widget).init(.{ .scroll = left_scroll }));
            try box.children.append(wgt.Any(Widget).init(.{ .box = right_outer_box }));

            var git_info = GitInfo(Widget){
                .grid = null,
                .box = box,
                .allocator = allocator,
                .repo = repo,
                .bufs = std.ArrayList(c.git_buf).init(allocator),
                .commits = commits,
                .commit_index = 0,
                .page = .commit_list,
            };
            try git_info.updateDiff();

            return git_info;
        }

        pub fn deinit(self: *GitInfo(Widget)) void {
            for (self.commits.items) |commit| {
                c.git_commit_free(commit);
            }
            self.commits.deinit();
            for (self.bufs.items) |*buf| {
                c.git_buf_dispose(buf);
            }
            self.bufs.deinit();
            self.box.deinit();
        }

        pub fn build(self: *GitInfo(Widget), max_size: MaxSize) !void {
            switch (self.page) {
                .commit_list => {
                    for (self.box.children.items[0].widget.scroll.child.widget.box.children.items, 0..) |*commit, i| {
                        commit.widget.text_box.border_style = if (self.commit_index == i) .double else .single;
                    }
                    self.box.children.items[1].widget.box.border_style = .hidden;
                },
                .diff => {
                    for (self.box.children.items[0].widget.scroll.child.widget.box.children.items, 0..) |*commit, i| {
                        commit.widget.text_box.border_style = if (self.commit_index == i) .single else .hidden;
                    }
                    self.box.children.items[1].widget.box.border_style = .double;
                },
            }

            try self.box.build(max_size);
            self.grid = self.box.grid;
        }

        pub fn input(self: *GitInfo(Widget), key: inp.Key) !void {
            switch (key) {
                .arrow_up => {
                    switch (self.page) {
                        .commit_list => {
                            self.commit_index -|= 1;
                            self.updateScroll();
                            try self.updateDiff();
                        },
                        .diff => {
                            if (self.box.children.items[1].widget.box.children.items[0].widget.scroll.y > 0) {
                                self.box.children.items[1].widget.box.children.items[0].widget.scroll.y -= 1;
                            }
                        },
                    }
                },
                .arrow_down => {
                    switch (self.page) {
                        .commit_list => {
                            if (self.commit_index + 1 < self.commits.items.len) {
                                self.commit_index += 1;
                            }
                            self.updateScroll();
                            try self.updateDiff();
                        },
                        .diff => {
                            if (self.box.children.items[1].widget.box.grid) |outer_box_grid| {
                                const outer_box_height = outer_box_grid.size.height - 2;
                                const scroll_y = self.box.children.items[1].widget.box.children.items[0].widget.scroll.y;
                                const u_scroll_y: usize = if (scroll_y >= 0) @intCast(scroll_y) else 0;
                                if (self.box.children.items[1].widget.box.children.items[0].widget.scroll.child.widget.box.grid) |inner_box_grid| {
                                    const inner_box_height = inner_box_grid.size.height;
                                    if (outer_box_height + u_scroll_y < inner_box_height) {
                                        self.box.children.items[1].widget.box.children.items[0].widget.scroll.y += 1;
                                    }
                                }
                            }
                        },
                    }
                },
                .arrow_right => {
                    switch (self.page) {
                        .commit_list => {
                            self.page = .diff;
                        },
                        .diff => {},
                    }
                },
                .arrow_left => {
                    switch (self.page) {
                        .commit_list => {},
                        .diff => {
                            self.page = .commit_list;
                        },
                    }
                },
                .home => {
                    switch (self.page) {
                        .commit_list => {
                            self.commit_index = 0;
                            self.updateScroll();
                            try self.updateDiff();
                        },
                        .diff => {
                            self.box.children.items[1].widget.box.children.items[0].widget.scroll.y = 0;
                        },
                    }
                },
                .end => {
                    switch (self.page) {
                        .commit_list => {
                            if (self.commits.items.len > 0) {
                                self.commit_index = self.commits.items.len - 1;
                                self.updateScroll();
                                try self.updateDiff();
                            }
                        },
                        .diff => {
                            if (self.box.children.items[1].widget.box.grid) |outer_box_grid| {
                                if (self.box.children.items[1].widget.box.children.items[0].widget.scroll.child.widget.box.grid) |inner_box_grid| {
                                    const outer_box_height = outer_box_grid.size.height - 2;
                                    const inner_box_height = inner_box_grid.size.height;
                                    const max_scroll: isize = if (inner_box_height > outer_box_height) @intCast(inner_box_height - outer_box_height) else 0;
                                    self.box.children.items[1].widget.box.children.items[0].widget.scroll.y = max_scroll;
                                }
                            }
                        },
                    }
                },
                .page_up => {
                    switch (self.page) {
                        .commit_list => {
                            if (self.grid) |grid| {
                                const half_count = (grid.size.height / 3) / 2;
                                self.commit_index -|= half_count;
                                self.updateScroll();
                                try self.updateDiff();
                            }
                        },
                        .diff => {
                            if (self.box.children.items[1].widget.box.grid) |outer_box_grid| {
                                const outer_box_height = outer_box_grid.size.height - 2;
                                const scroll_y = self.box.children.items[1].widget.box.children.items[0].widget.scroll.y;
                                const scroll_change: isize = @intCast(outer_box_height / 2);
                                self.box.children.items[1].widget.box.children.items[0].widget.scroll.y = @max(0, scroll_y - scroll_change);
                            }
                        },
                    }
                },
                .page_down => {
                    switch (self.page) {
                        .commit_list => {
                            if (self.grid) |grid| {
                                if (self.commits.items.len > 0) {
                                    const half_count = (grid.size.height / 3) / 2;
                                    self.commit_index = @min(self.commit_index + half_count, self.commits.items.len - 1);
                                    self.updateScroll();
                                    try self.updateDiff();
                                }
                            }
                        },
                        .diff => {
                            if (self.box.children.items[1].widget.box.grid) |outer_box_grid| {
                                if (self.box.children.items[1].widget.box.children.items[0].widget.scroll.child.widget.box.grid) |inner_box_grid| {
                                    const outer_box_height = outer_box_grid.size.height - 2;
                                    const inner_box_height = inner_box_grid.size.height;
                                    const max_scroll: isize = if (inner_box_height > outer_box_height) @intCast(inner_box_height - outer_box_height) else 0;
                                    const scroll_y = self.box.children.items[1].widget.box.children.items[0].widget.scroll.y;
                                    const scroll_change: isize = @intCast(outer_box_height / 2);
                                    self.box.children.items[1].widget.box.children.items[0].widget.scroll.y = @min(scroll_y + scroll_change, max_scroll);
                                }
                            }
                        },
                    }
                },
                else => {},
            }
        }

        fn updateScroll(self: *GitInfo(Widget)) void {
            var left_scroll = &self.box.children.items[0].widget.scroll;
            var left_box = &left_scroll.child.widget.box;
            if (left_box.child_rects.items.len > self.commit_index) {
                const rect = left_box.child_rects.items[self.commit_index];
                left_scroll.scrollToRect(rect);
            }
        }

        fn updateDiff(self: *GitInfo(Widget)) !void {
            for (self.bufs.items) |*buf| {
                c.git_buf_dispose(buf);
            }
            self.bufs.clearAndFree();

            const commit = self.commits.items[self.commit_index];

            const commit_oid = c.git_commit_tree_id(commit);
            var commit_tree: ?*c.git_tree = null;
            std.debug.assert(0 == c.git_tree_lookup(&commit_tree, self.repo, commit_oid));
            defer c.git_tree_free(commit_tree);

            var prev_commit_tree: ?*c.git_tree = null;

            if (self.commit_index < self.commits.items.len - 1) {
                const prev_commit = self.commits.items[self.commit_index + 1];
                const prev_commit_oid = c.git_commit_tree_id(prev_commit);
                std.debug.assert(0 == c.git_tree_lookup(&prev_commit_tree, self.repo, prev_commit_oid));
            }
            defer if (prev_commit_tree) |ptr| c.git_tree_free(ptr);

            var commit_diff: ?*c.git_diff = null;
            std.debug.assert(0 == c.git_diff_tree_to_tree(&commit_diff, self.repo, prev_commit_tree, commit_tree, null));
            defer c.git_diff_free(commit_diff);

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
            for (self.box.children.items[1].widget.box.children.items[0].widget.scroll.child.widget.box.children.items) |*child| {
                child.deinit();
            }
            self.box.children.items[1].widget.box.children.items[0].widget.scroll.child.widget.box.children.clearAndFree();

            // add new diff widgets
            for (self.bufs.items) |buf| {
                var text_box = try wgt.TextBox(Widget).init(self.allocator, std.mem.sliceTo(buf.ptr, 0), .hidden);
                errdefer text_box.deinit();
                try self.box.children.items[1].widget.box.children.items[0].widget.scroll.child.widget.box.children.append(wgt.Any(Widget).init(.{ .text_box = text_box }));
            }

            // reset scroll position
            self.box.children.items[1].widget.box.children.items[0].widget.scroll.y = 0;
        }
    };
}
