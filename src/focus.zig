const std = @import("std");
const layout = @import("./layout.zig");

var next_id: usize = 0;

pub const Focus = struct {
    id: usize,
    child_id: ?usize,
    focusable: bool,
    children: std.AutoHashMap(usize, Child),

    const Child = struct {
        parent_id: usize,
        rect: layout.URect,
    };

    pub fn init(allocator: std.mem.Allocator) Focus {
        const id = next_id;
        next_id += 1;
        return .{
            .id = id,
            .child_id = null,
            .focusable = false,
            .children = std.AutoHashMap(usize, Child).init(allocator),
        };
    }

    pub fn deinit(self: *Focus) void {
        self.children.deinit();
    }

    pub fn addChild(self: *Focus, child: *const Focus, size: layout.Size, target_x: usize, target_y: usize) !void {
        if (child.focusable) {
            try self.children.put(child.id, .{
                .parent_id = self.id,
                .rect = .{ .x = target_x, .y = target_y, .size = size },
            });
        }
        var iter = child.children.iterator();
        while (iter.next()) |entry| {
            const grandchild = entry.value_ptr.*;
            try self.children.put(entry.key_ptr.*, .{
                .parent_id = grandchild.parent_id,
                .rect = .{ .x = target_x + grandchild.rect.x, .y = target_y + grandchild.rect.y, .size = grandchild.rect.size },
            });
        }
    }

    pub fn clear(self: *Focus) void {
        self.children.clearRetainingCapacity();
    }
};
