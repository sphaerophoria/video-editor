#!/usr/bin/env bash

set -ex

zig build --summary all
zig fmt src --check

valgrind \
        --suppressions=./suppressions.valgrind \
        --leak-check=full \
        --track-origins=yes \
        --track-fds=yes \
        --error-exitcode=1 \
        ./zig-out/bin/video-editor --input ./res/BigBuckBunny_320x240_20s.mp4 --lint

echo "Success"
