const std = @import("std");
const ascii = std.ascii;
const json = std.json;
const math = std.math;
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
const modal = @import("modal.zig");
const tooltip = @import("tooltip.zig");
const menu = @import("menu.zig");
const alert = @import("alert.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");
const TextBox = @import("text_box.zig").TextBox;
const Error = @import("error.zig").Error;

expanded: bool,
bookmarks: main.ArrayList(Bookmark),
show_bookmarks: bool,
drag_bookmark: ?struct { index: usize, y_pos: f32, offset: f32, dist: f32, container: clay.Config.Scroll.ContainerData },
new_bookmark: ?struct {
    path: []const u8,
    name: TextBox(.text, clay.id("NewBookmarkInput"), clay.id("NewBookmarkInputSubmit")),
},
menu_bookmark: usize,
drives: if (main.is_windows)
    struct { data: main.ArrayList(windows.Drive), state: union(enum) { shown: u32, hidden } }
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

const Menu = enum {
    rename,
    delete,
};

const widths = .{ .min = 200, .max = 350, .default = 250, .cutoff = 500 };
const toggle_id = clay.id("ShortcutsToggle");
const bookmarks_container_id = clay.id("BookmarksContainer");
const width_handle_id = clay.id("ShortcutsWidthHandle");
const collapsed_width = 32;
const shortcuts_width_handle_width = 5;
const bookmark_height = 32;
const bookmark_padding_y = 8;
const gap_between = 8;
const drives_refresh_interval = 20 * time.ms_per_s;

