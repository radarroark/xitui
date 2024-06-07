const std = @import("std");
const builtin = @import("builtin");
const Size = @import("./layout.zig").Size;

pub var terminal: Terminal = undefined;

fn handleSigWinch(_: c_int) callconv(.C) void {
    terminal.updateSize() catch return;
}

pub const Terminal = struct {
    core: Core,
    size: Size,

    pub const Core = switch (builtin.os.tag) {
        .windows => struct {
            tty: Tty,

            pub const KEY_EVENT_RECORD = extern struct {
                bKeyDown: std.os.windows.BOOL,
                wRepeatCount: std.os.windows.WORD,
                wVirtualKeyCode: std.os.windows.WORD,
                wVirtualScanCode: std.os.windows.WORD,
                uChar: extern union {
                    UnicodeChar: std.os.windows.WCHAR,
                    AsciiChar: std.os.windows.CHAR,
                },
                dwControlKeyState: std.os.windows.DWORD,
            };

            pub const MOUSE_EVENT_RECORD = extern struct {
                dwMousePosition: std.os.windows.COORD,
                dwButtonState: std.os.windows.DWORD,
                dwControlKeyState: std.os.windows.DWORD,
                dwEventFlags: std.os.windows.DWORD,
            };

            pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
                dwSize: std.os.windows.COORD,
            };

            pub const MENU_EVENT_RECORD = extern struct {
                dwCommandId: std.os.windows.UINT,
            };

            pub const FOCUS_EVENT_RECORD = extern struct {
                bSetFocus: std.os.windows.BOOL,
            };

            pub const INPUT_RECORD = extern struct {
                EventType: std.os.windows.WORD,
                Event: extern union {
                    KeyEvent: KEY_EVENT_RECORD,
                    MouseEvent: MOUSE_EVENT_RECORD,
                    WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
                    MenuEvent: MENU_EVENT_RECORD,
                    FocusEvent: FOCUS_EVENT_RECORD,
                },
            };

            pub extern "kernel32" fn ReadConsoleInputW(
                hConsoleInput: std.os.windows.HANDLE,
                lpBuffer: [*]INPUT_RECORD,
                nLength: std.os.windows.DWORD,
                lpNumberOfEventsRead: *std.os.windows.DWORD,
            ) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;

            pub extern "kernel32" fn PeekConsoleInputW(
                hConsoleInput: std.os.windows.HANDLE,
                lpBuffer: [*]INPUT_RECORD,
                nLength: std.os.windows.DWORD,
                lpNumberOfEventsRead: *std.os.windows.DWORD,
            ) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;

            pub const Tty = struct {
                allocator: std.mem.Allocator,
                old_out_mode: std.os.windows.DWORD,

                pub const Writer = struct {
                    allocator: std.mem.Allocator,

                    pub fn print(self: Writer, comptime format: []const u8, args: anytype) !void {
                        const bytes = try std.fmt.allocPrint(self.allocator, format, args);
                        defer self.allocator.free(bytes);
                        try self.writeAll(bytes);
                    }

                    pub fn writeByte(self: Writer, byte: u8) !void {
                        try self.writeAll(&[_]u8{byte});
                    }

                    pub fn writeAll(self: Writer, bytes: []const u8) !void {
                        const out_handle = std.io.getStdOut().handle;
                        const bytes_w = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, bytes);
                        defer self.allocator.free(bytes_w);
                        const num_chars_to_write: std.os.windows.DWORD = @intCast(try std.unicode.utf8CountCodepoints(bytes));
                        var num_chars_written: std.os.windows.DWORD = undefined;
                        if (0 == std.os.windows.kernel32.WriteConsoleW(out_handle, @ptrCast(bytes_w), num_chars_to_write, &num_chars_written, null)) {
                            return error.FailedToWriteConsoleW;
                        }
                    }
                };

                pub fn read(_: Tty, buffer: []u8) !usize {
                    const in_handle = std.io.getStdIn().handle;
                    var event_buffer: [1]INPUT_RECORD = undefined;
                    var num_events_read: std.os.windows.DWORD = undefined;
                    // check if there are any events to read
                    if (0 == PeekConsoleInputW(in_handle, @ptrCast(&event_buffer), event_buffer.len, &num_events_read)) {
                        return error.FailedToPeekConsoleInputW;
                    }
                    // exit early if there are none
                    if (num_events_read == 0) {
                        return 0;
                    }
                    // read events from the buffer
                    if (0 == ReadConsoleInputW(in_handle, @ptrCast(&event_buffer), event_buffer.len, &num_events_read)) {
                        return error.FailedToReadConsoleInputW;
                    }
                    var bytes_read: usize = 0;
                    for (0..num_events_read) |i| {
                        const event_type = event_buffer[i].EventType;
                        const event = event_buffer[i].Event;
                        switch (event_type) {
                            // KEY_EVENT
                            0x0001 => {
                                // ignore key up events
                                if (0 == event.KeyEvent.bKeyDown) {
                                    continue;
                                }
                                const bytes_read_old = bytes_read;
                                switch (event.KeyEvent.wVirtualKeyCode) {
                                    // LEFT ARROW
                                    0x25 => {
                                        const esc_code = "\x1B[D";
                                        bytes_read += esc_code.len;
                                        @memcpy(buffer[bytes_read_old..bytes_read], esc_code);
                                    },
                                    // UP ARROW
                                    0x26 => {
                                        const esc_code = "\x1B[A";
                                        bytes_read += esc_code.len;
                                        @memcpy(buffer[bytes_read_old..bytes_read], esc_code);
                                    },
                                    // RIGHT ARROW
                                    0x27 => {
                                        const esc_code = "\x1B[C";
                                        bytes_read += esc_code.len;
                                        @memcpy(buffer[bytes_read_old..bytes_read], esc_code);
                                    },
                                    // DOWN ARROW
                                    0x28 => {
                                        const esc_code = "\x1B[B";
                                        bytes_read += esc_code.len;
                                        @memcpy(buffer[bytes_read_old..bytes_read], esc_code);
                                    },
                                    else => continue,
                                }
                            },
                            // MOUSE_EVENT
                            0x0002 => {},
                            // WINDOW_BUFFER_SIZE_EVENT
                            0x0004 => {},
                            // MENU_EVENT
                            0x0008 => {},
                            // FOCUS_EVENT
                            0x0010 => {},
                            else => return error.UnrecognizedEventType,
                        }
                    }
                    return bytes_read;
                }

                pub fn writer(self: Tty) Writer {
                    return .{
                        .allocator = self.allocator,
                    };
                }
            };
        },
        else => struct {
            tty: std.fs.File,
            cooked_termios: std.posix.termios,
            raw: std.posix.termios,

            fn uncook(self: *Core) !void {
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

            fn cook(self: *Core) !void {
                const writer = self.tty.writer();
                try clearStyle(writer);
                try leaveAlt(writer);
                try showCursor(writer);
                try attributeReset(writer);
                try std.posix.tcsetattr(self.tty.handle, .FLUSH, self.cooked_termios);
            }
        },
    };

    pub fn init(allocator: std.mem.Allocator) !Terminal {
        switch (builtin.os.tag) {
            .windows => {
                const out_handle = std.io.getStdOut().handle;
                var old_out_mode: std.os.windows.DWORD = undefined;
                if (0 == std.os.windows.kernel32.GetConsoleMode(out_handle, &old_out_mode)) {
                    return error.FailedToGetConsoleMode;
                }
                const ENABLE_WRAP_AT_EOL_OUTPUT: std.os.windows.DWORD = 0x0002;
                const new_out_mode = old_out_mode & ~ENABLE_WRAP_AT_EOL_OUTPUT;
                if (0 == std.os.windows.kernel32.SetConsoleMode(out_handle, new_out_mode)) {
                    return error.FailedToSetConsoleMode;
                }
                var self = Terminal{
                    .core = .{
                        .tty = .{
                            .allocator = allocator,
                            .old_out_mode = old_out_mode,
                        },
                    },
                    .size = undefined,
                };
                try self.updateSize();
                try self.core.tty.writer().writeAll("\x1B[?1049h"); // clear screen
                return self;
            },
            else => {
                var tty = try std.fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
                errdefer tty.close();

                var self = Terminal{
                    .core = .{
                        .tty = tty,
                        .cooked_termios = undefined,
                        .raw = undefined,
                    },
                    .size = undefined,
                };

                try self.core.uncook();

                try self.updateSize();

                try std.posix.sigaction(std.posix.SIG.WINCH, &std.posix.Sigaction{
                    .handler = .{ .handler = handleSigWinch },
                    .mask = std.posix.empty_sigset,
                    .flags = 0,
                }, null);

                // set non-blocking
                self.core.raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
                self.core.raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
                try std.posix.tcsetattr(self.core.tty.handle, .NOW, self.core.raw);

                return self;
            },
        }
    }

    pub fn deinit(self: *Terminal) void {
        switch (builtin.os.tag) {
            .windows => {
                const out_handle = std.io.getStdOut().handle;
                _ = std.os.windows.kernel32.SetConsoleMode(out_handle, self.core.tty.old_out_mode);
            },
            else => {
                self.core.cook() catch {};
                self.core.tty.close();
            },
        }
    }

    pub fn updateSize(self: *Terminal) !void {
        switch (builtin.os.tag) {
            .windows => {
                const out_handle = std.io.getStdOut().handle;
                var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
                if (0 == std.os.windows.kernel32.GetConsoleScreenBufferInfo(out_handle, &info)) {
                    return error.FailedToGetConsoleScreenBufferInfo;
                }
                const width = info.srWindow.Right - info.srWindow.Left + 1;
                const height = info.srWindow.Bottom - info.srWindow.Top + 1;
                self.size = .{
                    .width = if (width < 0) 0 else @intCast(width),
                    .height = if (height < 0) 0 else @intCast(height),
                };
            },
            else => {
                var win_size = std.mem.zeroes(std.posix.winsize);
                const err = std.os.linux.ioctl(self.core.tty.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&win_size));
                if (std.posix.errno(err) != .SUCCESS) {
                    return std.posix.unexpectedErrno(@enumFromInt(err));
                }
                self.size = .{
                    .width = win_size.ws_col,
                    .height = win_size.ws_row,
                };
            },
        }
    }

    pub fn write(self: *Terminal, txt: []const u8, x: usize, y: usize) !void {
        if (y >= 0 and y < self.size.height) {
            const writer = self.core.tty.writer();
            try moveCursor(writer, x, y);
            try writer.writeAll(txt);
        }
    }

    pub fn writeHoriz(self: Terminal, char: []const u8, x: usize, y: usize, width: usize) !void {
        if (y >= 0 and y < self.size.height) {
            const writer = self.core.tty.writer();
            try moveCursor(writer, x, y);
            for (0..width) |_| {
                try writer.writeAll(char);
            }
        }
    }

    pub fn writeVert(self: Terminal, char: []const u8, x: usize, y: usize, height: usize) !void {
        if (y >= 0 and y < self.size.height) {
            const writer = self.core.tty.writer();
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
