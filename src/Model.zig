const std = @import("std");
const math = std.math;
const mem = std.mem;
const fs = std.fs;

const main = @import("main.zig");
const themes = @import("themes.zig");
const resources = @import("resources.zig");
const Input = @import("Input.zig");
const Tab = @import("Tab.zig");
const Entries = @import("Entries.zig");

const clay = @import("clay");
const rl = @import("raylib");

tabs: main.ArrayList(Tab),
curr_tab: TabIndex,
dragging: ?struct { x_pos: f32, tab_offset: f32 },

const Model = @This();

pub const Error = error{
    GracefulShutdown,
    OutOfMemory,
    OsNotSupported,
    OutOfBounds,
    OpenDirFailure,
    DirAccessDenied,
    AlreadyExists,
    DeleteDirFailure,
    DeleteFileFailure,
    RestoreFailure,
};

const TabIndex = u4;

pub const row_height = 30;
pub const tabs_height = 30;
const max_tab_width = 240;
const max_tabs = math.maxInt(TabIndex);
const new_tab_id = clay.id("NewTab");

fn getTabIds(key: []const u8) [max_tabs]clay.Id {
    @setEvalBranchQuota(1500); // not sure why this needs to be here
    var ids: [max_tabs]clay.Id = undefined;
    for (&ids, 0..) |*id, index| id.* = clay.idi(key, index);
    return ids;
}

const tab_ids = getTabIds("Tab");
const close_tab_ids = getTabIds("CloseTab");

