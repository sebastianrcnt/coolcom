#!/bin/sh
# Compile a HolyC source tree to a BIN with the Aiwnios stage-0 compiler.
# Usage: aiwcc.sh <src_dir> <entry.HC> <out.BIN>
# Aiwnios resolves paths relative to its boot directory (AIWNIOS_DIR, which
# holds HCRT2.BIN), so the tree is copied there. AIWNIOS_BIN picks the
# executable, so another boot directory (e.g. build/portrt) can be used.
set -e
SRC=$(cd "$1" && pwd); ENTRY=$2; OUT=$3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AIW=${AIWNIOS_DIR:-$ROOT/coolc/third_party/aiwnios}
BIN=${AIWNIOS_BIN:-$ROOT/coolc/third_party/aiwnios/aiwnios.app/Contents/MacOS/aiwnios}
TMP=CoolTmp.$$
trap 'rm -rf "$AIW/$TMP"' EXIT
mkdir -p "$AIW/$TMP"
cp -R "$SRC/" "$AIW/$TMP/"
printf 'Cd("%s");\nCmp("%s",NULL,"Out.BIN");\nExitAiwnios;\n' "$TMP" "$ENTRY" > "$AIW/$TMP/Run.HC"
LOG=$(cd "$AIW" && "$BIN" -t . -c "$TMP/Run.HC" 2>&1 | grep -v -E "WARNING: Fun [Hh]eader|Headers.HH" || true)
echo "$LOG" | grep -E "Errs:|ERROR|Unresolved" || true
echo "$LOG" | grep -q "Errs:0" || { echo "$LOG"; exit 1; }
cp "$AIW/$TMP/Out.BIN" "$OUT"
