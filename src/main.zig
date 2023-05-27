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

fn writeLine(writer: anytype, txt: []const u8, y: usize, width: usize, selected: bool) !void {
    if (selected) {
        try blueBackground(writer);
    } else {
        try attributeReset(writer);
    }
    try moveCursor(writer, y, 0);
    try writer.writeAll(txt);
    try writer.writeByteNTimes(' ', width - txt.len);
}

fn moveCursor(writer: anytype, row: usize, col: usize) !void {
    _ = try writer.print("\x1B[{};{}H", .{ row + 1, col + 1 });
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

var term: Terminal = undefined;
var page: Page = undefined;

pub const TerminalError = error{
    TerminalQuit,
};

pub const Page = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]const u8),
    index: u8 = 0,
    update_count: u32 = 0,
    last_width: usize = 0,
    last_height: usize = 0,

    pub fn init(allocator: std.mem.Allocator, index: u8, update_count: u32) !Page {
        const term_width_str = try std.fmt.allocPrint(allocator, "term width: {}", .{term.size.width});
        errdefer allocator.free(term_width_str);
        const term_height_str = try std.fmt.allocPrint(allocator, "term height: {}", .{term.size.height});
        errdefer allocator.free(term_height_str);
        const update_count_str = try std.fmt.allocPrint(allocator, "update count: {}", .{update_count});
        errdefer allocator.free(term_height_str);

        var lines = std.ArrayList([]const u8).init(allocator);
        errdefer lines.deinit();
        try lines.append(term_width_str);
        try lines.append(term_height_str);
        try lines.append(update_count_str);

        return .{
            .allocator = allocator,
            .lines = lines,
            .index = index,
            .update_count = update_count,
            .last_width = term.size.width,
            .last_height = term.size.height,
        };
    }

    pub fn deinit(self: *Page) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit();
    }

    pub fn render(self: *Page) !void {
        if (self.last_width != term.size.width or self.last_height != term.size.height) {
            self.deinit();
            self.* = try Page.init(self.allocator, self.index, self.update_count + 1);
        }

        const writer = term.tty.writer();
        for (self.lines.items, 0..) |line, i| {
            try writeLine(writer, line, i, term.size.width, self.index == i);
        }
    }

    pub fn input(self: *Page, byte: u8) !void {
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
                self.index = std.math.min(self.index + 1, self.lines.items.len - 1);
            }
        }
    }
};

fn tick() !void {
    try page.render();

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
            try page.input(buffer[0]);
        }
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    page = try Page.init(allocator, 0, 1);
    defer page.deinit();

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
