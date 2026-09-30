# Terminals and Tmux

Run `Tmux;` at the Cool shell. `Init.cool` loads it automatically from C:.
Install updated disk programs with `make disk-install` before using an existing
persistent disk (`make run` only adds files that are missing).

All commands below follow **Ctrl+B**:

| Key | Action |
| --- | --- |
| `%` | Split the selected pane left/right |
| `"` | Split the selected pane top/bottom |
| arrows | Select the adjacent pane in that direction |
| `o` | Select the next pane in tree order |
| `c` | Create a window with a new shell |
| `n`, `p` | Select next/previous window |
| `x` | Close the selected pane and its terminal tasks |
| `d` | Detach to the calling shell; pane tasks continue running |
| Ctrl+B | Send a literal Ctrl+B to the pane |

Run `Tmux;` again from the same calling shell to reattach. The status line
marks the selected window. There are up to eight windows and sixteen panes
per session. Splits preserve at least ten columns or three rows per pane;
closing a pane gives its area to its sibling. Closing the last pane ends the
session. Each pane runs `Init.cool` and an independent interactive Cool shell.

## Kernel implementation

`Term.cool` stores Unicode cells, their width and 16-color foreground/background,
cursor, UTF-8/ANSI parser state, primary/alternate buffers, and a 256-slot key
ring (255 usable entries) in `CVTerm`. It handles cursor positioning/movement,
SGR (including reverse), erase, lazy wrap, scrolling, and DEC alternate screen
47/1049. Resizing preserves the upper-left cells and clamps both saved and live
cursors. It does not implement the entire xterm protocol or scrollback.

`CTask.terminal` binds output (`PutS`/`Print`/`ConsPut`, including input echo)
and input (`KeyPop`/`GetKey`/`GetChar`/`GetLine`) to a terminal. Spawned workers
inherit a reference to their parent's terminal, as members of that terminal's
process group. Tmux binds each new shell to a fresh terminal before it runs.
The ordinary outer shell has a direct terminal: it records the same ANSI
screen while forwarding bytes to UART/framebuffer and reading physical keys.
Boot tasks without a terminal retain the physical console. History/edit
scratch storage is per task, so another shell cannot replace a pending line.

Tmux is an ordinary disk HolyC program. It reads its own terminal, recognizes
the prefix, queues other events only to the selected pane, and composites
pane cell snapshots as ANSI output, batching dirty screen updates at 30 Hz
so fast typing does not trigger a full redraw for every key. Hidden panes continue updating their
buffers. Terminal locks protect worker output and input on other cores; the
renderer releases those locks before acquiring the console print lock.
Terminal references survive task exit, and closing a pane kills its terminal
process group; scheduler reaping releases stacks, history, shell context and
terminal references. Direct framebuffer graphics APIs are still physical
APIs; graphics programs that bypass the console are not confined to panes.

## Independent compilers and scheduling

Every shell loads its **own Compiler.BIN instance**, including mutable module
globals, compiler task/hash tables and x28 TLS. `CShell` holds its export
pointers, input line, statement/line exception contexts, interrupt masks and
execution flags. The Vim statement cleanup hook (`shell_stmt_cleanup`) is a
task-local lvalue in `CShell`, so normal return, fault or break in one pane
cannot close another pane's editor. `ArchCtxSwitch` already saves/restores x28. Runtime Fs/SetFs,
loader trap names, debugger lookup, faults and breaks select the current
shell's state. Kernel exports remain shared; **user functions, globals and
macros are private to each shell**, and survive successive lines there.
Filesystem drive/directory remain per kernel task.

The scheduler remains cooperative in kernel/compiler code. A 10 ms timer
scheduling point also yields from interrupted JIT statements in heap code,
keeping a CPU-bound pane from starving the compositor or another shell. It
preserves the complete exception frame on that task's stack and enables
interrupts while other tasks run. Kernel/driver code is not asynchronously
preempted. Ctrl+Alt+C targets the selected shell, including one sleeping in a
statement. The upstream stack guards, canaries and kernel text protection
remain enabled; fault recovery uses the affected shell's saved SP and DAIF.

As with the previous shell, emitted statements/definitions and loaded compiler
storage remain resident after shell exit: HolyC code can publish pointers to
code and literal data outside its task. This is not a reclaiming JIT arena;
repeatedly creating and closing shells consumes memory until reboot. Pane
screens, task stacks and input histories are reclaimed. Terminals provide
routing/isolation, not a security boundary for privileged HolyC programs.

## Verification

`make test` includes `make tmux-test`, plus the existing relocated boot, device,
Vim, key and memory-safety recovery tests. `TermTest.cool` checks ANSI state,
alternate-screen restore, UTF-8 width, output/input isolation, queue bounds,
scrolling and resize preservation without consuming physical input.

`tools/tmux-test.py` creates a FAT32 disk and sends real VM keyboard events.
It exercises both split directions, directional/o focus, c/n/p/x, closes a
pane running an infinite loop, compiles the same variable independently in
several shells, runs one shell while another sleeps, and detaches/reattaches.
The host checks actual framebuffer font pixels for LEFT-111 and RIGHT-223 in
their respective panes. It also rejects heap corruption after boot self-tests.
The input script, UART log and screenshot remain in `build/tmux-test/`.

The Tmux test also runs two Vim editors concurrently, saves separate files,
and breaks/faults the left editor while the right editor remains open. It
checks both saved files, PageDown/Ctrl+U movement using the pane height,
and the two restored shell screens with cleared
cleanup hooks. These artifacts remain in `build/tmux-vim-test/`. Vim takes
its viewport dimensions from the bound terminal rather than the physical
framebuffer.

`make coolvm-test` also checks a timer deadline reprogrammed to an already
expired value. The VMM tracks changes to CVAL as well as ISTATUS, so missing
a short deasserted interval cannot permanently suppress timer FIQs and leave
a CPU-bound pane monopolizing the core.
