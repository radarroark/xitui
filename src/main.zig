//! you're looking at radar's hopeless attempt to implement
//! a text UI for git. it can't possibly be worse then using
//! the git CLI, right?

const std = @import("std");
const term = @import("./terminal.zig");
const wgt = @import("./widget.zig");
const grd = @import("./grid.zig");
const git_wgt = @import("./git_widget.zig");
const Size = @import("./layout.zig").Size;
const inp = @import("./input.zig");

const c = @cImport({
    @cInclude("git2.h");
});

const Widget = union(enum) {
    text: wgt.Text,
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    scroll: wgt.Scroll(Widget),
    git_info: git_wgt.GitInfo(Widget),
};

var root: wgt.Any(Widget) = undefined;

fn tick(allocator: std.mem.Allocator, last_grid_maybe: *?grd.Grid, last_size: *Size) !void {
    const root_size = Size{ .width = term.terminal.size.width, .height = term.terminal.size.height };
    if (root_size.width == 0 or root_size.height == 0) {
        return;
    }

    if (last_grid_maybe.*) |*last_grid| {
        var force_refresh = false;
        if (last_size.*.width != root_size.width or last_size.*.height != root_size.height) {
            force_refresh = true;
        } else if (root.grid()) |grid| {
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
        if (root.grid()) |grid| {
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
        try root.build(.{ .width = root_size.width, .height = root_size.height });
        try term.clearRect(term.terminal.tty.writer(), 0, 0, root_size);
        last_size.* = root_size;

        if (root.grid()) |grid| {
            last_grid_maybe.* = try grd.Grid.initFromGrid(allocator, grid, grid.size, 0, 0);
            for (0..grid.size.height) |y| {
                for (0..grid.size.width) |x| {
                    if (grid.cells.items[try grid.cells.at(.{ y, x })].rune) |rune| {
                        try term.terminal.write(rune, x, y);
                    }
                }
            }
        }
    }

    var buffer: [32]u8 = undefined;
    const size = try term.terminal.tty.read(&buffer);
    var esc = std.ArrayList(u8).init(allocator);
    defer esc.deinit();

    if (size > 0) {
        const text = std.unicode.Utf8View.init(buffer[0..size]) catch return;
        var iter = text.iterator();
        while (iter.nextCodepoint()) |codepoint| {
            if (try inp.Key.init(codepoint, &esc)) |key| {
                try root.input(key);
            }
        }
        try root.build(.{ .width = root_size.width, .height = root_size.height });
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
    root = wgt.Any(Widget).init(.{ .git_info = try git_wgt.GitInfo(Widget).init(allocator, repo) });
    defer root.deinit();

    // init term
    term.terminal = try term.Terminal.init();
    defer term.terminal.deinit();
    try term.setNonBlocking();

    var last_grid_maybe: ?grd.Grid = null;
    defer if (last_grid_maybe) |*last_grid| last_grid.deinit();
    var last_size = Size{ .width = 0, .height = 0 };

    while (true) {
        tick(allocator, &last_grid_maybe, &last_size) catch |err| {
            switch (err) {
                error.TerminalQuit => break,
                else => return err,
            }
        };
        std.time.sleep(5000000); // TODO: do variable sleep with target frame rate
    }
}
