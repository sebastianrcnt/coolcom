# Apple M1 (t8103 / Mac mini j274) platform reference for coolcom

Goal: everything the kernel needs to boot on a bare-metal Mac mini (M1, 2020, board `j274`, SoC `t8103`) via
m1n1, and everything the Hypervisor.framework VM monitor must emulate so the same drivers run in the VM.

## 0. Sources and confidence tags

| Key | Source | Revision read |
|---|---|---|
| `m1n1` | https://github.com/AsahiLinux/m1n1 (`src/`, `proxyclient/`) | `main` @ `647ae30533bc` |
| `linux` | https://github.com/AsahiLinux/linux, branch `asahi` (`arch/arm64/boot/dts/apple/t8103*`, `drivers/irqchip/irq-apple-aic.c`, `drivers/tty/serial/samsung_tty.c`, ...) | `77cb8f24c238` |
| `docs` | https://github.com/AsahiLinux/docs (site: https://asahilinux.org/docs/), `docs/` tree | `main` @ `715664a26993` |
| `hvsdk` | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Hypervisor.framework/Headers/` | macOS 27.0 SDK on the dev Mac |
| `probe` | Our own Hypervisor.framework experiments run on the dev Mac (Apple M6 host, macOS 27.0, 16 KiB host pages) | 2026-09-29 |

Citation form: `m1n1:src/payload.c:234` = file and line in that repo. Line numbers are for the revisions above.

Confidence tags used in tables: **[C]** read directly in source code/DTS; **[W]** only stated in wiki prose;
**[M]** measured by us with `probe` (on an M6 host, so guest ID-register values are the host's, not an M1's);
**[?]** inference or unverified. Where sources disagree this is called out as **DISCREPANCY**.

Not covered by anything I could read and therefore unknown: exact `ID_AA64*` register values of a real M1, the
memory contents of a real j274 ADT, behaviour of the physical UART after m1n1 without a debug cable.

---

## 1. Most important facts (TL;DR)

1. m1n1 hands the kernel control by a plain function call: `entry(x0 = FDT physical address, x1..x3 = 0)`
   (`m1n1:src/main.c:210`, `m1n1:src/kboot.c:2923-2929`). CPU is in **EL2**, MMU **off**, I/D caches **off**,
   D-cache cleaned, `DAIF.{A,I,F}` masked (`m1n1:src/memory.c:654-661`, `m1n1:src/exception.c:180-183`).
2. At entry `HCR_EL2 = E2H|TGE|RW|AMO|IMO|FMO|API|APK|TEA` (`m1n1:src/exception.c:164-172`): the CPU is in VHE "host"
   mode. Linux runs at EL2 with VHE on this machine ("CPU features: detected: Virtualization Host Extensions",
   `docs:docs/platform/dev-quickstart.md:650`).
3. Payload = concatenation `m1n1.bin || vars || DTB(s) || [initramfs.cpio.gz] || Image[.gz]`. m1n1 recognises a kernel by
   `"ARM\x64"` at offset `0x38` (`m1n1:src/payload.c:234`) and a DTB by matching root `compatible` against
   `apple,<target-type lowercased>` = `apple,j274` (`m1n1:src/payload.c:293-301`). For the concatenated-payload path our kernel therefore needs a 64-byte
   Linux arm64 Image header (the `linux.py` proxy path does not look at it), and we must supply a DTB whose root compatible list contains `apple,j274`.
4. All 8 cores are already running (m1n1 started them) and parked at EL2, MMU off, waiting in `wfe`. Boot CPU is
   MPIDR `0x80000000`. Wake protocol is the standard **spin-table**: write entry PA to the 8-byte `cpu-release-addr`
   from the FDT, `dc civac`, `sev` (`linux:arch/arm64/kernel/smp_spin_table.c:66-105`, `m1n1:src/smp.c:560-575`).
5. Interrupts: HW peripheral IRQs arrive as **IRQ** via **AIC** (`0x2_3b10_0000`, AICv1: EVENT read = ack+auto-mask).
   Timers, fast IPIs and PMU arrive as **FIQ** and have **no status register**; the FIQ handler must poll
   `CNTx_CTL` and Apple IMP sysregs (`linux:drivers/irqchip/irq-apple-aic.c:557-613`).
6. Debug UART0 = `0x2_3520_0000`, Samsung S5L-style, 32-bit accesses only, 24 MHz clock, 16-entry FIFO, AIC IRQ 605.
   It is only physically reachable with a special USB-C (VDM) cable; **under the m1n1 hypervisor it is virtualised to a
   USB serial port**. After m1n1 hands off, the USB serial is gone (`m1n1:src/main.c:200`), so a dev setup without the
   cable sees kernel output only on the framebuffer unless running as an m1n1 HV guest.
7. Framebuffer: `simple-framebuffer` node in `/chosen`, `x8r8g8b8` (32 bpp) typically, carved out above the usable RAM
   range; no mode setting without the DCP firmware/driver (`m1n1:src/kboot.c:180-254`).
8. MMIO must be mapped **Device-nGnRnE** (non-posted); the DTS marks the whole `soc` bus `nonposted-mmio`
   (`linux:arch/arm64/boot/dts/apple/t8103.dtsi:473`). Use **16 KiB** pages (m1n1 does; DARTs are 16K-only).
9. Counter frequency is **24 MHz** (`sched_clock: 56 bits at 24MHz`, `docs:docs/platform/dev-quickstart.md:673`;
   measured `CNTFRQ_EL0 = 0x16E3600` inside a Hypervisor.framework guest [M]).
10. Hypervisor.framework guests run at **EL1**, cannot be VHE (guest `ID_AA64MMFR1_EL1.VH == 0` [M]), and every Apple
    IMP-DEF sysreg (`S3_5_C15_*`, `S3_1_C15_C0_0`, ...) and every MMIO access exits to the host, where we can emulate it
    [M]. The vtimer is native (`HV_EXIT_REASON_VTIMER_ACTIVATED`) and FIQs can be injected with
    `hv_vcpu_set_pending_interrupt(HV_INTERRUPT_TYPE_FIQ)` [M]. This is the same model Asahi uses when it runs Linux as an
    m1n1-hypervisor guest, so the kernel needs both an EL2 (real HW) and an EL1 (VM) entry path.

---

## 2. Boot handoff from m1n1 to a payload

### 2.1 Boot chain (context)

SecureROM -> iBoot1 (in NOR) -> iBoot2 (OS-paired) -> loads a Mach-O/raw "kernel" from the Preboot volume. Asahi installs
**m1n1 stage 1** as that "custom kernel" (fuOS) with `kmutil configure-boot -c m1n1-stage1.bin --raw --entry-point 2048
--lowest-virtual-address 0` (`docs:docs/sw/m1n1-user-guide.md`, section "Stage 1 (as fuOS)"). Stage 1 either runs its own
appended payloads, chainloads a stage 2 (`chainload=` var, from the ESP), or drops into proxy mode. iBoot enters m1n1 with the MMU
off and `x0 = &boot_args`; the boot CPU's RVBAR is locked to the page of the entry point (`docs:docs/fw/macho-boot-protocol.md:79-90`).
The **watchdog is armed** by iBoot (120 s) and m1n1 disables it in `m1n1_main()` (`m1n1:src/main.c:162`,
`docs:docs/hw/soc/wdt.md`) so the payload starts with WDT off.

### 2.2 Payload formats m1n1 understands (`m1n1:src/payload.c:216-263`)

Payloads are concatenated after m1n1; m1n1 walks them sequentially with `load_one_payload()`.

| Magic / form | Meaning | Notes |
|---|---|---|
| `"ARM\x64"` at offset 0x38 | Linux arm64 Image | `payload.c:234`; struct in `m1n1:src/kboot.h:11-21` |
| `1f 8b` / `fd 37 7a 58 5a 00` | gzip / xz wrapper | decompressed to 2 MiB-aligned heap, then re-scanned (`payload.c:66-110`) |
| `d0 0d fe ed` | FDT | used only if root `compatible` matches `apple,<target-type>` (`payload.c:112-120`) |
| `07070` | cpio initramfs | must be compressed (`payload.c:122-132`) |
| `name=value\n` | m1n1 variable | `chosen.X=Y` becomes string property `/chosen/X`; also `chainload=`, `display=`, `mitigations=`, `tso=` (`payload.c:180-214`) |
| all-zero word | end of payloads | |

* Kernel must be **2 MiB aligned**; if it is not (inline payload) m1n1 copies it to an aligned heap block
  (`payload.c:140-145`). An uncompressed kernel must be the **last** payload because its size is only known from the header
  `image_size` (`payload.c:147-158`; user guide says uncompressed kernels may lose variables, `docs:docs/sw/m1n1-user-guide.md`).
* The header fields m1n1 actually reads are: magic (`+0x38`) and `image_size` (`+0x10`). `image_size` should cover the whole
  runtime footprint (BSS, initial stacks, as Linux's does): m1n1 asserts payload size <= `image_size` (`payload.c:138`), allocates `image_size` bytes when it has to copy an unaligned kernel (`:142`) and, for compressed payloads, skips exactly `image_size` bytes to find the next payload (`:155`).
  `text_offset`/`flags` are not used by m1n1 (`kboot.h:11-21`).
  The Linux header contract: `code0/code1` at +0, `text_offset` +8, `image_size` +0x10, `flags` +0x18, `magic` +0x38
  (`linux:Documentation/arch/arm64/booting.rst:73-88`). Set flags bit 1-2 = 2 (16K) for documentation value only.
* Boot arguments: `chosen.bootargs=...` variable -> `/chosen/bootargs` (`m1n1:src/kboot.c:263-272`).
* Initramfs is passed as `/chosen/linux,initrd-start/-end` and added as a memory reservation (`kboot.c:274-286`).
* Alternative for development: `linux.py` uploads DTB and kernel over the proxy and calls the same `kboot_*` functions
  (see 2.6); there the kernel is decompressed/copied to a 2 MiB-aligned block and **entered at its first byte**
  (`m1n1:proxyclient/tools/linux.py:69-70,138-153,163`); no header parsing at all in that path.

### 2.3 Register and machine state at kernel entry (bootloader -> kernel) [C]

| Item | Value | Source |
|---|---|---|
| Entry point | first byte of the Image (kernel base, 2 MiB aligned); `text_offset` ignored | `payload.c:141-145`, `linux.py:69-70` |
| `x0` | physical address of the FDT (in a `memalign`ed heap buffer, `fdt_pack`ed) | `kboot.c:2924` |
| `x1..x3` (and x4) | 0 | `kboot.c:2925-2928`, `main.c:210` |
| Exception level | EL2 (non-secure). CurrentEL = 8 | `main.c:148` prints "Running in EL2" (`docs:docs/platform/dev-quickstart.md:487`) |
| `HCR_EL2` | bits 41 API, 40 APK, 37 TEA, 34 E2H, 31 RW, 27 TGE, 5 AMO, 4 IMO, 3 FMO | `m1n1:src/exception.c:164-172` |
| `SCTLR` (EL2) | `M=0, C=0, I=0` (cleared by `mmu_shutdown`) | `m1n1:src/memory.c:654-661` |
| D-cache | clean+inval by set/way over all levels (`dcsw_op_all(DCCISW)`) | `memory.c:660` |
| I-cache | not explicitly invalidated by the payload path; do `ic iallu; dsb; isb` early | `memory.c:654-661` (no `ic`), `linux.py:153-154` does `dc cvau`/`ic ivau` |
| `DAIF` | `A,I,F` set (0x1c0) via `exception_shutdown()`; `D` clear | `exception.c:180-183`; `linux.py:158-160` sets `0xc0` |
| Timers | `CNTP_CTL/CNTV_CTL` written 7 (masked) at m1n1 init; `CNTFRQ_EL0` = 24 MHz | `exception.c:133-138` |
| Watchdog | disabled | `main.c:162` |
| Apple IMP state | chicken bits applied on every core; `CYC_OVRD`: FIQ/IRQ unmasked, WFI mode 2, WFI retention on | `m1n1:src/chickens.c:206-253` |
| USB, NVMe, display | USB proxy shut down, NVMe shut down, DCP put to sleep if external display | `main.c:197-201` |
| DMA | `nvme_shutdown()`, `usb_iodev_shutdown()` called; DARTs otherwise left as iBoot configured them | `main.c:197-201` [?] |
| Secondary cores | running at EL2, MMU off, parked (see section 7) | `smp.c`, `payload.c:318` |
| Linux boot contract | x0=dtb, x1-x3=0, DAIF masked, MMU off, EL2 recommended, CNTFRQ programmed | `linux:Documentation/arch/arm64/booting.rst:163-199` |

m1n1's own DTB pre-allocation: FDT buffer = original size + 96 KiB; m1n1 image and the FDT buffer are added as
`/memreserve/` entries (`kboot.c:2794-2804`). The FDT buffer is 16 KiB-aligned (`DT_ALIGN 16384`, `kboot.c:54,2795`), satisfying the 8-byte requirement of the Linux boot protocol.

### 2.4 The FDT m1n1 passes (what we must supply, what m1n1 fills)

m1n1 takes the DTB payload (Linux `t8103-j274.dtb` normally) and edits it in `kboot_prepare_dt()` (`m1n1:src/kboot.c:2781-2906`).
For the nodes that matter to a minimal kernel:

| Node / property | Provided by our DTB | Filled/edited by m1n1 | Source |
|---|---|---|---|
| root `compatible` | must contain `apple,j274` (Linux: `"apple,j274","apple,t8103","apple,arm-platform"`) | - | `payload.c:293-301`; `t8103-j274.dts:16` |
| `/memory` (`memory@800000000`) | node with `device_type="memory"` and 4-cell `reg` placeholder (`<0x8 0 0x2 0>`) | `reg` = **usable** range(s): `[boot_args.phys_base, phys_base+mem_size)` plus any non-`no-map` reserved-memory regions outside it | `t8103-jxxx.dtsi:48-51`; `kboot.c:350-452` |
| `/reserved-memory` | empty container with `#address-cells=2,#size-cells=2,ranges` | m1n1 appends ASC/DCP/SEP/ISP/... carve-outs (only if those nodes exist) | `t8103-jxxx.dtsi:41-46`; `kboot.c:1445-1700` |
| `/memreserve/` block | - | initrd, FDT buffer, m1n1 image | `kboot.c:282,2800-2804` |
| `/chosen` | `stdout-path = "serial0"`, `#address-cells/#size-cells = 2`, `ranges` | `bootargs` and all `chosen.*` vars, `linux,initrd-*`, `asahi,*-version`, `rng-seed`/random-seed, `asahi,kblang-code`, ... | `t8103-jxxx.dtsi:25-39`; `kboot.c:256-320` |
| `/chosen/framebuffer@..` | node `compatible = "apple,simple-framebuffer","simple-framebuffer"`, `reg = <0 0 0 0>`, `status="disabled"` | `reg`, `width`, `height`, `stride`, `format`; removes `status`; renames node `framebuffer@<base>` | `t8103-jxxx.dtsi:32-38`; `kboot.c:180-254` |
| `/cpus/cpu@N` | `reg` = MPIDR affinity, `enable-method="spin-table"`, 8-byte `cpu-release-addr = <0 0>` | writes `cpu-release-addr`; **nops out** CPUs that did not come alive; aborts if a node's MPIDR does not match the started core | `t8103.dtsi:63-173`; `kboot.c:541-640` |
| AIC node | `compatible="apple,t8103-aic","apple,aic"` (m1n1 searches for `apple,aic`/`apple,aic2`/`apple,t8122-aic3` and fails otherwise) | prunes PMU affinity of dead CPUs | `t8103.dtsi:1029`; `kboot.c:642-660` |
| everything else (PMGR, DARTs, USB, PCIe, NVMe, display, SEP, ...) | from Linux DT | many `dt_set_*` fix-ups; some `bail()` if expected nodes are missing | `kboot.c:2822-2880` |

