const std = @import("std");
const builtin = std.builtin;
const ascii = std.ascii;
const enums = std.enums;
const meta = std.meta;
const math = std.math;
const time = std.time;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");

const main = @import("main.zig");
const Bytes = main.Bytes;
const Millis = main.Millis;
const resources = @import("resources.zig");
const alert = @import("alert.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");

data: std.EnumArray(Kind, std.MultiArrayList(Entry)),
data_slices: std.EnumArray(Kind, std.MultiArrayList(Entry).Slice),
names: Bytes,
sortings: std.EnumArray(Sorting, std.EnumArray(Kind, std.ArrayListUnmanaged(Index))),
curr_sorting: Sorting,
sort_type: enum { asc, desc },

const Entries = @This();

pub const Index = u16;

pub const Kind = enum {
    dir,
    file,
};

const Sorting = enum {
    name,
    ext,
    created,
    modified,
    size,
};

const Entry = struct {
    name: [2]u32,
    selected: ?Millis, // TODO replace with more naive frame calculation?
    created: ?Millis,
    modified: Millis,
    size: u64,
    readonly: bool,
};

const Message = union(enum) {
    open_dir: []const u8,
    open_file: []const u8,
};

fn SortedIterator(fields: []const meta.FieldEnum(Entry)) type {
    const entry_fields = @typeInfo(Entry).Struct.fields;
    var item_fields: [entry_fields.len + 1]builtin.Type.StructField = undefined;
    var item_field_index = 0;
    for (entry_fields) |entry_field| {
        for (fields) |field| {
            if (mem.eql(u8, @tagName(field), entry_field.name)) {
                item_fields[item_field_index] = entry_field;
                if (field == .name) {
                    item_fields[item_field_index].type = []const u8;
                }
                item_field_index += 1;
                break;
            }
        }
    }
    item_fields[item_field_index] = .{
        .name = "index",
        .type = Index,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(Entry),
    };
    item_field_index += 1;
    var item_type = @typeInfo(Entry);
    item_type.Struct.fields = item_fields[0..item_field_index];
    const Item = @Type(item_type);

    return struct {
        sort_list: []const Index,
        slice: std.MultiArrayList(Entry).Slice,
        names: []const u8,

        pub fn next(self: *@This()) ?Item {
            if (self.sort_list.len == 0) return null;
            var item: Item = undefined;
            inline for (fields) |field| {
                const value = self.slice.items(field)[self.sort_list[0]];
                @field(item, @tagName(field)) = if (field == .name) self.names[value[0]..value[1]] else value;
            }
            item.index = self.sort_list[0];
            self.sort_list = self.sort_list[1..];
            return item;
        }
    };
}

const entries_id = main.newId("Entries");
const double_click_delay: Millis = 300;

fn kinds() []const Kind {
    return enums.values(Kind);
}

fn getEntryId(comptime kind: Kind, comptime suffix: []const u8, index: Index) clay.Element.Config.Id {
    var kind_name = @tagName(kind).*;
    kind_name[0] = ascii.toUpper(kind_name[0]);
    return main.newIdIndexed(kind_name ++ "Entry" ++ suffix, index);
}

fn nanosToMillis(nanos: i128) Millis {
    return @intCast(@divFloor(nanos, time.ns_per_ms));
}

pub fn init() !Entries {
    return .{
        .data = meta.FieldType(Entries, .data).initFill(.{}),
        .data_slices = meta.FieldType(Entries, .data_slices).initUndefined(),
        .names = try Bytes.initCapacity(main.alloc, 1024),
        .sortings = meta.FieldType(Entries, .sortings)
            .initFill(@TypeOf(meta.FieldType(Entries, .sortings).initUndefined().get(undefined)).initFill(.{})),
        .curr_sorting = .name,
        .sort_type = .asc,
    };
}

pub fn deinit(entries: *Entries) void {
    for (&entries.data.values) |*data| data.deinit(main.alloc);
    entries.names.deinit(main.alloc);
    for (&entries.sortings.values) |*sort_lists| for (&sort_lists.values) |*sort_list| sort_list.deinit(main.alloc);
}

pub fn update(entries: *Entries, input: Input) ?Message {
    if (!clay.pointerOver(entries_id)) return null;
    if (input.clicked(.left)) {
        inline for (comptime kinds()) |kind| {
            for (0..entries.data_slices.get(kind).len) |i| {
                const index: Index = @intCast(i);
                if (clay.pointerOver(getEntryId(kind, "", index))) {
                    return entries.select(kind, index, true, .single); // TODO select type
                }
            }
        }
    } else if (input.action) |action| {
        switch (action) {
            .mouse => {},
            .key => |key| switch (key) {
                .char => |char| entries.jump(char),
                else => {},
            },
        }
    }
    return null;
}

