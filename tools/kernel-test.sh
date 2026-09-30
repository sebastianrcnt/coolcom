#!/bin/sh
# Boot the kernel Image headless in coolvm with a disk, scripted input and a
# framebuffer, expect KERNEL TEST PASS and the line 49 printed by the shell
# (the input script types lines into it, incl. two Ctrl+Alt+C breaks), then check the screenshot and
# the disk files on the host (tools/kernel-verify.py; needs mtools). This boot has a NIC (--net): the
# kernel gets an address by DHCP from coolvm's NAT, tests TCP/UDP over loopback and fetches
# http://example.com (that part is skipped if the host is offline). Then boot the Image again as
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
    --bootargs 'coolcom.test=1' --input-script "$dir/input.txt" --disk "$dir/disk.img" --disk "$dir/fat.img" --disk "$dir/format.img" --net \
    --screenshot "$dir/screen.png" "$@" "$image" >"$log" 2>&1 \
    && grep -q 'SELFTEST PASS' "$log" && grep -q '2 cores online' "$log" \
    && [ "$(grep -c 'heap overflow block=' "$log")" = 5 ] \
    && [ "$(grep -c 'ERROR: stack overflow, task Shell' "$log")" = 2 ] \
    && grep -q 'ERROR: kernel text write' "$log" \
    && tr -d '\r' <"$log" | grep -qx 'MEMSAFE RECOVERED 81' \
    && grep -q 'KERNEL TEST PASS' "$log" && grep -q '  net: PASS' "$log" && grep -q 'net: loopback ok' "$log" && grep -q 'net: parser ok' "$log" && tr -d '\r' <"$log" | grep -qx '49' \
    && [ "$(tr -d '\r' <"$log" | grep -cx 'Break')" = 2 ] \
    && [ "$(tr -d '\r' <"$log" | grep -cx '51')" = 2 ] && tr -d '\r' <"$log" | grep -qx '42' && tr -d '\r' <"$log" | grep -qx '63' && tr -d '\r' <"$log" | grep -qx 'A92' \
    && tr -d '\r' <"$log" | grep -A2 -x 'ERROR: Expected an expression' | grep -qx '            ^' && python3 tools/kernel-verify.py verify "$dir"; then
    tail -n 12 "$log"
    grep -E '^net: (parser|address|HTTP|DNS failed)' "$log" | tr -d '\r'
    # The network commands typed at the shell (prelude): NetRep and Ping to the gateway always,
    # Dns and HttpGet of example.com unless the first boot found the host offline.
    printf 'NetRep;\nPing("10.0.2.2", 1);\n' >"$dir/net.in"
    grep -q 'net: DNS failed' "$log" || printf 'Dns("example.com");\nHttpGet("http://example.com/");\n' >>"$dir/net.in"
    printf 'Shutdown;\n' >>"$dir/net.in"
    gtimeout -k 2 30 build/coolvm --headless --cpus 2 --mem 1024 --timeout 10 --net "$@" "$image" \
        <"$dir/net.in" >"$dir/net.log" 2>&1 || true
    tr -d '\r' <"$dir/net.log" >"$dir/net.txt"
    if ! grep -q '^inet   10.0.2.15 ' "$dir/net.txt" || ! grep -q '^1 packets transmitted, 1 received' "$dir/net.txt" \
        || { ! grep -q 'net: DNS failed' "$log" && ! { grep -q '^example.com has address ' "$dir/net.txt" \
            && grep -q '^HTTP/1.1 200' "$dir/net.txt" && grep -q 'Example Domain' "$dir/net.txt"; }; }; then
        cat "$dir/net.log"
        exit 1
    fi
    echo "net shell commands: OK"
    # Compile the real startup files under the heap canaries as a regression
    # for GraphColor indexing its candidate array with an uncolored (-1) neighbor.
    tools/disk-files.sh "$dir/fat.img"
    # coolvm stops the VM once the shell has echoed the Korean line and printed it (an input script of
    # waits and quit: tools/coolvm/README.md), then the screenshot is saved.
    printf 'wait 한글 테스트\nwait 한글 테스트\ndelay 300\nquit\n' >"$dir/shell.wait"
    gtimeout -k 2 30 build/coolvm --headless --cpus 2 --mem 1024 --timeout 20 --width 640 --height 480 \
        --disk "$dir/fat.img" --screenshot "$dir/shell.png" --input-script "$dir/shell.wait" "$@" "$image" \
        <"$dir/shell.in" >"$dir/shell.log" 2>&1 || true
    # KTestHeap deliberately reports four corruptions; startup must add none.
    if [ "$(grep -c 'heap overflow block=' "$dir/shell.log")" = 4 ] \
        && grep -q 'Running C:/Init.cool' "$dir/shell.log" \
        && python3 tools/kernel-verify.py verify-shell "$dir"; then
        exit 0
    fi
    cat "$dir/shell.log"
    exit 1
fi
cat "$log"
exit 1
