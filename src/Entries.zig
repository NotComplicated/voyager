const std = @import("std");
const builtin = std.builtin;
const enums = std.enums;
const meta = std.meta;
const math = std.math;
const time = std.time;
const mem = std.mem;
const fs = std.fs;

const main = @import("main.zig");
const Bytes = main.Bytes;
const Millis = main.Millis;
const Message = @import("message.zig").Message;
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

pub fn kinds() []const Kind {
    return enums.values(Kind);
}

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

    pub fn handleInput(entry: Entry, input: Input) ?Message {
        _ = entry;
        _ = input;
    }

    pub fn handleMessage(entry: *Entry, message: Message) Model.Error!void {
        _ = entry;
        _ = message;
    }

    pub fn render(entry: Entry) void {
        _ = entry;
    }
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

fn deinit(entries: *Entries) void {
    for (&entries.data.values) |*data| data.deinit(main.alloc);
    entries.names.deinit(main.alloc);
    for (&entries.sortings.values) |*sort_lists| for (&sort_lists.values) |*sort_list| sort_list.deinit(main.alloc);
}

pub fn handleInput(entries: Entries, input: Input) ?Message {
    _ = entries;
    _ = input;
}

pub fn handleMessage(entries: *Entries, message: Message) Model.Error!void {
    _ = entries;
    _ = message;
}

pub fn render(entries: Entries) void {
    _ = entries;
}

pub fn load_entries(entries: *Entries, cwd: []const u8) Model.Error!void {
    if (!fs.path.isAbsolute(cwd)) return Model.Error.OpenDirFailure;
    const dir = fs.openDirAbsolute(cwd, .{ .iterate = true }) catch |err|
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
                .created = if (metadata.created()) |created| nanos_to_millis(created) else null,
                .modified = nanos_to_millis(metadata.modified()),
                .size = metadata.size(),
                .readonly = metadata.permissions().readOnly(),
            },
        ) catch break;
        if (data.len == math.maxInt(Index)) break;
    }

    for (entries.data.values, &entries.data_slices.values) |data, *data_slice| data_slice.* = data.slice();
    try entries.sort(.name);
    entries.sort_type = .asc;
}

fn nanos_to_millis(nanos: i128) Millis {
    return @intCast(@divFloor(nanos, time.ns_per_ms));
}

pub fn sorted(entries: *const Entries, kind: Kind, comptime fields: []const meta.FieldEnum(Entry)) SortedIterator(fields) {
    return .{
        .sort_list = entries.sortings.get(entries.curr_sorting).get(kind).items,
        .slice = entries.data_slices.get(kind),
        .names = entries.names.items,
    };
}

pub fn sort(entries: *Entries, comptime sorting: Sorting) Model.Error!void {
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

pub fn try_jump(entries: *Entries, char: u8) enum { jumped, not_found } {
    for (kinds()) |kind| {
        var sorted_entries = entries.sorted(kind, &.{ .name, .selected });
        while (sorted_entries.next()) |entry| {
            if (entry.name[0] == char) {
                for (entries.data_slices.values) |slice| {
                    for (slice.items(.selected)) |*unselect| unselect.* = null;
                }
                entries.data_slices.get(kind).items(.selected)[entry.index] = time.milliTimestamp();
                return .jumped;
            }
        }
    }
    return .not_found;
}

pub fn toggle_sort_type(entries: *Entries) void {
    entries.sort_type = if (entries.sort_type == .asc) .desc else .asc;
}
