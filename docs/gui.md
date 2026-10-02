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
| Cursor | virtio-gpu cursor queue, native Mac cursor, headless composition | Single native pointer; CPU/Venus, scale, hotspot and hide tests |
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
box previews a resize with a gray patterned outline and commits the size once on
release. The replacement front and back buffers retain the old committed client
until the app repaints. The left close box stops the terminal's process group; the right
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
applied by the compositor while the GUI is active: it rebuilds the desktop,
canvas, overlay and CPU/Venus scanout, fits windows into the new area, and
composes the new desktop before selecting the replacement scanout.

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

### G4 — complete

The System menu launches `GuiFiles;`, `GuiTop;`, `GuiSettings;`, and `GuiCube;`.
The three utility apps used Warm OS.Gui and a shared application helper module;
U5 rewrote them on OS.Ui (see [ui-framework.md](ui-framework.md)).
Files confines read access through OS.Dir/OS.File capabilities, shows directory
markers and an inverted selection, filters names, navigates folders/parents,
and retains a text preview/byte count across mouse events. GUI Top displays
copied task names/ids, core, CPU share and state plus heap use; its Kill action
uses the checked system capability and stable task id. Settings selects 1x/2x
and bitmap/optional Sarasa Mono K terminal fonts. Missing fonts report in the
app. Longer control labels are clipped to their widget rectangles.

Changing scale retains logical geometry, rebuilds physical window backing and
resident GPU textures, and sends repaint events even if cell counts did not
change. All monochrome chrome and controls stay exact integer pixel art.

The existing Cube renderer has a task-owned pixel-window mode. It renders at
physical client dimensions, copies its GPU readback into the pixel surface,
and handles local keyboard/drag/wheel input, move/resize and clean shutdown.
The full-screen Cube mode remains available. Without Venus the desktop opens
a monochrome availability message instead of trying to load Vulkan sources.

`main` absolute-pointer support (`1123eec`) and the classic arrow/paint-color
assertion correction (`65cff5c`) were merged during G4. New tests and G2 use
`testvm.pointer_absolute` (EV_ABS with exact integer mapping); G1 retains
relative input regression coverage. Tests cover folder navigation/filter/read,
monitor selection/protected-task kill denial, font/scale changes, exact 1x/2x
pixel enlargement, CPU/Venus app pixels, Cube scene/camera/move/resize and
repeated GPU buffer reclamation. Man pages were regenerated from the headers.
Artifacts: `build/gui-apps-test/`, `build/gui-scale-test/`,
`build/gui-cube-test/`. `make -j test` passed (exit 0; `build/g4-test.log`). The legacy full-screen
`cube-test` also passed all eight scenarios during the initial acceptance run.

The drawing demo acknowledges completed presentation before its ready/paint
markers; its input test waits for all 80 responses before VM shutdown. The
scroll pixel comparison waits for the final drawing/finish and shell prompt,
rather than taking a screenshot after the last text row but before the rectangle
has been drawn. Pixel and 100 ms input bounds remain unchanged.

Before G5, the user requested a hardware-cursor integration stage. GUI
pointers use standard virtio-gpu UPDATE_CURSOR/MOVE_CURSOR with a 64x64 BGRA
resource and hotspot; shape APIs support future I-beam/wait cursors. GUI exit
hides that resource. coolvm displays it through NSCursor with physical-to-view
scaling, uses the default Mac arrow for terminal mode, and composites the guest
cursor only in exported screenshots/frame dumps. CPU and Venus use the same
cursor path. Standard QEMU virtio-gpu cursor behavior should also be covered.

### Hardware cursor — complete

`GuiPointerSet` accepts up to 32x32 logical BGRA pixels and a logical hotspot;
`GuiPointerHide` and `GuiPointerShow` preserve/restore the shape. Integer scale
produces a transparent 64x64 DMA-backed virtio-gpu resource. Movement uses
MOVE_CURSOR; setting shape/hotspot uses UPDATE_CURSOR. GUI CPU and Venus
composition contain no pointer pixels, and exiting GUI hides the resource.
The text caret now uploads inverted pixels into the 2D scanout instead of using
the hardware pointer. Font changes inside GUI retain its pointer.

