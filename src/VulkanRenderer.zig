const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const zm = @import("zmath");
const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});
const wnd = @import("WindowingContext.zig");

pub const InstancedDataType = enum { Points, Lines, Triangles };
pub const TopologyType = enum { Vertex, Line, Surface };

pub const IdBuffer = std.ArrayListUnmanaged(u64);

pub const IdBuffers = struct {
    vertex_ids: IdBuffer,
    line_ids: IdBuffer,
    surface_ids: IdBuffer,

    pub fn deinit(self: *IdBuffers, allocator: std.mem.Allocator) void {
        self.vertex_ids.deinit(allocator);
        self.line_ids.deinit(allocator);
        self.surface_ids.deinit(allocator);
    }

    pub fn id_at(self: *const IdBuffers, which: TopologyType, x: u64, y: u64, width: u64) !?u64 {
        // Our buffers our 1-dimensional so we have to flatten the screen
        // coordinates
        const i = x + y * width;

        const len = switch (which) {
            .Vertex => self.vertex_ids.items.len,
            .Line => self.line_ids.items.len,
            .Surface => self.surface_ids.items.len,
        };
        if (i > len) {
            return error.IdBufferSizeMismatchWithWindow;
        }

        const id = switch (which) {
            .Vertex => self.vertex_ids.items[i],
            .Line => self.line_ids.items[i],
            .Surface => self.surface_ids.items[i],
        };

        if (id == std.math.maxInt(u64)) {
            return null;
        }

        return id;
    }
};

const InstancedData = struct {
    vertex_buffer: vk.Buffer,
    vertex_memory: vk.DeviceMemory,
    index_buffer: vk.Buffer,
    index_memory: vk.DeviceMemory,
    n_indices: u32,

    pub fn init(T: type, vk_ctx: *const VulkanContext, vertices: []const T, indices: []const u32) !InstancedData {
        const vertex_buffer, const vertex_memory = try vk_ctx.createBuffer(
            T,
            vertices.len,
            .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        );
        const index_buffer, const index_memory = try vk_ctx.createBuffer(
            @TypeOf(indices[0]),
            indices.len,
            .{ .transfer_dst_bit = true, .index_buffer_bit = true },
        );

        return InstancedData{
            .vertex_buffer = vertex_buffer,
            .vertex_memory = vertex_memory,
            .index_buffer = index_buffer,
            .index_memory = index_memory,
            .n_indices = @intCast(indices.len),
        };
    }

    pub fn deinit(self: *const InstancedData, vk_ctx: *const VulkanContext) void {
        vk_ctx.device.destroyBuffer(self.vertex_buffer, null);
        vk_ctx.device.destroyBuffer(self.index_buffer, null);
        vk_ctx.device.freeMemory(self.vertex_memory, null);
        vk_ctx.device.freeMemory(self.index_memory, null);
    }
};

