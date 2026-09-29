# Native CoolC on Apple Silicon

## Target

`coolc <entry.HC> <out.BIN>` runs the HolyC frontend and the CoolC AArch64
backend in a macOS process. Aiwnios is allowed only to create the first
compiler BIN. The compiler must then rebuild its own BIN to a byte stable
fixed point and compile `os/Kernel/Kernel.HC` to the same BIN as Aiwnios.

## Decisions

- The native host loads TempleOS BIN modules. Patch types and layout follow
  `tools/binlink.py` and Aiwnios `c/loader.c`; the host does not parse HolyC.
- Host code pages use `MAP_JIT`. Writes happen with JIT write protection off;
  execution happens with it on. Data heaps remain regular writable mappings.
- The frontend sources are copied from Aiwnios commit `e155e87` into this
  repository and changed here. The existing backend port is linked directly,
  without the Aiwnios C backend switch.
- Keep AOT output deterministic. The first fixed point check compares the
  complete second and third generation BIN files, not only code sections.

## Build stages

1. Load and execute a small AArch64 BIN in the native host.
2. Bootstrap a compiler BIN with Aiwnios from the owned frontend, minimal
   runtime, and `coolc/Compiler`.
3. Compile the code generation suite with the native CLI, then rebuild the
   compiler to a fixed point.
4. Compile the kernel, compare with Aiwnios, and add an opt-in Makefile path.

`tools/native/bootstrap.sh [out.BIN]` builds a stage-zero image from the owned
frontend and runtime sources plus the existing backend. In a separate worktree,
set `AIWNIOS_DIR` and `AIWNIOS_BIN` to the built stage-zero Aiwnios checkout.
The backend's colliding helper names are resolved in `coolc/Compiler` itself;
the script only copies the tracked sources into `build/native-src`.

The default build leaves frontend fixes 5, 6, and 7 disabled for baseline
parity. The 24/24 codegen, compiler self-build, and kernel checks passed before
aggregate value assignment (bug 5) was enabled. Set `NATIVE_FIXES=1` in
`tools/native/prepare.sh` to enable the frontend fixes. Bug 8 is always enabled;
the baseline inputs do not use arrays of function pointers.

`tools/native/check.sh` verifies the baseline: all 24 codegen modules match
Aiwnios under `bincmp.py`, the complete second and third generation compiler
BINs match byte for byte, and the kernel matches Aiwnios under `bincmp.py`.
`bincmp.py` clears import and heap relocation slots before comparing machine
code; those slots hold process addresses until the BIN loader patches them.
The compiler's own BIN clears those slots when it writes them, giving the
required full-file fixed point. `make AIWNIOS=/path/to/aiwnios native-kernel`
builds the optional `build/Kernel.native.BIN` through the self-built compiler.

`tools/native/behavior.sh` prepares a compiler with fixes 5, 6, and 7 enabled,
compiles and executes the native 5, 6, 7, and 8 behavior cases, and compares
their printed probe results against expected output. Bug 5 now forwards the
class width and operand addresses to an aggregate copy in the backend. Large
class locals remain on the stack so their full address is available. The fixed
output differs from Aiwnios for aggregate assignment, large decimal floats,
and string default arguments; those are the intended bug corrections.

## Current integration risks

- Aiwnios' `HCRT2.BIN` contains the whole graphical kernel, so it is unsuitable
  as the native compiler image. The compiler needs its own source bundle and
  a small set of runtime services.
- The small host still contains diagnostic traps for imports that the current
  compiler and validation paths never call. A future larger runtime workload
  can expose a missing service through a named trap.
- Frontend fixes 5, 6, and 7 are guarded by `COOLC_FRONTEND_FIXES` so baseline
  parity stays testable. Aggregate assignment results used as values beyond
  the tested statement form still need a dedicated value representation.
