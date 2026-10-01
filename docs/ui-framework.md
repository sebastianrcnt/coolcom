# OS.Ui: the declarative UI framework

Status: design decisions are recorded per stage before that stage is
implemented. Each decision lists the options considered and the choice.
Results and measurements follow each stage.

`OS.Ui` is the application framework for coolcom's GUI. Applications are written
in Warm in the Elm/iced style: a **Model**, a **Msg** union, `update(model, msg):
Model` and `view(&model): View[Msg]`. The framework does layout, painting,
damage-limited redraw, focus and keyboard handling, hit testing, and turns
input into `Msg` values. The immediate-mode `OS.Gui` stays the low-level layer
(Cube, the drawing demo and existing games use it directly), and `OS.Ui` is
built on top of it. The look is classic Macintosh (System 1–7, one bit).

## Why messages instead of callbacks

Warm has linear types, borrowing and no general closures (`Fn[...]` values are
named functions that capture nothing). A retained widget object holding a
callback into application state would need a closure capturing a mutable
borrow of the model, which Warm deliberately cannot express. Messages are plain
values: a button carries the `Msg` to send, a slider carries a named function
`Fn[Int64, Msg]` that wraps the new value. The model stays owned by the
application's loop and is changed only by `update`.

## Overall architecture (decided before U1)

### A1. Shape of the view tree

- **Option A: a recursive union** `View[M]` with `Vector[View[M]]` children,
  built by nested expressions. Warm has no list literals or varargs, so every
  container needs explicit `push` calls anyway; each node is a separate heap
  allocation, and dropping the tree means a recursive linear destructor.
- **Option B: a flat, builder-filled tree.** `View[M]` is one linear value that
  owns a node array, one byte arena for all text, and a handler array.
  `view` creates it and fills it with calls such as `column(&!v)`,
  `label(&!v, "Name")`, `button(&!v, "OK", Save())`, `end(&!v)`. Modifiers apply
  to the most recent node (`grow(&!v, 1)`, `width(&!v, 80)`, `disabled(&!v)`).
- **Option C: retained widget objects** mutated by the application. Rejected by
  the brief (callbacks, ownership).

**Choice: B.** `view(&model): View[Msg]` keeps the requested signature and
remains declarative (the whole UI is described from the model every time), but
the representation is flat: no per-node allocation, no recursive drop, cheap
comparison with the previous frame, and nodes are Free records that layout and
painting index directly. Components are ordinary functions that append nodes,
generic over the message type. (A side result: the Warm emitter now forward-
declares classes, so recursive generic unions also compile; see U1 results.)

### A2. Message type and handlers

- **Linear `Msg`** would let messages own Strings, but a constant message stored
  in a button would have to be moved out exactly once and unused messages could
  not be dropped without a destructor protocol.
- **Free `Msg`** can be stored in nodes and copied when an event fires.

**Choice: `M: Free`.** Handlers are stored in a side array: a constant `M`
(button, checkbox, radio, menu item, shortcut, timer) or a named function
(`Fn[Int64, M]` for sliders and selections, `Fn[TextEdit, M]` for text). Text
changes are described by a Free `TextEdit` (replace a byte range with a
codepoint, delete, or paste the clipboard snapshot whose serial the edit
carries); the model applies it with `OS.Ui.Text.applyEdit` to the String it
owns. Text never has to travel inside a message.

### A3. Who owns the loop

- **`run(init, update, view)`** with function values: `view` takes `&[Model, R]`,
  and a function value cannot be generic over the region of a borrow made inside
  the framework. It only type-checks with an explicit `Static` assertion at the
  call site, which also relies on a loophole for borrowing a local at a named
  outer region. Rejected.
- **An application-driven loop** around one framework call:

```
var app: App[Msg] := openApp(&!gui, "Counter", 320, 200);
var model: Model := initial();
var running: Bool := true;
while running do
    case next(&!app, view(&model)) of
        when Some(value as msg: Msg) do model := update(model, msg);
        when None do running := false;          -- the window was closed
    end case;
end while;
closeApp(app);
```

**Choice: the application-driven loop.** `next` takes ownership of the new view,
lays it out, compares it with the previous one, paints only damaged regions,
presents, and then waits for input. Input that only changes framework state
(focus, a pressed button, the caret, a scroll position kept by the framework)
is handled inside `next` without calling back into the application. `next`
returns as soon as an event produces a message. Side effects stay explicit:
capabilities (`Dir`, `System`) live in the model and `update` uses them.

### A4. Where widget state lives

- **All in the model (pure Elm).** Every caret, pressed state and scroll offset
  would need a message case and model field; very verbose.
