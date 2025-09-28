const std = @import("std");
const wl = @import("WaylandContext.zig");
const vkr = @import("VulkanRenderer.zig");
const wnd = @import("WindowingContext.zig");
const x11 = @import("X11Context.zig");
const vk = @import("vulkan");
const zm = @import("zmath");
const rndr = @import("Renderables.zig");
const geom = @import("Geometry.zig");
const HttpServer = @import("HttpServer.zig");
const wrld = @import("World.zig");

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
    const total_vertical_scroll = 10.0 * (input_state.vertical_scroll + app_ctx.prev_input_state.vertical_scroll);
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
            // std.debug.print("eye: {any}, focus_point: {any}, up: {any}\n", .{ app_ctx.eye, app_ctx.focus_point, app_ctx.up });
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
    var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = gpa.allocator() };
    const allocator = tsa.allocator();

    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("Welcome to zcad debugging stream\n", .{});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Welcome to zcad.\n", .{});

    try stdout.flush(); // Don't forget to flush!

    const eye: zm.Vec = .{ 2000, -1500, 2000, 1 };
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
            .projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), 1.0, 0.1, 10000.0),
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

    {
        const aspect_ratio = @as(f32, @floatFromInt(wnd_ctx.width)) / @as(f32, @floatFromInt(wnd_ctx.height));
        app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.1, 1000.0);
    }

    var id_buffers = vkr.IdBuffers.init();
    defer id_buffers.deinit(allocator);

    var world = wrld.World.init();
    defer world.deinit(allocator);

    var tesselator = wrld.Tesselator.init(&world);
    const tesselator_thread = try std.Thread.spawn(.{}, wrld.Tesselator.run, .{&tesselator});
    defer {
        tesselator.stop();
        tesselator_thread.join();
    }

    var server_app_ctx = HttpServer.ServerContext{
        .world = &world,
        .allocator = allocator,
        .tessellation_cond = &(tesselator.should_tesselate),
    };

    var server = try HttpServer.HttpServer.init(allocator, &server_app_ctx);
    defer server.deinit(allocator);

    while ((!wnd_ctx.should_exit) and (!app_ctx.should_exit)) {
        if (tesselator.tessellation_ready.isSet()) {
            tesselator.tessellation_ready.reset();

            tesselator.mut.lock();
            defer tesselator.mut.unlock();

            if (tesselator.renderable_vertices.vulkan_vertices.items.len > 0 and tesselator.renderable_vertices.vulkan_indices.items.len > 0) {
                try renderer.uploadInstanced(vkr.Vertex, &vk_ctx, .Points, tesselator.renderable_vertices.vulkan_vertices.items, tesselator.renderable_vertices.vulkan_indices.items);
            }
            if (tesselator.renderable_lines.vulkan_vertices.items.len > 0 and tesselator.renderable_lines.vulkan_indices.items.len > 0) {
                try renderer.uploadInstanced(vkr.Line, &vk_ctx, .Lines, tesselator.renderable_lines.vulkan_vertices.items, tesselator.renderable_lines.vulkan_indices.items);
            }
        }

        if (app_ctx.should_fetch_id_buffers) {
            app_ctx.should_fetch_id_buffers = false;
            try id_buffers.fill(allocator, &renderer, &vk_ctx);
            const i = app_ctx.pointer_x + app_ctx.pointer_y * @as(usize, @intCast(wnd_ctx.width));
            if (i >= id_buffers.vertex_ids.ids.items.len) {
                std.debug.print("index {d} bigger than len {d}\n", .{ i, id_buffers.vertex_ids.ids.items.len });
            } else {
                const vertex_id = id_buffers.vertex_ids.ids.items[i];
                const line_id = id_buffers.line_ids.ids.items[i];
                const surface_id = id_buffers.surface_ids.ids.items[i];

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

        if (wnd_ctx.should_resize) {
            const aspect_ratio = @as(f32, @floatFromInt(wnd_ctx.width)) / @as(f32, @floatFromInt(wnd_ctx.height));
            app_ctx.mvp_ubo.projection = zm.perspectiveFovRh(std.math.pi / @as(f32, 4), aspect_ratio, 0.1, 10000.0);
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

test {
    _ = @import("HttpServer.zig");
    _ = @import("Geometry.zig");
    _ = @import("WaylandContext.zig");
    _ = @import("WindowingContext.zig");
    _ = @import("VulkanRenderer.zig");
    _ = @import("X11Context.zig");
    _ = @import("Renderables.zig");
}
