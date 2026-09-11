const std = @import("std");
const xitui = @import("xitui");
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const StreamTerminal = xitui.stream_terminal.StreamTerminal;

pub const Widget = union(enum) {
    text: wgt.Text,
    box: wgt.Box(Widget),
    text_box: wgt.TextBox,
    text_input: wgt.TextInput,
    scroll: wgt.Scroll(Widget),

    pub fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }

    pub fn build(self: *Widget, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(allocator, constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(allocator, key, root_focus),
        }
    }

    pub fn clearGrid(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.clearGrid(),
        }
    }

    pub fn getGrid(self: Widget) ?Grid {
        switch (self) {
            inline else => |*case| return case.getGrid(),
        }
    }

    pub fn getFocus(self: *Widget) *Focus {
        switch (self.*) {
            inline else => |*case| return case.getFocus(),
        }
    }
};

test "text box" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "Hello, world!", .{ .border_style = .single, .wrap_kind = .none }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings(
        \\┌─────────────┐
        \\│Hello, world!│
        \\└─────────────┘
    , str);
}

test "box grow child fills remaining minimum" {
    const allocator = std.testing.allocator;

    var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
    errdefer box.deinit(allocator);

    var left = try wgt.Text.init(allocator, "left");
    errdefer left.deinit(allocator);
    try box.children.put(allocator, left.getFocus().id, .{
        .widget = .{ .text = left },
        .rect = null,
        .min_size = .{ .width = 4, .height = null },
    });

    var spacer = try wgt.TextBox.init(allocator, "", .{ .border_style = null, .wrap_kind = .none });
    errdefer spacer.deinit(allocator);
    const spacer_id = spacer.getFocus().id;
    try box.children.put(allocator, spacer_id, .{
        .widget = .{ .text_box = spacer },
        .rect = null,
        .min_size = null,
        .flex = .grow,
    });

    var right = try wgt.Text.init(allocator, "right");
    errdefer right.deinit(allocator);
    try box.children.put(allocator, right.getFocus().id, .{
        .widget = .{ .text = right },
        .rect = null,
        .min_size = .{ .width = 5, .height = null },
    });

    var widget = Widget{ .box = box };
    defer widget.deinit(allocator);
    try widget.build(allocator, .{
        .min_size = .{ .width = 20, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("left           right", str);
    const spacer_child = widget.box.children.get(spacer_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 11), spacer_child.rect.?.size.width);
}

test "box shrink measurement does not change child constraints" {
    const allocator = std.testing.allocator;

    var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
    errdefer box.deinit(allocator);

    var shrinking = try wgt.TextBox.init(allocator, "abcdefghij", .{ .border_style = null, .wrap_kind = .none });
    errdefer shrinking.deinit(allocator);
    const shrinking_id = shrinking.getFocus().id;
    try box.children.put(allocator, shrinking_id, .{
        .widget = .{ .text_box = shrinking },
        .rect = null,
        .min_size = null,
        .flex = .shrink,
    });

    var fixed = try wgt.Text.init(allocator, "fixed");
    errdefer fixed.deinit(allocator);
    try box.children.put(allocator, fixed.getFocus().id, .{
        .widget = .{ .text = fixed },
        .rect = null,
        .min_size = .{ .width = 5, .height = null },
    });

    var widget = Widget{ .box = box };
    defer widget.deinit(allocator);
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 8, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("abcfixed", str);
    }
    const shrinking_child = widget.box.children.get(shrinking_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(shrinking_child.min_size == null);
    try std.testing.expect(shrinking_child.max_size == null);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("abcdefghijfixed", str);
}

test "text box with wrapping" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "Hello, world!\nGöödbye, world!", .{ .border_style = .single, .wrap_kind = .char }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 10, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\┌────────┐
            \\│Hello, w│
            \\│orld!   │
            \\│Göödbye,│
            \\│ world! │
            \\└────────┘
        , str);
    }

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 12, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\┌──────────┐
            \\│Hello, wor│
            \\│ld!       │
            \\│Göödbye, w│
            \\│orld!     │
            \\└──────────┘
        , str);
    }

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 12, .height = null },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\┌──────────┐
            \\│Hello, wor│
            \\│ld!       │
            \\│Göödbye, w│
            \\│orld!     │
            \\└──────────┘
        , str);
    }
}

