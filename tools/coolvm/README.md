# coolvm - an M1 (t8103) subset VM monitor on macOS Hypervisor.framework

coolvm boots a coolcom kernel image in a VM that looks like the real target (Apple M1 Mac mini,
booted by m1n1): same physical addresses, same register behaviour, same device-tree shapes. The
kernel's drivers are meant to be **identical** in the VM and on metal. Background and the
source-cited hardware facts are in `docs/m1-platform.md` (section 11 proposes this VM; this tool is
that proposal, with the findings below).

```
make coolvm-test                 # build (ad-hoc codesigned) + run the assembly test guest, under a timeout
tools/coolvm/build.sh            # -> build/coolvm
build/coolvm [--cpus N] [--mem MB] [--headless] [--disk image] [--net] [--net-forward H:G] [--timeout S] kernel.Image [kernel.dtb]
```

Options: `--cpus N` (1..8, default 2; order = 4 e-cores then 4 p-cores), `--mem MB` (default 256),
`--timeout S` (exit status 124), `--trace-mmio` (log every emulated MMIO and IMP-DEF sysreg access),
`--load-offset BYTES` (kernel load offset from the DRAM base, 2 MiB-aligned, >= 0x200000, default 0x200000; to test kernel self-relocation like m1n1 choosing another base), `--bootargs STR`, `--dump-dtb FILE` (inspect with `dtc -I dtb -O dts`), `--lenient` (unknown MMIO reads
0 / writes ignored), `--strict` (unknown sysreg is fatal), `--verbose`, `--el2` (experimental, see below).
Display/device options: `--headless` (no Cocoa window), `--width N` and `--height N` (default 1024×768),
`--screenshot FILE` (PNG at exit), `--input-script FILE` (preload input records), `--disk FILE` (writable raw
image, repeat up to four times), `--net` (virtio-net NIC behind a user-mode NAT, below). Framebuffer size is limited to 256 MiB; RAM is limited to 4 GiB so it
cannot overlap the framebuffer carve-out. A supplied DTB replaces the generated FDT verbatim and must
describe any VM devices the guest intends to use.
stdout is the guest UART, stderr is coolvm's diagnostics. Exit status: 0 guest powered off,
124 timeout, 1 fatal guest fault (state dump on stderr), 2 usage. Needs Xcode command line tools,
an Apple silicon Mac, and the ad-hoc `com.apple.security.hypervisor` entitlement that `build.sh` applies.

## What the guest sees

### Boot state (what m1n1 gives a payload vs. what coolvm gives)

| | m1n1 -> kernel (real M1) | coolvm |
|---|---|---|
| Entry | first byte of the Image, 2 MiB-aligned base; `text_offset` ignored | Image loaded at `0x8_0020_0000` (DRAM+2 MiB); `text_offset` ignored (warned if non-zero). No `ARM\x64` header -> loaded as a flat binary with a warning |
| x0 / x1..x3 | FDT physical address / 0 | same; FDT at the next 2 MiB boundary after the image (`image_size`, or file size if larger) |
| EL | **EL2**, `HCR_EL2 = E2H\|TGE\|RW\|AMO\|IMO\|FMO\|API\|APK\|TEA` (VHE host) | **EL1h** (`CPSR = 0x3c5`): Hypervisor.framework guests run at EL1 and cannot be VHE |
| MMU / caches | off; D-cache cleaned | off (`SCTLR_EL1` = RES1 bits only); coolvm cleans D-cache/invalidates I-cache for everything it loaded |
| DAIF | A,I,F masked | D,A,I,F masked |
| FP/SIMD | not trapped for the kernel | `CPACR_EL1.FPEN = 3` |
| Secondaries | running in m1n1's WFE park loop on their spin-table entry, EL2, MMU off | not running; started on demand (see SMP) at EL1h, MMU off, x0 = 0 |
| Counter | 24 MHz | 24 MHz (host `CNTFRQ_EL0`), `CNTVCT` starts at 0 |

