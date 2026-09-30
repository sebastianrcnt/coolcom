# Warm compiler

Warm is coolcom's fork of the Austral programming language, a language with linear types
and capabilities. This directory starts from Austral commit
`0962d2a8a5d77f7daacd7f696819520733f4897d`; the source language and the `.warmh`
(interface) and `.warm` (body) formats are compatible with that upstream commit. The
older `.aui` and `.aum` names are still accepted.

The original project was created by Fernando Borretti and Austral contributors. Their
copyright notices and Apache-2.0-with-LLVM-exception license are preserved in
[LICENSE](LICENSE). The original README is preserved as
[UPSTREAM_README.md](UPSTREAM_README.md). Upstream source: <https://github.com/austral/austral>.

The compiler here is written in Cool (HolyC) and is the only one: the OCaml compiler of
Austral that this fork started from has been removed. It parses, resolves modules, checks
types, generics and typeclasses, linearity and borrowing, monomorphizes, and emits Cool
source, with source/caret or JSON diagnostics. It runs under native `coolc` on the Mac and
inside the OS kernel shell (`WarmRun` uses the shell's JIT). See [DESIGN.md](DESIGN.md) for
the implementation boundaries.

## Files

| Path | What |
|---|---|
| `Core.cool` `Lexer.cool` `Parser.cool` `Resolve.cool` `Types.cool` `Fold.cool` `Check.cool` `Linear.cool` `Emit.cool` `Diagnostic.cool` | the compiler (`Warm.cool` includes the passes) |
| `Runtime.cool` | the runtime that every generated program starts with |
| `Native.cool` | the host command line (built into `build/warmcool/Warm.BIN`) |
| `Kernel.cool` | `WarmRun` and `WarmCompile` for the kernel shell (`package_kernel.py` makes `C:/Warm.cool`) |
| `builtin/` | Pervasive and Memory, original Warm source that is embedded into the compiler (`embed_builtins.py`) |
| `standard/` `examples/` | the standard library and example programs; `standard/src/Kernel` is `Warm.Kernel` for the OS |
| `test-programs/` | the end-to-end test suites |
| `compare.py` `test_*.py` | the tests |

## Use on the Mac

From the repository root:

```sh
make build/warmc                  # Warm.BIN (warmc/build.sh) and the wrapper build/warmc
tools/warm run Foo.warm           # compile, build and run in one step
```

`build/warmc` is a wrapper script that runs `build/coolc --run build/warmcool/Warm.BIN`
with its arguments, so it works like a compiler command:

```sh
build/warmc compile Api.warmh,Api.warm Main.warm --entrypoint=Main:main \
  --target-type=hc --output=build/Main.cool
COOLC_COMPILER_BIN="$PWD/coolc/seed/Compiler.BIN" build/coolc build/Main.cool build/Main.BIN
build/coolc --run build/Main.BIN
```

`tools/warm run [--entrypoint=Module:main] FILES [-- program arguments]` does the three
steps, keeping the files under `build/warm-run/`; `tools/warm compile` stops after the
Cool file. The entrypoint defaults to `Module:main` of the last file's `module body`.
Supply modules as `path/Module.warmh,path/Module.warm` or a lone `path/Module.warm`; all
dependencies must be listed. Pervasive and Memory are embedded. Options of `compile`:

- `--parse`: lexer/parser only; `--dump-ast`: print the parsed tree.
- `--check`: all semantic checks, without generating code.
- `--entrypoint=Module:function`: defaults to `Test:main`; `--no-entrypoint`: emit the
  concrete functions and exports without invoking main.
- `--output=path` and `--target-type=hc`: write Cool source.
- `--error-format=plain|json`: source/caret diagnostics or structured JSON.

The only target is Cool source; there is no C or executable target.

## Use in the OS

`make disk-install` and `make disk-seed` (also `make run`) put the packaged compiler on
the disk as `C:/Warm.cool`, and `C:/Init.cool` loads it. In the kernel shell:

```c
WarmRun("C:/Test.warm");
WarmRun("C:/Api.warmh,C:/Api.warm,C:/Main.warm", "Main:main");
WarmCompile("C:/Test.warm", "Test:main", "C:/Test.cool");
```

`WarmRun` compiles and immediately JIT-executes through `ShellExe`, returning true on
completion and false on compilation or runtime failure. Later runs use distinct generated
names. `WarmCompile` with an output path writes Cool instead of executing. Kernel errors
include filename, line and caret. Execution uses the current shell task's compiler state.
Program arguments are just the source path as argv[0].

This is Cool text handed to the existing coolc JIT, not direct IR emission. JIT code stays
in the shell symbol table; the compilation arena is released after every operation.

## The Cool backend

The generated program is standalone Cool: records, union payloads and spans are packed
classes, so `sizeof` and pointer strides follow that layout. The internal ABI passes
aggregate arguments by pointer, copies them into callee locals and returns aggregates
through an output pointer; it is private to the module, not C ABI compatible. Allocation
calls `CAlloc`, `Free` and `MemCpy`; realloc uses a private size header. Output calls
`Print`. Abort writes to stderr through `NativeErrPutS` and calls `NativeExit`;
`NativeArgCount`/`NativeArg` supply the arguments (argument zero is the BIN path). Inside
the kernel shell (`WARM_KERNEL`, set by the kernel adapter) they are console output and an
empty list. Integer narrowing uses masks and explicit sign extension, and checked
arithmetic detects overflow before narrowing. Float32 is IEEE binary32 bits in a U32 with
explicit rounding helpers.

Limits:

- `@embed` C patterns are translated from a recognized set (builtin arithmetic, numeric
  casts, memory and span operations, printing); other C syntax is an `Unsupported
  Feature` diagnostic.
- Foreign imports call their Cool symbol verbatim: scalar integers, booleans, Float64,
  Unit/U0, pointers and span inputs (spans decay to pointers; pass the length
  explicitly). The symbol must be declared by the runtime or an included header or
  adapter. `puts` and `putchar` are supplied. Arbitrary C libraries and stdio handles are
  not available, so the standard library passes semantic checking, but its terminal
  input (`Terminal.readLine`, `fgetc`, `stdin`) cannot run yet. Output works.
- Parser nesting is limited to 256, instance search to 64 levels and one output unit to
  100,000 specializations; exceeding a bound is a diagnostic.

## Tests

The test suites need `build/warmc`, `build/coolc` and `build/coolvm`; `make warm-test`
builds what it needs and runs all of them (a few seconds):

```sh
python3 warmc/compare.py          # every test-programs case against its stored expectation
python3 warmc/test_frontend.py    # malformed-input and caret regressions, AST shape
python3 warmc/test_semantics.py   # semantic probes (semantic-expected.json)
python3 warmc/test_numbers.py     # exact numeric representation checks
python3 warmc/test_cli.py         # entrypoint, export, CLI and diagnostic checks
python3 warmc/test_standard.py    # the standard library and its tests, semantic checking
python3 warmc/test_kernel.py      # compile and run inside the kernel shell (make build/kernel.Image first)
warmc/run-examples.sh             # compile and run the examples
```

`compare.py` compiles every case under `test-programs/suites` with the Warm compiler,
using `cli.txt` for the arguments where a case has one. A case with `austral-stderr.txt`
must fail with that error kind. Any other case must compile, build with coolc and run: its
stdout must equal `program-stdout.txt`, and it exits nonzero exactly when
`program-stderr.txt` exists, with that stderr. The expectations came from the OCaml
compiler's C backend before it was removed; the 35 cases that had no expectation file got
an (empty) `program-stdout.txt`. `--filter=substring` selects cases, `--parse-only`
measures the parser alone, `--jobs` sets the parallelism. Commands, output and a JSON
report for each case are under `build/warmcool-comparison`.

`make warm-kernel-test` (part of `make test`) compiles the kernel examples in
`examples/kernel` with the Warm compiler and runs them in the real kernel shell. Files
writes and reads `Warm.txt` (checked with mtools), Screen draws a rectangle whose pixels
are checked in the screenshot, Key waits for a scripted key press, and Errors injects a
throwing `FileWrite` at the adapter boundary. Four negative fixtures in
`test-programs/kernel` (leaked buffer, double close, missing capability, forged root
capability) must be rejected. `ForeignUnit` checks Unit, scalar and span foreign calls
natively.

## Kernel bindings and capabilities

`standard/src/Kernel/Kernel.warmh,Kernel.warm` provides `Warm.Kernel`. Its 45 operations,
plus resource and capability lifecycle functions, use the kernel's actual FAT32, console,
Key.cool, framebuffer, clock and scheduler APIs. The Cool boundary is
`standard/src/Kernel/Adapter.cool`.

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

* This is a kernel-shell target, not a portable C standard module. Include the adapter
  **before** generated source. It defines `WARM_KERNEL`; native CLI imports are replaced
  with kernel-compatible helpers. CLI argument count is zero. Warm abort/ExitFailure
  returns control through the kernel's NativeExit.
* The generated private aggregate ABI stays inside Warm. The adapter accepts integers,
  opaque pointers and explicit pointer/length pairs. No generated class names, span
  layouts or allocation headers cross the boundary.
* Text inputs accept spans in any region. Use `Standard.String.getSpan` for heap strings.
  The adapter copies text into a temporary NUL-terminated `U8*`, rejects embedded NUL and
  text longer than 4096 bytes, and frees the copy on both success and caught exceptions.
  Binary file contents and `copyBytes` preserve embedded zero bytes. Input pointers are
  never retained.
* `readFile` uses the kernel's whole-file API, not a fictitious open file descriptor. It
  returns an opaque **linear Buffer**, even on failure. Read `bufferError`, borrow it for
  byte access, and consume it exactly once with `close`. `allocate` returns the same owned
  resource. Neither raw pointers nor escaping borrowed spans are exposed. Copies and
  indexes check buffer bounds. Allocation and write sizes are capped at 256 MiB. Rectangle
  coordinates are limited to signed 16-bit and sizes to 0..32767 before calling the
  framebuffer clipping code.
* Error values are `-1` (caught Cool throw), `-2` (invalid input/bounds), `-3` (missing
  file/allocation or write failure), with zero for successful commands. Query functions
  return their documented nonnegative value or a negative error. Kernel boolean queries
  retain 0/1; `dir` and `delete` retain counts. `stringCompare` returns 0/1/2 for
  less/equal/greater, reserving negative values for errors. Date conversions retain signed
  kernel dates. Exception identity is deliberately collapsed to -1; the catch marks the
  exception handled and frees adapter-owned temporaries. The adapter cannot repair
  internal allocations leaked by a kernel function before it throws.
* `Filesystem`, `Terminal` and `Tasks` are opaque linear capability values. Acquire each
  only through a mutable borrow of RootCapability, borrow the capability for operations,
  and release it explicitly. Callers can pass a restricted capability to a helper without
  handing over root. These are Austral-style authority tokens, not path ACLs or exclusive
  device locks; root can derive multiple tokens. Open buffers outlive filesystem tokens
  because they own a detached memory snapshot.
* Opaque constructors are checked against module visibility, closing an upstream hole
  that allowed constructing empty capability records outside their defining module. Tests
  reject root/capability forgery, missing capability arguments, leaked buffers and double
  close.
* This is a language-level discipline for callers of the safe API. Unsafe modules,
  arbitrary Cool, and the existing Pervasive printing builtins are outside its authority
  boundary. Task creation/kill and raw kernel pointers are deliberately not exposed in
  this initial scheduler binding.

## Fixes since the fork

Warm validates required typeclass methods, duplicate methods, and instance method
signatures. It also corrects the built-in `Printable` instances, fixes Buffer growth after
`realloc`, and checks `Index` and `ByteSize` literals against the host `size_t` width.