Consequences:
* The **only safe way to start** is to use Linux's `t8103-j274.dtb` unmodified as the payload DTB and read what we need from it.
  A hand-written minimal DTB is possible but m1n1 has many `bail()` paths (`kboot_prepare_dt`); a minimal DTB is **[?] untested** by me.
  Nodes required by code paths that unconditionally run: `/chosen`, `/memory`, `/cpus/cpu@*` with 8-byte `cpu-release-addr`, an AIC node,
  and `/reserved-memory` (`kboot.c:259,261,444,546,386,642`).
* `/memory` deliberately excludes the top-of-RAM carve-outs (framebuffer, coprocessor firmware) so the kernel never maps them
  cacheable (`kboot.c:370-372`). The `/chosen/framebuffer` region is *not* reserved separately because it lies outside the range
  (`kboot.c:241-242`).
* Sample from a real Mac mini (8 GiB, Feb 2021 log): `DRAM at 0x800000000 size 0x200000000`,
  `Usable memory is 0x80134c000..0x9db5e0000`, framebuffer at `0x9e0df8000` size `0x7e9000` (1920x1080x4),
  kernel at `0x821800000`, FDT at `0x8193f0000`, initrd `0x821700000`
  (`docs:docs/platform/dev-quickstart.md:561-609`).

### 2.5 Framebuffer/console, hv, and proxy transports

m1n1 has three ways to talk to a host during development:

| Transport | What it is | Notes |
|---|---|---|
| **USB proxy** | m1n1 brings up USB device mode on the Type-C ports ("available on all Thunderbolt ports") and presents two CDC-ACM ports. Port 1 = proxy protocol (`M1N1DEVICE`), port 2 = hypervisor virtual UART | macOS names `/dev/cu.usbmodemP_01` and `/dev/cu.usbmodemP_03` (`docs:docs/sw/m1n1-user-guide.md:184-186`; `docs:docs/sw/tethered-boot-macos-host.md`). |
| **Physical debug UART** | UART0 via USB-PD VDM "serial mode" on the SBU pins, 1.2 V logic, only on the DFU port = on the Mac mini the port **closest to the power plug** (`docs:docs/hw/soc/serial-debug.md:11`) | needs `macvdmtool` (from another M1 Mac) or a Central Scrutinizer / DIY board; host device `/dev/cu.debug-console` (`docs:docs/hw/soc/serial-debug.md:11-50`). Baud used in docs: 115200 on the host side; Linux examples use `console=ttySAC0,1500000` (`docs:docs/platform/dev-quickstart.md:542`); with a 24 MHz UART clock both are reachable, see 6. |
| **Framebuffer** | m1n1 draws its console on the boot framebuffer; kernel can keep drawing on it | 2.6, 8 |

USB is *not* available after handoff (`usb_iodev_shutdown()`, `m1n1:src/main.c:200`) unless the payload is run under the m1n1
hypervisor.

### 2.6 Development workflows

1. **Tethered boot (no disk install of our kernel).** Install m1n1 via the Asahi installer (expert mode, "tethered-only proxy mode") or
   put a release stage-1 in backdoor mode (`csrutil disable && nvram boot-args=-v` from 1TR; m1n1 then waits 5 s for a USB connection)
   (`docs:docs/sw/tethered-boot.md`, "Enabling the backdoor proxy mode"). Then on the host:
   ```
   export M1N1DEVICE=/dev/cu.usbmodemP_01
   python3 proxyclient/tools/linux.py -b 'bootargs...' Image.gz t8103-j274.dtb [initramfs.cpio.gz]
   ```
   (`docs:docs/sw/m1n1-user-guide.md`, "Booting a Linux kernel"). `linux.py` (`m1n1:proxyclient/tools/linux.py`): sets bootargs
   (`kboot_set_chosen`), uploads the compressed kernel and DTB with `malloc`, allocates a 512 MiB 2 MiB-aligned kernel region
   (`:69-70`), `smp_start_secondaries()` (`:113`), `kboot_prepare_dt(dtb_addr)` (`:127`), decompresses in place with
   `gzdec/xzdec` (`:139`), `dc cvau`+`ic ivau` over the image (`:153-154`), sets `DAIF=0xc0` (`:158-160`),
   `kboot_boot(boot_addr)` (`:163`). An **uncompressed raw kernel is accepted** with `--compression none` (the `auto` mode only
   recognises `.gz`/`.xz` suffixes, `:26-35`); the kernel is entered at its first byte, so during development our kernel can skip the
   Image header.
2. **Chainload another m1n1** for a matching proxy ABI: `chainload.py -r build/m1n1.bin`
   (`m1n1:proxyclient/tools/chainload.py`, `docs:docs/sw/m1n1-user-guide.md`). `chainload.py` rebuilds the *iBoot/XNU-style* environment (`boot_args`, SEPFW, ADT; entry at `image + 0x800` for `-r`, `chainload.py:15-33,84-125`), so it is for m1n1-like next stages, **not** for a Linux-protocol kernel (x0 = FDT); use `linux.py` or a payload for our kernel.
