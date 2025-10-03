const std = @import("std");
const geom = @import("Geometry.zig");
const rndr = @import("Renderables.zig");

pub const World = struct {
    vertices: std.ArrayList(geom.Point),
    lines: std.ArrayList(geom.Line),
    bbox: geom.BoundingBox,
    is_dirty: std.Thread.ResetEvent,
    mut: std.Thread.Mutex,

    pub fn init() World {
        return World{
            .vertices = .{},
            .lines = .{},
            .bbox = geom.BoundingBox.init(),
            .is_dirty = .{},
            .mut = .{},
        };
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.lines.deinit(allocator);
    }

    pub fn addVertex(self: *World, allocator: std.mem.Allocator, vertex: *const geom.Point) !void {
        self.mut.lock();
        defer self.mut.unlock();
        try self.vertices.append(allocator, vertex.*);
        self.is_dirty.set();
        self.bbox.expand(vertex);
    }

    pub fn addLine(self: *World, allocator: std.mem.Allocator, line: *const geom.Line) !void {
        self.mut.lock();
        defer self.mut.unlock();
        try self.lines.append(allocator, line.*);
        self.is_dirty.set();
        self.bbox.expand(&line.p0);
        self.bbox.expand(&line.p1);
    }
};

pub const Tesselator = struct {
    world: *World,
    should_run: std.Thread.ResetEvent,
    should_tesselate: std.Thread.Condition,
    tessellation_ready: std.Thread.ResetEvent,
    renderable_vertices: rndr.RenderedVertices,
    renderable_lines: rndr.RenderedLines,
    mut: std.Thread.Mutex,

    pub fn init(world: *World) Tesselator {
        return .{
            .world = world,
            .should_run = .{},
            .should_tesselate = .{},
            .tessellation_ready = .{},
            .renderable_vertices = rndr.RenderedVertices.init(),
            .renderable_lines = rndr.RenderedLines.init(),
            .mut = .{},
        };
    }

    pub fn run(self: *Tesselator) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = gpa.allocator() };
        const allocator = tsa.allocator();

        defer self.renderable_vertices.deinit(allocator);
        defer self.renderable_lines.deinit(allocator);

        self.should_run.set();
        self.world.mut.lock();
        defer self.world.mut.unlock();

        while (self.should_run.isSet()) {
            self.should_tesselate.wait(&self.world.mut);
            // we have a lock on self.world.mut from .wait.
            if (self.world.is_dirty.isSet()) {
                self.world.is_dirty.reset();

                self.mut.lock();
                defer self.mut.unlock();
                self.renderable_lines.clear();
                for (self.world.lines.items) |line| {
                    try self.renderable_lines.addLine(allocator, line);
                }

                self.renderable_vertices.clear();
                for (self.world.vertices.items) |vertex| {
                    const pos = .{ @as(f32, @floatFromInt(vertex.x)), @as(f32, @floatFromInt(vertex.y)), @as(f32, @floatFromInt(vertex.z)) };
                    try self.renderable_vertices.addVertex(allocator, pos, .{ 0.1, 0.1, 0.1 });
                }

                self.tessellation_ready.set();
            }
        }
    }

    pub fn stop(self: *Tesselator) void {
        self.should_run.reset();
        self.should_tesselate.signal();
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
