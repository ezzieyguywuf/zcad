const std = @import("std");
const builtin = @import("builtin");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const vk = @import("vulkan");

const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*;
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;

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

    // Wayland
    const wl_display = try wl.Display.connect(null);
    const wl_registry = try wl_display.getRegistry();

    var wl_context = WaylandContext{
        .height = 680,
        .width = 420,
    };
    wl_registry.setListener(*WaylandContext, globalRegistryListener, &wl_context);
    if (wl_display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

    const wl_compositor = wl_context.compositor orelse return error.NoWlCompositor;
    const wm_base = wl_context.wm_base orelse return error.NoXdgWmBase;
    const wl_surface = try wl_compositor.createSurface();
    defer wl_surface.destroy();
    wl_context.wl_surface = wl_surface;
    const xdg_surface: *xdg.Surface = try wm_base.getXdgSurface(wl_surface);
    defer xdg_surface.destroy();
    const xdg_toplevel = try xdg_surface.getToplevel();
    defer xdg_toplevel.destroy();

    xdg_surface.setListener(*WaylandContext, xdgSurfaceListener, &wl_context);
    xdg_toplevel.setListener(*WaylandContext, xdgTopLevelListener, &wl_context);

    wl_surface.commit();
    if (wl_display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

    const vk_ctx = try VulkanContext.init(allocator, wl_display, wl_surface);
    var extent = vk.Extent2D{
        .width = @intCast(wl_context.width),
        .height = @intCast(wl_context.height),
    };
    std.debug.print("Swapchain.init with Extent: {any}\n", .{extent});
    var swapchain = try Swapchain.init(&vk_ctx, allocator, extent);
    defer swapchain.deinit(allocator, &vk_ctx);

    const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    };
    const pipeline_layout = try vk_ctx.device.createPipelineLayout(&pipeline_layout_create_info, null);

    const render_pass = try createRenderPass(&vk_ctx.device, swapchain.surface_format.format);
    defer vk_ctx.device.destroyRenderPass(render_pass, null);

    const pipeline = try createPipeline(&vk_ctx.device, pipeline_layout, render_pass);
    defer vk_ctx.device.destroyPipeline(pipeline, null);

    var framebuffers = try createFramebuffers(allocator, &vk_ctx.device, &swapchain, render_pass);

    const command_pool_create_info = vk.CommandPoolCreateInfo{
        .queue_family_index = vk_ctx.graphics_queue_index,
    };
    const command_pool = try vk_ctx.device.createCommandPool(&command_pool_create_info, null);
    defer vk_ctx.device.destroyCommandPool(command_pool, null);

    const buffer_create_info = vk.BufferCreateInfo{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    };
    const buffer = try vk_ctx.device.createBuffer(&buffer_create_info, null);
    defer vk_ctx.device.destroyBuffer(buffer, null);

    const memory_requirements = vk_ctx.device.getBufferMemoryRequirements(buffer);
    // TODO bundle this whenever we fetch the physical device
    const physical_device_memory_properties = vk_ctx.instance.getPhysicalDeviceMemoryProperties(vk_ctx.physical_device);
    var memory_type_index: ?u32 = null;
    const memory_types = physical_device_memory_properties.memory_types;
    const n_memory_types = physical_device_memory_properties.memory_type_count;
    const memory_property_flags = vk.MemoryPropertyFlags{ .device_local_bit = true };
    for (memory_types[0..n_memory_types], 0..) |memory_type, i| {
        if (memory_requirements.memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and memory_type.property_flags.contains(memory_property_flags)) {
            memory_type_index = @truncate(i);
        }
    }
    if (memory_type_index == null) {
        return error.NoSuitableMemoryType;
    }
    const memory_allocate_info = vk.MemoryAllocateInfo{
        .allocation_size = memory_requirements.size,
        .memory_type_index = memory_type_index.?,
    };
    const memory = try vk_ctx.device.allocateMemory(&memory_allocate_info, null);
    defer vk_ctx.device.freeMemory(memory, null);
    try vk_ctx.device.bindBufferMemory(buffer, memory, 0);

    // Upload Vertices
    const staging_buffer_create_info = vk.BufferCreateInfo{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    };
    const staging_buffer = try vk_ctx.device.createBuffer(&staging_buffer_create_info, null);
    defer vk_ctx.device.destroyBuffer(staging_buffer, null);

    const staging_buffer_memory_requirements = vk_ctx.device.getBufferMemoryRequirements(staging_buffer);
    var staging_memory_type_index: ?u32 = null;
    const staging_memory_types = physical_device_memory_properties.memory_types;
    const n_staging_memory_types = physical_device_memory_properties.memory_type_count;
    const staging_memory_property_flags = vk.MemoryPropertyFlags{ .device_local_bit = true };
    for (staging_memory_types[0..n_staging_memory_types], 0..) |staging_memory_type, i| {
        if (staging_buffer_memory_requirements.memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and staging_memory_type.property_flags.contains(staging_memory_property_flags)) {
            staging_memory_type_index = @truncate(i);
        }
    }
    if (staging_memory_type_index == null) {
        return error.NoSuitableMemoryType;
    }
    const staging_memory_allocate_info = vk.MemoryAllocateInfo{
        .allocation_size = staging_buffer_memory_requirements.size,
        .memory_type_index = staging_memory_type_index.?,
    };
    const staging_memory = try vk_ctx.device.allocateMemory(&staging_memory_allocate_info, null);
    defer vk_ctx.device.freeMemory(staging_memory, null);
    try vk_ctx.device.bindBufferMemory(staging_buffer, staging_memory, 0);

    { // we want to unmap memory as soon as we're done with it, thus this
        // anonymous scope
        const data = try vk_ctx.device.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer vk_ctx.device.unmapMemory(staging_memory);

        const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));
        @memcpy(gpu_vertices, vertices[0..]);
    }

    // finish upload vertices

    // copy buffer
    var command_buffer_handle: vk.CommandBuffer = undefined;
    try vk_ctx.device.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer_handle));
    defer vk_ctx.device.freeCommandBuffers(command_pool, 1, @ptrCast(&command_buffer_handle));

    { // this command buffer must be cleaned up, we can't reuse it, thus
        // unnamed scope
        const command_buffer = VulkanContext.CommandBuffer.init(command_buffer_handle, vk_ctx.device.wrapper);

        try command_buffer.beginCommandBuffer(&.{
            .flags = .{ .one_time_submit_bit = true },
        });

        const region = vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = @sizeOf(@TypeOf(vertices)),
        };
        command_buffer.copyBuffer(staging_buffer, buffer, 1, @ptrCast(&region));

        try command_buffer.endCommandBuffer();

        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = (&command_buffer.handle)[0..1],
            .p_wait_dst_stage_mask = undefined,
        };
        try vk_ctx.device.queueSubmit(vk_ctx.graphics_queue, 1, @ptrCast(&submit_info), .null_handle);
        try vk_ctx.device.queueWaitIdle(vk_ctx.graphics_queue);
    }
    // end copy buffer

    std.debug.print("createCommandBuffers with Extent: {any}\n", .{extent});
    var command_buffers = try createCommandBuffers(&vk_ctx.device, command_pool, allocator, buffer, extent, render_pass, pipeline, framebuffers);
    defer {
        vk_ctx.device.freeCommandBuffers(command_pool, @truncate(command_buffers.len), command_buffers.ptr);
        allocator.free(command_buffers);
    }
    while (!wl_context.should_exit) {
        _ = wl_display.dispatchPending();
        if (wl_display.roundtrip() != .SUCCESS) return error.RoundTripFailed;
        if (wl_context.width == 0 or wl_context.height == 0) {
            // std.debug.print("Current dimensions: width -> {d}, height -> {d}\n", .{ wl_context.width, wl_context.height });
            // std.Thread.sleep(2000000);
            // smthn smthn poll events?
            // std.debug.print("Done with roundtrip\n", .{});
            continue;
        }
        if (wl_context.should_resize) {
            wl_context.ready_to_resize = false;
            wl_context.should_resize = false;

            wl_surface.commit();
        }

        const command_buffer = command_buffers[swapchain.current_image_index];

        const state = swapchain.present(&vk_ctx, command_buffer) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal or extent.width != @as(u32, @intCast(wl_context.width)) or extent.height != @as(u32, @intCast(wl_context.height))) {
            extent.width = @intCast(wl_context.width);
            extent.height = @intCast(wl_context.height);
            try vk_ctx.device.queueWaitIdle(vk_ctx.graphics_queue);
            try vk_ctx.device.queueWaitIdle(vk_ctx.presentation_queue);
            std.debug.print("Recreating swapchain\n", .{});
            try swapchain.recreate(allocator, &vk_ctx, extent); // catch |err| std.debug.print("Got an error, {any}\n", .{err});
            std.debug.print("got swapchain\n", .{});

            for (framebuffers) |fb| vk_ctx.device.destroyFramebuffer(fb, null);
            std.debug.print("destroyed framebuffers\n", .{});
            allocator.free(framebuffers);
            std.debug.print("deallocated framebuffers\n", .{});
            framebuffers = try createFramebuffers(allocator, &vk_ctx.device, &swapchain, render_pass);
            std.debug.print("recreated framebuffers\n", .{});
            vk_ctx.device.freeCommandBuffers(command_pool, @truncate(command_buffers.len), command_buffers.ptr);
            std.debug.print("freed command buffers\n", .{});
            allocator.free(command_buffers);

            command_buffers = try createCommandBuffers(&vk_ctx.device, command_pool, allocator, buffer, extent, render_pass, pipeline, framebuffers);
        }
    }

    try swapchain.waitForAllFences(&vk_ctx.device);
    try vk_ctx.device.deviceWaitIdle();
}

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_severity;
    _ = message_types;
    _ = p_callback_data;
    // std.debug.print("Severity: {any}, type {any}, message: {?s}, callback_data: {any}\n", .{
    //     message_severity,
    //     message_types,
    //     if (p_callback_data != null) p_callback_data.?.p_message else "no message",
    //     p_callback_data,
    // });
    return vk.FALSE;
}