pub const Renderer = struct {
    swapchain: Swapchain,
    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    triangle_pipeline: vk.Pipeline,
    circle_pipeline: vk.Pipeline,
    line_pipeline: vk.Pipeline,
    command_pool: vk.CommandPool,
    descriptor_pool: vk.DescriptorPool,
    framebuffers: []vk.Framebuffer,
    command_buffers: []vk.CommandBuffer,
    descriptor_sets: []vk.DescriptorSet,

    point_instanced_data: ?InstancedData,
    line_instanced_data: ?InstancedData,
    triangle_instanced_data: ?InstancedData,

    mvp_uniform_buffers: []vk.Buffer,
    mvp_uniform_buffer_memories: []vk.DeviceMemory,
    mvp_uniform_buffer_mapped_memories: []*MVPUniformBufferObject,

    line_uniform_buffers: []vk.Buffer,
    line_uniform_buffer_memories: []vk.DeviceMemory,
    line_uniform_buffer_mapped_memories: []*LineUniformBufferObject,

    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, vk_ctx: *const VulkanContext, width: u32, height: u32) !Renderer {
        const extent = vk.Extent2D{ .width = width, .height = height };
        var swapchain = try Swapchain.init(vk_ctx, allocator, extent);
        const render_pass = try vk_ctx.createRenderPass(swapchain.surface_format.format, swapchain.depth_format);
        const framebuffers = try vk_ctx.createFramebuffers(allocator, &swapchain, render_pass);
        const command_buffers = try allocator.alloc(vk.CommandBuffer, framebuffers.len);
        errdefer allocator.free(command_buffers);

        const descriptor_set_layout = try setupDescriptors(vk_ctx);
        defer vk_ctx.device.destroyDescriptorSetLayout(descriptor_set_layout, null);
        const pipeline_layout_create_info = vk.PipelineLayoutCreateInfo{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = &.{descriptor_set_layout},
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        };
        const pipeline_layout = try vk_ctx.device.createPipelineLayout(&pipeline_layout_create_info, null);

        const triangle_pipeline = try vk_ctx.createPipeline(
            "vertex_shader",
            "fragment_shader",
            .triangle_list,
            false,
            pipeline_layout,
            render_pass,
        );

        const circle_pipeline = try vk_ctx.createPipeline(
            "circle_vertex_shader",
            "circle_fragment_shader",
            .point_list,
            true,
            pipeline_layout,
            render_pass,
        );

        const line_pipeline = try vk_ctx.createPipeline(
            "line_vertex_shader",
            "line_fragment_shader",
            .triangle_list,
            true,
            pipeline_layout,
            render_pass,
        );

        const command_pool_create_info = vk.CommandPoolCreateInfo{
            .queue_family_index = vk_ctx.graphics_queue_index,
        };
        const command_pool = try vk_ctx.device.createCommandPool(&command_pool_create_info, null);

        const descriptor_pool_size = vk.DescriptorPoolSize{
            .type = .uniform_buffer,
            .descriptor_count = @intCast(framebuffers.len),
        };
        const descriptor_pool_create_info = vk.DescriptorPoolCreateInfo{
            .pool_size_count = 1,
            .p_pool_sizes = &.{descriptor_pool_size},
            .max_sets = @intCast(framebuffers.len),
        };
        const descriptor_pool = try vk_ctx.device.createDescriptorPool(&descriptor_pool_create_info, null);

        const descriptor_set_layouts = try allocator.alloc(vk.DescriptorSetLayout, framebuffers.len);
        @memset(descriptor_set_layouts, descriptor_set_layout);
        defer allocator.free(descriptor_set_layouts);
        const descriptor_set_allocate_info = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = @intCast(descriptor_set_layouts.len),
            .p_set_layouts = descriptor_set_layouts.ptr,
        };
        const descriptor_sets = try allocator.alloc(vk.DescriptorSet, framebuffers.len);
        try vk_ctx.device.allocateDescriptorSets(&descriptor_set_allocate_info, descriptor_sets.ptr);

        var renderer = Renderer{
            .swapchain = swapchain,
            .render_pass = render_pass,
            .framebuffers = framebuffers,
            .pipeline_layout = pipeline_layout,
            .triangle_pipeline = triangle_pipeline,
            .circle_pipeline = circle_pipeline,
            .line_pipeline = line_pipeline,
            .command_pool = command_pool,
            .descriptor_pool = descriptor_pool,
            .point_instanced_data = null,
            .line_instanced_data = null,
            .triangle_instanced_data = null,
            .mvp_uniform_buffers = undefined,
            .mvp_uniform_buffer_memories = undefined,
            .mvp_uniform_buffer_mapped_memories = undefined,
            .line_uniform_buffers = undefined,
            .line_uniform_buffer_memories = undefined,
            .line_uniform_buffer_mapped_memories = undefined,
            .command_buffers = command_buffers,
            .descriptor_sets = descriptor_sets,
            .width = width,
            .height = height,
        };

        // note: these bits need to explicitly go _after_ the renderer has been
        // initialized above - they rely on the state that is already stored.
        // The alternative would be to add many input parameters to these
        // helpers. Since we have finished init'ing yet, I figured it's ok to
        // leave some member variables `undefined` above and init them in these
        // helpers
        try renderer.createUniformBuffers(allocator, vk_ctx, framebuffers.len);
        try renderer.createCommandBuffers(&vk_ctx.device, .{ .width = @intCast(width), .height = @intCast(height) });

        return renderer;
    }

    pub fn deinit(self: *const Renderer, allocator: std.mem.Allocator, vk_ctx: *const VulkanContext) void {
        self.swapchain.deinit(allocator, vk_ctx);
        vk_ctx.device.destroyRenderPass(self.render_pass, null);
        for (self.mvp_uniform_buffers, self.mvp_uniform_buffer_memories) |uniform_buffer, uniform_buffer_memory| {
            vk_ctx.device.destroyBuffer(uniform_buffer, null);
            vk_ctx.device.unmapMemory(uniform_buffer_memory);
            vk_ctx.device.freeMemory(uniform_buffer_memory, null);
        }
        for (self.line_uniform_buffers, self.line_uniform_buffer_memories) |uniform_buffer, uniform_buffer_memory| {
            vk_ctx.device.destroyBuffer(uniform_buffer, null);
            vk_ctx.device.unmapMemory(uniform_buffer_memory);
            vk_ctx.device.freeMemory(uniform_buffer_memory, null);
        }
        for (self.framebuffers) |framebuffer| {
            vk_ctx.device.destroyFramebuffer(framebuffer, null);
        }
        std.debug.print("Checking instanced datas\n", .{});
        if (self.point_instanced_data) |data| {
            std.debug.print("deiniting points\n", .{});
            data.deinit(vk_ctx);
        }
        if (self.line_instanced_data) |data| {
            std.debug.print("deiniting lines\n", .{});
            data.deinit(vk_ctx);
        }
        if (self.triangle_instanced_data) |data| {
            std.debug.print("deiniting triangles\n", .{});
            data.deinit(vk_ctx);
        }
        std.debug.print("done Checking instanced datas\n", .{});

        vk_ctx.device.destroyPipeline(self.triangle_pipeline, null);
        vk_ctx.device.destroyPipeline(self.circle_pipeline, null);
        vk_ctx.device.destroyPipeline(self.line_pipeline, null);
        vk_ctx.device.destroyPipelineLayout(self.pipeline_layout, null);
        vk_ctx.device.destroyDescriptorPool(self.descriptor_pool, null);
        vk_ctx.device.freeCommandBuffers(self.command_pool, @truncate(self.command_buffers.len), self.command_buffers.ptr);
        vk_ctx.device.destroyCommandPool(self.command_pool, null);

        allocator.free(self.command_buffers);
        allocator.free(self.mvp_uniform_buffers);
        allocator.free(self.mvp_uniform_buffer_memories);
        allocator.free(self.mvp_uniform_buffer_mapped_memories);
        allocator.free(self.line_uniform_buffers);
        allocator.free(self.line_uniform_buffer_memories);
        allocator.free(self.line_uniform_buffer_mapped_memories);
        allocator.free(self.descriptor_sets);
        allocator.free(self.framebuffers);
    }

    pub fn getIdBuffers(self: *const Renderer, allocator: std.mem.Allocator, vk_ctx: *const VulkanContext) !IdBuffers {
        const capacity = self.width * self.height;
        // std.debug.print("Initing capacity of {d}\n", .{capacity});
        var id_buffers = IdBuffers{
            .vertex_ids = try std.ArrayListUnmanaged(u64).initCapacity(allocator, capacity),
            .line_ids = try std.ArrayListUnmanaged(u64).initCapacity(allocator, capacity),
            .surface_ids = try std.ArrayListUnmanaged(u64).initCapacity(allocator, capacity),
        };

        // maxInt is used so that our indices can stay zero-based
        try id_buffers.vertex_ids.appendNTimes(allocator, std.math.maxInt(u64), capacity);
        try id_buffers.line_ids.appendNTimes(allocator, std.math.maxInt(u64), capacity);
        try id_buffers.surface_ids.appendNTimes(allocator, std.math.maxInt(u64), capacity);

        const swap_image = self.swapchain.swap_images[self.swapchain.current_image_index];
        try self.transferImageFromDevice(vk_ctx, u64, swap_image.vertex_ids, id_buffers.vertex_ids);
        try self.transferImageFromDevice(vk_ctx, u64, swap_image.line_ids, id_buffers.line_ids);
        try self.transferImageFromDevice(vk_ctx, u64, swap_image.surface_ids, id_buffers.surface_ids);

        return id_buffers;
    }

    pub fn createCommandBuffers(
        self: *Renderer,
        device: *const VulkanContext.Device,
        extent: vk.Extent2D,
    ) !void {
        const command_buffer_allocate_info = vk.CommandBufferAllocateInfo{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(self.command_buffers.len),
        };
        try device.allocateCommandBuffers(&command_buffer_allocate_info, self.command_buffers.ptr);
        errdefer device.freeCommandBuffers(self.command_pool, @intCast(self.command_buffers.len), self.command_buffers.ptr);

        const color_clear = vk.ClearValue{
            .color = .{ .float_32 = .{ 0.2, 0.3, 0.3, 1 } },
        };
        const max_u32 = std.math.maxInt(u32);
        const id_clear = vk.ClearValue{
            .color = .{ .uint_32 = .{ max_u32, max_u32, max_u32, max_u32 } },
        };
        const depth_clear = vk.ClearValue{
            .depth_stencil = .{
                .depth = 1.0,
                .stencil = 0,
            },
        };
        const clear_values = [_]vk.ClearValue{
            color_clear,
            id_clear,
            id_clear,
            id_clear,
            depth_clear,
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

        for (
            self.command_buffers,
            self.framebuffers,
            self.descriptor_sets,
        ) |command_buffer, framebuffer, descriptor_set| {
            try device.beginCommandBuffer(command_buffer, &.{});

            device.cmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));
            device.cmdSetScissor(command_buffer, 0, 1, @ptrCast(&scissor));

            // This needs to be a separate definition - see https://github.com/ziglang/zig/issues/7627.
            const render_area = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent,
            };

            device.cmdBeginRenderPass(command_buffer, &.{
                .render_pass = self.render_pass,
                .framebuffer = framebuffer,
                .render_area = render_area,
                .clear_value_count = clear_values.len,
                .p_clear_values = &clear_values,
            }, .@"inline");

            const offset = [_]vk.DeviceSize{0};
            // Draw triangles
            if (self.triangle_instanced_data) |data| {
                device.cmdBindPipeline(command_buffer, .graphics, self.triangle_pipeline);
                device.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&data.vertex_buffer), &offset);
                // TODO: is there a way to _not_ bind this? it's nonsensical
                // since the Vertex buffer doesn't match up with the
                // BindingDescription of the Line type.
                device.cmdBindVertexBuffers(command_buffer, 1, 1, @ptrCast(&data.vertex_buffer), &offset);
                device.cmdBindIndexBuffer(command_buffer, data.index_buffer, 0, vk.IndexType.uint32);
                device.cmdBindDescriptorSets(command_buffer, .graphics, self.pipeline_layout, 0, 1, &.{descriptor_set}, 0, null);
                device.cmdDrawIndexed(command_buffer, data.n_indices, 1, 0, 0, 0);
            }

            // draw lines
            if (self.line_instanced_data) |data| {
                device.cmdBindPipeline(command_buffer, .graphics, self.line_pipeline);
                device.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&data.vertex_buffer), &offset);
                device.cmdBindVertexBuffers(command_buffer, 1, 1, @ptrCast(&data.vertex_buffer), &offset);
                device.cmdBindIndexBuffer(command_buffer, data.index_buffer, 0, vk.IndexType.uint32);
                device.cmdBindDescriptorSets(command_buffer, .graphics, self.pipeline_layout, 0, 1, &.{descriptor_set}, 0, null);
                // device.cmdDraw(command_buffer, 1, 6, 0, 0);
                device.cmdDrawIndexed(command_buffer, data.n_indices, 1, 0, 0, 0);
            }

            // draw dots
            if (self.point_instanced_data) |data| {
                device.cmdBindPipeline(command_buffer, .graphics, self.circle_pipeline);
                device.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&data.vertex_buffer), &offset);
                device.cmdBindVertexBuffers(command_buffer, 1, 1, @ptrCast(&data.vertex_buffer), &offset);
                device.cmdBindIndexBuffer(command_buffer, data.index_buffer, 0, vk.IndexType.uint32);
                device.cmdBindDescriptorSets(command_buffer, .graphics, self.pipeline_layout, 0, 1, &.{descriptor_set}, 0, null);
                device.cmdDrawIndexed(command_buffer, data.n_indices, 1, 0, 0, 0);
            }

            // draw lines

            device.cmdEndRenderPass(command_buffer);
            try device.endCommandBuffer(command_buffer);
        }
    }

    fn createUniformBuffers(
        self: *Renderer,
        allocator: std.mem.Allocator,
        vk_ctx: *const VulkanContext,
        n_frames: usize,
    ) !void {
        self.mvp_uniform_buffers = try allocator.alloc(vk.Buffer, n_frames);
        self.mvp_uniform_buffer_memories = try allocator.alloc(vk.DeviceMemory, n_frames);
        self.mvp_uniform_buffer_mapped_memories = try allocator.alloc(*MVPUniformBufferObject, n_frames);

        self.line_uniform_buffers = try allocator.alloc(vk.Buffer, n_frames);
        self.line_uniform_buffer_memories = try allocator.alloc(vk.DeviceMemory, n_frames);
        self.line_uniform_buffer_mapped_memories = try allocator.alloc(*LineUniformBufferObject, n_frames);
        // std.debug.print("buffer size is {d}\n", .{buffer_size});
        for (0..n_frames) |i| {
            self.mvp_uniform_buffers[i], self.mvp_uniform_buffer_memories[i] = try vk_ctx.createBuffer(
                MVPUniformBufferObject,
                1,
                .{ .uniform_buffer_bit = true },
            );
            const mvp_host_data = try vk_ctx.device.mapMemory(self.mvp_uniform_buffer_memories[i], 0, 1, .{});
            // gpu_data
            self.mvp_uniform_buffer_mapped_memories[i] = @ptrCast(@alignCast(mvp_host_data));
            try vk_ctx.device.bindBufferMemory(
                self.mvp_uniform_buffers[i],
                self.mvp_uniform_buffer_memories[i],
                0,
            );

            self.line_uniform_buffers[i], self.line_uniform_buffer_memories[i] = try vk_ctx.createBuffer(
                LineUniformBufferObject,
                1,
                .{ .uniform_buffer_bit = true },
            );
            const line_host_data = try vk_ctx.device.mapMemory(self.line_uniform_buffer_memories[i], 0, 1, .{});
            // gpu_data
            self.line_uniform_buffer_mapped_memories[i] = @ptrCast(@alignCast(line_host_data));
            try vk_ctx.device.bindBufferMemory(
                self.line_uniform_buffers[i],
                self.line_uniform_buffer_memories[i],
                0,
            );

            const descriptor_buffer_infos = [_]vk.DescriptorBufferInfo{
                .{
                    .buffer = self.mvp_uniform_buffers[i],
                    .offset = 0,
                    .range = @sizeOf(MVPUniformBufferObject),
                },
                .{
                    .buffer = self.line_uniform_buffers[i],
                    .offset = 0,
                    .range = @sizeOf(LineUniformBufferObject),
                },
            };

            // Since p_image_info and p_texel_buffer aren't implemented by
            // vulkav-zig as `?[*]....`, we _have_ to specify something, so here
            // goes.
            const descriptor_image_info = vk.DescriptorImageInfo{
                .sampler = .null_handle,
                .image_view = .null_handle,
                .image_layout = .undefined,
            };
            const write_descriptor_set = vk.WriteDescriptorSet{
                .dst_set = self.descriptor_sets[i],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = descriptor_buffer_infos.len,
                .p_buffer_info = &descriptor_buffer_infos,
                .p_image_info = &.{descriptor_image_info},
                .p_texel_buffer_view = &.{.null_handle},
            };
            vk_ctx.device.updateDescriptorSets(1, &.{write_descriptor_set}, 0, null);
        }
    }

    pub fn setupDescriptors(vk_ctx: *const VulkanContext) !vk.DescriptorSetLayout {
        const mvp_uniform_binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = vk.DescriptorType.uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true },
        };
        const line_uniform_binding = vk.DescriptorSetLayoutBinding{
            .binding = 1,
            .descriptor_type = vk.DescriptorType.uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true },
        };

        const descriptor_set_layout_create_info = vk.DescriptorSetLayoutCreateInfo{
            .binding_count = 2,
            .p_bindings = &.{ mvp_uniform_binding, line_uniform_binding },
        };
        return try vk_ctx.device.createDescriptorSetLayout(&descriptor_set_layout_create_info, null);
    }

    pub fn uploadInstanced(
        self: *Renderer,
        T: type,
        vk_ctx: *const VulkanContext,
        data_type: InstancedDataType,
        vertices: []const T,
        indices: []const u32,
    ) !void {
        const instanced_data: *?InstancedData = switch (data_type) {
            .Points => &self.point_instanced_data,
            .Lines => &self.line_instanced_data,
            .Triangles => &self.triangle_instanced_data,
        };
        if (instanced_data.* == null or instanced_data.*.?.n_indices != indices.len) {
            if (instanced_data.*) |old_data| {
                old_data.deinit(vk_ctx);
            }
            instanced_data.* = try InstancedData.init(T, vk_ctx, vertices, indices);
        }
        try self.transferToDevice(vk_ctx, T, vertices, instanced_data.*.?.vertex_buffer, instanced_data.*.?.vertex_memory);
        try self.transferToDevice(vk_ctx, u32, indices, instanced_data.*.?.index_buffer, instanced_data.*.?.index_memory);

        try self.createCommandBuffers(&vk_ctx.device, .{ .width = @intCast(self.width), .height = @intCast(self.height) });
    }

    // Data will be transferred from `data` into the `buffer` on the device
    fn transferToDevice(
        self: *const Renderer,
        vk_ctx: *const VulkanContext,
        comptime T: type,
        from_data: []const T,
        to_buffer: vk.Buffer,
        to_buffer_memory: vk.DeviceMemory,
    ) !void {
        const staging_buffer, const staging_memory = try vk_ctx.createBuffer(T, from_data.len, .{ .transfer_src_bit = true });
        defer vk_ctx.device.destroyBuffer(staging_buffer, null);
        defer vk_ctx.device.freeMemory(staging_memory, null);

        const mapped_data = try vk_ctx.device.mapMemory(staging_memory, 0, from_data.len, .{});
        const casted_mapped_data: [*]T = @ptrCast(@alignCast(mapped_data));
        @memcpy(casted_mapped_data, from_data[0..]);
        vk_ctx.device.unmapMemory(staging_memory);

        try vk_ctx.device.bindBufferMemory(staging_buffer, staging_memory, 0);
        try vk_ctx.device.bindBufferMemory(to_buffer, to_buffer_memory, 0);
        try self.copyBuffer(vk_ctx, staging_buffer, to_buffer, from_data.len * @sizeOf(T));
    }

    // Data will be transferred into `data` from the `buffer` on the device
    fn transferImageFromDevice(
        self: *const Renderer,
        vk_ctx: *const VulkanContext,
        comptime T: type,
        from_image: vk.Image,
        to_data: std.ArrayListUnmanaged(T),
    ) !void {
        try self.transitionImageLayout(vk_ctx, from_image, .color_attachment_optimal, .transfer_src_optimal);

        const staging_buffer, const staging_memory = try vk_ctx.createBuffer(T, to_data.capacity, .{ .transfer_dst_bit = true });
        defer vk_ctx.device.destroyBuffer(staging_buffer, null);
        defer vk_ctx.device.freeMemory(staging_memory, null);
        try vk_ctx.device.bindBufferMemory(staging_buffer, staging_memory, 0);

        try self.copyImageToBuffer(vk_ctx, from_image, .transfer_src_optimal, staging_buffer);

        const mapped_data = try vk_ctx.device.mapMemory(staging_memory, 0, to_data.capacity, .{});
        const casted_mapped_data: [*]T = @ptrCast(@alignCast(mapped_data));
        // std.debug.print("transfered {d} bytes from gpu\n", .{to_data.capacity});
        @memcpy(to_data.items, casted_mapped_data);
        // std.debug.print("to_data.len = {d}\n", .{to_data.items.len});
        vk_ctx.device.unmapMemory(staging_memory);
    }

    fn transitionImageLayout(
        self: *const Renderer,
        vk_ctx: *const VulkanContext,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
    ) !void {
        const command_buffer = try self.beginCommand(vk_ctx);

        var src_stage: vk.PipelineStageFlags = .{};
        var dst_stage: vk.PipelineStageFlags = .{};
        var src_access_mask: vk.AccessFlags = .{};
        var dst_access_mask: vk.AccessFlags = .{};

        if (old_layout == .color_attachment_optimal and new_layout == .transfer_src_optimal) {
            src_stage = .{ .fragment_shader_bit = true };
            dst_stage = .{ .transfer_bit = true };
            src_access_mask = .{ .shader_write_bit = true };
            dst_access_mask = .{ .transfer_read_bit = true };
        } else {
            return error.UnsupportedLayoutTransition;
        }

        const barriers = [_]vk.ImageMemoryBarrier{
            .{
                .src_access_mask = src_access_mask,
                .dst_access_mask = dst_access_mask,
                .old_layout = old_layout,
                .new_layout = new_layout,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = image,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            },
        };

        command_buffer.pipelineBarrier(src_stage, dst_stage, .{}, 0, null, 0, null, barriers.len, &barriers);

        try self.endCommand(vk_ctx, command_buffer);
    }

    fn beginCommand(self: *const Renderer, vk_ctx: *const VulkanContext) !VulkanContext.CommandBuffer {
        var command_buffer_handle: vk.CommandBuffer = undefined;
        try vk_ctx.device.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer_handle));

        const command_buffer = VulkanContext.CommandBuffer.init(command_buffer_handle, vk_ctx.device.wrapper);

        try command_buffer.beginCommandBuffer(&.{ .flags = .{ .one_time_submit_bit = true } });
        return command_buffer;
    }

    fn endCommand(self: *const Renderer, vk_ctx: *const VulkanContext, command_buffer: VulkanContext.CommandBuffer) !void {
        try command_buffer.endCommandBuffer();

        const submit_info = vk.SubmitInfo{
            .command_buffer_count = 1,
            .p_command_buffers = (&command_buffer.handle)[0..1],
            .p_wait_dst_stage_mask = undefined,
        };
        try vk_ctx.device.queueSubmit(vk_ctx.graphics_queue, 1, @ptrCast(&submit_info), .null_handle);
        try vk_ctx.device.queueWaitIdle(vk_ctx.graphics_queue);
        vk_ctx.device.freeCommandBuffers(self.command_pool, 1, (&command_buffer.handle)[0..1].ptr);
    }

    fn copyBuffer(self: *const Renderer, vk_ctx: *const VulkanContext, src: vk.Buffer, dst: vk.Buffer, size: usize) !void {
        const command_buffer = try self.beginCommand(vk_ctx);

        const regions = [_]vk.BufferCopy{
            .{
                .src_offset = 0,
                .dst_offset = 0,
                .size = size,
            },
        };
        command_buffer.copyBuffer(src, dst, 1, &regions);

        try self.endCommand(vk_ctx, command_buffer);
    }

    fn copyImageToBuffer(self: *const Renderer, vk_ctx: *const VulkanContext, src_image: vk.Image, src_image_layout: vk.ImageLayout, dst_buffer: vk.Buffer) !void {
        const command_buffer = try self.beginCommand(vk_ctx);

        const buffer_image_copy_regions = [_]vk.BufferImageCopy{
            .{
                .buffer_offset = 0,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = .{ .width = self.width, .height = self.height, .depth = 1 },
            },
        };
        command_buffer.copyImageToBuffer(src_image, src_image_layout, dst_buffer, 1, &buffer_image_copy_regions);

        try self.endCommand(vk_ctx, command_buffer);
    }

    pub fn render(
        self: *Renderer,
        allocator: std.mem.Allocator,
        vk_ctx: *const VulkanContext,
        window_width: u32,
        window_height: u32,
        mvp_ubo: *const MVPUniformBufferObject,
    ) !void {
        const command_buffer = self.command_buffers[self.swapchain.current_image_index];
        {
            const gpu_data: [*]MVPUniformBufferObject = @ptrCast(@alignCast(self.mvp_uniform_buffer_mapped_memories[self.swapchain.current_image_index]));
            const data = [1]MVPUniformBufferObject{mvp_ubo.*};
            @memcpy(gpu_data, &data);
        }
        {
            const gpu_data: [*]LineUniformBufferObject = @ptrCast(@alignCast(self.line_uniform_buffer_mapped_memories[self.swapchain.current_image_index]));
            const aspect_ratio = @as(f32, @floatFromInt(window_width)) / @as(f32, @floatFromInt(window_height));
            // std.debug.print("aspect_ratio: {d:3}\n", .{aspect_ratio});
            const data = [1]LineUniformBufferObject{.{
                .aspect_ratio = aspect_ratio,
                .line_thickness = 0.25,
            }};
            @memcpy(gpu_data, &data);
        }
        const state = self.swapchain.present(vk_ctx, command_buffer) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal or self.width != window_width or self.height != window_height) {
            self.width = window_width;
            self.height = window_height;
            const extent = vk.Extent2D{ .width = self.width, .height = self.height };
            try vk_ctx.device.queueWaitIdle(vk_ctx.graphics_queue);
            try vk_ctx.device.queueWaitIdle(vk_ctx.presentation_queue);

            try self.swapchain.recreate(allocator, vk_ctx, extent);

            for (self.framebuffers) |fb| vk_ctx.device.destroyFramebuffer(fb, null);
            // TODO: we shouldn't need to free this
            allocator.free(self.framebuffers);
            self.framebuffers = try vk_ctx.createFramebuffers(allocator, &self.swapchain, self.render_pass);
            vk_ctx.device.freeCommandBuffers(self.command_pool, @truncate(self.command_buffers.len), self.command_buffers.ptr);

            try self.createCommandBuffers(&vk_ctx.device, extent);
        }
    }
};

