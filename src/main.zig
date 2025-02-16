const builtin = @import("builtin");
const debug = builtin.mode == .Debug;

const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const enums = std.enums;
const fs = std.fs;

const clay = @import("clay");
const renderer = clay.renderers.raylib;

const rl = @import("raylib");

const title = "Voyager" ++ if (debug) " (Debug)" else "";
const width = if (debug) 1200 else 800;
const height = 480;

const rl_config = rl.ConfigFlags{
    .vsync_hint = true,
    .window_resizable = true,
    .msaa_4x_hint = true,
};

const roboto = @embedFile("resources/roboto.ttf");

const FontSize = enum(u16) {
    sm = 24,
    md = 32,
    lg = 40,
    xl = 48,
};

fn rgb(r: u8, g: u8, b: u8) clay.Color {
    return .{ .r = @floatFromInt(r), .g = @floatFromInt(g), .b = @floatFromInt(b) };
}

const catppuccin = .{
    .text = rgb(205, 214, 244),
    .base = rgb(30, 30, 46),
    .mantle = rgb(24, 24, 37),
};

fn vector_conv(v: rl.Vector2) clay.Vector2 {
    return .{ .x = v.x, .y = v.y };
}

fn text(contents: []const u8, comptime font_size: FontSize) void {
    inline for (comptime enums.values(FontSize), 0..) |size, id| {
        if (size == font_size) {
            clay.text(contents, .{
                .color = catppuccin.text,
                .font_id = id,
                .font_size = @intFromEnum(size),
                .wrap_mode = .none,
            });
            return;
        }
    }
    comptime unreachable;
}

pub fn main() !void {
    const arena = clay.createArena(heap.page_allocator, clay.minMemorySize());
    defer heap.page_allocator.free(@as([*]u8, @ptrCast(arena.memory))[0..arena.capacity]);

    clay.setMeasureTextFunction(renderer.measureText);
    _ = clay.initialize(arena, .{ .width = width, .height = height }, .{});
    clay.setDebugModeEnabled(debug);
    renderer.initialize(width, height, title, rl_config);
    rl.setExitKey(.null);

    inline for (comptime enums.values(FontSize), 0..) |size, id| {
        const roboto_font = try rl.Font.fromMemory(".ttf", roboto, @intFromEnum(size), null);
        rl.setTextureFilter(roboto_font.texture, .anisotropic_8x);
        renderer.addFont(id, roboto_font);
    }
    defer inline for (0..comptime enums.values(FontSize).len) |id| renderer.getFont(id).unload();

    while (!rl.windowShouldClose()) frame();
}

fn frame() void {
    const delta = rl.getFrameTime();
    clay.setLayoutDimensions(.{ .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) });
    clay.setPointerState(vector_conv(rl.getMousePosition()), rl.isMouseButtonDown(.left));
    clay.updateScrollContainers(true, vector_conv(rl.getMouseWheelMoveV()), delta);

    rl.beginDrawing();
    defer rl.endDrawing();

    clay.beginLayout();
    defer {
        // a buffer for the raylib renderer to use for temporary string copies
        var buf: [fs.max_path_bytes + 1]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(&buf);
        renderer.render(clay.endLayout(), fba.allocator());
    }

    clay.ui()(.{
        .id = clay.id("Screen"),
        .layout = .{
            .sizing = .{
                .width = .{ .size = .{ .percent = 1 }, .type = .percent },
                .height = .{ .size = .{ .percent = 1 }, .type = .percent },
            },
        },
        .rectangle = .{ .color = catppuccin.base },
    })({
        //
    });
}
