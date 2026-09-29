#!/bin/sh
# Format HolyC with the checked-in native compiler and the native BIN host.
# Usage: hcfmt.sh [--check|--diff] file.HC... | --selftest
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=write
SELF=0
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
[ "$SELF" = 1 ] || [ $# -gt 0 ] || {
  echo 'usage: hcfmt.sh [--check|--diff] file.HC... | --selftest' >&2
  exit 2
}
make -s -C "$ROOT" build/hcfmt.BIN || exit 2
HOST=$ROOT/build/coolc
FMT=$ROOT/build/hcfmt.BIN
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hcfmt.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

if [ "$SELF" = 1 ]; then
  count=0
  pass=0
  for input in "$ROOT"/coolc/Fmt/tests/*.in.HC; do
    name=$(basename "$input" .in.HC)
    expected=$ROOT/coolc/Fmt/tests/$name.exp.HC
    [ -f "$expected" ] || { echo "hcfmt: missing $name.exp.HC" >&2; exit 2; }
    count=$((count + 1))
    if "$HOST" --format "$FMT" "$input" "$TMP/actual" &&
       "$HOST" --format "$FMT" "$expected" "$TMP/fixed" &&
       "$HOST" --format "$FMT" "$TMP/actual" "$TMP/again" &&
       cmp -s "$TMP/actual" "$expected" &&
       cmp -s "$TMP/fixed" "$expected" &&
       cmp -s "$TMP/again" "$TMP/actual"; then
      echo "HCFMT-TEST PASS $name"
      pass=$((pass + 1))
    else
      echo "HCFMT-TEST FAIL $name"
      diff -u "$expected" "$TMP/actual" || true
    fi
  done
  echo "hcfmt selftest: $pass/$count passed"
  [ "$pass" = "$count" ]
  exit $?
fi

result=0
for file in "$@"; do
  [ -f "$file" ] || { echo "hcfmt: no such file $file" >&2; exit 2; }
  if ! "$HOST" --format "$FMT" "$file" "$TMP/formatted"; then
    echo "hcfmt: failed to format $file" >&2
    result=2
    continue
  fi
  if ! cmp -s "$file" "$TMP/formatted"; then
    if [ "$MODE" = write ]; then
      cp "$TMP/formatted" "$file"
      echo "formatted $file"
    else
      echo "would change $file"
      if [ "$MODE" = diff ]; then
        diff -u "$file" "$TMP/formatted" || true
      fi
      [ "$result" = 2 ] || result=1
    fi
  fi
done
exit "$result"
