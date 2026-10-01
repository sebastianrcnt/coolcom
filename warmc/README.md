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

Building and testing Warm requires no OCaml, opam or installed Austral compiler.
`compare.py` checks the stored upstream expectations, including `austral-stderr.txt`,
with the Cool implementation; it does not invoke upstream Austral.

## Files

| Path | What |
|---|---|
| `Core.cool` `Lexer.cool` `Parser.cool` `Resolve.cool` `Types.cool` `Fold.cool` `Check.cool` `Linear.cool` `Emit.cool` `Diagnostic.cool` | the compiler (`Warm.cool` includes the passes) |
| `Format.cool` `FmtNative.cool` | the formatter (`WFmt`, `WarmFmt`) and its host command line (built into `build/warmfmt.BIN`) |
| `Runtime.cool` | the runtime that every generated program starts with |
| `ModuleRuntime.cool` | the smaller runtime of a kernel module (`--kernel-module`) |
| `Native.cool` | the host command line (built into `build/warmcool/Warm.BIN`) |
| `Kernel.cool` | `WarmRun` and `WarmCompile` for the kernel shell (`package_kernel.py` makes `C:/Warm/Warm.cool`) |
| `builtin/` | Pervasive and Memory, original Warm source that is embedded into the compiler (`embed_builtins.py`) |
| `standard/` `examples/` | the standard library and example programs; `standard/src/OS` contains portable OS APIs |
| `test-programs/` | the end-to-end test suites |
| `fmt-tests/` | the formatter's fixtures (`NAME.in.warm` formats to `NAME.exp.warm`) |
| `compare.py` `test_*.py` | the tests |
| [docs/paths.md](docs/paths.md) | current Warm paths, reference transforms and assignment rules |

For editor support, use the [Cool/Warm Zed extension](../tools/zed-coolcom/README.md).

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
- `--kernel-module=NAME`: Cool source to be compiled into the kernel (below); implies
  `--no-entrypoint`.

The only target is Cool source; there is no C or executable target.

## Use in the OS

`make disk-install` and `make disk-seed` (also `make run`) put the packaged compiler on
the disk as `C:/Warm/Warm.cool`, and `C:/Init.cool` loads it. In the kernel shell:

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

## Formatting

`tools/warmfmt [--check] files` formats `.warm`/`.warmh` files in place (`--check` only reports and exits 1 when a
file would change; 2 is an error). In the OS, `WarmFmt("C:/x.warm");` does the same to a file (`WarmFmt(path, TRUE)`
only reports); it comes with `C:/Warm/Warm.cool`. `make fmt` and `make fmt-check` cover the tracked Warm files too, next to
the HolyC ones (`tools/hcfmt.sh`), and the pre-commit hook (`make hooks`) refuses staged Warm files that are not
formatted. The suites in `test-programs/suites` are left as they are: their expected diagnostics carry line and column numbers.

The formatter is `Format.cool`. It lexes the text with `WLex` (`Lexer.cool`), so a change to the lexer changes what it
sees, and it never parses: block structure comes from the keywords (`is`, `then`, `else`, `do`, `of`, `end`), so it also
formats unfinished code. It only rewrites whitespace and keeps the line breaks:

