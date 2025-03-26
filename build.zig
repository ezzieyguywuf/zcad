const std = @import("std");

const Scanner = @import("zig_wayland").Scanner;

pub fn build(b: *std.Build) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zmath = b.dependency("zmath", .{});
    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("xdg_wm_base", 1);
    scanner.generate("zxdg_decoration_manager_v1", 1);

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    const exe = b.addExecutable(.{
        .name = "zcad",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("wayland", wayland);
    exe.root_module.addImport("vulkan", vulkan);
    exe.root_module.addImport("zmath", zmath.module("root"));

    // TODO: do this.
    // if (b.systemIntegrationOption("zcad", .{})) {
    exe.linkSystemLibrary("vulkan");
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("x11");

    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    try addShader(allocator, b, exe, "vertex_shader", "shaders/triangle.vert");
    try addShader(allocator, b, exe, "fragment_shader", "shaders/triangle.frag");
    try addShader(allocator, b, exe, "circle_vertex_shader", "shaders/circle.vert");
    try addShader(allocator, b, exe, "circle_fragment_shader", "shaders/circle.frag");
    try addShader(allocator, b, exe, "line_vertex_shader", "shaders/line.vert");
    try addShader(allocator, b, exe, "line_fragment_shader", "shaders/line.frag");

    const test_filter = b.option([]const u8, "test-filter", "Filter for test");
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .filter = test_filter,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn addShader(
    allocator: std.mem.Allocator,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    import_name: []const u8,
    path: []const u8,
) !void {
    const cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const output_file_name = try std.fmt.allocPrint(allocator, "{s}.spv", .{import_name});
    defer allocator.free(output_file_name);
    const spv = cmd.addOutputFileArg(output_file_name);
    cmd.addFileArg(b.path(path));
    exe.root_module.addAnonymousImport(import_name, .{
        .root_source_file = spv,
    });
}