fn createFramebuffers(allocator: std.mem.Allocator, device: *const VulkanContext.Device, swapchain: *const Swapchain, render_pass: vk.RenderPass) ![]vk.Framebuffer {
    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(framebuffers);

    var n_framebuffers: usize = 0;
    errdefer for (framebuffers[0..n_framebuffers]) |fb| device.destroyFramebuffer(fb, null);

    for (framebuffers) |*fb| {
        const framebuffer_create_info = vk.FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&swapchain.swap_images[n_framebuffers].view),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        };
        fb.* = try device.createFramebuffer(&framebuffer_create_info, null);
        n_framebuffers += 1;
    }

    return framebuffers;
}

const VulkanContext = struct {
    // vulkan
    const _apis: []const vk.ApiInfo = &.{
        vk.features.version_1_0,
        vk.features.version_1_1,
        vk.features.version_1_2,
        vk.features.version_1_3,
        vk.features.version_1_4,
        vk.extensions.khr_surface,
        vk.extensions.khr_swapchain,
        vk.extensions.khr_wayland_surface,
        vk.extensions.ext_debug_utils,
    };

    // These are types: they contain functions that e.g. require you to provide the
    // instance or device
    const BaseDispatch = vk.BaseWrapper(_apis);
    const InstanceDispatch = vk.InstanceWrapper(_apis);
    const DeviceDispatch = vk.DeviceWrapper(_apis);

    // These are also types: they hold the instance or device or w/e so you don't
    // have to pass those in.
    const Instance = vk.InstanceProxy(_apis);
    const Device = vk.DeviceProxy(_apis);
    const CommandBuffer = vk.CommandBufferProxy(_apis);

    instance: Instance,
    surface: vk.SurfaceKHR,
    physical_device: vk.PhysicalDevice,
    physical_device_properties: vk.PhysicalDeviceProperties,
    // physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,

    device: Device,
    graphics_queue_index: u32,
    presentation_queue_index: u32,
    graphics_queue: vk.Queue,
    presentation_queue: vk.Queue,

    pub fn init(allocator: std.mem.Allocator, wl_display: *wl.Display, wl_surface: *wl.Surface) !VulkanContext {
        // TODO: try (again) to see if we can do this without linking vulkan and
        // importing the c-thing, e.g. can we do this in pure zig.
        const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @extern(vk.PfnGetInstanceProcAddr, .{
            .name = "vkGetInstanceProcAddr",
            .library_name = "vulkan",
        });
        const base_dispatch = try BaseDispatch.load(get_instance_proc_addr);

        const application_info = vk.ApplicationInfo{
            .p_application_name = "zcad vulkan",
            .application_version = vk.makeApiVersion(0, 0, 0, 0),
            .engine_version = vk.makeApiVersion(0, 0, 0, 0),
            .api_version = vk.API_VERSION_1_4,
        };

        // TODO: add checks to ensure the requested extensions are supported, see
        // https://vulkan-tutorial.com/en/Drawing_a_triangle/Setup/Validation_layers
        const instance_extensions = if (builtin.mode == .Debug)
            [_][*:0]const u8{
                vk.extensions.khr_surface.name,
                vk.extensions.khr_wayland_surface.name,
                vk.extensions.ext_debug_utils.name,
            }
        else
            [_][*:0]const u8{
                vk.extensions.khr_surface.name,
                vk.extensions.khr_wayland_surface.name,
            };
        const enabled_layers = if (builtin.mode == .Debug)
            [1][*:0]const u8{
                "VK_LAYER_KHRONOS_validation",
            }
        else
            [0][*:0]const u8{};
        const create_instance_info = vk.InstanceCreateInfo{
            .p_application_info = &application_info,
            .enabled_extension_count = instance_extensions.len,
            .pp_enabled_extension_names = &instance_extensions,
            .enabled_layer_count = enabled_layers.len,
            .pp_enabled_layer_names = &enabled_layers,
        };
        const instance_handle = try base_dispatch.createInstance(&create_instance_info, null);
        const instance_dispatch = try allocator.create(InstanceDispatch);
        errdefer allocator.destroy(instance_dispatch);
        instance_dispatch.* = try InstanceDispatch.load(instance_handle, base_dispatch.dispatch.vkGetInstanceProcAddr);
        const instance = Instance.init(instance_handle, instance_dispatch);
        errdefer instance.destroyInstance(null);

        const debug_util_messenger_create_info = vk.DebugUtilsMessengerCreateInfoEXT{
            .message_severity = .{ .verbose_bit_ext = true, .warning_bit_ext = true, .error_bit_ext = true, .info_bit_ext = true },
            .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
            .pfn_user_callback = debugCallback,
            .p_user_data = null,
        };
        const debug_messenger = try instance.createDebugUtilsMessengerEXT(&debug_util_messenger_create_info, null);
        defer instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

        const create_wayland_surface_info = vk.WaylandSurfaceCreateInfoKHR{
            .display = @ptrCast(wl_display),
            .surface = @ptrCast(wl_surface),
        };
        const surface = try instance.createWaylandSurfaceKHR(&create_wayland_surface_info, null);
        errdefer instance.destroySurfaceKHR(surface, null);

        const required_device_extensions = [1][]const u8{
            vk.extensions.khr_swapchain.name,
        };
        const physical_devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
        defer allocator.free(physical_devices);
        var maybe_physical_device: ?vk.PhysicalDevice = null;
        var physical_device_properties: vk.PhysicalDeviceProperties = undefined;
        outer: for (physical_devices) |physical_device_candidate| {
            physical_device_properties = instance.getPhysicalDeviceProperties(physical_device_candidate);
            std.debug.print("Checking physical device {s}\n", .{physical_device_properties.device_name});
            const api_version = physical_device_properties.api_version;
            const major_version = vk.apiVersionMajor(api_version);
            const minor_version = vk.apiVersionMinor(api_version);
            if (vk.apiVersionMajor(api_version) < 1) {
                std.debug.print("  Major version {d} is too low, expected at least 1\n", .{major_version});
                continue;
            }
            if (vk.apiVersionMinor(api_version) < 4) {
                std.debug.print("  Minor version {d} is too low, expected at least 4\n", .{minor_version});
                continue;
            }
            // get the device extension properties
            const props = try instance.enumerateDeviceExtensionPropertiesAlloc(physical_device_candidate, null, allocator);
            defer allocator.free(props);
            for (required_device_extensions) |need| {
                var found = false;
                std.debug.print("Searching for extension {s}\n", .{need});
                for (props) |prop| {
                    // note: the extension_name is a 256-long array, so we need to
                    // take a slice for the comparison
                    if (std.mem.eql(u8, need, prop.extension_name[0..need.len])) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    continue :outer;
                }
            }
            std.debug.print("  MATCH on {s}\n", .{physical_device_properties.device_name});
            maybe_physical_device = physical_device_candidate;
            break;
        }
        if (maybe_physical_device == null) {
            std.debug.print("Checked {d} physical devices, found none with {d} required extensions and minimum API version\n", .{ physical_devices.len, required_device_extensions.len });
            return error.NoSuitablePhysicalDevice;
        }
        const physical_device = maybe_physical_device.?;

        const queue_family_properties = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, allocator);
        defer allocator.free(queue_family_properties);
        std.debug.print("Found {d} queue families\n", .{queue_family_properties.len});
        var graphics_queue_index: ?u32 = null;
        var presentation_queue_index: ?u32 = null;
        for (queue_family_properties, 0..) |queue_family_property, i| {
            std.debug.print("Checking queue family at index {d}\n", .{i});
            if (graphics_queue_index == null and queue_family_property.queue_flags.graphics_bit) {
                std.debug.print("Found graphics bit in index {d}\n", .{i});
                graphics_queue_index = @intCast(i);
            }

            if (presentation_queue_index == null and try instance.getPhysicalDeviceSurfaceSupportKHR(physical_device, @intCast(i), surface) == vk.TRUE) {
                std.debug.print("Found queue family with index {d} that supports presentation to our surface\n", .{i});
                presentation_queue_index = @intCast(i);
            }
            if (graphics_queue_index != null and presentation_queue_index != null) {
                break;
            }
        }

        if (graphics_queue_index == null) {
            std.debug.print("Unable to find queue that supports graphics\n", .{});
            return error.NoGraphicsQueue;
        }
        if (presentation_queue_index == null) {
            std.debug.print("Unable to find queue that supports presentation\n", .{});
            return error.NoPresentationQueue;
        }

        const priority = [_]f32{1};
        var queue_create_infos = std.ArrayListUnmanaged(vk.DeviceQueueCreateInfo){};
        try queue_create_infos.append(allocator, vk.DeviceQueueCreateInfo{
            .queue_family_index = graphics_queue_index.?,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        });
        if (graphics_queue_index.? != presentation_queue_index.?) {
            try queue_create_infos.append(allocator, vk.DeviceQueueCreateInfo{
                .queue_family_index = presentation_queue_index.?,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            });
        }
        defer queue_create_infos.deinit(allocator);

        const device_create_info = vk.DeviceCreateInfo{
            .queue_create_info_count = @intCast(queue_create_infos.items.len),
            .p_queue_create_infos = queue_create_infos.items.ptr,
            .enabled_extension_count = required_device_extensions.len,
            .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        };
        const device_handle = try instance.createDevice(physical_device, &device_create_info, null);
        const device_dispatch = try allocator.create(DeviceDispatch);
        errdefer allocator.destroy(device_dispatch);
        device_dispatch.* = try DeviceDispatch.load(device_handle, instance.wrapper.dispatch.vkGetDeviceProcAddr);
        const device = Device.init(device_handle, device_dispatch);
        errdefer device.destroyDevice(null);

        const graphics_queue = device.getDeviceQueue(graphics_queue_index.?, 0);
        const presentation_queue = device.getDeviceQueue(presentation_queue_index.?, 0);
        return VulkanContext{
            .instance = instance,
            .surface = surface,
            .physical_device = physical_device,
            .physical_device_properties = physical_device_properties,
            .device = device,
            .graphics_queue_index = graphics_queue_index.?,
            .presentation_queue_index = presentation_queue_index.?,
            .graphics_queue = graphics_queue,
            .presentation_queue = presentation_queue,
        };
    }

    pub fn deinit(self: VulkanContext, allocator: std.mem.Allocator) void {
        self.device.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyInstance(null);

        // Don't forget to free the tables to prevent a memory leak.
        allocator.destroy(self.device.wrapper);
        allocator.destroy(self.instance.wrapper);
    }
};

