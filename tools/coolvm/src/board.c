/*
 * The device tree coolvm hands to the guest. It mirrors what m1n1 + the Asahi
 * t8103 DT give a Linux payload, restricted to the devices coolvm emulates.
 * Node names, compatibles, reg/interrupts encodings are copied from
 *   linux arch/arm64/boot/dts/apple/t8103.dtsi and t8103-jxxx.dtsi
 * and the /chosen + cpu-release-addr fix-ups from m1n1 src/kboot.c.
 */
#include "coolvm.h"

/* dt-bindings/interrupt-controller/apple-aic.h and irq.h */
#define AIC_IRQ 0
#define AIC_FIQ 1
#define AIC_TMR_HV_PHYS 0
#define AIC_TMR_HV_VIRT 1
#define AIC_TMR_GUEST_PHYS 2
#define AIC_TMR_GUEST_VIRT 3
#define IRQ_TYPE_LEVEL_HIGH 4

#define PH_AIC 1
#define PH_CLKREF 2

/* t8103.dtsi cpu@ nodes: e-cores (icestorm) reg 0..3, p-cores (firestorm) reg 0x10100..0x10103.
 * m1n1 turns the spin-table "cpu-release-addr" into the address of spin_table[cpu].target. */
uint64_t board_cpu_reg(int idx)
{
    return idx < 4 ? (uint64_t)idx : 0x10100ULL + (idx - 4);
}

uint64_t board_spin_target_addr(int idx)
{
    /* struct spin_table { u64 mpidr, flag, target, args[4], retval } = 64 bytes (m1n1 smp.c). */
    return DRAM_BASE + SPIN_AREA_OFF + 64ULL * idx + 16;
}

