const std = @import("std");
const wl = @import("WaylandClient.zig");
const vkr = @import("VulkanRenderer.zig");
const vk = @import("vulkan");
const zm = @import("zmath");

const AppContext = struct {
    prev_input_state: wl.InputState,
    angle: f32,
    eye: zm.Vec,
    focus_point: zm.Vec,
    up: zm.Vec,
    mvp_ubo: vkr.MVPUniformBufferObject,
    should_exit: bool,
};

pub fn InputCallback(app_ctx: *AppContext, input_state: wl.InputState) !void {
    const delta_angle = std.math.pi / @as(f32, 9);
    if ((!input_state.window_moving) and (!input_state.window_resizing)) {
        if (input_state.left_button and !app_ctx.prev_input_state.left_button) {
            app_ctx.angle += delta_angle;
        }
        if (input_state.right_button and !app_ctx.prev_input_state.right_button) {
            app_ctx.angle -= delta_angle;
        }
        if (input_state.middle_button and !app_ctx.prev_input_state.middle_button) {}
    }

    const total_scroll = input_state.vertical_scroll + app_ctx.prev_input_state.vertical_scroll;
    app_ctx.prev_input_state = input_state;
    app_ctx.prev_input_state.vertical_scroll = total_scroll;

    const delta_zoom: ?f64 = if (total_scroll > 1 or total_scroll < -1) total_scroll else null;
    if (delta_zoom) |amt| {
        std.debug.print("eye: ({d:3}, {d:3}, {d:3})\n", .{ app_ctx.eye[0], app_ctx.eye[1], app_ctx.eye[2] });
        const dir_long = app_ctx.focus_point - app_ctx.eye;
        std.debug.print("  dir_long: ({d:3}, {d:3}, {d:3})\n", .{ dir_long[0], dir_long[1], dir_long[2] });
        const dir_len = zm.length3(dir_long)[0];
        std.debug.print("  dir_len; {d:3}\n", .{dir_len});
        const dir = zm.normalize3(app_ctx.focus_point - app_ctx.eye);
        app_ctx.eye += @as(zm.Vec, @splat(@floatCast(amt))) * dir;
        app_ctx.prev_input_state.vertical_scroll = 0;
        std.debug.print("  dir: ({d:3}, {d:3}, {d:3})\n", .{ dir[0], dir[1], dir[2] });
        std.debug.print("  amt: {d:3}\n", .{amt});
        std.debug.print("  eye: ({d:3}, {d:3}, {d:3})\n", .{ app_ctx.eye[0], app_ctx.eye[1], app_ctx.eye[2] });
    }

    if (app_ctx.angle > 0.001 or app_ctx.angle < -0.001) {
        const axis = zm.Vec{ 0, 1, 0, 0 };
        app_ctx.mvp_ubo.model = zm.matFromAxisAngle(axis, app_ctx.angle);
    }
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
        .angle = 0,
        .eye = eye,
        .focus_point = focus_point,
        .up = up,
        .mvp_ubo = .{
            .model = zm.identity(),
            .view = zm.lookAtRh(eye, focus_point, up),
            .projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), 1.0, 0.01, 100.0),
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
    var vkVertices = std.mem.zeroes([points.len]vkr.Vertex);

    for (points, 0..) |point, i| {
        var color = [_]f32{ 0, 0, 0 };
        if (i == 3) {
            color = [_]f32{ 1, 1, 1 };
        } else {
            color[i] = 1;
        }
        vkVertices[i] = .{
            .pos = .{
                @as(f32, @floatFromInt(point.x)) / scale,
                @as(f32, @floatFromInt(point.y)) / scale,
                @as(f32, @floatFromInt(point.z)) / scale,
            },
            .color = color,
        };
    }
    const indices = [_]u32{ 0, 1, 2, 2, 3, 0 };

    // vulkan
    const vk_ctx = try vkr.VulkanContext.init(
        allocator,
        @ptrCast(wl_ctx.wl_display),
        @ptrCast(wl_ctx.wl_surface),
    );
    var renderer = try vkr.Renderer.init(
        allocator,
        &vk_ctx,
        @intCast(wl_ctx.width),
        @intCast(wl_ctx.height),
        &vkVertices,
        &indices,
    );
    defer renderer.deinit(allocator, &vk_ctx);

    {
        const aspect_ratio = @as(f32, @floatFromInt(wl_ctx.width)) / @as(f32, @floatFromInt(wl_ctx.height));
        app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.01, 100.0);
    }
    while ((!wl_ctx.should_exit) or (!app_ctx.should_exit)) {
        const should_render = try wl_ctx.run();
        if (!should_render) continue;
        if (wl_ctx.should_resize) {
            const aspect_ratio = @as(f32, @floatFromInt(wl_ctx.width)) / @as(f32, @floatFromInt(wl_ctx.height));
            app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.01, 100.0);
        }

        try renderer.render(
            allocator,
            &vk_ctx,
            @intCast(wl_ctx.width),
            @intCast(wl_ctx.height),
            &app_ctx.mvp_ubo,
        );
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
