const std = @import("std");
const httpz = @import("httpz");
const vkr = @import("VulkanRenderer.zig");
const geom = @import("Geometry.zig");
const RenderedLines = @import("RenderedLines.zig").RenderedLines;
const testing = std.testing;

// Context to be passed to HTTP handlers, containing application state
pub const ServerContext = struct {
    rendered_lines: *RenderedLines,
    allocator: std.mem.Allocator, // Main application's allocator
    lines_mutex: *std.Thread.Mutex,
    lines_updated_signal: *std.atomic.Value(bool),
};

pub const HttpServer = struct {
    const Server = httpz.Server(*ServerContext);

    server: *Server,
    thread: std.Thread,

    // It's ok for the allocator here to be the same as the one in the
    // ServerContext - the two serve different purposes though. The explicit
    // allocator is used e.g. for allocating memory for HttpServer.server and
    // the nested allocator is used when handling requests if needed.
    // HttpServer.handler.
    pub fn init(allocator: std.mem.Allocator, server_ctx: *ServerContext) !HttpServer {
        // This is on the stack for now b/c of https://github.com/karlseguin/http.zig/issues/135
        const server = try allocator.create(Server);
        server.* = try Server.init(allocator, .{ .port = 4042 }, server_ctx);

        var router = try server.router(.{});
        // TODO: Re-examine if GET is the right verb for this endpoint.
        // It modifies server-side state, so POST might be more appropriate,
        // but this requires fixing the test client's handling of bodiless POST requests.
        router.get("/lines", handlePostLines, .{});

        const thread = try server.listenInNewThread();

        return .{
            .server = server,
            .thread = thread,
        };
    }

    pub fn deinit(self: *HttpServer, allocator: std.mem.Allocator) void {
        // The order here matters
        self.server.stop();
        self.thread.join();
        self.server.deinit();

        // after this order doesn't matter
        allocator.destroy(self.server);
    }
};

const ParsePointError = error{
    InvalidFormat,
    ParseIntError,
};

fn parsePoint(point_str: []const u8) ParsePointError!geom.Point {
    var parts = std.mem.splitScalar(u8, point_str, ',');
    var coords: [3]i64 = undefined;
    var i: usize = 0;
    while (parts.next()) |part| {
        if (i >= 3) return error.InvalidFormat;
        const trimmed_part = std.mem.trim(u8, part, " \t\r\n");
        coords[i] = std.fmt.parseInt(i64, trimmed_part, 10) catch |err| {
            std.debug.print("Failed to parse point component '{s}': {any}\n", .{ trimmed_part, err });
            return error.ParseIntError;
        };
        i += 1;
    }
    if (i != 3) return error.InvalidFormat;

    return geom.Point{ .x = coords[0], .y = coords[1], .z = coords[2] };
}

fn handlePostLines(server_ctx: *ServerContext, req: *httpz.Request, res: *httpz.Response) !void {
    const query = req.query() catch |err| {
        std.debug.print("Failed to parse query string: {any}\n", .{err});
        res.status = 400;
        try res.json(.{ .err = "Failed to parse query string" }, .{});
        return;
    };

    const p0_str = query.get("p0") orelse {
        res.status = 400;
        try res.json(.{ .err = "Missing query parameter p0 (e.g., p0=x1,y1,z1)" }, .{});
        return;
    };

    const p1_str = query.get("p1") orelse {
        res.status = 400;
        try res.json(.{ .err = "Missing query parameter p1 (e.g., p1=x2,y2,z2)" }, .{});
        return;
    };

    const p0 = parsePoint(p0_str) catch |err| {
        std.debug.print("Failed to parse p0 '{s}': {any}\n", .{ p0_str, err });
        res.status = 400;
        try res.json(.{ .err = "Invalid format for p0. Expected x,y,z", .details = @errorName(err) }, .{});
        return;
    };

    const p1 = parsePoint(p1_str) catch |err| {
        std.debug.print("Failed to parse p1 '{s}': {any}\n", .{ p1_str, err });
        res.status = 400;
        try res.json(.{ .err = "Invalid format for p1. Expected x,y,z", .details = @errorName(err) }, .{});
        return;
    };

    const new_line = geom.Line.init(p0, p1) catch |err| {
        std.debug.print("Failed to initialize line from p0={any} to p1={any}: {any}\n", .{ p0, p1, err });
        res.status = 400;
        try res.json(.{ .err = "Failed to create line", .details = @errorName(err) }, .{});
        return;
    };

    {
        server_ctx.lines_mutex.lock();
        defer server_ctx.lines_mutex.unlock();

        server_ctx.rendered_lines.addLine(server_ctx.allocator, new_line) catch |err| {
            std.debug.print("HTTP Server: Error adding line to RenderedLines: {any}\n", .{err});
            res.status = 500;
            try res.json(.{ .err = "Failed to add line to internal storage" }, .{});
            return;
        };
    }

    server_ctx.lines_updated_signal.store(true, .release);

    res.status = 200;
    try res.json(.{ .message = "Line added successfully", .p0 = p0, .p1 = p1 }, .{});
    // trailing newline in response makes e.g. command-line interactions nicer.
    try res.writer().writeByte('\n');
}

test "HttpServer can shut down without crashing or leaking memory" {
    var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = std.testing.allocator };
    const allocator = tsa.allocator();

    var rendered_lines_storage = RenderedLines.init();
    defer rendered_lines_storage.deinit(allocator);
    var lines_mutex = std.Thread.Mutex{};
    var lines_updated_signal = std.atomic.Value(bool).init(false);

    var server_ctx = ServerContext{
        .rendered_lines = &rendered_lines_storage,
        .allocator = allocator,
        .lines_mutex = &lines_mutex,
        .lines_updated_signal = &lines_updated_signal,
    };

    var server_instance = try HttpServer.init(allocator, &server_ctx);

    // Now we can shut down
    server_instance.deinit(allocator);

    // this test case will fail if there is a memory leak or if the server
    // shutdown fails to join the spawned thread.
}

test "Add line via /lines endpoint" {
    var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = std.testing.allocator };
    const allocator = tsa.allocator();

    var rendered_lines_storage = RenderedLines.init();
    defer rendered_lines_storage.deinit(allocator);
    var lines_mutex = std.Thread.Mutex{};
    var lines_updated_signal = std.atomic.Value(bool).init(false);

    var server_ctx = ServerContext{
        .rendered_lines = &rendered_lines_storage,
        .allocator = allocator,
        .lines_mutex = &lines_mutex,
        .lines_updated_signal = &lines_updated_signal,
    };

    // Initialize HttpServer (in a separate thread)
    var server = try HttpServer.init(allocator, &server_ctx);
    defer server.deinit(allocator);

    // Initialize HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // make POST request
    const fetch_result = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = "http://127.0.0.1:4042/lines?p0=0,0,0&p1=1,1,1" },
    });

    // Assert success
    try std.testing.expectEqual(std.http.Status.ok, fetch_result.status);
}
