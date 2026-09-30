#!/bin/sh
# Install the explicitly built resident Vulkan app into an existing FAT image.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IMG=$1
mdir -i "$IMG" ::Vulkan >/dev/null 2>&1 || mmd -i "$IMG" ::Vulkan
for f in "$ROOT/build/venus/Vulkan.cool" "$ROOT"/os/Vulkan/*.cool "$ROOT"/build/venus/terminal.*.spv; do
    [ -f "$f" ] || { echo "Missing Vulkan input: $f; run make venus-terminal" >&2; exit 1; }
    mcopy -o -i "$IMG" "$f" ::Vulkan/
done