- **All in the framework (uncontrolled).** The model could not see values.
- **Split (iced/SwiftUI).** Values the application cares about (text, checked,
  slider value, selected row, sort order, tab index) are in the model and are
  passed into the view. Interaction details (focus, pressed/tracking state,
  caret and selection, horizontal text scroll, split position, scroll offsets
  of plain scroll views) are kept by the framework, keyed by node identity.

**Choice: split.** Virtual lists and tables are the exception that proves the
rule: their first visible row is in the model because the view must emit only
the visible rows (see U3).

### A5. Node identity

Identity is a 64-bit hash of the path from the root: each node hashes its
parent's identity, its kind and its ordinal among siblings of the same kind.
`key(&!v, "name")` replaces the ordinal with an explicit key, for state that
must follow an item that moves. Identity is computed after the view is built,
so `key` is an ordinary modifier.

### A6. Module layout

| Module | Role | Pure |
| --- | --- | --- |
| `OS.Ui.Text` | UTF-8 stepping, `TextEdit`, `applyEdit`, word and line boundaries | yes |
| `OS.Ui.Tree` | node records, the arena, builder primitives, identity, layout, hit testing, focus order, damage comparison, interaction state and input → action | yes |
| `OS.Ui.Draw` | the classic theme painter over an `OS.Gui` window: clip rectangles, patterns, frames, round rectangles, bold/dimmed text, inverted selections, 1-bit icons | no |
| `OS.Ui` | the public API: `View[M]`, `App[M]`, controls, `next`, generic over the message type | no |

The pure modules are tested on the host with `tools/warm`; drawing and the
loop are tested in the VM with screenshots, damage traces and latency samples.
Only `OS.Ui` is generic over `M`; the engine itself is monomorphic, which keeps
the generated code per application small.

## U1: foundation

### U1.1 Layout

- **Constraint/flexbox solver** with width-dependent heights in one pass —
  complex and hard to make exact.
- **Axis-separated layout:** (1) preferred widths bottom-up, (2) widths
  top-down, (3) preferred heights bottom-up with known widths, (4) heights and
  positions top-down. Height may depend on width (wrapped text) without
  iteration.

**Choice: axis-separated.** Containers are `row`, `column`, `grid(columns)` and
`split` (two panes and a draggable divider; the divider position is framework
state, initialised from the view). Containers have padding and spacing.
Every node has an optional fixed width/height, a minimum size, a `grow` weight
on its parent's main axis and an alignment on the cross axis
(`Start`/`Center`/`End`/`Fill`; a container's default applies to children that
do not set their own). `spacer` is an empty node with grow 1. Grid columns take
the widest preferred child; columns marked with `grow` share extra width.

### U1.2 Redraw only what changed

- **Repaint everything** on every message: simple, wasteful, and the time grows
  with the window.
- **Per-node dirty flags set by the application:** contradicts the declarative
  model.
- **Diff the new tree against the previous one.** After layout every node gets
  a 64-bit *visual hash* (kind, rectangle, text bytes, value, flags, and the
  framework state that affects its drawing: pressed, focused, caret, scroll).
  Nodes are matched by identity. A changed, new or vanished node damages its
  old and new rectangles. Damage is merged into at most a few rectangles; if
  it covers most of the window the whole window is repainted.

**Choice: diff.** Each damaged rectangle becomes the clip rectangle; the
framework repaints every node intersecting it in tree order (containers paint
their own background before their children, overlays last), then presents. The
kernel's present copies only the union of drawn rectangles to the front buffer,
and only that region is composed. All drawing goes to the back buffer and one
present per frame commits it, so there is no flicker.

A new kernel clip rectangle per window (`GrClip`) is honoured by every Gr
operation, so a damaged region can be repainted without touching neighbours.

### U1.3 Focus, Tab order and keyboard

Focusable nodes are visited in tree order; disabled nodes are skipped. Tab and
Shift+Tab move focus (wrapping). Clicking a text-like control (text box, text
view, list, table, tree) focuses it; clicking a button, checkbox, radio or
slider activates it without taking the focus away from a text field, as on the
Mac. Keyboard focus on non-text controls is drawn as a dotted (50% gray)
rectangle; text controls show the caret, lists a two-pixel frame (as in the
System 7 Standard File dialog).

Key routing order: an open modal overlay, then declared shortcuts
(`shortcut(&!v, key, modifiers, msg)`, matched on Ctrl/Alt chords), then Tab,
then Return/Escape for the default/cancel buttons (unless the focused control
consumes them), then the focused control.

### U1.4 Theme

Classic Mac, one bit, white window background. Text is the bitmap GNU Unifont
(16 px). The "system font" used for labels, buttons and titles is bitmap bold
(double struck, like the window titles); content (text fields, lists, tables,
text views) uses the regular face. Disabled text and frames are drawn through
a 50% gray mask, selections are inverted, gray areas use 8×8 patterns aligned
to window coordinates. Every one-pixel line is one logical pixel, which the
kernel scales by an integer, so 2x stays crisp.