const Swapchain = struct {
    pub const PresentState = enum {
        optimal,
        suboptimal,
    };

    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    handle: vk.SwapchainKHR,

    swap_images: []SwapImage,
    current_image_index: u32,
    next_image_acquired: vk.Semaphore,

    pub fn init(vk_ctx: *const VulkanContext, allocator: std.mem.Allocator, extent: vk.Extent2D) !Swapchain {
        return try initRecycle(vk_ctx, allocator, extent, .null_handle);
    }

    pub fn initRecycle(vk_ctx: *const VulkanContext, allocator: std.mem.Allocator, desired_extent: vk.Extent2D, old_handle: vk.SwapchainKHR) !Swapchain {
        const capabilities = try vk_ctx.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(vk_ctx.physical_device, vk_ctx.surface);
        var extent = capabilities.current_extent;
        std.debug.print("Current extent: {any}\n", .{extent});
        if (extent.height == 0xFFFF_FFFF or extent.width == 0xFFFF_FFFF) {
            const min_image_extent = capabilities.min_image_extent;
            const max_image_extent = capabilities.max_image_extent;
            extent.width = std.math.clamp(desired_extent.width, min_image_extent.width, max_image_extent.width);
            extent.height = std.math.clamp(desired_extent.height, min_image_extent.height, max_image_extent.height);
        }
        if (extent.width == 0 or extent.height == 0) {
            return error.InvalidSurfaceDimensions;
        }
        std.debug.print("Final extent: {any}\n", .{extent});

        const surface_formats = try vk_ctx.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(vk_ctx.physical_device, vk_ctx.surface, allocator);
        defer allocator.free(surface_formats);
        std.debug.print("got surface formats\n", .{});
        if (surface_formats.len == 0) {
            return error.NoSurfaceFormats;
        }
        var surface_format = surface_formats[0];
        for (surface_formats) |surface_format_candidate| {
            if (surface_format_candidate.format == vk.Format.b8g8r8_srgb and surface_format_candidate.color_space == vk.ColorSpaceKHR.srgb_nonlinear_khr) {
                surface_format = surface_format_candidate;
            }
        }

        const present_modes = try vk_ctx.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(vk_ctx.physical_device, vk_ctx.surface, allocator);
        defer allocator.free(present_modes);
        std.debug.print("got present modes\n", .{});
        if (present_modes.len == 0) {
            return error.NoPresentModes;
        }
        var present_mode = vk.PresentModeKHR.fifo_khr;
        for (present_modes) |present_mode_candidate| {
            if (present_mode_candidate == vk.PresentModeKHR.mailbox_khr) {
                present_mode = vk.PresentModeKHR.mailbox_khr;
                break;
            }
        }

        var image_count = capabilities.min_image_count + 1;
        if (capabilities.max_image_count > 0 and image_count > capabilities.max_image_count) {
            image_count = capabilities.max_image_count;
        }
        const queue_family_indices = [_]u32{ vk_ctx.graphics_queue_index, vk_ctx.presentation_queue_index };

        const swapchain_create_info = vk.SwapchainCreateInfoKHR{
            .surface = vk_ctx.surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
            .image_sharing_mode = if (vk_ctx.graphics_queue_index != vk_ctx.presentation_queue_index) vk.SharingMode.concurrent else vk.SharingMode.exclusive,
            .queue_family_index_count = queue_family_indices.len,
            .p_queue_family_indices = &queue_family_indices,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_handle,
        };

        std.debug.print("creating swapchain\n", .{});
        const swapchain = try vk_ctx.device.createSwapchainKHR(&swapchain_create_info, null);
        errdefer vk_ctx.device.destroySwapchainKHR(swapchain, null);

        if (old_handle != .null_handle) {
            // Apparently, the old swapchain handle still needs to be destroyed after recreating.
            std.debug.print("destroying old handle\n", .{});
            vk_ctx.device.destroySwapchainKHR(old_handle, null);
        }

        const images = try vk_ctx.device.getSwapchainImagesAllocKHR(swapchain, allocator);
        defer allocator.free(images);
        std.debug.print("got images\n", .{});
        const swap_images = try allocator.alloc(SwapImage, images.len);
        errdefer allocator.free(swap_images);
        var n_swap_images: usize = 0;
        for (images) |image| {
            swap_images[n_swap_images] = try SwapImage.init(vk_ctx.device, image, surface_format.format);
            n_swap_images += 1;
        }
        errdefer {
            for (swap_images) |si| si.deinit(&vk_ctx.device);
        }

        var next_image_acquired = try vk_ctx.device.createSemaphore(&.{}, null);
        errdefer vk_ctx.device.destroySemaphore(next_image_acquired, null);

        std.debug.print("acquiring next image\n", .{});
        std.debug.print("acquireNextImage initRecycle handle: {any}, next_image_acquired: {any}\n", .{ swapchain, next_image_acquired });
        const result = try vk_ctx.device.acquireNextImageKHR(swapchain, std.math.maxInt(u64), next_image_acquired, .null_handle);
        std.debug.print("result {any}\n", .{result});
        if (result.result != .success and result.result != .suboptimal_khr) {
            std.debug.print("ImageAcquireFailed\n", .{});
            return error.ImageAcquireFailed;
        }
        std.debug.print("got it\n", .{});

        std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);
        return Swapchain{
            .surface_format = surface_format,
            .present_mode = present_mode,
            .extent = extent,
            .handle = swapchain,
            .swap_images = swap_images,
            .current_image_index = result.image_index,
            .next_image_acquired = next_image_acquired,
        };
    }

    pub fn deinit(self: Swapchain, allocator: std.mem.Allocator, vk_ctx: *const VulkanContext) void {
        self.deinitExceptSwapchain(allocator, vk_ctx);
        vk_ctx.device.destroySwapchainKHR(self.handle, null);
    }

    fn deinitExceptSwapchain(self: Swapchain, allocator: std.mem.Allocator, vk_ctx: *const VulkanContext) void {
        std.debug.print("destroying swap images\n", .{});
        for (self.swap_images, 0..) |si, i| {
            std.debug.print("destroying swap_image {d}, {any}\n", .{ i, si });
            si.deinit(&vk_ctx.device);
        }
        allocator.free(self.swap_images);
        std.debug.print("destroying semaphore\n", .{});
        vk_ctx.device.destroySemaphore(self.next_image_acquired, null);
        std.debug.print("done destroying semaphore\n", .{});
    }

    pub fn recreate(self: *Swapchain, allocator: std.mem.Allocator, vk_ctx: *const VulkanContext, new_extent: vk.Extent2D) !void {
        const old_handle = self.handle;
        self.deinitExceptSwapchain(allocator, vk_ctx);
        self.* = try initRecycle(vk_ctx, allocator, new_extent, old_handle);
    }

    pub fn waitForAllFences(self: Swapchain, device: *const VulkanContext.Device) !void {
        for (self.swap_images) |si| si.waitForFence(device) catch {};
    }

    pub fn present(self: *Swapchain, vk_ctx: *const VulkanContext, command_buffer: vk.CommandBuffer) !PresentState {
        // Simple method:
        // 1) Acquire next image
        // 2) Wait for and reset fence of the acquired image
        // 3) Submit command buffer with fence of acquired image,
        //    dependendent on the semaphore signalled by the first step.
        // 4) Present current frame, dependent on semaphore signalled by previous step
        // Problem: This way we can't reference the current image while rendering.
        // Better method: Shuffle the steps around such that acquire next image is the last step,
        // leaving the swapchain in a state with the current image.
        // 1) Wait for and reset fence of current image
        // 2) Submit command buffer, signalling fence of current image and dependent on
        //    the semaphore signalled by step 4.
        // 3) Present current frame, dependent on semaphore signalled by the submit
        // 4) Acquire next image, signalling its semaphore
        // One problem that arises is that we can't know beforehand which semaphore to signal,
        // so we keep an extra auxilery semaphore that is swapped around

        // Step 1: Make sure the current frame has finished rendering
        const current_swap_image = self.swap_images[self.current_image_index];
        try current_swap_image.waitForFence(&vk_ctx.device);
        try vk_ctx.device.resetFences(1, @ptrCast(&current_swap_image.frame_fence));

        // Step 2: Submit the command buffer
        const wait_stage = [_]vk.PipelineStageFlags{.{ .top_of_pipe_bit = true }};
        const frame_submit_info = [_]vk.SubmitInfo{
            .{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast(&current_swap_image.image_acquired),
                .p_wait_dst_stage_mask = &wait_stage,
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&command_buffer),
                .signal_semaphore_count = 1,
                .p_signal_semaphores = @ptrCast(&current_swap_image.render_finished),
            },
        };
        try vk_ctx.device.queueSubmit(vk_ctx.graphics_queue, 1, &frame_submit_info, current_swap_image.frame_fence);

        // Step 3: Present the current frame
        const present_info = vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current_swap_image.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.handle),
            .p_image_indices = @ptrCast(&self.current_image_index),
        };
        _ = try vk_ctx.device.queuePresentKHR(vk_ctx.presentation_queue, &present_info);

        // Step 4: Acquire next frame
        const result = try vk_ctx.device.acquireNextImageKHR(
            self.handle,
            std.math.maxInt(u64),
            self.next_image_acquired,
            .null_handle,
        );

        std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
        self.current_image_index = result.image_index;

        return switch (result.result) {
            .success => .optimal,
            .suboptimal_khr => .suboptimal,
            else => unreachable,
        };
    }
};

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(device: VulkanContext.Device, image: vk.Image, format: vk.Format) !SwapImage {
        const image_view_create_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = vk.ImageViewType.@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const image_view = try device.createImageView(&image_view_create_info, null);
        errdefer device.destroyImageView(image_view, null);

        const image_acquired = try device.createSemaphore(&.{}, null);
        errdefer device.destroySemaphore(image_acquired, null);

        const render_finished = try device.createSemaphore(&.{}, null);
        errdefer device.destroySemaphore(render_finished, null);

        const frame_fence = try device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer device.destroyFence(frame_fence, null);

        return SwapImage{
            .image = image,
            .view = image_view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, device: *const VulkanContext.Device) void {
        self.waitForFence(device) catch return;
        device.destroyImageView(self.view, null);
        device.destroySemaphore(self.image_acquired, null);
        device.destroySemaphore(self.render_finished, null);
        device.destroyFence(self.frame_fence, null);
    }

    fn waitForFence(self: SwapImage, device: *const VulkanContext.Device) !void {
        _ = try device.waitForFences(1, @ptrCast(&self.frame_fence), vk.TRUE, std.math.maxInt(u64));
    }
};