pub const init = Shortcuts{
    .expanded = true,
    .bookmarks = .empty,
    .show_bookmarks = true,
    .drag_bookmark = null,
    .new_bookmark = null,
    .menu_bookmark = 0,
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
    if (input.clicked(.left) and clay.pointerOver(toggle_id)) shortcuts.expanded = !shortcuts.expanded;
    if (!shortcuts.expanded) return null;

    if (menu.get(Menu, input)) |option| {
        switch (option) {
            .rename => {
                const writers = modal.set(.text, Shortcuts, shortcuts, struct {
                    fn f(shortcuts_inner: *Shortcuts, new_name: []const u8) Error!void {
                        if (new_name.len == 0) {
                            alert.updateFmt("No name provided.", .{});
                            return;
                        }
                        const name = &shortcuts_inner.bookmarks.items[shortcuts_inner.menu_bookmark].name;
                        main.alloc.free(name.*);
                        name.* = try main.alloc.dupe(u8, new_name);
                        config.save();
                    }
                }.f);

                fmt.format(
                    writers.message,
                    "Rename '{s}'?",
                    .{shortcuts.bookmarks.items[shortcuts.menu_bookmark].name},
                ) catch return Error.Unexpected;
                writers.labels[0].writeAll("New name") catch return Error.Unexpected;
                writers.reject.writeAll("Cancel") catch return Error.Unexpected;
                writers.accept.writeAll("Rename") catch return Error.Unexpected;
            },
            .delete => {
                const removed = shortcuts.bookmarks.orderedRemove(shortcuts.menu_bookmark);
                main.alloc.free(removed.name);
                config.save();
                return .{ .bookmark_deleted = removed.path };
            },
        }
        return null;
    }

    if (clay.pointerOver(width_handle_id)) if (input.action) |action| switch (action) {
        .mouse => |mouse| if (mouse.button == .left) switch (mouse.state) {
            .pressed => shortcuts.dragging = true,
            .down, .released => {}, // handled down below
        },
        else => {},
    };

    if (main.is_windows) switch (shortcuts.drives.state) {
        .shown => |*timer| {
            if (timer.* == 0) try shortcuts.assignDriveData();
            timer.* +|= @max(@as(@TypeOf(timer.*), @intFromFloat(rl.getFrameTime() * 1000)), 1);
            if (timer.* > drives_refresh_interval) timer.* = 0;
        },
        .hidden => {},
    };

    if (shortcuts.new_bookmark != null) shortcuts.show_bookmarks = true;

    if (shortcuts.drag_bookmark == null and clay.pointerOver(clay.id("Shortcuts"))) {
        if (input.clicked(.left) and clay.pointerOver(clay.id("BookmarksCollapse"))) {
            shortcuts.show_bookmarks = shortcuts.new_bookmark != null or !shortcuts.show_bookmarks;
        } else for (shortcuts.bookmarks.items, 0..) |bookmark, i| {
            if (input.clicked(.left) and clay.pointerOver(clay.idi("BookmarkDelete", @intCast(i)))) {
                main.alloc.free(bookmark.name);
                _ = shortcuts.bookmarks.orderedRemove(i);
                config.save();
                tooltip.disable();
                return .{ .bookmark_deleted = bookmark.path };
            }

            const bookmark_id = clay.idi("Bookmark", @intCast(i));
            if (clay.pointerOver(bookmark_id)) {
                if (input.clicked(.left)) {
                    if (input.offset(bookmark_id)) |offset| {
                        const container = clay.getScrollContainerData(bookmarks_container_id);
                        if (container.found) shortcuts.drag_bookmark = .{
                            .index = i,
                            .y_pos = input.mouse_pos.y,
                            .offset = offset.y,
                            .dist = 0,
                            .container = container,
                        };
                    }
                } else if (input.clicked(.right)) {
                    shortcuts.menu_bookmark = i;
                    tooltip.disable();
                    menu.register(Menu, input.mouse_pos, .{
                        .rename = .{ .name = "Rename", .icon = &resources.images.ibeam },
                        .delete = .{ .name = "Delete", .icon = &resources.images.trash },
                    });
                } else if (tooltip.update(input)) |writer| try writer.writeAll(bookmark.path);
                break;
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

    if (input.action) |action| switch (action) {
        .mouse => |mouse| if (mouse.button == .left) switch (mouse.state) {
            .pressed => {},

            .down => {
                if (shortcuts.dragging) {
                    shortcuts.width = math.clamp(math.lossyCast(usize, input.mouse_pos.x), widths.min, widths.max);
                }

                if (shortcuts.drag_bookmark) |*dragging| {
                    const swap_window: ?f32 = switch (math.order(dragging.y_pos, input.mouse_pos.y)) {
                        .lt => -1,
                        .gt => 1,
                        .eq => null,
                    };

                    dragging.dist += @abs(dragging.y_pos - input.mouse_pos.y);
                    dragging.y_pos = input.mouse_pos.y;

                    const bookmarks_container_data = clay.getElementData(bookmarks_container_id);
                    if (!bookmarks_container_data.found) return null;
                    const y_pos = dragging.y_pos - dragging.offset + ((bookmark_height + bookmark_padding_y * 2) / 2);
                    const scroll_scalar = 3 * rl.getFrameTime();
                    const max_scroll_y = dragging.container.scroll_container_dimensions.height - dragging.container.content_dimensions.height;

                    if (y_pos < bookmarks_container_data.boundingBox.y) {
                        if (dragging.container.scroll_position.y < 0) {
                            dragging.container.scroll_position.y += scroll_scalar * (bookmarks_container_data.boundingBox.y - y_pos);
                        } else {
                            mem.swap(Bookmark, &shortcuts.bookmarks.items[dragging.index], &shortcuts.bookmarks.items[0]);
                            dragging.index = 0;
                        }
                    } else if (y_pos > bookmarks_container_data.boundingBox.y + bookmarks_container_data.boundingBox.height) {
                        if (dragging.container.scroll_position.y > max_scroll_y) {
                            dragging.container.scroll_position.y -= scroll_scalar *
                                (y_pos - bookmarks_container_data.boundingBox.y - bookmarks_container_data.boundingBox.height);
                        } else {
                            const last = shortcuts.bookmarks.items.len - 1;
                            mem.swap(Bookmark, &shortcuts.bookmarks.items[dragging.index], &shortcuts.bookmarks.items[last]);
                            dragging.index = last;
                        }
                    } else for (shortcuts.bookmarks.items, 0..) |*bookmark, i| {
                        if (i == dragging.index) continue;
                        const bookmark_data = clay.getElementData(clay.idi("Bookmark", @intCast(i)));
                        if (!bookmark_data.found) continue;

                        if (swap_window) |window| if (y_pos >= bookmark_data.boundingBox.y + window and
                            y_pos <= bookmark_data.boundingBox.y + bookmark_data.boundingBox.height + window)
                        {
                            mem.swap(Bookmark, &shortcuts.bookmarks.items[dragging.index], bookmark);
                            dragging.index = i;
                            break;
                        };
                    }
                }
            },

            .released => {
                shortcuts.dragging = false;
                if (shortcuts.drag_bookmark) |dragging| {
                    const bookmark_clicked = if (dragging.dist < 5) shortcuts.bookmarks.items[dragging.index] else null;
                    shortcuts.drag_bookmark = null;
                    config.save();
                    return if (bookmark_clicked) |bookmark| .{ .open = bookmark.path } else null;
                }
            },
        },
        else => {},
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
                config.save();
                return .{ .bookmark_created = new_bookmark.path };
            },
        };
    }

    return null;
}

pub fn render(shortcuts: Shortcuts) void {
    if (rl.getScreenWidth() < widths.cutoff) {
        // fixes a strange bug where entries scrolling stops working
        clay.ui()(.{ .scroll = .{ .vertical = true } })({
            clay.ui()(.{ .scroll = .{ .vertical = true } })({});
        });
        return;
    }

    clay.ui()(.{
        .id = clay.id("Shortcuts"),
        .layout = .{
            .padding = .{ .left = 16, .right = 8, .top = 16, .bottom = 16 },
            .sizing = .{ .width = .fixed(@floatFromInt(if (shortcuts.expanded) shortcuts.width else collapsed_width)) },
            .layout_direction = .top_to_bottom,
            .child_gap = gap_between,
        },
        .scroll = .{ .horizontal = true },
    })(shortcuts: {
        clay.ui()(.{
            .layout = .{
                .sizing = .{ .width = .grow(.{}) },
            },
        })({
            if (shortcuts.expanded) clay.ui()(.{ .layout = .{ .sizing = .grow(.{}) } })({});
            clay.ui()(.{
                .id = toggle_id,
                .layout = .{
                    .sizing = .fixed(16),
                },
                .image = .{
                    .image_data = if (shortcuts.expanded) &resources.images.collapse else &resources.images.expand,
                    .source_dimensions = .square(16),
                },
            })({
                draw.pointer();
            });
        });

        if (!shortcuts.expanded) {
            clay.ui()(.{ .scroll = .{ .vertical = true } })({});
            break :shortcuts;
        }

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
                    draw.text("Bookmarks", .{ .font_size = .sm, .color = themes.current.dim_text });
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

                if (shortcuts.show_bookmarks) {
                    clay.ui()(.{
                        .id = bookmarks_container_id,
                        .layout = .{
                            .sizing = .{
                                .width = .grow(.{}),
                            },
                            .layout_direction = .top_to_bottom,
                        },
                        .scroll = .{ .vertical = true },
                    })({
                        for (shortcuts.bookmarks.items, 0..) |bookmark, i| {
                            const bookmark_id = clay.idi("Bookmark", @intCast(i));
                            const floating = if (shortcuts.drag_bookmark) |dragging| floating: {
                                // const max: f32 = @floatFromInt(width - tab_width);
                                if (dragging.index != i) break :floating null;

                                const bookmarks_container_data = clay.getElementData(bookmarks_container_id);
                                if (!bookmarks_container_data.found) break :floating null;

                                // Placeholder when dragging a bookmark
                                clay.ui()(.{ .layout = bookmark_layout })({});

                                const y_pos = math.clamp(
                                    dragging.y_pos - dragging.offset - bookmarks_container_data.boundingBox.y,
                                    0,
                                    dragging.container.scroll_container_dimensions.height - bookmark_height - bookmark_padding_y * 2,
                                );

                                break :floating clay.Config.Floating{
                                    .offset = .{ .y = y_pos },
                                    .z_index = 1,
                                    .parent_id = bookmarks_container_id.id,
                                    .attach_to = .parent,
                                };
                            } else null;

                            const hovered = if (shortcuts.drag_bookmark) |dragging| dragging.index == i else true and
                                clay.pointerOver(bookmark_id);

                            clay.ui()(.{
                                .id = bookmark_id,
                                .layout = bookmark_layout,
                                .floating = floating,
                                .bg_color = if (hovered) themes.current.hovered else themes.current.bg,
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
                                draw.text(bookmark.name, .{ .width = shortcuts.width });
                                clay.ui()(.{ .layout = .{ .sizing = .grow(.{}) } })({});
                                if (hovered) {
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
                        }
                    });
                }
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
                    draw.text("Drives", .{ .font_size = .sm, .color = themes.current.dim_text });
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
                                draw.text(drive_type, .{});
                                draw.text(" (", .{});
                                draw.text(drive.path[0..2], .{});
                                draw.text(")", .{});
                            } else {
                                draw.text(drive.path[0..2], .{});
                            }
                        });
                    }
                }
            });
        } else {
            // TODO posix shortcuts (mounts?)
        }
    });

    if (shortcuts.expanded) clay.ui()(.{
        .id = width_handle_id,
        .layout = .{
            .sizing = .{
                .width = .fixed(shortcuts_width_handle_width),
                .height = .grow(.{}),
            },
        },
        .bg_color = if (shortcuts.dragging)
            themes.current.highlight
        else if (clay.hovered())
            themes.current.secondary
        else
            themes.current.bg,
    })({
        draw.left_right_arrows();
    });
}

