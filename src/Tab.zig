const std = @import("std");
const enums = std.enums;
const time = std.time;
const meta = std.meta;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const ops = @import("ops.zig");
const windows = @import("windows.zig");
const themes = @import("themes.zig");
const resources = @import("resources.zig");
const alert = @import("alert.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");
const TextBox = @import("text_box.zig").TextBox;
const Entries = @import("Entries.zig");

cwd: TextBox(.path, main.newId("CurrentDir")),
cached_cwd: std.ArrayListUnmanaged(u8),
del_history: if (main.is_windows) std.BoundedArray(DelEvent, max_history) else void,
entries: Entries,

const Tab = @This();

pub const Message = union(enum) {
    open_dirs: []const u8,
};

const DelEvent = union(enum) {
    single: windows.RecycleId,
    multiple: []windows.RecycleId,
};

const max_paste_len = 1024;
const max_history = 16;
const nav_buttons = .{
    .parent = main.newId("Parent"),
    .refresh = main.newId("Refresh"),
    .vscode = main.newId("VsCode"),
};

fn renderNavButton(id: clay.Element.Config.Id, icon: *rl.Texture) void {
    clay.ui()(.{
        .id = id,
        .layout = .{ .sizing = clay.Element.Sizing.fixed(Model.row_height) },
        .image = .{
            .image_data = icon,
            .source_dimensions = clay.Dimensions.square(Model.row_height),
        },
        .rectangle = .{
            .color = if (clay.pointerOver(id)) themes.current.hovered else themes.current.base,
            .corner_radius = main.rounded,
        },
    })({
        main.pointer();
    });
}

pub fn init(path: []const u8) Model.Error!Tab {
    var tab = Tab{
        .cwd = try meta.FieldType(Tab, .cwd).init(path, .unfocused),
        .cached_cwd = try meta.FieldType(Tab, .cached_cwd).initCapacity(main.alloc, 256),
        .del_history = if (main.is_windows) .{} else {},
        .entries = try Entries.init(),
    };
    errdefer tab.deinit();

    try tab.loadEntries(path);

    return tab;
}

pub fn deinit(tab: *Tab) void {
    tab.cwd.deinit();
    tab.cached_cwd.deinit(main.alloc);
    tab.entries.deinit();
}

