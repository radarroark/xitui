//! you're looking at radar's hopeless attempt to implement
//! a text UI for git. it can't possibly be worse then using
//! the git CLI, right?

const std = @import("std");
const builtin = @import("builtin");
const system = switch (builtin.os.tag) {
    .linux => std.os.linux,
    .wasi => std.os.wasi,
    .uefi => std.os.uefi,
    else => std.os.system,
};

const c = @cImport({
    @cInclude("git2.h");
});
const NDSlice = @import("./ndslice.zig").NDSlice;

fn handleSigWinch(_: c_int) callconv(.C) void {
    term.updateSize() catch return;
}

const Size = struct { width: usize, height: usize };

pub const Terminal = struct {
    tty: std.fs.File,
    cooked_termios: std.os.termios = undefined,
    raw: std.os.termios = undefined,
    size: Size = undefined,

    pub fn init() !Terminal {
        var tty = try std.fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
        errdefer tty.close();

        var self = Terminal{
            .tty = tty,
        };

        try self.uncook();

        try self.updateSize();

        try std.os.sigaction(std.os.SIG.WINCH, &std.os.Sigaction{
            .handler = .{ .handler = handleSigWinch },
            .mask = std.os.empty_sigset,
            .flags = 0,
        }, null);

        return self;
    }

    pub fn deinit(self: *Terminal) void {
        self.cook() catch {};
        self.tty.close();
    }

    pub fn updateSize(self: *Terminal) !void {
        var win_size = std.mem.zeroes(system.winsize);
        const err = system.ioctl(term.tty.handle, system.T.IOCGWINSZ, @ptrToInt(&win_size));
        if (std.os.errno(err) != .SUCCESS) {
            return std.os.unexpectedErrno(@intToEnum(system.E, err));
        }
        self.size = Size{
            .height = win_size.ws_row,
            .width = win_size.ws_col,
        };
    }

    fn uncook(self: *Terminal) !void {
        const writer = self.tty.writer();
        self.cooked_termios = try std.os.tcgetattr(self.tty.handle);
        errdefer self.cook() catch {};

        self.raw = self.cooked_termios;
        self.raw.lflag &= ~@as(
            system.tcflag_t,
            system.ECHO | system.ICANON | system.ISIG | system.IEXTEN,
        );
        self.raw.iflag &= ~@as(
            system.tcflag_t,
            system.IXON | system.ICRNL | system.BRKINT | system.INPCK | system.ISTRIP,
        );
        self.raw.oflag &= ~@as(system.tcflag_t, system.OPOST);
        self.raw.cflag |= system.CS8;
        self.raw.cc[system.V.TIME] = 0;
        self.raw.cc[system.V.MIN] = 1;
        try std.os.tcsetattr(self.tty.handle, .FLUSH, self.raw);

        try hideCursor(writer);
        try enterAlt(writer);
        try clearStyle(writer);
    }

    fn cook(self: *Terminal) !void {
        const writer = self.tty.writer();
        try clearStyle(writer);
        try leaveAlt(writer);
        try showCursor(writer);
        try attributeReset(writer);
        try std.os.tcsetattr(self.tty.handle, .FLUSH, self.cooked_termios);
    }

    pub fn write(self: *Terminal, txt: []const u8, x: usize, y: usize) !void {
        if (y >= 0 and y < term.size.height) {
            const writer = self.tty.writer();
            try moveCursor(writer, x, y);
            try writer.writeAll(txt);
        }
    }

    pub fn writeHoriz(self: Terminal, char: []const u8, x: usize, y: usize, width: usize) !void {
        if (y >= 0 and y < self.size.height) {
            const writer = self.tty.writer();
            try moveCursor(writer, x, y);
            for (0..width) |_| {
                try writer.writeAll(char);
            }
        }
    }

    pub fn writeVert(self: Terminal, char: []const u8, x: usize, y: usize, height: usize) !void {
        if (y >= 0 and y < self.size.height) {
            const writer = self.tty.writer();
            for (0..height) |i| {
                try moveCursor(writer, x, y + i);
                try writer.writeAll(char);
            }
        }
    }
};

