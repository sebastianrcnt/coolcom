# Frontend reproducers

These files document frontend bugs inherited from Aiwnios.
`tools/native/behavior.sh` checks the corrected native behavior.

| Bug | Reproducer | Expected | Observed with the port |
| --- | --- | --- | --- |
| 5 | `B05ClassCopy.HC` | `3 4 / 7 8` | `3 2 / 7 6` |
| 6 | `B06LargeFloat.HC` | `43F0000000000000` | `0` |
| 7 | `B07StringDefault.HC` | AOT relocation for `"abc"` | A process heap pointer is embedded in the code; two builds differ in the pointer immediate |
| 8 | `B08FunctionPointerArray.HC` | Compiles | `PrsType`: `Missing ')'` after `a` |
| 9 | `B09StringIndex.HC` | `65` | `16961` (`0x4241`) |

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
- **9:** `AIWNIOS_PrsExp.HC:AssignRawTypeToNode` gives `IC_STR_CONST` the
  class of `RT_PTR`, whose element is eight bytes, so `"AB"[0]` loads a word
  (`0x4241`) instead of the byte `'A'`. A string constant is a `U8 *`.

Run `tools/native/behavior.sh` to compile and check the corrected cases.