### U1.5 Event coalescing

Three levels: `OS.Gui.poll` already folds motion and same-direction wheel
records; the engine handles every queued input event before painting (each
message still goes through `update`/`view`/layout, which is cheap), and paints
and presents once when the queue is empty; repeated wheel/motion messages that
produce the same state do not repaint at all (the diff is empty).
`WgPending` reports whether input is queued; `WgWait` blocks the task until an
event arrives or a timer (`every(&!v, ms, msg)`) is due, so idle apps use no CPU.

### U1.6 Measuring input latency

The kernel stamps every input record with the counter (`CNTVCT`) when the
interrupt queues it. A pixel window remembers the stamp of the oldest event it
has dequeued since its last present; present moves it to the presented
revision, and the compositor records `compose time − stamp` when it composes
that revision. `GuiLatency` prints the samples; VM tests assert the budget.

### U1 results

Implemented: `OS.Ui.Text`, `OS.Ui.Tree`, `OS.Ui.Engine`, `OS.Ui.Draw` and the
generic `OS.Ui` (`View[M]`, `App[M]`, `openApp`/`next`/`closeApp`, containers
`column`/`row`/`grid`/`split`/`group`, `spacer`, modifiers, `label`/`paragraph`,
`button` with default/cancel, `separator`, `shortcut`, `every`). The Gallery
example (`GuiGallery;`, also in the System menu) exercises them.

