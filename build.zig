const std = @import("std");

const Scanner = @import("zig_wayland").Scanner;

pub fn build(b: *std.Build) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filter = b.option([]const u8, "test-filter", "The test filter");

    const dependencies = Dependencies.init(b);

    const exe = b.addExecutable(.{
        .name = "zcad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    setupExecutable(exe, &dependencies);
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

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    setupExecutable(exe_unit_tests, &dependencies);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    if (test_filter) |filter| {
        run_exe_unit_tests.addArg("--test-filter");
        run_exe_unit_tests.addArg(filter);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    b.installArtifact(exe_unit_tests);
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

const Dependencies = struct {
    wayland: *std.Build.Module,
    vulkan: *std.Build.Module,
    zmath: *std.Build.Module,
    httpz: *std.Build.Module,

    fn init(b: *std.Build) Dependencies {
        const zmath_options = b.addOptions();
        zmath_options.addOption(bool, "enable_cross_platform_determinism", false);

        const zmath_dep = b.dependency("zmath", .{});
        const zmath = b.createModule(.{
            .root_source_file = zmath_dep.path("src/root.zig"),
            .imports = &.{
                .{ .name = "zmath_options", .module = zmath_options.createModule() },
            },
        });
        const vulkan = b.dependency("vulkan_zig", .{
            .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
        }).module("vulkan-zig");
        const httpz = b.dependency("httpz", .{}).module("httpz");

        const scanner = Scanner.create(b, .{});
        scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
        scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
        scanner.generate("wl_compositor", 1);
        scanner.generate("wl_seat", 7);
        scanner.generate("xdg_wm_base", 1);
        scanner.generate("zxdg_decoration_manager_v1", 1);
        const wayland = b.createModule(.{ .root_source_file = scanner.result });

        return .{
            .wayland = wayland,
            .vulkan = vulkan,
            .zmath = zmath,
            .httpz = httpz,
        };
    }
};

fn setupExecutable(exe: *std.Build.Step.Compile, d: *const Dependencies) void {
    exe.root_module.addImport("wayland", d.wayland);
    exe.root_module.addImport("vulkan", d.vulkan);
    exe.root_module.addImport("zmath", d.zmath);
    exe.root_module.addImport("httpz", d.httpz);

    // TODO: do this.
    // if (b.systemIntegrationOption("zcad", .{})) {
    exe.linkSystemLibrary("vulkan");
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("x11");

    exe.linkLibC();
    return;
}
