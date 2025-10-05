const std = @import("std");
const httpz = @import("httpz");
const geom = @import("Geometry.zig");
const World = @import("World.zig").World;
const testing = std.testing;
const app = @import("Application.zig");
const zm = @import("zmath");
const wnd = @import("WindowingContext.zig");

// Context to be passed to HTTP handlers, containing application state
pub const ServerContext = struct {
    world: *World,
    camera: *app.Camera,
    window_ctx: *wnd.WindowingContext(*app.AppContext),
    allocator: std.mem.Allocator, // Main application's allocator
    tessellation_cond: *std.Thread.Condition,
    stats: Stats,
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

        router.get("/stats", handleGetStats, .{});
        router.post("/moveCamera", handleMoveCamera, .{});
        router.post("/zoomToFit", handleZoomToFit, .{});
        // TODO: Re-examine if GET is the right verb for this endpoint.
        // It modifies server-side state, so POST might be more appropriate,
        // but this requires fixing the test client's handling of bodiless POST requests.
        router.get("/lines", handleGetLines, .{});
        router.get("/vertices", handleGetVertices, .{});

        const thread = try server.listenInNewThread();
        std.debug.print("Server listening on port 4042\n", .{});

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

const Stats = struct {
    frametime_ms: f64,
    bytes_uploaded_to_gpu: u64,
    mut: std.Thread.Mutex,
};

// Represents the expected JSON structure for the /moveCamera endpoint.
const MoveCameraPayload = struct {
    pan: ?[3]f32 = null,
    pitch_rads: ?f32 = null,
    yaw_rads: ?f32 = null,
};

fn handleZoomToFit(server_ctx: *ServerContext, _: *httpz.Request, res: *httpz.Response) !void {
    server_ctx.world.mut.lock();
    const bbox = server_ctx.world.bbox;
    const fov_rads = server_ctx.world.fov_rads;
    server_ctx.world.mut.unlock();

    const aspect_ratio = @as(f32, @floatFromInt(server_ctx.window_ctx.width)) / @as(f32, @floatFromInt(server_ctx.window_ctx.height));

    server_ctx.camera.zoomToFit(bbox, fov_rads, aspect_ratio) catch |err| {
        res.status = 500;
        try addTrailingNewline(res, .{ .@"error" = "Failed to zoom to fit", .details = @errorName(err) });
        return;
    };

    res.status = 200;
    try addTrailingNewline(res, .{ .message = "Zoom to fit successful" });
}

fn handleMoveCamera(server_ctx: *ServerContext, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        try addTrailingNewline(res, .{ .@"error" = "Failed to read request body" });
        return;
    };

    const payload = std.json.parseFromSlice(MoveCameraPayload, server_ctx.allocator, body, .{}) catch {
        res.status = 400;
        try addTrailingNewline(res, .{ .@"error" = "Failed to parse JSON payload. Expected fields: pan: ?[f32,f32,f32], pitch_rads: ?f32, yaw_rads: ?f32" });
        return;
    };
    defer payload.deinit();

    if (payload.value.pan) |pan_slice| {
        const pan_vec: zm.Vec = .{ pan_slice[0], pan_slice[1], pan_slice[2], 0 };
        server_ctx.camera.pan(pan_vec);
    }

    if (payload.value.pitch_rads != null or payload.value.yaw_rads != null) {
        const pitch = payload.value.pitch_rads orelse 0.0;
        const yaw = payload.value.yaw_rads orelse 0.0;
        server_ctx.camera.rotate(pitch, yaw);
    }

    if (payload.value.pan == null and payload.value.pitch_rads == null and payload.value.yaw_rads == null) {
        res.status = 400;
        try addTrailingNewline(res, .{ .@"error" = "At least one of pan, pitch, or yaw must be provided." });
        return;
    }

    res.status = 200;
    try addTrailingNewline(res, .{ .message = "Camera move command processed" });
}