**The kernel entry code must handle both**: `CurrentEL == 8` (real hardware; decide whether to stay at
EL2/VHE or drop to EL1) and `CurrentEL == 4` (this VM).

### Physical memory map (all addresses/sizes from the Asahi DT unless noted)

| Region | Address | Size | Source |
|---|---|---|---|
| DRAM (`/memory@800000000`) | `0x8_0000_0000` | `--mem` | `t8103-jxxx.dtsi` memory node, m1n1 `kboot.c` fallback |
| spin tables (reserved, `/memreserve/` + `/reserved-memory`) | `0x8_0000_0000` | 16 KiB | mirrors m1n1's `spin_table[]`, see SMP |
| kernel Image | `0x8_0020_0000` | | m1n1 `payload.c` `KERNEL_ALIGN` 2 MiB |
| FDT | 2 MiB boundary after the Image | | |
| `serial0` (apple,s5l-uart) | `0x2_3520_0000` | 0x1000 | `t8103.dtsi` `serial@235200000` |
| `aic` (apple,t8103-aic) | `0x2_3b10_0000` | 0x8000 | `t8103.dtsi` `interrupt-controller@23b100000` |
| VM-only "finisher" | `0x1_ff00_0000` | 0x1000 | coolvm invention, see Power off |
| VM-only input FIFO | `0x1_ff00_1000` | 0x1000 | `coolcom,coolvm-input`, AIC IRQ 700 |
| VM-only virtio-blk | `0x1_ff01_0000` + `0x1000` per disk | 0x1000 each | `virtio,mmio` v2, AIC IRQ 704–707 |
| VM-only virtio-net (`--net`) | `0x1_ff02_0000` | 0x1000 | `virtio,mmio` v2 device ID 1, AIC IRQ 712 |
| VM-only framebuffer | `0x9_0000_0000` | width × height × 4, 16 KiB rounded | `simple-framebuffer`, outside `/memory` |

Everything else in `0x2_0000_0000..0x2_ffff_ffff` is unmapped: an access is a **fatal** guest fault
(`coolvm: FATAL cpuN: unhandled MMIO read of 4 bytes at 0x...`, register dump, exit 1) unless
`--lenient`. MMIO accesses must be single-register `ldr/str` (w or x, no writeback, no `ldp/stp`, no SIMD):
Hypervisor.framework only reports a decodable syndrome (`ESR.ISV`) for those; anything else is a fatal
"data abort without valid syndrome".

### Device tree (built in `src/board.c` with a 100-line FDT builder in `src/fdt.c`; no dtc at runtime)

Mirrors `t8103.dtsi`/`t8103-jxxx.dtsi` after m1n1's fix-ups; verify with `--dump-dtb x.dtb; dtc -I dtb -O dts x.dtb`.
Root `compatible = "coolcom,coolvm", "apple,j274", "apple,t8103", "apple,arm-platform"` (the first
entry lets a kernel detect the VM), `aliases/serial0`, `cpus` (`cpu@0..3` icestorm reg `0x0..0x3`,
`cpu@10100..10103` firestorm; `enable-method = "spin-table"`; `cpu-release-addr` filled), `timer`
(`arm,armv8-timer`, the four AIC FIQs 2,3,0,1 as in the DTS), `clock-ref` (24 MHz `fixed-clock`), `soc`
(`simple-bus`, `nonposted-mmio`) with `serial@235200000` (`apple,s5l-uart`, `reg-io-width = 4`,
`<AIC_IRQ 605 LEVEL_HIGH>`, `clocks`) and `interrupt-controller@23b100000`, `finisher@1ff000000`,
`/chosen` (`stdout-path = "serial0"`, `bootargs`, `framebuffer@900000000`), `/reserved-memory`, `/memory@800000000`.
The framebuffer node has `compatible = "apple,simple-framebuffer", "simple-framebuffer"`,
`reg`, `width`, `height`, `stride = width × 4`, and `format = "x8r8g8b8"`. Its range also has a
`no-map` `/reserved-memory` child and a `/memreserve/` entry. The input and attached disks appear
under `/soc` with their VM-only addresses and level-high AIC interrupts. Not present: PMGR, DARTs,
WDT, NVMe, USB, PCIe.
A user-supplied `kernel.dtb` replaces the generated one verbatim (no fix-ups: you must supply
`cpu-release-addr`, memory, etc. yourself). Note that DT property data is only 4-byte aligned; with the MMU
off an unaligned 8-byte load is an alignment fault (the test guest reads `cpu-release-addr` as two words).

