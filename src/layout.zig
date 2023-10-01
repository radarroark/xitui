pub const Size = struct { width: usize, height: usize };
pub const MaxSize = struct { width: ?usize, height: ?usize };
pub const Rect = struct { x: isize, y: isize, size: Size };
