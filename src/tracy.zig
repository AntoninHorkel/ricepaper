const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const c = @cImport(if (build_options.tracy.enable) {
    @cDefine("TRACY_ENABLE", "1");
    @cInclude("TracyC.h");
});

comptime {
    switch (builtin.target.os.tag) {
        .linux, .freebsd => {},
        else => |os| @compileError(std.fmt.comptimePrint("Unsupported OS ({s}).", .{@tagName(os)})),
    }
}

var bindings: struct {
    ___tracy_emit_zone_begin: *const @TypeOf(c.___tracy_emit_zone_begin),
    ___tracy_emit_zone_begin_callstack: *const @TypeOf(c.___tracy_emit_zone_begin_callstack),
    ___tracy_emit_zone_end: *const @TypeOf(c.___tracy_emit_zone_end),
    ___tracy_emit_zone_name: *const @TypeOf(c.___tracy_emit_zone_name),
    ___tracy_emit_zone_color: *const @TypeOf(c.___tracy_emit_zone_color),
    ___tracy_emit_zone_value: *const @TypeOf(c.___tracy_emit_zone_value),
    ___tracy_emit_zone_text: *const @TypeOf(c.___tracy_emit_zone_text),
    ___tracy_emit_message: *const @TypeOf(c.___tracy_emit_message),
    ___tracy_emit_messageC: *const @TypeOf(c.___tracy_emit_messageC),
    ___tracy_emit_messageL: *const @TypeOf(c.___tracy_emit_messageL),
    ___tracy_emit_messageLC: *const @TypeOf(c.___tracy_emit_messageLC),
} = undefined;

pub inline fn initGlobal() (std.DynLib.Error || error{ProcNotFound})!void {
    if (!build_options.tracy.link) {
        // https://github.com/oven-sh/bun/blob/main/src/tracy.zig#L520-L529
        const possible_tracy_lib_paths: []const []const u8 = &.{
            "/usr/local/lib/libtracy.so",
            "/usr/local/opt/tracy/lib/libtracy.so",
            "/opt/tracy/lib/libtracy.so",
            "/usr/lib/libtracy.so",
            "/usr/local/lib/libTracyClient.so",
            "/usr/local/opt/tracy/lib/libTracyClient.so",
            "/opt/tracy/lib/libTracyClient.so",
            "/usr/lib/libTracyClient.so",
            "libtracy.so",
            "libTracyClient.so",
        };
        for (possible_tracy_lib_paths) |possible_tracy_lib_path| {
            var handle = std.DynLib.open(possible_tracy_lib_path) catch continue; // TODO: Retry a few times if temporary error?
            defer handle.close();
            bindings = .{
                .___tracy_emit_zone_begin = handle.lookup(*const @TypeOf(c.___tracy_emit_zone_begin), "___tracy_emit_zone_begin") orelse return error.ProcNotFound,
                .___tracy_emit_zone_begin_callstack = handle.lookup(*const @TypeOf(c.___tracy_emit_zone_begin_callstack), "___tracy_emit_zone_begin_callstack") orelse return error.ProcNotFound,
                .___tracy_emit_zone_end = handle.lookup(*const @TypeOf(c.___tracy_emit_zone_end), "___tracy_emit_zone_end") orelse return error.ProcNotFound,
                .___tracy_emit_zone_name = handle.lookup(*const @TypeOf(c.___tracy_emit_zone_name), "___tracy_emit_zone_name") orelse return error.ProcNotFound,
                .___tracy_emit_zone_color = handle.lookup(*const @TypeOf(c.___tracy_emit_zone_color), "___tracy_emit_zone_color") orelse return error.ProcNotFound,
                .___tracy_emit_zone_value = handle.lookup(*const @TypeOf(c.___tracy_emit_zone_value), "___tracy_emit_zone_value") orelse return error.ProcNotFound,
                .___tracy_emit_zone_text = handle.lookup(*const @TypeOf(c.___tracy_emit_zone_text), "___tracy_emit_zone_text") orelse return error.ProcNotFound,
                .___tracy_emit_message = handle.lookup(*const @TypeOf(c.___tracy_emit_message), "___tracy_emit_message") orelse return error.ProcNotFound,
                .___tracy_emit_messageC = handle.lookup(*const @TypeOf(c.___tracy_emit_messageC), "___tracy_emit_messageC") orelse return error.ProcNotFound,
                .___tracy_emit_messageL = handle.lookup(*const @TypeOf(c.___tracy_emit_messageL), "___tracy_emit_messageL") orelse return error.ProcNotFound,
                .___tracy_emit_messageLC = handle.lookup(*const @TypeOf(c.___tracy_emit_messageLC), "___tracy_emit_messageLC") orelse return error.ProcNotFound,
            };
            break;
        } else return error.FileNotFound;
    } else bindings = .{
        .___tracy_emit_zone_begin = c.___tracy_emit_zone_begin,
        .___tracy_emit_zone_begin_callstack = c.___tracy_emit_zone_begin_callstack,
        .___tracy_emit_zone_end = c.___tracy_emit_zone_end,
        .___tracy_emit_zone_name = c.___tracy_emit_zone_name,
        .___tracy_emit_zone_color = c.___tracy_emit_zone_color,
        .___tracy_emit_zone_value = c.___tracy_emit_zone_value,
        .___tracy_emit_zone_text = c.___tracy_emit_zone_text,
        .___tracy_emit_message = c.___tracy_emit_message,
        .___tracy_emit_messageC = c.___tracy_emit_messageC,
        .___tracy_emit_messageL = c.___tracy_emit_messageL,
        .___tracy_emit_messageLC = c.___tracy_emit_messageLC,
    };
}

