# coolcom user guide

coolcom is a TempleOS-like operating system for the Apple M1. It is written in HolyC ("Cool") and developed on
coolvm, our Hypervisor.framework VM. Everything below was tried on coolvm. Features that exist only in the VM
are marked **VM-only** and collected in [the last section](#vm-only). Deeper documents: [M1 kernel
notes](../os/Kernel/M1.md), [C: programs](../os/Disk/README.md), [Vim](../os/Disk/Vim.md),
[Tmux](terminal-multiplexer.md), [networking](networking.md), [FAT32 tools](fat32-tools.md),
[rebuilding the kernel in the OS](kernel-rebuild.md), [coolvm](../tools/coolvm/README.md).

## Build and run

On an Apple silicon Mac, install the Homebrew packages `aarch64-elf-gcc`, `aarch64-elf-binutils`, `mtools` and
`coreutils` (for `gtimeout`), plus Python 3 and the Xcode command-line tools. Then:

| Command | What it does |
|---|---|
| `make` | compiles the kernel with the checked-in compiler seed and writes `build/kernel.Image` |
| `make run` | boots the Image in a coolvm window with 2 CPUs, 1 GiB and `build/disk.img` as `C:` |
| `make run-net` | the same with a network card and the Mac's ports 2323 and 8080 forwarded to the guest's 23 and 80 |
| `make -j test` | all checks, side by side (about 40 s; `make test` runs them one after another in about 3 minutes); each part has its own target, e.g. `make vim-test`, `make kernel-rebuild-test` |
| `make disk-install` | overwrites the programs and sources on `build/disk.img` with the repository's versions |
| `make m1n1-payload` | `build/m1n1-payload.bin` for real hardware (m1n1 + device tree + the Image; not yet booted on a Mac) |

`make run` creates `build/disk.img` (64 MiB FAT32) the first time. It then adds only the files that are
missing, so edits made inside the OS are kept. The disk holds the programs of `os/Disk`, the kernel sources
in `C:/Kernel` and `C:/coolc`, the shell prelude `C:/Kernel.HH`, and the compiler sources in `C:/Compiler`.
To read the disk from the Mac, shut the VM down and run `hdiutil attach build/disk.img`.

The VM shows the framebuffer console in a window, and the terminal you started it from is the serial port
(UART). Both carry the same shell: output appears in both, and you can type in either. Hangul input is
available in the window only (Shift+Space, the Hangul key, or Right Alt alone toggles 2-beolsik). The
terminal composes Hangul itself and sends UTF-8. coolvm options are listed by `build/coolvm --help`, for
example `--width/--height`, `--cpus`, `--mem`, `--headless`, `--net` and `--timeout`.

## The shell

After boot the shell prints `Cool shell: ... compiler loaded`, runs `C:/Init.HC` (which loads Vim, Tmux,
Less, and the other programs) and shows the `>` prompt.

### HolyC lines

Each line is HolyC. It is compiled by the Cool compiler that runs inside the kernel (a JIT) and runs at once.
Functions and globals you define stay defined for later lines:

```
> I64 Sq(I64 x) { return x * x; }
> Print("%d\n", Sq(7));
49
> "%d files\n", 3;
3 files
```

- Every kernel function, class, global and `#define` can be used directly, because the shell prelude
  declares them all (`Dir`, `FileRead`, `Spawn`, `HeapStats`, `Uf`, ...). The shell does not print an
  expression's value; use `Print`.
- A function called with no arguments needs no parentheses: `Dir;`, `HeapStats;`.
- A compile error prints `ERROR:`, the message, the source line and a caret, then the line is dropped:
  ```
  > I64 bad = ;
  ERROR: Expected an expression
    I64 bad = ;
              ^
  ```
  Errors in files (`ExeFile`, `#include`, `Cmp`) also name the file and line.
- A fault inside a statement (a bad pointer, stack overflow, heap corruption) prints the error and a
  backtrace, and the shell returns to the prompt.

### Unix-style command lines

When a line starts with a function's name followed by words, the shell rewrites it into a call. The name may
be written in any capitalization. The function's parameter types decide whether each word becomes a string
or a number. Quote words that contain spaces.

```
> ls                          // Dir;          aliases: ls cat rm cp mv clear
> cd Kernel                   // Cd("Kernel");
> ls *.S
> cd /
> cat Init.HC                 // Type("Init.HC");
> cp Init.HC I2.HC
> mv I2.HC I3.HC
> rm I3.HC
> mkdir Foo
> find Cls *.HC               // Find("Cls", "*.HC");
> hexdump Init.HC 0 16
> vim a.HC
> top
```

