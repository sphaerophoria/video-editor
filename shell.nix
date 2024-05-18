with import <nixpkgs> {};

let
  unstable = import
    (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/b172a41aea589d5d71633f1fe77fc4da737d4507.tar.gz")
    # reuse the current configuration
    { config = config; };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    unstable.zls
    unstable.zig_0_12
    gdb
    zlib
    valgrind
    # For linter script on push hook
    python3
    glfw
    libGL
    ffmpeg
    libpulseaudio
    rustPlatform.bindgenHook
    rustup
    clang-tools
  ];

  LD_LIBRARY_PATH = with pkgs.xorg; "${pkgs.mesa}/lib:${libX11}/lib:${libXcursor}/lib:${libXxf86vm}/lib:${libXi}/lib:${libXrandr}/lib:${pkgs.libGL}/lib:${pkgs.gtk3}/lib:${pkgs.cairo}/lib:${pkgs.gdk-pixbuf}/lib:${pkgs.fontconfig}/lib:${wayland}/lib:${libxkbcommon}/lib";
}

