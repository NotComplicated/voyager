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
const windows = @import("windows.zig");
const themes = @import("themes.zig");
const draw = @import("draw.zig");
const resources = @import("resources.zig");
const alert = @import("alert.zig");
const modal = @import("modal.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");
const Entries = @import("Entries.zig");
const Shortcuts = @import("Shortcuts.zig");
const TextBox = @import("text_box.zig").TextBox;
const Error = @import("error.zig").Error;

cwd: TextBox(.path, clay.id("CurrentDir"), null),
cached_cwd: main.ArrayList(u8),
del_history: if (main.is_windows) std.BoundedArray(DelEvent, max_history) else void,
del_queue: ?[]const u8,
rename: ?[]const u8,
entries: Entries,
bookmarked: bool,

const Tab = @This();

pub const Message = union(enum) {
    open_dirs: []const u8,
    open_parent_dir,
    toggle_bookmark: []const u8,
    set_clipboard: Model.Transfer,
    paste,
};

const DelEvent = union(enum) {
    single: windows.RecycleId,
    multiple: []windows.RecycleId,
};

const max_paste_len = 1024;
const max_history = 16;
const nav_buttons = .{
    .parent = clay.id("Parent"),
    .refresh = clay.id("Refresh"),
    .vscode = clay.id("VsCode"),
    .bookmark = clay.id("ToggleBookmark"),
};

fn renderNavButton(id: clay.Id, icon: *rl.Texture) void {
    clay.ui()(.{
        .id = id,
        .layout = .{ .sizing = .fixed(Model.row_height) },
        .bg_color = if (clay.pointerOver(id)) themes.current.hovered else themes.current.base,
        .corner_radius = draw.rounded,
    })({
        draw.pointer();

        clay.ui()(.{
            .layout = .{
                .sizing = .grow(.{}),
            },
            .image = .{
                .image_data = icon,
                .source_dimensions = .square(Model.row_height),
            },
        })({});
    });
}

pub fn init(path: []const u8, bookmarked: bool) Error!Tab {
    var cwd = try @FieldType(Tab, "cwd").init(path, .unfocused);
    errdefer cwd.deinit();
    var cached_cwd = try @FieldType(Tab, "cached_cwd").initCapacity(main.alloc, 256);
    errdefer cached_cwd.deinit(main.alloc);
    var entries = try Entries.init();
    errdefer entries.deinit();
    var tab = Tab{
        .cwd = cwd,
        .cached_cwd = cached_cwd,
        .del_history = if (main.is_windows) .{} else {},
        .del_queue = null,
        .rename = null,
        .entries = entries,
        .bookmarked = bookmarked,
    };

    try tab.loadEntries(path);

    return tab;
}

pub fn deinit(tab: *Tab) void {
    tab.cwd.deinit();
    tab.cached_cwd.deinit(main.alloc);
    if (tab.del_queue) |del_queue| main.alloc.free(del_queue);
    tab.entries.deinit();
}