fn moveCursor(writer: anytype, x: usize, y: usize) !void {
    _ = try writer.print("\x1B[{};{}H", .{ y + 1, x + 1 });
}

fn enterAlt(writer: anytype) !void {
    try writer.writeAll("\x1B[s"); // save cursor position
    try writer.writeAll("\x1B[?47h"); // save screen
    try writer.writeAll("\x1B[?1049h"); // enable alternative buffer
}

fn leaveAlt(writer: anytype) !void {
    try writer.writeAll("\x1B[?1049l"); // disable alternative buffer
    try writer.writeAll("\x1B[?47l"); // restore screen
    try writer.writeAll("\x1B[u"); // restore cursor position
}

fn hideCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25l");
}

fn showCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25h");
}

fn attributeReset(writer: anytype) !void {
    try writer.writeAll("\x1B[0m");
}

fn blueBackground(writer: anytype) !void {
    try writer.writeAll("\x1B[44m");
}

fn clearStyle(writer: anytype) !void {
    try writer.writeAll("\x1B[2J");
}

fn clearRect(writer: anytype, x: usize, y: usize, size: Size) !void {
    for (0..size.height) |i| {
        try moveCursor(writer, x, y + i);
        for (0..size.width) |_| {
            try writer.writeByte(' ');
        }
    }
}

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub const TerminalError = error{
    TerminalQuit,
};

pub const Grid = struct {
    allocator: std.mem.Allocator,
    size: Size,
    cells: Cells,
    buffer: []Grid.Cell,

    pub const Cell = struct {
        rune: ?[]const u8,
    };
    pub const Cells = NDSlice(Cell, 2, .row_major);

    pub fn init(allocator: std.mem.Allocator, size: Size) !Grid {
        var buffer = try allocator.alloc(Grid.Cell, size.width * size.height);
        errdefer allocator.free(buffer);
        for (buffer) |*cell| {
            cell.rune = null;
        }
        return .{
            .allocator = allocator,
            .size = size,
            .cells = try Grid.Cells.init(.{ size.height, size.width }, buffer),
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.buffer);
    }
};

test {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, .{ .width = 10, .height = 10 });
    defer grid.deinit();
    try expectEqual(null, grid.cells.items[try grid.cells.at(.{ 0, 0 })].rune);
}

var term: Terminal = undefined;
var root: Widget = undefined;

// the top-level widget type.
// for now, this is just a union. in the future we'll probably
// need a vtable so new types can be made without changing it.
// this will be fine for a while though.
pub const Widget = union(enum) {
    text: Text,
    box: Box,
    text_box: TextBox,
    git_info: GitInfo,

    pub fn deinit(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }

    pub const BuildError = Error("BuildError");

    pub fn build(self: *Widget, max_size: Size) BuildError!void {
        switch (self.*) {
            inline else => |*case| try case.build(max_size),
        }
    }

    pub const InputError = Error("InputError");

    pub fn input(self: *Widget, byte: u8) InputError!void {
        switch (self.*) {
            inline else => |*case| try case.input(byte),
        }
    }

    pub fn grid(self: *Widget) ?Grid {
        switch (self.*) {
            inline else => |*case| return case.grid,
        }
    }

    // returns error union that combines the error unions
    // from all the branches of Widget. we have to do this
    // because zig can't infer the error sets above due to
    // the use of recursion. is this radar's first use of
    // metaprogramming in zig? looks like it!
    fn Error(comptime field_name: []const u8) type {
        var err = error{};
        inline for (@typeInfo(Widget).Union.fields) |field| {
            err = err || @field(field.type, field_name);
        }
        return err;
    }
};

