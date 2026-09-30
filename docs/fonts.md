# Console fonts and HiDPI

The console's glyphs come from one place, `os/Kernel/Glyph.cool` (`GlyphGet`). Both the
CPU renderer (`Fb.cool`) and the Vulkan terminal (`os/Vulkan/Terminal.cool`) use it. The
font decides the cell size.

## Scale

Every glyph is drawn at 1x or 2x. At 2x, Unifont's 8x16 stamps are drawn with each bit as
a 2x2 block, so a cell is 16x32 pixels, and the screen looks the same size as 1x does on a
screen of half the resolution.

- **Under coolvm with virtio-gpu,** the scale is the window's backing scale: 2 on a
  Retina display, 1 otherwise. coolvm reports it in a coolcom-specific virtio-gpu config
  register, at config offset 0x10, after the standard ones. It sends a display-change
  event when the window moves to a screen with another scale. `coolvm --scale N` fixes
  the scale at 1 or 2. Headless runs use 1 unless `--scale` says otherwise.
- **Elsewhere** (QEMU, a real M1, `coolvm --no-gpu`), the scale is 2 when the screen is at
  least 2560 pixels wide, and 1 otherwise.
- **Overrides:** the boot argument `coolcom.scale=1` or `coolcom.scale=2`, or
  `FontScale(n);` in the shell (`FontScale(0);` goes back to automatic).

A change of scale makes a new grid over the same pixels. Programs see it as a resize
(`KEY_RESIZE`), as they do when the window changes size.

## Tests

`make font-test` (part of `make test`) boots the same screen at 1024x768 with scale 1 and at
2048x1536 with scale 2. The 2x screenshot must equal the 1x one with every pixel doubled.
It checks the CPU renderer, and also the Vulkan terminal when the Venus stack is built
(`make venus-vendor venus-terminal`). The other pixel tests use scale 1.
