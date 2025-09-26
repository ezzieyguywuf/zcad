const std = @import("std");
const vkr = @import("VulkanRenderer.zig");
const geom = @import("Geometry.zig");

pub const RenderedVertices = struct {
    vulkan_vertices: std.ArrayListUnmanaged(vkr.Vertex),
    vulkan_indices: std.ArrayListUnmanaged(u32),
    next_uid: u64, // For potential future use with picking

    pub fn init() RenderedVertices {
        return RenderedVertices{
            .vulkan_vertices = .{},
            .vulkan_indices = .{},
            .next_uid = 0,
        };
    }

    pub fn deinit(self: *RenderedVertices, allocator: std.mem.Allocator) void {
        self.vulkan_vertices.deinit(allocator);
        self.vulkan_indices.deinit(allocator);
    }

    // Adds a single vertex.
    // For now, each vertex is its own indexed entity.
    pub fn addVertex(
        self: *RenderedVertices,
        allocator: std.mem.Allocator,
        pos: [3]f32,
        color: [3]f32,
    ) !void {
        const n_vertices: u32 = @intCast(self.vulkan_vertices.items.len);
        const uid_lower: u32 = @truncate(self.next_uid);
        const uid_upper: u32 = @truncate(self.next_uid >> 32);

        try self.vulkan_vertices.append(allocator, .{
            .pos = pos,
            .color = color,
            .uid_lower = uid_lower,
            .uid_upper = uid_upper,
        });
        try self.vulkan_indices.append(allocator, n_vertices);

        // Increment UID if we want to assign a unique ID per vertex
        // For now, UIDs might not be directly used by the shader for points,
        // but good to have for consistency or future enhancements.
        // If vertex picking is implemented, this UID could be used.
        self.next_uid += 1;
        if (self.next_uid == std.math.maxInt(u64)) {
            // Or handle this more gracefully depending on requirements
            return error.RanOutOfUidsForRenderedVertices;
        }
    }
};

test "RenderedVertices basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var vertices = RenderedVertices.init();
    defer vertices.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), vertices.vulkan_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 0), vertices.vulkan_indices.items.len);
    try std.testing.expectEqual(@as(u64, 0), vertices.next_uid);

    try vertices.addVertex(allocator, .{ 1.0, 2.0, 3.0 }, .{ 1.0, 0.0, 0.0 });
    try std.testing.expectEqual(@as(usize, 1), vertices.vulkan_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), vertices.vulkan_indices.items.len);
    try std.testing.expectEqual(@as(u64, 1), vertices.next_uid);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 2.0, 3.0 }, &vertices.vulkan_vertices.items[0].pos);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0 }, &vertices.vulkan_vertices.items[0].color);
    try std.testing.expectEqual(@as(u32, 0), vertices.vulkan_indices.items[0]);

    try vertices.addVertex(allocator, .{ 4.0, 5.0, 6.0 }, .{ 0.0, 1.0, 0.0 });
    try std.testing.expectEqual(@as(usize, 2), vertices.vulkan_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 2), vertices.vulkan_indices.items.len);
    try std.testing.expectEqual(@as(u64, 2), vertices.next_uid);
    try std.testing.expectEqualSlices(f32, &.{ 4.0, 5.0, 6.0 }, &vertices.vulkan_vertices.items[1].pos);
    try std.testing.expectEqualSlices(f32, &.{ 0.0, 1.0, 0.0 }, &vertices.vulkan_vertices.items[1].color);
    try std.testing.expectEqual(@as(u32, 1), vertices.vulkan_indices.items[1]);

    // Test UID overflow error if RanOutOfUidsForRenderedVertices is a public error
    // For now, this is not tested as the error is not explicitly made public.
}

