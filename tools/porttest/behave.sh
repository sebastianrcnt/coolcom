#!/bin/sh
# Execute HolyC behavior cases using the port in build/portrt.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RT=$ROOT/build/portrt
BIN=$ROOT/coolc/third_party/aiwnios/aiwnios.app/Contents/MacOS/aiwnios
TESTS=$ROOT/coolc/tests/behavior
if [ ! -f "$RT/HCRT2.BIN" ]; then
  echo "Build build/portrt with tools/porttest/mkportrt.sh first" >&2
  exit 1
fi
tmp="$RT/CoolTmpBehavior.$$"
mkdir -p "$tmp"
trap 'find "$tmp" -depth -delete' EXIT HUP INT TERM
pass=0
fail=0
for source in "$TESTS"/*.HC; do
  [ -f "$source" ] || continue
  name=$(basename "$source" .HC)
  if [ $# -gt 0 ]; then
    selected=0
    for arg in "$@"; do
      if [ "$arg" = "$name" ] || [ "$arg" = "$name.HC" ]; then
        selected=1
      fi
    done
    [ "$selected" -eq 1 ] || continue
  fi
  cp "$source" "$tmp/$name.HC"
  cat > "$tmp/Run.HC" <<EOF
extern I64 b_use_port; b_use_port=TRUE;
Print("BEHAVIOR_START\\n");
#include "$(basename "$tmp")/$name.HC"
Print("BEHAVIOR_END\\n");
ExitAiwnios;
EOF
  (cd "$RT" && gtimeout 20 "$BIN" -t . -c "$(basename "$tmp")/Run.HC" < /dev/null) > "$tmp/$name.log" 2>&1
  status=$?
  awk '/^BEHAVIOR_START$/{copy=1;next} /^BEHAVIOR_END$/{copy=0;next} copy{print}' "$tmp/$name.log" > "$tmp/$name.out"
  if [ "$status" -eq 0 ] && grep -q '^BEHAVIOR_END$' "$tmp/$name.log" && diff -u "$TESTS/$name.expected" "$tmp/$name.out"; then
    pass=$((pass + 1))
    echo "PASS $name"
  else
    fail=$((fail + 1))
    echo "FAIL $name (exit $status)"
    tail -12 "$tmp/$name.log"
  fi
done
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
