const std = @import("std");
const Allocator = std.mem.Allocator;

const Item = struct {
    key: ?[]u8 = null,
    value: []u8 = &.{},
};

// 两种正常情况
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
    const default_capacity = 1048576;
    const InsertError = error{TableFull} || Allocator.Error;

    pub fn init(allocator: Allocator) Allocator.Error!Self {
        return initCapacity(allocator, default_capacity);
    }

    fn initCapacity(allocator: Allocator, cap: usize) Allocator.Error!Self {
        const table = try allocator.alloc(Item, cap);
        // 零初始化，默认key = null ，避免脏指针
        @memset(table, .{});
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
        // 重置
        self.table = &.{};
        self.used = 0;
        self.total = 0;
    }

    pub fn insert(self: *Self, key: []const u8, value: []const u8) !InsertResult {
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
            // 此处和self.table.len作比较，不和default_size作比较
            if (self.total >= self.table.len) return error.TableFull;
            break :blk self.total;
        };

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);

        self.table[position] = .{ .key = key_copy, .value = value_copy };
        if (first_free == null) {
            self.total += 1;
        }
        self.used += 1;
        return .inserted;
    }

    // 返回const，调用方在编译期就无法写入
    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        for (self.table[0..self.total]) |slot| {
            const stored_key = slot.key orelse continue;
            if (std.mem.eql(u8, stored_key, key)) return slot.value;
        }
        return null;
    }

    // true修改成功，false键不存在
    pub fn modify(self: *Self, key: []const u8, value: []const u8) !bool {
        for (self.table[0..self.total]) |slot| {
            const stored_key = slot.key orelse continue;
            if (!std.mem.eql(u8, stored_key, key)) continue;

            const new_value = try self.allocator.dupe(u8, value);
            self.allocator.free(slot.value);
            slot.value = new_value;
            return true;
        }
        return false;
    }

    // 这里返回bool，true表示删除成功，false表示删除失败
    pub fn delete(self: *Self, key: []const u8) bool {
        // 加入末尾删除优化
        for (self.table[0..self.total], 0..) |slot, i| {
            // 用orelse continue减少一层大括号
            const stored_key = slot.key orelse continue;
            // 否定走continue，少一层括号
            if (!std.mem.eql(u8, stored_key, key)) continue;
            self.allocator.free(stored_key);
            self.allocator.free(slot.key);
            self.table[i] = .{};

            if (i == self.total - 1) self.total -= 1;
            // 不要忘记更新实际存储的数量
            self.used -= 1;
            return true;
        }
        return false;
    }

    pub fn exist(self: *const Self, key: []const u8) bool {
        return self.get(key) != null;
    }
    pub fn count(self: *const Self) u32 {
        return self.used;
    }
};
