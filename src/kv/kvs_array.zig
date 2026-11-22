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
        var first_free: ?usize = null;
        for (self.table[0..self.total], 0..) |slot, i| {
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
        for (self.table[0..self.total]) |*slot| {
            const stored_key = slot.key orelse continue;
            if (!std.mem.eql(u8, stored_key, key)) continue;

            const new_value = try self.allocator.dupe(u8, value);
            self.allocator.free(slot.value);
            // 此时slot是指针，可以直接用slot修改
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
            // free不能传?[]u8
            self.allocator.free(stored_key);
            self.allocator.free(slot.value);
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

    pub fn capacity(self: *const Self) usize {
        return self.table.len;
    }
};

// ============================== 测试 ==============================

test "基本生命周期：insert / get / exist / mod / del / count" {
    var arr = try Array.initCapacity(std.testing.allocator, 8);
    defer arr.deinit();

    try std.testing.expectEqual(@as(usize, 0), arr.count());
    try std.testing.expectEqual(@as(usize, 8), arr.capacity());

    try std.testing.expectEqual(InsertResult.inserted, try arr.insert("name", "inazuma"));
    try std.testing.expectEqual(InsertResult.inserted, try arr.insert("lang", "zig"));
    try std.testing.expectEqual(@as(usize, 2), arr.count());

    try std.testing.expectEqualSlices(u8, "inazuma", arr.get("name").?);
    try std.testing.expect(arr.exist("lang"));
    try std.testing.expect(!arr.exist("missing"));
    try std.testing.expect(arr.get("missing") == null);

    // 键已存在：不覆盖，返回 .exists（保持 C 版语义）
    try std.testing.expectEqual(InsertResult.exists, try arr.insert("name", "other"));
    try std.testing.expectEqualSlices(u8, "inazuma", arr.get("name").?);
    try std.testing.expectEqual(@as(usize, 2), arr.count());

    // 修改
    try std.testing.expect(try arr.modify("lang", "zig-0.18"));
    try std.testing.expectEqualSlices(u8, "zig-0.18", arr.get("lang").?);
    try std.testing.expect(!try arr.modify("nope", "x"));

    // 删除
    try std.testing.expect(arr.delete("name"));
    try std.testing.expect(!arr.delete("name"));
    try std.testing.expectEqual(@as(usize, 1), arr.count());
    try std.testing.expect(arr.get("name") == null);
}

test "二进制安全：key/value 中含 0x00 也能精确区分" {
    var arr = try Array.initCapacity(std.testing.allocator, 8);
    defer arr.deinit();

    const k1 = "a\x00b";
    const k2 = "a\x00c";
    const v1 = "\x00\x01\x00";
    const v2 = "plain";

    try std.testing.expectEqual(InsertResult.inserted, try arr.insert(k1, v1));
    try std.testing.expectEqual(InsertResult.inserted, try arr.insert(k2, v2));

    try std.testing.expectEqual(@as(usize, 2), arr.count());
    try std.testing.expectEqualSlices(u8, v1, arr.get(k1).?);
    try std.testing.expectEqualSlices(u8, v2, arr.get(k2).?);

    // 前缀相同、长度不同 / 内容不同，都不能误命中
    try std.testing.expect(arr.get("a") == null);
    try std.testing.expect(arr.get("a\x00") == null);

    try std.testing.expect(arr.delete(k1));
    try std.testing.expect(arr.get(k1) == null);
    try std.testing.expectEqualSlices(u8, v2, arr.get(k2).?);
}

test "空洞复用：删除中间元素后插入，不推高水位线" {
    var arr = try Array.initCapacity(std.testing.allocator, 8);
    defer arr.deinit();

    _ = try arr.insert("a", "1");
    _ = try arr.insert("b", "2");
    _ = try arr.insert("c", "3");
    try std.testing.expectEqual(@as(usize, 3), arr.total);

    try std.testing.expect(arr.delete("b"));
    try std.testing.expectEqual(@as(usize, 3), arr.total); // 非尾部删除，不收缩
    try std.testing.expectEqual(@as(usize, 2), arr.count());

    // 新键应复用 b 留下的空洞，而不是追加到 total 之后
    try std.testing.expectEqual(InsertResult.inserted, try arr.insert("d", "4"));
    try std.testing.expectEqual(@as(usize, 3), arr.total);
    try std.testing.expectEqual(@as(usize, 3), arr.count());

    try std.testing.expectEqualSlices(u8, "1", arr.get("a").?);
    try std.testing.expectEqualSlices(u8, "3", arr.get("c").?);
    try std.testing.expectEqualSlices(u8, "4", arr.get("d").?);
}

test "尾部删除收缩高水位线，并可重新尾插" {
    var arr = try Array.initCapacity(std.testing.allocator, 8);
    defer arr.deinit();

    _ = try arr.insert("a", "1");
    _ = try arr.insert("b", "2");
    try std.testing.expectEqual(@as(usize, 2), arr.total);

    try std.testing.expect(arr.delete("b"));
    try std.testing.expectEqual(@as(usize, 1), arr.total); // 尾部删除，收缩

    _ = try arr.insert("c", "3");
    try std.testing.expectEqual(@as(usize, 2), arr.total);
    try std.testing.expectEqualSlices(u8, "3", arr.get("c").?);
}

test "容量上限：表满返回 error.TableFull" {
    var arr = try Array.initCapacity(std.testing.allocator, 2);
    defer arr.deinit();

    _ = try arr.insert("a", "1");
    _ = try arr.insert("b", "2");
    try std.testing.expectError(error.TableFull, arr.insert("c", "3"));

    // 已存在的 key 在满表时仍应返回 .exists，而不是 TableFull
    try std.testing.expectEqual(InsertResult.exists, try arr.insert("a", "999"));

    // 删除一个后重新可插入
    try std.testing.expect(arr.delete("a"));
    try std.testing.expectEqual(InsertResult.inserted, try arr.insert("c", "3"));
}

test "set 的 OOM 回滚：key 分配成功、value 分配失败时无泄漏" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var arr = try Array.initCapacity(failing.allocator(), 4);
    defer arr.deinit();

    // 表格分配占 1 次；让下一次（key）成功，随后（value）失败
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, arr.insert("k", "v"));

    // errdefer 应已释放 key，计数与水位线都保持原样
    try std.testing.expectEqual(@as(usize, 0), arr.total);
    try std.testing.expectEqual(@as(usize, 0), arr.count());
    try std.testing.expect(arr.get("k") == null);
}

test "mod 的 OOM 安全性：新值分配失败时旧值仍有效" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var arr = try Array.initCapacity(failing.allocator(), 4);
    defer arr.deinit();

    try std.testing.expectEqual(InsertResult.inserted, try arr.insert("k", "old"));

    failing.fail_index = failing.alloc_index; // 让下一次分配直接失败
    try std.testing.expectError(error.OutOfMemory, arr.modify("k", "a-much-longer-value"));

    try std.testing.expectEqualSlices(u8, "old", arr.get("k").?);
    try std.testing.expectEqual(@as(usize, 1), arr.count());
}

test "deinit 幂等" {
    var arr = try Array.initCapacity(std.testing.allocator, 4);
    _ = try arr.insert("k", "v");
    arr.deinit();
    arr.deinit(); // 再次调用不应崩溃，也不应重复释放
    try std.testing.expectEqual(@as(usize, 0), arr.count());
    try std.testing.expectEqual(@as(usize, 0), arr.capacity());
}

test "槽位布局与 C 版对齐：Item 为 32 字节" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Item));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(?[]u8));
}
