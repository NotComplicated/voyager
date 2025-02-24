const std = @import("std");
const heap = std.heap;
const meta = std.meta;
const enums = std.enums;

const clay = @import("clay");
const PointerState = clay.Pointer.Data.InteractionState;

const main = @import("main.zig");
const alert = @import("alert.zig");
const Model = @import("Model.zig");

pub const EventParam = union(enum) {
    focus: ?enum { cwd },
    entry: struct { Model.Entries.Kind, Model.Index },
    parent,
    refresh,
    vscode,
};
const Event = meta.Tag(EventParam);

// This cursed function tries to get around the clay limitation where
// Clay_OnHover only accepts an *anyopaque with an unpredictable lifetime.
// Instead of only passing static values, we use MemoryPool to persistently
// store params and HashMap to recycle previously created params.
fn OnHover(
    comptime event: Event,
    onHoverFn: fn (PointerState, meta.TagPayload(EventParam, event)) anyerror!void,
) type {
    const Param = meta.TagPayload(EventParam, event);

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

        var params_pool = heap.MemoryPool(Param).init(main.alloc);
        var params_map = std.HashMapUnmanaged(*Param, void, Context, 80){};

        fn register(event_param: EventParam) void {
            var param = switch (event_param) {
                inline event => |payload| payload,
                else => unreachable,
            };
            const param_ptr = params_map.getKey(&param) orelse param_ptr: {
                const new_param_ptr = params_pool.create() catch |err| return alert.update(err);
                errdefer params_pool.destroy(new_param_ptr);
                new_param_ptr.* = param;
                params_map.put(main.alloc, new_param_ptr, {}) catch |err| return alert.update(err);
                break :param_ptr new_param_ptr;
            };

            clay.onHover(
                Param,
                param_ptr,
                struct {
                    inline fn onHover(_: clay.Element.Config.Id, data: clay.Pointer.Data, passed_param: *Param) void {
                        onHoverFn(data.state, passed_param.*) catch |err| alert.update(err);
                    }
                }.onHover,
            );
        }

        fn deinit() void {
            params_pool.deinit();
            params_map.deinit(main.alloc);
        }
    };
}

const onHovers: [enums.values(Event).len]type = .{
    OnHover(.focus, onFocus),
    OnHover(.entry, onEntry),
    OnHover(.parent, onParent),
    OnHover(.refresh, onRefresh),
    OnHover(.vscode, onVscode),
};

pub fn on(param: EventParam) void {
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

fn onFocus(state: PointerState, focus: meta.TagPayload(EventParam, .focus)) !void {
    if (state == .pressed_this_frame) {
        main.model.exitEditing();
        switch (focus orelse return) {
            .cwd => main.model.enterEditing(),
        }
    }
}

fn onEntry(state: PointerState, data: struct { Model.Entries.Kind, Model.Index }) !void {
    const kind, const index = data;
    if (state == .pressed_this_frame) {
        try main.model.select(kind, index, .try_open);
    }
}

fn onParent(state: PointerState, _: void) !void {
    if (state == .pressed_this_frame) {
        try main.model.open_parent_dir();
    }
}

fn onRefresh(state: PointerState, _: void) !void {
    if (state == .pressed_this_frame) {
        try main.model.entries.load_entries(main.model.cwd.items);
    }
}

fn onVscode(state: PointerState, _: void) !void {
    if (state == .pressed_this_frame) {
        try main.model.open_vscode();
    }
}
