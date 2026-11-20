const std = @import("std");
const Allocator = std.mem.Allocator;

const Item = struct {
    key: ?[]u8 = null,
    value: []u8 = &.{},
};

const InsertResult = enum {
    inserted,
    exists,
};

pub const Array = struct {
    table: []Item,
    // 已使用槽位数
    used: u32 = 0,
    // 水位线
    total: u32 = 0,
    allocator: Allocator,

    const Self = @This();
    const max_capacity = 1048576;
    const InsertError = error{TableFull} || Allocator.Error;
    const ModifyError = error{NotFound} || Allocator.Error;

    pub fn init(allocator: Allocator) !Self {
        return initCapacity(allocator, max_capacity);
    }

    fn initCapacity(allocator: Allocator, cap: usize) !Self {
        const table = try allocator.alloc(Item, cap);
        return .{
            .allocator = allocator,
            .table = table,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.table[0..self.total]) |slot| {
            if (slot.key) |key| {
                self.allocator.free(key);
                self.allocator.free(slot.value);
            }
        }
        self.allocator.free(self.table);
        self.table = &.{};
        self.used = 0;
        self.total = 0;
    }

    pub fn insert(self: *Self, key: []u8, value: []u8) !InsertResult {
        var first_free: ?u32 = null;
        for (self.table, 0..) |slot, i| {
            if (slot.key) |stored_key| {
                if (std.mem.eql(u8, stored_key, key)) {
                    return .exists;
                }
            } else if (first_free == null) {
                first_free = i;
            }
        }

        const position = first_free orelse blk: {
            if (self.total == max_capacity) return InsertError.TableFull;
            break :blk self.total;
        };

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);

        self.table[position] = .{ .key = key_copy, .vaule = value_copy };
        if (first_free == null) {
            self.total += 1;
        }
        self.used += 1;
        return .inserted;
    }

    pub fn get(self: *Self, key: []u8) ?[]u8 {
        for (self.table[0..self.total]) |slot| {
            if (slot.key) |stored_key| {
                if (std.mem.eql(u8, stored_key, key)) {
                    return slot.value;
                }
            }
        }
        return null;
    }

    pub fn modify(self: *Self, key: []u8, value: []u8) !void {
        for (self.table[0..self.total]) |slot| {
            if (slot.key) |stored_key| {
                if (std.mem.eql(u8, stored_key, key)) {
                    if (slot.value.len >= value.len) {
                        @memcpy(slot.value, value);
                        return;
                    } else {
                        const value_copy = try self.allocator.dupe(u8, value);
                        self.allocator.free(value);
                        value = value_copy;
                        return;
                    }
                }
            }
        }
        return ModifyError.NotFound;
    }

    pub fn delete(self: *Self, key: []u8) !void {
        for (self.table[0..self.total]) |slot| {
            if (slot.key) |stored_key| {
                if (std.mem.eql(u8, stored_key, key)) {
                    self.allocator.free(slot.value);
                    self.allocator.free(slot.key);
                    slot.key = null;
                    slot.value = null;
                }
            }
        }
    }

    pub fn exist(self: *Self, key: []u8) bool {
        if (self.get(key)) |_| {
            return true;
        } else {
            return false;
        }
    }
    pub fn count(self: *Self) u32 {
        return self.used;
    }
};
