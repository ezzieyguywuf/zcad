const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const wl = @import("WaylandClient.zig");
const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*;
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;

pub const Renderer = struct {
    swapchain: Swapchain,
    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,
    pipeline: vk.Pipeline,
    command_pool: vk.CommandPool,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    command_buffers: []vk.CommandBuffer,
    width: u32,
    height: u32,
    n_vertices: u32,

    pub fn init(allocator: std.mem.Allocator, vk_ctx: *const VulkanContext, width: u32, height: u32, vertices: []const Vertex) !Renderer {
        const extent = vk.Extent2D{ .width = width, .height = height };
        var swapchain = try Swapchain.init(vk_ctx, allocator, extent);
        const render_pass = try vk_ctx.createRenderPass(swapchain.surface_format.format);
        const framebuffers = try vk_ctx.createFramebuffers(allocator, &swapchain, render_pass);

        const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 0,
            .p_set_layouts = undefined,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        };
        const pipeline_layout = try vk_ctx.device.createPipelineLayout(&pipeline_layout_create_info, null);
        const pipeline = try vk_ctx.createPipeline(pipeline_layout, render_pass);

        const command_pool_create_info = vk.CommandPoolCreateInfo{
            .queue_family_index = vk_ctx.graphics_queue_index,
        };
        const command_pool = try vk_ctx.device.createCommandPool(&command_pool_create_info, null);

        const buffer, const memory = try createBuffer(
            vk_ctx,
            Vertex,
            vertices.len,
            .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        );
        const command_buffers = try allocator.alloc(vk.CommandBuffer, framebuffers.len);

        var renderer = Renderer{
            .swapchain = swapchain,
            .render_pass = render_pass,
            .framebuffers = framebuffers,
            .pipeline = pipeline,
            .command_pool = command_pool,
            .buffer = buffer,
            .memory = memory,
            .command_buffers = command_buffers,
            .width = width,
            .height = height,
            .n_vertices = @intCast(vertices.len),
        };

        try renderer.uploadVertices(vk_ctx, vertices);
        try renderer.createCommandBuffers(
            allocator,
            &vk_ctx.device,
            .{ .width = @intCast(width), .height = @intCast(height) },
        );

        return renderer;
    }

    pub fn deinit(self: *const Renderer, allocator: std.mem.Allocator, vk_ctx: *const VulkanContext) void {
        self.swapchain.deinit(allocator, vk_ctx);
        vk_ctx.device.destroyRenderPass(self.render_pass, null);
        vk_ctx.device.destroyPipeline(self.pipeline, null);
        vk_ctx.device.destroyCommandPool(self.command_pool, null);
        vk_ctx.device.destroyBuffer(self.buffer, null);
        vk_ctx.device.freeMemory(self.memory, null);
        vk_ctx.device.freeCommandBuffers(self.command_pool, @truncate(self.command_buffers.len), self.command_buffers.ptr);
        allocator.free(self.command_buffers);
    }

    pub fn createCommandBuffers(
        self: *Renderer,
        allocator: std.mem.Allocator,
        device: *const VulkanContext.Device,
        extent: vk.Extent2D,
    ) !void {
        self.command_buffers = try allocator.alloc(vk.CommandBuffer, self.framebuffers.len);
        errdefer allocator.free(self.command_buffers);

        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(self.command_buffers.len),
        };
        try device.allocateCommandBuffers(&command_buffer_allocate_info, self.command_buffers.ptr);
        errdefer device.freeCommandBuffers(self.command_pool, @intCast(self.command_buffers.len), self.command_buffers.ptr);

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

        for (self.command_buffers, self.framebuffers) |cmdbuf, framebuffer| {
            try device.beginCommandBuffer(cmdbuf, &.{});

            device.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
            device.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&scissor));

            // This needs to be a separate definition - see https://github.com/ziglang/zig/issues/7627.
            const render_area = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent,
            };

            device.cmdBeginRenderPass(cmdbuf, &.{
                .render_pass = self.render_pass,
                .framebuffer = framebuffer,
                .render_area = render_area,
                .clear_value_count = 1,
                .p_clear_values = @ptrCast(&clear),
            }, .@"inline");

            device.cmdBindPipeline(cmdbuf, .graphics, self.pipeline);
            const offset = [_]vk.DeviceSize{0};
            device.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&self.buffer), &offset);
            device.cmdDraw(cmdbuf, self.n_vertices, 1, 0, 0);

            device.cmdEndRenderPass(cmdbuf);
            try device.endCommandBuffer(cmdbuf);
        }
    }

    pub fn createMemory(vk_ctx: *const VulkanContext, buffer: vk.Buffer) !vk.DeviceMemory {
        const memory_requirements = vk_ctx.device.getBufferMemoryRequirements(buffer);
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
        return try vk_ctx.device.allocateMemory(&memory_allocate_info, null);
    }

    fn createBuffer(
        vk_ctx: *const VulkanContext,
        item_type: type,
        n_items: usize,
        usage: vk.BufferUsageFlags,
    ) !struct { vk.Buffer, vk.DeviceMemory } {
        const size = n_items * @sizeOf(item_type);
        const buffer_create_info = vk.BufferCreateInfo{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        };
        const buffer = try vk_ctx.device.createBuffer(&buffer_create_info, null);
        const memory = try createMemory(vk_ctx, buffer);

        return .{ buffer, memory };
    }

    pub fn uploadVertices(self: *Renderer, vk_ctx: *const VulkanContext, vertices: []const Vertex) !void {
        try vk_ctx.device.bindBufferMemory(self.buffer, self.memory, 0);

        // Upload to staging buffer
        const size = vertices.len * @sizeOf(Vertex);

        const staging_buffer, const staging_memory = try createBuffer(vk_ctx, Vertex, vertices.len, .{ .transfer_src_bit = true });
        defer vk_ctx.device.destroyBuffer(staging_buffer, null);
        defer vk_ctx.device.freeMemory(staging_memory, null);
        try vk_ctx.device.bindBufferMemory(staging_buffer, staging_memory, 0);

        { // we want to unmap memory as soon as we're done with it, thus this
            // anonymous scope
            const data = try vk_ctx.device.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{});
            defer vk_ctx.device.unmapMemory(staging_memory);

            const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));
            @memcpy(gpu_vertices, vertices[0..]);
        }

        // finish upload to staging buffer

        // copy to final buffer
        var command_buffer_handle: vk.CommandBuffer = undefined;
        try vk_ctx.device.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer_handle));
        defer vk_ctx.device.freeCommandBuffers(self.command_pool, 1, @ptrCast(&command_buffer_handle));

        { // this command buffer must be cleaned up, we can't reuse it, thus
            // unnamed scope
            const command_buffer = VulkanContext.CommandBuffer.init(command_buffer_handle, vk_ctx.device.wrapper);

            try command_buffer.beginCommandBuffer(&.{
                .flags = .{ .one_time_submit_bit = true },
            });

            const region = vk.BufferCopy{
                .src_offset = 0,
                .dst_offset = 0,
                .size = size,
            };
            command_buffer.copyBuffer(staging_buffer, self.buffer, 1, @ptrCast(&region));

            try command_buffer.endCommandBuffer();

            const submit_info = vk.SubmitInfo{
                .command_buffer_count = 1,
                .p_command_buffers = (&command_buffer.handle)[0..1],
                .p_wait_dst_stage_mask = undefined,
            };
            try vk_ctx.device.queueSubmit(vk_ctx.graphics_queue, 1, @ptrCast(&submit_info), .null_handle);
            try vk_ctx.device.queueWaitIdle(vk_ctx.graphics_queue);
        }
        // end copy to final buffer
    }

    pub fn render(self: *Renderer, allocator: std.mem.Allocator, vk_ctx: *const VulkanContext, wl_ctx: *const wl.WaylandContext) !void {
        const command_buffer = self.command_buffers[self.swapchain.current_image_index];

        const state = self.swapchain.present(vk_ctx, command_buffer) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal or self.width != @as(u32, @intCast(wl_ctx.width)) or self.height != @as(u32, @intCast(wl_ctx.height))) {
            self.width = @intCast(wl_ctx.width);
            self.height = @intCast(wl_ctx.height);
            const extent = vk.Extent2D{ .width = self.width, .height = self.height };
            try vk_ctx.device.queueWaitIdle(vk_ctx.graphics_queue);
            try vk_ctx.device.queueWaitIdle(vk_ctx.presentation_queue);
            try self.swapchain.recreate(allocator, vk_ctx, extent);

            for (self.framebuffers) |fb| vk_ctx.device.destroyFramebuffer(fb, null);
            allocator.free(self.framebuffers);
            self.framebuffers = try vk_ctx.createFramebuffers(allocator, &self.swapchain, self.render_pass);
            vk_ctx.device.freeCommandBuffers(self.command_pool, @truncate(self.command_buffers.len), self.command_buffers.ptr);
            allocator.free(self.command_buffers);

            // const buffer_create_info = vk.BufferCreateInfo{
            //     .size = self.n_vertices * @sizeOf(Vertex),
            //     .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
            //     .sharing_mode = .exclusive,
            // };
            // self.buffer = try vk_ctx.device.createBuffer(&buffer_create_info, null);
            try self.createCommandBuffers(allocator, &vk_ctx.device, extent);
        }
    }
};