3. **Payload concatenation (stand-alone boot from the volume)**: `cat m1n1.bin <(echo 'chosen.bootargs=...') t8103-j274.dtb
   initramfs.cpio.gz Image.gz > payload.bin` (`m1n1:README.md`, "Payloads"; `docs:docs/sw/m1n1-user-guide.md`, "Configuring to boot
   Linux directly"). This is what gets installed with `kmutil configure-boot -c payload.bin --raw --entry-point 2048
   --lowest-virtual-address 0` on macOS >= 12.1.
4. **Under the m1n1 hypervisor** (`proxyclient/tools/run_guest.py`, `run_guest_kernel.sh`): guest runs at EL1; the hypervisor virtualises
   `uart0` (`m1n1:proxyclient/m1n1/hv/__init__.py:1465-1471`, `m1n1:src/hv/hv_vuart.c`) to the second USB-serial port; `^C` breaks into the
   guest, `gdbserver` is provided (`docs:docs/sw/tethered-boot.md`, "Booting a kernel under the hypervisor"). Best option to get a
   console from our kernel without a VDM cable, and it is exactly the EL1 configuration our VM monitor reproduces.
5. Reboot: `python3 proxyclient/tools/reboot.py` or (from the HV) `reboot`; the host can also hard-reboot the target via USB-PD VDM
   (`docs:docs/hw/soc/serial-debug.md:13`).

---

## 3. Memory map (t8103)

Addresses are physical; the SoC bus uses 2-cell address/size (`t8103.dtsi:20-21`).

### 3.1 DRAM

* DRAM base `0x8_0000_0000` (`docs:docs/hw/soc/memmap.md:60`; `m1n1:src/kboot.c:362` fallback; DTS `memory@800000000`).
* Size: 8 GiB (`0x2_0000_0000`) or 16 GiB (`0x4_0000_0000`) on Mac mini M1. The 8 GiB case is confirmed by a real log
  (`docs:docs/platform/dev-quickstart.md:609`); the 16 GiB size is **[W]** (memmap says "8/16G").
* Not all of it is usable. Layout when iBoot calls m1n1 (`docs:docs/fw/macho-boot-protocol.md:12-45`): bottom of RAM has coprocessor
  carve-outs/iBoot data; `boot_args.phys_base` starts the OS-visible region; then ADT, trust cache, m1n1 Mach-O, payload region
  (64 MiB), SEPFW, BootArgs, and free memory up to `top_of_kdata + mem_size`; above that, video memory/SEP/other carve-outs to
  `0x8_0000_0000 + mem_size_actual`.
* In the FDT that reaches the kernel only `[phys_base, phys_base + mem_size)` is in `/memory` (`kboot.c:374-383`). The 8 GiB log
  shows `0x80134c000..0x9db5e0000` (~7.4 GiB). Everything else must be treated as unknown MMIO/carve-out (never map cacheable).
* m1n1 marks as reserved: its own image (`fdt_add_mem_rsv(_base.._end)`, `kboot.c:2803`), the FDT buffer (`:2800`), the initrd (`:282`), and
  DT `/reserved-memory` regions it creates for coprocessor firmware (`kboot.c:1445-1700`). Everything else inside `[phys_base, phys_base+mem_size)`,
  including m1n1's heap and the upload buffers used by `linux.py`, is handed to the kernel as free RAM; the kernel image itself lies inside that
  range. The kernel must therefore honour both `/memreserve/` entries and `/reserved-memory` children.

### 3.2 MMIO regions we care about (t8103, `linux:arch/arm64/boot/dts/apple/t8103.dtsi` unless noted)

| Device | Base | Size (DTS) | AIC IRQ | DTS line |
|---|---|---|---|---|
| CPU impl regs (RVBAR at +0x0; running state at +0x100) | `0x2_1005_0000 + core*0x10_0000` (E cores), `0x2_1105_0000 + core*0x10_0000` (P cores) | 0x10000 | - | `docs:docs/hw/soc/memmap.md:7-25` [W]; m1n1 reads the real value from ADT `cpu-impl-reg` (`m1n1:src/smp.c:404-419`) |
| cluster cpufreq E / P | `0x2_10e2_0000` / `0x2_11e2_0000` | 0x1000 | - | 539-549 |
| UART0 (debug console, `serial0`) | `0x2_3520_0000` | 0x1000 (docs: 0x4000) | 605 | 878-892 |
| UART2 (`serial2`, WLAN debug) | `0x2_3520_8000` | 0x1000 | 607 | 894-904 |
| AIC | `0x2_3b10_0000` | 0x8000 (docs: 0xc000) | - | 1029-1046 |
| PMGR | `0x2_3b70_0000` | 0x14000 (docs: 0x100000) | - | 1049-1054 |
| GPIO / pinctrl (AP) | `0x2_3c10_0000` | 0x100000 | - | 1064 |
| PMGR "mini" | `0x2_3d28_0000` | 0x4000 | - | 1216-1221 |
| WDT | `0x2_3d2b_0000` | 0x4000 | 338 | 1223-1229 |
| SMC + mailbox | `0x2_3e40_0000` / `0x2_3e40_8000` | | | 1231, 1263 |
| ANS mailbox / SART / NVMe (ANS2) | `0x2_7740_8000` / `0x2_7bc5_0000` / `0x2_7bcc_0000` (+ `0x2_7740_0000`) | 0x4000 / 0x10000 / 0x40000 | 583-586, -, 590 | 1514-1547 |
| USB DWC3 #0 (Type-C) | `0x3_8228_0000` | 0xcd00+0x3200 | 777 | 1548-1562 |
| USB DWC3 #1 (Type-C) | `0x5_0228_0000` | | | 1607 |
| PCIe root complex (config / rc / ports) | `0x6_9000_0000` / `0x6_8000_0000` / `0x6_8100_0000, 0x6_8200_0000, 0x6_8300_0000` | 16 MiB / 1 MiB / 16 KiB each | 695, 698, 701 (+ MSI `704..735`) | 1695-1713 |
| PCIe BAR windows | `0x6_a000_0000` (0x2000_0000, 64-bit prefetchable) and `0x6_c000_0000` (0x4000_0000, 32-bit; PCI address `0xc000_0000`) | | | 1724-1725 |
| GPU/AGX | `0x2_0640_0000` + `0x2_0400_0000` | | 575-578 | 477-524 |
| DCP / DART / display | `0x2_31c0_0000`, `0x2_3130_4000`, `0x2_2820_0000` | | | 551-660 |

* All of `0x2_0000_0000 .. 0x2_ffff_ffff` is one large MMIO window ("ARM-IO"); m1n1 maps every ARM-IO `ranges` entry as
  nGnRnE (`m1n1:src/memory.c:397-418`). Some regions only respond when their PMGR power domain is on (`docs:docs/hw/soc/memmap.md`,
  "MMIO ranges that respond to probe reads").
* Address `0` is unmapped: a read from EL2 gives a synchronous data abort with `L2C_ERR_STS` set ("unmapped (L2C faults)",
  `docs:docs/hw/soc/memmap.md:9`; `docs:docs/platform/dev-quickstart.md:497-517` shows `ESR_EL2 0x96000018`).
* PA span in use: highest documented MMIO `0x6_ffff_ffff`, DRAM to `0x9_ffff_ffff` (8 GiB) or `0xb_ffff_ffff` (16 GiB), so a >= 36-bit
  physical address space is needed. Hypervisor.framework default IPA size is exactly 36 bits (`0x10_0000_0000`) [M].

---

## 4. AIC (Apple Interrupt Controller), AICv1 on t8103

DT: `compatible = "apple,t8103-aic","apple,aic"`, `#interrupt-cells = <3>` (`t8103.dtsi:1029-1046`). Linux table maps
`apple,t8103-aic` to `aic1_local_fipi_info` = AIC version 1 with **fast IPIs** and **local fast IPIs**
(`linux:drivers/irqchip/irq-apple-aic.c:281-289,309-313`). Header comment: 896 level-triggered HW IRQs, per-IRQ affinity,
auto-mask on delivery, software trigger ORed with the HW line, 2 per-CPU IPIs, single event register per CPU where lower
IRQ numbers have higher priority (`irq-apple-aic.c:11-30`).

### 4.1 MMIO register map (offsets from `0x2_3b10_0000`) [C]

| Offset | Name | Access | Function | Source |
|---|---|---|---|---|
| `0x0004` | `INFO` | R | `[15:0]` `NR_IRQ` (register dump from a real M1 in the wiki shows `0x000a0380`, i.e. 896 IRQs) | `irq-apple-aic.c:71-72`; `docs:docs/platform/dev-quickstart.md:453-456` [W] |
| `0x0010` | `CONFIG` | RW | global config; not touched by the v1 Linux driver | `irq-apple-aic.c:74`; `docs:docs/hw/soc/aic.md` |
| `0x2000` | `WHOAMI` | R | index of the reading CPU; Linux requires it to equal the logical CPU number | `irq-apple-aic.c:76,900` |
| `0x2004` | `EVENT` | R | **acknowledge**: `[31:24]` die, `[23:16]` type (1 = HW IRQ, 4 = IPI), `[15:0]` number; 0 = nothing pending. Reading it masks the delivered IRQ | `irq-apple-aic.c:77-86,391-421` |
| `0x2008` | `IPI_SEND` | W | bit `n` (0..) = send "other" IPI to CPU `n`; bit 31 = "self" IPI | `irq-apple-aic.c:88,93-96` |
| `0x200c` | `IPI_ACK` | W1C | bit 0 = other, bit 31 = self | `:89` |
| `0x2024` / `0x2028` | `IPI_MASK_SET` / `IPI_MASK_CLR` | W | same bit layout as `IPI_ACK` | `:90-91` |
| `0x3000 + 4*irq` | `TARGET_CPU` | RW | one word per IRQ; CPU bitmask (Linux writes `BIT(cpu)`) | `:98,459` |
| `0x4000` | `SW_SET` | W1S | software-trigger bits, 32 IRQs per word, ORed with HW line | derived: `irq-apple-aic.c:1004-1033` |
| `0x4080` | `SW_CLR` | W1C | | |
| `0x4100` | `MASK_SET` | W1S | 1 = masked | |
| `0x4180` | `MASK_CLR` | W1C | 1 = unmask | |
| `0x4200` | `HW_STATE` | R | raw line state | `docs:docs/hw/soc/aic.md` [W] |
| `0x5008 + (cpu<<7)` etc. | per-CPU aliases of `IPI_SET/CLR/MASK_SET/MASK_CLR` | | defined but unused by Linux | `irq-apple-aic.c:100-103`; `m1n1:src/aic_regs.h:22-25` |
| `0x8020/0x8028` | mirror of `CNTPCT_EL0` low/high | R | **[W]** only | `docs:docs/hw/soc/aic.md` |

Offsets `0x4000..0x4200` are computed by the driver (`sw_set = target_cpu + 4*0x400 = 0x4000`; then each bank is
`0x400 >> 5 = 32` words = `0x80` bytes) and match `m1n1:src/aic_regs.h:13-16`. `MASK_REG(irq) = 4*(irq>>5)`,
`MASK_BIT(irq) = 1<<(irq&31)` (`:163-164`). AIC size in DT is `0x8000`; the Asahi memmap says `0xc000` (**DISCREPANCY**, harmless).

### 4.2 IRQ handling sequence (Linux behaviour to mirror) [C]

Init (`irq-apple-aic.c:1073-1083`): for every IRQ word write `MASK_SET = ~0`, `SW_CLR = ~0`, and `TARGET_CPU[irq] = 1` (CPU 0)
for all `nr_irq` IRQs. Per CPU (`aic_init_cpu`, `:859-920`): clear pending fast IPI, mask `CNTP_CTL`/`CNTV_CTL`, disable PMC FIQ sources
(see 4.4), `isb`, check `WHOAMI == cpu`, `IPI_ACK = SELF|OTHER`, then `IPI_MASK_SET = SELF|OTHER` (fast IPI mode; with fast IPIs
disabled: mask SELF, unmask OTHER).

Delivery/handler (`aic_handle_irq`, `:401-421`):
```
do {
    event = readl(EVENT);            // ordering: real (non-relaxed) read
    type = (event>>16)&0xff; num = event&0xffff;
    if (type == 1)  handle_hw_irq(num);          // die in [31:24]
    else if (type == 4 && num == 1) handle_ipi();  // "other" IPI
    else if (event != 0) error;
} while (event);
```
EOI for a HW IRQ = write `MASK_CLR` bit *after* the device has deasserted its line (the read of `EVENT` auto-set the mask) (`:391-399`).
Software mask/unmask = `MASK_SET`/`MASK_CLR` (`:369-389`). Affinity = `TARGET_CPU[irq] = BIT(cpu)` (`:459`). IRQ type: only level-high
and edge-rising accepted; there is no type register (`:465-472`).

Non-fast IPIs (unused on t8103 but the AIC-side protocol is in `docs:docs/hw/soc/aic.md`): write bit to `IPI_SEND` -> IRQ; read `EVENT`
(IPI masked automatically); write `IPI_ACK`; write `IPI_MASK_CLR`.

### 4.3 The IRQ / FIQ split

| Source | Vector | Notes |
|---|---|---|
| Peripheral HW IRQs (UART, PCIe, USB, NVMe, mailboxes, WDT...) | **IRQ** | via `EVENT`; DT `<AIC_IRQ n type>` |
| ARM generic timers (CNTP/CNTV, and the EL2 hyp timers) | **FIQ** | DT `<AIC_FIQ 0..3>`; no AIC involvement, no mask register except guest-timer enable |
| Fast (sysreg) IPIs | **FIQ** | `IPI_SR_EL1.PENDING` |
| CPU PMU (P and E), uncore PMU | **FIQ** | DT `<AIC_FIQ 4/5>` |
| vGIC maintenance | FIQ (only when Linux is a KVM host) | not needed |

The kernel therefore needs an FIQ vector that is a full interrupt entry (both IRQ and FIQ share the AIC domain). With `HCR_EL2.IMO/FMO`
set (m1n1's setting) and the kernel at EL2, both go to the EL2 vectors at offsets `0x280` (IRQ, SPx) and `0x300` (FIQ, SPx) [C-by-ARM].

### 4.4 FIQ demultiplexing (there is no FIQ status register) [C]

`aic_handle_fiq` (`irq-apple-aic.c:557-613`) tests, in this order:

1. Fast IPI: `IPI_SR_EL1 (S3_5_C15_C1_1) & 1` -> ack and process IPIs.
2. `CNTP_CTL_EL0`: `TIMER_FIRING = (ctl & (ENABLE|IMASK|ISTATUS)) == (ENABLE|ISTATUS)` (bits 0, 1, 2) -> "HV/EL0 physical timer".
3. `CNTV_CTL_EL0` likewise.
4. If kernel at EL2: `VM_TMR_FIQ_ENA_EL2` bit 1 (`P`) and `CNTP_CTL_EL02` firing; bit 0 (`V`) and `CNTV_CTL_EL02` firing.
5. `PMCR0_EL1 (S3_1_C15_C0_0)`: `(ctl & (IMODE | IACT)) == (IMODE_FIQ | IACT)` with `IMODE = bits[10:8]`, `4 = FIQ`, `IACT = bit 11`
   (`m1n1:src/cpu_regs.h:466-476`).
6. Uncore PMC: `UPMCR0_EL1 (S3_7_C15_C0_4)` `IMODE (bits[18:16]) == 4` and `UPMSR_EL1 (S3_7_C15_C6_4) & 1`.

"Not dealing with any of these results in a FIQ storm" (comment at `:568-572`). A FIQ can arrive for a source you do not use, so
all sources must be disabled at boot the way `aic_init_cpu` does (`:861-889`): timers masked, `PMCR0.IMODE=off`, `UPMCR0.IMODE=off`,
`IPI_SR` pending cleared, `VM_TMR_FIQ_ENA_EL2 = 0` (EL2 only).

### 4.5 Timer FIQ numbering in DT

`apple-aic.h` (`linux:include/dt-bindings/interrupt-controller/apple-aic.h:6-13`):
`AIC_IRQ=0, AIC_FIQ=1`; FIQ indexes `AIC_TMR_HV_PHYS=0, AIC_TMR_HV_VIRT=1, AIC_TMR_GUEST_PHYS=2, AIC_TMR_GUEST_VIRT=3, AIC_CPU_PMU_E=4,
AIC_CPU_PMU_P=5`. `t8103.dtsi:368-376`: `timer` node lists `phys`=GUEST_PHYS, `virt`=GUEST_VIRT, `hyp-phys`=HV_PHYS, `hyp-virt`=HV_VIRT.

Meaning (driver comment `irq-apple-aic.c:220-239`): the *_EL0-encoded registers `CNTP_*_EL0/CNTV_*_EL0` and the *_EL02-encoded registers are two
different physical timers. At EL2 with VHE the EL0 encodings alias the **hyp** timers (`HV_PHYS`/`HV_VIRT`, FIQ 0/1) and the EL02 encodings
reach the **guest** timers (FIQ 2/3). At EL1 the EL0 encodings are the guest timers, so the driver remaps DT `GUEST_PHYS/VIRT` to the EL0 pair and
rejects `HV_*` (`:718-736`).

### 4.6 Apple IMP-DEF system registers involved

Encodings are `S<op0>_<op1>_C<CRn>_C<CRm>_<op2>` (`sys_reg(op0,op1,CRn,CRm,op2)`).

| Name | Encoding | Fields | Source |
|---|---|---|---|
| `IPI_RR_LOCAL_EL1` (W) | `S3_5_C15_C0_0` | `[7:0]` target core, `[29:28]` type (0 immediate, 1 retract, 2 deferred, 3 nowake). Same-cluster target only | `irq-apple-aic.c:171-180` |
| `IPI_RR_GLOBAL_EL1` (W) | `S3_5_C15_C0_1` | `[7:0]` core, `[23:16]` cluster (= MPIDR Aff1), `[29:28]` type | `:172-180`; m1n1 uses `(mpidr & 0xff) \| ((mpidr & 0xff00) << 8)` (`m1n1:src/smp.c:485`) |
| `IPI_SR_EL1` (RW) | `S3_5_C15_C1_1` | bit 0 pending, **write 1 to clear**, `isb` afterwards | `:183-184,822-823`; `docs:docs/hw/cpu/system-registers.md:506-512` |
| `IPI_CR_EL1` | `S3_5_C15_C3_1` | `[15:0]` deferred IPI countdown (REFCLK ticks) | `:192`; docs |
| `VM_TMR_FIQ_ENA_EL2` | `S3_5_C15_C1_3` | bit 0 = V (guest CNTV) FIQ enable, bit 1 = P (guest CNTP) FIQ enable | `:187-189`; `docs:...:499-504` |
| `VM_TMR_LR_EL2` | `S3_5_C15_C1_2` | GIC-LR-like pending state of guest CNTV | `docs:...:119,493-497` [W] |
| `PMCR0_EL1` | `S3_1_C15_C0_0` | `IMODE [10:8]`, `IACT [11]` | `m1n1:src/cpu_regs.h:466-476` |
| `UPMCR0_EL1` / `UPMSR_EL1` | `S3_7_C15_C0_4` / `S3_7_C15_C6_4` | `IMODE [18:16]` / `IACT [0]` | `irq-apple-aic.c:195-204` |
| `CYC_OVRD_EL1` | `S3_5_C15_C5_0` | `[0]` disable WFI return, `[21:20]` FIQ mode, `[23:22]` IRQ mode (2 = disable), `[25:24]` WFI mode (2 = "up", 3 = deep) | `m1n1:src/cpu_regs.h:530-537`; `docs:...:378-383`; `m1n1:src/chickens.c:247-253` |
| `SIQ_CFG_EL1` | `S3_4_C15_C10_4` | writing 3 stops AICv2 IRQs to that core (AICv2 only; m1n1 writes 2 on all M1s) | `docs:...:735-737`, `m1n1:src/chickens.c:228-231`, `cpu_regs.h:518` |

**DISCREPANCY**: the wiki describes `IPI_RR` target fields as `[3:0]` core and `[20:16]` cluster (`docs:...:476-489`); both Linux and m1n1 use
`[7:0]` and `[23:16]`. Use the code.

Fast IPI sequence (`irq-apple-aic.c:796-836`): send = `msr IPI_RR_{LOCAL,GLOBAL}, (core | cluster<<16)` then `isb`. Receive = FIQ; handler reads
`IPI_SR`, writes `IPI_SR = 1`, `isb`, then processes the software IPI mux. Per-target "self" IPIs are not used.

---

## 5. Timers

* Counter frequency: **24 MHz** (`sched_clock: 56 bits at 24MHz`, `docs:docs/platform/dev-quickstart.md:673`; `CNTFRQ_EL0` measured
  `0x16E3600` in a guest [M]; m1n1 uses `CNTFRQ_EL0` everywhere, e.g. `m1n1:src/utils.c:97-118`; also `clkref` = 24 MHz in DT, `t8103.dtsi:390-396`).
  Counters are 56 bits wide per the boot log. M3+ has a scaled counter redirect (irrelevant to M1, `m1n1:src/chickens.c:260-264`).
* Timer sources at the **CPU**: the standard ARMv8 generic timers, "bypasses AIC. It is wired straight to FIQ" (`docs:docs/hw/soc/aic.md`, "Timer").
* Which timer Linux uses (`linux:drivers/clocksource/arm_arch_timer.c:1108-1121`, comment `:1091-1106`): kernel in hyp mode (VHE) -> the **hyp physical timer** (VHE
  redirects `CNTP_*_EL0` to `CNTHP_*_EL2`; DT `hyp-phys` = FIQ 0); kernel at EL1 with no hyp available -> the **virtual timer**
  (DT `virt` = `AIC_TMR_GUEST_VIRT`, remapped to the EL0 pair by `aic_irq_domain_translate`, `irq-apple-aic.c:718-736`).
* Masking/acking: there is no AIC-level mask for timers except the guest-timer pair. To mask a timer FIQ set `CTL.IMASK` (bit 1);
  Linux's FIQ ack is a no-op for the EL0/hyp timers and relies on the timer driver disabling/masking the timer in its handler
  (`irq-apple-aic.c:500-537` only touches `VM_TMR_FIQ_ENA_EL2` for `EL02_*`). The condition "timer is asserting FIQ" is
  `ENABLE && !IMASK && ISTATUS` (`:552-555`).
* m1n1 clears all timer FIQ sources before handing off by writing `7` to `CNTP_CTL_EL0`, `CNTV_CTL_EL0` (and the `_EL02` variants at EL2)
  (`m1n1:src/exception.c:133-139`).
* Suggested for coolcom: use the **virtual timer (`CNTV_*`) at both ELs**. At EL2/VHE the EL0 encoding hits `CNTHV` (FIQ index 1, `HV_VIRT`), at EL1 it hits the
  guest virtual timer (FIQ index 3). m1n1 itself handles both `PHYS` and `VIRT` EL0 timer FIQs at EL2 (`m1n1:src/exception.c:398-421`),
  so both fire on real hardware **[?]** (not exercised by me; Linux picks hyp-phys, index 0).
* `CNTFRQ_EL0` and `CNTVOFF` are set by firmware/m1n1 consistently; Linux's boot protocol requires this (`booting.rst:195-198`).

---

## 6. UART (Samsung/S5L style)

DT: `compatible = "apple,s5l-uart"`, `reg-io-width = <4>`, `clocks = <&clkref>, <&clkref>` (24 MHz), `interrupts = <AIC_IRQ 605 LEVEL_HIGH>` for
`serial0` at `0x2_3520_0000`; `serial2` at `0x2_3520_8000`, IRQ 607; `chosen/stdout-path = "serial0"`
(`t8103.dtsi:878-904`, `t8103-jxxx.dtsi:30`). The Linux driver info: FIFO size **16**, `iotype = UPIO_MEM32`, so **only 32-bit
accesses** (`linux:drivers/tty/serial/samsung_tty.c:2564-2588`; early console `:2861-2878`, which also maps the console page nGnRnE).

### 6.1 Registers [C]

| Offset | Name | Bits used | Source |
|---|---|---|---|
| `0x00` | `ULCON` | line control (`[1:0]` = 3 for 8 data bits) | `linux:include/linux/serial_s3c.h:21,33-45` |
| `0x04` | `UCON` | `[1:0]` RX mode (1 = IRQ/poll), `[3:2]` TX mode; Apple: bit 9 `RXTO_ENA`, 11 `RXTO_LEGACY_ENA`, 12 `RXTHRESH_ENA`, 13 `TXTHRESH_ENA` | `serial_s3c.h:249-264`; `m1n1:src/uart_regs.h:11-16` |
| `0x08` | `UFCON` | bit 0 FIFO enable, bit 1 reset RX, bit 2 reset TX, `[5:4]` RX trigger | `serial_s3c.h:119-141`; `samsung_tty.c:1254-1290` |
| `0x0C` | `UMCON` | modem control | |
| `0x10` | `UTRSTAT` | bit 0 `RXD` (data ready), bit 1 `TXBE` (tx buffer empty), bit 2 `TXE` (transmitter empty); Apple IRQ status (**write 1 to clear**): bit 3 `RXTO_LEGACY`, 4 `RXTHRESH`, 5 `TXTHRESH`, 9 `RXTO` | `m1n1:src/uart_regs.h:18-24`; `serial_s3c.h:266-270`; `samsung_tty.c:954-975` |
| `0x14` | `UERSTAT` | errors | |
| `0x18` | `UFSTAT` | `[3:0]` RX count, `[7:4]` TX count, bit 8 RX full, bit 9 TX full | `uart_regs.h:26-29`; `serial_s3c.h:155-160` |
| `0x1C` | `UMSTAT` | | |
| `0x20` | `UTXH` | TX byte (write as 32-bit) | |
| `0x24` | `URXH` | RX byte | |
| `0x28` | `UBRDIV` | baud divisor: `((24_000_000 / baud + 7) / 16) - 1` | `m1n1:src/uart.c:106-112` |
| `0x2C` | `UFRACVAL` | fractional divider | `uart_regs.h:9` |

### 6.2 Minimal polled sequence (what m1n1 itself does; UART is already configured by iBoot/m1n1) [C]

```
TX byte c:  while (!(rd32(UART+0x10) & (1<<1))) ;   // UTRSTAT.TXBE   (m1n1 uart_putbyte)
            wr32(UART+0x20, c);                     // UTXH
  (Linux FIFO-mode variant: wait until !(rd32(UART+0x18) & (1<<9)) i.e. UFSTAT.TXFULL clear)
Flush:      while (!(rd32(UART+0x10) & (1<<2))) ;   // UTRSTAT.TXE
RX byte:    while (!(rd32(UART+0x10) & 1)) ;        // UTRSTAT.RXD
            c = rd32(UART+0x24) & 0xff;             // URXH
newline:    emit '\r' before '\n'
```
(`m1n1:src/uart.c:37-56,114-118`, `m1n1:src/start.S:debug_putc` for the raw early variant; Linux polled console `samsung_tty.c:2269-2277` and
`samsung_early_putc` `:2745-2762`.) No init is needed after m1n1: m1n1 leaves the UART running at whatever baud iBoot/m1n1 set (m1n1 only
changes it if the proxy asks, `m1n1:src/proxy.c:76`). To (re)program: `UBRDIV = ((24e6/baud + 7)/16) - 1` (at 1.5 Mbaud -> 0).

### 6.3 Interrupt usage (Apple variant) [C]

Startup (`samsung_tty.c:1254-1290`): `UTRSTAT = 0x3f8` (clear all flags), install IRQ handler, `UFCON |= RESETRX|RXTRIG8` (+`RESETTX` unless console),
enable `UCON.RXTHRESH_ENA | RXTO_ENA | RXTO_LEGACY_ENA`. Handler (`:954-975`): read `UTRSTAT`; if any RX status bit, write it back to clear, drain RX FIFO; if `TXTHRESH`, write back to clear and refill TX.
**TX IRQs are edge-like**: "The Apple version only has edge triggered TX IRQs, so we need to kick off the process by sending some characters" (`:415-418`).
RX interrupt sources are level: `RXTHRESH` (FIFO >= trigger), `RXTO`/`RXTO_LEGACY` (idle timeout). The AIC line is level-high.

### 6.4 Reference emulation

m1n1's hypervisor emulates exactly the useful subset in ~60 lines (`m1n1:src/hv/hv_vuart.c:80-134`): `UCON` (rw), `UTXH` (write -> host byte stream), `URXH`
(read -> next host byte or 0), `UTRSTAT` (reads: `TXBE|TXE` always set, `RXD` when bytes queued, IRQ bits derived from `UCON`; writes clear IRQ bits),
`UFSTAT` (`RXCNT` = min(queued,15), `RXFULL` if >15), everything else reads 0. It raises the AIC IRQ by setting the software-trigger bit
(`aic_set_sw`), a technique the VM monitor can copy for AIC's `SW_SET`.

---

## 7. SMP bring-up

### 7.1 Topology [C]

| Logical CPU | Core | `MPIDR_EL1` | Cluster | DT `reg` | DT node |
|---|---|---|---|---|---|
| 0..3 | Icestorm (E), 4 cores, shared 4 MiB L2 | `0x8000_0000 + n` (Aff2=0, Aff1=0, Aff0=n) | `cluster0` | `0x0..0x3` | `cpu@0..3` (`t8103.dtsi:63-117`) |
| 4..7 | Firestorm (P), 4 cores, L2 12 MiB shared | `0x8001_0100 + n` (Aff2=1, Aff1=1, Aff0=n) | `cluster1` | `0x10100..0x10103` | `cpu@10100..10103` (`:119-173`) |

* `MPIDR_EL1` layout: `[23:16]` Aff2 (0 = E, 1 = P), `[15:8]` Aff1 = cluster, `[7:0]` Aff0 = core; bit 31 RES1
  (`docs:docs/hw/cpu/system-registers.md:704-709`; real values in the boot log `docs:docs/platform/dev-quickstart.md:487,567-603`).
* DT `reg` is `MPIDR & 0xFFFFFF`; the boot CPU is CPU 0 (`0x80000000`, an E core; `boot_cpu_idx` = the ADT node with `state="running"`, `m1n1:src/smp.c:361-383`).
* AIC CPU numbering = logical index 0..7 (E0-3, P0-3); Linux warns if `AIC.WHOAMI != smp_processor_id()` (`irq-apple-aic.c:900`).
* Caches: E: I 128 KiB, D 64 KiB; P: I 192 KiB, D 128 KiB; L2 E 4 MiB, P 12 MiB (`t8103.dtsi:74-75,129-130,175-187`).
* MIDR: implementer `0x61` (Apple) in bits `[31:24]`; part `0x022` = Icestorm, `0x023` = Firestorm (`m1n1:src/midr.h:25-26`). The boot CPU (CPU 0) of the wiki log reports `0x611f0221`, i.e. Icestorm (`docs:docs/platform/dev-quickstart.md:633`).
* Performance domains/cpufreq blocks are separate MMIO (section 3.2); not needed to run.

### 7.2 How secondaries are started (what m1n1 has already done by the time we run) [C]

`smp_start_secondaries()` runs in `payload_run()` before the DT is prepared (`m1n1:src/payload.c:318`). For each core (`m1n1:src/smp.c:152-212`):

1. `RVBAR` for that core: write `_vectors_start` to the core's `cpu-impl-reg` (ADT) (`+0x0`; `bit 0` = lock, `[47:12]` address; RVBAR of the boot CPU is locked by iBoot,
   others are free) (`smp.c:28-29,184-187`; `docs:docs/hw/cpu/smp.md:43-47`).
2. PMGR "CPU start block" at `PMGR_base + 0x54000` for M1 (`smp.c:17,309-313`; `docs:docs/hw/cpu/smp.md:11-17`), i.e. `0x2_3b75_4000` on t8103:
   * `+0x4`: system-wide core-alive mask; write `1 << (4*cluster + core)` (needed for AIC interrupts to work) (`smp.c:193`).
   * `+0x8 + 4*cluster`: per-cluster start register; write `1 << core` (`smp.c:196`; cluster 0 = E at `+0x8`, cluster 1 = P at `+0xc`).
   * `+0x0`: write `1 << (4*cluster+core)` requests stop (`smp.c:229`).
3. The core resets into m1n1's `_vectors_start` (`cpu_reset`), applies chicken bits (`init_cpu`), sets `exception_initialize()` (VBAR, HCR_EL2 as in 2.3, `DAIF = 3<<6` = I,F masked, SError unmasked
   on secondaries, `exception.c:158-160`), and enters `smp_secondary_entry()` (`startup.c:216-239`).
