const std = @import("std");
const fs = std.fs;
const time = std.time;
const heap = std.heap;
const fmt = std.fmt;
const mem = std.mem;

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

const double_click: Millis = 300;

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

pub fn select(model: *Model, entry_index: usize, open_entry: bool) !void {
    const selected = model.entries.list.items(.selected);
    if (selected.len <= entry_index) return;

    const now = time.milliTimestamp();
    if (selected[entry_index]) |selected_ts| {
        if (open_entry and (now - selected_ts) < double_click) {
            return model.open(entry_index);
        }
    }

    if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
        // TODO bulk selection
    }
    if (!rl.isKeyDown(.left_control) and !rl.isKeyDown(.right_control)) {
        for (selected) |*unselect| unselect.* = null;
    }
    selected[entry_index] = now;
}

pub fn try_jump(model: *Model, char: u8) bool {
    const selected = model.entries.list.items(.selected);
    for (model.entries.list.items(.name_indices), 0..) |name_indices, index| {
        const name = model.entries.get_name(name_indices);
        if (name[0] == char) {
            for (selected) |*unselect| unselect.* = null;
            selected[index] = time.milliTimestamp();
            return true;
        }
    }
    return false;
}

pub fn open(model: *Model, entry_index: usize) !void {
    const name = model.entries.get_name(model.entries.list.items(.name_indices)[entry_index]);
    if (model.entries.list.items(.is_dir)[entry_index]) {
        try model.cwd.append(alloc, fs.path.sep);
        try model.cwd.appendSlice(alloc, name);

        try model.entries.refresh(model.cwd.items);
    } else {
        const path = try mem.join(alloc, fs.path.sep_str, &[_][]const u8{ model.cwd.items, name });
        defer alloc.free(path);
        const invoker = if (windows)
            .{ "cmd", "/c", "start" }
        else
            @panic("OS not yet supported");
        const argv = invoker ++ .{path};

        var child = std.process.Child.init(&argv, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.cwd = model.cwd.items;
        _ = try child.spawnAndWait();
    }
}

pub fn open_parent_dir(model: *Model) !void {
    const parent_dir_path = fs.path.dirname(model.cwd.items) orelse return;
    model.cwd.shrinkRetainingCapacity(parent_dir_path.len);

    try model.entries.refresh(model.cwd.items);
}

const Entries = struct {
    names: Bytes,
    list: std.MultiArrayList(Entry),

    const Entry = struct {
        name_indices: [2]u32,
        is_dir: bool,
        selected: ?Millis,
        created: ?Millis,
        modified: Millis,
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
            const name_start = entries.names.items.len;
            try entries.names.appendSlice(alloc, entry.name);
            const is_dir = entry.kind == .directory;
            const metadata = if (is_dir)
                try (dir.openDir(entry.name, .{ .access_sub_paths = false }) catch continue).metadata()
            else
                try (dir.openFile(entry.name, .{}) catch continue).metadata();

            try entries.list.append(
                alloc,
                .{
                    .name_indices = .{ @intCast(name_start), @intCast(entries.names.items.len) },
                    .is_dir = is_dir,
                    .selected = null,
                    .created = if (metadata.created()) |created| nanos_to_millis(created) else null,
                    .modified = nanos_to_millis(metadata.modified()),
                    .size = metadata.size(),
                    .readonly = metadata.permissions().readOnly(),
                },
            );
        }
    }

    fn nanos_to_millis(nanos: i128) Millis {
        return @intCast(@divFloor(nanos, time.ns_per_ms));
    }

    pub fn get_name(entries: *const Entries, name_indices: [2]u32) []const u8 {
        return entries.names.items[name_indices[0]..name_indices[1]];
    }
};

pub fn format(model: *const Model, comptime fmt_string: []const u8, options: fmt.FormatOptions, writer: anytype) !void {
    _ = fmt_string;
    _ = options;
    try fmt.format(writer, "cwd: {s}\nitems:", .{model.cwd.items});
    const entries = model.entries.list.slice();
    for (0..entries.len) |i| {
        try fmt.format(writer, "\n\t{s} {s} {d}", .{
            model.entries.get_name(entries.items(.name_indices)[i]),
            if (entries.items(.is_dir)[i]) "(dir)" else "",
            i,
        });
    }
}
