const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const vk = @import("vulkan");
const tracy = @import("tracy");

comptime {
    switch (builtin.target.os.tag) {
        .linux, .freebsd => {},
        else => |os| @compileError(std.fmt.comptimePrint("Unsupported OS ({s}).", .{@tagName(os)})),
    }
}

pub const VulkanLib = struct {
    handle: std.DynLib,

    pub inline fn init() std.DynLib.Error!@This() {
        const tracy_zone = tracy.zoneNamed(@src(), "VulkanLib.init", .{});
        defer tracy_zone.deinit();

        // https://github.com/zeux/volk/blob/master/volk.c#L101-L105
        const possible_vulkan_lib_paths: []const []const u8 = &.{ "libvulkan.so.1", "libvulkan.so" };
        for (possible_vulkan_lib_paths) |possible_vulkan_lib_path|
            return .{ .handle = std.DynLib.open(possible_vulkan_lib_path) catch continue } // TODO: Retry a few times if temporary error?
        else
            return error.FileNotFound;
    }

    pub inline fn deinit(self: *@This()) void {
        self.handle.close();
    }

    pub inline fn lookup(self: *@This(), comptime T: type, name: [:0]const u8) ?T {
        return self.handle.lookup(T, name);
    }
};

pub const GraphicsContextOptions = struct {
    additional_apis: []const vk.ApiInfo = &.{},
    debugCallback: ?vk.PfnDebugUtilsMessengerCallbackEXT = null,
};

