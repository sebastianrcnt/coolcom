#!/bin/sh
# Build build/portrt: a copy of the Aiwnios runtime whose HolyC compiler uses
# the CoolC backend port (coolc/Compiler) instead of the C backend.
# The whole runtime is bootstrapped by Aiwnios' C compiler as usual; only
# code JIT/AOT-compiled at run time (e.g. Cmp()) goes through the port.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
AIW=$ROOT/coolc/third_party/aiwnios
BIN=$AIW/aiwnios.app/Contents/MacOS/aiwnios
RT=$ROOT/build/portrt
mkdir -p "$RT"
rsync -a --delete --exclude .git --exclude build --exclude aiwnios.app --exclude c \
  --exclude vendor --exclude asm --exclude cmake --exclude img --exclude 'CoolTmp*' \
  --exclude 'HCRT2.*' "$AIW/" "$RT/"
mkdir -p "$RT/Src/Port"
cp "$ROOT"/coolc/Compiler/*.HC "$ROOT"/coolc/Compiler/*.HH "$RT/Src/Port/"
# Use the extern (not import) declarations of the __HC_* functions and pull
# the port in right after them.
python3 - "$RT/Src/AIWNIOS_CodeGen.HC" <<'PY'
import sys
p = sys.argv[1]
s = open(p, 'rb').read()
s = s.replace(b'#ifdef IMPORT_AIWNIOS_SYMS', b'#ifdef PORT_BACKEND_NEVER', 1)
i = s.index(b'#endif', s.index(b'#ifdef PORT_BACKEND_NEVER'))
s = s[:i + 6] + b'\n#include "Port/Backend.HC"\n' + s[i + 6:]
open(p, 'wb').write(s)
PY
(cd "$RT" && "$BIN" -b -t . > "$ROOT/build/portrt-boot.log" 2>&1) || true
grep -a "Errs:" "$ROOT/build/portrt-boot.log" | tail -1
grep -a -q "Errs:0" "$ROOT/build/portrt-boot.log" || {
  grep -a -E "ERROR|Error" "$ROOT/build/portrt-boot.log" | head -20; exit 1; }
