const std = @import("std");
const builtin = std.builtin;
const ascii = std.ascii;
const enums = std.enums;
const json = std.json;
const meta = std.meta;
const math = std.math;
const time = std.time;
const fmt = std.fmt;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");

const main = @import("main.zig");
const resources = @import("resources.zig");
const alert = @import("alert.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");

data: std.EnumArray(Kind, std.MultiArrayList(Entry)),
data_slices: std.EnumArray(Kind, std.MultiArrayList(Entry).Slice),
names: std.ArrayListUnmanaged(u8),
sizes: std.ArrayListUnmanaged(std.BoundedArray(u8, 9)),
sortings: std.EnumArray(Sorting, std.EnumArray(Kind, std.ArrayListUnmanaged(Index))),
curr_sorting: Sorting,
sort_type: enum { asc, desc },
max_name_len: u16,

const Entries = @This();

pub const Index = u16;

pub const Kind = enum {
    dir,
    file,
};

const Timespan = union(enum) {
    just_now,
    past: struct { count: u7, metric: TimespanMetric },

    fn fromNanos(nanos: i128) Timespan {
        if (nanos < 0) return .just_now;
        comptime var metrics = mem.reverseIterator(enums.values(TimespanMetric));
        inline while (comptime metrics.next()) |metric| {
            const count: u7 = @intCast(@min(@divFloor(nanos, metric.inNanos()), 99));
            if (count > 0) {
                return .{ .past = .{ .count = count, .metric = metric } };
            }
        }
        return .just_now;
    }
};

