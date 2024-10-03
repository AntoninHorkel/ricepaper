# Ricepaper

![License - Apache-2.0 OR MIT](https://img.shields.io/badge/License-Apache--2.0_OR_MIT-blue)
![Made with LOVE](https://img.shields.io/badge/Made_with-LOVE_%3C3-hotpink)

TODO

## Style Guide

Adhere to the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide).
Use [ZLS](https://github.com/zigtools/zls) to auto-format code.
In addition:
```zig
// Use this:
const x: Foo = .{ .bar = 0 };
const y: []const []const u8 = &.{ "hello", "world!" };
// Not that:
const x = Foo{ .bar = 0 };
const y = [_][]const u8{ "hello", "world!" };

// Use this:
pub fn fun(self: @This()) void {}
// Not that:
pub fn fun(self: Self) void {}
pub fn fun(self: Foo) void {}

// Use this:
pub fn fun(foo: Foo) void {
    _ = foo;
}
// Not this:
pub fn fun(_: Foo) void {}

// Use this:
const foo = import("foo.zig");
foo.bar();
// Not that:
const bar = import("foo.zig").bar;
bar();

// Use this:
const Foo = import("foo.zig").Foo;
// Not that:
const Foo = import("Foo.zig");
```