4. It parks in a loop on its **spin-table entry** (`struct spin_table {mpidr; flag; target; args[4]; retval;}`, `smp.c:31-37`), waiting for `target != 0`. Before handoff
   `kboot_boot()` sets **WFE mode** (`smp_set_wfe_mode(true)`, `kboot.c:2920`): the loop is `wfe`, so a `sev` wakes it (`smp.c:118-134`).
5. m1n1 fills each CPU node's `cpu-release-addr` with the address of that entry's `target` field (`&spin_table[cpu].target`, `smp.c:560-575`, `kboot.c:589-591`);
   sample: `release-addr=0x8153c4050` for CPU 0, spacing `0x40` (`docs:docs/platform/dev-quickstart.md:611-618`).

### 7.3 Wake protocol for the kernel (enable-method `spin-table`) [C]

DTS: `enable-method = "spin-table"; cpu-release-addr = <0 0>; /* To be filled by loader */` on every CPU (`t8103.dtsi:67-68` ...).
Linux (`linux:arch/arm64/kernel/smp_spin_table.c:43-120`, `head.S:337-349`):

```
release = ioremap_cache(cpu-release-addr, 8);
*release = PA(secondary entry);        // 64-bit little-endian store
dcache_clean_inval_poc(release, 8);    // dc civac + dsb
sev();
```
m1n1 then calls `((u64(*)(a,b,c,d))target)(args[0..3])` from its loop with `args[]` zeroed (`smp.c:138-139`; `smp_get_release_addr` zeroes them, `smp.c:560-575`), so **the secondary enters at the given PA
with x0..x3 = 0, EL2, MMU off (m1n1 only enables the MMU on secondaries for the hypervisor/proxy, `m1n1:src/proxy.c:322`, `m1n1:src/hv/hv.c:343`), IRQ/FIQ masked, SError unmasked (`DAIF.A=0`), `SP` = m1n1's private per-CPU stack (do not rely on it)**
(x30 holds a return address into m1n1: a `ret` returns the core to m1n1's park loop). Linux's holding pen then spins on a variable with `wfe` until the boot CPU sets it to the MPIDR
(`head.S:337-349`); we can skip the pen and jump straight to the real secondary entry.

Rules for our kernel: (a) the boot CPU and every secondary must mask `DAIF` first thing; (b) the kernel must not clobber m1n1 reserved memory until all cores are released
(the release words live in m1n1's `.data.smp_shared`, inside the image region m1n1 reserves via `fdt_add_mem_rsv(_base.._end)`, so treat that region as off-limits forever); (c) no PMGR access is needed; (d) `AIC WHOAMI` must be the logical id you index per-CPU state with.

Hypervisor/VM equivalent: see 11.

---

## 8. Framebuffer

* `boot_args.video` = `{base, display, stride, width, height, depth}` (`m1n1:src/xnuboot.h:9-16`); m1n1 copies it into `/chosen/framebuffer@<base>` (`m1n1:src/kboot.c:180-254`):

  | Property | Value |
  |---|---|
  | `compatible` | `"apple,simple-framebuffer","simple-framebuffer"` (already in DTB, `t8103-jxxx.dtsi:33`) |
  | `reg` | `<base(64) size(64)>` with `size = stride * height` (notch lines excluded on notched MacBooks; not relevant on Mac mini) |
  | `width`, `height`, `stride` | `boot_args.video.width`, `height - notch`, `stride` (bytes per line) |
  | `format` | depth 32 -> `"x8r8g8b8"`; depth 30 -> `"x2r10g10b10"`; depth 16 -> `"r5g6b5"`; anything else: node left disabled |
  | `power-domains` | `<&ps_disp0_cpu0>` (`t8103-jxxx.dtsi:35`) - m1n1 already turned display power on; keep it on |
  | `status` | `"disabled"` in the DTB; m1n1 deletes the property when it can fill the node |

* Real sample (Mac mini, 1080p): `framebuffer@9e0df8000 base 0x9e0df8000 size 0x7e9000` = 1920 x 1080 x 4 (`docs:docs/platform/dev-quickstart.md:608`). The framebuffer sits near the top of the 8 GiB DRAM window (~30 MiB below `0xa_0000_0000`), above the `/memory` range.
* Pixel format `x8r8g8b8`: little-endian 32-bit word `0x00RRGGBB`, i.e. byte order B, G, R, X in memory.
* Cache attributes: m1n1 maps it **Normal non-cacheable** (`MAIR_IDX_NORMAL_NC`) after flushing (`m1n1:src/memory.c:455-460`); do the same (or clean+inval after writes). Device-nGnRnE works but is slow.
* Limits: the panel/HDMI mode is whatever iBoot/m1n1 left. Changing resolution needs the DCP coprocessor (RTKit firmware + IOMFB protocol); no driver = no mode setting, no brightness/HPD handling. m1n1 puts the DCP to sleep for external displays "so dodgy monitors which cause reconnect cycles don't cause us to lose the framebuffer"
  (`m1n1:src/main.c:170-172,201`); hot-plug or monitor power-cycle may blank it **[?]**.
* Finding it: parse `/chosen/framebuffer@*` (`compatible` contains `simple-framebuffer`). Fall back: none (m1n1 doesn't pass `boot_args` to the kernel).

---

## 9. MMU specifics

| Topic | Facts |
|---|---|
| Granules | **16K: certainly supported on M1** (m1n1 and Asahi Linux run with it; m1n1 selects 16K when `ID_AA64MMFR0[23:20]==1`, `m1n1:src/utils.h:369-383`, and programs `TCR` from that, `memory.c:551-557`). **4K: supported** - "these machines can boot 4K kernels" but need hacks for DARTs (`docs:docs/sw/broken-software.md:16-18`). **64K: unconfirmed for M1**; the guest view on my M6 host is TGran4=0 (supported), TGran16=1 (supported), TGran64=0xf (not supported) (`ID_AA64MMFR0_EL1 = 0x10000f100022` [M]); I have not read a real M1 ID register **[?]**. |
| Why 16K | All Apple DARTs (IOMMUs in front of every DMA master) are 16K-page: "the IOMMUs only support 16K-aligned pages... [4K kernels] require some very hacky patches" (`docs:docs/sw/broken-software.md:16-19`); DART page size comes from a hardware parameter (`linux:drivers/iommu/apple-dart.c:1369`). Using 16K CPU pages means a CPU physical page can be mapped 1:1 into a DART. |
| Address sizes | m1n1: `T0SZ = T1SZ = 48-bit VA`, `IPS = 4 TB` (`memory.c:551-557`); actual `PARange` of a real M1 not read (needs >= 36 bit, see 3.2). |
| MMIO attribute | **nGnRnE (non-posted)**: `nonposted-mmio;` on the `soc` bus (`t8103.dtsi:473`) makes Linux use `ioremap_np()` = `PROT_DEVICE_nGnRnE` (`linux:arch/arm64/include/asm/io.h:288-289`); the Apple earlycon explicitly re-maps nGnRnE (`samsung_tty.c:2867-2873`); m1n1 maps all ARM-IO ranges nGnRnE (`memory.c:397-418`), and only ADT `pmap-io-ranges` entries with flag nibble 8 as nGnRE (`memory.c:440-445`). Rule: map every SoC MMIO page nGnRnE; use plain `ldr/str` (w/x) for register access. |
| MAIR | m1n1 uses: idx0 Normal WB `0xff`, idx1 Normal NC `0x44`, idx2 Device-nGnRnE `0x00`, idx3 Device-nGnRE `0x04`, (idx4 nGRE, idx5 GRE) (`memory.c:169-174,547-550`). |
| DMA/cache | PCIe `dma-coherent` in DT (`t8103.dtsi:1695...`); other masters are behind DARTs and treated non-coherent unless the DT says otherwise **[?]**. Framebuffer: use NC mapping. |
| Cache maintenance | m1n1 sets `HID4/EHID4 DISABLE_DC_MVA \| DISABLE_DC_SW_L2_OPS` on all M1 cores (`chickens.c:208-213`); the functional consequence is not documented in what I read, but it suggests never relying on set/way ops for L2 - use by-VA maintenance (`dc civac/cvac`) for anything that matters. m1n1's `mmu_shutdown` uses `dcsw_op_all` for L1 only (`memory.c:660`). |
| SError / faults | Access to an unmapped PA raises an *external* abort that is reported at the access (sync abort, `ESR_EL2 0x96000018`) with details in the Apple `L2C_ERR_STS/ADR/INF_EL1` registers (`L2C_ERR_STS_EL1 = S3_3_C15_C8_0`, `docs:docs/hw/cpu/system-registers.md:81`); the wiki notes the enable flags (incl. bit 39 "Enable SError interrupts") are all 1 on entry from iBoot [W]. Handle/clear via write-1-to-clear (`docs:docs/hw/cpu/system-registers.md:394-407`; `docs:docs/platform/dev-quickstart.md:497-525`). Keep `DAIF.A` masked until VBAR is installed. |
| WFI | m1n1 sets `CYC_OVRD` FIQ/IRQ mode 0 (not disabled), WFI mode 2 ("up"), WFI retention on, for every core (`chickens.c:247-253`); "deep WFI" (`WFI_MODE=3`) is only used by m1n1's SMP park loop (`m1n1:src/utils.c:225-243`). Use plain `wfi` for idle; it wakes on IRQ/FIQ even when `PSTATE.I/F` are masked, as on any ARMv8 core. |
| Chicken bits | Per-core IMPDEF tuning registers are applied by m1n1 on **every core** before we run (`chickens.c:189-262`). If we ever bypass m1n1 (e.g. our own PMGR CPU start), they must be applied ("Chicken bits / etc must be applied as usual", `docs:docs/hw/cpu/smp.md:53`). |
| Other CPU quirks | PAC uses an Apple mode (`SYS_APL_APCTL_EL1`); AMX and SPRR/GXF exist and are left alone by m1n1 for a Linux payload. TSO can be requested with `tso=1` var (`payload.c:206-207,320-331`, sets `ACTLR_EL1[1]`). Not needed. |
| Boot `SCTLR` | Only `M,C,I = 0` is promised; program the whole of `SCTLR`/`TCR`/`MAIR` explicitly. |

---

## 10. Other devices (pointers only)

* **Keyboard/mouse.** Mac mini has no internal input devices: USB HID via xHCI. Two sources: (a) the two Type-C ports use a DWC3 controller behind the Apple ATC PHY
  and a USB-PD/Thunderbolt controller (`dwc3_0` `0x3_8228_0000` IRQ 777, `atcphy0` `0x3_8300_0000`; USB-PD controller on I2C0 `0x2_3501_0000`; Linux glue `drivers/usb/dwc3/dwc3-apple.c`, ATC PHY node `atcphy0`); (b) the Type-A ports come
  from a discrete xHCI on the PCIe root complex `port01` ("Mac Mini: additional on-board PCIe hardware (Ethernet & xHCI for type A ports)", `docs:docs/platform/dev-quickstart.md`; `t8103-j274.dts` enables `port01` (bus 2) and `port02` = Ethernet (bus 3)).
  (a) needs the ATC PHY/PD setup, (b) needs the Apple PCIe host driver (`linux:drivers/pci/controller/pcie-apple.c`); both need DARTs (`apple-dart.c`), then a standard xHCI/DWC3 driver does the rest. Guides: `docs:docs/sw/linux-bringup-usb.md`, `linux-bringup-usb-keyboard.md`.
* **NVMe.** Apple ANS2 controller, not a PCIe device: MMIO `0x2_7bcc_0000` (NVMe regs) + `0x2_7740_0000` (ANS), IRQ 590, mailbox `0x2_7740_8000`, plus **SART** (`0x2_7bc5_0000`, an address-range allow-list for the coprocessor's DMA) and RTKit firmware handshake
  over the mailbox (`t8103.dtsi:1514-1547`; Linux: `drivers/nvme/host/apple.c`, `drivers/soc/apple/{rtkit,sart,mailbox}.c`). Power domains `ps_ans2` and `ps_apcie_st` must be on. Non-trivial (RTKit + SART + queue quirks); postpone.
* **Power off / reboot.** *Reboot* = watchdog: registers at `0x2_3d2b_0000`: counter `+0x10` (24 MHz, 32-bit), alarm/bite `+0x14`, control `+0x1c` (`bit 2 = reset enable`); m1n1's reboot writes `ALARM=0x100000, COUNT=0, CTL=4` (`m1n1:src/wdt.c:12-14,52-58`; `docs:docs/hw/soc/wdt.md`; Linux: `linux:drivers/watchdog/apple_wdt.c:37-52,121-136`
  restart = `CTRL=RESET_EN, BITE=0, CUR=0`). Registers `+0x00/+0x04/+0x0c` (`WD0`) and `+0x20/24/2c` (`WD2`) reboot into recovery instead (wiki, [W]). *Power off* = SMC: RTKit-managed coprocessor at `0x2_3e40_0000`; Linux writes SMC key `MBSE = 'off1'`
  (`linux:drivers/power/reset/macsmc-reboot.c:75-104`) and restart via `MBSE='phra'` (`:113-123`). Without an SMC driver the best available "off" is a watchdog reset (the machine reboots into m1n1/macOS).
* **PMGR power domains.** Each peripheral has a 32-bit PS register in PMGR (`0x2_3b70_0000`, per-domain offsets listed in `t8103-pmgr.dtsi`, e.g. `ps_uart0` at `pmgr+0x270`, `ps_aic` at `+0x108`): `[3:0]` target state, `[7:4]` actual state, `0xf` = active, `0x4` = clock gated, `0x0` = power gated;
  `[9] WAS_CLKGATED`, `[8] WAS_PWRGATED`, `[10] DEV_DISABLE`, `[11] BUSY/parent-off`, `[12] PS_RESET`, `[28] AUTO_ENABLE`, `[31] RESET` (`linux:drivers/pmdomain/apple/pmgr-pwrstate.c:19-40`; `m1n1:src/pmgr.c:9-17,87-95`).
  Set target = 0xf and poll actual (timeout ~100 us). Parent domains must be enabled first (`m1n1:src/pmgr.c:154-200`). m1n1 leaves domains for UART0, AIC, display, and what it used for USB in the "on" state; everything else is as iBoot left it **[?]**.
* Others seen in the DTS that we can ignore for now: DCP/display pipe, ISP, AOP, SEP, SIO, ASC mailboxes, I2C/SPI, audio (`mca`, `admac`), SPMI, GPIO/pinctrl, cpufreq.

---

## 11. Proposed "M1-lite" VM (Hypervisor.framework) mirroring real hardware

### 11.1 What Hypervisor.framework gives us (all [M] unless noted)

| Capability | Result on macOS 27 / M6 host | Implication |
|---|---|---|
| Guest EL | Runs at **EL1** by default (`CurrentEL == 4`). `hv_vm_config_set_el2_enabled` exists and `hv_vm_config_get_el2_supported` = true on this host (`hvsdk/hv_vm_config.h:73,108`) | For the M1-lite model use EL1 |
| EL2-enabled guest | Starts at EL2; `HCR_EL2.E2H` can be written but `ID_AA64MMFR1.VH == 0` is reported; `CNTHP_*` and `CNTP_*` accesses trap to the host; Apple `S3_5_C15_*` accesses are **not** trapped to the host - they raise an exception in the guest's own EL2 (inferred: a fetch fault at `VBAR_EL2+0x200`) | Cannot emulate Apple IMP regs or VHE. Do not use EL2 mode |
| Apple IMP-DEF sysregs at EL1 (`S3_5_C15_C1_1`, `C1_2`, `C1_3`, `S3_5_C15_C0_1`, `S3_1_C15_C0_0`) | Trap to host: `HV_EXIT_REASON_EXCEPTION`, `EC=0x18`; ESR ISS decodes op0/op1/CRn/CRm/op2/Rt/direction; host writes `Rt` and advances PC by 4 | We can emulate `IPI_SR`, `IPI_RR_*`, `PMCR0`, `VM_TMR_*`, `UPMCR0` etc. |
| MMIO | Access to an unmapped IPA: `EC=0x24`, `physical_address` filled, `ISV=1` for a simple `ldr/str w` (measured; the `x` forms are architecturally the same) with `SRT` giving the register, write bit `WnR` = ESR bit 6 | Kernel MMIO accessors must be single `ldr/str` (no `ldp/stp`, no writeback, no SIMD) so that `ISV` is set |
| Physical timer | `CNTP_CTL/CVAL/TVAL_EL0` and `CNTPCT_EL0` **trap** to host (`S3_3_C14_C2_x`, `S3_3_C14_C0_1`) | Use the **virtual** timer in the guest; only emulate CNTP if a kernel insists |
| Virtual timer | Native. Fires -> `hv_vcpu_run` returns `HV_EXIT_REASON_VTIMER_ACTIVATED` and auto-sets the vtimer mask; host must inject FIQ and later `hv_vcpu_set_vtimer_mask(vcpu,false)` (`hvsdk/hv_vcpu.h:441-463`) | Timer FIQ model below |
| Interrupt injection | `hv_vcpu_set_pending_interrupt(vcpu, HV_INTERRUPT_TYPE_IRQ/FIQ, true)`; pending state is **cleared each time `hv_vcpu_run` returns** and must be re-asserted before every run (`hvsdk/hv_vcpu.h:332-337`). Injecting FIQ works. In my first probe a FIQ handler that never caused an exit did not leave the FIQ loop (run hung until cancelled), consistent with a level line that can only be dropped on an exit | Design rule in 11.4 |
| Counter | `CNTFRQ_EL0 = 24 MHz`; `CNTVCT = mach_absolute_time() - vtimer_offset` (`hv_vcpu_set_vtimer_offset`, `hvsdk/hv_vcpu.h:465-486`) | Matches M1's 24 MHz |
| MPIDR | `hv_vcpu_set_sys_reg(HV_SYS_REG_MPIDR_EL1, 0x80010100)` succeeds and is read back by the guest | Can present 0x80000000..3 / 0x80010100..3 |
| IPA space | default 36 bits, max 40, default granule 16 KiB; `hv_vm_map` requires page-aligned host address, IPA and size (`hvsdk/hv_vm.h:46-49`); host page = 16 KiB (`sysctl hw.pagesize`) | Fits `0x8_0000_0000..` DRAM and `0x2_xxxx_xxxx` MMIO. Guest RAM should be 16 KiB aligned |
| Guest ID regs | `MIDR 0x610f0000` (implementer Apple), `ID_AA64MMFR0 0x10000f100022`, `ID_AA64MMFR1 0x100011312000` (host's, not an M1's) | Kernel feature detection must not assume M1-exact IDs |
| GIC | `hv_gic_create` (GICv3) exists (macOS 15+) but injection APIs are then unsupported and the interrupt controller is architecturally different | Do **not** use; AIC must be emulated in software |
| Multiple vCPUs | one host thread per vCPU (`hv_vcpu_create` per thread); `hv_vcpus_exit()` kicks a running vCPU | Needed for IPIs and interrupt delivery to a different vCPU |

Probe sources (throw-away, not in the repo): assembled guest code embedded in a small C host, run with `com.apple.security.hypervisor` ad-hoc signed.

### 11.2 Device set and addresses (mirror t8103 so drivers/DT are unchanged)

| Device | Address | Behaviour to emulate |
|---|---|---|
| DRAM | `0x8_0000_0000`, size configurable (default 2 GiB; 8 GiB mirrors the real 8 GiB Mac mini), 16 KiB-aligned | plain `hv_vm_map` RWX. Kernel image at a 2 MiB-aligned address near the base (like m1n1 heap), FDT above it |
| UART0 | `0x2_3520_0000` (0x4000 decode, DT says 0x1000) | Section 6.4: `UCON`, `UTXH`, `URXH`, `UTRSTAT` (TXBE\|TXE always, RXD/RXTHRESH/RXTO with W1C IRQ bits), `UFSTAT`, `UBRDIV/UFCON/ULCON` read/write storage; IRQ 605 via AIC `SW_SET`-style level line. 32-bit access only |
| AIC v1 | `0x2_3b10_0000`, 0x8000 | Section 4.1 registers: `INFO` (NR_IRQ = 0x380 to match M1, or lower), `WHOAMI`, `EVENT` (ack + auto-mask, priority = lowest number), `TARGET_CPU`, `SW_SET/CLR`, `MASK_SET/CLR`, `HW_STATE`, `IPI_SEND/ACK/MASK_*` |
| Timer | architectural CNTV (native) + FIQ | DT keeps the 4-entry `timer` node from `t8103.dtsi:368-376` |
| Fast-IPI + PMU + UPMU sysregs | trap-and-emulate | see 11.3 |
| WDT | `0x2_3d2b_0000`, 0x4000 | `WD1` at `+0x10/14/1c`: counter (24 MHz), bite time, control (bit 2 = reset-enable). Reset -> VM restarts. Lets the kernel implement reboot with the real code |
| Framebuffer | at a fixed IPA near the top of DRAM (e.g. `0x9_0000_0000 - fbsize`, outside `/memory`) | host `mmap` shared with a window; `simple-framebuffer` node identical to 8. Format `x8r8g8b8`, stride = width*4 |
| Boot CPU state | see 11.5 | |
| PMGR / DART / NVMe / USB / PCIe | absent | Add later as needed |

Everything else that the DTS lists but we don't emulate should be **omitted from the synthesized FDT** (or `status="disabled"`), because m1n1's post-processing is not part of the VM.

### 11.3 Sysreg traps to implement (EL1 guest, all read returns / effects)

| Register | Read | Write |
|---|---|---|
| `S3_5_C15_C1_1` `IPI_SR_EL1` | bit 0 = a fast IPI is pending for this vCPU | bit 0: clear pending. Treat any exit on this reg as "FIQ handler running" (see 11.4) |
| `S3_5_C15_C0_0` `IPI_RR_LOCAL_EL1`, `S3_5_C15_C0_1` `IPI_RR_GLOBAL_EL1` | (write-only) | set target vCPU's pending flag, kick it with `hv_vcpus_exit`; on next run it gets the FIQ. Decode `[7:0]` core, `[23:16]` cluster |
| `S3_5_C15_C3_1` `IPI_CR_EL1` | 0 | deferred-IPI countdown; may treat as immediate |
| `S3_5_C15_C1_3` `VM_TMR_FIQ_ENA_EL2` | 0 | ignore (EL2-only in real HW) |
| `S3_1_C15_C0_0` `PMCR0_EL1` | 0 (IMODE off, IACT clear) | store/ignore |
| `S3_7_C15_C0_4` `UPMCR0_EL1`, `S3_7_C15_C6_4` `UPMSR_EL1` | 0 | ignore |
| `CNTP_*_EL0`, `CNTPCT_EL0` | only if the kernel uses CNTP | emulate from `mach_absolute_time` if needed |

### 11.4 Timer / FIQ delivery model for the VM

1. Guest programs `CNTV_CVAL/CTL` (native). When it expires: `hv_vcpu_run` returns `HV_EXIT_REASON_VTIMER_ACTIVATED`; vtimer is now masked by the framework.
2. Monitor sets `fiq_level[vcpu] = 1`. Before **every** `hv_vcpu_run` it does `hv_vcpu_set_pending_interrupt(vcpu, FIQ, fiq_level)` (also true while any other FIQ source, e.g. fast IPI, is pending).
3. The guest takes FIQ and its FIQ handler, like Asahi's, reads `IPI_SR_EL1` first -> **trap -> exit -> pending state is cleared by the framework**; the monitor recomputes `fiq_level` (remains 1 only for still-pending IPIs). [M: this exact sequence was exercised and works; the FIQ fired once]
4. To re-arm the vtimer without losing an interrupt, end the kernel's FIQ handler with a trapping access too (e.g. `msr S3_5_C15_C1_1, #1` "clear IPI pending", harmless on real HW where Linux does the same at `irq-apple-aic.c:865`): on that exit the monitor calls `hv_vcpu_set_vtimer_mask(vcpu, false)` if `CNTV_CTL_EL0` shows no asserted condition (`ENABLE && !IMASK && ISTATUS`), else leaves it masked and re-injects. **[?]** The unmask ordering is a design proposal; only the exit/inject part was tested.
5. **Rule**: while a FIQ is asserted the guest keeps re-taking it; a handler that cannot cause an exit cannot drop the line (my first probe hung this way). Always design the guest FIQ path so its first instruction of substance causes an exit (the `IPI_SR` read).
6. Physical-timer-based kernels can't work on EL1 without emulating `CNTP_*`; keep the kernel on CNTV in both worlds (section 5).

HW IRQs: keep `irq_level[vcpu] = (any unmasked pending HW irq targeted at vcpu) || (unmasked pending IPI)`; assert `HV_INTERRUPT_TYPE_IRQ` before every run when true; the guest's read of AIC `EVENT` (MMIO exit) returns the highest-priority event and auto-masks it; `MASK_CLR` write recomputes and may drop the line.

### 11.5 FDT to synthesize (mirror what m1n1 hands to Linux)

Start from Linux `t8103-j274.dts` structure but keep only:
`/` (`compatible = "apple,j274","apple,t8103","apple,arm-platform"`, `#address-cells=2`, `#size-cells=2`), `/chosen` (`bootargs`, `stdout-path="serial0"`,
`framebuffer@<base>` filled: `reg`, `width`, `height`, `stride`, `format`), `/memory@800000000` (`reg = <0x8 0x0 0x0 size>`), `/reserved-memory` (empty or framebuffer/firmware),
`/cpus` with cpu nodes `reg = 0x0..0x3, 0x10100..0x10103` (or fewer), `enable-method="spin-table"`, `cpu-release-addr` filled with the IPA of an 8-byte word per CPU,
`timer` (4 FIQs as in `t8103.dtsi:368-376`), `aic` (`apple,t8103-aic`, `apple,aic`, reg `0x2 0x3b100000 0x0 0x8000`), `soc` (`nonposted-mmio`), `serial0` (`apple,s5l-uart`, `reg 0x2 0x35200000 0x0 0x1000`, IRQ `AIC_IRQ 605`, clocks `clkref`),
`clkref` (24 MHz fixed clock), `wdt` (`apple,t8103-wdt`, `0x2 0x3d2b0000`, IRQ 338).

Entry state to mimic (the "m1n1-lite" the monitor plays): `x0 = FDT IPA`, `x1..x3 = 0`, **EL1** (the VM cannot be EL2/VHE), MMU off, `SCTLR_EL1` as reset, `DAIF = 0x3c0` (all masked), `CNTV` disabled/masked.
Secondaries: do not start their vCPU threads at boot. Give each CPU an 8-byte release word (its IPA goes into `cpu-release-addr`) on a page mapped **read-only** (`HV_MEMORY_READ|HV_MEMORY_EXEC`) so the kernel's store traps
as a data abort (`EC=0x24`, IPA known); the monitor emulates the store, then creates/starts that vCPU at the stored entry PA with `x0..x3 = 0`, EL1, MMU off, `DAIF` masked - the same state m1n1 gives a woken secondary (the `sev` is then a no-op). **[?]** design proposal, not tested.
Hence the kernel entry path must branch on `CurrentEL`: EL2 (real HW: m1n1 gave VHE-host `HCR_EL2`, decide between staying at EL2/VHE or dropping to EL1 non-VHE) and EL1 (VM).

### 11.6 Differences the kernel must tolerate between VM and hardware

| Aspect | Real M1 (via m1n1) | M1-lite VM |
|---|---|---|
| EL at entry | EL2, VHE host mode | EL1 |
| Timer used | CNTHV/CNTV via E2H redirection (FIQ idx 1) or hyp-phys (idx 0) | guest CNTV (FIQ idx 3) |
| Apple IMP regs | native | trapped and emulated |
| Debug UART | physical / m1n1 HV virtual UART | emulated |
| Secondaries | parked by m1n1 in WFE loop | monitor-managed |
| ID registers | Apple M1 | host chip (M-series, any generation) |
| MMIO exit cost | none | 10s of microseconds; batch UART writes |
| Page size | 16 KiB (DART constraint) | stage-1 granule is the guest's choice; keep RAM and MMIO windows 16 KiB aligned (stage-2 IPA granule defaults to 16 KiB) |

---

## 12. Open questions (not verifiable from the material I read)

1. Does a **minimal** hand-written DTB pass `kboot_prepare_dt()`? Many `dt_set_*` helpers run; only the mandatory ones are identified above. Needs an experiment on hardware (or reading the remaining ~25 helpers for `bail()` on missing nodes).
2. Exact `ID_AA64MMFR0_EL1` (PARange, TGran*) and `ID_AA64MMFR1_EL1` (VH) of a real M1; I only have an M6 host's guest view.
3. Whether EL0-encoded `CNTV_*` at EL2/VHE (`HV_VIRT`, FIQ idx 1) reliably raises FIQ on t8103 without further setup (m1n1's handlers for it exist; Linux uses `hyp-phys` instead).
4. Whether guest-timer FIQs at EL1 on bare metal (HCR_EL2.FMO=0 after dropping to EL1) need `VM_TMR_FIQ_ENA_EL2` bits set. m1n1's HV routes them to EL2 and injects `HCR_EL2.VF` (`m1n1:src/hv/hv_exc.c:152-176`), so the direct EL1 case is unverified. Stay at EL2/VHE on real HW to avoid this.
5. Baud rate of UART0 as left by m1n1; and whether the physical UART is even enabled on a retail Mac mini without VDM "serial mode" (docs: needs `macvdmtool ... serial`).
6. DART default state: are all DARTs bypassed/aborting when the kernel starts? m1n1 does `dapf_init_all()` and leaves DART state as iBoot did (`kboot_boot`, `m1n1:src/kboot.c:2909-2916`); kernel should not start DMA without programming the relevant DART.
7. Cache-maintenance semantics behind `DISABLE_DC_MVA`/`DISABLE_DC_SW_L2_OPS` (`m1n1:src/chickens.c:208-213`).
8. What happens to the framebuffer if the external display re-syncs after DCP sleep.
9. 16 GiB Mac mini `phys_base`/carve-out layout (only the 8 GiB log was found).
10. Whether Hypervisor.framework can emulate the deferred-IPI (`IPI_CR_EL1`) timing (irrelevant if we treat every IPI as immediate).

Source disagreements collected: AIC size (DTS 0x8000 vs wiki 0xc000), UART size (0x1000 vs 0x4000), PMGR size (0x14000 vs 0x100000), `IPI_RR` field widths (wiki vs code).
