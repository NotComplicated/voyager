const std = @import("std");
const ascii = std.ascii;
const enums = std.enums;
const time = std.time;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const Millis = main.Millis;

mouse_pos: clay.Vector2,
action: ?union(enum) {
    mouse: struct {
        state: enum { pressed, down, released },
        button: rl.MouseButton,
    },
    key: union(enum) {
        char: u8,
        delete,
        backspace,
        home,
        end,
        escape,
        tab,
        up,
        down,
        left,
        right,
    },
},
shift: bool,
ctrl: bool,

const Input = @This();

var maybe_prev_key: ?struct {
    key: rl.KeyboardKey,
    timer: union(enum) { start: Millis, repeat: Millis },
} = null;
const hold_down_init_delay: Millis = 400;
const hold_down_repeat_delay: Millis = 50;

pub fn read() Input {
    const mouse_pos = main.convertVector(rl.getMousePosition());
    const shift = rl.isKeyDown(rl.KeyboardKey.left_shift) or rl.isKeyDown(rl.KeyboardKey.right_shift);
    const ctrl = rl.isKeyDown(rl.KeyboardKey.left_control) or rl.isKeyDown(rl.KeyboardKey.right_control);

    for (enums.values(rl.MouseButton)) |button| {
        const state = if (rl.isMouseButtonPressed(button))
            .pressed
        else if (rl.isMouseButtonReleased(button))
            .released
        else if (rl.isMouseButtonDown(button))
            .down
        else
            continue;
        return .{
            .mouse_pos = mouse_pos,
            .action = .{ .mouse = .{ state, button } },
            .shift = shift,
            .ctrl = ctrl,
        };
    }

    var key = rl.getKeyPressed();
    if (key == .null) {
        const null_action_input = .{
            .mouse_post = mouse_pos,
            .action = null,
            .shift = shift,
            .ctrl = ctrl,
        };
        if (maybe_prev_key) |prev_key| {
            if (rl.isKeyDown(prev_key.key)) {
                const now = time.milliTimestamp();
                switch (prev_key.timer) {
                    .start => |*timer| if (now - timer.* > hold_down_init_delay) {
                        timer.* = .{ .repeat = now };
                        key = prev_key.key;
                    } else return null_action_input,
                    .repeat => |*timer| if (now - timer.* > hold_down_repeat_delay) {
                        timer.* = .{ .repeat = now };
                        key = prev_key.key;
                    } else return null_action_input,
                }
            } else {
                prev_key = null;
                return null_action_input;
            }
        } else {
            return null_action_input;
        }
    }
    maybe_prev_key = .{ .key = key, .timer = time.milliTimestamp() };

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

    const action = if (maybe_char) |char|
        .{ .key = .{ .char = char } }
    else switch (key) {
        .delete => .{ .key = .{.delete} },
        .backspace => .{ .key = .{.backspace} },
        .home => .{ .key = .{.home} },
        .end => .{ .key = .{.end} },
        .escape => .{ .key = .{.escape} },
        .tab => .{ .key = .{.tab} },
        .up => .{ .key = .{.up} },
        .down => .{ .key = .{.down} },
        .left => .{ .key = .{.left} },
        .right => .{ .key = .{.right} },
        else => null,
    };

    return .{
        .mouse_pos = mouse_pos,
        .action = action,
        .shift = shift,
        .ctrl = ctrl,
    };
}

pub fn clicked(input: Input, button: rl.MouseButton) bool {
    return input.action == .{ .mouse = .{ .state = .pressed, .button = button } };
}

pub fn offset(input: Input, id: clay.Element.Config.Id) ?clay.Vector2 {
    const bounds = main.getBounds(id) orelse return null;
    return .{ .x = input.mouse_pos.x - bounds.x, .y = input.mouse_pos.y - bounds.y };
}
