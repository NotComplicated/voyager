const builtin = @import("builtin");
pub const debug = builtin.mode == .Debug;
pub const windows = builtin.os.tag == .windows;

const std = @import("std");
const enums = std.enums;
const ascii = std.ascii;
const heap = std.heap;
const meta = std.meta;
const log = std.log;
const fs = std.fs;
const os = std.os;

const clay = @import("clay");
const renderer = clay.renderers.raylib;

const rl = @import("raylib");

const resources = @import("resources.zig");
const FontSize = resources.FontSize;
const Font = resources.Font;
const hover = @import("hover.zig");
const EventParam = hover.EventParam;
const alert = @import("alert.zig");
const Model = @import("Model.zig");

pub const Bytes = std.ArrayListUnmanaged(u8);
pub const Millis = i64;

pub var model: Model = undefined;

const title = "Voyager" ++ if (debug) " (Debug)" else "";
const width = 1000 + if (debug) 400 else 0;
const height = 600;
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

fn rgb(r: u8, g: u8, b: u8) clay.Color {
    return .{ .r = @floatFromInt(r), .g = @floatFromInt(g), .b = @floatFromInt(b) };
}

pub fn opacity(color: clay.Color, alpha: f32) clay.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha * 255 };
}

pub const theme = .{
    .alert = rgb(228, 66, 38),
    .text = rgb(205, 214, 244),
    .bright_text = rgb(255, 255, 255),
    .nav = rgb(43, 43, 58),
    .base = rgb(30, 30, 46),
    .hovered = rgb(43, 43, 58),
    .selected = rgb(59, 59, 71),
    .mantle = rgb(24, 24, 37),
};

const title_color =
    @as(os.windows.DWORD, @intFromFloat(theme.base.r)) +
    (@as(os.windows.DWORD, @intFromFloat(theme.base.g)) << 8) +
    (@as(os.windows.DWORD, @intFromFloat(theme.base.b)) << 16);
const dwma_caption_color = 35;

pub const rounded = clay.CornerRadius.all(6);

fn vector_conv(v: rl.Vector2) clay.Vector2 {
    return .{ .x = v.x, .y = v.y };
}