Kernel support: a per-window clip rectangle honoured by every Gr operation and
its damage (`GrClip`), `GrPattern`, `GrInvert`, `GrTextStyle` (bitmap bold,
50% dimming, underline; advances agree with the Warm text metrics), `GrBits`,
`GuiPending`/`GuiWait` (blocking wait for the window's queue), a prompt
compositor wake on present, input-to-composition latency samples
(`GuiLatency`, Ctrl+Alt+L) and test screenshots of the composed desktop
(`GuiShot`, Ctrl+Alt+P → `C:/Shots/NNN.BMP`). `gui.trace = 1;` makes OS.Ui print
`UI NODE` layout lines and `UI FRAME` damage lines.

Language/toolchain: Warm's emitter now forward-declares classes and defers the
body of a class that is first reached through a pointer, so recursive generic
unions (`union Tree[T] … Vector[Tree[T]]`) compile (regression in
`warmc/test_language.py`). Warm treats `Span!` as linear (passing it consumes
it), so the layout keeps node properties (read-only spans, shared freely) and
geometry (one write span threaded through each pass) in separate arrays.
GUI example apps now compile only their transitive imports
(`C:/<EntryModule>Modules.txt`, written by `tools/gui-modules.py --app`).

Tests: `warmc/test_ui.py` (host: layout of rows/columns/grids/splits, padding,
spacing, alignment, grow, wrapping, identity stability with and without keys,
key descriptions, damage merging, focus order, default/cancel/shortcut keys,
classic button tracking, frame comparison) and `tools/ui-test.py --stage U1`
(VM, CPU and Venus, 1x and 2x).

Measurements (`build/ui-u1/u1-results.json`, 2026-10-01, Gallery 420×360). The
latency phase has no screenshots (writing one stalls core 0, so Ctrl+Alt+P
discards the samples taken across it): three clicks, two Tabs, Space, Return,
Escape, Ctrl+R and a click. `GuiLatency` also splits the time: about 0.5 ms of
it is the application (update + view ≈ 0.15 ms, install + layout ≈ 0.2 ms,
compare + paint ≤ 0.3 ms), present → compositor wake about 2.6 ms, compose 0.2–
1.7 ms; the rest is input dispatch and scheduling on core 0.

| Session | Input → composed p50 / max (ms) | 31 queued keys: frames, latency (ms) | First full paint (ms) | Largest partial repaint (ms) |
| --- | ---: | ---: | ---: | ---: |
| CPU 1x | 4.6 / 13.5 | 1, 7.1 | 0.25 | 1.2 |
| CPU 2x | 1.5 / 9.1 | 1, 4.3 | 0.42 | 0.31 |
| Venus 1x | 9.0 / 24.0 | 1, 4.4 | 0.22 | 1.2 |
| Venus 2x | 6.9 / 18.5 | 1, 8.5 | 0.46 | 1.2 |

The budget is the median within one frame (16 ms), and the tables in this
document meet it. In the full suite, `make -j test` runs many VMs on fewer host
cores, and the guest counter keeps running while a VM is descheduled. The suite
therefore asserts a median under 20 ms (one 60 Hz frame plus 20% slack) and no
sample above 100 ms (a stall). Per-frame application work (update and view,
layout, paint) is still held to 16 ms. During the U5 full suite, a CPU 2x run
of the Gallery measured a median of 18.9 ms against about 12 ms in isolation. (U1 to U3 first allowed
50 ms; with about ten samples a run's maximum is one sample, and a single
descheduled VM exceeded it in the U4 full suite, at 57 ms, while isolated runs
stay below 25 ms.) The Venus maxima above are single samples from a loaded host.

A click on a button repaints the button and the two labels it changes
(`12,92,64,24 67,139,9,16 67,161,65,16`); timer ticks that change nothing
repaint nothing. Screenshots: `build/ui-u1/u1-<cpu|venus>-<1|2>x/shot-000.png`
(initial), `shot-001.png` (button held), `shot-002.png` (keyboard focus ring),
`shot-003.png` (split bar dragged). The 2x shots equal the 1x shots with every
pixel doubled; CPU and Venus shots are identical.

## U2: basic controls

### U2.1 Who owns the text of a text box

- **Framework-owned (uncontrolled) text**, read by the application through the
  App: `update` has no access to the App, so the model could not see it.
- **Messages that carry an owned String**: `Msg` would become linear, which A2
  rejected.
- **Edits.** The model owns a `String`; the view passes its bytes to
  `textBox(&!v, text, onEdit)`; every change arrives as a Free `TextEdit`
  (replace the byte range `[start, finish)` with one code point, with the
  clipboard, or with nothing) wrapped by the application's `Fn[TextEdit, Msg]`;
  `update` applies it with `applyEdit(text, edit): String`.

**Choice: edits.** The caret, the selection anchor and the horizontal scroll
offset are framework state (A4); after an edit the framework places the caret
after the inserted text. If `update` rejects or changes an edit, the next view
carries the actual text and the caret is clamped to it and to a code point
boundary. Copying a selection needs no message.

### U2.2 Clipboard

- **A capability object** passed to `update` for paste: every application
  with a text box would need it in its model.
- **Implicit reads** of the clipboard from `applyEdit`: hidden global input.
- **Snapshots named by a serial.** The kernel clipboard holds bytes and a
  serial number that grows with every copy. Copy and cut write the selection
  with the window's authority; a paste edit records the serial current at the
  keystroke, and `applyEdit` inserts the bytes of exactly that snapshot
  (nothing if the clipboard changed in between).

**Choice: serials.** The user's keystroke authorises the paste, and the edit
says which content. The kernel service (`ClipboardSet`, `ClipboardGet`,
`ClipboardSerial`) is shared with terminal windows in U4.

### U2.3 Hangul input

The kernel IME composes 2-beolsik syllables and rewrites the preedit by
queueing Backspace plus the new syllable. A text box that implements Backspace
(delete the previous code point, or the selection) and insertion correctly
therefore composes Hangul with no IME-specific state; typing over a selection
replaces it with the first jamo. The composing syllable is shown as ordinary
text, as in the terminal.

### U2.4 Controls

| Control | API | Message | Keyboard |
| --- | --- | --- | --- |
| Checkbox | `checkbox(&!v, title, checked, msg)` | `msg` on toggle (the model flips) | Space |
| Radio | `radio(&!v, title, selected, msg)` | `msg` when chosen | Space |
| Slider | `slider(&!v, value, low, high, step, onChange)` | `onChange(value)` live while dragging | arrows, Home/End, PageUp/PageDown |
| Progress | `progress(&!v, value, total)` (total <= 0: indeterminate) | none | none |
| Text box | `textBox(&!v, text, onEdit)`, `password(...)`, `placeholder(&!v, text)` | `onEdit(TextEdit)` | editing, selection, Ctrl+A/C/X/V |
| Image | `image(&!v, handle)` | none | none |

Checkboxes draw the classic box with an X (System 7), radios a circle with a
dot; both track the mouse like buttons (the box frame thickens while held) and
the whole title is clickable. The slider has a one-pixel rounded track and a
white rectangular thumb; clicking the track moves one page. The progress bar is
a framed black fill; indeterminate bars use a diagonal stripe pattern.

Images are registered once with the App (`oneBitImage`, `colorImage` → a Free
`Image` handle) so views never copy pixel data; built-in one-bit icons
(`iconFolder`, `iconDocument`, `iconNote`, `iconCaution`, `iconStop`) need no
registration. The pointer becomes an I-beam over editable text.

### U2 results

Implemented: `checkbox`, `radio`, `slider` (`Fn[Int64, Msg]`, live while
dragging, stepped, arrows/Home/End/PageUp/PageDown once focused by a click or
Tab), `progress` (determinate, or striped when the total is unknown),
`textBox`/`password`/`placeholder` with `applyEdit`, `image` with
`oneBitImage`/`colorImage` and the built-in `iconFolder`, `iconDocument`,
`iconNote`, `iconCaution`, `iconStop` (original one-bit art). Text boxes:
click to place the caret, drag to select, double click selects a word, triple
click everything; Left/Right (Ctrl: words), Home/End, Shift extends, Backspace/
Delete, Ctrl+A/C/X/V; the field scrolls horizontally to keep the caret
visible; password fields draw bullets and refuse copying. Side-by-side panels
(groups, columns, lists) now share their row's height.

Kernel: the clipboard service `Clip.cool` (`ClipboardSet`/`Get`/`Size`/
`Serial`, and `ClipboardCopy("text")`/`ClipboardText` for the shell; the
TempleOS DolDoc names `ClipCopy`/`ClipPaste` stay reserved), Warm adapters
`copyText`, `clipboardSerial`, `clipboardSize`, `clipboardText`, and a
per-window pointer shape: the focused window's I-beam over its text fields (a
shape set with `GuiPointerSet` is left alone). The host runtime keeps an
in-process clipboard.

