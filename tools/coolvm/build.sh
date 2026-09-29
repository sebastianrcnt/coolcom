#!/bin/sh
# Build coolvm (host tool) and ad-hoc codesign it with the hypervisor entitlement.
# Usage: build.sh [output]     (default: <repo>/build/coolvm)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${1:-$ROOT/build/coolvm}
mkdir -p "$(dirname "$OUT")"
clang -O2 -g -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
    -o "$OUT" "$HERE"/src/*.c "$HERE"/src/*.m -framework Hypervisor -framework AppKit -framework ImageIO -lpthread
codesign --force --sign - --entitlements "$HERE/entitlements.plist" "$OUT"
echo "built $OUT"
