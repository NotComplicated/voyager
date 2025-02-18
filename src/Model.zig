const std = @import("std");
const fs = std.fs;
const time = std.time;
const heap = std.heap;
const fmt = std.fmt;

const main = @import("main.zig");
const alloc = main.alloc;
const debug = main.debug;

cwd: Bytes,
entries: Entries,

const Model = @This();

const Bytes = std.ArrayListUnmanaged(u8);

pub fn init() !Model {
    var model = Model{
        .cwd = try Bytes.initCapacity(alloc, 1024),
        .entries = .{
            .names = try Bytes.initCapacity(alloc, 1024),
            .list = .{},
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

pub fn open_dir(model: *Model, entry_index: usize) !void {
    const dirname = model.entries.list.items(.name)[entry_index];
    try model.cwd.append(alloc, fs.path.sep);
    try model.cwd.appendSlice(alloc, dirname);

    try model.entries.refresh(model.cwd.items);
}

const Entries = struct {
    names: Bytes,
    list: std.MultiArrayList(Entry),

    const Entry = struct {
        name: []const u8,
        is_dir: bool,
        created: ?i128,
        modified: i128,
        size: u64,
        readonly: bool,
    };

    fn deinit(entries: *Entries) void {
        entries.names.deinit(alloc);
        entries.list.deinit(alloc);
    }

    fn refresh(entries: *Entries, cwd: []const u8) !void {
        entries.names.clearRetainingCapacity();
        entries.list.shrinkRetainingCapacity(0);

        const dir = try fs.openDirAbsolute(cwd, .{ .iterate = true });
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            try entries.names.appendSlice(alloc, entry.name);
            const is_dir = entry.kind == .directory;
            const metadata = if (is_dir)
                try (try dir.openDir(entry.name, .{ .access_sub_paths = false })).metadata()
            else
                try (try dir.openFile(entry.name, .{})).metadata();

            try entries.list.append(
                alloc,
                .{
                    .name = entries.names.items[entries.names.items.len - entry.name.len ..],
                    .is_dir = is_dir,
                    .created = metadata.created(),
                    .modified = metadata.modified(),
                    .size = metadata.size(),
                    .readonly = metadata.permissions().readOnly(),
                },
            );
        }
    }
};

pub fn format(model: *Model, comptime fmt_string: []const u8, options: fmt.FormatOptions, writer: anytype) !void {
    _ = fmt_string;
    _ = options;
    try fmt.format(writer, "cwd: {s}\nitems:", .{model.cwd.items});
    for (model.entries.list.items(.name)) |name| {
        try fmt.format(writer, "\n\t{s}", .{name});
    }
}
