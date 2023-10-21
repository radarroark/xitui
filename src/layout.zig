pub const Size = struct { width: usize, height: usize };
pub const MaybeSize = struct { width: ?usize, height: ?usize };
pub const Rect = struct { x: isize, y: isize, size: Size };
pub const Constraint = struct {
    min_size: MaybeSize,
    max_size: MaybeSize,
};
