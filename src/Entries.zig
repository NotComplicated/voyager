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
const os = std.os;

const clay = @import("clay");
const rl = @import("raylib");
const Datetime = @import("datetime").datetime.Datetime;

const main = @import("main.zig");
const resources = @import("resources.zig");
const extensions = @import("extensions.zig");
const alert = @import("alert.zig");
const tooltip = @import("tooltip.zig");
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
timer: u32,

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

    fn toTitle(sorting: Sorting) []const u8 {
        return switch (sorting) {
            .name => "Name",
            .ext => "Type",
            .created => "Created",
            .modified => "Modified",
            .size => "Size",
        };
    }
};

const Entry = struct {
    name: [2]u32,
    size: u64,
    selected: bool,
    created: ?Timespan,
    modified: Timespan,
    created_millis: ?u64,
    modified_millis: u64,
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
        reverse: bool,

        pub fn next(self: *@This()) ?Item {
            if (self.sort_list.len == 0) return null;
            const next_index = if (self.reverse) self.sort_list.len - 1 else 0;
            var item: Item = undefined;
            inline for (fields) |field| {
                const value = self.slice.items(field)[self.sort_list[next_index]];
                @field(item, @tagName(field)) = if (field == .name) self.names[value[0]..value[1]] else value;
            }
            item.index = self.sort_list[next_index];
            self.sort_list = if (self.reverse) self.sort_list[0 .. self.sort_list.len - 1] else self.sort_list[1..];
            return item;
        }
    };
}

var file_types = std.StaticStringMapWithEql(
    []const u8,
    std.static_string_map.eqlAsciiIgnoreCase,
).initComptime(extensions.data);

const container_id = main.newId("EntriesContainer");
const entries_id = main.newId("Entries");

const ext_len = 6;
const char_px_width = 10; // not monospaced font, so this is just an approximation
const entries_x_offset = 455; // TODO this includes shortcut width
const entries_y_offset = 104;
const min_name_chars = 16;
const max_name_chars = 32;
const type_chars = 12;
const size_chars = 16;
const timespan_chars = 20;

fn getSizing(chars: comptime_int) clay.Element.Sizing {
    return .{
        .width = clay.Element.Sizing.Axis.fit(.{
            .min = chars * char_px_width,
            .max = chars * char_px_width,
        }),
    };
}
const type_sizing = getSizing(type_chars);
const size_sizing = getSizing(size_chars);
const timespan_sizing = getSizing(timespan_chars);

const SYSTEMTIME = extern struct {
    wYear: os.windows.WORD,
    wMonth: os.windows.WORD,
    wDayOfWeek: os.windows.WORD,
    wDay: os.windows.WORD,
    wHour: os.windows.WORD,
    wMinute: os.windows.WORD,
    wSecond: os.windows.WORD,
    wMilliseconds: os.windows.WORD,
};
const TIME_ZONE_INFORMATION = extern struct {
    Bias: os.windows.LONG,
    StandardName: [32]os.windows.WCHAR,
    StandardDate: SYSTEMTIME,
    StandardBias: os.windows.LONG,
    DaylightName: [32]os.windows.WCHAR,
    DaylightDate: SYSTEMTIME,
    DaylightBias: os.windows.LONG,
};
extern fn GetTimeZoneInformation(lpTimeZoneInformation: [*c]TIME_ZONE_INFORMATION) os.windows.DWORD;

fn kinds() []const Kind {
    return enums.values(Kind);
}

fn getEntryId(comptime kind: Kind, comptime suffix: []const u8, index: Index) clay.Element.Config.Id {
    comptime var kind_name = @tagName(kind).*;
    kind_name[0] = comptime ascii.toUpper(kind_name[0]);
    return main.newIdIndexed(kind_name[0..] ++ "Entry" ++ suffix, index);
}

fn getColumnId(comptime title: []const u8, comptime suffix: []const u8) clay.Element.Config.Id {
    return main.newId("EntriesColumn" ++ title ++ suffix);
}

