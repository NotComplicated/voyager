const std = @import("std");
const ascii = std.ascii;
const meta = std.meta;
const time = std.time;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const alert = @import("alert.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");

pub fn TextBox(kind: enum(u8) { path = fs.path.sep, text = ' ' }, id: clay.Element.Config.Id) type {
    return struct {
        content: std.ArrayListUnmanaged(u8),
        cursor: union(enum) {
            none,
            at: usize,
            selected: struct { at: usize, len: usize },
            selecting: struct { from: usize, to: usize },
        },
        // TODO millis timer for double-click select word
        // TODO select all when going from none -> selected w/o selecting any

        const max_paste_len = 1024;
        const char_px_width = 9;

        const Self = @This();

        const Message = union(enum) {
            submit: []const u8,
        };

        pub fn init() Model.Error!Self {
            var text_box = Self{
                .content = try meta.FieldType(Self, .content).initCapacity(main.alloc, 256),
                .cursor = .none,
            };
            errdefer text_box.content.deinit(main.alloc);

            if (kind == .path) {
                const path = fs.realpathAlloc(main.alloc, ".") catch return Model.Error.OutOfMemory;
                defer main.alloc.free(path);
                try text_box.content.appendSlice(main.alloc, path);
            }

            return text_box;
        }

        pub fn deinit(self: *Self) void {
            self.content.deinit(main.alloc);
        }

        pub fn update(self: *Self, input: Input) Model.Error!?Message {
            switch (self.cursor) {
                .none => if (input.clicked(.left) and clay.pointerOver(id)) {
                    if (mouseAt(input.mouse_pos)) |mouse_at| {
                        const at = @min(mouse_at, self.value().len);
                        self.cursor = .{ .selecting = .{ .from = at, .to = at } };
                    }
                },

                .at => |index| switch (input.action orelse return null) {
                    .mouse => if (input.clicked(.left)) {
                        if (clay.pointerOver(id)) {
                            if (mouseAt(input.mouse_pos)) |mouse_at| {
                                const at = @min(mouse_at, self.value().len);
                                self.cursor = .{ .selecting = .{
                                    .from = if (input.shift) index else at,
                                    .to = at,
                                } };
                            }
                        } else {
                            self.cursor = .none;
                        }
                    },

                    .key => |key| switch (key) {
                        .char => |char| {
                            if (input.ctrl) {
                                switch (char) {
                                    'v' => {
                                        const clipboard = mem.span(rl.getClipboardText());
                                        if (clipboard.len > max_paste_len) {
                                            alert.updateFmt("Clipboard contents are too long ({} characters)", .{clipboard.len});
                                            return null;
                                        }
                                        try self.content.insertSlice(main.alloc, index, clipboard);
                                        self.cursor.at += clipboard.len;
                                    },
                                    'a' => self.cursor = .{ .selected = .{ .at = 0, .len = self.value().len } },
                                    else => {},
                                }
                            } else {
                                try self.content.insert(main.alloc, index, char);
                                self.cursor.at += 1;
                            }
                        },

                        .delete => if (index < self.value().len)
                            if (input.ctrl) self.removeCursorToNextSep() else self.removeCursor(),

                        .backspace => if (input.ctrl)
                            self.removeCursorToPrevSep()
                        else if (index > 0) {
                            self.cursor.at -= 1;
                            self.removeCursor();
                        },

                        .escape, .tab => self.cursor = .none,

                        .enter => return .{ .submit = self.value() },

                        .up, .home => self.cursor = if (input.shift)
                            .{ .selected = .{ .at = 0, .len = index } }
                        else
                            .{ .at = 0 },

                        .down, .end => self.cursor = if (input.shift)
                            .{ .selected = .{ .at = index, .len = self.value().len - index } }
                        else
                            .{ .at = self.value().len },

                        .left => {
                            const dest = if (input.ctrl)
                                toPrevSep(self.value(), index)
                            else if (index > 0) index - 1 else index;
                            self.cursor = if (input.shift)
                                .{ .selected = .{ .at = dest, .len = index - dest } }
                            else
                                .{ .at = dest };
                        },

                        .right => {
                            const dest = if (input.ctrl)
                                toNextSep(self.value(), index)
                            else if (index < self.value().len) index + 1 else index;
                            self.cursor = if (input.shift)
                                .{ .selected = .{ .at = index, .len = dest - index } }
                            else
                                .{ .at = dest };
                        },
                    },
                },

                .selected => |selection| switch (input.action orelse return null) {
                    .mouse => if (input.clicked(.left)) {
                        if (clay.pointerOver(id)) {
                            if (mouseAt(input.mouse_pos)) |mouse_at| {
                                const at = @min(mouse_at, self.value().len);
                                self.cursor = .{ .selecting = .{
                                    .from = if (input.shift)
                                        if (at <= selection.at) selection.at + selection.len else selection.at
                                    else
                                        at,
                                    .to = at,
                                } };
                            }
                        } else {
                            self.cursor = .none;
                        }
                    },

                    .key => |key| switch (key) {
                        .char => |char| {
                            if (input.ctrl) {
                                switch (char) {
                                    'c' => {
                                        try self.content.insert(main.alloc, selection.at + selection.len, 0);
                                        defer _ = self.content.orderedRemove(selection.at + selection.len);
                                        rl.setClipboardText(@ptrCast(self.content.items.ptr + selection.at));
                                    },
                                    'v' => {
                                        const clipboard = mem.span(rl.getClipboardText());
                                        if (clipboard.len > max_paste_len) {
                                            alert.updateFmt("Clipboard contents are too long ({} characters)", .{clipboard.len});
                                            return null;
                                        }
                                        try self.content.replaceRange(main.alloc, selection.at, selection.len, clipboard);
                                        self.cursor = .{ .at = selection.at + clipboard.len };
                                    },
                                    'a' => self.cursor = .{ .selected = .{ .at = 0, .len = self.value().len } },
                                    else => {},
                                }
                            } else {
                                try self.content.replaceRange(main.alloc, selection.at, selection.len, &.{char});
                                self.cursor = .{ .at = selection.at + 1 };
                            }
                        },

                        .delete, .backspace => self.removeCursor(),

                        .escape, .tab => self.cursor = .none,

                        .enter => return .{ .submit = self.value() },

                        .up, .home => self.cursor = if (input.shift)
                            .{ .selected = .{ .at = 0, .len = selection.at + selection.len } }
                        else
                            .{ .at = 0 },

                        .down, .end => self.cursor = if (input.shift)
                            .{ .selected = .{ .at = selection.at, .len = self.value().len - selection.at } }
                        else
                            .{ .at = self.value().len },

                        .left => self.cursor = if (input.shift)
                            .{ .selected = .{ .at = selection.at, .len = selection.len -| 1 } }
                        else
                            .{ .at = selection.at },

                        .right => self.cursor = if (input.shift)
                            .{ .selected = .{
                                .at = selection.at,
                                .len = if (selection.at + selection.len < self.value().len) selection.len + 1 else selection.len,
                            } }
                        else
                            .{ .at = selection.at + selection.len },
                    },
                },

                .selecting => switch (input.action orelse return null) {
                    .mouse => |mouse| if (mouse.button == .left) switch (mouse.state) {
                        .down => if (mouseAt(input.mouse_pos)) |mouse_at| {
                            self.cursor.selecting.to = @min(mouse_at, self.value().len);
                        },
                        .released => if (mouseAt(input.mouse_pos)) |mouse_at| {
                            self.cursor.selecting.to = @min(mouse_at, self.value().len);
                            self.select();
                        },
                        else => {},
                    },
                    else => {},
                },
            }

            return null;
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
                .scroll = .{ .horizontal = true },
                .rectangle = .{
                    .color = if (self.cursor == .none) main.theme.nav else main.theme.selected,
                    .corner_radius = main.rounded,
                },
            })({
                main.ibeam();

                switch (self.cursor) {
                    .none => {
                        // TODO special rendering for paths?
                        main.textEx(.roboto_mono, .sm, self.content.items, main.theme.text);
                    },

                    .at => |index| {
                        main.textEx(.roboto_mono, .sm, self.content.items[0..index], main.theme.text);
                        clay.ui()(.{
                            .floating = .{
                                .offset = .{ .x = @floatFromInt(index * 9), .y = -2 },
                                .attachment = .{ .element = .left_center, .parent = .left_center },
                                .pointer_capture_mode = .passthrough,
                            },
                        })({
                            main.textEx(.roboto_mono, .md, "|", main.theme.bright_text);
                        });
                        main.textEx(.roboto_mono, .sm, self.content.items[index..], main.theme.text);
                    },

                    .selected => |selection| {
                        main.textEx(.roboto_mono, .sm, self.content.items[0..selection.at], main.theme.text);
                        clay.ui()(.{ .rectangle = .{ .color = main.theme.sapphire } })({
                            main.textEx(.roboto_mono, .sm, self.content.items[selection.at..][0..selection.len], main.theme.text);
                        });
                        main.textEx(.roboto_mono, .sm, self.content.items[selection.at + selection.len ..], main.theme.text);
                    },

                    .selecting => |from_to| {
                        const left = @min(from_to.from, from_to.to);
                        const right = @max(from_to.from, from_to.to);
                        main.textEx(.roboto_mono, .sm, self.content.items[0..left], main.theme.text);
                        clay.ui()(.{ .rectangle = .{ .color = main.theme.sapphire } })({
                            main.textEx(.roboto_mono, .sm, self.content.items[left..right], main.theme.text);
                        });
                        main.textEx(.roboto_mono, .sm, self.content.items[right..], main.theme.text);
                    },
                }
            });
        }

        pub fn value(self: Self) []const u8 {
            return self.content.items;
        }

        pub fn popPath(self: *Self) void {
            if (kind != .path) @compileError("popPath only works on paths");
            const parent_dir_path = fs.path.dirname(self.value()) orelse return;
            self.content.shrinkRetainingCapacity(parent_dir_path.len);
        }

        pub fn appendPath(self: *Self, entry_name: []const u8) Model.Error!void {
            if (kind != .path) @compileError("appendPath only works on paths");
            try self.content.append(main.alloc, fs.path.sep);
            return self.content.appendSlice(main.alloc, entry_name);
        }

        fn select(self: *Self) void {
            switch (self.cursor) {
                .selecting => |from_to| {
                    const at = @min(from_to.from, from_to.to);
                    const len = @max(from_to.from, from_to.to) - at;
                    self.cursor = if (len == 0) .{ .at = at } else .{ .selected = .{ .at = at, .len = len } };
                },
                else => {},
            }
        }

        fn removeCursor(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| _ = self.content.orderedRemove(index),
                .selected => |selection| {
                    self.content.replaceRangeAssumeCapacity(selection.at, selection.len, "");
                    self.cursor = .{ .at = selection.at };
                },
                .selecting => {
                    self.select();
                    self.removeCursor();
                },
            }
        }

        fn removeCursorToNextSep(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| self.content.replaceRangeAssumeCapacity(index, toNextSep(self.value(), index) - index, ""),
                .selected, .selecting => self.removeCursor(),
            }
        }

        fn removeCursorToPrevSep(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| {
                    const prev = toPrevSep(self.value(), index);
                    self.content.replaceRangeAssumeCapacity(prev, index - prev, "");
                    self.cursor.at = prev;
                },
                .selected, .selecting => self.removeCursor(),
            }
        }

        fn toNextSep(string: []const u8, index: usize) usize {
            if (mem.indexOfScalarPos(u8, string, index, @intFromEnum(kind))) |next_sep| {
                return if (index == next_sep)
                    mem.indexOfScalarPos(u8, string, index + 1, @intFromEnum(kind)) orelse string.len
                else
                    next_sep;
            } else {
                return string.len;
            }
        }

        fn toPrevSep(string: []const u8, index: usize) usize {
            if (mem.lastIndexOfScalar(u8, string[0..index], @intFromEnum(kind))) |prev_sep| {
                return if (index == prev_sep + 1)
                    mem.lastIndexOfScalar(u8, string[0 .. index - 1], @intFromEnum(kind)) orelse 0
                else
                    prev_sep;
            } else {
                return 0;
            }
        }

        fn mouseAt(mouse_pos: clay.Vector2) ?usize {
            const bounds = main.getBounds(id) orelse return null;
            if (bounds.x <= mouse_pos.x and mouse_pos.x <= bounds.x + bounds.width) {
                if (bounds.y <= mouse_pos.y and mouse_pos.y <= bounds.y + bounds.height) {
                    return @intFromFloat((mouse_pos.x - bounds.x) / char_px_width);
                }
            }
            return null;
        }
    };
}
