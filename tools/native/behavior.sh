#!/bin/sh
# Compile fixed frontend cases and execute their exported probe functions.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BASE=$ROOT/coolc/seed/Compiler.BIN
OUT=$ROOT/build/native-behavior
mkdir -p "$OUT"
[ -f "$BASE" ] || { echo 'native compiler seed is missing' >&2; exit 1; }
for name in B05ClassCopy B06LargeFloat B07StringDefault B08FunctionPointerArray B09StringIndex; do
    case "$name" in
        B05ClassCopy) symbol=ClassCopyCheck ;;
        B06LargeFloat) symbol=LargeFloatBits ;;
        B07StringDefault) symbol=DefaultByte ;;
        B08FunctionPointerArray) symbol=FunctionPointerArrayBytes ;;
        B09StringIndex) symbol=StringIndexSum ;;
    esac
    COOLC_COMPILER_BIN=$BASE gtimeout 20 build/coolc \
        "coolc/tests/behavior/native/$name.HC" "$OUT/$name.BIN" \
        > "$OUT/$name.compile.log"
    gtimeout 10 build/coolc --probe "$OUT/$name.BIN" "$symbol" \
        > "$OUT/$name.actual"
    diff -u "coolc/tests/behavior/native/$name.expected" "$OUT/$name.actual"
    echo "PASS $name"
done
