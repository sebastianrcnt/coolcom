# Shared C library

`LibC.cool` supplies the C names used by tools/c2hc and Warm foreign imports.
It is ordinary Cool source, separate from the compiler seed. Include it once per
program. Host programs import the OS primitive names from build/coolc; OS programs
include Kernel.coolh first (COOLCOM_KERNEL). disk-files.sh installs it under
C:/coolc/LibC/LibC.cool.

The headers in include/ are the hermetic clang parsing interface for c2hc.
Memory, strings, C-locale classification, numeric conversion, printf formatting,
stdio, math and UTC time are implemented over the OS primitives. File streams
buffer entire files: writes reach FileWrite on fflush/fclose. stdin is byte input
on the host and line input on the OS. There is no process, environment, dynamic
loader, or signal implementation. Check return values for unsupported operations.

setjmp is lowered at its call site to the OS exception context; longjmp preserves
its nonzero return value (zero becomes one). LibCRun provides a context for C exit
and abort to return to their caller. Allocations have a private size header for
realloc; use malloc/free together, not MAlloc/Free across that boundary.

`make c2hc-test` compares library behavior with native C, including memory,
strings, formatting, file IO, math, time and a nonlocal jump. `make stbtt-test`
compares six translated font bitmaps against upstream C.
