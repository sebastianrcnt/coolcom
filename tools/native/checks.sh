#!/bin/sh
# The compiler's checks: definite bugs are compile errors (coolc/tests/checks/Errors.cool), lookalikes
# that are fine compile (Clean.cool), and coolc --vet reports the style findings (Vet.cool).
# UPDATE=1 rewrites the .expected files.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
export COOLC_COMPILER_BIN=${COOLC_COMPILER_BIN:-$ROOT/coolc/seed/Compiler.BIN}
OUT=$ROOT/build/checks
mkdir -p "$OUT"
T=coolc/tests/checks

# The message and position of each finding: ERROR/vet lines with the "file,line" line after them.
findings() {
    grep -A1 -e '^ERROR' -e '^vet:' "$1" | grep -v '^--' | sed 's|^  .*/\([A-Za-z]*\.cool,[0-9]*\)$|  \1|' | grep -v '^Vet:' || true
}
compare() {
    if [ "${UPDATE:-}" = 1 ]; then
        cp "$2" "$T/$1.expected"
    else
        diff -u "$T/$1.expected" "$2" || { echo "FAIL $1" >&2; exit 1; }
    fi
    echo "PASS $1"
}

# Errors.cool: exits nonzero, writes no BIN, reports each error
rm -f "$OUT/Errors.BIN"
if gtimeout 60 build/coolc $T/Errors.cool "$OUT/Errors.BIN" > "$OUT/Errors.log" 2>&1; then
    echo "FAIL Errors: compiled" >&2; exit 1
fi
[ ! -e "$OUT/Errors.BIN" ] || { echo "FAIL Errors: wrote a BIN" >&2; exit 1; }
findings "$OUT/Errors.log" > "$OUT/Errors.actual"
compare Errors "$OUT/Errors.actual"

# Clean.cool: compiles without errors
gtimeout 60 build/coolc $T/Clean.cool "$OUT/Clean.BIN" > "$OUT/Clean.log" 2>&1 || { cat "$OUT/Clean.log"; echo "FAIL Clean" >&2; exit 1; }
grep -q 'Errs:0 ' "$OUT/Clean.log" || { cat "$OUT/Clean.log"; echo "FAIL Clean" >&2; exit 1; }
echo "PASS Clean"

# Vet.cool: --vet lists the findings; a normal compile does not
gtimeout 60 build/coolc --vet $T/Vet.cool > "$OUT/Vet.log" 2>&1
findings "$OUT/Vet.log" > "$OUT/Vet.actual"
grep '^Vet:' "$OUT/Vet.log" >> "$OUT/Vet.actual"
compare Vet "$OUT/Vet.actual"
gtimeout 60 build/coolc $T/Vet.cool "$OUT/Vet.BIN" > "$OUT/VetPlain.log" 2>&1
! grep -q '^vet:' "$OUT/VetPlain.log" || { echo "FAIL Vet: findings without --vet" >&2; exit 1; }
echo "PASS Vet (off by default)"
