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

    var server_ctx = HttpServer.ServerContext{
        .world = &world,
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

    var last_uploaded_bytes: usize = 0;

    while (app.should_loop()) {
        const start_time = std.time.microTimestamp();

        const uploaded_bytes = try app.tick(allocator);
        if (uploaded_bytes) |bytes| {
            last_uploaded_bytes = bytes;

            server_ctx.stats.mut.lock();
            defer server_ctx.stats.mut.unlock();
            server_ctx.stats.bytes_uploaded_to_gpu = bytes;
        }

        const time_delta_ms: f64 = @as(f64, @floatFromInt(std.time.microTimestamp() - start_time)) / @as(f64, @floatFromInt(std.time.us_per_ms));
        server_ctx.stats.mut.lock();
        defer server_ctx.stats.mut.unlock();
        server_ctx.stats.frametime_ms = time_delta_ms;
    }
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
