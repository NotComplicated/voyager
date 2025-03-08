const std = @import("std");
const meta = std.meta;
const time = std.time;
const fmt = std.fmt;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");

const tooltip_duration = 500;
const offset = clay.Vector2{ .x = 16, .y = 24 };

var tooltip: struct {
    state: union(enum) {
        disabled,
        delay: struct { timer: u32, pos: clay.Vector2 },
        enabled: struct { pos: clay.Vector2 },
    },
    msg: std.ArrayListUnmanaged(u8),
} = .{
    .state = .disabled,
    .msg = .{},
};

pub fn deinit() void {
    tooltip.msg.deinit(main.alloc);
}

pub fn update(input: Input) ?@TypeOf(tooltip.msg.writer(undefined)) {
    const reset = @TypeOf(tooltip.state){ .delay = .{ .timer = 0, .pos = input.mouse_pos } };
    switch (tooltip.state) {
        .disabled => {
            tooltip.state = reset;
        },
        .delay => |state| if (meta.eql(state.pos, input.mouse_pos)) {
            tooltip.state.delay.timer +|= input.delta_ms;
            if (tooltip.state.delay.timer > tooltip_duration) {
                tooltip.state = @TypeOf(tooltip.state){ .enabled = .{ .pos = input.mouse_pos } };
                tooltip.msg.clearRetainingCapacity();
                return tooltip.msg.writer(main.alloc);
            }
        } else {
            tooltip.state = reset;
        },
        .enabled => |state| if (!meta.eql(state.pos, input.mouse_pos)) {
            tooltip.state = reset;
        },
    }
    return null;
}

pub fn render() void {
    switch (tooltip.state) {
        .disabled, .delay => {},
        .enabled => |state| if (tooltip.msg.items.len > 0) {
            var pos = clay.Vector2{ .x = state.pos.x + offset.x, .y = state.pos.y + offset.y };
            if (pos.y + 45 > @as(f32, @floatFromInt(rl.getScreenHeight()))) pos.y -= 65;
            const pos_x_end = pos.x + @as(f32, @floatFromInt(tooltip.msg.items.len * 9));
            const width = @as(f32, @floatFromInt(rl.getScreenWidth()));
            if (pos_x_end > width) pos.x -= pos_x_end - width;

            clay.ui()(.{
                .id = main.newId("ToolTip"),
                .floating = .{
                    .offset = pos,
                    .z_index = 1,
                    .pointer_capture_mode = .passthrough,
                },
                .layout = .{
                    .padding = clay.Padding.xy(16, 8),
                    .child_alignment = .{ .x = .center },
                },
                .rectangle = .{
                    .color = main.theme.pitch_black,
                    .corner_radius = main.rounded,
                },
            })({
                main.text(tooltip.msg.items);
            });
        },
    }
}
