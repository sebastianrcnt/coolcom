#include "Asm.h"
// Files embedded in the Image for the shell (Shell.HC): the Cool compiler
// seed and the shell prelude source (build/ShellPrelude.HH, made by
// tools/mkprelude.py from the kernel sources; NUL-terminated).
// Paths are relative to the repository root, where make runs the assembler.

.section .rodata
.balign 16
cmp_bin:
  .incbin "coolc/seed/Compiler.BIN"
cmp_bin_end:
shell_prelude:
  .incbin "build/ShellPrelude.HH"
  .byte 0

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

// ArchKSyms(): the kernel symbol table (tools/binlink.py, KSym.HC).
.global ArchKSyms
ArchKSyms:
  LA x0, KSYM_TABLE
  ret

// ArchShellPrelude(): the prelude text.
.global ArchShellPrelude
ArchShellPrelude:
  LA x0, shell_prelude
  ret
