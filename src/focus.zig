const std = @import("std");
const layout = @import("./layout.zig");

var next_id: usize = 0;

pub const Focus = struct {
    id: usize,
    focusable: bool,
    rects: std.AutoHashMap(usize, layout.URect),

    pub fn init(allocator: std.mem.Allocator) Focus {
        const id = next_id;
        next_id += 1;
        return .{
            .id = id,
            .focusable = false,
            .rects = std.AutoHashMap(usize, layout.URect).init(allocator),
        };
    }

    pub fn deinit(self: *Focus) void {
        self.rects.deinit();
    }

    pub fn addChild(self: *Focus, child: *const Focus, size: layout.Size, target_x: usize, target_y: usize) !void {
        if (child.focusable) {
            try self.rects.put(child.id, .{ .x = target_x, .y = target_y, .size = size });
        }
        var iter = child.rects.iterator();
        while (iter.next()) |entry| {
            const rect = entry.value_ptr.*;
            try self.rects.put(entry.key_ptr.*, .{ .x = target_x + rect.x, .y = target_y + rect.y, .size = rect.size });
        }
    }

    pub fn clear(self: *Focus) void {
        self.rects.clearRetainingCapacity();
    }
};
