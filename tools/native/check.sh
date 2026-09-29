#!/bin/sh
# Verify the unfixed native compiler against Aiwnios, then check self-hosting.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
AIW=${AIWNIOS_DIR:-$ROOT/coolc/third_party/aiwnios}
BIN=${AIWNIOS_BIN:-$AIW/aiwnios.app/Contents/MacOS/aiwnios}
make AIWNIOS="$AIW" build/coolc-selfhost.BIN
NATIVE_FIXES=0 tools/native/prepare.sh
IMAGE=$ROOT/build/coolc-selfhost.BIN
OUT=$ROOT/build/native-check
mkdir -p "$OUT"
pass=0
for source in coolc/tests/codegen/T*.HC; do
    name=$(basename "$source" .HC)
    AIWNIOS_DIR=$AIW AIWNIOS_BIN=$BIN AIWCC_TIMEOUT=30 \
        gtimeout 35 tools/aiwcc.sh coolc/tests/codegen "$name.HC" "$OUT/$name.ref.BIN" \
        > "$OUT/$name.ref.log"
    COOLC_COMPILER_BIN=$IMAGE gtimeout 20 build/coolc "$source" "$OUT/$name.native.BIN" \
        > "$OUT/$name.native.log"
    python3 tools/porttest/bincmp.py "$OUT/$name.ref.BIN" "$OUT/$name.native.BIN"
    pass=$((pass + 1))
done
echo "native codegen: $pass/24 matched Aiwnios"
COOLC_COMPILER_BIN=$IMAGE gtimeout 90 build/coolc build/native-src/Native.HC \
    "$OUT/coolc-gen3.BIN" > "$OUT/selfhost.log"
cmp "$IMAGE" "$OUT/coolc-gen3.BIN"
echo 'native self-build: generation 2 = generation 3, full BIN bytes'
AIWNIOS_DIR=$AIW AIWNIOS_BIN=$BIN AIWCC_TIMEOUT=60 \
    gtimeout 70 tools/aiwcc.sh os/Kernel Kernel.HC "$OUT/Kernel.ref.BIN" \
    > "$OUT/Kernel.ref.log"
COOLC_COMPILER_BIN=$IMAGE gtimeout 45 build/coolc os/Kernel/Kernel.HC \
    "$OUT/Kernel.native.BIN" > "$OUT/Kernel.native.log"
python3 tools/porttest/bincmp.py "$OUT/Kernel.ref.BIN" "$OUT/Kernel.native.BIN"
echo 'native kernel: machine code matched Aiwnios'
