const std = @import("std");
const process = std.process;
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
const Millis = main.Millis;
const resources = @import("resources.zig");
const Input = @import("Input.zig");
const widgets = @import("widgets.zig");
const TextBox = widgets.TextBox;
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

    try model.entries.load_entries(model.cwd.value());

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
        try model.open_parent_dir();
    } else if (input.clicked(.left)) {
        inline for (comptime enums.values(meta.FieldEnum(@TypeOf(nav_buttons)))) |button| {
            if (clay.pointerOver(@field(nav_buttons, @tagName(button)))) {
                switch (button) {
                    .parent => try model.open_parent_dir(),
                    .refresh => try model.entries.load_entries(model.cwd.value()),
                    .vscode => try model.open_vscode(),
                }
            }
        }
    }
    if (try model.cwd.update(input)) |message| {
        switch (message) {
            .submit => |path| try model.entries.load_entries(path),
        }
    }
    if (try model.entries.update(input)) |message| {
        switch (message) {
            .open_dir => |name| try model.open_dir(name),
            .open_file => |name| try model.open_file(name),
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
    try fmt.format(writer, "\ncwd: {s}\nentries: {}", .{ model.cwd.value(), model.entries });
}

fn open_dir(model: *Model, name: []const u8) Error!void {
    try model.cwd.appendPath(name);

    model.entries.load_entries(model.cwd.value()) catch |err| switch (err) {
        Error.DirAccessDenied, Error.OpenDirFailure => {
            model.cwd.popPath();
            return err;
        },
        else => return err,
    };
}

fn open_parent_dir(model: *Model) Error!void {
    model.cwd.popPath();
    try model.entries.load_entries(model.cwd.value());
}

fn open_file(model: Model, name: []const u8) Error!void {
    const path = try fs.path.join(main.alloc, &.{ model.cwd.value(), name });
    defer main.alloc.free(path);
    const invoker = if (main.windows)
        .{ "cmd", "/c", "start" }
    else
        return Error.OsNotSupported;
    const argv = invoker ++ .{path};

    var child = process.Child.init(&argv, main.alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = model.cwd.value();
    _ = try child.spawnAndWait();
}

fn open_vscode(model: Model) Error!void {
    const invoker = if (main.windows)
        .{ "cmd", "/c", "code" }
    else
        return Error.OsNotSupported;
    const argv = invoker ++ .{model.cwd.value()};

    var child = process.Child.init(&argv, main.alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = model.cwd.value();
    _ = try child.spawnAndWait();
}

// TODO
// pub fn enterEditing(model: *Model) void {
//     model.cursor = @intCast(model.cwd.items.len);
// }

// pub fn exitEditing(model: *Model) void {
//     model.cursor = null;
// }

// pub fn handleKey(model: *Model) Error!void {
//     const key = rl.getKeyPressed();
//     const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
//     const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
//     const key_int = @intFromEnum(key);
//     const as_alpha: ?u8 = if (65 <= key_int and key_int <= 90) @intCast(key_int) else null;
//     const as_num: ?u8 = if (48 <= key_int and key_int <= 57) // number row
//         @intCast(key_int)
//     else if (320 <= key_int and key_int <= 329) // numpad
//         @intCast(key_int - (320 - 48))
//     else
//         null;
//     const as_punc: ?u8 = switch (key) {
//         .apostrophe => '\'',
//         .comma => ',',
//         .minus => '-',
//         .period => '.',
//         .slash => '/',
//         .semicolon => ';',
//         .equal => '=',
//         .space => ' ',
//         .left_bracket => '[',
//         .backslash => '\\',
//         .right_bracket => ']',
//         .grave => '`',
//         else => null,
//     };

//     if (model.cursor) |*cursor_index| {
//         switch (key) {
//             .backspace => {
//                 if (ctrl) {
//                     const maybe_last_sep = mem.lastIndexOfScalar(u8, model.cwd.items[0..cursor_index.*], fs.path.sep);
//                     if (maybe_last_sep) |last_sep| {
//                         const last_sep_index: Index = @intCast(last_sep);
//                         if (cursor_index.* == last_sep_index + 1) {
//                             cursor_index.* -= 1;
//                             _ = model.cwd.orderedRemove(cursor_index.*);
//                         } else {
//                             model.cwd.replaceRangeAssumeCapacity(last_sep_index, cursor_index.* - last_sep_index, "");
//                             cursor_index.* = last_sep_index;
//                         }
//                     } else {
//                         model.cwd.shrinkRetainingCapacity(0);
//                         cursor_index.* = 0;
//                     }
//                 } else if (cursor_index.* > 0) {
//                     _ = model.cwd.orderedRemove(cursor_index.* - 1);
//                     cursor_index.* -= 1;
//                 }
//             },
//             .delete => if (cursor_index.* < model.cwd.items.len) {
//                 if (ctrl) {
//                     const maybe_next_sep = mem.indexOfScalarPos(u8, model.cwd.items, cursor_index.*, fs.path.sep);
//                     if (maybe_next_sep) |next_sep| {
//                         const next_sep_index: Index = @intCast(next_sep);
//                         if (cursor_index.* == next_sep_index) {
//                             _ = model.cwd.orderedRemove(cursor_index.*);
//                         } else {
//                             model.cwd.replaceRangeAssumeCapacity(cursor_index.*, next_sep_index - cursor_index.*, "");
//                         }
//                     } else {
//                         model.cwd.shrinkRetainingCapacity(cursor_index.*);
//                     }
//                 } else {
//                     _ = model.cwd.orderedRemove(cursor_index.*);
//                 }
//             },
//             .tab, .escape => model.exitEditing(),
//             .enter => try model.entries.load_entries(model.cwd.items),
//             .up, .home => cursor_index.* = 0,
//             .down, .end => cursor_index.* = @intCast(model.cwd.items.len),
//             .left => {
//                 if (ctrl) {
//                     const maybe_prev_sep = mem.lastIndexOfScalar(u8, model.cwd.items[0..cursor_index.*], fs.path.sep);
//                     if (maybe_prev_sep) |prev_sep| {
//                         const prev_sep_index: Index = @intCast(prev_sep);
//                         if (cursor_index.* == prev_sep_index + 1) {
//                             cursor_index.* -= 1;
//                         } else {
//                             cursor_index.* = prev_sep_index + 1;
//                         }
//                     } else {
//                         cursor_index.* = 0;
//                     }
//                 } else if (cursor_index.* > 0) {
//                     cursor_index.* -= 1;
//                 }
//             },
//             .right => {
//                 if (ctrl) {
//                     const maybe_next_sep = mem.indexOfScalarPos(u8, model.cwd.items, cursor_index.*, fs.path.sep);
//                     if (maybe_next_sep) |next_sep| {
//                         const next_sep_index: Index = @intCast(next_sep);
//                         if (cursor_index.* == next_sep_index) {
//                             cursor_index.* += 1;
//                         } else {
//                             cursor_index.* = next_sep_index;
//                         }
//                     } else {
//                         cursor_index.* = @intCast(model.cwd.items.len);
//                     }
//                 } else if (cursor_index.* < model.cwd.items.len) {
//                     cursor_index.* += 1;
//                 }
//             },

//             else => {
//                 const maybe_char: ?u8 = if (as_alpha) |alpha|
//                     if (!shift) ascii.toLower(alpha) else alpha
//                 else if (as_num) |num|
//                     if (shift) switch (num) {
//                         '1' => '!',
//                         '2' => '@',
//                         '3' => '#',
//                         '4' => '$',
//                         '5' => '%',
//                         '6' => '^',
//                         '7' => '&',
//                         '8' => '*',
//                         '9' => '(',
//                         '0' => ')',
//                         else => unreachable,
//                     } else num
//                 else if (as_punc) |punc|
//                     if (shift) switch (punc) {
//                         '\'' => '"',
//                         ',' => '<',
//                         '-' => '_',
//                         '.' => '>',
//                         '/' => '?',
//                         ';' => ':',
//                         '=' => '+',
//                         ' ' => ' ',
//                         '[' => '{',
//                         '\\' => '|',
//                         ']' => '}',
//                         '`' => '~',
//                         else => unreachable,
//                     } else punc
//                 else
//                     null;

//                 if (maybe_char) |char| {
//                     if (ctrl) {
//                         switch (char) {
//                             'c' => {
//                                 try model.cwd.append(main.alloc, 0);
//                                 defer _ = model.cwd.pop();
//                                 rl.setClipboardText(@ptrCast(model.cwd.items.ptr));
//                             },
//                             'v' => {
//                                 var clipboard: []const u8 = mem.span(rl.getClipboardText());
//                                 if (clipboard.len > max_paste_len) clipboard = clipboard[0..max_paste_len]; // TODO cull large cwd
//                                 try model.cwd.insertSlice(main.alloc, cursor_index.*, clipboard);
//                                 cursor_index.* += @intCast(clipboard.len);
//                             },
//                             else => {},
//                         }
//                     } else {
//                         try model.cwd.insert(main.alloc, cursor_index.*, char);
//                         cursor_index.* += 1;
//                     }
//                 }
//             },
//         }
//     } else {
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
