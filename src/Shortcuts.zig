const std = @import("std");
const ascii = std.ascii;
const json = std.json;
const time = std.time;
const fmt = std.fmt;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const themes = @import("themes.zig");
const resources = @import("resources.zig");
const windows = @import("windows.zig");
const config = @import("config.zig");
const draw = @import("draw.zig");
const tooltip = @import("tooltip.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");
const TextBox = @import("text_box.zig").TextBox;
const Error = @import("error.zig").Error;

bookmarks: main.ArrayList(Bookmark),
show_bookmarks: bool,
new_bookmark: ?struct {
    path: []const u8,
    name: TextBox(.text, clay.id("NewBookmarkInput"), clay.id("NewBookmarkInputSubmit")),
},
drives: if (main.is_windows)
    struct { data: main.ArrayList(windows.DrivesIterator.Drive), state: union(enum) { shown: u32, hidden } }
else
    void,
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
    bookmark_created: []const u8,
    bookmark_deleted: []const u8,
};

pub const widths = .{ .min = 200, .max = 350, .default = 250, .cutoff = 500 };
pub const width_handle_id = clay.id("ShortcutsWidthHandle");
const bookmark_height = 32;
const gap_between = 8;
const drives_refresh_interval = 20 * time.ms_per_s;

pub const init = Shortcuts{
    .bookmarks = .empty,
    .show_bookmarks = true,
    .new_bookmark = null,
    .drives = if (main.is_windows) .{ .data = .empty, .state = .{ .shown = 0 } } else {},
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
    if (main.is_windows) shortcuts.drives.data.deinit(main.alloc);
}

pub fn update(shortcuts: *Shortcuts, input: Input) Error!?Message {
    if (main.is_windows) switch (shortcuts.drives.state) {
        .shown => |*timer| {
            if (timer.* == 0) try shortcuts.assignDriveData();
            timer.* +|= @max(@as(@TypeOf(timer.*), @intFromFloat(rl.getFrameTime() * 1000)), 1);
            if (timer.* > drives_refresh_interval) timer.* = 0;
        },
        .hidden => {},
    };

    if (shortcuts.new_bookmark != null) shortcuts.show_bookmarks = true;

    if (clay.pointerOver(clay.id("Shortcuts"))) {
        if (input.clicked(.left) and clay.pointerOver(clay.id("BookmarksCollapse"))) {
            shortcuts.show_bookmarks = shortcuts.new_bookmark != null or !shortcuts.show_bookmarks;
        } else for (shortcuts.bookmarks.items, 0..) |bookmark, i| {
            if (input.clicked(.left) and clay.pointerOver(clay.idi("BookmarkDelete", @intCast(i)))) {
                main.alloc.free(bookmark.name);
                _ = shortcuts.bookmarks.orderedRemove(i);
                tooltip.disable();
                return .{ .bookmark_deleted = bookmark.path };
            }
            if (clay.pointerOver(clay.idi("Bookmark", @intCast(i)))) {
                if (input.clicked(.left)) return .{ .open = bookmark.path };
                if (tooltip.update(input)) |writer| try writer.writeAll(bookmark.path);
            }
        }

        if (main.is_windows) {
            if (input.clicked(.left) and clay.pointerOver(clay.id("DrivesCollapse"))) {
                shortcuts.drives.state = switch (shortcuts.drives.state) {
                    .shown => .hidden,
                    .hidden => .{ .shown = 0 },
                };
            } else for (shortcuts.drives.data.items, 0..) |*drive, i| {
                if (clay.pointerOver(clay.idi("Drive", @intCast(i)))) {
                    if (input.clicked(.left)) return .{ .open = &drive.path };
                    if (tooltip.update(input)) |writer| {
                        try fmt.format(
                            writer,
                            "{:.2} free, {:.2} total",
                            .{ fmt.fmtIntSizeBin(drive.free_space), fmt.fmtIntSizeBin(drive.total_space) },
                        );
                    }
                }
            }
        }
    }

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
                return .{ .bookmark_created = new_bookmark.path };
            },
        };
    }

    return null;
}

