const std = @import("std");
const builtin = @import("builtin");
const inp = @import("./input.zig");
const Size = @import("./layout.zig").Size;
const grd = @import("./grid.zig");

const write_buffer_size = 4096;

pub const Core = switch (builtin.os.tag) {
    .windows => struct {
        tty: Tty,
        writer: std.io.BufferedWriter(write_buffer_size, Tty.Writer),
        allocator: std.mem.Allocator,

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
            old_out_mode: std.os.windows.DWORD,

            pub const Writer = struct {
                pub const Error = error{ InvalidUtf8, FailedToWriteConsoleW, UnexpectedCharCount } || std.unicode.Utf16LeIterator.NextCodepointError;

                pub fn print(self: Writer, comptime format: []const u8, args: anytype) !void {
                    var buffer = [_]u8{0} ** write_buffer_size;
                    const bytes = try std.fmt.bufPrint(&buffer, format, args);
                    try self.writeAll(bytes);
                }

                pub fn writeByte(self: Writer, byte: u8) !void {
                    try self.writeAll(&[_]u8{byte});
                }

                pub fn writeAll(self: Writer, utf8_bytes: []const u8) !void {
                    var total_written: usize = 0;
                    while (total_written < utf8_bytes.len) {
                        total_written += try self.write(utf8_bytes[total_written..]);
                    }
                }

                pub fn write(_: Writer, utf8_bytes: []const u8) !usize {
                    var utf16_buffer = [_]u16{0} ** write_buffer_size;
                    const size = try std.unicode.utf8ToUtf16Le(&utf16_buffer, utf8_bytes);
                    const utf16_bytes = utf16_buffer[0..size];

                    const num_chars = try std.unicode.utf16CountCodepoints(utf16_bytes);
                    var num_chars_written: std.os.windows.DWORD = undefined;

                    const out_handle = std.io.getStdOut().handle;
                    if (0 == std.os.windows.kernel32.WriteConsoleW(out_handle, utf16_bytes.ptr, @intCast(num_chars), &num_chars_written, null)) {
                        return error.FailedToWriteConsoleW;
                    }

                    // return the number of bytes written
                    if (num_chars == num_chars_written) {
                        return utf8_bytes.len;
                    } else {
                        const text = try std.unicode.Utf8View.init(utf8_bytes);
                        var iter = text.iterator();
                        var bytes_written: usize = 0;
                        for (0..num_chars_written) |_| {
                            const slice = iter.nextCodepointSlice() orelse return error.UnexpectedCharCount;
                            bytes_written += slice.len;
                        }
                        return bytes_written;
                    }
                }
            };

            pub fn writer(_: Tty) Writer {
                return .{};
            }
        };

        fn uncook(self: *Core) !void {
            const out_handle = std.io.getStdOut().handle;
            if (0 == std.os.windows.kernel32.GetConsoleMode(out_handle, &self.tty.old_out_mode)) {
                return error.FailedToGetConsoleMode;
            }
            const ENABLE_WRAP_AT_EOL_OUTPUT: std.os.windows.DWORD = 0x0002;
            const new_out_mode = self.tty.old_out_mode & ~ENABLE_WRAP_AT_EOL_OUTPUT;
            if (0 == std.os.windows.kernel32.SetConsoleMode(out_handle, new_out_mode)) {
                return error.FailedToSetConsoleMode;
            }
            errdefer self.cook() catch {};

            const writer = self.writer.writer();
            try hideCursor(writer);
            try enterAlt(writer);
            try clearStyle(writer);
            try self.writer.flush();
        }

        fn cook(self: *Core) !void {
            const writer = self.writer.writer();
            try clearStyle(writer);
            try leaveAlt(writer);
            try showCursor(writer);
            try attributeReset(writer);
            try self.writer.flush();

            const out_handle = std.io.getStdOut().handle;
            _ = std.os.windows.kernel32.SetConsoleMode(out_handle, self.tty.old_out_mode);
        }

        fn readKey(_: *Core) !?inp.Key {
            while (true) {
                const in_handle = std.io.getStdIn().handle;
                var event_buffer: [1]INPUT_RECORD = undefined;
                var num_events_read: std.os.windows.DWORD = undefined;
                // exit early if there is no event ready to read
                std.os.windows.WaitForSingleObject(in_handle, 0) catch |err| switch (err) {
                    error.WaitAbandoned => return null,
                    error.WaitTimeOut => return null,
                    error.Unexpected => |e| return e,
                };
                // read events from the buffer
                if (0 == ReadConsoleInputW(in_handle, @ptrCast(&event_buffer), event_buffer.len, &num_events_read)) {
                    return error.FailedToReadConsoleInputW;
                }
                const event_type = event_buffer[0].EventType;
                const event = event_buffer[0].Event;
                switch (event_type) {
                    // KEY_EVENT
                    0x0001 => {
                        // ignore key up events
                        if (0 == event.KeyEvent.bKeyDown) {
                            continue;
                        }
                        // if unicode char is not zero, return the codepoint
                        if (event.KeyEvent.uChar.UnicodeChar > 0) {
                            var utf8_buffer = [_]u8{0} ** 4;
                            const size = try std.unicode.utf16LeToUtf8(&utf8_buffer, &[_]u16{event.KeyEvent.uChar.UnicodeChar});
                            return .{ .codepoint = try std.unicode.utf8Decode(utf8_buffer[0..size]) };
                        }
                        // otherwise it's a non-printable key. key codes are listed here:
                        // https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
                        else {
                            return switch (event.KeyEvent.wVirtualKeyCode) {
                                0x21 => .page_up,
                                0x22 => .page_down,
                                0x23 => .end,
                                0x24 => .home,
                                0x25 => .arrow_left,
                                0x26 => .arrow_up,
                                0x27 => .arrow_right,
                                0x28 => .arrow_down,
                                else => continue,
                            };
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
        }
    },
    else => struct {
        tty: std.fs.File,
        writer: std.io.BufferedWriter(write_buffer_size, std.fs.File.Writer),
        allocator: std.mem.Allocator,
        cooked_termios: std.posix.termios,
        raw: std.posix.termios,
        esc_buffer: std.ArrayList(u8),
        key_queue: std.DoublyLinkedList(inp.Key),

        fn uncook(self: *Core) !void {
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

            const writer = self.writer.writer();
            try hideCursor(writer);
            try enterAlt(writer);
            try clearStyle(writer);
            try self.writer.flush();
        }

        fn cook(self: *Core) !void {
            const writer = self.writer.writer();
            try clearStyle(writer);
            try leaveAlt(writer);
            try showCursor(writer);
            try attributeReset(writer);
            try self.writer.flush();

            try std.posix.tcsetattr(self.tty.handle, .FLUSH, self.cooked_termios);
        }

        fn initKey(self: *Core, codepoint: u21, next_byte_maybe: ?u8) !?inp.Key {
            const esc_len = self.esc_buffer.items.len;

            // sanity check
            if (esc_len == self.esc_buffer.capacity) {
                return error.EscCodeAtCapacity;
            }
            // we are in an esc sequence
            else if (esc_len > 0) {
                // esc sequences should be ascii-only
                const byte: u8 = std.math.cast(u8, codepoint) orelse return null;

                // the character after esc is part of the sequence and doesn't need to be looked at
                if (esc_len == 1) {
                    self.esc_buffer.appendAssumeCapacity(byte);
                    return null;
                }

                // return key or add byte to esc sequence
                switch (byte) {
                    // chars that terminate the sequence
                    0x40...0x7E => {
                        const key: inp.Key = switch (byte) {
                            'A' => .arrow_up,
                            'B' => .arrow_down,
                            'C' => .arrow_right,
                            'D' => .arrow_left,
                            'F' => .end,
                            'H' => .home,
                            '~' => blk: {
                                var codes = std.mem.splitSequence(u8, self.esc_buffer.items[2..], ";");
                                const code = codes.first();
                                break :blk if (std.mem.eql(u8, code, "1"))
                                    .home
                                else if (std.mem.eql(u8, code, "4"))
                                    .end
                                else if (std.mem.eql(u8, code, "5"))
                                    .page_up
                                else if (std.mem.eql(u8, code, "6"))
                                    .page_down
                                else
                                    .unknown;
                            },
                            else => .unknown,
                        };
                        self.esc_buffer.clearRetainingCapacity();
                        return key;
                    },
                    // add all other chars to the esc sequence
                    else => self.esc_buffer.appendAssumeCapacity(byte),
                }
            }
            // we are not in an esc sequence
            else {
                if ('\x1B' == codepoint) {
                    if (next_byte_maybe) |next_byte| {
                        // sequence must start with [
                        if (next_byte == '[') {
                            self.esc_buffer.appendAssumeCapacity('\x1B');
                            return null;
                        }
                    }
                }
                return .{ .codepoint = codepoint };
            }
            return null;
        }

        fn readKey(self: *Core) !?inp.Key {
            defer self.esc_buffer.clearRetainingCapacity();

            // if there is any key in the queue, return it
            if (self.key_queue.popFirst()) |node| {
                const key = node.data;
                self.allocator.destroy(node);
                return key;
            }

            const buffer_size = 32;
            var buffer: [buffer_size]u8 = undefined;
            const size = try self.tty.read(&buffer);
            var key_maybe: ?inp.Key = null;

            if (size > 0) {
                const text = std.unicode.Utf8View.init(buffer[0..size]) catch return null;
                var iter = text.iterator();
                while (iter.nextCodepoint()) |codepoint| {
                    const next_bytes = iter.peek(1);
                    if (try self.initKey(codepoint, if (next_bytes.len == 1) next_bytes[0] else null)) |key| {
                        if (key_maybe == null) {
                            key_maybe = key;
                        } else {
                            var node = try self.allocator.create(std.DoublyLinkedList(inp.Key).Node);
                            errdefer self.allocator.free(node);
                            node.data = key;
                            self.key_queue.append(node);
                        }
                    }
                }
            }

            return key_maybe;
        }
    },
};

pub const Terminal = struct {
    core: Core,
    size: Size,

    pub fn init(allocator: std.mem.Allocator) !Terminal {
        switch (builtin.os.tag) {
            .windows => {
                const tty = Core.Tty{
                    .old_out_mode = undefined,
                };

                var self = Terminal{
                    .core = .{
                        .tty = tty,
                        .writer = std.io.BufferedWriter(write_buffer_size, Core.Tty.Writer){ .unbuffered_writer = tty.writer() },
                        .allocator = allocator,
                    },
                    .size = .{ .width = 0, .height = 0 },
                };

                try self.core.uncook();
                errdefer self.core.cook() catch {};

                try self.core.writer.unbuffered_writer.writeAll("\x1B[?1049h"); // clear screen
                self.size = try self.getSize();

                return self;
            },
            else => {
                var tty = try std.fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
                errdefer tty.close();

                // just needs to be able to hold the largest possible escape code
                var esc_buffer = try std.ArrayList(u8).initCapacity(allocator, 32);
                errdefer esc_buffer.deinit();

                var self = Terminal{
                    .core = .{
                        .tty = tty,
                        .writer = std.io.BufferedWriter(write_buffer_size, std.fs.File.Writer){ .unbuffered_writer = tty.writer() },
                        .allocator = allocator,
                        .cooked_termios = undefined,
                        .raw = undefined,
                        .esc_buffer = esc_buffer,
                        .key_queue = std.DoublyLinkedList(inp.Key){},
                    },
                    .size = .{ .width = 0, .height = 0 },
                };

                try self.core.uncook();
                errdefer self.core.cook() catch {};

                // set non-blocking
                self.core.raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
                self.core.raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
                try std.posix.tcsetattr(self.core.tty.handle, .NOW, self.core.raw);

                self.size = try self.getSize();

                return self;
            },
        }
    }

    pub fn deinit(self: *Terminal) void {
        switch (builtin.os.tag) {
            .windows => {
                self.core.cook() catch {};
            },
            else => {
                self.core.cook() catch {};
                self.core.esc_buffer.deinit();
                while (self.core.key_queue.popFirst()) |node| {
                    self.core.allocator.destroy(node);
                }
                self.core.tty.close();
            },
        }
    }

    pub fn getSize(self: *const Terminal) !Size {
        switch (builtin.os.tag) {
            .windows => {
                const out_handle = std.io.getStdOut().handle;
                var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
                if (0 == std.os.windows.kernel32.GetConsoleScreenBufferInfo(out_handle, &info)) {
                    return error.FailedToGetConsoleScreenBufferInfo;
                }
                const width = info.srWindow.Right - info.srWindow.Left + 1;
                const height = info.srWindow.Bottom - info.srWindow.Top + 1;
                return .{
                    .width = if (width < 0) 0 else @intCast(width),
                    .height = if (height < 0) 0 else @intCast(height),
                };
            },
            else => {
                try std.posix.tcsetattr(self.core.tty.handle, .FLUSH, self.core.raw);
                var win_size = std.mem.zeroes(std.posix.winsize);
                const err = std.os.linux.ioctl(self.core.tty.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&win_size));
                if (std.posix.errno(err) != .SUCCESS) {
                    return std.posix.unexpectedErrno(@enumFromInt(err));
                }
                return .{
                    .width = win_size.col,
                    .height = win_size.row,
                };
            },
        }
    }

    pub fn readKey(self: *Terminal) !?inp.Key {
        return try self.core.readKey();
    }

    fn write(self: *Terminal, txt: []const u8, x: usize, y: usize) !void {
        if (y >= 0 and y < self.size.height) {
            const writer = self.core.writer.writer();
            try moveCursor(writer, x, y);
            try writer.writeAll(txt);
        }
    }

    pub fn render(self: *Terminal, root_widget: anytype, last_grid: *grd.Grid, last_size: *Size) !void {
        self.size = try self.getSize();

        const root_size = Size{ .width = self.size.width, .height = self.size.height };
        if (root_size.width == 0 or root_size.height == 0) {
            return;
        }

        // determine if the grid must be refreshed
        var force_refresh = false;
        if (last_size.*.width != root_size.width or last_size.*.height != root_size.height) {
            force_refresh = true;
        } else if (root_widget.getGrid()) |grid| {
            if (last_grid.size.width != grid.size.width or last_grid.size.height != grid.size.height) {
                force_refresh = true;
            }
        }

        if (force_refresh) {
            // rebuild the root widget
            try root_widget.build(.{
                .min_size = .{ .width = null, .height = null },
                .max_size = .{ .width = root_size.width, .height = root_size.height },
            }, root_widget.getFocus());
            try clearRect(self.core.writer.writer(), 0, 0, root_size);
            last_size.* = root_size;

            // render the grid
            if (root_widget.getGrid()) |grid| {
                last_grid.deinit();
                last_grid.* = try grd.Grid.initFromGrid(self.core.allocator, grid, grid.size, 0, 0);
                for (0..grid.size.height) |y| {
                    for (0..grid.size.width) |x| {
                        if (grid.cells.items[try grid.cells.at(.{ y, x })].rune) |rune| {
                            try self.write(rune, x, y);
                        }
                    }
                }
            }
        } else {
            if (root_widget.getGrid()) |grid| {
                // clear cells that are in last grid but not current grid
                for (0..last_grid.size.height) |y| {
                    for (0..last_grid.size.width) |x| {
                        if (grid.cells.items[try grid.cells.at(.{ y, x })].rune == null) {
                            try self.write(" ", x, y);
                        }
                    }
                }

                // render the grid
                for (0..grid.size.height) |y| {
                    for (0..grid.size.width) |x| {
                        if (grid.cells.items[try grid.cells.at(.{ y, x })].rune) |rune| {
                            try self.write(rune, x, y);
                        }
                    }
                }
            }
        }

        try self.core.writer.flush();
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