pub fn render(entries: Entries) void {
    clay.ui()(.{
        .id = main.newId("EntriesContainer"),
        .layout = .{
            .padding = clay.Padding.all(10),
            .sizing = clay.Element.Sizing.grow(.{}),
        },
    })({
        clay.ui()(.{
            .id = entries_id,
            .layout = .{
                .layout_direction = .top_to_bottom,
                .padding = clay.Padding.all(10),
                .sizing = clay.Element.Sizing.grow(.{}),
                .child_gap = 4,
            },
            .scroll = .{ .vertical = true },
            .rectangle = .{ .color = main.theme.base, .corner_radius = main.rounded },
        })({
            inline for (comptime kinds()) |kind| {
                var sorted_iter = entries.sorted(kind, &.{ .name, .selected });
                var sorted_index: Index = 0;
                while (sorted_iter.next()) |entry| : (sorted_index += 1) {
                    const entry_id = getEntryId(kind, "", sorted_index);
                    clay.ui()(.{
                        .id = entry_id,
                        .layout = .{
                            .padding = .{ .top = 4, .bottom = 4, .left = 8 },
                            .sizing = .{ .width = .{ .type = .grow } },
                            .child_alignment = .{ .y = clay.Element.Config.Layout.AlignmentY.center },
                            .child_gap = 4,
                        },
                        .rectangle = .{
                            .color = if (entry.selected) |_|
                                main.theme.selected
                            else if (clay.pointerOver(entry_id))
                                main.theme.hovered
                            else
                                main.theme.base,
                            .corner_radius = main.rounded,
                        },
                    })({
                        main.pointer();

                        const icon_image = switch (kind) {
                            .dir => if (clay.hovered()) &resources.images.folder_open else &resources.images.folder,
                            .file => resources.getFileIcon(entry.name),
                        };

                        clay.ui()(.{
                            .id = getEntryId(kind, "IconContainer", sorted_index),
                            .layout = .{
                                .sizing = clay.Element.Sizing.fixed(resources.file_icon_size),
                            },
                        })({
                            clay.ui()(.{
                                .id = getEntryId(kind, "Icon", sorted_index),
                                .layout = .{
                                    .sizing = clay.Element.Sizing.grow(.{}),
                                },
                                .image = .{
                                    .image_data = icon_image,
                                    .source_dimensions = clay.Dimensions.square(resources.file_icon_size),
                                },
                            })({});
                        });

                        clay.ui()(.{
                            .id = getEntryId(kind, "Name", sorted_index),
                            .layout = .{
                                .padding = clay.Padding.all(6),
                            },
                        })({
                            main.text(entry.name);
                        });
                    });
                }
            }
        });
    });
}

pub fn load_entries(entries: *Entries, path: []const u8) Model.Error!void {
    if (!fs.path.isAbsolute(path)) return Model.Error.OpenDirFailure;
    const dir = fs.openDirAbsolute(path, .{ .iterate = true }) catch |err|
        return if (err == error.AccessDenied) Model.Error.DirAccessDenied else Model.Error.OpenDirFailure;

    for (&entries.data.values) |*data| data.shrinkRetainingCapacity(0);
    entries.names.clearRetainingCapacity();
    for (&entries.sortings.values) |*sort_lists| for (&sort_lists.values) |*sort_list| sort_list.clearRetainingCapacity();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.name.len == 0) continue;
        const start_index = entries.names.items.len;
        try entries.names.appendSlice(main.alloc, entry.name);

        const is_dir = entry.kind == .directory;
        const metadata = if (is_dir)
            (dir.openDir(entry.name, .{ .access_sub_paths = false }) catch continue).metadata() catch continue
        else
            (dir.openFile(entry.name, .{}) catch continue).metadata() catch continue;

        const data = entries.data.getPtr(if (is_dir) .dir else .file);
        data.append(
            main.alloc,
            .{
                .name = .{ @intCast(start_index), @intCast(entries.names.items.len) },
                .selected = null,
                .created = if (metadata.created()) |created| nanosToMillis(created) else null,
                .modified = nanosToMillis(metadata.modified()),
                .size = metadata.size(),
                .readonly = metadata.permissions().readOnly(),
            },
        ) catch break;
        if (data.len == math.maxInt(Index)) {
            alert.updateFmt("Reached the maximum entry limit", .{});
            break;
        }
    }

    for (entries.data.values, &entries.data_slices.values) |data, *data_slice| data_slice.* = data.slice();
    try entries.sort(.name);
    entries.sort_type = .asc;
}

