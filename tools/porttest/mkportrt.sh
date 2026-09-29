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
python3 "$ROOT/tools/porttest/hostrename.py" "$RT"/Src/Port/*.HC "$RT"/Src/Port/*.HH > /dev/null
[ -n "$PORT_STUBS" ] && cp "$PORT_STUBS"/* "$RT/Src/Port/"  # testing only: stand-ins for unfinished files
# The port's bindings are renamed __HC_* -> __PB_*; the frontend calls go
# through HCSel_* wrappers that pick the C backend or the port (b_use_port).
for f in "$RT"/Src/Port/*.HC "$RT"/Src/Port/*.HH; do
  perl -pi -e 's/\b__HC_/__PB_/g' "$f"
done
if [ -n "$PORT_INSTRUMENT" ]; then  # debug: trace every port function entry (see tracert.sh)
  python3 "$ROOT/tools/porttest/addtrace.py" "$RT"/Src/Port/IRBind.HC "$RT"/Src/Port/OptPass.HC \
    "$RT"/Src/Port/ArmBackendA.HC "$RT"/Src/Port/ArmBackendB.HC "$RT"/Src/Port/BQSort.HC \
    "$RT"/Src/Port/Arm64Enc.HC "$RT"/Src/Port/BackendRT.HC
  printf '#define PORT_TRACE_ALL '"${PORT_TRACE_ALL:-0}"'\nI64 b_trace_n;\nU0 BTrace(U8 *name)\n{\n  b_trace_n++;\n  if (PORT_TRACE_ALL || b_trace_n<20000 || !(b_trace_n&0xFFFF))\n    Print("T %%d %%s\\n",b_trace_n,name);\n}\n' > "$RT/Src/Port/BTrace.HC"
  perl -0pi -e 's/#include "BackendA.HH"\n/#include "BackendA.HH"\n#include "BTrace.HC"\n/' "$RT/Src/Port/Backend.HC"
fi
python3 "$ROOT/tools/porttest/mkswitch.py" "$RT/Src/AIWNIOS_CodeGen.HC" "$RT/Src/Port/Switch.HC" > /dev/null
(cd "$RT" && gtimeout 120 "$BIN" -b -t . < /dev/null > "$ROOT/build/portrt-boot.log" 2>&1) || echo "bootstrap exited with $? (124 = timed out)"
grep -a "Errs:" "$ROOT/build/portrt-boot.log" | tail -1
grep -a -q "Errs:0" "$ROOT/build/portrt-boot.log" || {
  grep -a -E "ERROR|Error" "$ROOT/build/portrt-boot.log" | head -20; exit 1; }
