#!/bin/sh
# Compile fixed frontend cases and execute their exported probe functions.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BASE=$ROOT/build/coolc-selfhost.BIN
FIXED=$ROOT/build/coolc-fixed.BIN
OUT=$ROOT/build/native-behavior
mkdir -p "$OUT"
[ -f "$BASE" ] || { echo 'build the baseline compiler first (tools/native/check.sh)' >&2; exit 1; }
NATIVE_FIXES=1 tools/native/prepare.sh
COOLC_COMPILER_BIN=$BASE gtimeout 90 build/coolc build/native-src/Native.HC "$FIXED" \
    > "$OUT/fixed-compiler.log"
for name in B06LargeFloat B07StringDefault B08FunctionPointerArray; do
    case "$name" in
        B06LargeFloat) symbol=LargeFloatBits ;;
        B07StringDefault) symbol=DefaultByte ;;
        B08FunctionPointerArray) symbol=FunctionPointerArrayBytes ;;
    esac
    COOLC_COMPILER_BIN=$FIXED gtimeout 20 build/coolc \
        "coolc/tests/behavior/native/$name.HC" "$OUT/$name.BIN" \
        > "$OUT/$name.compile.log"
    gtimeout 10 build/coolc --probe "$OUT/$name.BIN" "$symbol" \
        > "$OUT/$name.actual"
    diff -u "coolc/tests/behavior/native/$name.expected" "$OUT/$name.actual"
    echo "PASS $name"
done
