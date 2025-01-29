const std = @import("std");
const glfw = @cImport({
    @cDefine("GLFW_INCLUDE_VULKAN", "1");
    @cInclude("GLFW/glfw3.h");
});
const wl = @cImport({
    @cInclude("wayland-client.h");
});

pub fn main() !void {
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

    // returns NULL or the previous callback, neither of which we're interested
    // in.
    _ = glfw.glfwSetErrorCallback(glfwErrorCallback);
    if (glfw.glfwInit() == 0) {
        std.process.exit(1);
    }
    defer glfw.glfwTerminate();

    // per https://www.glfw.org/docs/3.3/vulkan_guide.html#vulkan_window
    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
    // I think orelse return is ok because we have the error callback
    const glfw_window = glfw.glfwCreateWindow(640, 480, "zcad", null, null) orelse return;
    defer glfw.glfwDestroyWindow(glfw_window);

    // https://www.glfw.org/docs/3.3/vulkan_guide.html#vulkan_ext
    var extension_count: u32 = 0;
    const extension_names = glfw.glfwGetRequiredInstanceExtensions(&extension_count);
    if (extension_names == null) {
        std.debug.print("Could not get required instance extensions.\n", .{});
        std.debug.print("Vulkan can still be used for off-screen rendering, but I don't know how to do that\n", .{});
        return;
    }

    const app_info = glfw.VkApplicationInfo{
        .sType = glfw.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "zcad",
        .applicationVersion = glfw.VK_MAKE_VERSION(0, 0, 0),
        .apiVersion = glfw.VK_API_VERSION_1_4,
    };
    const create_info = glfw.VkInstanceCreateInfo{
        .sType = glfw.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = extension_count,
        .ppEnabledExtensionNames = extension_names,
    };
    var instance: glfw.VkInstance = undefined;
    if (glfw.vkCreateInstance(&create_info, null, &instance) != glfw.VK_SUCCESS) {
        std.debug.print("Could not create vulkan instance\n", .{});
        return;
    }

    var device_count: u32 = 0;
    if (glfw.vkEnumeratePhysicalDevices(instance, &device_count, null) != glfw.VK_SUCCESS) {
        std.debug.print("Unable to enumerate physical devices\n", .{});
        return;
    }
    std.debug.print("Found {d} physical devices\n", .{device_count});

    const c_alloc = std.heap.c_allocator;
    // defer c_alloc.deinit();
    var devices = try std.ArrayListUnmanaged(*glfw.VkPhysicalDevice).initCapacity(c_alloc, device_count);
    defer devices.deinit(c_alloc);

    // maybe try using wayland directly and get rid of glfw
    const wl_display = wl.wl_display_connect(null) orelse {
        std.debug.print("Unable to connect to wayland display\n", .{});
        return;
    };
    const wl_registry = wl.wl_display_get_registry(wl_display) orelse {
        std.debug.print("Unable to get global registry\n", .{});
        return;
    };

    const registry_listener = wl.wl_registry_listener{
        .global = globalRegistryListener,
    };
    if (wl.wl_registry_add_listener(wl_registry, &registry_listener, null) != 0) {
        std.debug.print("Error attaching listener to registry\n", .{});
    }
    wl.wl_display_disconnect(wl_display);

    while (glfw.glfwWindowShouldClose(glfw_window) == 0) {
        glfw.glfwPollEvents();
    }
}

var compositor: *wl.wl_compositor = undefined;
fn globalRegistryListener(_: ?*anyopaque, wl_registry: ?*wl.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    if (std.mem.orderZ(u8, interface, wl.wl_compositor_interface.name) == .eq) {
        if (wl.wl_registry_bind(wl_registry, name, &wl.wl_compositor_interface, version)) |success| {
            compositor = @ptrCast(success);
        }
    }
}

fn glfwErrorCallback(err: c_int, description: [*c]const u8) callconv(.c) void {
    std.debug.print("GLFW Error {d}: {s}\n", .{ err, description });
    if (err == 0x1000E) {
        std.debug.print("Do you have a windowing system running? (X or wayland on linux)\n", .{});
        std.debug.print("If yes, does your terminal have the correct environment variables set? (DISPLAY or WAYLAND_DISPLAY respectively)\n", .{});
    }
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
