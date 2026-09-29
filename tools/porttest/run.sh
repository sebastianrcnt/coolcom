#!/bin/sh
# Differential test of the backend port: compile every test module with the
# stock Aiwnios runtime and with build/portrt (see mkportrt.sh) and compare
# the machine code. Usage: run.sh [test.HC ...] (default: all in coolc/tests/codegen)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
AIW=$ROOT/coolc/third_party/aiwnios
T=$ROOT/coolc/tests/codegen
OUT=$ROOT/build/porttest
mkdir -p "$OUT"
[ $# -gt 0 ] && TESTS="$*" || TESTS=$(cd "$T" && ls *.HC)
pass=0; fail=0
for t in $TESTS; do
  n=${t%.HC}
  AIWNIOS_DIR=$AIW "$ROOT/tools/aiwcc.sh" "$T" "$t" "$OUT/$n.ref.BIN" > "$OUT/$n.ref.log" 2>&1 \
    || { echo "SKIP $t (stock compiler failed)"; continue; }
  if AIWNIOS_PORT=1 AIWNIOS_DIR=$ROOT/build/portrt "$ROOT/tools/aiwcc.sh" "$T" "$t" "$OUT/$n.port.BIN" > "$OUT/$n.port.log" 2>&1 \
     && python3 "$ROOT/tools/porttest/bincmp.py" "$OUT/$n.ref.BIN" "$OUT/$n.port.BIN" > "$OUT/$n.diff" 2>&1; then
    pass=$((pass + 1)); echo "PASS $t"
  else
    fail=$((fail + 1)); echo "FAIL $t"; head -12 "$OUT/$n.diff" "$OUT/$n.port.log" 2>/dev/null | sed 's/^/     /'
  fi
done
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
