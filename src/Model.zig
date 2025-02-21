const std = @import("std");
const fs = std.fs;
const time = std.time;
const heap = std.heap;
const fmt = std.fmt;
const mem = std.mem;
const meta = std.meta;
const math = std.math;
const enums = std.enums;
const process = std.process;
const builtin = std.builtin;

const rl = @import("raylib");

const main = @import("main.zig");
const alloc = main.alloc;
const debug = main.debug;
const windows = main.windows;

cwd: Bytes,
entries: Entries,

const Model = @This();

const Bytes = std.ArrayListUnmanaged(u8);
const Millis = i64;
pub const Index = u16;

const double_click: Millis = 300;

pub const Error = error{
    OsNotSupported,
    OutOfBounds,
    OpenDirFailure,
} || mem.Allocator.Error || process.Child.SpawnError;

pub fn init() !Model {
    var model = Model{
        .cwd = try Bytes.initCapacity(alloc, 1024),
        .entries = .{
            .data = meta.FieldType(Entries, .data).initFill(.{}),
            .data_slices = meta.FieldType(Entries, .data_slices).initUndefined(),
            .names = try Bytes.initCapacity(alloc, 1024),
            .sortings = meta.FieldType(Entries, .sortings)
                .initFill(@TypeOf(meta.FieldType(Entries, .sortings).initUndefined().get(undefined)).initFill(.{})),
            .curr_sorting = .name,
            .sort_type = .asc,
        },
    };
    errdefer model.deinit();

    const path = try fs.realpathAlloc(alloc, ".");
    defer alloc.free(path);
    try model.cwd.appendSlice(alloc, path);

    try model.entries.refresh(path);

    return model;
}

pub fn deinit(model: *Model) void {
    model.cwd.deinit(alloc);
    model.entries.deinit();
}

pub fn select(model: *Model, kind: Entries.Kind, index: Index, action: enum { touch, try_open }) Error!void {
    const selected = model.entries.data_slices.get(kind).items(.selected);
    if (selected.len <= index) return Error.OutOfBounds;

    const now = time.milliTimestamp();
    if (selected[index]) |selected_ts| {
        if (action == .try_open and (now - selected_ts) < double_click) {
            return if (kind == .dir) model.open_dir(index) else model.open_file(index);
        }
    }

    if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
        // TODO bulk selection
    }
    if (!rl.isKeyDown(.left_control) and !rl.isKeyDown(.right_control)) {
        for (model.entries.data_slices.values) |slice| {
            for (slice.items(.selected)) |*unselect| unselect.* = null;
        }
    }
    selected[index] = now;
}

pub fn open_dir(model: *Model, index: Index) Error!void {
    const name_start, const name_end = model.entries.data_slices.get(.dir).items(.name)[index];
    const name = model.entries.names.items[name_start..name_end];
    try model.cwd.append(alloc, fs.path.sep);
    try model.cwd.appendSlice(alloc, name);
    try model.entries.refresh(model.cwd.items);
}

pub fn open_parent_dir(model: *Model) Error!void {
    const parent_dir_path = fs.path.dirname(model.cwd.items) orelse return;
    model.cwd.shrinkRetainingCapacity(parent_dir_path.len);
    try model.entries.refresh(model.cwd.items);
}

pub fn open_file(model: *const Model, index: Index) Error!void {
    const name_start, const name_end = model.entries.data_slices.get(.file).items(.name)[index];
    const name = model.entries.names.items[name_start..name_end];
    const path = try mem.join(alloc, fs.path.sep_str, &[_][]const u8{ model.cwd.items, name });
    defer alloc.free(path);
    const invoker = if (windows)
        .{ "cmd", "/c", "start" }
    else
        return Error.OsNotSupported;
    const argv = invoker ++ .{path};

    var child = process.Child.init(&argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = model.cwd.items;
    _ = try child.spawnAndWait();
}

pub const Entries = struct {
    data: std.EnumArray(Kind, std.MultiArrayList(Entry)),
    data_slices: std.EnumArray(Kind, std.MultiArrayList(Entry).Slice),
    names: Bytes,
    sortings: std.EnumArray(Sorting, std.EnumArray(Kind, std.ArrayListUnmanaged(Index))),
    curr_sorting: Sorting,
    sort_type: enum { asc, desc },

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
        for (&entries.data.values) |*data| data.deinit(alloc);
        entries.names.deinit(alloc);
        for (&entries.sortings.values) |*sort_lists| for (&sort_lists.values) |*sort_list| sort_list.deinit(alloc);
    }

    pub fn kinds() []const Kind {
        return enums.values(Kind);
    }

    fn refresh(entries: *Entries, cwd: []const u8) Error!void {
        for (&entries.data.values) |*data| data.shrinkRetainingCapacity(0);
        entries.names.clearRetainingCapacity();
        for (&entries.sortings.values) |*sort_lists| for (&sort_lists.values) |*sort_list| sort_list.clearRetainingCapacity();

        const dir = fs.openDirAbsolute(cwd, .{ .iterate = true }) catch return Error.OpenDirFailure;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.name.len == 0) continue;
            const start_index = entries.names.items.len;
            entries.names.appendSlice(alloc, entry.name) catch break;
            const is_dir = entry.kind == .directory;
            const metadata = if (is_dir)
                (dir.openDir(entry.name, .{ .access_sub_paths = false }) catch continue).metadata() catch continue
            else
                (dir.openFile(entry.name, .{}) catch continue).metadata() catch continue;

            const data = entries.data.getPtr(if (is_dir) .dir else .file);
            data.append(
                alloc,
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

    pub fn sort(entries: *Entries, comptime sorting: Sorting) Error!void {
        const sort_lists = entries.sortings.getPtr(sorting);

        inline for (comptime kinds()) |kind| {
            const sort_list = sort_lists.getPtr(kind);
            if (sort_list.items.len == 0) { // non-zero means either already sorted or empty dir
                const len = entries.data.get(kind).len;
                try sort_list.ensureTotalCapacity(alloc, len);
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
};

pub fn format(model: *const Model, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try fmt.format(writer, "cwd: {s}\n", .{model.cwd.items});
    for (Entries.kinds()) |kind| {
        try fmt.format(writer, "{s}s:\n", .{@tagName(kind)});
        for (0..model.entries.data.get(kind).len) |i| {
            const name_start, const name_end = model.entries.data_slices.get(kind).items(.name)[i];
            const name = model.entries.names.items[name_start..name_end];
            try fmt.format(writer, "\t{d}) {s}\n", .{ i + 1, name });
        }
    }
}
