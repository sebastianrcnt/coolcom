#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p build/warmcool build/tmp
export TMPDIR="$ROOT/build/tmp"
python3 warmc/Cool/embed_builtins.py
make build/coolc
rm -f build/warmcool/Warm.BIN
COOLC_COMPILER_BIN="$ROOT/coolc/seed/Compiler.BIN" build/coolc warmc/Cool/Native.HC build/warmcool/Warm.BIN >build/warmcool/build.log 2>&1 || { cat build/warmcool/build.log; exit 1; }
cat build/warmcool/build.log
grep -q 'Errs:0 ' build/warmcool/build.log
test -s build/warmcool/Warm.BIN
