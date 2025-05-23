const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const net = std.net;
const http = std.http;
const json = std.json;
const fs = std.fs;

// Assuming types are accessible from main.zig and VulkanRenderer.zig are in the same package
// or appropriately referenced in build.zig for test builds.
const main_types = @import("main.zig");
const vkr = @import("VulkanRenderer.zig"); // For Renderer type
const HttpServer = @import("HttpServer.zig");

// Global allocator for tests
var test_allocator: std.mem.Allocator = undefined;

// Mock Renderer (if needed, for now we pass null if startServer handles it)
// For this test, we mainly care about RenderedLines and the HTTP interface.
// A more complex mock might be needed if Renderer methods were called directly by server.
const MockRenderer = struct {
    // Add fields if methods are called that need state
};

// Helper to manage server thread
var server_thread: ?std.Thread = null;
var server_app_ctx_for_test: ?HttpServer.ServerAppContext = null;
var server_should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var lines_mutex_for_test = std.Thread.Mutex{};
var lines_updated_atomic_for_test = std.atomic.Value(bool).init(false);

fn runTestServer(
    alloc: std.mem.Allocator,
    rendered_lines: *main_types.RenderedLines,
    renderer: ?*MockRenderer, // Using mock, or null if not strictly needed by server logic
) !void {
    // This function will be spawned in a thread
    var server_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = server_gpa.deinit();
    const server_thread_allocator = server_gpa.allocator();

    // Initialize the actual ServerAppContext for the HttpServer
    // The renderer field might need a proper mock if the server interacts with it.
    // For now, assuming handlePostLines only needs rendered_lines, allocator, mutex, signal.
    var concrete_renderer: vkr.Renderer = undefined; // Dummy, not fully initialized
    if (renderer != null) {
        // If a mock is actually used and needs fields from vkr.Renderer,
        // this part would need more careful handling or a more complete mock.
        // For now, this is a placeholder to make the type system happy.
        // Let's assume the server doesn't deeply interact with renderer for POST /lines.
    }

    var app_ctx = HttpServer.ServerAppContext{
        .rendered_lines = rendered_lines,
        .renderer = &concrete_renderer, // Pass the dummy renderer
        .allocator = alloc, // Main test allocator
        .lines_mutex = &lines_mutex_for_test,
        .lines_updated_signal = &lines_updated_atomic_for_test,
    };
    server_app_ctx_for_test = app_ctx; // Store for potential access in tests (e.g., to check line count directly)

    // Wrap the actual server start in a loop that checks server_should_stop
    // This is tricky because httpz.Server.listen() is blocking.
    // A real robust solution might involve httpz providing a non-blocking mode or
    // a way to interrupt listen(). For testing, we might have to rely on
    // the server exiting after requests if it's designed that way, or just let it run
    // and kill the thread (which is not ideal).
    // Given http.zig's design, a clean stop from another thread is not trivial.
    // We will proceed with the understanding that `server.stop()` might not be callable
    // directly here to break the `listen()` loop from outside without modifying http.zig.
    // For the purpose of this test, we'll let listen() block and the test client
    // will make requests. The thread will be joined at the end.

    std.debug.print("\nTest server starting...\n", .{});
    HttpServer.startServer(server_thread_allocator, &app_ctx) catch |err| {
        if (err == error.AddressInUse) {
            std.debug.print("Test server: Address already in use. This might be from a previous test run.\n", .{});
        } else if (err != error.ConnectionResetByPeer and err != error.BrokenPipe) {
            // Expected errors if client disconnects abruptly or server is stopped while client is connected
            std.debug.print("Test server error: {any}\n", .{err});
        }
    };
    std.debug.print("\nTest server stopped.\n", .{});
}

// Helper to make HTTP requests
fn makeRequest(alloc: std.mem.Allocator, method: http.Method, path_and_query: []const u8, body: ?[]const u8) !http.Client.Request {
    const server_address = try net.Address.parseIp("127.0.0.1", 4042);
    var client = http.Client{ .allocator = alloc };
    defer client.deinit();

    var req = try client.request(method, server_address, path_and_query, .{});
    // req.transfer_encoding = .chunked; // Enable for POST if httpz expects it for non-empty bodies
    if (body) |b| {
        try req.write(b);
    }
    try req.finish();
    return req;
}

