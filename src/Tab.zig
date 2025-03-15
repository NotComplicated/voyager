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
const Model = @import("Model.zig");
const TextBox = @import("text_box.zig").TextBox;
const Entries = @import("Entries.zig");

cwd: TextBox(.path, main.newId("CurrentDir")),
entries: Entries,

const Tab = @This();

const max_paste_len = 1024;
const nav_buttons = .{
    .parent = main.newId("Parent"),
    .refresh = main.newId("Refresh"),
    .vscode = main.newId("VsCode"),
};

fn renderNavButton(id: clay.Element.Config.Id, icon: *rl.Texture) void {
    clay.ui()(.{
        .id = id,
        .layout = .{ .sizing = clay.Element.Sizing.fixed(Model.row_height) },
        .image = .{
            .image_data = icon,
            .source_dimensions = clay.Dimensions.square(Model.row_height),
        },
        .rectangle = .{
            .color = if (clay.pointerOver(id)) main.theme.hovered else main.theme.base,
            .corner_radius = main.rounded,
        },
    })({
        main.pointer();
    });
}

pub fn init(path: []const u8) Model.Error!Tab {
    var tab = Tab{
        .cwd = try meta.FieldType(Tab, .cwd).init(path),
        .entries = try Entries.init(),
    };
    errdefer tab.deinit();

    try tab.entries.loadEntries(path);

    return tab;
}

pub fn deinit(tab: *Tab) void {
    tab.cwd.deinit();
    tab.entries.deinit();
}

pub fn update(tab: *Tab, input: Input) Model.Error!void {
    if (main.is_debug and input.clicked(.middle)) {
        log.debug("{}\n", .{tab});
    } else if (input.clicked(.side)) {
        try tab.openParentDir();
    } else if (input.clicked(.left)) {
        inline for (comptime enums.values(meta.FieldEnum(@TypeOf(nav_buttons)))) |button| {
            if (clay.pointerOver(@field(nav_buttons, @tagName(button)))) {
                switch (button) {
                    .parent => try tab.openParentDir(),
                    .refresh => try tab.entries.loadEntries(tab.cwd.value()),
                    .vscode => try tab.openVscode(),
                }
            }
        }
    }

    const cwd_active = tab.cwd.isActive();

    if (try tab.cwd.update(input)) |message| {
        switch (message) {
            .submit => |path| try tab.entries.loadEntries(path),
        }
    }

    if (input.action) |action| if (!cwd_active) switch (action) {
        .mouse, .event => {},
        .key => |key| switch (key) {
            .backspace => try tab.openParentDir(),
            else => {},
        },
    };

    if (try tab.entries.update(input, !cwd_active)) |message| {
        switch (message) {
            .open => |open| switch (open.kind) {
                .dir => try tab.openDir(open.name),
                .file => try tab.openFile(open.name),
            },
            .delete => |del| try tab.delete(del.kind, del.name),
        }
    }
}

pub fn render(tab: Tab) void {
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

            tab.cwd.render();

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

            tab.entries.render();
        });
    });
}

pub fn format(tab: Tab, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
    try fmt.format(writer, "\ncwd: {}\nentries: {}", .{ tab.cwd, tab.entries });
}

fn openDir(tab: *Tab, name: []const u8) Model.Error!void {
    try tab.cwd.appendPath(name);

    tab.entries.loadEntries(tab.cwd.value()) catch |err| switch (err) {
        Model.Error.DirAccessDenied, Model.Error.OpenDirFailure => {
            try tab.cwd.popPath();
            return err;
        },
        else => return err,
    };
}

fn openParentDir(tab: *Tab) Model.Error!void {
    try tab.cwd.popPath();
    try tab.entries.loadEntries(tab.cwd.value());
}

fn openFile(tab: Tab, name: []const u8) Model.Error!void {
    if (main.is_windows) {
        const path = try fs.path.joinZ(main.alloc, &.{ tab.cwd.value(), name });
        defer main.alloc.free(path);
        const status = @intFromPtr(windows.ShellExecuteA(windows.getHandle(), null, path, null, null, 0));
        if (status <= 32) return alert.updateFmt("{s}", .{windows.shellExecStatusMessage(status)});
    } else {
        return Model.Error.OsNotSupported;
    }
}

fn openVscode(tab: Tab) Model.Error!void {
    if (main.is_windows) {
        const path = try main.alloc.dupeZ(u8, tab.cwd.value());
        defer main.alloc.free(path);
        const status = @intFromPtr(windows.ShellExecuteA(windows.getHandle(), null, "code", path, null, 0));
        if (status <= 32) return alert.updateFmt("Failed to open directory.", .{});
    } else {
        return Model.Error.OsNotSupported;
    }
}

// TODO if hard deleting, show confirmation modal
// if recycling, add generated filename to undo history
fn delete(tab: *Tab, kind: Entries.Kind, name: []const u8) Model.Error!void {
    if (kind == .dir) return Model.Error.DeleteDirFailure; // TODO
    if (!main.is_windows) return Model.Error.OsNotSupported; // TODO

    const delete_time = windows.getFileTime();

    const disk_designator = fs.path.diskDesignatorWindows(tab.cwd.value());
    if (disk_designator.len == 0) {
        alert.updateFmt("Unexpected file path.", .{});
        return;
    }

    const path = try fs.path.join(main.alloc, &.{ tab.cwd.value(), name });
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
    const sid_string = maybe_sid_string orelse return Model.Error.DeleteFileFailure;
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
        meta_writer.writeAll(&(.{0x02} ++ .{0x00} ** 7)) catch return Model.Error.DeleteFileFailure;
        const size_le = mem.nativeToLittle(u64, metadata.size());
        meta_writer.writeAll(&mem.toBytes(size_le)) catch return Model.Error.DeleteFileFailure;
        meta_writer.writeStructEndian(delete_time, .little) catch return Model.Error.DeleteFileFailure;
        const wide_path = unicode.wtf8ToWtf16LeAllocZ(main.alloc, path) catch return Model.Error.DeleteFileFailure;
        defer main.alloc.free(wide_path);
        const wide_path_z = wide_path[0 .. wide_path.len + 1];
        const wide_path_len_le = math.lossyCast(u32, mem.nativeToLittle(usize, wide_path_z.len));
        meta_writer.writeAll(&mem.toBytes(wide_path_len_le)) catch return Model.Error.DeleteFileFailure;
        meta_writer.writeAll(mem.sliceAsBytes(wide_path_z)) catch return Model.Error.DeleteFileFailure;
    }

    main.moveFile(meta_temp_path, meta_path) catch return Model.Error.DeleteFileFailure;
    main.moveFile(path, trash_path) catch return Model.Error.DeleteFileFailure;

    try tab.entries.loadEntries(tab.cwd.value());
}
