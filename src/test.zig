const std = @import("std");

pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

test "xitui" {
    try expectEqual(1, 1);
}
