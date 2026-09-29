#!/bin/sh
# Boot the kernel Image headless in coolvm with a disk, scripted input and a
# framebuffer, expect KERNEL TEST PASS, then check the screenshot and the disk
# file on the host (tools/kernel-verify.py). Extra arguments go to coolvm.
# Usage: kernel-test.sh kernel.Image [coolvm options]
set -eu
image=$1
shift
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
python3 tools/kernel-verify.py prepare "$dir"
log=$dir/log
if gtimeout -k 2 45 build/coolvm --headless --cpus 2 --mem 1024 --timeout 40 --width 640 --height 480 \
    --bootargs 'coolcom.test=1' --input-script "$dir/input.txt" --disk "$dir/disk.img" \
    --screenshot "$dir/screen.png" "$@" "$image" >"$log" 2>&1 \
    && grep -q 'SELFTEST PASS' "$log" && grep -q '2 cores online' "$log" \
    && grep -q 'KERNEL TEST PASS' "$log" && python3 tools/kernel-verify.py verify "$dir"; then
    tail -n 12 "$log"
    exit 0
fi
cat "$log"
exit 1