pub const WindowingInfo = union(wnd.WindowingType) {
    xlib: struct {
        x11_display: *vk.Display,
        x11_window: vk.Window,
    },
    wayland: struct {
        wl_display: *vk.wl_display,
        wl_surface: *vk.wl_surface,
    },
};

pub const VulkanContext = struct {
    // These are types: they contain functions that e.g. require you to provide the
    // instance or device
    const BaseWrapper = vk.BaseWrapper;
    const InstanceWrapper = vk.InstanceWrapper;
    const DeviceWrapper = vk.DeviceWrapper;

    // These are also types: they hold the instance or device or w/e so you don't
    // have to pass those in.
    const Instance = vk.InstanceProxy;
    const Device = vk.DeviceProxy;
    const CommandBuffer = vk.CommandBufferProxy;

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

    pub fn init(allocator: std.mem.Allocator, windowing_info: WindowingInfo) !VulkanContext {
        // TODO: try (again) to see if we can do this without linking vulkan and
        // importing the c-thing, e.g. can we do this in pure zig.
        const get_instance_proc_addr: vk.PfnGetInstanceProcAddr = @extern(vk.PfnGetInstanceProcAddr, .{
            .name = "vkGetInstanceProcAddr",
            .library_name = "vulkan",
        });
        const base_dispatch = BaseWrapper.load(get_instance_proc_addr);

        // Query available instance layers
        var available_layer_properties_count: u32 = 0;
        var result = try base_dispatch.enumerateInstanceLayerProperties(&available_layer_properties_count, null);
        if (result != .success) {
            std.debug.print("Failed to get instance layer property count: {any}\n", .{result});
            return error.InstanceLayerEnumerationFailed;
        }

        const available_layer_properties_alloc = try allocator.alloc(vk.LayerProperties, available_layer_properties_count);
        defer allocator.free(available_layer_properties_alloc); // Ensure this is freed if an error occurs later

        result = try base_dispatch.enumerateInstanceLayerProperties(&available_layer_properties_count, available_layer_properties_alloc.ptr);
        if (result != .success) {
            std.debug.print("Failed to enumerate instance layer properties: {any}\n", .{result});
            return error.InstanceLayerEnumerationFailed;
        }
        const available_layers = available_layer_properties_alloc[0..available_layer_properties_count];

        const application_info = vk.ApplicationInfo{
            .p_application_name = "zcad vulkan",
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_3),
        };

        // TODO: add checks to ensure the requested extensions are supported, see
        // https://vulkan-tutorial.com/en/Drawing_a_triangle/Setup/Validation_layers
        const instance_extensions = [_][*:0]const u8{
            vk.extensions.khr_surface.name,
            vk.extensions.khr_wayland_surface.name,
            vk.extensions.khr_xlib_surface.name,
        };

        var final_enabled_layer_count: u32 = 0;
        var final_enabled_layer_names_ptr: ?[*]const [*:0]const u8 = null;
        const validation_layer_name_str = "VK_LAYER_KHRONOS_validation";

        if (builtin.mode == .Debug) {
            std.debug.print("Available Vulkan Instance Layers:\n", .{});
            var validation_layer_found = false;
            for (available_layers) |layer_prop| {
                const layer_name_slice = std.mem.sliceTo(layer_prop.layer_name[0..], 0);
                std.debug.print("  - {s}\n", .{layer_name_slice});
                if (std.mem.eql(u8, layer_name_slice, validation_layer_name_str)) {
                    validation_layer_found = true;
                    break;
                }
            }

            if (validation_layer_found) {
                // Keep this static or ensure its lifetime exceeds createInstance call
                const validation_layer_to_enable = [_][*:0]const u8{validation_layer_name_str};
                final_enabled_layer_names_ptr = &validation_layer_to_enable;
                final_enabled_layer_count = 1;
                std.debug.print("Enabling Vulkan validation layer: {s}\n", .{validation_layer_name_str});
            } else {
                std.debug.print("WARNING: Vulkan validation layer ({s}) not found among available layers. Proceeding without it.\n", .{validation_layer_name_str});
            }
        }

        const create_instance_info = vk.InstanceCreateInfo{
            .p_application_info = &application_info,
            .enabled_extension_count = instance_extensions.len,
            .pp_enabled_extension_names = &instance_extensions,
            .enabled_layer_count = final_enabled_layer_count,
            .pp_enabled_layer_names = final_enabled_layer_names_ptr,
        };
        const instance_handle = try base_dispatch.createInstance(&create_instance_info, null);
        const instance_dispatch = try allocator.create(InstanceWrapper);
        errdefer allocator.destroy(instance_dispatch);
        instance_dispatch.* = InstanceWrapper.load(instance_handle, base_dispatch.dispatch.vkGetInstanceProcAddr.?);
        const instance = Instance.init(instance_handle, instance_dispatch);
        errdefer instance.destroyInstance(null);

        const surface = switch (windowing_info) {
            .xlib => |info| try instance.createXlibSurfaceKHR(&.{ .dpy = info.x11_display, .window = info.x11_window }, null),
            .wayland => |info| try instance.createWaylandSurfaceKHR(&.{ .display = info.wl_display, .surface = info.wl_surface }, null),
        };
        errdefer instance.destroySurfaceKHR(surface, null);

        // const debug_util_messenger_create_info = vk.DebugUtilsMessengerCreateInfoEXT{
        //     .message_severity = .{ .verbose_bit_ext = true, .warning_bit_ext = true, .error_bit_ext = true, .info_bit_ext = true },
        //     .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
        //     .pfn_user_callback = debugCallback,
        //     .p_user_data = null,
        // };
        // const debug_messenger = try instance.createDebugUtilsMessengerEXT(&debug_util_messenger_create_info, null);
        // defer instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

        const required_device_extensions = [_][*:0]const u8{
            vk.extensions.khr_swapchain.name,
        };
        const required_device_features = vk.PhysicalDeviceFeatures{
            .independent_blend = vk.TRUE,
        };
        const physical_devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
        defer allocator.free(physical_devices);
        var maybe_physical_device: ?vk.PhysicalDevice = null;
        var physical_device_properties: vk.PhysicalDeviceProperties = undefined;
        outer: for (physical_devices) |physical_device_candidate| {
            physical_device_properties = instance.getPhysicalDeviceProperties(physical_device_candidate);
            std.debug.print("Checking physical device {s}\n", .{physical_device_properties.device_name});
            const api_version: vk.Version = @bitCast(physical_device_properties.api_version);
            if (api_version.major < 1) {
                std.debug.print("  Major version {d} is too low, expected at least 1\n", .{api_version.major});
                continue;
            }
            if (api_version.minor < 4) {
                std.debug.print("  Minor version {d} is too low, expected at least 3\n", .{api_version.minor});
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
                    if (std.mem.eql(u8, std.mem.span(need), std.mem.sliceTo(&prop.extension_name, 0))) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    continue :outer;
                }
            }

            // get the device features
            const device_features = instance.getPhysicalDeviceFeatures(physical_device_candidate);
            inline for (@typeInfo(vk.PhysicalDeviceFeatures).@"struct".fields) |field| {
                if (@field(required_device_features, field.name) == vk.TRUE and @field(device_features, field.name) == vk.FALSE) {
                    continue :outer;
                }
            }

            std.debug.print("  MATCH on {s}\n", .{physical_device_properties.device_name});
            std.debug.print("  Api Version: {d}.{d}.{d}\n", .{ api_version.major, api_version.minor, api_version.patch });
            const driver_version: vk.Version = @bitCast(physical_device_properties.driver_version);
            std.debug.print("  Driver Version: {d}.{d}.{d}\n", .{ driver_version.major, driver_version.minor, driver_version.patch });
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
        std.debug.print("done looping\n", .{});

        if (graphics_queue_index == null) {
            std.debug.print("Unable to find queue that supports graphics\n", .{});
            return error.NoGraphicsQueue;
        }
        if (presentation_queue_index == null) {
            std.debug.print("Unable to find queue that supports presentation\n", .{});
            return error.NoPresentationQueue;
        }
        std.debug.print("got indices\n", .{});

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
            .pp_enabled_extension_names = &required_device_extensions,
            .p_enabled_features = &required_device_features,
        };
        const device_handle = try instance.createDevice(physical_device, &device_create_info, null);
        const device_dispatch = try allocator.create(DeviceWrapper);
        errdefer allocator.destroy(device_dispatch);
        device_dispatch.* = DeviceWrapper.load(device_handle, instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
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

    pub fn createRenderPass(self: *const VulkanContext, surface_format: vk.Format, depth_format: vk.Format) !vk.RenderPass {
        const color_attachment = vk.AttachmentDescription{
            .format = surface_format,
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

        const id_color_attachment = vk.AttachmentDescription{
            .format = .r32g32_uint,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .color_attachment_optimal,
        };
        const vertex_id_color_attachment_ref = vk.AttachmentReference{
            .attachment = 1,
            .layout = .color_attachment_optimal,
        };
        const line_id_color_attachment_ref = vk.AttachmentReference{
            .attachment = 2,
            .layout = .color_attachment_optimal,
        };
        const surface_id_color_attachment_ref = vk.AttachmentReference{
            .attachment = 3,
            .layout = .color_attachment_optimal,
        };

        const depth_attachment = vk.AttachmentDescription{
            .format = depth_format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .dont_care,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .depth_stencil_attachment_optimal,
        };
        const depth_attachment_ref = vk.AttachmentReference{
            .attachment = 4,
            .layout = .depth_stencil_attachment_optimal,
        };

        const attachment_references = [_]vk.AttachmentReference{
            color_attachment_ref,
            vertex_id_color_attachment_ref,
            line_id_color_attachment_ref,
            surface_id_color_attachment_ref,
        };
        const subpass = vk.SubpassDescription{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = attachment_references.len,
            .p_color_attachments = &attachment_references,
            .p_depth_stencil_attachment = @ptrCast(&depth_attachment_ref),
        };

        const subpass_dependency = vk.SubpassDependency{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .dst_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
        };

        const attachments = [_]vk.AttachmentDescription{
            color_attachment,
            id_color_attachment, // vertex ids
            id_color_attachment, // line ids
            id_color_attachment, // surface ids
            depth_attachment,
        };
        const render_pass_create_info = vk.RenderPassCreateInfo{
            .attachment_count = attachments.len,
            .p_attachments = &attachments,
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 1,
            .p_dependencies = @ptrCast(&subpass_dependency),
        };
        return try self.device.createRenderPass(&render_pass_create_info, null);
    }

    // These "fname"s are embedded files - this is set up in build.zig
    fn createPipeline(
        self: *const VulkanContext,
        comptime vert_fname: []const u8,
        comptime frag_fname: []const u8,
        topology: vk.PrimitiveTopology,
        blend_enable: bool,
        layout: vk.PipelineLayout,
        render_pass: vk.RenderPass,
    ) !vk.Pipeline {
        const vert_spv align(@alignOf(u32)) = @embedFile(vert_fname).*;
        const frag_spv align(@alignOf(u32)) = @embedFile(frag_fname).*;

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

        const binding_descriptions = [_]vk.VertexInputBindingDescription{
            Vertex.binding_description,
            Line.binding_description,
        };
        const attribute_descriptions = Vertex.attribute_description ++ Line.attribute_description;
        const pipeline_vertex_input_state_create_info = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = binding_descriptions.len,
            .p_vertex_binding_descriptions = @ptrCast(&binding_descriptions),
            .vertex_attribute_description_count = attribute_descriptions.len,
            .p_vertex_attribute_descriptions = &attribute_descriptions,
        };

        const pipeline_input_assembly_state_create_info = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = topology,
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
            .cull_mode = .{ .back_bit = false },
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

        const null_stencil_op_state = vk.StencilOpState{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .less,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        };
        const pipeline_depth_stencil_state_create_info = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = vk.TRUE,
            .depth_write_enable = vk.TRUE,
            .depth_compare_op = .less,
            .depth_bounds_test_enable = vk.FALSE,
            .min_depth_bounds = 0,
            .max_depth_bounds = 0,
            .stencil_test_enable = vk.FALSE,
            .front = null_stencil_op_state,
            .back = null_stencil_op_state,
        };

        const pipeline_color_blend_attachment_state = vk.PipelineColorBlendAttachmentState{
            .blend_enable = if (blend_enable) vk.TRUE else vk.FALSE,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = false },
        };
        const disabled_color_blend = vk.PipelineColorBlendAttachmentState{
            .blend_enable = vk.FALSE,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = false },
        };

        const color_blend_attachments = [_]vk.PipelineColorBlendAttachmentState{
            pipeline_color_blend_attachment_state,
            disabled_color_blend,
            disabled_color_blend,
            disabled_color_blend,
        };
        const pipeline_color_blend_state_create_info = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .attachment_count = color_blend_attachments.len,
            .p_attachments = &color_blend_attachments,
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
            .p_dynamic_state = &pipeline_dynamic_state_create_info,
            .p_color_blend_state = &pipeline_color_blend_state_create_info,
            .p_depth_stencil_state = &pipeline_depth_stencil_state_create_info,
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
            const attachments = [_]vk.ImageView{
                swapchain.swap_images[n_framebuffers].view,
                swapchain.swap_images[n_framebuffers].vertex_ids_view,
                swapchain.swap_images[n_framebuffers].line_ids_view,
                swapchain.swap_images[n_framebuffers].surface_ids_view,
                swapchain.depth_image_view,
            };
            const framebuffer_create_info = vk.FramebufferCreateInfo{
                .render_pass = render_pass,
                .attachment_count = attachments.len,
                .p_attachments = &attachments,
                .width = swapchain.extent.width,
                .height = swapchain.extent.height,
                .layers = 1,
            };
            fb.* = try self.device.createFramebuffer(&framebuffer_create_info, null);
            n_framebuffers += 1;
        }

        return framebuffers;
    }

    pub fn findMemoryType(self: *const VulkanContext, memory_type_bits: u32, memory_property_flags: vk.MemoryPropertyFlags) !u32 {
        const physical_device_memory_properties = self.instance.getPhysicalDeviceMemoryProperties(self.physical_device);
        const memory_types = physical_device_memory_properties.memory_types;
        const n_memory_types = physical_device_memory_properties.memory_type_count;
        for (memory_types[0..n_memory_types], 0..) |memory_type, i| {
            if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and memory_type.property_flags.contains(memory_property_flags)) {
                return @truncate(i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    fn createBuffer(
        self: *const VulkanContext,
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
        const buffer = try self.device.createBuffer(&buffer_create_info, null);

        const memory_requirements = self.device.getBufferMemoryRequirements(buffer);
        const memory_type_index = try self.findMemoryType(memory_requirements.memory_type_bits, .{ .device_local_bit = true });
        const memory_allocate_info = vk.MemoryAllocateInfo{
            .allocation_size = memory_requirements.size,
            .memory_type_index = memory_type_index,
        };
        const memory = try self.device.allocateMemory(&memory_allocate_info, null);

        return .{ buffer, memory };
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
    depth_format: vk.Format,
    depth_image: vk.Image,
    depth_image_memory: vk.DeviceMemory,
    depth_image_view: vk.ImageView,
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

        // depth buffer
        // const depth_format = vk.Format.d32_sfloat;
        const depth_format = vk.Format.d32_sfloat_s8_uint;
        const depth_image_create_info = vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = depth_format,
            .extent = .{
                .width = extent.width,
                .height = extent.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{
                .depth_stencil_attachment_bit = true,
            },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        };
        const depth_image = try vk_ctx.device.createImage(&depth_image_create_info, null);

        const image_memory_requirements = vk_ctx.device.getImageMemoryRequirements(depth_image);
        const memory_type_index = try vk_ctx.findMemoryType(image_memory_requirements.memory_type_bits, .{ .device_local_bit = true });
        const depth_image_memory_allocate_info = vk.MemoryAllocateInfo{
            .allocation_size = image_memory_requirements.size,
            .memory_type_index = memory_type_index,
        };
        const depth_image_memory = try vk_ctx.device.allocateMemory(&depth_image_memory_allocate_info, null);
        try vk_ctx.device.bindImageMemory(depth_image, depth_image_memory, 0);

        const depth_image_view_create_info = vk.ImageViewCreateInfo{
            .image = depth_image,
            .view_type = .@"2d",
            .format = depth_format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .depth_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const depth_image_view = try vk_ctx.device.createImageView(&depth_image_view_create_info, null);

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
            swap_images[n_swap_images] = try SwapImage.init(vk_ctx, image, surface_format.format, extent);
            n_swap_images += 1;
        }
        errdefer {
            for (swap_images) |si| si.deinit(vk_ctx);
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
            .depth_format = depth_format,
            .depth_image = depth_image,
            .depth_image_memory = depth_image_memory,
            .depth_image_view = depth_image_view,
        };
    }

    pub fn deinit(self: Swapchain, allocator: std.mem.Allocator, vk_ctx: *const VulkanContext) void {
        self.deinitExceptSwapchain(allocator, vk_ctx);
        vk_ctx.device.destroySwapchainKHR(self.handle, null);
    }

    fn deinitExceptSwapchain(self: Swapchain, allocator: std.mem.Allocator, vk_ctx: *const VulkanContext) void {
        for (self.swap_images) |si| {
            si.deinit(vk_ctx);
        }
        allocator.free(self.swap_images);
        vk_ctx.device.destroyImageView(self.depth_image_view, null);
        vk_ctx.device.destroyImage(self.depth_image, null);
        vk_ctx.device.freeMemory(self.depth_image_memory, null);
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

    vertex_ids: vk.Image,
    vertex_ids_view: vk.ImageView,
    vertex_ids_memory: vk.DeviceMemory,

    line_ids: vk.Image,
    line_ids_view: vk.ImageView,
    line_ids_memory: vk.DeviceMemory,

    surface_ids: vk.Image,
    surface_ids_view: vk.ImageView,
    surface_ids_memory: vk.DeviceMemory,

    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(vk_ctx: *const VulkanContext, image: vk.Image, format: vk.Format, extent: vk.Extent2D) !SwapImage {
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
        const image_view = try vk_ctx.device.createImageView(&image_view_create_info, null);
        errdefer vk_ctx.device.destroyImageView(image_view, null);

        const image_acquired = try vk_ctx.device.createSemaphore(&.{}, null);
        errdefer vk_ctx.device.destroySemaphore(image_acquired, null);

        const render_finished = try vk_ctx.device.createSemaphore(&.{}, null);
        errdefer vk_ctx.device.destroySemaphore(render_finished, null);

        const frame_fence = try vk_ctx.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer vk_ctx.device.destroyFence(frame_fence, null);

        const ids_format = vk.Format.r32g32_uint;
        const ids_image_info = vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = ids_format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .linear,
            .usage = .{ .transfer_src_bit = true, .color_attachment_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        };
        const vertex_ids = try vk_ctx.device.createImage(&ids_image_info, null);
        const line_ids = try vk_ctx.device.createImage(&ids_image_info, null);
        const surface_ids = try vk_ctx.device.createImage(&ids_image_info, null);

        const image_memory_requirements = vk_ctx.device.getImageMemoryRequirements(vertex_ids);
        const memory_type_index = try vk_ctx.findMemoryType(image_memory_requirements.memory_type_bits, .{ .device_local_bit = true });
        const ids_image_memory_allocate_info = vk.MemoryAllocateInfo{
            .allocation_size = image_memory_requirements.size,
            .memory_type_index = memory_type_index,
        };

        const vertex_ids_memory = try vk_ctx.device.allocateMemory(&ids_image_memory_allocate_info, null);
        const line_ids_memory = try vk_ctx.device.allocateMemory(&ids_image_memory_allocate_info, null);
        const surface_ids_memory = try vk_ctx.device.allocateMemory(&ids_image_memory_allocate_info, null);

        try vk_ctx.device.bindImageMemory(vertex_ids, vertex_ids_memory, 0);
        try vk_ctx.device.bindImageMemory(line_ids, line_ids_memory, 0);
        try vk_ctx.device.bindImageMemory(surface_ids, surface_ids_memory, 0);

        var ids_image_view_create_info = vk.ImageViewCreateInfo{
            .image = vertex_ids,
            .view_type = vk.ImageViewType.@"2d",
            .format = ids_format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };

        const vertex_ids_view = try vk_ctx.device.createImageView(&ids_image_view_create_info, null);

        ids_image_view_create_info.image = line_ids;
        const line_ids_view = try vk_ctx.device.createImageView(&ids_image_view_create_info, null);

        ids_image_view_create_info.image = surface_ids;
        const surface_ids_view = try vk_ctx.device.createImageView(&ids_image_view_create_info, null);

        return SwapImage{
            .image = image,
            .view = image_view,
            .vertex_ids = vertex_ids,
            .vertex_ids_view = vertex_ids_view,
            .vertex_ids_memory = vertex_ids_memory,
            .line_ids = line_ids,
            .line_ids_view = line_ids_view,
            .line_ids_memory = line_ids_memory,
            .surface_ids = surface_ids,
            .surface_ids_view = surface_ids_view,
            .surface_ids_memory = surface_ids_memory,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, vk_ctx: *const VulkanContext) void {
        self.waitForFence(&vk_ctx.device) catch return;

        vk_ctx.device.destroyImageView(self.view, null);

        vk_ctx.device.destroyImageView(self.vertex_ids_view, null);
        vk_ctx.device.destroyImage(self.vertex_ids, null);
        vk_ctx.device.freeMemory(self.vertex_ids_memory, null);

        vk_ctx.device.destroyImageView(self.line_ids_view, null);
        vk_ctx.device.destroyImage(self.line_ids, null);
        vk_ctx.device.freeMemory(self.line_ids_memory, null);

        vk_ctx.device.destroyImageView(self.surface_ids_view, null);
        vk_ctx.device.destroyImage(self.surface_ids, null);
        vk_ctx.device.freeMemory(self.surface_ids_memory, null);

        vk_ctx.device.destroySemaphore(self.image_acquired, null);
        vk_ctx.device.destroySemaphore(self.render_finished, null);
        vk_ctx.device.destroyFence(self.frame_fence, null);
    }

    fn waitForFence(self: SwapImage, device: *const VulkanContext.Device) !void {
        _ = try device.waitForFences(1, @ptrCast(&self.frame_fence), vk.TRUE, std.math.maxInt(u64));
    }
};

pub const MVPUniformBufferObject = struct {
    model: zm.Mat,
    view: zm.Mat,
    projection: zm.Mat,
};

pub const LineUniformBufferObject = struct {
    aspect_ratio: f32,
    line_thickness: f32,
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
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
        .{
            .binding = 0,
            .location = 2,
            .format = .r32_uint,
            .offset = @offsetOf(Vertex, "uid_lower"),
        },
        .{
            .binding = 0,
            .location = 3,
            .format = .r32_uint,
            .offset = @offsetOf(Vertex, "uid_upper"),
        },
    };

    pos: [3]f32,
    color: [3]f32,
    uid_lower: u32,
    uid_upper: u32,

    pub fn uid(self: Line) u64 {
        var uid_val: u64 = @as(u64, self.uid_upper);
        uid_val <<= 32;
        uid_val |= @as(u64, self.uid_lower);
        return uid_val;
    }

    pub fn format(self: Vertex, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Pos: ({d:3}, {d:3}, {d:3})", .{ self.pos[0], self.pos[1], self.pos[2] });
    }
};

pub const Line = struct {
    const binding_description = vk.VertexInputBindingDescription{
        .binding = 1,
        .stride = @sizeOf(Line),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 1,
            .location = 2,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Line, "posA"),
        },
        .{
            .binding = 1,
            .location = 3,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Line, "posB"),
        },
        .{
            .binding = 1,
            .location = 4,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Line, "colorA"),
        },
        .{
            .binding = 1,
            .location = 5,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Line, "colorB"),
        },
        .{
            .binding = 1,
            .location = 6,
            .format = .r8_uint,
            .offset = @offsetOf(Line, "up"),
        },
        .{
            .binding = 1,
            .location = 7,
            .format = .r8_uint,
            .offset = @offsetOf(Line, "left"),
        },
        .{
            .binding = 1,
            .location = 8,
            .format = .r8_uint,
            .offset = @offsetOf(Line, "edge"),
        },
        .{
            .binding = 1,
            .location = 9,
            .format = .r32_uint,
            .offset = @offsetOf(Line, "uid_lower"),
        },
        .{
            .binding = 1,
            .location = 10,
            .format = .r32_uint,
            .offset = @offsetOf(Line, "uid_upper"),
        },
    };

    posA: [3]f32,
    posB: [3]f32,
    colorA: [3]f32,
    colorB: [3]f32,
    up: bool,
    left: bool,
    edge: bool,
    uid_lower: u32,
    uid_upper: u32,

    pub fn uid(self: Line) u64 {
        var uid_val: u64 = @as(u64, self.uid_upper);
        uid_val <<= 32;
        uid_val |= @as(u64, self.uid_lower);
        return uid_val;
    }
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
