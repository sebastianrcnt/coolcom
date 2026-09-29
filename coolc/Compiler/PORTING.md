# Porting the Aiwnios AArch64 backend from C to CoolC

The Aiwnios HolyC frontend (`coolc/third_party/aiwnios/Src/*.HC`) builds IR
through `__HC_*` functions implemented in C, and the C code optimizes the IR
and emits AArch64 machine code. To make the whole compiler CoolC (and so
editable inside the OS) we translate that C code to CoolC here.

Upstream is pinned to Aiwnios commit `e155e87` (the submodule). The code is
BSD-3; keep a credit line at the top of every translated file:
`// Translated from Aiwnios <file> (nrootconauto, BSD-3), commit e155e87.`

## Files

| CoolC file | Translated from |
|---|---|
| `BackendA.HH` | `c/aiwn_lexparser.h`, `c/aiwn_arm.h` (types, enums, macros needed by the files below) |
| `IRBind.HC` | `c/parser.c`: the `__HC_*` binding functions (~lines 4581-5109) and the helpers the backend calls (`AssignRawTypeToNode`, `CodeMiscNew`, `CodeMiscAddRef`, `ICArgN`, `ICFree`, `ICFwd`, `__HC_SetAOTRelocBeforeRIP`, `CodeCtrlPush/Pop`, `CmpCtrlNew/Del`, ...) |
| `Arm64Enc.HC` | `c/arm64_asm.c` |
| `OptPass.HC` | `c/optpass.c` (skip the bytecode `CompileBC` part) |
| `ArmBackendA.HC` | `c/arm_backend.c` lines 1-2529 (up to, not including, `FuncProlog`) |
| `ArmBackendB.HC` | `c/arm_backend.c` lines 2530-end |

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
- **Assigning a class by value copies only its first 8 bytes** (`a = b;`,
  `*p = *q;`). Write struct copies as `MemCpy(&a, &b, sizeof(CBFoo))` and
  `CBFoo x = {0};` as a declaration plus `MemSet`. `tools/porttest/classassign.py`
  flags suspicious lines.
- `reg` is a keyword; rename such identifiers. A prototype without `extern`
  defines an empty function. Function addresses need `&`. Locals are
  function-scoped.
- Arrays of function pointers don't parse: store them as `U8 *` and copy
  into a local function-pointer variable to call.
- No `static` locals: use a global named `<Function>_<var>`.
- `switch` builds a jump table over min..max case value; for sparse or huge
  case values use `if` chains (or HolyC's case ranges `case 1...5:` when dense).
- Function calls with no arguments may omit `()`, but always write `()` here
  for clarity. Default arguments exist and are fine.
- String/char literals and `printf`-style calls: `printf(fmt, ...)` ->
  `Print(fmt, ...)`; HolyC `%` formats are close to C's.
- `assert(x)` -> `BAssert(x, "text")`, declared in `BackendA.HH`.

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

Syntax-check a file by compiling it with the stage-0 compiler. In a scratch
directory (not in the repo) put: `os/Kernel/KernelA.HH`, `BackendA.HH`, your
file, a stub header of `extern` prototypes for everything your file calls
that is defined elsewhere (other port files, `MAlloc`, `Print`, `MemCpy`,
`QueIns`, ...; HolyC rejects calls to undeclared functions), and an entry
file that `#define BACKEND_STANDALONE` and then includes them in that order. Then run
`AIWNIOS_DIR=/Volumes/t5/coolcom/coolc/third_party/aiwnios tools/aiwcc.sh <dir> <entry.HC> <out.BIN>`
from the repo. It must report `Errs:0`. Don't commit the stubs.

Every translated function should keep the C function's name (after
renames) so reviewers can diff function by function.
