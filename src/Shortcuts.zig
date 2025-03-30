const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const themes = @import("themes.zig");
const resources = @import("resources.zig");
const draw = @import("draw.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");
const TextBox = @import("text_box.zig").TextBox;

bookmarks: main.ArrayList(Bookmark),
show_bookmarks: bool,
new_bookmark: ?struct { path: []const u8, name: TextBox(.text, clay.id("NewBookmarkInput")) },
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
    .show_bookmarks = true,
    .new_bookmark = null,
    .width = widths.default,
    .dragging = false,
};

pub fn deinit(shortcuts: *Shortcuts) void {
    for (shortcuts.bookmarks.items) |bookmark| {
        main.alloc.free(bookmark.name);
        main.alloc.free(bookmark.path);
    }
    shortcuts.bookmarks.deinit(main.alloc);
    if (shortcuts.new_bookmark) |*new_bookmark| {
        new_bookmark.name.deinit();
        main.alloc.free(new_bookmark.path);
    }
}

pub fn update(shortcuts: *Shortcuts, input: Input) Model.Error!?Message {
    if (input.clicked(.left)) if (clay.pointerOver(clay.id("Shortcuts"))) {
        if (clay.pointerOver(clay.id("BookmarksCollapse"))) {
            shortcuts.show_bookmarks = !shortcuts.show_bookmarks;
        } else for (shortcuts.bookmarks.items, 0..) |bookmark, i| {
            if (clay.pointerOver(clay.idi("Bookmark", @intCast(i)))) return .{ .open = bookmark.path };
        }
    };

    if (shortcuts.new_bookmark) |*new_bookmark| {
        if (try new_bookmark.name.update(input)) |message| switch (message) {
            .submit => |name| {
                defer {
                    new_bookmark.name.deinit();
                    shortcuts.new_bookmark = null;
                }
                errdefer main.alloc.free(new_bookmark.path);
                const dupe_name = try main.alloc.dupe(u8, name);
                errdefer main.alloc.free(dupe_name);
                try shortcuts.bookmarks.insert(main.alloc, 0, .{
                    .name = dupe_name,
                    .path = new_bookmark.path,
                    .icon = &resources.images.bookmarked,
                });
            },
        };
    }

    return null;
}

pub fn render(shortcuts: Shortcuts) void {
    clay.ui()(.{
        .id = clay.id("Shortcuts"),
        .layout = .{
            .padding = .{ .left = 16, .right = 16, .top = 32, .bottom = 16 },
            .sizing = .{ .width = .fixed(@floatFromInt(shortcuts.width)) },
            .layout_direction = .top_to_bottom,
        },
        .scroll = .{ .vertical = true, .horizontal = true },
    })({
        clay.ui()(.{
            .id = clay.id("Bookmarks"),
            .layout = .{
                .sizing = .grow(.{}),
                .layout_direction = .top_to_bottom,
                .child_gap = 12,
            },
        })({
            clay.ui()(.{
                .id = clay.id("BookmarksCollapse"),
                .layout = .{
                    .padding = .all(8),
                    .sizing = .{ .width = .grow(.{}) },
                },
                .bg_color = if (clay.hovered()) themes.current.hovered else themes.current.bg,
                .corner_radius = draw.rounded,
            })({
                draw.pointer();
                draw.textEx(.roboto, .sm, "Bookmarks", themes.current.dim_text, null);
                clay.ui()(.{ .layout = .{ .sizing = .grow(.{}) } })({});
                clay.ui()(.{
                    .layout = .{
                        .sizing = .fixed(16),
                    },
                    .image = .{
                        .image_data = if (shortcuts.show_bookmarks)
                            &resources.images.tri_up
                        else
                            &resources.images.tri_down,
                        .source_dimensions = .square(16),
                    },
                })({});
            });

            const bookmark_layout = clay.Config.Layout{
                .padding = .all(8),
                .sizing = .{ .width = .grow(.{}) },
                .child_alignment = .{ .y = .center },
                .child_gap = 12,
            };

            if (shortcuts.new_bookmark) |new_bookmark| {
                clay.ui()(.{
                    .id = clay.id("NewBookmark"),
                    .layout = bookmark_layout,
                })({
                    new_bookmark.name.render();
                });
            }

            if (shortcuts.show_bookmarks) for (shortcuts.bookmarks.items, 0..) |bookmark, i| {
                clay.ui()(.{
                    .id = clay.idi("Bookmark", @intCast(i)),
                    .layout = bookmark_layout,
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
            };
        });
    });
}

pub fn isBookmarked(shortcuts: Shortcuts, path: []const u8) bool {
    for (shortcuts.bookmarks.items) |bookmark| {
        if (if (main.is_windows)
            ascii.eqlIgnoreCase(bookmark.path, path)
        else
            mem.eql(u8, bookmark.path, path))
        {
            return true;
        }
    }
    return false;
}

pub fn toggleBookmark(shortcuts: *Shortcuts, path: []const u8) Model.Error!void {
    for (shortcuts.bookmarks.items, 0..) |bookmark, i| {
        if (if (main.is_windows)
            ascii.eqlIgnoreCase(bookmark.path, path)
        else
            mem.eql(u8, bookmark.path, path))
        {
            main.alloc.free(bookmark.name);
            main.alloc.free(bookmark.path);
            _ = shortcuts.bookmarks.orderedRemove(i);
            return;
        }
    }
    if (shortcuts.new_bookmark == null) {
        const dupe_path = try main.alloc.dupe(u8, path);
        errdefer main.alloc.free(dupe_path);
        shortcuts.new_bookmark = .{
            .path = dupe_path,
            .name = try .init(fs.path.basename(path), .selected),
        };
    }
}
