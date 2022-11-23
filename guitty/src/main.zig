const c = @cImport({
    @cInclude("SDL.h");
});

const witty = @import("witty");

const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const player = @import("player.zig");

const CliSubcommand = enum { stat, play };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var command: CliSubcommand = undefined;
    var file: std.fs.File = undefined;
    {
        const args = try std.process.argsAlloc(alloc);
        defer std.process.argsFree(alloc, args);
        var path: []const u8 = undefined;
        if (args.len == 3) {
            path = args[2];
            const command_str = args[1];
            if (std.mem.eql(u8, command_str, "stat")) {
                command = .stat;
            } else {
                std.debug.print("Invalid subcommand: {s}.\n", .{command_str});
                return;
            }
        } else if (args.len == 2) {
            path = args[1];
            command = .play;
        } else {
            std.debug.print("Please provide a file name.\n", .{});
            return;
        }
        file = try std.fs.cwd().openFile(path, .{});
    }
    defer file.close();
    switch (command) {
        .stat => try getFrameStats(alloc, file),
        .play => try player.play(alloc, file),
    }
}

fn getFrameStats(alloc: Allocator, file: File) !void {
    const Ctx = struct {
        n_frames: u64 = 0,
        total_size: u64 = 0,
        max_frame_size: usize = 0,
        min_time: u64 = initial_min_time,
        max_time: u64 = 0,

        const initial_min_time = std.math.maxInt(u64);

        const Err = error{};
        fn addFrame(self: *@This(), frame: witty.ttyrec.Frame) Err!void {
            self.n_frames += 1;
            self.total_size += frame.data.len;
            self.max_frame_size = std.math.max(self.max_frame_size, frame.data.len);
            const time = frame.timestamp;
            self.min_time = std.math.min(self.min_time, time);
            self.max_time = std.math.max(self.max_time, time);
        }

        fn duration(self: @This()) u64 {
            if (self.min_time == initial_min_time)
                return 0; // must have been no frames
            return self.max_time - self.min_time;
        }
    };
    var ctx = Ctx{};
    try witty.ttyrec.parse(alloc, file.reader(), *Ctx, Ctx.Err, &ctx, Ctx.addFrame);
    try std.io.getStdOut().writer().print(
        \\{{
        \\  "num_frames": {},
        \\  "avg_frame":  {d:.2},
        \\  "max_frame":  {},
        \\  "duration":   {d:.3}
        \\}}
        \\
    , .{
        ctx.n_frames,
        @intToFloat(f64, ctx.total_size) / @intToFloat(f64, ctx.n_frames),
        ctx.max_frame_size,
        @intToFloat(f64, ctx.duration()) / 1000000.0,
    });
}

test "compilation" {
    std.testing.refAllDecls(@This());
}