coolvm's view installs a shape-specific NSCursor through cursor rectangles;
physical-to-view scale and hotspot follow current display dimensions. Moving
updates the guest screenshot position without rebuilding the native shape.
Unconfigured/hidden guest cursors use the default Mac arrow. Window framebuffer
and direct Metal presentation omit the cursor; exported PNGs and raw frame dumps
compose it over both 2D and Venus scanouts. The standard cursor queue uses only
an outgoing descriptor and completes without a response, as QEMU requires.

Tests use an asymmetric custom alpha shape, nonzero hotspot, 1x/2x, shape change,
hide/show, GUI exit, and canvas assertions proving no software pointer remains.
The standard QEMU virt virtio-gpu UPDATE/MOVE/hide sequence also passes. Native
CPU 1x / Venus 2x windows passed cursor-change/default restoration checks
(`build/cursor-native-test.log`). `make -j test` passed (exit 0;
`build/cursor-full-test.log`). Artifacts are under `build/gui-cursor-test/`
and `build/gui-cursor-qemu-test/`.

### G5 — complete

`GuiVulkanPresent(device, view, physical_width, physical_height, mirror, stride)`
publishes an app-owned sampled image in `SHADER_READ_ONLY_OPTIMAL` after its
producer fence has completed. It validates the calling task's pixel window,
the resident display device and current physical client size. Applications own
the image/view, render commands and fences; the compositor owns only a borrowed
image descriptor. Direct image rectangles and a transparent BGRA HUD/chrome
texture compose in window Z order. Scene pixels do not pass through the window
raster upload. `GuiVulkanDetach` ends the borrow before the producer destroys a
view. Window resize invalidates the old publication and asks the app to repaint.

An optional physical BGRA mirror supplies the CPU path. Cube retains readback
for this fallback/verification, draws its HUD into a separate transparent layer,
and now uses direct Vulkan by default in `GuiCube;`. `CubeWindow(0, FALSE)`
provides the former readback window path for comparison. Other producers may
omit the mirror to avoid readback; CPU composition then has a white client
background with the overlay. This first API shares the resident Venus display
device/queue and runs structural/presentation operations on core 0.

Completed producer/compositor fences serialize publication and view replacement
on core 0. Cube installs an idempotent task exit hook to reclaim its GPU resources
on abrupt kill. The compositor retains closing windows until the owner is reaped,
and GUI exit waits for producer cleanup before freeing surfaces. Texture slots
track the monotonic window id as well as its address, including address reuse.
Consecutive Ctrl+Alt+Tab keys now change focus immediately in input order.

Acceptance compares the complete Cube frame/client/HUD for direct Vulkan,
readback uploads and CPU mirrors at both 1x and 2x. It also covers concurrent
Vulkan windows, camera/move/resize, abrupt kill, server close, application quit,
GUI exit, and return to the original mapped GPU-buffer count. Odd physical screen
sizes at 2x include the last partial logical pixel; tests compare a Vulkan client
clipped at both right/bottom screen edges. Screenshots were visually reviewed.
Artifacts: `build/gui-vulkan-test/`. `make -j test` passed (exit 0;
`build/g5-test.log`).


### Post-G5 Warm toolchain integration and input backlog — complete

Merged `main` Warm CLI/toolchain isolation (`bfbd7f5`); CoolOS kernel bindings
now live in `os/Warm/`, while portable OS.Gui remains in the standard library.
The Warm terminal-application integration section and all GUI stages are kept.

The reported 63-of-80 key failure was reproduced on both CPU and Venus with a
single 80-key raw-input backlog, waiting for completed presentation before VM
shutdown. The 64-slot window event ring has 63 usable entries; the compositor
pumped the complete source backlog before a consumer could run, dropped 17 keys,
and reported `KEY_INPUT_LOST`. Reproduction log: `build/burst-repro.log`.

