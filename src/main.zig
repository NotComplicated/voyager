const builtin = @import("builtin");
pub const debug = builtin.mode == .Debug;
pub const windows = builtin.os.tag == .windows;

const std = @import("std");
const testing = std.testing;
const enums = std.enums;
const heap = std.heap;
const math = std.math;
const os = std.os;

const clay = @import("clay");
const renderer = clay.renderers.raylib;
const rl = @import("raylib");

const resources = @import("resources.zig");
const FontSize = resources.FontSize;
const Font = resources.Font;
const alert = @import("alert.zig");
const tooltip = @import("tooltip.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");

const title = "Voyager" ++ if (debug) " (Debug)" else "";
const width = 1200 + if (debug) 400 else 0;
const height = 600;
const mem_scale = 4;
const max_elem_count = mem_scale * 8192; // 8192 is the default clay max elem count

var logging_page_alloc = heap.loggingAllocator(heap.c_allocator);
pub const alloc = if (debug) logging_page_alloc.allocator() else heap.c_allocator;

// a buffer for the raylib renderer to use for temporary string copies
var buf: [4096]u8 = undefined;
var fba = heap.FixedBufferAllocator.init(&buf);
const raylib_alloc = fba.allocator();

const rl_config = rl.ConfigFlags{
    .vsync_hint = true,
    .window_resizable = true,
    .msaa_4x_hint = true,
};

pub const double_click_delay = 300;

fn rgb(r: u8, g: u8, b: u8) clay.Color {
    return .{ .r = @floatFromInt(r), .g = @floatFromInt(g), .b = @floatFromInt(b) };
}

pub fn opacity(color: clay.Color, alpha: f32) clay.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha * 255 };
}

pub const theme = .{
    .alert = rgb(247, 55, 87),
    .text = rgb(205, 214, 244),
    .bright_text = rgb(255, 255, 255),
    .highlight = rgb(203, 166, 247),
    .nav = rgb(43, 43, 58),
    .base = rgb(30, 30, 46),
    .hovered = rgb(43, 43, 58),
    .selected = rgb(59, 59, 71),
    .mantle = rgb(24, 24, 37),
    .pitch_black = rgb(17, 17, 27),
};

const title_color =
    @as(os.windows.DWORD, @intFromFloat(theme.base.r)) +
    (@as(os.windows.DWORD, @intFromFloat(theme.base.g)) << 8) +
    (@as(os.windows.DWORD, @intFromFloat(theme.base.b)) << 16);
const dwma_caption_color = 35;

pub const rounded = clay.CornerRadius.all(6);

pub fn convertVector(v: rl.Vector2) clay.Vector2 {
    return .{ .x = v.x, .y = v.y };
}

pub fn text(contents: []const u8) void {
    textEx(.roboto, .sm, contents, theme.text);
}

pub fn textEx(comptime font: Font, comptime font_size: FontSize, contents: []const u8, color: clay.Color) void {
    inline for (comptime enums.values(Font), 0..) |f, i| {
        inline for (comptime enums.values(FontSize), 0..) |size, j| {
            if (f == font and size == font_size) {
                clay.text(contents, .{
                    .color = color,
                    .font_id = @intCast(i * enums.values(FontSize).len + j),
                    .font_size = @intFromEnum(size),
                    .wrap_mode = .none,
                });
                return;
            }
        }
    }
    comptime unreachable;
}

var cursor = rl.MouseCursor.default;

pub fn pointer() void {
    if (clay.hovered()) cursor = .pointing_hand;
}

pub fn ibeam() void {
    if (clay.hovered()) cursor = .ibeam;
}

// can't use clay.getElementData until it's patched
extern fn Clay_GetElementData(id: clay.external_typedefs.ElementConfig.Id) clay.Element.Data;
pub fn getBounds(id: clay.Element.Config.Id) ?clay.BoundingBox {
    const data = Clay_GetElementData(.{
        .id = id.id,
        .offset = id.offset,
        .base_id = id.base_id,
        .string_id = clay.external_typedefs.String.new(id.string_id),
    });
    if (!data.found) {
        alert.updateFmt("Failed to locate element '{s}:{}'", .{ id.string_id, id.offset });
        return null;
    } else {
        return data.boundingBox;
    }
}

