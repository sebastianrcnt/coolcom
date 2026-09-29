#!/bin/sh
set -eu
image=$1
shift
log=$(mktemp)
trap 'rm -f "$log"' EXIT
if gtimeout 45 build/coolvm --cpus 2 --mem 1024 --timeout 40 --bootargs 'coolcom.test=1' "$@" "$image" >"$log" 2>&1; then
    if grep -q 'SELFTEST PASS' "$log" && grep -q '2 cores online' "$log" && grep -q 'KERNEL TEST PASS' "$log"; then
        tail -n 12 "$log"
        exit 0
    fi
fi
cat "$log"
exit 1