Window event capacity now matches the 1024-slot raw-input ring. The compositor
yields to notified pixel-window producers before synchronous GPU composition,
so they drain input and paint before the frame. Actual overflow remains explicit.
The drawing demo reports lost input and acknowledges completed presentation.
Its regression test covers both 80 host keys and a deterministic 80-key queued
backlog with five windows, all 160 responses, no loss, CPU/Venus pixel equality,
and the existing 100 ms dispatch/burst bounds. Tests wait for every response and
completed presentation before exiting. Acceptance results are recorded below.

`make -j test` passed three consecutive times on the same implementation (exit
0 each), including the merged Warm CLI tests, G1–G5, hardware cursors and the
existing terminal applications. Each CPU/Venus drawing run delivered all 160
keys without overflow and satisfied both the 100 ms event-age and burst bounds.

| Full suite run / log | CPU host / queued burst | Venus host / queued burst |
| --- | --- | --- |
| `build/post-g5-test-1.log` | 67 / 13 ms | 48 / 8 ms |
| `build/post-g5-test-2.log` | 58 / 15 ms | 52 / 11 ms |
| `build/post-g5-test-3.log` | 77 / 13 ms | 64 / 10 ms |

### Atomic pixel-window frames

Pixel windows now have a committed front buffer (`CGuiWindow.pixels`) and a
producer back buffer. `GrRect`, `GrLine`, `GrText`, `GrBlit`, `GrDither`, direct
`GrPixels` writes and the `OS.Gui` widgets all draw into the back buffer.
Drawing accumulates a clipped logical dirty bounding rectangle without changing
compositor damage or the front revision. `GuiPresent()` / `OS.Gui.present`
copies only that rectangle's scaled rows into the front, then increments the
revision and adds desktop damage. An unchanged present is a no-op. Present
commits a frame; it does not wait for display scanout.

For existing applications, `GuiPoll` (including `OS.Gui.poll` and the examples'
`nextEvent`) automatically presents before returning an event or Idle. Finish
all drawing before the next poll, or call present explicitly before sleeping.
Sleeping between clear and repaint does not publish the unfinished scene.
`GrPixels` returns physical BGRA back-buffer storage with a byte stride; call
`GrDirty` for every directly modified region, then present. A resize/scale change
replaces both buffers, discards pending drawing and invalidates old pixel
pointers; handle Resize by repainting. Both buffers use ordinary `MAlloc`, so
large windows can use the virtually contiguous large-allocation region without
requiring physically contiguous memory. Both are released on resize and close.

Pixel drawing/present are owner-task operations on core 0. Its scheduler is
cooperative, and the dirty copy never yields, so front publication cannot
interleave with composition. CPU composition and Venus window-texture uploads
read only the committed front. Chrome remains compositor-owned.
`GuiVulkanPresent` also commits the staged BGRA overlay together with the
fence-completed sampled image and optional CPU mirror.

Files, Top, Settings and Widgets present completed paints explicitly and query
`buttonNeedsRedraw`, `listNeedsRedraw` and `textInputNeedsRedraw` before painting.
These detect activation, selection/scrolling, focus/caret/editing and pressed
state changes; passive pointer motion and an unchanged held button do not
repaint. List selection is resolved before drawing rows, so the previous
selection is erased in the same frame without needing a release-event repaint.
The current widgets have no separate hover artwork. Top retains its
periodic sample refresh; Files caches its item count between content changes.

`make gui-present-test` captures every submitted framebuffer via
`COOLVM_FRAMES`, including Venus scanout snapshots. It deliberately yields eight
times after clearing, forces composition during the delay and checks that every
visible client remains a complete scene with text and Open/Up buttons. CPU and
Venus run at 1x and 2x, covering explicit and automatic poll present, unchanged
present and clipped sparse direct-pixel damage. `make gui-redraw-test` checks all
four examples: pointer traffic leaves the front revision unchanged, press and
release repaint, and held motion without a state change does not. Artifacts
are under `build/gui-present-test/` and `build/gui-redraw-test/`.

