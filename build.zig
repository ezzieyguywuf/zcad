const std = @import("std");

const Scanner = @import("zig-wayland").Scanner;

pub fn build(b: *std.Build) void {
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

    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const vert_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const vert_spv = vert_cmd.addOutputFileArg("vert.spv");
    vert_cmd.addFileArg(b.path("shaders/triangle.vert"));
    exe.root_module.addAnonymousImport("vertex_shader", .{
        .root_source_file = vert_spv,
    });

    const frag_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const frag_spv = frag_cmd.addOutputFileArg("frag.spv");
    frag_cmd.addFileArg(b.path("shaders/triangle.frag"));
    exe.root_module.addAnonymousImport("fragment_shader", .{
        .root_source_file = frag_spv,
    });

    const circle_vert_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const circle_vert_spv = circle_vert_cmd.addOutputFileArg("circle_vert.spv");
    circle_vert_cmd.addFileArg(b.path("shaders/circle.vert"));
    exe.root_module.addAnonymousImport("circle_vertex_shader", .{
        .root_source_file = circle_vert_spv,
    });

    const circle_frag_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const circle_frag_spv = circle_frag_cmd.addOutputFileArg("circle_frag.spv");
    circle_frag_cmd.addFileArg(b.path("shaders/circle.frag"));
    exe.root_module.addAnonymousImport("circle_fragment_shader", .{
        .root_source_file = circle_frag_spv,
    });
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
