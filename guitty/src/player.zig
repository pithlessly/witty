const c = @cImport({
    @cInclude("SDL.h");
});

const witty = @import("witty");
const Frame = witty.ttyrec.Frame;

const std = @import("std");
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const File = std.fs.File;

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
            const ownedFrame = Frame{
                .timestamp = frame.timestamp,
                .data = try self.alloc.dupe(u8, frame.data),
            };
            self.status.addOwnedFrame(ownedFrame);
        }
    };
    const ctx = .{ .status = status, .alloc = alloc };
    witty.ttyrec.parse(alloc, file.reader(), Ctx, Ctx.Err, ctx, Ctx.addFrame) catch |e|
        status.signalError(e);
}

pub fn play(alloc: Allocator, file: File) !void {
    const readerStatus = try ReaderStatus.init(alloc);
    defer readerStatus.deinitAndFree(alloc);

    const readerTh = try std.Thread.spawn(.{}, readerThread, .{ readerStatus, alloc, file });
    defer readerTh.join();

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("SDL initialization failed: {s}", .{getSdlError()});
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
        std.log.err("Unable to create window: {s}", .{getSdlError()});
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyWindow(win);

    c.SDL_SetWindowResizable(win, c.SDL_TRUE);

    const renderer = c.SDL_CreateRenderer(
        win,
        -1, // automatically choose rendering driver
        0, // no flags
    ) orelse {
        std.log.err("Unable to create renderer: {s}", .{getSdlError()});
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    var quit = false;
    while (!quit) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.@"type") {
                c.SDL_QUIT => quit = true,
                else => {},
            }
        }

        c.SDL_RenderPresent(renderer);
        c.SDL_Delay(17);
    }

    std.debug.print("frames: {}\n", .{readerStatus.initializedFrames().len});
}

test "compilation" {
    std.testing.refAllDecls(ReaderStatus);
    std.testing.refAllDecls(@This());
}
