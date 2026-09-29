#!/bin/sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
AIW=${AIWNIOS_DIR:-/Volumes/t5/coolcom/coolc/third_party/aiwnios}
BIN=${AIWNIOS_BIN:-$AIW/aiwnios.app/Contents/MacOS/aiwnios}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/coolc-host.XXXXXX")
trap 'find "$tmp" -depth -delete' EXIT HUP INT TERM
cat > "$tmp/Probe.HC" <<'EOF'
I64i g = 7;
I64i CoolCProbe() { return g + 35; }
EOF
make -C "$ROOT" build/coolc
AIWNIOS_DIR=$AIW AIWNIOS_BIN=$BIN AIWCC_TIMEOUT=20 \
  gtimeout 25 "$ROOT/tools/aiwcc.sh" "$tmp" Probe.HC "$tmp/Probe.BIN"
result=$(gtimeout 5 "$ROOT/build/coolc" --probe "$tmp/Probe.BIN" CoolCProbe)
[ "$result" = 42 ] || { echo "native BIN probe returned $result" >&2; exit 1; }
echo "native BIN loader probe: PASS"
