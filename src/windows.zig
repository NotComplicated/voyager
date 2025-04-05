const std = @import("std");
const unicode = std.unicode;
const math = std.math;
const time = std.time;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const win = std.os.windows;
const fs = std.fs;
const io = std.io;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const alert = @import("alert.zig");
const Error = @import("error.zig").Error;

const Color = win.DWORD;

pub const Event = union(enum) {
    copy,
    paste,
    undo,
    redo,
    special_char: u21,
};

pub const NameFormat = enum(win.INT) {
    sam_compatible = 2,
    display = 3,
    _,
};

pub const SYSTEMTIME = extern struct {
    year: win.WORD,
    month: win.WORD,
    day_of_week: win.WORD,
    day: win.WORD,
    hour: win.WORD,
    minute: win.WORD,
    second: win.WORD,
    milliseconds: win.WORD,
};

pub const TIME_ZONE_INFORMATION = extern struct {
    bias: win.LONG,
    standard_name: [32]win.WCHAR,
    standard_date: SYSTEMTIME,
    standard_bias: win.LONG,
    daylight_name: [32]win.WCHAR,
    daylight_date: SYSTEMTIME,
    daylight_bias: win.LONG,
};

pub const RecycleId = [6]u8;

pub const RecycleMeta = struct {
    size: u64,
    delete_time: win.FILETIME,
    restore_path: [:0]const u8,
};

pub const DrivesIterator = struct {
    iter: Set.Iterator(.{}),

    const Set = std.StaticBitSet(@bitSizeOf(@TypeOf(GetLogicalDrives())));
    pub const Drive = struct {
        path: [3]u8,
        free_space: u64,
        total_space: u64,
        type: ?[]const u8,
    };

    pub fn init() @This() {
        return .{ .iter = (Set{ .mask = GetLogicalDrives() }).iterator(.{}) };
    }

    pub fn next(self: *@This()) ?Drive {
        const letter: u8 = @intCast('A' + (self.iter.next() orelse return null));
        const path: [3:0]u8 = .{ letter, ':', '\\' };
        var disk_space: DISK_SPACE_INFORMATION = undefined;
        const free_space, const total_space = if (GetDiskSpaceInformationA(&path, &disk_space) == 0) space: {
            const bytes_per_au = disk_space.bytes_per_sector * disk_space.sectors_per_allocation_unit;
            const free_space = disk_space.caller_available_allocation_units * bytes_per_au;
            const total_space = disk_space.caller_total_allocation_units * bytes_per_au;
            break :space .{ free_space, total_space };
        } else .{ 0, 0 };

        return .{
            .path = path,
            .free_space = free_space,
            .total_space = total_space,
            .type = GetDriveTypeA(&path).toString(),
        };
    }
};

const WNDPROC = @TypeOf(&newWindowProc);

const SID = extern struct {
    revision: win.BYTE,
    sub_authority_count: win.BYTE,
    identifier_authority: SID_IDENTIFIER_AUTHORITY,
    sub_authority: [1]win.DWORD, // flexible c struct
};

const SID_IDENTIFIER_AUTHORITY = extern struct {
    value: [6]win.BYTE,
};

const SID_NAME_USE = enum(win.INT) {
    user = 1,
    group,
    domain,
    alias,
    well_known_group,
    deleted_account,
    invalid,
    unknown,
    computer,
    label,
    logon_session,
    _,
};

const DriveType = enum(win.UINT) {
    unknown = 0,
    no_root_dir,
    removable,
    fixed,
    remote,
    cdrom,
    ramdisk,
    _,

    pub fn toString(drive_type: DriveType) ?[]const u8 {
        return switch (drive_type) {
            .removable => "USB",
            .fixed => "Disk",
            .remote => "Network",
            .cdrom => "CD",
            .ramdisk => "RAM",
            else => null,
        };
    }
};

const DISK_SPACE_INFORMATION = extern struct {
    actual_total_allocation_units: win.ULONGLONG,
    actual_available_allocation_units: win.ULONGLONG,
    actual_pool_unavailable_allocation_units: win.ULONGLONG,
    caller_total_allocation_units: win.ULONGLONG,
    caller_available_allocation_units: win.ULONGLONG,
    caller_pool_unavailable_allocation_units: win.ULONGLONG,
    used_allocation_units: win.ULONGLONG,
    total_reserved_allocation_units: win.ULONGLONG,
    volume_storage_reserve_allocation_units: win.ULONGLONG,
    available_committed_allocation_units: win.ULONGLONG,
    pool_available_allocation_units: win.ULONGLONG,
    sectors_per_allocation_unit: win.DWORD,
    bytes_per_sector: win.DWORD,
};