const TimespanMetric = enum {
    seconds,
    minutes,
    hours,
    days,
    weeks,
    years,

    fn inNanos(metric: TimespanMetric) u64 {
        return switch (metric) {
            .seconds => time.ns_per_s,
            .minutes => time.ns_per_min,
            .hours => time.ns_per_hour,
            .days => time.ns_per_day,
            .weeks => time.ns_per_week,
            .years => 365 * time.ns_per_day,
        };
    }

    fn toString(metric: TimespanMetric, plural: bool) []const u8 {
        switch (plural) {
            inline true, false => |p| switch (metric) {
                inline else => |m| {
                    const metric_name = @tagName(m);
                    return " " ++ (if (p) metric_name else metric_name[0 .. metric_name.len - 1]) ++ " ago";
                },
            },
        }
    }
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
    selected: ?i64, // TODO replace with more naive frame calculation?
    created: ?Timespan,
    modified: Timespan,
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
const double_click_delay = 300;
const char_px_width = 10;
const min_name_chars = 16;
const max_name_chars = 32;
const size_chars = 20;
const timespan_chars = 20;

const size_sizing = clay.Element.Sizing{
    .width = clay.Element.Sizing.Axis.fit(.{
        .min = size_chars * char_px_width,
        .max = size_chars * char_px_width,
    }),
};

const timespan_sizing = clay.Element.Sizing{
    .width = clay.Element.Sizing.Axis.fit(.{
        .min = timespan_chars * char_px_width,
        .max = timespan_chars * char_px_width,
    }),
};

fn kinds() []const Kind {
    return enums.values(Kind);
}

fn getEntryId(comptime kind: Kind, comptime suffix: []const u8, index: Index) clay.Element.Config.Id {
    comptime var kind_name = @tagName(kind).*;
    kind_name[0] = comptime ascii.toUpper(kind_name[0]);
    return main.newIdIndexed(kind_name[0..] ++ "Entry" ++ suffix, index);
}

fn twoDigitString(n: u7) []const u8 {
    const one_digits = "0123456789";
    const two_digits =
        "____________________10111213141516171819" ++
        "2021222324252627282930313233343536373839" ++
        "4041424344454647484950515253545556575859" ++
        "6061626364656667686970717273747576777879" ++
        "8081828384858687888990919293949596979899";
    return if (n < 10) one_digits[n..][0..1] else two_digits[n * 2 ..][0..2];
}

pub fn init() Model.Error!Entries {
    return .{
        .data = meta.FieldType(Entries, .data).initFill(.{}),
        .data_slices = meta.FieldType(Entries, .data_slices).initUndefined(),
        .names = try meta.FieldType(Entries, .names).initCapacity(main.alloc, 1024),
        .sizes = try meta.FieldType(Entries, .sizes).initCapacity(main.alloc, 64),
        .sortings = meta.FieldType(Entries, .sortings)
            .initFill(@TypeOf(meta.FieldType(Entries, .sortings).initUndefined().get(undefined)).initFill(.{})),
        .curr_sorting = .name,
        .sort_type = .asc,
        .max_name_len = 0,
    };
}

pub fn deinit(entries: *Entries) void {
    for (&entries.data.values) |*data| data.deinit(main.alloc);
    entries.names.deinit(main.alloc);
    entries.sizes.deinit(main.alloc);
    for (&entries.sortings.values) |*sort_lists| for (&sort_lists.values) |*sort_list| sort_list.deinit(main.alloc);
}

pub fn update(entries: *Entries, input: Input) Model.Error!?Message {
    if (!clay.pointerOver(entries_id)) return null;
    if (input.clicked(.left)) {
        inline for (comptime kinds()) |kind| {
            var sorted_iter = entries.sorted(kind, &.{});
            var sorted_index: Index = 0;
            while (sorted_iter.next()) |entry| : (sorted_index += 1) {
                if (clay.pointerOver(getEntryId(kind, "", sorted_index))) {
                    return entries.select(kind, entry.index, true, .single); // TODO select type
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
    const name_sizing = clay.Element.Sizing{
        .width = clay.Element.Sizing.Axis.fit(.{
            .min = @max(@as(f32, @floatFromInt(entries.max_name_len)), min_name_chars) * char_px_width,
            .max = max_name_chars * char_px_width,
        }),
    };

    clay.ui()(.{
        .id = main.newId("EntriesContainer"),
        .layout = .{
            .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
            .sizing = clay.Element.Sizing.grow(.{}),
            .layout_direction = .top_to_bottom,
        },
    })({
        clay.ui()(.{
            .id = main.newId("EntriesColumns"),
            .layout = .{
                .padding = .{ .top = 4, .bottom = 4, .left = 12 },
                .sizing = .{ .width = .{ .type = .grow } },
                .child_alignment = .{ .y = .center },
                .child_gap = 4,
            },
        })({
            clay.ui()(.{
                .id = main.newId("EntriesColumnPad"),
                .layout = .{
                    .sizing = clay.Element.Sizing.fixed(resources.file_icon_size),
                },
            })({});

            const column = struct {
                fn f(comptime name: []const u8, sizing: clay.Element.Sizing) void {
                    const id = main.newId("EntriesColumn" ++ name);
                    clay.ui()(.{
                        .id = id,
                        .layout = .{
                            .padding = clay.Padding.all(6),
                            .sizing = sizing,
                        },
                        .rectangle = .{
                            .color = if (clay.pointerOver(id)) main.theme.hovered else main.theme.mantle,
                            .corner_radius = main.rounded,
                        },
                    })({
                        main.pointer();
                        main.text(name);
                    });
                }
            }.f;
            column("Name", name_sizing);
            column("Size", size_sizing);
            column("Created", timespan_sizing);
            column("Modified", timespan_sizing);
        });

        clay.ui()(.{
            .id = entries_id,
            .layout = .{
                .padding = clay.Padding.all(10),
                .sizing = clay.Element.Sizing.grow(.{}),
                .child_gap = 4,
                .layout_direction = .top_to_bottom,
            },
            .scroll = .{ .vertical = true },
            .rectangle = .{ .color = main.theme.base, .corner_radius = main.rounded },
        })({
            inline for (comptime kinds()) |kind| {
                var sorted_iter = entries.sorted(kind, &.{
                    .name,
                    .selected,
                    .created,
                    .modified,
                });
                var sorted_index: Index = 0;
                while (sorted_iter.next()) |entry| : (sorted_index += 1) {
                    const entry_id = getEntryId(kind, "", sorted_index);
                    clay.ui()(.{
                        .id = entry_id,
                        .layout = .{
                            .padding = .{ .top = 4, .bottom = 4, .left = 8 },
                            .sizing = .{ .width = .{ .type = .grow } },
                            .child_alignment = .{ .y = .center },
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
                                .sizing = name_sizing,
                            },
                        })({
                            if (entry.name.len > max_name_chars) {
                                main.text(entry.name[0 .. max_name_chars - "...".len]);
                                main.text("...");
                            } else main.text(entry.name);
                        });

                        clay.ui()(.{
                            .id = getEntryId(kind, "Size", sorted_index),
                            .layout = .{
                                .padding = clay.Padding.all(6),
                                .sizing = size_sizing,
                            },
                        })({
                            main.text(switch (kind) {
                                .dir => "",
                                .file => entries.sizes.items[entry.index].slice(),
                            });
                        });

                        clay.ui()(.{
                            .id = getEntryId(kind, "Created", sorted_index),
                            .layout = .{
                                .padding = clay.Padding.all(6),
                                .sizing = timespan_sizing,
                            },
                        })({
                            if (entry.created) |created| {
                                switch (created) {
                                    .just_now => main.text("Just now"),
                                    .past => |timespan| {
                                        main.text(twoDigitString(timespan.count));
                                        main.text(timespan.metric.toString(timespan.count != 1));
                                    },
                                }
                            } else main.text("");
                        });

                        clay.ui()(.{
                            .id = getEntryId(kind, "Modified", sorted_index),
                            .layout = .{
                                .padding = clay.Padding.all(6),
                                .sizing = timespan_sizing,
                            },
                        })({
                            switch (entry.modified) {
                                .just_now => main.text("Just now"),
                                .past => |timespan| {
                                    main.text(twoDigitString(timespan.count));
                                    main.text(timespan.metric.toString(timespan.count != 1));
                                },
                            }
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
    entries.sizes.clearRetainingCapacity();
    for (&entries.sortings.values) |*sort_lists| for (&sort_lists.values) |*sort_list| sort_list.clearRetainingCapacity();
    entries.max_name_len = 0;

    const now = time.nanoTimestamp();

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

        var size = meta.Elem(@TypeOf(entries.sizes.items)){};
        fmt.format(size.writer(), "{:.2}", .{fmt.fmtIntSizeBin(metadata.size())}) catch unreachable;
        if (mem.indexOfScalar(u8, size.slice(), 'i')) |remove_i_at| _ = size.orderedRemove(remove_i_at);
        var window_iter = mem.window(u8, size.slice(), 2, 1);
        var insert_space_at: usize = 0;
        while (window_iter.next()) |window| : (insert_space_at += 1) {
            if (ascii.isDigit(window[0]) and ascii.isAlphabetic(window[1])) {
                size.insert(insert_space_at + 1, ' ') catch unreachable;
                break;
            }
        } else unreachable;
        try entries.sizes.append(main.alloc, size);

        const data = entries.data.getPtr(if (is_dir) .dir else .file);
        try data.append(
            main.alloc,
            .{
                .name = .{ @intCast(start_index), @intCast(entries.names.items.len) },
                .selected = null,
                .created = if (metadata.created()) |created| Timespan.fromNanos(now - created) else null,
                .modified = Timespan.fromNanos(now - metadata.modified()),
                .size = metadata.size(),
                .readonly = metadata.permissions().readOnly(),
            },
        );
        if (data.len == math.maxInt(Index)) {
            alert.updateFmt("Reached the maximum entry limit", .{});
            break;
        }
        const name_len: u16 = @intCast(entries.names.items.len - start_index);
        entries.max_name_len = @max(name_len, entries.max_name_len);
    }

    for (entries.data.values, &entries.data_slices.values) |data, *slice| slice.* = data.slice();

    try entries.sort(.name);
    entries.sort_type = .asc;
}

pub fn sorted(entries: *const Entries, kind: Kind, comptime fields: []const meta.FieldEnum(Entry)) SortedIterator(fields) {
    return .{
        .sort_list = entries.sortings.get(entries.curr_sorting).get(kind).items,
        .slice = entries.data_slices.get(kind),
        .names = entries.names.items,
    };
}

pub fn format(entries: Entries, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    for (kinds()) |kind| {
        try fmt.format(writer, "\n{s}s:\n", .{@tagName(kind)});
        var array_writer = json.writeStreamMaxDepth(writer, .{ .whitespace = .indent_3 }, null);
        try array_writer.beginArray();
        var sorted_iter = entries.sorted(kind, enums.values(meta.FieldEnum(Entry)));
        while (sorted_iter.next()) |entry| try array_writer.write(entry);
        try array_writer.endArray();
    }
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
                fn getName(passed_entries: *const Entries, index: Index) []const u8 {
                    const start, const end = passed_entries.data_slices.get(kind).items(.name)[index];
                    return passed_entries.names.items[start..end];
                }

                fn cmp(passed_entries: *const Entries, lhs: Index, rhs: Index) bool {
                    switch (sorting) {
                        .name => return ascii.lessThanIgnoreCase(
                            getName(passed_entries, lhs),
                            getName(passed_entries, rhs),
                        ),
                        .ext => return ascii.lessThanIgnoreCase(
                            fs.path.extension(getName(passed_entries, lhs)),
                            fs.path.extension(getName(passed_entries, rhs)),
                        ),
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
                            return switch (math.order(size[lhs], size[rhs])) { // dirs will have 0 size, fallback to name
                                .lt => true,
                                .gt => false,
                                .eq => ascii.lessThanIgnoreCase(
                                    getName(passed_entries, lhs),
                                    getName(passed_entries, rhs),
                                ),
                            };
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
