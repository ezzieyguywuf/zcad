const std = @import("std");

// This is unitless, by design. For higher precision maths, simply scale these
// values differently - for example, if 1000 represents the value "1 inch", then
// this provides precision to 0.001 of an inch.
//
// For reference, let's say you needed 0.000001 inches precision, then these
// u64's could represent up to ~9.2e12 inches, or 145 million miles (roughly the
// distance from the sun to mars).
pub const Point = struct {
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

pub const Vector = struct {
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

test "Vector operations" {
    const v1 = Vector{ .dx = 1, .dy = 2, .dz = 3 };
    const v2 = Vector{ .dx = 1, .dy = 2, .dz = 3 };
    const v3 = Vector{ .dx = 4, .dy = 5, .dz = 6 };
    const v_zero = Vector{ .dx = 0, .dy = 0, .dz = 0 };
    const vx = Vector{ .dx = 1, .dy = 0, .dz = 0 };
    const vy = Vector{ .dx = 0, .dy = 1, .dz = 0 };

    // Equals
    try std.testing.expect(v1.Equals(v2));
    try std.testing.expect(!v1.Equals(v3));

    // Plus
    const sum = v1.Plus(v3);
    try std.testing.expectEqual(sum.dx, 5);
    try std.testing.expectEqual(sum.dy, 7);
    try std.testing.expectEqual(sum.dz, 9);
    try std.testing.expect(v1.Plus(v_zero).Equals(v1));

    // Minus
    const diff = v3.Minus(v1);
    try std.testing.expectEqual(diff.dx, 3);
    try std.testing.expectEqual(diff.dy, 3);
    try std.testing.expectEqual(diff.dz, 3);
    try std.testing.expect(v1.Minus(v1).Equals(v_zero));

    // Times
    const scaled = v1.Times(3);
    try std.testing.expectEqual(scaled.dx, 3);
    try std.testing.expectEqual(scaled.dy, 6);
    try std.testing.expectEqual(scaled.dz, 9);
    try std.testing.expect(v1.Times(0).Equals(v_zero));
    try std.testing.expect(v1.Times(-1).Equals(Vector{ .dx = -1, .dy = -2, .dz = -3 }));

    // Dot
    try std.testing.expectEqual(v1.Dot(v3), 1 * 4 + 2 * 5 + 3 * 6); // 32
    try std.testing.expectEqual(vx.Dot(vy), 0); // Perpendicular
    try std.testing.expectEqual(vx.Dot(vx), 1); // Parallel to self

    // Cross
    const cross_vx_vy = vx.Cross(vy); // Should be (0,0,1)
    try std.testing.expect(cross_vx_vy.Equals(Vector{ .dx = 0, .dy = 0, .dz = 1 }));
    const cross_vy_vx = vy.Cross(vx); // Should be (0,0,-1)
    try std.testing.expect(cross_vy_vx.Equals(Vector{ .dx = 0, .dy = 0, .dz = -1 }));
    try std.testing.expect(vx.Cross(vx).Equals(v_zero)); // Parallel

    // SquaredMagnitude
    try std.testing.expectEqual((Vector{ .dx = 3, .dy = 4, .dz = 0 }).SquaredMagnitude(), 25); // 3*3 + 4*4 = 9 + 16 = 25
    try std.testing.expectEqual(v_zero.SquaredMagnitude(), 0);
}

pub const Line = struct {
    p0: Point,
    p1: Point,

    pub fn init(p0: Point, p1: Point) !Line {
        if (p0.Equals(p1)) {
            return error.ZeroLengthLine;
        }
        return Line{ .p0 = p0, .p1 = p1 };
    }

    // from https://mathworld.wolfram.com/Point-LineDistance3-Dimensional.html,
    // TODO: figure out overflow.
    // TODO: This formula calculates the distance from a point to an *infinite*
    // line defined by p0 and p1. It does not consider the line segment's endpoints.
    pub fn DistanceToPoint(self: Line, other: Point) i64 {
        // v0 represents the vector from self.p0 to self.p1 (analogous to x2 - x1 in some formula notations)
        const v0 = Vector.FromPoint(self.p1).Minus(Vector.FromPoint(self.p0));
        // v_p0_other represents the vector from self.p0 to the point 'other' (analogous to x0 - x1 in some formula notations)
        const v_p0_other = Vector.FromPoint(self.p0).Minus(Vector.FromPoint(other));

        const numerator = v0.Cross(v_p0_other).SquaredMagnitude();
        const denominator = v0.SquaredMagnitude();

        // If numerator is zero, the point is on the infinite line.
        // If denominator is zero, the line has zero length. This case should ideally be handled
        // by the caller or an upcoming Line.init function, as distance to a point is ambiguous
        // without more context (distance to which endpoint, or should it be an error?).
        // For now, if denominator is 0, this will lead to division by zero if numerator is non-zero.
        // The original tests expect DistanceToPoint(zero_length_line, point) to return distance to that single point.
        // That logic is being removed from here. A division by zero here would be a panic.
        if (numerator == 0) {
            return 0;
        }

        const tmp: u32 = @intCast(@divTrunc(numerator, denominator));
        return @as(i64, @intFromFloat(std.math.sqrt(@as(f64, @floatFromInt(tmp)))));
    }
};

test "Distance from point to line" {
    const p1_start = Point{ .x = 10, .y = 10, .z = 0 };
    const p1_end = Point{ .x = 20, .y = 10, .z = 0 };
    const l1 = try Line.init(p1_start, p1_end);

    // Original tests
    try std.testing.expectEqual(l1.DistanceToPoint(Point{ .x = 15, .y = 15, .z = 0 }), 5);
    try std.testing.expectEqual(l1.DistanceToPoint(Point{ .x = 15, .y = 10, .z = 0 }), 0);

    // Endpoints
    try std.testing.expectEqual(l1.DistanceToPoint(Point{ .x = 10, .y = 10, .z = 0 }), 0); // p0
    try std.testing.expectEqual(l1.DistanceToPoint(Point{ .x = 20, .y = 10, .z = 0 }), 0); // p1

    // Points on infinite line projection but outside segment
    // (current formula calculates distance to infinite line, so these should be 0)
    try std.testing.expectEqual(l1.DistanceToPoint(Point{ .x = 0, .y = 10, .z = 0 }), 0);
    try std.testing.expectEqual(l1.DistanceToPoint(Point{ .x = 30, .y = 10, .z = 0 }), 0);

    // 3D points/lines
    const p3_start = Point{ .x = 0, .y = 0, .z = 0 };
    const p3_end = Point{ .x = 10, .y = 0, .z = 0 };
    const l3 = try Line.init(p3_start, p3_end); // Line along X-axis
    try std.testing.expectEqual(l3.DistanceToPoint(Point{ .x = 5, .y = 5, .z = 0 }), 5); // Point directly above mid-point
    try std.testing.expectEqual(l3.DistanceToPoint(Point{ .x = 5, .y = 0, .z = 5 }), 5); // Point "in front" of mid-point
}

test "Line initialization" {
    const p_a = Point{ .x = 0, .y = 0, .z = 0 };
    const p_b = Point{ .x = 1, .y = 0, .z = 0 };
    const line = try Line.init(p_a, p_b);
    // Basic assertion to ensure it's created and fields are set
    try std.testing.expect(line.p0.Equals(p_a));
    try std.testing.expect(line.p1.Equals(p_b));

    const p_c = Point{ .x = 5, .y = 5, .z = 5 };
    const maybe_line = Line.init(p_c, p_c);
    try std.testing.expectError(error.ZeroLengthLine, maybe_line);
}

pub const BoundingBox = struct {
    min: Point,
    max: Point,

    pub fn init() BoundingBox {
        return BoundingBox{
            .min = Point{ .x = std.math.maxInt(i64), .y = std.math.maxInt(i64), .z = std.math.maxInt(i64) },
            .max = Point{ .x = std.math.minInt(i64), .y = std.math.minInt(i64), .z = std.math.minInt(i64) },
        };
    }

    pub fn expand(self: *BoundingBox, p: *const Point) void {
        self.min.x = @min(self.min.x, p.x);
        self.min.y = @min(self.min.y, p.y);
        self.min.z = @min(self.min.z, p.z);
        self.max.x = @max(self.max.x, p.x);
        self.max.y = @max(self.max.y, p.y);
        self.max.z = @max(self.max.z, p.z);
    }
};

test "BoundingBox operations" {
    var bbox = BoundingBox.init();

    // Test initial state
    try std.testing.expectEqual(std.math.maxInt(i64), bbox.min.x);
    try std.testing.expectEqual(std.math.minInt(i64), bbox.max.x);

    // Expand with first point
    bbox.expand(&.{ .x = 10, .y = -10, .z = 100 });
    try std.testing.expectEqual(10, bbox.min.x);
    try std.testing.expectEqual(10, bbox.max.x);
    try std.testing.expectEqual(-10, bbox.min.y);
    try std.testing.expectEqual(-10, bbox.max.y);
    try std.testing.expectEqual(100, bbox.min.z);
    try std.testing.expectEqual(100, bbox.max.z);

    // Expand with a second point that should set a new min/max
    bbox.expand(&.{ .x = 0, .y = 20, .z = -200 });
    try std.testing.expectEqual(0, bbox.min.x);
    try std.testing.expectEqual(10, bbox.max.x);
    try std.testing.expectEqual(-10, bbox.min.y);
    try std.testing.expectEqual(20, bbox.max.y);
    try std.testing.expectEqual(-200, bbox.min.z);
    try std.testing.expectEqual(100, bbox.max.z);

    // Expand with a point that is within the current bounds
    bbox.expand(&.{ .x = 5, .y = 5, .z = 5 });
    try std.testing.expectEqual(0, bbox.min.x);
    try std.testing.expectEqual(10, bbox.max.x);
    try std.testing.expectEqual(-10, bbox.min.y);
    try std.testing.expectEqual(20, bbox.max.y);
    try std.testing.expectEqual(-200, bbox.min.z);
    try std.testing.expectEqual(100, bbox.max.z);
}
