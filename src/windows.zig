const std = @import("std");
const unicode = std.unicode;
const math = std.math;
const time = std.time;
const log = std.log;
const mem = std.mem;
const win = std.os.windows;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");

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

pub fn getSid() error{ UserNotFound, LookupError, ConvertError }![]const u8 {
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
