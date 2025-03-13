const std = @import("std");
const win = std.os.windows;

const clay = @import("clay");
const rl = @import("raylib");

pub const Color = win.DWORD;

pub const Event = enum {
    copy,
    paste,
    undo,
    redo,
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

const gwlp_wndproc = -4;
const wm_char = 0x0102;
const copy_char = 'C' - 0x40;
const paste_char = 'V' - 0x40;
const undo_char = 'Z' - 0x40;
const redo_char = 'Y' - 0x40;
var oldWindowProc: ?WNDPROC = null;
pub var event: ?Event = null;

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

pub extern fn DwmSetWindowAttribute(window: win.HWND, attr: win.DWORD, pvAttr: win.LPCVOID, cbAttr: win.DWORD) win.HRESULT;

pub extern fn ShellExecuteA(
    hwnd: ?win.HWND,
    lpOperation: ?win.LPCSTR,
    lpFile: win.LPCSTR,
    lpParameters: ?win.LPCSTR,
    lpDirectory: ?win.LPCSTR,
    nShowCmd: win.INT,
) win.HINSTANCE;

pub extern fn GetTimeZoneInformation(lpTimeZoneInformation: [*c]TIME_ZONE_INFORMATION) win.DWORD;

extern fn SetWindowLongPtrW(wnd: win.HWND, index: win.INT, newlong: win.LONG_PTR) win.LONG_PTR;
extern fn GetWindowLongPtrW(wnd: win.HWND, index: win.INT) win.LONG_PTR;
extern fn CallWindowProcW(lpPrevWndFunc: WNDPROC, win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) win.LRESULT;
