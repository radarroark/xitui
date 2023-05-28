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

fn handleSigWinch(_: c_int) callconv(.C) void {
    term.updateSize() catch return;
    tick() catch return;
}

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

    const Size = struct { width: usize, height: usize };

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
        try clear(writer);
    }

    fn cook(self: *Terminal) !void {
        const writer = self.tty.writer();
        try clear(writer);
        try leaveAlt(writer);
        try showCursor(writer);
        try attributeReset(writer);
        try std.os.tcsetattr(self.tty.handle, .FLUSH, self.cooked_termios);
    }
};

fn writeHoriz(writer: anytype, txt: []const u8, x: usize, y: usize, selected: bool) !void {
    if (selected) {
        try blueBackground(writer);
    } else {
        try attributeReset(writer);
    }
    try moveCursor(writer, x, y);
    try writer.writeAll(txt);
}

fn writeHorizRepeat(writer: anytype, char: []const u8, x: usize, y: usize, width: usize, selected: bool) !void {
    if (selected) {
        try blueBackground(writer);
    } else {
        try attributeReset(writer);
    }
    for (0..width) |i| {
        try moveCursor(writer, x + i, y);
        try writer.writeAll(char);
    }
}

fn writeVertRepeat(writer: anytype, char: []const u8, x: usize, y: usize, height: usize, selected: bool) !void {
    if (selected) {
        try blueBackground(writer);
    } else {
        try attributeReset(writer);
    }
    for (0..height) |i| {
        try moveCursor(writer, x, y + i);
        try writer.writeAll(char);
    }
}

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

fn clear(writer: anytype) !void {
    try writer.writeAll("\x1B[2J");
}

pub const TerminalError = error{
    TerminalQuit,
};

var term: Terminal = undefined;
var widget: Widget = undefined;

pub const Widget = union(enum) {
    text: Text,
    rect: Rect,
    git_info: GitInfo,

    pub fn deinit(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }

    pub const RenderError = Error("RenderError");

    pub fn render(self: *Widget, x: usize, y: usize) RenderError!void {
        switch (self.*) {
            inline else => |*case| try case.render(x, y),
        }
    }

    pub const InputError = Error("InputError");

    pub fn input(self: *Widget, byte: u8) InputError!void {
        switch (self.*) {
            inline else => |*case| try case.input(byte),
        }
    }

    pub fn width(self: Widget) usize {
        switch (self) {
            inline else => |case| return case.width,
        }
    }

    pub fn height(self: Widget) usize {
        switch (self) {
            inline else => |case| return case.height,
        }
    }

    fn Error(comptime field_name: []const u8) type {
        var err = error{};
        inline for (@typeInfo(Widget).Union.fields) |field| {
            err = err || @field(field.type, field_name);
        }
        return err;
    }
};

pub const Text = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    content: []const u8,

    pub fn init(x: usize, y: usize, content: []const u8) Text {
        return .{
            .x = x,
            .y = y,
            .width = content.len,
            .height = 1,
            .content = content,
        };
    }

    pub fn deinit(self: *Text) void {
        _ = self;
    }

    pub const RenderError = std.fs.File.WriteError;

    pub fn render(self: *Text, x: usize, y: usize) Widget.RenderError!void {
        const writer = term.tty.writer();
        try writeHoriz(writer, self.content, x + self.x, y + self.y, false);
    }

    pub const InputError = error{};

    pub fn input(self: *Text, byte: u8) !void {
        _ = self;
        _ = byte;
    }
};

pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,

    allocator: std.mem.Allocator,
    children: std.ArrayList(Widget),
    border_style: BorderStyle,

    pub const BorderStyle = enum {
        none,
        single,
        double,
    };

    pub fn init(allocator: std.mem.Allocator, x: usize, y: usize, width: usize, height: usize, border_style: BorderStyle) Rect {
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .allocator = allocator,
            .children = std.ArrayList(Widget).init(allocator),
            .border_style = border_style,
        };
    }

    pub fn deinit(self: *Rect) void {
        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit();
    }

    pub const RenderError = std.fs.File.WriteError;

    pub fn render(self: *Rect, x: usize, y: usize) Widget.RenderError!void {
        var max_width: usize = 0;
        var height: usize = 0;
        for (self.children.items) |*child| {
            try child.render(x + self.x + 1, y + self.y + 1 + height);
            max_width = std.math.max(max_width, child.width());
            height += child.height();
        }
        var horiz_buffer = try self.allocator.alloc(u8, max_width);
        defer self.allocator.free(horiz_buffer);
        for (horiz_buffer) |*b| {
            b.* = '-';
        }
        // border style
        const horiz_line = switch (self.border_style) {
            .none => " ",
            .single => "─",
            .double => "═",
        };
        const vert_line = switch (self.border_style) {
            .none => " ",
            .single => "│",
            .double => "║",
        };
        const top_left_corner = switch (self.border_style) {
            .none => " ",
            .single => "┌",
            .double => "╔",
        };
        const top_right_corner = switch (self.border_style) {
            .none => " ",
            .single => "┐",
            .double => "╗",
        };
        const bottom_left_corner = switch (self.border_style) {
            .none => " ",
            .single => "└",
            .double => "╚",
        };
        const bottom_right_corner = switch (self.border_style) {
            .none => " ",
            .single => "┘",
            .double => "╝",
        };
        const writer = term.tty.writer();
        // horiz lines
        try writeHorizRepeat(writer, horiz_line, x + self.x + 1, y + self.y, max_width, false);
        try writeHorizRepeat(writer, horiz_line, x + self.x + 1, y + self.y + height + 1, max_width, false);
        // vert lines
        try writeVertRepeat(writer, vert_line, x + self.x, y + self.y + 1, height, false);
        try writeVertRepeat(writer, vert_line, x + self.x + max_width + 1, y + self.y + 1, height, false);
        // corners
        try moveCursor(writer, x + self.x, y + self.y);
        try writer.writeAll(top_left_corner);
        try moveCursor(writer, x + self.x + max_width + 1, y + self.y);
        try writer.writeAll(top_right_corner);
        try moveCursor(writer, x + self.x, y + self.y + height + 1);
        try writer.writeAll(bottom_left_corner);
        try moveCursor(writer, x + self.x + max_width + 1, y + self.y + height + 1);
        try writer.writeAll(bottom_right_corner);
    }

    pub const InputError = error{};

    pub fn input(self: *Rect, byte: u8) Widget.InputError!void {
        for (self.children.items) |*child| {
            try child.input(byte);
        }
    }
};

