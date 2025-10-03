const std = @import("std");
const vkr = @import("VulkanRenderer.zig");
const wnd = @import("WindowingContext.zig");
const zm = @import("zmath");
const x11 = @import("X11Context.zig");
const wl = @import("WaylandContext.zig");
const wrld = @import("World.zig");

const Camera = struct {
    eye: zm.Vec,
    focus_point: zm.Vec,
    up: zm.Vec,
    mut: std.Thread.Mutex,
};

const AppContext = struct {
    prev_input_state: wnd.InputState,
    camera: Camera,
    mvp_ubo: vkr.MVPUniformBufferObject,
    should_exit: bool,
    should_fetch_id_buffers: bool,
    pointer_x: usize,
    pointer_y: usize,
};

const Self = @This();

app_ctx: *AppContext,
window_ctx: *wnd.WindowingContext(*AppContext),
vk_ctx: vkr.VulkanContext,

renderer: vkr.Renderer,
os_window: OsWindow,
tesselator: *wrld.Tesselator,
tesselator_thread: std.Thread,
id_buffers: vkr.IdBuffers,

pub fn init(allocator: std.mem.Allocator, use_x11: bool, world: *wrld.World) !Self {
    const eye: zm.Vec = .{ 2000, -1500, 2000, 1 };
    const focus_point: zm.Vec = .{ 0, 0, 0, 1 };
    const up: zm.Vec = .{ 0, 1, 0, 0 };
    var app_ctx = try allocator.create(AppContext);
    app_ctx.* = AppContext{
        .prev_input_state = wnd.InputState{},
        .camera = .{
            .eye = eye,
            .focus_point = focus_point,
            .up = up,
            .mut = .{},
        },
        .mvp_ubo = .{
            .model = zm.identity(),
            .view = zm.lookAtRh(eye, focus_point, up),
            .projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), 1.0, 0.1, 10000.0),
        },
        .should_exit = false,
        .should_fetch_id_buffers = false,
        .pointer_x = 0,
        .pointer_y = 0,
    };

    var window_ctx = try allocator.create(wnd.WindowingContext(*AppContext));
    window_ctx.* = wnd.WindowingContext(*AppContext).init(app_ctx, InputCallback, 680, 420);
    var os_window = if (use_x11) OsWindow{ .xlib = try allocator.create(x11.X11Context(*AppContext)) } else OsWindow{ .wayland = try allocator.create(wl.WaylandContext(*AppContext)) };

    switch (os_window) {
        .xlib => |*window| try window.*.init(window_ctx),
        .wayland => |*window| try window.*.init(window_ctx),
    }

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
    const renderer = try vkr.Renderer.init(allocator, &vk_ctx, @intCast(window_ctx.width), @intCast(window_ctx.height));

    const aspect_ratio = @as(f32, @floatFromInt(window_ctx.width)) / @as(f32, @floatFromInt(window_ctx.height));
    app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.1, 1000.0);

    const tesselator = try allocator.create(wrld.Tesselator);
    tesselator.* = wrld.Tesselator.init(world);
    const tesselator_thread = try std.Thread.spawn(.{}, wrld.Tesselator.run, .{tesselator});

    return .{
        .app_ctx = app_ctx,
        .window_ctx = window_ctx,
        .vk_ctx = vk_ctx,
        .os_window = os_window,
        .renderer = renderer,
        .tesselator = tesselator,
        .tesselator_thread = tesselator_thread,
        .id_buffers = vkr.IdBuffers.init(),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    switch (self.os_window) {
        .xlib => |window| allocator.destroy(window),
        .wayland => |window| allocator.destroy(window),
    }
    allocator.destroy(self.window_ctx);

    self.tesselator.stop();
    self.tesselator_thread.join();
    allocator.destroy(self.tesselator);

    self.renderer.deinit(allocator, &self.vk_ctx);
    self.vk_ctx.deinit(allocator);

    self.id_buffers.deinit(allocator);
    allocator.destroy(self.app_ctx);
}

