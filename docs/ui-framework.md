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

The test requires the median within one frame (16 ms) and every sample within
50 ms: `make -j test` runs many VMs on fewer host cores and the guest counter
keeps running while a VM is descheduled (the same policy as `gui-files-test`).
The Venus maxima above are single samples from a loaded host.

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