pub const Text = struct {
    allocator: std.mem.Allocator,
    grid: ?Grid,
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) Text {
        return .{
            .allocator = allocator,
            .grid = null,
            .content = content,
        };
    }

    pub fn deinit(self: *Text) void {
        if (self.grid) |*grid| {
            grid.deinit();
        }
    }

    pub const BuildError = error{ InvalidUtf8, TruncatedInput, Utf8CodepointTooLarge, Utf8EncodesSurrogateHalf, Utf8ExpectedContinuation, Utf8OverlongEncoding, Utf8InvalidStartByte, OutOfMemory, IndexOutOfBounds, InsufficientBufferSize, ZeroLengthDimensionsNotSupported };

    pub fn build(self: *Text, max_size: Size) Widget.BuildError!void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        if (max_size.height == 0) {
            return;
        }
        const width = try std.unicode.utf8CountCodepoints(self.content);
        var grid = try Grid.init(self.allocator, .{ .width = @max(1, @min(max_size.width, width)), .height = @max(1, @min(max_size.height, 1)) });
        errdefer grid.deinit();
        var utf8 = (try std.unicode.Utf8View.init(self.content)).iterator();
        var i: u32 = 0;
        while (utf8.nextCodepointSlice()) |char| {
            if (i == grid.size.width) {
                break;
            }
            grid.cells.items[try grid.cells.at(.{ 0, i })].rune = char;
            i += 1;
        }
        self.grid = grid;
    }

    pub const InputError = error{};

    pub fn input(self: *Text, byte: u8) !void {
        _ = self;
        _ = byte;
    }
};

pub const Box = struct {
    grid: ?Grid,
    allocator: std.mem.Allocator,
    children: std.ArrayList(Widget),
    border_style: ?BorderStyle,
    direction: Direction,

    pub const BorderStyle = enum {
        hidden,
        single,
        double,
    };

    pub const Direction = enum {
        vert,
        horiz,
    };

    pub fn init(allocator: std.mem.Allocator, widgets: []Widget, border_style: ?BorderStyle, direction: Direction) !Box {
        var children = std.ArrayList(Widget).init(allocator);
        errdefer children.deinit();
        for (widgets) |widget| {
            try children.append(widget);
        }
        return .{
            .grid = null,
            .allocator = allocator,
            .children = children,
            .border_style = border_style,
            .direction = direction,
        };
    }

    pub fn deinit(self: *Box) void {
        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit();
        if (self.grid) |*grid| {
            grid.deinit();
        }
    }

    pub const BuildError = error{};

    pub fn build(self: *Box, max_size: Size) Widget.BuildError!void {
        if (self.grid) |*grid| {
            grid.deinit();
            self.grid = null;
        }
        const border_size: usize = if (self.border_style) |_| 1 else 0;
        if (max_size.width <= border_size * 2 or max_size.height <= border_size * 2) {
            return;
        }
        var width: usize = 0;
        var height: usize = 0;
        var remaining_width = max_size.width - (border_size * 2);
        var remaining_height = max_size.height - (border_size * 2);
        for (self.children.items) |*child| {
            if (remaining_width <= 0 or remaining_height <= 0) {
                break;
            }
            try child.build(.{ .width = remaining_width, .height = remaining_height });
            if (child.grid()) |child_grid| {
                switch (self.direction) {
                    .vert => {
                        remaining_height -= child_grid.size.height;
                        width = @max(width, child_grid.size.width);
                        height += child_grid.size.height;
                    },
                    .horiz => {
                        remaining_width -= child_grid.size.width;
                        width += child_grid.size.width;
                        height = @max(height, child_grid.size.height);
                    },
                }
            } else {
                break;
            }
        }
        width += border_size * 2;
        height += border_size * 2;
        if (width > max_size.width or height > max_size.height) {
            return;
        }
        var grid = try Grid.init(self.allocator, .{ .width = width, .height = height });
        errdefer grid.deinit();
        switch (self.direction) {
            .vert => {
                var line: usize = 0;
                for (self.children.items) |*child| {
                    if (child.grid()) |child_grid| {
                        for (0..child_grid.size.height) |y| {
                            for (0..child_grid.size.width) |x| {
                                const rune = child_grid.cells.items[try child_grid.cells.at(.{ y, x })].rune;
                                if (grid.cells.at(.{ line + border_size, x + border_size })) |index| {
                                    grid.cells.items[index].rune = rune;
                                } else |_| {
                                    break;
                                }
                            }
                            line += 1;
                        }
                    }
                }
            },
            .horiz => {
                var col: usize = 0;
                for (self.children.items) |*child| {
                    if (child.grid()) |child_grid| {
                        for (0..child_grid.size.width) |x| {
                            for (0..child_grid.size.height) |y| {
                                const rune = child_grid.cells.items[try child_grid.cells.at(.{ y, x })].rune;
                                if (grid.cells.at(.{ y + border_size, col + border_size })) |index| {
                                    grid.cells.items[index].rune = rune;
                                } else |_| {
                                    break;
                                }
                            }
                            col += 1;
                        }
                    }
                }
            },
        }
        // border style
        if (self.border_style) |border_style| {
            const horiz_line = switch (border_style) {
                .hidden => " ",
                .single => "─",
                .double => "═",
            };
            const vert_line = switch (border_style) {
                .hidden => " ",
                .single => "│",
                .double => "║",
            };
            const top_left_corner = switch (border_style) {
                .hidden => " ",
                .single => "┌",
                .double => "╔",
            };
            const top_right_corner = switch (border_style) {
                .hidden => " ",
                .single => "┐",
                .double => "╗",
            };
            const bottom_left_corner = switch (border_style) {
                .hidden => " ",
                .single => "└",
                .double => "╚",
            };
            const bottom_right_corner = switch (border_style) {
                .hidden => " ",
                .single => "┘",
                .double => "╝",
            };
            // top and bottom border
            for (1..grid.size.width - 1) |x| {
                grid.cells.items[try grid.cells.at(.{ 0, x })].rune = horiz_line;
                grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, x })].rune = horiz_line;
            }
            // left and right border
            for (1..grid.size.height - 1) |y| {
                grid.cells.items[try grid.cells.at(.{ y, 0 })].rune = vert_line;
                grid.cells.items[try grid.cells.at(.{ y, grid.size.width - 1 })].rune = vert_line;
            }
            // corners
            grid.cells.items[try grid.cells.at(.{ 0, 0 })].rune = top_left_corner;
            grid.cells.items[try grid.cells.at(.{ 0, grid.size.width - 1 })].rune = top_right_corner;
            grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, 0 })].rune = bottom_left_corner;
            grid.cells.items[try grid.cells.at(.{ grid.size.height - 1, grid.size.width - 1 })].rune = bottom_right_corner;
        }
        // set grid
        self.grid = grid;
    }

    pub const InputError = error{};

    pub fn input(self: *Box, byte: u8) Widget.InputError!void {
        for (self.children.items) |*child| {
            try child.input(byte);
        }
    }
};

