#!/bin/sh
# Build the coolvm test guests and run them under coolvm with timeouts.
#   run.sh            positive test (guest.S) + negative tests (fault.S, --strict)
# Exit status 0 = everything behaved as expected.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=$ROOT/build/coolvm-test
COOLVM=${COOLVM:-$ROOT/build/coolvm}
AS=${AS:-aarch64-elf-as}
LD=${LD:-aarch64-elf-ld}
OBJCOPY=${OBJCOPY:-aarch64-elf-objcopy}
TIMEOUT=${TIMEOUT:-20}

mkdir -p "$OUT"
for g in guest fault devices timer-rearm; do
    "$AS" -o "$OUT/$g.o" "$HERE/$g.S"
    "$LD" --no-warn-rwx-segments -T "$HERE/guest.ld" -o "$OUT/$g.elf" "$OUT/$g.o"
    "$OBJCOPY" -O binary "$OUT/$g.elf" "$OUT/$g.Image"
done

[ -x "$COOLVM" ] || "$HERE/../build.sh"
command -v gtimeout >/dev/null || { echo "gtimeout is required" >&2; exit 2; }

FAIL=0
expect() { # file pattern
    if ! grep -q -- "$2" "$1"; then
        echo "MISSING in $(basename "$1"): $2"
        FAIL=1
    fi
}
expect_rc() { # actual expected what
    if [ "$1" -ne "$2" ]; then
        echo "$3: exit status $1, expected $2"
        FAIL=1
    fi
}

# ---- 1. positive test: everything the emulated M1 subset offers ----
set +e
gtimeout -k 2 "$((TIMEOUT + 5))" "$COOLVM" --headless --cpus 2 --timeout "$TIMEOUT" "$@" "$OUT/guest.Image" </dev/null >"$OUT/out.txt" 2>"$OUT/err.txt"
RC=$?
set -e
cat "$OUT/out.txt"
[ -s "$OUT/err.txt" ] && { echo "--- coolvm stderr ---"; cat "$OUT/err.txt"; echo "---"; }
expect_rc $RC 0 "guest.Image"
for p in \
    "^hello from coolvm" \
    "^dt compatible: coolcom,coolvm" \
    "^dt memory base=0x0000000800000000" \
    "^aic: nr_irq=896 whoami=0" \
    "^unknown sysreg -> UNDEF ok" \
    "^unknown hvc returns -1 ok" \
    "^aic irq taken, event=0x0000000000010064" \
    "^uart tx-threshold irq taken" \
    "^tick 1$" \
    "^tick 5$" \
    "^expired timer rearm ok$" \
    "^hello from cpu1 mpidr=0x0000000080000001" \
    "^cpu1: got fast IPI" \
    "^smp ok" \
    "^coolvm-test PASS"; do
    expect "$OUT/out.txt" "$p"
done

# A missed quiescent interval must not permanently mask the virtual timer.
set +e
gtimeout -k 2 8 "$COOLVM" --headless --cpus 1 --timeout 5 "$OUT/timer-rearm.Image" >"$OUT/out_timer_rearm.txt" 2>"$OUT/err_timer_rearm.txt"
RC=$?
set -e
expect_rc "$RC" 0 "timer-rearm.Image"
expect "$OUT/out_timer_rearm.txt" "^timer rearm PASS"

# ---- 2. UART RX from host stdin ----
printf 'Q' | gtimeout -k 2 "$((TIMEOUT + 5))" "$COOLVM" --headless --cpus 2 --timeout "$TIMEOUT" "$OUT/guest.Image" >"$OUT/out_rx.txt" 2>/dev/null || true
expect "$OUT/out_rx.txt" "^uart rx: Q"

# ---- 3. negative: unknown MMIO is fatal, --lenient makes it RAZ ----
set +e
gtimeout -k 2 15 "$COOLVM" --headless --timeout 10 "$OUT/fault.Image" </dev/null >/dev/null 2>"$OUT/err_fault.txt"
RC=$?
set -e
expect_rc $RC 1 "fault.Image (default)"
expect "$OUT/err_fault.txt" "unhandled MMIO read of 4 bytes at 0x235300000"
set +e
gtimeout -k 2 15 "$COOLVM" --headless --timeout 10 --lenient "$OUT/fault.Image" </dev/null >/dev/null 2>"$OUT/err_lenient.txt"
RC=$?
set -e
expect_rc $RC 0 "fault.Image --lenient"
expect "$OUT/err_lenient.txt" "unknown MMIO read32 at 0x235300000"

# ---- 4. negative: --strict turns an unknown sysreg into a fatal error ----
set +e
gtimeout -k 2 15 "$COOLVM" --headless --timeout 10 --strict "$OUT/guest.Image" </dev/null >/dev/null 2>"$OUT/err_strict.txt"
RC=$?
set -e
expect_rc $RC 1 "guest.Image --strict"
expect "$OUT/err_strict.txt" "unknown sysreg access S3_5_C15_C9_6"

# ---- 5. framebuffer, scripted input and virtio-blk (repeat from clean images) ----
printf '1 30 1\n2 0 7\n' >"$OUT/input.txt"
for iteration in 1 2 3; do
    python3 - "$OUT" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
(out / "device-disk.img").write_bytes(b"ABCD" + bytes(4092))
(out / "second-disk.img").write_bytes(b"WXYZ" + bytes(4092))
PY
    set +e
    gtimeout -k 2 15 "$COOLVM" --headless --cpus 1 --timeout 10 --width 64 --height 32 \
        --input-script "$OUT/input.txt" --disk "$OUT/device-disk.img" --disk "$OUT/second-disk.img" \
        --dump-dtb "$OUT/devices.dtb" --screenshot "$OUT/screen.png" \
        "$OUT/devices.Image" </dev/null >"$OUT/out_devices.txt" 2>"$OUT/err_devices.txt"
    RC=$?
    set -e
    expect_rc "$RC" 0 "devices.Image iteration $iteration"
    for p in "input key and mouse ok" "disk read ok" "disk write ok" "disk flush ok" "devices PASS"; do
        expect "$OUT/out_devices.txt" "$p"
    done
    dtc -I dtb -O dts -o "$OUT/devices.dts" "$OUT/devices.dtb"
    python3 "$HERE/verify_devices.py" "$OUT"
done

# ---- 6. user-mode NAT (src/net.c) driven by a host-side fake guest; 77 = host offline ----
clang -O1 -g -std=gnu11 -I "$HERE/../src" -o "$OUT/nat-test" "$HERE/nat-test.c" "$HERE/../src/net.c" -lpthread
set +e
gtimeout -k 2 30 "$OUT/nat-test" >"$OUT/out_nat.txt" 2>&1
RC=$?
set -e
cat "$OUT/out_nat.txt"
if [ "$RC" -eq 77 ]; then echo "nat-test: host offline, external part skipped"; else expect_rc "$RC" 0 "nat-test"; fi

# Window composition and exported pixels must agree even when scanout wraps.
clang -O2 -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
    "$HERE/scanout.m" "$HERE/../src/display.m" -o "$OUT/scanout" \
    -framework Hypervisor -framework AppKit -framework QuartzCore -framework ImageIO
"$OUT/scanout" "$OUT/scanout.png"

if [ "$FAIL" -eq 0 ]; then echo "coolvm-test: OK"; else echo "coolvm-test: FAILED"; fi
exit $FAIL
