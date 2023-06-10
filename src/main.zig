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
}

pub const Terminal = struct {
    tty: std.fs.File,
    cooked_termios: std.os.termios = undefined,
    raw: std.os.termios = undefined,
    size: Size = undefined,

    const Size = struct { width: usize, height: usize };

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

fn clearRect(writer: anytype, rect: Rect) !void {
    for (0..rect.height) |i| {
        try moveCursor(writer, rect.x, rect.y + i);
        for (0..rect.width) |_| {
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

const TRIM_BUFFER_SIZE = 1024;

/// copies `in` to `out` up to `max_len` unicode codepoints.
/// escape codes are preserved and do not count towards the total.
fn trim(in: []const u8, max_len: u64, out: *[TRIM_BUFFER_SIZE]u8) ![]u8 {
    var utf8 = (try std.unicode.Utf8View.init(in)).iterator();
    var count: u64 = 0;
    const EscCodeStatus = enum { none, start, middle };
    var esc_code_status = EscCodeStatus.none;
    var i: u32 = 0;
    while (utf8.nextCodepointSlice()) |codepoint| {
        switch (esc_code_status) {
            .none => {
                if (std.mem.eql(u8, codepoint, "\x1B")) {
                    esc_code_status = .start;
                } else {
                    if (count == max_len) {
                        continue;
                    } else {
                        count += 1;
                    }
                }
            },
            .start => {
                esc_code_status = if (std.mem.eql(u8, codepoint, "[")) .middle else .none;
            },
            .middle => {
                switch (codepoint[0]) {
                    '\x40'...'\x7E' => esc_code_status = .none,
                    else => {},
                }
            },
        }
        if (i + codepoint.len > out.len) {
            break;
        } else {
            for (codepoint) |byte| {
                out[i] = byte;
                i += 1;
            }
        }
    }
    return out[0..i];
}

test "trim string with escape codes" {
    var buffer = [_]u8{0} ** TRIM_BUFFER_SIZE;
    const text = try trim("\x1B[32;43mHello, world!\x1B[0m", 5, &buffer);
    try std.testing.expectEqualStrings("\x1B[32;43mHello\x1B[0m", text);
}

pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

var term: Terminal = undefined;
var root: Widget = undefined;

// the top-level widget type.
// for now, this is just a union. in the future we'll probably
// need a vtable so new types can be made without changing it.
// this will be fine for a while though.
pub const Widget = union(enum) {
    text: Text,
    box: Box,
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
            inline else => |case| return case.rect.width,
        }
    }

    pub fn height(self: Widget) usize {
        switch (self) {
            inline else => |case| return case.rect.height,
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
    rect: Rect,
    content: []const u8,

    pub fn init(x: usize, y: usize, content: []const u8) Text {
        return .{
            .rect = .{
                .x = x,
                .y = y,
                .width = content.len,
                .height = 1,
            },
            .content = content,
        };
    }

    pub fn deinit(self: *Text) void {
        _ = self;
    }

    pub const RenderError = std.fs.File.WriteError || error{InvalidUtf8};

    pub fn render(self: *Text, x: usize, y: usize) Widget.RenderError!void {
        var buffer = [_]u8{0} ** TRIM_BUFFER_SIZE;
        const text = try trim(self.content, self.rect.width, &buffer);
        try term.write(text, x + self.rect.x, y + self.rect.y);
    }

    pub const InputError = error{};

    pub fn input(self: *Text, byte: u8) !void {
        _ = self;
        _ = byte;
    }
};

pub const Box = struct {
    rect: Rect,
    allocator: std.mem.Allocator,
    children: std.ArrayList(Widget),
    border_style: BorderStyle,

    pub const BorderStyle = enum {
        none,
        single,
        double,
    };

    pub fn init(allocator: std.mem.Allocator, rect: Rect, border_style: BorderStyle) Box {
        return .{
            .rect = rect,
            .allocator = allocator,
            .children = std.ArrayList(Widget).init(allocator),
            .border_style = border_style,
        };
    }

    pub fn deinit(self: *Box) void {
        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit();
    }

    pub const RenderError = std.fs.File.WriteError;

    pub fn render(self: *Box, x: usize, y: usize) Widget.RenderError!void {
        // render the children
        // TODO: this lays the children out vertically -- support horizontal layout as well
        var width: usize = 0;
        var height: usize = 0;
        for (self.children.items) |*child| {
            try child.render(x + self.rect.x + 1, y + self.rect.y + 1 + height);
            width = std.math.max(width, child.width());
            height += child.height();
        }
        var horiz_buffer = try self.allocator.alloc(u8, width);
        defer self.allocator.free(horiz_buffer);
        for (horiz_buffer) |*b| {
            b.* = '-';
        }
        if (width > self.rect.width) self.rect.width = width;
        if (height > self.rect.height) self.rect.height = height + 2;
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
        // horiz lines
        try term.writeHoriz(horiz_line, x + self.rect.x + 1, y + self.rect.y, width);
        try term.writeHoriz(horiz_line, x + self.rect.x + 1, y + self.rect.y + height + 1, width);
        // vert lines
        try term.writeVert(vert_line, x + self.rect.x, y + self.rect.y + 1, height);
        try term.writeVert(vert_line, x + self.rect.x + width + 1, y + self.rect.y + 1, height);
        // corners
        try term.write(top_left_corner, x + self.rect.x, y + self.rect.y);
        try term.write(top_right_corner, x + self.rect.x + width + 1, y + self.rect.y);
        try term.write(bottom_left_corner, x + self.rect.x, y + self.rect.y + height + 1);
        try term.write(bottom_right_corner, x + self.rect.x + width + 1, y + self.rect.y + height + 1);
    }

    pub const InputError = error{};

    pub fn input(self: *Box, byte: u8) Widget.InputError!void {
        for (self.children.items) |*child| {
            try child.input(byte);
        }
    }
};

pub const GitInfo = struct {
    rect: Rect,
    allocator: std.mem.Allocator,
    repo: ?*c.git_repository,
    lines: std.ArrayList([]const u8),
    index: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, rect: Rect, repo: ?*c.git_repository, index: u32) !GitInfo {
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
            .rect = rect,
            .allocator = allocator,
            .repo = repo,
            .lines = lines,
            .index = index,
        };
    }

    pub fn deinit(self: *GitInfo) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit();
    }

    pub const RenderError = std.mem.Allocator.Error || Text.RenderError;

    pub fn render(self: *GitInfo, x: usize, y: usize) RenderError!void {
        var total_height: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            var box_widget = Widget{ .box = Box.init(self.allocator, .{ .x = 0, .y = 0, .width = 0, .height = 0 }, if (self.index == i) .double else .single) };
            defer box_widget.deinit();
            var text_widget = Widget{ .text = Text.init(0, 0, line) };
            text_widget.text.rect.width = std.math.min(
                text_widget.text.rect.width,
                self.rect.width - 2,
            );
            try box_widget.box.children.append(text_widget);
            try box_widget.render(x + self.rect.x, y + self.rect.y + total_height);
            total_height += box_widget.height();
        }
    }

    pub const InputError = std.os.TermiosSetError || std.fs.File.ReadError;

    pub fn input(self: *GitInfo, byte: u8) Widget.InputError!void {
        if (byte == '\x1B') {
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
    const root_rect = .{ .x = 0, .y = 0, .width = term.size.width, .height = term.size.height };
    if (root.width() != root_rect.width or root.height() != root_rect.height) {
        root.git_info.rect = root_rect;
        try clearRect(term.tty.writer(), root_rect);
    }

    try root.render(0, 0);

    var buffer: [1]u8 = undefined;
    const size = try term.tty.read(&buffer);

    if (size > 0) {
        if (buffer[0] == 'q') {
            return error.TerminalQuit;
        } else {
            try root.input(buffer[0]);
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

    // init term
    term = try Terminal.init();
    defer term.deinit();

    // init root widget
    const allocator = std.heap.page_allocator;
    root = Widget{ .git_info = try GitInfo.init(allocator, .{ .x = 0, .y = 0, .width = term.size.width, .height = term.size.height }, repo, 0) };
    defer root.deinit();

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
