const std = @import("std");
const process = std.process;
const unicode = std.unicode;
const enums = std.enums;
const time = std.time;
const math = std.math;
const meta = std.meta;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const fs = std.fs;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const windows = @import("windows.zig");
const resources = @import("resources.zig");
const alert = @import("alert.zig");
const Input = @import("Input.zig");
const TextBox = @import("text_box.zig").TextBox;
const Entries = @import("Entries.zig");

cwd: TextBox(.path, main.newId("CurrentDir")),
entries: Entries,

const Model = @This();

pub const Error = error{
    OutOfMemory,
    OsNotSupported,
    OutOfBounds,
    OpenDirFailure,
    DirAccessDenied,
    DeleteDirFailure,
    DeleteFileFailure,
};

pub const row_height = 30;
const max_paste_len = 1024;
const nav_buttons = .{
    .parent = main.newId("Parent"),
    .refresh = main.newId("Refresh"),
    .vscode = main.newId("VsCode"),
};

fn renderNavButton(id: clay.Element.Config.Id, icon: *rl.Texture) void {
    clay.ui()(.{
        .id = id,
        .layout = .{ .sizing = clay.Element.Sizing.fixed(row_height) },
        .image = .{
            .image_data = icon,
            .source_dimensions = clay.Dimensions.square(row_height),
        },
        .rectangle = .{
            .color = if (clay.pointerOver(id)) main.theme.hovered else main.theme.base,
            .corner_radius = main.rounded,
        },
    })({
        main.pointer();
    });
}

pub fn init() Error!Model {
    var model = Model{
        .cwd = try meta.FieldType(Model, .cwd).init(),
        .entries = try Entries.init(),
    };
    errdefer model.deinit();

    try model.entries.loadEntries(model.cwd.value());

    return model;
}

pub fn deinit(model: *Model) void {
    model.cwd.deinit();
    model.entries.deinit();
}

pub fn update(model: *Model, input: Input) Error!void {
    if (main.is_debug and input.clicked(.middle)) {
        log.debug("{}\n", .{model});
    } else if (input.clicked(.side)) {
        try model.openParentDir();
    } else if (input.clicked(.left)) {
        inline for (comptime enums.values(meta.FieldEnum(@TypeOf(nav_buttons)))) |button| {
            if (clay.pointerOver(@field(nav_buttons, @tagName(button)))) {
                switch (button) {
                    .parent => try model.openParentDir(),
                    .refresh => try model.entries.loadEntries(model.cwd.value()),
                    .vscode => try model.openVscode(),
                }
            }
        }
    }

    if (input.action) |action| switch (action) {
        .mouse, .event => {},
        .key => |key| switch (key) {
            .escape => try model.openParentDir(),
            else => {},
        },
    };

    if (try model.cwd.update(input)) |message| {
        switch (message) {
            .submit => |path| try model.entries.loadEntries(path),
        }
    }
    if (try model.entries.update(input)) |message| {
        switch (message) {
            .open => |open| switch (open.kind) {
                .dir => try model.openDir(open.name),
                .file => try model.openFile(open.name),
            },
            .delete => |del| try model.delete(del.kind, del.name),
        }
    }
}

pub fn render(model: Model) void {
    clay.ui()(.{
        .id = main.newId("Screen"),
        .layout = .{
            .sizing = clay.Element.Sizing.grow(.{}),
            .layout_direction = .top_to_bottom,
        },
        .rectangle = .{ .color = main.theme.base },
    })({
        clay.ui()(.{
            .id = main.newId("NavBar"),
            .layout = .{
                .padding = clay.Padding.all(10),
                .sizing = .{
                    .width = .{ .type = .grow },
                },
                .child_gap = 10,
            },
        })({
            renderNavButton(nav_buttons.parent, &resources.images.arrow_up);
            renderNavButton(nav_buttons.refresh, &resources.images.refresh);

            model.cwd.render();

            renderNavButton(nav_buttons.vscode, &resources.images.vscode);
        });

        clay.ui()(.{
            .id = main.newId("Content"),
            .layout = .{
                .sizing = clay.Element.Sizing.grow(.{}),
            },
            .rectangle = .{ .color = main.theme.mantle },
        })({
            const shortcut_width = 260; // TODO customizable

            clay.ui()(.{
                .id = main.newId("ShortcutsContainer"),
                .layout = .{
                    .padding = clay.Padding.all(10),
                    .sizing = .{ .width = clay.Element.Sizing.Axis.fixed(shortcut_width) },
                },
            })({
                clay.ui()(.{
                    .id = main.newId("Shortcuts"),
                    .layout = .{
                        .layout_direction = .top_to_bottom,
                        .padding = clay.Padding.all(16),
                    },
                })({
                    main.text("Shortcuts will go here");
                });
            });

            model.entries.render();
        });
    });
}

pub fn format(model: Model, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try fmt.format(writer, "\ncwd: {}\nentries: {}", .{ model.cwd, model.entries });
}

fn openDir(model: *Model, name: []const u8) Error!void {
    try model.cwd.appendPath(name);

    model.entries.loadEntries(model.cwd.value()) catch |err| switch (err) {
        Error.DirAccessDenied, Error.OpenDirFailure => {
            try model.cwd.popPath();
            return err;
        },
        else => return err,
    };
}

fn openParentDir(model: *Model) Error!void {
    try model.cwd.popPath();
    try model.entries.loadEntries(model.cwd.value());
}

fn openFile(model: Model, name: []const u8) Error!void {
    if (main.is_windows) {
        const path = try fs.path.joinZ(main.alloc, &.{ model.cwd.value(), name });
        defer main.alloc.free(path);
        const status = @intFromPtr(windows.ShellExecuteA(windows.getHandle(), null, path, null, null, 0));
        if (status <= 32) return alert.updateFmt("{s}", .{windows.shellExecStatusMessage(status)});
    } else {
        return Error.OsNotSupported;
    }
}

