# zdkvstore

Zig 的命名规范可以用一个简单的分类逻辑来概括——**看它"是什么"和"返回什么"**。

## 核心规则

| 类别 | 命名风格 | 例子 |
|---|---|---|
| **类型声明**（struct / enum / union / opaque） | TitleCase（大驼峰） | `Point`, `ArrayList`, `HttpRequest` |
| **可调用且返回类型**的函数（泛型构造器） | TitleCase | `ArrayList(T)`, `ShortList(T, n)` |
| **普通函数 / 方法**（返回非类型） | camelCase（小驼峰） | `print()`, `indexOf()`, `addOne()` |
| **变量 / 常量 / 字段** | snake_case | `user_name`, `max_count`, `field_x` |
| **内置函数**（`@` 开头） | camelCase | `@import()`, `@typeInfo()`, `@fieldParentPtr()` |

## 详细说明

### 1. 类型 → TitleCase
```zig
const User = struct { ... };           // ✅ 类型
pub const Vec3 = struct { x: f32, ... }; // ✅ 类型

// 例外：0 字段的 struct 被视为"命名空间"，用 snake_case
const math_utils = struct {
    pub const pi = 3.14159;
};
```

### 2. 函数 → camelCase（小驼峰）
```zig
fn addOne(x: i32) i32 { ... }          // ✅ 普通函数
fn readU32Be() u32 { ... }              // ✅ 方法

// 结构体方法
const Vec3 = struct {
    x: f32,
    pub fn dot(self: Vec3, other: Vec3) f32 { ... }  // ✅ 方法
};
```

### 3. 变量 / 常量 / 字段 → snake_case
```zig
var global_var: i32 = undefined;        // ✅ 变量
const const_name = 42;                 // ✅ 常量
const string_alias = []u8;              // ✅ 类型别名（snake_case）

const Point = struct {
    x: f32,                             // ✅ 字段
    y: f32,
};
```

### 4. 返回类型的函数（泛型工厂）→ TitleCase
这是 Zig 比较特别的一条规则——**如果一个函数是"用来构造类型的"，就用 TitleCase**，和类型一样对待：

```zig
// 这个函数接收类型参数，返回一个新类型 → 用 TitleCase
fn ArrayList(comptime T: type) type {
    return struct {
        items: []T,
        capacity: usize,
    };
}

// 使用：像类型一样用
const IntList = ArrayList(i32);
```

## 文件和目录命名

- **文件名**分两类：
  - 文件**有字段**（是一个类型）→ `TitleCase.zig`，比如 `ArrayList.zig`
  - 文件**没字段**（是命名空间）→ `snake_case.zig`，比如 `mem.zig`、`http.zig`
- **目录名** → 一律 `snake_case`，比如 `std/net/`, `std/crypto/`

## 首字母缩写词的处理

Zig 的规则很反直觉：**缩写词和普通单词一样对待，不全部大写**。

```zig
// ❌ 不要这样
const HTTPServer = struct { ... };
fn parseHTTPRequest() void { ... }

// ✅ 要这样
const HttpServer = struct { ... };
fn parseHttpRequest() void { ... }

// 数字也一样
fn readU32Be() u32 { ... }   // 不是 readU32BE
```

## 项目名

一般是小写字母，用-连接

## 一张图总结

```
┌─────────────────────────────────────────┐
│  是类型？还是返回类型的函数？            │
│     ├─ 是 → TitleCase（大驼峰）         │
│     └─ 否 → 是函数？                    │
│              ├─ 是 → camelCase（小驼峰） │
│              └─ 否 → snake_case（下划线）│
└─────────────────────────────────────────┘
```

这套规则的好处是：**看到名字的大小写风格，就能立刻判断它是什么东西**——是类型、是函数、还是一个值/变量，不用点进去看定义。
