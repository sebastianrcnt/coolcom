# Native coolc build

Cool is our HolyC dialect; `coolc` is its compiler (as Warm and `warmc`).

On Apple Silicon, `make` builds `build/coolc` from `coolc/Host`, then uses the
checked-in `coolc/seed/Compiler.BIN` to compile `os/Kernel/Kernel.HC`. The
resulting `build/Kernel.BIN` is linked into `build/kernel.Image`. The seed was
compiled by `build/coolc` from the owned frontend, runtime, and backend with
`COOLC_FRONTEND_FIXES` enabled. Aiwnios is not needed.

Run `make test` for the kernel and relocation checks. `tools/hcfmt.sh --selftest`
checks the formatter; `make fmt-check` checks tracked HolyC source. The
pre-commit hook installed by `make hooks` uses the same formatter.

The kernel also embeds the seed and loads it at run time for its shell, with a
HolyC port of `coolc/Host/native.c` (`os/Kernel/BinLoad.HC`, `os/Kernel/Shell.HC`;
see os/Kernel/M1.md). The shell depends on the seed's exports `ExePutS`,
`LexStmt2Bin` and `HashAdd`, on its imports, and on the `CCmpCtrl` and
`CHashExport` offsets noted in `Shell.HC`; rebuilding the seed with other
layouts or imports means updating the shell.

To compile another HolyC entry point:

```sh
make build/coolc
COOLC_COMPILER_BIN="$PWD/coolc/seed/Compiler.BIN" \
  build/coolc path/to/Entry.HC path/to/Output.BIN
```

`tools/native/prepare.sh` stages the owned compiler source under
`build/native-src`; frontend fixes are enabled by default.

Standalone programs can be executed with `build/coolc --run program.BIN [args...]`.
`NativeArgCount()` and `NativeArg(index)` expose the BIN path as argument zero
and the remaining arguments; an out-of-range index returns NULL.
`NativeErrPutS(text)` writes a string to stderr without adding a newline, and
`NativeExit(status)` terminates the host process. These imports are used by
Warm's native Cool runtime; they are not kernel shell services.
