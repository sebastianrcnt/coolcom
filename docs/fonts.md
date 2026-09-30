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

## TrueType fonts

`FontSet("C:/Fonts/SarasaMonoK-Regular.ttf", 14);` in the shell sets a TrueType font at 14
pixels per em at 1x (the scale multiplies it). `FontSet;` (a NULL path) goes back to
Unifont. The first call loads `C:/FontTtf.cool` into a resident task, the way the Vulkan
terminal is loaded:
- `stb_truetype`, translated to Cool (`coolc/Lib/StbTrueType.cool`), reads the font.
  A `.ttc` collection uses its first font. The translator handles TrueType outlines only,
  not CFF.
- The cell is the advance of `M` wide and the font's line (ascent, descent, line gap) high.
- Glyphs are rasterized lazily with grayscale antialiasing, and kept in a 32 MiB cache,
  keyed by code point and bold. A font or scale change empties the cache, and so does a
  full cache.
- Bold text uses the `Bold` file next to a `...Regular...` one, when it exists. With
  Unifont, the Vulkan terminal emboldens bold text and the CPU renderer draws it plainly,
  as before.
- A code point the font lacks is Unifont's glyph, scaled by an integer that fits and
  centered in the cell.
- Wide cells (Hangul, CJK) are two columns, as the terminal decides.

Changing the font makes a new grid, and programs see a resize.

Font files are not in the repository. `make disk-install` and `make run` (`disk-seed`)
copy them from the Mac when present (`tools/disk-fonts.sh`) into `C:/Fonts`:
- `~/Library/Fonts/SarasaMonoK-Regular.ttf` and `SarasaMonoK-Bold.ttf`;
- the system's `NanumGothic.ttc`, found under `/System/Library/AssetsV2`.

`C:/Init.cool` sets Sarasa Mono K at 14 when it is there, once per boot: a later
`FontSet` is kept, even in new Tmux panes. The disks the tests build have no fonts, so
their screens stay Unifont at 1x.

## Tests

`make font-test` (part of `make test`) boots the same screen at 1024x768 with scale 1 and at
2048x1536 with scale 2. The 2x screenshot must equal the 1x one with every pixel doubled.
It checks the CPU renderer, and also the Vulkan terminal when the Venus stack is built
(`make venus-vendor venus-terminal`). With Sarasa Mono K in `~/Library/Fonts` it also
runs a TrueType smoke test; otherwise that part is skipped. The smoke test checks that the
regular and bold faces load, that the cell metrics are sane at 1x and 2x (the 2x cell is
the 1x cell doubled, give or take a pixel), and that every glyph of a `Hello 한글 bold`
line has ink and antialiased gray pixels. It runs on the CPU renderer, and on the Vulkan
terminal when that is built. The other pixel tests use Unifont at scale 1.
