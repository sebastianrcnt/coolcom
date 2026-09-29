#!/bin/sh
# Build the first native compiler image with Aiwnios as stage zero.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
STAGE=$ROOT/build/native-src
OUT=${1:-$ROOT/build/coolc-compiler.BIN}
mkdir -p "$STAGE" "$(dirname "$OUT")"
cp coolc/Frontend/*.HC coolc/Frontend/*.HH coolc/Runtime/*.HC \
   coolc/Compiler/*.HC coolc/Compiler/*.HH "$STAGE/"
python3 tools/porttest/hostrename.py \
    "$STAGE/BackendA.HH" "$STAGE/BackendRT.HC" "$STAGE/BQSort.HC" \
    "$STAGE/IRBind.HC" "$STAGE/Arm64Enc.HC" "$STAGE/OptPass.HC" \
    "$STAGE/ArmBackendA.HC" "$STAGE/ArmBackendB.HC"
python3 - "$STAGE/Native.HC" <<'PY'
import pathlib
import sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = '#include "Compiler.HC"'
assert s.count(needle) == 1
p.write_text(s.replace(needle, '#include "Backend.HC"\n' + needle))
PY
AIWCC_TIMEOUT=45 gtimeout 50 tools/aiwcc.sh "$STAGE" Native.HC "$OUT"