test "text box with wide characters" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "你好, world!", .{ .border_style = .single, .wrap_kind = .none }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    // 你好 occupies four columns, so the border must span 12, not 10
    try std.testing.expectEqualStrings(
        \\┌────────────┐
        \\│你好, world!│
        \\└────────────┘
    , str);
}

test "text box char-wraps wide characters by columns" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "你好世界", .{ .border_style = .single, .wrap_kind = .char }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 6, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    // four wide runes are eight columns: two per line at inner width 4
    try std.testing.expectEqualStrings(
        \\┌────┐
        \\│你好│
        \\│世界│
        \\└────┘
    , str);
}

test "text box wraps a wide character that does not fit the last column" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "ab你好", .{ .border_style = .single, .wrap_kind = .char }) };
    defer widget.deinit(allocator);

    // inner width 5: "ab" (2) + 你 (2) fit, but 好 would straddle the edge,
    // so it wraps early and leaves the fifth column blank
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 7, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings(
        \\┌────┐
        \\│ab你│
        \\│好  │
        \\└────┘
    , str);
}

test "text box word-wraps an unbroken wide run by columns" {
    const allocator = std.testing.allocator;

    // no spaces to break at, so the run is longer than a line and falls
    // back to char-wrapping — which must count columns, not codepoints
    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "你好世界你好", .{ .border_style = .single, .wrap_kind = .word }) };
    defer widget.deinit(allocator);

    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 6, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings(
        \\┌────┐
        \\│你好│
        \\│世界│
        \\│你好│
        \\└────┘
    , str);
}

test "horizontal scroll clips wide characters at the view edges" {
    const allocator = std.testing.allocator;

    const text = Widget{ .text = try wgt.Text.init(allocator, "你好世界") };
    var widget = Widget{ .scroll = try wgt.Scroll(Widget).init(allocator, text, .{ .direction = .horiz, .show_bar = false }) };
    defer widget.deinit(allocator);

    // viewport of 3 columns at offset 0: 你 fits, 好's lead is cut at the
    // right edge and renders as a blank column
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 3, .height = 1 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings("你 ", str);
    }

    // offset 1: the left edge lands mid-你, blanking its trailing half
    widget.scroll.x = 1;
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 3, .height = 1 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);
        try std.testing.expectEqualStrings(" 好", str);
    }
}

test "text input scrolls wide content by columns" {
    const allocator = std.testing.allocator;

    var widget = Widget{ .text_input = try wgt.TextInput.init(allocator, .{ .border_style = null, .visible_width = 4 }) };
    defer widget.deinit(allocator);

    // 你(2) 好(2) a b c: the cursor lands past 'c', so the window slides
    // until the tail fits — 你 and 好 scroll out entirely
    try widget.text_input.setContent(allocator, "你好abc");
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = null, .height = null },
    }, widget.getFocus());

    const str = try widget.getGrid().?.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("abc ", str);
}

test "vertical scroll bar" {
    const allocator = std.testing.allocator;

    const text_box = Widget{ .text_box = try wgt.TextBox.init(allocator, "aaaa\nbbbb\ncccc\ndddd\neeee\nffff", .{ .border_style = null, .wrap_kind = .none }) };
    var widget = Widget{ .scroll = try wgt.Scroll(Widget).init(allocator, text_box, .{ .direction = .vert, .show_bar = true }) };
    defer widget.deinit(allocator);

    // content is 6 rows tall, the viewport only 3, so the thumb covers half
    // the track. the bar takes the far right column, narrowing content to 4.
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 5, .height = 3 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\aaaa█
            \\bbbb█
            \\cccc░
        , str);
    }

    // scroll to the bottom; the thumb slides down to the end of the track.
    widget.scroll.scrollToRect(.{ .x = 0, .y = 5, .size = .{ .width = 1, .height = 1 } });
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 5, .height = 3 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\dddd░
            \\eeee█
            \\ffff█
        , str);
    }
}

test "scroll bar hidden when content fits" {
    const allocator = std.testing.allocator;

    const text_box = Widget{ .text_box = try wgt.TextBox.init(allocator, "aaaa\nbbbb\ncccc", .{ .border_style = null, .wrap_kind = .none }) };
    var widget = Widget{ .scroll = try wgt.Scroll(Widget).init(allocator, text_box, .{ .direction = .vert, .show_bar = true }) };
    defer widget.deinit(allocator);

    // the viewport is taller than the content, so nothing scrolls: no bar is
    // drawn and no column is reserved (content keeps its full width).
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 5, .height = 5 },
    }, widget.getFocus());

    {
        const str = try widget.getGrid().?.toString(allocator);
        defer allocator.free(str);

        try std.testing.expectEqualStrings(
            \\aaaa
            \\bbbb
            \\cccc
        , str);
    }
}

