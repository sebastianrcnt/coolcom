# Apple Virtualization.framework (VZ) as seen from a UEFI app

Reference only: the project targets our own Hypervisor.framework VMM and real
M1 hardware, not VZ. Probed with `make vzprobe` / `make vzprobe-gui`
(setup: `brew install mtools gptfdisk llvm@21 lld@21`).

## Platform
- Firmware: EDK II derivative, UEFI 2.7; SMBIOS "Apple Virtualization Generic Platform".
- Entry: EL1, MMU+caches on. MIDR 0x610f0000, MPIDR 0x80000000, CNTFRQ 24 MHz,
  36-bit PA, 4K/16K granules (no 64K).
- RAM: 0x70000000..0xB0000000 (one block).
- No device tree. ACPI: FACP, GTDT, APIC, MCFG, DSDT only.
- GICv3: GICD 0x10000000, GICR 0x10010000, MSI frame 0x1FFF0000, no ITS.
  MADT GICC entries have no CPU-interface base.
- Timer PPIs: phys 30, virt 27, hyp 26, PMU 23.
- PCIe: ECAM 0x40000000; 32-bit window 0x50000000..0x6FFDFFFF;
  64-bit 0x1_0000_0000..0x4_FFFF_FFFF; INTA of device n = GSI 64+n (DSDT _PRT).
- Devices: host bridge 00:00.0, virtio-console 00:05.0, virtio-blk 00:06.0,
  virtio-gpu 00:07.0, Apple xHCI 00:08.0 (regs BAR0, MSI-X table BAR1).
- PL061 GPIO at 0x20060000 (ACPI power button).
- PSCI 1.1 via HVC: CPU_ON/OFF, SYSTEM_OFF/RESET (no CPU_SUSPEND, SYSTEM_RESET2).
  Core 1 starts OFF.

## Console, display, input
- No UART at all (no SPCR/DBG2/SerialIO). ConOut/StdErr go only to the GOP
  text console. Headless output = drive virtio-console yourself: no MULTIPORT,
  port 0 rx=queue 0, tx=queue 1. A kick right after DRIVER_OK was lost; after
  ~200 ms it works.
- GOP is BltOnly, FrameBufferBase 0: no linear framebuffer. After
  ExitBootServices use virtio-gpu 2D (RESOURCE_CREATE_2D B8G8R8X8, backing,
  SET_SCANOUT, transfer, flush) — works.
- Input is USB HID through the xHCI; no virtio-input.
- Firmware page tables stay valid after ExitBootServices.

## Kernel implications (if we ever target VZ)
virtio-pci modern, virtio-console, virtio-gpu, GICv3, arch timer, PSCI/HVC,
xHCI+HID; RAM base 0x70000000; hardware addresses from ACPI or hard-coded.

## Tooling notes
- `cacheDisplay`/IOSurface of VZVirtualMachineView come back black;
  `screencapture -l <windowid>` works (retry if the window is on another Space).

## Open
GOP SetMode, real interrupt delivery (INTx vs MSI-X), CPU_ON for core 1,
virtio-console rx, xHCI/HID, VZLinuxBootLoader's generated DTB, config-table
GUIDs 49152e77-1ada-4764-b7a2-7afefed95e8b and d719b2cb-3d3a-4596-a3bc-dad00e67656f,
what lives at 0x01000000 and 0x20050000.
