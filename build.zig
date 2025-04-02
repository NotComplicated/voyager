const std = @import("std");

const name = "voyager";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const console = b.option(bool, "console", "Enable console mode") orelse (optimize == .Debug);

    const clay = b.dependency("clay_zig", .{
        .target = target,
        .optimize = optimize,
        .raylib_renderer = true,
    });
    const datetime = b.dependency("datetime", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
    });

    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("dwmapi");
        exe.linkSystemLibrary("secur32");
        exe.subsystem = if (console) .Console else .Windows;
    }

    exe.root_module.addImport("clay", clay.module("clay"));
    exe.root_module.addImport("raylib", clay.module("raylib"));
    exe.root_module.addImport("datetime", datetime.module("datetime"));

    for (raylib_config) |config| clay.artifact("raylib").root_module.addCMacro(config[0], config[1]);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run " ++ name);
    run_step.dependOn(&run_cmd.step);

    b.installArtifact(exe);
}

const raylib_config = [_][2][]const u8{
    .{ "EXTERNAL_CONFIG_FLAGS", "1" },
    .{ "SUPPORT_MODULE_RSHAPES", "1" },
    .{ "SUPPORT_MODULE_RTEXTURES", "1" },
    .{ "SUPPORT_MODULE_RTEXT", "1" },
    .{ "SUPPORT_MODULE_RAUDIO", "1" },
    .{ "SUPPORT_GESTURES_SYSTEM", "1" },
    .{ "SUPPORT_RPRAND_GENERATOR", "1" },
    .{ "SUPPORT_MOUSE_GESTURES", "1" },
    .{ "SUPPORT_SSH_KEYBOARD_RPI", "1" },
    .{ "SUPPORT_WINMM_HIGHRES_TIMER", "1" },
    .{ "SUPPORT_PARTIALBUSY_WAIT_LOOP", "1" },
    .{ "SUPPORT_COMPRESSION_API", "1" },
    .{ "SUPPORT_AUTOMATION_EVENTS", "1" },
    .{ "SUPPORT_CLIPBOARD_IMAGE", "1" },
    .{ "STBI_REQUIRED", "1" },
    .{ "SUPPORT_FILEFORMAT_BMP", "1" },
    .{ "SUPPORT_FILEFORMAT_PNG", "1" },
    .{ "SUPPORT_FILEFORMAT_JPG", "1" },
    .{ "MAX_FILEPATH_CAPACITY", "8192" },
    .{ "MAX_FILEPATH_LENGTH", "4096" },
    .{ "MAX_KEYBOARD_KEYS", "512" },
    .{ "MAX_MOUSE_BUTTONS", "8" },
    .{ "MAX_GAMEPADS", "4" },
    .{ "MAX_GAMEPAD_AXIS", "8" },
    .{ "MAX_GAMEPAD_BUTTONS", "32" },
    .{ "MAX_GAMEPAD_VIBRATION_TIME", "2.0f" },
    .{ "MAX_TOUCH_POINTS", "8" },
    .{ "MAX_KEY_PRESSED_QUEUE", "16" },
    .{ "MAX_CHAR_PRESSED_QUEUE", "16" },
    .{ "MAX_DECOMPRESSION_SIZE", "64" },
    .{ "MAX_AUTOMATION_EVENTS", "16384" },
    .{ "RLGL_ENABLE_OPENGL_DEBUG_CONTEXT", "1" },
    .{ "RL_SUPPORT_MESH_GPU_SKINNING", "1" },
    .{ "RL_DEFAULT_BATCH_BUFFERS", "1" },
    .{ "RL_DEFAULT_BATCH_DRAWCALLS", "256" },
    .{ "RL_DEFAULT_BATCH_MAX_TEXTURE_UNITS", "4" },
    .{ "RL_MAX_MATRIX_STACK_SIZE", "32" },
    .{ "RL_MAX_SHADER_LOCATIONS", "32" },
    .{ "RL_CULL_DISTANCE_NEAR", "0.01" },
    .{ "RL_CULL_DISTANCE_FAR", "1000.0" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_POSITION", "0" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_TEXCOORD", "1" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_NORMAL", "2" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_COLOR", "3" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_TANGENT", "4" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_TEXCOORD2", "5" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_INDICES", "6" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_BONEIDS", "7" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_BONEWEIGHTS", "8" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_LOCATION_INSTANCE_TX", "9" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_NAME_POSITION", "\"vertexPosition\"" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_NAME_TEXCOORD", "\"vertexTexCoord\"" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_NAME_NORMAL", "\"vertexNormal\"" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_NAME_COLOR", "\"vertexColor\"" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_NAME_TANGENT", "\"vertexTangent\"" },
    .{ "RL_DEFAULT_SHADER_ATTRIB_NAME_TEXCOORD2", "\"vertexTexCoord2\"" },
    .{ "RL_DEFAULT_SHADER_UNIFORM_NAME_MVP", "\"mvp\"" },
    .{ "RL_DEFAULT_SHADER_UNIFORM_NAME_VIEW", "\"matView\"" },
    .{ "RL_DEFAULT_SHADER_UNIFORM_NAME_PROJECTION", "\"matProjection\"" },
    .{ "RL_DEFAULT_SHADER_UNIFORM_NAME_MODEL", "\"matModel\"" },
    .{ "RL_DEFAULT_SHADER_UNIFORM_NAME_NORMAL", "\"matNormal\"" },
    .{ "RL_DEFAULT_SHADER_UNIFORM_NAME_COLOR", "\"colDiffuse\"" },
    .{ "RL_DEFAULT_SHADER_SAMPLER2D_NAME_TEXTURE0", "\"texture0\"" },
    .{ "RL_DEFAULT_SHADER_SAMPLER2D_NAME_TEXTURE1", "\"texture1\"" },
    .{ "RL_DEFAULT_SHADER_SAMPLER2D_NAME_TEXTURE2", "\"texture2\"" },
    .{ "SUPPORT_QUADS_DRAW_MODE", "1" },
    .{ "SPLINE_SEGMENT_DIVISIONS", "24" },
    .{ "SUPPORT_FILEFORMAT_PNG", "1" },
    .{ "SUPPORT_FILEFORMAT_BMP", "1" },
    .{ "SUPPORT_FILEFORMAT_JPG", "1" },
    .{ "SUPPORT_FILEFORMAT_GIF", "1" },
    .{ "SUPPORT_IMAGE_EXPORT", "1" },
    .{ "SUPPORT_IMAGE_GENERATION", "1" },
    .{ "SUPPORT_IMAGE_MANIPULATION", "1" },
    .{ "SUPPORT_FILEFORMAT_TTF", "1" },
    .{ "SUPPORT_FILEFORMAT_FNT", "1" },
    .{ "SUPPORT_TEXT_MANIPULATION", "1" },
    .{ "SUPPORT_FONT_ATLAS_WHITE_REC", "1" },
    .{ "MAX_TEXT_BUFFER_LENGTH", "1024" },
    .{ "MAX_TEXTSPLIT_COUNT", "128" },
    .{ "SUPPORT_FILEFORMAT_OBJ", "1" },
    .{ "SUPPORT_FILEFORMAT_MTL", "1" },
    .{ "SUPPORT_FILEFORMAT_IQM", "1" },
    .{ "SUPPORT_FILEFORMAT_GLTF", "1" },
    .{ "SUPPORT_FILEFORMAT_VOX", "1" },
    .{ "SUPPORT_FILEFORMAT_M3D", "1" },
    .{ "SUPPORT_MESH_GENERATION", "1" },
    .{ "MAX_MATERIAL_MAPS", "12" },
    .{ "MAX_MESH_VERTEX_BUFFERS", "9" },
    .{ "SUPPORT_FILEFORMAT_WAV", "1" },
    .{ "SUPPORT_FILEFORMAT_OGG", "1" },
    .{ "SUPPORT_FILEFORMAT_MP3", "1" },
    .{ "SUPPORT_FILEFORMAT_QOA", "1" },
    .{ "SUPPORT_FILEFORMAT_XM", "1" },
    .{ "SUPPORT_FILEFORMAT_MOD", "1" },
    .{ "AUDIO_DEVICE_FORMAT", "ma_format_f32" },
    .{ "AUDIO_DEVICE_CHANNELS", "2" },
    .{ "AUDIO_DEVICE_SAMPLE_RATE", "0" },
    .{ "MAX_AUDIO_BUFFER_POOL_CHANNELS", "16" },
    .{ "SUPPORT_STANDARD_FILEIO", "1" },
    .{ "SUPPORT_TRACELOG", "1" },
    .{ "SUPPORT_TRACELOG_DEBUG", "1" },
    .{ "MAX_TRACELOG_MSG_LENGTH", "256" },
};