test "StreamTerminal parses a CSI arrow key" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("\x1B[A");
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
}

test "StreamTerminal parses ctrl+letter" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // ctrl+a and ctrl+r are C0 control chars
    try terminal.writeBytes("\x01\x12");
    try std.testing.expectEqual(@as(?inp.Key, .{ .ctrl = 'a' }), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, .{ .ctrl = 'r' }), terminal.popKey());

    // ctrl+h, ctrl+i, and ctrl+m still arrive as their named keys
    try terminal.writeBytes("\x08\x09\x0D");
    try std.testing.expectEqual(@as(?inp.Key, .backspace), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, .tab), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, .enter), terminal.popKey());
}

test "StreamTerminal parses alt+letter" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("\x1Bx");
    try std.testing.expectEqual(@as(?inp.Key, .{ .alt = 'x' }), terminal.popKey());

    // a lone ESC is held back — the next frame may carry the rest of a
    // sequence — until the driver flushes it
    try terminal.writeBytes("\x1B");
    try std.testing.expectEqual(@as(?inp.Key, null), terminal.popKey());
    try terminal.flushEscape();
    try std.testing.expectEqual(@as(?inp.Key, .escape), terminal.popKey());
}

test "StreamTerminal keeps keys in arrival order across feeds" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("ab");
    try terminal.writeBytes("cd");

    var got: [4]u8 = undefined;
    for (&got) |*g| g.* = @intCast(terminal.popKey().?.codepoint);
    try std.testing.expectEqualStrings("abcd", &got);
}

test "StreamTerminal resolves utf-8 split across feeds" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("a\xe2");
    try terminal.writeBytes("\x82");
    try terminal.writeBytes("\xacb");

    try std.testing.expectEqual(@as(u21, 'a'), terminal.popKey().?.codepoint);
    try std.testing.expectEqual(@as(u21, '€'), terminal.popKey().?.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), terminal.popKey().?.codepoint);
}

test "StreamTerminal resolves a sequence split across feeds" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try terminal.writeBytes("\x1B");
    try terminal.writeBytes("[A");
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, null), terminal.popKey());

    // split mid-parameter too
    try terminal.writeBytes("\x1B[1");
    try terminal.writeBytes("5~");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 5 }), terminal.popKey());
}

test "StreamTerminal survives an over-long escape sequence" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // a device attributes reply longer than the parser's scratch buffer: it
    // reports as one unknown key, tail and all, and input keeps working
    try terminal.writeBytes("\x1B[?" ++ ("1;" ** 100) ++ "2c");
    try std.testing.expectEqual(@as(?inp.Key, .unknown), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, null), terminal.popKey());

    try terminal.writeBytes("\x1B[Aq");
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
    try std.testing.expectEqual(@as(u21, 'q'), terminal.popKey().?.codepoint);
}

test "StreamTerminal reports repeated escape presses" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // ESC followed by a control byte can't be an alt combo, so the first ESC
    // resolves on its own and the second opens the next sequence
    try terminal.writeBytes("\x1B\x1B[A");
    try std.testing.expectEqual(@as(?inp.Key, .escape), terminal.popKey());
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
}

test "StreamTerminal parses function keys and insert" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // F1 — SS3 style
    try terminal.writeBytes("\x1BOP");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 1 }), terminal.popKey());

    // F2 — old xterm/rxvt CSI style
    try terminal.writeBytes("\x1B[12~");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 2 }), terminal.popKey());

    // F5 and F12 — CSI style, with the historical gaps in the code sequence
    try terminal.writeBytes("\x1B[15~");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 5 }), terminal.popKey());
    try terminal.writeBytes("\x1B[24~");
    try std.testing.expectEqual(@as(?inp.Key, .{ .f = 12 }), terminal.popKey());

    try terminal.writeBytes("\x1B[2~");
    try std.testing.expectEqual(@as(?inp.Key, .insert), terminal.popKey());
}

