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
    log.debug("Move: {s} -> {s}", .{ old_path, new_path });
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
    const ext = if (mem.lastIndexOfScalar(u8, name, '.')) |i| name[i..] else "";
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
    const wide_path_z = wide_path[0 .. wide_path.len + 1];
    const wide_path_len_le = math.lossyCast(u32, mem.nativeToLittle(usize, wide_path_z.len));
    try writer.writeAll(&mem.toBytes(wide_path_len_le));
    try writer.writeAll(mem.sliceAsBytes(wide_path_z));
    try buf_writer.flush();
}

pub fn readRecycleMeta(path: []const u8) if (main.is_windows) Model.Error!windows.RecycleMeta else @compileError("OS not supported") {
    const sanity_check_size = 100 * 1024;
    const file = fs.openFileAbsolute(path, .{}) catch return Model.Error.RestoreFailure;
    defer file.close();
    const meta_buf = file.readToEndAlloc(main.alloc, sanity_check_size) catch return Model.Error.RestoreFailure;
    defer main.alloc.free(meta_buf);
    const header_index = mem.indexOf(u8, meta_buf, meta_header) orelse return Model.Error.RestoreFailure;
    var meta_buf_stream = io.fixedBufferStream(meta_buf[header_index + meta_header.len ..]);
    const reader = meta_buf_stream.reader();
    var meta: windows.RecycleMeta = undefined;
    meta.size = reader.readInt(@TypeOf(meta.size), .little) catch return Model.Error.RestoreFailure;
    meta.delete_time = reader.readStructEndian(@TypeOf(meta.delete_time), .little) catch return Model.Error.RestoreFailure;
    const restore_len = reader.readInt(u32, .little) catch return Model.Error.RestoreFailure;
    const restore_len_wide_z = restore_len * 2 + 2;
    const meta_buf_rem = meta_buf[meta_buf_stream.pos];
    if (meta_buf_rem.len < restore_len_wide_z) return Model.Error.RestoreFailure;
    if (!mem.endsWith(u8, meta_buf_rem[0..restore_len_wide_z], &.{ 0x00, 0x00 })) return Model.Error.RestoreFailure;
    meta.restore_path = try unicode.wtf16LeToWtf8AllocZ(main.alloc, meta_buf_rem[0..restore_len_wide_z]);
    return meta;
}

pub fn restore(disk: u8, id: windows.RecycleId) if (main.is_windows) Model.Error!void else @compileError("OS not supported") {
    const trash_basename = "$R" ++ id;
    const meta_basename = "$I" ++ id;
    const sid = windows.getSid() catch |err| return alert.update(err);
    const meta_path = try fmt.allocPrintZ(main.alloc, "{c}:\\$Recycle.Bin\\{s}\\{s}", &.{ disk, sid, meta_basename });
    defer main.alloc.free(meta_path);
    _ = trash_basename;
}
