{
    description = "TODO";
    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    };
    outputs = { self, lib, nixpkgs }: {
        devShells = nixpkgs.mkShellNoCC {
            name = "ricepaper";
            version = "0.1.0";
            packages = [
                git
                strace
                tracy
                valgrind
                zig
                zls
            ];
            # buildInputs = [];
            # TODO: Fetch the Tracy source code with version based on the output of `nix-env -qa --json tracy`.
            shellHook = "
                zig fetch --save=vulkan_codegen git+https://github.com/Snektron/vulkan-zig.git
                zig fetch --save=vulkan_headers git+https://github.com/KhronosGroup/Vulkan-Headers.git
                zig fetch --save=glsl_compiler git+https://github.com/Games-by-Mason/shader_compiler.git
                zig fetch --save=tracy https://github.com/wolfpld/tracy/archive/v${"0.10.0"}.tar.gz
            ";
        };
    };
}