A line that is only a lowercase function name (`top`, `heapstats`) runs that function. A capitalized name
alone still needs the `;` (`HeapStats;`). Normal HolyC lines such as `x = 5;`, `Print("a");` and `I64 n;`
are compiled as they are. There is no `pwd`: the current directory is `DirCur`, as in
`Print("%s\n", DirCur);`.

### Line editing, history and completion

| Key | Action |
|---|---|
| Left/Right, Home/End, Ctrl+A/Ctrl+E | move the cursor |
| Backspace, Delete | delete at the cursor |
| Up/Down | earlier lines (the last 32 of this shell) |
| Tab | complete: symbols (functions, classes, globals, `#define`s) and file names after a command or inside a string. The first Tab extends to the common prefix; the next one lists the candidates. |

### Ctrl+Alt+C

Ctrl+Alt+C in the **VM window** stops the statement the shell is running: a busy loop, a `Sleep`, or a
program waiting for a key. The shell prints `Break` and returns to the prompt. The rest of that line does
not run. If the break comes while the line is still compiling, or while a line is waiting unread, that
line is dropped. In a Tmux pane it stops the focused pane's shell.

The serial terminal cannot send Ctrl+Alt+C (the kernel only polls the UART). A remote shell uses Ctrl+C
instead (see [networking](#networking)).

## Files and drives

`C:` is the first FAT32 disk, `D:` the second, and so on. `coolvm --disk` can be given up to four times;
make an extra disk with `mkfile -n 64m d.img` and `mformat -i d.img -F ::`. An 8 MiB image is too small
for FAT32 and does not become a drive.
Names are UTF-8 with long names, Hangul included. ASCII letters match regardless of case.

| Command | |
|---|---|
| `Dir;` `Dir("*.TXT");` | list the current directory |
| `Cd("Kernel");` `Cd("/");` `Cd("D:/");` | change the directory or drive; `DirCur` is the current one |
| `Type("Init.HC");` | print a text file |
| `FileRead(name, &size)` / `FileWrite(name, buf, size)` | read or write a whole file |
| `Copy(a, b)`, `Move(a, b)` (or `Rename`), `Del(name)`, `MkDir(name)` | copy, move and delete work recursively on directories |
| `DiskInfo;` | capacity and free space |
| `Fsck`, `FatFormat` | check or repair a volume, or format one ([FAT32 tools](fat32-tools.md)) |

Everything written goes straight to the disk image (the block cache is write-through), so Shutdown is not
needed to keep your data. Still, shut down before attaching the image on the Mac.

## Editors and tools

These are the programs on `C:` that `C:/Init.HC` loads into every shell. [os/Disk/README.md](../os/Disk/README.md)
describes each one.

| Command | |
|---|---|
| `Vim("a.HC");` or `vim a.HC` | modal editor: insert/visual modes, counts, undo/redo, search, `:w` `:q` `:q!` `:wq`, syntax highlighting for Cool and Warm; see [Vim.md](../os/Disk/Vim.md) |
| `Tmux;` | independent shells in panes: Ctrl+B then `%` / `"` split, `o` or arrows move, `c` new window, `n` / `p` switch window, `x` close pane, `d` detach; `Tmux;` again reattaches |
| `Less("file");` | pager: Space/b/d/u/j/k/g/G, `/text` `?text` `n` `N`, `q` |
| `Man("StrLen");` | opens Vim (Less for big files) at the definition of a function, class, global or `#define`, in the kernel sources or in code the shell compiled |
| `Find("text", "*.HC");` | search files recursively; `file,line: text` (third argument TRUE: ignore case) |
| `Diff("a", "b");` | show differing hunks; `Diff("a", "b", TRUE)` merges into `a` interactively |
| `HexDump("file", start, count);` | hex and ASCII |
| `Top;` | cores, heap, disk and tasks, refreshed every second; Up/Down select, `c` `p` `n` `s` sort, `k` then `y` kills, `q` quits |
| `Nyan;` | animation; any key stops it |
| `Cls;` | clear the screen |

The kernel also has debugging commands: `Uf("StrLen");` disassembles a function, `D(addr, n);` dumps
memory, and `HeapStats;` shows heap use and checks the heap for consistency.

## Compiling programs: Cmp, Load, ExeFile

| Command | |
|---|---|
| `ExeFile("Hello");` | JIT-compile and run `Hello.HC` in this shell (its definitions stay) |
| `#include "Hello"` | the same, as a HolyC line (`.HC` is added) |
| `Cmp("Lib");` | compile `Lib.HC` ahead of time to `Lib.BIN`; returns the error count |
| `Load("Lib");` | load `Lib.BIN` and run its top-level code; declare its functions with `extern` to call them |

```
> Cmp("Lib");                      // Lib.HC starts with #include "Kernel.HH"
Errs:0 Warns:9 Code:C0 Size:11E
> Load("Lib");
Lib loaded
> extern I64 Tri(I64 x);
> Print("%d\n", Tri(4));
12
```

A program compiled with `Cmp` declares the kernel by including `C:/Kernel.HH`, the shell prelude. The
OS can also rebuild itself: `Cmp("C:/Compiler/Native.HC")` reproduces the compiler seed byte for byte, and
`MakeKernel;` followed by `Reboot("C:/Kernel.Image");` builds and boots a new kernel
([kernel-rebuild.md](kernel-rebuild.md)).

## Networking

Networking needs a VM started with `--net` (use `make run-net`). DHCP configures the interface at boot.

| Command | |
|---|---|
| `NetRep;` | interface, address, counters, ARP cache, sockets |
| `Ping("10.0.2.2", 1);` | ICMP echo (the count defaults to 4) |
| `Dns("example.com");` | print the A records |
| `HttpGet("http://example.com/");` | print a page (HTTP/1.0 only, no https) |
| `ShellServe(23);` | remote shells: from the Mac, `tools/rsh.sh 2323` or `telnet localhost 2323`; Ctrl+C breaks a statement, `Exit;` disconnects |
| `Wget("http://example.com/", "C:/Ex.html");` | save a page to a file |
| `HttpServe(80, "C:/");` | serve `C:` over HTTP; with `make run-net`, `curl localhost:8080/Init.HC` on the Mac |

The API and the TCP/IP design are in [networking.md](networking.md).

## Shutdown and Reboot

`Shutdown;` flushes the disks and powers the VM off. `Reboot;` flushes the disks and restarts coolvm with
the same options. `Reboot("C:/Kernel.Image");` boots a kernel Image from the disk. On a real M1 both only
flush the disks and halt, because the SMC power interface is not implemented.

## Warm

Warm is our fork of Austral, a language with linear types and capabilities, meant for safe code such as
drivers and parsers ([warmc/README.md](../warmc/README.md)). A Warm program compiles to HolyC and runs in the
shell. The kernel is reached through `Warm.Kernel` (files, console, keys, framebuffer, clock). There are two
compilers:

- **On the Mac (OCaml warmc, built in the opam switch `austral`):** `./warmc/build.sh`, then `warmc/warmc compile ... --target-type=hc` writes a
  `.HC` file. Copy it to `C:` together with `warmc/standard/src/Kernel/Adapter.HC`, and include both in the
  shell: `#include "C:/Adapter.HC"`, then the generated file. `make warm-kernel-test` does exactly this with
  `warmc/examples/kernel`.
- **Inside the OS (Warm written in Cool, `warmc/Cool`):** `./warmc/Cool/build.sh` and
  `python3 warmc/Cool/package_kernel.py` produce `build/warmcool/Kernel.HC`. Copy it to `C:/Warm.HC`, then
  run `#include "C:/Warm.HC"` and `WarmRun("C:/Test.aum");` in the shell ([warmc/Cool/README.md](../warmc/Cool/README.md)).

<a id="vm-only"></a>
## What is VM-only

These parts work only under coolvm today. The kernel itself is written for the M1 (AIC interrupts, the
Apple UART, 16 KiB pages, spin-table SMP, relocation to any 2 MiB base).

| Feature | On a real M1 |
|---|---|
| Keyboard and mouse (coolvm input device), so also Ctrl+Alt+C and the Hangul IME | needs USB HID or the SPI keyboard driver |
| Disks (virtio-blk), so also `C:` and every file command | needs ANS NVMe behind DART |
| Network (virtio-net, coolvm NAT and port forwarding) | no driver for the Mac's Ethernet or Wi-Fi |
| `Shutdown`, `Reboot`, `Reboot(image)` (coolvm finisher) | only flush and halt; the SMC power keys are not implemented |
| Clock (`Now`) from coolvm's device tree | starts at 1970 until the SMC RTC is read |

The framebuffer console (m1n1's `simple-framebuffer`) and the serial console are M1 drivers, but neither has
been tested on hardware yet. The hardware checklist is in [M1.md](../os/Kernel/M1.md#m1-hardware-checks).
