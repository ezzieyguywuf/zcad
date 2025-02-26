const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

pub const X11Context = struct {
    display: *c.Display,
    window: c.Window,

    pub fn init(width: c_uint, height: c_uint) !X11Context {
        const display = c.XOpenDisplay("");
        if (display == null) {
            return error.CannotOpenX11Display;
        }

        const screen_id = c.DefaultScreen(display);
        const window = c.XCreateSimpleWindow(
            display,
            c.RootWindow(display, screen_id),
            10,
            10,
            width,
            height,
            1,
            c.BlackPixel(display, screen_id),
            c.WhitePixel(display, screen_id),
        );
        _ = c.XSelectInput(display, window, c.ExposureMask | c.KeyPressMask);
        _ = c.XMapWindow(display, window);

        return X11Context{
            .display = display.?,
            .window = window,
        };
    }

    pub fn deinit(self: *const X11Context) void {
        _ = c.XCloseDisplay(self.display);
    }

    pub fn tick(self: *const X11Context) bool {
        var event: c.XEvent = undefined;
        _ = c.XNextEvent(self.display, &event);
        if (event.type == c.KeyPress) {
            return false;
        }

        return false;
    }
};
