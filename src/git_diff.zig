const std = @import("std");
const wgt = @import("./widget.zig");
const grd = @import("./grid.zig");
const layout = @import("./layout.zig");
const inp = @import("./input.zig");

const c = @cImport({
    @cInclude("git2.h");
});

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
