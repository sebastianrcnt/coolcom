# C to Cool pilot

`make c2hc-test` builds the native host, parses each `tests/*.c` with clang's
JSON AST, writes `.HC` and `.BIN` files under `build/c2hc-test`, and compares
the byte-for-byte stdout of the C executable and native Cool BIN.

Run the translator directly with:

```sh
python3 tools/c2hc/c2hc.py input.c output.HC
```

This pilot accepts simple definitions using integer, pointer, array, and
record types; functions; `if`, `for`, `while`, `do`, `break`, `continue`, and
`return`; simple array initializers; `printf`; and ternaries used as a returned
or assigned value. Expressions are parenthesized and 8/16/32-bit integer
arithmetic is narrowed to the C result width. It moves static local integers
to globals, changes `continue` to a loop-specific `goto`, converts struct
assignments to `MemCpy`, and prefixes known Cool keyword collisions.
Unsupported AST constructs produce an error instead of an unverified output.

The generated source is a small standalone native program. `printf` maps to
`Print`, which the native host binds to libc `printf`; the fixtures use `%d`
and `%s` with matching arguments. Records in this pilot have only 32-bit fields, so
Cool's packed class layout matches their C layout. The translator does not
yet cover the larger backend port, C preprocessor macros, function pointers,
varargs definitions, numeric floating casts, designated initializers, or
platform-dependent record padding.
