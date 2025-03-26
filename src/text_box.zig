const std = @import("std");
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
const alert = @import("alert.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");

pub fn TextBox(kind: enum(u8) { path, text }, id: clay.Id) type {
    return struct {
        content: main.ArrayList(u8),
        cursor: Cursor,
        timer: u32,
        history: std.BoundedArray(struct { content: main.ArrayList(u8), cursor: Cursor }, max_history),
        tab_complete: if (kind == .path) struct {
            completions: main.ArrayList([2]u32),
            names: main.ArrayList(u8),
            state: union(enum) { unloaded, selecting: usize, just_updated: usize },
        } else void,

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

        pub fn init(contents: []const u8, state: enum { unfocused, selected }) Model.Error!Self {
            var text_box = Self{
                .content = try .initCapacity(main.alloc, 256),
                .cursor = switch (state) {
                    .unfocused => .none,
                    .selected => .{ .select = .{ .from = 0, .to = contents.len } },
                },
                .timer = 0,
                .history = .{},
                .tab_complete = if (kind == .path) .{
                    .completions = try .initCapacity(main.alloc, 256),
                    .names = try .initCapacity(main.alloc, 256 * 8),
                    .state = .unloaded,
                } else {},
            };
            errdefer {
                text_box.content.deinit(main.alloc);
                if (kind == .path) {
                    text_box.tab_complete.completions.deinit(main.alloc);
                    text_box.tab_complete.names.deinit(main.alloc);
                }
            }

            try text_box.content.appendSlice(main.alloc, contents);

            for (text_box.history.unusedCapacitySlice()) |*hist| {
                hist.* = .{ .content = try text_box.content.clone(main.alloc), .cursor = text_box.cursor };
            }
            text_box.history.len = 1;

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
                if (kind == .path) self.tab_complete.state = switch (self.tab_complete.state) {
                    .unloaded, .selecting => .unloaded,
                    .just_updated => |current| .{ .selecting = current },
                };
            }

            if (maybe_message) |message| {
                switch (message) {
                    .submit => |contents| if (kind == .path) {
                        const realpath = fs.realpathAlloc(main.alloc, contents) catch |err| return switch (err) {
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

                .at => |index| switch (input.action orelse return null) {
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

                        .f => |_| {},

                        .delete => if (index < self.value().len)
                            if (input.ctrl) self.removeCursorToNextSep() else self.removeCursor(),

                        .backspace => if (input.ctrl)
                            self.removeCursorToPrevSep()
                        else if (index > 0) {
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
                                    self.cursor = .{ .at = self.value().len };
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
                                    self.cursor = .{ .at = self.value().len };
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
                            if (kind == .path) switch (self.tab_complete.state) {
                                .unloaded, .just_updated => {},
                                .selecting => |current| {
                                    const start, const end = self.tab_complete.completions.items[current];
                                    try self.content.appendSlice(main.alloc, self.tab_complete.names.items[start..end]);
                                    self.cursor = .{ .at = self.value().len };
                                    return null;
                                },
                            };
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
                    .padding = .horizontal(8),
                    .sizing = .{
                        .width = .grow(.{}),
                        .height = .fixed(Model.row_height),
                    },
                    .child_alignment = .{ .y = .center },
                },
                .bg_color = if (self.cursor == .none) themes.current.nav else themes.current.selected,
                .corner_radius = main.rounded,
                .scroll = .{ .horizontal = true },
            })({
                main.ibeam();

                switch (self.cursor) {
                    .none => main.textEx(.roboto_mono, .md, self.content.items, themes.current.text),

                    .at => |index| {
                        main.textEx(
                            .roboto_mono,
                            .md,
                            self.content.items[0..index],
                            themes.current.text,
                        );
                        if ((self.timer / ibeam_blink_interval) % 2 == 0) {
                            clay.ui()(.{
                                .floating = .{
                                    .offset = .{
                                        .x = @floatFromInt(index * char_px_width + ibeam_x_offset),
                                        .y = ibeam_y_offset,
                                    },
                                    .attach_points = .{ .element = .left_center, .parent = .left_center },
                                    .pointer_capture_mode = .passthrough,
                                    .attach_to = .parent,
                                },
                            })({
                                main.textEx(
                                    .roboto_mono,
                                    .lg,
                                    "|",
                                    themes.current.bright_text,
                                );
                            });
                        }
                        main.textEx(
                            .roboto_mono,
                            .md,
                            self.content.items[index..],
                            themes.current.text,
                        );
                    },

                    .select => |selection| {
                        main.textEx(
                            .roboto_mono,
                            .md,
                            self.content.items[0..selection.left()],
                            themes.current.text,
                        );
                        clay.ui()(.{
                            .bg_color = themes.current.highlight,
                        })({
                            main.textEx(
                                .roboto_mono,
                                .md,
                                self.content.items[selection.left()..selection.right()],
                                themes.current.base,
                            );
                        });
                        main.textEx(
                            .roboto_mono,
                            .md,
                            self.content.items[selection.right()..],
                            themes.current.text,
                        );
                    },
                }

                if (kind == .path) switch (self.tab_complete.state) {
                    .unloaded => {},
                    .selecting, .just_updated => |current| {
                        const start, const end = self.tab_complete.completions.items[current];
                        main.textEx(
                            .roboto_mono,
                            .md,
                            self.tab_complete.names.items[start..end],
                            themes.current.dim_text,
                        );
                    },
                };
            });
        }

        pub fn value(self: Self) []const u8 {
            return self.content.items;
        }

        pub fn toOwned(self: *Self) Model.Error![]const u8 {
            return self.content.toOwnedSlice(main.alloc) catch Model.Error.OutOfMemory;
        }

        pub fn isActive(self: Self) bool {
            return self.cursor != .none;
        }

        pub fn focus(self: *Self) void {
            self.cursor = .{ .at = self.value().len };
            self.timer = 0;
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
            rl.setClipboardText(@ptrCast(self.value()[selection.left()..]));
        }

        fn paste(self: *Self, index: usize, len: usize) Model.Error!void {
            const clipboard = rl.getClipboardText();
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
                    const dir_path = fs.realpathAlloc(main.alloc, self.value()[0..last_sep]) catch return;
                    defer main.alloc.free(dir_path);

                    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
                    defer dir.close();
                    var entries = dir.iterate();
                    var suggest_enter_dir = false;
                    var i: usize = 0;
                    while (entries.next() catch return) |entry| : (i += 1) {
                        if (i == max_completions_search) break;
                        if (entry.kind == .directory and ascii.eqlIgnoreCase(entry.name, prefix)) {
                            suggest_enter_dir = true;
                        } else if (ascii.startsWithIgnoreCase(entry.name, prefix)) {
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
                                return ascii.lessThanIgnoreCase(names[lhs[0]..lhs[1]], names[rhs[0]..rhs[1]]);
                            }
                        }.f,
                    );

                    self.tab_complete.state = .{ .just_updated = 0 };
                    self.cursor = .{ .at = self.value().len };
                },
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

        fn seps() []const u8 {
            return switch (kind) {
                .path => if (main.is_windows) &.{ fs.path.sep_posix, fs.path.sep },
                .text => " ",
            };
        }

        fn toNextSep(string: []const u8, index: usize) usize {
            if (mem.indexOfAnyPos(u8, string, index, seps())) |next_sep| {
                return if (index == next_sep)
                    mem.indexOfAnyPos(u8, string, index + 1, seps()) orelse string.len
                else
                    next_sep;
            } else {
                return string.len;
            }
        }

        fn toPrevSep(string: []const u8, index: usize) usize {
            if (mem.lastIndexOfAny(u8, string[0..index], seps())) |prev_sep| {
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