pub fn update(tab: *Tab, input: Input) Error!?Message {
    if (rl.isFileDropped()) {
        // TODO
        const files = rl.loadDroppedFiles();
        defer rl.unloadDroppedFiles(files);
        if (main.is_debug) for (files.paths[0..files.count]) |path| log.debug("Dropped: {s}", .{path});
    }

    if (main.is_debug and input.clicked(.middle)) {
        log.debug("{}", .{tab});
    } else if (!tab.cwd.isActive() and !tab.entries.isActive()) {
        if (input.clicked(.side)) {
            return .open_parent_dir;
        } else if (input.clicked(.left)) { // TODO middle click new tab for parent
            inline for (comptime enums.values(meta.FieldEnum(@TypeOf(nav_buttons)))) |button| {
                if (clay.pointerOver(@field(nav_buttons, @tagName(button)))) {
                    switch (button) {
                        .parent => return .open_parent_dir,
                        .refresh => try tab.reloadEntries(),
                        .vscode => try tab.openVscode(),
                        .bookmark => return .{ .toggle_bookmark = tab.cached_cwd.items },
                    }
                    return null;
                }
            }
        }
    }

    if (try tab.cwd.update(input)) |message| {
        switch (message) {
            .submit => |path| tab.loadEntries(path) catch |err| switch (err) {
                Error.OpenDirFailure => {
                    if (main.is_windows and mem.eql(u8, fs.path.diskDesignator(path), path)) return null;
                    const path_z = try main.alloc.dupeZ(u8, path);
                    defer main.alloc.free(path_z);
                    try openFileAt(path_z, null);
                },
                else => return err,
            },
        }
        return null;
    }

    if (!tab.cwd.isActive()) if (input.action) |action| switch (action) {
        .mouse => {},
        .event => |event| if (main.is_windows) switch (event) {
            .paste => return .paste,
            .undo => {
                try tab.undoDelete();
                return null;
            },
            else => {},
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
                'v' => return .paste,
                else => {},
            },
            .up => if (input.alt) return .open_parent_dir,
            .backspace => return .open_parent_dir,
            else => {},
        },
    };

    if (try tab.entries.update(input, !tab.cwd.isActive())) |message| {
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
                defer {
                    tab.reloadEntries() catch {};
                    tab.entries.selectName(create.name) catch alert.updateFmt("Failed to find '{s}'.", .{create.name});
                    main.alloc.free(create.name);
                }
                try tab.cached_cwd.append(main.alloc, fs.path.sep);
                defer tab.cached_cwd.shrinkRetainingCapacity(tab.cached_cwd.items.len - 1);
                try tab.cached_cwd.appendSlice(main.alloc, create.name);
                defer tab.cached_cwd.shrinkRetainingCapacity(tab.cached_cwd.items.len - create.name.len);
                switch (create.kind) {
                    .dir => fs.makeDirAbsolute(tab.cached_cwd.items) catch |err| switch (err) {
                        error.PathAlreadyExists => return Error.AlreadyExists,
                        else => {
                            alert.update(err);
                            return null;
                        },
                    },
                    .file => {
                        const file = fs.createFileAbsolute(
                            tab.cached_cwd.items,
                            .{ .exclusive = true },
                        ) catch |err| switch (err) {
                            error.PathAlreadyExists => return Error.AlreadyExists,
                            else => {
                                alert.update(err);
                                return null;
                            },
                        };
                        file.close();
                    },
                }
            },

            .delete => |names| {
                defer main.alloc.free(names);

                if (main.is_windows and !input.shift) {
                    try tab.cached_cwd.append(main.alloc, fs.path.sep);
                    const dir_len = tab.cached_cwd.items.len;
                    defer tab.cached_cwd.shrinkRetainingCapacity(dir_len - 1);

                    var recycle_ids = std.ArrayList(windows.RecycleId).init(main.alloc);
                    defer recycle_ids.deinit();

                    var new_del_event: ?DelEvent = null;

                    var names_iter = mem.tokenizeScalar(u8, names, '\x00');
                    while (names_iter.next()) |name| {
                        try tab.cached_cwd.appendSlice(main.alloc, name.ptr[0 .. name.len + 1]);
                        defer tab.cached_cwd.shrinkRetainingCapacity(dir_len);
                        const recycle_id = try windows.delete(tab.cached_cwd.items[0 .. tab.cached_cwd.items.len - 1 :0]) orelse continue;
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
                            switch (tab.del_history.pop() orelse unreachable) {
                                .single => {},
                                .multiple => |multiple| main.alloc.free(multiple),
                            }
                            tab.del_history.appendAssumeCapacity(del_event.*);
                        };
                    }

                    try tab.reloadEntries();
                } else {
                    if (tab.del_queue) |del_queue| main.alloc.free(del_queue);
                    tab.del_queue = main.alloc.dupe(u8, names) catch return Error.OutOfMemory;
                    errdefer {
                        main.alloc.free(tab.del_queue.?);
                        tab.del_queue = null;
                    }

                    const writers = modal.set(.confirm, Tab, tab, struct {
                        fn f(tab_inner: *Tab) Error!void {
                            const names_inner = tab_inner.del_queue orelse return;
                            defer main.alloc.free(names_inner);
                            tab_inner.del_queue = null;

                            const cwd_len = tab_inner.cached_cwd.items.len;
                            try tab_inner.cached_cwd.append(main.alloc, fs.path.sep);
                            defer tab_inner.cached_cwd.shrinkRetainingCapacity(cwd_len);

                            var dir_inner = fs.openDirAbsolute(
                                tab_inner.cached_cwd.items,
                                .{},
                            ) catch return Error.OpenDirFailure;
                            defer dir_inner.close();

                            var names_iter = mem.tokenizeScalar(u8, names_inner, '\x00');
                            var errors: u32 = 0;
                            while (names_iter.next()) |name| dir_inner.deleteTree(name) catch {
                                errors += 1;
                            };
                            if (errors > 0) alert.updateFmt("Encountered {} error(s).", .{errors});

                            tab_inner.cached_cwd.shrinkRetainingCapacity(cwd_len);
                            try tab_inner.reloadEntries();
                        }
                    }.f);
                    errdefer modal.reset();

                    const name_count = mem.count(u8, names, "\x00");
                    if (name_count > 1) {
                        fmt.format(
                            writers.message,
                            "Permanently delete {} items?",
                            .{name_count},
                        ) catch return Error.OutOfMemory;
                    } else {
                        fmt.format(
                            writers.message,
                            "Permanently delete '{s}'?",
                            .{mem.trimRight(u8, names, "\x00")},
                        ) catch return Error.OutOfMemory;
                    }
                    writers.reject.writeAll("Cancel") catch return Error.Unexpected;
                    writers.accept.writeAll("Delete") catch return Error.Unexpected;
                }
            },

            .rename => |name| {
                tab.rename = name;
                const writers = modal.set(.text, Tab, tab, struct {
                    fn f(tab_inner: *Tab, new_name: []const u8) Error!void {
                        if (tab_inner.rename == null) return Error.Unexpected;
                        defer tab_inner.rename = null;
                        if (new_name.len == 0) {
                            alert.updateFmt("No name provided.", .{});
                            return;
                        }
                        var dir = fs.openDirAbsolute(tab_inner.cached_cwd.items, .{}) catch return Error.OpenDirFailure;
                        defer dir.close();
                        dir.rename(tab_inner.rename.?, new_name) catch {
                            alert.updateFmt("Failed to rename '{s}' to '{s}'.", .{ tab_inner.rename.?, new_name });
                            return;
                        };
                        try tab_inner.reloadEntries();
                    }
                }.f);
                errdefer modal.reset();

                fmt.format(writers.message, "Rename '{s}'?", .{name}) catch return Error.Unexpected;
                writers.labels[0].writeAll("New name") catch return Error.Unexpected;
                writers.reject.writeAll("Cancel") catch return Error.Unexpected;
                writers.accept.writeAll("Rename") catch return Error.Unexpected;
            },

            .set_clipboard => |clipboard| {
                errdefer main.alloc.free(clipboard.names);
                const dir_path = try main.alloc.dupe(u8, tab.directory());
                return .{ .set_clipboard = .{
                    .mode = switch (clipboard.mode) {
                        .copy => .copy,
                        .cut => .cut,
                    },
                    .dir_path = dir_path,
                    .names = clipboard.names,
                } };
            },

            .paste => return .paste,
        }
    }

    return null;
}

