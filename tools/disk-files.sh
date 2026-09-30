#!/bin/sh
# Copy the C: drive's files into a FAT32 disk image with mtools: the programs of os/Disk,
# and the kernel's own sources: os/Kernel in C:/Kernel, and the library files Kernel.cool
# includes as ../../coolc/Runtime/... and ../../coolc/Fmt/HCTok.cool in C:/coolc (".." stops
# at the root), so Cmp("C:/Kernel/Kernel.cool") in the OS compiles the kernel and Man finds
# definitions. With build/BootStub.BIN (the prebuilt assembly, tools/mkbootstub.py) the
# OS's MakeKernel rebuilds the whole Image (docs/kernel-rebuild.md).
# Usage: disk-files.sh image [-n]   (-n: leave files that are already there alone)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=$1
FLAG=-o
[ "${2:-}" = "-n" ] && FLAG=-n
cd "$ROOT"
# Build once, and refresh only when the compiler or its embedded sources change.
make build/warmcool/Kernel.cool os/Kernel/NetParse.cool build/lua/LuaRuntime.cool  # (and the kernel's Warm parts)
for d in Kernel coolc coolc/Runtime coolc/Fmt coolc/LibC; do
    # mmd asks on the terminal when the directory exists, so only make missing ones.
    mdir -i "$IMG" ::$d >/dev/null 2>&1 || mmd -i "$IMG" ::$d </dev/null
done
# put DIR SRC...: copy each file into ::DIR; with -n, leave existing files alone.
# (mcopy -n / -D s exit non-zero when they skip a file, so check first.)
put() {
    dir=$1; shift
    for f in "$@"; do
        if [ "$FLAG" = -n ] && mdir -i "$IMG" "::$dir$(basename "$f")" >/dev/null 2>&1; then
            continue
        fi
        mcopy -o -i "$IMG" "$f" "::$dir"
    done
}
put "" os/Disk/*.cool os/Disk/*.warm
# Install the generated package under its public shell name.
if [ "$FLAG" != -n ] || ! mdir -i "$IMG" ::Warm.cool >/dev/null 2>&1; then
    mcopy -o -i "$IMG" build/warmcool/Kernel.cool ::Warm.cool
fi
put Kernel/ os/Kernel/*
[ ! -f build/BootStub.BIN ] || put Kernel/ build/BootStub.BIN
put coolc/Runtime/ coolc/Runtime/*.cool
put coolc/Fmt/ coolc/Fmt/HCTok.cool

put coolc/LibC/ coolc/LibC/LibC.cool

put "" build/lua/LuaRuntime.cool
