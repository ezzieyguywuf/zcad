const std = @import("std");
const HttpServer = @import("HttpServer.zig");
const World = @import("World.zig").World;
const Application = @import("Application.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = gpa.allocator() };
    const allocator = tsa.allocator();

    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("Welcome to zcad debugging stream\n", .{});

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

    var world = World.init();
    defer world.deinit(allocator);

    var app = try Application.init(allocator, use_x11, &world);
    defer app.deinit(allocator);

    var server_ctx = HttpServer.ServerContext{
        .world = &world,
        .camera = &app.app_ctx.camera,
        .window_ctx = app.window_ctx,
        .allocator = allocator,
        .tessellation_cond = &(app.tesselator.should_tesselate),
        .stats = .{
            .frametime_ms = 0,
            .bytes_uploaded_to_gpu = 0,
            .mut = .{},
        },
    };

    var server = try HttpServer.HttpServer.init(allocator, &server_ctx);
    defer server.deinit(allocator);

    while (app.should_loop()) {
        const start_time = std.time.microTimestamp();

        if (app.app_ctx.camera.zoom_changed.isSet()) {
            app.app_ctx.camera.zoom_changed.reset();
            world.mut.lock();
            defer world.mut.unlock();

            world.far_plane = app.app_ctx.camera.farPlane(world.bbox);
        }

        const uploaded_bytes = try app.tick(allocator);
        if (uploaded_bytes) |bytes| {
            server_ctx.stats.mut.lock();
            defer server_ctx.stats.mut.unlock();
            server_ctx.stats.bytes_uploaded_to_gpu = bytes;
        }

        const time_delta_ms: f64 = @as(f64, @floatFromInt(std.time.microTimestamp() - start_time)) / @as(f64, @floatFromInt(std.time.us_per_ms));
        server_ctx.stats.mut.lock();
        defer server_ctx.stats.mut.unlock();
        server_ctx.stats.frametime_ms = time_delta_ms;
    }

    try app.renderer.swapchain.waitForAllFences(&app.vk_ctx.device);
    try app.vk_ctx.device.deviceWaitIdle();
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