- Indentation is 4 spaces per block (module, record, union, function, typeclass, instance, `if`/`else`, `case` and its
  `when`s, `while`, `for`, `borrow`; a union case's slots are one level in). A continuation line is one level past its
  statement, and inside brackets one level past the line that opened them, with the closing bracket lined up with that line.
- Spaces follow fixed rules: `name: Type`, `a + b`, `f(x, y)`, `Buffer[T]`, `&![T, R]`, `p->x`, `{ a: T }`, `-x`,
  `import M (A, B);`. Trailing whitespace goes, runs of blank lines become one, the file ends with one newline.
- Comments are kept, and a trailing comment keeps its column. A comment on its own line takes the indentation of the code
  after it; before `end`, `else` or `when` it stays inside the block when it was indented past that word.
  Docstrings move with their declaration. Strings and other triple-quoted values are untouched.

The output is verified before it is written: it must lex to the same tokens (docstrings up to their indentation) and
contain the same comments as the input; otherwise the file is left alone and the run reports an error. So does a file that
does not lex. `python3 warmc/test_fmt.py` (part of `make warm-test`) checks the fixtures, odd inputs, and on all Warm files
in the repository that formatting is idempotent and leaves the parse tree (`--dump-ast`) unchanged.

## The Cool backend

The generated program is standalone Cool: records, union payloads and spans are packed
classes, so `sizeof` and pointer strides follow that layout. The internal ABI passes
aggregate arguments by pointer, copies them into callee locals and returns aggregates
through an output pointer; it is private to the module, not C ABI compatible. Allocation
calls `CAlloc`, `Free` and `MemCpy`; realloc uses a private size header. Output calls
`Print`. C printf formats in `@embed` are rewritten into ones both Prints read (C's printf
natively, Cool's in the kernel): every integer conversion becomes `%ld`, `%lu` or `%lx`, whatever
its length modifier (`%zu`, `%lld`), and `%i` becomes `%d`. Abort writes to stderr through `NativeErrPutS` and calls `NativeExit`;
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
  adapter. `puts`, `putchar`, `fputc`, `fgetc` and the `stdin`/`stdout`/`stderr` handles are
  supplied; arbitrary C libraries and other stdio handles are not available.
- Standard input (`Terminal.readLine`, `fgetc`) reads the host's real stdin under
  `build/coolc --run` (`NativeGetChar`, -1 at the end of input). In the kernel shell
  (`WarmRun`) it reads the shell terminal a line at a time with `GetLine`, and never ends.
- Parser nesting is limited to 256, instance search to 64 levels and one output unit to
  100,000 specializations; exceeding a bound is a diagnostic.

## Kernel modules

`--kernel-module=NAME` makes a Warm module a part of the kernel itself, compiled ahead of time with
it: the first is the network stack's packet parser, `os/Kernel/NetParse.warm`
([docs/networking.md](../docs/networking.md#the-packet-parser-in-warm)). The Makefile runs

```sh
build/warmc compile os/Kernel/NetParse.warm \
  --kernel-module=NetParse --target-type=hc --output=os/Kernel/NetParse.cool
```

and `os/Kernel/Kernel.cool` includes the result. The output lives in the kernel's global namespace, so:

- Every generated name starts with `NAME_` (`NetParse_wf12`, `NetParse_WT8`), as do the names of
  the runtime (`NetParse_au_span_t`, `NetParse_wh_abort`). Only `Foreign_Export` functions keep the
  name they declare, and `Export_Layout` records the class name they declare; together they are the
  module's interface (see "Crossing to Cool" below).
- The runtime is `ModuleRuntime.cool`, not `Runtime.cool`: spans, abort, and allocation through
  `CAlloc`/`Free`. It has no `#define`s, no output, input, arguments or Float32 helpers; a module that
  uses those does not compile into the kernel.
- An abort (a failed index, overflow or division check, or `abort`) does not exit: it keeps the
  message in `NAME_wh_abort_message` and throws `'WarmAbrt'`. The Cool caller catches it (Net.cool's
  `NetParsePkt` drops the packet and counts it), so a bug in the module costs a dropped packet, not a
  fault or corrupted kernel memory.
- The generated file is not committed: `make` makes it, and `tools/disk-files.sh` copies it to
  `C:/Kernel` with the other kernel sources so `MakeKernel` in the OS compiles the same text.

What the packet parser needed that Warm did not have, and what was added:

- **Widening conversions that cannot fail.** Every `toNat64`, `toIndex` and so on returns an
  `Option`, even from `Nat8`. Pervasive now has the typeclasses `WidenToNat64` (from Nat8, Nat16,
  Nat32, Nat64, Index, ByteSize) and `WidenToIndex` (from Nat8, Nat16, Nat32, Nat64, Index) with
  `widenToNat64` and `widenToIndex`, which return the value itself (Index is 64 bits here).
- **Faster generated code.** Unoptimized, the parser was about 30 times slower than the Cool it
  replaced (12.6 us instead of 0.35 us for a 1514-byte TCP segment), because every operator and every
  span index was a call. The emitter now open-codes span indexing (the bounds check of
  `au_array_index`, inline), the unsigned trapping `+`, `-` and `*` (the same checks and abort
  messages as their Pervasive bodies), the bitwise and/or/xor and the widening conversions, and copies
  aggregates with a class assignment instead of `MemCpy`. That brought it to about 7 times slower
  (2.2 us) for a full segment and 9 times (280 ns) for a small one; see
  [docs/networking.md](../docs/networking.md#the-packet-parser-in-warm). These apply to every
  program, and all the test suites still pass.
- Shift operators, precedence, and passing spans and records across `Foreign_Export`: added in
  stage 0 of [docs/warm-stdlib.md](../docs/warm-stdlib.md) (next section). The parser is now one
  safe file; its unsafe export module and the hand-kept Cool class are gone.

## Warm's additions to Austral

Stage 0 of [docs/warm-stdlib.md](../docs/warm-stdlib.md). All of them are additive: every Austral
program that parsed before still parses and means the same (all test programs pass unchanged).

**Operators and precedence.** Austral allowed one binary operator per expression, `(a * 256) + b`.
Warm has precedence and adds the bitwise operators. From loosest to tightest:

| Level | Operators | Notes |
|---|---|---|
| 1 | `and` `or` | a chain of one of them; mixing them needs parentheses (`a and (b or c)`) |
| 2 | `=` `/=` `<` `<=` `>` `>=` | no chains: `a < b < c` is an error |
| 3 | `\|` | bitwise or |
| 4 | `^` | bitwise xor |
| 5 | `&` | bitwise and |
| 6 | `<<` `>>` | shifts |
| 7 | `+` `-` | |
| 8 | `*` `/` | |
| prefix | `-` `not` `~` | `~` is bitwise not; prefix operators bind tighter than all binary ones |

Levels 3-8 associate to the left. Unlike C, `&`, `^` and `|` bind tighter than comparisons, so
`flags & 2 /= 0` means `(flags & 2) /= 0`. The bitwise operators and the shifts take two integers
of the same type (Pervasive's `BitwiseOperations` and new `BitwiseShift` typeclasses:
`bitwiseAnd`, `bitwiseOr`, `bitwiseXor`, `bitwiseNot`, `bitwiseShiftLeft`, `bitwiseShiftRight`).
A shift amount outside `0 .. width - 1` aborts; bits shifted out are lost (no overflow check);
`>>` of a signed type copies the sign bit. Lexing: `<<`, `>>`, `|`, `^` and `~` are new tokens;
after an operand `&(` and `&~` are read as `&` followed by `(` or `~`, and `x -1` as `x - 1`.

**Region elision.** In a function's parameter types, `Span[T]`, `Span![T]`, `&[T]` and `&![T]`
may leave out the region. Each gets a fresh region type parameter of the function, as if
declared in `generic [...]` (they are named `_R1`, `_R2`, ... in messages). A region shared
between parameters, or one in the result or a `let` type, is still written out:

```
function get16(f: Span[Nat8], at: Index): Nat64 is          -- was generic [R: Region] ... Span[Nat8, R]
    return widenToNat64(f[at]) << 8 | widenToNat64(f[at + 1]);
end;
```

Only `function` declarations elide, not typeclass or instance methods.

**`private` and optional interfaces.** A module can be one `.warm` file; everything in it is
importable except declarations marked `private` (`private function f ...`, `private record`,
`private constant`, also after `generic [...]`). `private` is a keyword now. In a module that has a
`.warmh`, the interface decides what is public, and `private` on a declaration the interface
declares is an error; `private` in a `.warmh` is a parse error.

**`Result`.** Pervasive has `union Result[T: Type, E: Type]: Type` with cases `Ok(value: T)` and
`Err(error: E)`, for fallible operations (the error model of docs/warm-stdlib.md).

**Crossing to Cool.**

- A `Foreign_Export` function may take spans: each `Span[T]` or `Span![T]` parameter is two C
  parameters, a `T *` and an `I64` count (a negative count aborts). warmc emits a small wrapper
  with the export's name around the function. An export may have region parameters (elided or
  not); other type parameters are still an error.
- `pragma Export_Layout(Name => "CFoo");` before a non-generic record makes it the Cool class
  `CFoo`, with the record's field names and types (Nat64 is `U64`, Int32 `I32`, Bool `U8`,
  pointers stay pointers), emitted into the generated file. Fields must be integers, booleans,
  `Float64` or pointers. Cool code includes the generated file and uses the class directly.
- An export's record result comes back through an out pointer, the first parameter:
  `pragma Foreign_Export(External_Name => "NetParseFrame") function parseFrame(frame: Span[Nat8]): Packet`
  is `U0 NetParseFrame(CNetPkt *out, U8 *frame, I64 len)` in Cool.

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
python3 warmc/test_fmt.py         # the formatter (tools/warmfmt): fixtures, idempotence, same parse trees
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
writes and reads `Warm.txt` (checked with mtools), Fmt runs `WarmFmt` on a messy file on the disk (the result is compared with the fixture), Screen draws a rectangle whose pixels
are checked in the screenshot, Key waits for a scripted key press, and Errors injects a
throwing `FileWrite` at the adapter boundary. System checks monitor snapshots,
heap/drive statistics, termination by number, clocks and timed terminal input,
both ahead of time and with WarmRun. Seven negative fixtures in
`test-programs/kernel` (leaked buffer, double close, missing capability, forged root
capability, forged System capability, missing System capability, leaked snapshot)
must be rejected. `ForeignUnit` checks Unit, scalar and span foreign calls
natively.

## OS bindings and capabilities

`standard/src/OS` provides the common host and CoolOS API. `OS.Terminal` splits
`Output` and `Input`, with typed `Key` and `Color`. `OS.File` owns whole-file
`Bytes` and returns `Result` with `OS.Error.IoError`; a failed read returns no
resource to close. Inputs borrow spans. `OS.CoolOS.Framebuffer`, `OS.CoolOS.Key`
and `OS.CoolOS.Task` hold the platform-specific operations.

`OS.CoolOS.System` acquires a linear `System` capability from RootCapability.
`snapshotTasks` copies up to 4096 task rows; use `snapshotCount`, `snapshotTask`
and `snapshotName`, then `releaseSnapshot`. Names are owned Strings (destroy them
with `destroyString`). Row states are running/ready/sleeping/stopped/killing (0..4);
rows include task number, core, counter ticks, idle flag, stack bytes and switches.
`heapStats`, `driveFree`, `killTask` and `clock` supply monitor data and termination
by task number. Missing tasks return NotFound; idle and calling tasks return Denied.
Drive free bytes are -1 when FAT32 FSInfo has no count. Convert task counter ticks
with `Clock.ticksPerSecond`, and uptime jiffies with `Clock.jiffiesPerSecond`.

`OS.Terminal.terminalSize` borrows Output and returns rows/columns (24x80 without
a screen on CoolOS). `readKeyTimeout` borrows Input, accepts 0..2147483647
milliseconds (zero polls once), and returns IoError.Timeout on expiration.
These additions return an unsupported Other error on the host backend.
`examples/kernel/System.warm` exercises these APIs, including a worker on core 1
and copied data after its termination; run `tools/warm-kernel-test.py --filter System`.

The scalar ABI is implemented in `OSHost.cool` and `OSKernel.cool`, packaged
with the corresponding runtime. The temporary `OS.Raw` binding has been removed;
new applications should use the typed modules. The former `Warm.Kernel` is
removed. `Standard.IO` remains a compatibility facade over the same terminal
boundary for upstream library tests.

To list the dependencies for a program, see `warmc/os_modules.py`. The same
sources run with `tools/warm run` on macOS and `WarmRun` in the kernel shell.
Whole-file reads own a detached snapshot; release it exactly once using
`OS.File.closeBytes`. Indexing outside its bounds is a programmer error.

## Fixes since the fork

Warm validates required typeclass methods, duplicate methods, and instance method
signatures. It also corrects the built-in `Printable` instances, fixes Buffer growth after
`realloc`, and checks `Index` and `ByteSize` literals against the host `size_t` width.

`OS.Task` provides `spawn`/`spawnOn`, `join`, `detach`, `sleep` and `yield`.
A worker is a named `Fn[T,R]`; arguments and results must satisfy intrinsic
`Sendable`. RootCapability, non-static borrows and raw pointers cannot cross
the task boundary. `detach` requires a Free result. `join` reports child abort
and external kill as `Aborted` and `Killed`. `OS.Time` provides UTC time and
monotonic milliseconds; `OS.Random.seeded` creates a deterministic xorshift64 RNG.

`OS.Dir.narrow(dir, Rights(...))` consumes a directory and intersects its
read/write/create/delete rights; `readOnly()` and `allRights()` construct common
sets. Child handles retain the same restrictions. Paths are relative and cannot
contain dot components, drive prefixes or symlinks on the host.
`OS.Net.narrowNet(network, allowed: Span[Endpoint])` consumes Network and
intersects its IPv4 address/port allow list. Restricted policies allow outbound
TCP and ephemeral UDP; listeners and fixed local UDP ports require unrestricted
authority. UDP sockets retain and enforce the policy independently.
`OS.CoolOS.Framebuffer` takes Output; `OS.CoolOS.Key` takes Input and returns
`Result[Bool,IoError]` or `Result[Option[Key],IoError]`.