Validation: `make -j test` exited 0 on 2026-10-01, including the existing GUI,
Vulkan, cursor, scale, Warm, kernel and QEMU tests. Full log:
`build/gui-buffer-full-test-2.log`. The first full run hit the existing G2
100 ms key-burst ceiling (134 ms); the final run passed unchanged limits
(CPU 63/12 ms and Venus 54/13 ms for the host/queued bursts). Each new
1x/2x CPU/Venus frame run inspected 57 complete client frames with no cleared
intermediate scene.

### Files latency, normalized wheel input, and one initial shell

Measured and fixed on top of main's Stage 7 plus small-function inlining / callee-first emission merge (`c11ce30`), using the same
Warm/Cool compiler for both versions. No compiler source or vendor file was
edited. `Gui;` now opens one shell; Ctrl+Alt+N and the System menu still open
more. Existing GUI scenarios explicitly call `GuiShell;` for their second
shell, retaining geometry, five-window, pixel, cursor and lifecycle assertions.
The QEMU cursor probe also explicitly creates its second shell.

**Host input.** `scrollWheel:` previously truncated every event separately.
The shared native/test accumulator now sends signed **lines** in REL_WHEEL
(code 8) and REL_HWHEEL (code 6). One line is 20 AppKit view points: precise
input and the line height are converted to backing pixels together, so Retina
scale does not change speed. Ordinary mouse-wheel deltas already use lines.
Both axes retain signed fractional remainders. Ended events do not discard the
remainder before momentum begins; momentum changes/end are accumulated normally,
and cancellation clears the remainder. Switching between precise/nonprecise
units also clears it. The SDK NSEvent.h documents precise deltas in points and nonprecise deltas
scaled by row height. No zero wheel/SYN records are sent. OS.Gui's current
Mouse event exposes the vertical axis; horizontal REL_HWHEEL is emitted by the
host but is not yet exposed as a toolkit horizontal scrolling control.

`make host-scroll-test` reproduces the loss: 100 deltas of 0.2 points, half in
momentum, produced **0** using the old cast and **1 line** with accumulation.
It also checks backing scales 1/2, positive/negative wheel lines, horizontal
remainders, cancellation and nonfinite synthetic input.

**Files and toolkit.** FAT directory enumeration dominated input handling;
the old path reread the directory twice on every repaint and rebuilt titles.
Files now owns cached names, directory flags and display titles, reads a
new path once, and filters an index array in memory. Failed navigation and Up
at the root do not reread unchanged content. Only the eleven visible rows are
visited on a scroll. Scroll/selection redraw the list rectangle; buttons, input,
item count and preview redraw independently. Navigation/resize repaint the
complete client. The unconditional 10 ms sleep after every event is gone;
only Idle sleeps (1 ms, interruptible by task wake).

OS.Gui folds queued consecutive mouse motion and same-direction wheel records
into the last position and summed wheel delta. It preserves button edges,
keys, resize, menu/close events and wheel direction changes, including reversal
at a clamped list boundary. Thumb hit mapping uses the same travel as thumb
painting; held-motion bursts reach the last drag position. Selection uses the
post-scroll first row when a record contains both button and wheel input.

Cold opening also parsed/emitted unrelated modules. The installer now generates
`GuiFilesModules.txt` with Files' transitive imports; older disks fall back to
`GuiModules.txt`. Compiler implementations remain unchanged.

**Method.** (Retired in U5, when Files was rewritten on OS.Ui; `tools/ui-test.py`
stage U5 measures the new Files.) `tools/gui-files-test.py` installed an isolated disk with 160 tiny
files plus the production directory tree, bitmap font, 800x600 at 1x. Cold
launch uses the real `GuiFiles`/guest WarmRun path. A test-only copy of the
generated compiler package times parse/file loading, checking and emission.
For event measurements, the same host Warm compiler emits instrumented copies
of Files/OS.Gui to Cool, run by the guest shell with the production kernel
adapters. CNTVCT brackets app work, widget bodies, Gr operations/text, directory
listing/stat/file reads and present; a `gui.compose_ticks` counter brackets the
CPU/Venus compositor. A sentinel key acknowledged at the end of the app loop
ensures that the whole burst, including prefetched events, has finished.
End-to-end time waits for the committed revision to be composited. These are
elapsed times, not host CPU time or physical display scanout latency. Profile reports
are outside measured work. Existing app markers remain in the Warm residual.
Widget timing subtracts nested Gr calls; Warm app/string time is the residual
after IO, widgets, drawing, poll and present. Cold startup and event work are separated
so shell/compiler setup cannot be mistaken for row rendering.

