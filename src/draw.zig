const std = @import("std");
const enums = std.enums;
const math = std.math;

const clay = @import("clay");
const renderer = clay.renderers.raylib;
const rl = @import("raylib");

const themes = @import("themes.zig");
const resources = @import("resources.zig");

pub const rounded = clay.CornerRadius.all(6);

var cursor = rl.MouseCursor.default;

pub fn getCursor() rl.MouseCursor {
    return cursor;
}

pub fn setCursor(new_cursor: rl.MouseCursor) void {
    cursor = new_cursor;
}

pub fn pointer() void {
    if (clay.hovered()) cursor = .pointing_hand;
}

pub fn ibeam() void {
    if (clay.hovered()) cursor = .ibeam;
}

pub fn left_right_arrows() void {
    if (clay.hovered()) cursor = .resize_ew;
}

pub fn text(contents: []const u8) void {
    textEx(.roboto, .md, contents, themes.current.text, null);
}

pub fn textEx(
    comptime font: resources.Font,
    comptime font_size: resources.FontSize,
    contents: []const u8,
    color: clay.Color,
    width: ?usize,
) void {
    inline for (comptime enums.values(resources.Font), 0..) |font_inner, i| {
        inline for (comptime enums.values(resources.FontSize), 0..) |size, j| {
            if (font_inner == font and size == font_size) {
                var config = clay.Config.Text{
                    .color = color,
                    .font_id = @intCast(i * enums.values(resources.FontSize).len + j),
                    .font_size = @intFromEnum(size),
                    .wrap_mode = .none,
                };

                if (width) |width_inner| {
                    const dimensions = renderer.measureText(contents, &config, &resources.fonts);
                    const width_float: f32 = @floatFromInt(width_inner);
                    if (dimensions.width > width_float) {
                        const new_len: usize = @intFromFloat(@as(f32, @floatFromInt(contents.len)) * width_float / dimensions.width);
                        clay.text(contents[0..new_len -| "...".len], config);
                        clay.text("...", config);
                    } else clay.text(contents, config);
                } else clay.text(contents, config);

                return;
            }
        }
    }
    comptime unreachable;
}
