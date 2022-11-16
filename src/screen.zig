const std = @import("std");
const assert = std.debug.assert;

pub const Screen = struct {
    const Row = [80]u8;
    const blank_row: Row = " ".* ** 80;

    rows: [24]Row = [_]Row{blank_row} ** 24,
    cursor_x: u8 = 0,
    cursor_y: u8 = 0,

    pub fn update(self: Screen, byte: u8) Screen {
        var new = self;
        var rows = &new.rows;
        if (byte == '\r') {
            new.cursor_x = 0;
        } else if (byte == '\n') {
            if (new.cursor_y < rows.len - 1) {
                new.cursor_y += 1;
            } else {
                std.mem.copy(Row, rows[0..rows.len - 1], rows[1..]);
                rows[rows.len - 1] = blank_row;
            }
            // we assume the tty input flag ICRNL is off, so \n doesn't reset the cursor x to 0.
            // this works because ttyrec seems to convert \n to \r\n for non-raw-mode programs.
        } else if (byte == '\t') {
            const width = comptime rows[new.cursor_y].len;
            if (new.cursor_x < width) {
                new.cursor_x = (new.cursor_x / 8 + 1) * 8;
            }
        } else {
            var row = &rows[new.cursor_y];
            const width = comptime row.len;
            if (new.cursor_x < width) {
                rows[new.cursor_y][new.cursor_x] = byte;
                new.cursor_x += 1;
            }
        }
        return new;
    }
};

test "screen update" {
    var screen = Screen{};
    for ("abc\n12345") |b|
        screen = screen.update(b);
    assert(std.mem.eql(u8, screen.rows[0][0..4], "abc "));
    assert(std.mem.eql(u8, screen.rows[1][0..6], "12345 "));
    assert(screen.cursor_x == 5);
    assert(screen.cursor_y == 1);
}
