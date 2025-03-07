const std = @import("std");
const process = std.process;
const enums = std.enums;
const time = std.time;
const meta = std.meta;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const fs = std.fs;
const os = std.os;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const resources = @import("resources.zig");
const alert = @import("alert.zig");
const Input = @import("Input.zig");
const text_box = @import("text_box.zig");
const TextBox = text_box.TextBox;
const Entries = @import("Entries.zig");

cwd: TextBox(.path, main.newId("CurrentDir")),
entries: Entries,

const Model = @This();

pub const Error = error{
    OsNotSupported,
    OutOfBounds,
    OpenDirFailure,
    DirAccessDenied,
} || mem.Allocator.Error || process.Child.SpawnError;

pub const row_height = 30;
const max_paste_len = 1024;
const nav_buttons = .{
    .parent = main.newId("Parent"),
    .refresh = main.newId("Refresh"),
    .vscode = main.newId("VsCode"),
};

extern fn ShellExecuteA(
    hwnd: ?os.windows.HWND,
    lpOperation: ?os.windows.LPCSTR,
    lpFile: os.windows.LPCSTR,
    lpParameters: ?os.windows.LPCSTR,
    lpDirectory: ?os.windows.LPCSTR,
    nShowCmd: os.windows.INT,
) os.windows.HINSTANCE;

fn renderNavButton(id: clay.Element.Config.Id, icon: *rl.Texture) void {
    clay.ui()(.{
        .id = id,
        .layout = .{ .sizing = clay.Element.Sizing.fixed(row_height) },
        .image = .{
            .image_data = icon,
            .source_dimensions = clay.Dimensions.square(row_height),
        },
        .rectangle = .{
            .color = if (clay.pointerOver(id)) main.theme.hovered else main.theme.base,
            .corner_radius = main.rounded,
        },
    })({
        main.pointer();
    });
}

pub fn init() Error!Model {
    var model = Model{
        .cwd = try meta.FieldType(Model, .cwd).init(),
        .entries = try Entries.init(),
    };
    errdefer model.deinit();

    try model.entries.loadEntries(model.cwd.value());

    return model;
}

pub fn deinit(model: *Model) void {
    model.cwd.deinit();
    model.entries.deinit();
}

pub fn update(model: *Model, input: Input) Error!void {
    if (main.debug and input.clicked(.middle)) {
        log.debug("{}\n", .{model});
    } else if (input.clicked(.side)) {
        try model.openParentDir();
    } else if (input.clicked(.left)) {
        inline for (comptime enums.values(meta.FieldEnum(@TypeOf(nav_buttons)))) |button| {
            if (clay.pointerOver(@field(nav_buttons, @tagName(button)))) {
                switch (button) {
                    .parent => try model.openParentDir(),
                    .refresh => try model.entries.loadEntries(model.cwd.value()),
                    .vscode => try model.openVscode(),
                }
            }
        }
    }

    if (input.action) |action| switch (action) {
        .mouse, .event => {},
        .key => |key| switch (key) {
            .escape => try model.openParentDir(),
            else => {},
        },
    };

    if (try model.cwd.update(input)) |message| {
        switch (message) {
            .submit => |path| try model.entries.loadEntries(path),
        }
    }
    if (try model.entries.update(input)) |message| {
        switch (message) {
            .open_dir => |name| try model.openDir(name),
            .open_file => |name| try model.openFile(name),
        }
    }
}

pub fn render(model: Model) void {
    clay.ui()(.{
        .id = main.newId("Screen"),
        .layout = .{
            .sizing = clay.Element.Sizing.grow(.{}),
            .layout_direction = .top_to_bottom,
        },
        .rectangle = .{ .color = main.theme.base },
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

            model.cwd.render();

            renderNavButton(nav_buttons.vscode, &resources.images.vscode);
        });

        clay.ui()(.{
            .id = main.newId("Content"),
            .layout = .{
                .sizing = clay.Element.Sizing.grow(.{}),
            },
            .rectangle = .{ .color = main.theme.mantle },
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

            model.entries.render();
        });
    });
}

pub fn format(model: Model, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try fmt.format(writer, "\ncwd: {}\nentries: {}", .{ model.cwd, model.entries });
}

