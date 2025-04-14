const std = @import("std");
const builtin = std.builtin;
const meta = std.meta;

const clay = @import("clay");
const rl = @import("raylib");

const main = @import("main.zig");
const themes = @import("themes.zig");
const draw = @import("draw.zig");
const alert = @import("alert.zig");
const Model = @import("Model.zig");
const Input = @import("Input.zig");
const TextBox = @import("text_box.zig").TextBox;
const Error = @import("error.zig").Error;

var modal: struct {
    message: main.ArrayList(u8) = .empty,
    reject: std.BoundedArray(u8, 12) = .{},
    accept: std.BoundedArray(u8, 12) = .{},
    layout: ?Layout = null,
} = .{};

pub const Kind = enum { confirm, text };

fn NewLayout(field_types: []const type) type {
    return struct {
        fields: meta.Tuple(field_types),
        labels: [field_types.len]std.BoundedArray(u8, 32),
        data: *anyopaque,
        callback: *const fn (*anyopaque, meta.Tuple(value_types)) void,

        pub const value_types: []const type = value_types: {
            var vts: [field_types.len]type = undefined;
            for (&vts, field_types) |*Value, Field| Value.* = @TypeOf(Field.empty.value());
            const value_types_inner = vts;
            break :value_types &value_types_inner;
        };
    };
}

const Layout = union(Kind) {
    confirm: NewLayout(&.{}),
    text: NewLayout(&.{TextBox(.text, clay.id("ModalText"), null)}),
};

pub fn Callback(kind: Kind, T: type) type {
    const value_types = meta.TagPayload(Layout, kind).value_types;
    var field_params: [value_types.len]builtin.Type.Fn.Param = undefined;
    for (&field_params, value_types) |*param, ValueType| {
        param.* = .{ .is_generic = false, .is_noalias = false, .type = ValueType };
    }
    const data_param = builtin.Type.Fn.Param{ .is_generic = false, .is_noalias = false, .type = *T };

    return @Type(.{
        .@"fn" = .{
            .calling_convention = .auto,
            .is_generic = false,
            .is_var_args = false,
            .return_type = Error!void,
            .params = &(.{data_param} ++ field_params),
        },
    });
}

pub fn Writers(kind: Kind) type {
    const Labels = @FieldType(meta.TagPayload(Layout, kind), "labels");
    return struct {
        message: @TypeOf(modal.message).Writer,
        reject: @TypeOf(modal.reject).Writer,
        accept: @TypeOf(modal.accept).Writer,
        labels: [@typeInfo(Labels).array.len]meta.Child(Labels).Writer,
    };
}

const modal_id = clay.id("Modal");
const reject_id = clay.id("ModalReject");
const accept_id = clay.id("ModalAccept");

pub fn deinit() void {
    reset();
    modal.message.deinit(main.alloc);
}

pub fn set(comptime kind: Kind, T: type, data: *T, callback: Callback(kind, T)) Writers(kind) {
    const ThisLayout = meta.TagPayload(Layout, kind);

    reset();

    var fields: @FieldType(ThisLayout, "fields") = undefined;
    inline for (&fields) |*field| field.* = .empty;

    const cb = &struct {
        fn f(data_opaque: *anyopaque, values: meta.Tuple(ThisLayout.value_types)) void {
            const data_original: *T = @alignCast(@ptrCast(data_opaque));
            @call(.auto, callback, .{data_original} ++ values) catch |err| alert.update(err);
        }
    }.f;

    modal.layout = @unionInit(Layout, @tagName(kind), .{
        .fields = fields,
        .labels = [_]meta.Child(@FieldType(ThisLayout, "labels")){.{}} ** fields.len,
        .data = data,
        .callback = cb,
    });

    var label_writers: @FieldType(Writers(kind), "labels") = undefined;
    for (&label_writers, &@field(modal.layout.?, @tagName(kind)).labels) |*writer, *label| writer.* = label.writer();

    return .{
        .message = modal.message.writer(main.alloc),
        .reject = modal.reject.writer(),
        .accept = modal.accept.writer(),
        .labels = label_writers,
    };
}

