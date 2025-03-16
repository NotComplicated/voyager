const std = @import("std");
const process = std.process;
const ascii = std.ascii;
const time = std.time;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const Model = @import("Model.zig");

const error_duration = 1_500;
const error_fade_duration = 300;
const unexpected_error = "Unexpected Error";

var alert: struct { timer: ?u32, msg: std.ArrayListUnmanaged(u8) } = .{ .timer = null, .msg = .{} };

pub fn deinit() void {
    alert.msg.deinit(main.alloc);
}

pub fn update(err: anyerror) void {
    if (err == error.OutOfMemory) process.abort();
    alert.timer = 0;
    alert.msg.clearRetainingCapacity();
    var writer = alert.msg.writer(main.alloc);
    switch (err) {
        Model.Error.OsNotSupported => _ = writer.write("Error: OS not yet supported") catch process.abort(),
        Model.Error.DeleteDirFailure => _ = writer.write("Failed to delete folder.") catch process.abort(),
        Model.Error.DeleteFileFailure => _ = writer.write("Failed to delete file.") catch process.abort(),
        Model.Error.DirAccessDenied, Model.Error.OpenDirFailure => {
            _ = writer.write("Error: Unable to open this folder") catch process.abort();
        },
        else => {
            const err_name = @errorName(err);
            _ = writer.write("Error: \"") catch process.abort();
            for (err_name, 0..) |c, i| {
                if (ascii.isUpper(c) and i != 0) {
                    _ = writer.writeByte(' ') catch process.abort();
                }
                _ = writer.writeByte(ascii.toLower(c)) catch process.abort();
            }
            _ = writer.writeByte('"') catch process.abort();
        },
    }
}

pub fn updateFmt(comptime format: []const u8, args: anytype) void {
    alert.timer = 0;
    alert.msg.clearRetainingCapacity();
    alert.msg.writer(main.alloc).print("Error: " ++ format, args) catch
        alert.msg.appendSlice(main.alloc, unexpected_error) catch process.abort();
}

pub inline fn updateClay(err_data: clay.Error.Data) void {
    alert.timer = 0;
    alert.msg.clearRetainingCapacity();
    alert.msg.appendSlice(main.alloc, "Error: ") catch process.abort();
    alert.msg.appendSlice(main.alloc, err_data.error_text) catch process.abort();
}

pub fn render() void {
    if (alert.timer) |*timer| {
        const delta_ms: u32 = @intFromFloat(rl.getFrameTime() * time.ms_per_s);
        timer.* +|= delta_ms;
        if (timer.* > error_duration) {
            alert.timer = null;
            return;
        }

        var alpha: f32 = 1;
        if (timer.* > error_duration - error_fade_duration) {
            alpha = @as(f32, @floatFromInt(error_duration - timer.*)) / @as(f32, @floatFromInt(error_fade_duration));
        }

        clay.ui()(.{
            .id = main.newId("ErrorModal"),
            .floating = .{
                .offset = .{ .x = -24, .y = -24 },
                .z_index = 1,
                .attachment = .{ .element = .right_bottom, .parent = .right_bottom },
                .pointer_capture_mode = .passthrough,
            },
            .layout = .{
                .sizing = .{ .height = clay.Element.Sizing.Axis.fixed(60) },
                .padding = clay.Padding.horizontal(12),
                .child_alignment = clay.Element.Config.Layout.ChildAlignment.center,
            },
            .rectangle = .{
                .color = main.opacity(main.theme.alert, alpha),
                .corner_radius = main.rounded,
            },
        })({
            main.textEx(.roboto, .lg, alert.msg.items, main.opacity(main.theme.text, alpha));
        });
    }
}