pub fn render(tab: Tab, shortcuts: Shortcuts) void {
    clay.ui()(.{
        .id = clay.id("TabContent"),
        .layout = .{
            .sizing = .grow(.{}),
            .layout_direction = .top_to_bottom,
        },
    })({
        clay.ui()(.{
            .id = clay.id("NavBar"),
            .layout = .{
                .padding = .all(10),
                .sizing = .{
                    .width = .grow(.{}),
                },
                .child_gap = 10,
            },
        })({
            renderNavButton(nav_buttons.parent, &resources.images.arrow_up);
            renderNavButton(nav_buttons.refresh, &resources.images.refresh);

            tab.cwd.render();

            renderNavButton(
                nav_buttons.bookmark,
                if (tab.bookmarked) &resources.images.bookmarked else &resources.images.not_bookmarked,
            );
            if (main.is_windows and windows.vscode_available) renderNavButton(nav_buttons.vscode, &resources.images.vscode);
        });

        clay.ui()(.{
            .id = clay.id("Content"),
            .layout = .{
                .sizing = .grow(.{}),
            },
            .bg_color = themes.current.bg,
        })({
            shortcuts.render();
            tab.entries.render(shortcuts.getWidth());
        });
    });
}

pub fn directory(tab: Tab) []const u8 {
    return tab.cached_cwd.items;
}