pub fn reset() void {
    modal.message.clearRetainingCapacity();
    modal.accept.len = 0;
    modal.reject.len = 0;
    switch (modal.layout orelse return) {
        inline else => |*layout_inner| {
            inline for (&layout_inner.fields) |*field| field.deinit();
            inline for (&layout_inner.labels) |*label| label.len = 0;
        },
    }
    modal.layout = null;
}

pub fn update(input: Input) Error!enum { active, inactive } {
    switch (modal.layout orelse return .inactive) {
        inline else => |*layout| {
            var accepted = false;

            inline for (&layout.fields) |*field| {
                accepted = accepted or if (try field.update(input)) |message| message == .submit else false;
            }

            if (input.clicked(.left)) {
                if (clay.pointerOver(accept_id)) {
                    accepted = true;
                } else if (clay.pointerOver(reject_id) or !clay.pointerOver(modal_id)) {
                    reset();
                    return .inactive;
                }
            }

            if (accepted) {
                var values: meta.Tuple(@TypeOf(layout.*).value_types) = undefined;
                inline for (&values, layout.fields) |*value, field| value.* = field.value();
                layout.callback(layout.data, values);
                reset();
            }
        },
    }
    return .active;
}

pub fn render() void {
    const layout = &(modal.layout orelse return);

    clay.ui()(.{
        .id = clay.id("ModalScreen"),
        .layout = .{
            .sizing = .grow(.{}),
            .child_alignment = .center,
        },
        .floating = .{
            .z_index = 3,
            .attach_to = .root,
        },
        .bg_color = .rgba(0, 0, 0, 80),
    })({
        clay.ui()(.{
            .id = modal_id,
            .layout = .{
                .padding = .all(32),
                .layout_direction = .top_to_bottom,
                .child_alignment = .center,
            },
            .bg_color = themes.current.bg,
            .border = .{
                .color = themes.current.highlight,
                .width = .outside(2),
            },
            .corner_radius = draw.rounded,
        })({
            draw.textEx(.roboto, .lg, modal.message.items, themes.current.text, null);

            clay.ui()(.{
                .id = clay.id("ModalFields"),
                .layout = .{
                    .padding = .vertical(32),
                    .sizing = .{ .height = .fit(.{ .min = 32 }) },
                },
            })({
                switch (layout.*) {
                    inline else => |*layout_inner| inline for (layout_inner.fields, &layout_inner.labels) |field, *label| {
                        clay.ui()(.{
                            .layout = .{
                                .padding = .vertical(16),
                                .child_alignment = .center,
                                .child_gap = 16,
                            },
                        })({
                            draw.text(label.slice());

                            clay.ui()(.{
                                .layout = .{
                                    .sizing = .{ .width = .fixed(128) },
                                },
                            })({
                                field.render();
                            });
                        });
                    },
                }
            });

            clay.ui()(.{
                .id = clay.id("ModalAcceptReject"),
                .layout = .{
                    .child_gap = 24,
                },
            })({
                clay.ui()(.{
                    .id = reject_id,
                    .layout = .{
                        .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
                    },
                    .bg_color = if (clay.hovered()) themes.current.hovered_button_secondary else themes.current.button_secondary,
                    .corner_radius = draw.rounded,
                })({
                    draw.pointer();
                    draw.textEx(.roboto, .md, modal.reject.slice(), themes.current.bright_text, null);
                });

                clay.ui()(.{
                    .id = accept_id,
                    .layout = .{
                        .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
                    },
                    .bg_color = if (clay.hovered()) themes.current.hovered_button else themes.current.button,
                    .corner_radius = draw.rounded,
                })({
                    draw.pointer();
                    draw.textEx(.roboto, .md, modal.accept.slice(), themes.current.bright_text, null);
                });
            });
        });
    });
}
