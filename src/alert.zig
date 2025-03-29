const std = @import("std");
const process = std.process;
const ascii = std.ascii;
const time = std.time;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const themes = @import("themes.zig");
const Model = @import("Model.zig");

const error_duration = 1_500;
const error_fade_duration = 300;
const unexpected_error = "Unexpected Error";

var alert: struct { timer: ?u32, msg: main.ArrayList(u8) } = .{ .timer = null, .msg = .empty };

pub fn deinit() void {
    alert.msg.deinit(main.alloc);
}

pub fn update(err: anyerror) void {
    if (err == error.OutOfMemory) process.abort();
    alert.timer = 0;
    alert.msg.clearRetainingCapacity();
    var writer = alert.msg.writer(main.alloc);
    switch (err) {
        Model.Error.OsNotSupported => writer.writeAll("Action not supported on this system.") catch process.abort(),
        Model.Error.ExeNotFound => writer.writeAll("Failed to open new window.") catch process.abort(),
        Model.Error.AlreadyExists => writer.writeAll("A file with this name already exists.") catch process.abort(),
        Model.Error.DeleteDirFailure => writer.writeAll("Failed to delete folder.") catch process.abort(),
        Model.Error.DeleteFileFailure => writer.writeAll("Failed to delete file.") catch process.abort(),
        Model.Error.RestoreFailure => writer.writeAll("Failed to restore from Recycle Bin.") catch process.abort(),
        Model.Error.DirAccessDenied, Model.Error.OpenDirFailure => writer.writeAll("Unable to open this folder.") catch process.abort(),
        else => {
            const err_name = @errorName(err);
            _ = writer.writeAll("Error: \"") catch process.abort();
            for (err_name, 0..) |c, i| {
                if (ascii.isUpper(c) and i != 0) writer.writeByte(' ') catch process.abort();
                writer.writeByte(ascii.toLower(c)) catch process.abort();
            }
            writer.writeByte('"') catch process.abort();
        },
    }
}

pub fn updateFmt(comptime format: []const u8, args: anytype) void {
    alert.timer = 0;
    alert.msg.clearRetainingCapacity();
    alert.msg.writer(main.alloc).print("Error: " ++ format, args) catch
        alert.msg.appendSlice(main.alloc, unexpected_error) catch process.abort();
}

pub inline fn updateClay(err_data: clay.ErrorData) void {
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
            .id = clay.id("ErrorModal"),
            .layout = .{
                .sizing = .{ .height = .fixed(60) },
                .padding = .horizontal(12),
                .child_alignment = .center,
            },
            .bg_color = themes.opacity(themes.current.alert, alpha),
            .floating = .{
                .offset = .{ .x = -24, .y = -24 },
                .z_index = 1,
                .attach_points = .{ .element = .right_bottom, .parent = .right_bottom },
                .pointer_capture_mode = .passthrough,
                .attach_to = .root,
            },
            .corner_radius = main.rounded,
        })({
            main.textEx(.roboto, .lg, alert.msg.items, themes.opacity(themes.current.text, alpha));
        });
    }
}