pub fn GraphicsContext(comptime options: GraphicsContextOptions) type {
    const apis = [_]vk.ApiInfo{
        // TODO: List individual functions.
        vk.features.version_1_0,
        // .{
        //     .base_commands = .{
        //         // .getInstanceProcAddr = true,
        //         .enumerateInstanceLayerProperties = true,
        //         .enumerateInstanceExtensionProperties = true,
        //         .createInstance = true,
        //     },
        // },
        vk.extensions.khr_surface,
        // vk.extensions.khr_swapchain,
        // vk.extensions.khr_video_queue,
        // vk.extensions.khr_video_decode_queue,
        // vk.extensions.khr_video_decode_h_264,
        // vk.extensions.khr_video_decode_h_265,
        vk.extensions.khr_wayland_surface,
        if (build_options.validate) vk.extensions.ext_debug_utils else .{},
    } ++ options.additional_apis;

    const BaseDispatch = vk.BaseWrapper(apis);
    const InstanceDispatch = vk.InstanceWrapper(apis);
    const DeviceDispatch = vk.DeviceWrapper(apis);

    return struct {
        vulkan_lib: VulkanLib,

        base_dispatch: BaseDispatch,
        instance_dispatch: InstanceDispatch,
        device_dispatch: DeviceDispatch,

        instance: vk.Instance,
        device: vk.Device,

        debug_messenger: if (build_options.validate) vk.DebugUtilsMessengerEXT else void,

        fn defaultDebugCallback(
            message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
            message_type: vk.DebugUtilsMessageTypeFlagsEXT,
            callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
            user_data: ?*anyopaque,
        ) callconv(.C) vk.Bool32 {
            if (build_options.validate and build_options.tracy.enable) {
                const allocator = @as(*std.mem.Allocator, @alignCast(@ptrCast(user_data.?))).*; // This is so ugly...

                const message = std.fmt.allocPrint(allocator, "{s}: {s}\n\nType: {}\n\nSeverity: {}\n\nData: {}\n", .{
                    switch (message_type.toInt()) {
                        (vk.DebugUtilsMessageTypeFlagsEXT{ .general_bit_ext = true }).toInt() => "General",
                        (vk.DebugUtilsMessageTypeFlagsEXT{ .validation_bit_ext = true }).toInt() => "Validation",
                        (vk.DebugUtilsMessageTypeFlagsEXT{ .performance_bit_ext = true }).toInt() => "Performance",
                        else => "Other",
                    },
                    callback_data.?.p_message.?,
                    message_type,
                    message_severity,
                    callback_data.?.*,
                }) catch return vk.FALSE;
                defer allocator.free(message);
                tracy.messageColor(message, switch (message_severity.toInt()) {
                    (vk.DebugUtilsMessageSeverityFlagsEXT{ .verbose_bit_ext = true }).toInt() => 0x007FFF,
                    (vk.DebugUtilsMessageSeverityFlagsEXT{ .info_bit_ext = true }).toInt() => 0xFFFFFF,
                    (vk.DebugUtilsMessageSeverityFlagsEXT{ .warning_bit_ext = true }).toInt() => 0xFF7F00,
                    (vk.DebugUtilsMessageSeverityFlagsEXT{ .error_bit_ext = true }).toInt() => 0xFF0000,
                    else => 0xFFFFFF,
                }, .{});
            }

            return vk.FALSE;
        }

        pub inline fn init(allocator: std.mem.Allocator) !@This() {
            const tracy_zone = tracy.zoneNamed(@src(), "GraphicsContext.init", .{});
            defer tracy_zone.deinit();

            var vulkan_lib = try VulkanLib.init();
            errdefer vulkan_lib.deinit();

            const getInstanceProcAddr = vulkan_lib.lookup(
                vk.BaseCommandFlags.CmdType(.getInstanceProcAddr),
                vk.BaseCommandFlags.cmdName(.getInstanceProcAddr),
            ) orelse return error.InstanceProcAddrNotFound;
            const getDeviceProcAddr = vulkan_lib.lookup(
                vk.InstanceCommandFlags.CmdType(.getDeviceProcAddr),
                vk.InstanceCommandFlags.cmdName(.getDeviceProcAddr),
            ) orelse return error.DeviceProcAddrNotFound;

            const base_dispatch = try BaseDispatch.load(getInstanceProcAddr);

            const required_layers = if (build_options.validate and false) // TODO
                [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"}
            else
                [_][*:0]const u8{};

            // TODO
            const required_extensions = [_][*:0]const u8{
                // vk.extensions.khr_video_queue.name,
                // vk.extensions.khr_video_decode_queue.name,
                // vk.extensions.khr_video_decode_h_264.name,
                    vk.extensions.khr_surface.name,
                    vk.extensions.khr_wayland_surface.name,
            } ++ if (build_options.validate) [_][*:0]const u8{vk.extensions.ext_debug_utils.name} else [_][*:0]const u8{};

            var stack_fallback = std.heap.stackFallback(std.mem.max(usize, &.{
                std.mem.page_size,
                @sizeOf(vk.LayerProperties) * 32,
                @sizeOf(vk.ExtensionProperties) * 32,
                @sizeOf(vk.PhysicalDevice) * 4,
                @sizeOf(vk.QueueFamilyProperties) * 8,
            }), allocator);
            const stack_fallback_allocator = stack_fallback.get();

            {
                const available_layers = try base_dispatch.enumerateInstanceLayerPropertiesAlloc(stack_fallback_allocator);
                defer stack_fallback_allocator.free(available_layers);

                var required_layer_count: usize = 0;
                for (available_layers) |available_layer| {
                    for (required_layers) |required_layer|
                        if (std.mem.orderZ(u8, @ptrCast(&available_layer.layer_name), required_layer) == .eq) {
                            required_layer_count += 1;
                            break;
                        };
                    if (required_layers.len == required_layer_count) break;
                } else return error.LayerNotPresent;
            }

            {
                const available_extensions = try base_dispatch.enumerateInstanceExtensionPropertiesAlloc(null, stack_fallback_allocator);
                defer stack_fallback_allocator.free(available_extensions);

                var required_extension_count: usize = 0;
                for (available_extensions) |available_extension| {
                    for (required_extensions) |required_extension|
                        if (std.mem.orderZ(u8, @ptrCast(&available_extension.extension_name), required_extension) == .eq) {
                            required_extension_count += 1;
                            break;
                        };
                    if (required_extensions.len == required_extension_count) break;
                } else return error.ExtensionNotPresent;
            }

            const debug_messenger_create_info = if (build_options.validate) vk.DebugUtilsMessengerCreateInfoEXT{
                .message_severity = .{
                    .verbose_bit_ext = true,
                    .info_bit_ext = true,
                    .warning_bit_ext = true,
                    .error_bit_ext = true,
                },
                .message_type = .{
                    .general_bit_ext = true,
                    .validation_bit_ext = true,
                    .performance_bit_ext = true,
                },
                .pfn_user_callback = options.debugCallback orelse defaultDebugCallback,
                .p_user_data = @ptrCast(@constCast(&stack_fallback_allocator)),
            } else {};

            const instance = try base_dispatch.createInstance(&.{
                .p_application_info = &.{
                    .p_application_name = @ptrCast(build_options.name),
                    .application_version = vk.makeApiVersion(0, build_options.version.major, build_options.version.minor, build_options.version.patch),
                    .p_engine_name = @ptrCast(build_options.name),
                    .engine_version = vk.makeApiVersion(0, build_options.version.major, build_options.version.minor, build_options.version.patch),
                    .api_version = vk.API_VERSION_1_0,
                },
                .enabled_layer_count = required_layers.len,
                .pp_enabled_layer_names = &required_layers,
                .enabled_extension_count = required_extensions.len,
                .pp_enabled_extension_names = &required_extensions,
                .p_next = if (build_options.validate) &debug_messenger_create_info else null,
            }, null);

            const instance_dispatch = try InstanceDispatch.load(instance, getInstanceProcAddr);

            errdefer instance_dispatch.destroyInstance(instance, null);

            const debug_messenger = if (build_options.validate) try instance_dispatch.createDebugUtilsMessengerEXT(instance, &debug_messenger_create_info, null) else {};
            errdefer if (build_options.validate) instance_dispatch.destroyDebugUtilsMessengerEXT(instance, debug_messenger, null);

            const physical_device = blk: {
                const physical_devices = try instance_dispatch.enumeratePhysicalDevicesAlloc(instance, stack_fallback_allocator);
                defer stack_fallback_allocator.free(physical_devices);

                var best_physical_device: vk.PhysicalDevice = undefined;
                var best_physical_device_score: usize = 0;
                for (physical_devices) |physical_device| {
                    const properties = instance_dispatch.getPhysicalDeviceProperties(physical_device);
                    // const features = instance_dispatch.getPhysicalDeviceFeatures(physical_device);

                    const score: usize = switch (properties.device_type) {
                        .discrete_gpu => 10_000,
                        .virtual_gpu => 1_000,
                        .integrated_gpu => 100,
                        .cpu, .other => 1,
                        else => 1,
                    };
                    if (score > best_physical_device_score) {
                        best_physical_device = physical_device;
                        best_physical_device_score = score;
                    }
                }
                if (best_physical_device_score == 0) return error.NoSuitablePhysicalDevice;
                break :blk best_physical_device;
            };

            const queue_create_infos, const queue_create_info_count = blk: {
                const queue_families = try instance_dispatch.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, stack_fallback_allocator);
                defer stack_fallback_allocator.free(queue_families);

                var graphics_queue_family_idx: usize = 0;
                var graphics_queue_family_score: usize = 0;
                var transfer_queue_family_idx: usize = 0;
                var transfer_queue_family_score: usize = 0;
                var video_decode_queue_family_idx: usize = 0;
                var video_decode_queue_family_score: usize = 0;
                for (queue_families, 0..) |family, family_idx| {
                    if (family.queue_count > 0 and family.queue_flags.contains(.{ .graphics_bit = true }))
                        if (family.queue_count > graphics_queue_family_score) {
                            graphics_queue_family_idx = family_idx;
                            graphics_queue_family_score = family.queue_count;
                        };
                    if (family.queue_count > 0 and family.queue_flags.contains(.{ .transfer_bit = true }))
                        if (family.queue_count > transfer_queue_family_score) {
                            transfer_queue_family_idx = family_idx;
                            transfer_queue_family_score = family.queue_count;
                        };
                    if (family.queue_count > 0 and family.queue_flags.contains(.{ .video_decode_bit_khr = true }))
                        if (family.queue_count > video_decode_queue_family_score) {
                            video_decode_queue_family_idx = family_idx;
                            video_decode_queue_family_score = family.queue_count;
                        };
                }
                if (graphics_queue_family_score == 0) return error.NoSuitableGraphicsQueueFamily;
                if (transfer_queue_family_score == 0) return error.NoSuitableTransferQueueFamily;
                if (video_decode_queue_family_score == 0) return error.NoSuitableVideoDecodeQueueFamily;
                var queue_create_infos: [3]vk.DeviceQueueCreateInfo = undefined;
                var queue_create_info_count: usize = 0;
                const queue_family_idxs: [3]usize = .{
                    graphics_queue_family_idx,
                    transfer_queue_family_idx,
                    video_decode_queue_family_idx,
                };
                inline for (queue_family_idxs, 0..) |family_idx, create_info_idx| {
                    if (inline for (queue_family_idxs[(create_info_idx + 1)..]) |other_family_idx| {
                        if (family_idx == other_family_idx) break false;
                    } else true) {
                        queue_create_infos[queue_create_info_count] = .{
                            .queue_family_index = @intCast(family_idx),
                            .queue_count = 1,
                            .p_queue_priorities = &.{1.0},
                        };
                        queue_create_info_count += 1;
                    }
                }
                break :blk .{ queue_create_infos, queue_create_info_count };
            };

            const device = try instance_dispatch.createDevice(physical_device, &.{
                .queue_create_info_count = @intCast(queue_create_info_count),
                .p_queue_create_infos = &queue_create_infos,
            }, null);

            const device_dispatch = try DeviceDispatch.load(device, getDeviceProcAddr);

            errdefer device_dispatch.destroyDevice(device, null);

            return .{
                .vulkan_lib = vulkan_lib,

                .base_dispatch = base_dispatch,
                .instance_dispatch = instance_dispatch,
                .device_dispatch = device_dispatch,

                .instance = instance,
                .device = device,

                .debug_messenger = debug_messenger,
            };
        }

        pub inline fn deinit(self: @This()) void {
            defer {
                var vulkan_lib = self.vulkan_lib;
                vulkan_lib.deinit();
            }
            defer self.instance_dispatch.destroyInstance(self.instance, null);
            defer if (build_options.validate) self.instance_dispatch.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
            defer self.device_dispatch.destroyDevice(self.device, null);
        }
    };
}

