# Frontend reproducers

These files document bugs in `coolc/third_party/aiwnios/Src`. They are kept
separate from `behave.sh` because that runner checks successful behavior.

| Bug | Reproducer | Expected | Observed with the port |
| --- | --- | --- | --- |
| 5 | `B05ClassCopy.HC` | `3 4 / 7 8` | `3 2 / 7 6` |
| 6 | `B06LargeFloat.HC` | `43F0000000000000` | `0` |
| 7 | `B07StringDefault.HC` | AOT relocation for `"abc"` | A process heap pointer is embedded in the code; two builds differ in the pointer immediate |
| 8 | `B08FunctionPointerArray.HC` | Compiles | `PrsType`: `Missing ')'` after `a` |

The same results for bugs 5 and 6 occur with `b_use_port=FALSE` and `TRUE`.

- **5:** `AIWNIOS_PrsExp.HC:PrsExpression` lowers class assignment to the
  scalar `IC_ASSIGN` operation. `AssignRawTypeToNode` preserves the class type
  but emits no aggregate copy size, so the backend's scalar move copies one
  eight byte word.
- **6:** `Lex.HC:Lex` accumulates decimal digits into an `I64` before converting
  the significand to `F64`; `18446744073709551616.0` overflows that integer.
- **7:** `PrsVar.HC:PrsVarLst` evaluates a default argument and saves its
  string pointer in `dft_val`. `AIWNIOS_PrsExp.HC:PrsExpression` and
  `ImplicitFunCall` later emit that pointer as `IC_IMM_I64` for AOT code.
- **8:** `PrsVar.HC:PrsType` requires `)` immediately after the identifier in
  `(*name)`. It parses array dimensions only after the closing `)`.

For bugs 5 and 6, include the reproducer in an Aiwnios `Run.HC` after
`extern I64 b_use_port; b_use_port=TRUE;`, then run Aiwnios with `gtimeout`.
For bug 7, compile the same file twice to AOT BIN files with the port and
compare with `tools/porttest/bincmp.py`. For bug 8, compile with the port;
the parser exits before code generation.
