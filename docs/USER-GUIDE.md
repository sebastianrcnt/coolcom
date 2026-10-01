# coolcom user guide

coolcom is a TempleOS-like arm64 operating system for the Apple M1 and QEMU `virt`. It is written in HolyC ("Cool") and developed on
coolvm, our Hypervisor.framework VM. The QEMU serial console is also tested; the window features below were tried on coolvm. Features that exist only in the VM
are marked **VM-only** and collected in [the last section](#vm-only). Deeper documents: [M1 kernel
notes](../os/Kernel/M1.md), [C: programs](../os/Disk/README.md), [Vim](../os/Disk/Vim.md),
[Tmux](terminal-multiplexer.md), [networking](networking.md), [FAT32 tools](fat32-tools.md),
[rebuilding the kernel in the OS](kernel-rebuild.md), [Warm standard library design](warm-stdlib.md), [x86-64 design](x86-64.md), [shell JIT linking](shell-jit-linking.md), [historical Logos design](logos.md), [Venus/Vulkan design](venus.md), [coolvm](../tools/coolvm/README.md).

## Build and run

On an Apple silicon Mac, install the Homebrew packages `aarch64-elf-gcc`, `aarch64-elf-binutils`, `mtools` and
`coreutils` (for `gtimeout`), plus Python 3 and the Xcode command-line tools. Then:

| Command | What it does |
|---|---|
| `make` | compiles the kernel with the checked-in compiler seed and writes `build/kernel.Image` |
| `make run` | boots the Image in a coolvm window with 2 CPUs, 1 GiB and `build/disk.img` as `C:` |
| `make run-qemu` | boots the same Image with QEMU `virt`, 2 CPUs, 1 GiB, `build/disk.img`, virtio-net and a serial console (install Homebrew `qemu`) |
| `make qemu-test` | disposable FAT disk; GICv3/HVF when available and GICv2/TCG: shell file read, 2 cores, IPI, network, PSCI reset and shutdown |
| `make run-net` | the same with a network card and the Mac's ports 2323 and 8080 forwarded to the guest's 23 and 80 |
| `make -j test` | all checks, side by side (about 40 s; `make test` runs them one after another in about 3 minutes); each part has its own target, e.g. `make vim-test`, `make kernel-rebuild-test` |
| `make disk-install` | overwrites the programs and sources on `build/disk.img` with the repository's versions |
| `make m1n1-payload` | `build/m1n1-payload.bin` for real hardware (m1n1 + device tree + the Image; not yet booted on a Mac) |

### Vulkan terminal on coolvm

A fresh checkout has no `vendor/` libraries, so `make run` uses the CPU terminal.
To enable Venus on Apple silicon macOS:

```sh
brew install meson ninja pkg-config cmake glslang
make venus-vendor  # downloads/builds pinned generator, virglrenderer and MoltenVK inputs
make run           # automatically builds the Venus monitor and installs the terminal app/shaders
```

The first command is the explicit network/build step; it can take several minutes.
Later `make run` and `make run-net` detect the installed stack, use
`build/coolvm-venus`, refresh **only `C:/Vulkan`** and compile GLSL with the host's
`glslang`. Existing programs and edits elsewhere on the disk remain intact.
The boot log confirms `VENUS TERMINAL READY` and `VENUS PRESENT Metal image`.
`VENUS=0 make run` forces the ordinary CPU monitor; `VENUS=1 make run` explicitly
requires the installed stack. `make venus-run` also explicitly selects Venus.
`make venus-generator-vendor` downloads just the generator inputs.

The guest renders cells/atlas/overlay with Vulkan. Completed images go directly
to a `CAMetalLayer`; screenshots alone request GPU readback. Old host stacks
without the image bridge use linear readback, as does `--venus-readback` on
`build/coolvm-venus`. `--no-venus` forces CPU rendering in that executable.
`FbFlush` requests an asynchronous display update; `FbFinish` waits for the latest
frame when a program needs completion. Shutdown/reboot call it automatically.
`make -j test` always keeps the ordinary monitor and needs no Venus dependencies
or internet; optional GPU validation is `make venus-term-test venus-test`.

