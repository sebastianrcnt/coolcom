# C: programs

`make run` copies these files into `build/disk.img` before boot (only the ones that are missing, so edits made inside the OS survive; `make disk-install` overwrites them) with `tools/disk-files.sh`, which also puts the kernel's own sources under `C:/Kernel` (`os/Kernel`, and `Runtime/` for the shared TempleOS library files) so the OS can show its source. The shell runs `C:/Init.HC` at startup, which loads the programs below into that shell (each Tmux pane's shell loads its own copy).

| File | What |
|---|---|
| `Vim.HC` | `Vim("name", line)`: modal UTF-8 editor on the alternate ANSI screen, whole file in memory (128 KiB limit), syntax highlighting by file extension (`Syntax.HC` in the kernel; `:set ft=cool\|warm\|text`, `:hi group color`). `:q` refuses a modified buffer, `:q!` discards. See `Vim.md`. |
| `Tmux.HC` | `Tmux;`: independent shells in virtual terminals (Ctrl-B `%` `"` `o` arrows `c` `n` `p` `x` `d`). |
| `Nyan.HC` | `Nyan;`: animation, any key stops it. |
| `Find.HC` | `Find("text", "*.HC")`: search files recursively, print `file,line: text` (third argument TRUE: ignore case). |
| `Less.HC` | `Less("file")`: pager with wrapping by terminal columns (UTF-8, wide characters), Space/b/d/u/j/k/g/G, `/text` `?text` `n` `N`, `q`. |
| `Man.HC` | `Man("Name")`: open Vim (or Less for a file over 128 KiB) at the definition of a function, class, global or `#define`. The shell compiler's symbol table gives the file and line of what the shell compiled; kernel symbols are looked up in `C:/Kernel`. |
| `Diff.HC` | `Diff("a", "b")`: report differing hunks (port of Aiwnios `Diff.HC`, ANSI colors instead of DolDoc); `Diff("a", "b", TRUE)` merges into `a` one hunk at a time (keys 1 2 a b q Esc). |
| `Top.HC` | `Top;`: full-screen monitor refreshed every second: a bar per core, heap, FAT32 free space, and the tasks (core, state, CPU share over the last second, switches, stack; the core's first task is its idle task). Up/Down select, `c` `p` `n` `s` sort by CPU/task/name/state, `k` then `y` kills the selected task, `q` quits. |
| `HexDump.HC` | `HexDump("file", start, count)`. |
| `Text.HC` | helpers the tools share. |
| `Init.HC` | includes the above; defines `Cls`. |

The VM framebuffer and the UART terminal receive the same ANSI output, so the programs work on either; the terminal should be 80x24 or larger. `make vim-test`, `tmux-test`, `syntax-test` and `text-test` boot the VM and drive them with input scripts.