The U1 checks moved to `warmc/examples/gui/UiCheck.warm` (a small framework
check app, launched with `GuiRun`), so the Gallery can grow. Host tests add
`applyEdit`, caret placement, typing, Backspace, selection, copy/cut/paste
actions, word selection, caret clamping, slider drag and keys, checkbox
toggling. The VM scenario (`--stage U2`) clicks a checkbox and a radio, drags
and steps the slider, types, selects, copies and pastes, types Hangul with
the kernel IME (Shift+Space, `gksrmf` → 한글), double-clicks a word, pastes
into the password field and measures typing latency.

| Session | Typing: input → composed p50 / max (ms) |
| --- | ---: |
| CPU 1x | 4.2 / 9.7 |
| CPU 2x | 4.0 / 9.0 |
| Venus 1x | 5.3 / 12.5 |
| Venus 2x | 2.9 / 12.3 |

Screenshots: `build/ui-u2/u2-<mode>-<scale>x/shot-000.png` (all controls at
rest), `shot-001.png` (Italic checked, Large chosen, slider moved),
`shot-002.png` (text field with an inverted selection), `shot-003.png`
(Hangul text and password bullets); `screen.png` shows the I-beam pointer.

## U3: data views

### U3.1 Virtual rows

- **Emit every row as nodes.** A 10,000-row table would be 10,000+ nodes to
  build, lay out and compare on every keystroke.
- **A row provider callback.** Without closures a provider cannot reach the
  model; with `Fn[Int64, Row]` it cannot either.
- **The model owns the scroll window.** A Free `ListState` (first visible row,
  selected row, rows that fit, sort column and direction) lives in the model.
  The view emits only the rows `[first, first + fit]`; scrolling, selection,
  sorting and size changes come back as `onState(ListState)` messages. When a
  layout leaves the list taller than the rows it was given (a resize), the
  framework sends the corrected state itself, so the next view fills it.

**Choice: model-owned scroll window.** Work per frame is proportional to the
visible rows (about 25), not to the row count; the application keeps its rows
in any structure and sorts an index vector when the sort column changes.

### U3.2 Controls

| Control | API | State | Messages |
| --- | --- | --- | --- |
| List | `listView(&!v, state, rowCount, onState)`, `listRow(&!v, index, text)` | `ListState` | `onState`, `onOpen(index)` (double click, Return) |
| Table | `tableView(...)`, `tableColumn(&!v, title, width, sortable)`, `tableRow(&!v, index)`, `cell(&!v, text)` | `ListState` (+ sort) | `onState`, `onOpen` |
| Tree | `treeView(...)`, `treeRow(&!v, index, depth, children, expanded, text)` | `ListState` over the visible (flattened) rows | `onState`, `onToggle(index)` |
| Scroll view | `scrollView(&!v)` … `done` | framework (offsets) | none |
| Text view | `textView(&!v, text, onEdit)`, `noWrap(&!v)` | framework (caret, selection, scroll) | `onEdit(TextEdit)` |

Rows are 18 pixels. The selected row is inverted; a focused list gets the
two-pixel System 7 frame. Scroll bars are 16 pixels: arrow boxes at both ends,
the 50% gray track and a white thumb sized to the visible fraction. The wheel
scrolls three rows a line; Up/Down/PageUp/PageDown/Home/End move the selection
and keep it visible. Table headers are a row of titles over one-pixel column
rules; clicking a sortable title sorts by it (again: reversed, a small
triangle marks the direction); dragging a rule resizes the column (widths are
framework state, initialised from the view). Tree rows indent 16 pixels a
level and show a classic disclosure triangle (right: collapsed, down:
expanded); clicking it or Right/Left toggles.

