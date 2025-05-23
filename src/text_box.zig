const std = @import("std");
const unicode = std.unicode;
const ascii = std.ascii;
const math = std.math;
const meta = std.meta;
const sort = std.sort;
const time = std.time;
const fmt = std.fmt;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const themes = @import("themes.zig");
const resources = @import("resources.zig");
const draw = @import("draw.zig");
const alert = @import("alert.zig");
const menu = @import("menu.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");
const Error = @import("error.zig").Error;

pub fn TextBox(kind: enum(u8) { path, text }, id: clay.Id, checkmark_id: ?clay.Id) type {
    return struct {
        content: main.ArrayList(u8),
        cursor: Cursor,
        right_click_at: ?usize,
        timer: u32,
        history: std.BoundedArray(struct { content: main.ArrayList(u8), cursor: Cursor }, max_history),
        tab_complete: if (kind == .path) struct {
            completions: main.ArrayList([2]u32),
            names: main.ArrayList(u8),
            state: union(enum) { unloaded, selecting: usize, just_updated: usize },
        } else void,

        pub const empty = Self{
            .content = .empty,
            .cursor = .none,
            .right_click_at = null,
            .timer = 0,
            .history = history: {
                var history = @FieldType(Self, "history"){};
                history.appendAssumeCapacity(.{ .content = .empty, .cursor = .none });
                for (history.unusedCapacitySlice()) |*hist| hist.* = .{ .content = .empty, .cursor = .none };
                break :history history;
            },
            .tab_complete = if (kind == .path) .{
                .completions = .empty,
                .names = .empty,
                .state = .unloaded,
            } else {},
        };

        const max_history = 16;
        const max_completions_search = 512;
        const max_len = if (kind == .path) 512 else 2048;
        const max_paste_len = if (kind == .path) 512 else 1024;
        const char_px_width = 9;
        const ibeam_x_offset = 2;
        const ibeam_y_offset = -2;
        const ibeam_blink_interval = 600;
        const select_all_delay = 150;

        const Self = @This();

        const Cursor = union(enum) {
            none,
            at: usize,
            select: Selection,
        };

        const Selection = struct {
            from: usize,
            to: usize,

            fn left(selection: Selection) usize {
                return @min(selection.from, selection.to);
            }

            fn right(selection: Selection) usize {
                return @max(selection.from, selection.to);
            }

            fn len(selection: Selection) usize {
                return selection.right() - selection.left();
            }
        };

        const Message = union(enum) {
            submit: []const u8,
        };

        const Menu = enum {
            cut,
            copy,
            paste,
            undo,
            redo,
            select_all,
        };

        pub fn init(contents: []const u8, state: enum { unfocused, selected }) Error!Self {
            var content = try @FieldType(Self, "content").initCapacity(main.alloc, 256);
            errdefer content.deinit(main.alloc);

            var completions = if (kind == .path)
                try @FieldType(@FieldType(Self, "tab_complete"), "completions").initCapacity(main.alloc, 256)
            else {};
            errdefer if (kind == .path) completions.deinit(main.alloc);

            var names = if (kind == .path)
                try @FieldType(@FieldType(Self, "tab_complete"), "names").initCapacity(main.alloc, 256 * 8)
            else {};
            errdefer if (kind == .path) names.deinit(main.alloc);

            var text_box = Self{
                .content = content,
                .cursor = switch (state) {
                    .unfocused => .none,
                    .selected => .{ .select = .{ .from = 0, .to = contents.len } },
                },
                .right_click_at = null,
                .timer = 0,
                .history = .{},
                .tab_complete = if (kind == .path) .{ .completions = completions, .names = names, .state = .unloaded } else {},
            };

            try text_box.content.appendSlice(main.alloc, contents);

            for (text_box.history.unusedCapacitySlice()) |*hist| {
                hist.* = .{ .content = try text_box.content.clone(main.alloc), .cursor = .none };
            }
            text_box.history.len = 1;
            text_box.history.slice()[0].cursor = text_box.cursor;

            return text_box;
        }

        pub fn deinit(self: *Self) void {
            self.content.deinit(main.alloc);
            for (self.history.slice()) |*hist| hist.content.deinit(main.alloc);
            for (self.history.unusedCapacitySlice()) |*hist| hist.content.deinit(main.alloc);
            if (kind == .path) {
                self.tab_complete.completions.deinit(main.alloc);
                self.tab_complete.names.deinit(main.alloc);
            }
        }

        pub fn update(self: *Self, input: Input) Error!?Message {
            var maybe_updated = self.cursor != .none and
                input.action != null and
                meta.activeTag(input.action.?) != .mouse;

            self.timer +|= input.delta_ms;
            self.history.slice()[self.history.len - 1].cursor = self.cursor;
            const maybe_message = try self.handleInput(input, &maybe_updated);
            if (self.utf8Len() > max_len) {
                self.content.items.len = max_len;
                self.fixCursor();
            }

            if (maybe_updated) {
                self.timer = 0;
                try self.updateHistory();
                if (kind == .path) self.tab_complete.state = switch (self.tab_complete.state) {
                    .unloaded, .selecting => .unloaded,
                    .just_updated => |current| .{ .selecting = current },
                };
            }

            if (maybe_message) |message| {
                switch (message) {
                    .submit => |contents| if (kind == .path) {
                        var realpath = fs.realpathAlloc(main.alloc, contents) catch |err| return switch (err) {
                            error.OutOfMemory => Error.OutOfMemory,
                            else => Error.OpenDirFailure,
                        };
                        defer main.alloc.free(realpath);

                        // windows has an awful realpath API
                        if (main.is_windows and ascii.eqlIgnoreCase(contents, fs.path.diskDesignator(realpath))) {
                            main.alloc.free(realpath);
                            realpath = try mem.concat(main.alloc, u8, &.{ contents, fs.path.sep_str });
                            self.cursor = .{ .at = self.utf8Len() + 1 };
                        }

                        self.content.clearRetainingCapacity();
                        try self.content.appendSlice(main.alloc, realpath);
                        self.fixCursor();
                        try self.updateHistory();
                    },
                }
            }

            return maybe_message;
        }

        fn handleInput(self: *Self, input: Input, maybe_updated: *bool) Error!?Message {
            if (checkmark_id) |c_id| if (input.clicked(.left) and clay.pointerOver(c_id)) {
                return .{ .submit = self.value() };
            };

            if (menu.get(Menu, input)) |option| {
                switch (option) {
                    .cut => if (self.cursor == .select) {
                        try self.copy(self.cursor.select);
                        self.removeCursor();
                        maybe_updated.* = true;
                    },
                    .copy => if (self.cursor == .select) {
                        try self.copy(self.cursor.select);
                        self.timer = 0;
                    },
                    .paste => switch (self.cursor) {
                        .none => {},
                        .at => |index| {
                            try self.paste(index, 0);
                            maybe_updated.* = true;
                        },
                        .select => |selection| {
                            try self.paste(selection.left(), selection.len());
                            maybe_updated.* = true;
                        },
                    },
                    .undo => {
                        maybe_updated.* = false;
                        try self.undo();
                    },
                    .redo => {
                        maybe_updated.* = false;
                        try self.redo();
                    },
                    .select_all => {
                        self.cursor = .{ .select = .{ .from = 0, .to = self.utf8Len() } };
                        self.timer = 0;
                    },
                }
                return null;
            }

            const hovered = clay.pointerOver(id);

            if (hovered) if (input.action) |action| switch (action) {
                .mouse => |mouse| if (mouse.button == .right and mouse.state == .released) {
                    self.right_click_at = null;
                    const data = clay.getElementData(id);
                    if (data.found) {
                        const pos = clay.Vector2{
                            .x = input.mouse_pos.x,
                            .y = data.boundingBox.y + data.boundingBox.height / 2,
                        };
                        const has_selection = self.cursor == .select and self.cursor.select.len() > 0;
                        menu.register(Menu, pos, .{
                            .cut = .{
                                .name = "Cut",
                                .icon = &resources.images.cut,
                                .enabled = has_selection,
                            },
                            .copy = .{
                                .name = "Copy",
                                .icon = &resources.images.copy,
                                .enabled = has_selection,
                            },
                            .paste = .{
                                .name = "Paste",
                                .icon = &resources.images.paste,
                                .enabled = self.cursor != .none,
                            },
                            .undo = .{
                                .name = "Undo",
                                .icon = &resources.images.backward,
                                .enabled = self.history.len > 1,
                            },
                            .redo = .{
                                .name = "Redo",
                                .icon = &resources.images.forward,
                                .enabled = self.history.unusedCapacitySlice().len > 0 and
                                    self.history.unusedCapacitySlice()[0].cursor != .none,
                            },
                            .select_all = .{
                                .name = "Select All",
                                .icon = &resources.images.highlight,
                            },
                        });
                    }
                },
                else => {},
            };

            switch (self.cursor) {
                .none => if ((input.clicked(.left) or input.clicked(.right)) and hovered) {
                    if (self.mouseAt(input.mouse_pos)) |at| {
                        self.cursor = .{ .select = .{ .from = at, .to = at } };
                        if (input.clicked(.right)) self.right_click_at = at;
                    }
                },

                .at => |index| switch (input.action orelse return null) {
                    .mouse => if (input.clicked(.left) or input.clicked(.right)) {
                        if (hovered) {
                            if (self.mouseAt(input.mouse_pos)) |at| {
                                if (input.clicked(.right)) {
                                    if (self.right_click_at) |right_click_at| if (at != right_click_at) {
                                        self.cursor = .{ .select = .{ .from = right_click_at, .to = at } };
                                        self.right_click_at = null;
                                        return null;
                                    };
                                }
                                self.cursor = .{
                                    .select = if (at == index and self.timer < main.double_click_delay)
                                        .{ .from = 0, .to = self.utf8Len() }
                                    else
                                        .{ .from = if (input.shift) index else at, .to = at },
                                };
                                self.timer = 0;
                            }
                        } else self.cursor = .none;
                    },

                    .key => |key| switch (key) {
                        .char => |char| {
                            if (input.ctrl) {
                                switch (char) {
                                    'v' => try self.paste(index, 0),
                                    'a' => self.cursor = .{ .select = .{ .from = 0, .to = self.utf8Len() } },
                                    'z' => {
                                        maybe_updated.* = false;
                                        try self.undo();
                                    },
                                    'y' => {
                                        maybe_updated.* = false;
                                        try self.redo();
                                    },
                                    else => {},
                                }
                            } else {
                                const byte_index = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                                    var chars_iter = chars.iterator();
                                    break :utf8 chars_iter.peek(index).len;
                                } else |_| index;
                                try self.content.insert(main.alloc, byte_index, char);
                                self.cursor.at += 1;
                            }
                        },

                        .f => |_| {},

                        .delete => if (input.ctrl) self.removeCursorToNextSep() else self.removeCursor(),

                        .backspace => if (input.ctrl) self.removeCursorToPrevSep() else if (index > 0) {
                            self.cursor.at -= 1;
                            self.removeCursor();
                        },

                        .escape => self.cursor = .none,

                        .tab => if (kind == .path) {
                            if (self.tab_complete.completions.items.len == 1) switch (self.tab_complete.state) {
                                .unloaded, .just_updated => {},
                                .selecting => |current| {
                                    const start, const end = self.tab_complete.completions.items[current];
                                    try self.content.appendSlice(main.alloc, self.tab_complete.names.items[start..end]);
                                    self.cursor = .{ .at = self.utf8Len() };
                                    return null;
                                },
                            };
                            self.updateCompletions(if (input.shift) .backward else .forward);
                        } else {
                            self.cursor = .none;
                        },

                        .enter => {
                            if (kind == .path) switch (self.tab_complete.state) {
                                .unloaded, .just_updated => {},
                                .selecting => |current| {
                                    const start, const end = self.tab_complete.completions.items[current];
                                    try self.content.appendSlice(main.alloc, self.tab_complete.names.items[start..end]);
                                    self.cursor = .{ .at = self.utf8Len() };
                                    return null;
                                },
                            };
                            return .{ .submit = self.value() };
                        },

                        .up, .home => self.cursor = if (input.shift)
                            .{ .select = .{ .from = index, .to = 0 } }
                        else
                            .{ .at = 0 },

                        .down, .end => self.cursor = if (input.shift)
                            .{ .select = .{ .from = index, .to = self.utf8Len() } }
                        else
                            .{ .at = self.utf8Len() },

                        .left => {
                            const dest = if (input.ctrl)
                                toPrevSep(self.value(), index)
                            else
                                index -| 1;
                            self.cursor = if (input.shift)
                                .{ .select = .{ .from = index, .to = dest } }
                            else
                                .{ .at = dest };
                        },

                        .right => {
                            if (kind == .path) switch (self.tab_complete.state) {
                                .unloaded, .just_updated => {},
                                .selecting => |current| {
                                    const start, const end = self.tab_complete.completions.items[current];
                                    try self.content.appendSlice(main.alloc, self.tab_complete.names.items[start..end]);
                                    self.cursor = .{ .at = self.utf8Len() };
                                    return null;
                                },
                            };
                            const dest = if (input.ctrl)
                                toNextSep(self.value(), index)
                            else
                                index + @intFromBool(index < self.utf8Len());
                            self.cursor = if (input.shift)
                                .{ .select = .{ .from = index, .to = dest } }
                            else
                                .{ .at = dest };
                        },
                    },

                    .event => |event| if (main.is_windows) switch (event) {
                        .cut, .copy => {},
                        .paste => try self.paste(index, 0),
                        .undo => try self.undo(),
                        .redo => try self.redo(),
                        .special_char => |char| {
                            var encoded: [4]u8 = undefined;
                            const len = unicode.utf8Encode(char, &encoded) catch return null;
                            const byte_index = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                                var chars_iter = chars.iterator();
                                break :utf8 chars_iter.peek(index).len;
                            } else |_| index;
                            try self.content.insertSlice(main.alloc, byte_index, encoded[0..len]);
                            self.cursor.at += 1;
                        },
                    },
                },

                .select => |selection| switch (input.action orelse return null) {
                    .mouse => |mouse| if (mouse.button == .left or mouse.button == .right) switch (mouse.state) {
                        .pressed => if (hovered) {
                            if (self.mouseAt(input.mouse_pos)) |at| {
                                if (mouse.button == .left) {
                                    if (input.shift) {
                                        self.cursor.select.to = at;
                                    } else self.cursor = .{ .select = .{ .from = at, .to = at } };
                                } else {
                                    self.right_click_at = at;
                                }
                            }
                        } else {
                            self.cursor = .none;
                        },

                        .down => if (self.mouseAt(input.mouse_pos)) |at| {
                            if (mouse.button == .left) {
                                if (self.timer > select_all_delay) self.cursor.select.to = at;
                            } else {
                                if (self.right_click_at) |right_click_at| {
                                    if (at != right_click_at) {
                                        self.cursor = .{ .select = .{ .from = right_click_at, .to = at } };
                                        self.right_click_at = null;
                                    }
                                } else if (self.timer > select_all_delay) self.cursor.select.to = at;
                            }
                        },

                        .released => if (selection.from == selection.to) {
                            self.cursor = .{ .at = selection.from };
                            self.timer = 0;
                        },
                    },

                    .key => |key| switch (key) {
                        .char => |char| {
                            if (input.ctrl) {
                                switch (char) {
                                    'c' => try self.copy(selection),
                                    'x' => {
                                        try self.copy(selection);
                                        self.removeCursor();
                                    },
                                    'v' => try self.paste(selection.left(), selection.len()),
                                    'a' => self.cursor = .{ .select = .{ .from = 0, .to = self.utf8Len() } },
                                    'z' => {
                                        maybe_updated.* = false;
                                        try self.undo();
                                    },
                                    'y' => {
                                        maybe_updated.* = false;
                                        try self.redo();
                                    },
                                    else => {},
                                }
                            } else {
                                const byte_index, const byte_len = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                                    var chars_iter = chars.iterator();
                                    for (0..selection.left()) |_| _ = chars_iter.nextCodepoint();
                                    break :utf8 .{ chars_iter.i, chars_iter.peek(selection.len()).len };
                                } else |_| .{ selection.left(), selection.len() };
                                try self.content.replaceRange(main.alloc, byte_index, byte_len, &.{char});
                                self.cursor = .{ .at = selection.left() + 1 };
                            }
                        },

                        .f => |_| {},

                        .delete, .backspace => self.removeCursor(),

                        .escape => self.cursor = .none,

                        .tab => if (kind == .path) self.updateCompletions(if (input.shift) .backward else .forward) else {
                            self.cursor = .none;
                        },

                        .enter => return .{ .submit = self.value() },

                        .up, .home => self.cursor = if (input.shift)
                            .{ .select = .{ .from = selection.right(), .to = 0 } }
                        else
                            .{ .at = 0 },

                        .down, .end => self.cursor = if (input.shift)
                            .{ .select = .{ .from = selection.left(), .to = self.utf8Len() } }
                        else
                            .{ .at = self.utf8Len() },

                        .left => if (input.shift) {
                            const dest = if (input.ctrl)
                                toPrevSep(self.value(), selection.to)
                            else
                                selection.to -| 1;
                            if (dest == selection.from) {
                                self.cursor = .{ .at = dest };
                            } else {
                                self.cursor.select.to = dest;
                            }
                        } else {
                            self.cursor = .{ .at = selection.left() };
                        },

                        .right => if (input.shift) {
                            const dest = if (input.ctrl)
                                toNextSep(self.value(), selection.to)
                            else
                                selection.to + @intFromBool(selection.to < self.utf8Len());
                            if (dest == selection.from) {
                                self.cursor = .{ .at = dest };
                            } else {
                                self.cursor.select.to = dest;
                            }
                        } else {
                            self.cursor = .{ .at = selection.right() };
                        },
                    },

                    .event => |event| if (main.is_windows) switch (event) {
                        .cut => {
                            try self.copy(selection);
                            self.removeCursor();
                        },
                        .copy => try self.copy(selection),
                        .paste => try self.paste(selection.left(), selection.len()),
                        .undo => try self.undo(),
                        .redo => try self.redo(),
                        .special_char => |char| {
                            var encoded: [4]u8 = undefined;
                            const len = unicode.utf8Encode(char, &encoded) catch return null;
                            const byte_index, const byte_len = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                                var chars_iter = chars.iterator();
                                for (0..selection.left()) |_| _ = chars_iter.nextCodepoint();
                                break :utf8 .{ chars_iter.i, chars_iter.peek(selection.len()).len };
                            } else |_| .{ selection.left(), selection.len() };
                            try self.content.replaceRange(main.alloc, byte_index, byte_len, encoded[0..len]);
                            self.cursor = .{ .at = selection.left() + 1 };
                        },
                    },
                },
            }

            return null;
        }

        pub fn render(self: Self) void {
            clay.ui()(.{
                .id = id,
                .layout = .{
                    .padding = .horizontal(8),
                    .sizing = .{
                        .width = .grow(.{}),
                        .height = .fixed(Model.row_height),
                    },
                    .child_alignment = .{ .y = .center },
                },
                .bg_color = if (self.cursor == .none) themes.current.nav else themes.current.selected,
                .corner_radius = draw.rounded,
                .scroll = .{ .horizontal = true },
            })({
                draw.ibeam();

                switch (self.cursor) {
                    .none => draw.text(self.content.items, .{ .font = .roboto_mono }),

                    .at => |index| {
                        const before, const after = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                            var chars_iter = chars.iterator();
                            const before = chars_iter.peek(index);
                            break :utf8 .{ before, self.value()[before.len..] };
                        } else |_| .{ self.value()[0..index], self.value()[index..] };

                        draw.text(before, .{ .font = .roboto_mono });
                        if ((self.timer / ibeam_blink_interval) % 2 == 0) {
                            clay.ui()(.{
                                .floating = .{
                                    .offset = .{
                                        .x = @floatFromInt(index * char_px_width + ibeam_x_offset),
                                        .y = ibeam_y_offset,
                                    },
                                    .z_index = 4,
                                    .attach_points = .{ .element = .left_center, .parent = .left_center },
                                    .pointer_capture_mode = .passthrough,
                                    .attach_to = .parent,
                                },
                            })({
                                draw.text(
                                    "|",
                                    .{
                                        .font = .roboto_mono,
                                        .font_size = .xl,
                                        .color = themes.current.bright_text,
                                    },
                                );
                            });
                        }
                        draw.text(after, .{ .font = .roboto_mono });
                    },

                    .select => |selection| {
                        const before, const inside, const after = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                            var chars_iter = chars.iterator();
                            const before = chars_iter.peek(selection.left());
                            chars_iter = unicode.Utf8View.initUnchecked(self.value()[before.len..]).iterator();
                            const inside = chars_iter.peek(selection.len());
                            break :utf8 .{ before, inside, self.value()[before.len + inside.len ..] };
                        } else |_| .{
                            self.value()[selection.left()..],
                            self.value()[selection.left()..selection.right()],
                            self.value()[selection.right()..],
                        };

                        draw.text(before, .{ .font = .roboto_mono });
                        clay.ui()(.{
                            .bg_color = themes.current.highlight,
                        })({
                            draw.text(inside, .{ .font = .roboto_mono, .color = themes.current.base });
                        });
                        draw.text(after, .{ .font = .roboto_mono });
                    },
                }

                if (kind == .path) switch (self.tab_complete.state) {
                    .unloaded => {},
                    .selecting, .just_updated => |current| {
                        const start, const end = self.tab_complete.completions.items[current];
                        draw.text(
                            self.tab_complete.names.items[start..end],
                            .{ .font = .roboto_mono, .color = themes.current.dim_text },
                        );
                    },
                };

                if (checkmark_id) |c_id| {
                    clay.ui()(.{
                        .id = c_id,
                        .layout = .{
                            .sizing = .fixed(32),
                        },
                        .floating = .{
                            .z_index = 4,
                            .attach_points = .{ .element = .right_center, .parent = .right_center },
                            .parent_id = id.id,
                            .attach_to = .parent,
                        },
                        .image = .{
                            .image_data = &resources.images.checkmark,
                            .source_dimensions = .square(32),
                        },
                        .bg_color = if (clay.hovered()) themes.current.bright_text else themes.current.text,
                    })({
                        draw.pointer();
                    });
                }
            });
        }

        pub fn value(self: Self) []const u8 {
            return self.content.items;
        }

        pub fn isActive(self: Self) bool {
            return self.cursor != .none;
        }

        pub fn focus(self: *Self) void {
            self.cursor = .{ .at = self.utf8Len() };
            self.timer = 0;
        }

        pub fn set(self: *Self, new_value: []const u8) Error!void {
            self.content.clearRetainingCapacity();
            try self.content.appendSlice(main.alloc, new_value);
            self.cursor = .none;
            try self.updateHistory();
        }

        pub fn popPath(self: *Self) Error!void {
            if (kind != .path) @compileError("popPath only works on paths");
            const parent_dir_path = fs.path.dirname(self.value()) orelse return;
            self.content.shrinkRetainingCapacity(parent_dir_path.len);
            self.fixCursor();
            try self.updateHistory();
        }

        pub fn appendPath(self: *Self, entry_name: []const u8) Error!void {
            if (kind != .path) @compileError("appendPath only works on paths");
            try self.content.append(main.alloc, fs.path.sep);
            try self.content.appendSlice(main.alloc, entry_name);
            if (self.utf8Len() > max_len) {
                self.content.items.len = max_len;
                self.fixCursor();
            }
            try self.updateHistory();
        }

        pub fn format(self: Self, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
            try fmt.format(writer, "value: {s}\n", .{self.value()});
            switch (self.cursor) {
                .none => {},
                .at => |index| try fmt.format(writer, "at: {}\n", .{index}),
                .select => |selection| try fmt.format(
                    writer,
                    "from: {} to: {}\n",
                    .{ selection.from, selection.to },
                ),
            }
            try fmt.format(writer, "History:\n", .{});
            for (self.history.constSlice(), 0..) |hist, i| {
                try fmt.format(writer, "{}) value: {s}\n", .{ i, hist.content.items });
                switch (hist.cursor) {
                    .none => {},
                    .at => |index| try fmt.format(writer, "{}) at: {}\n", .{ i, index }),
                    .select => |selection| try fmt.format(
                        writer,
                        "{}) from: {} to: {}\n",
                        .{ i, selection.from, selection.to },
                    ),
                }
            }
        }

        fn utf8Len(self: Self) usize {
            return unicode.utf8CountCodepoints(self.value()) catch self.value().len;
        }

        fn updateHistory(self: *Self) Error!void {
            if (!mem.eql(u8, self.value(), self.history.get(self.history.len - 1).content.items)) {
                const next_hist = self.history.addOne() catch rotate: {
                    mem.rotate(meta.Elem(@TypeOf(self.history.slice())), self.history.slice(), 1);
                    break :rotate &self.history.slice()[self.history.len - 1];
                };
                next_hist.content.clearRetainingCapacity();
                try next_hist.content.appendSlice(main.alloc, self.value());
                next_hist.cursor = self.cursor;
            }
        }

        fn fixCursor(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |*index| index.* = @min(index.*, self.utf8Len()),
                .select => |*selection| {
                    selection.from = @min(selection.from, self.utf8Len());
                    selection.to = @min(selection.to, self.utf8Len());
                    if (selection.from == selection.to) self.cursor = .{ .at = selection.from };
                },
            }
        }

        fn removeCursor(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| if (unicode.Utf8View.init(self.value())) |chars| {
                    var chars_iter = chars.iterator();
                    for (0..index) |_| _ = chars_iter.nextCodepoint();
                    const start = chars_iter.i;
                    const replace = chars_iter.nextCodepointSlice() orelse return;
                    self.content.replaceRangeAssumeCapacity(start, replace.len, "");
                } else |_| if (index < self.value().len) {
                    _ = self.content.orderedRemove(index);
                },
                .select => |selection| if (unicode.Utf8View.init(self.value())) |chars| {
                    var chars_iter = chars.iterator();
                    for (0..selection.left()) |_| _ = chars_iter.nextCodepoint();
                    const start = chars_iter.i;
                    for (0..selection.len()) |_| _ = chars_iter.nextCodepoint();
                    self.content.replaceRangeAssumeCapacity(start, chars_iter.i - start, "");
                    self.cursor = .{ .at = selection.left() };
                } else |_| {
                    self.content.replaceRangeAssumeCapacity(selection.left(), selection.len(), "");
                    self.cursor = .{ .at = selection.left() };
                },
            }
        }

        fn removeCursorToNextSep(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| {
                    const sep_index = toNextSep(self.value(), index);
                    const byte_index, const byte_len = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                        var chars_iter = chars.iterator();
                        for (0..index) |_| _ = chars_iter.nextCodepoint();
                        const byte_index = chars_iter.i;
                        for (index..sep_index) |_| _ = chars_iter.nextCodepoint();
                        break :utf8 .{ byte_index, chars_iter.i - byte_index };
                    } else |_| .{ index, sep_index - index };
                    self.content.replaceRangeAssumeCapacity(byte_index, byte_len, "");
                },
                .select => self.removeCursor(),
            }
        }

        fn removeCursorToPrevSep(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| {
                    const sep_index = toPrevSep(self.value(), index);
                    const byte_index, const byte_len = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                        var chars_iter = chars.iterator();
                        for (0..sep_index) |_| _ = chars_iter.nextCodepoint();
                        const byte_index = chars_iter.i;
                        for (sep_index..index) |_| _ = chars_iter.nextCodepoint();
                        break :utf8 .{ byte_index, chars_iter.i - byte_index };
                    } else |_| .{ sep_index, index - sep_index };
                    self.content.replaceRangeAssumeCapacity(byte_index, byte_len, "");
                    self.cursor.at = sep_index;
                },
                .select => self.removeCursor(),
            }
        }

        fn copy(self: *Self, selection: Selection) Error!void {
            const left, const right = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                var chars_iter = chars.iterator();
                for (0..selection.left()) |_| _ = chars_iter.nextCodepoint();
                const left = chars_iter.i;
                for (0..selection.len()) |_| _ = chars_iter.nextCodepoint();
                break :utf8 .{ left, chars_iter.i };
            } else |_| .{ selection.left(), selection.right() };
            try self.content.insert(main.alloc, right, 0);
            defer _ = self.content.orderedRemove(right);
            rl.setClipboardText(@ptrCast(self.value()[left..right]));
        }

        fn paste(self: *Self, index: usize, len: usize) Error!void {
            const clipboard = rl.getClipboardText();
            if (clipboard.len > max_paste_len) {
                alert.updateFmt("Clipboard contents are too long ({} characters)", .{clipboard.len});
            } else if (clipboard.len > 0) {
                const byte_index, const byte_len = if (unicode.Utf8View.init(self.value())) |chars| utf8: {
                    var chars_iter = chars.iterator();
                    for (0..index) |_| _ = chars_iter.nextCodepoint();
                    break :utf8 .{ chars_iter.i, chars_iter.peek(len).len };
                } else |_| .{ index, len };
                try self.content.replaceRange(main.alloc, byte_index, byte_len, clipboard);
                for (self.content.items[byte_index..][0..clipboard.len]) |*char| {
                    if (ascii.isControl(char.*)) char.* = ' ';
                }
                self.cursor = .{ .at = index + (unicode.utf8CountCodepoints(clipboard) catch clipboard.len) };
            }
        }

        fn undo(self: *Self) Error!void {
            if (self.history.len > 1) {
                self.history.len -= 1;
                const prev = self.history.get(self.history.len - 1);
                self.content.clearRetainingCapacity();
                try self.content.appendSlice(main.alloc, prev.content.items);
                self.cursor = prev.cursor;
                if (self.cursor == .none) {
                    self.cursor = .{ .at = self.utf8Len() };
                }
            }
        }

        fn redo(self: *Self) Error!void {
            const next = self.history.addOne() catch return;
            self.content.clearRetainingCapacity();
            try self.content.appendSlice(main.alloc, next.content.items);
            self.cursor = next.cursor;
            if (self.cursor == .none) {
                self.cursor = .{ .at = self.utf8Len() };
            }
        }

        fn updateCompletions(self: *Self, direction: enum { forward, backward }) void {
            if (kind != .path) @compileError("updateCompletions only works on paths");

            switch (self.tab_complete.state) {
                .just_updated => {},

                .selecting => |current| self.tab_complete.state = .{
                    .just_updated = if (direction == .forward)
                        (current + 1) % self.tab_complete.completions.items.len
                    else if (current == 0) self.tab_complete.completions.items.len - 1 else current - 1,
                },

                .unloaded => {
                    self.tab_complete.completions.clearRetainingCapacity();
                    self.tab_complete.names.clearRetainingCapacity();

                    const last_sep = if (main.is_windows)
                        mem.lastIndexOfAny(u8, self.value(), &.{ fs.path.sep, fs.path.sep_posix }) orelse return
                    else
                        mem.lastIndexOfScalar(u8, self.value(), fs.path.sep) orelse return;
                    const prefix = self.value()[last_sep + 1 ..];
                    const relative_dir_path = self.value()[0..last_sep];
                    var dir_path = fs.realpathAlloc(main.alloc, relative_dir_path) catch return;
                    defer main.alloc.free(dir_path);
                    if (main.is_windows and ascii.eqlIgnoreCase(relative_dir_path, fs.path.diskDesignator(dir_path))) {
                        main.alloc.free(dir_path);
                        dir_path = mem.concat(main.alloc, u8, &.{ relative_dir_path, fs.path.sep_str }) catch return;
                    }

                    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
                    defer dir.close();
                    var entries = dir.iterate();
                    var suggest_enter_dir = false;
                    var i: usize = 0;
                    while (entries.next() catch return) |entry| : (i += 1) {
                        if (i == max_completions_search) break;
                        if (entry.kind == .directory and
                            (if (main.is_windows)
                                ascii.eqlIgnoreCase(entry.name, prefix)
                            else
                                mem.eql(u8, entry.name, prefix)))
                        {
                            suggest_enter_dir = true;
                        } else if (if (main.is_windows)
                            ascii.startsWithIgnoreCase(entry.name, prefix)
                        else
                            mem.startsWith(u8, entry.name, prefix))
                        {
                            const start = math.lossyCast(u32, self.tab_complete.names.items.len);
                            self.tab_complete.names.appendSlice(main.alloc, entry.name[prefix.len..]) catch return;
                            const end = math.lossyCast(u32, self.tab_complete.names.items.len);
                            self.tab_complete.completions.append(main.alloc, .{ start, end }) catch return;
                        }
                    }
                    if (suggest_enter_dir) {
                        const start = math.lossyCast(u32, self.tab_complete.names.items.len);
                        self.tab_complete.names.append(main.alloc, fs.path.sep) catch return;
                        self.tab_complete.completions.append(main.alloc, .{ start, start + 1 }) catch return;
                    }
                    if (self.tab_complete.completions.items.len == 0) return;

                    sort.pdq(
                        meta.Child(@TypeOf(self.tab_complete.completions.items)),
                        self.tab_complete.completions.items,
                        self.tab_complete.names.items,
                        struct {
                            fn f(names: []const u8, lhs: [2]u32, rhs: [2]u32) bool {
                                return if (main.is_windows)
                                    ascii.lessThanIgnoreCase(names[lhs[0]..lhs[1]], names[rhs[0]..rhs[1]])
                                else
                                    mem.lessThan(u8, names[lhs[0]..lhs[1]], names[rhs[0]..rhs[1]]);
                            }
                        }.f,
                    );

                    self.tab_complete.state = .{ .just_updated = 0 };
                    self.cursor = .{ .at = self.utf8Len() };
                },
            }
        }

        fn mouseAt(self: Self, mouse_pos: clay.Vector2) ?usize {
            const bounds = main.getBounds(id) orelse return null;
            if (bounds.x <= mouse_pos.x and mouse_pos.x <= bounds.x + bounds.width) {
                const chars: usize = @intFromFloat((mouse_pos.x - bounds.x - (char_px_width / 2)) / char_px_width);
                return @min(chars, self.utf8Len());
            }
            return null;
        }

        fn seps() []const u8 {
            return switch (kind) {
                .path => &(.{fs.path.sep_posix} ++ if (main.is_windows) .{fs.path.sep_windows} else .{}),
                .text => " ",
            };
        }

        fn toNextSep(string: []const u8, index: usize) usize {
            if (unicode.Utf8View.init(string)) |chars| {
                var chars_iter = chars.iterator();
                for (0..index) |_| _ = chars_iter.nextCodepoint();
                var i: usize = 0;
                find_sep: while (chars_iter.nextCodepoint()) |codepoint| : (i += 1) {
                    for (seps()) |sep| if (sep == codepoint) break :find_sep;
                }
                if (i == 0 and chars_iter.i < string.len) {
                    i = 1;
                    find_sep: while (chars_iter.nextCodepoint()) |codepoint| : (i += 1) {
                        for (seps()) |sep| if (sep == codepoint) break :find_sep;
                    }
                }
                return index + i;
            } else |_| if (mem.indexOfAnyPos(u8, string, index, seps())) |next_sep| {
                return if (index == next_sep)
                    mem.indexOfAnyPos(u8, string, index + 1, seps()) orelse string.len
                else
                    next_sep;
            } else {
                return string.len;
            }
        }

        fn toPrevSep(string: []const u8, index: usize) usize {
            if (unicode.Utf8View.init(string)) |chars| {
                var chars_iter = chars.iterator();
                var prev_index: usize = 0;
                var i: usize = 0;
                while (chars_iter.nextCodepoint()) |codepoint| : (i += 1) {
                    if (i == index) break;
                    for (seps()) |sep| if (sep == codepoint) {
                        prev_index = i;
                    };
                }
                return prev_index;
            } else |_| if (mem.lastIndexOfAny(u8, string[0..index], seps())) |prev_sep| {
                return if (index == prev_sep + 1)
                    mem.lastIndexOfAny(u8, string[0 .. index - 1], seps()) orelse 0
                else
                    prev_sep;
            } else {
                return 0;
            }
        }
    };
}
