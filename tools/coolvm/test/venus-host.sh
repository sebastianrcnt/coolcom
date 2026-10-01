#!/bin/sh
# Real coolvm split queues and Venus renderer, without a guest or vCPU.
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
V=$ROOT/vendor/venus
P=$V/install
OUT=$ROOT/build/venus-host-test
mkdir -p "$OUT/protocol-driver"
# Use pinned pure-Python sources; keep generated codecs in build/.
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$V/Mako:$V/MarkupSafe/src"
python3 "$V/venus-protocol/vn_protocol.py" --outdir "$OUT/protocol-driver"
# Keep the upstream wire codecs; omit Mesa's driver-specific submit wrappers.
python3 - "$OUT/protocol-driver" <<'PY'
import pathlib,sys
for p in pathlib.Path(sys.argv[1]).glob('*.h'):
    s=p.read_text().replace('#include "vn_instance.h"','')
    start=s.find('static inline void vn_submit_')
    if start>=0: s=s[:start]+'\n#endif\n'
    p.write_text(s)
PY
clang -O2 -g -std=gnu11 -Wall -Wextra -Wno-unused-parameter -DCOOLVM_VENUS=1 \
    -I"$ROOT/tools/coolvm/test" -isystem "$OUT/protocol-driver" -isystem "$V/venus-protocol/include" -I"$P/include/virgl" -I"$P/include" \
    "$ROOT/tools/coolvm/test/venus-gpu-test.c" "$ROOT/tools/coolvm/src/gpu.c" "$ROOT/tools/coolvm/src/gpu3d.c" "$ROOT/tools/coolvm/src/venus-metal.m" \
    -L"$P/lib" -Wl,-rpath,"$P/lib" -lvirglrenderer -framework Hypervisor -framework Metal -framework QuartzCore -lpthread -o "$OUT/gpu-test"
codesign --force --sign - --entitlements "$ROOT/tools/coolvm/entitlements.plist" "$OUT/gpu-test"
"$OUT/gpu-test"