pub fn init() Error!Model {
    var model = Model{
        .tabs = .empty,
        .curr_tab = 0,
        .dragging = null,
    };
    errdefer model.tabs.deinit(main.alloc);

    const path = fs.realpathAlloc(main.alloc, ".") catch return Error.OutOfMemory;
    defer main.alloc.free(path);

    try model.tabs.append(main.alloc, try .init(path));

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
                const offset = input.offset(tab_ids[index]) orelse return;
                model.dragging = .{ .x_pos = input.mouse_pos.x, .tab_offset = offset.x };
                return;
            }
            if (input.clicked(.middle)) {
                try model.closeTab(tab_index);
                return;
            }
        }
    }

    if (input.action) |action| switch (action) {
        .mouse => |mouse| if (mouse.button == .left) switch (mouse.state) {
            .pressed => {},
            .down => if (model.dragging) |*dragging| {
                dragging.x_pos = input.mouse_pos.x;
            },
            .released => model.dragging = null,
        },

        .key => |key| switch (key) {
            .char => |c| switch (c) {
                'w' => if (input.ctrl) {
                    try model.closeTab(model.curr_tab);
                    return;
                },
                't' => if (input.ctrl) {
                    try model.newTab();
                    return;
                },
                else => {},
            },
            .f => |f| switch (f) {
                5 => try model.currTab().reloadEntries(),
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

        .event => {},
    };

    if (try model.currTab().update(input)) |message| switch (message) {
        .open_dirs => |names| {
            defer main.alloc.free(names);
            var names_iter = mem.tokenizeScalar(u8, names, '\x00');
            const old_tab = model.curr_tab;
            const first_name = names_iter.next();
            while (names_iter.next()) |name| {
                try model.newTab();
                try model.currTab().openDir(name);
                model.curr_tab = old_tab;
            }
            model.curr_tab = old_tab;
            if (first_name) |name| {
                try model.currTab().openDir(name);
            }
        },
    };
}

pub fn render(model: Model) void {
    const tabs_id = clay.id("Tabs");
    const width: usize = @intCast(rl.getScreenWidth() -| tabs_height);

    clay.ui()(.{
        .id = clay.id("Screen"),
        .layout = .{
            .sizing = .grow(.{}),
            .layout_direction = .top_to_bottom,
        },
        .bg_color = themes.current.base,
    })({
        clay.ui()(.{
            .id = tabs_id,
            .layout = .{
                .sizing = .{
                    .width = .grow(.{}),
                    .height = .fixed(tabs_height),
                },
                .padding = .horizontal(8),
                .child_alignment = .{ .y = .center },
                .child_gap = 0,
            },
            .bg_color = themes.current.bg,
        })({
            const tab_width = @min(width / model.tabs.items.len, max_tab_width);

            for (model.tabs.items, 0..) |tab, index| {
                const selected = index == model.curr_tab;
                const hovered = !selected and clay.pointerOver(tab_ids[index]);

                const floating = if (selected) if (model.dragging) |dragging| clay.Config.Floating{
                    .offset = .{ .x = dragging.x_pos - dragging.tab_offset },
                    .z_index = 2,
                    .parent_id = tabs_id.id,
                } else null else null;

                clay.ui()(.{
                    .id = tab_ids[index],
                    .layout = .{
                        .sizing = .{
                            .width = .fixed(@floatFromInt(tab_width)),
                            .height = .grow(.{}),
                        },
                        .child_alignment = .{ .x = .center, .y = .center },
                    },
                    .floating = floating,
                    .bg_color = if (hovered)
                        themes.current.bright
                    else if (selected)
                        themes.current.base
                    else
                        themes.current.dim,
                })({
                    clay.ui()(.{
                        .layout = .{
                            .sizing = .fixed(tabs_height),
                        },
                        .image = .{
                            .image_data = if (hovered)
                                &resources.images.tab_left_bright
                            else if (selected)
                                &resources.images.tab_left
                            else
                                &resources.images.tab_left_dim,
                            .source_dimensions = .square(tabs_height),
                        },
                    })({});

                    clay.ui()(.{ .layout = .{ .sizing = .grow(.{}) } })({});

                    const name = tab.tabName();
                    const chars = tab_width / 16;
                    if (name.len > chars) {
                        main.textEx(.roboto, .sm, name[0..chars -| "...".len], themes.current.dim_text);
                        main.textEx(.roboto, .sm, "...", themes.current.dim_text);
                    } else {
                        main.textEx(.roboto, .sm, name, themes.current.dim_text);
                    }

                    clay.ui()(.{ .layout = .{ .sizing = .grow(.{}) } })({});

                    clay.ui()(.{
                        .id = close_tab_ids[index],
                        .layout = .{
                            .sizing = .{
                                .width = .fixed(9),
                                .height = .fixed(tabs_height),
                            },
                        },
                        .image = .{
                            .image_data = if (!hovered and !selected) &resources.images.x_dim else &resources.images.x,
                            .source_dimensions = .{ .width = 9, .height = tabs_height },
                        },
                    })({
                        main.pointer();
                    });

                    clay.ui()(.{
                        .layout = .{
                            .sizing = .fixed(tabs_height),
                        },
                        .image = .{
                            .image_data = if (hovered)
                                &resources.images.tab_right_bright
                            else if (selected)
                                &resources.images.tab_right
                            else
                                &resources.images.tab_right_dim,
                            .source_dimensions = .square(tabs_height),
                        },
                    })({});
                });
            }

            if (model.tabs.items.len < max_tabs) {
                const x_offset = @min(width - 8, model.tabs.items.len * tab_width + 4);

                clay.ui()(.{
                    .id = new_tab_id,
                    .layout = .{
                        .sizing = .fixed(tabs_height),
                    },
                    .image = .{
                        .image_data = &resources.images.plus,
                        .source_dimensions = .square(tabs_height),
                    },
                    .floating = .{
                        .offset = .{ .x = @floatFromInt(x_offset) },
                        .z_index = 1,
                        .parent_id = tabs_id.id,
                    },
                })({
                    main.pointer();
                });
            }
        });

        model.currTab().render();
    });
}

fn currTab(model: anytype) if (@TypeOf(model) == *Model) *Tab else *const Tab {
    return &model.tabs.items[model.curr_tab];
}

fn newTab(model: *Model) Error!void {
    if (model.tabs.items.len == max_tabs) return;
    var new_tab = try model.currTab().clone();
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
