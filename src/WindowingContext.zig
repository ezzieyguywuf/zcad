const wl = @import("WaylandContext.zig");
const x11 = @import("X11Context.zig");

pub const WindowingType = enum {
    xlib,
    wayland,
};

pub const InputState = packed struct {
    left_button: bool = false,
    left_button_serial: u32 = 0,
    middle_button: bool = false,
    right_button: bool = false,
    vertical_scroll: f64 = 0,
    horizontal_scroll: f64 = 0,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    window_moving: bool = false,
    window_resizing: bool = false,
    should_close: bool = false,
};

pub fn WindowingContext(comptime T: type) type {
    const CallbackType = *const fn (t: T, input_state: InputState) error{}!void;

    return struct {
        callback: CallbackType,
        t: T,
        width: i32,
        height: i32,
        should_exit: bool,
        should_resize: bool,
        ready_to_resize: bool,
        resizing_done: bool,

        pub fn init(t: T, callback: CallbackType, width: i32, height: i32) WindowingContext(T) {
            return WindowingContext(T){
                .t = t,
                .callback = callback,
                .width = width,
                .height = height,
                .should_exit = false,
                .should_resize = false,
                .ready_to_resize = false,
                .resizing_done = false,
            };
        }
    };
}
