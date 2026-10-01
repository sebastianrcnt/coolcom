# coolcom GUI

## Confirmed design

A window is a task-owned kernel surface. All tasks share one address space;
there is no GUI IPC. Applications draw into their buffer and mark damage. A
compositor task updates the damaged windows and composes the desktop.

Two surface types are supported:

- **Cell:** one existing `Term.cool` cell grid per window. Shell, Vim, Tmux and
  Top run inside it without application changes.
- **Pixel:** a physical-pixel BGRA buffer.

With Venus, each window is a texture rectangle; the terminal cell renderer's
output goes to that window's texture. Without Venus, the Fb CPU path blits dirty
regions. Both paths must produce the same pixels.

Windows float, with keyboard tiling shortcuts. Drawing is an immediate-mode
2D Cool kernel API (`GrRect`, `GrLine`, `GrText`, `GrBlit`) with automatic damage
tracking. The widget toolkit lives in Warm as `OS.Gui`, following standard
library capability and `OS.*` naming rules. Widgets include buttons, labels,
lists, text inputs and layout. `tools/warm-man.py` generates Man pages from
`.warmh` interfaces.

Click selects focus. Keys go to the focused window task's input queue. The
compositor owns decorations (title bar and close button), moving and resizing,
and the mouse cursor. DolDoc compatibility is out of scope. Tmux remains a tool
inside a terminal, not the desktop window manager.

Boot remains the current full-screen terminal. `Gui;` switches to the desktop;
changing the boot default is deferred until stabilization.

Window geometry uses logical pixels; surface buffers use physical pixels, using
scaling in the same manner as `FontScale`.

## Classic appearance

Use the monochrome, one-bit feel of classic Macintosh System 1–7. The desktop
has a gray checker dither. A white top menu bar contains a system menu at the
left, application menus, and a clock at the right. G1 starts with the system
menu and clock; G3 adds the Warm OS.Gui menu API.

Active title bars have horizontal stripes around a centered title; inactive
bars are plain. The close box is on the left, zoom box on the right. Windows
have a one-logical-pixel black border, a one-pixel right/bottom shadow, and a
bottom-right resize box. Scrollbars have arrows and a gray patterned track.
Buttons are rounded rectangles; default buttons have a thicker border.
Selections invert black and white. The pointer is a black/white arrow.

Use an original or open-license bitmap font with a bold Chicago-like feel;
never ship the original proprietary font. Terminal contents keep their ANSI
colors. Every one-pixel line scales to an integer number of physical pixels,
without filtering, preserving crisp pixel art at HiDPI.

## Implementation sequence and acceptance

| Stage | Work | Acceptance |
| --- | --- | --- |
| G1 | Compositor, cell windows, multiple shells, move/resize/close, cursor | Vim/Tmux/Top work in windows; CPU/GPU pixel equality |
| G2 | Pixel surfaces, Gr API, automatic damage, local mouse events | Drawing demo; multiple windows keep input responsive |
| G3 | Warm OS.Gui widgets and example | Capability checks, regenerated Man pages, example works |
| G4 | File manager, GUI Top, font/scale settings, windowed Cube | Apps run as desktop windows |
| G5 | Direct Vulkan application surfaces | Venus apps render into their own window |

Each stage runs `make -j test` successfully before its English-language commit.
No commits are pushed. Results and any limitations are recorded below.

## Integration constraints

Do not modify `os/Disk/Vim*`, `Tmux*` or `Top*` (concurrent Warm ports). Avoid
`os/Kernel/Mem.cool` (concurrent large-allocation work). Canonical kernel header:
`coolc/Frontend/KernelA.coolh`; `os/Kernel/KernelA.coolh` is generated. Never edit
`vendor/` (symlinks). VM tests use the shared `tools/testvm.py` plumbing and
isolated test disks/output directories.

## Results

`main` heap integration (`8ddec69`) was merged before G1 acceptance. GUI raster
buffers use ordinary virtual allocations; GPU guest DMA allocations use the
merged `CAllocDma` paths. No additional heap changes were needed.

### G1 — complete

Implemented task-owned cell windows and a core-0 compositor task. `Gui;` opens
two independent shells. Click focuses; title dragging moves; the bottom-right
box resizes; the left close box stops the terminal's process group; the right
zoom box toggles maximized/floating geometry. Ctrl+Alt+N opens a shell,
Ctrl+Alt+Tab cycles focus, Ctrl+Alt+Left/Right tiles halves, Ctrl+Alt+Up fills the
screen, and Ctrl+Alt+Q returns to the preserved full-screen terminal.

Classic chrome uses bitmap-bold GNU Unifont, integer-scaled black borders and
shadows, active-only stripes, dither wallpaper, a System control (new shell),
a minute clock and a monochrome arrow. ANSI terminal colors are preserved.

