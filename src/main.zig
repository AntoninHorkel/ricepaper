const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");
// const shimizu = @import("shimizu");
const vk = @import("vulkan");
const tracy = @import("tracy");

comptime {
    switch (builtin.target.os.tag) {
        .linux, .freebsd => {},
        else => |os| @compileError(std.fmt.comptimePrint("Unsupported OS ({s}).", .{@tagName(os)})),
    }
}

test {
    @setEvalBranchQuota(1_000_000);
    std.testing.refAllDeclsRecursive(@This());
}

test renderLoop {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, renderLoop, .{});
}

const std_options = .{
    .log_level = .debug,
    .logFn = struct {
        pub fn closure(
            comptime level: std.log.Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            std.debug.lockStdErr();
            defer std.debug.unlockStdErr();
            nosuspend std.io.getStdErr().writer().print(level.asText() ++ if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): " ++ format ++ "\n", args) catch {};
        }
    }.closure,
};

const log = std.log.scoped(.ricepaper);

const apis = &(.{
    // TODO: List individual functions.
    vk.features.version_1_0,
    vk.extensions.khr_surface,
    vk.extensions.khr_wayland_surface,
    vk.extensions.khr_swapchain,
    // vk.extensions.khr_video_queue,
    // vk.extensions.khr_video_decode_queue,
    // vk.extensions.khr_video_decode_h_264,
    // vk.extensions.khr_video_decode_h_265,
    // vk.extensions.khr_sampler_ycbcr_conversion,
} ++ if (build_options.validate) .{vk.extensions.ext_debug_utils} else .{});

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);
const Queue = vk.QueueProxy(apis);
const CommandBuffer = vk.CommandBufferProxy(apis);

const VulkanLib = struct {
    handle: std.DynLib,

    pub inline fn init(allocator: std.mem.Allocator) std.DynLib.Error!@This() {
        const tracy_zone = tracy.zoneNamed(@src(), "VulkanLib.init", .{});
        defer tracy_zone.deinit();

        // https://github.com/zeux/volk/blob/master/volk.c#L101-L105
        const possible_vulkan_lib_paths: []const []const u8 = &.{ "libvulkan.so.1", "libvulkan.so" };
        for (possible_vulkan_lib_paths) |possible_vulkan_lib_path|
            return .{ .handle = std.DynLib.open(possible_vulkan_lib_path) catch continue }; // TODO: Retry a few times if temporary error?

        const possible_vulkan_env_vars: []const []const u8 = &.{ "VULKAN_SDK", "VK_SDK_PATH" };
        for (possible_vulkan_env_vars) |possible_vulkan_env_var| {
            const possible_vulkan_lib_path = std.fs.path.join(allocator, &.{ std.posix.getenv(possible_vulkan_env_var) orelse continue, "lib" }) catch continue;
            defer allocator.free(possible_vulkan_lib_path);
            return .{ .handle = std.DynLib.open(possible_vulkan_lib_path) catch continue };
        }

        return error.FileNotFound;
    }

    pub inline fn deinit(self: *@This()) void {
        self.handle.close();
    }

    pub inline fn lookup(self: *@This(), comptime T: type, name: [:0]const u8) ?T {
        return self.handle.lookup(T, name);
    }
};

