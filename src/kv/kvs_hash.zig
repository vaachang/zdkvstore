const std = @import("std");
const Allocator = std.mem.Allocator;

// 由于zig没有C语言的柔性数组这一概念，采用类似ArenaAllocator的思路实现
const HashNode = struct {
    next: ?*HashNode,
    key_len: usize,
    value_len: usize,
    // 这里多一个字段，对应C语言malloc的分配长度记录，在free时需要用到
    // 相当于C语言是malloc记录，这里要自己记录
    alloc_size: u64,

    const header_size = @sizeOf(HashNode);

    inline fn loadKey(self: *HashNode) []u8 {
        const bytes: [*]u8 = @ptrCast(self);
        return bytes[header_size..][0..self.key_len];
    }

    inline fn loadValue(self: *HashNode) []u8 {
        const bytes: [*]u8 = @ptrCast(self);
        return bytes[header_size..][self.key_len..][0..self.value_len];
    }

    fn init(key: []const u8, value: []const u8, allocator: Allocator) Allocator.Error!*HashNode {
        const new_node_len = header_size + key.len + value.len;
        const new_node_ptr = try allocator.allocBytesAligned(.of(HashNode), new_node_len, @returnAddress());
        const new_node: *HashNode = @ptrCast(@alignCast(new_node_ptr));
        new_node.* = .{
            .next = null,
            .key_len = key.len,
            .value_len = value.len,
            .alloc_size = new_node_len,
        };
        @memcpy(new_node.loadKey(), key);
        @memcpy(new_node.loadValue(), value);
        return new_node;
    }

    fn deinit(self: *HashNode, allocator: Allocator) void {
        const bytes: [*]align(@alignOf(HashNode)) u8 = @ptrCast(self);
        allocator.free(bytes[0..self.alloc_size]);
    }
};

const InsertResult = enum {
    inserted,
    exists,
};

