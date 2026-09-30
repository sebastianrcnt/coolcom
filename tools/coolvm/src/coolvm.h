/*
 * coolvm - a small VM monitor for macOS Hypervisor.framework that emulates a
 * subset of the Apple M1 (t8103) at the SAME physical addresses and with the
 * SAME register behaviour as the real chip, so coolcom's drivers are identical
 * in the VM and on the Mac mini.
 *
 * Sources for every address/register (all AsahiLinux):
 *   - linux  arch/arm64/boot/dts/apple/t8103.dtsi, t8103-jxxx.dtsi
 *   - linux  drivers/irqchip/irq-apple-aic.c, include/dt-bindings/interrupt-controller/apple-aic.h
 *   - linux  drivers/tty/serial/samsung_tty.c, include/linux/serial_s3c.h
 *   - m1n1   src/aic_regs.h, src/uart_regs.h, src/smp.c, src/kboot.c, src/payload.c
 */
#ifndef COOLVM_H
#define COOLVM_H

#include <Hypervisor/Hypervisor.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Memory map (t8103) ------------------------------------------------- */

/* DRAM base: t8103-jxxx.dtsi "memory@800000000 { reg = <0x8 0 0x2 0>; }",
 * m1n1 kboot.c falls back to dram-base = 0x800000000. */
#define DRAM_BASE 0x800000000ULL

/* serial0: t8103.dtsi "serial@235200000", reg = <0x2 0x35200000 0x0 0x1000>,
 * interrupts = <AIC_IRQ 605 IRQ_TYPE_LEVEL_HIGH>. */
#define UART0_BASE 0x235200000ULL
#define UART0_SIZE 0x1000ULL
#define UART0_IRQ 605

/* aic: t8103.dtsi "interrupt-controller@23b100000", reg = <0x2 0x3b100000 0x0 0x8000>. */
#define AIC_BASE 0x23b100000ULL
#define AIC_SIZE 0x8000ULL

/* VM-only "test finisher" (SiFive-test style): a write of 0x5555 powers the VM off (exit 0),
 * (code << 16) | 0x3333 exits with `code`, 0x7777 resets: coolvm starts again (re-executes
 * itself with the same arguments minus --input-script; disks keep what was written).
 * Boot another kernel (VM-only, docs/kernel-rebuild.md): write the guest-physical address of an
 * arm64 Image in RAM to FINISHER_BOOT_ADDR and its size to FINISHER_BOOT_SIZE (32-bit halves,
 * low word first, or one 64-bit store), then 0x7777: coolvm saves those bytes to a temporary
 * file and starts again with it as the kernel (later plain resets boot it again).
 * Framebuffer damage (VM-only): a 32-bit write of (end << 16) | start to FINISHER_FB_DAMAGE says
 * the guest changed framebuffer rows start..end-1. Once a guest has written it, the window
 * redraws on those reports instead of comparing the whole framebuffer every frame.
 * Advertised in the device tree as /soc/finisher@1ff000000; NOT present on real hardware.
 * Unlike the PSCI-style HVC it also works for guests running at EL2. */
#define FINISHER_BASE 0x1ff000000ULL
#define FINISHER_SIZE 0x1000ULL
#define FINISHER_BOOT_ADDR 0x8
#define FINISHER_BOOT_SIZE 0x10
#define FINISHER_FB_DAMAGE 0x18
/* 32-bit pixel-row offset, modulo framebuffer height. FDT coolcom,scanout-y
 * contains its 64-bit MMIO address; absent means fixed scanout. */
#define FINISHER_FB_SCANOUT_Y 0x1c

/* VM-only devices, deliberately outside the t8103 SoC MMIO window. */
#define INPUT_BASE 0x1ff001000ULL
#define INPUT_SIZE 0x1000ULL
#define INPUT_IRQ 700
#define BLK_BASE 0x1ff010000ULL
#define BLK_STRIDE 0x1000ULL
#define BLK_IRQ_BASE 704
#define MAX_DISKS 4
/* VM-only virtio-net with a user-mode NAT (net.c), present with --net. */
#define NET_BASE 0x1ff020000ULL
#define NET_SIZE 0x1000ULL
#define NET_IRQ 712
#define GPU_BASE 0x1ff030000ULL
#define GPU_SIZE 0x1000ULL
#define GPU_IRQ 713
#define GPU_STUB_BASE 0x400000000ULL
#define GPU_STUB_SIZE (16ULL << 20)
#define FB_BASE 0x900000000ULL