fn sorted(entries: *const Entries, kind: Kind, comptime fields: []const meta.FieldEnum(Entry)) SortedIterator(fields) {
    return .{
        .sort_list = entries.sortings.get(entries.curr_sorting).get(kind).items,
        .slice = entries.data_slices.get(kind),
        .names = entries.names.items,
    };
}

fn sort(entries: *Entries, comptime sorting: Sorting) Model.Error!void {
    const sort_lists = entries.sortings.getPtr(sorting);

    inline for (comptime kinds()) |kind| {
        const sort_list = sort_lists.getPtr(kind);
        if (sort_list.items.len == 0) { // non-zero means either already sorted or empty dir
            const len = entries.data.get(kind).len;
            try sort_list.ensureTotalCapacity(main.alloc, len);
            for (0..len) |i| sort_list.appendAssumeCapacity(@intCast(i));

            const lessThanFn = struct {
                fn cmp(passed_entries: *const Entries, lhs: Index, rhs: Index) bool {
                    switch (sorting) {
                        .name => {
                            const lhs_start, const lhs_end = passed_entries.data_slices.get(kind).items(.name)[lhs];
                            const rhs_start, const rhs_end = passed_entries.data_slices.get(kind).items(.name)[rhs];
                            const lhs_name = passed_entries.names.items[lhs_start..lhs_end];
                            const rhs_name = passed_entries.names.items[rhs_start..rhs_end];
                            return mem.lessThan(u8, lhs_name, rhs_name);
                        },
                        .ext => {
                            const lhs_start, const lhs_end = passed_entries.data_slices.get(kind).items(.name)[lhs];
                            const rhs_start, const rhs_end = passed_entries.data_slices.get(kind).items(.name)[rhs];
                            const lhs_name = passed_entries.names.items[lhs_start..lhs_end];
                            const rhs_name = passed_entries.names.items[rhs_start..rhs_end];
                            return mem.lessThan(u8, fs.path.extension(lhs_name), fs.path.extension(rhs_name));
                        },
                        .created => {
                            const created = passed_entries.data_slices.get(kind).items(.created);
                            return created[lhs] < created[rhs];
                        },
                        .modified => {
                            const modified = passed_entries.data_slices.get(kind).items(.modified);
                            return modified[lhs] < modified[rhs];
                        },
                        .size => {
                            const size = passed_entries.data_slices.get(kind).items(.size);
                            return size[lhs] < size[rhs];
                        },
                    }
                }
            }.cmp;

            std.sort.block(u16, sort_list.items, entries, lessThanFn);
        }
    }

    entries.curr_sorting = sorting;
}

fn select(entries: *Entries, kind: Kind, index: Index, clicked: bool, select_type: enum { single, multi, bulk }) ?Message {
    const selected = entries.data_slices.get(kind).items(.selected);

    const now = time.milliTimestamp();
    if (selected[index]) |selected_ts| {
        if (clicked and (now - selected_ts) < double_click_delay) {
            const name_start, const name_end = entries.data_slices.get(kind).items(.name)[index];
            const name = entries.names.items[name_start..name_end];
            return switch (kind) {
                .dir => .{ .open_dir = name },
                .file => .{ .open_file = name },
            };
        }
    }

    switch (select_type) {
        .single => {
            for (entries.data_slices.values) |slice| {
                for (slice.items(.selected)) |*unselect| unselect.* = null;
            }
            selected[index] = now;
        },
        .multi => selected[index] = now,
        .bulk => {
            // TODO
        },
    }

    return null;
}

fn jump(entries: *Entries, char: u8) void {
    for (kinds()) |kind| {
        var sorted_entries = entries.sorted(kind, &.{ .name, .selected });
        while (sorted_entries.next()) |entry| {
            if (ascii.startsWithIgnoreCase(entry.name, &.{char})) {
                for (entries.data_slices.values) |slice| {
                    for (slice.items(.selected)) |*unselect| unselect.* = null;
                }
                entries.data_slices.get(kind).items(.selected)[entry.index] = time.milliTimestamp();
                return;
            }
        }
    }
}

fn toggle_sort_type(entries: *Entries) void {
    entries.sort_type = if (entries.sort_type == .asc) .desc else .asc;
}
