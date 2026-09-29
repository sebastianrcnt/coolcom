#!/bin/sh
# Build the first native compiler image with Aiwnios as stage zero.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT=${1:-$ROOT/build/coolc-compiler.BIN}
mkdir -p "$(dirname "$OUT")"
tools/native/prepare.sh
AIWCC_TIMEOUT=45 gtimeout 50 tools/aiwcc.sh build/native-src Native.HC "$OUT"