pub const TextBox = struct {
    allocator: std.mem.Allocator,
    grid: ?Grid,
    box: Box,
    border_style: ?Box.BorderStyle,
    lines: std.ArrayList(std.ArrayList(u8)),

    pub const InitError = error{ EndOfStream, StreamTooLong };

    pub fn init(allocator: std.mem.Allocator, content: []const u8, border_style: ?Box.BorderStyle) !TextBox {
        var lines = std.ArrayList(std.ArrayList(u8)).init(allocator);
        errdefer {
            for (lines.items) |*line| {
                line.deinit();
            }
            lines.deinit();
        }
        var fbs = std.io.fixedBufferStream(content);
        var reader = fbs.reader();
        while (true) {
            var line = std.ArrayList(u8).init(allocator);
            errdefer line.deinit();
            if (reader.streamUntilDelimiter(line.writer(), '\n', null)) {
                try lines.append(line);
            } else |err| {
                if (err == error.EndOfStream) {
                    try lines.append(line);
                    break;
                } else {
                    return err;
                }
            }
        }

        var widgets = std.ArrayList(Widget).init(allocator);
        defer widgets.deinit();
        for (lines.items) |line| {
            var text = Text.init(allocator, line.items);
            errdefer text.deinit();
            try widgets.append(Widget{ .text = text });
        }

        var box = try Box.init(allocator, widgets.items, border_style, .vert);
        errdefer box.deinit();

        return .{
            .allocator = allocator,
            .grid = null,
            .box = box,
            .border_style = border_style,
            .lines = lines,
        };
    }

    pub fn deinit(self: *TextBox) void {
        self.box.deinit();
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
    }

    pub const BuildError = error{};

    pub fn build(self: *TextBox, max_size: Size) Widget.BuildError!void {
        self.grid = null;
        try self.box.build(max_size);
        self.grid = self.box.grid;
    }

    pub const InputError = error{};

    pub fn input(self: *TextBox, byte: u8) Widget.InputError!void {
        try self.box.input(byte);
    }
};

