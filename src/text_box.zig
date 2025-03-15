const std = @import("std");
const ascii = std.ascii;
const meta = std.meta;
const time = std.time;
const fmt = std.fmt;
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
        cursor: Cursor,
        timer: u32,
        history: std.BoundedArray(struct { content: std.ArrayListUnmanaged(u8), cursor: Cursor }, max_history),

        const max_history = 16;
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

        pub fn init(contents: []const u8) Model.Error!Self {
            var text_box = Self{
                .content = try meta.FieldType(Self, .content).initCapacity(main.alloc, 256),
                .cursor = .none,
                .timer = 0,
                .history = .{},
            };
            errdefer text_box.content.deinit(main.alloc);

            try text_box.content.appendSlice(main.alloc, contents);

            for (text_box.history.unusedCapacitySlice()) |*hist| {
                hist.* = .{ .content = try text_box.content.clone(main.alloc), .cursor = .none };
            }
            text_box.history.len = 1;

            return text_box;
        }

        pub fn deinit(self: *Self) void {
            self.content.deinit(main.alloc);
            for (self.history.slice()) |*hist| hist.content.deinit(main.alloc);
            for (self.history.unusedCapacitySlice()) |*hist| hist.content.deinit(main.alloc);
        }

        pub fn update(self: *Self, input: Input) Model.Error!?Message {
            var maybe_updated = self.cursor != .none and
                input.action != null and
                meta.activeTag(input.action.?) != .mouse;

            self.timer +|= input.delta_ms;
            self.history.slice()[self.history.len - 1].cursor = self.cursor;
            const maybe_message = try self.handleInput(input, &maybe_updated);
            if (self.value().len > max_len) {
                self.content.items.len = max_len;
                self.fixCursor();
            }

            if (maybe_updated) {
                self.timer = 0;
                try self.updateHistory();
            }

            if (maybe_message) |message| {
                switch (message) {
                    .submit => |path| {
                        const realpath = fs.realpathAlloc(main.alloc, path) catch |err| return switch (err) {
                            error.OutOfMemory => Model.Error.OutOfMemory,
                            else => Model.Error.OpenDirFailure,
                        };
                        defer main.alloc.free(realpath);
                        self.content.clearRetainingCapacity();
                        try self.content.appendSlice(main.alloc, realpath);
                        self.fixCursor();
                        try self.updateHistory();
                    },
                }
            }

            return maybe_message;
        }

        fn handleInput(self: *Self, input: Input, maybe_updated: *bool) Model.Error!?Message {
            switch (self.cursor) {
                .none => if (input.clicked(.left) and clay.pointerOver(id)) {
                    if (self.mouseAt(input.mouse_pos)) |at| {
                        self.cursor = .{ .select = .{ .from = at, .to = at } };
                    }
                },

                .at => |index| {
                    switch (input.action orelse return null) {
                        .mouse => if (input.clicked(.left)) {
                            if (clay.pointerOver(id)) {
                                if (self.mouseAt(input.mouse_pos)) |at| {
                                    self.cursor = .{
                                        .select = if (at == index and self.timer < main.double_click_delay)
                                            .{ .from = 0, .to = self.value().len }
                                        else
                                            .{ .from = if (input.shift) index else at, .to = at },
                                    };
                                    self.timer = 0;
                                }
                            } else {
                                self.cursor = .none;
                            }
                        },

                        .key => |key| switch (key) {
                            .char => |char| {
                                if (input.ctrl) {
                                    switch (char) {
                                        'v' => try self.paste(index, 0),
                                        'a' => self.cursor = .{ .select = .{ .from = 0, .to = self.value().len } },
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
                                .{ .select = .{ .from = index, .to = 0 } }
                            else
                                .{ .at = 0 },

                            .down, .end => self.cursor = if (input.shift)
                                .{ .select = .{ .from = index, .to = self.value().len } }
                            else
                                .{ .at = self.value().len },

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
                                const dest = if (input.ctrl)
                                    toNextSep(self.value(), index)
                                else
                                    index + @intFromBool(index < self.value().len);
                                self.cursor = if (input.shift)
                                    .{ .select = .{ .from = index, .to = dest } }
                                else
                                    .{ .at = dest };
                            },
                        },

                        .event => |event| if (main.is_windows) switch (event) {
                            .copy => {},
                            .paste => try self.paste(index, 0),
                            .undo => try self.undo(),
                            .redo => try self.redo(),
                        },
                    }
                },

                .select => |selection| switch (input.action orelse return null) {
                    .mouse => |mouse| if (mouse.button == .left) switch (mouse.state) {
                        .pressed => if (clay.pointerOver(id)) {
                            if (self.mouseAt(input.mouse_pos)) |at| {
                                if (input.shift) {
                                    self.cursor.select.to = at;
                                } else {
                                    self.cursor = .{ .select = .{ .from = at, .to = at } };
                                }
                            }
                        } else {
                            self.cursor = .none;
                        },
                        .down => if (self.mouseAt(input.mouse_pos)) |at| {
                            if (self.timer > select_all_delay) self.cursor.select.to = at;
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
                                    'a' => self.cursor = .{ .select = .{ .from = 0, .to = self.value().len } },
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
                                try self.content.replaceRange(
                                    main.alloc,
                                    selection.left(),
                                    selection.len(),
                                    &.{char},
                                );
                                self.cursor = .{ .at = selection.left() + 1 };
                            }
                        },

                        .delete, .backspace => self.removeCursor(),

                        .escape, .tab => self.cursor = .none,

                        .enter => return .{ .submit = self.value() },

                        .up, .home => self.cursor = if (input.shift)
                            .{ .select = .{ .from = selection.right(), .to = 0 } }
                        else
                            .{ .at = 0 },

                        .down, .end => self.cursor = if (input.shift)
                            .{ .select = .{ .from = selection.left(), .to = self.value().len } }
                        else
                            .{ .at = self.value().len },

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
                                selection.to + @intFromBool(selection.to < self.value().len);
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
                        .copy => try self.copy(selection),
                        .paste => try self.paste(selection.left(), selection.len()),
                        .undo => try self.undo(),
                        .redo => try self.redo(),
                    },
                },
            }

            return null;
        }

        pub fn render(self: Self) void {
            clay.ui()(.{
                .id = id,
                .layout = .{
                    .padding = clay.Padding.horizontal(8),
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
                    .none => main.textEx(.roboto_mono, .sm, self.content.items, main.theme.text),

                    .at => |index| {
                        main.textEx(
                            .roboto_mono,
                            .sm,
                            self.content.items[0..index],
                            main.theme.text,
                        );
                        if ((self.timer / ibeam_blink_interval) % 2 == 0) {
                            clay.ui()(.{
                                .floating = .{
                                    .offset = .{
                                        .x = @floatFromInt(index * char_px_width + ibeam_x_offset),
                                        .y = ibeam_y_offset,
                                    },
                                    .attachment = .{ .element = .left_center, .parent = .left_center },
                                    .pointer_capture_mode = .passthrough,
                                },
                            })({
                                main.textEx(
                                    .roboto_mono,
                                    .md,
                                    "|",
                                    main.theme.bright_text,
                                );
                            });
                        }
                        main.textEx(
                            .roboto_mono,
                            .sm,
                            self.content.items[index..],
                            main.theme.text,
                        );
                    },

                    .select => |selection| {
                        main.textEx(
                            .roboto_mono,
                            .sm,
                            self.content.items[0..selection.left()],
                            main.theme.text,
                        );
                        clay.ui()(.{
                            .rectangle = .{ .color = main.theme.highlight },
                        })({
                            main.textEx(
                                .roboto_mono,
                                .sm,
                                self.content.items[selection.left()..selection.right()],
                                main.theme.base,
                            );
                        });
                        main.textEx(
                            .roboto_mono,
                            .sm,
                            self.content.items[selection.right()..],
                            main.theme.text,
                        );
                    },
                }
            });
        }

        pub fn value(self: Self) []const u8 {
            return self.content.items;
        }

        pub fn isActive(self: Self) bool {
            return self.cursor != .none;
        }

        pub fn set(self: *Self, new_value: []const u8) Model.Error!void {
            self.content.clearRetainingCapacity();
            try self.content.appendSlice(main.alloc, new_value);
            self.cursor = .none;
            try self.updateHistory();
        }

        pub fn popPath(self: *Self) Model.Error!void {
            if (kind != .path) @compileError("popPath only works on paths");
            const parent_dir_path = fs.path.dirname(self.value()) orelse return;
            self.content.shrinkRetainingCapacity(parent_dir_path.len);
            self.fixCursor();
            try self.updateHistory();
        }

        pub fn appendPath(self: *Self, entry_name: []const u8) Model.Error!void {
            if (kind != .path) @compileError("appendPath only works on paths");
            try self.content.append(main.alloc, fs.path.sep);
            try self.content.appendSlice(main.alloc, entry_name);
            if (self.value().len > max_len) {
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

        fn updateHistory(self: *Self) Model.Error!void {
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
                .at => |*index| index.* = @min(index.*, self.value().len),
                .select => |*selection| {
                    selection.from = @min(selection.from, self.value().len);
                    selection.to = @min(selection.to, self.value().len);
                    if (selection.from == selection.to) self.cursor = .{ .at = selection.from };
                },
            }
        }

        fn removeCursor(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| _ = self.content.orderedRemove(index),
                .select => |selection| {
                    self.content.replaceRangeAssumeCapacity(selection.left(), selection.len(), "");
                    self.cursor = .{ .at = selection.left() };
                },
            }
        }

        fn removeCursorToNextSep(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| self.content.replaceRangeAssumeCapacity(
                    index,
                    toNextSep(self.value(), index) - index,
                    "",
                ),
                .select => self.removeCursor(),
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
                .select => self.removeCursor(),
            }
        }

        fn copy(self: *Self, selection: Selection) Model.Error!void {
            try self.content.insert(main.alloc, selection.right(), 0);
            defer _ = self.content.orderedRemove(selection.right());
            rl.setClipboardText(@ptrCast(self.value().ptr + selection.left()));
        }

        fn paste(self: *Self, index: usize, len: usize) Model.Error!void {
            const clipboard = mem.span(rl.getClipboardText());
            if (clipboard.len > max_paste_len) {
                alert.updateFmt("Clipboard contents are too long ({} characters)", .{clipboard.len});
            } else if (clipboard.len > 0) {
                try self.content.replaceRange(main.alloc, index, len, clipboard);
                for (self.content.items[index..][0..clipboard.len]) |*char| {
                    if (ascii.isControl(char.*)) char.* = ' ';
                }
                self.cursor = .{ .at = index + clipboard.len };
            }
        }

        fn undo(self: *Self) Model.Error!void {
            if (self.history.len > 1) {
                self.history.len -= 1;
                const prev = self.history.get(self.history.len - 1);
                self.content.clearRetainingCapacity();
                try self.content.appendSlice(main.alloc, prev.content.items);
                self.cursor = prev.cursor;
                if (self.cursor == .none) {
                    self.cursor = .{ .at = self.value().len };
                }
            }
        }

        fn redo(self: *Self) Model.Error!void {
            const next = self.history.addOne() catch return;
            self.content.clearRetainingCapacity();
            try self.content.appendSlice(main.alloc, next.content.items);
            self.cursor = next.cursor;
            if (self.cursor == .none) {
                self.cursor = .{ .at = self.value().len };
            }
        }

        fn mouseAt(self: Self, mouse_pos: clay.Vector2) ?usize {
            const bounds = main.getBounds(id) orelse return null;
            if (bounds.x <= mouse_pos.x and mouse_pos.x <= bounds.x + bounds.width) {
                const chars: usize = @intFromFloat((mouse_pos.x - bounds.x - (char_px_width / 2)) / char_px_width);
                return @min(chars, self.value().len);
            }
            return null;
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
    };
}
