const std = @import("std");
const unicode = std.unicode;
const enums = std.enums;
const meta = std.meta;
const fs = std.fs;

const clay = @import("clay");
const renderer = clay.renderers.raylib;
const rl = @import("raylib");

const resources_path = "resources" ++ fs.path.sep_str;

const font_filenames = .{
    .roboto = "roboto.ttf",
    .roboto_mono = "roboto-mono.ttf",
};

pub const Font: type = meta.FieldEnum(@TypeOf(font_filenames));

pub const FontSize = enum(u16) {
    sm = 18,
    md = 20,
    lg = 24,
    xl = 30,
};

const standard_codepoints = standard: {
    var points: [95]i32 = undefined;
    for (&points, 0..) |*point, i| point.* = i + 32;
    break :standard points;
};

const special_codepoints = special: {
    @setEvalBranchQuota(6250);
    var points = std.BoundedArray(i32, 1024){};
    // Latin supplements
    for (0x00A1..0x0180) |point| points.append(point) catch @compileError("Not enough space");
    // Extended Latin
    for (0x1EA0..0x1EFA) |point| points.append(point) catch @compileError("Not enough space");
    // Greek
    for (0x038E..0x03A2) |point| points.append(point) catch @compileError("Not enough space");
    for (0x03A3..0x03CE) |point| points.append(point) catch @compileError("Not enough space");
    // Cyrillic
    for (0x0400..0x0514) |point| points.append(point) catch @compileError("Not enough space");
    const misc =
        "ƒơƯưƠǺǻǼǽǾǿȘșȚțȷəʼˆˇˉ˘˙˚˛˜˝ǰ́̃̉̏΄΅Ά·ΈΉΊΌ˳ϑϒϖḀḁ" ++
        "ḾḿẀẁẂẃẄẅ–—―‗‘’‚‛“”„†‡•‰′″‥…⁄‹›‼Ὅⁿ€₫₧₤₣℅ℓ™№Ω℮" ++
        "⅛⅜⅝⅞∏∞∫√∆∕∂−∑≈≥≤≠⁴◊�￼";
    var chars_iter = unicode.Utf8View.initComptime(misc).iterator();
    while (chars_iter.nextCodepoint()) |point| points.append(point) catch @compileError("Not enough space");
    break :special points.slice()[0..].*;
};

var all_codepoints = standard_codepoints ++ special_codepoints;

pub var fonts: [meta.fields(@TypeOf(font_filenames)).len * meta.tags(FontSize).len + 1]rl.Font = undefined;

const image_filenames = .{
    .x = "x.png",
    .x_dim = "x-dim.png",
    .tab_left = "tab-left.png",
    .tab_right = "tab-right.png",
    .plus = "plus.png",
    .add_file = "add-file.png",
    .add_folder = "add-folder.png",
    .arrow_up = "arrow-up.png",
    .clipboard = "clipboard.png",
    .compare = "compare.png",
    .copy = "copy.png",
    .edit_file = "edit-file.png",
    .edit_text_file = "edit-text-file.png",
    .filetypes = "filetypes.png",
    .folder = "folder.png",
    .folder_open = "folder-open.png",
    .folder_dls = "downloads-folder.png",
    .folder_docs = "documents-folder.png",
    .folder_music = "music-folder.png",
    .folder_code = "code-folder.png",
    .icon = "voyager.bmp",
    .image = "image.png",
    .refresh = "refresh.png",
    .vscode = "vs-code.png",
    .tri_up = "tri-up.png",
    .tri_down = "tri-down.png",
    .checkmark = "checkmark.png",
    .not_bookmarked = "not-bookmarked.png",
    .bookmarked = "bookmarked.png",
    .expand = "expand.png",
    .collapse = "collapse.png",
};

pub var images: enums.EnumFieldStruct(meta.FieldEnum(@TypeOf(image_filenames)), rl.Texture, null) = undefined;

pub const file_icon_size = 36;

var file_icons: [6][6]rl.Texture = undefined;

pub fn getFonts() []const rl.Font {
    return &fonts;
}

