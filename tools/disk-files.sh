#!/bin/sh
# Copy the C: drive's files into a FAT32 disk image with mtools: the programs of os/Disk,
# and the kernel's own sources: os/Kernel in C:/Kernel, and the library files Kernel.HC
# includes as ../../coolc/Runtime/... and ../../coolc/Fmt/HCTok.HC in C:/coolc (".." stops
# at the root), so Cmp("C:/Kernel/Kernel.HC") in the OS compiles the kernel and Man finds
# definitions. With build/BootStub.BIN (the prebuilt assembly, tools/mkbootstub.py) the
# OS's MakeKernel rebuilds the whole Image (docs/kernel-rebuild.md).
# Usage: disk-files.sh image [-n]   (-n: leave files that are already there alone)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=$1
FLAG=-o
[ "${2:-}" = "-n" ] && FLAG=-n
cd "$ROOT"
for d in Kernel coolc coolc/Runtime coolc/Fmt; do
    mmd -i "$IMG" ::$d 2>/dev/null || true
done
mcopy $FLAG -i "$IMG" os/Disk/*.HC ::
mcopy $FLAG -i "$IMG" os/Kernel/* ::Kernel/
[ ! -f build/BootStub.BIN ] || mcopy $FLAG -i "$IMG" build/BootStub.BIN ::Kernel/
mcopy $FLAG -i "$IMG" coolc/Runtime/*.HC ::coolc/Runtime/
mcopy $FLAG -i "$IMG" coolc/Fmt/HCTok.HC ::coolc/Fmt/
