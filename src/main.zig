const std = @import("std");
const wl = @import("WaylandClient.zig");
const vkr = @import("VulkanRenderer.zig");
const wnd = @import("WindowingContext.zig");
const x11 = @import("X11Context.zig");
const vk = @import("vulkan");
const zm = @import("zmath");

const AppContext = struct {
    prev_input_state: wnd.InputState,
    eye: zm.Vec,
    focus_point: zm.Vec,
    up: zm.Vec,
    mvp_ubo: vkr.MVPUniformBufferObject,
    should_exit: bool,
    should_fetch_id_buffers: bool,
    pointer_x: usize,
    pointer_y: usize,
};

const OsWindow = union(wnd.WindowingType) {
    xlib: *x11.X11Context(*AppContext),
    wayland: *wl.WaylandContext(*AppContext),
};

pub fn InputCallback(app_ctx: *AppContext, input_state: wnd.InputState) !void {
    if (input_state.should_close) {
        app_ctx.should_exit = true;
        return;
    }
    const total_vertical_scroll = input_state.vertical_scroll + app_ctx.prev_input_state.vertical_scroll;
    const total_horizontal_scroll = input_state.horizontal_scroll + app_ctx.prev_input_state.horizontal_scroll;

    const dir_long = app_ctx.focus_point - app_ctx.eye;
    const dir = zm.normalize3(dir_long);
    const dir_len = zm.length3(dir_long)[0];

    const delta_eye = @as(zm.Vec, @splat(@floatCast(total_vertical_scroll))) * dir;
    const delta_eye_len = zm.length3(delta_eye)[0];
    const delta_radians = std.math.pi / @as(f64, @floatCast(368));

    if ((!input_state.window_moving) and (!input_state.window_resizing)) {
        if (input_state.left_button == false and app_ctx.prev_input_state.left_button == true) {
            app_ctx.should_fetch_id_buffers = true;
            app_ctx.pointer_x = @intFromFloat(input_state.pointer_x);
            app_ctx.pointer_y = @intFromFloat(input_state.pointer_y);
            // std.debug.print("clicked, x: {d}, y: {d}\n", .{ x_pos, y_pos });
        }
        if (input_state.left_button) {
            // TODO rotation around focus_point
            const delta_x = input_state.pointer_x - app_ctx.prev_input_state.pointer_x;
            const angle_x = delta_radians * delta_x;
            const rotate_x = zm.matFromAxisAngle(app_ctx.up, @floatCast(angle_x));

            const delta_y = input_state.pointer_y - app_ctx.prev_input_state.pointer_y;
            const angle_y = delta_radians * delta_y;
            const axis = zm.cross3(app_ctx.eye, app_ctx.up);
            const rotate_y = zm.matFromAxisAngle(axis, @floatCast(angle_y));

            app_ctx.up = zm.mul(rotate_y, zm.mul(rotate_x, app_ctx.up));
            app_ctx.eye = zm.mul(rotate_y, zm.mul(rotate_x, app_ctx.eye));
        }
        if (input_state.right_button and !app_ctx.prev_input_state.right_button) {}
        if (input_state.middle_button and !app_ctx.prev_input_state.middle_button) {}
    }

    if (total_horizontal_scroll != 0) {
        const angle = delta_radians * total_horizontal_scroll;
        const rotate = zm.matFromAxisAngle(app_ctx.up, @floatCast(angle));
        const new_dir_long = zm.mul(rotate, dir_long);
        app_ctx.focus_point = app_ctx.eye + new_dir_long;
    }

    if (total_vertical_scroll < 0 or dir_len > delta_eye_len) {
        app_ctx.eye += @as(zm.Vec, @splat(@floatCast(total_vertical_scroll))) * dir;
    }

    app_ctx.prev_input_state = input_state;
    app_ctx.prev_input_state.vertical_scroll = 0;
    app_ctx.prev_input_state.horizontal_scroll = 0;
}

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

    const eye: zm.Vec = .{ 0, 0, 20, 1 };
    const focus_point: zm.Vec = .{ 0, 0, 0, 1 };
    const up: zm.Vec = .{ 0, 1, 0, 0 };
    var app_ctx = AppContext{
        .prev_input_state = wnd.InputState{},
        .eye = eye,
        .focus_point = focus_point,
        .up = up,
        .mvp_ubo = .{
            .model = zm.identity(),
            .view = zm.lookAtRh(eye, focus_point, up),
            .projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), 1.0, 0.1, 1000.0),
        },
        .should_exit = false,
        .should_fetch_id_buffers = false,
        .pointer_x = 0,
        .pointer_y = 0,
    };

    var args = try std.process.argsWithAllocator(allocator);
    var use_x11 = false;
    defer args.deinit();
    // skip first arg, which is program name
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--use-x11")) {
            use_x11 = true;
        } else {
            std.debug.print("unrecognized arg: {s}\n", .{arg});
            return error.UnrecognizedArgument;
        }
    }

    // Windowing
    var wnd_ctx = wnd.WindowingContext(*AppContext).init(&app_ctx, InputCallback, 680, 420);
    var os_window = if (use_x11) OsWindow{ .xlib = try allocator.create(x11.X11Context(*AppContext)) } else OsWindow{ .wayland = try allocator.create(wl.WaylandContext(*AppContext)) };
    defer {
        switch (os_window) {
            .xlib => |window| allocator.destroy(window),
            .wayland => |window| allocator.destroy(window),
        }
    }

    switch (os_window) {
        .xlib => |*window| try window.*.init(&wnd_ctx),
        .wayland => |*window| try window.*.init(&wnd_ctx),
    }

    // vulkan
    const vk_ctx = switch (os_window) {
        .xlib => |window| try vkr.VulkanContext.init(allocator, vkr.WindowingInfo{ .xlib = .{
            .x11_display = @ptrCast(window.display),
            .x11_window = window.window,
        } }),
        .wayland => |window| try vkr.VulkanContext.init(
            allocator,
            vkr.WindowingInfo{
                .wayland = .{
                    .wl_display = @ptrCast(window.wl_display),
                    .wl_surface = @ptrCast(window.wl_surface),
                },
            },
        ),
    };
    defer vk_ctx.deinit(allocator);
    var renderer = try vkr.Renderer.init(allocator, &vk_ctx, @intCast(wnd_ctx.width), @intCast(wnd_ctx.height));
    defer renderer.deinit(allocator, &vk_ctx);

    // zcad
    // const triangle_color = [_]f32{ 0.8, 0.2, 0.8 };
    // const vk_triangle_vertices = [_]vkr.Vertex{
    //     .{
    //         .pos = .{ -5, -5, 0 },
    //         .color = triangle_color,
    //     },
    //     .{
    //         .pos = .{ 5, -5, 0 },
    //         .color = triangle_color,
    //     },
    //     .{
    //         .pos = .{ 5, 5, 0 },
    //         .color = triangle_color,
    //     },
    //     .{
    //         .pos = .{ -5, 5, 0 },
    //         .color = triangle_color,
    //     },
    //     .{
    //         .pos = .{ 5, 5, -10 },
    //         .color = triangle_color,
    //     },
    //     .{
    //         .pos = .{ 5, -5, -10 },
    //         .color = triangle_color,
    //     },
    // };
    // const triangle_indices = [_]u32{ 0, 1, 2, 2, 3, 0, 1, 2, 5, 2, 4, 5 };

    // const vk_point_vertices = [_]vkr.Vertex{
    //     .{
    //         .pos = .{ -5, -5, 0 },
    //         .color = .{ 0, 0.5, 0.5 },
    //     },
    //     .{
    //         .pos = .{ 5, -5, 0 },
    //         .color = .{ 0, 0.5, 0.5 },
    //     },
    //     .{
    //         .pos = .{ 5, 5, -10 },
    //         .color = .{ 1, 0, 0 },
    //     },
    //     .{
    //         .pos = .{ 5, -5, -10 },
    //         .color = .{ 1, 1, 0 },
    //     },
    // };
    // const point_indices = [_]u32{ 0, 1, 2 };

    var rendered_lines = RenderedLines.init();
    defer rendered_lines.deinit(allocator);
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = -5, .y = -5, .z = -5 },
        .{ .x = 5, .y = -5, .z = -5 },
    ));
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = 5, .y = -5, .z = -5 },
        .{ .x = 5, .y = 5, .z = -5 },
    ));
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = 5, .y = 5, .z = -5 },
        .{ .x = -5, .y = 5, .z = -5 },
    ));
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = -5, .y = 5, .z = -5 },
        .{ .x = -5, .y = -5, .z = -5 },
    ));

    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = -5, .y = -5, .z = 5 },
        .{ .x = 5, .y = -5, .z = 5 },
    ));
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = 5, .y = -5, .z = 5 },
        .{ .x = 5, .y = 5, .z = 5 },
    ));
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = 5, .y = 5, .z = 5 },
        .{ .x = -5, .y = 5, .z = 5 },
    ));
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = -5, .y = 5, .z = 5 },
        .{ .x = -5, .y = -5, .z = 5 },
    ));

    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = -5, .y = -5, .z = -5 },
        .{ .x = -5, .y = -5, .z = 5 },
    ));
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = 5, .y = -5, .z = -5 },
        .{ .x = 5, .y = -5, .z = 5 },
    ));
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = 5, .y = 5, .z = -5 },
        .{ .x = 5, .y = 5, .z = 5 },
    ));
    try rendered_lines.addLine(allocator, try Line.init(
        .{ .x = -5, .y = 5, .z = -5 },
        .{ .x = -5, .y = 5, .z = 5 },
    ));

    // try renderer.uploadInstanced(vkr.Vertex, &vk_ctx, .Points, &vk_point_vertices, &point_indices);
    try renderer.uploadInstanced(vkr.Line, &vk_ctx, .Lines, rendered_lines.vulkan_vertices.items, rendered_lines.vulkan_indices.items);
    // try renderer.uploadInstanced(vkr.Vertex, &vk_ctx, .Triangles, &vk_triangle_vertices, &triangle_indices);

    {
        const aspect_ratio = @as(f32, @floatFromInt(wnd_ctx.width)) / @as(f32, @floatFromInt(wnd_ctx.height));
        app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.1, 1000.0);
    }

    var id_buffers = vkr.IdBuffers{
        .vertex_ids = .{},
        .line_ids = .{},
        .surface_ids = .{},
    };
    defer id_buffers.deinit(allocator);

    while ((!wnd_ctx.should_exit) and (!app_ctx.should_exit)) {
        if (app_ctx.should_fetch_id_buffers) {
            app_ctx.should_fetch_id_buffers = false;
            id_buffers.deinit(allocator);
            id_buffers = try renderer.getIdBuffers(allocator, &vk_ctx);
            const i = app_ctx.pointer_x + app_ctx.pointer_y * @as(usize, @intCast(wnd_ctx.width));
            if (i > id_buffers.vertex_ids.items.len) {
                std.debug.print("index {d} bigger than len {d}\n", .{ i, id_buffers.vertex_ids.items.len });
            } else {
                std.debug.print("got vertex_id: {d}\n", .{id_buffers.vertex_ids.items[i]});
                std.debug.print("got line_id: {d}\n", .{id_buffers.line_ids.items[i]});
            }
        }
        if (wnd_ctx.should_resize) {
            const aspect_ratio = @as(f32, @floatFromInt(wnd_ctx.width)) / @as(f32, @floatFromInt(wnd_ctx.height));
            app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.1, 1000.0);
            wnd_ctx.resizing_done = true;
        }

        const should_render = switch (os_window) {
            .xlib => true,
            .wayland => |window| try window.run(),
        };
        if (!should_render) continue;

        app_ctx.mvp_ubo.view = zm.lookAtRh(app_ctx.eye, app_ctx.focus_point, app_ctx.up);
        try renderer.render(
            allocator,
            &vk_ctx,
            @intCast(wnd_ctx.width),
            @intCast(wnd_ctx.height),
            &app_ctx.mvp_ubo,
        );
    }

    std.debug.print("exited loop\n", .{});
    try renderer.swapchain.waitForAllFences(&vk_ctx.device);
    try vk_ctx.device.deviceWaitIdle();

    std.debug.print("exiting main\n", .{});
}

