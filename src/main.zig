const std = @import("std");

pub const ttyrec = @import("ttyrec.zig");
pub const Screen = @import("screen.zig").Screen;

test "compilation" {
    _ = ttyrec;
    _ = Screen;
}
