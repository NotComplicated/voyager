const std = @import("std");
const math = std.math;
const meta = std.meta;
const fs = std.fs;

const main = @import("main.zig");
const resources = @import("resources.zig");
const Input = @import("Input.zig");
const Tab = @import("Tab.zig");

const clay = @import("clay");
const rl = @import("raylib");

tabs: std.ArrayListUnmanaged(Tab),
curr_tab: TabIndex,

const Model = @This();

pub const Error = error{
    GracefulShutdown,
    OutOfMemory,
    OsNotSupported,
    OutOfBounds,
    OpenDirFailure,
    DirAccessDenied,
    DeleteDirFailure,
    DeleteFileFailure,
};

const TabIndex = u4;

pub const row_height = 30;
const tabs_height = 30;
const max_tab_width = 240;
const max_tabs = math.maxInt(TabIndex);
const new_tab_id = main.newId("NewTab");
const tab_ids = ids: {
    var ids: [max_tabs]clay.Element.Config.Id = undefined;
    for (&ids, 0..) |*id, index| id.* = main.newIdIndexed("Tab", index);
    break :ids ids;
};
const close_tab_ids = ids: {
    var ids: [max_tabs]clay.Element.Config.Id = undefined;
    for (&ids, 0..) |*id, index| id.* = main.newIdIndexed("CloseTab", index);
    break :ids ids;
};

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
    if (clay.pointerOver(new_tab_id) and input.clicked(.left)) try model.newTab();
    for (0..model.tabs.items.len) |index| {
        const tab_index: TabIndex = @intCast(index);
        if (clay.pointerOver(close_tab_ids[index]) and input.clicked(.left)) {
            try model.closeTab(tab_index);
            return;
        } else if (clay.pointerOver(tab_ids[index])) {
            if (input.clicked(.left)) {
                model.curr_tab = tab_index;
                return;
            }
            if (input.clicked(.middle)) {
                try model.closeTab(tab_index);
                return;
            }
        }
    }

    if (input.action) |action| switch (action) {
        .key => |key| switch (key) {
            .char => |c| switch (c) {
                'w' => if (input.ctrl) {
                    try model.closeTab(model.curr_tab);
                    return;
                },
                'n' => if (input.ctrl) {
                    try model.newTab();
                    return;
                },
                else => {},
            },
            .tab => if (input.ctrl) {
                const last_tab: TabIndex = @intCast(model.tabs.items.len - 1);
                model.curr_tab = if (input.shift)
                    if (model.curr_tab == 0) last_tab else model.curr_tab - 1
                else if (model.curr_tab == last_tab) 0 else model.curr_tab + 1;
                return;
            },
            else => {},
        },
        else => {},
    };

    try model.tabs.items[model.curr_tab].update(input);
}

pub fn render(model: Model) void {
    const width: usize = @intCast(rl.getScreenWidth() -| tabs_height);

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
                .child_gap = 0,
            },
            .rectangle = .{ .color = main.theme.bg },
        })({
            const tab_width = @min(width / model.tabs.items.len, max_tab_width);

            for (model.tabs.items, 0..) |tab, index| {
                const selected = index == model.curr_tab;
                const hovered = !selected and clay.pointerOver(tab_ids[index]);

                clay.ui()(.{
                    .id = tab_ids[index],
                    .layout = .{
                        .sizing = .{
                            .width = clay.Element.Sizing.Axis.fixed(@floatFromInt(tab_width)),
                            .height = clay.Element.Sizing.Axis.grow(.{}),
                        },
                        .child_alignment = .{ .x = .center, .y = .center },
                    },
                    .rectangle = .{
                        .color = if (hovered)
                            main.theme.bright
                        else if (selected)
                            main.theme.base
                        else
                            main.theme.dim,
                    },
                })({
                    clay.ui()(.{
                        .layout = .{
                            .sizing = clay.Element.Sizing.fixed(tabs_height),
                        },
                        .image = .{
                            .image_data = if (hovered)
                                &resources.images.tab_left_bright
                            else if (selected)
                                &resources.images.tab_left
                            else
                                &resources.images.tab_left_dim,
                            .source_dimensions = clay.Dimensions.square(tabs_height),
                        },
                    })({});

                    clay.ui()(.{ .layout = .{ .sizing = clay.Element.Sizing.grow(.{}) } })({});
                    main.textEx(.roboto, .sm, tab.tabName(), main.theme.dim_text);
                    clay.ui()(.{ .layout = .{ .sizing = clay.Element.Sizing.grow(.{}) } })({});

                    clay.ui()(.{
                        .id = close_tab_ids[index],
                        .layout = .{
                            .sizing = .{
                                .width = clay.Element.Sizing.Axis.fixed(9),
                                .height = clay.Element.Sizing.Axis.fixed(tabs_height),
                            },
                        },
                        .image = .{
                            .image_data = if (!hovered and !selected) &resources.images.x_dim else &resources.images.x,
                            .source_dimensions = clay.Dimensions{ .width = 9, .height = tabs_height },
                        },
                    })({
                        main.pointer();
                    });

                    clay.ui()(.{
                        .layout = .{
                            .sizing = clay.Element.Sizing.fixed(tabs_height),
                        },
                        .image = .{
                            .image_data = if (hovered)
                                &resources.images.tab_right_bright
                            else if (selected)
                                &resources.images.tab_right
                            else
                                &resources.images.tab_right_dim,
                            .source_dimensions = clay.Dimensions.square(tabs_height),
                        },
                    })({});
                });
            }

            if (model.tabs.items.len < max_tabs) {
                clay.ui()(.{
                    .id = new_tab_id,
                    .layout = .{
                        .sizing = clay.Element.Sizing.fixed(tabs_height),
                    },
                    .image = .{
                        .image_data = &resources.images.plus,
                        .source_dimensions = clay.Dimensions.square(tabs_height),
                    },
                })({
                    main.pointer();
                });
            }
        });

        model.tabs.items[model.curr_tab].render();
    });
}

fn newTab(model: *Model) Error!void {
    if (model.tabs.items.len == max_tabs) return;
    var new_tab = try model.tabs.items[model.curr_tab].clone();
    errdefer new_tab.deinit();
    try model.tabs.append(main.alloc, new_tab);
    model.curr_tab = @intCast(model.tabs.items.len - 1);
}

fn closeTab(model: *Model, index: TabIndex) Error!void {
    if (model.tabs.items.len == 1) return Error.GracefulShutdown;
    if (index >= model.tabs.items.len) return Error.OutOfBounds;
    model.tabs.items[index].deinit();
    _ = model.tabs.orderedRemove(index);
    if (model.curr_tab >= index) model.curr_tab -|= 1;
}