pub const HashTable = struct {
    nodes: []?*HashNode,
    entry_count: u32,
    allocator: Allocator,

    const Self = @This();
    const default_capacity = 1 << 23;
    const InitError = Allocator.Error || error{InvalidCapacity};

    pub fn init(allocator: Allocator) InitError!Self {
        return initCapacity(allocator, default_capacity);
    }

    fn initCapacity(allocator: Allocator, slot_count: u32) InitError!Self {
        if (slot_count == 0 or !std.math.isPowerOfTwo(slot_count)) {
            return error.InvalidCapacity;
        }
        const nodes = try allocator.alloc(?*HashNode, slot_count);
        @memset(nodes, null);
        return .{
            .nodes = nodes,
            .entry_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.nodes) |head| {
            var it = head;
            while (it) |node| {
                it = node.next;
                node.deinit(self.allocator);
            }
        }
        self.allocator.free(self.nodes);
        self.nodes = &.{};
        self.entry_count = 0;
    }

    inline fn getIdx(self: *const Self, key: []const u8) usize {
        return hashKey(key, self.nodes.len);
    }

    pub fn insert(self: *Self, key: []const u8, value: []const u8) Allocator.Error!InsertResult {
        const idx = self.getIdx(key);
        var it = self.nodes[idx];
        while (it) |node| : (it = node.next) {
            if (std.mem.eql(u8, node.loadKey(), key)) {
                return .exists;
            }
        }

        const new_node = try HashNode.init(key, value, self.allocator);
        new_node.next = self.nodes[idx];
        self.nodes[idx] = new_node;
        self.entry_count += 1;
        return .inserted;
    }

    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        const idx = self.getIdx(key);
        var it = self.nodes[idx];
        while (it) |node| : (it = node.next) {
            if (std.mem.eql(u8, node.loadKey(), key)) {
                return node.loadValue();
            }
        }
        return null;
    }

    // true修改成功，false键不存在
    pub fn modify(self: *Self, key: []const u8, value: []const u8) Allocator.Error!bool {
        const idx = self.getIdx(key);
        var link = &self.nodes[idx];
        while (link.*) |node| : (link = &node.next) {
            if (std.mem.eql(u8, node.loadKey(), key)) {
                if (node.value_len >= value.len) {
                    @memcpy(node.loadValue()[0..value.len], value);
                    node.value_len = value.len;
                    return true;
                }
                const new_node = try HashNode.init(key, value, self.allocator);
                new_node.next = node.next;
                link.* = new_node;
                node.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    // 这里返回bool，true表示删除成功，false表示删除失败
    pub fn delete(self: *Self, key: []const u8) bool {
        const idx = self.getIdx(key);
        var link = &self.nodes[idx];
        while (link.*) |node| : (link = &node.next) {
            if (std.mem.eql(u8, node.loadKey(), key)) {
                link.* = node.next;
                node.deinit(self.allocator);
                self.entry_count -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn exist(self: *const Self, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn count(self: *const Self) u32 {
        return self.entry_count;
    }

    pub fn capacity(self: *const Self) usize {
        return self.nodes.len;
    }
};

// 这里应该是尝试用SIMD指令优化，理论上std.mem.eql实现的会更好
inline fn fastEq(p1: []const u8, p2: []const u8) bool {
    std.debug.assert(p1.len == p2.len);
    const len = p1.len;
    var i: usize = 0;

    while (len - i >= 8) : (i += 8) {
        const a = std.mem.readInt(u64, p1[i..][0..8], .little);
        const b = std.mem.readInt(u64, p2[i..][0..8], .little);
        if (a != b) return false;
    }

    if (len - i >= 4) {
        const a = std.mem.readInt(u32, p1[i..][0..4], .little);
        const b = std.mem.readInt(u32, p2[i..][0..4], .little);
        if (a != b) return false;
        i += 4;
    }

    while (i < len) : (i += 1) {
        if (p1[i] != p2[i]) return false;
    }

    return true;
}

inline fn hashKey(key: []const u8, slot_count: usize) usize {
    // if (key.len == 0) return 0;
    // 其实应该插一个assert size是2的倍数，调试模式下激活
    var h: u32 = 2166136261;
    for (key) |byte| {
        h ^= byte;
        h *%= 16777619;
    }

    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;

    return h & (slot_count - 1);
}

// ==========================================================================
// 测试
// ==========================================================================

test "基本生命周期：set / get / contains / modify / delete / count" {
    var hash = try HashTable.initCapacity(std.testing.allocator, 8);
    defer hash.deinit();

    try std.testing.expectEqual(@as(usize, 0), hash.count());
    try std.testing.expectEqual(@as(usize, 8), hash.capacity());

    try std.testing.expectEqual(InsertResult.inserted, try hash.insert("name", "inazuma"));
    try std.testing.expectEqual(InsertResult.inserted, try hash.insert("lang", "zig"));
    try std.testing.expectEqual(@as(usize, 2), hash.count());

    try std.testing.expectEqualStrings("inazuma", hash.get("name").?);
    try std.testing.expect(hash.exist("lang"));
    try std.testing.expect(!hash.exist("missing"));
    try std.testing.expect(hash.get("missing") == null);

    // Key 已存在：不覆盖，保持与 C 版 set 返回 1 的语义一致。
    try std.testing.expectEqual(InsertResult.exists, try hash.insert("name", "other"));
    try std.testing.expectEqualStrings("inazuma", hash.get("name").?);
    try std.testing.expectEqual(@as(usize, 2), hash.count());

    try std.testing.expectEqual(true, try hash.modify("lang", "zig-0.18"));
    try std.testing.expectEqualStrings("zig-0.18", hash.get("lang").?);
    try std.testing.expectEqual(false, try hash.modify("nope", "x"));

    try std.testing.expect(hash.delete("name"));
    try std.testing.expect(!hash.delete("name"));
    try std.testing.expectEqual(@as(usize, 1), hash.count());
    try std.testing.expect(hash.get("name") == null);
}

test "二进制安全：Key/Value 中的 0x00 不会被截断" {
    var hash = try HashTable.initCapacity(std.testing.allocator, 8);
    defer hash.deinit();

    const k1 = "a\x00b";
    const k2 = "a\x00c";
    const v1 = "\x00\x01\x00";
    const v2 = "plain";

    try std.testing.expectEqual(InsertResult.inserted, try hash.insert(k1, v1));
    try std.testing.expectEqual(InsertResult.inserted, try hash.insert(k2, v2));

    try std.testing.expectEqual(@as(usize, 2), hash.count());
    try std.testing.expectEqualSlices(u8, v1, hash.get(k1).?);
    try std.testing.expectEqualSlices(u8, v2, hash.get(k2).?);

    try std.testing.expect(hash.get("a") == null);
    try std.testing.expect(hash.get("a\x00") == null);
    try std.testing.expect(hash.get("a\x00b\x00") == null);

    // 带 0x00 的 Key 同样可以正常删除。
    try std.testing.expect(hash.delete(k1));
    try std.testing.expect(hash.get(k1) == null);
    try std.testing.expectEqualSlices(u8, v2, hash.get(k2).?);
}

test "冲突链表：头插、头删、中间删除、尾删" {
    // 只有 1 个槽位，所有 Key 都会落在同一条链表上。
    var hash = try HashTable.initCapacity(std.testing.allocator, 1);
    defer hash.deinit();

    const keys = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (keys, 0..) |key, i| {
        try std.testing.expectEqual(InsertResult.inserted, try hash.insert(key, keys[i]));
    }
    try std.testing.expectEqual(@as(usize, keys.len), hash.count());

    for (keys) |key| {
        try std.testing.expectEqualStrings(key, hash.get(key).?);
    }

    // 头节点
    try std.testing.expect(hash.delete("e"));
    try std.testing.expectEqual(@as(usize, 4), hash.count());

    // 中间节点
    try std.testing.expect(hash.delete("c"));
    try std.testing.expectEqual(@as(usize, 3), hash.count());

    // 尾节点
    try std.testing.expect(hash.delete("a"));
    try std.testing.expectEqual(@as(usize, 2), hash.count());

    try std.testing.expectEqualStrings("b", hash.get("b").?);
    try std.testing.expectEqualStrings("d", hash.get("d").?);
    try std.testing.expect(hash.get("a") == null);
    try std.testing.expect(hash.get("c") == null);
    try std.testing.expect(hash.get("e") == null);
}

test "modify：原地缩短、容量内扩张、超容量重新分配" {
    var hash = try HashTable.initCapacity(std.testing.allocator, 8);
    defer hash.deinit();

    _ = try hash.insert("k", "0123456789");

    // 原 Value 10 字节，新 Value 3 字节：原地覆写。
    try std.testing.expectEqual(true, try hash.modify("k", "abc"));
    try std.testing.expectEqualStrings("abc", hash.get("k").?);

    // 虽然新值比当前 val_len 长，但仍能放进原来的 10 字节容量：
    // 这是 Zig 版利用 alloc_size 做的额外优化。
    try std.testing.expectEqual(true, try hash.modify("k", "0123456"));
    try std.testing.expectEqualStrings("0123456", hash.get("k").?);

    // 超过原容量：分配新节点并替换。
    try std.testing.expectEqual(true, try hash.modify("k", "0123456789abcdef"));
    try std.testing.expectEqualStrings("0123456789abcdef", hash.get("k").?);
    try std.testing.expectEqual(@as(usize, 1), hash.count());
}

test "连续内存布局：Key 与 Value 紧邻 Node 头部" {
    var hash = try HashTable.initCapacity(std.testing.allocator, 4);
    defer hash.deinit();

    _ = try hash.insert("key", "value");

    const node = hash.nodes[hash.getIdx("key")].?;
    const key = node.loadKey();
    const value = node.loadValue();

    try std.testing.expectEqualStrings("key", key);
    try std.testing.expectEqualStrings("value", value);
    try std.testing.expectEqual(@intFromPtr(value.ptr), @intFromPtr(key.ptr) + key.len);
    try std.testing.expectEqual(@as(usize, @sizeOf(HashNode) + key.len + value.len), node.alloc_size);
}

test "OOM 安全：set 分配失败时不改变表" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var hash = try HashTable.initCapacity(failing.allocator(), 4);
    defer hash.deinit();

    failing.fail_index = failing.alloc_index; // 让下一次分配直接失败
    try std.testing.expectError(error.OutOfMemory, hash.insert("k", "v"));
    try std.testing.expectEqual(@as(usize, 0), hash.count());
    try std.testing.expect(hash.get("k") == null);

    // 关闭故障注入后仍可正常插入。
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(InsertResult.inserted, try hash.insert("k", "v"));
    try std.testing.expectEqualStrings("v", hash.get("k").?);
}

test "OOM 安全：modify 扩容失败时旧值保持有效" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var hash = try HashTable.initCapacity(failing.allocator(), 4);
    defer hash.deinit();

    _ = try hash.insert("k", "old");

    // 新值超过当前容量，必然走重新分配；让这次分配失败。
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, hash.modify("k", "a-much-longer-value"));

    try std.testing.expectEqualStrings("old", hash.get("k").?);
    try std.testing.expectEqual(@as(usize, 1), hash.count());
    try std.testing.expect(hash.delete("k"));
}

test "容量校验：必须是 2 的幂次" {
    try std.testing.expectError(error.InvalidCapacity, HashTable.initCapacity(std.testing.allocator, 0));
    try std.testing.expectError(error.InvalidCapacity, HashTable.initCapacity(std.testing.allocator, 3));
    try std.testing.expectError(error.InvalidCapacity, HashTable.initCapacity(std.testing.allocator, 6));
}

test "deinit 幂等" {
    var hash = try HashTable.initCapacity(std.testing.allocator, 4);
    _ = try hash.insert("k", "v");
    hash.deinit();
    hash.deinit(); // 再次调用不应崩溃，也不应重复释放
    try std.testing.expectEqual(@as(usize, 0), hash.count());
    try std.testing.expectEqual(@as(usize, 0), hash.capacity());
}

test "大量元素与随机查找" {
    var hash = try HashTable.initCapacity(std.testing.allocator, 1024);
    defer hash.deinit();

    var buf: [32]u8 = undefined;
    const n = 5000;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "key-{d}", .{i});
        try std.testing.expectEqual(InsertResult.inserted, try hash.insert(key, key));
    }
    try std.testing.expectEqual(@as(usize, n), hash.count());

    i = 0;
    while (i < n) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "key-{d}", .{i});
        try std.testing.expectEqualStrings(key, hash.get(key).?);
    }

    // 删除偶数 Key，再检查剩余元素。
    i = 0;
    while (i < n) : (i += 2) {
        const key = try std.fmt.bufPrint(&buf, "key-{d}", .{i});
        try std.testing.expect(hash.delete(key));
    }

    i = 0;
    while (i < n) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "key-{d}", .{i});
        if (i % 2 == 0) {
            try std.testing.expect(hash.get(key) == null);
        } else {
            try std.testing.expectEqualStrings(key, hash.get(key).?);
        }
    }
}
