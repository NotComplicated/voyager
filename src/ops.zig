const std = @import("std");
const unicode = std.unicode;
const time = std.time;
const math = std.math;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const fs = std.fs;
const io = std.io;

const main = @import("main.zig");
const windows = @import("windows.zig");
const alert = @import("alert.zig");
const Model = @import("Model.zig");

const meta_header = &(.{0x02} ++ .{0x00} ** 7);

pub fn mkdir(path: []const u8) !void {
    fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn move(old_path: [*:0]const u8, new_path: [*:0]const u8) error{Failed}!void {
    if (!main.is_windows) @compileError("OS not supported");
    if (main.is_debug) log.debug("Move: {s} -> {s}", .{ old_path, new_path });
    if (windows.MoveFileExA(old_path, new_path, windows.move_flags) == 0) {
        alert.updateFmt("\"{s}\"", .{windows.getLastError()});
        return error.Failed;
    }
}

pub fn delete(path: [:0]const u8) Model.Error!(if (main.is_windows) ?windows.RecycleId else void) {
    if (!main.is_windows) return Model.Error.OsNotSupported; // TODO confirm delete

    const delete_time = windows.getFileTime();

    const disk_designator = fs.path.diskDesignatorWindows(path);
    if (disk_designator.len == 0) { // TODO fallback to confirm delete
        alert.updateFmt("Unexpected file path.", .{});
        return null;
    }

    var delete_error: Model.Error = undefined;
    const metadata = metadata: {
        if (fs.openFileAbsolute(path, .{})) |file| {
            defer file.close();
            delete_error = Model.Error.DeleteFileFailure;
            break :metadata file.metadata() catch return delete_error;
        } else |err| if (err == error.IsDir) {
            delete_error = Model.Error.DeleteDirFailure;
            var dir = fs.openDirAbsolute(path, .{ .iterate = true }) catch |dir_err| {
                alert.update(dir_err);
                return null;
            };
            defer dir.close();
            var metadata = dir.metadata() catch return delete_error;
            metadata.inner._size = 0;
            var walker = dir.walk(main.alloc) catch return delete_error;
            defer walker.deinit();
            while (walker.next() catch return delete_error) |entry| {
                if (entry.kind != .directory) {
                    const file = entry.dir.openFile(entry.basename, .{}) catch return delete_error;
                    defer file.close();
                    const metadata_inner = file.metadata() catch return delete_error;
                    metadata.inner._size += metadata_inner.size();
                }
            }
            break :metadata metadata;
        } else {
            alert.update(err);
            return null;
        }
    };

    const sid = windows.getSid() catch |err| {
        alert.update(err);
        return null;
    };
    const recycle_path = try fs.path.join(main.alloc, &.{ disk_designator, "$Recycle.Bin", sid });
    defer main.alloc.free(recycle_path);

    var prng = std.Random.DefaultPrng.init(@bitCast(time.milliTimestamp()));
    const rand = prng.random();
    var new_id: windows.RecycleId = undefined;
    for (&new_id) |*c| {
        const n = rand.uintLessThan(u8, 36);
        c.* = switch (n) {
            0...9 => '0' + n,
            10...35 => 'A' + (n - 10),
            else => unreachable,
        };
    }
    const trash_basename = "$R" ++ new_id;
    const meta_basename = "$I" ++ new_id;

    const name = fs.path.basename(path);
    const ext = extension(name);
    const path_fmt = "{s}{c}{s}{s}";
    const trash_path = try fmt.allocPrintZ(main.alloc, path_fmt, .{ recycle_path, fs.path.sep, trash_basename, ext });
    defer main.alloc.free(trash_path);
    const meta_path = try fmt.allocPrintZ(main.alloc, path_fmt, .{ recycle_path, fs.path.sep, meta_basename, ext });
    defer main.alloc.free(meta_path);

    const meta_temp_path = try fs.path.joinZ(main.alloc, &.{ main.temp_path, meta_basename });
    defer main.alloc.free(meta_temp_path);

    const meta = windows.RecycleMeta{
        .size = metadata.size(),
        .delete_time = delete_time,
        .restore_path = path,
    };
    writeRecycleMeta(meta_temp_path, meta) catch |err| {
        alert.update(err);
        return null;
    };

    move(meta_temp_path, meta_path) catch return null;
    move(path, trash_path) catch return null;

    return new_id;
}

fn writeRecycleMeta(path: []const u8, meta: windows.RecycleMeta) !void {
    const meta_file = try fs.createFileAbsolute(path, .{});
    defer meta_file.close();
    var buf_writer = io.bufferedWriter(meta_file.writer());
    const writer = buf_writer.writer();
    try writer.writeAll(meta_header);
    const size_le = mem.nativeToLittle(u64, meta.size);
    try writer.writeAll(&mem.toBytes(size_le));
    try writer.writeStructEndian(meta.delete_time, .little);
    const wide_path = try unicode.wtf8ToWtf16LeAllocZ(main.alloc, meta.restore_path);
    defer main.alloc.free(wide_path);
    const wide_path_z = wide_path.ptr[0 .. wide_path.len + 1];
    const wide_path_len_le = math.lossyCast(u32, mem.nativeToLittle(usize, wide_path_z.len));
    try writer.writeAll(&mem.toBytes(wide_path_len_le));
    try writer.writeAll(mem.sliceAsBytes(wide_path_z));
    try buf_writer.flush();
}

pub fn readRecycleMeta(path: []const u8) if (main.is_windows) Model.Error!windows.RecycleMeta else @compileError("OS not supported") {
    const file = fs.openFileAbsolute(path, .{}) catch return Model.Error.RestoreFailure;
    defer file.close();

    const meta_buf: []align(2) u8 = file.readToEndAllocOptions(
        main.alloc,
        10 * 1024,
        256,
        2,
        null,
    ) catch return Model.Error.RestoreFailure;
    defer main.alloc.free(meta_buf);

    const header_index = mem.indexOf(u8, meta_buf, meta_header) orelse return Model.Error.RestoreFailure;
    var meta_buf_stream = io.fixedBufferStream(meta_buf[header_index + meta_header.len ..]);
    const reader = meta_buf_stream.reader();

    var meta: windows.RecycleMeta = undefined;
    meta.size = reader.readInt(@TypeOf(meta.size), .little) catch return Model.Error.RestoreFailure;
    meta.delete_time = reader.readStructEndian(@TypeOf(meta.delete_time), .little) catch return Model.Error.RestoreFailure;
    meta.restore_path = restore: {
        const restore_len = reader.readInt(u32, .little) catch return Model.Error.RestoreFailure;
        const pos = meta_buf_stream.getPos() catch return Model.Error.RestoreFailure;
        if (pos % 2 != 0) return Model.Error.RestoreFailure; // misaligned byte
        const meta_buf_rem: []align(2) u8 = @alignCast(meta_buf_stream.buffer[pos..]);
        if (meta_buf_rem.len < restore_len * 2) return Model.Error.RestoreFailure;
        const restore_path_wide: [*]u16 = @ptrCast(meta_buf_rem);
        if (restore_path_wide[restore_len - 1] != 0) return Model.Error.RestoreFailure;
        break :restore try unicode.wtf16LeToWtf8AllocZ(main.alloc, restore_path_wide[0 .. restore_len - 1]);
    };

    return meta;
}

pub fn restore(disk: u8, ids: []const windows.RecycleId) if (main.is_windows) Model.Error!void else @compileError("OS not supported") {
    const sid = windows.getSid() catch |err| return alert.update(err);
    const recycle_path_fmt = "{c}:\\$Recycle.Bin\\{s}";
    const recycle_path = try fmt.allocPrint(main.alloc, recycle_path_fmt, .{ disk, sid });
    defer main.alloc.free(recycle_path);

    var dir = fs.openDirAbsolute(recycle_path, .{ .iterate = true }) catch return Model.Error.RestoreFailure;
    defer dir.close();
    var entries = dir.iterate();
    while (entries.next() catch return Model.Error.RestoreFailure) |entry| {
        for (ids) |id| {
            const meta_basename = ("$I" ++ id).*;
            if (mem.startsWith(u8, entry.name, &meta_basename)) {
                const recycle_item_path_fmt = recycle_path_fmt ++ "\\{s}{s}";
                const meta_path = try fmt.allocPrintZ(
                    main.alloc,
                    recycle_item_path_fmt,
                    .{ disk, sid, meta_basename, extension(entry.name) },
                );
                defer main.alloc.free(meta_path);
                const meta: windows.RecycleMeta = try readRecycleMeta(meta_path);

                const trash_path = trash: {
                    const index = mem.lastIndexOfScalar(u8, meta_path, '\\') orelse return Model.Error.RestoreFailure;
                    meta_path[index + 2] = 'R'; // replace $I with $R
                    break :trash meta_path;
                };
                move(trash_path, meta.restore_path) catch return Model.Error.RestoreFailure;
                fs.deleteFileAbsolute(meta_path) catch {};
            }
        }
    }
}

fn extension(name: []const u8) []const u8 { // subtly different from fs.path.extension for dotfile handling
    return if (mem.lastIndexOfScalar(u8, name, '.')) |i| name[i..] else "";
}
