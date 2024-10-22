{ pkgs ? import <nixpkgs> {} }:
with pkgs; mkShellNoCC {
    name = "ricepaper";
    version = "0.1.0";
    packages = [
        git
        strace
        tracy
        valgrind
        zig
        zls
        pkg-config
    ];
    buildInputs = [
        # tracy
        zig
        pkg-config
    ];
    # TODO: Fetch the Tracy source code with version based on the output of `nix-env -qa --json tracy`.
    shellHook = ''
        zig fetch --save git+https://git.sr.ht/~geemili/shimizu
        zig fetch --save=wayland_protocols git+https://gitlab.freedesktop.org/wayland/wayland-protocols.git
        zig fetch --save=wlr_protocols git+https://gitlab.freedesktop.org/wlroots/wlr-protocols.git
        zig fetch --save=vulkan_codegen git+https://github.com/Snektron/vulkan-zig.git
        zig fetch --save=vulkan_headers git+https://github.com/KhronosGroup/Vulkan-Headers.git
        zig fetch --save=tracy https://github.com/wolfpld/tracy/archive/v${"0.11.1"}.tar.gz
    '';
};
