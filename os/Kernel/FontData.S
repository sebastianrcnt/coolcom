#include "Asm.h"
// The console font (GNU Unifont, converted by tools/mkfont.py; layout in that
// file). It is too big for the boot stub's 2 MiB, so Kernel.ld places it after
// the HolyC module's BSS, just before image_end. Path is relative to the
// repository root, where make runs the assembler.

.section .fontdata,"a"
.balign 16
unifont_data:
  .incbin "os/Kernel/Unifont.BIN"

.text
// ArchFontData(): the font blob.
.global ArchFontData
ArchFontData:
  LA x0, unifont_data
  ret
