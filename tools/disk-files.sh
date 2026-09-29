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
# put SRC... DIR: copy each file into ::DIR; with -n, leave existing files alone.
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
put "" os/Disk/*.HC
put Kernel/ os/Kernel/*.HC os/Kernel/*.HH os/Kernel/*.S os/Kernel/*.h coolc/Fmt/HCTok.HC
put Kernel/Runtime/ coolc/Runtime/*.HC