### UART (`src/uart.c`)

`apple,s5l-uart` register file (`serial_s3c.h`, m1n1 `uart_regs.h`): ULCON, UCON, UFCON, UMCON, UTRSTAT,
UERSTAT, UFSTAT, UMSTAT, UTXH, URXH, UBRDIV, UFRACVAL; 32-bit accesses. TX is instantaneous (UTRSTAT
TXBE|TXE always set, UFSTAT TX count 0, byte -> host stdout, no CR translation). RX comes from host stdin
(raw mode if it is a tty) via a 256-byte ring: UTRSTAT.RXD, UFSTAT RX count (max 15, RXFULL), URXH pops.
Apple interrupt bits follow m1n1's `hv_vuart.c`: with UCON mode field (`[1:0]` RX, `[3:2]` TX) == 1 and the
Apple enable bit (RXTO 9, RXTO_LEGACY 11, RXTHRESH 12, TXTHRESH 13) set, UTRSTAT bits 9/3/4/5 read as set
and **AIC hwirq 605** is asserted (level). Writing 1 to those UTRSTAT bits is accepted but the status is
derived, so it stays asserted until the driver clears the enable.

### Framebuffer and input (VM-only)

The framebuffer is guest-writable memory mapped at `0x9_0000_0000`. Pixels are little-endian
`x8r8g8b8`: a 32-bit word `0x00RRGGBB` appears as B, G, R, X bytes. The Cocoa view refreshes about
20 times per second on the main thread; all vCPUs run on worker threads. Closing the window stops the VM.
`--headless` skips Cocoa window creation; `--screenshot` works in either mode. The fixed framebuffer
address stays outside guest `/memory`, matching m1n1's usable-RAM carve-out layout.

Input uses a **small VM-only MMIO FIFO** rather than virtio-input. This keeps the input path simple for
the current assembly guest and avoids implementing virtio-input's event and status queues before a
kernel driver exists. The records use Linux input event numbers (`EV_KEY=1`, `EV_REL=2`, `EV_SYN=0`,
`KEY_A=30`, `REL_X=0`, etc.). At `INPUT_BASE+0`, a 32-bit read returns the number of complete records.
Three successive 32-bit reads of `INPUT_BASE+4` return `type`, `code`, and signed `value`, then pop the
record. IRQ 700 stays asserted while records remain, and AIC EVENT auto-masks it like other AIC sources.
The window sends key press/release, mouse button, relative movement, and wheel events. `--input-script`
loads up to 255 records before the guest starts, one `type code value` decimal triple per line; blank
lines and `#` comments are allowed. A `delay MS` line holds back every record after it until MS
milliseconds (cumulative) after coolvm loaded the script (to type at a program that is already running;
delayed records are fed one at a time, so they are not part of the 255-record preload limit). Example:

```
1 30 1    # KEY_A down
2 0 7     # mouse X +7
```

### virtio-blk (VM-only)

`--disk image` attaches a writable raw file whose size is a positive multiple of 512 bytes. Up to four
images appear at `0x1_ff01_0000 + i*0x1000`, IRQ `704+i`. This is virtio-mmio **version 2**
(`compatible = "virtio,mmio"`, device ID 2), with one split virtqueue (max 256 entries),
`VIRTIO_F_VERSION_1` and `VIRTIO_BLK_F_FLUSH`. It handles `VIRTIO_BLK_T_IN` (read), `OUT` (write),
and `FLUSH`; the capacity config is the image size in 512-byte sectors. The guest supplies an ordinary
descriptor chain with a 16-byte request header, data descriptors for read/write, and a writable status
byte. Indirect descriptors are not advertised. Queue notification processes available requests
synchronously; used-ring completion raises a level-high AIC IRQ until interrupt acknowledgment.
The guest and host should use the normal virtio barriers around split-ring indices. Images are modified
in place; the test runner recreates them for each iteration.