pub fn tick(self: *Self, allocator: std.mem.Allocator) !?usize {
    var uploaded_bytes: ?usize = null;

    if (self.tesselator.tessellation_ready.isSet()) {
        self.tesselator.tessellation_ready.reset();
        self.tesselator.mut.lock();
        defer self.tesselator.mut.unlock();

        if (self.tesselator.renderable_vertices.vulkan_vertices.items.len > 0 and self.tesselator.renderable_vertices.vulkan_indices.items.len > 0) {
            try self.renderer.uploadInstanced(vkr.Vertex, &self.vk_ctx, .Points, self.tesselator.renderable_vertices.vulkan_vertices.items, self.tesselator.renderable_vertices.vulkan_indices.items);
        }
        if (self.tesselator.renderable_lines.vulkan_vertices.items.len > 0 and self.tesselator.renderable_lines.vulkan_indices.items.len > 0) {
            try self.renderer.uploadInstanced(vkr.Line, &self.vk_ctx, .Lines, self.tesselator.renderable_lines.vulkan_vertices.items, self.tesselator.renderable_lines.vulkan_indices.items);
        }
        const upload_vertex_bytes = @sizeOf(@TypeOf(self.tesselator.renderable_vertices.vulkan_vertices)) * self.tesselator.renderable_vertices.vulkan_vertices.items.len + @sizeOf(@TypeOf(self.tesselator.renderable_vertices.vulkan_indices)) * self.tesselator.renderable_vertices.vulkan_indices.items.len;
        const upload_lines_bytes = @sizeOf(@TypeOf(self.tesselator.renderable_lines.vulkan_vertices)) * self.tesselator.renderable_lines.vulkan_vertices.items.len + @sizeOf(@TypeOf(self.tesselator.renderable_lines.vulkan_indices)) * self.tesselator.renderable_lines.vulkan_indices.items.len;
        uploaded_bytes = upload_vertex_bytes + upload_lines_bytes;
    }

    if (self.app_ctx.should_fetch_id_buffers) {
        self.app_ctx.should_fetch_id_buffers = false;
        try self.id_buffers.fill(allocator, &self.renderer, &self.vk_ctx);
        const i = self.app_ctx.pointer_x + self.app_ctx.pointer_y * @as(usize, @intCast(self.window_ctx.width));
        if (i >= self.id_buffers.vertex_ids.ids.items.len) {
            std.debug.print("ERROR: index {d} bigger than len {d}\n", .{ i, self.id_buffers.vertex_ids.ids.items.len });
        } else {
            const vertex_id = self.id_buffers.vertex_ids.ids.items[i];
            const line_id = self.id_buffers.line_ids.ids.items[i];
            const surface_id = self.id_buffers.surface_ids.ids.items[i];

            if (vertex_id != std.math.maxInt(u64)) {
                std.debug.print("got vertex_id: {d}\n", .{vertex_id});
            } else if (line_id != std.math.maxInt(u64)) {
                std.debug.print("got line_id: {d}\n", .{line_id});
            } else if (surface_id != std.math.maxInt(u64)) {
                std.debug.print("got surface_id: {d}\n", .{surface_id});
            } else {
                std.debug.print("no item clicked\n", .{});
            }
        }
    }

    if (self.window_ctx.should_resize) {
        const aspect_ratio = @as(f32, @floatFromInt(self.window_ctx.width)) / @as(f32, @floatFromInt(self.window_ctx.height));
        self.app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.1, 10000.0);
        self.window_ctx.resizing_done = true;
    }

    const should_render = switch (self.os_window) {
        .xlib => true,
        .wayland => |window| try window.run(),
    };
    if (should_render) {
        self.app_ctx.camera.mut.lock();
        self.app_ctx.mvp_ubo.view = zm.lookAtRh(self.app_ctx.camera.eye, self.app_ctx.camera.focus_point, self.app_ctx.camera.up);
        self.app_ctx.camera.mut.unlock();
        try self.renderer.render(
            allocator,
            &self.vk_ctx,
            @intCast(self.window_ctx.width),
            @intCast(self.window_ctx.height),
            &self.app_ctx.mvp_ubo,
        );
    }

    return uploaded_bytes;
}

pub fn should_loop(self: *const Self) bool {
    return (!self.window_ctx.should_exit) and (!self.app_ctx.should_exit);
}

const OsWindow = union(wnd.WindowingType) {
    xlib: *x11.X11Context(*AppContext),
    wayland: *wl.WaylandContext(*AppContext),
};

pub fn InputCallback(app_ctx: *AppContext, input_state: wnd.InputState) !void {
    if (input_state.should_close) {
        std.debug.print("InputCallback: should_close received\n", .{});
        app_ctx.should_exit = true;
        return;
    }
    const total_vertical_scroll = 10.0 * (input_state.vertical_scroll + app_ctx.prev_input_state.vertical_scroll);
    const total_horizontal_scroll = input_state.horizontal_scroll + app_ctx.prev_input_state.horizontal_scroll;

    app_ctx.camera.mut.lock();
    defer app_ctx.camera.mut.unlock();
    const dir_long = app_ctx.camera.focus_point - app_ctx.camera.eye;
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
        }
        if (input_state.left_button) {
            const delta_x = input_state.pointer_x - app_ctx.prev_input_state.pointer_x;
            const angle_x = delta_radians * delta_x;
            const rotate_x = zm.matFromAxisAngle(app_ctx.camera.up, @floatCast(angle_x));

            const delta_y = input_state.pointer_y - app_ctx.prev_input_state.pointer_y;
            const angle_y = delta_radians * delta_y;
            const axis = zm.cross3(app_ctx.camera.eye, app_ctx.camera.up);
            const rotate_y = zm.matFromAxisAngle(axis, @floatCast(angle_y));

            app_ctx.camera.up = zm.mul(rotate_y, zm.mul(rotate_x, app_ctx.camera.up));
            app_ctx.camera.eye = zm.mul(rotate_y, zm.mul(rotate_x, app_ctx.camera.eye));
        }
    }

    if (total_horizontal_scroll != 0) {
        const angle = delta_radians * total_horizontal_scroll;
        const rotate = zm.matFromAxisAngle(app_ctx.camera.up, @floatCast(angle));
        const new_dir_long = zm.mul(rotate, dir_long);
        app_ctx.camera.focus_point = app_ctx.camera.eye + new_dir_long;
    }

    if (total_vertical_scroll < 0 or dir_len > delta_eye_len) {
        app_ctx.camera.eye += @as(zm.Vec, @splat(@floatCast(total_vertical_scroll))) * dir;
    }

    app_ctx.prev_input_state = input_state;
    app_ctx.prev_input_state.vertical_scroll = 0;
    app_ctx.prev_input_state.horizontal_scroll = 0;
}

// TODO: enable this once we have a headless thing.
// test "Application lifecycle" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();

//     var world = wrld.World.init();
//     defer world.deinit(allocator);

//     var app = try Self.init(allocator, false, &world);

//     // Tick once to ensure no crashes on first frame.
//     _ = try app.tick(allocator);

//     try app.deinit(allocator);
// }
