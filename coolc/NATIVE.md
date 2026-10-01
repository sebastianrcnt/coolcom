# Native coolc build

Cool is our HolyC dialect; `coolc` is its compiler (as Warm and `warmc`).

On Apple Silicon, `make` builds `build/coolc` from `coolc/Host`, then uses the
checked-in `coolc/seed/Compiler.BIN` to compile `os/Kernel/Kernel.cool`. The
resulting `build/Kernel.BIN` is linked into `build/kernel.Image`. The seed was
compiled by `build/coolc` from the owned frontend, runtime, and backend with
`COOLC_FRONTEND_FIXES` enabled. Aiwnios is not needed.

Run `make test` for the kernel and relocation checks. `tools/hcfmt.sh --selftest`
checks the formatter; `make fmt-check` checks tracked HolyC source (and Warm source,
with `tools/warmfmt`, see `warmc/README.md`). The pre-commit hook installed by
`make hooks` uses the same formatters.

The kernel also embeds the seed and loads it at run time for its shell, with a
HolyC port of `coolc/Host/native.c` (`os/Kernel/BinLoad.cool`, `os/Kernel/Shell.cool`;
see os/Kernel/M1.md). The shell depends on the seed's exports `ExePutS`,
`LexStmt2Bin` and `HashAdd`, on its imports, and on the `CCmpCtrl` and
`CHashExport` offsets noted in `Shell.cool`; rebuilding the seed with other
layouts or imports means updating the shell.

To compile another HolyC entry point:

```sh
make build/coolc
COOLC_COMPILER_BIN="$PWD/coolc/seed/Compiler.BIN" \
  build/coolc path/to/Entry.cool path/to/Output.BIN
```

`tools/native/prepare.sh` stages the owned compiler source under
`build/native-src`; frontend fixes are enabled by default.

For a manual legacy HolyC compatibility check, run `tools/aiwnios-compile.sh`
after `make build/coolc`, with an existing Aiwnios checkout at `vendor/aiwnios`
or selected by `AIWNIOS=/path/to/aiwnios`. It compiles the full
`Src/FULL_PACKAGE.HC` bootstrap package without running it or modifying the
checkout. The current seed compiles the unmodified sources with `Errs:0`;
`WORKAROUNDS=1` is retained for older compiler images. The log, compiler tally
and output BIN are under `build/aiwnios-compile/` (or the directory given as
the first argument, which the script replaces). Check both the exit status
and `Errs:0` in `summary.txt`. This optional probe needs the external sources
and is independent of the normal build and `make test`.

The OS reaches the same fixed point: `make selfhost-test` (part of `make test`)
puts the staged sources on a FAT32 disk as `C:/Compiler`, the shell runs
`Cmp("C:/Compiler/Native.cool", "C:/Self.BIN")` with the compiler loaded from the
seed, and the host requires `Self.BIN` to equal `coolc/seed/Compiler.BIN`. This
found that `Cmp` left 15 bytes past the patch table's end uninitialized (zero
from macOS's fresh pages, the heap's poison in the kernel); they are zeroed now.
`make run` puts the sources on `build/disk.img` too.

Standalone programs can be executed with `build/coolc --run program.BIN [args...]`.
`NativeArgCount()` and `NativeArg(index)` expose the BIN path as argument zero
and the remaining arguments; an out-of-range index returns NULL.
`NativeErrPutS(text)` writes a string to stderr without adding a newline, and
`NativeExit(status)` terminates the host process. These imports are used by
Warm's native Cool runtime; they are not kernel shell services.

The compiler inlines small functions of the same unit into their callers
(`coolc/Frontend/Inline.cool`; rules, controls such as `noinline` and
`#define COOLC_NO_INLINE`, and measurements in
[docs/coolc-inline.md](../docs/coolc-inline.md)).