test {
    @setEvalBranchQuota(1_000_000);
    std.testing.refAllDeclsRecursive(@This());
}

test GraphicsContext {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn closure(allocator: std.mem.Allocator) !void {
            const gc = try GraphicsContext(.{}).init(allocator);
            defer gc.deinit();
        }
    }.closure, .{});
}

pub inline fn mainInner() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const gc = try GraphicsContext(.{}).init(allocator);
    defer gc.deinit();
}

pub fn main() u8 {
    tracy.initGlobal() catch return 1; // TODO: Some form of error handling?

    const tracy_zone = tracy.zone(@src(), .{});
    defer tracy_zone.deinit();

    mainInner() catch |err| {
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();
        nosuspend std.io.getStdErr().writeAll(switch (err) {
            error.OutOfMemory => "Allocation error: Out of memory.\n",
            error.FileNotFound => "Vulkan error: Vulkan lib file not found.\n",
            error.InstanceProcAddrNotFound => "Vulkan error: Instance proc address not found.\n",
            error.DeviceProcAddrNotFound => "Vulkan error: Device proc address not found.\n",
            error.CommandLoadFailure => "Vulkan error: Failed to load command.\n",
            error.OutOfHostMemory => "Vulkan allocation error: Out of host memory.\n",
            error.OutOfDeviceMemory => "Vulkan allocation error: Out of device.\n",
            error.LayerNotPresent => "Vulkan error: Required layer not present.\n",
            error.ExtensionNotPresent => "Vulkan error: Required extension not present.\n",
            error.InitializationFailed => "Vulkan error: Initialization failed.\n",
            error.IncompatibleDriver => "Vulkan error: Incompatible driver.\n",
            error.TooManyObjects => "Vulkan error: Too many objects.\n",
            error.DeviceLost => "Vulkan error: Device lost.\n",
            error.Unknown => "Unknown error.\n",
            inline else => |other_err| "Other error: " ++ @errorName(other_err) ++ ".\n",
        }) catch {};
        return 1;
    };
    return 0;
}
