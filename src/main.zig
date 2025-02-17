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

const Model = @import("Model.zig");

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

fn text(comptime font_size: FontSize, contents: []const u8) void {
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

    // a buffer for the raylib renderer to use for temporary string copies
    var buf: [4096]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buf);

    var model = try Model.init();

    while (!rl.windowShouldClose()) frame(fba.allocator(), &model);
}

fn frame(alloc: mem.Allocator, model: *Model) void {
    const delta = rl.getFrameTime();
    clay.setLayoutDimensions(.{ .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) });
    clay.setPointerState(vector_conv(rl.getMousePosition()), rl.isMouseButtonDown(.left));
    clay.updateScrollContainers(true, vector_conv(rl.getMouseWheelMoveV()), delta);
    rl.beginDrawing();
    defer rl.endDrawing();
    clay.beginLayout();
    defer renderer.render(clay.endLayout(), alloc);

    clay.ui()(.{
        .id = clay.id("Screen"),
        .layout = .{
            .sizing = .{
                .width = .{ .size = .{ .percent = 1 }, .type = .percent },
                .height = .{ .size = .{ .percent = 1 }, .type = .percent },
            },
            .layout_direction = .top_to_bottom,
        },
        .rectangle = .{ .color = catppuccin.base },
    })({
        text(.sm, model.cwd.slice());
        clay.ui()(.{ .id = clay.id("Entries"), .layout = .{ .layout_direction = .top_to_bottom } })({
            for (model.entries.slice(), 0..) |*entry, i| {
                clay.ui()(.{ .id = clay.idi("Entry", @intCast(i)) })({
                    if (entry.is_dir) text(.sm, "(dir)");
                    text(.sm, entry.name.slice());
                });
            }
        });
    });
}
