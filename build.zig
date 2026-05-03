// Copyright (c) 2025 Egor Lazarchuk
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const args: Args = .init(b);

    const miniz_mod = create_miniz_module(b, target, optimize);

    const imports: []const std.Build.Module.Import = &.{.{ .name = "miniz", .module = miniz_mod }};
    create_exe(b, target, optimize, &args, "replay", "src/replay.zig", imports);
    create_exe(b, target, optimize, &args, "print_entries", "src/print_entries.zig", imports);

    create_exe(b, target, optimize, &args, "gen_vk", "src/gen_vk.zig", &.{});
    create_exe(b, target, optimize, &args, "gen_vk_utils", "src/gen_vk_utils.zig", &.{});
    create_exe(b, target, optimize, &args, "gen_vk_validation", "src/gen_vk_validation.zig", &.{});

    create_lib(b, target, optimize, &args, "fornax_capture_layer", "src/fornax_capture_layer.zig");
}

const Args = struct {
    use_llvm: bool,
    profile: bool,
    no_driver: bool,
    no_validation: bool,
    disable_shader_cache: bool,
    shader_cache_dir: ?[]const u8,
    custom_mesa_icd: bool,

    const Self = @This();
    fn init(b: *std.Build) Self {
        return .{
            .use_llvm = b.option(bool, "use_llvm", "Use LLVM backend") != null,
            .profile = b.option(bool, "profile", "Enable profiling") != null,
            .no_driver = b.option(bool, "no_driver", "Replace driver calls with stubs") != null,
            .no_validation = b.option(bool, "no_validation", "Disable vulkan object validation") != null,
            .disable_shader_cache = b.option(
                bool,
                "disable_shader_cache",
                "Set MESA_SHADER_CACHE_DISABLE",
            ) != null,
            .shader_cache_dir = b.option(
                []const u8,
                "shader_cache_dir",
                "Set MESA_SHADER_CACHE_DIR",
            ),
            .custom_mesa_icd = b.option(
                bool,
                "custom_mesa_icd",
                "Use custom_mesa_icd.json to overwrite the driver to use",
            ) != null,
        };
    }
};

fn create_exe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    args: *const Args,
    comptime name: []const u8,
    source_file: []const u8,
    imports: []const std.Build.Module.Import,
) void {
    const build_options = b.addOptions();
    build_options.addOption(bool, "profile", args.profile);
    build_options.addOption(bool, "no_driver", args.no_driver);
    build_options.addOption(bool, "no_validation", args.no_validation);

    const root_mudule = b.createModule(.{
        .root_source_file = b.path(source_file),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    root_mudule.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_mudule,
        .use_llvm = args.use_llvm,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    const unit_tests = b.addTest(.{
        .name = name ++ "_unit_test",
        .root_module = root_mudule,
        .filters = b.args orelse &.{},
        .use_llvm = args.use_llvm,
    });
    const unit_tests_install_step = b.addInstallArtifact(unit_tests, .{});

    const build_step = b.step(name ++ "_build", "Build the `" ++ name ++ "` binary");
    build_step.dependOn(&install_step.step);

    const run_cmd = b.addRunArtifact(exe);
    if (args.disable_shader_cache) run_cmd.setEnvironmentVariable("MESA_SHADER_CACHE_DISABLE", "1");
    if (args.shader_cache_dir) |scd| run_cmd.setEnvironmentVariable("MESA_SHADER_CACHE_DIR", scd);
    if (args.custom_mesa_icd) run_cmd.setEnvironmentVariable("VK_DRIVER_FILES", "custom_mesa_icd.json");
    if (b.args) |a| run_cmd.addArgs(a);
    run_cmd.step.dependOn(&install_step.step);
    const run_step = b.step(name ++ "_run", "Run the `" ++ name ++ "` binary");
    run_step.dependOn(&run_cmd.step);

    const unit_tests_run_cmd = b.addRunArtifact(unit_tests);
    unit_tests_run_cmd.step.dependOn(&unit_tests_install_step.step);
    const test_step = b.step(name ++ "_test", "Run `" ++ name ++ "` unit tests");
    test_step.dependOn(&unit_tests_run_cmd.step);
}

fn create_lib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    args: *const Args,
    comptime name: []const u8,
    source_file: []const u8,
) void {
    const build_options = b.addOptions();
    build_options.addOption(bool, "profile", args.profile);
    build_options.addOption(bool, "no_driver", args.no_driver);
    build_options.addOption(bool, "no_validation", args.no_validation);

    const root_mudule = b.createModule(.{
        .root_source_file = b.path(source_file),
        .target = target,
        .optimize = optimize,
    });
    root_mudule.addOptions("build_options", build_options);

    const exe = b.addLibrary(.{
        .linkage = .dynamic,
        .name = name,
        .root_module = root_mudule,
        // Broken without llvm
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    const build_step = b.step(name ++ "_build", "Build the `" ++ name ++ "` binary");
    build_step.dependOn(&install_step.step);
}

pub fn create_miniz_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const miniz_config_header = b.addConfigHeader(
        .{ .include_path = "miniz_export.h" },
        .{ .MINIZ_EXPORT = void{} },
    );
    const miniz_header = b.addWriteFiles().add("translate_miniz.h",
        \\#define MINIZ_NO_STDIO
        \\#define MINIZ_NO_MALLOC
        \\#define MINIZ_NO_ARCHIVE_APIS
        \\#define MINIZ_NO_DEFLATE_APIS
        \\#define MINIZ_LITTLE_ENDIAN 1
        \\#define MINIZ_HAS_64BIT_REGISTERS 1
        \\#include "miniz.h"
    );
    const miniz_translate = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = miniz_header,
    });
    miniz_translate.addConfigHeader(miniz_config_header);
    miniz_translate.addIncludePath(b.path("thirdparty/miniz"));
    const miniz_mod = b.createModule(.{
        .root_source_file = miniz_translate.getOutput(),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    miniz_mod.addConfigHeader(miniz_config_header);
    miniz_mod.addIncludePath(b.path("thirdparty/miniz"));
    miniz_mod.addCMacro("MINIZ_NO_STDIO", "");
    miniz_mod.addCMacro("MINIZ_NO_MALLOC", "");
    miniz_mod.addCMacro("MINIZ_NO_ARCHIVE_APIS", "");
    miniz_mod.addCMacro("MINIZ_NO_DEFLATE_APIS", "");
    miniz_mod.addCMacro("MINIZ_LITTLE_ENDIAN", "1");
    miniz_mod.addCMacro("MINIZ_HAS_64BIT_REGISTERS", "1");
    miniz_mod.addCSourceFiles(.{
        .files = &.{
            "thirdparty/miniz/miniz.c",
            "thirdparty/miniz/miniz_tdef.c",
            "thirdparty/miniz/miniz_tinfl.c",
        },
    });
    return miniz_mod;
}
