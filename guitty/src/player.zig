const c = @cImport({
    @cInclude("SDL.h");
});

const witty = @import("witty");

const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

fn getSdlError() [*:0]const u8 {
    return @ptrCast([*:0]const u8, c.SDL_GetError());
}

pub fn play(alloc: Allocator, file: File) !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("SDL initialization failed: {s}", .{ getSdlError() });
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    const win_width = 500;
    const win_height = 500;
    const win = c.SDL_CreateWindow(
        "Witty",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        win_width,
        win_height,
        c.SDL_WINDOW_OPENGL,
    ) orelse {
        std.log.err("Unable to create window: {s}", .{ getSdlError() });
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyWindow(win);

    const Ctx = struct {
        screen: witty.Screen = .{},
        const Err = error{};
        fn addFrame(self: *@This(), frame: witty.ttyrec.Frame) Err!void {
            for (frame.data) |b|
                self.screen = self.screen.update(b);
        }
    };
    var ctx = Ctx{};
    try witty.ttyrec.parse(alloc, file.reader(), *Ctx, Ctx.Err, &ctx, Ctx.addFrame);
    for (ctx.screen.rows) |row| {
        var content = row;
        for (content) |*b| {
            if (' ' <= b.* and b.* <= 127) continue;
            b.* = '%';
        }
        std.debug.print("|{s}|\n", .{content});
    }
}
