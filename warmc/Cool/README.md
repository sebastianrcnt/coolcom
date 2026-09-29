# Independent Warm compiler in Cool

A HolyC implementation of Warm's lexer, parser, module resolution, typechecker,
linearity/borrow checker, monomorphization, diagnostics and HolyC backend. It runs
under native `coolc` and inside the OS kernel shell. The compiler does not invoke
OCaml, a C compiler, Python, or test fixtures. Python scripts package source data
and run validation. See [DESIGN.md](DESIGN.md) for the implementation boundaries.

## Host use

From the repository root:

```sh
./warmc/Cool/build.sh
export COOLC_COMPILER_BIN="$PWD/coolc/seed/Compiler.BIN"
build/coolc --run build/warmcool/Warm.BIN compile \
  warmc/test-programs/suites/018-hc-backend/002-record-flow-float/Test.aum \
  --entrypoint=Test:main --target-type=hc --output=build/warmcool/Test.HC
build/coolc build/warmcool/Test.HC build/warmcool/Test.BIN
build/coolc --run build/warmcool/Test.BIN
```

Supply module pairs as `path/Module.aui,path/Module.aum`; all dependencies must
be provided. Pervasive and Memory sources are embedded automatically. Options:

- `--parse`: lexer/parser only; `--dump-ast`: print the parsed tree.
- `--check`: all semantic checks, without generating code.
- `--entrypoint=Module:function`: defaults to `Test:main`.
- `--no-entrypoint`: emit concrete functions/exports without invoking main.
- `--output=path` and `--target-type=hc`: write HolyC source.
- `--error-format=plain|json`: source/caret diagnostics or structured JSON.

The host adapter supports HC output, not the OCaml CLI's C/executable targets.

## Kernel shell use

```sh
./warmc/Cool/build.sh
python3 warmc/Cool/package_kernel.py
```

Copy `build/warmcool/Kernel.HC` to `C:/Warm.HC` and Warm sources to the OS disk.
On the kernel compiler/shell task:

```c
#include "C:/Warm.HC"
WarmRun("C:/Test.aum");
WarmRun("C:/Api.aui,C:/Api.aum,C:/Main.aum", "Main:main");
WarmCompile("C:/Test.aum", "Test:main", "C:/Test.HC");
```

`WarmRun` compiles and immediately JIT-executes through `ShellExe`, returning
true on completion and false on compilation/runtime failure. Subsequent runs
use distinct generated names. `WarmCompile` with an output path writes HC
instead of executing. Kernel errors include filename, line and caret. Shell
execution uses the current shell task's compiler state, not arbitrary tasks.
Program arguments in this adapter are currently just the source path as argv[0].

This is **HolyC text → existing coolc JIT**, not direct coolc IR emission.
The optional direct `__HC_*` sink is not implemented. JIT code stays in the
shell symbol table; the compilation arena is released after every operation.

## Reproducible validation

Build the OCaml reference (`./warmc/build.sh`) for differential tests. Native
execution comparison also needs the host `cc`. Kernel validation needs the
repository's VM/kernel build and `mtools` (`mformat`, `mcopy`).

```sh
python3 warmc/Cool/compare.py
python3 warmc/Cool/test_frontend.py
python3 warmc/Cool/test_semantics.py
python3 warmc/Cool/test_numbers.py
python3 warmc/Cool/test_cli.py
python3 warmc/Cool/test_standard.py
make build/coolvm build/kernel.Image
python3 warmc/Cool/test_kernel.py
```

Measured on 2026-09-30, native arm64 macOS and the actual coolvm kernel shell:

| Check | Result |
| --- | ---: |
| Entire unchanged `test-programs` suite | **296/296** |
| Runtime tests, including silent programs | **86/86** |
| Expected errors, matching recorded and OCaml error kind | **210/210** |
| Source files parsed (suite, builtins, standard library) | **350/350** |
| Malformed-input/caret frontend regressions | **9/9**, plus AST shape |
| Additional semantic probes | **24/24** |
| Exact numeric representation checks | **1577/1577** |
| Entrypoint/export/CLI/diagnostic checks | **5/5** |
| Standard library and its tests: semantic checking | **42/42 files** |
| Kernel shell: abort, execution, parse failure, repeated execution | **PASS** |
| Root `make test`: kernel, relocation, Vim, shell | **PASS** |

`compare.py` discovers every suite test, honours `cli.txt`, validates the oracle
against recorded fixtures, then compares Cool's stdout, stderr and exit status
exactly. Errors require the recorded kind, OCaml kind and Cool kind to agree.
Unsupported output, crashes and timeouts are failures. `--parse-only` measures
syntax separately; `--filter=substring` selects cases. A filtered invocation
replaces the comparison report, so run the unfiltered command for a full report.
Commands, output, exit codes and JSON reports live under `build/warmcool*`.

The 24 extra probes include interface-only imports, opaque privacy, region
escape, payload completeness, borrowing, checked arithmetic, unbounded integer
constant folding, exact floating conversions and case errors. One duplicate
named-argument probe crashes the OCaml oracle; that probe separately requires a
clean Cool diagnostic instead of counting an error-kind match. The numeric
checks cover binary32 round-to-nearest-even and decimal-to-binary64 conversion.
The kernel test checks two exact outputs from the aggregate/function-pointer/
float/control-flow fixture, including recovery after an initial Warm abort.

Progress checkpoints: lexer/parser **350 files** → resolution **9/296** →
semantic/ownership **209/296** → monomorphized HC execution **296/296** →
additional semantic/numeric checks and real kernel JIT execution. These counts
measure coverage, not a proof of conformance for all possible Warm programs.

## Backend limits

Like the existing OCaml HC target, C embeds are translated through recognized
patterns, not passed to a C compiler. Foreign imports currently support `puts`
and `putchar`; arbitrary C ABI calls and C `stdio` handles are rejected. Thus the
whole standard library passes semantic checking, but its terminal implementation
cannot yet execute through this HC backend (`fputc`, `fgetc`, stream globals).
Float32 is supported as IEEE binary32 bits in U32 with explicit rounding helpers,
extending the OCaml HC target's Float32 limitation. Operators still require the
same Pervasive typeclass instances as the reference language.

Parser nesting is limited to 256, instance search to 64 levels, and an output
unit to 100,000 specializations; exceeding a bound produces a diagnostic.
EOF/invalid syntax and normal compiler errors recover; arena allocation failure
is handled by the underlying host/kernel allocator.
