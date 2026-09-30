#include "Asm.h"
// Files embedded in the Image for the shell (Shell.cool): the Cool compiler
// seed here, and the shell prelude source (build/ShellPrelude.coolh, made by
// tools/mkprelude.py from the kernel sources), which tools/binlink.py puts in
// the kernel module (SHELL_PRELUDE).
// Paths are relative to the repository root, where make runs the assembler.

.section .rodata
.balign 16
cmp_bin:
  .incbin "coolc/seed/Compiler.BIN"
cmp_bin_end:

.text
// ArchCompilerBin(I64 *size): address of Compiler.BIN, its size in *size.
.global ArchCompilerBin
ArchCompilerBin:
  LA x1, cmp_bin
  LA x2, cmp_bin_end
  sub x2, x2, x1
  str x2, [x0]
  mov x0, x1
  ret

// ArchKSyms(): the kernel symbol table (tools/binlink.py, KSym.cool).
.global ArchKSyms
ArchKSyms:
  LA x0, KSYM_TABLE
  ret

// ArchArm64Ops(): the disassembler's opcode table (Arm64Ops.csv, UAsmARM64.cool).
.global ArchArm64Ops
ArchArm64Ops:
  LA x0, ARM64_OPS
  ret

// ArchFp(): the caller's frame pointer (x29), for backtraces (KDbg.cool).
.global ArchFp
ArchFp:
  mov x0, x29
  ret

// ArchShellPrelude(): the prelude text.
.global ArchShellPrelude
ArchShellPrelude:
  LA x0, SHELL_PRELUDE
  ret
