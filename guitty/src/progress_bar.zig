const c = @cImport({
    @cInclude("SDL.h");
});

const Frame = @import("witty").ttyrec.Frame;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

fn float(x: anytype) f64 {
    return @intToFloat(f64, x);
}

const tick_radius = 1;

pub fn draw(
    pb: *State,
    renderer: *c.SDL_Renderer,
    w: u31,
    h: u31,
    frames: []const Frame,
) !void {
    const padding = 10;
    const bar_width = w -| (2 * padding);
    if (bar_width == 0) return;
    const bar_height = 10;
    const bar_x = 0 + padding;
    const bar_y = h -| (padding + bar_height);
    if (bar_y == 0) return;
    // draw progress bar rectangle
    _ = c.SDL_SetRenderDrawColor(renderer, 0x40, 0x40, 0x40, 0xFF);
    _ = c.SDL_RenderFillRect(renderer, &c.SDL_Rect{
        .x = @intCast(c_int, bar_x),
        .y = @intCast(c_int, bar_y),
        .w = @intCast(c_int, bar_width),
        .h = @intCast(c_int, bar_height),
    });

    // draw tick ranges
    if (frames.len == 0) return;
    _ = c.SDL_SetRenderDrawColor(renderer, 0xA0, 0xA0, 0xA0, 0xFF);
    var iterator = try pb.updateWithFrames(bar_width, frames);
    while (iterator.next()) |range| {
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_Rect{
            .x = padding + range.start,
            .y = bar_y,
            .w = range.end - range.start,
            .h = bar_height,
        });
    }
}

const PixelRange = struct {
    start: i32,
    end: i32,
    fn overlaps(r1: PixelRange, r2: PixelRange) bool {
        assert(r1.start <= r2.start);
        assert(r1.end <= r2.end);
        return r2.start <= r1.end;
    }
};

const TickRange = struct {
    start: f64,
    end: f64,

    fn fromFrame(f: Frame, min_time: u64) TickRange {
        const t = float(f.timestamp - min_time);
        return .{ .start = t, .end = t };
    }

    fn pixelRange(self: TickRange, time_range: f64, bar_width: f64) PixelRange {
        const sta = @floatToInt(i32, @round((bar_width / time_range) * self.start));
        const end = @floatToInt(i32, @round((bar_width / time_range) * self.end));
        return .{
            .start = sta - tick_radius,
            .end = end + tick_radius,
        };
    }

    fn coalesce(t1: TickRange, t2: TickRange, time_range: f64, bar_width: f64) ?TickRange {
        assert(t1.start <= t2.start);
        assert(t1.end <= t2.end);
        const r1 = t1.pixelRange(time_range, bar_width);
        const r2 = t2.pixelRange(time_range, bar_width);
        return if (r1.overlaps(r2))
            TickRange{
                .start = t1.start,
                .end = t2.end,
            }
        else
            null;
    }
};

pub const State = struct {
    prev_bar_width: u31,
    prev_num_frames: usize,
    tick_ranges: std.ArrayList(TickRange),

    pub fn init(alloc: Allocator) State {
        return .{
            .prev_bar_width = std.math.maxInt(u31),
            .prev_num_frames = 0,
            .tick_ranges = std.ArrayList(TickRange).init(alloc),
        };
    }

    pub fn deinit(self: State) void {
        self.tick_ranges.deinit();
    }

    fn updateWithFrames(self: *State, bar_width: u31, frames: []const Frame) !PixelRangeIterator {
        assert(frames.len > 0);
        const min_time = frames[0].timestamp;
        const max_time = frames[frames.len - 1].timestamp;
        const time_range = float(std.math.max(1, max_time - min_time));

        const bar_width_float = float(bar_width);

        if (bar_width > self.prev_bar_width) {
            std.log.info("progress bar width increased; invalidating tick ranges", .{});
            // this will cause all frames to be reprocessed in the loop below
            self.tick_ranges.clearRetainingCapacity();
            self.prev_num_frames = 0;
        } else if (bar_width < self.prev_bar_width) {
            self.recoalesce(time_range, bar_width_float);
        }
        self.prev_bar_width = bar_width;

        if (frames.len > self.prev_num_frames) {
            // add these frames to the range list, coalescing as necessary
            self.recoalesce(time_range, bar_width_float);
            const new_frames = frames[self.prev_num_frames..];
            try self.addFramesCoalescing(new_frames, min_time, time_range, bar_width_float);
        }
        self.prev_num_frames = frames.len;

        return PixelRangeIterator.init(self.tick_ranges.items, time_range, bar_width_float);
    }

    fn recoalesce(self: *State, time_range: f64, bar_width: f64) void {
        const tick_ranges = self.tick_ranges.items;
        if (tick_ranges.len == 0) return;
        var current_idx: usize = 0;
        var num_coalesced: usize = 0;
        for (tick_ranges[1..]) |next_range| {
            var current_range = &tick_ranges[current_idx];
            if (current_range.coalesce(next_range, time_range, bar_width)) |coalesced| {
                num_coalesced += 1;
                current_range.* = coalesced;
            } else {
                current_idx += 1;
                tick_ranges[current_idx] = next_range;
            }
        }
        self.tick_ranges.shrinkRetainingCapacity(current_idx + 1);
        if (num_coalesced > 0)
            std.log.info("coalesced ranges ({})", .{num_coalesced});
    }

    fn addFramesCoalescing(self: *State, frames: []const Frame, min_time: u64, time_range: f64, bar_width: f64) !void {
        var current_range_opt = self.tick_ranges.popOrNull();
        for (frames) |frame| {
            const next_range = TickRange.fromFrame(frame, min_time);
            if (current_range_opt) |current_range| {
                if (current_range.coalesce(next_range, time_range, bar_width)) |coalesced| {
                    current_range_opt = coalesced;
                } else {
                    try self.tick_ranges.append(current_range);
                    current_range_opt = next_range;
                }
            } else {
                current_range_opt = next_range;
            }
        }
        if (current_range_opt) |range|
            try self.tick_ranges.append(range);
    }
};

const PixelRangeIterator = struct {
    pos: [*]const TickRange,
    end: [*]const TickRange,
    time_range: f64,
    bar_width: f64,

    fn init(ranges: []const TickRange, time_range: f64, bar_width: f64) PixelRangeIterator {
        return .{
            .pos = ranges.ptr,
            .end = ranges.ptr + ranges.len,
            .time_range = time_range,
            .bar_width = bar_width,
        };
    }

    fn next(self: *PixelRangeIterator) ?PixelRange {
        if (self.pos == self.end) return null;
        defer self.pos += 1;
        return self.pos[0].pixelRange(self.time_range, self.bar_width);
    }
};
