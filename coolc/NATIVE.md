# Native CoolC build

On Apple Silicon, `make` builds `build/coolc` from `coolc/Host`, then uses the
checked-in `coolc/seed/Compiler.BIN` to compile `os/Kernel/Kernel.HC`. The
resulting `build/Kernel.BIN` is linked into `build/kernel.Image`. The seed was
compiled by `build/coolc` from the owned frontend, runtime, and backend with
`COOLC_FRONTEND_FIXES` enabled. Aiwnios is not needed.

Run `make test` for the kernel and relocation checks. `tools/hcfmt.sh --selftest`
checks the formatter; `make fmt-check` checks tracked HolyC source. The
pre-commit hook installed by `make hooks` uses the same formatter.

To compile another HolyC entry point:

```sh
make build/coolc
COOLC_COMPILER_BIN="$PWD/coolc/seed/Compiler.BIN" \
  build/coolc path/to/Entry.HC path/to/Output.BIN
```

`tools/native/prepare.sh` stages the owned compiler source under
`build/native-src`; frontend fixes are enabled by default.