pub fn save(shortcuts: Shortcuts, writer: *config.Writer) !void {
    try writer.beginObject();
    try writer.objectField("bookmarks");
    try writer.beginArray();
    for (shortcuts.bookmarks.items) |bookmark| {
        try writer.write(.{
            .name = bookmark.name,
            .path = bookmark.path,
        });
    }
    try writer.endArray();
    try writer.endObject();
}

pub fn load(shortcuts: *Shortcuts, config_json: json.Value) !void {
    const object = switch (config_json) {
        .object => |object| object,
        else => return error.InvalidFormat,
    };
    var kv_iter = object.iterator();
    while (kv_iter.next()) |kv| {
        if (mem.eql(u8, kv.key_ptr.*, "bookmarks")) {
            const array = switch (kv.value_ptr.*) {
                .array => |array| array,
                else => return error.InvalidFormat,
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
                const bookmark = bookmark_result.value;

                try shortcuts.bookmarks.append(main.alloc, .{
                    .icon = &resources.images.bookmarked,
                    .name = try main.alloc.dupe(u8, bookmark.name),
                    .path = try main.alloc.dupe(u8, bookmark.path),
                });
            }
        }
    }
}

pub fn isActive(shortcuts: Shortcuts) bool {
    return if (shortcuts.new_bookmark) |new_bookmark| new_bookmark.name.isActive() else false;
}

pub fn getWidth(shortcuts: Shortcuts) usize {
    return if (rl.getScreenWidth() < widths.cutoff)
        0
    else if (shortcuts.expanded)
        shortcuts.width + shortcuts_width_handle_width
    else
        collapsed_width;
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
            config.save();
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
