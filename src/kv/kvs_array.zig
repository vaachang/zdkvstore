const Item = struct {
    key: []u8,
    value: []u8,
};

pub const Array = struct {
    table: [*]Item,
    idx: i32,
    total: i32,
    count: i32,
};

const kvs_array_size = 1048576;
const std = @import("std");
