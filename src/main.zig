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
const os = std.os;

const clay = @import("clay");
const renderer = clay.renderers.raylib;

const rl = @import("raylib");

const Model = @import("Model.zig");

pub var model: Model = undefined;

const hover = @import("hover.zig");

const title = "Voyager" ++ if (debug) " (Debug)" else "";
const width = 800 + if (debug) 400 else 0;
const height = 480;
const mem_scale = 5;
const max_elem_count = mem_scale * 8192; // 8192 is the default clay max elem count

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

const icon_data = @embedFile("resources/voyager.bmp");
const icon_ext = ".bmp";

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

const title_color =
    @as(os.windows.DWORD, @intFromFloat(catppuccin.base.r)) +
    (@as(os.windows.DWORD, @intFromFloat(catppuccin.base.g)) << 8) +
    (@as(os.windows.DWORD, @intFromFloat(catppuccin.base.b)) << 16);
const dwma_caption_color = 35;

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
    const err_str = switch (err) {
        Model.Error.OsNotSupported => "OS not yet supported",
        else => @errorName(err),
    };
    log.err("{s}\n", .{err_str}); // TODO replace with graphical error modal
}

extern fn DwmSetWindowAttribute(
    window: os.windows.HWND,
    attr: os.windows.DWORD,
    pvAttr: os.windows.LPCVOID,
    cbAttr: os.windows.DWORD,
) os.windows.HRESULT;

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

    const icon = try rl.loadImageFromMemory(icon_ext, icon_data);
    defer rl.unloadImage(icon);
    rl.setWindowIcon(icon);

    if (windows) {
        _ = DwmSetWindowAttribute(
            @ptrCast(rl.getWindowHandle()),
            dwma_caption_color,
            &title_color,
            @sizeOf(@TypeOf(title_color)),
        );
    }

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
        .up, .down => updown: {
            for (Model.Entries.kinds()) |kind| {
                var sorted = model.entries.sorted(kind, &.{.selected});
                var sorted_index: Model.Index = 0;
                while (sorted.next()) |entry| : (sorted_index += 1) {
                    if (entry.selected != null) {
                        // TODO handle going from one kind to the other
                        // TODO how to get next/prev?
                        // if (key == .up and sorted_index > 0) {
                        //     // model.select(kind, sort_list[sort_index - 1], .touch) catch |err| updateError(err);
                        //     break :updown;
                        // } else if (key == .down and sort_index < sort_list.len - 1) {
                        //     // model.select(kind, sort_list[sort_index + 1], .touch) catch |err| updateError(err);
                        //     break :updown;
                        // }
                        break :updown;
                    }
                }
            }
            if (key == .down) {
                // TODO bounds check the 0
                // model.select(.dir, model.entries.sortings.get(model.entries.curr_sorting).get(.dir)[0], .touch) catch |err| switch (err) {
                //     Model.Error.OutOfBounds => _ = model.select(.file, model.entries.sortings.get(model.entries.curr_sorting).get(.file)[0], .touch),
                //     else => updateError(err),
                // };
                clay.getScrollContainerData(clay.getId("Entries")).scroll_position.y = 0;
            }
        },
        // TODO select_top() / select_bottom() ?
        .home => {
            // model.select(.dir, model.entries.sortings.get(model.entries.curr_sorting).get(.dir)[0], .touch) catch |err| switch (err) {
            //     Model.Error.OutOfBounds => _ = model.select(.file, model.entries.sortings.get(model.entries.curr_sorting).get(.file)[0], .touch),
            //     else => updateError(err),
            // };
            clay.getScrollContainerData(clay.getId("Entries")).scroll_position.y = 0;
        },
        .end => {
            // TODO
            // if (model.entries.list.len > 0) {
            //     model.select(model.entries.list.len - 1, false) catch |err| updateError(err);
            // }
            clay.getScrollContainerData(clay.getId("Entries")).scroll_position.y = -100_000;
        },
        .enter => {
            // TODO also support opening dirs?
            for (model.entries.data_slices.get(.file).items(.selected), 0..) |selected, index| {
                if (selected) |_| model.open_file(@intCast(index)) catch |err| updateError(err);
            }
        },
        .period => _ = model.entries.try_jump('.'),
        else => {},
    }

    // jump to entries when typing letters/numbers
    const key_int = @intFromEnum(key);
    if (65 <= key_int and key_int <= 90) {
        if (model.entries.try_jump(@intCast(key_int)) == .not_found) {
            _ = model.entries.try_jump(@intCast(key_int + 32));
        }
    } else if (48 <= key_int and key_int <= 57) {
        _ = model.entries.try_jump(@intCast(key_int - 48));
    } else if (320 <= key_int and key_int <= 329) {
        _ = model.entries.try_jump(@intCast(key_int - 320));
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
            inline for (comptime Model.Entries.kinds()) |kind| {
                var sorted = model.entries.sorted(kind, &.{ .name, .selected });
                var sorted_index: Model.Index = 0;
                while (sorted.next()) |entry| : (sorted_index += 1) {
                    const id = clay.idi(@tagName(kind) ++ "Entry", entry.index);
                    clay.ui()(.{
                        .id = id,
                        .layout = .{
                            .padding = clay.Padding.vertical(2),
                            .sizing = .{ .width = .{ .type = .grow } },
                        },
                        .rectangle = .{
                            .color = if (entry.selected) |_|
                                catppuccin.selected
                            else if (clay.pointerOver(id))
                                catppuccin.hovered
                            else
                                catppuccin.base,
                            .corner_radius = clay.CornerRadius.all(3),
                        },
                    })({
                        if (clay.hovered()) cursor = .pointing_hand;
                        hover.on(.{ .entry = .{ kind, entry.index } });
                        clay.ui()(.{
                            .id = clay.idi(@tagName(kind) ++ "EntryName", entry.index),
                            .layout = .{
                                .padding = clay.Padding.all(4),
                            },
                        })({
                            if (kind == .dir) {
                                text(.sm, "(dir) ");
                            }
                            text(.sm, entry.name);
                        });
                    });
                }
            }
        });
    });
}
