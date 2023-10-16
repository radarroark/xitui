const std = @import("std");
const runtime_safety = std.debug.runtime_safety;
const mem = std.mem;

const NDSliceErrors = error{
    InsufficientBufferSize,
    IndexOutOfBounds,
};

pub const MemoryOrdering = enum {
    // least signficant dimension last: [z, y, x] where consecutive x's are contiguous
    row_major,
    // least signficant dimension first: [z, y, x] where consecutive z's are contiguous
    col_major,
};

pub fn NDSlice(comptime T: type, comptime N: comptime_int, comptime order_val: MemoryOrdering) type {
    return struct {
        const Self = @This();

        // length in each dimension {x0, x1, x2, ... xN-1}
        shape: [N]usize,

        // underlying memory used to store the individual items
        // is shrunk to the required size (buffer.len will yield number of elements)
        items: []T,

        pub const order = order_val;

        // memory used has to be passed in
        pub fn init(shape: [N]usize, buffer: []T) !Self {
            var num_items: usize = 1;
            for (shape) |s| {
                num_items *= s;
            }
            if (num_items > buffer.len) return NDSliceErrors.InsufficientBufferSize;

            return Self{
                .shape = shape,
                .items = buffer[0..num_items],
            };
        }

        // computes the linear index of an element
        pub fn at(self: Self, index: [N]usize) !usize {
            if (runtime_safety) {
                for (index, 0..) |index_i, i| {
                    if (index_i >= self.shape[i]) return NDSliceErrors.IndexOutOfBounds;
                }
            }

            return switch (order) {
                .row_major => blk: {
                    // linear index = ( ... ((i0*s1 + i1)*s2 + i2)*s3 + ... )*s(N-1) + i(N-1)
                    var linear_index = index[0];

                    comptime var i = 1;
                    inline while (i < N) : (i += 1) {
                        linear_index = linear_index * self.shape[i] + index[i]; // single fused multiply add
                    }

                    break :blk linear_index;
                },
                .col_major => blk: {
                    // linear index = i0 + s0*(i1 + s1*(i2 + s2*(...(i(N-2) + s(N-2)*i(N-1)) ... ))
                    var linear_index = index[N - 1];

                    comptime var i = N - 2;
                    inline while (i >= 0) : (i -= 1) {
                        linear_index = linear_index * self.shape[i] + index[i]; // single fused mutiply add
                    }

                    break :blk linear_index;
                },
            };
        }
    };
}

test "simple slice" {
    // creates a 2D slice type we can use to represent images, its a MxN slice of triplets of RGB values
    const ImageSlice = NDSlice([3]u8, 2, .row_major);

    // we need to create a buffer to put the slice on
    var image_buffer = [_][3]u8{.{ 0, 0, 0 }} ** 30; // 6x5 image (width X height)

    // this slice is created over that buffer.
    const image = try ImageSlice.init(.{ 5, 6 }, &image_buffer); // by convention height is the first dimension

    // use .at() and .items() to access members.
    image.items[try image.at(.{ 0, 0 })] = .{ 1, 2, 3 };
    image.items[try image.at(.{ 1, 1 })] = .{ 50, 50, 50 };
    image.items[try image.at(.{ 4, 5 })] = .{ 128, 255, 0 };
    image.items[try image.at(.{ 2, 4 })] = .{ 100, 12, 30 };

    // you can get each of the individual dimensions with .shape
    // and for the total number of elements use .items.len
}
