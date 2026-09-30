#!/usr/bin/env bash
# Part of the Austral project, under the Apache License v2.0 with LLVM Exceptions.
# See LICENSE file for details.
#
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

set -euxo pipefail

dune build

function compile() {
    ./warmc compile \
        ./standard/src/Buffer.warmh,./standard/src/Buffer.warm \
        ./standard/src/String.warmh,./standard/src/String.warm \
        ./standard/src/StringBuilder.warmh,./standard/src/StringBuilder.warm \
        ./standard/src/IO/IO.warmh,./standard/src/IO/IO.warm \
        ./standard/src/IO/Terminal.warmh,./standard/src/IO/Terminal.warm \
        $1/$2.warmh,$1/$2.warm \
        --entrypoint=Example.$2:main --output=testbin

    if [ $# -eq 4 ] 
    then
        echo -n -e $4 | ./testbin > actual.txt
    else
        ./testbin > actual.txt
    fi

    echo -n -e "$3" > expected.txt
    diff actual.txt expected.txt
    rm testbin
    rm actual.txt
    rm expected.txt
}

compile examples/ffi FFI "aHello, world!\n"
compile examples/fib Fibonacci ""
compile examples/generic-record GenericRecord ""
compile examples/generic-union GenericUnion ""
compile examples/haversine Haversine ""
compile examples/hello-world HelloWorld "Hello, world!\n"
compile examples/identity Identity ""
compile examples/memory Memory ""
compile examples/named-argument NamedArgument ""
compile examples/record Record ""
compile examples/union Union ""
compile examples/greet Greet "Hello, Santa!\n" "Santa"