pub fn update(tab: *Tab, input: Input) Model.Error!?Message {
    const input_active = tab.cwd.isActive() or tab.entries.isActive();

    if (main.is_debug and input.clicked(.middle)) {
        log.debug("{}", .{tab});
    } else if (!input_active) {
        if (input.clicked(.side)) {
            try tab.openParentDir();
        } else if (input.clicked(.left)) {
            inline for (comptime enums.values(meta.FieldEnum(@TypeOf(nav_buttons)))) |button| {
                if (clay.pointerOver(@field(nav_buttons, @tagName(button)))) {
                    switch (button) {
                        .parent => try tab.openParentDir(),
                        .refresh => try tab.reloadEntries(),
                        .vscode => try tab.openVscode(),
                    }
                }
            }
        }
    }

    if (try tab.cwd.update(input)) |message| {
        switch (message) {
            .submit => |path| tab.loadEntries(path) catch |err| switch (err) {
                Model.Error.OpenDirFailure => {
                    const path_z = try main.alloc.dupeZ(u8, path);
                    defer main.alloc.free(path_z);
                    try openFileAt(path_z);
                },
                else => return err,
            },
        }
    }

    if (input.action) |action| if (!input_active) switch (action) {
        .mouse => {},
        .event => |event| if (main.is_windows) switch (event) {
            .copy => {},
            .paste => {},
            .undo => {
                try tab.undoDelete();
                return null;
            },
            .redo => {},
        },
        .key => |key| switch (key) {
            .char => |c| if (input.ctrl) switch (c) {
                'z' => {
                    if (main.is_windows) try tab.undoDelete();
                    return null;
                },
                'l' => {
                    tab.cwd.focus();
                    return null;
                },
                else => {},
            },
            .up => if (input.alt) try tab.openParentDir(),
            .backspace => try tab.openParentDir(),
            else => {},
        },
    };

    if (try tab.entries.update(input, !input_active)) |message| {
        switch (message) {
            .open => |open| switch (open.kind) {
                .dir => return .{ .open_dirs = open.names },
                .file => {
                    defer main.alloc.free(open.names);
                    var names_iter = mem.tokenizeScalar(u8, open.names, '\x00');
                    while (names_iter.next()) |name| try tab.openFile(name);
                },
            },
            .create => |create| {
                defer main.alloc.free(create.name);
                defer tab.reloadEntries() catch {};
                try tab.cached_cwd.append(main.alloc, fs.path.sep);
                defer tab.cached_cwd.shrinkRetainingCapacity(tab.cached_cwd.items.len - 1);
                try tab.cached_cwd.appendSlice(main.alloc, create.name);
                defer tab.cached_cwd.shrinkRetainingCapacity(tab.cached_cwd.items.len - create.name.len);
                switch (create.kind) {
                    .dir => fs.makeDirAbsolute(tab.cached_cwd.items) catch |err| switch (err) {
                        error.PathAlreadyExists => alert.updateFmt("A folder with this name already exists.", .{}),
                        else => {
                            alert.update(err);
                            return null;
                        },
                    },
                    .file => {
                        const file = fs.createFileAbsolute(
                            tab.cached_cwd.items,
                            .{ .exclusive = true },
                        ) catch |err| {
                            switch (err) {
                                error.PathAlreadyExists => alert.updateFmt("A file with this name already exists.", .{}),
                                else => alert.update(err),
                            }
                            return null;
                        };
                        file.close();
                    },
                }
            },
            .delete => |names| {
                defer main.alloc.free(names);
                try tab.cached_cwd.append(main.alloc, fs.path.sep);
                const dir_len = tab.cached_cwd.items.len;
                defer tab.cached_cwd.shrinkRetainingCapacity(dir_len - 1);
                var names_iter = mem.tokenizeScalar(u8, names, '\x00');
                if (main.is_windows) {
                    var recycle_ids = std.ArrayList(windows.RecycleId).init(main.alloc);
                    defer recycle_ids.deinit();
                    var new_del_event: ?DelEvent = null;
                    while (names_iter.next()) |name| {
                        try tab.cached_cwd.appendSlice(main.alloc, name.ptr[0 .. name.len + 1]);
                        defer tab.cached_cwd.shrinkRetainingCapacity(dir_len);
                        const recycle_id = try ops.delete(tab.cached_cwd.items[0 .. tab.cached_cwd.items.len - 1 :0]) orelse continue;
                        if (new_del_event) |*del_event| switch (del_event.*) {
                            .single => |single| {
                                try recycle_ids.append(single);
                                try recycle_ids.append(recycle_id);
                                del_event.* = .{ .multiple = &.{} };
                            },
                            .multiple => try recycle_ids.append(recycle_id),
                        } else new_del_event = .{ .single = recycle_id };
                    }
                    if (new_del_event) |*del_event| {
                        if (meta.activeTag(del_event.*) == .multiple) {
                            del_event.* = .{ .multiple = try recycle_ids.toOwnedSlice() };
                        }
                        tab.del_history.append(del_event.*) catch {
                            mem.rotate(DelEvent, tab.del_history.slice(), 1);
                            switch (tab.del_history.pop()) {
                                .single => {},
                                .multiple => |multiple| main.alloc.free(multiple),
                            }
                            tab.del_history.appendAssumeCapacity(del_event.*);
                        };
                    }
                } else {
                    while (names_iter.next()) |name| {
                        tab.cached_cwd.appendSlice(main.alloc, name);
                        defer tab.cached_cwd.shrinkRetainingCapacity(dir_len);
                        try ops.delete(tab.cached_cwd.items);
                    }
                }
                try tab.reloadEntries();
            },
        }
    }

    return null;
}

pub fn render(tab: Tab) void {
    clay.ui()(.{
        .id = main.newId("TabContent"),
        .layout = .{
            .sizing = clay.Element.Sizing.grow(.{}),
            .layout_direction = .top_to_bottom,
        },
    })({
        clay.ui()(.{
            .id = main.newId("NavBar"),
            .layout = .{
                .padding = clay.Padding.all(10),
                .sizing = .{
                    .width = .{ .type = .grow },
                },
                .child_gap = 10,
            },
        })({
            renderNavButton(nav_buttons.parent, &resources.images.arrow_up);
            renderNavButton(nav_buttons.refresh, &resources.images.refresh);

            tab.cwd.render();

            renderNavButton(nav_buttons.vscode, &resources.images.vscode);
        });

        clay.ui()(.{
            .id = main.newId("Content"),
            .layout = .{
                .sizing = clay.Element.Sizing.grow(.{}),
            },
            .rectangle = .{ .color = themes.current.bg },
        })({
            const shortcut_width = 260; // TODO customizable

            clay.ui()(.{
                .id = main.newId("ShortcutsContainer"),
                .layout = .{
                    .padding = clay.Padding.all(10),
                    .sizing = .{ .width = clay.Element.Sizing.Axis.fixed(shortcut_width) },
                },
            })({
                clay.ui()(.{
                    .id = main.newId("Shortcuts"),
                    .layout = .{
                        .layout_direction = .top_to_bottom,
                        .padding = clay.Padding.all(16),
                    },
                })({
                    main.text("Shortcuts will go here");
                });
            });

            tab.entries.render();
        });
    });
}

