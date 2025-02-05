const std = @import("std");
const wl = @import("WaylandClient.zig");
const vkr = @import("VulkanRenderer.zig");
const vk = @import("vulkan");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
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

    // Wayland
    var wl_context = try allocator.create(wl.WaylandContext);
    defer allocator.destroy(wl_context);
    try wl.WaylandContext.init(wl_context, 680, 420);

    // vulkan
    const vk_ctx = try vkr.VulkanContext.init(allocator, wl_context);
    var extent = vk.Extent2D{
        .width = @intCast(wl_context.width),
        .height = @intCast(wl_context.height),
    };
    var renderer = try vkr.Renderer.init(allocator, &vk_ctx, extent);
    defer renderer.deinit(allocator, &vk_ctx);

    while (!wl_context.should_exit) {
        const should_render = try wl_context.run();
        if (!should_render) continue;

        try renderer.render(allocator, &vk_ctx, &extent, wl_context);
    }

    try renderer.swapchain.waitForAllFences(&vk_ctx.device);
    try vk_ctx.device.deviceWaitIdle();
}

// This is unitless, by design. For higher precision maths, simply scale these
// values differently - for example, if 1000 represents the value "1 inch", then
// this provides precision to 0.001 of an inch.
//
// For reference, let's say you needed 0.000001 inches precision, then these
// u64's could represent up to ~9.2e12 inches, or 145 million miles (roughly the
// distance from the sun to mars).
const Point = struct {
    x: i64,
    y: i64,
    z: i64,

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

const Line = struct {
    p0: Point,
    p1: Point,

    // from https://mathworld.wolfram.com/Point-LineDistance3-Dimensional.html,
    // equation (8)
    // TODO: figure out overflow.
    pub fn DistanceToPoint(self: Line, other: Point) i64 {
        // x2 - x2 from wolfram
        const v0 = Vector.FromPoint(self.p1).Minus(Vector.FromPoint(self.p0));

        // x1 - x0 from wolfram
        const v = Vector.FromPoint(self.p0).Minus(Vector.FromPoint(other));

        const numerator = v0.Cross(v).SquaredMagnitude();
        const denominator = v0.SquaredMagnitude();

        // Try to avoid the sqrt if we can
        if (numerator == denominator) {
            return 0;
        }

        // since both numerator and denominoter were squared, they should both
        // be positive. Thus it should be safe to convert to uint and take the
        // square root. Since they start as signed int, it should be safe to
        // convert back to signed int.
        const tmp: u32 = @intCast(@divTrunc(numerator, denominator));

        return @intCast(std.math.sqrt(tmp));
    }
};

test "Distance from point to line" {
    const l1 = Line{
        .p0 = Point{ .x = 10, .y = 10, .z = 0 },
        .p1 = Point{ .x = 20, .y = 10, .z = 0 },
    };

    try std.testing.expectEqual(l1.DistanceToPoint(Point{ .x = 15, .y = 15, .z = 0 }), 5);
    try std.testing.expectEqual(l1.DistanceToPoint(Point{ .x = 15, .y = 10, .z = 0 }), 0);
}

const Vector = struct {
    dx: i64,
    dy: i64,
    dz: i64,

    pub fn FromPoint(point: Point) Vector {
        return Vector{
            .dx = point.x,
            .dy = point.y,
            .dz = point.z,
        };
    }

    pub fn Equals(self: Vector, other: Vector) bool {
        return self.dx == other.dx and self.dy == other.dy and self.dz == other.dz;
    }

    pub fn Plus(self: Vector, other: Vector) Vector {
        return Vector{
            .dx = self.dx + other.dx,
            .dy = self.dy + other.dy,
            .dz = self.dz + other.dz,
        };
    }

    pub fn Minus(self: Vector, other: Vector) Vector {
        return Vector{
            .dx = self.dx - other.dx,
            .dy = self.dy - other.dy,
            .dz = self.dz - other.dz,
        };
    }

    pub fn Times(self: Vector, amt: i64) Vector {
        return Vector{
            .dx = self.dx * amt,
            .dy = self.dy * amt,
            .dz = self.dz * amt,
        };
    }

    pub fn Dot(self: Vector, other: Vector) i64 {
        return self.dx * other.dx + self.dy * other.dy + self.dz * other.dz;
    }

    pub fn Cross(self: Vector, other: Vector) Vector {
        return Vector{
            .dx = self.dy * other.dz - self.dz * other.dy,
            .dy = self.dz * other.dx - self.dx * other.dz,
            .dz = self.dx * other.dy - self.dy * other.dx,
        };
    }

    // Avoids square-root calculation, I think is hard to do in computers, and
    // most of the times this seems to be all you need in calculations
    pub fn SquaredMagnitude(self: Vector) i64 {
        return self.dx * self.dx + self.dy * self.dy + self.dz * self.dz;
    }
};
