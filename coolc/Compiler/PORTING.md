# Porting the Aiwnios AArch64 backend from C to Cool

The x86-64 sibling is in `X64Backend.cool` and `X64Backend.coolh`. Regenerate it
with `python3 tools/port-x86.py` from `vendor/aiwnios/c/x86_64_backend.c` (the
same pinned upstream revision). The generator uses the existing clang AST
translator, with a packed C shim derived from `BackendA.coolh`, so both backends
consume the same IR objects. Generated functions keep the upstream name with
an `X64` prefix to coexist with their ARM siblings. Macro expansions, narrowing,
numeric conversions, function-pointer thunks and whole-record copies are
explicit in the output. The computed dispatch becomes a switch to the same
labels, and its one variable-length local array becomes a freed heap buffer.

`BTargetX86` selects AOT output; `BEmitX86` selects the frontend's register and
frame conventions during code generation. `LexExpression2Bin` temporarily
uses the ARM backend because its results execute in the ARM compiler process.
The shared optimization passes still run before backend dispatch.

The owned HolyC frontend (`coolc/Frontend/*.cool`) builds IR
through `__HC_*` functions implemented in C, and the C code optimizes the IR
and emits AArch64 machine code. To make the whole compiler Cool (and so
editable inside the OS) we translate that C code to Cool here.

Upstream provenance is Aiwnios commit `e155e87`. The code is
BSD-3; keep a credit line at the top of every translated file:
`// Translated from Aiwnios <file> (nrootconauto, BSD-3), commit e155e87.`

## Files

| Cool file | Translated from |
|---|---|
| `BackendA.coolh` | `c/aiwn_lexparser.h`, `c/aiwn_arm.h` (types, enums, macros needed by the files below) |
| `IRBind.cool` | `c/parser.c`: the `__HC_*` binding functions (~lines 4581-5109) and the helpers the backend calls (`AssignRawTypeToNode`, `CodeMiscNew`, `CodeMiscAddRef`, `ICArgN`, `ICFree`, `ICFwd`, `__HC_SetAOTRelocBeforeRIP`, `CodeCtrlPush/Pop`, `CmpCtrlNew/Del`, ...) |
| `Arm64Enc.cool` | `c/arm64_asm.c` |
| `OptPass.cool` | `c/optpass.c` (skip the bytecode `CompileBC` part) |
| `ArmBackendA.cool` | `c/arm_backend.c` lines 1-2529 (up to, not including, `FuncProlog`) |
| `ArmBackendB.cool` | `c/arm_backend.c` lines 2530-end |

## Rules

**Faithful, mechanical translation.** Same functions, same order, same
control flow, same comments. Don't fix, optimize or restructure — the port
is verified by comparing its machine code byte-for-byte with the C
backend's, so any behavioural change is a bug. If the C code looks buggy,
translate it as is and add a `//PORT-NOTE:` comment.

**Names.** Keep every C identifier except those in `RENAMES.txt`:
- every C struct/typedef `CFoo` becomes the class `CBFoo` (`CRPN` -> `CBRPN`);
- whole constant families that clash with the HolyC frontend get a `B`
  prefix (`IC_ADD` -> `BIC_ADD`, `RT_I64i` -> `BRT_I64i`, `TK_...` -> `BTK_...`);
- 18 clashing functions get a `B` prefix (`IsConst` -> `BIsConst`).
`static` functions become ordinary functions (HolyC has one global scope);
if two C files have a static function with the same name, prefix the later
file's copy with its file tag (`Opt`, `Enc`, `ArmA`, `ArmB`) and note it.

**Types.** `int64_t`/`long` -> `I64`, `uint64_t` -> `U64`, `int32_t` -> `I32`,
`uint32_t` -> `U32`, `int16_t` -> `I16`, `uint16_t` -> `U16`, `int8_t` -> `I8`,
`char`/`uint8_t` -> `U8`, `double` -> `F64`, `void` -> `U0`, `bool`/`_Bool` -> `Bool`,
`void *` -> `U8 *`. HolyC computes in 64 bits: where C relies on 32-bit
wrap-around or truncation (instruction encodings!), make it explicit with a
mask or by assigning to a `U32`/`I32` variable.

