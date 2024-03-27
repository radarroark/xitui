const std = @import("std");
const builtin = @import("builtin");
const Size = @import("./layout.zig").Size;

pub var terminal: Terminal = undefined;

fn handleSigWinch(_: c_int) callconv(.C) void {
    terminal.updateSize() catch return;
}

pub const Terminal = struct {
    tty: std.fs.File,
    cooked_termios: std.posix.termios = undefined,
    raw: std.posix.termios = undefined,
    size: Size = undefined,

    pub fn init() !Terminal {
        var tty = try std.fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
        errdefer tty.close();

        var self = Terminal{
            .tty = tty,
        };

        try self.uncook();

        try self.updateSize();

        try std.posix.sigaction(std.posix.SIG.WINCH, &std.posix.Sigaction{
            .handler = .{ .handler = handleSigWinch },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        }, null);

        return self;
    }

    pub fn deinit(self: *Terminal) void {
        self.cook() catch {};
        self.tty.close();
    }

    pub fn updateSize(self: *Terminal) !void {
        var win_size = std.mem.zeroes(std.posix.winsize);
        const err = std.os.linux.ioctl(terminal.tty.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&win_size));
        if (std.posix.errno(err) != .SUCCESS) {
            return std.posix.unexpectedErrno(@enumFromInt(err));
        }
        self.size = Size{
            .height = win_size.ws_row,
            .width = win_size.ws_col,
        };
    }

    fn uncook(self: *Terminal) !void {
        const writer = self.tty.writer();
        self.cooked_termios = try std.posix.tcgetattr(self.tty.handle);
        errdefer self.cook() catch {};

        self.raw = self.cooked_termios;
        self.raw.lflag = .{ .ECHO = true, .ISIG = true, .IEXTEN = true };
        self.raw.iflag = .{ .ICRNL = true, .IUTF8 = true };
        self.raw.oflag = .{ .OPOST = true };
        self.raw.cflag.CSIZE = .CS8;
        self.raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        self.raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        try std.posix.tcsetattr(self.tty.handle, .FLUSH, self.raw);

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
        try std.posix.tcsetattr(self.tty.handle, .FLUSH, self.cooked_termios);
    }

    pub fn write(self: *Terminal, txt: []const u8, x: usize, y: usize) !void {
        if (y >= 0 and y < terminal.size.height) {
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

pub fn moveCursor(writer: anytype, x: usize, y: usize) !void {
    _ = try writer.print("\x1B[{};{}H", .{ y + 1, x + 1 });
}

pub fn enterAlt(writer: anytype) !void {
    try writer.writeAll("\x1B[s"); // save cursor position
    try writer.writeAll("\x1B[?47h"); // save screen
    try writer.writeAll("\x1B[?1049h"); // enable alternative buffer
}

pub fn leaveAlt(writer: anytype) !void {
    try writer.writeAll("\x1B[?1049l"); // disable alternative buffer
    try writer.writeAll("\x1B[?47l"); // restore screen
    try writer.writeAll("\x1B[u"); // restore cursor position
}

pub fn hideCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25l");
}

pub fn showCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25h");
}

pub fn attributeReset(writer: anytype) !void {
    try writer.writeAll("\x1B[0m");
}

pub fn blueBackground(writer: anytype) !void {
    try writer.writeAll("\x1B[44m");
}

pub fn clearStyle(writer: anytype) !void {
    try writer.writeAll("\x1B[2J");
}

pub fn clearRect(writer: anytype, x: usize, y: usize, size: Size) !void {
    for (0..size.height) |i| {
        try moveCursor(writer, x, y + i);
        for (0..size.width) |_| {
            try writer.writeByte(' ');
        }
    }
}

pub fn setNonBlocking() !void {
    terminal.raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    terminal.raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    try std.posix.tcsetattr(terminal.tty.handle, .NOW, terminal.raw);
}
