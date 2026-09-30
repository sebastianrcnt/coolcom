# Vim in Coolcom

`Vim("C:/File.cool");` opens a UTF-8 file (or an empty new file). `Init.cool`
loads the editor. The UART and VM keyboard use the same `GetKey` events.

- Normal: `hjkl`, `w b e`, `0 ^ $`, `gg G`, `f<char> t<char>`;
  counts such as `5j`, `3dd`, `d3w`, `2d2d`, `12G`.
- Insert: `i a I A o O`; Escape ends one undo transaction. Arrow keys,
  Home/End, Backspace, Delete, Tab and Enter also work while inserting.
- Edit: `x`, `d`/`c`/`y` followed by a motion (or `dd cc yy`),
  `p P`, `r<char>`, `J`, and `.` to repeat the last change including inserted text.
- Visual: `v` selects characters, `V` selects whole lines; motions extend
  the selection, `d x c y` operate on it, Escape cancels.
- Definitions: `gd` finds a declaration in the current live buffer (Cool functions,
  classes, variables and defines; Warm functions, types and records), then uses
  Man's compiler symbols and kernel sources. Ctrl+O restores the previous file,
  cursor and viewport (32 jumps). Save before crossing files with changes.
- History: `u`, Ctrl+R, with counts. A fresh change after undo discards the
  redo branch. Saving does not clear history; undo recomputes the modified flag.
- Search: `/text` or `?text`, Enter; `n N` repeat in either direction.
  Searches are literal, case-sensitive UTF-8 and wrap around the buffer.
  An empty search repeats the previous pattern.
- Numbers: `:set number/nu`, `nonumber/nonu`, `relativenumber/rnu`,
  `norelativenumber/nornu` (space-separated options also work). With both
  enabled, the current line is absolute and other lines are relative; with
  only relative numbers the current line is zero. Default: number, nornu.
- Ex: `:w :q :q! :wq`, `:e C:/Other.cool`, `:42`. Unsaved changes block
  `:q` and `:e`; failed reads/writes stay in the editor with a status message.

The display has line numbers, vertical/horizontal scrolling, a mode/filename/
modified/message status line, and ANSI colors for Cool keywords, types,
numbers, strings and comments. Hangul/CJK occupy two cells, tabs use four-cell
stops. Stored cursor offsets are UTF-8 byte boundaries. File control characters
are displayed as placeholders rather than being sent as ANSI commands.

The text is a gap buffer that grows with the file, so there is no size limit
but memory (KernelA.coolh, 231 KB, opens and saves). Undo records each edit
(position, removed text, inserted text) instead of copying the text, grouped
into the same transactions as before. Storage is still bounded in these ways:
there are 32 undoable changes, counts are capped at 10000, and the dot recorder holds
4096 key events. Longer edits still work and remain undoable but do not replace
the previous dot command. This is a single-buffer editor, not full Vim: there
are no regex searches, named registers, plugins or split windows. Insert counts
are not expanded. A trailing newline does not create an extra normal-mode line.

`VimOpen` registers `VimClose` with the shell's statement cleanup before
allocating editor storage. Normal return, a synchronous statement fault, and
Ctrl+Alt+C all restore the console and release editor-owned buffers. This uses
the existing kernel fault recovery, not memory isolation: arbitrary kernel/heap
corruption cannot be made safe by an editor cleanup callback.

`make vim-test` boots the real VM, injects keyboard input scripts and UART UTF-8,
and compares each FAT32 result and byte cursor with independent host expectations.
It also checks scroll state, files over 128 KiB, forced quit, and a
real null-pointer fault while the editor is open followed by successful reentry.
Generated disks, scripts and diagnostic logs stay in `build/vim-test`.

Syntax highlighting follows the file extension: Cool (`.cool`, `.coolh`, with identifiers colored from the
shell compiler's symbol table: functions, types, globals, `#define`s), Warm (`.warm`, `.warmh`) and plain
text. `:set ft=cool|warm|text` overrides it and `:hi GROUP COLOR` changes a group's Ansi color
(groups: normal comment string number keyword type storage preproc label constant function global
linenr nontext). `Vim("name", line)` opens at a line. Rules: `os/Kernel/Syntax.cool`; tokenizer shared with
the formatter: `coolc/Fmt/HCTok.cool`; `make syntax-test`.
