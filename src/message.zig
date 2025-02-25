const std = @import("std");
const ascii = std.ascii;
const enums = std.enums;

const clay = @import("clay");
const rl = @import("raylib");

const alert = @import("alert.zig");
const Model = @import("Model.zig");

pub const Message = union(enum) {
    select_entry: struct { kind: Model.Entries.Kind, index: Model.Index, clicked: bool },
    open_entry: struct { kind: Model.Entries.Kind, index: Model.Index },
    parent,
    refresh,
    vscode,
    focus: ?enum { cwd },
};

// TODO
// var maybe_message: ?Message = null;

// pub fn getMessage() ?Message {
//     return maybe_message;
// }

// pub fn on(events: enums.EnumFieldStruct(clay.Pointer.InteractionState, ?Message, @as(?Message, null))) void {
//     const onHoverFunction = struct {
//         inline fn f(id: clay.Element.Config.Id, pointer_data: clay.Pointer.Data, passed_maybe_message: *?Message) void {
//             if (passed_maybe_message.* != null) {
//                 alert.updateFmt("Received conflicting event from {s}:{}", .{ id.string_id, id.offset });
//             } else {
//                 passed_maybe_message.* = @field(events, @tagName(pointer_data.state));
//             }
//         }
//     }.f;
//     clay.onHover(?Message, &maybe_message, onHoverFunction);
// }