pub fn getFileIcon(file_name: []const u8) *rl.Texture {
    const ExtensionMap = std.StaticStringMapWithEql(struct { u3, u3 }, std.static_string_map.eqlAsciiIgnoreCase);
    const extensions = ExtensionMap.initComptime(.{
        .{ "txt", .{ 0, 0 } },
        .{ "png", .{ 0, 1 } },
        .{ "lnk", .{ 0, 2 } },
        .{ "mp4", .{ 0, 3 } },
        .{ "avi", .{ 0, 3 } },
        .{ "wmv", .{ 0, 3 } },
        .{ "webm", .{ 0, 3 } },
        .{ "wav", .{ 0, 4 } },
        .{ "wma", .{ 0, 5 } },
        .{ "jpg", .{ 1, 1 } },
        .{ "jpeg", .{ 1, 1 } },
        .{ "mkv", .{ 1, 2 } },
        .{ "mov", .{ 1, 3 } },
        .{ "ttf", .{ 1, 4 } },
        .{ "mp3", .{ 1, 5 } },
        .{ "otf", .{ 2, 0 } },
        .{ "pdf", .{ 2, 1 } },
        .{ "ppt", .{ 2, 2 } },
        .{ "rar", .{ 2, 3 } },
        .{ "apng", .{ 2, 4 } },
        .{ "gif", .{ 2, 4 } },
        .{ "bmp", .{ 2, 4 } },
        .{ "rtf", .{ 2, 5 } },
        .{ "ogg", .{ 3, 0 } },
        .{ "xml", .{ 3, 1 } },
        .{ "tar", .{ 3, 2 } },
        .{ "mpg", .{ 3, 3 } },
        .{ "xls", .{ 3, 4 } },
        .{ "xlsx", .{ 3, 4 } },
        .{ "aac", .{ 4, 3 } },
        .{ "apk", .{ 4, 4 } },
        .{ "css", .{ 4, 5 } },
        .{ "htm", .{ 5, 0 } },
        .{ "html", .{ 5, 0 } },
        .{ "zip", .{ 5, 1 } },
        .{ "7z", .{ 5, 1 } },
        .{ "tar", .{ 5, 1 } },
        .{ "xz", .{ 5, 1 } },
        .{ "gz", .{ 5, 1 } },
        .{ "rar", .{ 5, 1 } },
        .{ "exe", .{ 5, 2 } },
        .{ "doc", .{ 5, 3 } },
        .{ "docx", .{ 5, 3 } },
        .{ "dll", .{ 5, 4 } },
        .{ "csv", .{ 5, 5 } },
    });

    const extension = fs.path.extension(file_name);
    const i, const j = extensions.get(if (extension.len > 0) extension[1..] else "") orelse .{ 4, 1 };
    return &file_icons[i][j];
}

pub fn init() !void {
    inline for (comptime meta.fieldNames(@TypeOf(image_filenames))) |filename| {
        const path = resources_path ++ @field(image_filenames, filename);
        const image = try rl.loadImageFromMemory(@ptrCast(fs.path.extension(path)), @embedFile(path));
        defer image.unload();
        @field(images, filename) = try image.toTexture();
        rl.setTextureFilter(@field(images, filename), .bilinear);
    }
    errdefer inline for (comptime meta.fieldNames(@TypeOf(images))) |image| @field(images, image).unload();

    rl.setWindowIcon(try rl.Image.fromTexture(images.icon));

    const filetypes = try rl.Image.fromTexture(images.filetypes);
    defer filetypes.unload();
    for (0..6) |i| for (0..6) |j| {
        const icon = filetypes.copyRec(.init(
            @floatFromInt(j * file_icon_size),
            @floatFromInt(i * file_icon_size),
            file_icon_size,
            file_icon_size,
        ));
        defer icon.unload();
        file_icons[i][j] = try icon.toTexture();
        rl.setTextureFilter(file_icons[i][j], .bilinear);
    };
    errdefer for (file_icons) |file_icons_row| for (file_icons_row) |file_icon| file_icon.unload();

    inline for (comptime meta.fieldNames(@TypeOf(font_filenames)), 0..) |font_name, i| {
        for (meta.tags(FontSize), 0..) |size, j| {
            const path = resources_path ++ @field(font_filenames, font_name);
            const font = try rl.Font.fromMemory(
                @ptrCast(fs.path.extension(path)),
                @embedFile(path),
                @intFromEnum(size),
                &all_codepoints,
            );
            rl.setTextureFilter(font.texture, .anisotropic_8x);
            fonts[i * meta.tags(FontSize).len + j] = font;
        }
    }

    clay.setMeasureTextFunction(rl.Font, &fonts, renderer.measureText);
}

pub fn deinit() void {
    inline for (comptime meta.fieldNames(@TypeOf(images))) |image| @field(images, image).unload();
    for (file_icons) |file_icons_row| for (file_icons_row) |file_icon| file_icon.unload();
    for (fonts) |font| font.unload();
}
