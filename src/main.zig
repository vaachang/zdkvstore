const std = @import("std");

const zdkvstore = @import("zdkvstore");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("Hello, world!\n", .{});
}
