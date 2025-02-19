const std = @import("std");
const heap = std.heap;
const meta = std.meta;
const enums = std.enums;

const clay = @import("clay");
const PointerState = clay.Pointer.Data.InteractionState;

const main = @import("main.zig");
const alloc = main.alloc;
const updateError = main.updateError;

const model = &main.model;

pub const EventParams = union(enum) {
    entry: u32,
    parent,
};
const Event = meta.Tag(EventParams);

fn OnHover(
    comptime event: Event,
    onHoverFn: fn (PointerState, meta.TagPayload(EventParams, event)) anyerror!void,
) type {
    const Param = meta.TagPayload(EventParams, event);

    return struct {
        const hover_event = event;

        const Context = struct {
            pub fn hash(_: @This(), param: *Param) u64 {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHash(&hasher, param.*);
                return hasher.final();
            }

            pub fn eql(_: @This(), lhs: *Param, rhs: *Param) bool {
                return meta.eql(lhs.*, rhs.*);
            }
        };

        var params_pool = heap.MemoryPool(Param).init(alloc);
        var params_map = std.HashMapUnmanaged(*Param, void, Context, 80){};

        fn register(event_param: EventParams) void {
            var param = switch (event_param) {
                inline event => |payload| payload,
                else => unreachable,
            };
            const param_ptr = params_map.getKey(&param) orelse param_ptr: {
                const new_param_ptr = params_pool.create() catch |err| return updateError(err);
                errdefer params_pool.destroy(new_param_ptr);
                new_param_ptr.* = param;
                params_map.put(alloc, new_param_ptr, {}) catch |err| return updateError(err);
                break :param_ptr new_param_ptr;
            };

            clay.onHover(
                Param,
                param_ptr,
                struct {
                    inline fn onHover(_: clay.Element.Config.Id, data: clay.Pointer.Data, passed_param: *Param) void {
                        onHoverFn(data.state, passed_param.*) catch |err| return updateError(err);
                    }
                }.onHover,
            );
        }

        fn deinit() void {
            params_pool.deinit();
            params_map.deinit(alloc);
        }
    };
}

const onHovers: [enums.values(Event).len]type = .{
    OnHover(.entry, onEntryHover),
    OnHover(.parent, onParentHover),
};

pub fn on(param: EventParams) void {
    inline for (onHovers) |onHover| {
        if (onHover.hover_event == meta.activeTag(param)) {
            onHover.register(param);
            return;
        }
    }
    unreachable;
}

pub fn deinit() void {
    inline for (onHovers) |onHover| {
        onHover.deinit();
    }
}

fn onEntryHover(state: PointerState, entry_index: u32) !void {
    if (state == .pressed_this_frame) {
        try model.select(entry_index, true);
    }
}

fn onParentHover(state: PointerState, _: void) !void {
    if (state == .pressed_this_frame) {
        try model.open_parent_dir();
    }
}