inline fn renderLoop(allocator: std.mem.Allocator) !void {
    // Number of instance layers (https://vulkan.gpuinfo.org/listinstancelayers.php?platform=linux) with more than 25% support: ~20.
    // Number of instance extensions (https://vulkan.gpuinfo.org/listinstanceextensions.php?platform=linux) with more than 25% support: ~20.
    // Number of device extensions (https://vulkan.gpuinfo.org/listextensions.php?platform=linux) with more than 25% support: ~128.
    // Number of surface formats (https://vulkan.gpuinfo.org/listsurfaceformats.php?platform=linux) with more than 25% support: ~2.
    // Number of surface present modes (https://vulkan.gpuinfo.org/listsurfacepresentmodes.php?platform=linux) with more than 25% support: ~4.
    // Reserves ~33kB of stack memory.
    var stack_fallback = std.heap.stackFallback(std.mem.max(usize, &.{
        std.mem.page_size,
        @sizeOf(vk.LayerProperties) * 32,
        @sizeOf(vk.ExtensionProperties) * 128,
        @sizeOf(vk.PhysicalDevice) * 4,
        @sizeOf(vk.QueueFamilyProperties) * 8,
        @sizeOf(vk.SurfaceFormatKHR) * 4,
        @sizeOf(vk.PresentModeKHR) * 4,
        @sizeOf(vk.Image) * 4,
        @sizeOf(vk.ImageView) * 4,
        @sizeOf(vk.Framebuffer) * 4,
        @sizeOf(vk.CommandBuffer) * 4,
    }), allocator);
    const stack_fallback_allocator = stack_fallback.get();

    var vulkan_lib = try VulkanLib.init(stack_fallback_allocator);
    defer vulkan_lib.deinit();

    const getInstanceProcAddr = vulkan_lib.lookup(
        vk.BaseCommandFlags.CmdType(.getInstanceProcAddr),
        vk.BaseCommandFlags.cmdName(.getInstanceProcAddr),
    ) orelse return error.InstanceProcAddrNotFound;
    const getDeviceProcAddr = vulkan_lib.lookup(
        vk.InstanceCommandFlags.CmdType(.getDeviceProcAddr),
        vk.InstanceCommandFlags.cmdName(.getDeviceProcAddr),
    ) orelse return error.DeviceProcAddrNotFound;

    const base_dispatch = try BaseDispatch.load(getInstanceProcAddr);

    // https://vulkan.gpuinfo.org/listinstancelayers.php?platform=linux
    const required_instance_layers = if (build_options.validate and false) // TODO: Layers are not guaranteed to be present.
        [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"}
    else
        [_][*:0]const u8{};
    {
        const available_instance_layers = try base_dispatch.enumerateInstanceLayerPropertiesAlloc(stack_fallback_allocator);
        defer stack_fallback_allocator.free(available_instance_layers);

        var available_instance_layer_count: usize = 0;
        for (available_instance_layers) |available_layer| {
            for (required_instance_layers) |required_layer|
                if (std.meta.eql(required_layer, @ptrCast(&available_layer.layer_name))) {
                    available_instance_layer_count += 1;
                    break;
                };
            if (required_instance_layers.len == available_instance_layer_count) break;
        } else return error.RequiredInstanceLayerNotPresent;
    }

    // https://vulkan.gpuinfo.org/listinstanceextensions.php?platform=linux
    const required_instance_extensions = [_][*:0]const u8{
        vk.extensions.khr_surface.name,
        vk.extensions.khr_wayland_surface.name,
    } ++ if (build_options.validate) [_][*:0]const u8{vk.extensions.ext_debug_utils.name} else [_][*:0]const u8{};
    {
        const available_instance_extensions = try base_dispatch.enumerateInstanceExtensionPropertiesAlloc(null, stack_fallback_allocator);
        defer stack_fallback_allocator.free(available_instance_extensions);

        var available_instance_extension_count: usize = 0;
        for (available_instance_extensions) |available_extension| {
            for (required_instance_extensions) |required_extension|
                if (std.meta.eql(required_extension, @ptrCast(&available_extension.extension_name))) {
                    available_instance_extension_count += 1;
                    break;
                };
            if (required_instance_extensions.len == available_instance_extension_count) break;
        } else return error.RequiredInstanceExtensionNotPresent;
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
        .pfn_user_callback = struct {
            pub fn debugCallback(
                message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
                message_type: vk.DebugUtilsMessageTypeFlagsEXT,
                callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
                user_data: ?*anyopaque,
            ) callconv(.C) vk.Bool32 {
                if (build_options.validate) {
                    if (build_options.tracy.enable) {
                        const validation_allocator = @as(*std.mem.Allocator, @alignCast(@ptrCast(user_data.?))).*; // This is so ugly...

                        const message = std.fmt.allocPrint(validation_allocator, "{s}: {s}\n\nType: {}\n\nSeverity: {}\n\nData: {}\n", .{
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
                        defer validation_allocator.free(message);
                        tracy.messageColor(message, switch (message_severity.toInt()) {
                            (vk.DebugUtilsMessageSeverityFlagsEXT{ .verbose_bit_ext = true }).toInt() => 0x007FFF,
                            (vk.DebugUtilsMessageSeverityFlagsEXT{ .info_bit_ext = true }).toInt() => 0xFFFFFF,
                            (vk.DebugUtilsMessageSeverityFlagsEXT{ .warning_bit_ext = true }).toInt() => 0xFF7F00,
                            (vk.DebugUtilsMessageSeverityFlagsEXT{ .error_bit_ext = true }).toInt() => 0xFF0000,
                            else => 0xFFFFFF,
                        }, .{});
                    } else {
                        const validation_log = std.log.scoped(.@"ricepaper validation");

                        const logFn = switch (message_severity.toInt()) {
                            (vk.DebugUtilsMessageSeverityFlagsEXT{ .verbose_bit_ext = true }).toInt() => validation_log.debug,
                            (vk.DebugUtilsMessageSeverityFlagsEXT{ .info_bit_ext = true }).toInt() => validation_log.info,
                            (vk.DebugUtilsMessageSeverityFlagsEXT{ .warning_bit_ext = true }).toInt() => validation_log.warn,
                            (vk.DebugUtilsMessageSeverityFlagsEXT{ .error_bit_ext = true }).toInt() => validation_log.err,
                            else => validation_log.info,
                        };
                        logFn("{s}: {s}\n\nType: {}\n\nSeverity: {}\n\nData: {}", .{
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
                        });
                    }
                }

                return vk.FALSE;
            }
        }.debugCallback,
        .p_user_data = @ptrCast(@constCast(&stack_fallback_allocator)),
    } else {};

    const instance_handle = try base_dispatch.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = @ptrCast(build_options.name),
            .application_version = vk.makeApiVersion(0, build_options.version.major, build_options.version.minor, build_options.version.patch),
            .p_engine_name = @ptrCast(build_options.name),
            .engine_version = vk.makeApiVersion(0, build_options.version.major, build_options.version.minor, build_options.version.patch),
            .api_version = vk.API_VERSION_1_0,
        },
        .enabled_layer_count = required_instance_layers.len,
        .pp_enabled_layer_names = &required_instance_layers,
        .enabled_extension_count = required_instance_extensions.len,
        .pp_enabled_extension_names = &required_instance_extensions,
        .p_next = if (build_options.validate) &debug_messenger_create_info else null,
    }, null);
    const instance_dispatch = try InstanceDispatch.load(instance_handle, getInstanceProcAddr);
    const instance = Instance.init(instance_handle, &instance_dispatch);
    defer instance.destroyInstance(null);

    const debug_messenger = if (build_options.validate) try instance.createDebugUtilsMessengerEXT(&debug_messenger_create_info, null) else {};
    defer if (build_options.validate) instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

    const physical_device, const physical_device_features = blk: {
        const physical_devices = try instance.enumeratePhysicalDevicesAlloc(stack_fallback_allocator);
        defer stack_fallback_allocator.free(physical_devices);

        var best_physical_device: vk.PhysicalDevice = undefined;
        var best_physical_device_features: vk.PhysicalDeviceFeatures = undefined;
        var best_physical_device_score: usize = 0;
        for (physical_devices) |physical_device| {
            // TODO: Check common devices from https://store.steampowered.com/hwsurvey/videocard/ on https://vulkan.gpuinfo.org/listdevices.php?platform=linux or sort by count.

            const properties = instance.getPhysicalDeviceProperties(physical_device); // https://vulkan.gpuinfo.org/listpropertiescore10.php?platform=linux
            const features = instance.getPhysicalDeviceFeatures(physical_device); // https://vulkan.gpuinfo.org/listfeaturescore10.php?platform=linux

            // https://vulkan.gpuinfo.org/displaycoreproperty.php?platform=linux&name=devicetype
            // https://vulkan.gpuinfo.org/displaydevicelimit.php?name=maxImageDimension2D&platform=linux
            // https://docs.vulkan.org/guide/latest/robustness.html
            // https://registry.khronos.org/vulkan/specs/1.3-extensions/html/vkspec.html#textures-texel-anisotropic-filtering
            const score: usize = @as(usize, switch (properties.device_type) {
                .discrete_gpu => 16 + properties.limits.max_image_dimension_2d,
                .virtual_gpu => 12,
                .integrated_gpu => 8,
                .cpu => 4,
                else => 1,
            }) + @as(usize, if (features.robust_buffer_access == vk.TRUE) 1 else 0) + @as(usize, if (features.sampler_anisotropy == vk.TRUE) 1 else 0);
            if (score > best_physical_device_score) {
                best_physical_device = physical_device;
                best_physical_device_features = .{
                    .robust_buffer_access = features.robust_buffer_access,
                    .sampler_anisotropy = features.sampler_anisotropy,
                };
                best_physical_device_score = score;
            }
        }

        if (best_physical_device_score == 0) return error.NoSuitablePhysicalDevice;

        break :blk .{ best_physical_device, best_physical_device_features };
    };

    const surface = try instance.createWaylandSurfaceKHR(&.{
        .display = undefined, // TODO
        .surface = undefined, // TODO
    }, null);
    defer instance.destroySurfaceKHR(surface, null);

    const required_device_layers = required_instance_layers;
    {
        const available_device_layers = try instance.enumerateDeviceLayerPropertiesAlloc(physical_device, stack_fallback_allocator);
        defer stack_fallback_allocator.free(available_device_layers);

        var available_device_layer_count: usize = 0;
        for (available_device_layers) |available_layer| {
            for (required_device_layers) |required_layer|
                if (std.meta.eql(required_layer, @ptrCast(&available_layer.layer_name))) {
                    available_device_layer_count += 1;
                    break;
                };
            if (required_device_layers.len == available_device_layer_count) break;
        } else return error.RequiredDeviceLayerNotPresent;
    }

    // This could be done in the physical device selection loop, so if the selected physical device doesn't support the required extensions,
    // we could fallback to another one, but VK_KHR_swapchain extension has 100% support anyway so it's not really necessary.
    // https://vulkan.gpuinfo.org/listextensions.php?platform=linux
    const required_device_extensions = [_][*:0]const u8{
        vk.extensions.khr_swapchain.name,
        // vk.extensions.khr_video_queue.name,
        // vk.extensions.khr_video_decode_queue.name,
        // vk.extensions.khr_video_decode_h_264.name,
        // vk.extensions.khr_video_decode_h_265.name,
        // vk.extensions.khr_sampler_ycbcr_conversion.name,
    };
    {
        const available_device_extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(physical_device, null, stack_fallback_allocator);
        defer stack_fallback_allocator.free(available_device_extensions);

        var available_device_extension_count: usize = 0;
        for (available_device_extensions) |available_extension| {
            for (required_device_extensions) |required_extension|
                if (std.meta.eql(required_extension, @ptrCast(&available_extension.extension_name))) {
                    available_device_extension_count += 1;
                    break;
                };
            if (required_device_extensions.len == available_device_extension_count) break;
        } else return error.RequiredDeviceExtensionNotPresent;
    }

    const QueueFamilies = struct {
        graphics: u32 = 0,
        present: u32 = 0,
        // transfer: u32 = 0,
        // video_decode: u32 = 0,
    };

    const queue_family_idxs = blk: {
        const queue_families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, stack_fallback_allocator);
        defer stack_fallback_allocator.free(queue_families);

        var queue_family_idxs: QueueFamilies = .{};
        var queue_family_scores: QueueFamilies = .{};

        // TODO: Scores shouldn't be based on queue count since we only ever use 1 queue.
        for (queue_families, 0..) |family, family_idx| {
            if (family.queue_flags.graphics_bit)
                if (family.queue_count > queue_family_scores.graphics) {
                    queue_family_idxs.graphics = @intCast(family_idx);
                    queue_family_scores.graphics = family.queue_count;
                };
            if (try instance.getPhysicalDeviceSurfaceSupportKHR(physical_device, @intCast(family_idx), surface) == vk.TRUE)
                if (family.queue_count > queue_family_scores.present) {
                    queue_family_idxs.present = @intCast(family_idx);
                    queue_family_scores.present = family.queue_count;
                };
            // if (family.queue_flags.transfer_bit)
            //     if (family.queue_count > queue_family_scores.transfer) {
            //         queue_family_idxs.transfer = @intCast(family_idx);
            //         queue_family_scores.transfer = family.queue_count;
            //     };
            // if (family.queue_flags.video_decode_bit_khr)
            //     if (family.queue_count > queue_family_scores.video_decode) {
            //         queue_family_idxs.video_decode = @intCast(family_idx);
            //         queue_family_scores.video_decode = family.queue_count;
            //     };
        }

        if (queue_family_scores.graphics == 0) return error.NoSuitableGraphicsQueueFamily;
        if (queue_family_scores.present == 0) return error.NoSuitablePresentQueueFamily;
        // if (queue_family_scores.transfer == 0) return error.NoSuitableTransferQueueFamily;
        // if (queue_family_scores.video_decode == 0) return error.NoSuitableVideoDecodeQueueFamily;

        break :blk queue_family_idxs;
    };

    const queue_create_infos, const queue_create_info_count = blk: {
        var queue_create_infos: [2]vk.DeviceQueueCreateInfo = undefined;
        var queue_create_info_idx: usize = 0;
        const queue_family_idxs_arr: [2]u32 = .{ queue_family_idxs.graphics, queue_family_idxs.present };
        inline for (queue_family_idxs_arr, 0..) |family_idx, create_info_idx| {
            if (inline for (queue_family_idxs_arr[(create_info_idx + 1)..]) |other_family_idx| {
                if (family_idx == other_family_idx) break false;
            } else true) {
                queue_create_infos[queue_create_info_idx] = .{
                    .queue_family_index = @intCast(family_idx),
                    .queue_count = 1,
                    .p_queue_priorities = &.{1.0},
                };
                queue_create_info_idx += 1;
            }
        }
        break :blk .{ queue_create_infos, @as(u32, @intCast(queue_create_info_idx)) };
    };

    const device_handle = try instance.createDevice(physical_device, &.{
        .queue_create_info_count = queue_create_info_count,
        .p_queue_create_infos = &queue_create_infos,
        .enabled_layer_count = required_device_layers.len,
        .pp_enabled_layer_names = &required_device_layers,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = &required_device_extensions,
        .p_enabled_features = &physical_device_features,
    }, null);
    const device_dispatch = try DeviceDispatch.load(device_handle, getDeviceProcAddr);
    const device = Device.init(device_handle, &device_dispatch);
    defer device.destroyDevice(null);

    const present_queue_handle = device.getDeviceQueue(queue_family_idxs.present, 0);
    const present_queue = Queue.init(present_queue_handle, &device_dispatch);

    const graphics_queue_handle = device.getDeviceQueue(queue_family_idxs.graphics, 0);
    const graphics_queue = Queue.init(graphics_queue_handle, &device_dispatch);

    const surface_capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);

    // https://vulkan.gpuinfo.org/listsurfaceformats.php?platform=linux
    const surface_format = blk: {
        const available_surface_formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, stack_fallback_allocator);
        defer stack_fallback_allocator.free(available_surface_formats);

        var best_surface_format: vk.SurfaceFormatKHR = undefined;
        var best_surface_format_score: usize = 0;
        for (available_surface_formats) |format| {
            const score: usize = @as(usize, switch (format.format) { // TODO
                .b8g8r8a8_unorm => 9,
                .b8g8r8a8_srgb => 7,
                .r8g8b8a8_unorm => 5,
                .r8g8b8a8_srgb => 3,
                else => 1,
            }) + @as(usize, switch (format.color_space) {
                .srgb_nonlinear_khr => 1,
                else => 0,
            });
            if (score > best_surface_format_score) {
                best_surface_format = format;
                best_surface_format_score = score;
            }
        }

        // There has to be at least 1 surface format according to Vulkan spec, so this shouldn't be necessary.
        if (best_surface_format_score == 0) return error.NoSuitableSurfaceFormat;

        break :blk best_surface_format;
    };

    // https://vulkan.gpuinfo.org/listsurfacepresentmodes.php?platform=linux
    // https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/VkPresentModeKHR.html
    const surface_present_mode = blk: {
        const available_surface_present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(physical_device, surface, stack_fallback_allocator);
        defer stack_fallback_allocator.free(available_surface_present_modes);

        var best_surface_present_mode: vk.PresentModeKHR = undefined;
        var best_surface_present_mode_score: usize = 0;
        for (available_surface_present_modes) |present_mode| {
            const score: usize = switch (present_mode) {
                .mailbox_khr => 4,
                .fifo_khr => 3,
                .fifo_relaxed_khr => 2,
                .immediate_khr => 1,
                else => 0, // TODO: Aren't other present modes suitable?
            };
            if (score > best_surface_present_mode_score) {
                best_surface_present_mode = present_mode;
                best_surface_present_mode_score = score;
            }
        }

        // TODO: Does spec guarantee any present modes? If yes, fix error message.
        if (best_surface_present_mode_score == 0) return error.NoSuitableSurfacePresentMode;

        break :blk best_surface_present_mode;
    };

    const swapchain_extent = .{
        .width = std.math.clamp(1920, surface_capabilities.min_image_extent.width, surface_capabilities.max_image_extent.width), // TODO
        .height = std.math.clamp(1080, surface_capabilities.min_image_extent.height, surface_capabilities.max_image_extent.height), // TODO
    };

    const swapchain = try device.createSwapchainKHR(&.{
        .surface = surface,
        .min_image_count = std.math.clamp(@as(u32, switch (surface_present_mode) {
            .mailbox_khr => 4,
            .fifo_khr => 3,
            .fifo_relaxed_khr => 3,
            .immediate_khr => 1,
            else => 3,
        }), surface_capabilities.min_image_count, if (surface_capabilities.max_image_count == 0) std.math.maxInt(u32) else surface_capabilities.max_image_count),
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = swapchain_extent,
        .image_array_layers = 1,
        .image_usage = if (surface_capabilities.supported_usage_flags.color_attachment_bit) .{ .color_attachment_bit = true } else return error.RequiredImageUsageFlagNotPresent,
        .image_sharing_mode = if (queue_family_idxs.graphics == queue_family_idxs.present) .exclusive else .concurrent,
        .queue_family_index_count = if (queue_family_idxs.graphics == queue_family_idxs.present) 0 else 2,
        .p_queue_family_indices = if (queue_family_idxs.graphics == queue_family_idxs.present) null else &.{ queue_family_idxs.graphics, queue_family_idxs.present },
        // https://vulkan.gpuinfo.org/listsurfacetransformmodes.php?platform=linux
        .pre_transform = surface_capabilities.current_transform,
        // https://vulkan.gpuinfo.org/listsurfacecompositealphamodes.php?platform=linux
        .composite_alpha = if (surface_capabilities.supported_composite_alpha.opaque_bit_khr)
            .{ .opaque_bit_khr = true }
        else if (surface_capabilities.supported_composite_alpha.inherit_bit_khr)
            .{ .inherit_bit_khr = true }
        else
            return error.NoSuitableSurfaceCompositeAlphaMode,
        .present_mode = surface_present_mode,
        .clipped = vk.TRUE,
    }, null);
    defer device.destroySwapchainKHR(swapchain, null);

    const swapchain_images = try device.getSwapchainImagesAllocKHR(swapchain, stack_fallback_allocator);
    defer stack_fallback_allocator.free(swapchain_images);

    const image_count = swapchain_images.len;

    const swapchain_image_views = try stack_fallback_allocator.alloc(vk.ImageView, image_count);
    defer stack_fallback_allocator.free(swapchain_image_views);

    for (swapchain_image_views, swapchain_images) |*image_view, image|
        image_view.* = try device.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = surface_format.format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
    defer for (swapchain_image_views) |image_view|
        device.destroyImageView(image_view, null);

    // TODO: From this point on, the code is a mess.
    // TODO: Dependency?
    const render_pass = try device.createRenderPass(&.{
        .attachment_count = 1,
        .p_attachments = &.{
            .{
                .format = surface_format.format,
                .samples = .{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .undefined,
                .final_layout = .present_src_khr,
            },
        },
        .subpass_count = 1,
        .p_subpasses = &.{
            .{
                .pipeline_bind_point = .graphics,
                .color_attachment_count = 1,
                .p_color_attachments = &.{
                    .{
                        .attachment = 0,
                        .layout = .color_attachment_optimal,
                    },
                },
            },
        },
    }, null);
    defer device.destroyRenderPass(render_pass, null);

    const vert_shader_code align(@alignOf(u32)) = @embedFile("shaders/vert.spv").*;
    const frag_shader_code align(@alignOf(u32)) = @embedFile("shaders/frag.spv").*;

    const vert_shader_module = try device.createShaderModule(&.{
        .code_size = vert_shader_code.len,
        .p_code = @ptrCast(&vert_shader_code),
    }, null);
    defer device.destroyShaderModule(vert_shader_module, null);
    const frag_shader_module = try device.createShaderModule(&.{
        .code_size = frag_shader_code.len,
        .p_code = @ptrCast(&frag_shader_code),
    }, null);
    defer device.destroyShaderModule(frag_shader_module, null);

    const pipeline_layout = try device.createPipelineLayout(&.{}, null);
    defer device.destroyPipelineLayout(pipeline_layout, null);

    var pipeline: vk.Pipeline = undefined;
    _ = try device.createGraphicsPipelines(.null_handle, 1, &.{
        .{
            .stage_count = 2,
            .p_stages = &.{
                .{
                    .stage = .{ .vertex_bit = true },
                    .module = vert_shader_module,
                    .p_name = "main",
                },
                .{
                    .stage = .{ .fragment_bit = true },
                    .module = frag_shader_module,
                    .p_name = "main",
                },
            },
            // .p_vertex_input_state = null,
            .p_input_assembly_state = &.{
                .topology = .triangle_list,
                .primitive_restart_enable = vk.FALSE,
            },
            // .p_tessellation_state = null,
            .p_viewport_state = &.{
                .viewport_count = 1,
                .p_viewports = &.{
                    .{
                        .x = 0.0,
                        .y = 0.0,
                        .width = @floatFromInt(swapchain_extent.width),
                        .height = @floatFromInt(swapchain_extent.height),
                        .min_depth = 0.0,
                        .max_depth = 1.0,
                    },
                },
                .scissor_count = 1,
                .p_scissors = &.{
                    .{
                        .offset = .{ .x = 0, .y = 0 },
                        .extent = swapchain_extent,
                    },
                },
            },
            .p_rasterization_state = &.{
                .depth_clamp_enable = vk.FALSE,
                .rasterizer_discard_enable = vk.FALSE,
                .polygon_mode = .fill,
                .cull_mode = .{ .back_bit = true },
                .front_face = .clockwise,
                .depth_bias_enable = vk.FALSE,
                .depth_bias_constant_factor = 0, // undefined?
                .depth_bias_clamp = 0, // undefined?
                .depth_bias_slope_factor = 0, // undefined?
                .line_width = 1.0,
            },
            // .p_multisample_state = null, // TODO: Does this disable MSAA?
            // .p_depth_stencil_state = null,
            .p_color_blend_state = &.{
                .logic_op_enable = vk.FALSE, // TODO: TRUE???
                .logic_op = .copy, // undefined?
                .attachment_count = 1,
                .p_attachments = &.{
                    .{
                        .blend_enable = vk.FALSE,
                        .src_color_blend_factor = .one,
                        .dst_color_blend_factor = .zero,
                        .color_blend_op = .add,
                        .src_alpha_blend_factor = .one,
                        .dst_alpha_blend_factor = .zero,
                        .alpha_blend_op = .add,
                        .color_write_mask = .{
                            .r_bit = true,
                            .g_bit = true,
                            .b_bit = true,
                            .a_bit = true,
                        },
                    },
                },
                .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 }, // undefined?
            },
            .p_dynamic_state = &.{
                .dynamic_state_count = 1,
                .p_dynamic_states = &.{ .viewport, .scissor },
            },
            .layout = pipeline_layout,
            .render_pass = render_pass,
            .subpass = 0,
            .base_pipeline_index = -1, // undefined?
        },
    }, null, @ptrCast(&pipeline));
    defer device.destroyPipeline(pipeline, null);

    const framebuffers = try stack_fallback_allocator.alloc(vk.Framebuffer, image_count);
    defer stack_fallback_allocator.free(framebuffers);

    for (framebuffers, swapchain_image_views) |*framebuffer, image_view|
        framebuffer.* = try device.createFramebuffer(&.{
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = &.{image_view},
            .width = swapchain_extent.width,
            .height = swapchain_extent.height,
            .layers = 1,
        }, null);
    defer for (framebuffers) |framebuffer|
        device.destroyFramebuffer(framebuffer, null);

    const command_pool = try device.createCommandPool(&.{
        .flags = .{ .reset_command_buffer_bit = true }, // TODO
        .queue_family_index = queue_family_idxs.graphics,
    }, null);
    defer device.destroyCommandPool(command_pool, null);

    const cmdbuffers = try stack_fallback_allocator.alloc(vk.CommandBuffer, image_count);
    defer stack_fallback_allocator.free(cmdbuffers);

    try device.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary, // TODO
        .command_buffer_count = @intCast(image_count),
    }, cmdbuffers.ptr);
    defer device.freeCommandBuffers(command_pool, @intCast(image_count), cmdbuffers.ptr);

    for (cmdbuffers, framebuffers) |cmdbuffer, framebuffer| {
        try device.beginCommandBuffer(cmdbuffer, &.{});
        device.cmdBeginRenderPass(cmdbuffer, &.{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = swapchain_extent,
            },
            .clear_value_count = 1,
            .p_clear_values = &.{.{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } } }},
        }, .@"inline");
        device.cmdBindPipeline(cmdbuffer, .graphics, pipeline);
        device.cmdEndRenderPass(cmdbuffer);
        device.cmdDraw(cmdbuffer, 3, 1, 0, 0);
        try device.endCommandBuffer(cmdbuffer);
    }

    const image_available_semaphore = try device.createSemaphore(&.{}, null);
    defer device.destroySemaphore(image_available_semaphore, null);
    const render_finished_semaphore = try device.createSemaphore(&.{}, null);
    defer device.destroySemaphore(render_finished_semaphore, null);

    const in_flight_fence = try device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
    defer device.destroyFence(in_flight_fence, null);

    while (true) {
        _ = try device.waitForFences(1, &.{in_flight_fence}, vk.TRUE, std.math.maxInt(u64));
        try device.resetFences(1, &.{in_flight_fence});

        const acquire_image_result = device.acquireNextImageKHR(swapchain, std.math.maxInt(u64), image_available_semaphore, in_flight_fence);
        if (if (acquire_image_result) |result| switch (result.result) {
            .success => false,
            .timeout => return error.TODO, // TODO
            .not_ready => return error.TODO, // TODO
            .suboptimal_khr => true,
            else => unreachable,
        } else |err| switch (err) {
            error.OutOfDateKHR => true,
            else => return err,
        }) {
            // TODO: Rebuild swapchain and continue loop.
        }
        const image_index = (acquire_image_result catch unreachable).image_index;

        try graphics_queue.submit(1, &.{
            .{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = &.{image_available_semaphore},
                .p_wait_dst_stage_mask = &.{.{ .color_attachment_output_bit = true }}, // TODO: What does this mean?
                .command_buffer_count = 1,
                .p_command_buffers = &.{cmdbuffers[image_index]},
                .signal_semaphore_count = 1,
                .p_signal_semaphores = &.{render_finished_semaphore},
            },
        }, in_flight_fence);

        if (if (present_queue.presentKHR(&.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &.{render_finished_semaphore},
            .swapchain_count = 1,
            .p_swapchains = &.{swapchain},
            .p_image_indices = &.{image_index},
        })) |result| switch (result) {
            .success => false,
            .suboptimal_khr => true,
            else => unreachable,
        } else |err| switch (err) {
            error.OutOfDateKHR => true,
            else => return err,
        }) {
            // TODO: Rebuild swapchain and continue loop.
        }
    }

    try device.deviceWaitIdle();
}