fn createPipeline(dev: *const VulkanContext.Device, layout: vk.PipelineLayout, render_pass: vk.RenderPass) !vk.Pipeline {
    const vert = try dev.createShaderModule(&.{
        .code_size = vert_spv.len,
        .p_code = @ptrCast(&vert_spv),
    }, null);
    defer dev.destroyShaderModule(vert, null);

    const frag = try dev.createShaderModule(&.{
        .code_size = frag_spv.len,
        .p_code = @ptrCast(&frag_spv),
    }, null);
    defer dev.destroyShaderModule(frag, null);

    const pipeline_shader_stage_create_info = [_]vk.PipelineShaderStageCreateInfo{ .{
        .stage = .{ .vertex_bit = true },
        .module = vert,
        .p_name = "main",
    }, .{
        .stage = .{ .fragment_bit = true },
        .module = frag,
        .p_name = "main",
    } };

    const pipeline_vertex_input_state_create_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&Vertex.binding_description),
        .vertex_attribute_description_count = Vertex.attribute_description.len,
        .p_vertex_attribute_descriptions = &Vertex.attribute_description,
    };

    const pipeline_input_assembly_state_create_info = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const pipeline_viewport_state_create_info = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = undefined, // set in createCommandBuffers with cmdSetViewport
        .scissor_count = 1,
        .p_scissors = undefined, // set in createCommandBuffers with cmdSetScissor
    };

    const pipeline_rasterization_state_create_info = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pipeline_multisample_state_create_info = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const pipeline_color_blend_attachment_state = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const pipeline_color_blend_state_create_info = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pipeline_color_blend_attachment_state),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const pipeline_dynamic_state_create_info = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    const graphics_pipeline_create_info = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &pipeline_shader_stage_create_info,
        .p_vertex_input_state = &pipeline_vertex_input_state_create_info,
        .p_input_assembly_state = &pipeline_input_assembly_state_create_info,
        .p_tessellation_state = null,
        .p_viewport_state = &pipeline_viewport_state_create_info,
        .p_rasterization_state = &pipeline_rasterization_state_create_info,
        .p_multisample_state = &pipeline_multisample_state_create_info,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &pipeline_color_blend_state_create_info,
        .p_dynamic_state = &pipeline_dynamic_state_create_info,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try dev.createGraphicsPipelines(
        .null_handle,
        1,
        @ptrCast(&graphics_pipeline_create_info),
        null,
        @ptrCast(&pipeline),
    );

    return pipeline;
}