### virtio-net and user-mode NAT (VM-only, `--net`, `src/net.c`)

`--net` adds a `virtio,mmio` node at `0x1_ff02_0000` (IRQ 712, after the disks): virtio-mmio version 2,
device ID 1, features `VIRTIO_F_VERSION_1`, `VIRTIO_NET_F_MAC` (config bytes 0..5 = `52:54:00:12:34:56`)
and `VIRTIO_NET_F_STATUS` (link always up). Queue 0 receives, queue 1 transmits; every buffer starts
with the 12-byte `virtio_net_hdr` (all zero, `num_buffers = 1` on receive); no offloads, no mergeable
buffers, no control queue. A transmit notification processes the chains synchronously; received frames
wait in a 512-frame host queue until the guest posts receive buffers (a queue-0 notify, or the poll
thread every 50 ms, flushes it). The used ring is updated with release ordering; the ISR bit and level
IRQ are raised unless the guest set `VRING_AVAIL_F_NO_INTERRUPT`.

There is no host network device: the frames go to a small slirp-style NAT inside coolvm, so neither
root nor vmnet is needed. The guest network is QEMU's: guest `10.0.2.15/24`, gateway `10.0.2.2`
(MAC `52:55:0a:00:02:02`), DNS `10.0.2.3`.
- **ARP** requests for the gateway or DNS address are answered; the guest's MAC is learned from them.
- **DHCP**: DISCOVER gets an OFFER and REQUEST an ACK for `10.0.2.15` (mask, router, DNS, 1-day lease).
- **ICMP echo** to `10.0.2.2`/`10.0.2.3` is answered locally; to other addresses it goes out through an
  unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP` socket (macOS allows these without root) and the reply is
  returned with the guest's identifier and sequence.
- **DNS** to `10.0.2.3:53`: an `A` query is answered from the host's `getaddrinfo()` on a helper thread
  (so the host's resolver configuration, `/etc/hosts`, VPN resolvers etc. apply; up to 8 answers, TTL 60,
  NXDOMAIN/SERVFAIL from the error). Other query types get an empty NOERROR answer.
- **UDP**: one non-blocking host socket per guest source port (closed after 60 s idle).
- **TCP**: a guest SYN makes coolvm `connect()` a non-blocking host socket; when that succeeds the guest
  gets the SYN-ACK (MSS 1460, window 65535, no options otherwise), or an RST if it fails. Guest data is
  accepted in order only and acknowledged as far as the host socket took it (the guest retransmits the
  rest); host data is buffered (256 KiB) and sent within the guest's window, with go-back-N
  retransmission after 300 ms and zero-window probes. FINs map to `shutdown(SHUT_WR)` and host EOF.
  Connections idle for 5 minutes are reset.
- TCP and UDP to `10.0.2.2` go to the host's `127.0.0.1`. IP fragments are dropped.
- **Inbound forwarding** (`--net-forward [ADDR:]HOST:GUEST`, repeatable, implies `--net`): coolvm listens on
  TCP port `HOST` of `ADDR` (default `127.0.0.1`, so only the Mac itself can connect). Each accepted
  connection becomes a connection to the guest's port `GUEST` from `10.0.2.2` (source ports
  40000..48999): coolvm sends the SYN (retransmitted every 300 ms, given up after 10 s, an RST from the
  guest closes the host socket), then relays both ways like an outbound connection. Example:
  `--net-forward 2323:23 --net-forward 8080:80`, then `nc localhost 2323` on the Mac.

`COOLVM_NET_DEBUG=1` logs DNS lookups, TCP connects, every guest TCP segment and bad guest checksums,
and prints frame counts at exit. `COOLVM_NET_OFFLINE=1` makes every DNS query fail with SERVFAIL, as if the host were offline. `test/nat-test.c` (part of `make coolvm-test`) drives the NAT from a
host program acting as the guest driver: ARP, ICMP, DHCP, DNS and an HTTP GET of example.com (skipped
with status 77 when the host is offline).

### AIC v1 (`src/aic.c`)

Register map per `irq-apple-aic.c` (v1 offsets) and m1n1 `aic_regs.h`: `INFO` (0x4, reads `0x000a0380` like a
real M1: 896 IRQs), `CONFIG`, `WHOAMI` (0x2000, the reading CPU's logical index), `EVENT` (0x2004; read =
ack: `(type<<16)|num`, type 1 = HW IRQ, 4 = IPI; lowest IRQ number wins; the delivered IRQ is auto-masked),
`IPI_SEND/ACK/MASK_SET/MASK_CLR`, `TARGET_CPU[irq]` (0x3000), `SW_SET/SW_CLR/MASK_SET/MASK_CLR/HW_STATE`
(0x4000/0x4080/0x4100/0x4180/0x4200), per-CPU IPI views (0x5008 + cpu<<7 ...). Reset state: all IRQs masked,
all targets = CPU 0. The IRQ line of a CPU is asserted when any unmasked pending IRQ (SW_SET or a hardware
source: the UART) targets it, or a non-fast IPI is pending; it is delivered as a virtual IRQ before every
`hv_vcpu_run`. EOI = `MASK_CLR` after the device deasserted, exactly as Linux does.

**Fast IPIs** (t8103 uses these, not the MMIO IPIs): `IPI_RR_LOCAL_EL1` (`S3_5_C15_C0_0`),
`IPI_RR_GLOBAL_EL1` (`S3_5_C15_C0_1`), `IPI_SR_EL1` (`S3_5_C15_C1_1`, bit 0 pending, write-1-to-clear).
A send sets the target's pending flag and kicks it; it takes a **FIQ**. The "deferred" IPI type is treated as
immediate; "retract" clears.

### Timer

The guest uses the architectural virtual timer natively (`CNTV_*`). `CNTPCT_EL0` reads trap and are emulated (host counter); the physical timer registers `CNTP_CTL/CVAL/TVAL_EL0`
trap too and are **not** emulated (unknown sysreg -> UNDEF): use CNTV. On M1 the timer is a **FIQ**. Protocol with Hypervisor.framework:

1. Timer expiry -> `HV_EXIT_REASON_VTIMER_ACTIVATED`; the framework masks its vtimer; coolvm asserts the FIQ line.
2. Hypervisor.framework clears pending interrupts each time `hv_vcpu_run` returns, so lines are re-asserted
   before every run while they are still asserted in the model.
3. The first thing every M1 FIQ handler does (`aic_handle_fiq()`) is read `IPI_SR_EL1`; that traps, and coolvm
   treats it as **FIQ entry**: the timer line drops (edge-like, until the timer condition has been seen to clear).
4. While the framework's vtimer mask is set, a poker thread forces the vCPU out every ~150 us; on each exit coolvm
   re-reads `CNTV_CTL` and, once the guest has masked/disabled/re-armed the timer, calls
   `hv_vcpu_set_vtimer_mask(false)` so the next expiry exits again. **No cooperation is needed from the guest
   beyond reading `IPI_SR_EL1` first**; a FIQ handler that does not may see one extra spurious FIQ per tick.
5. WFI is emulated by sleeping the vCPU thread on a kqueue (`EVFILT_USER` for interrupt-line changes,
   `EVFILT_TIMER` with `NOTE_CRITICAL` for the timer deadline; plain condvar sleeps oversleep by ~2 ms).
   Measured tick period for a 10 ms `CVAL += period` timer: 9992..10007 us. WFE sleeps 20 us (spin loops).

### Other Apple IMP-DEF system registers

Any EC=0x18 trap is decoded; emulated: `IPI_RR_*`, `IPI_SR_EL1`, `IPI_CR_EL1` (`S3_5_C15_C3_1`, scratch),
`VM_TMR_FIQ_ENA_EL2` (`S3_5_C15_C1_3`, scratch, EL2-only on hardware), `PMCR0_EL1` (`S3_1_C15_C0_0`, scratch),
`UPMCR0_EL1` (`S3_7_C15_C0_4`, scratch), `UPMSR_EL1` (`S3_7_C15_C6_4`, reads 0). **Unknown** accesses are logged
(`UNKNOWN system register read S3_5_C15_C9_6 pc=...`) and reflected into the guest as an UNDEF (what an
unimplemented IMP-DEF register does on the CPU; `--strict` makes them fatal).

### SMP (spin-table)

Real M1 + m1n1: every secondary is parked at EL2 in `smp_secondary_entry()` polling `spin_table[i].target`
(`{mpidr, flag, target, args[4], retval}`, 64 bytes); m1n1 sets each CPU's DT `cpu-release-addr` to
`&spin_table[i].target`; Linux stores the entry PA there, `dc civac`, `sev`; m1n1 calls it with `x0..x3 = args = 0`.
coolvm reproduces this: the spin tables are at `0x8_0000_0000 + 64*i` (`mpidr` = DT reg, `flag` = 1), the DT
`cpu-release-addr` = `0x8_0000_0000 + 64*i + 16`, and one host thread per CPU. A secondary's thread does not
create its vCPU until it sees a non-zero `target` (host-side poll every 200 us, with a cache flush of the word),
then starts the vCPU at that address: EL1h, MMU off, DAIF masked, `x0 = 0`. Guest MPIDR = `0x80000000 | reg`
(e-cores `0x8000_0000+n`, p-cores `0x8001_0100+n`). Fast IPIs address CPUs by Aff0 + Aff1 (cluster) like the
hardware. Linux's holding pen (`secondary_holding_pen`) works unmodified.

### Power off / exit (VM-only, marked as such)

Real M1 poweroff is an SMC (RTKit) call, far out of scope. coolvm offers two VM-only mechanisms:
1. **PSCI-compatible HVC** (EL1 guests only): `hvc #0` with `x0 = 0x84000008` (SYSTEM_OFF) or `0x84000009`
   (SYSTEM_RESET) -> exit 0. `hvc #0xC001` with `x0 = code` -> exit(code). Any other HVC returns `-1`.