fn openDir(model: *Model, name: []const u8) Error!void {
    try model.cwd.appendPath(name);

    model.entries.loadEntries(model.cwd.value()) catch |err| switch (err) {
        Error.DirAccessDenied, Error.OpenDirFailure => {
            try model.cwd.popPath();
            return err;
        },
        else => return err,
    };
}

fn openParentDir(model: *Model) Error!void {
    try model.cwd.popPath();
    try model.entries.loadEntries(model.cwd.value());
}

fn openFile(model: Model, name: []const u8) Error!void {
    if (main.windows) {
        const path = try fs.path.joinZ(main.alloc, &.{ model.cwd.value(), name });
        defer main.alloc.free(path);
        const instance = ShellExecuteA(@ptrCast(rl.getWindowHandle()), null, path, null, null, 0);
        const status = @intFromPtr(instance);
        if (status <= 32) return alert.updateFmt("{s}", .{
            switch (status) {
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
            },
        });
    } else {
        return Error.OsNotSupported;
    }
}

fn openVscode(model: Model) Error!void {
    if (main.windows) {
        const path = try main.alloc.dupeZ(u8, model.cwd.value());
        defer main.alloc.free(path);
        const instance = ShellExecuteA(@ptrCast(rl.getWindowHandle()), null, "code", path, null, 0);
        const status = @intFromPtr(instance);
        if (status <= 32) return alert.updateFmt("Failed to open directory.", .{});
    } else {
        return Error.OsNotSupported;
    }
}

//         switch (key) {
//             .escape => {
//                 try model.open_parent_dir();
//             },
//             .up, .down => updown: {
//                 for (Model.Entries.kinds()) |kind| {
//                     var sorted = model.entries.sorted(kind, &.{.selected});
//                     var sorted_index: Model.Index = 0;
//                     while (sorted.next()) |entry| : (sorted_index += 1) {
//                         if (entry.selected != null) {
//                             // TODO handle going from one kind to the other
//                             // TODO how to get next/prev?
//                             // if (key == .up and sorted_index > 0) {
//                             //     // model.select(kind, sort_list[sort_index - 1], .touch) catch |err| updateError(err);
//                             //     break :updown;
//                             // } else if (key == .down and sort_index < sort_list.len - 1) {
//                             //     // model.select(kind, sort_list[sort_index + 1], .touch) catch |err| updateError(err);
//                             //     break :updown;
//                             // }
//                             break :updown;
//                         }
//                     }
//                 }
//                 if (key == .down) {
//                     // TODO bounds check the 0
//                     // model.select(.dir, model.entries.sortings.get(model.entries.curr_sorting).get(.dir)[0], .touch) catch |err| switch (err) {
//                     //     Model.Error.OutOfBounds => _ = model.select(.file, model.entries.sortings.get(model.entries.curr_sorting).get(.file)[0], .touch),
//                     //     else => updateError(err),
//                     // };
//                     clay.getScrollContainerData(clay.getId("Entries")).scroll_position.y = 0;
//                 }
//             },
//             // TODO select_top() / select_bottom() ?
//             .home => {
//                 // model.select(.dir, model.entries.sortings.get(model.entries.curr_sorting).get(.dir)[0], .touch) catch |err| switch (err) {
//                 //     Model.Error.OutOfBounds => _ = model.select(.file, model.entries.sortings.get(model.entries.curr_sorting).get(.file)[0], .touch),
//                 //     else => updateError(err),
//                 // };
//                 clay.getScrollContainerData(clay.getId("Entries")).scroll_position.y = 0;
//             },
//             .end => {
//                 // TODO
//                 // if (model.entries.list.len > 0) {
//                 //     model.select(model.entries.list.len - 1, false) catch |err| updateError(err);
//                 // }
//                 clay.getScrollContainerData(clay.getId("Entries")).scroll_position.y = -100_000;
//             },
//             .enter => {
//                 // TODO also support opening dirs?
//                 for (model.entries.data_slices.get(.file).items(.selected), 0..) |selected, index| {
//                     if (selected) |_| try model.open_file(@intCast(index));
//                 }
//             },
//             .period => _ = model.entries.try_jump('.'),
//             else => {},
//         }

//         // jump to entries when typing letters/numbers
//         if (as_alpha) |alpha| {
//             if (model.entries.try_jump(alpha) == .not_found) {
//                 _ = model.entries.try_jump(ascii.toUpper(alpha));
//             }
//         } else if (as_num) |num| {
//             _ = model.entries.try_jump(num);
//         }
//     }
// }
