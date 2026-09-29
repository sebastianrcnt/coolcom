# Warm compiler

Warm is coolcom's fork of the Austral programming language. This directory
starts from Austral commit `0962d2a8a5d77f7daacd7f696819520733f4897d`
and builds an OCaml compiler named `warmc`. The source language and `.aui`/`.aum`
formats are currently compatible with that upstream commit.

The original project was created by Fernando Borretti and Austral contributors.
Their copyright notices and Apache-2.0-with-LLVM-exception license are preserved
in [LICENSE](LICENSE). The original README is preserved as
[UPSTREAM_README.md](UPSTREAM_README.md). Upstream source:
<https://github.com/austral/austral>.

## Build

Use the existing opam switch named `austral`:

```sh
./warmc/build.sh
./warmc/warmc --version
```

`build.sh` uses `opam exec --switch=austral` and produces `warmc/warmc`. It does
not modify coolcom's root Makefile. To compile a program:

```sh
./warmc/warmc compile example.aum --entrypoint=Example:main --output=example
```

From `warmc/`, run `opam exec --switch=austral -- ./run-tests.sh` for the full
compiler, end-to-end, example, and standard library test suite.

## Fixes since the fork

Warm validates required typeclass methods, duplicate methods, and instance
method signatures. It also corrects the built-in `Printable` instances, fixes
Buffer growth after `realloc`, and checks `Index` and `ByteSize` literals against
the host `size_t` width.

## Cool / HolyC backend

`--target-type=hc` emits standalone Cool source. It shares the existing
monomorphization and `CRepr` code generation with the C backend, then uses an
OCaml renderer (`lib/HCRenderer.ml`) and a Cool runtime (`lib/HCRuntime.ml`).
No C compiler or external C-to-HolyC translator is needed to emit `.HC`.

From the repository root, on the native Apple Silicon host:

```sh
./warmc/build.sh
make build/coolc
./warmc/warmc compile \
  warmc/test-programs/suites/001-trivial/005-hello-world/Test.aum \
  --entrypoint=Test:main --target-type=hc --output=build/Hello.HC
COOLC_COMPILER_BIN="$PWD/coolc/seed/Compiler.BIN" \
  build/coolc build/Hello.HC build/Hello.BIN
build/coolc --run build/Hello.BIN
```

An entrypoint emits `WarmMain()` and invokes it at module initialization.
`--no-entrypoint` emits user functions and their dependencies without running
an entrypoint. Unreachable builtins are omitted, so unused Float32 functions
do not prevent ordinary programs from compiling.

The backend parenthesizes operators, lowers conditional expressions and
short-circuit evaluation to statements, and initializes aggregate fields
explicitly. The shared IR has no `continue`. Integer narrowing uses masks and
explicit signed extension; checked arithmetic detects overflow before
returning the narrowed result. Float64 conversions use numeric assignments,
not bit-reinterpreting postfix casts.

Records, union payloads, and spans use packed Cool classes. `sizeof` and pointer
strides follow the target layout, which can differ from C padding and enum
sizes. The internal ABI passes aggregate arguments by pointer, copies them
into callee locals, and returns aggregates through an output pointer. Copies
use `MemCpy`; all temporaries are stack locals. This is an explicit backend ABI,
not a workaround required by current class assignment: coolc frontend fix 5,
enabled in the checked-in seed, already copies whole classes. The older
8-byte-copy warning in `coolc/Compiler/PORTING.md` describes historical behavior.

Allocation/free and byte copies call `CAlloc`, `Free`, and `MemCpy`; the Warm
runtime implements realloc with a private allocation-size header and memmove
with overlap-aware byte copying. Output calls HolyC `Print` (bound to native
printf). Abort writes stderr through `NativeErrPutS` and calls `NativeExit`.
`NativeArgCount`/`NativeArg` supply CLI arguments; argument zero is the BIN path.
These native imports need adapters before kernel-shell inclusion; kernel
`#include` execution has not been tested.

Current deliberate limits:

- Float32 is rejected instead of silently widened to Float64.
- `@embed` supports the builtin arithmetic, numeric casts, memory/span and
  printing patterns; arbitrary C syntax is rejected with a backend diagnostic.
- Foreign calls currently support `putchar` and `puts` through Cool adapters.
  Other C library/foreign APIs need explicit bindings.
- The generated aggregate ABI and packed layouts are private to this backend;
  they are not C ABI compatible. Libraries retain generated symbol names.

### Differential validation

```sh
python3 warmc/test-programs/compare-hc.py
# A focused run that is expected to pass completely:
python3 warmc/test-programs/compare-hc.py --filter 018-hc-backend
```

The script selects every test with `program-stdout.txt` or `program-stderr.txt`,
including custom `cli.txt` module lists. It emits and builds C with `-fwrapv`,
emits `.HC`, compiles with `build/coolc` and the checked-in seed, and runs both.
It first checks C against the recorded expectation, then compares stdout,
stderr, and process exit status **exactly** between C and Cool. Both programs
receive the same argv[0]; only the CLI fixture's historical `/tmp` path in its
recorded expectation is relocated. It checks coolc's `Errs:0` report as well
as its exit status and output file, and applies a per-command timeout.

Sources, binaries, commands, stdout/stderr logs, and categorized `results.json`
are saved under `build/warmhc-comparison/`. Any failure makes the script exit
nonzero; the known Float32 failure is not counted as a pass or silently skipped.
`--filter` selects a substring of the suite/test path; `--timeout` changes the
20-second per-command limit.

Results on 2026-09-30, native arm64 macOS, opam switch `austral`:

| Selection | Passed | Failed | Failure classification |
| --- | ---: | ---: | --- |
| Original tests with recorded runtime output | 45 | 1 | Unsupported Float32 |
| Added `018-hc-backend` semantic regressions | 6 | 0 | — |
| Total | **51** | **1** | `001-trivial/015-float-conversions` |

The remaining test uses Float32 arithmetic/conversions/printing; Cool has no
F32 scalar representation. The compiler rejects it before writing output.
No native compilation errors, output differences, crashes, or timeouts remain
in this selection. Compile-error tests and tests without recorded runtime
output are outside this differential count.

`warmc/run-tests.sh` (OCaml tests, all C end-to-end tests, examples, standard
library) and root `make test` (kernel, relocation, Vim, and shell checks) also
pass. To keep regression artifacts within this checkout:

```sh
mkdir -p build/tmp
TMPDIR="$PWD/build/tmp" WARM_TEST_TMPDIR="$PWD/build/tmp" \
  opam exec --switch=austral -- sh -c 'cd warmc && ./run-tests.sh'
TMPDIR="$PWD/build/tmp" make test
```

## Independent compiler written in Cool

[`Cool/`](Cool/README.md) now contains an independent Warm compiler written in
HolyC, including module resolution, generic/typeclass checking, linearity and
borrowing, monomorphization, HC output and caret/JSON diagnostics. It runs under
native coolc and in the OS kernel shell (`WarmRun` uses the existing HolyC JIT).
Its full-suite differential result is **296/296**: 86 runtime cases and 210
expected errors. These are separate from the OCaml HC renderer counts above.
See [the design](Cool/DESIGN.md) and [build, kernel and validation commands](Cool/README.md).