`make run` and `make run-qemu` create `build/disk.img` (512 MiB FAT32, a sparse file) the first time; an older, smaller
disk is kept as it is (to get the larger one, copy your files off, `rm build/disk.img`, and `make run` again). It then adds only the files that are
missing, so edits made inside the OS are kept. The disk holds the programs of `os/Disk`, the kernel sources
in `C:/Kernel` and `C:/Cool/Runtime` (tokenizer in `C:/Cool/Fmt`), the shell prelude `C:/Kernel.coolh`, and the compiler sources in `C:/Cool/Compiler`.
It also installs the shared C library in `C:/Cool/LibC`, the Warm compiler in
`C:/Warm/Warm.cool`, standard library sources in `C:/Warm/Standard` (including `builtin/`),
and examples in `C:/Warm/Examples`, preserving their subdirectories. Repository directories
`coolc/` and `warmc/` keep their names. The disk installer maps the kernel's library includes
to `C:/Cool/...`; host compilation uses the original relative includes.
To read the disk from the Mac, shut the VM down and run `hdiutil attach build/disk.img`.

Source files: Cool is `.cool` (headers `.coolh`), Warm is `.warm` (interfaces `.warmh`). The old extensions
`.HC`, `.HH`, `.aum` and `.aui` still work for legacy files: the compiler, `#include`, `Cmp`, `ExeFile`, Vim and
Less highlighting, `Find`, `Man`, `warmc` and `WarmRun` accept both. An extensionless name (`#include "Foo"`,
`ExeFile("Foo")`, `Cmp("Foo")`) means `Foo.cool` if that exists, else `Foo.HC`. At boot the shell runs
`C:/Init.cool`, or `C:/Init.HC` on an old disk that has no `Init.cool`. `make run` on such a disk adds the
`.cool` files beside the old ones; `Init.cool` then wins, and the old `.HC` copies can be deleted.

The VM shows the framebuffer console in a window, and the terminal you started it from is the serial port
(UART). Both carry the same shell: output appears in both, and you can type in either. Hangul input is
available in the window only (Shift+Space, the Hangul key, or Right Alt alone toggles 2-beolsik). The
terminal composes Hangul itself and sends UTF-8. coolvm options are listed by `build/coolvm --help`, for
example `--width/--height`, `--cpus`, `--mem`, `--headless`, `--net` and `--timeout`.

QEMU uses `-kernel build/kernel.Image` and its generated FDT; no firmware or alternate kernel build
is needed. `QEMU_ACCEL=auto` probes HVF and falls back to TCG; force either with
`QEMU_ACCEL=hvf make run-qemu` or `QEMU_ACCEL=tcg make run-qemu`. The default GIC is v3;
`QEMU_ACCEL=tcg QEMU_GIC=2 make run-qemu` selects v2 (HVF requires v3). `QEMU` can override
the executable. Ctrl+A X exits QEMU; Ctrl+A C switches between its monitor and serial console.
The launcher uses modern virtio-MMIO block/network devices. It currently uses the serial console;
virtio-gpu display support is being developed separately. No ramfb setup is required.

## The shell

After boot the shell prints `Cool shell: ... compiler loaded`, runs `C:/Init.cool` (which loads Vim, Tmux,
Less, Warm, and the other programs) and shows the prompt: the current directory, as in TempleOS
(`C:/> `, `C:/Kernel> `), or `> ` alone when there is no drive.

### HolyC lines

Each line is HolyC. It is compiled by the Cool compiler that runs inside the kernel (a JIT) and runs at once.
Functions and globals you define stay defined for later lines:

