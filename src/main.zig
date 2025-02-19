const builtin = @import("builtin");
pub const debug = builtin.mode == .Debug;
pub const windows = builtin.os.tag == .windows;

const std = @import("std");
const heap = std.heap;
const meta = std.meta;
const mem = std.mem;
const enums = std.enums;
const fs = std.fs;
const log = std.log;

const clay = @import("clay");
const renderer = clay.renderers.raylib;

const rl = @import("raylib");

const Model = @import("Model.zig");

pub var model: Model = undefined;

const hover = @import("hover.zig");

const title = "Voyager" ++ if (debug) " (Debug)" else "";
const width = if (debug) 1200 else 800;
const height = 480;
const mem_scale = 5;
const max_elem_count = mem_scale * 8192;

var logging_page_alloc = heap.LoggingAllocator(.debug, .info).init(heap.page_allocator);
pub const alloc = logging_page_alloc.allocator();

// a buffer for the raylib renderer to use for temporary string copies
var buf: [4096]u8 = undefined;
var fba = heap.FixedBufferAllocator.init(&buf);
const raylib_alloc = fba.allocator();

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
    .hovered = rgb(43, 43, 58),
    .selected = rgb(59, 59, 71),
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

pub fn updateError(err: anyerror) void {
    log.err("{s}\n", .{@errorName(err)});
}

pub fn main() !void {
    clay.setMaxElementCount(max_elem_count);
    const arena = clay.createArena(alloc, mem_scale * clay.minMemorySize());
    defer alloc.free(@as([*]u8, @ptrCast(arena.memory))[0..arena.capacity]);

    _ = clay.initialize(arena, .{ .width = width, .height = height }, .{});
    clay.setMeasureTextFunction(renderer.measureText);
    clay.setDebugModeEnabled(debug);
    renderer.initialize(width, height, title, rl_config);
    rl.setExitKey(.null);
    defer hover.deinit();

    inline for (comptime enums.values(FontSize), 0..) |size, id| {
        const roboto_font = try rl.Font.fromMemory(".ttf", roboto, @intFromEnum(size), null);
        rl.setTextureFilter(roboto_font.texture, .anisotropic_8x);
        renderer.addFont(id, roboto_font);
    }
    defer inline for (0..comptime enums.values(FontSize).len) |id| renderer.getFont(id).unload();

    model = try Model.init();
    defer model.deinit();

    while (!rl.windowShouldClose()) render_frame();
}

fn render_frame() void {
    clay.setLayoutDimensions(.{ .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) });
    // setPointerState will call all hover events, updating the model
    clay.setPointerState(vector_conv(rl.getMousePosition()), rl.isMouseButtonDown(.left));
    clay.updateScrollContainers(true, vector_conv(rl.math.vector2Scale(rl.getMouseWheelMoveV(), 4)), rl.getFrameTime());

    rl.beginDrawing();
    defer rl.endDrawing();

    if (debug and rl.isMouseButtonPressed(.middle)) {
        log.debug("{any}\n", .{&model});
    }
    if (rl.isMouseButtonPressed(.side)) {
        model.open_parent_dir() catch |err| updateError(err);
    }

    const key = rl.getKeyPressed();
    switch (key) {
        .escape => {
            model.open_parent_dir() catch |err| updateError(err);
        },
        .up, .down => {
            const selected = model.entries.list.items(.selected);
            const Selected = meta.Elem(@TypeOf(selected));
            if (mem.indexOfNone(Selected, selected, &[_]Selected{null})) |index| {
                if (key == .up and index > 0) {
                    model.select(index - 1, false) catch |err| updateError(err);
                } else if (key == .down) {
                    model.select(index + 1, false) catch |err| updateError(err);
                }
            } else if (key == .down) {
                model.select(0, false) catch |err| updateError(err);
            }
        },
        .home => {
            model.select(0, false) catch |err| updateError(err);
            clay.getScrollContainerData(clay.getId("Entries")).scroll_position.y = 0;
        },
        .end => {
            if (model.entries.list.len > 0) {
                model.select(model.entries.list.len - 1, false) catch |err| updateError(err);
                clay.getScrollContainerData(clay.getId("Entries")).scroll_position.y = -100_000;
            }
        },
        .enter => {
            for (model.entries.list.items(.selected), 0..) |selected, index| {
                if (selected) |_| {
                    model.open(index) catch |err| updateError(err);
                }
            }
        },
        .period => _ = model.try_jump('.'),
        else => {},
    }

    // jump to entries when typing letters/numbers
    const key_int = @intFromEnum(key);
    if (65 <= key_int and key_int <= 90) {
        if (!model.try_jump(@intCast(key_int))) {
            _ = model.try_jump(@intCast(key_int + 32));
        }
    } else if (48 <= key_int and key_int <= 57) {
        _ = model.try_jump(@intCast(key_int - 48));
    } else if (320 <= key_int and key_int <= 329) {
        _ = model.try_jump(@intCast(key_int - 320));
    }

    clay.beginLayout();
    defer renderer.render(clay.endLayout(), raylib_alloc);

    var cursor = rl.MouseCursor.default;
    defer rl.setMouseCursor(cursor);

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
        text(.sm, model.cwd.items);
        clay.ui()(.{
            .id = clay.id("Entries"),
            .layout = .{
                .layout_direction = .top_to_bottom,
                .padding = clay.Padding.all(16),
                .sizing = .{ .width = .{ .type = .grow } },
                .child_gap = 4,
            },
            .scroll = .{ .vertical = true },
        })({
            clay.ui()(.{
                .id = clay.id("ParentEntry"),
                .layout = .{
                    .sizing = .{ .width = .{ .type = .grow } },
                },
            })({
                text(.sm, "..");
                hover.on(.parent);
            });
            const entries = model.entries.list.slice();
            for (0..entries.len) |i| {
                const id = clay.idi("Entry", @intCast(i));
                clay.ui()(.{
                    .id = id,
                    .layout = .{
                        .padding = clay.Padding.vertical(2),
                        .sizing = .{ .width = .{ .type = .grow } },
                    },
                    .rectangle = .{
                        .color = if (entries.items(.selected)[i] != null)
                            catppuccin.selected
                        else if (clay.pointerOver(id))
                            catppuccin.hovered
                        else
                            catppuccin.base,
                        .corner_radius = clay.CornerRadius.all(3),
                    },
                })({
                    if (clay.hovered()) cursor = .pointing_hand;
                    hover.on(.{ .entry = @intCast(i) });
                    clay.ui()(.{
                        .id = clay.idi("EntryName", @intCast(i)),
                        .layout = .{
                            .padding = clay.Padding.all(4),
                        },
                    })({
                        if (entries.items(.is_dir)[i]) {
                            text(.sm, "(dir) ");
                        }
                        text(.sm, model.entries.get_name(entries.items(.name_indices)[i]));
                    });
                });
            }
        });
    });
}