Scroll views lay their content out at its preferred height and clip it to the
viewport; Tab focus scrolls the focused control into view. Text views edit
like text boxes, plus Up/Down (keeping the column), PageUp/PageDown and
Return (a newline); lines wrap at the width unless `noWrap` (then a
horizontal offset follows the caret). Line starts are found by one scan per
frame, so a 100 KB text stays interactive.

### U3.3 Test application

The Gallery window is full; U3 adds `warmc/examples/gui/UiData.warm` with a
10,000-row sortable table, a list, a tree and a text view (U4's tabs bring
them into the Gallery). Its VM test scrolls the table with wheel bursts and
keys and asserts every frame of a scroll stays within one 16 ms frame.

### U3 results

Implemented as designed: `listView`/`listRow` (with `rowIcon`), `tableView`/
`tableColumn`/`tableRow`/`cell`, `treeView`/`treeRow` with `onToggle`,
`onOpen`, `scrollView`, `textView`/`noWrap`, and `listState()`. Only the
visible rows exist as nodes: the 10,000-row table builds about 100 nodes a
frame. The test application `UiData` sorts an index vector when the sort
column changes.

Two latency findings, both fixed. First, the `UI NODE` trace (every node of
every new layout) cost about 15 ms a frame while scrolling, because each scroll
step is a new layout. Node traces are now level 2 (`gui.trace=2`, used only by
the tests' layout phase); level 1 keeps the per-frame `UI FRAME`/`UI CYCLE`
lines. Second, a wake sent to the compositor while it was still composing was
lost, so the compositor slept a full period. A present now sets a sticky flag
that skips the next sleep, and `GuiWait` wakes the compositor when the
window's last frame has not been composed yet (a present made while input was
still queued does not wake it).

| Session | Wheel scrolling, 40 lines 20 ms apart: p50 / max (ms) | Table keys p50 / max (ms) | Worst paint / layout / update+view (ms) |
| --- | ---: | ---: | ---: |
| CPU 1x | 6.9 / 9.8 | 6.5 / 9.5 | 2.9 / 2.0 / 3.5 |
| CPU 2x | 9.2 / 12.7 | 11.0 / 15.1 | 4.7 / 2.0 / 3.2 |
| Venus 1x | 8.0 / 11.0 | 9.9 / 12.4 | 2.4 / 2.9 / 2.7 |
| Venus 2x | 10.7 / 15.1 | 7.8 / 13.7 | 3.5 / 1.7 / 2.8 |

Every one of the 40 scroll steps produced its own frame. The scroll bar thumb
dragged to the bottom reaches row 9,984, and header clicks sort ascending and
then descending. Screenshots: `build/ui-u3/u3-<mode>-<scale>x/shot-000.png`
(table, list, tree and text view), `shot-001.png` (sorted by size descending,
Name column widened, first row selected), `shot-002.png` (tree expanded two
levels, list scrolled, text view with a selection).

## U4: window level

### U4.1 Menus

- **Menus drawn by the framework inside the client area**: every window would
  carry its own bar, unlike the rest of the desktop and unlike the Mac.
- **Menus as an App call** (`setMenus(...)` once): they could not follow the
  model (checked items, disabled items).
- **Menus are part of the view.** `menu(&!v, "File")`, `menuItem(&!v, title,
  keys, msg)`, `menuSeparator`, `checkMark(&!v, on)`, `disabled(&!v, on)` …
  `done`. After each view the App hashes the menu part of the tree and, when
  it changed, reinstalls the window's menus in the kernel's menu bar
  (`GuiMenuReset`, then one entry per item with its shortcut text and flags).
  A chosen item comes back as a menu event carrying the item's ordinal; the
  App maps it to that item's message. Shortcuts given to `menuItem` are also
  registered like `shortcut`, so Ctrl+S works whether or not the menu is open.

