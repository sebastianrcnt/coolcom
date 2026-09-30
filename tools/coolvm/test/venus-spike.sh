#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
V=$ROOT/vendor/venus
P=$V/install
OUT=$ROOT/build/venus-spike
mkdir -p "$OUT" "$V/protocol-driver"
# Use pinned pure-Python sources; MarkupSafe falls back without its C speedups.
export PYTHONPATH="$V/Mako:$V/MarkupSafe/src"
python3 "$V/venus-protocol/vn_protocol.py" --outdir "$V/protocol-driver"
# Keep the upstream wire codecs; omit Mesa's driver-specific submit wrappers.
python3 - "$V/protocol-driver" <<'PY'
import pathlib,sys
for p in pathlib.Path(sys.argv[1]).glob('*.h'):
    s=p.read_text().replace('#include "vn_instance.h"','')
    start=s.find('static inline void vn_submit_')
    if start>=0: s=s[:start]+'\n#endif\n'
    p.write_text(s)
PY
clang -O0 -g -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
    -I"$ROOT/tools/coolvm/test" -isystem "$V/protocol-driver" -isystem "$V/venus-protocol/include" -I"$P/include/virgl" -I"$P/include" \
    "$ROOT/tools/coolvm/test/venus-spike.c" -L"$P/lib" -Wl,-rpath,"$P/lib" -lvirglrenderer -framework Hypervisor -o "$OUT/spike"
codesign --force --sign - --entitlements "$ROOT/tools/coolvm/entitlements.plist" "$OUT/spike"
"$OUT/spike"

clang -O2 -g -std=gnu11 -Wall -Wextra -Wno-unused-parameter -DCOOLVM_VENUS=1 \
    -I"$ROOT/tools/coolvm/test" -isystem "$V/protocol-driver" -isystem "$V/venus-protocol/include" -I"$P/include/virgl" -I"$P/include" \
    "$ROOT/tools/coolvm/test/venus-gpu-test.c" "$ROOT/tools/coolvm/src/gpu.c" "$ROOT/tools/coolvm/src/gpu3d.c" \
    -L"$P/lib" -Wl,-rpath,"$P/lib" -lvirglrenderer -framework Hypervisor -lpthread -o "$OUT/gpu-test"
codesign --force --sign - --entitlements "$ROOT/tools/coolvm/entitlements.plist" "$OUT/gpu-test"
"$OUT/gpu-test"