// port of Clay__HashString to allow comptime IDs
pub fn newId(key: []const u8) clay.Element.Config.Id {
    return newIdIndexed(key, 0);
}
pub fn newIdIndexed(key: []const u8, offset: u32) clay.Element.Config.Id {
    var hash: u32 = 0;
    var base: u32 = 0;

    for (key) |c| {
        base +%= c;
        base +%= math.shl(u32, base, 10);
        base ^= math.shr(u32, base, 6);
    }

    hash = base;
    hash +%= offset;
    hash +%= math.shl(u32, hash, 10);
    hash ^= math.shr(u32, hash, 6);

    hash +%= math.shl(u32, hash, 3);
    base +%= math.shl(u32, base, 3);
    hash ^= math.shr(u32, hash, 11);
    base ^= math.shr(u32, base, 11);
    hash +%= math.shl(u32, hash, 15);
    base +%= math.shl(u32, base, 15);

    return .{
        .id = hash + 1,
        .offset = offset,
        .base_id = base + 1,
        .string_id = key,
    };
}

pub fn main() !void {
    clay.setMaxElementCount(max_elem_count);
    const arena = clay.createArena(alloc, mem_scale * clay.minMemorySize());
    defer alloc.free(@as([*]u8, @ptrCast(arena.memory))[0..arena.capacity]);

    _ = clay.initialize(arena, .{ .width = width, .height = height }, .{ .function = alert.updateClay });
    clay.setMeasureTextFunction(renderer.measureText);
    clay.setDebugModeEnabled(debug);
    renderer.initialize(width, height, title, rl_config);
    rl.setExitKey(.null);

    if (windows) {
        _ = struct {
            extern fn DwmSetWindowAttribute(
                window: os.windows.HWND,
                attr: os.windows.DWORD,
                pvAttr: os.windows.LPCVOID,
                cbAttr: os.windows.DWORD,
            ) os.windows.HRESULT;
        }.DwmSetWindowAttribute(
            @ptrCast(rl.getWindowHandle()),
            dwma_caption_color,
            &title_color,
            @sizeOf(@TypeOf(title_color)),
        );
    }

    try resources.init();
    defer resources.deinit();

    defer alert.deinit();
    defer tooltip.deinit();

    var model = try Model.init();
    defer model.deinit();

    while (!rl.windowShouldClose()) frame(&model);
}

fn frame(model: *Model) void {
    clay.setLayoutDimensions(.{ .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) });
    clay.setPointerState(convertVector(rl.getMousePosition()), rl.isMouseButtonDown(.left));
    clay.updateScrollContainers(false, convertVector(rl.math.vector2Scale(rl.getMouseWheelMoveV(), 5)), rl.getFrameTime());

    model.update(Input.read()) catch |err| alert.update(err);

    rl.beginDrawing();
    defer rl.endDrawing();
    clay.beginLayout();
    defer renderer.render(clay.endLayout(), raylib_alloc);

    cursor = .default;
    defer rl.setMouseCursor(cursor);

    model.render();
    alert.render();
    tooltip.render();
}

test "ids" {
    for ([_][]const u8{ "FooBar", "Baz", "" }) |key| {
        const clay_id = clay.id(key);
        const clay_get_id = clay.getId(key);
        const new_id = newId(key);

        try testing.expectEqual(clay_id.id, clay_get_id.id);
        try testing.expectEqual(clay_id.id, new_id.id);

        try testing.expectEqual(clay_id.base_id, clay_get_id.base_id);
        try testing.expectEqual(clay_id.base_id, new_id.base_id);

        try testing.expectEqualStrings(clay_id.string_id, clay_get_id.string_id);
        try testing.expectEqualStrings(clay_id.string_id, new_id.string_id);
    }
}

test "offset ids" {
    const key = "Key";
    for (0..3) |i| {
        const offset: u32 = @intCast(i);
        const clay_id = clay.idi(key, offset);
        const clay_get_id = clay.getIdi(key, offset);
        const new_id = newIdIndexed(key, offset);

        try testing.expectEqual(clay_id.id, clay_get_id.id);
        try testing.expectEqual(clay_id.id, new_id.id);

        try testing.expectEqual(clay_id.base_id, clay_get_id.base_id);
        try testing.expectEqual(clay_id.base_id, new_id.base_id);

        try testing.expectEqualStrings(clay_id.string_id, clay_get_id.string_id);
        try testing.expectEqualStrings(clay_id.string_id, new_id.string_id);
    }
}
