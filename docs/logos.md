# Logos (historical design)

The custom Logos transport was retired after Venus milestone 3 passed. The
cell/atlas/overlay design below now lives in the guest Vulkan terminal app;
see [implementation, tests and measurements](venus.md#milestone-3-resident-vulkan-terminal).
This document preserves the original protocol and M1 measurements for history.

Logos is coolcom's GPU graphics layer, named after John 1:14 ("the Word became flesh"):
text becoming visible. Its first part draws the console's terminal cells on the GPU in
coolvm. The guest sends cells instead of pixels, and coolvm draws them with Metal.

## How it works

The console is a grid of cells (`Term.cool`), and `Fb.cool`'s renderer shows it. Without
Logos the renderer draws each changed cell into a back buffer with Unifont and copies the
pixels to the display: a simple-framebuffer, or a virtio-gpu 2D resource under coolvm.
With Logos the same renderer hands its frame to `LogosFrame` (`os/Kernel/Logos.cool`)
instead:

- The rows that changed go to the device as cells: glyph, fg, bg and flags (bold, reverse,
  underline, right half of a wide glyph). The rows are sent in runs, one command each.
- A full-screen scroll is one command: the device keeps the rows in a ring.
- The guest still rasterizes the glyphs, from the same Unifont as the CPU renderer (a TTF
  rasterizer can replace it later). It uploads each glyph once, as 8-bit coverage into the
  device's atlas.
- The cursor is a cell position.
- Rectangles painted over the console (`FbFillRect`, which Warm's `OS.CoolOS.Framebuffer`
  also uses) go to a pixel layer that covers the cells until those cells are sent again.
  The CPU renderer behaves the same way.

coolvm (`tools/coolvm/src/logos.m`) only updates state when a command arrives. It renders
the whole screen when something needs pixels: the window, once per changed frame, and a
screenshot. The render is one Metal pass. For each pixel it takes the cell and the glyph's
coverage from the atlas, then applies the colors and attributes, the block cursor
(inverted) and the pixel layer. Headless screenshots render offscreen, so tests see Logos
output. The window currently reads the rendered frame back and draws it as an image, the
same path the 2D mode uses. Presenting straight to a `CAMetalLayer` is the next step.

The output is pixel-identical to the CPU renderer except for bold text, which Logos
emboldens by one pixel.

## The protocol

Custom commands on the virtio-gpu control queue. Device feature bit 23 offers them, and
FDT `coolcom,logos = <1>` on the virtio-gpu node says so too. The driver accepts the
feature bit to use them. Every command is the 24-byte control header followed by 32-bit
little-endian fields; the first field names the target (0 is the screen; a window will be
another target). GRID carries the protocol version. A later version adds command numbers
instead of changing these.

| Command | Fields |
|---|---|
| `0x4000` GRID | target, version (1), width, height (pixels), cols, rows, cell width, cell height: (re)starts the target, blank |
| `0x4001` GLYPH | id (not 0), cells (1 or 2), then cells × cell width × cell height coverage bytes |
| `0x4002` ROWS | target, first row, count, 0, the guest address of count × cols cells (16 bytes: glyph id, fg, bg, flags) |
| `0x4003` SCROLL | target, n: the rows move up n, the n new bottom rows are blank |
| `0x4004` CURSOR | target, col, row, cells (0: hidden) |
| `0x4005` FILL | target, x, y, w, h, 0xRRGGBB: a rectangle on the pixel layer |
| `0x4006` PRESENT | target: the frame is complete |

The glyph atlas is one fixed 4096×2048 texture, with room for 32,768 glyph slots at
8×16 cells. Nothing is ever evicted. When the atlas is full, GLYPH fails and the guest
shows `?` for glyphs it could not upload.

## When it is used

`FbInit` uses Logos when coolvm's virtio-gpu offers it. Otherwise the CPU renderer draws as
before: on QEMU, on a real M1, with `coolvm --no-gpu`, and with `coolvm --no-logos` (the off
switch). A display resize sends GRID again with the new size.

## Tests

The existing pixel tests (kernel, Vim, Tmux, ANSI, syntax, IME, text, Warm, GPU pixel and
resize) run with `--no-logos`, so they keep checking the CPU renderer. `make logos-test`
(part of `make test`):

- `tools/logos-test.py` runs five screens twice, with Logos and with `--no-logos`, and
  compares the headless screenshots. The screens are colors (16 and 256-color, reverse,
  bold, 24-bit, Hangul and CJK wide cells, scrolling, a filled rectangle), the same at
  1031×775 (partial cells in the margins), Vim on `Init.cool` with syntax colors, Tmux with
  two panes, and a resize from 1024×768 to 800×600. At most 0.1% of the pixels may differ;
  only bold text does (31 pixels). The test also checks that the filled rectangle is
  visible with Logos on.
- The scroll and fill run of `tools/scroll-bench.py` with Logos must equal the
  simple-framebuffer reference exactly, at 640×480 and 1031×775.

## Speed

Measured with `tools/scroll-bench.py` on an M1: 3000 lines, each followed by a forced frame
(`FbFlush`), then 3000 lines batched by the timer. Averages of 3 runs, headless. "CPU" is
the virtio-gpu 2D path (`--no-logos`), the default before Logos.

| | 1024×768 CPU | 1024×768 Logos | 3200×2000 CPU | 3200×2000 Logos |
|---|---|---|---|---|
| forced frame, µs per line (guest) | 160 | 45 | 281 | 138 |
| 3000 lines with forced frames, ms | 1127 | 521 | 1311 | 868 |
| 3000 lines batched, ms | 519 | 407 | 648 | 492 |
| host CPU for the whole run, s | 1.67 | 1.30 | 2.38 | 1.87 |

Headless, Logos makes pixels only for the final screenshot. With a window, each changed
frame also costs one Metal pass and, for now, the readback.