// TODO currently always puts entry at top or highest it can.
// should instead do nothing if entry already in frame,
// if entry coming from above put it on top,
// if entry from below put it on bottom
fn scrollToView(comptime kind: Kind, index: Index) void {
    const container = clay.getScrollContainerData(entries_id);
    if (!container.found) return;
    container.scroll_position.y += entries_y_offset;
    const bounds = main.getBounds(getEntryId(kind, "", index)) orelse return;
    container.scroll_position.y -= bounds.y;
    const dist_to_bottom = container.content_dimensions.height + container.scroll_position.y;
    if (dist_to_bottom < container.scroll_container_dimensions.height) {
        container.scroll_position.y += container.scroll_container_dimensions.height - dist_to_bottom;
    }
}

fn intToString(n: u7) []const u8 {
    const one_digit = "0123456789";
    const two_digits =
        "____________________10111213141516171819" ++
        "2021222324252627282930313233343536373839" ++
        "4041424344454647484950515253545556575859" ++
        "6061626364656667686970717273747576777879" ++
        "8081828384858687888990919293949596979899";
    return if (n < 10) one_digit[n..][0..1] else two_digits[n * 2 ..][0..2];
}

fn nanosToMillis(nanos: i128) u64 {
    return math.lossyCast(u64, @divTrunc(nanos, time.ns_per_ms));
}

fn printDate(millis: u64, writer: anytype) Model.Error!void {
    const GetTimezone = struct {
        var bias: ?i32 = null;

        fn getTimezone() void {
            if (main.windows) {
                var timezone_info = mem.zeroes(TIME_ZONE_INFORMATION);
                switch (GetTimeZoneInformation(&timezone_info)) {
                    0, 1, 2 => bias = timezone_info.Bias,
                    else => alert.updateFmt("Failed to get timezone.", .{}),
                }
            }
        }
    };
    var once = std.once(GetTimezone.getTimezone);
    once.call();
    const datetime = Datetime.fromTimestamp(math.lossyCast(i64, millis)).shiftMinutes(-(GetTimezone.bias orelse 0));
    const hour = switch (datetime.time.hour) {
        0 => 12,
        1...12 => datetime.time.hour,
        13...24 => datetime.time.hour - 12,
        else => unreachable,
    };
    writer.print("{s}, {s} {} {} at {}:{:0>2} {s}", .{
        datetime.date.weekdayName(),
        datetime.date.monthName(),
        datetime.date.day,
        datetime.date.year,
        hour,
        datetime.time.minute,
        datetime.time.amOrPm(),
    }) catch return Model.Error.OutOfMemory;
}

pub fn init() Model.Error!Entries {
    const expected_entries = 128;

    var entries = Entries{
        .data = meta.FieldType(Entries, .data).initFill(.{}),
        .data_slices = meta.FieldType(Entries, .data_slices).initUndefined(),
        .names = try meta.FieldType(Entries, .names).initCapacity(main.alloc, expected_entries * 8),
        .sizes = try meta.FieldType(Entries, .sizes).initCapacity(main.alloc, expected_entries),
        .sortings = meta.FieldType(Entries, .sortings)
            .initFill(@TypeOf(meta.FieldType(Entries, .sortings).initUndefined().get(undefined)).initFill(.{})),
        .curr_sorting = .name,
        .sort_type = .asc,
        .max_name_len = 0,
        .timer = 0,
    };
    for (&entries.data.values) |*data| {
        data.ensureTotalCapacity(main.alloc, expected_entries) catch return Model.Error.OutOfMemory;
    }

    return entries;
}

pub fn deinit(entries: *Entries) void {
    for (&entries.data.values) |*data| data.deinit(main.alloc);
    entries.names.deinit(main.alloc);
    entries.sizes.deinit(main.alloc);
    for (&entries.sortings.values) |*sort_lists| for (&sort_lists.values) |*sort_list| sort_list.deinit(main.alloc);
}

