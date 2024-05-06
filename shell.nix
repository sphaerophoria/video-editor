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
  ];
}

