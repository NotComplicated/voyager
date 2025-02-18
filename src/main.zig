const builtin = @import("builtin");
pub const debug = builtin.mode == .Debug;

const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const enums = std.enums;
const fs = std.fs;
const log = std.log;

const clay = @import("clay");
const renderer = clay.renderers.raylib;
const PointerState = clay.Pointer.Data.InteractionState;

const rl = @import("raylib");

const Model = @import("Model.zig");

var model: Model = undefined;

const title = "Voyager" ++ if (debug) " (Debug)" else "";
const width = if (debug) 1200 else 800;
const height = 480;

var logging_page_alloc = heap.LoggingAllocator(.debug, .info).init(heap.page_allocator);
pub const alloc = logging_page_alloc.allocator();

// a buffer for the raylib renderer to use for temporary string copies
var buf: [4096]u8 = undefined;
var fba = heap.FixedBufferAllocator.init(&buf);
const raylib_alloc = fba.allocator();

const rl_config = rl.ConfigFlags{
    .vsync_hint = true,
    .window_resizable = true,
    .msaa_4x_hint = true,
};

const roboto = @embedFile("resources/roboto.ttf");

const FontSize = enum(u16) {
    sm = 24,
    md = 32,
    lg = 40,
    xl = 48,
};

fn rgb(r: u8, g: u8, b: u8) clay.Color {
    return .{ .r = @floatFromInt(r), .g = @floatFromInt(g), .b = @floatFromInt(b) };
}

const catppuccin = .{
    .text = rgb(205, 214, 244),
    .base = rgb(30, 30, 46),
    .mantle = rgb(24, 24, 37),
};

fn vector_conv(v: rl.Vector2) clay.Vector2 {
    return .{ .x = v.x, .y = v.y };
}

fn text(comptime font_size: FontSize, contents: []const u8) void {
    inline for (comptime enums.values(FontSize), 0..) |size, id| {
        if (size == font_size) {
            clay.text(contents, .{
                .color = catppuccin.text,
                .font_id = id,
                .font_size = @intFromEnum(size),
                .wrap_mode = .none,
            });
            return;
        }
    }
    comptime unreachable;
}

pub fn main() !void {
    const arena = clay.createArena(alloc, clay.minMemorySize());
    defer alloc.free(@as([*]u8, @ptrCast(arena.memory))[0..arena.capacity]);

    clay.setMeasureTextFunction(renderer.measureText);
    _ = clay.initialize(arena, .{ .width = width, .height = height }, .{});
    clay.setDebugModeEnabled(debug);
    renderer.initialize(width, height, title, rl_config);
    rl.setExitKey(.null);
    defer deinitHovers();

    inline for (comptime enums.values(FontSize), 0..) |size, id| {
        const roboto_font = try rl.Font.fromMemory(".ttf", roboto, @intFromEnum(size), null);
        rl.setTextureFilter(roboto_font.texture, .anisotropic_8x);
        renderer.addFont(id, roboto_font);
    }
    defer inline for (0..comptime enums.values(FontSize).len) |id| renderer.getFont(id).unload();

    model = try Model.init();
    defer model.deinit();

    while (!rl.windowShouldClose()) render_frame();
}

fn render_frame() void {
    clay.setLayoutDimensions(.{ .width = @floatFromInt(rl.getScreenWidth()), .height = @floatFromInt(rl.getScreenHeight()) });
    // setPointerStat will call all onHover events, updating the model
    clay.setPointerState(vector_conv(rl.getMousePosition()), rl.isMouseButtonDown(.left));
    clay.updateScrollContainers(true, vector_conv(rl.getMouseWheelMoveV()), rl.getFrameTime());
    defer resetHovers();

    rl.beginDrawing();
    defer rl.endDrawing();

    if (debug and rl.isMouseButtonPressed(.left)) {
        log.debug("{any}\n", .{&model});
    }

    clay.beginLayout();
    defer renderer.render(clay.endLayout(), raylib_alloc);

    clay.ui()(.{
        .id = clay.id("Screen"),
        .layout = .{
            .sizing = .{
                .width = .{ .size = .{ .percent = 1 }, .type = .percent },
                .height = .{ .size = .{ .percent = 1 }, .type = .percent },
            },
            .layout_direction = .top_to_bottom,
        },
        .rectangle = .{ .color = catppuccin.base },
    })({
        text(.sm, model.cwd.items);
        clay.ui()(.{
            .id = clay.id("Entries"),
            .layout = .{ .layout_direction = .top_to_bottom },
        })({
            const entries = model.entries.list.slice();
            for (0..entries.len) |i| {
                clay.ui()(.{
                    .id = clay.idi("Entry", @intCast(i)),
                })({
                    if (entries.items(.is_dir)[i]) {
                        text(.sm, "(dir)");
                        onHover.get("dir").?.register(i);
                    }
                    text(.sm, entries.items(.name)[i]);
                });
            }
        });
    });
}

fn updateError(err: anyerror) void {
    log.err("{s}\n", .{@errorName(err)});
}

fn OnHover(Param: type, onHoverFn: fn (PointerState, Param) anyerror!void) type {
    return struct {
        var pool = heap.MemoryPool(Param).init(alloc);

        fn register(param: Param) void {
            const new_param = pool.create() catch |err| return updateError(err);
            new_param.* = param;

            clay.onHover(
                Param,
                new_param,
                struct {
                    inline fn onHover(element_id: clay.Element.Config.Id, pointer_data: clay.Pointer.Data, passed_param: *Param) void {
                        _ = element_id;
                        onHoverFn(pointer_data.state, passed_param.*) catch |err| return updateError(err);
                    }
                }.onHover,
            );
        }

        fn reset() void {
            _ = pool.reset(.retain_capacity);
        }

        fn deinit() void {
            pool.deinit();
        }
    };
}

fn onDirHover(state: PointerState, entry_index: usize) !void {
    if (state == .pressed_this_frame) {
        std.debug.print("{d}\n", .{entry_index});
        try model.open_dir(entry_index);
    }
}

const onHover = std.StaticStringMap(type).initComptime(.{
    .{ "dir", OnHover(usize, onDirHover) },
});

fn resetHovers() void {
    inline for (onHover.values()) |Hover| Hover.reset();
}

fn deinitHovers() void {
    inline for (onHover.values()) |Hover| Hover.deinit();
}