CPU measurements in milliseconds (before → after):

| Operation | App + poll + present | Input → composed | Directory listings |
| --- | ---: | ---: | ---: |
| First app frame (excluding compiler setup) | 9.883 → 5.255 | 373.021 → 378.056 | 2 → 1 |
| One wheel line | 8.461 → 0.088 | 18.662 → 7.782 | 2 → 0 |
| 100 queued wheel ticks | 874.986 → 0.085 | 1801.679 → 8.675 | 200 → 0 |
| List click | 8.421 → 0.164 | 28.607 → 8.698 | 2 → 0 |
| One filter key | 8.704 → 0.170 | 19.002 → 9.081 | 2 → 0 |
| Open Kernel directory (press/release) | 37.051 → 12.053 | 61.238 → 17.109 | 6 → 1 |
| Up to root (press/release) | 40.813 → 4.212 | 64.685 → 8.676 | 6 → 1 |
| 32 held drag motions | 279.153 → 0.157 | 596.446 → 8.539 | 64 → 0 |
| Open file preview (press/release) | 22.817 → 5.906 | 42.999 → 8.993 | 4 → 0 |

The first-frame “input → composed” column includes the instrumented Cool
package's shell/JIT setup; use the cold-launch table below for actual GuiFiles
startup. Layer breakdown after the fix (CPU, ms; exclusive widget timing,
Warm/string residual estimates; composition is a separate task):

| Operation | Warm app / strings | OS.Gui widgets | Gr shapes / adapters | Gr text / measure | Directory / file IO | Present | Poll / coalesce | Compose |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| One wheel line | 0.003 | 0.004 | 0.042 | 0.029 | 0.000 | 0.008 | 0.003 | 0.128 |
| 100 queued wheel ticks | <0.002 | 0.002 | 0.042 | 0.026 | 0.000 | 0.007 | 0.009 | 0.098 |
| List click | 0.087 | 0.002 | 0.040 | 0.026 | 0.000 | 0.007 | 0.003 | 0.091 |
| One filter key | 0.097 | 0.003 | 0.046 | 0.005 | 0.000 | 0.017 | 0.002 | 0.226 |
| Open Kernel directory (press/release) | 0.157 | 0.003 | 0.109 | 0.038 | 11.720 | 0.024 | 0.002 | 0.265 |
| Up to root (press/release) | 0.147 | 0.003 | 0.107 | 0.032 | 3.899 | 0.023 | 0.001 | 0.239 |
| Open file preview (press/release) | 0.098 | 0.001 | 0.017 | 0.005 | 5.773 | 0.010 | 0.001 | 0.126 |

Sub-2 µs residuals are shown as `<0.002`: separate timing brackets can differ
by about 1 µs.

Before, one wheel line spent 8.198 ms in IO out of 8.461 ms total; shapes/text/present were 0.090/0.032/0.028 ms. The costly repeated FAT work and sleep were the primary bottlenecks.

| Cold real GuiFiles launch | Before CPU / Venus | After CPU / Venus |
| --- | ---: | ---: |
| Launch → first composed app frame | 859.792 / 872.409 | 618.731 / 639.991 |
| Warm parse + input file loading | 476.392 / 477.369 | 230.552 / 230.610 |
| Warm resolution / type / linearity checks | 13.810 / 12.382 | 10.018 / 14.102 |
| Warm code emission | 7.452 / 9.918 | 11.123 / 23.528 |

