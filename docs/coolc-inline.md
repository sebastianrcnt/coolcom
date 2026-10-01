# Small-function inlining in coolc

coolc copies the bodies of small functions into their callers
(`coolc/Frontend/Inline.cool`). Warm compiles to Cool, and a Warm loop such as
`total := total + nth(&b, i)` became three calls per iteration: `nth` (bounds
check), then a pointer-offset helper (`return p + i;`) and a load helper
(`return *p;`). Each paid for a call, a prologue and an epilogue.

## Design

The pass works on the frontend IR (the `CRPN` list of `cc->coc`). It runs in
`PrsFun` after a function is parsed and before `COCCompile`, so register
allocation, liveness and both backends (arm64, and x86_64 from
`tools/port-x86.py`) only see ordinary IR: no backend code changed.

1. **Expand.** `InlCalls` scans the function's statements (last first, the list
   order). For each statement, `InlSearch` looks for a direct call to a captured
   function, inner calls first. The call is moved in front of the statement:
   - each argument goes into a fresh local, first to last, before the body;
   - the body is copied with fresh locals (`name@N`), labels, string constants and
     symbol references, and every source line set to the call's line;
   - `return e;` becomes `result = e; goto end;` (no jump from the last statement);
   - the statement then reads the result local in place of the call.

   Two refinements keep the number of new locals down, since liveness and graph
   colouring cost grows with them:
   - an argument that is a constant, the address of a local, a symbol's address, or
     a 64-bit/F64 local whose address is never taken is read in place by a
     parameter the body never writes (no copy);
   - for `x = f(...)`, with `x` such a local of the result's type, the body assigns
     `x` itself and the statement disappears.

   The statement is then scanned again (for `f(x, g(y))`: `g`, then `f`); the
   argument statements are scanned too, the copied body is not.
2. **Capture.** `InlCapture` copies the function's IR, after its own calls were
   expanded, when it qualifies (below). `InlCommit` adds it to the unit's table
   (`CCmpCtrl.inline_tab`, keyed by `CHashFun`) once the function compiled.
   Since captured bodies are already expanded, `nth -> offset/load` chains
   collapse in one step, and nesting is bounded by the size limit.

Captured bodies are kept per compilation unit (`CCmpCtrl`) and freed with it
(`CmpCtrlDel` -> `InlTabDel`).

### When

| Callee | Inlined at |
|---|---|
| leaf (no calls), at most 16 IR nodes | any call |
| at most 96 nodes, may call | calls inside a tight loop: a backward branch at most 512 nodes after its label |

A callee must be loop-free (only forward branches): a loop's own cost hides the
call's. A caller stops receiving bodies after 6000 added nodes or 480 locals. With
these limits the compiler self-compile takes 1.07 s instead of 0.95 s and the kernel
0.23 s instead of 0.20 s (see Measurements).

Controls:
- `noinline` before a function definition (`noinline I64 F() {...}`) keeps it out
  of line (new keyword, `KW_NOINLINE`/`FSF_NOINLINE` in `KernelA.coolh`);
- `#define COOLC_NO_INLINE` disables the pass for the rest of the unit;
- `#define COOLC_INLINE_TRACE` prints `inline: CALLEE into CALLER (N nodes)`.

## Safety rules

A function is never inlined (not captured) when it:
- is varargs, `interrupt`, `haserrcode`, `argpop`/`noargpop`, `_intern`/`_extern`,
  imported, or marked `noinline`;
- has `try`/`catch` (`CCF_NO_REG_OPT`), `static` locals, local arrays, locals in an
  explicit register, function pointer variables (their type is owned by the
  member list), or more than 32 arguments and locals or 64 bytes of class-valued
  locals;
- takes a class argument by value, or returns one;
- contains any IR outside a whitelist (`InlBodyType`): no inline assembly, `Fs`/`Gs`,
  register intrinsics (`GetRBP` and the like), switch tables, sub-switch calls,
  statics, `&label`, or casts carrying array dimensions;
- has a loop, or exceeds the size limits.

