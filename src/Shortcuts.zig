const std = @import("std");

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const themes = @import("themes.zig");
const draw = @import("draw.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");

bookmarks: main.ArrayList(Bookmark),
width: usize,
dragging: bool,

const Shortcuts = @This();

pub const Bookmark = struct {
    name: []const u8,
    path: []const u8,
    icon: *rl.Texture,
};

pub const Message = union(enum) {
    open: []const u8,
};

pub const widths = .{ .min = 200, .max = 350, .default = 250, .cutoff = 500 };
pub const width_handle_id = clay.id("ShortcutsWidthHandle");

pub const init = Shortcuts{
    .bookmarks = .empty,
    .width = widths.default,
    .dragging = false,
};

pub fn deinit(shortcuts: *Shortcuts) void {
    for (shortcuts.bookmarks.items) |bookmark| {
        main.alloc.free(bookmark.name);
        main.alloc.free(bookmark.path);
    }
    shortcuts.bookmarks.deinit(main.alloc);
}

pub fn update(shortcuts: *Shortcuts, input: Input) Model.Error!?Message {
    if (input.clicked(.left)) if (clay.pointerOver(clay.id("Shortcuts"))) {
        for (shortcuts.bookmarks.items, 0..) |bookmark, i| {
            if (clay.pointerOver(clay.idi("Bookmark", @intCast(i)))) return .{ .open = bookmark.path };
        }
    };
    return null;
}

pub fn render(shortcuts: Shortcuts) void {
    clay.ui()(.{
        .id = clay.id("Shortcuts"),
        .layout = .{
            .padding = .all(16),
            .sizing = .{ .width = .fixed(@floatFromInt(shortcuts.width)) },
            .layout_direction = .top_to_bottom,
            .child_gap = 12,
        },
        .scroll = .{ .vertical = true, .horizontal = true },
    })({
        for (shortcuts.bookmarks.items, 0..) |bookmark, i| {
            clay.ui()(.{
                .id = clay.idi("Bookmark", @intCast(i)),
                .layout = .{
                    .padding = .all(8),
                    .sizing = .{ .width = .grow(.{}) },
                    .child_alignment = .{ .y = .center },
                    .child_gap = 12,
                },
                .bg_color = if (clay.hovered()) themes.current.hovered else themes.current.bg,
                .corner_radius = draw.rounded,
            })({
                draw.pointer();
                clay.ui()(.{
                    .layout = .{
                        .sizing = .fixed(24),
                    },
                    .image = .{
                        .image_data = bookmark.icon,
                        .source_dimensions = .square(24),
                    },
                })({});
                draw.textEx(.roboto, .md, bookmark.name, themes.current.text, shortcuts.width);
            });
        }
    });
}