```
C:/> I64 Sq(I64 x) { return x * x; }
C:/> Print("%d\n", Sq(7));
49
C:/> "%d files\n", 3;
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
C:/> ls                          // Dir;          aliases: ls cat rm cp mv clear
C:/> cd Kernel                   // Cd("Kernel");
C:/Kernel> ls *.S
C:/Kernel> cd /
C:/> cat Init.cool                 // Type("Init.cool");
C:/> cp Init.cool I2.cool
C:/> mv I2.cool I3.cool
C:/> rm I3.cool
C:/> mkdir Foo
C:/> find Cls *.cool               // Find("Cls", "*.cool");
C:/> hexdump Init.cool 0 16
C:/> vim a.cool
C:/> top
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
| `Type("Init.cool");` | print a text file |
| `FileRead(name, &size)` / `FileWrite(name, buf, size)` | read or write a whole file |
| `Copy(a, b)`, `Move(a, b)` (or `Rename`), `Del(name)`, `MkDir(name)` | copy, move and delete work recursively on directories |
| `DiskInfo;` | capacity and free space |
| `Fsck`, `FatFormat` | check or repair a volume, or format one ([FAT32 tools](fat32-tools.md)) |

Everything written goes straight to the disk image (the block cache is write-through), so Shutdown is not
needed to keep your data. Still, shut down before attaching the image on the Mac.

## Editors and tools

These are the programs on `C:` that `C:/Init.cool` loads into every shell. [os/Disk/README.md](../os/Disk/README.md)
describes each one.

| Command | |
|---|---|
| `Vim("a.cool");` or `vim a.cool` | modal editor: insert/visual modes, counts, undo/redo, search, `:w` `:q` `:q!` `:wq`, syntax highlighting for Cool and Warm; see [Vim.md](../os/Disk/Vim.md) |
| `Tmux;` | independent shells in panes: Ctrl+B then `%` / `"` split, `o` or arrows move, `c` new window, `n` / `p` switch window, `x` close pane, `d` detach; `Tmux;` again reattaches |
| `Less("file");` | pager: Space/b/d/u/j/k/g/G, `/text` `?text` `n` `N`, `q` |
| `Man("StrLen");` | opens Vim (Less for big files) at the definition of a function, class, global or `#define`, in the kernel sources or in code the shell compiled |
| `Find("text", "*.cool");` | search files recursively; `file,line: text` (third argument TRUE: ignore case) |
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
| `ExeFile("Hello");` | JIT-compile and run `Hello.cool` in this shell (its definitions stay) |
| `#include "Hello"` | the same, as a HolyC line (`.cool` is added; the legacy `Hello.HC` if only that exists) |
| `Cmp("Lib");` | compile `Lib.cool` ahead of time to `Lib.BIN`; returns the error count |
| `Load("Lib");` | load `Lib.BIN` and run its top-level code; declare its functions with `extern` to call them |
| `Vet("Lib");` | check `Lib.cool` for style problems, without writing a BIN (see below); returns the number of findings |

```
C:/> Cmp("Lib");                      // Lib.cool starts with #include "Kernel.coolh"
Errs:0 Code:C0 Size:11E
C:/> Load("Lib");
Lib loaded
C:/> extern I64 Tri(I64 x);
C:/> Print("%d\n", Tri(4));
12
```

A program compiled with `Cmp` declares the kernel by including `C:/Kernel.coolh`, the shell prelude. The
OS can also rebuild itself: `Cmp("C:/Cool/Compiler/Native.cool")` reproduces the compiler seed byte for byte, and
`MakeKernel;` followed by `Reboot("C:/Kernel.Image");` builds and boots a new kernel
([kernel-rebuild.md](kernel-rebuild.md)).

### What the compiler rejects, and what Vet reports

The compiler has no warnings. What is almost certainly a bug is an error: the program is not compiled (no BIN,
`Cmp` returns the error count), and all the errors of a file are reported, not only the first. What is only
style is reported by `Vet`, and only there.

Errors:

- a string compared with `==` or `!=` against a string literal (`s == "abc"` compares addresses; use `StrCmp`);
- an integer constant divided by or taken modulo zero (`n / 0`, `n %= 0`; a float divided by 0 is fine) and a
  constant shift by 64 or more;
- a duplicate `case` value in a `switch`;
- a nonzero integer constant assigned to, compared with, or passed as the argument for a pointer (`p = 5`,
  `p == -1`, `Man('Tmux')`; `0`, `NULL` and casts such as `p = 5(U8 *)` are fine);