pub fn update(entries: *Entries, input: Input) Model.Error!?Message {
    if (!clay.pointerOver(container_id)) return null;
    entries.timer +|= input.delta_ms;

    if (input.clicked(.left)) {
        inline for (comptime enums.values(Sorting)) |sorting| {
            if (clay.pointerOver(getColumnId(sorting.toTitle(), ""))) {
                if (entries.curr_sorting == sorting) {
                    entries.sort_type = if (entries.sort_type == .asc) .desc else .asc;
                } else {
                    try entries.sort(sorting);
                    entries.sort_type = .asc;
                }
                return null;
            }
        }
        inline for (comptime kinds()) |kind| {
            var sorted_iter = entries.sorted(kind, &.{});
            var sorted_index: Index = 0;
            while (sorted_iter.next()) |entry| : (sorted_index += 1) {
                if (clay.pointerOver(getEntryId(kind, "", sorted_index))) {
                    return entries.select(
                        kind,
                        entry.index,
                        true,
                        if (input.ctrl) .multi else if (input.shift) .bulk else .single,
                    );
                }
            }
        }
    } else if (input.action) |action| {
        switch (action) {
            .mouse, .event => {},
            .key => |key| switch (key) {
                .char => |char| entries.jump(char),

                //TODO nav buttons

                else => {},
            },
        }
    } else {
        if (tooltip.update(input)) |writer| {
            inline for (comptime kinds()) |kind| {
                var sorted_iter = entries.sorted(kind, &.{});
                var sorted_index: Index = 0;
                while (sorted_iter.next()) |entry| : (sorted_index += 1) {
                    if (clay.pointerOver(getEntryId(kind, "Name", sorted_index))) {
                        const start, const end = entries.data_slices.get(kind).items(.name)[entry.index];
                        if (end - start > max_name_chars) {
                            writer.writeAll(entries.names.items[start..end]) catch return Model.Error.OutOfMemory;
                        }
                    } else if (clay.pointerOver(getEntryId(kind, "Type", sorted_index))) {
                        if (kind == .file) {
                            const start, const end = entries.data_slices.get(kind).items(.name)[entry.index];
                            const extension = fs.path.extension(entries.names.items[start..end]);
                            const file_type = if (extension.len > 0)
                                if (extension.len > ext_len) "" else file_types.get(extension[1..]) orelse ""
                            else
                                "";
                            writer.writeAll(file_type) catch return Model.Error.OutOfMemory;
                        }
                    } else if (clay.pointerOver(getEntryId(kind, "Size", sorted_index))) {
                        const size = entries.data_slices.get(kind).items(.size)[entry.index];
                        if (size > 1000) writer.print("{} bytes", .{size}) catch return Model.Error.OutOfMemory;
                    } else if (clay.pointerOver(getEntryId(kind, "Created", sorted_index))) {
                        if (entries.data_slices.get(kind).items(.created_millis)[entry.index]) |created_millis| {
                            try printDate(created_millis, writer);
                        }
                    } else if (clay.pointerOver(getEntryId(kind, "Modified", sorted_index))) {
                        try printDate(entries.data_slices.get(kind).items(.modified_millis)[entry.index], writer);
                    }
                }
            }
        }
    }
    return null;
}

