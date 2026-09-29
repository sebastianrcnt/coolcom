# C: programs

`make run` copies `Init.HC`, `Vim.HC`, and `Tmux.HC` into `build/disk.img` before boot. The shell runs `C:/Init.HC` at startup, so `Vim("C:/Note.txt");` and `Tmux;` are available at the prompt. To update another FAT32 image, use `mcopy -o -i image.img os/Disk/{Init,Vim,Tmux}.HC ::`.

`Vim` uses the alternate ANSI screen and edits a whole file in memory (128 KiB limit). The VM framebuffer and UART terminal receive the same ANSI output. The terminal should be 80×24 or larger. `:q` refuses a modified buffer; `:q!` discards it.

`Tmux` provides two scratch panes, split with Ctrl-B `%`, switched with Ctrl-B `o`, and closed with Ctrl-B `q`. The compiler uses x28 task local storage and can only run on the one shell task. The panes therefore cannot each host a shell; they are independent scratch views within one shell invocation.
