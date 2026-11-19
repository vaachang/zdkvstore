const Item = struct {
    key: []u8,
    value: []u8,
};

pub const Array = struct {
    table: []Item,
    /// 水位线
    total: u32,
    /// 实际存了多少元素
    count: u32,

    const InsertError = error{
        InvalidArg,
        keyExists,
        OutOfMemory,
    };

    pub fn create() Array {
        return .{
            .total = 0,
            .count = 0,
        };
    }
};

const kvs_array_size = 1048576;
const std = @import("std");

pub var aVar: u32 = 0;

test "array test" {
    Array.create();
}