pub fn tabName(tab: Tab) []const u8 {
    const basename = fs.path.basename(tab.cached_cwd.items);
    return if (basename.len != 0)
        basename
    else if (main.is_windows) fs.path.diskDesignator(tab.cached_cwd.items) else "/";
}

pub fn clone(tab: Tab) Error!Tab {
    return Tab.init(tab.cached_cwd.items, tab.bookmarked);
}

pub fn toggleBookmark(tab: *Tab) void {
    tab.bookmarked = !tab.bookmarked;
}

fn loadEntries(tab: *Tab, path: []const u8) Error!void {
    const reloaded = mem.eql(u8, tab.cached_cwd.items, path);
    try tab.entries.load(path);
    tab.cached_cwd.clearRetainingCapacity();
    try tab.cached_cwd.appendSlice(main.alloc, path);
    if (main.is_windows) if (!reloaded) while (tab.del_history.pop()) |del| switch (del) {
        .single => {},
        .multiple => |multiple| main.alloc.free(multiple),
    };
}

pub fn reloadEntries(tab: *Tab) Error!void {
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

pub fn openDir(tab: *Tab, name: []const u8) Error!void {
    try tab.cwd.set(tab.cached_cwd.items);
    try tab.cwd.appendPath(name);

    tab.loadEntries(tab.cwd.value()) catch |err| switch (err) {
        Error.DirAccessDenied, Error.OpenDirFailure => {
            try tab.cwd.popPath();
            return err;
        },
        else => return err,
    };
}

pub fn newWindow(tab: *Tab) Error!void {
    const exe = fs.selfExePathAlloc(main.alloc) catch return Error.ExeNotFound;
    defer main.alloc.free(exe);
    const exe_z = try main.alloc.dupeZ(u8, exe);
    defer main.alloc.free(exe_z);
    try tab.cached_cwd.append(main.alloc, 0);
    defer tab.cached_cwd.shrinkRetainingCapacity(tab.cached_cwd.items.len - 1);
    try openFileAt(exe_z, @ptrCast(tab.cached_cwd.items));
}

pub fn openParentDir(tab: *Tab) Error!void {
    try tab.cwd.set(tab.cached_cwd.items);
    try tab.cwd.popPath();
    try tab.loadEntries(tab.cwd.value());
}

fn openFile(tab: Tab, name: []const u8) Error!void {
    const path = try fs.path.joinZ(main.alloc, &.{ tab.cached_cwd.items, name });
    defer main.alloc.free(path);
    try openFileAt(path, null);
}

fn openVscode(tab: Tab) Error!void {
    const path = try main.alloc.dupeZ(u8, tab.cwd.value());
    defer main.alloc.free(path);
    try openFileAt("code", path);
}

fn undoDelete(tab: *Tab) Error!void {
    if (!main.is_windows) @compileError("OS not supported");

    const disk = fs.path.diskDesignator(tab.cached_cwd.items);
    if (disk.len == 0) return Error.RestoreFailure;
    const del_event = tab.del_history.pop() orelse return;
    const names = switch (del_event) {
        .single => |id| try windows.restore(disk[0], &.{id}),
        .multiple => |ids| multiple: {
            defer main.alloc.free(ids);
            break :multiple try windows.restore(disk[0], ids);
        },
    } orelse return;
    defer main.alloc.free(names);

    try tab.reloadEntries();

    var names_iter = mem.tokenizeScalar(u8, names, 0);
    while (names_iter.next()) |name| {
        tab.entries.selectName(name) catch {
            alert.updateFmt("Failed to find '{s}'.", .{name});
            break;
        };
    }
}

fn openFileAt(path: [:0]const u8, args: ?[*:0]const u8) Error!void {
    if (main.is_windows) {
        const status = @intFromPtr(windows.ShellExecuteA(windows.getHandle(), null, path, args, null, 0));
        if (status <= 32) alert.updateFmt("{s}", .{windows.shellExecStatusMessage(status)});
    } else {
        // TODO posix execv
    }
}
