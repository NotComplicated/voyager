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

const Model = @import("Model.zig");

pub const EventParams = union(enum) {
    entry: struct { Model.Entries.Kind, Model.Index },
    parent,
};
const Event = meta.Tag(EventParams);

// This cursed function tries to get around the clay limitation where
// Clay_OnHover only accepts an *anyopaque with an unpredictable lifetime.
// Instead of only passing static values, we use MemoryPool to persistently
// store params and HashMap to recycle previously created params.
fn OnHover(
    comptime event: Event,
    onHoverFn: fn (PointerState, meta.TagPayload(EventParams, event)) anyerror!void,
) type {
    const Param = meta.TagPayload(EventParams, event);

    return struct {
        const hover_event = event;

        // Like AutoContext, but dereferences pointers.
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

fn onEntryHover(state: PointerState, data: struct { Model.Entries.Kind, Model.Index }) !void {
    const kind, const index = data;
    if (state == .pressed_this_frame) {
        try model.select(kind, index, .try_open);
    }
}

fn onParentHover(state: PointerState, _: void) !void {
    if (state == .pressed_this_frame) {
        try model.open_parent_dir();
    }
}