pub fn createRenderPass(dev: *const VulkanContext.Device, format: vk.Format) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .format = format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
    };

    return try dev.createRenderPass(&.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    }, null);
}

fn createCommandBuffers(
    device: *const VulkanContext.Device,
    pool: vk.CommandPool,
    allocator: std.mem.Allocator,
    buffer: vk.Buffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    framebuffers: []vk.Framebuffer,
) ![]vk.CommandBuffer {
    const command_buffers = try allocator.alloc(vk.CommandBuffer, framebuffers.len);
    errdefer allocator.free(command_buffers);

    const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @intCast(command_buffers.len),
    };
    try device.allocateCommandBuffers(&command_buffer_allocate_info, command_buffers.ptr);
    errdefer device.freeCommandBuffers(pool, @intCast(command_buffers.len), command_buffers.ptr);

    const clear = vk.ClearValue{
        .color = .{ .float_32 = .{ 0.2, 0.3, 0.3, 1 } },
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    for (command_buffers, framebuffers) |cmdbuf, framebuffer| {
        try device.beginCommandBuffer(cmdbuf, &.{});

        device.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
        device.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&scissor));

        // This needs to be a separate definition - see https://github.com/ziglang/zig/issues/7627.
        const render_area = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };

        device.cmdBeginRenderPass(cmdbuf, &.{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .render_area = render_area,
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear),
        }, .@"inline");

        device.cmdBindPipeline(cmdbuf, .graphics, pipeline);
        const offset = [_]vk.DeviceSize{0};
        device.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&buffer), &offset);
        device.cmdDraw(cmdbuf, vertices.len, 1, 0, 0);

        device.cmdEndRenderPass(cmdbuf);
        try device.endCommandBuffer(cmdbuf);
    }

    return command_buffers;
}

