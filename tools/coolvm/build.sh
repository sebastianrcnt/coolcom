#!/bin/sh
# Build coolvm (host tool) and ad-hoc codesign it with the hypervisor entitlement.
# Usage: build.sh [output]     (default: <repo>/build/coolvm)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-$ROOT/build/coolvm}
mkdir -p "$(dirname "$OUT")"
if [ "${COOLVM_VENUS:-0}" = 1 ]; then
    P=$ROOT/vendor/venus/install
    [ -f "$P/lib/libvirglrenderer.dylib" ] || { echo 'Run tools/vendor-venus.sh --host first' >&2; exit 1; }
    # Compiler arguments are set positionally so a workspace path can contain spaces.
    set -- -DCOOLVM_VENUS=1 -I"$P/include/virgl" -L"$P/lib" -Wl,-rpath,"$P/lib" -lvirglrenderer
else
    set --
fi
clang -O2 -g -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
    "$@" -o "$OUT" "$HERE"/src/*.c "$HERE"/src/*.m -framework Hypervisor -framework AppKit -framework QuartzCore -framework Metal -framework ImageIO -lpthread
codesign --force --sign - --entitlements "$HERE/entitlements.plist" "$OUT"
echo "built $OUT"
