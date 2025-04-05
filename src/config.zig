const std = @import("std");
const json = std.json;
const log = std.log;
const fs = std.fs;

const main = @import("main.zig");
const windows = @import("windows.zig");

pub const Writer = struct {
    config_file: fs.File,
    json_writer: JsonWriter,

    pub const JsonWriter = json.WriteStream(fs.File.Writer, .{ .checked_to_fixed_depth = check_depth });

    const check_depth = 64;

    pub fn init() !Writer {
        var writer: Writer = undefined;
        writer.config_file = try fs.createFileAbsolute(main.config_temp_path, .{});
        writer.json_writer = json.writeStreamMaxDepth(
            writer.config_file.writer(),
            .{ .whitespace = .indent_2 },
            check_depth,
        );
    }

    pub fn deinit(writer: *Writer) void {
        writer.json_writer.deinit();
        writer.config_file.close();
        if (main.is_windows) {
            windows.moveFile(main.config_temp_path, main.config_path) catch |err| {
                if (main.is_debug) log.err("Failed to move file: {}", .{err});
            };
        } else @compileError("OS not supported");
    }

    pub fn write(writer: *Writer) *JsonWriter {
        return &writer.json_writer;
    }
};

pub fn read() !json.Parsed(json.Value) {
    const config_file = try fs.openFileAbsolute(main.config_path, .{});
    defer config_file.close();
    var reader = json.reader(main.alloc, config_file.reader());
    defer reader.deinit();
    return json.parseFromTokenSource(json.Value, main.alloc, &reader, .{});
}
