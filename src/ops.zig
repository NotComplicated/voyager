const std = @import("std");
const unicode = std.unicode;
const time = std.time;
const math = std.math;
const fmt = std.fmt;
const mem = std.mem;
const fs = std.fs;

const main = @import("main.zig");
const windows = @import("windows.zig");
const alert = @import("alert.zig");
const Model = @import("Model.zig");

pub const RecycleId = [6]u8;

pub fn mkdir(path: []const u8) !void {
    fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn move(old_path: [*:0]const u8, new_path: [*:0]const u8) error{Failed}!void {
    if (!main.is_windows) @compileError("OS not supported");
    if (windows.MoveFileExA(old_path, new_path, windows.move_flags) == 0) {
        alert.updateFmt("\"{s}\"", .{windows.getLastError()});
        return error.Failed;
    }
}

pub fn delete(path: [:0]const u8) Model.Error!(if (main.is_windows) ?RecycleId else void) {
    if (!main.is_windows) return Model.Error.OsNotSupported; // TODO

    const delete_time = windows.getFileTime();

    const disk_designator = fs.path.diskDesignatorWindows(path);
    if (disk_designator.len == 0) {
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

    var maybe_sid_string: windows.String = null;
    defer if (maybe_sid_string) |sid_string| windows.free(sid_string);
    sid: {
        var username_buf: [128:0]u8 = undefined;
        var username_size: windows.BufSize = @intCast(username_buf.len);
        if (windows.GetUserNameExA(.sam_compatible, &username_buf, &username_size) == 0) break :sid;
        var sid_bytes: [256]u8 = undefined;
        const sid: *windows.SID = @ptrCast(mem.alignInBytes(&sid_bytes, @alignOf(windows.SID)).?);
        var sid_size: windows.BufSize = @intCast(sid_bytes.len - (@intFromPtr(&sid_bytes) - @intFromPtr(sid)));
        var domain_buf: [128:0]u8 = undefined;
        var domain_size: windows.BufSize = @intCast(domain_buf.len);
        var use: windows.SID_NAME_USE = undefined;
        const res = windows.LookupAccountNameA(null, &username_buf, sid, &sid_size, &domain_buf, &domain_size, &use);
        if (res == 0) break :sid;
        if (windows.ConvertSidToStringSidA(sid, &maybe_sid_string) == 0) break :sid;
    }
    const sid_string = maybe_sid_string orelse return delete_error;
    const sid_slice = mem.span(sid_string);

    const recycle_path = try fs.path.joinZ(main.alloc, &.{ disk_designator, "$Recycle.Bin", sid_slice });
    defer main.alloc.free(recycle_path);

    var prng = std.Random.DefaultPrng.init(@bitCast(time.milliTimestamp()));
    const rand = prng.random();
    var new_id: RecycleId = undefined;
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
    const trash_path = try fmt.allocPrintZ(main.alloc, path_fmt, .{ recycle_path, fs.path.sep, &trash_basename, ext });
    defer main.alloc.free(trash_path);
    const meta_path = try fmt.allocPrintZ(main.alloc, path_fmt, .{ recycle_path, fs.path.sep, &meta_basename, ext });
    defer main.alloc.free(meta_path);

    const meta_temp_path = try fs.path.joinZ(main.alloc, &.{ main.temp_path, name });
    defer main.alloc.free(meta_temp_path);

    {
        const meta_file = fs.createFileAbsolute(meta_temp_path, .{}) catch |err| {
            alert.update(err);
            return null;
        };
        defer meta_file.close();
        const meta_writer = meta_file.writer();
        meta_writer.writeAll(&(.{0x02} ++ .{0x00} ** 7)) catch return delete_error;
        const size_le = mem.nativeToLittle(u64, metadata.size());
        meta_writer.writeAll(&mem.toBytes(size_le)) catch return delete_error;
        meta_writer.writeStructEndian(delete_time, .little) catch return delete_error;
        const wide_path = unicode.wtf8ToWtf16LeAllocZ(main.alloc, path) catch return delete_error;
        defer main.alloc.free(wide_path);
        const wide_path_z = wide_path[0 .. wide_path.len + 1];
        const wide_path_len_le = math.lossyCast(u32, mem.nativeToLittle(usize, wide_path_z.len));
        meta_writer.writeAll(&mem.toBytes(wide_path_len_le)) catch return delete_error;
        meta_writer.writeAll(mem.sliceAsBytes(wide_path_z)) catch return delete_error;
    }

    move(meta_temp_path, meta_path) catch return null;
    move(path, trash_path) catch return null;

    return new_id;
}