#define MAX_CPUS 8

/* Boot-time layout inside DRAM (coolvm's own choice, see README). */
#define SPIN_AREA_OFF 0x0ULL     /* m1n1-style spin tables, reserved */
#define SPIN_AREA_SIZE 0x4000ULL /* one 16K page */
#define KERNEL_ALIGN 0x200000ULL /* m1n1 payload.c KERNEL_ALIGN = 2 MiB */
#define KERNEL_BASE_OFF 0x200000ULL

/* ---- Per-CPU state ------------------------------------------------------ */

typedef struct cpu {
    int idx;
    uint64_t mpidr; /* value the guest reads from MPIDR_EL1 */
    uint64_t reg;   /* DT "reg" (MPIDR & 0xffffff) */

    uint64_t boot_entry, boot_x0; /* cpu0 only; secondaries take theirs from the spin table */

    hv_vcpu_t vcpu;
    hv_vcpu_exit_t *exit;
    pthread_t thread;
    _Atomic bool started; /* hv_vcpu_create() done, safe to hv_vcpus_exit() */
    _Atomic bool parked;  /* secondary waiting on its spin-table release address */

    /* Interrupt lines into the vCPU, computed by the AIC model (any thread). */
    _Atomic bool irq_line;
    _Atomic bool fipi_pending; /* Apple fast IPI (IPI_SR_EL1 bit 0) */

    /* vCPU-thread-only state. */
    _Atomic bool vt_host_masked; /* HVF vtimer mask is set (poker thread watches it) */
    uint64_t vt_fired_cval;       /* deadline that caused the masked activation */
    bool vt_await_clear;         /* FIQ was acked; don't re-inject until the source deasserts */
    bool timer_fiq;              /* virtual-timer FIQ line asserted */


    /* Apple IMP-DEF sysregs kept as plain scratch state. */
    uint64_t vm_tmr_fiq_ena, pmcr0, upmcr0, ipi_cr;

    int kq; /* wakes a vCPU sleeping in WFI: EVFILT_USER = line changed, EVFILT_TIMER = deadline */
} cpu_t;

struct vm {
    int ncpus;
    cpu_t cpus[MAX_CPUS];
    uint8_t *ram;
    uint64_t ram_size;
    uint8_t *fb;
    uint64_t fb_size;
    uint32_t fb_width, fb_height;
    uint32_t fb_scale;           /* --scale: the scale the guest is told (0: the window's backing scale, 1 headless) */
    bool gpu;                   /* modern virtio-gpu 2D */
    bool gpu_3d_stub;
    uint8_t *gpu_stub_memory;
    bool no_venus, venus_readback;              /* runtime CPU fallback even in a renderer build */
    bool fb_scroll;              /* advertise optional scanout-y register */
    _Atomic uint32_t fb_scanout_y;
    _Atomic bool fb_damage_used;  /* the guest reports damage (FINISHER_FB_DAMAGE) */
    _Atomic uint64_t fb_damage;   /* rows changed since the window last drew: (end << 32) | start, 0 none */
    bool headless;
    const char *screenshot;
    int disk_fd[MAX_DISKS];
    uint64_t disk_size[MAX_DISKS];
    int ndisks;
    bool net; /* --net: virtio-net + NAT */
    pthread_mutex_t lock; /* protects all device state (uart, aic) */
    _Atomic bool stop;
    _Atomic int exit_code;
    _Atomic bool reset;  /* finisher 0x7777: boot again once stopped (main.c) */
    uint64_t boot_addr, boot_size; /* finisher: the Image to boot at the reset, if boot_size */
    bool trace_mmio;
    bool lenient; /* unknown MMIO reads-as-zero / writes ignored instead of fatal */
    bool strict;  /* unknown sysregs are fatal instead of injecting UNDEF */
    bool el2;     /* experimental: run guests at EL2h (VHE-style, like m1n1 hands over) */
    uint64_t cntvoff;
    uint64_t cntfrq;
    pthread_mutex_t stop_lock;
    pthread_cond_t stop_cv;
};
extern struct vm g;

