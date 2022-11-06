const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const ttyrec = @import("ttyrec.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const file = blk: {
        const args = try std.process.argsAlloc(alloc);
        defer std.process.argsFree(alloc, args);
        if (args.len != 2) {
            std.debug.print("Please provide a file name.\n", .{});
            return;
        }
        const path = args[1];
        break :blk try std.fs.cwd().openFile(path, .{});
    };
    defer file.close();
    try getFrameStats(alloc, file);
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
        fn addFrame(self: *@This(), frame: ttyrec.Frame) Err!void {
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
    try ttyrec.parse(alloc, file.reader(), *Ctx, Ctx.Err, &ctx, Ctx.addFrame);
    try std.io.getStdOut().writer().print(
        \\# frames:      {}
        \\average frame: {d:.2} bytes
        \\largest frame: {} bytes
        \\duration:      {d:.3} s
        \\
    , .{
        ctx.n_frames,
        @intToFloat(f64, ctx.total_size) / @intToFloat(f64, ctx.n_frames),
        ctx.max_frame_size,
        @intToFloat(f64, ctx.duration()) / 1000000.0,
    });
}

test "compilation" {
    _ = ttyrec;
}
