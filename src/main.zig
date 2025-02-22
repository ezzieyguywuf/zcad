const std = @import("std");
const wl = @import("WaylandClient.zig");
const vkr = @import("VulkanRenderer.zig");
const vk = @import("vulkan");
const zm = @import("zmath");

const AppContext = struct {
    prev_input_state: wl.InputState,
    eye: zm.Vec,
    focus_point: zm.Vec,
    up: zm.Vec,
    mvp_ubo: vkr.MVPUniformBufferObject,
    should_exit: bool,
};

pub fn InputCallback(app_ctx: *AppContext, input_state: wl.InputState) !void {
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
        .prev_input_state = wl.InputState{},
        .eye = eye,
        .focus_point = focus_point,
        .up = up,
        .mvp_ubo = .{
            .model = zm.identity(),
            .view = zm.lookAtRh(eye, focus_point, up),
            .projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), 1.0, 0.01, 10000.0),
        },
        .should_exit = false,
    };

    // Wayland
    var wl_ctx = try allocator.create(wl.WaylandContext(*AppContext));
    defer allocator.destroy(wl_ctx);
    try wl_ctx.init(&app_ctx, InputCallback, 680, 420);

    // zcad
    const points = [_]Point{
        .{ .x = -5, .y = -5, .z = 0 },
        .{ .x = 5, .y = -5, .z = 0 },
        .{ .x = 5, .y = 5, .z = 0 },
        .{ .x = -5, .y = 5, .z = 0 },
    };
    const scale: f32 = 1.0;
    var vk_triangle_vertices = std.mem.zeroes([points.len]vkr.Vertex);

    for (points, 0..) |point, i| {
        var color = [_]f32{ 0, 0, 0 };
        if (i == 3) {
            color = [_]f32{ 1, 1, 1 };
        } else {
            color[i] = 1;
        }
        vk_triangle_vertices[i] = .{
            .pos = .{
                @as(f32, @floatFromInt(point.x)) / scale,
                @as(f32, @floatFromInt(point.y)) / scale,
                @as(f32, @floatFromInt(point.z)) / scale,
            },
            .color = color,
        };
    }
    const triangle_indices = [_]u32{ 0, 1, 2, 2, 3, 0 };

    const vk_point_vertices = [_]vkr.Vertex{
        .{
            .pos = .{ -5, -5, 0 },
            .color = .{ 0, 0.5, 0.5 },
        },
    };
    const point_indices = [_]u32{0};

    // vulkan
    const vk_ctx = try vkr.VulkanContext.init(
        allocator,
        @ptrCast(wl_ctx.wl_display),
        @ptrCast(wl_ctx.wl_surface),
    );
    defer vk_ctx.deinit(allocator);
    var renderer = try vkr.Renderer.init(allocator, &vk_ctx, @intCast(wl_ctx.width), @intCast(wl_ctx.height));
    try renderer.uploadInstanced(&vk_ctx, .Points, &vk_point_vertices, &point_indices);
    try renderer.uploadInstanced(&vk_ctx, .Triangles, &vk_triangle_vertices, &triangle_indices);
    defer renderer.deinit(allocator, &vk_ctx);

    {
        const aspect_ratio = @as(f32, @floatFromInt(wl_ctx.width)) / @as(f32, @floatFromInt(wl_ctx.height));
        app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.01, 10000.0);
    }
    while ((!wl_ctx.should_exit) and (!app_ctx.should_exit)) {
        if (wl_ctx.should_resize) {
            const aspect_ratio = @as(f32, @floatFromInt(wl_ctx.width)) / @as(f32, @floatFromInt(wl_ctx.height));
            app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.01, 10000.0);
            wl_ctx.resizing_done = true;
        }

        const should_render = try wl_ctx.run();
        if (!should_render) continue;

        app_ctx.mvp_ubo.view = zm.lookAtRh(app_ctx.eye, app_ctx.focus_point, app_ctx.up);
        try renderer.render(
            allocator,
            &vk_ctx,
            @intCast(wl_ctx.width),
            @intCast(wl_ctx.height),
            &app_ctx.mvp_ubo,
        );
    }

    std.debug.print("exited loop\n", .{});
    try renderer.swapchain.waitForAllFences(&vk_ctx.device);
    try vk_ctx.device.deviceWaitIdle();
    std.debug.print("exiting main\n", .{});
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
