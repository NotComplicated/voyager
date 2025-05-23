const std = @import("std");
const ascii = std.ascii;
const enums = std.enums;
const meta = std.meta;
const time = std.time;
const mem = std.mem;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const windows = @import("windows.zig");

mouse_pos: clay.Vector2,
action: ?union(enum) {
    mouse: struct {
        state: enum { pressed, down, released },
        button: rl.MouseButton,
    },
    key: union(enum) {
        char: u8,
        f: u4,
        delete,
        backspace,
        home,
        end,
        escape,
        enter,
        tab,
        up,
        down,
        left,
        right,
    },
    event: if (main.is_windows) windows.Event else noreturn,
},
delta_ms: u32,
shift: bool,
ctrl: bool,
alt: bool,

const Input = @This();

var maybe_prev_key: ?struct { key: rl.KeyboardKey, timer: i64 } = null;
const hold_down_init_delay = 400;
const hold_down_repeat_delay = 50;

pub fn read() Input {
    var input = Input{
        .mouse_pos = main.convertVector(rl.getMousePosition()),
        .action = null,
        .delta_ms = @intFromFloat(rl.getFrameTime() * time.ms_per_s),
        .shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift),
        .ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control),
        .alt = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt),
    };

    if (main.is_windows) {
        if (windows.event) |event| {
            input.action = .{ .event = event };
            windows.event = null;
            return input;
        }
    }

    for (enums.values(rl.MouseButton)) |button| {
        const action: @TypeOf(input.action) = .{
            .mouse = .{
                .state = if (rl.isMouseButtonPressed(button))
                    .pressed
                else if (rl.isMouseButtonReleased(button))
                    .released
                else if (rl.isMouseButtonDown(button))
                    .down
                else
                    continue,
                .button = button,
            },
        };
        input.action = action;
        return input;
    }

    var key = rl.getKeyPressed();
    if (key == .null) {
        if (maybe_prev_key) |*prev_key| {
            if (rl.isKeyDown(prev_key.key)) {
                prev_key.timer -= input.delta_ms;
                if (prev_key.timer <= 0) {
                    prev_key.timer = hold_down_repeat_delay;
                } else return input;
            } else {
                maybe_prev_key = null;
                return input;
            }
            key = prev_key.key;
        } else return input;
    }
    const modifiers = [_]rl.KeyboardKey{ .left_shift, .right_shift, .left_control, .right_control };
    if (maybe_prev_key == null and mem.indexOfScalar(rl.KeyboardKey, &modifiers, key) == null) {
        maybe_prev_key = .{ .key = key, .timer = hold_down_init_delay };
    }

    const key_int = @intFromEnum(key);
    const as_alpha: ?u8 = if (65 <= key_int and key_int <= 90) @intCast(key_int) else null;
    const as_num: ?u8 = if (48 <= key_int and key_int <= 57) // number row
        @intCast(key_int)
    else if (320 <= key_int and key_int <= 329) // numpad
        @intCast(key_int - (320 - 48))
    else
        null;
    const as_f: ?u4 = if (290 <= key_int and key_int <= 301) @intCast(key_int - 290 + 1) else null;
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
        if (input.shift) alpha else ascii.toLower(alpha)
    else if (as_num) |num|
        if (input.shift) switch (num) {
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
        if (input.shift) switch (punc) {
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

    input.action = if (maybe_char) |char|
        .{ .key = .{ .char = char } }
    else if (as_f) |f|
        .{ .key = .{ .f = f } }
    else switch (key) {
        .delete => .{ .key = .delete },
        .backspace => .{ .key = .backspace },
        .home => .{ .key = .home },
        .end => .{ .key = .end },
        .escape => .{ .key = .escape },
        .enter => .{ .key = .enter },
        .tab => .{ .key = .tab },
        .up => .{ .key = .up },
        .down => .{ .key = .down },
        .left => .{ .key = .left },
        .right => .{ .key = .right },
        else => null,
    };
    return input;
}

pub fn clicked(input: Input, button: rl.MouseButton) bool {
    return meta.eql(input.action, .{ .mouse = .{ .state = .pressed, .button = button } });
}

pub fn offset(input: Input, id: clay.Id) ?clay.Vector2 {
    const bounds = main.getBounds(id) orelse return null;
    return .{ .x = input.mouse_pos.x - bounds.x, .y = input.mouse_pos.y - bounds.y };
}
