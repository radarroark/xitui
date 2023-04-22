//! you're looking at radar's hopeless attempt to implement
//! a text UI for git. it can't possibly be worse then using
//! the git CLI, right?

const std = @import("std");

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
        var win_size = std.mem.zeroes(std.os.system.winsize);
        const err = std.os.system.ioctl(term.tty.handle, std.os.system.T.IOCGWINSZ, @ptrToInt(&win_size));
        if (std.os.errno(err) != .SUCCESS) {
            return std.os.unexpectedErrno(@intToEnum(std.os.system.E, err));
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
            std.os.system.tcflag_t,
            std.os.system.ECHO | std.os.system.ICANON | std.os.system.ISIG | std.os.system.IEXTEN,
        );
        self.raw.iflag &= ~@as(
            std.os.system.tcflag_t,
            std.os.system.IXON | std.os.system.ICRNL | std.os.system.BRKINT | std.os.system.INPCK | std.os.system.ISTRIP,
        );
        self.raw.oflag &= ~@as(std.os.system.tcflag_t, std.os.system.OPOST);
        self.raw.cflag |= std.os.system.CS8;
        self.raw.cc[std.os.system.V.TIME] = 0;
        self.raw.cc[std.os.system.V.MIN] = 1;
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
var index: usize = 0;

pub const TerminalError = error{
    TerminalQuit,
};

fn tick() !void {
    const writer = term.tty.writer();
    try writeLine(writer, "hello", 0, term.size.width, index == 0);
    try writeLine(writer, "world", 1, term.size.width, index == 1);
    try writeLine(writer, "goodbye", 2, term.size.width, index == 2);
    try writeLine(writer, "world", 3, term.size.width, index == 3);

    var buffer: [1]u8 = undefined;
    _ = try term.tty.read(&buffer);

    if (buffer[0] == 'q') {
        return error.TerminalQuit;
    } else if (buffer[0] == '\x1B') {
        term.raw.cc[std.os.system.V.TIME] = 1;
        term.raw.cc[std.os.system.V.MIN] = 0;
        try std.os.tcsetattr(term.tty.handle, .NOW, term.raw);

        var esc_buffer: [8]u8 = undefined;
        const esc_read = try term.tty.read(&esc_buffer);

        term.raw.cc[std.os.system.V.TIME] = 0;
        term.raw.cc[std.os.system.V.MIN] = 1;
        try std.os.tcsetattr(term.tty.handle, .NOW, term.raw);

        if (std.mem.eql(u8, esc_buffer[0..esc_read], "[A")) {
            index -|= 1;
        } else if (std.mem.eql(u8, esc_buffer[0..esc_read], "[B")) {
            index = std.math.min(index + 1, 3);
        }
    }
}

pub fn main() !void {
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
