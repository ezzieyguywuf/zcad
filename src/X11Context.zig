const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});
const wnd = @import("WindowingContext.zig");

pub fn X11Context(comptime T: type) type {
    return struct {
        wnd_ctx: *wnd.WindowingContext(T),
        display: *c.Display,
        window: c.Window,

        pub fn init(self: *X11Context(T), wnd_ctx: *wnd.WindowingContext(T)) !void {
            self.wnd_ctx = wnd_ctx;
            self.display = c.XOpenDisplay("") orelse return error.CannotOpenX11Display;

            const screen_id = c.DefaultScreen(self.display);
            self.window = c.XCreateSimpleWindow(
                self.display,
                c.RootWindow(self.display, screen_id),
                10,
                10,
                @intCast(wnd_ctx.width),
                @intCast(wnd_ctx.height),
                1,
                c.BlackPixel(self.display, screen_id),
                c.WhitePixel(self.display, screen_id),
            );
            _ = c.XSelectInput(self.display, self.window, c.ExposureMask | c.KeyPressMask);
            _ = c.XMapWindow(self.display, self.window);

            return;
        }

        pub fn deinit(self: *const X11Context) void {
            _ = c.XCloseDisplay(self.display);
        }

        pub fn run(self: *const X11Context) bool {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(self.display, &event);
            if (event.type == c.KeyPress) {
                return false;
            }

            return false;
        }
    };
}
