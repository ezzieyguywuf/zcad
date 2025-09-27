const std = @import("std");
const geom = @import("Geometry.zig");

pub const World = struct {
    vertices: std.ArrayList(geom.Point),
    lines: std.ArrayList(geom.Line),
    bbox: geom.BoundingBox,
    mutex: std.Thread.Mutex,

    pub fn init() World {
        return World{
            .vertices = .{},
            .lines = .{},
            .bbox = geom.BoundingBox.init(),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.lines.deinit(allocator);
    }

    pub fn addVertex(self: *World, allocator: std.mem.Allocator, vertex: *const geom.Point) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.vertices.append(allocator, vertex.*);
        self.bbox.expand(vertex);
    }

    pub fn addLine(self: *World, allocator: std.mem.Allocator, line: *const geom.Line) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.lines.append(allocator, line.*);
        self.bbox.expand(&line.p0);
        self.bbox.expand(&line.p1);
    }
};

test "World bounding box expansion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init();
    defer world.deinit(allocator);

    // Test initial state
    try std.testing.expectEqual(@as(usize, 0), world.lines.items.len);
    try std.testing.expectEqual(std.math.maxInt(i64), world.bbox.min.x);

    // Add a vertex and check state
    try world.addVertex(allocator, &.{ .x = -5, .y = 0, .z = 0 });
    try std.testing.expectEqual(@as(usize, 1), world.vertices.items.len);
    try std.testing.expectEqual(@as(i64, -5), world.bbox.min.x);
    try std.testing.expectEqual(@as(i64, -5), world.bbox.max.x);

    // Add a line and check bbox expansion
    const line1 = try geom.Line.init(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 10, .y = 10, .z = 10 });
    try world.addLine(allocator, &line1);

    try std.testing.expectEqual(@as(usize, 1), world.lines.items.len);
    try std.testing.expectEqual(@as(i64, -5), world.bbox.min.x);
    try std.testing.expectEqual(@as(i64, 10), world.bbox.max.x);
    try std.testing.expectEqual(@as(i64, 0), world.bbox.min.y);
    try std.testing.expectEqual(@as(i64, 10), world.bbox.max.y);
}