pub fn render(entries: Entries) void {
    const width: usize = @intCast(rl.getScreenWidth());
    const shortcuts_width = 280; // TODO
    const name_chars: usize = @max(@min(entries.max_name_len, max_name_chars), min_name_chars);
    const name_sizing = clay.Element.Sizing{
        .width = clay.Element.Sizing.Axis.fixed(@floatFromInt(name_chars * char_px_width)),
    };

    clay.ui()(.{
        .id = container_id,
        .layout = .{
            .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 10 },
            .sizing = .{
                .width = clay.Element.Sizing.Axis.grow(.{}),
                .height = clay.Element.Sizing.Axis.grow(.{}),
            },
            .layout_direction = .top_to_bottom,
        },
        .scroll = .{ .horizontal = true },
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
                fn f(passed_entries: Entries, comptime sorting: Sorting, sizing: clay.Element.Sizing) void {
                    const title = comptime sorting.toTitle();
                    const id = getColumnId(title, "");
                    clay.ui()(.{
                        .id = id,
                        .layout = .{
                            .padding = clay.Padding.xy(10, 6),
                            .sizing = sizing,
                            .child_gap = 6,
                        },
                        .rectangle = .{
                            .color = if (clay.pointerOver(id)) main.theme.hovered else main.theme.mantle,
                            .corner_radius = main.rounded,
                        },
                    })({
                        main.pointer();
                        main.text(title);

                        clay.ui()(.{
                            .id = getColumnId(title, "Sort"),
                            .layout = .{
                                .sizing = .{ .width = clay.Element.Sizing.Axis.fixed(20) },
                            },
                            .image = if (passed_entries.curr_sorting == sorting) .{
                                .image_data = if (passed_entries.sort_type == .asc)
                                    &resources.images.sort_asc
                                else
                                    &resources.images.sort_desc,
                                .source_dimensions = clay.Dimensions.square(20),
                            } else null,
                        })({});
                    });
                }
            }.f;

            var cutoff: usize = entries_x_offset;

            column(entries, .name, name_sizing);
            cutoff += name_chars * char_px_width;

            if (width > cutoff) column(entries, .ext, type_sizing);
            cutoff += type_chars * char_px_width;

            if (width > cutoff) column(entries, .size, size_sizing);
            cutoff += size_chars * char_px_width;

            if (width > cutoff) column(entries, .created, timespan_sizing);
            cutoff += timespan_chars * char_px_width;

            if (width > cutoff) column(entries, .modified, timespan_sizing);
        });

        clay.ui()(.{
            .id = entries_id,
            .layout = .{
                .padding = clay.Padding.all(10),
                .sizing = .{
                    .width = clay.Element.Sizing.Axis.grow(.{ .max = @floatFromInt(width - shortcuts_width) }),
                    .height = clay.Element.Sizing.Axis.grow(.{ .max = 1 }), // hacky fix for element leaking off-screen
                },
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
                            .color = if (entry.selected)
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

                        var cutoff: usize = entries_x_offset;

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
                        cutoff += name_chars * char_px_width;

                        if (width > cutoff) {
                            clay.ui()(.{
                                .id = getEntryId(kind, "Type", sorted_index),
                                .layout = .{
                                    .padding = clay.Padding.all(6),
                                    .sizing = type_sizing,
                                },
                            })({
                                if (kind == .file) {
                                    const extension = fs.path.extension(entry.name);
                                    if (extension.len > 0 and extension.len <= ext_len) {
                                        if (file_types.getIndex(extension[1..])) |i| {
                                            main.text(file_types.kvs.keys[i]);
                                        } else {
                                            main.text(extension[1..]);
                                        }
                                    }
                                }
                            });
                        }
                        cutoff += type_chars * char_px_width;

                        if (width > cutoff) {
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
                        }
                        cutoff += size_chars * char_px_width;

                        if (width > cutoff) {
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
                                            main.text(intToString(timespan.count));
                                            main.text(timespan.metric.toString(timespan.count != 1));
                                        },
                                    }
                                } else main.text("");
                            });
                        }
                        cutoff += timespan_chars * char_px_width;

                        if (width > cutoff) {
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
                                        main.text(intToString(timespan.count));
                                        main.text(timespan.metric.toString(timespan.count != 1));
                                    },
                                }
                            });
                        }
                    });
                }
            }
        });
    });
}

