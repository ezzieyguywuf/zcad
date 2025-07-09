const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;
const wnd = @import("WindowingContext.zig");

const c = @cImport({
    @cInclude("linux/input-event-codes.h");
});

const WaylandGlobals = struct {
    compositor: ?*wl.Compositor = null,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    wm_base: ?*xdg.WmBase = null,
    zxdg_decoration_manager_v1: ?*zxdg.DecorationManagerV1 = null,
};

pub fn WaylandContext(comptime T: type) type {
    return struct {
        wnd_ctx: *wnd.WindowingContext(T),

        wl_display: *wl.Display,
        wl_registry: *wl.Registry,
        wl_seat: *wl.Seat,
        wl_surface: *wl.Surface,
        wl_pointer: *wl.Pointer,
        xdg_surface: *xdg.Surface,
        xdg_toplevel: *xdg.Toplevel,
        zxdg_toplevel_decoration_v1: ?*zxdg.ToplevelDecorationV1 = null,
        compositor: *wl.Compositor,
        wm_base: *xdg.WmBase,

        input_state_in_flight: wnd.InputState,

        pub fn init(self: *WaylandContext(T), wnd_ctx: *wnd.WindowingContext(T)) !void {
            const display = try wl.Display.connect(null);
            const registry = try display.getRegistry();

            var wl_globals = WaylandGlobals{};
            registry.setListener(*WaylandGlobals, globalRegistryListener, &wl_globals);
            if (display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

            const wl_compositor = wl_globals.compositor orelse return error.NoWlCompositor;
            const wl_seat = wl_globals.seat orelse return error.NoSeat;
            const wm_base = wl_globals.wm_base orelse return error.NoXdgWmBase;
            const zxdg_decoration_manager_v1 = wl_globals.zxdg_decoration_manager_v1 orelse null;

            wl_seat.setListener(*WaylandGlobals, seatListener, &wl_globals);
            if (display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

            const surface = try wl_compositor.createSurface();
            const xdg_surface = try wm_base.getXdgSurface(surface);
            const xdg_toplevel = try xdg_surface.getToplevel();
            xdg_toplevel.setTitle("zcad vulkan");

            self.* = .{
                .wnd_ctx = wnd_ctx,
                .wl_display = display,
                .wl_registry = registry,
                .wl_pointer = wl_globals.pointer orelse return error.NoWlPointer,
                .compositor = wl_compositor,
                .wm_base = wm_base,
                .wl_seat = wl_seat,
                .wl_surface = surface,
                .xdg_surface = xdg_surface,
                .xdg_toplevel = xdg_toplevel,
                .input_state_in_flight = .{},
            };

            self.wl_pointer.setListener(*WaylandContext(T), pointerListener, self);
            if (display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

            self.xdg_toplevel.setListener(*WaylandContext(T), xdgTopLevelListener, self);
            if (self.wl_display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

            self.xdg_surface.setListener(*WaylandContext(T), xdgSurfaceListener, self);
            self.wl_surface.commit();

            self.wm_base.setListener(*WaylandContext(T), xdgWmBaseListener, self);

            if (zxdg_decoration_manager_v1 != null) {
                const zxdg_toplevel_decoration_v1 = try zxdg_decoration_manager_v1.?.getToplevelDecoration(self.xdg_toplevel);
                self.zxdg_toplevel_decoration_v1 = zxdg_toplevel_decoration_v1;
                zxdg_toplevel_decoration_v1.setListener(*WaylandContext(T), zxdgToplevelDecorationV1Listener, self);
            }

            if (self.wl_display.roundtrip() != .SUCCESS) return error.RoundTripFailed;
        }

        pub fn deinit(self: *WaylandContext(T)) void {
            self.wl_surface.destroy();
            self.xdg_surface.destroy();
            self.xdg_toplevel.destroy();
        }

        pub fn run(self: *WaylandContext(T)) !bool {
            _ = self.wl_display.dispatchPending();
            if (self.wl_display.roundtrip() != .SUCCESS) return error.RoundTripFailed;
            if (self.wnd_ctx.width == 0 or self.wnd_ctx.height == 0) {
                // std.debug.print("Current dimensions: width -> {d}, height -> {d}\n", .{ self.wnd_ctx.width, self.wnd_ctx.height });
                // std.Thread.sleep(2000000);
                // smthn smthn poll events?
                // std.debug.print("Done with roundtrip\n", .{});
                return false;
            }
            if (self.wnd_ctx.should_resize and self.wnd_ctx.resizing_done) {
                self.wnd_ctx.ready_to_resize = false;
                self.wnd_ctx.should_resize = false;
                self.wnd_ctx.resizing_done = false;

                self.wl_surface.commit();
            }

            return true;
        }

        fn xdgWmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *WaylandContext(T)) void {
            switch (event) {
                .ping => |ping| wm_base.pong(ping.serial),
            }
        }

        fn globalRegistryListener(wl_registry: *wl.Registry, event: wl.Registry.Event, globals: *WaylandGlobals) void {
            switch (event) {
                .global => |global| {
                    if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                        globals.compositor = wl_registry.bind(global.name, wl.Compositor, 1) catch return;
                    } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                        globals.seat = wl_registry.bind(global.name, wl.Seat, 5) catch return;
                    } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                        globals.wm_base = wl_registry.bind(global.name, xdg.WmBase, 1) catch return;
                    } else if (std.mem.orderZ(u8, global.interface, zxdg.DecorationManagerV1.interface.name) == .eq) {
                        globals.zxdg_decoration_manager_v1 = wl_registry.bind(global.name, zxdg.DecorationManagerV1, 1) catch return;
                    }
                },
                .global_remove => {},
            }
        }

        fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, globals: *WaylandGlobals) void {
            switch (event) {
                .capabilities => |data| {
                    std.debug.print("Seat capabilities\n  Pointer {}\n  Keyboard {}\n  Touch {}\n", .{
                        data.capabilities.pointer,
                        data.capabilities.keyboard,
                        data.capabilities.touch,
                    });
                    if (data.capabilities.pointer) {
                        if (seat.getPointer()) |pointer| {
                            globals.pointer = pointer;
                        } else |err| switch (err) {
                            else => std.debug.print("Error getting pointer: {any}\n", .{err}),
                        }
                    }
                },
                .name => |data| {
                    std.debug.print("Seat name: {s}\n", .{data.name});
                },
            }
        }

        fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, ctx: *WaylandContext(T)) void {
            switch (event) {
                // .enter => {
                //     std.debug.print("pointer enter\n", .{});
                // },
                // .leave => {
                //     std.debug.print("pointer leave\n", .{});
                // },
                .button => |button| {
                    const state = switch (button.state) {
                        wl.Pointer.ButtonState.pressed => true,
                        wl.Pointer.ButtonState.released => false,
                        else => false,
                    };
                    switch (button.button) {
                        c.BTN_LEFT => {
                            ctx.input_state_in_flight.left_button = state;
                            ctx.input_state_in_flight.left_button_serial = button.serial;
                        },
                        c.BTN_RIGHT => ctx.input_state_in_flight.right_button = state,
                        c.BTN_MIDDLE => ctx.input_state_in_flight.middle_button = state,
                        else => std.debug.print("unrecognized button {d}, state {s}\n", .{ button.button, if (state) "pressed" else "released" }),
                    }
                },
                .axis => |axis| {
                    switch (axis.axis) {
                        .vertical_scroll => ctx.input_state_in_flight.vertical_scroll += axis.value.toDouble(),
                        .horizontal_scroll => ctx.input_state_in_flight.horizontal_scroll += axis.value.toDouble(),
                        else => std.debug.print("unrecognized axis: {any}\n", .{axis}),
                    }
                },
                .motion => |motion| {
                    ctx.input_state_in_flight.pointer_x = motion.surface_x.toDouble();
                    ctx.input_state_in_flight.pointer_y = motion.surface_y.toDouble();
                },
                .frame => {
                    const window_moving: bool = ctx.input_state_in_flight.window_moving;
                    // std.debug.print("FULL FRAME, window_moving: {any}, x: {d:3} y: {d:3}\n", .{
                    //     window_moving
                    //     ctx.input_state_in_flight.pointer_x,
                    //     ctx.input_state_in_flight.pointer_y,
                    // });
                    const x = ctx.input_state_in_flight.pointer_x;
                    const y = ctx.input_state_in_flight.pointer_y;
                    const drag_size: f64 = 15;
                    const right_edge = @as(f64, @floatFromInt(ctx.wnd_ctx.width)) - drag_size;
                    const bottom_edge = @as(f64, @floatFromInt(ctx.wnd_ctx.height)) - drag_size;
                    if (window_moving and ctx.input_state_in_flight.left_button == false) {
                        ctx.input_state_in_flight.window_moving = false;
                    }
                    if (ctx.input_state_in_flight.window_resizing and ctx.input_state_in_flight.left_button == false) {
                        ctx.input_state_in_flight.window_resizing = false;
                    }
                    if (x > drag_size and y <= 15 and x < right_edge) {
                        ctx.input_state_in_flight.window_moving = true;
                        ctx.xdg_toplevel.move(
                            ctx.wl_seat,
                            ctx.input_state_in_flight.left_button_serial,
                        );
                    }
                    if (!window_moving) {
                        if (x < drag_size and y <= drag_size) {
                            ctx.input_state_in_flight.window_resizing = true;
                            ctx.xdg_toplevel.resize(
                                ctx.wl_seat,
                                ctx.input_state_in_flight.left_button_serial,
                                .top_left,
                            );
                        }
                        if (ctx.input_state_in_flight.left_button and x > right_edge and y <= drag_size) {
                            ctx.input_state_in_flight.should_close = true;
                        }
                        if (x > right_edge and y > bottom_edge) {
                            ctx.input_state_in_flight.window_resizing = true;
                            ctx.xdg_toplevel.resize(
                                ctx.wl_seat,
                                ctx.input_state_in_flight.left_button_serial,
                                .bottom_right,
                            );
                        }
                        if (x < drag_size and y > bottom_edge) {
                            ctx.input_state_in_flight.window_resizing = true;
                            ctx.xdg_toplevel.resize(
                                ctx.wl_seat,
                                ctx.input_state_in_flight.left_button_serial,
                                .bottom_left,
                            );
                        }

                        if (x < drag_size and y < bottom_edge and y > drag_size) {
                            ctx.input_state_in_flight.window_resizing = true;
                            ctx.xdg_toplevel.resize(
                                ctx.wl_seat,
                                ctx.input_state_in_flight.left_button_serial,
                                .left,
                            );
                        }
                        if (x > right_edge and y < bottom_edge and y > drag_size) {
                            ctx.input_state_in_flight.window_resizing = true;
                            ctx.xdg_toplevel.resize(
                                ctx.wl_seat,
                                ctx.input_state_in_flight.left_button_serial,
                                .right,
                            );
                        }
                        if (x > drag_size and x < right_edge and y > bottom_edge) {
                            ctx.input_state_in_flight.window_resizing = true;
                            ctx.xdg_toplevel.resize(
                                ctx.wl_seat,
                                ctx.input_state_in_flight.left_button_serial,
                                .bottom,
                            );
                        }
                    }
                    try ctx.wnd_ctx.callback(ctx.wnd_ctx.t, ctx.input_state_in_flight);
                    ctx.input_state_in_flight.vertical_scroll = 0;
                    ctx.input_state_in_flight.horizontal_scroll = 0;
                },
                else => {},
            }
        }

        fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, ctx: *WaylandContext(T)) void {
            switch (event) {
                .configure => |configure| {
                    ctx.wl_surface.commit();
                    if (ctx.wnd_ctx.should_resize) {
                        ctx.wnd_ctx.ready_to_resize = true;
                    }
                    xdg_surface.ackConfigure(configure.serial);
                },
            }
        }

        fn xdgTopLevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, ctx: *WaylandContext(T)) void {
            switch (event) {
                .configure => |conf| {
                    if (conf.width > 0 and conf.height > 0) {
                        ctx.wnd_ctx.width = conf.width;
                        ctx.wnd_ctx.height = conf.height;
                        ctx.wnd_ctx.should_resize = true;
                    }
                },
                .close => ctx.wnd_ctx.should_exit = true,
            }
        }

        fn zxdgToplevelDecorationV1Listener(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, _: *WaylandContext(T)) void {
            const mode = std.enums.tagName(zxdg.ToplevelDecorationV1.Mode, event.configure.mode);
            std.debug.print("Got decoration mode: {?s}\n", .{mode});
        }
    };
}
