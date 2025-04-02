const std = @import("std");
const process = std.process;
const heap = std.heap;
const fs = std.fs;

const clay = @import("clay");
const renderer = clay.renderers.raylib;
const rl = @import("raylib");

const windows = @import("windows.zig");
const themes = @import("themes.zig");
const draw = @import("draw.zig");
const resources = @import("resources.zig");
const alert = @import("alert.zig");
const tooltip = @import("tooltip.zig");
const modal = @import("modal.zig");
const Input = @import("Input.zig");
const Model = @import("Model.zig");
const Error = @import("error.zig").Error;

const builtin = @import("builtin");
pub const is_debug = builtin.mode == .Debug;
pub const is_windows = builtin.os.tag == .windows;

pub fn ArrayList(T: type) type {
    return std.ArrayListUnmanaged(T);
}

const title = "Voyager" ++ if (is_debug) " (Debug)" else "";
const default_width = 1200 + if (is_debug) 400 else 0;
const default_height = 600;
const min_width = 240;
const min_height = 320;
const fps = .{ .focused = 0, .unfocused = 15 };
const scroll_speed = 5;
const mem_scale = 16;
const max_elem_count = mem_scale * 8192; // 8192 is the default clay max elem count

var debug_alloc = heap.DebugAllocator(.{ .verbose_log = true }).init;
pub const alloc = if (is_debug) debug_alloc.allocator() else heap.smp_allocator;

const data_dirname = "voyagerfm";
const temp_dirname = "temp";
pub var data_path: []const u8 = undefined;
pub var temp_path: []const u8 = undefined;

const rl_config = rl.ConfigFlags{
    .vsync_hint = true,
    .window_resizable = true,
    .msaa_4x_hint = true,
};

pub const double_click_delay = 300;

pub fn convertVector(v: rl.Vector2) clay.Vector2 {
    return .{ .x = v.x, .y = v.y };
}

var focused = true;

pub fn getBounds(id: clay.Id) ?clay.BoundingBox {
    const data = clay.getElementData(id);
    if (!data.found) {
        alert.updateFmt("Failed to locate element '{s}:{}'", .{ id.string_id, id.offset });
        return null;
    } else {
        return data.boundingBox;
    }
}

const GlfwWindow = opaque {};
const GlfwMonitor = opaque {};
const GlfwKeyfun = *const fn (*GlfwWindow, c_int, c_int, c_int, c_int) callconv(.c) void;

extern fn glfwGetCurrentContext() *GlfwWindow;
extern fn glfwSetKeyCallback(window: *GlfwWindow, callback: GlfwKeyfun) GlfwKeyfun;

var prevKeyCallback: GlfwKeyfun = undefined;

// This is the only way I know to remove screenshotting @_@
fn keyCallback(window: *GlfwWindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    switch (@as(rl.KeyboardKey, @enumFromInt(key))) {
        rl.KeyboardKey.f12 => if (is_debug) clay.setDebugModeEnabled(true),
        else => prevKeyCallback(window, key, scancode, action, mods),
    }
}

fn mkdir(path: []const u8) !void {
    fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn main() !void {
    defer _ = if (is_debug) debug_alloc.deinit();

    var args = try process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.skip();

    data_path = try fs.getAppDataDir(alloc, data_dirname);
    defer alloc.free(data_path);
    try mkdir(data_path);
    temp_path = try fs.path.join(alloc, &.{ data_path, temp_dirname });
    defer alloc.free(temp_path);
    try mkdir(temp_path);

    clay.setMaxElementCount(max_elem_count);
    const arena = clay.createArena(alloc, mem_scale * clay.minMemorySize());
    defer alloc.free(@as([*]u8, @ptrCast(arena.memory))[0..arena.capacity]);

    _ = clay.initialize(
        arena,
        .{ .width = default_width, .height = default_height },
        .{ .function = alert.updateClay },
    );
    clay.setDebugModeEnabled(is_debug);
    renderer.initialize(default_width, default_height, title, rl_config);
    rl.setExitKey(.null);
    rl.setTargetFPS(fps.focused);

    prevKeyCallback = glfwSetKeyCallback(glfwGetCurrentContext(), &keyCallback);

    if (is_windows) {
        windows.init();
        windows.setTitleColor(themes.current.bg);
    }
    defer if (is_windows) windows.deinit();

    try resources.init();
    defer resources.deinit();

    defer alert.deinit();
    defer tooltip.deinit();
    defer modal.deinit();

    var model = try Model.init(&args);
    defer model.deinit();

    while (!rl.windowShouldClose()) frame(&model);
}

fn frame(model: *Model) void {
    // Update phase

    var width, var height = .{ rl.getScreenWidth(), rl.getScreenHeight() };
    const width_too_small, const height_too_small = .{ width < min_width, height < min_height };
    if (width_too_small) width = min_width;
    if (height_too_small) height = min_height;
    if (width_too_small or height_too_small) rl.setWindowSize(width, height);

    clay.setLayoutDimensions(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) });
    clay.setPointerState(convertVector(rl.getMousePosition()), rl.isMouseButtonDown(.left));
    clay.updateScrollContainers(
        false,
        convertVector(rl.math.vector2Scale(rl.getMouseWheelMoveV(), scroll_speed)),
        rl.getFrameTime(),
    );

    const new_focused = rl.isWindowFocused();
    if (new_focused != focused) {
        focused = new_focused;
        rl.setTargetFPS(if (focused) fps.focused else fps.unfocused);
    }

    model.update(Input.read()) catch |err| switch (err) {
        Error.GracefulShutdown => {
            rl.closeWindow();
            return;
        },
        else => {
            if (is_debug) if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
            alert.update(err);
        },
    };

    // Render phase

    rl.beginDrawing();
    defer rl.endDrawing();

    clay.beginLayout();
    defer renderer.render(clay.endLayout(), resources.getFonts().ptr);

    draw.setCursor(.default);
    defer rl.setMouseCursor(draw.getCursor());

    model.render();
    alert.render();
    tooltip.render();
    modal.render();
}
