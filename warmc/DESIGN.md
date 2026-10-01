# Warm in Cool

This is the only implementation of the Warm compiler. It was written after the
OCaml compiler of Austral (the fork's original `warmc`, since removed from the tree; its
sources are upstream Austral at the commit named in `UPSTREAM_README.md`), following
its parser, semantic passes and HC renderer. The current path and assignment rules
are documented in [docs/paths.md](docs/paths.md). Reference Austral code is
Apache-2.0 WITH LLVM-exception; see `LICENSE`. No generated answer table or test
fixture is used by the compiler. The builtins remain original Warm source compiled by the same
pipeline as user modules.

## Lifetime and representation

One `CWUnit` owns a compilation arena. Chained zero-filled blocks (64 KiB minimum)
use bump allocation aligned to eight bytes. Sources, tokens, AST nodes, symbols,
types, substitutions and emitted text belong to that unit. `WDestroy` frees all
blocks after the caller consumes the output or diagnostic. No garbage collector
or reference counting is needed. Independent core units have no shared mutable
state. Allocation failure is a fatal host/runtime condition, as in coolc.

Tokens retain source ownership and byte offsets. Diagnostics derive line/column
and the source excerpt from those offsets. Tagged AST nodes use first-child/
next-sibling links and named child roles. Interfaces and bodies remain separate,
paired by declaration identity. Resolved declarations are pointers, not bare
names. Linked scope tables favor simple ownership over hash-table optimization.
Cloned/substituted types have independent sibling links.

The source files follow `coolc/Compiler/PORTING.md`: packed layout, function-wide
local names, no ternary/continue, parenthesized expressions, and assignment for
numeric conversion. Postfix casts are used intentionally for bit reinterpretation.

## Implemented passes

1. `Lexer.cool`, `Parser.cool`: all grammar forms, interfaces/bodies, docstrings,
   literals, pragmas, generic/typeclass declarations, aggregates, paths, cases,
   borrowing and expressions. Warm's explicit binary grouping is preserved.
2. `Resolve.cool`: module/declaration indexing, interface/body pairing, imports
   and aliases, implicit Pervasive, lexical scopes and nominal identities.
   Public function/constant/instance signatures use interface imports; bodies
   use implementation imports. Opaque representations stay private.
3. `Types.cool`, `Fold.cool`, `Check.cool`: universes, substitution and inference,
   generic constraints, visible/coherent instances and contracts, interface
   signatures, complete aggregate/case payloads, return paths and expressions.
   Integer constant expressions use signed decimal bignums before range checks;
   intermediate overflow cannot silently change a constant. Decimal float
   literals are rounded exactly to binary64, bypassing the HolyC lexer.
4. `Linear.cool`: per-declaration live/consumed/read-loan/write-loan states,
   temporary loans, branch snapshots/merges, loop invariants, scope exits,
   consumption assignment and reborrowing. Fresh nominal region identities
   prevent anonymous borrow escape. Borrow statement mode follows its operator,
   as in the reference parser (the displayed type annotation is not authoritative).
5. `Emit.cool`: discover reachable concrete instantiations, specialize typeclass
   methods, lower checked operators to Pervasive implementations, emit packed
   records and overlapping union payloads. Aggregates use pointer arguments and
   out-pointer returns, including function-pointer calls. Temporary assignments
   preserve evaluation order, copies and short-circuit behavior. Integer widths
   are normalized explicitly. `Foreign_Export` roots are retained; no-entrypoint
   mode emits concrete library functions without a main invocation.
6. `Diagnostic.cool`: a first-error record, plain filename/line/column/excerpt/caret
   rendering, and escaped structured JSON. Native option parsing precedes input
   parsing so trailing diagnostic-format flags also apply to parser errors.

The runtime follows the former OCaml HC target's allocation headers, copies, span
bounds, argument and abort conventions. `Runtime.cool` additionally represents
Float32 as four-byte U32 IEEE bits, converting and rounding at expression
boundaries. Float64-to-Nat64 conversion splits around 2^63 because the native
Cool scalar conversion instruction is signed. Numeric tests compare exact bits,
not decimal printouts alone.

C embeds are a deliberately recognized translation vocabulary, matching the
HC backend approach; unknown C syntax fails explicitly. The current foreign
binding set is `puts`/`putchar`. Parser depth (256), instance recursion (64) and
monomorphization count (100,000) are bounded with diagnostics.

## Host and kernel boundaries

`Warm.cool` includes the reusable core. It has no process exit, CLI or filesystem
operations. A caller uses `WNew`, `WParse` for its sources, `WBuiltins`, `WResolve`,
`WTypeCheck`, `WLinearity`, `WEmit`, inspects `error_kind`, then calls `WDestroy`.
Allocation/string primitives are supplied by the host or kernel.

`Native.cool` adapts native file, argument and output APIs. `embed_builtins.py`
packages the original builtin interfaces/bodies and the HC runtime as source
strings; it does not translate the compiler logic. `build.sh` invokes native
coolc and checks both the binary and `Errs:0`, since compiler status alone is
not sufficient to detect an HC error.

`os/Warm/package_kernel.py` flattens includes and appends `os/Warm/Kernel.cool` to make one file
loadable by the TempleOS frontend. The kernel adapter loads FAT sources and
calls the same passes. For `WarmRun`, generated HolyC is sent to `ShellExe` on
the compiler/shell task. Runtime services replace native imports; Print format
strings are mapped to TempleOS conventions. Each unit reserves a distinct
symbol range so subsequent compilations coexist.

Runtime initialization and generated execution have separate completion markers.
An abort in the first user program does not cause runtime redefinition on the
next compilation. Shell exceptions are caught and reported as failure; the
arena is released. JIT functions remain in the kernel symbol table, following
normal ShellExe lifetime, rather than being freed with the arena. This adapter
is serialized on the shell task and is not a concurrent compile service.

Direct `__HC_*` IR emission is optional and not implemented. The current route
already compiles and executes Warm inside the OS without host assistance, via
the established HolyC frontend and JIT.

## Validation

`compare.py` covers every directory in `test-programs/suites`, including silent
success cases and expected errors. It honours `cli.txt`; runtime stdout, stderr and
exit status must equal the stored fixtures (`program-stdout.txt`, `program-stderr.txt`;
recorded from the OCaml compiler's C backend, which no longer exists) and error kinds
must equal `austral-stderr.txt`. Crashes, timeouts and unsupported output never count as
passes. Parser coverage is reported separately. Extra probes (`test_semantics.py`, with
`semantic-expected.json`) test semantic boundaries, opaque privacy and reference
quirks; standard-library checking covers imports used only by interface signatures.

`test_kernel.py` boots the real kernel in coolvm, includes the whole Cool
compiler, handles a Warm abort and parse error, and verifies two identical
program outputs from independent compilations in one shell. This is executable
kernel evidence, not an inference from a native host build. README records
counts and remaining output restrictions. All generated build/test artifacts
stay inside this checkout's `build/` directory.