pub const RenderedLines = struct {
    // TODO: maybe make this an ArrayList(vkr.Line, void) to dedupe
    vulkan_vertices: std.ArrayListUnmanaged(vkr.Line),
    vulkan_indices: std.ArrayListUnmanaged(u32),
    next_uid: u64,

    pub fn init() RenderedLines {
        return RenderedLines{
            .vulkan_vertices = .{},
            .vulkan_indices = .{},
            .next_uid = 0,
        };
    }

    pub fn deinit(self: *RenderedLines, allocator: std.mem.Allocator) void {
        self.vulkan_vertices.deinit(allocator);
        self.vulkan_indices.deinit(allocator);
    }

    pub fn addLine(self: *RenderedLines, allocator: std.mem.Allocator, line: geom.Line) !void {
        const left = [3]f32{
            @floatFromInt(line.p0.x),
            @floatFromInt(line.p0.y),
            @floatFromInt(line.p0.z),
        };
        const right = [3]f32{
            @floatFromInt(line.p1.x),
            @floatFromInt(line.p1.y),
            @floatFromInt(line.p1.z),
        };
        const color = [3]f32{ 0, 0, 0 };

        const n: u32 = @intCast(self.vulkan_vertices.items.len);
        const uid_lower: u32 = @truncate(self.next_uid);
        const uid_upper: u32 = @truncate(self.next_uid >> 32);

        // Line body vertices
        try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .left = true, .up = false, .edge = false, .is_endcap = false, .segment_index = 0 }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });
        try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .left = false, .up = true, .edge = false, .is_endcap = false, .segment_index = 0 }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });
        try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .left = true, .up = true, .edge = false, .is_endcap = false, .segment_index = 0 }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });
        try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .left = false, .up = false, .edge = false, .is_endcap = false, .segment_index = 0 }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });

        // Anti-aliasing edge vertices
        try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .left = true, .up = false, .edge = true, .is_endcap = false, .segment_index = 0 }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });
        try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .left = false, .up = true, .edge = true, .is_endcap = false, .segment_index = 0 }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });
        try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .left = true, .up = true, .edge = true, .is_endcap = false, .segment_index = 0 }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });
        try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .left = false, .up = false, .edge = true, .is_endcap = false, .segment_index = 0 }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });

        // Line body indices
        try self.vulkan_indices.appendSlice(allocator, &.{ n, n + 1, n + 2, n, n + 3, n + 1 });
        try self.vulkan_indices.appendSlice(allocator, &.{ n + 2, n + 5, n + 6, n + 2, n + 1, n + 5 });
        try self.vulkan_indices.appendSlice(allocator, &.{ n + 4, n + 3, n, n + 4, n + 7, n + 3 });

        const n_caps = 16;
        const cap_start_index = n + 8;

        // Start cap vertices
        for (0..n_caps) |i| {
            try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .up = false, .left = true, .edge = false, .is_endcap = true, .segment_index = @intCast(i) }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });
        }

        // Start cap indices (triangle fan)
        for (1..n_caps - 1) |i| {
            try self.vulkan_indices.appendSlice(allocator, &.{ cap_start_index, cap_start_index + @as(u32, @intCast(i)), cap_start_index + @as(u32, @intCast(i)) + 1 });
        }

        const cap_end_index = cap_start_index + n_caps;

        // End cap vertices
        for (0..n_caps) |i| {
            try self.vulkan_vertices.append(allocator, .{ .posA = left, .posB = right, .flags = .{ .up = false, .left = false, .edge = false, .is_endcap = true, .segment_index = @intCast(i) }, .colorA = color, .colorB = color, .uid_lower = uid_lower, .uid_upper = uid_upper });
        }

        // End cap indices (triangle fan)
        for (1..n_caps - 1) |i| {
            try self.vulkan_indices.appendSlice(allocator, &.{ cap_end_index, cap_end_index + @as(u32, @intCast(i)), cap_end_index + @as(u32, @intCast(i)) + 1 });
        }

        self.next_uid += 1;
        if (self.next_uid == std.math.maxInt(u64)) {
            return error.RanOutOfUidsForRenderedLines;
        }
    }
};