fn openVscode(model: Model) Error!void {
    if (main.is_windows) {
        const path = try main.alloc.dupeZ(u8, model.cwd.value());
        defer main.alloc.free(path);
        const status = @intFromPtr(windows.ShellExecuteA(windows.getHandle(), null, "code", path, null, 0));
        if (status <= 32) return alert.updateFmt("Failed to open directory.", .{});
    } else {
        return Error.OsNotSupported;
    }
}

// TODO if hard deleting, show confirmation modal
// if recycling, add generated filename to undo history
fn delete(model: *Model, kind: Entries.Kind, name: []const u8) Error!void {
    if (kind == .dir) return Error.DeleteDirFailure;
    if (!main.is_windows) return Error.OsNotSupported;

    const delete_time = windows.getFileTime();

    const disk_designator = fs.path.diskDesignatorWindows(model.cwd.value());
    if (disk_designator.len == 0) {
        alert.updateFmt("Unexpected file path.", .{});
        return;
    }

    const path = try fs.path.join(main.alloc, &.{ model.cwd.value(), name });
    defer main.alloc.free(path);

    const metadata = metadata: {
        const file = fs.openFileAbsolute(path, .{}) catch |err| {
            alert.update(err);
            return;
        };
        defer file.close();
        break :metadata file.metadata() catch |err| {
            alert.update(err);
            return;
        };
    };

    var maybe_sid_string: windows.String = null;
    defer if (maybe_sid_string) |sid_string| windows.free(sid_string);
    sid: {
        var username_buf: [128:0]u8 = undefined;
        var username_size: windows.BufSize = @intCast(username_buf.len);
        if (windows.GetUserNameExA(.sam_compatible, &username_buf, &username_size) == 0) break :sid;
        var sid_bytes: [256]u8 = undefined;
        const sid: *windows.SID = @ptrCast(mem.alignInBytes(&sid_bytes, @alignOf(windows.SID)).?);
        var sid_size: windows.BufSize = @intCast(sid_bytes.len - (@intFromPtr(&sid_bytes) - @intFromPtr(sid)));
        var domain_buf: [128:0]u8 = undefined;
        var domain_size: windows.BufSize = @intCast(domain_buf.len);
        var use: windows.SID_NAME_USE = undefined;
        const res = windows.LookupAccountNameA(null, &username_buf, sid, &sid_size, &domain_buf, &domain_size, &use);
        if (res == 0) break :sid;
        if (windows.ConvertSidToStringSidA(sid, &maybe_sid_string) == 0) break :sid;
    }
    const sid_string = maybe_sid_string orelse return Error.DeleteFileFailure;
    const sid_slice = mem.span(sid_string);

    const recycle_path = try fs.path.joinZ(main.alloc, &.{ disk_designator, "$Recycle.Bin", sid_slice });
    defer main.alloc.free(recycle_path);

    var prng = std.Random.DefaultPrng.init(@bitCast(time.milliTimestamp()));
    const rand = prng.random();
    var trash_basename: [6]u8 = undefined;
    for (&trash_basename) |*c| {
        const n = rand.uintLessThan(u8, 36);
        c.* = switch (n) {
            0...9 => '0' + n,
            10...35 => 'A' + (n - 10),
            else => unreachable,
        };
    }

    const ext = if (mem.lastIndexOfScalar(u8, name, '.')) |i| name[i..] else "";
    const trash_path = try fmt.allocPrint(
        main.alloc,
        "{s}{c}$R{s}{s}",
        .{ recycle_path, fs.path.sep, &trash_basename, ext },
    );
    defer main.alloc.free(trash_path);
    const meta_path = try fmt.allocPrint(
        main.alloc,
        "{s}{c}$I{s}{s}",
        .{ recycle_path, fs.path.sep, &trash_basename, ext },
    );
    defer main.alloc.free(meta_path);

    const meta_temp_path = try fs.path.join(main.alloc, &.{ main.temp_path, name });
    defer main.alloc.free(meta_temp_path);

    {
        const meta_file = fs.createFileAbsolute(meta_temp_path, .{}) catch |err| {
            alert.update(err);
            return;
        };
        defer meta_file.close();
        const meta_writer = meta_file.writer();
        meta_writer.writeAll(&(.{0x02} ++ .{0x00} ** 7)) catch return Error.DeleteFileFailure;
        const size_le = mem.nativeToLittle(u64, metadata.size());
        meta_writer.writeAll(&mem.toBytes(size_le)) catch return Error.DeleteFileFailure;
        meta_writer.writeStructEndian(delete_time, .little) catch return Error.DeleteFileFailure;
        const wide_path = unicode.wtf8ToWtf16LeAllocZ(main.alloc, path) catch return Error.DeleteFileFailure;
        defer main.alloc.free(wide_path);
        const wide_path_z = wide_path[0 .. wide_path.len + 1];
        const wide_path_len_le = math.lossyCast(u32, mem.nativeToLittle(usize, wide_path_z.len));
        meta_writer.writeAll(&mem.toBytes(wide_path_len_le)) catch return Error.DeleteFileFailure;
        meta_writer.writeAll(mem.sliceAsBytes(wide_path_z)) catch return Error.DeleteFileFailure;
    }

    main.moveFile(meta_temp_path, meta_path) catch return Error.DeleteFileFailure;
    main.moveFile(path, trash_path) catch return Error.DeleteFileFailure;

    try model.entries.loadEntries(model.cwd.value());
}
