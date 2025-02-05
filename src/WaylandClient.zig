const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zxdg = wayland.client.zxdg;

const WaylandGlobals = struct {
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    zxdg_decoration_manager_v1: ?*zxdg.DecorationManagerV1 = null,
};

pub const WaylandContext = struct {
    should_exit: bool = false,
    should_resize: bool = false,
    ready_to_resize: bool = false,
    width: i32 = 0,
    height: i32 = 0,

    display: *wl.Display,
    registry: *wl.Registry,
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    xdg_toplevel: *xdg.Toplevel,
    zxdg_toplevel_decoration_v1: *zxdg.ToplevelDecorationV1,
    compositor: *wl.Compositor,
    wm_base: *xdg.WmBase,

    pub fn init(self: *WaylandContext, width: i32, height: i32) !void {
        const display = try wl.Display.connect(null);
        const registry = try display.getRegistry();

        var wl_globals = WaylandGlobals{};
        registry.setListener(*WaylandGlobals, globalRegistryListener, &wl_globals);
        if (display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

        const wl_compositor = wl_globals.compositor orelse return error.NoWlCompositor;
        const wm_base = wl_globals.wm_base orelse return error.NoXdgWmBase;
        const zxdg_decoration_manager_v1 = wl_globals.zxdg_decoration_manager_v1 orelse return error.NoZxdgDecorationManagerV1;

        const surface = try wl_compositor.createSurface();
        const xdg_surface = try wm_base.getXdgSurface(surface);
        const xdg_toplevel = try xdg_surface.getToplevel();
        const zxdg_toplevel_decoration_v1 = try zxdg_decoration_manager_v1.getToplevelDecoration(xdg_toplevel);

        self.display = display;
        self.registry = registry;
        self.compositor = wl_compositor;
        self.wm_base = wm_base;
        self.surface = surface;
        self.xdg_surface = xdg_surface;
        self.xdg_toplevel = xdg_toplevel;
        self.zxdg_toplevel_decoration_v1 = zxdg_toplevel_decoration_v1;
        self.width = width;
        self.height = height;
        xdg_toplevel.setListener(*WaylandContext, xdgTopLevelListener, self);
        if (self.display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

        self.xdg_surface.setListener(*WaylandContext, xdgSurfaceListener, self);
        self.surface.commit();

        zxdg_toplevel_decoration_v1.setListener(*WaylandContext, zxdgToplevelDecorationV1Listener, self);

        if (self.display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

        return;
    }

    pub fn deinit(self: *WaylandContext) void {
        self.surface.destroy();
        self.xdg_surface.destroy();
        self.xdg_toplevel.destroy();
    }

    pub fn run(self: *WaylandContext) !bool {
        _ = self.display.dispatchPending();
        if (self.display.roundtrip() != .SUCCESS) return error.RoundTripFailed;
        if (self.width == 0 or self.height == 0) {
            // std.debug.print("Current dimensions: width -> {d}, height -> {d}\n", .{ self.width, self.height });
            // std.Thread.sleep(2000000);
            // smthn smthn poll events?
            // std.debug.print("Done with roundtrip\n", .{});
            return false;
        }
        if (self.should_resize) {
            self.ready_to_resize = false;
            self.should_resize = false;

            self.surface.commit();
        }

        return true;
    }
};

fn globalRegistryListener(wl_registry: *wl.Registry, event: wl.Registry.Event, globals: *WaylandGlobals) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                globals.compositor = wl_registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                globals.wm_base = wl_registry.bind(global.name, xdg.WmBase, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zxdg.DecorationManagerV1.interface.name) == .eq) {
                globals.zxdg_decoration_manager_v1 = wl_registry.bind(global.name, zxdg.DecorationManagerV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, ctx: *WaylandContext) void {
    switch (event) {
        .configure => |configure| {
            ctx.surface.commit();
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
            if (conf.width > 0 and conf.height > 0) {
                ctx.width = conf.width;
                ctx.height = conf.height;
                ctx.should_resize = true;
            }
        },
        .close => ctx.should_exit = true,
    }
}

fn zxdgToplevelDecorationV1Listener(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, _: *WaylandContext) void {
    const mode = std.enums.tagName(zxdg.ToplevelDecorationV1.Mode, event.configure.mode);
    std.debug.print("Got decoration mode: {?s}\n", .{mode});
}
