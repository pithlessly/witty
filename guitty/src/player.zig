const witty = @import("witty");
const Frame = witty.ttyrec.Frame;

const std = @import("std");
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const c = @import("c.zig");
const progress_bar = @import("progress_bar.zig");

fn getSdlError() [*:0]const u8 {
    return @ptrCast([*:0]const u8, c.SDL_GetError());
}

// TODO: rather than limiting the length so we can
// preallocate the buffer, use a segmented list or similar
// concurrent structure
const max_frames = 1024 * 1024;

const ReaderThreadError = Allocator.Error || File.ReadError || witty.ttyrec.ParseError;

// State shared between the reader and GUI thread.
const ReaderStatus = struct {
    frames: []Frame align(std.atomic.cache_line),
    num_frames: Atomic(usize) align(std.atomic.cache_line),
    has_err: Atomic(bool),
    err: ReaderThreadError,

    fn init(alloc: Allocator) !*ReaderStatus {
        const frames = try alloc.alloc(Frame, max_frames);
        errdefer alloc.free(frames);
        const self = try alloc.create(ReaderStatus);
        self.* = .{
            .frames = frames,
            .num_frames = Atomic(usize).init(0),
            .has_err = Atomic(bool).init(false),
            .err = undefined,
        };
        return self;
    }

    fn initializedFrames(self: *const ReaderStatus) []Frame {
        const n = self.num_frames.load(.Acquire);
        return self.frames[0..n];
    }

    fn deinitAndFree(self: *const ReaderStatus, alloc: Allocator) void {
        for (self.initializedFrames()) |frame|
            alloc.free(frame.data);
        alloc.free(self.frames);
        alloc.destroy(self);
    }

    fn addOwnedFrame(self: *ReaderStatus, frame: Frame) void {
        if (std.debug.runtime_safety)
            assert(!self.has_err.load(.SeqCst));
        const n = self.num_frames.load(.Acquire);
        self.frames[n] = frame;
        self.num_frames.store(n + 1, .Release);
    }

    fn signalError(self: *ReaderStatus, err: ReaderThreadError) void {
        assert(!self.has_err.load(.Acquire));
        self.err = err;
        self.has_err.store(true, .Release);
    }
};

fn readerThread(status: *ReaderStatus, alloc: Allocator, file: File) void {
    const Ctx = struct {
        status: *ReaderStatus,
        alloc: Allocator,
        const Err = Allocator.Error;
        fn addFrame(self: @This(), frame: Frame) Err!void {
            const owned_frame = Frame{
                .timestamp = frame.timestamp,
                .data = try self.alloc.dupe(u8, frame.data),
            };
            self.status.addOwnedFrame(owned_frame);
        }
    };
    const ctx = .{ .status = status, .alloc = alloc };
    witty.ttyrec.parse(alloc, file.reader(), Ctx, Ctx.Err, ctx, Ctx.addFrame) catch |e|
        status.signalError(e);
}

pub fn play(alloc: Allocator, file: File) !void {
    const reader_status = try ReaderStatus.init(alloc);
    defer reader_status.deinitAndFree(alloc);

    const reader_th = try std.Thread.spawn(.{}, readerThread, .{ reader_status, alloc, file });
    defer reader_th.join();

    try guiThread(reader_status, alloc);
}

fn guiThread(reader_status: *const ReaderStatus, alloc: Allocator) !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("SDL initialization failed: {s}", .{getSdlError()});
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    if (c.TTF_Init() != 0) {
        std.log.err("SDL_ttf initialization failed: {s}", .{getSdlError()});
        return error.SDLInitializationFailed;
    }
    defer c.TTF_Quit();

    const sans_ttf_data = @embedFile("fonts/DejaVuSans-2.37.ttf");
    const sans_stream = c.SDL_RWFromConstMem(sans_ttf_data, sans_ttf_data.len) orelse {
        std.log.err("Unable to create RWops for font: {s}", .{getSdlError()});
        return error.SDLInitializationFailed;
    };
    const sans_font = c.TTF_OpenFontRW(
        sans_stream,
        1, // tell SDL to free the stream after reading it
        16, // font size
    ) orelse {
        std.log.err("Unable to open font: {s}", .{getSdlError()});
        return error.SDLInitializationFailed;
    };
    defer c.TTF_CloseFont(sans_font);

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
        std.log.err("Unable to create window: {s}", .{getSdlError()});
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyWindow(win);

    c.SDL_SetWindowResizable(win, c.SDL_TRUE);

    const renderer = c.SDL_CreateRenderer(
        win,
        -1, // automatically choose rendering driver
        c.SDL_RENDERER_ACCELERATED,
    ) orelse {
        std.log.err("Unable to create renderer: {s}", .{getSdlError()});
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    var pb = progress_bar.State.init(alloc);
    defer pb.deinit();

    var quit = false;
    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;
    while (!quit) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.@"type") {
                c.SDL_QUIT => quit = true,
                c.SDL_MOUSEMOTION => {
                    mouse_x = event.motion.x;
                    mouse_y = event.motion.y;
                },
                else => {},
            }
        }

        var width: u31 = undefined;
        var height: u31 = undefined;
        try getWindowSize(renderer, &width, &height);

        _ = c.SDL_SetRenderDrawColor(renderer, 0xC0, 0xC0, 0xC0, 0xFF);
        _ = c.SDL_RenderClear(renderer);

        try progress_bar.draw(&pb, renderer, width, height, reader_status.initializedFrames());

        c.SDL_RenderPresent(renderer);
        c.SDL_Delay(17);
    }

    std.debug.print("frames: {}\n", .{reader_status.initializedFrames().len});
}

fn getWindowSize(renderer: *c.SDL_Renderer, w: *u31, h: *u31) !void {
    var c_w: c_int = undefined;
    var c_h: c_int = undefined;
    if (c.SDL_GetRendererOutputSize(renderer, &c_w, &c_h) != 0) {
        std.log.err("Unable to get draw size: {s}", .{getSdlError()});
        return error.SDLFailure;
    }
    w.* = std.math.cast(u31, c_w) orelse {
        std.log.err("SDL returned impossible window width: {}", .{c_w});
        return error.SDLFailure;
    };
    h.* = std.math.cast(u31, c_h) orelse {
        std.log.err("SDL returned impossible window height: {}", .{c_h});
        return error.SDLFailure;
    };
}

test "compilation" {
    std.testing.refAllDecls(ReaderStatus);
    std.testing.refAllDecls(@This());
}
