const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const Bytes = main.Bytes;
const Input = @import("Input.zig");
const Model = @import("Model.zig");

pub fn TextBox(kind: enum { path, text }, id: clay.Element.Config.Id) type {
    return struct {
        data: Bytes,
        cursor: union(enum) {
            none,
            at: usize,
            select: struct { from: usize, to: usize },
        },

        const max_paste_len = 1024;
        const char_px_width = 9;

        const Self = @This();

        const Message = union(enum) {
            submit: []const u8,
        };

        pub fn init() Model.Error!Self {
            return .{
                .data = try Bytes.initCapacity(main.alloc, 1024),
                .cursor = .none,
            };
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit(main.alloc);
        }

        pub fn update(self: *Self, input: Input) ?Message {
            _ = input;
            return self.data.items;
        }

        pub fn render(self: Self) void {
            clay.ui()(.{
                .id = id,
                .layout = .{
                    .padding = clay.Padding.all(6),
                    .sizing = .{
                        .width = .{ .type = .grow },
                        .height = clay.Element.Sizing.Axis.fixed(Model.row_height),
                    },
                    .child_alignment = .{ .y = clay.Element.Config.Layout.AlignmentY.center },
                },
                .rectangle = .{ //TODO color based on if editing
                    .color = if (self.cursor == .none) main.theme.nav else main.theme.selected,
                    .corner_radius = main.rounded,
                },
            })({
                main.pointer();
                switch (self.cursor) {
                    .none => {
                        // TODO special rendering for paths?
                        main.textEx(.roboto_mono, .sm, self.data.items, main.theme.text);
                    },
                    .at => |index| {
                        main.textEx(.roboto_mono, .sm, self.data.items[0..index], main.theme.text);
                        clay.ui()(.{
                            .floating = .{
                                .offset = .{ .x = @floatFromInt(index * 9), .y = -2 },
                                .attachment = .{ .element = .left_center, .parent = .left_center },
                            },
                        })({
                            main.textEx(.roboto_mono, .md, "|", main.theme.bright_text);
                        });
                        main.textEx(.roboto_mono, .sm, self.data.items[index..], main.theme.text);
                    },
                    .select => |selection| {
                        main.textEx(.roboto_mono, .sm, self.data.items[0..selection.from], main.theme.text);
                        main.textEx(.roboto_mono, .sm, self.data.items[selection.from..selection.to], main.theme.sapphire);
                        main.textEx(.roboto_mono, .sm, self.data.items[selection.to..], main.theme.text);
                    },
                }
            });
        }

        // TODO move to update
        pub fn handleKey(text_box: *TextBox, key: rl.KeyboardKey, shift: bool, ctrl: bool) !void {
            if (!text_box.editing) {
                return;
            }

            const key_int = @intFromEnum(key);
            const as_alpha: ?u8 = if (65 <= key_int and key_int <= 90) @intCast(key_int) else null;
            const as_num: ?u8 = if (48 <= key_int and key_int <= 57) // number row
                @intCast(key_int)
            else if (320 <= key_int and key_int <= 329) // numpad
                @intCast(key_int - (320 - 48))
            else
                null;
            const as_punc: ?u8 = switch (key) {
                .apostrophe => '\'',
                .comma => ',',
                .minus => '-',
                .period => '.',
                .slash => '/',
                .semicolon => ';',
                .equal => '=',
                .space => ' ',
                .left_bracket => '[',
                .backslash => '\\',
                .right_bracket => ']',
                .grave => '`',
                else => null,
            };
            const word_sep = if (kind == .path) fs.path.sep else ' ';

            switch (key) {
                .backspace => {
                    if (ctrl) {
                        const maybe_last_sep = mem.lastIndexOfScalar(u8, text_box.cwd.items[0..text_box.cursor], word_sep);
                        if (maybe_last_sep) |last_sep| {
                            if (text_box.cursor == last_sep + 1) {
                                text_box.cursor -= 1;
                                _ = text_box.cwd.orderedRemove(text_box.cursor);
                            } else {
                                text_box.cwd.replaceRangeAssumeCapacity(last_sep, text_box.cursor - last_sep, "");
                                text_box.cursor = last_sep;
                            }
                        } else {
                            text_box.cwd.shrinkRetainingCapacity(0);
                            text_box.cursor = 0;
                        }
                    } else if (text_box.cursor > 0) {
                        _ = text_box.cwd.orderedRemove(text_box.cursor - 1);
                        text_box.cursor -= 1;
                    }
                },
                .delete => if (text_box.cursor < text_box.cwd.items.len) {
                    if (ctrl) {
                        const maybe_next_sep = mem.indexOfScalarPos(u8, text_box.cwd.items, text_box.cursor, word_sep);
                        if (maybe_next_sep) |next_sep| {
                            if (text_box.cursor == next_sep) {
                                _ = text_box.cwd.orderedRemove(text_box.cursor);
                            } else {
                                text_box.cwd.replaceRangeAssumeCapacity(text_box.cursor, next_sep - text_box.cursor, "");
                            }
                        } else {
                            text_box.cwd.shrinkRetainingCapacity(text_box.cursor);
                        }
                    } else {
                        _ = text_box.cwd.orderedRemove(text_box.cursor);
                    }
                },
                .tab, .escape => text_box.exitEditing(),
                .enter => try text_box.entries.load_entries(text_box.cwd.items),
                .up, .home => text_box.cursor = 0,
                .down, .end => text_box.cursor = @intCast(text_box.cwd.items.len),
                .left => {
                    if (ctrl) {
                        const maybe_prev_sep = mem.lastIndexOfScalar(u8, text_box.cwd.items[0..text_box.cursor], word_sep);
                        if (maybe_prev_sep) |prev_sep| {
                            if (text_box.cursor == prev_sep + 1) {
                                text_box.cursor -= 1;
                            } else {
                                text_box.cursor = prev_sep + 1;
                            }
                        } else {
                            text_box.cursor = 0;
                        }
                    } else if (text_box.cursor > 0) {
                        text_box.cursor -= 1;
                    }
                },
                .right => {
                    if (ctrl) {
                        const maybe_next_sep = mem.indexOfScalarPos(u8, text_box.cwd.items, text_box.cursor, word_sep);
                        if (maybe_next_sep) |next_sep| {
                            if (text_box.cursor == next_sep) {
                                text_box.cursor += 1;
                            } else {
                                text_box.cursor = next_sep;
                            }
                        } else {
                            text_box.cursor = @intCast(text_box.cwd.items.len);
                        }
                    } else if (text_box.cursor < text_box.cwd.items.len) {
                        text_box.cursor += 1;
                    }
                },

                else => {
                    const maybe_char: ?u8 = if (as_alpha) |alpha|
                        if (!shift) ascii.toLower(alpha) else alpha
                    else if (as_num) |num|
                        if (shift) switch (num) {
                            '1' => '!',
                            '2' => '@',
                            '3' => '#',
                            '4' => '$',
                            '5' => '%',
                            '6' => '^',
                            '7' => '&',
                            '8' => '*',
                            '9' => '(',
                            '0' => ')',
                            else => unreachable,
                        } else num
                    else if (as_punc) |punc|
                        if (shift) switch (punc) {
                            '\'' => '"',
                            ',' => '<',
                            '-' => '_',
                            '.' => '>',
                            '/' => '?',
                            ';' => ':',
                            '=' => '+',
                            ' ' => ' ',
                            '[' => '{',
                            '\\' => '|',
                            ']' => '}',
                            '`' => '~',
                            else => unreachable,
                        } else punc
                    else
                        null;

                    if (maybe_char) |char| {
                        if (ctrl) {
                            switch (char) {
                                'c' => {
                                    try text_box.cwd.append(main.alloc, 0);
                                    defer _ = text_box.cwd.pop();
                                    rl.setClipboardText(@ptrCast(text_box.cwd.items.ptr));
                                },
                                'v' => {
                                    var clipboard: []const u8 = mem.span(rl.getClipboardText());
                                    if (clipboard.len > max_paste_len) clipboard = clipboard[0..max_paste_len];
                                    try text_box.cwd.insertSlice(main.alloc, text_box.cursor, clipboard);
                                    text_box.cursor += @intCast(clipboard.len);
                                },
                                else => {},
                            }
                        } else {
                            try text_box.cwd.insert(main.alloc, text_box.cursor, char);
                            text_box.cursor += 1;
                        }
                    }
                },
            }
        }

        pub fn value(self: Self) []const u8 {
            return self.data.items;
        }

        pub fn appendString(self: *Self, string: []const u8) Model.Error!void {
            return self.data.appendSlice(main.alloc, string);
        }

        pub fn popPath(self: *Self) if (kind == .path) void else @compileError("popPath only works on paths") {
            const parent_dir_path = fs.path.dirname(self.value()) orelse return;
            self.data.shrinkRetainingCapacity(parent_dir_path.len);
        }
    };
}