pub const RenderedLines = struct {
    // TODO: maybe make this an ArrayList(vkr.Line, void) to dedupe
    vulkan_vertices: std.ArrayListUnmanaged(vkr.Line),
    vulkan_indices: std.ArrayListUnmanaged(u32),

    pub fn init() RenderedLines {
        return RenderedLines{
            .vulkan_vertices = .{},
            .vulkan_indices = .{},
        };
    }

    pub fn deinit(self: *RenderedLines, allocator: std.mem.Allocator) void {
        self.vulkan_vertices.deinit(allocator);
        self.vulkan_indices.deinit(allocator);
    }

    pub fn addLine(self: *RenderedLines, allocator: std.mem.Allocator, line: Line) !void {
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
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .left = true,
            .up = false,
            .edge = false,
            .colorA = color,
            .colorB = color,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .left = false,
            .up = true,
            .edge = false,
            .colorA = color,
            .colorB = color,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .left = true,
            .up = true,
            .edge = false,
            .colorA = color,
            .colorB = color,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .left = false,
            .up = false,
            .edge = false,
            .colorA = color,
            .colorB = color,
        });

        // These "edge" vertices will allow for anti-aliasing
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .left = true,
            .up = false,
            .edge = true,
            .colorA = color,
            .colorB = color,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .left = false,
            .up = true,
            .edge = true,
            .colorA = color,
            .colorB = color,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .left = true,
            .up = true,
            .edge = true,
            .colorA = color,
            .colorB = color,
        });
        try self.vulkan_vertices.append(allocator, .{
            .posA = left,
            .posB = right,
            .left = false,
            .up = false,
            .edge = true,
            .colorA = color,
            .colorB = color,
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
    }
};

