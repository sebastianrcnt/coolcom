#!/bin/sh
# Parse every tracked .warm/.warmh file in the repo with the grammar; fail on any ERROR/MISSING.
# Usage: tools/tree-sitter-warm/check-repo.sh   (needs tree-sitter on PATH or $TREE_SITTER)
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
ts=${TREE_SITTER:-tree-sitter}
cd "$here"
"$ts" generate --abi 14
git -C "$root" ls-files -z '*.warm' '*.warmh' | (cd "$root" && xargs -0 "$ts" parse --grammar-path "$here" --quiet --stat >"${TMPDIR:-/tmp}/warm-parse.out" 2>&1) || {
  grep -v '^$' "${TMPDIR:-/tmp}/warm-parse.out" | head -40
  echo "FAIL: some .warm/.warmh files did not parse cleanly" >&2
  exit 1
}
tail -3 "${TMPDIR:-/tmp}/warm-parse.out"
echo "ok: all $(git -C "$root" ls-files '*.warm' '*.warmh' | wc -l | tr -d ' ') files parse without errors"
