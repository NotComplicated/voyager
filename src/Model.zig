const std = @import("std");
const fs = std.fs;
const time = std.time;

const Model = @This();

const max_entries = 16;
const max_entry_name = 32;

cwd: std.BoundedArray(u8, fs.max_path_bytes),
entries: std.BoundedArray(Entry, max_entries),

pub fn init() !Model {
    var self = Model{
        .cwd = try std.BoundedArray(u8, fs.max_path_bytes).init(0),
        .entries = try std.BoundedArray(Entry, max_entries).init(0),
    };

    const len = (try fs.realpath(".", &self.cwd.buffer)).len;
    try self.cwd.resize(len);

    const dir = try fs.openDirAbsolute(self.cwd.slice(), .{ .iterate = true });
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (self.entries.len == self.entries.capacity()) {
            break;
        }
        var name = try std.BoundedArray(u8, max_entry_name).init(0);
        name.appendSlice(entry.name) catch try name.appendSlice(entry.name[0..max_entry_name]);
        const is_dir = entry.kind == .directory;
        const metadata = if (is_dir)
            try (try dir.openDir(entry.name, .{ .access_sub_paths = false })).metadata()
        else
            try (try dir.openFile(entry.name, .{})).metadata();

        try self.entries.append(.{
            .is_dir = is_dir,
            .name = name,
            .created = metadata.created(),
            .modified = metadata.modified(),
            .size = metadata.size(),
            .readonly = metadata.permissions().readOnly(),
        });
    }

    return self;
}

const Entry = struct {
    is_dir: bool,
    name: std.BoundedArray(u8, max_entry_name),
    created: ?i128,
    modified: i128,
    size: u64,
    readonly: bool,
};