pub fn render(shortcuts: Shortcuts) void {
    clay.ui()(.{
        .id = clay.id("Shortcuts"),
        .layout = .{
            .padding = .{ .left = 16, .right = 8, .top = 32, .bottom = 16 },
            .sizing = .{ .width = .fixed(@floatFromInt(shortcuts.width)) },
            .layout_direction = .top_to_bottom,
            .child_gap = gap_between,
        },
        .scroll = .{ .vertical = true, .horizontal = true },
    })({
        if (shortcuts.bookmarks.items.len > 0 or shortcuts.new_bookmark != null) {
            clay.ui()(.{
                .id = clay.id("Bookmarks"),
                .layout = .{
                    .sizing = .grow(.{}),
                    .layout_direction = .top_to_bottom,
                    .child_gap = gap_between,
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

                const bookmark_padding_y = 8;
                const bookmark_layout = clay.Config.Layout{
                    .padding = .{
                        .left = 8,
                        .right = 16,
                        .top = bookmark_padding_y,
                        .bottom = bookmark_padding_y,
                    },
                    .sizing = .{
                        .width = .grow(.{}),
                        .height = .fit(.{ .min = bookmark_height + bookmark_padding_y * 2 }),
                    },
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
                        clay.ui()(.{ .layout = .{ .sizing = .grow(.{}) } })({});
                        if (clay.hovered()) {
                            clay.ui()(.{
                                .id = clay.idi("BookmarkDelete", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .width = .fixed(9) },
                                },
                                .image = .{
                                    .image_data = if (clay.hovered()) &resources.images.x else &resources.images.x_dim,
                                    .source_dimensions = .{ .width = 9, .height = bookmark_height },
                                },
                            })({});
                        }
                    });
                };
            });
        }

        if (main.is_windows) {
            clay.ui()(.{
                .id = clay.id("Drives"),
                .layout = .{
                    .sizing = .grow(.{}),
                    .layout_direction = .top_to_bottom,
                    .child_gap = gap_between,
                },
            })({
                clay.ui()(.{
                    .id = clay.id("DrivesCollapse"),
                    .layout = .{
                        .padding = .all(8),
                        .sizing = .{ .width = .grow(.{}) },
                    },
                    .bg_color = if (clay.hovered()) themes.current.hovered else themes.current.bg,
                    .corner_radius = draw.rounded,
                })({
                    draw.pointer();
                    draw.textEx(.roboto, .sm, "Drives", themes.current.dim_text, null);
                    clay.ui()(.{ .layout = .{ .sizing = .grow(.{}) } })({});
                    clay.ui()(.{
                        .layout = .{
                            .sizing = .fixed(16),
                        },
                        .image = .{
                            .image_data = switch (shortcuts.drives.state) {
                                .shown => &resources.images.tri_up,
                                .hidden => &resources.images.tri_down,
                            },
                            .source_dimensions = .square(16),
                        },
                    })({});
                });

                if (shortcuts.drives.state == .shown) {
                    for (shortcuts.drives.data.items, 0..) |*drive, i| {
                        clay.ui()(.{
                            .id = clay.idi("Drive", @intCast(i)),
                            .layout = .{
                                .padding = .{ .left = 8, .top = 8, .bottom = 8 },
                                .sizing = .{ .width = .grow(.{}) },
                                .child_alignment = .{ .y = .center },
                            },
                            .bg_color = if (clay.hovered()) themes.current.hovered else themes.current.bg,
                            .corner_radius = draw.rounded,
                        })({
                            draw.pointer();
                            if (drive.type) |drive_type| {
                                draw.text(drive_type);
                                draw.text(" (");
                                draw.text(drive.path[0..2]);
                                draw.text(")");
                            } else {
                                draw.text(drive.path[0..2]);
                            }
                        });
                    }
                }
            });
        } else {
            // TODO posix shortcuts (mounts?)
        }
    });
}

pub fn save(shortcuts: Shortcuts, writer: *config.Writer) !void {
    try writer.write().beginArray();
    for (shortcuts.bookmarks.items) |bookmark| {
        try writer.write().write(.{
            .name = bookmark.name,
            .path = bookmark.path,
        });
    }
    try writer.write().endArray();
}

pub fn load(shortcuts: *Shortcuts, reader: *config.Reader) !void {
    const result = try reader.read();
    defer result.deinit();
    const object = switch (result.value) {
        .object => |object| object,
        else => return Error.InvalidFormat,
    };
    var kv_iter = object.iterator();
    while (kv_iter.next()) |kv| {
        if (mem.eql(u8, kv.key_ptr.*, "bookmarks")) {
            const array = switch (kv.value_ptr.*) {
                .array => |array| array,
                else => return Error.InvalidFormat,
            };
            shortcuts.bookmarks.clearRetainingCapacity();
            for (array.items) |value| {
                const bookmark_result = try json.parseFromValue(
                    struct { name: []const u8, path: []const u8 },
                    main.alloc,
                    value,
                    .{},
                );
                defer bookmark_result.deinit();

                shortcuts.bookmarks.append(main.alloc, .{
                    .icon = &resources.images.bookmarked,
                    .name = try main.alloc.dupe(u8, bookmark_result.name),
                    .path = try main.alloc.dupe(u8, bookmark_result.path),
                });
            }
        }
    }
}

pub fn isActive(shortcuts: Shortcuts) bool {
    return if (shortcuts.new_bookmark) |new_bookmark| new_bookmark.name.isActive() else false;
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

pub fn toggleBookmark(shortcuts: *Shortcuts, path: []const u8) Error!void {
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
        var name = fs.path.basename(path);
        if (name.len == 0) name = path;
        shortcuts.new_bookmark = .{
            .path = dupe_path,
            .name = try .init(name, .selected),
        };
    }
}

fn assignDriveData(shortcuts: *Shortcuts) Error!void {
    if (!main.is_windows) return;
    shortcuts.drives.data.clearRetainingCapacity();
    var drives_iter = windows.DrivesIterator.init();
    while (drives_iter.next()) |drive| try shortcuts.drives.data.append(main.alloc, drive);
}