pub fn main() u8 {
    struct {
        pub inline fn closure() !void {
            try tracy.loadLib();

            const tracy_zone = tracy.zone(@src(), .{});
            defer tracy_zone.deinit();

            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            const allocator = gpa.allocator();

            // var conn = try shimizu.openConnection(allocator, .{});
            // defer conn.close();

            // const display = conn.getDisplayProxy();
            // const registry = try display.sendRequest(.get_registry, .{});
            // const callback = try display.sendRequest(.sync, .{});
            // _ = registry; // autofix
            // _ = callback; // autofix

            try renderLoop(allocator);

            // while (true) conn.recv();
        }
    }.closure() catch |err| {
        log.err("{s}", .{
            switch (err) {
                error.OutOfMemory => "Allocation error: Out of memory.",
                error.FileNotFound => "Vulkan error: Vulkan lib file not found.",
                error.InstanceProcAddrNotFound => "Vulkan error: Instance proc address not found.",
                error.DeviceProcAddrNotFound => "Vulkan error: Device proc address not found.",
                error.CommandLoadFailure => "Vulkan error: Failed to load command.",
                error.OutOfHostMemory => "Vulkan allocation error: Out of host memory.",
                error.OutOfDeviceMemory => "Vulkan allocation error: Out of device.",
                error.RequiredInstanceLayerNotPresent => "Vulkan error: Required instance layer not present.",
                error.RequiredInstanceExtensionNotPresent => "Vulkan error: Required instance extension not present.",
                error.RequiredDeviceLayerNotPresent => "Vulkan error: Required device layer not present.",
                error.RequiredDeviceExtensionNotPresent => "Vulkan error: Required device extension not present.",
                error.NoSuitablePhysicalDevice => "Vulkan error: No suitable physical device.",
                error.NoSuitableGraphicsQueueFamily => "Vulkan error: No suitable graphics queue family.",
                error.NoSuitablePresentQueueFamily => "Vulkan error: No suitable present queue family.",
                // error.NoSuitableTransferQueueFamily => "Vulkan error: No suitable transfer queue family.",
                // error.NoSuitableVideoDecodeQueueFamily => "Vulkan error: No suitable video decode queue family.",
                error.NoSuitableSurfaceFormat => "Vulkan error: No suitable surface format. This indicates a driver bug.",
                error.NoSuitableSurfacePresentMode => "Vulkan error: No suitable surface present mode.",
                error.NoSuitableSurfaceCompositeAlphaMode => "Vulkan error: No suitable surface composite alpha mode.",
                error.RequiredImageUsageFlagNotPresent => "Vulkan error: Required image usage flag not present.",
                error.InitializationFailed => "Vulkan error: Initialization failed.",
                error.IncompatibleDriver => "Vulkan error: Incompatible driver.",
                error.TooManyObjects => "Vulkan error: Too many objects.",
                error.DeviceLost => "Vulkan error: Device lost.",
                error.Unknown => "Unknown error.",
                inline else => |other_err| "Other error: " ++ @errorName(other_err) ++ ".",
            },
        });
        return 1;
    };
    return 0;
}