uint8_t *board_build_fdt(uint32_t *size, uint64_t ram_size, const char *bootargs)
{
    fdt_t *f = fdt_new();
    char name[64];

    fdt_begin(f, "");
    {
        /* First entry marks the VM (kernels can detect it); the rest is the j274 (Mac mini M1)
         * list from t8103-j274.dts, which is what m1n1's payload loader matches on. */
        const char *compat[] = {"coolcom,coolvm", "apple,j274", "apple,t8103", "apple,arm-platform"};
        fdt_prop_strs(f, "compatible", compat, 4);
    }
    fdt_prop_str(f, "model", "coolvm (emulated Apple M1 t8103)");
    fdt_prop_u32(f, "#address-cells", 2);
    fdt_prop_u32(f, "#size-cells", 2);

    fdt_begin(f, "aliases");
    fdt_prop_str(f, "serial0", "/soc/serial@235200000");
    fdt_end(f);

    fdt_begin(f, "cpus");
    fdt_prop_u32(f, "#address-cells", 2);
    fdt_prop_u32(f, "#size-cells", 0);
    for (int i = 0; i < g.ncpus; i++) {
        uint64_t reg = board_cpu_reg(i);
        snprintf(name, sizeof(name), "cpu@%llx", (unsigned long long)reg);
        fdt_begin(f, name);
        fdt_prop_str(f, "compatible", i < 4 ? "apple,icestorm" : "apple,firestorm");
        fdt_prop_str(f, "device_type", "cpu");
        uint32_t r[2] = {(uint32_t)(reg >> 32), (uint32_t)reg};
        fdt_prop_cells(f, "reg", r, 2);
        fdt_prop_str(f, "enable-method", "spin-table");
        uint64_t rel = board_spin_target_addr(i);
        uint32_t ra[2] = {(uint32_t)(rel >> 32), (uint32_t)rel};
        fdt_prop_cells(f, "cpu-release-addr", ra, 2);
        fdt_end(f);
    }
    fdt_end(f);

    /* t8103.dtsi "timer": armv8 timer, all four routed as AIC FIQs. */
    fdt_begin(f, "timer");
    fdt_prop_str(f, "compatible", "arm,armv8-timer");
    fdt_prop_u32(f, "interrupt-parent", PH_AIC);
    {
        const char *names[] = {"phys", "virt", "hyp-phys", "hyp-virt"};
        fdt_prop_strs(f, "interrupt-names", names, 4);
        uint32_t ints[12] = {AIC_FIQ, AIC_TMR_GUEST_PHYS, IRQ_TYPE_LEVEL_HIGH,
                             AIC_FIQ, AIC_TMR_GUEST_VIRT, IRQ_TYPE_LEVEL_HIGH,
                             AIC_FIQ, AIC_TMR_HV_PHYS,    IRQ_TYPE_LEVEL_HIGH,
                             AIC_FIQ, AIC_TMR_HV_VIRT,    IRQ_TYPE_LEVEL_HIGH};
        fdt_prop_cells(f, "interrupts", ints, 12);
    }
    fdt_end(f);

    /* t8103.dtsi clkref: 24 MHz reference clock feeding the UART. */
    fdt_begin(f, "clock-ref");
    fdt_prop_str(f, "compatible", "fixed-clock");
    fdt_prop_u32(f, "#clock-cells", 0);
    fdt_prop_u32(f, "clock-frequency", 24000000);
    fdt_prop_str(f, "clock-output-names", "clkref");
    fdt_prop_u32(f, "phandle", PH_CLKREF);
    fdt_end(f);

    fdt_begin(f, "soc");
    fdt_prop_str(f, "compatible", "simple-bus");
    fdt_prop_u32(f, "#address-cells", 2);
    fdt_prop_u32(f, "#size-cells", 2);
    fdt_prop_empty(f, "ranges");
    fdt_prop_empty(f, "nonposted-mmio");

    fdt_begin(f, "serial@235200000");
    fdt_prop_str(f, "compatible", "apple,s5l-uart");
    {
        uint32_t reg[4] = {(uint32_t)(UART0_BASE >> 32), (uint32_t)UART0_BASE, 0, (uint32_t)UART0_SIZE};
        fdt_prop_cells(f, "reg", reg, 4);
        fdt_prop_u32(f, "reg-io-width", 4);
        fdt_prop_u32(f, "interrupt-parent", PH_AIC);
        uint32_t ints[3] = {AIC_IRQ, UART0_IRQ, IRQ_TYPE_LEVEL_HIGH};
        fdt_prop_cells(f, "interrupts", ints, 3);
        uint32_t clks[2] = {PH_CLKREF, PH_CLKREF};
        fdt_prop_cells(f, "clocks", clks, 2);
        const char *cn[] = {"uart", "clk_uart_baud0"};
        fdt_prop_strs(f, "clock-names", cn, 2);
    }
    fdt_prop_str(f, "status", "okay");
    fdt_end(f);

    fdt_begin(f, "finisher@1ff000000");
    fdt_prop_str(f, "compatible", "coolcom,coolvm-finisher");
    {
        uint32_t reg[4] = {(uint32_t)(FINISHER_BASE >> 32), (uint32_t)FINISHER_BASE, 0, (uint32_t)FINISHER_SIZE};
        fdt_prop_cells(f, "reg", reg, 4);
    }
    fdt_end(f);

    fdt_begin(f, "interrupt-controller@23b100000");
    {
        const char *compat[] = {"apple,t8103-aic", "apple,aic"};
        fdt_prop_strs(f, "compatible", compat, 2);
        fdt_prop_u32(f, "#interrupt-cells", 3);
        fdt_prop_empty(f, "interrupt-controller");
        uint32_t reg[4] = {(uint32_t)(AIC_BASE >> 32), (uint32_t)AIC_BASE, 0, (uint32_t)AIC_SIZE};
        fdt_prop_cells(f, "reg", reg, 4);
        fdt_prop_u32(f, "phandle", PH_AIC);
    }
    fdt_end(f);
    fdt_end(f); /* soc */

    /* t8103-jxxx.dtsi "chosen" (stdout-path = "serial0"); bootargs as m1n1 chosen.bootargs.
     * No simple-framebuffer: coolvm has no display (see README). */
    fdt_begin(f, "chosen");
    fdt_prop_u32(f, "#address-cells", 2);
    fdt_prop_u32(f, "#size-cells", 2);
    fdt_prop_empty(f, "ranges");
    fdt_prop_str(f, "stdout-path", "serial0");
    fdt_prop_str(f, "bootargs", bootargs ? bootargs : "");
    fdt_end(f);

    /* Spin-table area: in real life this lives in m1n1's own (reserved) memory. */
    fdt_begin(f, "reserved-memory");
    fdt_prop_u32(f, "#address-cells", 2);
    fdt_prop_u32(f, "#size-cells", 2);
    fdt_prop_empty(f, "ranges");
    fdt_begin(f, "spin-table@800000000");
    {
        uint32_t reg[4] = {(uint32_t)(DRAM_BASE >> 32), (uint32_t)DRAM_BASE, 0, (uint32_t)SPIN_AREA_SIZE};
        fdt_prop_cells(f, "reg", reg, 4);
        fdt_prop_empty(f, "no-map");
    }
    fdt_end(f);
    fdt_end(f);

    /* t8103-jxxx.dtsi memory@800000000 (reg filled by the loader). */
    fdt_begin(f, "memory@800000000");
    fdt_prop_str(f, "device_type", "memory");
    {
        uint32_t reg[4] = {(uint32_t)(DRAM_BASE >> 32), (uint32_t)DRAM_BASE, (uint32_t)(ram_size >> 32),
                           (uint32_t)ram_size};
        fdt_prop_cells(f, "reg", reg, 4);
    }
    fdt_end(f);

    fdt_end(f); /* root */
    fdt_add_memrsv(f, DRAM_BASE + SPIN_AREA_OFF, SPIN_AREA_SIZE);
    return fdt_finish(f, size);
}