const meta_header = &(.{0x02} ++ .{0x00} ** 7);
const dwma_caption_color = 35;
const gwlp_wndproc = -4;
const wm_char = 0x0102;
const copy_char = 'C' - 0x40;
const paste_char = 'V' - 0x40;
const undo_char = 'Z' - 0x40;
const redo_char = 'Y' - 0x40;
var oldWindowProc: ?WNDPROC = null;
pub var event: ?Event = null;
var maybe_sid: ?[]u8 = null;
pub var vscode_available = false;

pub fn init() void {
    const handle = getHandle();
    oldWindowProc = @ptrFromInt(@as(usize, @intCast(GetWindowLongPtrW(handle, gwlp_wndproc))));
    _ = SetWindowLongPtrW(handle, gwlp_wndproc, @intCast(@intFromPtr(&newWindowProc)));

    const status = @intFromPtr(ShellExecuteA(getHandle(), null, "code", "--version", null, 0));
    if (status > 32) vscode_available = true;
}

pub fn deinit() void {
    if (maybe_sid) |sid| _ = LocalFree(sid.ptr);
}

pub fn colorFromClay(color: clay.Color) Color {
    return @as(Color, @intFromFloat(color.r)) + (@as(Color, @intFromFloat(color.g)) << 8) + (@as(Color, @intFromFloat(color.b)) << 16);
}

pub fn getHandle() win.HWND {
    return @ptrCast(rl.getWindowHandle());
}

pub fn getFileTime() win.FILETIME {
    return win.nanoSecondsToFileTime(time.nanoTimestamp());
}

pub fn getLastError() []const u8 {
    return @tagName(win.kernel32.GetLastError());
}

pub fn setTitleColor(color: clay.Color) void {
    _ = DwmSetWindowAttribute(
        getHandle(),
        dwma_caption_color,
        &colorFromClay(color),
        @sizeOf(Color),
    );
}

pub fn moveFile(old_path: [:0]const u8, new_path: [:0]const u8) !void {
    if (main.is_debug) log.debug("Move: {s} -> {s}", .{ old_path, new_path });
    return win.MoveFileEx(old_path, new_path, win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH);
}

pub fn shellExecStatusMessage(status: usize) []const u8 {
    return switch (status) {
        2 => "File not found.",
        3 => "Path not found.",
        5 => "Access denied.",
        8 => "Out of memory.",
        32 => "Dynamic-link library not found.",
        26 => "Cannot share an open file.",
        27 => "File association information not complete.",
        28 => "DDE operation timed out.",
        29 => "DDE operation failed.",
        30 => "DDE operation is busy.",
        31 => "File association not available.",
        else => "Unknown status code.",
    };
}