pub const GitInfo = struct {
    grid: ?Grid,
    box: ?Box,
    allocator: std.mem.Allocator,
    repo: ?*c.git_repository,
    commits: std.ArrayList(?*c.git_commit),
    index: u32 = 0,
    bufs: std.ArrayList(c.git_buf),

    pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository, index: u32) !GitInfo {
        // init walker
        var walker: ?*c.git_revwalk = null;
        try expectEqual(0, c.git_revwalk_new(&walker, repo));
        defer c.git_revwalk_free(walker);
        try expectEqual(0, c.git_revwalk_sorting(walker, c.GIT_SORT_TIME));
        try expectEqual(0, c.git_revwalk_push_head(walker));

        // init commits
        var commits = std.ArrayList(?*c.git_commit).init(allocator);
        errdefer commits.deinit();

        // walk the commits
        var oid: c.git_oid = undefined;
        while (0 == c.git_revwalk_next(&oid, walker)) {
            var commit: ?*c.git_commit = null;
            try expectEqual(0, c.git_commit_lookup(&commit, repo, &oid));
            errdefer c.git_commit_free(commit);
            try commits.append(commit);
        }

        var git_info = GitInfo{
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

    pub fn deinit(self: *GitInfo) void {
        for (self.commits.items) |commit| {
            c.git_commit_free(commit);
        }
        self.commits.deinit();
        for (self.bufs.items) |*buf| {
            c.git_buf_dispose(buf);
        }
        self.bufs.deinit();
    }

    pub const BuildError = std.mem.Allocator.Error || Text.BuildError || TextBox.InitError;

    pub fn build(self: *GitInfo, max_size: Size) BuildError!void {
        self.box = null;
        self.grid = null;

        var commits = std.ArrayList(Widget).init(self.allocator);
        defer commits.deinit();
        for (self.commits.items, 0..) |commit, i| {
            const line = std.mem.sliceTo(c.git_commit_message(commit), '\n');
            var text_box = try TextBox.init(self.allocator, line, if (self.index == i) .double else .single);
            errdefer text_box.deinit();
            try commits.append(Widget{ .text_box = text_box });
        }
        var left_box = try Box.init(self.allocator, commits.items, null, .vert);

        var diffs = std.ArrayList(Widget).init(self.allocator);
        defer diffs.deinit();
        for (self.bufs.items) |buf| {
            var text_box = try TextBox.init(self.allocator, std.mem.sliceTo(buf.ptr, 0), .hidden);
            errdefer text_box.deinit();
            try diffs.append(Widget{ .text_box = text_box });
        }
        var right_box = try Box.init(self.allocator, diffs.items, null, .vert);

        var box_contents = [_]Widget{ Widget{ .box = left_box }, Widget{ .box = right_box } };
        var box = try Box.init(self.allocator, &box_contents, null, .horiz);
        errdefer box.deinit();

        try box.build(max_size);
        self.box = box;
        self.grid = box.grid;
    }

    pub const InputError = std.os.TermiosSetError || std.fs.File.ReadError || error{ TestExpectedEqual, OutOfMemory };

    pub fn input(self: *GitInfo, byte: u8) Widget.InputError!void {
        if (byte == '\x1B') {
            var esc_buffer: [8]u8 = undefined;
            const esc_read = try term.tty.read(&esc_buffer);
            const esc_slice = esc_buffer[0..esc_read];

            if (std.mem.eql(u8, esc_slice, "[A")) {
                self.index -|= 1;
            } else if (std.mem.eql(u8, esc_slice, "[B")) {
                if (self.index + 1 < self.commits.items.len) {
                    self.index += 1;
                }
            }

            try self.updateDiff();
        }
    }

    fn updateDiff(self: *GitInfo) !void {
        for (self.bufs.items) |*buf| {
            c.git_buf_dispose(buf);
        }
        self.bufs.clearAndFree();

        const commit = self.commits.items[self.index];

        const commit_oid = c.git_commit_tree_id(commit);
        var commit_tree: ?*c.git_tree = null;
        try expectEqual(0, c.git_tree_lookup(&commit_tree, self.repo, commit_oid));
        defer c.git_tree_free(commit_tree);

        var prev_commit_tree: ?*c.git_tree = null;

        if (self.index < self.commits.items.len - 1) {
            const prev_commit = self.commits.items[self.index + 1];
            const prev_commit_oid = c.git_commit_tree_id(prev_commit);
            try expectEqual(0, c.git_tree_lookup(&prev_commit_tree, self.repo, prev_commit_oid));
        }
        defer if (prev_commit_tree) |ptr| c.git_tree_free(ptr);

        var commit_diff: ?*c.git_diff = null;
        try expectEqual(0, c.git_diff_tree_to_tree(&commit_diff, self.repo, prev_commit_tree, commit_tree, null));
        defer c.git_diff_free(commit_diff);

        const delta_count = c.git_diff_num_deltas(commit_diff);
        for (0..delta_count) |delta_index| {
            var commit_patch: ?*c.git_patch = null;
            try expectEqual(0, c.git_patch_from_diff(&commit_patch, commit_diff, delta_index));
            defer c.git_patch_free(commit_patch);

            var commit_buf: c.git_buf = std.mem.zeroes(c.git_buf);
            try expectEqual(0, c.git_patch_to_buf(&commit_buf, commit_patch));
            {
                errdefer c.git_buf_dispose(&commit_buf);
                try self.bufs.append(commit_buf);
            }
        }
    }
};

fn tick() !void {
    const root_size: Size = .{ .width = term.size.width, .height = term.size.height };
    if (root_size.width == 0 or root_size.height == 0) {
        return;
    }
    const refresh = if (root.grid()) |grid|
        grid.size.width != root_size.width or grid.size.height != root_size.height
    else
        true;
    if (refresh) {
        try root.build(root_size);
    }

    // TODO: this is very inefficient...clear the screen more surgically
    try clearRect(term.tty.writer(), 0, 0, root_size);

    if (root.grid()) |grid| {
        for (0..grid.size.height) |y| {
            for (0..grid.size.width) |x| {
                if (grid.cells.items[try grid.cells.at(.{ y, x })].rune) |rune| {
                    try term.write(rune, x, y);
                }
            }
        }
    }

    var buffer: [1]u8 = undefined;
    const size = try term.tty.read(&buffer);

    if (size > 0) {
        if (buffer[0] == 'q') {
            return error.TerminalQuit;
        } else {
            try root.input(buffer[0]);
            try root.build(root_size);
        }
    }
}

pub fn main() !void {
    // start libgit
    _ = c.git_libgit2_init();
    defer _ = c.git_libgit2_shutdown();

    // find cwd
    var cwd_path_buffer = [_]u8{0} ** std.fs.MAX_PATH_BYTES;
    const cwd_path = @ptrCast([*c]const u8, try std.fs.cwd().realpath(".", &cwd_path_buffer));

    // init repo
    var repo: ?*c.git_repository = null;
    try expectEqual(0, c.git_repository_init(&repo, cwd_path, 0));
    defer c.git_repository_free(repo);

    // init root widget
    const allocator = std.heap.page_allocator;
    root = Widget{ .git_info = try GitInfo.init(allocator, repo, 0) };
    defer root.deinit();

    // init term
    term = try Terminal.init();
    defer term.deinit();

    // non-blocking
    term.raw.cc[system.V.TIME] = 1;
    term.raw.cc[system.V.MIN] = 0;
    try std.os.tcsetattr(term.tty.handle, .NOW, term.raw);

    while (true) {
        tick() catch |err| {
            switch (err) {
                error.TerminalQuit => break,
                else => return err,
            }
        };
        std.time.sleep(5000000); // TODO: do variable sleep with target frame rate
    }
}
