# C: programs

`make run` copies these files into `build/disk.img` before boot (only the ones that are missing, so edits made inside the OS survive; `make disk-install` overwrites them) with `tools/disk-files.sh`, which also puts the kernel's own sources under `C:/Kernel` (`os/Kernel`), with shared libraries in `C:/Cool/Runtime` and `C:/Cool/Fmt` so the OS can show its source. The shell runs `C:/Init.cool` at startup, which loads the programs below into that shell (each Tmux pane's shell loads its own copy).

| File | What |
|---|---|
| `Vim.cool` | `Vim("name", line)`: modal UTF-8 editor on the alternate ANSI screen, whole file in memory (a gap buffer, no size limit), syntax highlighting by file extension (`Syntax.cool` in the kernel; `:set ft=cool\|warm\|text`, `:hi group color`). `:q` refuses a modified buffer, `:q!` discards. See `Vim.md`. |
| `Tmux.cool` | `Tmux;`: independent shells in virtual terminals (Ctrl-B `%` `"` `o` arrows `c` `n` `p` `x` `d`). |
| `Nyan.cool` | `Nyan;`: animation, any key stops it. |
| `Find.cool` | `Find("text", "*.cool")`: search files recursively, print `file,line: text` (third argument TRUE: ignore case). |
| `Less.cool` | `Less("file")`: pager with wrapping by terminal columns (UTF-8, wide characters), Space/b/d/u/j/k/g/G, `/text` `?text` `n` `N`, `q`. |
| `Man.cool` | `Man;` opens the manual index; `Man("Warm")`, `Man("WarmSyntax")`, `Man("WarmRun")`, `Man("WarmExamples")` and `Man("OS.Terminal")` (or another `OS.*` module) open generated pages in `C:/Man`. Other names open Vim at a function, class, global or `#define` definition. The shell compiler's symbol table supplies compiled source locations; kernel symbols are looked up in `C:/Kernel` and `C:/Cool`. |
| `Diff.cool` | `Diff("a", "b")`: report differing hunks (port of Aiwnios `Diff.HC`, ANSI colors instead of DolDoc); `Diff("a", "b", TRUE)` merges into `a` one hunk at a time (keys 1 2 a b q Esc). |
| `Top.cool` | `Top;`: full-screen monitor refreshed every second: a bar per core, heap, FAT32 free space, and the tasks (core, state, CPU share over the last second, switches, stack; the core's first task is its idle task). Up/Down select, `c` `p` `n` `s` sort by CPU/task/name/state, `k` then `y` kills the selected task, `q` quits. |
| `Cube.cool` | Optional GPU 3D demo: in a Venus-enabled `make run` shell, load `#include "C:/Cube.cool"` once and run `Cube;`. `make cube-run` launches a separate demo VM. Rotating lit cube, two smaller cubes, perspective camera, grid and shadow. W/S or +/- move forward/back, A/D pan, arrows orbit/look, Space pauses rotation, R resets, Q/Esc returns to the terminal. Requires the existing Venus terminal and the main framebuffer shell; no kernel changes. |
| `HexDump.cool` | `HexDump("file", start, count)`. |
| `Text.cool` | helpers the tools share. |
| `Init.cool` | includes the above; defines `Cls`. |

At the prompt a line such as `vim a.cool`, `find foo *.cool`, `less C:/Vim.cool`, `man StrLen`, `top` runs the tool (the shell turns command lines into calls; Tab completes function and file names).

`tools/warm-man.py` generates the Warm manual during each disk installation from
`docs/man/*.txt` and `warmc/standard/src/OS/**/*.warmh`. Body-only modules
(`OS.Time`, `OS.Random`, `OS.Error`) use their public `.warm` declarations.
New modules enter the index automatically and need a matching note in `docs/man`.
Full reference documents are installed under `C:/Warm/Docs`; library and example
sources remain in `C:/Warm/Standard` and `C:/Warm/Examples`.
Seeding preserves manual edits; `make disk-install` refreshes generated pages.
`make warm-man-test` compares body-only declarations with the compiler's AST,
checks interface coverage and page/example references; disk-layout and text
tests verify installation, preservation/refresh and actual `Man` navigation.

The VM framebuffer and the UART terminal receive the same ANSI output, so the programs work on either; the terminal should be 80x24 or larger. `make vim-test`, `tmux-test`, `syntax-test` and `text-test` boot the VM and drive them with input scripts.

`make cube-run` launches a separate demo disk under `build/cube-demo`, leaving the
normal VM disk untouched. Cube is a framebuffer-only application. Cool owns input, camera state, frame timing,
GPU resources and the HUD; the GLSL shaders under `tools/venus/shaders/cube.*` render
the 3D scene with analytic ray/box intersections on the GPU. The demo reuses the
resident terminal's Vulkan device, found through the existing resident shell's
symbol table under the core and renderer locks. It retains no task pointers and
does not destroy the terminal's device or Venus context. Demo command buffers,
shaders, images and readback blobs are released on exit; the console is redrawn
before its scanout buffer is unmapped. Resize recreates the render target.
`make cube-test` checks real GPU pixels, camera input, pause, repeated runs,
resource counts, camera bounds/reset, shell-break cleanup, resize, allocation-failure
cleanup and the missing-Venus message in
separate scratch VMs; screenshots and logs are saved under `build/cube-test`.
