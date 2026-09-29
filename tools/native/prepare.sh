#!/bin/sh
# Assemble the tracked HolyC sources for a native compiler self-build.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
STAGE=$ROOT/build/native-src
mkdir -p "$STAGE"
cp coolc/Frontend/*.HC coolc/Frontend/*.HH coolc/Runtime/*.HC \
   coolc/Compiler/*.HC coolc/Compiler/*.HH "$STAGE/"
python3 - "$STAGE/Native.HC" "${NATIVE_FIXES:-0}" <<'PY'
import pathlib
import sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = '#include "Compiler.HC"'
assert s.count(needle) == 1
if sys.argv[2] == '1':
    s = '#define COOLC_FRONTEND_FIXES 1\n' + s
p.write_text(s.replace(needle, '#define BACKEND_NATIVE 1\n#include "Backend.HC"\n' + needle))
PY
