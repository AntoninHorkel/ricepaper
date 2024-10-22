{
    lib,
    stdenv,
    zig,
    pkg-config,
    # tracy,
    debug ? false,
    version ? "git",
}:
with lib; stdenv.mkDerivation {
    name = "ricepaper";
    pname = "ricepaper";
    inherit version;
    src = ./;
    buildInputs = [
        zig
        pkg-config
        (optionals debug tracy)
    ];
    # nativeBuildInputs = [];
    buildPhase = "zig build -Doptimize=ReleaseFast";
    installPhase = ''
        mkdir -p $out/bin
        cp $src/zig-out/bin/ricepaper $out/bin
    '';
    # outputs = [];
    # TODO: Fetch the Tracy source code with version based on the output of `nix-env -qa --json tracy`.
    shellHook = ''
        zig fetch --save git+https://git.sr.ht/~geemili/shimizu
        zig fetch --save=wayland_protocols git+https://gitlab.freedesktop.org/wayland/wayland-protocols.git
        zig fetch --save=wlr_protocols git+https://gitlab.freedesktop.org/wlroots/wlr-protocols.git
        zig fetch --save=vulkan_codegen git+https://github.com/Snektron/vulkan-zig.git
        zig fetch --save=vulkan_headers git+https://github.com/KhronosGroup/Vulkan-Headers.git
    '' + (strings.optionalString debug "zig fetch --save=tracy https://github.com/wolfpld/tracy/archive/v${"0.11.1"}.tar.gz");
    meta = {
        mainProgram = "ricepaper";
        description = "TODO";
        longDescription = "TODO";
        homepage = "https://github.com/AntoninHorkel/ricepaper";
        downloadPage = "https://github.com/AntoninHorkel/ricepaper/releases";
        license = with licenses; [ asl20 mit ];
        maintainers = with maintainers; [ AntoninHorkel ];
        platforms = with platforms; [ linux freebsd ];
    };
}