2. **Finisher MMIO** at `0x1_ff00_0000` (`/soc/finisher@1ff000000`, `coolcom,coolvm-finisher`, SiFive-test
   protocol): 32-bit write `0x5555` = power off, `(code<<16)|0x3333` = exit(code), `0x7777` = reset: coolvm runs again from the start with the same options, minus `--input-script` (disk files keep what the guest wrote). To boot another kernel at the reset, the guest first writes the guest-physical address of an arm64 Image in its RAM to offset `0x8` and its size to offset `0x10` (32-bit halves, low word first, or 64-bit stores); coolvm then saves those bytes to a temporary file in `$TMPDIR` and runs again with it as the kernel (an internal `--temp-kernel` option deletes it when that coolvm exits or boots yet another one). The kernel's `Reboot("C:/Kernel.Image")` does this ([kernel rebuild](../../docs/kernel-rebuild.md)).
   Works at any EL. A kernel should use it only when the root `compatible` contains `coolcom,coolvm`.

## Deviations from real hardware

* EL1 instead of EL2/VHE; MPIDR/MIDR/ID registers are the host's (MPIDR is overridden; `MIDR_EL1`, `ID_AA64*`
  are the host chip's, e.g. `ID_AA64MMFR1_EL1.VH = 0`).
* Only one die, one UART, one AIC; no PMGR/DART/WDT/NVMe/USB/PCIe. The VM-only framebuffer/input/block/net devices do not model M1 DCP, USB HID, or ANS storage. No AIC `0x8020` CNTPCT mirror.
* AIC interrupt arbitration is simplified (line up while any unmasked pending IRQ targets the CPU); fast IPI
  "deferred" is immediate; IPI to a parked CPU is remembered and seen when it starts.