test "RenderedLines UID generation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rendered_lines = RenderedLines.init();
    defer rendered_lines.deinit(allocator);

    const line_data1 = geom.Line{ .p0 = .{ .x = 0, .y = 0, .z = 0 }, .p1 = .{ .x = 1, .y = 1, .z = 1 } };
    const line_data2 = geom.Line{ .p0 = .{ .x = 2, .y = 2, .z = 2 }, .p1 = .{ .x = 3, .y = 3, .z = 3 } };
    const line_data3 = geom.Line{ .p0 = .{ .x = 4, .y = 4, .z = 4 }, .p1 = .{ .x = 5, .y = 5, .z = 5 } };

    // First line
    try rendered_lines.addLine(allocator, line_data1);
    try std.testing.expectEqual(@as(u64, 0), rendered_lines.vulkan_vertices.items[0].uid());
    try std.testing.expectEqual(@as(u64, 0), rendered_lines.vulkan_vertices.items[39].uid());
    try std.testing.expectEqual(@as(u64, 1), rendered_lines.next_uid);
    try std.testing.expectEqual(@as(usize, 40), rendered_lines.vulkan_vertices.items.len);

    // Second line
    try rendered_lines.addLine(allocator, line_data2);
    try std.testing.expectEqual(@as(u64, 1), rendered_lines.vulkan_vertices.items[40].uid());
    try std.testing.expectEqual(@as(u64, 1), rendered_lines.vulkan_vertices.items[79].uid());
    try std.testing.expectEqual(@as(u64, 2), rendered_lines.next_uid);
    try std.testing.expectEqual(@as(usize, 80), rendered_lines.vulkan_vertices.items.len);

    // Third line
    try rendered_lines.addLine(allocator, line_data3);
    try std.testing.expectEqual(@as(u64, 2), rendered_lines.vulkan_vertices.items[80].uid());
    try std.testing.expectEqual(@as(u64, 2), rendered_lines.vulkan_vertices.items[119].uid());
    try std.testing.expectEqual(@as(u64, 3), rendered_lines.next_uid);
    try std.testing.expectEqual(@as(usize, 120), rendered_lines.vulkan_vertices.items.len);
}

pub const RenderedFaces = struct {
    vulkan_vertices: std.ArrayListUnmanaged(vkr.Vertex),
    vulkan_indices: std.ArrayListUnmanaged(u32),
    next_uid: u64,

    pub fn init() RenderedFaces {
        return RenderedFaces{
            .vulkan_vertices = .{},
            .vulkan_indices = .{},
            .next_uid = 0,
        };
    }

    pub fn deinit(self: *RenderedFaces, allocator: std.mem.Allocator) void {
        self.vulkan_vertices.deinit(allocator);
        self.vulkan_indices.deinit(allocator);
    }

    // Adds a face, triangulating it using a simple fan algorithm.
    // Assumes points are coplanar and form a convex polygon.
    // Takes an array slice of `Point` structs and a color.
    pub fn addFace(
        self: *RenderedFaces,
        allocator: std.mem.Allocator,
        points: []const geom.Point,
        color: [3]f32,
    ) !void {
        if (points.len < 3) {
            return error.NotEnoughPointsForFace; // Need at least 3 points for a face
        }

        const base_vertex_index: u32 = @intCast(self.vulkan_vertices.items.len);
        const current_face_uid_lower: u32 = @truncate(self.next_uid);
        const current_face_uid_upper: u32 = @truncate(self.next_uid >> 32);

        // Add all points of the polygon as vertices
        for (points) |p| {
            try self.vulkan_vertices.append(allocator, .{
                .pos = .{ @floatFromInt(p.x), @floatFromInt(p.y), @floatFromInt(p.z) },
                .color = color,
                .uid_lower = current_face_uid_lower,
                .uid_upper = current_face_uid_upper,
            });
        }

        // Fan triangulation:
        // Triangle 1: p0, p1, p2
        // Triangle 2: p0, p2, p3
        // ...
        for (1..(points.len - 1)) |i| {
            try self.vulkan_indices.append(allocator, base_vertex_index); // p0
            try self.vulkan_indices.append(allocator, base_vertex_index + @as(u32, @intCast(i))); // pi
            try self.vulkan_indices.append(allocator, base_vertex_index + @as(u32, @intCast(i)) + 1); // p(i+1)
        }

        self.next_uid += 1;
        if (self.next_uid == std.math.maxInt(u64)) {
            return error.RanOutOfUidsForRenderedFaces;
        }
    }
};