test "StreamTerminal parses codepoints and queues extras" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    // arrow up followed by 'q' in a single byte feed — the parser returns
    // the arrow first and queues the codepoint for the next pop.
    try terminal.writeBytes("\x1B[Aq");
    try std.testing.expectEqual(@as(?inp.Key, .arrow_up), terminal.popKey());
    const second = terminal.popKey();
    try std.testing.expect(second != null);
    try std.testing.expectEqual(@as(u21, 'q'), second.?.codepoint);
}

test "StreamTerminal resize injection" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    terminal.pushResize(.{ .width = 100, .height = 30 });

    try std.testing.expectEqual(@as(?inp.Key, .{ .event = .resize }), terminal.popKey());
    try std.testing.expectEqual(@as(usize, 100), terminal.getSize().width);
    try std.testing.expectEqual(@as(usize, 30), terminal.getSize().height);
}

test "StreamTerminal quit injection" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });
    defer terminal.deinit();

    try std.testing.expect(!terminal.shouldQuit());
    terminal.requestQuit();
    try std.testing.expect(terminal.shouldQuit());
}

test "StreamTerminal renders a widget tree" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 20, .height = 5 });
    defer terminal.deinit();

    // drop the startup bytes (alt-screen enter, mouse enable, etc.) so we
    // can examine only what render emits.
    const startup_len = output.written().len;

    var widget = Widget{ .text_box = try wgt.TextBox.init(allocator, "hello", .{ .border_style = .single, .wrap_kind = .none }) };
    defer widget.deinit(allocator);

    _ = try terminal.render(&widget);

    const rendered = output.written()[startup_len..];
    // we should see the rune 'h' from "hello" written somewhere in the output
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, 'h') != null);
    // and a cursor move for the first run
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1B[") != null);

    const unchanged_start = output.written().len;
    try std.testing.expect(!try terminal.render(&widget));
    try std.testing.expectEqualStrings(
        "",
        output.written()[unchanged_start..],
    );

    try widget.text_box.setContent(allocator, "jello");
    try widget.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 20, .height = 5 },
    }, widget.getFocus());

    const changed_start = output.written().len;
    try std.testing.expect(try terminal.render(&widget));
    try std.testing.expectEqualStrings(
        "\x1B[?2026h\x1B[2;2Hj\x1B[?2026l",
        output.written()[changed_start..],
    );

    const grid = &widget.text_box.grid.?;
    (try grid.cell(1, 1)).style.inverted = true;

    const styled_start = output.written().len;
    try std.testing.expect(try terminal.render(&widget));
    try std.testing.expectEqualStrings(
        "\x1B[?2026h\x1B[2;2H\x1B[7mj\x1B[0m\x1B[?2026l",
        output.written()[styled_start..],
    );
}

test "cursor control sequence stays whole at a writer boundary" {
    const ChunkWriter = struct {
        output: std.Io.Writer.Allocating,
        interface: std.Io.Writer,

        fn init(allocator: std.mem.Allocator, buffer: []u8) @This() {
            return .{
                .output = .init(allocator),
                .interface = .{
                    .vtable = &.{ .drain = drain },
                    .buffer = buffer,
                },
            };
        }

        fn deinit(self: *@This()) void {
            self.output.deinit();
        }

        fn drain(writer: *std.Io.Writer, _: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            if (splat != 1) return error.WriteFailed;
            const self: *@This() = @alignCast(@fieldParentPtr("interface", writer));
            self.output.writer.writeAll(writer.buffered()) catch return error.WriteFailed;
            self.output.writer.writeByte('|') catch return error.WriteFailed;
            return writer.consumeAll();
        }
    };

    var buffer: [8]u8 = undefined;
    var writer = ChunkWriter.init(std.testing.allocator, &buffer);
    defer writer.deinit();

    try writer.interface.writeAll("xxxxxx");
    try xitui.terminal.moveCursor(&writer.interface, 101, 0);
    try writer.interface.flush();

    try std.testing.expectEqualStrings(
        "xxxxxx|\x1B[1;102H|",
        writer.output.written(),
    );
}

test "StreamTerminal init and deinit emit alt-screen lifecycle" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var terminal = try StreamTerminal.init(allocator, &output.writer, .{ .width = 80, .height = 24 });

    // after init we expect the alt-screen enter sequence and the hide-cursor sequence
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1B[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1B[?25l") != null);

    terminal.deinit();

    // after deinit we expect the leave-alt sequence and show-cursor
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1B[?1049l") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1B[?25h") != null);
}
