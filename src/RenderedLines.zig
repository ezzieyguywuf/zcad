const std = @import("std");
const vkr = @import("VulkanRenderer.zig");
const geom = @import("Geometry.zig");

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

        // we need to know how many vertices we have before we add any
        const n: u32 = @intCast(self.vulkan_vertices.items.len);

        // The line will consist of two triangles. First, define the four
        // corners
        const uid_lower: u32 = @truncate(self.next_uid);
        const uid_upper: u32 = @truncate(self.next_uid >> 32);
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .flags = .{ .left = true, .up = false, .edge = false },
            .colorA = color,
            .colorB = color,
            .uid_lower = uid_lower,
            .uid_upper = uid_upper,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .flags = .{ .left = false, .up = true, .edge = false },
            .colorA = color,
            .colorB = color,
            .uid_lower = uid_lower,
            .uid_upper = uid_upper,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .flags = .{ .left = true, .up = true, .edge = false },
            .colorA = color,
            .colorB = color,
            .uid_lower = uid_lower,
            .uid_upper = uid_upper,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .flags = .{ .left = false, .up = false, .edge = false },
            .colorA = color,
            .colorB = color,
            .uid_lower = uid_lower,
            .uid_upper = uid_upper,
        });

        // These "edge" vertices will allow for anti-aliasing
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .flags = .{ .left = true, .up = false, .edge = true },
            .colorA = color,
            .colorB = color,
            .uid_lower = uid_lower,
            .uid_upper = uid_upper,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .flags = .{ .left = false, .up = true, .edge = true },
            .colorA = color,
            .colorB = color,
            .uid_lower = uid_lower,
            .uid_upper = uid_upper,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .flags = .{ .left = true, .up = true, .edge = true },
            .colorA = color,
            .colorB = color,
            .uid_lower = uid_lower,
            .uid_upper = uid_upper,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .flags = .{ .left = false, .up = false, .edge = true },
            .colorA = color,
            .colorB = color,
            .uid_lower = uid_lower,
            .uid_upper = uid_upper,
        });

        // Next, make sure we index them in the correct order
        try self.vulkan_indices.append(allocator, n);
        try self.vulkan_indices.append(allocator, n + 1);
        try self.vulkan_indices.append(allocator, n + 2);
        try self.vulkan_indices.append(allocator, n);
        try self.vulkan_indices.append(allocator, n + 3);
        try self.vulkan_indices.append(allocator, n + 1);

        // and finally the edge indices
        try self.vulkan_indices.append(allocator, n + 2);
        try self.vulkan_indices.append(allocator, n + 5);
        try self.vulkan_indices.append(allocator, n + 6);
        try self.vulkan_indices.append(allocator, n + 2);
        try self.vulkan_indices.append(allocator, n + 1);
        try self.vulkan_indices.append(allocator, n + 5);

        try self.vulkan_indices.append(allocator, n + 4);
        try self.vulkan_indices.append(allocator, n + 3);
        try self.vulkan_indices.append(allocator, n);
        try self.vulkan_indices.append(allocator, n + 4);
        try self.vulkan_indices.append(allocator, n + 7);
        try self.vulkan_indices.append(allocator, n + 3);

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
    try std.testing.expectEqual(@as(u64, 0), rendered_lines.vulkan_vertices.items[7].uid()); // Check last vertex of the 8 generated for this line
    try std.testing.expectEqual(@as(u64, 1), rendered_lines.next_uid);
    try std.testing.expectEqual(@as(usize, 8), rendered_lines.vulkan_vertices.items.len); // 8 vertices per line

    // Second line
    try rendered_lines.addLine(allocator, line_data2);
    try std.testing.expectEqual(@as(u64, 1), rendered_lines.vulkan_vertices.items[8].uid()); // First vertex of second line
    try std.testing.expectEqual(@as(u64, 1), rendered_lines.vulkan_vertices.items[15].uid()); // Last vertex of second line
    try std.testing.expectEqual(@as(u64, 2), rendered_lines.next_uid);
    try std.testing.expectEqual(@as(usize, 16), rendered_lines.vulkan_vertices.items.len);

    // Third line
    try rendered_lines.addLine(allocator, line_data3);
    try std.testing.expectEqual(@as(u64, 2), rendered_lines.vulkan_vertices.items[16].uid()); // First vertex of third line
    try std.testing.expectEqual(@as(u64, 2), rendered_lines.vulkan_vertices.items[23].uid()); // Last vertex of third line
    try std.testing.expectEqual(@as(u64, 3), rendered_lines.next_uid);
    try std.testing.expectEqual(@as(usize, 24), rendered_lines.vulkan_vertices.items.len);
}
