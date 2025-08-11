const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var env_map = try std.process.getEnvMap(b.allocator);
    defer env_map.deinit();

    const miniz_config_header = b.addConfigHeader(
        .{ .include_path = "miniz_export.h" },
        .{ .MINIZ_EXPORT = void{} },
    );

    const exe = b.addExecutable(.{
        .name = "glacier",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    exe.addIncludePath(miniz_config_header.getOutput());
    exe.addIncludePath(b.path("thirdparty/volk"));
    exe.addIncludePath(b.path("thirdparty/miniz"));
    exe.addIncludePath(.{ .cwd_relative = env_map.get("VULKAN_INCLUDE_PATH").? });
    exe.addCSourceFile(.{ .file = b.path("thirdparty/volk/volk.c") });
    exe.addConfigHeader(miniz_config_header);
    exe.addCSourceFiles(.{
        .files = &.{
            "thirdparty/miniz/miniz.c",
            "thirdparty/miniz/miniz_tdef.c",
            "thirdparty/miniz/miniz_tinfl.c",
            "thirdparty/miniz/miniz_zip.c",
        },
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
