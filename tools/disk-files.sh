#!/bin/sh
# Install OS programs, kernel sources and shared libraries on a FAT32 disk.
# Repository names stay unchanged; Kernel.cool's includes are mapped on disk
# to C:/Cool so both host builds and OS MakeKernel/Cmp use the same sources.
# Usage: disk-files.sh image [-n]   (-n: leave files that are already there alone)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=$1
FLAG=-o
[ "${2:-}" = "-n" ] && FLAG=-n
cd "$ROOT"
# Build once, and refresh only when the compiler or its embedded sources change.
make build/warmcool/Kernel.cool os/Kernel/NetParse.cool build/lua/LuaRuntime.cool  # (and the kernel's Warm parts)
for d in Kernel Cool Cool/Runtime Cool/Fmt Cool/LibC Warm Warm/Standard Warm/Examples; do
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
if [ "$FLAG" != -n ] || ! mdir -i "$IMG" ::Warm/Warm.cool >/dev/null 2>&1; then
    mcopy -o -i "$IMG" build/warmcool/Kernel.cool ::Warm/Warm.cool
fi
# Stage only the include mapping; do not change repository sources or binaries.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
sed 's|#include "\.\./\.\./coolc/|#include "C:/Cool/|g' os/Kernel/Kernel.cool >"$stage/Kernel.cool"
for f in os/Kernel/*; do
    [ "$f" != os/Kernel/Kernel.cool ] || f=$stage/Kernel.cool
    put Kernel/ "$f"
done
[ ! -f build/BootStub.BIN ] || put Kernel/ build/BootStub.BIN
put Cool/Runtime/ coolc/Runtime/*.cool
put Cool/Fmt/ coolc/Fmt/HCTok.cool

put Cool/LibC/ coolc/LibC/LibC.cool

put "" build/lua/LuaRuntime.cool

# Recursive copies keep module names and example directories intact. put() makes
# seeding preserve edits to individual files, including newly added modules.
tree() {
    src=$1; dst=$2
    find "$src" -type d | while IFS= read -r d; do
        target=$dst${d#"$src"}
        mdir -i "$IMG" "::$target" >/dev/null 2>&1 || mmd -i "$IMG" "::$target" </dev/null
    done
    find "$src" -type f | while IFS= read -r f; do
        rel=${f#"$src"/}
        case "$rel" in
            */*) put "$dst/${rel%/*}/" "$f" ;;
            *) put "$dst/" "$f" ;;
        esac
    done
}
tree warmc/standard/src Warm/Standard
tree warmc/builtin Warm/Standard/builtin
tree warmc/examples Warm/Examples

# An explicit install replaces Init.cool and the mapped kernel sources above,
# so the old layout can now be removed. Seeding keeps old files and user edits.
if [ "$FLAG" != -n ]; then
    for d in coolc Compiler; do
        if mdir -i "$IMG" "::$d" >/dev/null 2>&1; then
            mdeltree -i "$IMG" "::$d" </dev/null
        fi
    done
    for f in Warm.cool Warm.HC; do
        if mdir -i "$IMG" "::$f" >/dev/null 2>&1; then
            mdel -i "$IMG" "::$f"
        fi
    done
fi
