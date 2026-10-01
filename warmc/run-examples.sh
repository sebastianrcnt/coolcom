#!/usr/bin/env bash
# Part of the Austral project, under the Apache License v2.0 with LLVM Exceptions.
# See LICENSE file for details.
#
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#
# Run the examples with the Warm compiler written in Cool (tools/warm) and compare their output.
# From the repository root: warmc/run-examples.sh
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=build/warm-examples
mkdir -p "$OUT"
failed=0

# compile DIR MODULE EXPECTED [STDIN]: compile, run and compare the output
function compile() {
    local dir=warmc/examples/$1 module=$2 expected=$3 input=${4:-}
    if printf '%b' "$input" | tools/warm run "$dir/$module.warm" --entrypoint="Example.$module:main" >"$OUT/$module.actual" 2>"$OUT/$module.err" \
        && printf '%b' "$expected" | cmp -s - "$OUT/$module.actual"; then
        echo "PASS $1"
    else
        echo "FAIL $1 (see $OUT/$module.actual and $OUT/$module.err)"
        failed=1
    fi
}

compile ffi FFI "aHello, world!\n"
compile fib Fibonacci ""
compile generic-record GenericRecord ""
compile generic-union GenericUnion ""
compile haversine Haversine ""
compile hello-world HelloWorld "Hello, world!\n"
compile identity Identity ""
compile memory Memory ""
compile named-argument NamedArgument ""
compile record Record ""
compile union Union ""
compile greet Greet "Hello, World!\n" "World\n"
exit $failed