pub fn text(comptime font_size: FontSize, contents: []const u8) void {
    textEx(.roboto, font_size, contents, theme.text);
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

fn pointer() void {
    if (clay.hovered()) cursor = .pointing_hand;
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

    try resources.init_resources();
    defer resources.deinit_resources();

    model = try Model.init();
    defer model.deinit();

    while (!rl.windowShouldClose()) render_frame();
}

fn render_frame() void {
    clay.setLayoutDimensions(.{ .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) });

    // setPointerState will call all hover events, updating the model
    clay.setPointerState(vector_conv(rl.getMousePosition()), rl.isMouseButtonDown(.left));

    clay.updateScrollContainers(true, vector_conv(rl.math.vector2Scale(rl.getMouseWheelMoveV(), 5)), rl.getFrameTime());

    rl.beginDrawing();
    defer rl.endDrawing();

    if (debug and rl.isMouseButtonPressed(.middle)) {
        log.debug("{any}\n", .{&model});
    }
    if (rl.isMouseButtonPressed(.side)) {
        model.open_parent_dir() catch |err| alert.update(err);
    }

    model.handleKeyboard() catch |err| alert.update(err);

    clay.beginLayout();
    defer renderer.render(clay.endLayout(), raylib_alloc);

    cursor = rl.MouseCursor.default;
    defer rl.setMouseCursor(cursor);

    clay.ui()(.{
        .id = clay.id("Screen"),
        .layout = .{
            .sizing = clay.Element.Sizing.grow(.{}),
            .layout_direction = .top_to_bottom,
        },
        .rectangle = .{ .color = theme.base },
    })({
        alert.render();

        const cwd_id = clay.id("CurrentDir");

        hover.on(.{ .focus = if (clay.pointerOver(cwd_id)) .cwd else null });

        clay.ui()(.{
            .id = clay.id("NavBar"),
            .layout = .{
                .padding = clay.Padding.all(10),
                .sizing = .{
                    .width = .{ .type = .grow },
                },
                .child_gap = 10,
            },
        })({
            const nav_size = 30;

            const navButton = struct {
                fn navButton(name: []const u8, param: EventParam, icon: *rl.Texture) void {
                    const id = clay.id(name);
                    clay.ui()(.{
                        .id = id,
                        .layout = .{ .sizing = clay.Element.Sizing.fixed(nav_size) },
                        .image = .{
                            .image_data = icon,
                            .source_dimensions = clay.Dimensions.square(nav_size),
                        },
                        .rectangle = .{
                            .color = if (clay.pointerOver(id)) theme.hovered else theme.base,
                            .corner_radius = rounded,
                        },
                    })({
                        pointer();
                        hover.on(param);
                    });
                }
            }.navButton;

            navButton("Parent", .parent, &resources.images.arrow_up);
            navButton("Refresh", .refresh, &resources.images.refresh);

            clay.ui()(.{
                .id = cwd_id,
                .layout = .{
                    .padding = clay.Padding.all(6),
                    .sizing = .{
                        .width = .{ .type = .grow },
                        .height = clay.Element.Sizing.Axis.fixed(nav_size),
                    },
                    .child_alignment = .{ .y = clay.Element.Config.Layout.AlignmentY.center },
                },
                .rectangle = .{
                    .color = if (model.cursor) |_| theme.selected else theme.nav,
                    .corner_radius = rounded,
                },
            })({
                pointer();
                if (model.cursor) |cursor_index| {
                    textEx(.roboto_mono, .sm, model.cwd.items[0..cursor_index], theme.text);
                    clay.ui()(.{
                        .floating = .{
                            .offset = .{ .x = @floatFromInt(cursor_index * 9), .y = -2 },
                            .attachment = .{ .element = .left_center, .parent = .left_center },
                        },
                    })({
                        textEx(.roboto_mono, .md, "|", theme.bright_text);
                    });
                    textEx(.roboto_mono, .sm, model.cwd.items[cursor_index..], theme.text);
                } else {
                    textEx(.roboto_mono, .sm, model.cwd.items, theme.text);
                }
            });

            navButton("VsCode", .vscode, &resources.images.vscode);
        });

        clay.ui()(.{
            .id = clay.id("Content"),
            .layout = .{
                .sizing = clay.Element.Sizing.grow(.{}),
            },
            .rectangle = .{ .color = theme.mantle },
        })({
            const shortcut_width = 260; // TODO customizable

            clay.ui()(.{
                .id = clay.id("ShortcutsContainer"),
                .layout = .{
                    .padding = clay.Padding.all(10),
                    .sizing = .{ .width = clay.Element.Sizing.Axis.fixed(shortcut_width) },
                },
            })({
                clay.ui()(.{
                    .id = clay.id("Shortcuts"),
                    .layout = .{
                        .layout_direction = .top_to_bottom,
                        .padding = clay.Padding.all(16),
                    },
                })({
                    text(.sm, "Shortcuts will go here");
                });
            });

            clay.ui()(.{
                .id = clay.id("EntriesContainer"),
                .layout = .{
                    .padding = clay.Padding.all(10),
                    .sizing = clay.Element.Sizing.grow(.{}),
                },
            })({
                clay.ui()(.{
                    .id = clay.id("Entries"),
                    .layout = .{
                        .layout_direction = .top_to_bottom,
                        .padding = clay.Padding.all(10),
                        .sizing = clay.Element.Sizing.grow(.{}),
                        .child_gap = 4,
                    },
                    .scroll = .{ .vertical = true },
                    .rectangle = .{ .color = theme.base, .corner_radius = rounded },
                })({
                    inline for (comptime Model.Entries.kinds()) |kind| {
                        var kind_name = @tagName(kind).*;
                        kind_name[0] = ascii.toUpper(kind_name[0]);

                        var sorted = model.entries.sorted(kind, &.{ .name, .selected });
                        var sorted_index: Model.Index = 0;
                        while (sorted.next()) |entry| : (sorted_index += 1) {
                            const id = clay.idi(kind_name ++ "Entry", entry.index);
                            clay.ui()(.{
                                .id = id,
                                .layout = .{
                                    .padding = .{ .top = 4, .bottom = 4, .left = 8 },
                                    .sizing = .{ .width = .{ .type = .grow } },
                                    .child_alignment = .{ .y = clay.Element.Config.Layout.AlignmentY.center },
                                    .child_gap = 4,
                                },
                                .rectangle = .{
                                    .color = if (entry.selected) |_|
                                        theme.selected
                                    else if (clay.pointerOver(id))
                                        theme.hovered
                                    else
                                        theme.base,
                                    .corner_radius = rounded,
                                },
                            })({
                                pointer();
                                hover.on(.{ .entry = .{ kind, entry.index } });

                                const icon_image = if (kind == .dir)
                                    if (clay.hovered()) &resources.images.folder_open else &resources.images.folder
                                else
                                    resources.get_file_icon(entry.name);

                                clay.ui()(.{
                                    .id = clay.idi(kind_name ++ "EntryIconContainer", entry.index),
                                    .layout = .{
                                        .sizing = clay.Element.Sizing.fixed(resources.file_icon_size),
                                    },
                                })({
                                    clay.ui()(.{
                                        .id = clay.idi(kind_name ++ "EntryIcon", entry.index),
                                        .layout = .{
                                            .sizing = clay.Element.Sizing.grow(.{}),
                                        },
                                        .image = .{
                                            .image_data = icon_image,
                                            .source_dimensions = clay.Dimensions.square(resources.file_icon_size),
                                        },
                                    })({});
                                });

                                clay.ui()(.{
                                    .id = clay.idi(kind_name ++ "EntryName", entry.index),
                                    .layout = .{ .padding = clay.Padding.all(6) },
                                })({
                                    text(.sm, entry.name);
                                });
                            });
                        }
                    }
                });
            });
        });
    });
}