pub fn tabName(tab: Tab) []const u8 {
    const basename = fs.path.basename(tab.cached_cwd.items);
    return if (basename.len != 0)
        basename
    else if (main.is_windows) fs.path.diskDesignator(tab.cached_cwd.items) else "/";
}

pub fn clone(tab: Tab) Model.Error!Tab {
    return Tab.init(tab.cached_cwd.items);
}

fn loadEntries(tab: *Tab, path: []const u8) Model.Error!void {
    const reloaded = mem.eql(u8, tab.cached_cwd.items, path);
    try tab.entries.load(path);
    tab.cached_cwd.clearRetainingCapacity();
    try tab.cached_cwd.appendSlice(main.alloc, path);
    if (main.is_windows) if (!reloaded) while (tab.del_history.popOrNull()) |del| switch (del) {
        .single => {},
        .multiple => |multiple| main.alloc.free(multiple),
    };
}

pub fn reloadEntries(tab: *Tab) Model.Error!void {
    try tab.entries.load(tab.cached_cwd.items);
}

pub fn format(tab: Tab, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try fmt.format(writer, "\ncwd: {}", .{tab.cwd});
    try fmt.format(writer, "\nentries: {}", .{tab.entries});
    if (tab.del_history.len > 0) {
        try fmt.format(writer, "\ndeletes:", .{});
        for (tab.del_history.slice()) |del| switch (del) {
            .single => |id| try fmt.format(writer, "\t{s}\n", .{id}),
            .multiple => |multiple| {
                for (multiple) |id| try fmt.format(writer, "\t{s}", .{id});
                try writer.writeByte('\n');
            },
        };
    }
}

pub fn openDir(tab: *Tab, name: []const u8) Model.Error!void {
    try tab.cwd.set(tab.cached_cwd.items);
    try tab.cwd.appendPath(name);

    tab.loadEntries(tab.cwd.value()) catch |err| switch (err) {
        Model.Error.DirAccessDenied, Model.Error.OpenDirFailure => {
            try tab.cwd.popPath();
            return err;
        },
        else => return err,
    };
}

fn openParentDir(tab: *Tab) Model.Error!void {
    try tab.cwd.set(tab.cached_cwd.items);
    try tab.cwd.popPath();
    try tab.loadEntries(tab.cwd.value());
}

fn openFile(tab: Tab, name: []const u8) Model.Error!void {
    const path = try fs.path.joinZ(main.alloc, &.{ tab.cached_cwd.items, name });
    defer main.alloc.free(path);
    try openFileAt(path);
}

fn openFileAt(path: [:0]const u8) Model.Error!void {
    if (!main.is_windows) return Model.Error.OsNotSupported;
    const status = @intFromPtr(windows.ShellExecuteA(windows.getHandle(), null, path, null, null, 0));
    if (status <= 32) return alert.updateFmt("{s}", .{windows.shellExecStatusMessage(status)});
}

fn openVscode(tab: Tab) Model.Error!void {
    if (main.is_windows) {
        const path = try main.alloc.dupeZ(u8, tab.cwd.value());
        defer main.alloc.free(path);
        const status = @intFromPtr(windows.ShellExecuteA(windows.getHandle(), null, "code", path, null, 0));
        if (status <= 32) return alert.updateFmt("Failed to open directory.", .{});
    } else {
        return Model.Error.OsNotSupported;
    }
}

fn undoDelete(tab: *Tab) Model.Error!void {
    if (!main.is_windows) @compileError("OS not supported");
    const disk = fs.path.diskDesignator(tab.cached_cwd.items);
    if (disk.len == 0) return Model.Error.RestoreFailure;
    const del_event = tab.del_history.popOrNull() orelse return;
    switch (del_event) {
        .single => |id| try ops.restore(disk[0], &.{id}),
        .multiple => |ids| {
            defer main.alloc.free(ids);
            try ops.restore(disk[0], ids);
        },
    }
    try tab.reloadEntries();
}
