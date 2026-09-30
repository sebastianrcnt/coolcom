# coolcom

A TempleOS-like operating system for arm64 — Apple M1 (booted by m1n1) and QEMU `virt` —
written in **Cool** (our HolyC) with a second, memory-safe language, **Warm** (a fork of
Austral with linear types and capabilities). Everything, including the compilers and the
kernel itself, can be edited and rebuilt from inside the OS.

- **coolvm**: our own Hypervisor.framework VM for Apple silicon Macs (virtio disk, network,
  framebuffer), used for development; QEMU `virt` works too.
- **Kernel**: SMP scheduler, FAT32, TCP/IP, a cell-grid terminal with Hangul and an IME,
  Tmux, Vim, Less, Top, Man, a shell whose command lines are compiled and run as Cool.
- **Cool compiler (`coolc`)**: self-hosting; the OS rebuilds its own compiler and kernel
  byte for byte (`make selfhost-test`, `make kernel-rebuild-test`).
- **Warm compiler (`warmc`)**: written in Cool, runs on the Mac and inside the OS; the
  network packet parser in the kernel is Warm.
- Also: Lua 5.4 translated to Cool through `tools/c2hc`, a Zed extension for both languages.

Start with the [user guide](docs/USER-GUIDE.md): `make run` on an Apple silicon Mac.

Licensed under MIT (`LICENSE`); third-party parts keep their own licenses (`THIRD_PARTY.md`).