const vertices = [_]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

const Vertex = struct {
    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    pos: [2]f32,
    color: [3]f32,
};

const WaylandContext = struct {
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    wl_surface: ?*wl.Surface = null,
    should_exit: bool = false,
    should_resize: bool = false,
    ready_to_resize: bool = false,
    width: i32 = 0,
    height: i32 = 0,
};

fn globalRegistryListener(wl_registry: *wl.Registry, event: wl.Registry.Event, context: *WaylandContext) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = wl_registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = wl_registry.bind(global.name, xdg.WmBase, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, ctx: *WaylandContext) void {
    switch (event) {
        .configure => |configure| {
            std.debug.print("Got CONFIGURE for xdg_surface, {any}\n", .{configure});
            if (ctx.wl_surface) |surface| {
                surface.commit();
            } else {
                std.debug.print("Cannot commit in xdgSurfaceListener without a wl_surface\n", .{});
                return;
            }
            if (ctx.should_resize) {
                ctx.ready_to_resize = true;
            }
            xdg_surface.ackConfigure(configure.serial);
        },
    }
}

fn xdgTopLevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, ctx: *WaylandContext) void {
    switch (event) {
        .configure => |conf| {
            std.debug.print("Got CONFIGURE for xdg_toplevel, {any}\n", .{conf});
            if (conf.width > 0 and conf.height > 0) {
                ctx.width = conf.width;
                ctx.height = conf.height;
                ctx.should_resize = true;
            }
        },
        .close => ctx.should_exit = true,
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