- an unused local variable (`no_warn x;` allows one; an unused function argument is fine);
- a `Print` format that disagrees with its arguments (count, or an integer where `%f` wants a float and back);
- a function that does not return a value when it should (`I64 F() {}`, `return;` in an `I64` function) or that returns
  one when it should not (`return 1;` in a `U0` function);
- a definition whose return type, argument types, argument count or default values differ from its declaration;
- a failed `#assert`.

Compat mode: in `.HC` and `.HH` files (legacy TempleOS and Aiwnios code) these errors are only Vet findings,
named `[strict]`, so such code compiles as before. `.cool` and `.coolh` files stay strict. `build/coolc --compat file.cool out.BIN`,
`Cmp("file", NULL, TRUE);` and `ExeFile("file", TRUE);` in the OS turn it on for any file; `Vet` takes it too.
(A duplicate `case` and a constant integer passed as a pointer argument are errors in every mode.)

`Vet("file");` in the OS (`build/coolc --vet file.cool` on the host, `make vet` for the repository's own
programs) compiles the file without output and prints the style findings, each named by its check, with the
position; nothing of this is reported during a normal compile:

| Check | Finds |
|---|---|
| `[assign-cond]` | an assignment used as a condition, `if (a = b)`; `if ((a = b))` says it is meant |
| `[empty-stmt]` | an empty statement right after `if (...)`, `for (...)` or `while (...)`, as in `if (x);` |
| `[unreachable]` | a statement right after `return`, `break` or `goto` in the same block (a label or a `case` is fine, and so is the `break;` habit after a `return`) |
| `[unused-arg]` | a function argument that is never used |
| `[arg-name]` | a definition that names an argument differently than its declaration |
| `[unneeded-no-warn]` | `no_warn` on a variable that is used |
| `[unused-extern]` | an extern variable that is never used |
| `[u0-ptr]` | `U0 *` where `U8 *` is meant |
| `[strict]` | in compat mode: an error the compiler would otherwise give |
| `[dup-type]` | with `Option(OPTf_WARN_DUP_TYPES, ON)`: a local declared in its own statement with a type another local has |

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
| `HttpServe(80, "C:/");` | serve `C:` over HTTP; with `make run-net`, `curl localhost:8080/Init.cool` on the Mac |

The API and the TCP/IP design are in [networking.md](networking.md).

## Shutdown and Reboot

`Shutdown;` flushes the disks and powers the VM off. `Reboot;` flushes the disks and restarts coolvm with
the same options. QEMU uses PSCI `SYSTEM_OFF` / `SYSTEM_RESET` for these commands.
`Reboot("C:/Kernel.Image");` boots a kernel Image from the disk on coolvm; it reports that this
finisher feature is unavailable on QEMU. On a real M1 both only
flush the disks and halt, because the SMC power interface is not implemented.

## The desktop

`Gui;` switches from the full-screen terminal to the desktop: floating windows,
a menu bar with the System menu (New Shell, Drawing, Widgets, Files, Top,
Settings, Cube, Gallery, Terminal) and each window's own menus. Ctrl+Alt+N opens
a shell window, Ctrl+Alt+Tab cycles focus, Ctrl+Alt+Left/Right/Up tile the
focused window. Dragging in a shell window selects text and copies it; Ctrl+Alt+V
pastes the clipboard into a shell, and Ctrl+C/Ctrl+V work in text fields.

- **Files** browses the disk read-only: a sortable, filterable table of the folder
  with a preview of the selected file (Return or a double click opens).
- **Top** lists the tasks on every core with their CPU share; Kill asks first.
- **Settings** switches the display between 1x and 2x and the terminal font
  between the bitmap font and System Mono.
- **Gallery** shows every control of OS.Ui, the framework these applications
  are written with; [ui-framework.md](ui-framework.md) explains how to write one.

## Warm

Warm is our fork of Austral, a language with linear types and capabilities, meant for safe code such as
drivers and parsers ([warmc/README.md](../warmc/README.md)). A Warm program compiles to Cool and runs in the
shell. The kernel is reached through `Warm.Kernel` (files, console, keys, framebuffer, clock). There is one
compiler, written in Cool (`warmc`), and it runs in two places:

