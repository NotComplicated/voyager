const Color = @import("clay").Color;

pub fn opacity(color: Color, alpha: f32) Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha * 255 };
}

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = @floatFromInt(r), .g = @floatFromInt(g), .b = @floatFromInt(b) };
}

pub var current: Theme = catppuccin_mocha;

const Theme = struct {
    alert: Color,
    dim_text: Color,
    text: Color,
    bright_text: Color,
    highlight: Color,
    secondary: Color,
    button: Color,
    hovered_button: Color,
    button_secondary: Color,
    hovered_button_secondary: Color,
    nav: Color,
    base: Color,
    base_light: Color,
    dim: Color,
    bright: Color,
    hovered: Color,
    selected: Color,
    bg: Color,
    pitch_black: Color,
};

pub const catppuccin_mocha = Theme{
    .alert = rgb(221, 63, 58),
    .dim_text = rgb(164, 168, 184),
    .text = rgb(205, 214, 244),
    .bright_text = rgb(255, 255, 255),
    .highlight = rgb(203, 166, 247),
    .secondary = rgb(138, 110, 175),
    .button = rgb(147, 86, 228),
    .hovered_button = rgb(133, 77, 206),
    .button_secondary = rgb(69, 71, 90),
    .hovered_button_secondary = rgb(64, 64, 80),
    .nav = rgb(43, 43, 58),
    .base = rgb(30, 30, 46),
    .base_light = rgb(34, 34, 50),
    .dim = rgb(17, 17, 26),
    .bright = rgb(34, 34, 49),
    .hovered = rgb(43, 43, 58),
    .selected = rgb(59, 59, 71),
    .bg = rgb(24, 24, 37),
    .pitch_black = rgb(17, 17, 27),
};
