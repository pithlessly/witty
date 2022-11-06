const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

fn makeTimestamp(s: u32, us: u32) u64 {
    assert(us < std.time.us_per_s);
    return std.math.mulWide(u32, s, std.time.us_per_s) + us;
}

pub const Frame = struct {
    timestamp: u64,
    data: []const u8,
};

pub fn parse(
    allocator: Allocator,
    reader: anytype,
    comptime Ctx: type,
    comptime Err: type,
    ctx: Ctx,
    comptime callback: fn (Ctx, Frame) Err!void,
) !void {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 1024 * 8);
    defer buffer.deinit();
    var last_timestamp: u64 = 0;
    while (true) {
        {
            // get more bytes from the reader
            try buffer.ensureUnusedCapacity(1024);
            const read_cursor = buffer.unusedCapacitySlice();
            var data_length = try reader.read(read_cursor);
            if (data_length == 0) {
                if (buffer.items.len == 0)
                    break // reached end of file cleanly
                else
                    return error.IncompleteFrame;
            }
            buffer.items.len += data_length;
        }
        // if we now have any completed frames, emit them
        var cursor = buffer.items;
        while (true) {
            if (cursor.len < 12) break;
            const data_len = std.mem.readIntLittle(u32, cursor[8..12]);
            if (cursor.len - 12 < data_len) break;
            const seconds = std.mem.readIntLittle(u32, cursor[0..4]);
            const microseconds = std.mem.readIntLittle(u32, cursor[4..8]);
            if (microseconds >= std.time.us_per_s)
                return error.InvalidMicroseconds;
            const timestamp = makeTimestamp(seconds, microseconds);
            if (timestamp < last_timestamp)
                return error.NonMonotonicTime;
            last_timestamp = timestamp;
            try callback(ctx, Frame{
                .timestamp = timestamp,
                .data = cursor[12..][0..data_len],
            });
            cursor = cursor[12..][data_len..];
        }
        // move the incomplete frame to the front of the buffer
        std.mem.copy(u8, buffer.items, cursor);
        buffer.shrinkRetainingCapacity(cursor.len);
    }
}

test "compilation" {
    var reader = std.io.fixedBufferStream("hello world!");
    assert(parse(
        std.testing.allocator,
        &reader,
        void,
        error{},
        {},
        struct {
            fn callback(ctx: void, f: Frame) !void {
                _ = ctx;
                _ = f;
            }
        }.callback,
    ) == error.IncompleteFrame);
}