pub fn loadEntries(entries: *Entries, path: []const u8) Model.Error!void {
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

        if (!is_dir) {
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
        }

        const data = entries.data.getPtr(if (is_dir) .dir else .file);
        try data.append(
            main.alloc,
            .{
                .name = .{ @intCast(start_index), @intCast(entries.names.items.len) },
                .size = metadata.size(),
                .selected = false,
                .created = if (metadata.created()) |created| Timespan.fromNanos(now - created) else null,
                .modified = Timespan.fromNanos(now - metadata.modified()),
                .created_millis = if (metadata.created()) |created| nanosToMillis(created) else null,
                .modified_millis = nanosToMillis(metadata.modified()),
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
        .reverse = entries.sort_type == .desc,
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
                        .ext => return if (kind == .dir)
                            ascii.lessThanIgnoreCase(
                                getName(passed_entries, lhs),
                                getName(passed_entries, rhs),
                            )
                        else {
                            const lhs_ext = fs.path.extension(getName(passed_entries, lhs));
                            const rhs_ext = fs.path.extension(getName(passed_entries, rhs));
                            return ascii.lessThanIgnoreCase(
                                if (lhs_ext.len > ext_len) "" else lhs_ext,
                                if (rhs_ext.len > ext_len) "" else rhs_ext,
                            );
                        },
                        .created => {
                            const created = passed_entries.data_slices.get(kind).items(.created_millis);
                            return created[lhs] orelse 0 < created[rhs] orelse 0;
                        },
                        .modified => {
                            const modified = passed_entries.data_slices.get(kind).items(.modified_millis);
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
    const selected = &entries.data_slices.get(kind).items(.selected)[index];

    if (clicked and entries.timer < main.double_click_delay and selected.*) {
        const name_start, const name_end = entries.data_slices.get(kind).items(.name)[index];
        const name = entries.names.items[name_start..name_end];
        return switch (kind) {
            .dir => .{ .open_dir = name },
            .file => .{ .open_file = name },
        };
    }
    entries.timer = 0;

    switch (select_type) {
        .single => {
            for (entries.data_slices.values) |slice| {
                for (slice.items(.selected)) |*unselect| unselect.* = false;
            }
            selected.* = true;
        },
        .multi => selected.* = !selected.*,
        .bulk => {
            var maybe_nearest: ?struct { Kind, Index } = null;
            var break_next = false;
            find_nearest: inline for (comptime kinds()) |kind_inner| {
                var sorted_iter = entries.sorted(kind_inner, &.{.selected});
                var sorted_index: Index = 0;
                while (sorted_iter.next()) |entry| : (sorted_index += 1) {
                    if (kind_inner == kind and entry.index == index) {
                        if (maybe_nearest != null) break :find_nearest;
                        break_next = true;
                    } else if (entry.selected) {
                        maybe_nearest = .{ kind_inner, sorted_index };
                        if (break_next) break :find_nearest;
                    }
                }
            }
            if (maybe_nearest) |nearest| {
                const nearest_kind, const nearest_index = nearest;
                var selecting = false;
                bulk_select: inline for (comptime kinds()) |kind_inner| {
                    var sorted_iter = entries.sorted(kind_inner, &.{});
                    var sorted_index: Index = 0;
                    while (sorted_iter.next()) |entry| : (sorted_index += 1) {
                        const found_nearest = kind_inner == nearest_kind and sorted_index == nearest_index;
                        const found_selected = kind_inner == kind and entry.index == index;
                        if (found_nearest or found_selected) {
                            if (selecting) {
                                entries.data_slices.get(kind_inner).items(.selected)[entry.index] = true;
                                break :bulk_select;
                            }
                            selecting = true;
                        }
                        if (selecting) {
                            entries.data_slices.get(kind_inner).items(.selected)[entry.index] = true;
                        }
                    }
                }
            } else {
                selected.* = true;
            }
        },
    }

    return null;
}

fn jump(entries: *Entries, char: u8) void {
    var first: ?struct { Kind, Index } = null;
    var found_selected = false;
    inline for (comptime kinds()) |kind| {
        var sorted_entries = entries.sorted(kind, &.{ .name, .selected });
        var sorted_index: Index = 0;
        while (sorted_entries.next()) |entry| : (sorted_index += 1) {
            if (ascii.startsWithIgnoreCase(entry.name, &.{char})) {
                const selected = &entries.data_slices.get(kind).items(.selected)[entry.index];
                if (first == null) first = .{ kind, sorted_index };
                if (selected.*) {
                    found_selected = true;
                } else if (found_selected) {
                    for (entries.data_slices.values) |slice| {
                        for (slice.items(.selected)) |*unselect| unselect.* = false;
                    }
                    selected.* = true;
                    scrollToView(kind, sorted_index);
                    return;
                }
            }
        }
    }
    const kind, const index = first orelse return;
    for (entries.data_slices.values) |slice| {
        for (slice.items(.selected)) |*unselect| unselect.* = false;
    }
    entries.data_slices.get(kind).items(.selected)[index] = true;
    switch (kind) {
        inline else => |kind_inner| scrollToView(kind_inner, index),
    }
}
