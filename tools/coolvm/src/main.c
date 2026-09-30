/*
 * coolvm - M1 (t8103) subset VM monitor on Hypervisor.framework.
 * See ../README.md for the design, the emulated address map and deviations.
 */
#include "coolvm.h"
#include "gpu3d.h"

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <libkern/OSCacheControl.h>
#include <signal.h>
#include <sys/event.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

struct vm g;

static volatile sig_atomic_t got_signal;

static void on_signal(int sig)
{
    (void)sig;
    got_signal = 1;
}

static void usage(void)
{
    fprintf(stderr,
            "usage: coolvm [options] kernel.Image [kernel.dtb]\n"
            "  --cpus N        number of CPUs, 1..%d (default 2). CPU order: 4 e-cores (icestorm, MPIDR 0..3)\n"
            "                  then p-cores (firestorm, MPIDR 0x10100..)\n"
            "  --mem MB        guest RAM at 0x%llx (default 256)\n"
            "  --load-offset B kernel load offset from DRAM base, 2 MiB-aligned, >= 0x200000 (default 0x200000); tests relocation\n"
            "  --timeout S     kill the VM after S seconds, exit status 124 (default: none)\n"
            "  --trace-mmio    log every emulated MMIO and IMP-DEF sysreg access to stderr\n"
            "  --bootargs STR  /chosen/bootargs for the generated device tree\n"
            "  --dump-dtb FILE write the generated device tree to FILE (inspect with dtc -I dtb -O dts)\n"
            "  --lenient       unknown MMIO reads as 0 / writes ignored (default: fatal)\n"
            "  --strict        unknown system registers are fatal (default: log + inject UNDEF)\n"
            "  --verbose       log boot and CPU lifecycle events\n"
            "  --el2           EXPERIMENTAL: enter the guest at EL2h with HCR_EL2 like m1n1 (needs macOS 15+ on M3 or later)\n"
            "  --headless      run without a Cocoa window\n"
            "  --width N       framebuffer width (default 1024)\n"
            "  --scale N       tell the guest its display scale is 1 or 2 (default: the window's backing scale; 1 headless)\n"
            "  --height N      framebuffer height (default 768)\n"
            "  --gpu/--no-gpu enable/disable virtio-gpu 2D\n"
            "  --gpu-3d-stub   test-only Venus transport responses (no Vulkan rendering)\n"
            "  --venus-readback force linear scanout instead of Metal image export\n"
            "  --no-venus      disable the optional renderer (the guest draws pixels)\n"
            "  --no-fb-scroll  omit FDT scanout-y capability (software fallback)\n"
            "  --screenshot F  save framebuffer to PNG on exit\n"
            "  --input-script F  preload input events (type code value, one per line)\n"
            "  --disk F        attach writable raw image; repeat up to four times\n"
            "  --net           attach a virtio-net NIC behind a user-mode NAT (guest 10.0.2.15, gateway 10.0.2.2)\n"
            "  --net-forward [ADDR:]HOST:GUEST  forward TCP host port HOST (on ADDR, default 127.0.0.1) to guest\n"
            "                  port GUEST; repeatable, implies --net\n"
            "The optional kernel.dtb replaces the generated device tree verbatim (no fix-ups are applied).\n"
            "stdout = guest UART, stderr = coolvm diagnostics. Exit status: 0 guest power-off, 124 timeout, 1 fatal.\n"
            "A guest reset (finisher 0x7777) starts coolvm again with the same options, without --input-script;\n"
            "a guest that named an Image in its RAM first (Reboot(\"C:/Kernel.Image\")) boots that instead.\n",
            MAX_CPUS, (unsigned long long)DRAM_BASE);
}

static uint8_t *read_file(const char *path, size_t *len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "coolvm: cannot open %s: %s\n", path, strerror(errno));
        return NULL;
    }
    struct stat st;
    fstat(fd, &st);
    uint8_t *buf = malloc(st.st_size ? st.st_size : 1);
    size_t got = 0;
    while (got < (size_t)st.st_size) {
        ssize_t n = read(fd, buf + got, st.st_size - got);
        if (n <= 0)
            break;
        got += n;
    }
    close(fd);
    if (got != (size_t)st.st_size) {
        fprintf(stderr, "coolvm: short read on %s\n", path);
        free(buf);
        return NULL;
    }
    *len = got;
    return buf;
}

static uint64_t le64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--)
        v = (v << 8) | p[i];
    return v;
}

