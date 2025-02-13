const std = @import("std");
const heap = std.heap;

const rl = @import("raylib");
const rg = @import("raygui");

const GPA = heap.GeneralPurposeAllocator(.{});

pub fn main() !void {
    var gpa = GPA{};
    defer {
        _ = gpa.detectLeaks();
        _ = gpa.deinit();
    }
    _ = gpa.allocator();

    const width = 800;
    const height = 450;
    var show_message = false;

    rl.initWindow(width, height, "Test");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        // Update

        // Draw

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        rl.drawText("Congrats! You created your first window!", 190, 200, 20, rl.Color.light_gray);

        if (rg.guiButton(rl.Rectangle.init(24, 24, 120, 30), "#191#Show Message") > 0) show_message = true;

        if (show_message) {
            const result = rg.guiMessageBox(rl.Rectangle.init(85, 70, 250, 100), "#191#Message Box", "Hi! This is a message!", "Nice;Cool");
            if (result >= 0) show_message = false;
        }
    }
}
