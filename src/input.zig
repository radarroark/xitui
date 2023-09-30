const std = @import("std");

pub const Key = union(enum) {
    unknown,
    arrow_up,
    arrow_down,
    arrow_right,
    arrow_left,
    home,
    end,
    page_up,
    page_down,
    codepoint: u21,

    pub fn init(codepoint: u21, esc: *std.ArrayList(u8)) !?Key {
        // if we are in an esc sequence
        if (esc.items.len > 0) {
            // esc sequences should be ascii-only
            const byte: u8 = std.math.cast(u8, codepoint) orelse return null;

            // sequence must start with [
            if (esc.items.len == 1) {
                if (byte == '[') {
                    try esc.append(byte);
                } else {
                    esc.clearAndFree();
                }
                return null;
            }

            // return key or add byte to esc sequence
            switch (byte) {
                // chars that terminate the sequence
                0x40...0x7E => {
                    const key: Key = switch (byte) {
                        'A' => .arrow_up,
                        'B' => .arrow_down,
                        'C' => .arrow_right,
                        'D' => .arrow_left,
                        '~' => if (std.mem.eql(u8, esc.items[2..], "1"))
                            .home
                        else if (std.mem.eql(u8, esc.items[2..], "4"))
                            .end
                        else if (std.mem.eql(u8, esc.items[2..], "5"))
                            .page_up
                        else if (std.mem.eql(u8, esc.items[2..], "6"))
                            .page_down
                        else
                            .unknown,
                        else => .unknown,
                    };
                    esc.clearAndFree();
                    return key;
                },
                // add all other chars to the esc sequence
                else => try esc.append(byte),
            }
        }
        // not in an esc sequence
        else {
            switch (codepoint) {
                'q' => return error.TerminalQuit,
                '\x1B' => try esc.append('\x1B'),
                else => return .{ .codepoint = codepoint },
            }
        }
        return null;
    }
};