Cold launch still costs about 0.6 seconds for shell/compiler setup and parsing;
the compiler startup cost remains visible. Cached clicks/keys/wheel react
within one frame; directory navigation needs its one FAT read. The measured
Open operation was about 17–18 ms end to end, with about 12 ms app/IO work.
Compiler optimizations beyond the merged main were outside this change.

Venus confirms the same behavior: one wheel line and the 100-tick burst use
about 0.08–0.09 ms of app/poll/present work and about 9 ms input-to-compose;
click/filter stay around one frame. Its per-layer JSON is recorded alongside
CPU results in `build/gui-files-test/{before-merged,after-merged}/{cpu,venus}/`, with logs and
screenshots; cold timings have separate `cold.json` files. Reproduction:

```
python3 tools/gui-files-test.py build/kernel.Image --label before-merged --baseline --venus
python3 tools/gui-files-test.py build/kernel.Image --label after-merged --venus
make host-scroll-test gui-files-test
```

Regression assertions check first row 1 after a single negative line and 101
after the following 100 ticks, exactly one burst paint, zero directory reads
for cached input, exact list-only damage `(12,78)-(256,300)`, final scrollbar
position after 32 motions, ordered reversal at the bottom boundary, all filter
keys, folder/parent navigation and file preview. CPU and Venus have strict
16 ms app-processing and 50 ms input-to-compose bounds for cached events.
For navigation/file reads the test separately bounds non-IO work to 16 ms and
allows a 1 s load bound: disk IO can be descheduled by concurrent VMs during
`make -j test` (one run observed 128 ms in the disk read). This allowance does
not relax the wheel burst or cached click/key bounds.

Validation (2026-10-01), after merging main `c11ce30`: `make -j test`
exited **0**; full log:
`build/gui-scroll-main-full-test.log`. CPU/Venus Files, G1–G5, cursor/QEMU,
Warm Stage 7, Cool inlining, terminal apps and kernel rebuild tests all passed. The unchanged
G2 bounds passed with CPU 31/20 ms and Venus 51/12 ms for the host/queued
key bursts. Earlier runs exposed the QEMU probe's two-shell assumption (fixed by
explicit GuiShell) and existing loaded-suite G2/Tmux timing failures; the final
full run passed all assertions. Isolated before/after logs:
`build/gui-files-before-merged.log`, `build/gui-files-after-merged.log`.
No changes were pushed.

### OS.Ui — the declarative framework

Above the immediate-mode OS.Gui sits OS.Ui (U1 to U5): an application keeps a
model, describes the window from it, and changes it with messages. The menus,
dialogs, tables, text fields, Files, Top, Settings and the Gallery are built on
it. Its design, measurements and screenshots are in
[ui-framework.md](ui-framework.md); `tools/ui-test.py` is its VM acceptance test.


### Resize acceptance under concurrent load

`tools/gui-resize-test.py` captures CPU/Venus frames headlessly at 1x and 2x.
Each mouse operation queues Ctrl+Alt+P after its input and waits for the
compositor's screenshot completion counter before checking geometry or saving
a reference. Display PASS markers follow that completed capture, so the host
can issue the next mode change or quit without a fixed settling delay. Gallery
repaint readiness is checked using its status-bar rule in the newly exposed
client area. The delayed pixel-app repaint and 1 ms display-event burst remain
intentional test stimuli.

The reported `cpu-1x-desktop: menu width` failure was a clock-dependent oracle,
not a delayed mode change. The archived host PNG and guest R14.BMP both contain
the complete 905x665 desktop. Pixel (880,10) intersects the minute digit in the
13:48 clock and is black; the test now samples the blank right margin (903,10)
and the menu's bottom rule (903,21). Raw scanout checks still reject incomplete
menu edges, incomplete desktop pixels, and white or partial client frames.


Validation (2026-10-02): ten consecutive runs with three background headless GUI
VMs (two CPU and one Venus) and four CPU workers passed without retries: all
80 CPU/Venus, 1x/2x pixel/desktop scenarios. The background processes stayed
alive throughout every run. Load driver and per-run logs:
`build/gui-resize-load.py`, `build/gui-resize-load/`, `build/gui-resize-load.log`.
