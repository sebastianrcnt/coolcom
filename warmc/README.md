# Warm compiler

Warm is coolcom's fork of the Austral programming language. This directory
starts from Austral commit `0962d2a8a5d77f7daacd7f696819520733f4897d`
and builds an OCaml compiler named `warmc`. The source language and `.warmh`/`.warm`
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
./warmc/warmc compile example.warm --entrypoint=Example:main --output=example
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
No C compiler or external C-to-HolyC translator is needed to emit `.cool`.

From the repository root, on the native Apple Silicon host:

```sh
./warmc/build.sh
make build/coolc
./warmc/warmc compile \
  warmc/test-programs/suites/001-trivial/005-hello-world/Test.warm \
  --entrypoint=Test:main --target-type=hc --output=build/Hello.cool
COOLC_COMPILER_BIN="$PWD/coolc/seed/Compiler.BIN" \
  build/coolc build/Hello.cool build/Hello.BIN
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
For kernel-shell inclusion, the kernel adapter selects console error output and
an empty argument list; see the kernel bindings below.

Current deliberate limits:

- Float32 is rejected instead of silently widened to Float64.
- `@embed` supports the builtin arithmetic, numeric casts, memory/span and
  printing patterns; arbitrary C syntax is rejected with a backend diagnostic.
- Foreign imports call their HolyC symbol verbatim. Scalar integers, booleans,
  Float64, Unit/U0, pointers and span inputs are supported. The symbol must
  already be declared by an included HolyC header or adapter. Span arguments
  decay to pointers; pass their length explicitly. Aggregate/span returns need
  an explicit adapter; arbitrary C libraries are not automatically available.
  The native runtime still supplies libc-compatible `putchar`/`puts` shims.
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
emits `.cool`, compiles with `build/coolc` and the checked-in seed, and runs both.
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


## Kernel bindings and capabilities

`standard/src/Kernel/Kernel.warmh,Kernel.warm` provides `Warm.Kernel`.
Its 45 operations, plus resource/capability lifecycle functions, use the
kernel's actual FAT32, console, Key.cool, framebuffer, clock and scheduler APIs.
The HolyC boundary is `standard/src/Kernel/Adapter.cool`.

| Area | Warm operations | Kernel implementation |
| --- | --- | --- |
| Memory | allocate, close, fill, copyBytes, readByte, storeByte, bufferSize, bufferError | CAlloc, Free, MemSet, MemCpy; bounds-checked owned bytes |
| Strings | stringLength, stringCompare | StrLen, StrCmp |
| Output | write, putByte, putCodepoint | PutS, ConsPut, ConsPutCp |
| Filesystem | readFile, writeFile, dir, mkdir, cd, exists, delete, validName | FileRead, FileWrite, Dir, DirMk, Cd, FileFind, Del, FileNameChk |
| Time | now, unixNow, ticks, ticksHP, dateToUnix, unixToDate | Now, UnixNow, __GetTicks, __GetTicksHP, CDate2Unix, Unix2CDate |
| Keys | getKey, keyPending, keyPop, keyChar, utf8Width | Key.cool GetKey(FALSE), KeyPending, KeyPop, KeyChar; Utf8Width |
| Screen | clear, cursorHide, cursorShow, setColor, fillRect, scroll, screenCodepoint, alternate, ansiColor | ConsClear, FbCursorHide/Show, FbSetColor, FbFillRect, FbScroll, FbPutCp, FbAlt, FbAnsiColor |
| Tasks | yieldTask, sleep, sleepUntil, taskReport, isSilent | Yield, Sleep, SleepUntil, TaskRep, IsSilent |

### Boundary and ownership decisions

* This is a kernel-shell target, not a portable C standard module. Include the
  adapter **before** generated source. It defines `WARM_KERNEL`; native CLI
  imports are replaced with kernel-compatible helpers. CLI argument count is
  zero. Warm abort/ExitFailure returns control through the kernel's NativeExit.
* The generated private aggregate ABI stays inside Warm. The adapter accepts
  integers, opaque pointers and explicit pointer/length pairs. No generated
  class names, span layouts or allocation headers cross the boundary.
* Text inputs accept spans in any region. Use `Standard.String.getSpan` for
  heap strings. The adapter copies text into a temporary NUL-terminated
  `U8*`, rejects embedded NUL and text longer than 4096 bytes, and frees the
  copy on both success and caught exceptions. Binary file contents and
  `copyBytes` preserve embedded zero bytes. Input pointers are never retained.
* `readFile` uses the kernel's whole-file API, not a fictitious open file
  descriptor. It returns an opaque **linear Buffer**, even on failure.
  Read `bufferError`, borrow it for byte access, and consume it exactly once
  with `close`. `allocate` returns the same owned resource. Neither raw
  pointers nor escaping borrowed spans are exposed. Copies and indexes check
  buffer bounds. Allocation and write sizes are capped at 256 MiB. Rectangle
  coordinates are limited to signed 16-bit and sizes to 0..32767 before
  calling the framebuffer clipping code.
* Error values are `-1` (caught HolyC throw), `-2` (invalid input/bounds),
  `-3` (missing file/allocation or write failure), with zero for successful
  commands. Query functions return their documented nonnegative value or a
  negative error. Kernel boolean queries retain 0/1; `dir` and `delete`
  retain counts. `stringCompare` returns 0/1/2 for less/equal/greater, reserving
  negative values for errors. Date conversions retain signed kernel dates.
  Exception identity is deliberately collapsed to -1; the catch marks the
  exception handled and frees adapter-owned temporaries. The adapter cannot
  repair internal allocations leaked by a kernel function before it throws.
* `Filesystem`, `Terminal` and `Tasks` are opaque linear capability values.
  Acquire each only through a mutable borrow of RootCapability, borrow the
  capability for operations, and release it explicitly. Callers can pass a
  restricted capability to a helper without handing over root. These are
  Austral-style authority tokens, not path ACLs or exclusive device locks;
  root can derive multiple tokens. Open buffers outlive filesystem tokens
  because they own a detached memory snapshot.
* Opaque constructors are now checked against module visibility, closing an
  upstream hole that allowed constructing empty capability records outside
  their defining module. Tests reject root/capability forgery, missing
  capability arguments, leaked buffers and double close.
* This is a language-level discipline for callers of the safe API. Unsafe
  modules, arbitrary HolyC, and the existing Pervasive printing builtins are
  outside its authority boundary. Task creation/kill and raw kernel pointers
  are deliberately not exposed in this initial scheduler binding.

### Build and run in the shell

From the repository root:

```sh
./warmc/build.sh
./warmc/warmc compile \
  warmc/standard/src/Kernel/Kernel.warmh,warmc/standard/src/Kernel/Kernel.warm \
  warmc/examples/kernel/Files.warm \
  --entrypoint=Files:main --target-type=hc --output=build/Files.cool
