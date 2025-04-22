const std = @import("std");
const enums = std.enums;
const meta = std.meta;

const clay = @import("clay");
const rl = @import("raylib");

const themes = @import("themes.zig");
const draw = @import("draw.zig");
const Input = @import("Input.zig");

const offset = clay.Vector2{ .x = 16, .y = 16 };

var menu: ?struct {
    type_id: u32,
    pos: clay.Vector2,
    labels: []const []const u8,
} = null;

pub fn register(
    Menu: type,
    pos: clay.Vector2,
    labels: enums.EnumFieldStruct(Menu, []const u8, null),
) void {
    const Labels = struct {
        var array: [meta.fieldNames(Menu).len][]const u8 = undefined;
    };
    inline for (&Labels.array, comptime meta.fieldNames(Menu)) |*label, field| label.* = @field(labels, field);
    menu = .{
        .type_id = @intFromError(@field(anyerror, @typeName(Menu))),
        .pos = pos,
        .labels = &Labels.array,
    };
}

pub fn get(Menu: type, input: Input) ?Menu {
    if (input.action) |action| switch (action) {
        .key, .event => menu = null,
        else => {},
    };
    if (menu == null or !input.clicked(.left) or menu.?.type_id != @intFromError(@field(anyerror, @typeName(Menu)))) return null;
    defer menu = null;
    for (0..menu.?.labels.len) |i| if (clay.pointerOver(clay.idi("MenuOption", @intCast(i)))) return @enumFromInt(i);
    return null;
}

pub fn render() void {
    if (menu == null) return;
    var pos = clay.Vector2{ .x = menu.?.pos.x + offset.x, .y = menu.?.pos.y + offset.y };
    const menu_height: f32 = @floatFromInt(menu.?.labels.len * 45);
    if (pos.y + menu_height > @as(f32, @floatFromInt(rl.getScreenHeight()))) pos.y -= menu_height + 20;
    var longest_option_label_len: usize = 0;
    for (menu.?.labels) |label| {
        if (label.len > longest_option_label_len) longest_option_label_len = label.len;
    }
    const menu_width = @as(f32, @floatFromInt(longest_option_label_len * 12 + 24));
    if (pos.x + menu_width > @as(f32, @floatFromInt(rl.getScreenWidth()))) pos.x -= menu_width;

    clay.ui()(.{
        .id = clay.id("Menu"),
        .layout = .{
            .layout_direction = .top_to_bottom,
            .child_gap = 2,
        },
        .bg_color = themes.current.pitch_black,
        .corner_radius = draw.rounded,
        .floating = .{
            .offset = pos,
            .z_index = 1,
            .attach_to = .root,
        },
    })({
        for (menu.?.labels, 0..) |label, i| {
            clay.ui()(.{
                .id = clay.idi("MenuOption", @intCast(i)),
                .layout = .{
                    .padding = .xy(24, 12),
                    .sizing = .grow(.{}),
                },
                .corner_radius = if (i == 0 or i == menu.?.labels.len - 1) draw.rounded else null,
                .bg_color = if (clay.hovered()) themes.current.hovered else themes.current.pitch_black,
            })({
                draw.pointer();
                draw.text(label);
            });
        }
    });
}
