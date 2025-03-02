const std = @import("std");
const meta = std.meta;
const time = std.time;
const fmt = std.fmt;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const Model = @import("Model.zig");

const tooltip_duration = 500;
const offset = clay.Vector2{ .x = 16, .y = 20 };

var tooltip: struct {
    state: union(enum) {
        disabled,
        delay: struct { timer: i32, pos: clay.Vector2 },
        enabled: struct { pos: clay.Vector2 },
    },
    msg: std.ArrayListUnmanaged(u8),
} = .{
    .state = .disabled,
    .msg = .{},
};

pub fn update(pos: clay.Vector2) ?@TypeOf(tooltip.msg.writer(undefined)) {
    const reset = @TypeOf(tooltip.state){ .delay = .{ .timer = tooltip_duration, .pos = pos } };
    switch (tooltip.state) {
        .disabled => {
            tooltip.state = reset;
        },
        .delay => |state| if (meta.eql(state.pos, pos)) {
            const delta_ms: i32 = @intFromFloat(rl.getFrameTime() * time.ms_per_s);
            tooltip.state.delay.timer -= delta_ms;
            if (tooltip.state.delay.timer <= 0) {
                tooltip.state = @TypeOf(tooltip.state){ .enabled = .{ .pos = pos } };
                tooltip.msg.clearRetainingCapacity();
                return tooltip.msg.writer(main.alloc);
            }
        } else {
            tooltip.state = reset;
        },
        .enabled => |state| if (!meta.eql(state.pos, pos)) {
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
            if (pos.y + 25 > @as(f32, @floatFromInt(rl.getScreenHeight()))) pos.y -= 65;
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