**HolyC differences you must handle:**
- **Operator precedence differs from C.** Highest first: unary; `` ` `` (power)
  and `<< >>`; `* / %`; `&`; `^`; `|`; `+ -`; `< > <= >=`; `== !=`; `&&`;
  `^^`; `||`; assignment. So `a | b + c` is `(a|b)+c` and `a + b << 2` is
  `a+(b<<2)`. Parenthesize every expression that mixes operator classes so it
  groups exactly as in C.
- `#define` has no parameters. Turn function-like macros into functions
  (or expand them inline if they are tiny and used a few times).
- No `continue`: use `goto` to a label at the end of the loop body.
- No ternary `?:`: use `if`/`else` into a temporary.
- No designated initializers or compound literals: assign fields one by one.
- Classes are packed (no padding). Don't rely on `sizeof` equalling C's.
- **Postfix casts reinterpret bits, they don't convert**: `i(F64)` is the
  double whose bits are `i`, `x(I64)` the bits of `x`. For C's numeric
  `(double)i` / `(int64_t)x` use `BToF64`/`BToI64` (or assign to a variable
  of the other type); for C's `(uint64_t)x` use `BF64ToU64`.
- **Assigning a class by value copies only its first 8 bytes** (`a = b;`,
  `*p = *q;`). Write struct copies as `MemCpy(&a, &b, sizeof(CBFoo))` and
  `CBFoo x = {0};` as a declaration plus `MemSet`.
  flags suspicious lines.
- `reg` is a keyword; rename such identifiers. A prototype without `extern`
  defines an empty function. Function addresses need `&`. Locals are
  function-scoped.
- Arrays of function pointers don't parse, and the C bootstrap compiler
  returns the member's *address* for `p->fnptr_member`: store function
  pointers in classes and arrays as `U8 *` and copy into a local
  function-pointer variable (declared and assigned on separate lines) to call.
- No `static` locals: use a global named `<Function>_<var>`.
- `switch` builds a jump table over min..max case value; for sparse or huge
  case values use `if` chains (or HolyC's case ranges `case 1...5:` when dense).
- Function calls with no arguments may omit `()`, but always write `()` here
  for clarity. Default arguments exist and are fine.
- String/char literals and `printf`-style calls: `printf(fmt, ...)` ->
  `Print(fmt, ...)`; HolyC `%` formats are close to C's.
- `assert(x)` -> `BAssert(x, "text")`, declared in `BackendA.coolh`.

**Runtime calls.** Map C library/runtime calls to TempleOS names:
`A_MALLOC(sz, hc)` -> `MAlloc(sz)`, `A_CALLOC(sz, hc)` -> `CAlloc(sz)`,
`A_FREE(p)` -> `Free(p)`, `A_STRDUP(s, hc)` -> `StrNew(s)`,
`memcpy(d, s, n)` -> `MemCpy(d, s, n)`, `memset(d, c, n)` -> `MemSet(d, c, n)`,
`strlen` -> `StrLen`, `strcmp` -> `StrCmp`, `QueIns`/`QueRem`/`QueInit` keep
their names, `MSize` keeps its name. Anything that touches the host
runtime (hash tables, `SetWriteNP`, `DoNothing`, TLS/`Fs`, debugger hooks)
stays as a call with the same name plus a `//INTEGRATION:` comment; it is
wired up later.

## Checking your work

Compile a HolyC entry point with the native host and checked-in seed:

```sh
make build/coolc
COOLC_COMPILER_BIN="$PWD/coolc/seed/Compiler.BIN" \
  build/coolc path/to/Entry.cool build/Output.BIN
```

Every translated function should keep the C function's name (after
renames) so reviewers can diff function by function.