pub fn delete(path: [:0]const u8) Error!(if (main.is_windows) ?RecycleId else void) {
    if (!main.is_windows) @compileError("OS not supported");

    const delete_time = getFileTime();

    const disk_designator = fs.path.diskDesignatorWindows(path);
    if (disk_designator.len == 0) {
        alert.updateFmt("Unexpected file path.", .{});
        return null;
    }

    var delete_error: Error = undefined;
    const metadata = metadata: {
        if (fs.openFileAbsolute(path, .{})) |file| {
            defer file.close();
            delete_error = Error.DeleteFileFailure;
            break :metadata file.metadata() catch return delete_error;
        } else |err| if (err == error.IsDir) {
            delete_error = Error.DeleteDirFailure;
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

    const sid = getSid() catch |err| {
        alert.update(err);
        return null;
    };
    const recycle_path = try fs.path.join(main.alloc, &.{ disk_designator, "$Recycle.Bin", sid });
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
    const ext = extension(name);
    const path_fmt = "{s}{c}{s}{s}";
    const trash_path = try fmt.allocPrintZ(main.alloc, path_fmt, .{ recycle_path, fs.path.sep, trash_basename, ext });
    defer main.alloc.free(trash_path);
    const meta_path = try fmt.allocPrintZ(main.alloc, path_fmt, .{ recycle_path, fs.path.sep, meta_basename, ext });
    defer main.alloc.free(meta_path);

    const meta_temp_path = try fs.path.joinZ(main.alloc, &.{ main.temp_path, meta_basename });
    defer main.alloc.free(meta_temp_path);

    const meta = RecycleMeta{
        .size = metadata.size(),
        .delete_time = delete_time,
        .restore_path = path,
    };
    writeRecycleMeta(meta_temp_path, meta) catch |err| {
        alert.update(err);
        return null;
    };

    moveFile(meta_temp_path, meta_path) catch |err| {
        alert.update(err);
        return null;
    };
    moveFile(path, trash_path) catch |err| {
        alert.update(err);
        return null;
    };

    return new_id;
}

fn writeRecycleMeta(path: []const u8, meta: RecycleMeta) !void {
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

pub fn readRecycleMeta(path: []const u8) Error!RecycleMeta {
    if (!main.is_windows) @compileError("OS not supported");

    const file = fs.openFileAbsolute(path, .{}) catch return Error.RestoreFailure;
    defer file.close();

    const meta_buf: []align(2) u8 = file.readToEndAllocOptions(
        main.alloc,
        10 * 1024,
        256,
        2,
        null,
    ) catch return Error.RestoreFailure;
    defer main.alloc.free(meta_buf);

    const header_index = mem.indexOf(u8, meta_buf, meta_header) orelse return Error.RestoreFailure;
    var meta_buf_stream = io.fixedBufferStream(meta_buf[header_index + meta_header.len ..]);
    const reader = meta_buf_stream.reader();

    var meta: RecycleMeta = undefined;
    meta.size = reader.readInt(@TypeOf(meta.size), .little) catch return Error.RestoreFailure;
    meta.delete_time = reader.readStructEndian(@TypeOf(meta.delete_time), .little) catch return Error.RestoreFailure;
    meta.restore_path = restore: {
        const restore_len = reader.readInt(u32, .little) catch return Error.RestoreFailure;
        const pos = meta_buf_stream.getPos() catch return Error.RestoreFailure;
        if (pos % 2 != 0) return Error.RestoreFailure; // misaligned byte
        const meta_buf_rem: []align(2) u8 = @alignCast(meta_buf_stream.buffer[pos..]);
        if (meta_buf_rem.len < restore_len * 2) return Error.RestoreFailure;
        const restore_path_wide: [*]u16 = @ptrCast(meta_buf_rem);
        if (restore_path_wide[restore_len - 1] != 0) return Error.RestoreFailure;
        break :restore try unicode.wtf16LeToWtf8AllocZ(main.alloc, restore_path_wide[0 .. restore_len - 1]);
    };

    return meta;
}

pub fn restore(disk: u8, ids: []const RecycleId) Error!?[]const u8 {
    if (!main.is_windows) @compileError("OS not supported");

    const sid = getSid() catch |err| return {
        alert.update(err);
        return null;
    };
    const recycle_path_fmt = "{c}:\\$Recycle.Bin\\{s}";
    const recycle_path = try fmt.allocPrint(main.alloc, recycle_path_fmt, .{ disk, sid });
    defer main.alloc.free(recycle_path);

    var names = try std.ArrayList(u8).initCapacity(main.alloc, ids.len * 8);
    errdefer names.deinit();

    var dir = fs.openDirAbsolute(recycle_path, .{ .iterate = true }) catch return Error.RestoreFailure;
    defer dir.close();
    var entries = dir.iterate();
    while (entries.next() catch return Error.RestoreFailure) |entry| {
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
                const meta: RecycleMeta = try readRecycleMeta(meta_path);
                defer main.alloc.free(meta.restore_path);

                const trash_path = trash: {
                    const index = mem.lastIndexOfScalar(u8, meta_path, '\\') orelse return Error.RestoreFailure;
                    meta_path[index + 2] = 'R'; // replace $I with $R
                    break :trash meta_path;
                };
                moveFile(trash_path, meta.restore_path) catch return Error.RestoreFailure;
                fs.deleteFileAbsolute(meta_path) catch {};
                try names.appendSlice(fs.path.basename(meta.restore_path));
                try names.append(0);
            }
        }
    }

    return try names.toOwnedSlice();
}

fn extension(name: []const u8) []const u8 { // subtly different from fs.path.extension for dotfile handling
    return if (mem.lastIndexOfScalar(u8, name, '.')) |i| name[i..] else "";
}

fn getSid() error{ UserNotFound, LookupError, ConvertError }![]const u8 {
    if (maybe_sid) |sid| return sid;
    var username_buf: [128:0]u8 = undefined;
    var username_size: win.ULONG = @intCast(username_buf.len);
    if (GetUserNameExA(.sam_compatible, &username_buf, &username_size) == 0) return error.UserNotFound;
    var sid_bytes: [256]u8 = undefined;
    const sid: *SID = @ptrCast(mem.alignInBytes(&sid_bytes, @alignOf(SID)).?);
    var sid_size: win.ULONG = @intCast(sid_bytes.len - (@intFromPtr(&sid_bytes) - @intFromPtr(sid)));
    var domain_buf: [128:0]u8 = undefined;
    var domain_size: win.ULONG = @intCast(domain_buf.len);
    var use: SID_NAME_USE = undefined;
    const res = LookupAccountNameA(null, &username_buf, sid, &sid_size, &domain_buf, &domain_size, &use);
    if (res == 0) return error.LookupError;
    var converted_sid: ?win.LPSTR = null;
    if (ConvertSidToStringSidA(sid, &converted_sid) == 0 or converted_sid == null) return error.ConvertError;
    maybe_sid = mem.span(converted_sid.?);
    return maybe_sid.?;
}

fn newWindowProc(handle: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.C) win.LRESULT {
    switch (message) {
        wm_char => switch (wparam) {
            copy_char => event = .copy,
            paste_char => event = .paste,
            undo_char => event = .undo,
            redo_char => event = .redo,
            else => if (wparam > comptime unicode.utf8Decode2("¡".*) catch unreachable) {
                event = .{ .special_char = math.lossyCast(u21, wparam) };
            },
        },
        else => {},
    }
    return CallWindowProcW(oldWindowProc.?, handle, message, wparam, lparam);
}

pub extern fn ShellExecuteA(
    hwnd: ?win.HWND,
    lpOperation: ?win.LPCSTR,
    lpFile: win.LPCSTR,
    lpParameters: ?win.LPCSTR,
    lpDirectory: ?win.LPCSTR,
    nShowCmd: win.INT,
) callconv(.winapi) win.HINSTANCE;

pub extern fn GetTimeZoneInformation(lpTimeZoneInformation: [*c]TIME_ZONE_INFORMATION) callconv(.winapi) win.DWORD;

extern fn DwmSetWindowAttribute(window: win.HWND, attr: win.DWORD, pvattr: win.LPCVOID, cbattr: win.DWORD) callconv(.winapi) win.HRESULT;

extern fn GetUserNameExA(name_format: NameFormat, name_buf: win.LPSTR, size: *win.ULONG) callconv(.winapi) win.BOOLEAN;
extern fn LookupAccountNameA(
    system_name: ?win.LPCSTR,
    account_name: win.LPCSTR,
    sid: ?*SID,
    sid_len: *win.DWORD,
    referenced_domain_name: ?win.LPSTR,
    referenced_domain_name_len: *win.DWORD,
    use: *SID_NAME_USE,
) callconv(.winapi) win.BOOL;
extern fn ConvertSidToStringSidA(sid: *SID, string: *?win.LPSTR) callconv(.winapi) win.BOOL;

extern fn SetWindowLongPtrW(wnd: win.HWND, index: win.INT, newlong: win.LONG_PTR) callconv(.winapi) win.LONG_PTR;
extern fn GetWindowLongPtrW(wnd: win.HWND, index: win.INT) callconv(.winapi) win.LONG_PTR;
extern fn CallWindowProcW(prev_wnd_func: WNDPROC, win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT;

extern fn LocalFree(mem: win.HLOCAL) callconv(.winapi) ?win.HLOCAL;

extern fn GetLogicalDrives() callconv(.winapi) win.DWORD;

extern fn GetDiskSpaceInformationA(root_path: ?win.LPCSTR, disk_space_info: *DISK_SPACE_INFORMATION) callconv(.winapi) win.HRESULT;

extern fn GetDriveTypeA(root_path_name: ?win.LPCSTR) callconv(.winapi) DriveType;
