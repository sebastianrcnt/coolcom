#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/coolc-host.XXXXXX")
trap 'find "$tmp" -depth -delete' EXIT HUP INT TERM
cat > "$tmp/Probe.cool" <<'EOF'
I64i g = 7;
I64i CoolCProbe() { return g + 35; }
EOF
make -C "$ROOT" -f tools/toolchain.mk build/coolc
COOLC_COMPILER_BIN="$ROOT/coolc/seed/Compiler.BIN" \
  gtimeout 25 "$ROOT/build/coolc" "$tmp/Probe.cool" "$tmp/Probe.BIN"
result=$(gtimeout 5 "$ROOT/build/coolc" --probe "$tmp/Probe.BIN" CoolCProbe)
[ "$result" = 42 ] || { echo "native BIN probe returned $result" >&2; exit 1; }
echo "native BIN loader probe: PASS"
