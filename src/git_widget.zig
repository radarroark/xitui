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
        box_wgt: wgt.Box(Widget),
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

            // init commit_wgts
            var commit_wgts = std.ArrayList(wgt.Any(Widget)).init(allocator);
            defer commit_wgts.deinit();
            for (commits.items) |commit| {
                const line = std.mem.sliceTo(c.git_commit_message(commit), '\n');
                var text_box = try wgt.TextBox(Widget).init(allocator, line, .single);
                errdefer text_box.deinit();
                try commit_wgts.append(wgt.Any(Widget){ .widget = .{ .text_box = text_box } });
            }

            // init left_scroll_wgt
            var left_box = try wgt.Box(Widget).init(allocator, commit_wgts.items, null, .vert);
            errdefer left_box.deinit();
            var left_scroll_wgt = try wgt.Scroll(Widget).init(allocator, wgt.Any(Widget){ .widget = .{ .box = left_box } }, .vert);
            errdefer left_scroll_wgt.deinit();

            // init right_box_wgt
            var right_box_wgt = try wgt.Box(Widget).init(allocator, &[_]wgt.Any(Widget){}, null, .vert);
            errdefer right_box_wgt.deinit();

            // init box_wgt
            var box_contents = [_]wgt.Any(Widget){ wgt.Any(Widget){ .widget = .{ .scroll = left_scroll_wgt } }, wgt.Any(Widget){ .widget = .{ .box = right_box_wgt } } };
            var box_wgt = try wgt.Box(Widget).init(allocator, &box_contents, null, .horiz);
            errdefer box_wgt.deinit();

            var git_info = GitInfo(Widget){
                .grid = null,
                .box_wgt = box_wgt,
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
            self.box_wgt.deinit();
        }

        pub fn build(self: *GitInfo(Widget), max_size: MaxSize) !void {
            for (self.box_wgt.children.items[0].widget.scroll.child.widget.box.children.items, 0..) |*commit_wgt, i| {
                commit_wgt.widget.text_box.border_style = if (self.index == i) .double else .single;
            }

            try self.box_wgt.build(max_size);
            self.grid = self.box_wgt.grid;
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
                    self.box_wgt.children.items[0].widget.scroll.y += 1;
                } else if (std.mem.eql(u8, esc_slice, "[D")) {
                    self.box_wgt.children.items[0].widget.scroll.y -= 1;
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

            // remove old diff widgets
            for (self.box_wgt.children.items[1].widget.box.children.items) |*child| {
                child.deinit();
            }
            self.box_wgt.children.items[1].widget.box.children.clearAndFree();

            // add new diff widgets
            for (self.bufs.items) |buf| {
                var text_box = try wgt.TextBox(Widget).init(self.allocator, std.mem.sliceTo(buf.ptr, 0), .hidden);
                errdefer text_box.deinit();
                try self.box_wgt.children.items[1].widget.box.children.append(wgt.Any(Widget){ .widget = .{ .text_box = text_box } });
            }
        }
    };
}