test "HTTP Server - Dynamic Line Creation and Error Handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    test_allocator = gpa.allocator();

    var rendered_lines_instance = main_types.RenderedLines.init();
    defer rendered_lines_instance.deinit(test_allocator);

    // Start the server in a background thread
    server_thread = try std.Thread.spawn(.{}, runTestServer, .{ test_allocator, &rendered_lines_instance, null });
    std.time.sleep(std.time.ns_per_s / 2); // Give server ~0.5s to start

    // --- Test Case 1: Valid Line 1 ---
    var req1 = try makeRequest(test_allocator, .POST, "/lines?p0=-5,5,0&p1=5,5,0", null);
    defer req1.deinit();
    try req1.wait();
    try testing.expectEqual(@as(u16, 200), req1.response.status);
    var body1_buf: [1024]u8 = undefined;
    const body1_len = try req1.response.readAll(&body1_buf);
    const body1 = mem.trimRight(u8, body1_buf[0..body1_len], "\r\n ");
    std.debug.print("\nTest 1 Resp: {s}\n", .{body1});
    // Could parse JSON and check fields if needed

    // --- Test Case 2: Valid Line 2 ---
    var req2 = try makeRequest(test_allocator, .POST, "/lines?p0=0,0,0&p1=10,10,10", null);
    defer req2.deinit();
    try req2.wait();
    try testing.expectEqual(@as(u16, 200), req2.response.status);

    // --- Test Case 3: Valid Line 3 ---
    var req3 = try makeRequest(test_allocator, .POST, "/lines?p0=-5,-5,-5&p1=5,5,5", null);
    defer req3.deinit();
    try req3.wait();
    try testing.expectEqual(@as(u16, 200), req3.response.status);

    // Check line count (assuming ServerAppContext is accessible and updated)
    // This check is a bit racy if the server thread hasn't fully processed, but good for a basic check.
    // lines_mutex_for_test.lock();
    // try testing.expectEqual(@as(u64, 3), rendered_lines_instance.next_uid); // 3 lines added
    // lines_mutex_for_test.unlock();

    // --- Test Case 4: Missing p1 ---
    var req4 = try makeRequest(test_allocator, .POST, "/lines?p0=1,2,3", null);
    defer req4.deinit();
    try req4.wait();
    try testing.expectEqual(@as(u16, 400), req4.response.status);
    var body4_buf: [1024]u8 = undefined;
    const body4_len = try req4.response.readAll(&body4_buf);
    const body4 = mem.trimRight(u8, body4_buf[0..body4_len], "\r\n ");
    std.debug.print("\nTest 4 Resp: {s}\n", .{body4});
    try testing.expect(std.mem.contains(u8, body4, "Missing query parameter p1"));


    // --- Test Case 5: Malformed Coordinates (p1) ---
    var req5 = try makeRequest(test_allocator, .POST, "/lines?p0=1,2,3&p1=a,b,c", null);
    defer req5.deinit();
    try req5.wait();
    try testing.expectEqual(@as(u16, 400), req5.response.status);
    var body5_buf: [1024]u8 = undefined;
    const body5_len = try req5.response.readAll(&body5_buf);
    const body5 = mem.trimRight(u8, body5_buf[0..body5_len], "\r\n ");
    std.debug.print("\nTest 5 Resp: {s}\n", .{body5});
    try testing.expect(std.mem.contains(u8, body5, "Invalid format for p1"));


    // --- Test Case 6: Zero-Length Line ---
    var req6 = try makeRequest(test_allocator, .POST, "/lines?p0=1,2,3&p1=1,2,3", null);
    defer req6.deinit();
    try req6.wait();
    try testing.expectEqual(@as(u16, 400), req6.response.status);
    var body6_buf: [1024]u8 = undefined;
    const body6_len = try req6.response.readAll(&body6_buf);
    const body6 = mem.trimRight(u8, body6_buf[0..body6_len], "\r\n ");
    std.debug.print("\nTest 6 Resp: {s}\n", .{body6});
    try testing.expect(std.mem.contains(u8, body6, "Failed to create line")); // Or "ZeroLengthLine" in details

    // --- Test Case 7: Malformed Coordinates (p0) ---
    var req7 = try makeRequest(test_allocator, .POST, "/lines?p0=x,y,z&p1=1,2,3", null);
    defer req7.deinit();
    try req7.wait();
    try testing.expectEqual(@as(u16, 400), req7.response.status);
     var body7_buf: [1024]u8 = undefined;
    const body7_len = try req7.response.readAll(&body7_buf);
    const body7 = mem.trimRight(u8, body7_buf[0..body7_len], "\r\n ");
    std.debug.print("\nTest 7 Resp: {s}\n", .{body7});
    try testing.expect(std.mem.contains(u8, body7, "Invalid format for p0"));


    // Signal server to stop and join thread
    // This is conceptual: httpz doesn't have a simple "stop" that breaks listen() from another thread.
    // In a real app, you might close the listening socket or use a more advanced mechanism.
    // For this test, we'll just join. The server thread will exit when the test executable finishes.
    // A more robust test would involve a custom stop mechanism in httpz or the test server.
    // For now, we rely on the fact that the test process ending will clean up threads.
    // Or, if `HttpServer.startServer` could be made to periodically check `server_should_stop`.
    // server_should_stop.store(true, .Release);
    if (server_thread) |t| {
        // There's no clean way to interrupt httpz's listen() from another thread
        // without modifying httpz or using OS-specific signals (which is complex for a test).
        // For this test, we'll assume that when the test function ends, the process
        // will terminate, taking the server thread with it.
        // A real application would need a more graceful shutdown (e.g. Server.stop() called from a signal handler).
        // t.join(); // This would block indefinitely as listen() is blocking.
        std.debug.print("\nTest finished. Server thread will be terminated with process.\n", .{});
    }
}

// It's good practice to have a main_test.zig or similar that can run all tests.
// For now, this file can be run with `zig test src/HttpServer_test.zig`
// Ensure build.zig is configured to find `main.zig` and `VulkanRenderer.zig`
// when compiling this test. This might require adding this test file to an
// `addTest` step in `build.zig` and ensuring modules are correctly imported.
// For example, in build.zig:
// const server_tests = b.addTest(.{
//     .root_source_file = b.path("src/HttpServer_test.zig"),
//     .target = target,
//     .optimize = optimize,
// });
// server_tests.root_module.addImport("main", main_module); // if main.zig is a module
// server_tests.root_module.addImport("VulkanRenderer", vkr_module); // if VulkanRenderer.zig is a module
// server_tests.root_module.addImport("HttpServer", http_server_module); // etc.
// const run_server_tests = b.addRunArtifact(server_tests);
// test_step.dependOn(&run_server_tests.step);

// Minimal main for `zig run` if needed, though `zig test` is preferred.
pub fn main() !void {
    std.debug.print("This is a test file. Run with 'zig test src/HttpServer_test.zig'\n", .{});
}
