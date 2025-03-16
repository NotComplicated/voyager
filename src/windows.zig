const std = @import("std");
const time = std.time;
const win = std.os.windows;

const clay = @import("clay");
const rl = @import("raylib");

pub const Color = win.DWORD;
pub const BufSize = win.ULONG;
pub const String = ?win.LPSTR;

pub const Event = enum {
    copy,
    paste,
    undo,
    redo,
};

pub const NameFormat = enum(win.INT) {
    sam_compatible = 2,
    display = 3,
};

const WNDPROC = @TypeOf(&newWindowProc);

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

pub const SID_IDENTIFIER_AUTHORITY = extern struct {
    value: [6]win.BYTE,
};

pub const SID = extern struct {
    revision: win.BYTE,
    sub_authority_count: win.BYTE,
    identifier_authority: SID_IDENTIFIER_AUTHORITY,
    sub_authority: [1]win.DWORD,
};

pub const SID_NAME_USE = enum(win.INT) {
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
};

pub const dwma_caption_color = 35;
const gwlp_wndproc = -4;
const wm_char = 0x0102;
const copy_char = 'C' - 0x40;
const paste_char = 'V' - 0x40;
const undo_char = 'Z' - 0x40;
const redo_char = 'Y' - 0x40;
var oldWindowProc: ?WNDPROC = null;
pub var event: ?Event = null;

pub const free = win.LocalFree;

pub fn init() void {
    const handle = getHandle();
    oldWindowProc = @ptrFromInt(@as(usize, @intCast(GetWindowLongPtrW(handle, gwlp_wndproc))));
    _ = SetWindowLongPtrW(handle, gwlp_wndproc, @intCast(@intFromPtr(&newWindowProc)));
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

pub fn moveFile(old_path: []const u8, new_path: []const u8) !void {
    const old_path_w = try win.sliceToPrefixedFileW(null, old_path);
    const new_path_w = try win.sliceToPrefixedFileW(null, new_path);
    return win.MoveFileExW(
        old_path_w.span().ptr,
        new_path_w.span().ptr,
        win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH,
    );
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
            else => {},
        },
        else => {},
    }
    return CallWindowProcW(oldWindowProc.?, handle, message, wparam, lparam);
}

pub extern fn DwmSetWindowAttribute(window: win.HWND, attr: win.DWORD, pvattr: win.LPCVOID, cbattr: win.DWORD) win.HRESULT;

pub extern fn ShellExecuteA(
    hwnd: ?win.HWND,
    lpOperation: ?win.LPCSTR,
    lpFile: win.LPCSTR,
    lpParameters: ?win.LPCSTR,
    lpDirectory: ?win.LPCSTR,
    nShowCmd: win.INT,
) win.HINSTANCE;

pub extern fn GetTimeZoneInformation(lpTimeZoneInformation: [*c]TIME_ZONE_INFORMATION) win.DWORD;

pub extern fn GetUserNameExA(name_format: NameFormat, name_buf: win.LPSTR, size: *win.ULONG) win.BOOLEAN;
pub extern fn LookupAccountNameA(
    system_name: ?win.LPCSTR,
    account_name: win.LPCSTR,
    sid: ?*SID,
    sid_len: *win.DWORD,
    referenced_domain_name: ?win.LPSTR,
    referenced_domain_name_len: *win.DWORD,
    use: *SID_NAME_USE,
) win.BOOL;
pub extern fn ConvertSidToStringSidA(sid: *SID, string: *?win.LPSTR) win.BOOL;

extern fn SetWindowLongPtrW(wnd: win.HWND, index: win.INT, newlong: win.LONG_PTR) win.LONG_PTR;
extern fn GetWindowLongPtrW(wnd: win.HWND, index: win.INT) win.LONG_PTR;
extern fn CallWindowProcW(prev_wnd_func: WNDPROC, win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) win.LRESULT;
