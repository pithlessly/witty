const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Frame = struct {
    seconds: u32,
    microseconds: u32,
    data: []const u8,

    pub fn timeMicroseconds(self: Frame) u64 {
        return std.math.mulWide(u32, self.seconds, std.time.us_per_s) + self.microseconds;
    }
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
            try callback(ctx, Frame{
                .seconds = std.mem.readIntLittle(u32, cursor[0..4]),
                .microseconds = std.mem.readIntLittle(u32, cursor[4..8]),
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
