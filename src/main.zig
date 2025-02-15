const builtin = @import("builtin");

const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const enums = std.enums;

const GPA = heap.GeneralPurposeAllocator(.{});

const clay = @import("clay");
const renderer = clay.renderers.raylib;

const rl = @import("raylib");

const title = "Voyager";
const width = 800;
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

fn vector_conv(v: rl.Vector2) clay.Vector2 {
    return .{ .x = v.x, .y = v.y };
}

const black = rgb(0, 0, 0);
const white = rgb(255, 255, 255);

fn text(contents: []const u8, comptime font_size: FontSize, color: clay.Color) void {
    inline for (comptime enums.values(FontSize), 0..) |size, id| {
        if (size == font_size) {
            clay.text(contents, .{ .font_id = id, .font_size = @intFromEnum(size), .color = color });
            return;
        }
    }
    comptime unreachable;
}

pub fn main() !void {
    var gpa = GPA{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const arena = clay.createArena(alloc, clay.minMemorySize());
    defer alloc.free(@as([*]u8, @ptrCast(arena.memory))[0..arena.capacity]);

    clay.setMeasureTextFunction(renderer.measureText);
    _ = clay.initialize(arena, .{ .width = width, .height = height }, .{});
    clay.setDebugModeEnabled(builtin.mode == .Debug);
    renderer.initialize(width, height, title, rl_config);
    rl.setExitKey(.null);

    inline for (comptime enums.values(FontSize), 0..) |size, id| {
        const roboto_font = try rl.Font.fromMemory(".ttf", roboto, @intFromEnum(size), null);
        rl.setTextureFilter(roboto_font.texture, .anisotropic_8x);
        renderer.addFont(id, roboto_font);
    }
    defer inline for (0..comptime enums.values(FontSize).len) |id| renderer.getFont(id).unload();

    while (!rl.windowShouldClose()) frame(alloc);
}

fn frame(alloc: mem.Allocator) void {
    const delta = rl.getFrameTime();

    clay.setLayoutDimensions(.{ .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) });
    clay.setPointerState(vector_conv(rl.getMousePosition()), rl.isMouseButtonDown(.left));
    clay.updateScrollContainers(true, vector_conv(rl.getMouseWheelMoveV()), delta);
    rl.clearBackground(rl.Color.light_gray);

    clay.beginLayout();
    rl.beginDrawing();
    defer rl.endDrawing();
    defer renderer.render(clay.endLayout(), alloc);

    clay.ui()(.{
        .id = clay.idi("Foo", 0),
        .layout = .{ .padding = clay.Padding.all(5) },
    })({
        text("Hello, world!", .md, black);
    });
}