#define LOGE(...) fprintf(stderr, "coolvm: " __VA_ARGS__)

/* vcpu.c */
void vm_stop(int code, const char *why);
void cpu_kick(cpu_t *c);
void *cpu_thread_main(void *arg);
void cpu_timer_poker_start(void);
void cpu_timer_poker_stop(void);
void cpu_set_verbose(bool v);

/* fdt.c */
typedef struct fdt fdt_t;
fdt_t *fdt_new(void);
void fdt_begin(fdt_t *f, const char *name);
void fdt_end(fdt_t *f);
void fdt_prop(fdt_t *f, const char *name, const void *data, uint32_t len);
void fdt_prop_empty(fdt_t *f, const char *name);
void fdt_prop_u32(fdt_t *f, const char *name, uint32_t v);
void fdt_prop_u64(fdt_t *f, const char *name, uint64_t v);
void fdt_prop_str(fdt_t *f, const char *name, const char *s);
void fdt_prop_strs(fdt_t *f, const char *name, const char *const *strs, int n);
void fdt_prop_cells(fdt_t *f, const char *name, const uint32_t *cells, int n);
void fdt_add_memrsv(fdt_t *f, uint64_t addr, uint64_t size);
uint8_t *fdt_finish(fdt_t *f, uint32_t *size);

/* board.c */
uint64_t board_cpu_reg(int idx);
uint64_t board_spin_target_addr(int idx);
uint8_t *board_build_fdt(uint32_t *size, uint64_t ram_size, const char *bootargs);

/* devices.c / display.m */
bool input_mmio(uint64_t off, int size, bool wr, uint64_t *val);
bool input_irq_level(void);
void input_push(uint32_t type, uint32_t code, int32_t value);
bool input_load_script(const char *path);
void input_uart_out(uint8_t ch);  /* UART output, for the script's "wait" lines */
bool blk_mmio(int disk, uint64_t off, int size, bool wr, uint64_t *val);
bool blk_irq_level(int disk);
bool net_mmio(uint64_t off, int size, bool wr, uint64_t *val);
bool net_irq_level(void);
void net_start(void);
bool net_add_forward(const char *spec); /* --net-forward [addr:]host:guest */
void net_report(void);
void fb_frame_dump(void); /* caller holds g.lock */
void gpu_init(void);
bool gpu_mmio(uint64_t off, int size, bool wr, uint64_t *val);
bool gpu_irq_level(void);
void gpu_resize(uint32_t width, uint32_t height);
void gpu_scale(uint32_t scale); /* the window's backing scale, unless --scale fixed it */
bool gpu_snapshot(uint8_t **pixels, uint32_t *width, uint32_t *height); /* g.lock held */
void fb_snapshot(uint8_t *dst); /* visible scanout, including ring wrap */
void display_init(void);
void display_pump(double seconds); /* run the window's event loop for that long */
bool display_screenshot(const char *path);

/* aic.c (all called with g.lock held except the fast-IPI helpers) */
void aic_init(void);
bool aic_mmio(cpu_t *c, uint64_t off, int size, bool wr, uint64_t *val);
const char *aic_regname(uint64_t off);
void aic_update_locked(void);
bool aic_fast_ipi_send(cpu_t *c, uint64_t val, bool global);
bool aic_fast_ipi_test_clear(cpu_t *c, bool clear);

/* uart.c */
void uart_init(void);
bool uart_mmio(cpu_t *c, uint64_t off, int size, bool wr, uint64_t *val);
const char *uart_regname(uint64_t off);
bool uart_irq_level(void);
void uart_start_stdin(void);
void uart_stop_stdin(void);

#endif