fn trimMutField(T: type) type {
    const T_info = @typeInfo(T).@"struct";
    var new_fields: [T_info.fields.len - 1]std.builtin.Type.StructField = undefined;
    var new_field_idx: usize = 0;

    for (T_info.fields) |field| {
        if (std.mem.eql(u8, field.name, "mut")) {
            continue;
        }
        new_fields[new_field_idx] = field;
        new_field_idx += 1;
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &new_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

fn handleGetStats(server_context: *ServerContext, _: *httpz.Request, res: *httpz.Response) !void {
    server_context.stats.mut.lock();
    const stats = server_context.stats;
    server_context.stats.mut.unlock();

    const StatsNoMutType = trimMutField(Stats);
    var stats_no_mut: StatsNoMutType = undefined;
    inline for (@typeInfo(StatsNoMutType).@"struct".fields) |field| {
        @field(stats_no_mut, field.name) = @field(stats, field.name);
    }
    const fps = 1 / (stats_no_mut.frametime_ms / std.time.ms_per_s);

    res.status = 200;
    try addTrailingNewline(res, .{ .fps = fps, .raw = stats_no_mut });
}

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

fn handleGetLines(server_ctx: *ServerContext, req: *httpz.Request, res: *httpz.Response) !void {
    const query = req.query() catch |err| {
        std.debug.print("Failed to parse query string: {any}\n", .{err});
        res.status = 400;
        try addTrailingNewline(res, .{ .err = "Failed to parse query string" });
        return;
    };

    const p0_str = query.get("p0") orelse {
        res.status = 400;
        try addTrailingNewline(res, .{ .err = "Missing query parameter p0 (e.g., p0=x1,y1,z1)" });
        return;
    };

    const p1_str = query.get("p1") orelse {
        res.status = 400;
        try addTrailingNewline(res, .{ .err = "Missing query parameter p1 (e.g., p1=x2,y2,z2)" });
        return;
    };

    const p0 = parsePoint(p0_str) catch |err| {
        std.debug.print("Failed to parse p0 '{s}': {any}\n", .{ p0_str, err });
        res.status = 400;
        try addTrailingNewline(res, .{ .err = "Invalid format for p0. Expected x,y,z", .details = @errorName(err) });
        return;
    };

    const p1 = parsePoint(p1_str) catch |err| {
        std.debug.print("Failed to parse p1 '{s}': {any}\n", .{ p1_str, err });
        res.status = 400;
        try addTrailingNewline(res, .{ .err = "Invalid format for p1. Expected x,y,z", .details = @errorName(err) });
        return;
    };

    const new_line = geom.Line.init(p0, p1) catch |err| {
        std.debug.print("Failed to initialize line from p0={any} to p1={any}: {any}\n", .{ p0, p1, err });
        res.status = 400;
        try addTrailingNewline(res, .{ .err = "Failed to create line", .details = @errorName(err) });
        return;
    };

    server_ctx.world.addLine(server_ctx.allocator, &new_line) catch |err| {
        std.debug.print("HTTP Server: Error adding line to World: {any}\n", .{err});
        res.status = 500;
        try addTrailingNewline(res, .{ .err = "Failed to add line to internal storage" });
        return;
    };

    server_ctx.tessellation_cond.signal();

    res.status = 200;
    try addTrailingNewline(res, .{ .message = "Line added successfully", .p0 = p0, .p1 = p1 });
}

fn handleGetVertices(server_ctx: *ServerContext, req: *httpz.Request, res: *httpz.Response) !void {
    const query = req.query() catch |err| {
        std.debug.print("Failed to parse query string: {any}\n", .{err});
        res.status = 400;
        try addTrailingNewline(res, .{ .err = "Failed to parse query string" });
        return;
    };

    const p0_str = query.get("p0") orelse {
        res.status = 400;
        try addTrailingNewline(res, .{ .err = "Missing query parameter p0 (e.g., p0=x1,y1,z1)" });
        return;
    };

    const p0 = parsePoint(p0_str) catch |err| {
        std.debug.print("Failed to parse p0 '{s}': {any}\n", .{ p0_str, err });
        res.status = 400;
        try addTrailingNewline(res, .{ .err = "Invalid format for p0. Expected x,y,z", .details = @errorName(err) });
        return;
    };

    server_ctx.world.addVertex(server_ctx.allocator, &p0) catch |err| {
        std.debug.print("HTTP Server: Error adding vertex to World: {any}\n", .{err});
        res.status = 500;
        try addTrailingNewline(res, .{ .err = "Failed to add vertex to internal storage" });
        return;
    };

    server_ctx.tessellation_cond.signal();

    res.status = 200;
    try addTrailingNewline(res, .{ .message = "Vertex added successfully", .p0 = p0 });
}

test "Add vertex via /vertices endpoint" {
    var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = std.testing.allocator };
    const allocator = tsa.allocator();

    var world_storage = World.init();
    defer world_storage.deinit(allocator);
    var tessellation_cond = std.Thread.Condition{};

    var camera = app.Camera{
        .eye = .{ 0, 0, 0, 0 },
        .focus_point = .{ 0, 0, 0, 0 },
        .up = .{ 0, 0, 0, 0 },
        .mut = .{},
        .zoom_changed = .{},
    };
    var app_ctx = app.AppContext{
        .prev_input_state = wnd.InputState{},
        .camera = camera,
        .mvp_ubo = .{
            .model = zm.identity(),
            .view = zm.lookAtRh(camera.eye, camera.focus_point, camera.up),
            .projection = zm.perspectiveFovRh(world_storage.fov_rads, 1.0, 0.1, 10000.0),
        },
        .should_exit = false,
        .should_fetch_id_buffers = false,
        .pointer_x = 0,
        .pointer_y = 0,
    };
    var window_ctx = wnd.WindowingContext(*app.AppContext).init(&app_ctx, undefined, 680, 420);

    var server_ctx = ServerContext{
        .world = &world_storage,
        .allocator = allocator,
        .tessellation_cond = &tessellation_cond,
        .stats = .{
            .frametime_ms = 0,
            .bytes_uploaded_to_gpu = 0,
            .mut = .{},
        },
        .camera = &camera,
        .window_ctx = &window_ctx,
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
        .location = .{ .url = "http://127.0.0.1:4042/vertices?p0=0,0,0" },
    });

    // Assert success
    try std.testing.expectEqual(std.http.Status.ok, fetch_result.status);
    try std.testing.expectEqual(@as(usize, 1), world_storage.vertices.items.len);
}

// Without a trailing newrline, e.g. if you curl your prompt ends up on the same
// line as the response
fn addTrailingNewline(res: *httpz.Response, json: anytype) !void {
    try res.json(json, .{});
    try res.writer().writeByte('\n');
}