* UART: no FIFO timing, RXTHRESH fires for any byte (UFCON trigger level ignored), TX never busy, no CR/LF handling.
* Timer FIQ is edge-like as described; re-arm latency <= ~150-250 us; `CNTP_*` not emulated.
* MMIO/sysreg exits cost tens of microseconds; batch UART output if speed matters.
* Secondary bring-up is by host polling instead of a trapped store to a read-only release page.
* Timing/uncore IMP-DEF registers other than the listed ones are not emulated (UNDEF).
* D-cache coherency: guest memory is `hv_vm_map`ped Normal WB; a guest with the MMU off uses Device
  attributes. coolvm cleans/invalidates the loaded regions before starting and flushes the spin word before polling.

## `--el2` (experimental, not a substitute for real hardware)

`--el2` creates the VM with `hv_vm_config_set_el2_enabled` (needs macOS 15+ and an M3-or-later host) and
enters the guest at **EL2h** with `HCR_EL2` as m1n1 sets it. Findings on this host (M6, macOS 27):
`HCR_EL2.E2H/TGE` read back as 0 (no VHE, `ID_AA64MMFR1.VH == 0`); EL2 system registers virtualized by the
framework trap to coolvm and are forwarded to `hv_vcpu_get/set_sys_reg`; an `hvc` at EL1/EL2 is taken by the guest's
own EL2 vectors, not by the monitor; **Apple IMP-DEF registers are not trapped** (UNDEF in the guest), so the AIC
fast IPI / timer-FIQ-ack model does not work; AIC MMIO and IRQ injection do. Use it to exercise a kernel's EL2
entry stub and the drop to EL1 (`test/guest.S` does exactly that) - everything after should run in normal EL1 mode.

