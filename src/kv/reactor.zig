pub const Reactor = struct {
    epfd: i32,
    fn init() void {}
};

const std = @import("std");
const linux = std.os.linux;

test "linux api call" {
    Reactor.init();
}
