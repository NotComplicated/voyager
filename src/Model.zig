const std = @import("std");
const fs = std.fs;

const main = @import("main.zig");
const Input = @import("Input.zig");
const Tab = @import("Tab.zig");

tabs: std.ArrayListUnmanaged(Tab),
curr_tab: u5,

const Model = @This();

pub const Error = error{
    OutOfMemory,
    OsNotSupported,
    OutOfBounds,
    OpenDirFailure,
    DirAccessDenied,
    DeleteDirFailure,
    DeleteFileFailure,
};

pub const row_height = 30;

pub fn init() Error!Model {
    var model = Model{
        .tabs = .{},
        .curr_tab = 0,
    };
    errdefer model.tabs.deinit(main.alloc);

    const path = fs.realpathAlloc(main.alloc, ".") catch return Error.OutOfMemory;
    defer main.alloc.free(path);

    try model.tabs.append(main.alloc, try Tab.init(path));

    return model;
}

pub fn deinit(model: *Model) void {
    for (model.tabs.items) |*tab| tab.deinit();
    model.tabs.deinit(main.alloc);
}

pub fn update(model: *Model, input: Input) Error!void {
    try model.tabs.items[model.curr_tab].update(input);
}

pub fn render(model: Model) void {
    model.tabs.items[model.curr_tab].render();
}
