# Warm in Cool

This is an independent implementation of the language in `../lib/Parser.mly`,
`Lexer.mll`, `Cst.ml`, and the subsequent OCaml passes. Reference code is from
Austral (Apache-2.0 WITH LLVM-exception; see ../LICENSE). No OCaml process,
C compiler, generated answer table, or test fixture is used by the compiler.

## Lifetime and representation

One `CWUnit` owns a compilation arena. Chained zero-filled blocks use bump
allocation aligned to eight bytes. Source text, tokens, AST nodes, symbols,
types, and emitted text belong to the unit. `WDestroy` frees all blocks after
the caller consumes the output/diagnostic. No tracing collector or reference
counting is required. Independent units have no shared mutable compiler state.
Allocation failure is a fatal host/runtime condition (as in coolc).

Tokens retain byte offsets and source ownership; line/column are calculated
from source on diagnostic rendering. AST nodes are tagged, ordered trees with
first-child/next-sibling links, named roles, and original token spans. Declaration
children distinguish type parameters, parameters, result types, pragmas, docs,
and executable blocks. This deliberately preserves interface declarations and
implementation definitions separately. Semantic passes must not identify nodes
by position in a list or mutate syntax into strings.

## Pass boundaries

1. Lex each source, parse module interfaces and bodies using the Warm grammar.
   Expressions preserve Warm's explicitly parenthesized binary expressions;
   HolyC precedence is never used to parse Warm.
2. Index modules/declarations, combine interfaces with bodies, resolve explicit
   imports (including aliases), then lexical scopes. Declaration identities
   are pointers, not unqualified string names.
3. Resolve types/universes, instantiate type parameters, check typeclass method
   contracts and instances, then expressions/statements and exhaustive cases.
4. Track linear resources and read/write loans per control-flow branch; merge
   branch states and check loop invariance and scope exits.
5. Discover reachable concrete instantiations, lower to explicitly typed code,
   and render HolyC using the OCaml HC backend's packed aggregate/pointer ABI,
   integer narrowing, and ordered evaluation rules.
6. Render structured diagnostics with file, line, column, source and caret.
7. A future IR sink may replace text rendering using coolc's `__HC_*` bindings.

These are design targets, not a declaration that every pass is implemented.
The README records measured implementation status and limitations.

## Host and kernel

`Warm.HC` is the reusable core: no Native imports, process exit, file access,
or CLI parsing. Kernel callers supply source strings and inspect the returned
unit. `Native.HC` supplies file/argument/output adapters for `coolc --run`.
Keeping process services out of the core permits shell inclusion without
binding NativeExit/NativeArg in the kernel. Kernel execution still needs an
integration test; host compilation alone is not evidence of kernel execution.

## Validation

`compare.py` discovers every test directory, honours `cli.txt`, and compares
independent Cool and OCaml results. Expected errors compare error kinds, not
merely nonzero exits. Runtime cases compare exit status and both output streams.
Unimplemented features, crashes, and timeouts are failures, never passes.
Syntax-only coverage is reported separately and never counted as compilation.
All build and test artifacts stay under this checkout's `build/`.