# Put Adapter.cool and Files.cool on the FAT32 drive, then in the kernel shell:
# #include "C:/Adapter.cool"
# #include "C:/Files.cool"
make warm-kernel-test
```

The automated harness prepends the adapter include, creates an isolated FAT32
image under `build/warm-kernel`, and boots each example in a fresh shell.
Files writes and reads Warm.txt (also checked with host mtools); Screen draws
a rectangle whose exact pixels are checked in the VM screenshot; Key waits
for a scripted 'x' through Key.cool. Errors injects a throwing FileWrite at the
adapter boundary and checks exception conversion, missing files, memory
bounds and string operations. Four negative compilation fixtures check
capabilities and linear ownership. A native execution fixture also checks
general Unit/U0, integer and span foreign calls, with a C-side void-return
regression in the compiler suite. Logs, generated sources, disk and
screenshots remain in `build/warm-kernel`.

Root `make test` includes `warm-kernel-test`. The existing
`warmc/run-tests.sh` includes a separate opaque RootCapability-constructor
regression, and otherwise continues to run the portable C tests.
The full `compare-hc.py` still reports the pre-existing unsupported Float32
case (51 pass, 1 fail); this work does not skip or relabel that failure.
## Independent compiler written in Cool

[`Cool/`](Cool/README.md) now contains an independent Warm compiler written in
HolyC, including module resolution, generic/typeclass checking, linearity and
borrowing, monomorphization, HC output and caret/JSON diagnostics. It runs under
native coolc and in the OS kernel shell (`WarmRun` uses the existing HolyC JIT).
Its full-suite differential result is **296/296**: 86 runtime cases and 210
expected errors. These are separate from the OCaml HC renderer counts above.
See [the design](Cool/DESIGN.md) and [build, kernel and validation commands](Cool/README.md).
