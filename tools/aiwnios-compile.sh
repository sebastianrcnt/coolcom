#!/bin/sh
# Compile-only conformance check: feed the Aiwnios TempleOS sources
# (vendor/aiwnios/Src, entered through FULL_PACKAGE.HC exactly as the Aiwnios
# BOOTSTRAP command line does in vendor/aiwnios/c/main.c) to build/coolc.
# Nothing is run; unresolved host/C runtime symbols are simply left unresolved.
#
#   tools/aiwnios-compile.sh [outdir]      (default outdir: build/aiwnios-compile)
#
# Env:
#   COOLC               compiler host          (default build/coolc)
#   COOLC_COMPILER_BIN  compiler image         (default coolc/seed/Compiler.BIN)
#   AIWNIOS             Aiwnios checkout       (default vendor/aiwnios)
#   COMPONET_GR=0       skip the GUI/utility half of the OS (default 1: the
#                       full HCRT_TOS.HC set, ~196 files)
#   WORKAROUNDS=1       patch a private copy of Src/ for the coolc bugs listed
#                       below so compilation can get past them (default 0: the
#                       untouched sources, which currently abort in the backend)
#   TIMEOUT             seconds (default 600)
# Writes stage/ (Src mirror + Drv.HC), compile.log and summary.txt to outdir.
#
# Known coolc bug worked around by WORKAROUNDS=1: storing into a local of
# class type (not pointer) aborts the backend (abort() in Compiler/IRBind.cool
# or ArmBackendA.cool, unhandled exception 'Abrt', no source location). Valid
# to Aiwnios, which lets such a local double as an integer/pointer:
#   MultiProc.HC:9       CTask *task,task1;  ... task1=Fs;
#   AIWNIOS_CodeGen.HC   CRPN *cur2,*next2,cnt2;  ... for(cnt2=...;cnt2>=0;cnt2--)
#   AsmARM64.HC          CArm64Opc *opc,a;  ... for(a=0;a!=16;++a)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
COOLC=${COOLC:-$ROOT/build/coolc}
export COOLC_COMPILER_BIN=${COOLC_COMPILER_BIN:-$ROOT/coolc/seed/Compiler.BIN}
AIWNIOS=$(cd "${AIWNIOS:-$ROOT/vendor/aiwnios}" && pwd)
OUT=${1:-$ROOT/build/aiwnios-compile}
rm -rf "$OUT"
mkdir -p "$OUT/stage"
OUT=$(cd "$OUT" && pwd)
STAGE=$OUT/stage
# coolc resolves #include relative to the entry's directory, not the includer's,
# so compile from a stage dir that mirrors Src/ (vendor/ itself is never edited).
if [ "${WORKAROUNDS:-0}" = 1 ]; then
  cp "$AIWNIOS"/Src/* "$STAGE/"
  sed -i.bak 's/CTask \*task,task1;/CTask *task,*task1;/' "$STAGE/MultiProc.HC"
  sed -i.bak 's/CRPN \*cur2,\*next2,cnt2;/CRPN *cur2,*next2; I64 cnt2;/' "$STAGE/AIWNIOS_CodeGen.HC"
  sed -i.bak 's/CArm64Opc \*opc,a;/CArm64Opc *opc; I64 a;/' "$STAGE/AsmARM64.HC"
  rm -f "$STAGE"/*.bak
else
  for f in "$AIWNIOS"/Src/*; do ln -s "$f" "$STAGE/"; done
fi
ln -s "$AIWNIOS/Src" "$STAGE/Src"
GR=
[ "${COMPONET_GR:-1}" = 1 ] && GR='#define COMPONET_GR 1'
# Same prologue as BOOTSTRAP_FMT in c/main.c (aarch64 + Apple ABI).
cat > "$STAGE/Drv.HC" <<HC
#define TARGET_AARCH64 1
#define lastclass "U8"
#define public
#define IMPORT_AIWNIOS_SYMS 1
#define TEXT_MODE 1
#define BOOTSTRAP 1
#define PAUSE ;
#define HOST_ABI 'Apple'
$GR
#include "FULL_PACKAGE.HC";;
HC
rc=0
gtimeout "${TIMEOUT:-600}" "$COOLC" "$STAGE/Drv.HC" "$OUT/Out.BIN" > "$OUT/compile.log" 2>&1 || rc=$?
{
  echo "exit status: $rc  (workarounds: ${WORKAROUNDS:-0}, GR: ${COMPONET_GR:-1})"
  echo "compiler tally: $(grep '^Errs:' "$OUT/compile.log" || echo none)"
  echo "--- messages by kind (count, text with names/numbers folded) ---"
  grep -E '^(ERROR|WARNING|abort|Unhandled)' "$OUT/compile.log" \
    | sed -E "s/'[^']*'/Q/g; s/ at [^ ]*\$//; s/[0-9]+/N/g" \
    | sort | uniq -c | sort -rn
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
exit $rc
