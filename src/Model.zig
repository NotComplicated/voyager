const std = @import("std");
const fs = std.fs;

const main = @import("main.zig");
const Input = @import("Input.zig");
const Tab = @import("Tab.zig");

const clay = @import("clay");
const rl = @import("raylib");

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
const tabs_height = 30;
const max_tab_width = 240;

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
    const width: usize = @intCast(rl.getScreenWidth());

    clay.ui()(.{
        .id = main.newId("Screen"),
        .layout = .{
            .sizing = clay.Element.Sizing.grow(.{}),
            .layout_direction = .top_to_bottom,
        },
        .rectangle = .{ .color = main.theme.base },
    })({
        clay.ui()(.{
            .id = main.newId("Tabs"),
            .layout = .{
                .sizing = .{
                    .width = clay.Element.Sizing.Axis.grow(.{}),
                    .height = clay.Element.Sizing.Axis.fixed(tabs_height),
                },
                .padding = clay.Padding.horizontal(8),
                .child_alignment = .{ .y = .center },
                .child_gap = 8,
            },
        })({
            const tab_width = @min(width / model.tabs.items.len, max_tab_width);

            for (model.tabs.items, 0..) |tab, index| {
                clay.ui()(.{
                    .id = main.newIdIndexed("Tab", @intCast(index)),
                    .layout = .{
                        .sizing = .{
                            .width = clay.Element.Sizing.Axis.fixed(@floatFromInt(tab_width)),
                            .height = clay.Element.Sizing.Axis.grow(.{}),
                        },
                        .child_alignment = .{ .x = .center, .y = .center },
                    },
                    .rectangle = .{ .color = main.theme.mantle, .corner_radius = main.rounded },
                })({
                    main.pointer();
                    main.text(tab.tabName());
                });
            }
        });

        model.tabs.items[model.curr_tab].render();
    });
}
