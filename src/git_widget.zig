const std = @import("std");
const term = @import("./terminal.zig");
const wgt = @import("./widget.zig");
const grd = @import("./grid.zig");
const MaxSize = @import("./common.zig").MaxSize;

const c = @cImport({
    @cInclude("git2.h");
});

pub fn GitInfo(comptime Widget: type) type {
    return struct {
        grid: ?grd.Grid,
        box: ?wgt.Box(Widget),
        allocator: std.mem.Allocator,
        repo: ?*c.git_repository,
        commits: std.ArrayList(?*c.git_commit),
        index: u32 = 0,
        bufs: std.ArrayList(c.git_buf),

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository, index: u32) !GitInfo(Widget) {
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

            var git_info = GitInfo(Widget){
                .grid = null,
                .box = null,
                .allocator = allocator,
                .repo = repo,
                .commits = commits,
                .index = index,
                .bufs = std.ArrayList(c.git_buf).init(allocator),
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
        }

        pub fn build(self: *GitInfo(Widget), max_size: MaxSize) !void {
            const old_box_maybe = self.box;
            self.box = null;
            self.grid = null;

            var commits = std.ArrayList(wgt.Any(Widget)).init(self.allocator);
            defer commits.deinit();
            for (self.commits.items, 0..) |commit, i| {
                const line = std.mem.sliceTo(c.git_commit_message(commit), '\n');
                var text_box = try wgt.TextBox(Widget).init(self.allocator, line, if (self.index == i) .double else .single);
                errdefer text_box.deinit();
                try commits.append(wgt.Any(Widget){ .widget = .{ .text_box = text_box } });
            }
            const left_box = try wgt.Box(Widget).init(self.allocator, commits.items, null, .vert);
            var left_scroll = try wgt.Scroll(Widget).init(self.allocator, wgt.Any(Widget){ .widget = .{ .box = left_box } }, .vert);
            // manually get the old scroll position
            // TODO: we won't have to do this once we have stateful widgets
            if (old_box_maybe) |old_box| {
                const old_scroll = old_box.children.items[0].widget.scroll;
                left_scroll.x = old_scroll.x;
                left_scroll.y = old_scroll.y;
            }

            var diffs = std.ArrayList(wgt.Any(Widget)).init(self.allocator);
            defer diffs.deinit();
            for (self.bufs.items) |buf| {
                var text_box = try wgt.TextBox(Widget).init(self.allocator, std.mem.sliceTo(buf.ptr, 0), .hidden);
                errdefer text_box.deinit();
                try diffs.append(wgt.Any(Widget){ .widget = .{ .text_box = text_box } });
            }
            const right_box = try wgt.Box(Widget).init(self.allocator, diffs.items, null, .vert);

            var box_contents = [_]wgt.Any(Widget){ wgt.Any(Widget){ .widget = .{ .scroll = left_scroll } }, wgt.Any(Widget){ .widget = .{ .box = right_box } } };
            var box = try wgt.Box(Widget).init(self.allocator, &box_contents, null, .horiz);
            errdefer box.deinit();

            try box.build(max_size);
            self.box = box;
            self.grid = box.grid;
        }

        pub fn input(self: *GitInfo(Widget), byte: u8) !void {
            if (byte == '\x1B') {
                var esc_buffer: [8]u8 = undefined;
                const esc_read = try term.terminal.tty.read(&esc_buffer);
                const esc_slice = esc_buffer[0..esc_read];

                if (std.mem.eql(u8, esc_slice, "[A")) {
                    self.index -|= 1;
                } else if (std.mem.eql(u8, esc_slice, "[B")) {
                    if (self.index + 1 < self.commits.items.len) {
                        self.index += 1;
                    }
                } else if (std.mem.eql(u8, esc_slice, "[C")) {
                    if (self.box) |box| {
                        box.children.items[0].widget.scroll.y += 1;
                    }
                } else if (std.mem.eql(u8, esc_slice, "[D")) {
                    if (self.box) |box| {
                        box.children.items[0].widget.scroll.y -|= 1;
                    }
                }

                try self.updateDiff();
            }
        }

        fn updateDiff(self: *GitInfo(Widget)) !void {
            for (self.bufs.items) |*buf| {
                c.git_buf_dispose(buf);
            }
            self.bufs.clearAndFree();

            const commit = self.commits.items[self.index];

            const commit_oid = c.git_commit_tree_id(commit);
            var commit_tree: ?*c.git_tree = null;
            std.debug.assert(0 == c.git_tree_lookup(&commit_tree, self.repo, commit_oid));
            defer c.git_tree_free(commit_tree);

            var prev_commit_tree: ?*c.git_tree = null;

            if (self.index < self.commits.items.len - 1) {
                const prev_commit = self.commits.items[self.index + 1];
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
        }
    };
}