**Choice: menus in the view, shown by the kernel's menu bar.** The kernel menu
bar gains shortcut text (Ctrl/Alt/Shift shown as the Mac's ⌃ ⌥ ⇧ symbols),
separators, disabled (gray) and checked items, and a drop shadow.

### U4.2 Pop-up menus and context menus

A pop-up list must draw over everything, including outside the window, so it
is a kernel overlay (`GuiPopupClear`/`GuiPopupItem`/`GuiPopupShow`) that
reports the chosen index as a menu event with a reserved id. `popupButton(&!v,
selected, onChoose)` with `popupItem` children shows the selected title in a
shadowed box with a triangle and opens the list over itself, the selected item
under the pointer. `contextMenu(&!v)` … `done` attaches items to the enclosing
node; a right click on it (or anything inside it) opens them at the pointer.

### U4.3 Dialogs

- **Separate kernel windows for dialogs**: a second window needs its own App,
  event loop and focus handling, and the parent could keep receiving input.
- **Dialogs are part of the view.** `dialog(&!v)` … `done` (or the `alert` and
  `confirm` helpers) is laid out centred over the window content with the
  classic double frame. While a dialog is present it is modal: clicks outside
  it, menu-bar items and shortcuts outside it are ignored, Tab stays inside it,
  Return presses its default button and Escape its cancel button.

**Choice: in-window modal dialogs.** The model decides when a dialog shows
(a field in the model), so dismissing it is an ordinary message.

File dialogs need directory access, which views do not have. They are a
component: `OS.Ui.Files` (`FileDialog` in the model, holding a `Dir`
capability; `fileDialogView`, `updateFileDialog(dialog, FileEvent)`,
`fileDialogOutcome`, `chosenPath`). Its messages are one Free `FileEvent`
union wrapped by the application's `Fn[FileEvent, Msg]`, so the application's
`Msg` needs one case for the whole dialog. Open lists the directory (folders
first) with Up and Open/Cancel; Save adds a name field.

### U4.4 Tabs, toolbar and status bar

`tabs(&!v, selected, onSelect)` with `tab(&!v, title)` … `done` pages: the
view builds every page (cheap, A1), the framework lays out and paints only the
selected one and hides the rest from focus. Tabs are the classic rounded
folder tabs over a framed page. `toolbar` and `statusBar` are rows with a
rule below (toolbar) or above (status bar) and the window's full width.

### U4.5 System clipboard and terminals

The U2 clipboard service becomes the system clipboard: dragging in a terminal
window selects cells (inverted) and releasing copies them, as UTF-8 text with
trailing blanks dropped, and Ctrl+Alt+V types the clipboard into the focused
terminal. Text copied in an OS.Ui window pastes in a terminal and the reverse.

### U4.6 Drag and drop within a window

- **Typed payloads** (`draggable(&!v, payload: M)`): a second message type
  per drag.
- **An Int64 payload.** `draggable(&!v, id)` marks a node; `dropTarget(&!v,
  onDrop: Fn[Drop, M])` marks a container. A press on a draggable node that is
  not itself a control and a move of four pixels starts a drag: a gray outline
  of the node follows the pointer, the target under the pointer is highlighted,
  and releasing over a target sends `onDrop(Drop(payload, x, y))` (the
  position inside the target). Releasing anywhere else cancels.

**Choice: Int64 payloads.** The application knows what its ids mean.

### U4 results

Implemented as designed: menus in the view with shortcuts (`menu`,
`menuItem`, `menuSeparator`, `checkMark`, `disabled`), pop-up buttons and
context menus, in-window modal dialogs (`dialog`, `alert`, `confirm`), the
`OS.Ui.Files` open/save dialog component, tabs, toolbar, status bar, drag and
drop within a window, and the system clipboard shared with terminal windows
(drag to select cells, release to copy, Ctrl+Alt+V to paste). The Gallery
shows them all on four tabs.

Found and fixed while testing:
- The kernel menu's hit test used chained comparisons with function calls
  (`a <= f(k) < b`). The compiler did not evaluate these as ranges, so no
  click ever chose an item. It now uses explicit pairs.
- Unifont has no U+2713, so the check mark is drawn as pixels.
- Ctrl+Alt global keys (screenshots, latency reports) now work while a menu
  is open.
- A draggable label inside a tab page did not start a drag, because the tab
  container took the press. A drag now starts when the draggable node is
  inside the interactive one.
- An unchanged frame no longer calls present. OS.Ui ends the latency sample
  of input that changed nothing just before it waits, rather than between an
  event and the message that event produces.
- `tools/warm`'s import resolver rejected the legal interface cycle between
  OS.File and OS.Dir, so host checks of any app that browses folders failed.
- coolvm's scripted input feeder now waits for FIFO space instead of failing
  when the guest stops draining for a moment. This was the cause of earlier
  full-suite flakes (`input FIFO overflow` in kernel-test); a regression test
  is in `input-limits-test`.

| Session | Tabs, menus, clicks and shortcuts: p50 / max (ms) |
| --- | ---: |
| CPU 1x | 9.5 / 13.3 |
| CPU 2x | 14.9 / 16.3 |
| Venus 1x | 11.5 / 12.7 |
| Venus 2x | 15.3 / 27.0 |

At 2x a tab switch repaints the whole page: about 4.5 ms of painting, and
about 2 ms to compose. Screenshots are in `build/ui-u4/u4-<mode>-<scale>x/`:
- `shot-000.png`: the Controls page with the menu bar, toolbar and status bar.
- `shot-001.png`: the View menu with check marks.
- `shot-002.png`: the Edit menu with shortcuts, a separator and a disabled item.
- `shot-003.png`: the Data tab.
- `shot-004.png`: dragging over the highlighted basket.
- `shot-005.png`: after the drop.
- `shot-006.png`: an alert.
- `shot-007.png`: a pop-up list.
- `shot-008.png`: the Save dialog.

## U5: the desktop applications

### U5.1 Files

- **Keep the immediate-mode Files and add a separate OS.Ui browser**: two
  file browsers, and the one people open would not show the framework.
- **Rewrite Files on OS.Ui.** The model holds the folder (a read-only `Dir`
  capability and its path), the listing (names, sizes, folder flags; read once
  per folder), the filter text, a sorted index vector and the table's
  `ListState`. The view is a toolbar (Up, the path, a filter field), a table
  (Name, Size, Kind; sortable by any column) beside a preview, and a status
  bar with the item count. Return or a double click opens a folder or
  previews a file; Up goes to the parent. Typing in the filter re-filters the
  cached listing; only the visible rows become nodes, so a folder of 10,000
  files costs the same per frame as one of 10.

**Choice: rewrite.** The old app's profiling test (`gui-files-test`) measured
the immediate-mode redraw paths it no longer has; the U5 ui-test stage
measures input-to-composition latency of Files with 10,000 rows instead.

### U5.2 Top and Settings

Top becomes a table of tasks (Task, ID, Core, CPU %, State) refreshed by a
one-second timer, with Kill asking for confirmation in a dialog. Settings
becomes two radio groups (display scale 1x/2x; terminal font Bitmap/System
Mono) with a status line. Both keep their test markers (`GUI TOP READY`,
`GUI SETTINGS SCALE2`, ...).

### U5.3 Reference pages

OS.Ui gets an interface file (`Ui.warmh`) with a comment for every public
builder, so `tools/warm-man.py` generates its manual page from the interface
like the other OS modules with headers.

### U5 results

Files, Top and Settings are OS.Ui applications (`warmc/examples/gui/`). The
System menu starts them directly, and the shared immediate-mode helper module
(`Support.warm`) and the old Files profiler are gone. Files keeps the sorted
order of the whole folder; a filter keystroke only filters it again, and the
merge sort runs once per folder or sort change. Toolbar: Up, Open (the
default button), Reload and a filter field. File menu: Open (Ctrl+O),
Enclosing Folder (Ctrl+U), Reload (Ctrl+R), Close (Ctrl+W). View menu: sort
by name, size or kind. OS.Gui gains `displayScale` and `systemMonoFont`, so
Settings shows the current choices. OS.Ui now has an interface file (`Ui.warmh`,
86 documented functions), and its manual page is generated from it.

GUI applications used far more memory than before: every running app held
about 440 MB, so a third app ran out of the 1 GB VM and crashed. The cause was
the Warm compiler's unit (sources, syntax trees, types and generated text),
which stayed alive until the program returned. `WarmCompile` now frees it
before running the program; a running app holds about 85 MB.

Moving a list's selection used to repaint the whole list, because the list
node's visual hash included the selected row. Rows and cells now carry their own
selected state, so a key repaints two rows: 1.4 ms instead of 4.7 ms of painting
at Venus 2x.

Files with a folder of 10,000 files (`C:/BIG`, ui-test stage U5). The browse
phase is clicks on rows, arrow keys, End and Home, and ten wheel lines:

| Session | Browse: p50 / max (ms), samples | Sort by size (update + view + layout + paint, ms) |
| --- | ---: | ---: |
| CPU 1x | 6.7 / 8.3, 18 | 6.9 |
| CPU 2x | 11.2 / 15.4, 19 | 4.5 |
| Venus 1x | 9.2 / 11.2, 19 | 7.1 |
| Venus 2x | 13.6 / 14.4, 18 | 4.5 |

Screenshots are in `build/ui-u5/u5-<mode>-<scale>x/`:
- `shot-000.png`: Files at C:/.
- `shot-001.png`: the 10,000-file folder.
- `shot-002.png`: scrolled.
- `shot-003.png`: sorted by size.
- `shot-004.png`: Top.
- `shot-005.png`: Settings.

`gui-apps-test` and `gui-redraw-test` drive the new applications.

## Known gaps

- A Warm program's compiled code and symbols are never unloaded: every app
  launch keeps about 68 MB after the app closes.
- Sorting keeps the selected row number rather than the selected file.
- Files' preview is a text view whose edits are ignored, not a read-only view.
- At 2x, a change that repaints a whole page (a tab switch) takes 11 to 15 ms
  from input to composed frame: inside the 16 ms budget, with little room.
- Venus composes and reads back the whole frame. Uploading only the damaged
  rows would make it faster.
- Drag and drop works within one window and carries Int64 payloads.
- A window has at most 8 menus of 24 items (the kernel's fixed tables).
- When a press and its release reach the screen in the same composed frame,
  the kernel records one latency sample for both.
