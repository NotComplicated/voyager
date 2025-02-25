const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const Bytes = main.Bytes;
const Message = @import("message.zig").Message;
const Input = @import("Input.zig");
const Model = @import("Model.zig");

data: Bytes,
editing: bool,
selection: struct { from: ?usize, to: ?usize },
kind: enum { path, text },
id: clay.Element.Config.Id,

const max_paste_len = 1024;
const char_px_width = 9;

const TextBox = @This();

pub fn init(kind: enum { path, text }, id: clay.Element.Config.Id) !TextBox {
    return .{
        .data = try Bytes.init(main.alloc, 256),
        .selection = .{ .from = null, .to = null },
        .editing = false,
        .kind = kind,
        .id = id,
    };
}

pub fn deinit(text_box: *TextBox) void {
    text_box.data.deinit(main.alloc);
}

pub fn handleInput(text_box: TextBox, input: Input) ?Message {
    _ = text_box;
    _ = input;
}

pub fn handleMessage(text_box: *TextBox, message: Message) Model.Error!void {
    _ = text_box;
    _ = message;
}

pub fn setFocus(text_box: *TextBox, focused: bool) void {
    text_box.editing = focused;
}

pub fn mousePressed(text_box: *TextBox, index: usize) void {
    text_box.editing.selection.from = index;
}

pub fn mouseReleased(text_box: *TextBox, index: usize) void {
    text_box.editing.selection.to = index;
    if (text_box.editing.selection.from) |*from| {
        if (text_box.editing.selection.to.? < from.*) {
            mem.swap(?usize, &text_box.editing.selection.to, from);
        }
    }
}

pub fn render(text_box: TextBox) void {
    clay.ui()(.{
        .id = text_box.id,
    })({
        //comptime onHoverFunction: *const fn(element_id:clay.Element.Config.Id, pointer_data:clay.Pointer.Data, user_data:*T, )callconv(.Inline)void)
        clay.onHover(
            TextBox,
            text_box,
            struct {
                inline fn onHover(id: clay.Element.Config.Id, pointer_data: clay.Pointer.Data, passed_text_box: *TextBox) void {
                    switch (pointer_data.state) {
                        .pressed_this_frame => {
                            const bounds = main.getBounds(id);
                            passed_text_box.mousePressed(@intFromFloat((pointer_data.position.x - bounds.x) / char_px_width));
                        },
                        else => {},
                    }
                }
            }.onHover,
        );
    });
}

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
    const word_sep = if (text_box.kind == .path) fs.path.sep else ' ';

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