pub const GitInfo = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,

    allocator: std.mem.Allocator,
    repo: ?*c.git_repository,
    lines: std.ArrayList([]const u8),
    index: u32 = 0,
    update_count: u32 = 0,

    pub const InitError = std.mem.Allocator.Error || error{TestExpectedEqual};

    pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository, index: u32, update_count: u32) !GitInfo {
        // init walker
        var walker: ?*c.git_revwalk = null;
        try expectEqual(0, c.git_revwalk_new(&walker, repo));
        defer c.git_revwalk_free(walker);
        try expectEqual(0, c.git_revwalk_sorting(walker, c.GIT_SORT_TIME));
        try expectEqual(0, c.git_revwalk_push_head(walker));

        // init lines
        var lines = std.ArrayList([]const u8).init(allocator);
        errdefer lines.deinit();

        // walk the commits
        var oid: c.git_oid = undefined;
        while (0 == c.git_revwalk_next(&oid, walker)) {
            var commit: ?*c.git_commit = null;
            try expectEqual(0, c.git_commit_lookup(&commit, repo, &oid));
            defer c.git_commit_free(commit);
            // make copy of message so it can live beyond lifetime of commit
            const message = try std.fmt.allocPrint(allocator, "{s}", .{std.mem.sliceTo(c.git_commit_message(commit), '\n')});
            errdefer allocator.free(message);
            try lines.append(message);
        }

        return .{
            .x = 0,
            .y = 0,
            .width = term.size.width,
            .height = term.size.height,
            .allocator = allocator,
            .repo = repo,
            .lines = lines,
            .index = index,
            .update_count = update_count,
        };
    }

    pub fn deinit(self: *GitInfo) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit();
    }

    pub const RenderError = InitError || std.fs.File.WriteError;

    pub fn render(self: *GitInfo, x: usize, y: usize) RenderError!void {
        if (self.width != term.size.width or self.height != term.size.height) {
            self.deinit();
            self.* = try GitInfo.init(self.allocator, self.repo, self.index, self.update_count + 1);
        }

        const writer = term.tty.writer();
        for (self.lines.items, 0..) |line, i| {
            try writeHoriz(writer, line, x, y + i, self.index == i);
        }
    }

    pub const InputError = std.os.TermiosSetError || std.fs.File.ReadError;

    pub fn input(self: *GitInfo, byte: u8) Widget.InputError!void {
        if (byte == '\x1B') {
            // non-blocking
            term.raw.cc[system.V.TIME] = 1;
            term.raw.cc[system.V.MIN] = 0;
            try std.os.tcsetattr(term.tty.handle, .NOW, term.raw);

            var esc_buffer: [8]u8 = undefined;
            const esc_read = try term.tty.read(&esc_buffer);
            const esc_slice = esc_buffer[0..esc_read];

            if (std.mem.eql(u8, esc_slice, "[A")) {
                self.index -|= 1;
            } else if (std.mem.eql(u8, esc_slice, "[B")) {
                if (self.index + 1 < self.lines.items.len) {
                    self.index += 1;
                }
            }
        }
    }
};

fn tick() !void {
    try widget.render(0, 0);

    // blocking
    term.raw.cc[system.V.TIME] = 0;
    term.raw.cc[system.V.MIN] = 1;
    try std.os.tcsetattr(term.tty.handle, .NOW, term.raw);

    var buffer: [1]u8 = undefined;
    const size = try term.tty.read(&buffer);

    if (size > 0) {
        if (buffer[0] == 'q') {
            return error.TerminalQuit;
        } else {
            try widget.input(buffer[0]);
        }
    }
}

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
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

    // init widget and term
    const allocator = std.heap.page_allocator;
    //widget = Widget{ .git_info = try GitInfo.init(allocator, repo, 0, 1) };
    widget = Widget{ .rect = Rect.init(allocator, 0, 0, 10, 5, .double) };
    defer widget.deinit();
    try widget.rect.children.append(Widget{ .text = Text.init(0, 0, "this is the first line") });
    try widget.rect.children.append(Widget{ .text = Text.init(0, 0, "you made it to the second line!") });
    try widget.rect.children.append(Widget{ .text = Text.init(0, 0, "and here's the third") });
    term = try Terminal.init();
    defer term.deinit();

    while (true) {
        tick() catch |err| {
            switch (err) {
                error.TerminalQuit => return,
                else => return err,
            }
        };
    }
}
