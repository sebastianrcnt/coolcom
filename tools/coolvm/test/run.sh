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
for g in guest fault; do
    "$AS" -o "$OUT/$g.o" "$HERE/$g.S"
    "$LD" --no-warn-rwx-segments -T "$HERE/guest.ld" -o "$OUT/$g.elf" "$OUT/$g.o"
    "$OBJCOPY" -O binary "$OUT/$g.elf" "$OUT/$g.Image"
done

[ -x "$COOLVM" ] || "$HERE/../build.sh"

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
"$COOLVM" --cpus 2 --timeout "$TIMEOUT" "$@" "$OUT/guest.Image" </dev/null >"$OUT/out.txt" 2>"$OUT/err.txt"
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
    "^hello from cpu1 mpidr=0x0000000080000001" \
    "^cpu1: got fast IPI" \
    "^smp ok" \
    "^coolvm-test PASS"; do
    expect "$OUT/out.txt" "$p"
done

# ---- 2. UART RX from host stdin ----
printf 'Q' | "$COOLVM" --cpus 2 --timeout "$TIMEOUT" "$OUT/guest.Image" >"$OUT/out_rx.txt" 2>/dev/null || true
expect "$OUT/out_rx.txt" "^uart rx: Q"

# ---- 3. negative: unknown MMIO is fatal, --lenient makes it RAZ ----
set +e
"$COOLVM" --timeout 10 "$OUT/fault.Image" </dev/null >/dev/null 2>"$OUT/err_fault.txt"
RC=$?
set -e
expect_rc $RC 1 "fault.Image (default)"
expect "$OUT/err_fault.txt" "unhandled MMIO read of 4 bytes at 0x235300000"
set +e
"$COOLVM" --timeout 10 --lenient "$OUT/fault.Image" </dev/null >/dev/null 2>"$OUT/err_lenient.txt"
RC=$?
set -e
expect_rc $RC 0 "fault.Image --lenient"
expect "$OUT/err_lenient.txt" "unknown MMIO read32 at 0x235300000"

# ---- 4. negative: --strict turns an unknown sysreg into a fatal error ----
set +e
"$COOLVM" --timeout 10 --strict "$OUT/guest.Image" </dev/null >/dev/null 2>"$OUT/err_strict.txt"
RC=$?
set -e
expect_rc $RC 1 "guest.Image --strict"
expect "$OUT/err_strict.txt" "unknown sysreg access S3_5_C15_C9_6"

if [ "$FAIL" -eq 0 ]; then echo "coolvm-test: OK"; else echo "coolvm-test: FAILED"; fi
exit $FAIL
