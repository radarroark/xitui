//! you're looking at radar's hopeless attempt to implement
//! a text UI for git. it can't possibly be worse then using
//! the git CLI, right?

const std = @import("std");
const term = @import("./terminal.zig");
const wgt = @import("./widget.zig");
const Grid = @import("./grid.zig").Grid;
const Focus = @import("./focus.zig").Focus;
const g_diff = @import("./git_diff.zig");
const g_log = @import("./git_log.zig");
const g_stat = @import("./git_status.zig");
const g_ui = @import("./git_ui.zig");
const layout = @import("./layout.zig");
const inp = @import("./input.zig");

const c = @cImport({
    @cInclude("git2.h");
});

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    scroll: wgt.Scroll(Widget),
    git_diff: g_diff.GitDiff(Widget),
    git_commit_list: g_log.GitCommitList(Widget),
    git_log: g_log.GitLog(Widget),
    git_status_tabs: g_stat.GitStatusTabs(Widget),
    git_status_list_item: g_stat.GitStatusListItem(Widget),
    git_status_list: g_stat.GitStatusList(Widget),
    git_status_content: g_stat.GitStatusContent(Widget),
    git_status: g_stat.GitStatus(Widget),
    git_ui_tabs: g_ui.GitUITabs(Widget),
    git_ui_stack: g_ui.GitUIStack(Widget),
    git_ui: g_ui.GitUI(Widget),

    pub fn deinit(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }

    pub fn build(self: *Widget, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, key: inp.Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(key, root_focus),
        }
    }

    pub fn clearGrid(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.clearGrid(),
        }
    }

    pub fn getGrid(self: Widget) ?Grid {
        switch (self) {
            inline else => |*case| return case.getGrid(),
        }
    }

    pub fn getFocus(self: *Widget) *Focus {
        switch (self.*) {
            inline else => |*case| return case.getFocus(),
        }
    }
};

fn tick(allocator: std.mem.Allocator, root: *Widget, last_grid_maybe: *?Grid, last_size: *layout.Size) !void {
    const root_size = layout.Size{ .width = term.terminal.size.width, .height = term.terminal.size.height };
    if (root_size.width == 0 or root_size.height == 0) {
        return;
    }

    if (last_grid_maybe.*) |*last_grid| {
        var force_refresh = false;
        if (last_size.*.width != root_size.width or last_size.*.height != root_size.height) {
            force_refresh = true;
        } else if (root.getGrid()) |grid| {
            if (last_grid.size.width != grid.size.width or last_grid.size.height != grid.size.height) {
                force_refresh = true;
            }
        }
        if (force_refresh) {
            last_grid.deinit();
            last_grid_maybe.* = null;
        }
    }

    if (last_grid_maybe.*) |last_grid| {
        if (root.getGrid()) |grid| {
            // clear cells that are in last grid but not current grid
            for (0..last_grid.size.height) |y| {
                for (0..last_grid.size.width) |x| {
                    if (grid.cells.items[try grid.cells.at(.{ y, x })].rune == null) {
                        try term.terminal.write(" ", x, y);
                    }
                }
            }
            // render current grid
            for (0..grid.size.height) |y| {
                for (0..grid.size.width) |x| {
                    if (grid.cells.items[try grid.cells.at(.{ y, x })].rune) |rune| {
                        try term.terminal.write(rune, x, y);
                    }
                }
            }
        }
    } else {
        try root.build(.{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = root_size.width, .height = root_size.height },
        }, root.getFocus());
        try term.clearRect(term.terminal.tty.writer(), 0, 0, root_size);
        last_size.* = root_size;

        if (root.getGrid()) |grid| {
            last_grid_maybe.* = try Grid.initFromGrid(allocator, grid, grid.size, 0, 0);
            for (0..grid.size.height) |y| {
                for (0..grid.size.width) |x| {
                    if (grid.cells.items[try grid.cells.at(.{ y, x })].rune) |rune| {
                        try term.terminal.write(rune, x, y);
                    }
                }
            }
        }
    }

    const buffer_size = 32;
    var buffer: [buffer_size]u8 = undefined;
    const size = try term.terminal.tty.read(&buffer);
    var esc = try std.ArrayList(u8).initCapacity(allocator, buffer_size);
    defer esc.deinit();

    if (size > 0) {
        const text = std.unicode.Utf8View.init(buffer[0..size]) catch return;
        var iter = text.iterator();
        while (iter.nextCodepoint()) |codepoint| {
            const next_bytes = iter.peek(1);
            if (try inp.Key.init(codepoint, if (next_bytes.len == 1) next_bytes[0] else null, &esc)) |key| {
                try root.input(key, root.getFocus());
            }
        }
        try root.build(.{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = root_size.width, .height = root_size.height },
        }, root.getFocus());
    }
}

pub fn main() !void {
    // start libgit
    _ = c.git_libgit2_init();
    defer _ = c.git_libgit2_shutdown();

    // find cwd
    var cwd_path_buffer = [_]u8{0} ** std.fs.MAX_PATH_BYTES;
    const cwd_path: [*c]const u8 = @ptrCast(try std.fs.cwd().realpath(".", &cwd_path_buffer));

    // init repo
    var repo: ?*c.git_repository = null;
    std.debug.assert(0 == c.git_repository_init(&repo, cwd_path, 0));
    defer c.git_repository_free(repo);

    // init root widget
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var root = Widget{ .git_ui = try g_ui.GitUI(Widget).init(allocator, repo) };
    defer root.deinit();

    // init term
    term.terminal = try term.Terminal.init();
    defer term.terminal.deinit();
    try term.setNonBlocking();

    var last_grid_maybe: ?Grid = null;
    defer if (last_grid_maybe) |*last_grid| last_grid.deinit();
    var last_size = layout.Size{ .width = 0, .height = 0 };

    while (true) {
        tick(allocator, &root, &last_grid_maybe, &last_size) catch |err| {
            switch (err) {
                error.TerminalQuit => break,
                else => return err,
            }
        };
        std.time.sleep(5000000); // TODO: do variable sleep with target frame rate
    }
}
