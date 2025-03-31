const std = @import("std");
const process = std.process;
const math = std.math;
const mem = std.mem;
const fs = std.fs;

const main = @import("main.zig");
const themes = @import("themes.zig");
const resources = @import("resources.zig");
const draw = @import("draw.zig");
const windows = @import("windows.zig");
const Input = @import("Input.zig");
const Tab = @import("Tab.zig");
const Shortcuts = @import("Shortcuts.zig");
const Entries = @import("Entries.zig");

const clay = @import("clay");
const rl = @import("raylib");

tabs: main.ArrayList(Tab),
curr_tab: TabIndex,
tab_drag: ?struct { x_pos: f32, tab_offset: f32, dist: f32, dimming: i8 },
shortcuts: Shortcuts,

const Model = @This();

pub const Error = error{
    GracefulShutdown,
    OutOfMemory,
    OsNotSupported,
    ExeNotFound,
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
pub const tabs_height = 32;
const max_tab_width = 240;
const max_tabs = math.maxInt(TabIndex);
const new_tab_id = clay.id("NewTab");

fn getTabIds(key: []const u8) [max_tabs]clay.Id {
    @setEvalBranchQuota(1500);
    var ids: [max_tabs]clay.Id = undefined;
    for (&ids, 0..) |*id, index| id.* = clay.idi(key, index);
    return ids;
}

const tab_ids = getTabIds("Tab");
const close_tab_ids = getTabIds("CloseTab");

pub fn init(args: *process.ArgIterator) Error!Model {
    var model = Model{
        .tabs = .empty,
        .curr_tab = 0,
        .tab_drag = null,
        .shortcuts = .init,
    };

    const path = fs.realpathAlloc(main.alloc, args.next() orelse ".") catch return Error.OutOfMemory;
    defer main.alloc.free(path);
    try model.tabs.append(main.alloc, try .init(path, model.shortcuts.isBookmarked(path)));

    return model;
}

pub fn deinit(model: *Model) void {
    for (model.tabs.items) |*tab| tab.deinit();
    model.tabs.deinit(main.alloc);
    model.shortcuts.deinit();
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
                model.tab_drag = .{
                    .x_pos = input.mouse_pos.x,
                    .tab_offset = offset.x,
                    .dist = 0,
                    .dimming = 0,
                };
                return;
            }
            if (input.clicked(.middle)) {
                try model.closeTab(tab_index);
                return;
            }
        }
    }

    if (clay.pointerOver(Shortcuts.width_handle_id)) if (input.action) |action| switch (action) {
        .mouse => |mouse| if (mouse.button == .left) switch (mouse.state) {
            .pressed => model.shortcuts.dragging = true,
            .down, .released => {}, // handled down below
        },
        else => {},
    };

    if (try model.shortcuts.update(input)) |message| switch (message) {
        .open => |path| {
            const new_tab = try Tab.init(path, true);
            model.currTab().deinit();
            model.currTab().* = new_tab;
            return;
        },
        .bookmark_created => |path| {
            model.updateTabsBookmarked(path);
            return;
        },
        .bookmark_deleted => |path| {
            defer main.alloc.free(path);
            model.updateTabsBookmarked(path);
            return;
        },
    };
    if (model.shortcuts.isActive()) return;

    if (input.action) |action| switch (action) {
        .mouse => |mouse| if (mouse.button == .left) switch (mouse.state) {
            .pressed => {},
            .down => {
                if (model.tab_drag) |*dragging| {
                    if (dragging.dimming == 0 or dragging.dimming == 100) {
                        dragging.dist += @abs(dragging.x_pos - input.mouse_pos.x);
                        dragging.x_pos = input.mouse_pos.x;
                    }

                    const width: usize = @intCast(rl.getScreenWidth() -| tabs_height);
                    const tab_width: f32 = @floatFromInt(@min(width / model.tabs.items.len, max_tab_width));
                    const pos: usize = @intFromFloat(@max(0, dragging.x_pos - dragging.tab_offset + (tab_width / 2)) / tab_width);
                    if (pos < model.tabs.items.len and pos != model.curr_tab) {
                        mem.swap(Tab, model.currTab(), &model.tabs.items[pos]);
                        model.curr_tab = @intCast(pos);
                    }

                    if (model.tabs.items.len > 1) {
                        const onscreen = -30 < input.mouse_pos.x and
                            input.mouse_pos.x <= @as(f32, @floatFromInt(rl.getScreenWidth())) + 30 and
                            -50 < input.mouse_pos.y and
                            input.mouse_pos.y <= @as(f32, @floatFromInt(rl.getScreenHeight())) + 30;
                        const dim = math.lossyCast(i8, 500 * @as(f32, if (onscreen) -1 else 1) * rl.getFrameTime());
                        dragging.dimming = math.clamp(dragging.dimming +| dim, 0, 100);
                    }
                }
                if (model.shortcuts.dragging) {
                    model.shortcuts.width = math.clamp(
                        math.lossyCast(usize, input.mouse_pos.x),
                        Shortcuts.widths.min,
                        Shortcuts.widths.max,
                    );
                }
            },
            .released => {
                if (model.tab_drag) |dragging| {
                    if (dragging.dimming == 100) try model.popOutTab();
                    model.tab_drag = null;
                }
                model.shortcuts.dragging = false;
            },
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
                model.updateTabsBookmarked(model.currTab().dir());
                model.curr_tab = old_tab;
            }
            model.curr_tab = old_tab;
            if (first_name) |name| {
                try model.currTab().openDir(name);
                model.updateTabsBookmarked(model.currTab().dir());
            }
        },
        .open_parent_dir => {
            try model.currTab().openParentDir();
            model.updateTabsBookmarked(model.currTab().dir());
        },
        .toggle_bookmark => |path| {
            try model.shortcuts.toggleBookmark(path);
            model.updateTabsBookmarked(path);
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
        const tabs_padding = 8;

        clay.ui()(.{
            .id = tabs_id,
            .layout = .{
                .sizing = .{
                    .width = .grow(.{}),
                    .height = .fixed(tabs_height),
                },
                .padding = .horizontal(tabs_padding),
                .child_alignment = .{ .y = .center },
                .child_gap = 0,
            },
            .bg_color = themes.current.bg,
            .scroll = .{ .vertical = true },
        })({
            const tab_width = @min(width / model.tabs.items.len, max_tab_width);

            for (model.tabs.items, 0..) |tab, index| {
                const selected = index == model.curr_tab;
                const hovered = !selected and clay.pointerOver(tab_ids[index]);

                const floating = if (selected) if (model.tab_drag) |dragging| floating: {
                    clay.ui()(.{
                        .id = clay.id("Dimming"),
                        .layout = .{
                            .sizing = .grow(.{}),
                        },
                        .floating = .{
                            .z_index = 2,
                            .attach_to = .root,
                        },
                        .bg_color = .rgba(0, 0, 0, @intCast(dragging.dimming)),
                    })({});

                    // Placeholder when dragging a tab
                    if (dragging.dimming == 0) {
                        clay.ui()(.{
                            .layout = .{
                                .sizing = .{ .width = .fixed(@floatFromInt(tab_width)) },
                            },
                        })({});
                    }

                    const max: f32 = @floatFromInt(width - tab_width);
                    break :floating clay.Config.Floating{
                        .offset = .{
                            .x = math.clamp(dragging.x_pos - dragging.tab_offset, tabs_padding, max),
                            .y = @as(f32, @floatFromInt(dragging.dimming)) / 2,
                        },
                        .z_index = 1,
                        .parent_id = tabs_id.id,
                        .attach_to = .parent,
                    };
                } else null else null;

                clay.ui()(.{
                    .id = tab_ids[index],
                    .layout = .{
                        .sizing = .{
                            .width = .fixed(@floatFromInt(tab_width)),
                            .height = .fixed(tabs_height),
                        },
                    },
                    .floating = floating,
                })({
                    clay.ui()(.{
                        .layout = .{
                            .sizing = .{
                                .width = .fixed(tabs_height / 2),
                                .height = .fixed(tabs_height),
                            },
                        },
                        .bg_color = if (hovered)
                            themes.current.bright
                        else if (selected)
                            themes.current.base
                        else
                            themes.current.dim,
                        .image = .{
                            .image_data = &resources.images.tab_left,
                            .source_dimensions = .{ .width = tabs_height / 2, .height = tabs_height },
                        },
                    })({});

                    clay.ui()(.{
                        .layout = .{
                            .sizing = .grow(.{}),
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                        .bg_color = if (hovered)
                            themes.current.bright
                        else if (selected)
                            themes.current.base
                        else
                            themes.current.dim,
                    })({
                        clay.ui()(.{ .layout = .{ .sizing = .grow(.{}) } })({});

                        draw.textEx(.roboto, .sm, tab.tabName(), themes.current.dim_text, tab_width / 2);

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
                                .image_data = if (!hovered and !selected)
                                    &resources.images.x_dim
                                else
                                    &resources.images.x,
                                .source_dimensions = .{ .width = 9, .height = tabs_height },
                            },
                        })({
                            draw.pointer();
                        });
                    });

                    clay.ui()(.{
                        .layout = .{
                            .sizing = .{
                                .width = .fixed(tabs_height / 2),
                                .height = .fixed(tabs_height),
                            },
                        },
                        .bg_color = if (hovered)
                            themes.current.bright
                        else if (selected)
                            themes.current.base
                        else
                            themes.current.dim,
                        .image = .{
                            .image_data = &resources.images.tab_right,
                            .source_dimensions = .{ .width = tabs_height / 2, .height = tabs_height },
                        },
                    })({});
                });
            }

            if (model.tabs.items.len < max_tabs and (model.tab_drag == null or model.tab_drag.?.dist < 5)) {
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
                    .bg_color = if (clay.pointerOver(new_tab_id)) themes.current.highlight else themes.current.secondary,
                    .floating = .{
                        .offset = .{ .x = @floatFromInt(x_offset) },
                        .z_index = 1,
                        .parent_id = tabs_id.id,
                        .attach_to = .parent,
                    },
                })({
                    draw.pointer();
                });
            }
        });

        model.currTab().render(if (width > Shortcuts.widths.cutoff) model.shortcuts else null);
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

fn popOutTab(model: *Model) Error!void {
    try model.currTab().newWindow();
    try model.closeTab(model.curr_tab);
}

fn updateTabsBookmarked(model: *Model, path: []const u8) void {
    const bookmarked = model.shortcuts.isBookmarked(path);
    for (model.tabs.items) |*tab| tab.bookmarked = bookmarked;
}
