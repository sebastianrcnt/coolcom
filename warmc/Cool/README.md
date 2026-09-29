# Independent Warm compiler in Cool

This directory contains a new HolyC implementation, not a wrapper around the
OCaml compiler. **It is under construction, not yet a complete compiler.**
See [DESIGN.md](DESIGN.md) for lifetime, pass, and kernel/host boundaries.

Build and inspect syntax from the repository root:

```sh
./warmc/Cool/build.sh
build/coolc --run build/warmcool/Warm.BIN --dump-ast path/to/Module.aum
python3 warmc/Cool/test_frontend.py
python3 warmc/Cool/compare.py --parse-only
python3 warmc/Cool/compare.py
```

The core `Warm.HC` has no process or filesystem imports. Call `WNew`, `WParse`
for each interface/body, inspect `error_kind`/AST, then `WDestroy`. Native.HC
provides the host executable adapter. Kernel execution is not yet validated.

## Measured progress (2026-09-30)

- Native build through the checked-in seed: `Errs:0`.
- Lexer/parser: **350/350** source files from test-programs, builtins and
  standard library parse. This includes module interfaces, generic parameters,
  typeclasses/instances, records/unions, cases, named calls, borrowing, paths,
  docstrings and pragmas.
- Frontend regressions: **9/9** invalid inputs rejected with a caret diagnostic;
  nested binary AST shape checked separately.
- Semantic compilation and execution: baseline intentionally reports
  `Unsupported Feature`; syntax passes are not compiler passes.

All subprocess logs, commands, exit codes and results.json live in
`build/warmcool*`. `compare.py` runs every suite test, including expected errors
and successful silent programs, and exits nonzero on any failure. Runtime
results are compared to OCaml's C backend and the recorded fixture; expected
errors require agreement between the recorded kind, OCaml, and Cool. Crashes,
missing output, timeout, and unsupported features are failures.

Second checkpoint: module/declaration indexing, interface/body pairs, public
imports and aliases, implicit Pervasive scope, lexical bindings, nominal type
identity, substitutions and integer range helpers. The first name-resolution
comparison reached **9/296** (all nine expected-error cases; no runtime passes).
Type/linearity/code generation are not claimed by that count.

Third checkpoint: expression/statement typing, type parameter substitution and
universe checks, typeclass contracts/coherence/visibility, aggregate and case
checking, integer bounds, and ownership/loan flow analysis. Full comparison
reached **209/296** before the last Nat64 boundary fix: 209 expected-error
matches, 86 successful fixtures blocked only at the unimplemented output stage,
and one integer-range mismatch. Subsequent focused integer tests confirm all
8 expected range errors, including Nat64 overflow. This is test coverage, not
proof of complete language conformance: signature constraints, region escape
and arbitrary control-flow combinations need further adversarial validation.
