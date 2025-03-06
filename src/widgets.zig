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
        cursor: Cursor,
        history: std.BoundedArray(struct { content: std.ArrayListUnmanaged(u8), cursor: Cursor }, max_history),

        // TODO millis timer for double-click select word
        // TODO select all when going from none -> selected w/o selecting any

        const max_history = 8;
        const max_paste_len = 1024;
        const char_px_width = 9;
        const ibeam_x_offset = 2;
        const ibeam_y_offset = -2;
        const ibeam_blink_interval = 600;

        const Self = @This();

        const Cursor = union(enum) {
            none,
            at: struct { index: usize, timer: u32 = 0 },
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

        pub fn init() Model.Error!Self {
            var text_box = Self{
                .content = try meta.FieldType(Self, .content).initCapacity(main.alloc, 256),
                .cursor = .none,
                .history = .{},
            };
            errdefer text_box.content.deinit(main.alloc);

            if (kind == .path) {
                const path = fs.realpathAlloc(main.alloc, ".") catch return Model.Error.OutOfMemory;
                defer main.alloc.free(path);
                try text_box.content.appendSlice(main.alloc, path);
            }

            for (text_box.history.unusedCapacitySlice()) |*hist| {
                hist.* = .{ .content = try text_box.content.clone(main.alloc), .cursor = .none };
            }
            text_box.history.resize(1) catch {};

            return text_box;
        }

        pub fn deinit(self: *Self) void {
            self.content.deinit(main.alloc);
            for (self.history.slice()) |*hist| hist.content.deinit(main.alloc);
            for (self.history.unusedCapacitySlice()) |*hist| hist.content.deinit(main.alloc);
        }

        pub fn update(self: *Self, input: Input) Model.Error!?Message {
            var contents_updated = self.cursor != .none and input.action != null and meta.activeTag(input.action.?) == .key;
            const maybe_message = try self.handleInput(input, &contents_updated);

            if (contents_updated) {
                switch (self.cursor) {
                    .at => |*cursor| cursor.timer = 0,
                    else => {},
                }
                const prev_hist = &self.history.slice()[self.history.len - 1];
                if (!mem.eql(u8, self.value(), prev_hist.content.items)) {
                    const next_hist = self.history.addOne() catch rotate: {
                        mem.rotate(meta.Elem(@TypeOf(self.history.slice())), self.history.slice(), 1);
                        break :rotate &self.history.slice()[self.history.len - 1];
                    };
                    next_hist.content.clearRetainingCapacity();
                    try next_hist.content.appendSlice(main.alloc, self.value());
                    next_hist.cursor = self.cursor;
                }
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
                    },
                }
            }

            return maybe_message;
        }

        fn handleInput(self: *Self, input: Input, contents_updated: *bool) Model.Error!?Message {
            switch (self.cursor) {
                .none => if (input.clicked(.left) and clay.pointerOver(id)) {
                    if (self.mouseAt(input.mouse_pos)) |at| {
                        self.cursor = .{ .select = .{ .from = at, .to = at } };
                    }
                },

                .at => |*cursor| {
                    cursor.timer += input.delta_ms;

                    switch (input.action orelse return null) {
                        .mouse => if (input.clicked(.left)) {
                            if (clay.pointerOver(id)) {
                                if (self.mouseAt(input.mouse_pos)) |at| {
                                    self.cursor = .{
                                        .select = if (at == cursor.index and cursor.timer < main.double_click_delay)
                                            .{ .from = 0, .to = self.value().len }
                                        else
                                            .{ .from = if (input.shift) cursor.index else at, .to = at },
                                    };
                                }
                            } else {
                                self.cursor = .none;
                            }
                        },

                        .key => |key| switch (key) {
                            .char => |char| {
                                if (input.ctrl) {
                                    switch (char) {
                                        'v' => if (getClipboard()) |clipboard| {
                                            try self.content.insertSlice(main.alloc, cursor.index, clipboard);
                                            self.cursor.at.index += clipboard.len;
                                        },
                                        'a' => self.cursor = .{ .select = .{ .from = 0, .to = self.value().len } },
                                        'z' => {
                                            contents_updated.* = false;
                                        },
                                        'y' => {
                                            contents_updated.* = false;
                                        },
                                        else => {},
                                    }
                                } else {
                                    try self.content.insert(main.alloc, cursor.index, char);
                                    cursor.index += 1;
                                }
                            },

                            .delete => if (cursor.index < self.value().len)
                                if (input.ctrl) self.removeCursorToNextSep() else self.removeCursor(),

                            .backspace => if (input.ctrl)
                                self.removeCursorToPrevSep()
                            else if (cursor.index > 0) {
                                cursor.index -= 1;
                                self.removeCursor();
                            },

                            .escape, .tab => self.cursor = .none,

                            .enter => return .{ .submit = self.value() },

                            .up, .home => self.cursor = if (input.shift)
                                .{ .select = .{ .from = cursor.index, .to = 0 } }
                            else
                                .{ .at = .{ .index = 0 } },

                            .down, .end => self.cursor = if (input.shift)
                                .{ .select = .{ .from = cursor.index, .to = self.value().len } }
                            else
                                .{ .at = .{ .index = self.value().len } },

                            .left => {
                                const dest = if (input.ctrl)
                                    toPrevSep(self.value(), cursor.index)
                                else
                                    cursor.index -| 1;
                                self.cursor = if (input.shift)
                                    .{ .select = .{ .from = cursor.index, .to = dest } }
                                else
                                    .{ .at = .{ .index = dest } };
                            },

                            .right => {
                                const dest = if (input.ctrl)
                                    toNextSep(self.value(), cursor.index)
                                else
                                    cursor.index + @intFromBool(cursor.index < self.value().len);
                                self.cursor = if (input.shift)
                                    .{ .select = .{ .from = cursor.index, .to = dest } }
                                else
                                    .{ .at = .{ .index = dest } };
                            },
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
                        },
                        .down => if (self.mouseAt(input.mouse_pos)) |at| {
                            self.cursor.select.to = at; // TODO check if double-clicked
                        },
                        .released => if (selection.from == selection.to) {
                            self.cursor = .{ .at = .{ .index = selection.from } };
                        },
                    },

                    .key => |key| switch (key) {
                        .char => |char| {
                            if (input.ctrl) {
                                switch (char) {
                                    'c' => try self.setClipboard(selection),
                                    'x' => {
                                        try self.setClipboard(selection);
                                        self.removeCursor();
                                    },
                                    'v' => if (getClipboard()) |clipboard| {
                                        try self.content.replaceRange(
                                            main.alloc,
                                            selection.left(),
                                            selection.len(),
                                            clipboard,
                                        );
                                        self.cursor = .{ .at = .{ .index = selection.right() } };
                                    },
                                    'a' => self.cursor = .{ .select = .{ .from = 0, .to = self.value().len } },
                                    'z' => {
                                        contents_updated.* = false;
                                    },
                                    'y' => {
                                        contents_updated.* = false;
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
                                self.cursor = .{ .at = .{ .index = selection.left() + 1 } };
                            }
                        },

                        .delete, .backspace => self.removeCursor(),

                        .escape, .tab => self.cursor = .none,

                        .enter => return .{ .submit = self.value() },

                        .up, .home => self.cursor = if (input.shift)
                            .{ .select = .{ .from = selection.right(), .to = 0 } }
                        else
                            .{ .at = .{ .index = 0 } },

                        .down, .end => self.cursor = if (input.shift)
                            .{ .select = .{ .from = selection.left(), .to = self.value().len } }
                        else
                            .{ .at = .{ .index = self.value().len } },

                        .left => if (input.shift) {
                            const dest = if (input.ctrl)
                                toPrevSep(self.value(), selection.to)
                            else
                                selection.to -| 1;
                            if (dest == selection.from) {
                                self.cursor = .{ .at = .{ .index = dest } };
                            } else {
                                self.cursor.select.to = dest;
                            }
                        } else {
                            self.cursor = .{ .at = .{ .index = selection.left() } };
                        },

                        .right => if (input.shift) {
                            const dest = if (input.ctrl)
                                toNextSep(self.value(), selection.to)
                            else
                                selection.to + @intFromBool(selection.to < self.value().len);
                            if (dest == selection.from) {
                                self.cursor = .{ .at = .{ .index = dest } };
                            } else {
                                self.cursor.select.to = dest;
                            }
                        } else {
                            self.cursor = .{ .at = .{ .index = selection.right() } };
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
                    .none => {
                        // TODO special rendering for paths?
                        main.textEx(
                            .roboto_mono,
                            .sm,
                            self.content.items,
                            main.theme.text,
                        );
                    },

                    .at => |cursor| {
                        main.textEx(
                            .roboto_mono,
                            .sm,
                            self.content.items[0..cursor.index],
                            main.theme.text,
                        );
                        if ((cursor.timer / ibeam_blink_interval) % 2 == 0) {
                            clay.ui()(.{
                                .floating = .{
                                    .offset = .{
                                        .x = @floatFromInt(cursor.index * char_px_width + ibeam_x_offset),
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
                            self.content.items[cursor.index..],
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

        fn removeCursor(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |cursor| _ = self.content.orderedRemove(cursor.index),
                .select => |selection| {
                    self.content.replaceRangeAssumeCapacity(selection.left(), selection.len(), "");
                    self.cursor = .{ .at = .{ .index = selection.left() } };
                },
            }
        }

        fn removeCursorToNextSep(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |cursor| self.content.replaceRangeAssumeCapacity(
                    cursor.index,
                    toNextSep(self.value(), cursor.index) - cursor.index,
                    "",
                ),
                .select => self.removeCursor(),
            }
        }

        fn removeCursorToPrevSep(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |cursor| {
                    const prev = toPrevSep(self.value(), cursor.index);
                    self.content.replaceRangeAssumeCapacity(prev, cursor.index - prev, "");
                    self.cursor.at.index = prev;
                },
                .select => self.removeCursor(),
            }
        }

        fn setClipboard(self: *Self, selection: Selection) Model.Error!void {
            try self.content.insert(main.alloc, selection.right(), 0);
            defer _ = self.content.orderedRemove(selection.right());
            rl.setClipboardText(@ptrCast(self.value().ptr + selection.left()));
        }

        fn mouseAt(self: Self, mouse_pos: clay.Vector2) ?usize {
            const bounds = main.getBounds(id) orelse return null;
            if (bounds.x <= mouse_pos.x and mouse_pos.x <= bounds.x + bounds.width) {
                const chars: usize = @intFromFloat((mouse_pos.x - bounds.x) / char_px_width);
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

        fn getClipboard() ?[]const u8 {
            const clipboard = mem.span(rl.getClipboardText());
            if (clipboard.len > max_paste_len) {
                alert.updateFmt("Clipboard contents are too long ({} characters)", .{clipboard.len});
                return null;
            }
            return if (clipboard.len == 0) null else clipboard;
        }
    };
}
