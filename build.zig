const std = @import("std");
const rlz = @import("raylib-zig");

const name = "voyager";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const console = b.option(bool, "console", "Enable console mode") orelse false;

    const clay = b.dependency("clay", .{
        .target = target,
        .optimize = optimize,
        .raylib_renderer = true,
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
    });

    if (target.result.os.tag == .windows) {
        exe.subsystem = if (console) .Console else .Windows;
    }

    exe.root_module.addImport("raylib", clay.module("raylib"));
    exe.root_module.addImport("clay", clay.module("clay"));

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run " ++ name);
    run_step.dependOn(&run_cmd.step);

    b.installArtifact(exe);
}
