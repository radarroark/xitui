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

    pub fn init(codepoint: u21, next_byte_maybe: ?u8, esc: *std.ArrayList(u8)) !?Key {
        const esc_len = esc.items.len;

        // sanity check
        if (esc_len == esc.capacity) {
            return error.EscCodeAtCapacity;
        }
        // we are in an esc sequence
        else if (esc_len > 0) {
            // esc sequences should be ascii-only
            const byte: u8 = std.math.cast(u8, codepoint) orelse return null;

            // the character after esc is part of the sequence and doesn't need to be looked at
            if (esc_len == 1) {
                esc.appendAssumeCapacity(byte);
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
                        'F' => .end,
                        'H' => .home,
                        '~' => blk: {
                            var codes = std.mem.splitSequence(u8, esc.items[2..], ";");
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
                    esc.clearRetainingCapacity();
                    return key;
                },
                // add all other chars to the esc sequence
                else => esc.appendAssumeCapacity(byte),
            }
        }
        // we are not in an esc sequence
        else {
            switch (codepoint) {
                'q' => return error.TerminalQuit,
                '\x1B' => {
                    if (next_byte_maybe) |next_byte| {
                        // sequence must start with [
                        if (next_byte == '[') {
                            esc.appendAssumeCapacity('\x1B');
                            return null;
                        }
                    }
                },
                else => {},
            }
            return .{ .codepoint = codepoint };
        }
        return null;
    }
};
