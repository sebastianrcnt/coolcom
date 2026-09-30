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
STD=warmc/standard/src
OUT=build/warm-examples
mkdir -p "$OUT"
failed=0

# compile DIR MODULE EXPECTED [STDIN]: compile, run and compare the output
function compile() {
    local dir=warmc/examples/$1 module=$2 expected=$3 input=${4:-}
    local modules=("$STD/Buffer.warmh,$STD/Buffer.warm" "$STD/String.warmh,$STD/String.warm"
        "$STD/StringBuilder.warmh,$STD/StringBuilder.warm" "$STD/IO/IO.warmh,$STD/IO/IO.warm"
        "$STD/IO/Terminal.warmh,$STD/IO/Terminal.warm" "$STD/OS/Error.warm" "$STD/OS/Terminal.warmh,$STD/OS/Terminal.warm" "$dir/$module.warmh,$dir/$module.warm")
    if printf '%b' "$input" | tools/warm run "${modules[@]}" --entrypoint="Example.$module:main" >"$OUT/$module.actual" 2>"$OUT/$module.err" \
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
