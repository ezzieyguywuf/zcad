const std = @import("std");

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("Welcome to zcad debugging stream\n", .{});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Welcome to zcad.\n", .{});

    try bw.flush(); // Don't forget to flush!
}

// This is unitless, and an unsigned integer by design. For higher precision
// maths, simply scale these values differently - for example, if 1000
// represents the value "1 inch", then this provides precision to 0.001 of an
// inch.
//
// For reference, let's say you needed 0.000001 inches precision, then these
// u64's could represent up to ~18.4e13 inches, or 291 million miles (roughly
// twice the distance from the sun to mars).
const Point = struct {
    x: u64,
    y: u64,
    z: u64,

    pub fn Equals(self: Point, other: Point) bool {
        return self.x == other.x and self.y == other.y and self.z == other.z;
    }
};

test "Point equality" {
    const p1 = Point{ .x = 10, .y = 1000, .z = 10000 };
    const p2 = Point{ .x = 10, .y = 1000, .z = 10000 };
    const p3 = Point{ .x = 11, .y = 1000, .z = 10000 };

    try std.testing.expect(p1.Equals(p2));
    try std.testing.expect(!p2.Equals(p3));
}