test "RenderedFaces basic operations and triangulation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var faces = RenderedFaces.init();
    defer faces.deinit(allocator);

    // Test initial state
    try std.testing.expectEqual(@as(usize, 0), faces.vulkan_vertices.items.len);
    try std.testing.expectEqual(@as(usize, 0), faces.vulkan_indices.items.len);
    try std.testing.expectEqual(@as(u64, 0), faces.next_uid);

    // Test adding a triangle
    const p_triangle = [_]geom.Point{
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 1, .z = 0 },
    };
    const color_triangle = [_]f32{ 1.0, 0.0, 0.0 }; // Red
    try faces.addFace(allocator, &p_triangle, color_triangle);

    try std.testing.expectEqual(@as(usize, 3), faces.vulkan_vertices.items.len); // 3 vertices for a triangle
    try std.testing.expectEqual(@as(usize, 3), faces.vulkan_indices.items.len); // 1 triangle = 3 indices (0,1,2)
    try std.testing.expectEqual(@as(u64, 1), faces.next_uid);
    // Check vertex data
    try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.0, 0.0 }, &faces.vulkan_vertices.items[0].pos);
    try std.testing.expectEqualSlices(f32, &color_triangle, &faces.vulkan_vertices.items[0].color);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0 }, &faces.vulkan_vertices.items[1].pos);
    try std.testing.expectEqualSlices(f32, &color_triangle, &faces.vulkan_vertices.items[1].color);
    try std.testing.expectEqualSlices(f32, &.{ 0.0, 1.0, 0.0 }, &faces.vulkan_vertices.items[2].pos);
    try std.testing.expectEqualSlices(f32, &color_triangle, &faces.vulkan_vertices.items[2].color);
    // Check indices for fan triangulation (base_index = 0)
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, faces.vulkan_indices.items);

    // Test adding a quad (should be triangulated into 2 triangles)
    const p_quad = [_]geom.Point{
        .{ .x = 0, .y = 0, .z = 1 }, // p0
        .{ .x = 1, .y = 0, .z = 1 }, // p1
        .{ .x = 1, .y = 1, .z = 1 }, // p2
        .{ .x = 0, .y = 1, .z = 1 }, // p3
    };
    const color_quad = [_]f32{ 0.0, 1.0, 0.0 }; // Green
    try faces.addFace(allocator, &p_quad, color_quad);

    try std.testing.expectEqual(@as(usize, 3 + 4), faces.vulkan_vertices.items.len); // 3 from triangle + 4 from quad
    try std.testing.expectEqual(@as(usize, 3 + 6), faces.vulkan_indices.items.len); // 3 from triangle + 6 from quad (2 triangles)
    try std.testing.expectEqual(@as(u64, 2), faces.next_uid);
    // Check new quad vertex data (starts at index 3)
    try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.0, 1.0 }, &faces.vulkan_vertices.items[3].pos);
    try std.testing.expectEqualSlices(f32, &color_quad, &faces.vulkan_vertices.items[3].color);
    // Check new quad indices (base_index = 3)
    // Triangle 1: p0, p1, p2 => indices 3, 4, 5
    // Triangle 2: p0, p2, p3 => indices 3, 5, 6
    const expected_quad_indices = [_]u32{ 3, 4, 5, 3, 5, 6 };
    try std.testing.expectEqualSlices(u32, &expected_quad_indices, faces.vulkan_indices.items[3..]);

    // Test error for not enough points
    const p_line = [_]geom.Point{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 } };
    try std.testing.expectError(error.NotEnoughPointsForFace, faces.addFace(allocator, &p_line, color_quad));
}
