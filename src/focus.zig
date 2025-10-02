const std = @import("std");
const layout = @import("./layout.zig");

var next_id: usize = 0;

pub const FocusKind = union(enum) {
    none,
    focusable,
    editable: struct { x: usize, y: usize },
};

pub const Focus = struct {
    id: usize,
    child_id: ?usize,
    grandchild_id: ?usize,
    focus_kind: FocusKind,
    children: std.AutoHashMap(usize, Child),

    const Child = struct {
        parent_id: usize,
        focus: *Focus,
        rect: layout.URect,
    };

    pub fn init(allocator: std.mem.Allocator) Focus {
        const id = next_id;
        next_id += 1;
        return .{
            .id = id,
            .child_id = null,
            .grandchild_id = null,
            .focus_kind = .none,
            .children = std.AutoHashMap(usize, Child).init(allocator),
        };
    }

    pub fn deinit(self: *Focus) void {
        self.children.deinit();
    }

    pub fn addChild(self: *Focus, child: *Focus, size: layout.Size, target_x: usize, target_y: usize) !void {
        try self.children.put(child.id, .{
            .parent_id = self.id,
            .focus = child,
            .rect = .{ .x = target_x, .y = target_y, .size = size },
        });
        var iter = child.children.iterator();
        while (iter.next()) |entry| {
            const grandchild = entry.value_ptr.*;
            try self.children.put(entry.key_ptr.*, .{
                .parent_id = grandchild.parent_id,
                .focus = grandchild.focus,
                .rect = .{ .x = target_x + grandchild.rect.x, .y = target_y + grandchild.rect.y, .size = grandchild.rect.size },
            });
        }
    }

    pub fn clear(self: *Focus) void {
        self.children.clearRetainingCapacity();
    }

    pub fn setFocus(self: *Focus, grandchild_id: usize) !void {
        var id = grandchild_id;
        // find the nearest child to grandchild_id that is focusable
        while (self.children.get(id)) |child| {
            if (child.focus.focus_kind != .none) {
                break;
            } else if (child.focus.child_id) |next_child_id| {
                id = next_child_id;
            } else {
                return;
            }
        }
        // set the child_id of all parents so the id is focused
        self.grandchild_id = id;
        while (self.children.get(id)) |child| {
            if (self.children.get(child.parent_id)) |*parent| {
                parent.focus.child_id = id;
            } else if (child.parent_id == self.id) {
                self.child_id = id;
            }
            id = child.parent_id;
        }
    }
};