A call is inlined only when:
- it is a direct call (`IC_ADDR_IMPORT` in AOT, the function's address in JIT) to a
  function of the same unit defined *before* it, with every argument present;
- moving it in front of its statement is invisible: every other operand on the
  way to the statement root reads only constants, addresses and scalar locals whose
  address is never taken (a call cannot change those), except the destination of a
  plain assignment; it is not under the right operand of `&&`/`||`; no node has
  `lock`;
- at most one argument has a side effect, and then the other arguments are
  constants and the statement reads nothing else (the original order of argument
  evaluation is a backend detail, so it must not be observable). Each argument is
  evaluated once, before the body;
- a U0 function is a whole statement.

Recursion: a function's body is captured only after it compiled, so it never
expands into itself; mutual recursion expands one level at most (bodies are not
expanded again).

### Narrow types

The backends do not narrow a value kept in a register: `U8 f(I64 x) {return x;}`
returns 300 for 300, and an out-of-range value stored into a `U8` local is
truncated only if that local was spilled to the frame. Inlining changes which
values are spilled, so a narrow (8-32 bit) destination may only receive a value
that certainly fits (`InlFits`): a constant in range, a comparison or logical
result, or a variable, memory load or call result of a type no wider and of
matching signedness. This applies to narrow parameters at the call, to `return`
in a narrow-returning function and to plain assignments to narrow locals in the
body (compound assignments and `++`/`--` on them keep the function out of line).
Code that stores out-of-range values into narrow variables already had
allocation-dependent results; the inliner relies on values of a narrow type
fitting it.

### Units, the JIT shell and redefinition

Only bodies of the same unit are inlined: one `Cmp()` (AOT), or one `ExePutS`
(JIT: one shell line, one `#include`d file, one Warm program run by `WarmRun`).
A function must be defined before the call; Warm writes callees first
(`WGCallEdge` in `warmc/Emit.cool`) because its output declares every function
`extern` at the top and used to define them in discovery order.

- **JIT:** a call to a defined function is bound to its address when compiled, and a
  later definition with the same name (another line) is a new `CHashFun`: earlier
  callers keep calling the old code. A copied body behaves the same, so
  redefining a function in the shell after another function inlined it has the
  same effect as before inlining: the caller keeps the old behavior until it is
  redefined itself. The kernel test checks this (`Doubled`/`Tripled`,
  `tools/kernel-verify.py`).
- **AOT:** calls bind to the *last* definition of a name in the unit. A function
  defined again after its first body was inlined is therefore an error ("defined
  again after its first definition was inlined (make that one noinline)"); one
  redefined before any inlining just replaces its body.

### Debug info and symbols

Inlined functions still exist and are exported, so their addresses, `&Fun`,
`sizeof(Fun)`, imports and the debugger are unchanged. Inlined code is attributed to
the line of the call; a backtrace through inlined code shows the caller only. The
new locals appear in the caller's member list as `name@N` and `@retN`.

## Tests

`make codegen-test` (`tools/native/codegen.py`, `inline_test`) compiles
`coolc/tests/inline/Inline.cool` for arm64 and x86_64 with inlining and for arm64
with `COOLC_NO_INLINE`; all must print `Inline.expected`, and the trace must equal
`Inline.trace` (which calls were and were not inlined). It covers nested chains,
argument order and single evaluation, result forwarding into an argument, locals
with the caller's names, labels and gotos in copies, several copies in one
function, narrow types, F64 arguments, pointers to caller locals, class-valued
locals, `&&`/`||`, `switch`, default arguments, string constants, function pointers,
`noinline`, recursion, `try`, statics, varargs, a function defined twice, and a
function that passes 64 locals through inlining (liveness bit sets). A unit that
redefines an inlined function must fail to compile. The 1703 existing probes still
match across targets and print the same as before inlining. The kernel test checks
JIT inlining and redefinition in the shell; `selfhost-test` and
`kernel-rebuild-test` check that the OS rebuilds the seed and the kernel byte for
byte (the latter caught the function-pointer member rule: the OS's second kernel
compile deletes the first one's member lists).

## Measurements

Apple M1 host, 2026-10-01. Host programs: `python3 tools/inline-bench.py --repeat 5
--before <previous seed>` (best of 5 wall-clock runs, process start included; the
same Cool source compiled by the previous seed, by the new seed with
`COOLC_NO_INLINE`, and by the new seed):

| Program | previous seed | no inlining | inlining |
|---|---|---|---|
| `coolc/tests/inline/Bench.cool` (Clamp/Abs/Lower/Get/Put/Dot in a loop) | 0.546 s | 0.545 s | 0.160 s (3.4x) |
| `coolc/tests/inline/BufferSum.warm` (200M `nth` reads) | 0.702 s | 0.710 s | 0.400 s (1.77x) |

In BufferSum, `nth` (70 nodes after its own expansion: bounds check, abort path,
offset and load helpers) and `storeNth` are inlined into `main`'s loops.

Vim and Tmux in the VM: `python3 tools/coolc-inline-perf.py --repeat 3`
(tools/program-perf.py's warm workload; "before" is the same revision with
`COOLC_NO_INLINE` for the kernel and for the Warm programs the guest compiles),
medians:

| | before | after | ratio |
|---|---|---|---|
| Vim navigation (us/key) | 0.2168 | 0.1850 | 0.85 |
| Vim insertion (us/key) | 0.0584 | 0.0596 | 1.02 |
| Vim paint (ms) | 3.978 | 3.918 | 0.98 |
| Vim jump to end of 330 KB (ms) | 7.140 | 6.951 | 0.97 |
| Tmux paint (ms) | 12.85 | 12.90 | 1.00 |
| Tmux key forwarding (us/key) | 0.075 | 0.088 | noise (trials 0.02-0.10) |

Only navigation moves beyond the run-to-run spread; the editor's other paths are
dominated by drawing and kernel calls that are not small functions.

Cost (seconds are the best of 3 host compiles):

| Unit | code before | code after | compile before | compile after |
|---|---|---|---|---|
| compiler (seed) | 0x16E258 | 0x17ACC8 (+3.4%) | 0.95 s | 1.07 s |
| kernel | 0xC67E0 | 0xD4748 (+7.0%) | 0.20 s | 0.23 s |
| warmc | 0xBB820 | 0xC8940 (+6.9%) | 0.12 s | 0.17 s |

The first version (96-node bodies anywhere, loops allowed in callees) grew the
kernel by 50% and tripled the compiler's compile time, mostly from loop helpers
(`MemSet`, `StrCpy`) and cold wrappers (`KTFail`, abort paths) inlined into large
dispatch functions; hence the leaf-only tier outside loops and the tight-loop rule.
