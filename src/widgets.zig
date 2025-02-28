const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const Bytes = main.Bytes;
const alert = @import("alert.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");

pub fn TextBox(kind: enum(u8) { path = fs.path.sep, text = ' ' }, id: clay.Element.Config.Id) type {
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
            var text_box = Self{
                .data = try Bytes.initCapacity(main.alloc, 1024),
                .cursor = .none,
            };
            errdefer text_box.data.deinit(main.alloc);

            if (kind == .path) {
                const path = fs.realpathAlloc(main.alloc, ".") catch return Model.Error.OutOfMemory;
                defer main.alloc.free(path);
                try text_box.data.appendSlice(main.alloc, path);
            }

            return text_box;
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit(main.alloc);
        }

        pub fn update(self: *Self, input: Input) Model.Error!?Message {
            switch (self.cursor) {
                .none => {
                    //
                },
                .at => |index| {
                    switch (input.action orelse return null) {
                        .mouse => |mouse| {
                            _ = mouse;
                            // TODO
                        },
                        .key => |key| {
                            switch (key) {
                                .char => |char| {
                                    if (input.ctrl) {
                                        switch (char) {
                                            'c' => {
                                                try self.data.append(main.alloc, 0);
                                                defer _ = self.data.pop();
                                                rl.setClipboardText(@ptrCast(self.value()));
                                            },
                                            'v' => {
                                                const clipboard = mem.span(rl.getClipboardText());
                                                if (clipboard.len > max_paste_len) {
                                                    alert.updateFmt("Clipboard contents are too long ({} characters)", .{clipboard.len});
                                                    return null;
                                                }
                                                try self.data.insertSlice(main.alloc, index, clipboard);
                                                self.cursor.at += clipboard.len;
                                            },
                                            else => {},
                                        }
                                    } else {
                                        try self.data.insert(main.alloc, index, char);
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

                                .up, .home => self.cursor.at = 0,

                                .down, .end => self.cursor.at = self.value().len,

                                .left => self.cursor.at = if (input.ctrl)
                                    toPrevSep(self.value(), index)
                                else if (index > 0) index - 1 else index,

                                .right => self.cursor.at = if (input.ctrl)
                                    toNextSep(self.value(), index)
                                else if (index < self.value().len) index + 1 else index,
                            }
                        },
                    }
                },
                .select => |*selection| {
                    _ = selection;
                    // TODO
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
                .rectangle = .{
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

        pub fn value(self: Self) []const u8 {
            return self.data.items;
        }

        pub fn popPath(self: *Self) void {
            if (kind != .path) @compileError("popPath only works on paths");
            const parent_dir_path = fs.path.dirname(self.value()) orelse return;
            self.data.shrinkRetainingCapacity(parent_dir_path.len);
        }

        pub fn appendPath(self: *Self, entry_name: []const u8) Model.Error!void {
            if (kind != .path) @compileError("appendPath only works on paths");
            try self.data.append(main.alloc, fs.path.sep);
            return self.data.appendSlice(main.alloc, entry_name);
        }

        fn removeCursor(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| _ = self.data.orderedRemove(index),
                .select => |selection| {
                    self.data.replaceRangeAssumeCapacity(selection.from, selection.to - selection.from, "");
                    self.cursor = .{ .at = selection.from };
                },
            }
        }

        fn removeCursorToNextSep(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| self.data.replaceRangeAssumeCapacity(index, toNextSep(self.value(), index) - index, ""),
                .select => self.removeCursor(),
            }
        }

        fn removeCursorToPrevSep(self: *Self) void {
            switch (self.cursor) {
                .none => {},
                .at => |index| {
                    const prev = toPrevSep(self.value(), index);
                    self.data.replaceRangeAssumeCapacity(prev, index - prev, "");
                    self.cursor.at = prev;
                },
                .select => self.removeCursor(),
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
    };
}