pub const VulkanContext = struct {
    // vulkan
    const _apis: []const vk.ApiInfo = &.{
        vk.features.version_1_0,
        vk.features.version_1_1,
        vk.features.version_1_2,
        vk.features.version_1_3,
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

    pub fn init(allocator: std.mem.Allocator, wl_ctx: *const wl.WaylandContext) !VulkanContext {
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
            .api_version = vk.API_VERSION_1_3,
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
            .display = @ptrCast(wl_ctx.display),
            .surface = @ptrCast(wl_ctx.surface),
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
            if (vk.apiVersionMinor(api_version) < 3) {
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

    pub fn createRenderPass(self: *const VulkanContext, format: vk.Format) !vk.RenderPass {
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

        return try self.device.createRenderPass(&.{
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
        }, null);
    }

    fn createPipeline(self: *const VulkanContext, layout: vk.PipelineLayout, render_pass: vk.RenderPass) !vk.Pipeline {
        const vert = try self.device.createShaderModule(&.{
            .code_size = vert_spv.len,
            .p_code = @ptrCast(&vert_spv),
        }, null);
        defer self.device.destroyShaderModule(vert, null);

        const frag = try self.device.createShaderModule(&.{
            .code_size = frag_spv.len,
            .p_code = @ptrCast(&frag_spv),
        }, null);
        defer self.device.destroyShaderModule(frag, null);

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
            .p_viewports = undefined,
            .scissor_count = 1,
            .p_scissors = undefined,
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
        _ = try self.device.createGraphicsPipelines(
            .null_handle,
            1,
            @ptrCast(&graphics_pipeline_create_info),
            null,
            @ptrCast(&pipeline),
        );

        return pipeline;
    }

    fn createFramebuffers(self: *const VulkanContext, allocator: std.mem.Allocator, swapchain: *const Swapchain, render_pass: vk.RenderPass) ![]vk.Framebuffer {
        const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
        errdefer allocator.free(framebuffers);

        var n_framebuffers: usize = 0;
        errdefer for (framebuffers[0..n_framebuffers]) |fb| self.device.destroyFramebuffer(fb, null);

        for (framebuffers) |*fb| {
            const framebuffer_create_info = vk.FramebufferCreateInfo{
                .render_pass = render_pass,
                .attachment_count = 1,
                .p_attachments = @ptrCast(&swapchain.swap_images[n_framebuffers].view),
                .width = swapchain.extent.width,
                .height = swapchain.extent.height,
                .layers = 1,
            };
            fb.* = try self.device.createFramebuffer(&framebuffer_create_info, null);
            n_framebuffers += 1;
        }

        return framebuffers;
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
        if (extent.height == 0xFFFF_FFFF or extent.width == 0xFFFF_FFFF) {
            const min_image_extent = capabilities.min_image_extent;
            const max_image_extent = capabilities.max_image_extent;
            extent.width = std.math.clamp(desired_extent.width, min_image_extent.width, max_image_extent.width);
            extent.height = std.math.clamp(desired_extent.height, min_image_extent.height, max_image_extent.height);
        }
        if (extent.width == 0 or extent.height == 0) {
            return error.InvalidSurfaceDimensions;
        }
        const surface_formats = try vk_ctx.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(vk_ctx.physical_device, vk_ctx.surface, allocator);
        defer allocator.free(surface_formats);
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

        const swapchain = try vk_ctx.device.createSwapchainKHR(&swapchain_create_info, null);
        errdefer vk_ctx.device.destroySwapchainKHR(swapchain, null);

        if (old_handle != .null_handle) {
            // Apparently, the old swapchain handle still needs to be destroyed after recreating.
            vk_ctx.device.destroySwapchainKHR(old_handle, null);
        }

        const images = try vk_ctx.device.getSwapchainImagesAllocKHR(swapchain, allocator);
        defer allocator.free(images);
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

        const result = try vk_ctx.device.acquireNextImageKHR(swapchain, std.math.maxInt(u64), next_image_acquired, .null_handle);
        if (result.result != .success and result.result != .suboptimal_khr) {
            return error.ImageAcquireFailed;
        }

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
        for (self.swap_images) |si| {
            si.deinit(&vk_ctx.device);
        }
        allocator.free(self.swap_images);
        vk_ctx.device.destroySemaphore(self.next_image_acquired, null);
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

pub const Vertex = struct {
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

    pos: [3]f32,
    color: [3]f32,
};

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
