const std = @import("std");
const httpz = @import("httpz");
const vkr = @import("VulkanRenderer.zig"); // Assuming VulkanRenderer.zig is accessible
const main_types = @import("main.zig"); // To access RenderedLines

// Context to be passed to HTTP handlers, containing application state
pub const ServerAppContext = struct {
    rendered_lines: *main_types.RenderedLines,
    renderer: *vkr.Renderer,
    allocator: std.mem.Allocator, // Main application's allocator
    lines_mutex: *std.Thread.Mutex,
    lines_updated_signal: *std.atomic.Value(bool),
};

const ParsePointError = error{
    InvalidFormat, // Not "x,y,z"
    ParseIntError, // Failed to parse one of x,y,z to i64
};

fn parsePoint(allocator: std.mem.Allocator, point_str: []const u8) ParsePointError!main_types.Point {
    var parts = std.mem.splitScalar(u8, point_str, ',');
    var coords: [3]i64 = undefined;
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= 3) return error.InvalidFormat; // Too many parts
        const trimmed_part = std.mem.trim(u8, part, " \t\r\n");
        coords[i] = std.fmt.parseInt(i64, trimmed_part, 10) catch |err| {
            std.debug.print("Failed to parse point component '{s}': {any}\n", .{ trimmed_part, err });
            return error.ParseIntError;
        };
        i += 1;
    }
    if (i != 3) return error.InvalidFormat; // Not enough parts

    return main_types.Point{ .x = coords[0], .y = coords[1], .z = coords[2] };
}

fn handlePostLines(app_ctx: *ServerAppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const query = req.query() catch |err| {
        std.debug.print("Failed to parse query string: {any}\n", .{err});
        res.status = 400; // Bad Request
        try res.json(.{ .error = "Failed to parse query string" }, .{});
        return;
    };

    const p0_str = query.get("p0") orelse {
        res.status = 400; // Bad Request
        try res.json(.{ .error = "Missing query parameter p0 (e.g., p0=x1,y1,z1)" }, .{});
        return;
    };

    const p1_str = query.get("p1") orelse {
        res.status = 400; // Bad Request
        try res.json(.{ .error = "Missing query parameter p1 (e.g., p1=x2,y2,z2)" }, .{});
        return;
    };

    const p0 = parsePoint(app_ctx.allocator, p0_str) catch |err| {
        std.debug.print("Failed to parse p0 '{s}': {any}\n", .{ p0_str, err });
        res.status = 400; // Bad Request
        try res.json(.{ .error = "Invalid format for p0. Expected x,y,z", .details = @errorName(err) }, .{});
        return;
    };

    const p1 = parsePoint(app_ctx.allocator, p1_str) catch |err| {
        std.debug.print("Failed to parse p1 '{s}': {any}\n", .{ p1_str, err });
        res.status = 400; // Bad Request
        try res.json(.{ .error = "Invalid format for p1. Expected x,y,z", .details = @errorName(err) }, .{});
        return;
    };

    const new_line = main_types.Line.init(p0, p1) catch |err| {
        std.debug.print("Failed to initialize line from p0={any} to p1={any}: {any}\n", .{ p0, p1, err });
        res.status = 400; // Bad Request - e.g., ZeroLengthLine
        try res.json(.{ .error = "Failed to create line", .details = @errorName(err) }, .{});
        return;
    };

    app_ctx.lines_mutex.lock();
    defer app_ctx.lines_mutex.unlock();

    app_ctx.rendered_lines.addLine(app_ctx.allocator, new_line) catch |err| {
        std.debug.print("HTTP Server: Error adding line to RenderedLines: {any}\n", .{err});
        res.status = 500; // Internal Server Error
        try res.json(.{ .error = "Failed to add line to internal storage" }, .{});
        return;
    };

    std.debug.print("HTTP Server: Line added via HTTP: p0={any}, p1={any}. Total line objects: {d}\n", .{ p0, p1, app_ctx.rendered_lines.next_uid });
    app_ctx.lines_updated_signal.store(true, .Release);

    res.status = 200;
    try res.json(.{ .message = "Line added successfully", .p0 = p0, .p1 = p1 }, .{});
}

pub fn startServer(_allocator: std.mem.Allocator, app_ctx: *ServerAppContext) !void {
    // The server will own its own allocator for its internal operations.
    // app_ctx.allocator is the main application's allocator, used for addLine.
    var server_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const server_allocator = server_gpa.allocator();
    // app_ctx.allocator is already set by main.zig before calling startServer

    var server = try httpz.Server(*ServerAppContext).init(server_allocator, .{ .port = 4042 }, app_ctx);
    errdefer {
        server.deinit();
        server_gpa.deinit();
    }

    var router = try server.router(.{});
    // Pass the app_ctx to the handler through httpz's handler context mechanism
    // The last parameter to router.post is route-specific configuration.
    // If your Server was initialized with a context (app_ctx here), that context is passed to handlers.
    router.post("/lines", handlePostLines, .{});

    std.debug.print("Server listening on localhost:4042\n", .{});
    try server.listen(); // This blocks

    // This part will only be reached if server.listen() returns (e.g., on error).
    // Graceful shutdown (server.stop()) would typically be initiated from another thread (e.g., main app signal).
    std.debug.print("Server finished listening or failed to start.\n", .{});
    // Server resources are deinitialized by errdefer or if listen returns.
    // If listen blocks and is stopped by server.stop(), deinit here might be redundant
    // or httpz handles it. For now, ensure gpa is deinitialized if listen fails early.
    server.deinit();
    server_gpa.deinit();
}