- **On the Mac:** `make build/warmc` builds it (`build/warmc compile ... --target-type=hc` writes a `.cool`
  file, as `coolc` compiles it). `tools/warm run Foo.warm` compiles, builds and runs a program in one step
  (entrypoint `Module:main` of the last file; add `--entrypoint=` and other modules as needed). To run generated
  code in the OS, copy it to `C:` together with `warmc/standard/src/Kernel/Adapter.cool`, and include both in the
  shell: `#include "C:/Adapter.cool"`, then the generated file. `make warm-kernel-test` does exactly this with
  `warmc/examples/kernel`; `make warm-test` runs the compiler's own tests.
- **Inside the OS:** `make disk-install` and `make disk-seed`
  automatically build and package the compiler as `C:/Warm/Warm.cool`. `C:/Init.cool` loads it for each shell,
  so after boot you can run `WarmRun("C:/HelloWarm.warm");` to print `Hello from Warm!`, or
  `WarmRun("C:/X.warm");` for your own module `Test` with a `main` function. For another module name,
  pass the entry point, e.g. `WarmRun("C:/X.warm", "X:main");`
  ([warmc/README.md](../warmc/README.md)). No manual build, copy, or `#include` is needed.
  Standard library inputs are explicit comma-separated paths, just as on the host. For example,
  the installed greeting example uses the OS terminal library:

  ```c
  WarmRun("C:/Warm/Standard/Buffer.warmh,C:/Warm/Standard/Buffer.warm,C:/Warm/Standard/String.warmh,C:/Warm/Standard/String.warm,C:/Warm/Standard/StringBuilder.warmh,C:/Warm/Standard/StringBuilder.warm,C:/Warm/Standard/OS/Error.warm,C:/Warm/Standard/OS/Terminal.warmh,C:/Warm/Standard/OS/Terminal.warm,C:/Warm/Examples/greet/Greet.warmh,C:/Warm/Examples/greet/Greet.warm", "Example.Greet:main");
  ```

  Builtins are already embedded in the compiler; their installed sources are available for browsing.
  On an existing disk, run `make disk-install` once to update `Init.cool` and kernel includes and
  remove the old `C:/coolc`, `C:/Compiler`, `C:/Warm.cool` and `C:/Warm.HC` paths.
  `disk-seed` (also used by `make run`) preserves existing files and adds missing files;
  older installations retain their old files until that explicit migration.
- **In the kernel:** the network stack's packet parser is Warm (`os/Kernel/NetParse.warm`), so a
  malformed packet from the network cannot make the kernel read or write outside the frame. `make` compiles
  it with `build/warmc --kernel-module=NetParse` into a Cool file the kernel includes
  ([networking.md](networking.md#the-packet-parser-in-warm), [warmc/README.md](../warmc/README.md#kernel-modules)).

<a id="vm-only"></a>
## What is VM-only

The kernel selects platform drivers from FDT compatibility: Apple AIC/S5L UART/spin-table for M1 and
coolvm, GICv2/v3/PL011/PSCI for QEMU `virt`. Both use 16 KiB pages and the same relocatable Image.
The following devices still need real M1 hardware drivers; virtio disks and networking work on both VMs.

| Feature | On a real M1 |
|---|---|
| Keyboard and mouse (coolvm input device), so also Ctrl+Alt+C and the Hangul IME | needs USB HID or the SPI keyboard driver |
| Disks (virtio-blk), so also `C:` and every file command | needs ANS NVMe behind DART |
| Network (virtio-net, coolvm NAT and port forwarding) | no driver for the Mac's Ethernet or Wi-Fi |
| `Shutdown`, `Reboot` (coolvm finisher or QEMU PSCI); `Reboot(image)` is coolvm-only | only flush and halt; the SMC power keys are not implemented |
| Clock (`Now`) from coolvm's device tree | starts at 1970 until the SMC RTC is read |

The framebuffer console (m1n1's `simple-framebuffer`) and the serial console are M1 drivers, but neither has
been tested on hardware yet. The hardware checklist is in [M1.md](../os/Kernel/M1.md#m1-hardware-checks).
