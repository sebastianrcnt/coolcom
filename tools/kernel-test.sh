#!/bin/sh
# Boot the kernel Image headless in coolvm with a disk, scripted input and a
# framebuffer, expect KERNEL TEST PASS and the line 49 printed by the shell
# (the input script types lines into it, incl. two Ctrl+Alt+C breaks), then check the screenshot and
# the disk files on the host (tools/kernel-verify.py; needs mtools). Then boot the Image again as
# a plain shell with a Korean line typed on the UART (stdin) and check the screenshot for Hangul.
# Extra arguments go to coolvm.
# Usage: kernel-test.sh kernel.Image [coolvm options]
set -eu
image=$1
shift
dir=$(mktemp -d build/kernel-test.XXXXXX)
trap 'rm -rf "$dir"' EXIT
python3 tools/kernel-verify.py prepare "$dir"
log=$dir/log
if gtimeout -k 2 45 build/coolvm --headless --cpus 2 --mem 1024 --timeout 40 --width 640 --height 480 \
    --bootargs 'coolcom.test=1' --input-script "$dir/input.txt" --disk "$dir/disk.img" --disk "$dir/fat.img" --disk "$dir/format.img" \
    --screenshot "$dir/screen.png" "$@" "$image" >"$log" 2>&1 \
    && grep -q 'SELFTEST PASS' "$log" && grep -q '2 cores online' "$log" \
    && [ "$(grep -c 'heap overflow block=' "$log")" = 5 ] \
    && [ "$(grep -c 'ERROR: stack overflow, task Shell' "$log")" = 2 ] \
    && grep -q 'ERROR: kernel text write' "$log" \
    && tr -d '\r' <"$log" | grep -qx 'MEMSAFE RECOVERED 81' \
    && grep -q 'KERNEL TEST PASS' "$log" && tr -d '\r' <"$log" | grep -qx '49' \
    && [ "$(tr -d '\r' <"$log" | grep -cx 'Break')" = 2 ] \
    && [ "$(tr -d '\r' <"$log" | grep -cx '51')" = 2 ] && tr -d '\r' <"$log" | grep -qx '42' && tr -d '\r' <"$log" | grep -qx '63' && tr -d '\r' <"$log" | grep -qx 'A92' && python3 tools/kernel-verify.py verify "$dir"; then
    tail -n 12 "$log"
    # Compile the real startup files under the heap canaries as a regression
    # for GraphColor indexing its candidate array with an uncolored (-1) neighbor.
    mcopy -o -i "$dir/fat.img" os/Disk/*.HC ::
    # The shell never exits: coolvm stops it at --timeout (nonzero status), then the screenshot is saved.
    gtimeout -k 2 30 build/coolvm --headless --cpus 2 --mem 1024 --timeout 8 --width 640 --height 480 \
        --disk "$dir/fat.img" --screenshot "$dir/shell.png" "$@" "$image" <"$dir/shell.in" >"$dir/shell.log" 2>&1 || true
    # KTestHeap deliberately reports four corruptions; startup must add none.
    if [ "$(grep -c 'heap overflow block=' "$dir/shell.log")" = 4 ] \
        && grep -q 'Running C:/Init.HC' "$dir/shell.log" \
        && python3 tools/kernel-verify.py verify-shell "$dir"; then
        exit 0
    fi
    cat "$dir/shell.log"
    exit 1
fi
cat "$log"
exit 1