The shared `FbGlyph` cell rasterizer targets window BGRA backing; Venus uploads
only changed window textures and draws their rectangles. CPU composition clips
copies to desktop damage. GPU commands have their own command buffer, and GPU
resources are released when leaving the desktop. Display mode changes are
currently deferred until returning to the full-screen terminal.

Validation (2026-10-01): `make -j test` exited 0. The new `gui-test` runs unchanged
Vim, Top and Tmux in a window, closes a background shell through the mouse,
drags a title, tiles via keyboard, resizes and toggles zoom. Its screenshots
verify chrome pixels, exact CPU/Venus equality (except the changing clock),
and exact 2x integer enlargement. Artifacts: `build/gui-test/`; full log:
`build/g1-test.log`. Existing terminal, font, Warm, disk, network, relocation,
QEMU and kernel rebuild checks also passed. No protected app source or vendor
file was modified.

### G2 — complete, including G1 review corrections

Pixel windows (`GuiNewPixel`) expose task-local `GrRect`, Bresenham `GrLine`,
UTF-8 bitmap `GrText`, nearest-neighbor `GrBlit`, and physical BGRA access
(`GrPixels`, byte stride; call `GrDirty` after direct writes). Gr coordinates
are logical pixels. Operations clip to the client rectangle and track damage
automatically. Pixel windows keep their requested logical dimensions.

`GuiDraw;` opens the drawing demo as a separate task. `GuiPoll` returns local
mouse/button/wheel events, keyboard events and resize notifications. Input IRQs
queue ordered records for the compositor; a click and a following key reach the
same focused task, including button presses/releases within one IRQ. The
compositor wakes immediately for input; queues report overflow explicitly.

G1 screenshot review corrections are included here: 3-pixel white client
insets, a clear black body frame/shadow, a reserved bottom grow-box strip,
active-only close/zoom/grow controls, and an activation click before a hidden
control can be used. Bodies remain opaque in both composition paths. The
screenshot scenario now gives the background terminal a distinct blue surface;
assertions inspect the overlapping front body, left/bottom frame and shadow,
insets and hidden inactive controls. The previous all-black terminal bodies
made the separation visually ambiguous.

Targeted validation: G1 and G2 GUI tests pass on CPU/Venus. G1's pixel equality
and 2x checks still pass. Five-window drawing tests preserve every key in an
80-key burst and check enqueue-to-app latency against a 100 ms ceiling, local
mouse coordinates, primitive colors and CPU/Venus equality. `make -j test` exited 0 on 2026-10-01 (`build/g2-test.log`).

### G3 — complete

`OS.Gui` provides opaque linear Gui/Window capabilities, root acquisition,
checked task-owned scalar adapters, typed local events, immediate label/button/
list/scrollbar/text-input widgets, and a vertical row layout. The host backend
reports unavailable GUI operations. Text inputs edit UTF-8 codepoints and keep
text/caret within the control; buffer spans use counted, borrow-scoped ranges.
Menus register on a window and appear for its focused app, with a server popup
overlay, inverted selection, Escape and arrows/Enter. The System menu adds the
Widgets launcher. Pixel close requests allow one second for app cleanup.

`GuiWidgets;` compiles/runs the Warm example in an independent core-0 task;
`GuiRun(program, entry)` uses the generated guest OS module list shared with
`os/Warm/modules.py`. Widgets exercise every basic control and a File menu.
Man pages were regenerated with `tools/warm-man.py` into `build/gui-man/`; the
production installer regenerates them from `.warmh` plus the prose notes.

Targeted tests cover capability construction denial, root acquisition, missing
authority, unclosed windows, host ABI compilation, menu overlay pixels, rounded
thick default-button borders, inverted list selection, scrollbar dithering,
UTF-8 insertion/deletion, keyboard editing with visible output, and graceful
close. CPU and Venus widget screenshots match exactly outside the clock.
Artifacts: `build/gui-widgets-test/`. `make -j test` exited 0 on 2026-10-01
(`build/g3-test.log`), including G1/G2 regression checks and all existing tests.

### Warm terminal application integration

The Warm ports use the calling window's terminal size, key queue and alternate
screen. Top retains keys received during its initial CPU sample; Vim/Tmux are
loaded through WarmRun on first use rather than compiled in every new pane's
startup. This also keeps the compositor available for title dragging while a
pane starts. The original gui-test assertions cover app return, window geometry,
1x/2x equality and CPU/Venus pixel equality.

Validation after merging GUI main: `make -j gui-test` and `make -j test` both
returned exit code 0, including the Venus comparison. Logs are
`build/port/gui-lazy.log` and `build/port/gui-full-test.log`. No gui-test
assertions or scenarios were changed.

After the G3 commit, `main` (`5ee167a`) was merged with both documentation
sections retained. `make -j test` exited 0 again (`build/g3-main-test.log`),
including unchanged G1 screenshots with Warm Vim, Tmux and Top, G2 latency,
G3 widgets, editor/pane tests and the existing suite.

G4–G5 are pending.
