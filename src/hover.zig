const std = @import("std");
const heap = std.heap;

const clay = @import("clay");
const PointerState = clay.Pointer.Data.InteractionState;

const main = @import("main.zig");
const alloc = main.alloc;
const updateError = main.updateError;

const model = &main.model;

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

pub const Event = enum {
    dir,
    parent,
};

const onHovers = .{
    .{ .dir, OnHover(usize, onDirHover) },
    .{ .parent, OnHover(void, onParentHover) },
};

pub fn on(comptime event: Event, param: anytype) void {
    inline for (onHovers) |onHover| {
        if (onHover.@"0" == event) {
            const Expected = @typeInfo(@TypeOf(onHover.@"1".register)).Fn.params[0].type.?;
            if (Expected != @TypeOf(param)) {
                @compileError("Expected '" ++ @typeName(Expected) ++ "' param for event '" ++ @tagName(event) ++ "'");
            }
            onHover.@"1".register(param);
            return;
        }
    }
    unreachable;
}

pub fn reset() void {
    inline for (onHovers) |onHover| onHover.@"1".reset();
}

pub fn deinit() void {
    inline for (onHovers) |onHover| onHover.@"1".deinit();
}

fn onDirHover(state: PointerState, entry_index: usize) !void {
    if (state == .pressed_this_frame) try model.open_dir(entry_index);
}

fn onParentHover(state: PointerState, _: void) !void {
    if (state == .pressed_this_frame) try model.open_parent_dir();
}
