#!/usr/bin/env bash

set -ex

#zig build --summary all
#zig fmt src --check
#pushd ./src/gui/rust
#cargo fmt --check
#cargo clippy -- -Dclippy::all -Aclippy::missing_safety_doc
#popd
#
#pushd src/gui/mock/
#clang-format -n -Werror mock_gui.c
#clang-tidy --extra-arg="-I../" mock_gui.c
#popd
#
#zig build -Doptimize=ReleaseSafe -Dfake_ui --summary all
#valgrind \
#        --suppressions=./suppressions.valgrind \
#        --leak-check=full \
#        --track-origins=yes \
#        --track-fds=yes \
#        --error-exitcode=1 \
#        ./zig-out/bin/video-editor \
#                --input ./res/BigBuckBunny_320x240_20s.mp4 \
#                --output test.json \
#                --skip-subtitles

echo "Success"
