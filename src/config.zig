const std = @import("std");
const json = std.json;
const log = std.log;
const fs = std.fs;

const main = @import("main.zig");
const windows = @import("windows.zig");
const Model = @import("Model.zig");

const check_depth = 64;

var save_this_frame = false;

pub const Writer = json.WriteStream(fs.File.Writer, .{ .checked_to_fixed_depth = check_depth });

pub fn save() void {
    save_this_frame = true;
}

pub fn read() !json.Parsed(json.Value) {
    const config_file = try fs.openFileAbsolute(main.config_path, .{});
    defer config_file.close();
    var reader = json.reader(main.alloc, config_file.reader());
    defer reader.deinit();
    return json.parseFromTokenSource(json.Value, main.alloc, &reader, .{});
}

pub fn update(model: Model) void {
    if (!save_this_frame) return;
    save_this_frame = false;
    const maybe_err: ?anyerror = save: {
        const config_file = fs.createFileAbsolute(main.config_temp_path, .{}) catch |err| break :save err;
        var config_closed = false;
        defer if (!config_closed) {
            config_file.close();
            config_closed = true;
        };
        var writer = json.writeStreamMaxDepth(config_file.writer(), .{ .whitespace = .indent_2 }, check_depth);
        defer writer.deinit();
        model.save(&writer) catch |err| break :save err;
        if (!config_closed) {
            config_file.close();
            config_closed = true;
        }
        if (main.is_windows) {
            windows.moveFile(main.config_temp_path, main.config_path) catch |err| break :save err;
        } else @compileError("OS not supported");
        break :save null;
    };
    if (main.is_debug) if (maybe_err) |err| log.err("Failed to save config: {}", .{err});
}