static uint32_t le32(const uint8_t *p)
{
    return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t align_up(uint64_t v, uint64_t a)
{
    return (v + a - 1) & ~(a - 1);
}

static uint64_t cntpct_now(void)
{
    uint64_t v;
    __asm__ volatile("isb\n\tmrs %0, cntpct_el0" : "=r"(v));
    return v;
}

static uint64_t cntfrq_now(void)
{
    uint64_t v;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
    return v;
}

int main(int argc, char **argv)
{
    int ncpus = 2;
    uint64_t mem_mb = 256;
    double timeout = 0;
    const char *bootargs = "";
    uint64_t load_off = KERNEL_BASE_OFF;
    const char *dump_dtb = NULL;
    const char *input_script = NULL;
    const char *disk_paths[MAX_DISKS];
    int ndisks = 0;
    g.gpu = true;
    g.fb_scroll = true;
    g.fb_width = 1024; g.fb_height = 768;
    bool verbose = false;
    bool temp_kernel = false;

    static const struct option opts[] = {
        {"cpus", required_argument, 0, 'c'},   {"mem", required_argument, 0, 'm'},
        {"timeout", required_argument, 0, 't'}, {"trace-mmio", no_argument, 0, 'T'},
        {"bootargs", required_argument, 0, 'b'}, {"dump-dtb", required_argument, 0, 'd'},
        {"lenient", no_argument, 0, 'l'},        {"strict", no_argument, 0, 's'},
        {"verbose", no_argument, 0, 'v'},        {"help", no_argument, 0, 'h'},
        {"el2", no_argument, 0, 'E'},          {"load-offset", required_argument, 0, 'L'},
        {"headless", no_argument, 0, 'H'}, {"screenshot", required_argument, 0, 'S'},
        {"gpu", no_argument, 0, 1001}, {"no-gpu", no_argument, 0, 1002},
        {"gpu-3d-stub", no_argument, 0, 1004}, {"no-venus", no_argument, 0, 1005}, {"venus-readback", no_argument, 0, 1006},
        {"no-fb-scroll", no_argument, 0, 1000}, {"no-logos", no_argument, 0, 1003},
        {"width", required_argument, 0, 'W'}, {"height", required_argument, 0, 'Y'}, {"scale", required_argument, 0, 1100},
        {"input-script", required_argument, 0, 'I'}, {"disk", required_argument, 0, 'D'},
        {"net", no_argument, 0, 'N'}, {"net-forward", required_argument, 0, 'F'},
        {"temp-kernel", no_argument, 0, 'K'}, /* internal: the kernel file is ours to delete */
        {0, 0, 0, 0}};
    int o;
    while ((o = getopt_long(argc, argv, "h", opts, NULL)) != -1) {
        switch (o) {
        case 'c': ncpus = atoi(optarg); break;
        case 'm': mem_mb = strtoull(optarg, NULL, 0); break;
        case 't': timeout = atof(optarg); break;
        case 'T': g.trace_mmio = true; break;
        case 'b': bootargs = optarg; break;
        case 'd': dump_dtb = optarg; break;
        case 'l': g.lenient = true; break;
        case 's': g.strict = true; break;
        case 'E': g.el2 = true; break;
        case 'L': load_off = strtoull(optarg, NULL, 0); break;
        case 'v': verbose = true; break;
        case 'H': g.headless = true; break;
        case 'N': g.net = true; break;
        case 'K': temp_kernel = true; break;
        case 'F': if (!net_add_forward(optarg)) { fprintf(stderr, "coolvm: bad --net-forward %s\n", optarg); return 2; } break;
        case 'S': g.screenshot = optarg; break;
        case 1001: g.gpu = true; break;
        case 1002: g.gpu = false; break;
        case 1000: g.fb_scroll = false; break;
        case 1004: g.gpu_3d_stub = true; break;
        case 1003: break; /* retired --no-logos, accepted for old scripts */
        case 1005: g.no_venus = true; break;
        case 1006: g.venus_readback = true; break;
        case 'W': g.fb_width = (uint32_t)strtoul(optarg, NULL, 0); break;
        case 1100: g.fb_scale = (uint32_t)strtoul(optarg, NULL, 0); if (g.fb_scale != 1 && g.fb_scale != 2) { usage(); return 2; } break;
        case 'Y': g.fb_height = (uint32_t)strtoul(optarg, NULL, 0); break;
        case 'I': input_script = optarg; break;
        case 'D': if (ndisks == MAX_DISKS) { usage(); return 2; } disk_paths[ndisks++] = optarg; break;
        default: usage(); return 2;
        }
    }
    if (optind >= argc || argc - optind > 2 || ncpus < 1 || ncpus > MAX_CPUS || mem_mb < 8 ||
        (load_off & (KERNEL_ALIGN - 1)) || load_off < KERNEL_BASE_OFF ||
        !g.fb_width || !g.fb_height || g.fb_width > 8192 || g.fb_height > 8192 ||
        (uint64_t)g.fb_width * g.fb_height * 4 > (256ULL << 20) || mem_mb > 4096) {
        usage();
        return 2;
    }
    const char *kernel_path = argv[optind];
    int kernel_arg = optind;
    const char *dtb_path = argc - optind > 1 ? argv[optind + 1] : NULL;
    cpu_set_verbose(verbose);

    g.ncpus = ncpus;
    g.ram_size = mem_mb << 20;
    gpu_init();
    g.fb_size = align_up((uint64_t)g.fb_width * g.fb_height * 4, 0x4000);
    g.ndisks = ndisks;
    g.cntfrq = cntfrq_now();
    g.cntvoff = cntpct_now(); /* guest virtual count starts at 0 */
    pthread_mutex_init(&g.lock, NULL);
    pthread_mutex_init(&g.stop_lock, NULL);
    pthread_cond_init(&g.stop_cv, NULL);
    uart_init();
    aic_init();
    for (int i = 0; i < ndisks; i++) {
        struct stat st;
        g.disk_fd[i] = open(disk_paths[i], O_RDWR);
        if (g.disk_fd[i] < 0 || fstat(g.disk_fd[i], &st) || !S_ISREG(st.st_mode) || st.st_size < 512 || st.st_size % 512) {
            LOGE("disk must be a writable, 512-byte-aligned regular file: %s\n", disk_paths[i]);
            return 2;
        }
        g.disk_size[i] = st.st_size;
    }

    /* ---- load payload ---- */
    size_t klen;
    uint8_t *kimg = read_file(kernel_path, &klen);
    if (!kimg)
        return 2;
    uint64_t text_offset = 0, image_size = klen;
    bool have_hdr = klen >= 64 && le32(kimg + 0x38) == 0x644d5241; /* "ARM\x64" */
    if (have_hdr) {
        text_offset = le64(kimg + 8);
        uint64_t isz = le64(kimg + 16);
        if (isz)
            image_size = isz;
        if (isz && isz < klen)
            image_size = klen;
    } else {
        fprintf(stderr, "coolvm: warning: %s has no arm64 Image header (magic 'ARM\\x64' at 0x38); loading as a flat binary at the load base\n",
                kernel_path);
    }
    /* m1n1 (payload.c) ignores text_offset and places the kernel at a 2 MiB-aligned address; do the
     * same (Linux >= 5.8 sets text_offset to 0 anyway, flags bit 3 "placement anywhere"). */
    uint64_t kernel_off = load_off;
    if (have_hdr && text_offset)
        fprintf(stderr, "coolvm: note: image header text_offset=0x%llx ignored (m1n1 loads at the 2 MiB-aligned base)\n",
                (unsigned long long)text_offset);
    uint64_t fdt_off = align_up(kernel_off + image_size, KERNEL_ALIGN);

    uint8_t *fdt;
    uint32_t fdt_size;
    if (dtb_path) {
        size_t l;
        fdt = read_file(dtb_path, &l);
        if (!fdt)
            return 2;
        fdt_size = (uint32_t)l;
    } else {
        fdt = board_build_fdt(&fdt_size, g.ram_size, bootargs);
    }
    if (dump_dtb) {
        FILE *fp = fopen(dump_dtb, "wb");
        if (!fp || fwrite(fdt, 1, fdt_size, fp) != fdt_size) {
            fprintf(stderr, "coolvm: cannot write %s\n", dump_dtb);
            return 2;
        }
        fclose(fp);
    }
    if (fdt_off + align_up(fdt_size, 8) > g.ram_size) {
        fprintf(stderr, "coolvm: kernel (%llu bytes) + dtb do not fit in %llu MB of RAM\n", (unsigned long long)image_size,
                (unsigned long long)mem_mb);
        return 2;
    }

    /* ---- VM + memory ---- */
    hv_vm_config_t cfg = NULL;
    if (g.el2) {
        bool ok = false;
        hv_vm_config_get_el2_supported(&ok);
        if (!ok) {
            fprintf(stderr, "coolvm: --el2: this host/OS does not support EL2 guests\n");
            return 2;
        }
        cfg = hv_vm_config_create();
        hv_vm_config_set_el2_enabled(cfg, true);
    }
    hv_return_t r = hv_vm_create(cfg);
    if (r != HV_SUCCESS) {
        fprintf(stderr, "coolvm: hv_vm_create failed: 0x%x%s\n", r,
                r == (hv_return_t)0xfae94007 ? " (HV_DENIED: binary needs the com.apple.security.hypervisor entitlement; run via build.sh)" : "");
        return 1;
    }
    uint32_t maxv = 0;
    hv_vm_get_max_vcpu_count(&maxv);
    if ((uint32_t)ncpus > maxv) {
        fprintf(stderr, "coolvm: host supports at most %u vCPUs\n", maxv);
        return 2;
    }
    g.ram = mmap(NULL, g.ram_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (g.ram == MAP_FAILED) {
        perror("coolvm: mmap");
        return 1;
    }
    r = hv_vm_map(g.ram, DRAM_BASE, g.ram_size, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC);
    if (r != HV_SUCCESS) {
        fprintf(stderr, "coolvm: hv_vm_map failed: 0x%x\n", r);
        return 1;
    }
    if (g.gpu_3d_stub) {
        g.gpu_stub_memory = mmap(NULL, GPU_STUB_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (g.gpu_stub_memory == MAP_FAILED ||
            hv_vm_map(g.gpu_stub_memory, GPU_STUB_BASE, GPU_STUB_SIZE, HV_MEMORY_READ | HV_MEMORY_WRITE) != HV_SUCCESS) {
            LOGE("GPU stub window allocation/map failed\n"); return 1;
        }
    }
    g.fb = mmap(NULL, g.fb_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (g.fb == MAP_FAILED || hv_vm_map(g.fb, FB_BASE, g.fb_size, HV_MEMORY_READ | HV_MEMORY_WRITE) != HV_SUCCESS) {
        LOGE("framebuffer allocation/map failed\n"); return 1;
    }

    memcpy(g.ram + kernel_off, kimg, klen);
    memcpy(g.ram + fdt_off, fdt, fdt_size);
    free(kimg);

    /* m1n1 spin_table[MAX_CPUS] {mpidr, flag, target, args[4], retval} (smp.c) */
    for (int i = 0; i < ncpus; i++) {
        uint64_t *st = (uint64_t *)(g.ram + SPIN_AREA_OFF + 64 * i);
        st[0] = board_cpu_reg(i);
        st[1] = 1; /* alive */
    }
    /* Guest starts with MMU/caches off: make everything visible to it (D-cache clean
     * to PoC, I-cache invalidate), as a bootloader would. */
    uint64_t used = fdt_off + align_up(fdt_size, 8);
    sys_dcache_flush(g.ram, used);
    sys_icache_invalidate(g.ram, used);

    for (int i = 0; i < ncpus; i++) {
        cpu_t *c = &g.cpus[i];
        c->idx = i;
        c->reg = board_cpu_reg(i);
        c->mpidr = 0x80000000ULL | c->reg; /* bit 31 RES1; Apple: E 0x80000000+n, P 0x81010100+n */
        c->kq = kqueue();
        struct kevent ke;
        EV_SET(&ke, 1, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
        kevent(c->kq, &ke, 1, NULL, 0, NULL);
    }
    g.cpus[0].boot_entry = DRAM_BASE + kernel_off;
    g.cpus[0].boot_x0 = DRAM_BASE + fdt_off;
    if (input_script && !input_load_script(input_script)) return 2;

    if (verbose) {
        LOGE("RAM 0x%llx..0x%llx, kernel @0x%llx (text_offset 0x%llx, image_size 0x%llx, hdr=%d), dtb @0x%llx (%u bytes), %d cpus, cntfrq %llu\n",
             (unsigned long long)DRAM_BASE, (unsigned long long)(DRAM_BASE + g.ram_size),
             (unsigned long long)(DRAM_BASE + kernel_off), (unsigned long long)text_offset,
             (unsigned long long)image_size, have_hdr, (unsigned long long)(DRAM_BASE + fdt_off), fdt_size, ncpus,
             (unsigned long long)g.cntfrq);
        bool el2 = false;
        hv_vm_config_get_el2_supported(&el2);
        LOGE("host: hv EL2 guests %s (coolvm runs guests at EL1)\n", el2 ? "supported" : "not supported");
    }
    free(fdt);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    uart_start_stdin();
    display_init();
    cpu_timer_poker_start();
    net_start();
    for (int i = 0; i < ncpus; i++)
        pthread_create(&g.cpus[i].thread, NULL, cpu_thread_main, &g.cpus[i]);

    /* ---- wait for power-off / timeout / signal ---- */
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        /* With a window, the main thread runs the Cocoa event loop for 50 ms at a time:
         * keys reach the guest as they arrive and the window follows the framebuffer. */
        if (!g.headless) {
            display_pump(0.05);
        } else {
            pthread_mutex_lock(&g.stop_lock);
            if (!atomic_load(&g.stop)) {
                struct timespec ts;
                clock_gettime(CLOCK_REALTIME, &ts);
                ts.tv_nsec += 50 * 1000 * 1000;
                if (ts.tv_nsec >= 1000000000L) {
                    ts.tv_sec++;
                    ts.tv_nsec -= 1000000000L;
                }
                pthread_cond_timedwait(&g.stop_cv, &g.stop_lock, &ts);
            }
            pthread_mutex_unlock(&g.stop_lock);
        }
        if (atomic_load(&g.stop))
            break;
        if (got_signal) {
            vm_stop(130, "interrupted");
            break;
        }
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double el = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
        if (timeout > 0 && el >= timeout) {
            fprintf(stderr, "coolvm: timeout after %.1f s, stopping guest\n", timeout);
            vm_stop(124, "timeout");
            break;
        }
    }
    for (int i = 0; i < ncpus; i++)
        pthread_join(g.cpus[i].thread, NULL);
    cpu_timer_poker_stop();
    net_report();
    uart_stop_stdin();
    if (g.screenshot && !display_screenshot(g.screenshot)) {
        LOGE("cannot save screenshot %s\n", g.screenshot);
        if (atomic_load(&g.exit_code) == 0) atomic_store(&g.exit_code, 1);
    }
    for (int i = 0; i < g.ndisks; i++) close(g.disk_fd[i]);
    gpu3d_cleanup();
    hv_vm_destroy();
    fflush(stdout);
    if (atomic_load(&g.reset)) {
        /* Reboot: run again from scratch, without the scripted input (already typed). */
        char **nargv = calloc(argc + 2, sizeof(char *));
        const char *next_kernel = kernel_path;
        static char boot_path[1024];
        int n = 0;
        if (g.boot_size) {
            /* The guest named an Image in its RAM: save it and boot it (docs/kernel-rebuild.md). */
            uint64_t a = g.boot_addr, sz = g.boot_size;
            if (a < DRAM_BASE || sz < 64 || sz > g.ram_size || a - DRAM_BASE > g.ram_size - sz) {
                LOGE("finisher: boot image 0x%llx+0x%llx is not in RAM\n", (unsigned long long)a,
                     (unsigned long long)sz);
                return 1;
            }
            const char *tmp = getenv("TMPDIR");
            snprintf(boot_path, sizeof(boot_path), "%s/coolvm-boot-XXXXXX", tmp && *tmp ? tmp : "/tmp");
            int fd = mkstemp(boot_path);
            if (fd < 0 || write(fd, g.ram + (a - DRAM_BASE), sz) != (ssize_t)sz || close(fd)) {
                perror("coolvm: boot image");
                return 1;
            }
            if (temp_kernel)
                unlink(kernel_path);
            next_kernel = boot_path;
            fprintf(stderr, "coolvm: guest reset, booting the %llu-byte Image it passed\n", (unsigned long long)sz);
        }
        for (int i = 0; i < argc; i++) {
            if (!strcmp(argv[i], "--input-script") && i + 1 < argc) {
                i++;
                continue;
            }
            if (!strncmp(argv[i], "--input-script=", 15))
                continue;
            if (i == kernel_arg && g.boot_size && !temp_kernel)
                nargv[n++] = "--temp-kernel";
            nargv[n++] = i == kernel_arg ? (char *)next_kernel : argv[i];
        }
        fprintf(stderr, "coolvm: guest reset, starting again\n");
        execv(argv[0], nargv);
        perror("coolvm: execv");
        return 1;
    }
    if (temp_kernel)
        unlink(kernel_path);
    return atomic_load(&g.exit_code);
}
