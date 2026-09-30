#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
V=$ROOT/vendor/venus
P=$V/install
OUT=$ROOT/build/venus-spike
mkdir -p "$OUT" "$V/protocol-driver"
# Mako is a build-time Python tool, isolated from the user's Python environment.
if [ ! -x "$V/python/bin/python" ]; then python3 -m venv "$V/python"; fi
"$V/python/bin/python" -c 'import mako' 2>/dev/null || "$V/python/bin/pip" install Mako==1.3.10 MarkupSafe==3.0.3
"$V/python/bin/python" "$V/venus-protocol/vn_protocol.py" --outdir "$V/protocol-driver"
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