## Tests

`make coolvm-test` -> `tools/coolvm/test/run.sh`: assembles `test/guest.S` and `test/fault.S` with
`aarch64-elf-as/ld/objcopy`, runs them with a timeout, checks output and exit statuses:
positive test (UART hello, FDT root compatible + memory node, AIC INFO/WHOAMI, unknown sysreg -> UNDEF, unknown
HVC -> -1, software-triggered AIC IRQ through the IRQ vector, UART TX-threshold IRQ 605, UART RX from stdin,
virtual timer FIQ x5 with measured period, `cpu-release-addr` spin-table start of CPU 1, fast IPI CPU0 -> CPU1
taken as FIQ, power off), `--lenient`/default behaviour for unmapped MMIO, `--strict` for an unknown sysreg.
`test/guest.S` doubles as a compact reference for the entry path, FDT walking with the MMU off, an AIC IRQ/FIQ
handler skeleton (`EVENT` read, `IPI_SR` first in the FIQ vector, `MASK_CLR` EOI) and spin-table secondary start.
It also assembles `test/devices.S` and runs it headlessly three times with fresh disk images and
scripted key/mouse events. The runner checks UART output, PNG pixel colors, raw disk bytes after
read/write/flush, and FDT framebuffer/input/disk nodes and interrupts. Every VM invocation is wrapped
in `gtimeout -k` and processes exit before the next iteration.

## Source layout

`src/main.c` CLI, image/FDT loading, VM + memory setup, watchdog/timeout. `src/vcpu.c` vCPU threads, exit
handling (MMIO, sysregs, HVC, WFI/WFE, vtimer), spin-table polling, poker thread. `src/aic.c`, `src/uart.c`,
`src/devices.c` device models (all under `g.lock`). `src/net.c` virtio-net and the user-mode NAT (poll thread + DNS threads, also under `g.lock`). `src/display.m` Cocoa window and PNG output on the main
thread. `src/board.c` device tree. `src/fdt.c` FDT builder. `test/` guests and runner.