pub const Options = struct {
    enable_callstack: bool = true,
    callstack_depth: c_int = 16,
};

pub const Zone = if (build_options.tracy.enable)
    struct {
        ctx: c.___tracy_c_zone_context,

        pub inline fn init(comptime src: std.builtin.SourceLocation, options: Options) @This() {
            const loc: c.___tracy_source_location_data = .{
                .name = null,
                .function = src.fn_name.ptr,
                .file = src.file.ptr,
                .line = src.line,
                .color = 0,
            };
            return if (options.enable_callstack)
                .{ .ctx = bindings.___tracy_emit_zone_begin_callstack(&loc, options.callstack_depth, 1) }
            else
                .{ .ctx = bindings.___tracy_emit_zone_begin(&loc, 1) };
        }

        pub inline fn initNamed(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8, options: Options) @This() {
            const loc: c.___tracy_source_location_data = .{
                .name = name.ptr,
                .function = src.fn_name.ptr,
                .file = src.file.ptr,
                .line = src.line,
                .color = 0,
            };
            return if (options.enable_callstack)
                .{ .ctx = bindings.___tracy_emit_zone_begin_callstack(&loc, options.callstack_depth, 1) }
            else
                .{ .ctx = bindings.___tracy_emit_zone_begin(&loc, 1) };
        }

        pub inline fn deinit(self: @This()) void {
            bindings.___tracy_emit_zone_end(self.ctx);
        }

        pub inline fn setName(self: @This(), name: []const u8) void {
            bindings.___tracy_emit_zone_name(self.ctx, name.ptr, name.len);
        }

        pub inline fn setColor(self: @This(), color: u32) void {
            bindings.___tracy_emit_zone_color(self.ctx, color);
        }

        pub inline fn setValue(self: @This(), value: u64) void {
            bindings.___tracy_emit_zone_value(self.ctx, value);
        }

        pub inline fn addText(self: @This(), text: []const u8) void {
            bindings.___tracy_emit_zone_text(self.ctx, text.ptr, text.len);
        }
    }
else
    struct {
        ctx: void,

        pub inline fn init(comptime src: std.builtin.SourceLocation, options: Options) @This() {
            _ = src;
            _ = options;
            return .{ .ctx = {} };
        }

        pub inline fn initNamed(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8, options: Options) @This() {
            _ = src;
            _ = name;
            _ = options;
            return .{ .ctx = {} };
        }

        pub inline fn deinit(self: @This()) void {
            _ = self;
        }

        pub inline fn setName(self: @This(), name: []const u8) void {
            _ = self;
            _ = name;
        }

        pub inline fn setColor(self: @This(), color: u32) void {
            _ = self;
            _ = color;
        }

        pub inline fn setValue(self: @This(), value: u64) void {
            _ = self;
            _ = value;
        }

        pub inline fn addText(self: @This(), text: []const u8) void {
            _ = self;
            _ = text;
        }
    };
pub const zone = Zone.init;
pub const zoneNamed = Zone.initNamed;

pub const Messager = if (build_options.tracy.enable)
    struct {
        pub inline fn message(msg: []const u8, options: Options) void {
            bindings.___tracy_emit_message(msg.ptr, msg.len, if (options.enable_callstack) options.callstack_depth else 0);
        }

        /// Color format is RGB.
        pub inline fn messageColor(msg: []const u8, color: u32, options: Options) void {
            bindings.___tracy_emit_messageC(msg.ptr, msg.len, color, if (options.enable_callstack) options.callstack_depth else 0);
        }

        pub inline fn messageZ(msg: [:0]const u8, options: Options) void {
            bindings.___tracy_emit_messageL(msg.ptr, if (options.enable_callstack) options.callstack_depth else 0);
        }

        /// Color format is RGB.
        pub inline fn messageColorZ(msg: [*:0]const u8, color: u32, options: Options) void {
            bindings.___tracy_emit_messageLC(msg, color, if (options.enable_callstack) options.callstack_depth else 0);
        }
    }
else
    struct {
        pub inline fn message(msg: []const u8, options: Options) void {
            _ = msg;
            _ = options;
        }

        /// Color format is RGB.
        pub inline fn messageColor(msg: []const u8, color: u32, options: Options) void {
            _ = msg;
            _ = color;
            _ = options;
        }

        pub inline fn messageZ(msg: [:0]const u8, options: Options) void {
            _ = msg;
            _ = options;
        }

        /// Color format is RGB.
        pub inline fn messageColorZ(msg: [:0]const u8, color: u32, options: Options) void {
            _ = msg;
            _ = color;
            _ = options;
        }
    };
pub usingnamespace Messager;
