#!/bin/sh
# Copy the C: drive's files into a FAT32 disk image with mtools: the programs of os/Disk,
# and the kernel's own sources under C:/Kernel (for Man; C:/Kernel/Runtime holds the shared
# TempleOS library files the kernel includes from coolc/Runtime).
# Usage: disk-files.sh image [-n]   (-n: leave files that are already there alone)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=$1
FLAG=-o
[ "${2:-}" = "-n" ] && FLAG=-n
cd "$ROOT"
mmd -i "$IMG" ::Kernel ::Kernel/Runtime 2>/dev/null || true
mcopy $FLAG -i "$IMG" os/Disk/*.HC ::
mcopy $FLAG -i "$IMG" os/Kernel/*.HC os/Kernel/*.HH os/Kernel/*.S os/Kernel/*.h coolc/Fmt/HCTok.HC ::Kernel/
mcopy $FLAG -i "$IMG" coolc/Runtime/*.HC ::Kernel/Runtime/
