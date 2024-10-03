const std = @import("std");

// TODO: .imports instead of .root_module.addImport(...)

const name = "ricepaper";
const version = std.SemanticVersion.parse("0.1.0") catch {};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_llvm = b.option(bool, "llvm", "Enable LLVM as the codegen backend. Defaults to false on debug builds, true otherwise") orelse (optimize != .Debug);
    const enable_lld = b.option(bool, "lld", "Enable LLD as the linker. Defaults to the value of use-llvm option") orelse enable_llvm;
    const strip = b.option(bool, "strip", "Omit debug symbols. Defaults to false on debug builds, true otherwise") orelse (optimize != .Debug);
    const enable_tracy = b.option(bool, "tracy", "Enable Tracy integration. Defaults to true on debug builds, false otherwise") orelse (optimize == .Debug);
    const link_tracy = b.option(bool, "link-tracy", "Whether to link or load Tracy. Defaults to true") orelse true;
    const enable_validation_layers = b.option(bool, "validation-layers", "Enable Vulkan validation layers. Defaults to true on debug builds, false otherwise") orelse (optimize == .Debug);

    const options = b.addOptions();
    options.addOption([]const u8, "name", name);
    options.addOption(std.SemanticVersion, "version", version);
    options.addOption(struct { enable: bool, link: bool }, "tracy", .{ .enable = enable_tracy, .link = link_tracy });
    options.addOption(bool, "validate", enable_validation_layers);
    const options_module = options.createModule();

    // TODO: Once https://github.com/ziglang/zig/issues/17895 is merged,
    // only https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/main/registry/vk.xml needs to be fetched.
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan_codegen = b.dependency("vulkan_codegen", .{}).artifact("vulkan-zig-generator");
    const vulkan_codegen_step = b.addRunArtifact(vulkan_codegen);
    vulkan_codegen_step.addFileArg(vulkan_headers.path("registry/vk.xml"));
    const vulkan_module = b.addModule("vulkan", .{
        .root_source_file = vulkan_codegen_step.addOutputFileArg("vulkan.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const tracy_module = b.addModule("tracy", .{
        .root_source_file = b.path("src/tracy.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    tracy_module.addImport("build_options", options_module); // tracy_module.addAnonymousImport(...);
    if (enable_tracy) {
        const tracy = b.dependency("tracy", .{});

        tracy_module.link_libc = true;

        tracy_module.addCMacro("TRACY_ENABLE", "1");
        tracy_module.addIncludePath(tracy.path("public/tracy/"));

        if (link_tracy) {
            tracy_module.link_libcpp = true;
            // if (enable_llvm) tracy_module.linkSystemLibrary("c++", .{ .use_pkg_config = .no });

            tracy_module.addCSourceFile(.{
                .file = tracy.path("public/TracyClient.cpp"),
                .flags = &.{"-fno-sanitize=undefined"},
            });
        }
    }

    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("src/graphics_context.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = enable_llvm,
        .use_lld = enable_lld,
        .strip = strip,
    });
    exe.root_module.addImport("vulkan", vulkan_module);
    exe.root_module.addImport("tracy", tracy_module);
    exe.root_module.addImport("build_options", options_module); // exe.root_module.addAnonymousImport(...);
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    // run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_cmd.step);

    // This can be simplified with https://github.com/ziglang/zig/pull/20388
    const unit_tests_exe = b.addTest(.{
        .root_source_file = b.path("src/graphics_context.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests_exe.root_module.addImport("vulkan", vulkan_module);
    unit_tests_exe.root_module.addImport("tracy", tracy_module);
    unit_tests_exe.root_module.addImport("build_options", options_module); // unit_tests_exe.root_module.addAnonymousImport(...);
    const run_exe_unit_tests = b.addRunArtifact(unit_tests_exe);
    if (b.args) |args| run_exe_unit_tests.addArgs(args);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // This can be simplified with https://github.com/ziglang/zig/pull/20388
    const autodoc_exe = b.addObject(.{
        .name = name,
        .root_source_file = b.path("src/graphics_context.zig"),
        .target = target,
        .optimize = .Debug,
    });
    autodoc_exe.root_module.addImport("vulkan", vulkan_module);
    autodoc_exe.root_module.addImport("tracy", tracy_module);
    autodoc_exe.root_module.addImport("build_options", options_module); // autodoc_exe.root_module.addAnonymousImport(...);
    const install_docs = b.addInstallDirectory(.{
        .source_dir = autodoc_exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc/" ++ name,
    });
    const docs_step = b.step("doc", "Generate and install documentation");
    docs_step.dependOn(&install_docs.step);
}
