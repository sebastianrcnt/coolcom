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
The script copies sources into `build/native-src` and renames colliding backend
helpers there; it never changes the tracked backend translation.

The current image compiles with `Errs:0`, but still has unresolved native
runtime imports. This is a source integration check, not an executable native
compiler yet. The native host probe (`coolc/Host/test.sh`) verifies BIN loading,
relocation, initializers, and an exported function independently.

## Current integration risks

- Aiwnios' `HCRT2.BIN` contains the whole graphical kernel, so it is unsuitable
  as the native compiler image. The compiler needs its own source bundle and
  a small set of runtime services.
- The frontend expects `Fs`, task heaps, exception handling, hashes, strings,
  and file access from the TempleOS runtime. Those calls must be supplied by
  the owned HolyC runtime or by the small C host before a compiler BIN can run.
- The frontend bugs documented in `tests/behavior/frontend/README.md` must
  be fixed in the owned frontend copy, then covered by native behavior tests.
- Frontend fixes 6, 7, and 8 have source changes and native test inputs, but
  their execution checks must wait until the native runtime can run the
  compiler image. Class value assignment (5) still needs aggregate IR lowering.