fn makeLine(
    left_pos: [3]f32,
    right_pos: [3]f32,
    left_color: [3]f32,
    right_color: [3]f32,
) [4]vkr.Line {
    return .{
        .{
            .posA = left_pos,
            .posB = right_pos,
            .colorA = left_color,
            .colorB = right_color,
            .left = true,
            .up = false,
        },
        .{
            .posA = left_pos,
            .posB = right_pos,
            .colorA = left_color,
            .colorB = right_color,
            .left = false,
            .up = true,
        },
        .{
            .posA = left_pos,
            .posB = right_pos,
            .colorA = left_color,
            .colorB = right_color,
            .left = true,
            .up = true,
        },
        .{
            .posA = left_pos,
            .posB = right_pos,
            .colorA = left_color,
            .colorB = right_color,
            .left = false,
            .up = false,
        },
    };
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

test "RenderedLines UID generation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rendered_lines = RenderedLines.init();
    defer rendered_lines.deinit(allocator);

    const line_data1 = Line{ .p0 = .{ .x = 0, .y = 0, .z = 0 }, .p1 = .{ .x = 1, .y = 1, .z = 1 } };
    const line_data2 = Line{ .p0 = .{ .x = 2, .y = 2, .z = 2 }, .p1 = .{ .x = 3, .y = 3, .z = 3 } };
    const line_data3 = Line{ .p0 = .{ .x = 4, .y = 4, .z = 4 }, .p1 = .{ .x = 5, .y = 5, .z = 5 } };

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
