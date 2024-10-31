# Ricepaper

![License - Apache-2.0 OR MIT](https://img.shields.io/badge/License-Apache--2.0_OR_MIT-blue)
![Made with LOVE](https://img.shields.io/badge/Made_with-LOVE_%3C3-hotpink)

> The code desperately needs a code review from a experienced third party.
> If you're interested in doing that, please feel free to post an issue for any dodgy practises in my code.
>
> If you notice any easily fixable bugs, typos, weird formatting, bad variable names or error messages, create a pull request.

TODO

## Usage

TODO

### Configuration

TODO

### IPC

TODO

## Features

- [ ] Config file
- [ ] SPIR-V fragment shaders
- [ ] Images
- [ ] GIFs
- [ ] Videos
- [ ] Shooth transition effects
- [ ] Vulkan Video backend
- [ ] FFMPEG backend

## Build Dependencies

- Zig 0.14.0 or newer
- pkg-config

## Runtime Dependencies

- Wayland compositor that implements [wlr-layer-shell](https://wayland.app/protocols/wlr-layer-shell-unstable-v1)
- Vulkan SDK

## Similar projects

- [glshell](https://github.com/Duckonaut/glshell)
- [swww - A Solution to your Wayland Wallpaper Woes](https://github.com/LGFae/swww)
- [mpvpaper](https://github.com/GhostNaN/mpvpaper)
- [And more...](https://github.com/rcalixte/awesome-wayland#wallpaper)

## Benchmarking

To profile ricepaper using [Tracy profiler](https://github.com/wolfpld/tracy) build it with the `-Dtracy` flag.

## Contributing

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

## License

Ricepaper is licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or [https://www.apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0))
- MIT license ([LICENSE-MIT](LICENSE-MIT) or [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT))

at your option.

It uses several third-party projects. Here is a list of them along with their respective licenses:

- [shimizu](https://git.sr.ht/~geemili/shimizu): [MIT license](https://git.sr.ht/~geemili/shimizu/tree/dev/item/LICENSE)
- [Wayland protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols): [MIT license](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/COPYING)
- [wlr-protocols](https://gitlab.freedesktop.org/wlroots/wlr-protocols): No license
- [vulkan-zig](https://github.com/Snektron/vulkan-zig): [MIT license](https://github.com/Snektron/vulkan-zig/blob/master/LICENSE)
- [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers): [Apache-2.0 or MIT license](https://github.com/KhronosGroup/Vulkan-Headers/blob/main/LICENSE.md)
- [Tracy](https://github.com/wolfpld/tracy): [3-clause BSD license](https://github.com/wolfpld/tracy/blob/master/LICENSE)
