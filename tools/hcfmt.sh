#!/bin/sh
# HolyC formatter (coolc/Fmt/HCFmt.HC) run on the host through Aiwnios.
# Usage: hcfmt.sh [--check] [--diff] file.HC...   format in place
#        hcfmt.sh --selftest                      run coolc/Fmt/tests
# --check  change nothing, list files that would change, exit 1 if any
# --diff   like --check, also print a unified diff for each
# Exit: 0 all fine, 1 files differ (--check/--diff), 2 error (refused/unreadable).
# Aiwnios resolves paths relative to its boot directory, so inputs are copied
# to a temp dir there (removed on exit) and results copied back afterwards.
# AIWNIOS_DIR / AIWNIOS_BIN override the runtime location.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AIW=${AIWNIOS_DIR:-$ROOT/coolc/third_party/aiwnios}
BIN=${AIWNIOS_BIN:-$AIW/aiwnios.app/Contents/MacOS/aiwnios}
if [ ! -x "$BIN" ]; then
  # a git worktree does not carry the (untracked) runtime; use the main checkout's
  MAIN=$(cd "$ROOT" && dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  AIW=$MAIN/coolc/third_party/aiwnios
  BIN=$AIW/aiwnios.app/Contents/MacOS/aiwnios
fi
[ -x "$BIN" ] || { echo "hcfmt: Aiwnios not found at $BIN" >&2; exit 2; }
FMT=$ROOT/coolc/Fmt
TMP=CoolTmpFmt.$$
trap 'rm -rf "$AIW/$TMP"' EXIT INT TERM
MODE=write; SELF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --diff) MODE=diff; shift ;;
    --selftest) SELF=1; shift ;;
    --) shift; break ;;
    -*) echo "hcfmt: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $SELF = 1 ] || [ $# -gt 0 ] || { echo "usage: hcfmt.sh [--check|--diff] file.HC... | --selftest" >&2; exit 2; }

mkdir -p "$AIW/$TMP"
cp "$FMT/HCFmt.HC" "$FMT/HCFmtMain.HC" "$AIW/$TMP/"
RUN=$AIW/$TMP/Run.HC
{
  printf '#include "%s/HCFmt.HC"\n#include "%s/HCFmtMain.HC"\n' "$TMP" "$TMP"
} > "$RUN"

runaiw() { # prints the runtime output
  (cd "$AIW" && gtimeout 60 "$BIN" -c "$TMP/Run.HC" </dev/null 2>&1) || true
}

if [ $SELF = 1 ]; then
  mkdir -p "$AIW/$TMP/tests"
  cp "$FMT"/tests/*.HC "$AIW/$TMP/tests/"
  N=0
  for f in "$FMT"/tests/*.in.HC; do
    b=$(basename "$f" .in.HC)
    [ -f "$FMT/tests/$b.exp.HC" ] || { echo "hcfmt: missing $b.exp.HC" >&2; exit 2; }
    printf 'HCFmtTest("%s/tests/%s.in.HC","%s/tests/%s.exp.HC");\n' "$TMP" "$b" "$TMP" "$b" >> "$RUN"
    N=$((N+1))
  done
  printf 'ExitAiwnios;\n' >> "$RUN"
  OUT=$(runaiw)
  echo "$OUT" | grep -E "^HCFMT-TEST" | sed "s#$TMP/tests/##g" || true
  PASS=$(echo "$OUT" | grep -c "^HCFMT-TEST PASS" || true)
  echo "hcfmt selftest: $PASS/$N passed"
  for g in "$AIW/$TMP"/tests/*.got; do
    [ -f "$g" ] || continue
    b=$(basename "$g" .in.HC.got)
    diff -u "$FMT/tests/$b.exp.HC" "$g" | sed 1,2d || true
  done
  [ "$PASS" = "$N" ] || exit 1
  exit 0
fi

# file mode
i=0
for f in "$@"; do
  [ -f "$f" ] || { echo "hcfmt: no such file $f" >&2; exit 2; }
  cp "$f" "$AIW/$TMP/f$i.HC"
  printf 'HCFmtFile("%s/f%s.HC",HCF_TOFMT);\n' "$TMP" "$i" >> "$RUN"
  i=$((i+1))
done
printf 'ExitAiwnios;\n' >> "$RUN"
OUT=$(runaiw)
RC=0
i=0
for f in "$@"; do
  L=$(echo "$OUT" | grep -E "^HCFMT [A-Z-]+ $TMP/f$i.HC\$" || true)
  echo "$L" | grep -E "ERROR|WARN" | sed "s#$TMP/f$i.HC#$f#" >&2 || true
  if echo "$L" | grep -q ERROR; then
    RC=2
  elif [ -z "$L" ]; then
    echo "hcfmt: no result for $f" >&2; RC=2
  elif ! cmp -s "$f" "$AIW/$TMP/f$i.HC.fmt"; then
    if [ $MODE = write ]; then
      cp "$AIW/$TMP/f$i.HC.fmt" "$f"; echo "formatted $f"
    else
      echo "would change $f"
      [ $MODE = diff ] && { diff -u "$f" "$AIW/$TMP/f$i.HC.fmt" | sed "1s#.*#--- $f#;2s#.*#+++ $f (formatted)#" || true; }
      [ $RC = 2 ] || RC=1
    fi
  fi
  i=$((i+1))
done
exit $RC
