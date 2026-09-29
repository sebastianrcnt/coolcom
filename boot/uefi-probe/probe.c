/* coolcom UEFI probe: learn what a UEFI firmware (Apple Virtualization.framework,
 * or QEMU+edk2 for comparison) hands to an AArch64 OS.  Single file, no EFI
 * library.  Output goes to ConOut, StdErr, a log file (\probe.log on the boot
 * volume) and the GOP framebuffer.  Optional config file \probe.cfg on the boot
 * volume (key=value lines):
 *   wait=N       seconds to wait for a key before shutting down (default 5)
 *   postwait=N   seconds to hold the post-ExitBootServices screen (default 4)
 *   off=MODE     psci    ExitBootServices, redraw, PSCI SYSTEM_OFF via HVC (default)
 *                rt      ResetSystem(EfiResetShutdown) with boot services alive
 *                rtpost  ExitBootServices, redraw, then runtime ResetSystem
 *                none    do not shut down (spin)
 *   pci=ecam     also scan ECAM directly (default on; pci=noecam disables)
 */
#include "efi.h"
#include "font8x8.h"

/* ------------------------------------------------------------------ libc bits */
void *memset(void *d, int c, UINTN n) {
    volatile u8 *p = d;
    while (n--) *p++ = (u8)c;
    return d;
}
void *memcpy(void *d, const void *s, UINTN n) {
    volatile u8 *p = d;
    const u8 *q = s;
    while (n--) *p++ = *q++;
    return d;
}
void *memmove(void *d, const void *s, UINTN n) {
    volatile u8 *p = d;
    const u8 *q = s;
    if (p < q) {
        while (n--) *p++ = *q++;
    } else {
        p += n;
        q += n;
        while (n--) *--p = *--q;
    }
    return d;
}
int memcmp(const void *a, const void *b, UINTN n) {
    const u8 *p = a, *q = b;
    for (; n; n--, p++, q++)
        if (*p != *q) return *p - *q;
    return 0;
}
static UINTN slen(const char *s) {
    UINTN n = 0;
    while (s[n]) n++;
    return n;
}
static int streq(const char *a, const char *b) {
    while (*a && *a == *b) a++, b++;
    return *a == *b;
}

/* unaligned little-endian reads */
static u16 rd16(const void *p) {
    const u8 *b = p;
    return b[0] | (b[1] << 8);
}
static u32 rd32(const void *p) {
    const u8 *b = p;
    return b[0] | (b[1] << 8) | (b[2] << 16) | ((u32)b[3] << 24);
}
static u64 rd64(const void *p) { return rd32(p) | ((u64)rd32((const u8 *)p + 4) << 32); }
static u32 be32(const void *p) {
    const u8 *b = p;
    return ((u32)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

/* ------------------------------------------------------------------ globals */
static EFI_HANDLE gIH;
static SYSTBL *gST;
static BOOTSVC *gBS;
static RTSVC *gRT;
static int bs_alive = 1;
static DP2T *gDP2T;

static char logbuf[1 << 19];
static u32 loglen, logflushed;
static EFIFILE *logf;
static int con_on = 1;
static int cons_state; /* virtio-console: 0 not tried, 1 ok, -1 failed */
static void cons_write(const char *s, UINTN n);

/* config */
static int cfg_wait = 5, cfg_postwait = 4, cfg_ecam = 1;
static char cfg_off[16] = "psci";

/* ------------------------------------------------------------------ output */
static void out16(TXTOUT *o, const char *s) {
    CHAR16 b[256];
    int n = 0;
    if (!o || !bs_alive) return;
    for (;;) {
        char c = *s++;
        if (!c) break;
        if (c == '\n') b[n++] = '\r';
        b[n++] = (u8)c;
        if (n >= 250) {
            b[n] = 0;
            o->OutputString(o, b);
            n = 0;
        }
    }
    if (n) {
        b[n] = 0;
        o->OutputString(o, b);
    }
}

static void flush_log(void) {
    if (!logf || !bs_alive) return;
    if (loglen > logflushed) {
        UINTN n = loglen - logflushed;
        logf->Write(logf, &n, logbuf + logflushed);
        logflushed += (u32)n;
        logf->Flush(logf);
    }
}

static void emit(const char *s) {
    for (const char *p = s; *p; p++)
        if (loglen < sizeof logbuf - 1) logbuf[loglen++] = *p;
    if (con_on) out16(gST->ConOut, s);
    if (cons_state == 1) cons_write(s, slen(s));
}

static void put(char **pp, char *e, char c) {
    if (*pp < e) *(*pp)++ = c;
}
static void putnum(char **pp, char *e, u64 v, int base, int upper, int width, int zero, int left, int neg) {
    char t[24];
    int n = 0;
    const char *dg = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (!v) t[n++] = '0';
    while (v) {
        t[n++] = dg[v % base];
        v /= base;
    }
    int len = n + neg;
    if (!left && !zero)
        for (; len < width; len++) put(pp, e, ' ');
    if (neg) put(pp, e, '-');
    if (!left && zero)
        for (; len < width; len++) put(pp, e, '0');
    while (n) put(pp, e, t[--n]);
    if (left)
        for (; len < width; len++) put(pp, e, ' ');
}

static void vsn(char *out, int n, const char *f, va_list ap) {
    char *p = out, *e = out + n - 1;
    while (*f) {
        if (*f != '%') {
            put(&p, e, *f++);
            continue;
        }
        f++;
        int left = 0, zero = 0, width = 0, lng = 0;
        for (;; f++) {
            if (*f == '-') left = 1;
            else if (*f == '0') zero = 1;
            else break;
        }
        while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
        while (*f == 'l') lng++, f++;
        switch (*f) {
        case 'd': {
            s64 v = lng ? va_arg(ap, s64) : (s64)va_arg(ap, int);
            putnum(&p, e, v < 0 ? (u64)-v : (u64)v, 10, 0, width, zero, left, v < 0);
            break;
        }
        case 'u': putnum(&p, e, lng ? va_arg(ap, u64) : (u64)va_arg(ap, u32), 10, 0, width, zero, left, 0); break;
        case 'x': putnum(&p, e, lng ? va_arg(ap, u64) : (u64)va_arg(ap, u32), 16, 0, width, zero, left, 0); break;
        case 'X': putnum(&p, e, lng ? va_arg(ap, u64) : (u64)va_arg(ap, u32), 16, 1, width, zero, left, 0); break;
        case 'p':
            put(&p, e, '0');
            put(&p, e, 'x');
            putnum(&p, e, va_arg(ap, u64), 16, 0, 16, 1, 0, 0);
            break;
        case 'c': put(&p, e, (char)va_arg(ap, int)); break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            int l = (int)slen(s);
            if (!left)
                for (; l < width; l++) put(&p, e, ' ');
            for (const char *q = s; *q; q++) put(&p, e, *q);
            if (left)
                for (; l < width; l++) put(&p, e, ' ');
            break;
        }
        case 'S': { /* CHAR16 string */
            const CHAR16 *s = va_arg(ap, const CHAR16 *);
            if (!s) {
                put(&p, e, '?');
                break;
            }
            for (; *s; s++) put(&p, e, *s < 0x80 && *s >= 0x20 ? (char)*s : '?');
            break;
        }
        case '%': put(&p, e, '%'); break;
        default: put(&p, e, '?'); break;
        }
        if (*f) f++;
    }
    *p = 0;
}

static char linebuf[2048];
static void pr(const char *f, ...) {
    va_list ap;
    va_start(ap, f);
    vsn(linebuf, sizeof linebuf, f, ap);
    va_end(ap);
    emit(linebuf);
}

/* screen summary lines (drawn on the framebuffer at the end) */
static char summ[64][96];
static int nsumm;
static void sum(const char *f, ...) {
    va_list ap;
    if (nsumm >= 64) return;
    va_start(ap, f);
    vsn(summ[nsumm++], 96, f, ap);
    va_end(ap);
}

static char secname[80];
static void sec(const char *name) {
    pr("\n== %s ==\n", name);
    char *p = secname;
    const char *pre = "[stderr] == ";
    while (*pre) *p++ = *pre++;
    while (*name && p < secname + 60) *p++ = *name++;
    *p++ = '\n';
    *p = 0;
    out16(gST->StdErr, secname);
    flush_log();
}

/* ------------------------------------------------------------------ GUIDs */
typedef struct {
    GUID g;
    const char *name;
} GNAME;

static GUID G_ACPI20 = GUID_INIT(0x8868e871, 0xe4f1, 0x11d3, 0xbc, 0x22, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81);
static GUID G_DTB = GUID_INIT(0xb1b621d5, 0xf19c, 0x41a5, 0x83, 0x0b, 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0);
static GUID G_SMBIOS = GUID_INIT(0xeb9d2d31, 0x2d88, 0x11d3, 0x9a, 0x16, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d);
static GUID G_SMBIOS3 = GUID_INIT(0xf2fd1544, 0x9794, 0x4a2c, 0x99, 0x2e, 0xe5, 0xbb, 0xcf, 0x20, 0xe3, 0x94);
static GUID G_GOP = GUID_INIT(0x9042a9de, 0x23dc, 0x4a38, 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a);
static GUID G_LOADEDIMG = GUID_INIT(0x5b1b31a1, 0x9562, 0x11d2, 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b);
static GUID G_SFS = GUID_INIT(0x964e5b22, 0x6459, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b);
static GUID G_PCIIO = GUID_INIT(0x4cf5b200, 0x68b8, 0x4ca5, 0x9e, 0xec, 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a);
static GUID G_PCIRB = GUID_INIT(0x2f707ebb, 0x4a1a, 0x11d4, 0x9a, 0x38, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d);
static GUID G_TEXTIN = GUID_INIT(0x387477c1, 0x69c7, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b);
static GUID G_TEXTINEX = GUID_INIT(0xdd9e7534, 0x7762, 0x4698, 0x8c, 0x14, 0xf5, 0x85, 0x17, 0xa6, 0x25, 0xaa);
static GUID G_TEXTOUT = GUID_INIT(0x387477c2, 0x69c7, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b);
static GUID G_SIMPTR = GUID_INIT(0x31878c87, 0x0b75, 0x11d5, 0x9a, 0x4f, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d);
static GUID G_ABSPTR = GUID_INIT(0x8d59d32b, 0xc655, 0x4ae9, 0x9b, 0x15, 0xf2, 0x59, 0x04, 0x99, 0x2a, 0x43);
static GUID G_SERIALIO = GUID_INIT(0xbb25cf6f, 0xf1d4, 0x11d2, 0x9a, 0x0c, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0xfd);
static GUID G_USBIO = GUID_INIT(0x2b2f68d6, 0x0cd2, 0x44cf, 0x8e, 0x8b, 0xbb, 0xa2, 0x0b, 0x1b, 0x5b, 0x75);
static GUID G_USB2HC = GUID_INIT(0x3e745226, 0x9818, 0x45b6, 0xa2, 0xac, 0xd7, 0xcd, 0x0e, 0x8b, 0xa2, 0xbc);
static GUID G_BLOCKIO = GUID_INIT(0x964e5b21, 0x6459, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b);
static GUID G_DP2T = GUID_INIT(0x8b843e20, 0x8132, 0x4852, 0x90, 0xcc, 0x55, 0x1a, 0x4e, 0x4a, 0x7f, 0x1c);
static GUID G_EDID = GUID_INIT(0xbd8c1056, 0x9f36, 0x44ec, 0x92, 0xa8, 0xa6, 0x33, 0x7f, 0x81, 0x79, 0x86);
static GUID G_SNP = GUID_INIT(0xa19832b9, 0xac25, 0x11d3, 0x9a, 0x2d, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d);
static GUID G_RNG = GUID_INIT(0x3152bca5, 0xeade, 0x433d, 0x86, 0x2e, 0xc0, 0x1c, 0xdc, 0x29, 0x1f, 0x44);

static const GNAME gnames[] = {
    {GUID_INIT(0x8868e871, 0xe4f1, 0x11d3, 0xbc, 0x22, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81), "ACPI 2.0 RSDP"},
    {GUID_INIT(0xeb9d2d30, 0x2d88, 0x11d3, 0x9a, 0x16, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d), "ACPI 1.0 RSDP"},
    {GUID_INIT(0xeb9d2d31, 0x2d88, 0x11d3, 0x9a, 0x16, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d), "SMBIOS"},
    {GUID_INIT(0xf2fd1544, 0x9794, 0x4a2c, 0x99, 0x2e, 0xe5, 0xbb, 0xcf, 0x20, 0xe3, 0x94), "SMBIOS3"},
    {GUID_INIT(0xb1b621d5, 0xf19c, 0x41a5, 0x83, 0x0b, 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0), "Device Tree (DTB)"},
    {GUID_INIT(0xdcfa911d, 0x26eb, 0x469f, 0xa2, 0x20, 0x38, 0xb7, 0xdc, 0x46, 0x12, 0x20), "MemoryAttributesTable"},
    {GUID_INIT(0xeb66918a, 0x7eef, 0x402a, 0x84, 0x2e, 0x93, 0x1d, 0x21, 0xc3, 0x8a, 0xe9), "RtPropertiesTable"},
    {GUID_INIT(0x7739f24c, 0x93d7, 0x11d4, 0x9a, 0x3a, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d), "HOB list"},
    {GUID_INIT(0x4c19049f, 0x4137, 0x4dd3, 0x9c, 0x10, 0x8b, 0x97, 0xa8, 0x3f, 0xfd, 0xfa), "MemoryTypeInformation"},
    {GUID_INIT(0x05ad34ba, 0x6f02, 0x4214, 0x95, 0x2e, 0x4d, 0xa0, 0x39, 0x8e, 0x2b, 0xb9), "DXE services"},
    {GUID_INIT(0x387477c1, 0x69c7, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b), "SimpleTextInput"},
    {GUID_INIT(0x387477c2, 0x69c7, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b), "SimpleTextOutput"},
    {GUID_INIT(0xdd9e7534, 0x7762, 0x4698, 0x8c, 0x14, 0xf5, 0x85, 0x17, 0xa6, 0x25, 0xaa), "SimpleTextInputEx"},
    {GUID_INIT(0x31878c87, 0x0b75, 0x11d5, 0x9a, 0x4f, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d), "SimplePointer"},
    {GUID_INIT(0x8d59d32b, 0xc655, 0x4ae9, 0x9b, 0x15, 0xf2, 0x59, 0x04, 0x99, 0x2a, 0x43), "AbsolutePointer"},
    {GUID_INIT(0x9042a9de, 0x23dc, 0x4a38, 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a), "GraphicsOutput"},
    {GUID_INIT(0xbd8c1056, 0x9f36, 0x44ec, 0x92, 0xa8, 0xa6, 0x33, 0x7f, 0x81, 0x79, 0x86), "EdidActive"},
    {GUID_INIT(0x1c0c34f6, 0xd380, 0x41fa, 0xa0, 0x49, 0x8a, 0xd0, 0x6c, 0x1a, 0x66, 0xaa), "EdidDiscovered"},
    {GUID_INIT(0x5b1b31a1, 0x9562, 0x11d2, 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b), "LoadedImage"},
    {GUID_INIT(0xbc62157e, 0x3e33, 0x4fec, 0x99, 0x20, 0x2d, 0x3b, 0x36, 0xd7, 0x50, 0xdf), "LoadedImageDevicePath"},
    {GUID_INIT(0x09576e91, 0x6d3f, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b), "DevicePath"},
    {GUID_INIT(0x8b843e20, 0x8132, 0x4852, 0x90, 0xcc, 0x55, 0x1a, 0x4e, 0x4a, 0x7f, 0x1c), "DevicePathToText"},
    {GUID_INIT(0x05c99a21, 0xc70f, 0x4ad2, 0x8a, 0x5f, 0x35, 0xdf, 0x33, 0x43, 0xf5, 0x1e), "DevicePathFromText"},
    {GUID_INIT(0x0379be4e, 0xd706, 0x437d, 0xb0, 0x37, 0xed, 0xb8, 0x2f, 0xb7, 0x72, 0xa4), "DevicePathUtilities"},
    {GUID_INIT(0x964e5b22, 0x6459, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b), "SimpleFileSystem"},
    {GUID_INIT(0x964e5b21, 0x6459, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b), "BlockIO"},
    {GUID_INIT(0xa77b2472, 0xe282, 0x4e9f, 0xa2, 0x45, 0xc2, 0xc0, 0xe2, 0x7b, 0xbc, 0xc1), "BlockIO2"},
    {GUID_INIT(0xce345171, 0xba0b, 0x11d2, 0x8e, 0x4f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b), "DiskIO"},
    {GUID_INIT(0x151c8eae, 0x7f2c, 0x472c, 0x9e, 0x54, 0x98, 0x28, 0x19, 0x4f, 0x6a, 0x88), "DiskIO2"},
    {GUID_INIT(0x8cf2f62c, 0xbc9b, 0x4821, 0x80, 0x8d, 0xec, 0x9e, 0xc4, 0x21, 0xa1, 0xa0), "PartitionInfo"},
    {GUID_INIT(0xbb25cf6f, 0xf1d4, 0x11d2, 0x9a, 0x0c, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0xfd), "SerialIO"},
    {GUID_INIT(0x2f707ebb, 0x4a1a, 0x11d4, 0x9a, 0x38, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d), "PciRootBridgeIO"},
    {GUID_INIT(0x4cf5b200, 0x68b8, 0x4ca5, 0x9e, 0xec, 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a), "PciIO"},
    {GUID_INIT(0x30cfe3e7, 0x3de1, 0x4586, 0xbe, 0x20, 0xde, 0xab, 0xa1, 0xb3, 0xb7, 0x93), "PciEnumerationComplete"},
    {GUID_INIT(0x2b2f68d6, 0x0cd2, 0x44cf, 0x8e, 0x8b, 0xbb, 0xa2, 0x0b, 0x1b, 0x5b, 0x75), "UsbIO"},
    {GUID_INIT(0x3e745226, 0x9818, 0x45b6, 0xa2, 0xac, 0xd7, 0xcd, 0x0e, 0x8b, 0xa2, 0xbc), "Usb2HostController"},
    {GUID_INIT(0xa19832b9, 0xac25, 0x11d3, 0x9a, 0x2d, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d), "SimpleNetwork"},
    {GUID_INIT(0x7ab33a91, 0xace5, 0x4326, 0xb5, 0x72, 0xe7, 0xee, 0x33, 0xd3, 0x9f, 0x16), "ManagedNetwork"},
    {GUID_INIT(0x3152bca5, 0xeade, 0x433d, 0x86, 0x2e, 0xc0, 0x1c, 0xdc, 0x29, 0x1f, 0x44), "RNG"},
    {GUID_INIT(0x18a031ab, 0xb443, 0x4d1a, 0xa5, 0xc0, 0x0c, 0x09, 0x26, 0x1e, 0x9f, 0x71), "DriverBinding"},
    {GUID_INIT(0x6a7a5cff, 0xe8d9, 0x4f70, 0xba, 0xda, 0x75, 0xab, 0x30, 0x25, 0xce, 0x14), "ComponentName2"},
    {GUID_INIT(0x107a772c, 0xd5e1, 0x11d4, 0x9a, 0x46, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d), "ComponentName"},
    {GUID_INIT(0xa4c751fc, 0x23ae, 0x4c3e, 0x92, 0xe9, 0x49, 0x64, 0xcf, 0x63, 0xf3, 0x49), "UnicodeCollation2"},
    {GUID_INIT(0xafbfde41, 0x2e6e, 0x4262, 0xba, 0x65, 0x62, 0xb9, 0x23, 0x6e, 0x54, 0x95), "Timestamp"},
    {GUID_INIT(0x6dcbd5ed, 0xe82d, 0x4c44, 0xbd, 0xa1, 0x71, 0x94, 0x19, 0x9a, 0xd9, 0x2a), "Tcg2"},
    {GUID_INIT(0x52c78312, 0x8edc, 0x4233, 0x98, 0xf2, 0x1a, 0x1a, 0xa5, 0xe3, 0x88, 0xa5), "NvmePassThru"},
    {GUID_INIT(0x26baccb1, 0x6f42, 0x11d4, 0xbc, 0xe7, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81), "CpuArch"},
    {GUID_INIT(0x26baccb3, 0x6f42, 0x11d4, 0xbc, 0xe7, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81), "TimerArch"},
    {GUID_INIT(0x27cfac87, 0x46cc, 0x11d4, 0x9a, 0x38, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d), "RtcArch"},
    {GUID_INIT(0x27cfac88, 0x46cc, 0x11d4, 0x9a, 0x38, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d), "ResetArch"},
    {GUID_INIT(0xffe06bdd, 0x6107, 0x46a6, 0x7b, 0xb2, 0x5a, 0x9c, 0x7e, 0xc5, 0x27, 0x5c), "AcpiTable"},
    {GUID_INIT(0xcf8034be, 0x6768, 0x4d8b, 0xb7, 0x39, 0x7c, 0xce, 0x68, 0x3a, 0x9f, 0xbe), "PciHostBridgeResAlloc"},
};

static const char *gname(const GUID *g) {
    for (UINTN i = 0; i < sizeof gnames / sizeof gnames[0]; i++)
        if (!memcmp(&gnames[i].g, g, sizeof(GUID))) return gnames[i].name;
    return NULL;
}
static int geq(const GUID *a, const GUID *b) { return !memcmp(a, b, sizeof(GUID)); }
static void pguid(const GUID *g) {
    pr("%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x", g->a, g->b, g->c, g->d[0], g->d[1], g->d[2], g->d[3],
       g->d[4], g->d[5], g->d[6], g->d[7]);
}

/* ------------------------------------------------------------------ graphics */
static GOP *gGop;
static volatile u32 *fb;
static u32 fbw, fbh, fbpps, fbfmt;
static u64 fbbase, fbsize;
static PIXBITMASK fbmask;
static u32 rawfmt, rawpps;
static int shadow;
static u64 shadow_base, shadow_bytes;

static u32 shift_of(u32 m) {
    u32 s = 0;
    if (!m) return 0;
    while (!(m & 1)) m >>= 1, s++;
    return s;
}
static u32 rgb(u32 r, u32 g, u32 b) {
    if (fbfmt == 0) return r | (g << 8) | (b << 16);
    if (fbfmt == 1) return b | (g << 8) | (r << 16);
    return (r << shift_of(fbmask.RedMask)) | (g << shift_of(fbmask.GreenMask)) | (b << shift_of(fbmask.BlueMask));
}
static void gfx_rect(int x, int y, int w, int h, u32 col) {
    if (!fb) return;
    for (int j = 0; j < h; j++) {
        int yy = y + j;
        if (yy < 0 || (u32)yy >= fbh) continue;
        for (int i = 0; i < w; i++) {
            int xx = x + i;
            if (xx < 0 || (u32)xx >= fbw) continue;
            fb[(u64)yy * fbpps + xx] = col;
        }
    }
}
static void gfx_char(int x, int y, unsigned c, int sc, u32 col) {
    u64 g = font8x8[c & 255];
    for (int r = 0; r < 8; r++) {
        u8 row = (u8)(g >> (8 * r));
        for (int cc = 0; cc < 8; cc++)
            if (row >> cc & 1) gfx_rect(x + cc * sc, y + r * sc, sc, sc, col);
    }
}
static void gfx_str(int x, int y, const char *s, int sc, u32 col) {
    for (; *s; s++, x += 8 * sc) gfx_char(x, y, (u8)*s, sc, col);
}

static void gfx_init(void) {
    EFI_STATUS st = gBS->LocateProtocol(&G_GOP, NULL, (void **)&gGop);
    if (EFI_ERROR(st) || !gGop) {
        gGop = NULL;
        return;
    }
    GOPMODE *m = gGop->Mode;
    fbfmt = m->Info->PixelFormat;
    fbmask = m->Info->PixelInformation;
    fbw = m->Info->HorizontalResolution;
    fbh = m->Info->VerticalResolution;
    fbpps = m->Info->PixelsPerScanLine;
    fbbase = m->FrameBufferBase;
    fbsize = m->FrameBufferSize;
    rawfmt = fbfmt;
    rawpps = fbpps;
    if (fbfmt != 3 && fbbase) {
        fb = (volatile u32 *)fbbase;
        return;
    }
    /* BltOnly GOP (no linear framebuffer): draw into a RAM shadow buffer and
     * present it with GOP->Blt() now, or with our own virtio-gpu driver after
     * ExitBootServices.  The shadow buffer is also the virtio-gpu backing store. */
    u64 pages = ((u64)fbw * fbh * 4 + 4095) / 4096;
    u64 a = 0;
    if (!EFI_ERROR(gBS->AllocatePages(0, 2, pages, &a)) && a) {
        shadow = 1;
        fb = (volatile u32 *)a;
        shadow_base = a;
        shadow_bytes = pages * 4096;
        fbfmt = 1; /* Blt pixel = B,G,R,reserved */
        fbpps = fbw;
        memset((void *)a, 0, shadow_bytes);
    }
}

static int gpu_ready;
static void gpu_present(void);
static void gfx_present(void) {
    if (!shadow) return;
    if (bs_alive) {
        if (gGop) gGop->Blt(gGop, (void *)fb, 2 /* BufferToVideo */, 0, 0, 0, 0, fbw, fbh, (UINTN)fbw * 4);
    } else if (gpu_ready) gpu_present();
}

/* full-screen page: background colour, title, and the summary lines */
static void gfx_page(u32 bg, u32 fg, u32 accent, const char *title, int sc, int first, int count) {
    if (!fb) return;
    gfx_rect(0, 0, fbw, fbh, bg);
    gfx_rect(0, 0, fbw, 40, accent);
    gfx_str(8, 6, title, 3, fg);
    int y = 48;
    for (int i = first; i < first + count && i < nsumm; i++, y += 8 * sc + 2) gfx_str(8, y, summ[i], sc, fg);
    /* colour bars along the bottom edge so a screenshot can verify pixel format */
    u32 cols[8] = {rgb(255, 0, 0), rgb(0, 255, 0), rgb(0, 0, 255), rgb(255, 255, 0),
                   rgb(0, 255, 255), rgb(255, 0, 255), rgb(255, 255, 255), rgb(0, 0, 0)};
    for (int i = 0; i < 8; i++) gfx_rect(i * (fbw / 8), fbh - 24, fbw / 8, 24, cols[i]);
}

/* ------------------------------------------------------------------ system registers */
#define RDSR(n) \
    ({ \
        u64 v_; \
        __asm__ volatile("mrs %0, " #n : "=r"(v_)); \
        v_; \
    })

static u64 psci(u64 fn, u64 a, u64 b, u64 c) {
    register u64 x0 __asm__("x0") = fn;
    register u64 x1 __asm__("x1") = a;
    register u64 x2 __asm__("x2") = b;
    register u64 x3 __asm__("x3") = c;
    __asm__ volatile("hvc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3) : "memory", "x4", "x5", "x6", "x7", "x8", "x9",
                     "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17");
    return x0;
}

static void delay_ms(u64 ms) {
    u64 f = RDSR(cntfrq_el0);
    u64 t0 = RDSR(cntvct_el0);
    u64 dt = f * ms / 1000;
    while (RDSR(cntvct_el0) - t0 < dt) __asm__ volatile("yield");
}

/* ------------------------------------------------------------------ names */
static const char *memtype_name(u32 t) {
    static const char *n[] = {"Reserved", "LoaderCode", "LoaderData", "BSCode", "BSData", "RTCode", "RTData",
                              "Conventional", "Unusable", "ACPIReclaim", "ACPINVS", "MMIO", "MMIOPortSpace",
                              "PalCode", "Persistent", "Unaccepted"};
    return t < 16 ? n[t] : "?";
}
static const char *virtio_name(u32 t) {
    switch (t) {
    case 1: return "net";
    case 2: return "blk";
    case 3: return "console";
    case 4: return "rng/entropy";
    case 5: return "balloon";
    case 8: return "scsi";
    case 9: return "9p";
    case 16: return "gpu";
    case 18: return "input";
    case 19: return "vsock";
    case 23: return "crypto";
    case 24: return "sock";
    case 25: return "fs";
    case 26: return "fs(virtiofs)";
    case 25 + 100: return "?";
    }
    return "other";
}
static const char *class_name(u32 cc) { /* cc = class<<8 | subclass */
    switch (cc) {
    case 0x0100: return "SCSI";
    case 0x0106: return "SATA";
    case 0x0108: return "NVMe";
    case 0x0180: return "storage";
    case 0x0200: return "ethernet";
    case 0x0300: return "VGA";
    case 0x0380: return "display";
    case 0x0401: return "audio(multimedia)";
    case 0x0403: return "HD audio";
    case 0x0600: return "host bridge";
    case 0x0601: return "ISA bridge";
    case 0x0604: return "PCI-PCI bridge";
    case 0x0700: return "serial";
    case 0x0780: return "comm other";
    case 0x0880: return "system other";
    case 0x0c03: return "USB";
    case 0x0d00: return "wireless";
    case 0xff00: return "unclassified";
    }
    return "?";
}

/* ------------------------------------------------------------------ memory map */
static u8 mmbuf[1 << 16];
static UINTN mmsize, mmkey, mmdsz;
static u32 mmver;

static EFI_STATUS get_memmap(void) {
    mmsize = sizeof mmbuf;
    return gBS->GetMemoryMap(&mmsize, (MEMDESC *)mmbuf, &mmkey, &mmdsz, &mmver);
}
#define MMD(i) ((MEMDESC *)(mmbuf + (UINTN)(i) * mmdsz))

static int mmio_type_at(u64 a, u32 *type) {
    UINTN n = mmsize / mmdsz;
    for (UINTN i = 0; i < n; i++) {
        MEMDESC *d = MMD(i);
        if (a >= d->PhysicalStart && a < d->PhysicalStart + d->NumberOfPages * 4096) {
            *type = d->Type;
            return 1;
        }
    }
    return 0;
}

static void attr_str(char *o, u64 a) {
    static const struct {
        u64 bit;
        const char *n;
    } t[] = {{1, "UC"}, {2, "WC"}, {4, "WT"}, {8, "WB"}, {0x10, "UCE"}, {0x1000, "WP"}, {0x2000, "RP"},
             {0x4000, "XP"}, {0x8000, "NV"}, {0x10000, "MR"}, {0x20000, "RO"}, {0x40000, "SP"},
             {0x8000000000000000ULL, "RT"}};
    *o = 0;
    for (UINTN i = 0; i < sizeof t / sizeof t[0]; i++)
        if (a & t[i].bit) {
            if (*o) *o++ = '|';
            for (const char *s = t[i].n; *s;) *o++ = *s++;
            *o = 0;
        }
}

static void sec_memmap(void) {
    sec("UEFI memory map");
    EFI_STATUS st = get_memmap();
    if (EFI_ERROR(st)) {
        pr("GetMemoryMap failed %llx\n", st);
        return;
    }
    UINTN n = mmsize / mmdsz;
    pr("descriptors=%llu descsize=%llu version=%u total=%llu bytes\n", n, mmdsz, mmver, mmsize);
    u64 pages[16] = {0};
    u64 lo = ~0ULL, hi = 0, ramtotal = 0;
    for (UINTN i = 0; i < n; i++) {
        MEMDESC *d = MMD(i);
        char at[64];
        attr_str(at, d->Attribute);
        pr("  %-12s %016llx-%016llx %7llu pg  attr=%llx %s\n", memtype_name(d->Type), d->PhysicalStart,
           d->PhysicalStart + d->NumberOfPages * 4096 - 1, d->NumberOfPages, d->Attribute, at);
        if (d->Type < 16) pages[d->Type] += d->NumberOfPages;
        if ((d->Type >= 1 && d->Type <= 7) || d->Type == 9 || d->Type == 10) {
            if (d->PhysicalStart < lo) lo = d->PhysicalStart;
            if (d->PhysicalStart + d->NumberOfPages * 4096 > hi) hi = d->PhysicalStart + d->NumberOfPages * 4096;
            ramtotal += d->NumberOfPages * 4096;
        }
    }
    pr("totals by type (MiB):\n");
    for (int t = 0; t < 16; t++)
        if (pages[t]) pr("  %-12s %llu KiB\n", memtype_name(t), pages[t] * 4);
    pr("RAM-like span: %016llx..%016llx, RAM-like bytes=%llu MiB\n", lo, hi, ramtotal >> 20);
    sum("RAM base %llx  span %llu MiB  (Conventional %llu MiB)", lo, ramtotal >> 20, pages[7] >> 8);
}

/* ------------------------------------------------------------------ firmware/cpu */
static void sec_firmware(void) {
    sec("Firmware");
    pr("UEFI spec revision : %u.%u.%u\n", gST->Hdr.Revision >> 16, (gST->Hdr.Revision & 0xffff) / 10,
       (gST->Hdr.Revision & 0xffff) % 10);
    pr("firmware vendor    : %S\n", gST->FirmwareVendor);
    pr("firmware revision  : 0x%x (%u)\n", gST->FirmwareRevision, gST->FirmwareRevision);
    pr("SystemTable=%p BootServices=%p RuntimeServices=%p ImageHandle=%p\n", gST, gBS, gRT, gIH);
    pr("BS hdr rev %x, RT hdr rev %x\n", gBS->Hdr.Revision, gRT->Hdr.Revision);
    sum("Firmware: %S  rev 0x%x  UEFI %u.%u", gST->FirmwareVendor, gST->FirmwareRevision, gST->Hdr.Revision >> 16,
        (gST->Hdr.Revision & 0xffff) / 10);
    EFITIME t;
    EFI_STATUS st = gRT->GetTime(&t, NULL);
    if (!EFI_ERROR(st))
        pr("RTC GetTime        : %04u-%02u-%02u %02u:%02u:%02u tz=%d\n", t.Year, t.Month, t.Day, t.Hour, t.Minute,
           t.Second, t.TimeZone);
    else pr("RTC GetTime failed %llx\n", st);
    LOADEDIMG *li = NULL;
    st = gBS->HandleProtocol(gIH, &G_LOADEDIMG, (void **)&li);
    if (!EFI_ERROR(st) && li) {
        pr("loaded image       : base=%p size=0x%llx codetype=%s datatype=%s\n", li->ImageBase, li->ImageSize,
           memtype_name(li->ImageCodeType), memtype_name(li->ImageDataType));
        pr("  LoadOptionsSize=%u DeviceHandle=%p FilePath=%p\n", li->LoadOptionsSize, li->DeviceHandle, li->FilePath);
        if (gDP2T && li->FilePath) pr("  FilePath text: %S\n", gDP2T->ConvertDevicePathToText(li->FilePath, 0, 0));
    }
}

static void sec_cpu(void) {
    sec("CPU / system registers");
    u64 el = RDSR(currentel) >> 2;
    u64 midr = RDSR(midr_el1), mpidr = RDSR(mpidr_el1), freq = RDSR(cntfrq_el0);
    u64 pfr0 = RDSR(id_aa64pfr0_el1), pfr1 = RDSR(id_aa64pfr1_el1), mmfr0 = RDSR(id_aa64mmfr0_el1);
    u64 mmfr1 = RDSR(id_aa64mmfr1_el1), isar0 = RDSR(id_aa64isar0_el1), dfr0 = RDSR(id_aa64dfr0_el1);
    pr("CurrentEL          : EL%llu\n", el);
    pr("MIDR_EL1           : %016llx (impl 0x%llx part 0x%llx var %llu rev %llu)\n", midr, midr >> 24, (midr >> 4) & 0xfff,
       (midr >> 20) & 15, midr & 15);
    pr("MPIDR_EL1          : %016llx (aff3=%llu aff2=%llu aff1=%llu aff0=%llu, MT=%llu U=%llu)\n", mpidr,
       (mpidr >> 32) & 255, (mpidr >> 16) & 255, (mpidr >> 8) & 255, mpidr & 255, (mpidr >> 24) & 1,
       (mpidr >> 30) & 1);
    pr("CNTFRQ_EL0         : %llu Hz\n", freq);
    pr("CNTVCT_EL0         : %llu\n", RDSR(cntvct_el0));
    pr("ID_AA64PFR0_EL1    : %016llx\n", pfr0);
    pr("   EL0=%llu EL1=%llu EL2=%llu EL3=%llu FP=%llx AdvSIMD=%llx GIC(sysreg)=%llu RAS=%llu SVE=%llu MPAM=%llu\n",
       pfr0 & 15, (pfr0 >> 4) & 15, (pfr0 >> 8) & 15, (pfr0 >> 12) & 15, (pfr0 >> 16) & 15, (pfr0 >> 20) & 15,
       (pfr0 >> 24) & 15, (pfr0 >> 28) & 15, (pfr0 >> 32) & 15, (pfr0 >> 40) & 15);
    pr("ID_AA64PFR1_EL1    : %016llx\n", pfr1);
    static const char *pa[] = {"32b/4GiB", "36b/64GiB", "40b/1TiB", "42b/4TiB", "44b/16TiB", "48b/256TiB", "52b/4PiB"};
    u64 parange = mmfr0 & 15;
    pr("ID_AA64MMFR0_EL1   : %016llx\n", mmfr0);
    pr("   PARange=%llu (%s) ASIDBits=%llu BigEnd=%llu TGran4=%llu TGran16=%llu TGran64=%llu\n", parange,
       parange < 7 ? pa[parange] : "?", (mmfr0 >> 4) & 15, (mmfr0 >> 8) & 15, (mmfr0 >> 28) & 15,
       (mmfr0 >> 20) & 15, (mmfr0 >> 24) & 15);
    pr("ID_AA64MMFR1_EL1   : %016llx\n", mmfr1);
    pr("ID_AA64ISAR0_EL1   : %016llx (AES=%llu SHA1=%llu SHA2=%llu CRC32=%llu Atomic=%llu RNDR=%llu)\n", isar0,
       (isar0 >> 4) & 15, (isar0 >> 8) & 15, (isar0 >> 12) & 15, (isar0 >> 16) & 15, (isar0 >> 20) & 15,
       (isar0 >> 60) & 15);
    pr("ID_AA64DFR0_EL1    : %016llx\n", dfr0);
    u64 sctlr = RDSR(sctlr_el1), tcr = RDSR(tcr_el1), mair = RDSR(mair_el1), ttbr0 = RDSR(ttbr0_el1);
    u64 ttbr1 = RDSR(ttbr1_el1), vbar = RDSR(vbar_el1);
    pr("SCTLR_EL1=%016llx (M=%llu C=%llu I=%llu WXN=%llu)  TCR_EL1=%016llx  MAIR_EL1=%016llx\n", sctlr, sctlr & 1,
       (sctlr >> 2) & 1, (sctlr >> 12) & 1, (sctlr >> 19) & 1, tcr, mair);
    pr("TTBR0_EL1=%016llx TTBR1_EL1=%016llx VBAR_EL1=%016llx\n", ttbr0, ttbr1, vbar);
    u64 sp;
    __asm__ volatile("mov %0, sp" : "=r"(sp));
    pr("SP=%016llx  DAIF=%llx\n", sp, RDSR(daif) >> 6);
    sum("CPU: EL%llu MIDR=%llx MPIDR=%llx CNTFRQ=%llu Hz", el, midr, mpidr, freq);
    sum("     PA range %s, GICv3+ sysreg field=%llu, granules 4K=%llu 16K=%llu 64K=%llu", parange < 7 ? pa[parange] : "?",
        (pfr0 >> 24) & 15, (mmfr0 >> 28) & 15, (mmfr0 >> 20) & 15, (mmfr0 >> 24) & 15);
    flush_log();
    if (((pfr0 >> 24) & 15) != 0) {
        u64 sre = ({
            u64 v_;
            __asm__ volatile("mrs %0, s3_0_c12_c12_5" : "=r"(v_));
            v_;
        });
        pr("ICC_SRE_EL1        : %llx (SRE=%llu)\n", sre, sre & 1);
    }
}

/* ------------------------------------------------------------------ GOP section */
static const char *pixfmt_name(u32 f) {
    static const char *n[] = {"RGBX (R low byte)", "BGRX (B low byte)", "BitMask", "BltOnly"};
    return f < 4 ? n[f] : "?";
}
static void sec_gop(void) {
    sec("Graphics Output Protocol");
    if (!gGop) {
        pr("no GOP found\n");
        sum("GOP: none");
        return;
    }
    GOPMODE *m = gGop->Mode;
    pr("MaxMode=%u current Mode=%u\n", m->MaxMode, m->Mode);
    for (u32 i = 0; i < m->MaxMode && i < 64; i++) {
        GOPINFO *inf;
        UINTN sz;
        EFI_STATUS st = gGop->QueryMode(gGop, i, &sz, &inf);
        if (EFI_ERROR(st)) {
            pr("  mode %u: QueryMode error %llx\n", i, st);
            continue;
        }
        pr("  mode %u%s: %ux%u pps=%u fmt=%s masks R%08x G%08x B%08x\n", i, i == m->Mode ? "*" : " ",
           inf->HorizontalResolution, inf->VerticalResolution, inf->PixelsPerScanLine, pixfmt_name(inf->PixelFormat),
           inf->PixelInformation.RedMask, inf->PixelInformation.GreenMask, inf->PixelInformation.BlueMask);
    }
    pr("framebuffer base=%llx size=0x%llx (%llu KiB) stride=%u px (%u bytes) %ux%u fmt=%s\n", fbbase, fbsize,
       fbsize >> 10, rawpps, rawpps * 4, fbw, fbh, pixfmt_name(rawfmt));
    if (shadow)
        pr("=> GOP is BltOnly / FrameBufferBase=0: NO linear framebuffer.  Probe uses a RAM shadow buffer at %llx "
           "(%llu KiB) presented with GOP->Blt()\n", shadow_base, shadow_bytes >> 10);
    u32 t;
    if (fbbase && mmio_type_at(fbbase, &t)) pr("framebuffer lies in memory-map type %s\n", memtype_name(t));
    else pr("framebuffer base not covered by the UEFI memory map\n");
    sum("GOP: %ux%u %s fb=%llx size=%llu KiB stride=%u modes=%u", fbw, fbh, pixfmt_name(rawfmt), fbbase, fbsize >> 10,
        rawpps, m->MaxMode);
    /* text console modes */
    TXTOUT *o = gST->ConOut;
    if (o && o->Mode) {
        pr("ConOut: MaxMode=%d Mode=%d\n", o->Mode->MaxMode, o->Mode->Mode);
        for (s32 i = 0; i < o->Mode->MaxMode && i < 8; i++) {
            UINTN c, r;
            if (!EFI_ERROR(o->QueryMode(o, i, &c, &r))) pr("  text mode %d: %llux%llu\n", i, c, r);
        }
    }
}

/* ------------------------------------------------------------------ ACPI */
static char sigbuf[8][5];
static const char *sig4(const u8 *p, int slot) {
    for (int i = 0; i < 4; i++) sigbuf[slot][i] = (p[i] >= 0x20 && p[i] < 0x7f) ? p[i] : '.';
    sigbuf[slot][4] = 0;
    return sigbuf[slot];
}

static void acpi_madt(const u8 *t) {
    u32 len = rd32(t + 4);
    pr("  MADT: rev %u, local int ctrl addr=%x flags=%x\n", t[8], rd32(t + 36), rd32(t + 40));
    int ncpu = 0;
    for (u32 o = 44; o + 2 <= len;) {
        const u8 *e = t + o;
        u8 ty = e[0], l = e[1];
        if (l < 2) break;
        switch (ty) {
        case 0x0B: /* GICC */
            pr("    GICC cpuif=%u uid=%u flags=%x parking=%u perfGSIV=%u parked=%llx gicc_base=%llx gicv=%llx gich=%llx "
               "vgicmaint=%u gicr=%llx mpidr=%llx eff=%u\n",
               rd32(e + 4), rd32(e + 8), rd32(e + 12), rd32(e + 16), rd32(e + 20), rd64(e + 24), rd64(e + 32),
               rd64(e + 40), rd64(e + 48), rd32(e + 56), rd64(e + 60), rd64(e + 68), e[76]);
            ncpu++;
            break;
        case 0x0C:
            pr("    GICD id=%u base=%llx vecbase=%u GIC VERSION=%u\n", rd32(e + 4), rd64(e + 8), rd32(e + 16), e[20]);
            sum("GICD base %llx, GIC version %u (from MADT)", rd64(e + 8), e[20]);
            break;
        case 0x0D:
            pr("    GIC MSI frame id=%u base=%llx flags=%x spicount=%u spibase=%u\n", rd32(e + 4), rd64(e + 8),
               rd32(e + 16), rd16(e + 20), rd16(e + 22));
            break;
        case 0x0E:
            pr("    GICR discovery range base=%llx length=%x\n", rd64(e + 4), rd32(e + 12));
            sum("GICR base %llx len %x", rd64(e + 4), rd32(e + 12));
            break;
        case 0x0F:
            pr("    GIC ITS id=%u base=%llx\n", rd32(e + 4), rd64(e + 8));
            sum("GIC ITS base %llx", rd64(e + 8));
            break;
        default: pr("    entry type 0x%x len %u\n", ty, l);
        }
        o += l;
    }
    pr("    => %d GICC entries\n", ncpu);
    sum("MADT: %d CPUs", ncpu);
}

static void acpi_gtdt(const u8 *t) {
    u32 len = rd32(t + 4);
    pr("  GTDT: rev %u cnt control base=%llx\n", t[8], rd64(t + 36));
    if (len >= 76) {
        pr("    secure EL1 timer     GSIV=%u flags=%x\n", rd32(t + 48), rd32(t + 52));
        pr("    non-secure EL1 timer GSIV=%u flags=%x (physical, PPI)\n", rd32(t + 56), rd32(t + 60));
        pr("    virtual EL1 timer    GSIV=%u flags=%x\n", rd32(t + 64), rd32(t + 68));
        pr("    non-secure EL2 timer GSIV=%u flags=%x\n", rd32(t + 72), rd32(t + 76));
        sum("Timer GSIV: phys-NS %u  virt %u  hyp %u  sec %u", rd32(t + 56), rd32(t + 64), rd32(t + 72), rd32(t + 48));
    }
    if (len >= 96) pr("    platform timer count=%u offset=%u\n", rd32(t + 88), rd32(t + 92));
}

static void acpi_mcfg(const u8 *t);
static u64 ecam_base;
static u8 ecam_sbus, ecam_ebus;
static void acpi_mcfg(const u8 *t) {
    u32 len = rd32(t + 4);
    for (u32 o = 44; o + 16 <= len; o += 16) {
        pr("  MCFG: ECAM base=%llx segment=%u buses %u..%u\n", rd64(t + o), rd16(t + o + 8), t[o + 10], t[o + 11]);
        if (!ecam_base) {
            ecam_base = rd64(t + o);
            ecam_sbus = t[o + 10];
            ecam_ebus = t[o + 11];
        }
        sum("PCIe ECAM %llx buses %u..%u", rd64(t + o), t[o + 10], t[o + 11]);
    }
}

static void acpi_spcr(const u8 *t) {
    u32 ty = t[36];
    static const char *typ[] = {"16550", "16550 DBGP1 subset", "?", "ARM PL011", "MSM8x60", "16550 (NVIDIA)",
                                "TI OMAP", "?", "APM88xxxx", "MSM8974", "SAM5250", "Intel USIF", "i.MX6",
                                "ARM SBSA 32-bit access", "ARM SBSA generic UART", "ARM DCC"};
    pr("  SPCR: rev %u interface type %u (%s) addrspace=%u width=%u addr=%llx irqtype=%x gsiv=%u baud=%u\n", t[8], ty,
       ty < 16 ? typ[ty] : "other", t[40], t[41], rd64(t + 44), t[52],
       rd32(t + 54), t[58]);
    sum("SPCR UART: type %u addr %llx gsiv %u", ty, rd64(t + 44), rd32(t + 54));
}

static void acpi_dbg2(const u8 *t) {
    u32 off = rd32(t + 36), n = rd32(t + 40);
    pr("  DBG2: %u debug device(s)\n", n);
    for (u32 i = 0; i < n && off + 22 < rd32(t + 4); i++) {
        const u8 *d = t + off;
        u16 l = rd16(d + 1);
        u16 bro = rd16(d + 18);
        pr("    dev: type=0x%x subtype=0x%x ns='%s' addr=%llx\n", rd16(d + 12), rd16(d + 14), (const char *)(d + rd16(d + 6)),
           d[3] ? rd64(t + off + bro + 4) : 0ULL);
        off += l;
    }
}

static void acpi_fadt(const u8 *t) {
    u32 len = rd32(t + 4);
    pr("  FADT: rev %u.%u len %u flags=%x (HW_REDUCED=%u)\n", t[8], len > 131 ? t[131] : 0, len, rd32(t + 112),
       (rd32(t + 112) >> 20) & 1);
    if (len > 130)
        pr("    ARM boot arch flags=%x (PSCI_COMPLIANT=%u, PSCI_USE_HVC=%u)\n", rd16(t + 129), rd16(t + 129) & 1,
           (rd16(t + 129) >> 1) & 1);
    if (len >= 276) pr("    hypervisor vendor id=%016llx\n", rd64(t + 268));
    if (len > 130) sum("FADT: PSCI %s conduit %s", (rd16(t + 129) & 1) ? "yes" : "no", (rd16(t + 129) & 2) ? "HVC" : "SMC");
}

/* scan AML for Device() names and _HID strings/eisa ids */
static void acpi_aml(const u8 *t) {
    u32 len = rd32(t + 4);
    int nd = 0;
    pr("  AML devices/_HID in %s:\n", sig4(t, 7));
    for (u32 i = 36; i + 8 < len; i++) {
        if (t[i] == 0x5B && t[i + 1] == 0x82) { /* DeviceOp */
            u32 j = i + 2;
            u32 lead = t[j] >> 6;
            j += 1 + lead;
            pr("    Device(%c%c%c%c)\n", t[j], t[j + 1], t[j + 2], t[j + 3]);
            if (++nd > 60) break;
        } else if (t[i] == '_' && t[i + 1] == 'H' && t[i + 2] == 'I' && t[i + 3] == 'D') {
            if (t[i + 4] == 0x0D) pr("      _HID \"%s\"\n", (const char *)(t + i + 5));
            else if (t[i + 4] == 0x0C) pr("      _HID eisa/dword 0x%x\n", rd32(t + i + 5));
            else pr("      _HID (op %02x)\n", t[i + 4]);
        }
    }
}

static void sec_acpi(void *rsdp_v) {
    sec("ACPI");
    const u8 *r = rsdp_v;
    pr("RSDP at %p sig '%s' rev %u oem '%c%c%c%c%c%c' rsdt=%x xsdt=%llx\n", r, sig4(r, 0), r[15], r[9], r[10], r[11],
       r[12], r[13], r[14], rd32(r + 16), rd64(r + 24));
    if (r[15] < 2) {
        pr("ACPI 1.0 only - no XSDT\n");
        return;
    }
    const u8 *x = (const u8 *)rd64(r + 24);
    u32 xl = rd32(x + 4);
    pr("XSDT at %p len %u oem '%c%c%c%c%c%c' -> %u tables\n", x, xl, x[10], x[11], x[12], x[13], x[14], x[15],
       (xl - 36) / 8);
    char list[128];
    char *lp = list;
    for (u32 i = 0; i < (xl - 36) / 8; i++) {
        const u8 *t = (const u8 *)rd64(x + 36 + i * 8);
        pr("  [%u] %p '%s' len %u rev %u oem '%c%c%c%c%c%c' oemtid '%c%c%c%c%c%c%c%c'\n", i, t, sig4(t, 0), rd32(t + 4),
           t[8], t[10], t[11], t[12], t[13], t[14], t[15], t[16], t[17], t[18], t[19], t[20], t[21], t[22], t[23]);
        if (lp < list + 116) {
            for (int k = 0; k < 4; k++) *lp++ = t[k];
            *lp++ = ' ';
            *lp = 0;
        }
    }
    sum("ACPI tables: %s", list);
    for (u32 i = 0; i < (xl - 36) / 8; i++) {
        const u8 *t = (const u8 *)rd64(x + 36 + i * 8);
        u32 sg = rd32(t);
        if (sg == 0x43495041) acpi_madt(t);       /* APIC */
        else if (sg == 0x54445447) acpi_gtdt(t);  /* GTDT */
        else if (sg == 0x4746434d) acpi_mcfg(t);  /* MCFG */
        else if (sg == 0x52435053) acpi_spcr(t);  /* SPCR */
        else if (sg == 0x32474244) acpi_dbg2(t);  /* DBG2 */
        else if (sg == 0x50434146) {              /* FACP */
            acpi_fadt(t);
            u64 dsdt = rd32(t + 40);
            if (rd32(t + 4) >= 148 && rd64(t + 140)) dsdt = rd64(t + 140);
            if (dsdt) {
                const u8 *d = (const u8 *)dsdt;
                pr("  DSDT at %p '%s' len %u\n", d, sig4(d, 1), rd32(d + 4));
                acpi_aml(d);
                if (rd32(d + 4) <= 2048) { /* small DSDT: dump raw AML so it can be decoded offline (iasl) */
                    pr("  DSDT raw (%u bytes):\n", rd32(d + 4));
                    for (u32 o = 0; o < rd32(d + 4); o += 32) {
                        pr("   %04x:", o);
                        for (u32 k = o; k < o + 32 && k < rd32(d + 4); k++) pr(" %02x", d[k]);
                        pr("\n");
                    }
                }
            }
        } else if (sg == 0x54445353) acpi_aml(t); /* SSDT */
        flush_log();
    }
}

/* ------------------------------------------------------------------ Device Tree */
static int printable_strs(const u8 *v, u32 len) {
    if (!len || v[len - 1]) return 0;
    u32 start = 0;
    for (u32 i = 0; i < len; i++) {
        if (!v[i]) {
            if (i == start) return 0;
            start = i + 1;
        } else if (v[i] < 0x20 || v[i] > 0x7e) return 0;
    }
    return 1;
}

static void dump_fdt(const u8 *b) {
    if (be32(b) != 0xd00dfeed) {
        pr("bad FDT magic %x\n", be32(b));
        return;
    }
    u32 total = be32(b + 4), off_st = be32(b + 8), off_str = be32(b + 12), ver = be32(b + 20);
    u32 size_st = be32(b + 36);
    pr("FDT at %p: totalsize=%u version=%u struct@%u(%u) strings@%u boot_cpuid=%u\n", b, total, ver, off_st, size_st,
       off_str, be32(b + 28));
    const u8 *p = b + off_st;
    const u8 *end = p + size_st;
    const char *strs = (const char *)b + off_str;
    int depth = 0;
    while (p < end) {
        u32 tok = be32(p);
        p += 4;
        if (tok == 1) {
            const char *name = (const char *)p;
            UINTN l = slen(name) + 1;
            p += (l + 3) & ~3ULL;
            pr("%*s%s {\n", depth * 2, "", *name ? name : "/");
            depth++;
        } else if (tok == 2) {
            depth--;
            pr("%*s};\n", depth * 2, "");
        } else if (tok == 3) {
            u32 l = be32(p), no = be32(p + 4);
            const u8 *v = p + 8;
            p += 8 + ((l + 3) & ~3U);
            const char *pn = strs + no;
            if (l == 0) pr("%*s%s;\n", depth * 2, "", pn);
            else if (printable_strs(v, l)) {
                pr("%*s%s = ", depth * 2, "", pn);
                for (u32 i = 0; i < l;) {
                    pr("%s\"%s\"", i ? ", " : "", (const char *)(v + i));
                    i += (u32)slen((const char *)v + i) + 1;
                }
                pr(";\n");
            } else if (l % 4 == 0) {
                pr("%*s%s = <", depth * 2, "", pn);
                for (u32 i = 0; i < l / 4 && i < 64; i++) pr("%s0x%x", i ? " " : "", be32(v + i * 4));
                pr("%s>;\n", l / 4 > 64 ? " ..." : "");
            } else {
                pr("%*s%s = [", depth * 2, "", pn);
                for (u32 i = 0; i < l && i < 64; i++) pr("%02x", v[i]);
                pr("];\n");
            }
        } else if (tok == 4) {
        } else if (tok == 9) break;
        else {
            pr("bad token %x\n", tok);
            break;
        }
    }
}

/* ------------------------------------------------------------------ SMBIOS */
static const char *smstr(const u8 *s, u8 idx) {
    const u8 *f = s;
    const char *p = (const char *)f + f[1];
    if (!idx) return "";
    while (--idx && *p) p += slen(p) + 1;
    return p;
}
static void smbios_walk(const u8 *p, u64 maxlen) {
    const u8 *end = p + maxlen;
    int n4 = 0;
    while (p + 4 <= end) {
        u8 ty = p[0], l = p[1];
        if (ty == 127) break;
        if (ty == 0) pr("  SMBIOS type0 BIOS: vendor='%s' version='%s' date='%s'\n", smstr(p, p[4]), smstr(p, p[5]), smstr(p, p[8]));
        else if (ty == 1) pr("  SMBIOS type1 System: manufacturer='%s' product='%s' version='%s'\n", smstr(p, p[4]), smstr(p, p[5]), smstr(p, p[6]));
        else if (ty == 4) n4++;
        const char *q = (const char *)p + l;
        while (q[0] || q[1]) q++;
        p = (const u8 *)q + 2;
    }
    pr("  SMBIOS type4 (processor) count: %d\n", n4);
}

/* ------------------------------------------------------------------ config tables */
static void *acpi_rsdp, *dtb_ptr;
static void sec_cfgtables(void) {
    sec("Configuration tables");
    pr("NumberOfTableEntries=%llu\n", gST->NumberOfTableEntries);
    for (UINTN i = 0; i < gST->NumberOfTableEntries; i++) {
        CFGTBL *c = &gST->ConfigurationTable[i];
        const char *n = gname(&c->VendorGuid);
        pr("  [%llu] ", i);
        pguid(&c->VendorGuid);
        pr(" %p  %s\n", c->VendorTable, n ? n : "(unknown)");
        if (geq(&c->VendorGuid, &G_ACPI20)) acpi_rsdp = c->VendorTable;
        else if (geq(&c->VendorGuid, &G_DTB)) dtb_ptr = c->VendorTable;
    }
    sum("Config tables: %llu  ACPI=%s  DTB=%s", gST->NumberOfTableEntries, acpi_rsdp ? "yes" : "no",
        dtb_ptr ? "yes" : "no");
    flush_log();
    for (UINTN i = 0; i < gST->NumberOfTableEntries; i++) {
        CFGTBL *c = &gST->ConfigurationTable[i];
        if (geq(&c->VendorGuid, &G_SMBIOS3)) {
            const u8 *e = c->VendorTable;
            pr("SMBIOS3 entry: anchor '%c%c%c%c%c' ver %u.%u structs@%llx maxsize=%u\n", e[0], e[1], e[2], e[3], e[4], e[7],
               e[8], rd64(e + 16), rd32(e + 12));
            smbios_walk((const u8 *)rd64(e + 16), rd32(e + 12));
        } else if (geq(&c->VendorGuid, &G_SMBIOS)) {
            const u8 *e = c->VendorTable;
            pr("SMBIOS2 entry: structs@%x len=%u\n", rd32(e + 24), rd16(e + 22));
            smbios_walk((const u8 *)(u64)rd32(e + 24), rd16(e + 22));
        }
    }
    if (acpi_rsdp) sec_acpi(acpi_rsdp);
    if (dtb_ptr) {
        sec("Device Tree dump");
        dump_fdt(dtb_ptr);
    } else pr("\n(no Device Tree configuration table)\n");
    flush_log();
}

/* ------------------------------------------------------------------ handle census */
static int census_interesting(GUID **pg, UINTN np) {
    static const char *hw[] = {"GraphicsOutput", "SimpleTextInput", "SimpleTextOutput", "SimpleTextInputEx",
                               "SimplePointer", "AbsolutePointer", "PciIO", "PciRootBridgeIO", "UsbIO",
                               "Usb2HostController", "BlockIO", "SimpleFileSystem", "SimpleNetwork", "SerialIO",
                               "RNG", "EdidActive", "PartitionInfo", "AcpiTable"};
    int has_dp = 0, has_img = 0;
    for (UINTN k = 0; k < np; k++) {
        const char *nm = gname(pg[k]);
        if (!nm) continue;
        if (streq(nm, "DevicePath")) has_dp = 1;
        if (streq(nm, "LoadedImage")) has_img = 1;
        for (UINTN j = 0; j < sizeof hw / sizeof hw[0]; j++)
            if (streq(nm, hw[j])) return 1;
    }
    return has_dp && !has_img;
}

static void sec_handles(void) {
    sec("Handle / protocol census");
    EFI_HANDLE *h;
    UINTN n;
    EFI_STATUS st = gBS->LocateHandleBuffer(0, NULL, NULL, &n, &h);
    if (EFI_ERROR(st)) {
        pr("LocateHandleBuffer(All) failed %llx\n", st);
        return;
    }
    pr("%llu handles\n", n);
    static GUID seen[128];
    static int seencnt[128];
    int nseen = 0;
    for (UINTN i = 0; i < n; i++) {
        GUID **pg;
        UINTN np;
        st = gBS->ProtocolsPerHandle(h[i], &pg, &np);
        if (EFI_ERROR(st)) continue;
        int show = census_interesting(pg, np);
        if (show) pr("  handle %p:", h[i]);
        for (UINTN k = 0; k < np; k++) {
            const char *nm = gname(pg[k]);
            if (show) {
                if (nm) pr(" %s", nm);
                else {
                    pr(" ");
                    pguid(pg[k]);
                }
            }
            int f = -1;
            for (int s = 0; s < nseen; s++)
                if (geq(&seen[s], pg[k])) f = s;
            if (f < 0 && nseen < 128) {
                seen[nseen] = *pg[k];
                seencnt[nseen] = 0;
                f = nseen++;
            }
            if (f >= 0) seencnt[f]++;
        }
        if (show) pr("\n");
        /* device path text for handles that carry one */
        static GUID G_DP = GUID_INIT(0x09576e91, 0x6d3f, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b);
        void *dp = NULL;
        if (show && gDP2T && !EFI_ERROR(gBS->HandleProtocol(h[i], &G_DP, &dp)) && dp) {
            CHAR16 *t = gDP2T->ConvertDevicePathToText(dp, 0, 0);
            if (t) pr("      path: %S\n", t);
        }
        gBS->FreePool(pg);
        if ((i & 15) == 15) flush_log();
    }
    pr("protocol totals (known GUIDs; unknown ones are firmware-internal and summed):\n");
    int unk = 0;
    for (int s = 0; s < nseen; s++) {
        const char *nm = gname(&seen[s]);
        if (nm) pr("  %3d x %s\n", seencnt[s], nm);
        else unk++;
    }
    pr("  (+ %d unknown GUIDs)\n", unk);
    gBS->FreePool(h);
}

static UINTN count_handles(GUID *g) {
    EFI_HANDLE *h;
    UINTN n = 0;
    if (EFI_ERROR(gBS->LocateHandleBuffer(2, g, NULL, &n, &h))) return 0;
    gBS->FreePool(h);
    return n;
}

static void sec_console(void) {
    sec("Console / input devices");
    pr("ConsoleInHandle=%p ConsoleOutHandle=%p StandardErrorHandle=%p\n", gST->ConsoleInHandle, gST->ConsoleOutHandle,
       gST->StandardErrorHandle);
    pr("ConOut==StdErr protocol pointers: %s\n", gST->ConOut == gST->StdErr ? "identical" : "different");
    static GUID G_DP = GUID_INIT(0x09576e91, 0x6d3f, 0x11d2, 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b);
    EFI_HANDLE hs[3] = {gST->ConsoleInHandle, gST->ConsoleOutHandle, gST->StandardErrorHandle};
    const char *nm[3] = {"ConIn", "ConOut", "StdErr"};
    for (int i = 0; i < 3; i++) {
        void *dp = NULL;
        if (gDP2T && hs[i] && !EFI_ERROR(gBS->HandleProtocol(hs[i], &G_DP, &dp)) && dp)
            pr("  %s device path: %S\n", nm[i], gDP2T->ConvertDevicePathToText(dp, 0, 0));
        else pr("  %s handle has no DevicePath protocol\n", nm[i]);
    }
    struct {
        GUID *g;
        const char *n;
    } l[] = {{&G_TEXTIN, "SimpleTextInput"}, {&G_TEXTINEX, "SimpleTextInputEx"}, {&G_TEXTOUT, "SimpleTextOutput"},
             {&G_SIMPTR, "SimplePointer"}, {&G_ABSPTR, "AbsolutePointer"}, {&G_SERIALIO, "SerialIO"},
             {&G_GOP, "GraphicsOutput"}, {&G_EDID, "EdidActive"}, {&G_USBIO, "UsbIO"}, {&G_USB2HC, "Usb2HostController"},
             {&G_SNP, "SimpleNetwork"}, {&G_BLOCKIO, "BlockIO"}, {&G_SFS, "SimpleFileSystem"}, {&G_RNG, "RNG"},
             {&G_PCIRB, "PciRootBridgeIO"}, {&G_PCIIO, "PciIO"}};
    char list[200];
    char *lp = list;
    *lp = 0;
    for (UINTN i = 0; i < sizeof l / sizeof l[0]; i++) {
        UINTN c = count_handles(l[i].g);
        pr("  %-20s handles: %llu\n", l[i].n, c);
        if (c && (l[i].g == &G_SERIALIO || l[i].g == &G_SIMPTR || l[i].g == &G_ABSPTR || l[i].g == &G_USBIO ||
                  l[i].g == &G_USB2HC || l[i].g == &G_TEXTIN || l[i].g == &G_SNP || l[i].g == &G_RNG)) {
            const char *s = l[i].n;
            while (*s && lp < list + 190) *lp++ = *s++;
            *lp++ = ' ';
            *lp = 0;
        }
    }
    sum("Input/serial/net protocols present: %s", list);
    INKEY k;
    EFI_STATUS st = gST->ConIn->ReadKeyStroke(gST->ConIn, &k);
    pr("ConIn->ReadKeyStroke (non-blocking) -> %llx%s\n", st, st == EFI_NOT_READY ? " (NOT_READY, no key pending)" : "");
    flush_log();
}

/* ------------------------------------------------------------------ PCI */
typedef struct {
    UINTN seg, bus, dev, fn;
    PCIIO *io;
    volatile u8 *ecam;
} PCIDEV;

static u32 pci_rd32(PCIDEV *d, u32 off) {
    if (d->io) {
        u32 v = 0xffffffff;
        d->io->PciRead(d->io, 2, off, 1, &v);
        return v;
    }
    return *(volatile u32 *)(d->ecam + off);
}

typedef struct {
    int type;
    u64 common, notify, isr, devcfg;
    u32 mult;
} VDEV;
static VDEV vdevs[8];
static int nvdev;

static u64 pci_bar_base(PCIDEV *d, u32 bar) {
    u32 v = pci_rd32(d, 0x10 + bar * 4);
    if (v & 1) return 0;
    u64 a = v & ~15U;
    if (((v >> 1) & 3) == 2) a |= (u64)pci_rd32(d, 0x10 + (bar + 1) * 4) << 32;
    return a;
}

static int npci, nvirtio;
static char virtio_sum[160];
static void pci_dump(PCIDEV *d) {
    u32 id = pci_rd32(d, 0);
    if ((id & 0xffff) == 0xffff) return;
    u32 vid = id & 0xffff, did = id >> 16;
    u32 cmdst = pci_rd32(d, 4), clsrev = pci_rd32(d, 8), hdr = (pci_rd32(d, 0xc) >> 16) & 0xff;
    u32 subs = pci_rd32(d, 0x2c);
    u32 cls = clsrev >> 8;
    npci++;
    pr("  %02llx:%02llx.%llx [%04x:%04x] class %06x (%s) rev %02x cmd=%04x status=%04x hdr=%02x subsys=%04x:%04x\n",
       d->bus, d->dev, d->fn, vid, did, cls, class_name(cls >> 8), clsrev & 0xff, cmdst & 0xffff, cmdst >> 16, hdr,
       subs & 0xffff, subs >> 16);
    if ((hdr & 0x7f) == 0) {
        u32 il = pci_rd32(d, 0x3c);
        pr("      interrupt line=%u pin=%u (0=none,1=INTA..)\n", il & 0xff, (il >> 8) & 0xff);
    }
    if (cls == 0x0c0330) { /* xHCI: peek at what each memory BAR looks like */
        for (int b = 0; b < 6; b++) {
            u64 ba = pci_bar_base(d, b);
            if (!ba) continue;
            volatile u32 *r = (volatile u32 *)ba;
            pr("      xHCI peek BAR%d @%llx: %08x %08x %08x %08x (CAPLENGTH=%x HCIVERSION=%x)\n", b, ba, r[0], r[1], r[2],
               r[3], r[0] & 0xff, r[0] >> 16);
        }
    }
    if (vid == 0x1af4) {
        u32 vt = did >= 0x1040 ? did - 0x1040 : (subs >> 16);
        pr("      VIRTIO %s device, type %u (%s)\n", did >= 0x1040 ? "modern" : "transitional", vt, virtio_name(vt));
        nvirtio++;
        char *s = virtio_sum;
        while (*s) s++;
        if (s < virtio_sum + 140) {
            const char *nn = virtio_name(vt);
            while (*nn) *s++ = *nn++;
            *s++ = ' ';
            *s = 0;
        }
    } else if (vid == 0x106b) pr("      Apple vendor device\n");
    /* BARs */
    if ((hdr & 0x7f) == 0) {
        for (int b = 0; b < 6; b++) {
            u32 v = pci_rd32(d, 0x10 + b * 4);
            if (!v) continue;
            int bi = b;
            if (v & 1) {
                pr("      BAR%d io  %08x", b, v & ~3U);
            } else {
                u32 ty = (v >> 1) & 3;
                u64 a = v & ~15U;
                if (ty == 2) {
                    a |= (u64)pci_rd32(d, 0x10 + (b + 1) * 4) << 32;
                }
                pr("      BAR%d mem%s%s %016llx", b, ty == 2 ? "64" : "32", (v & 8) ? " pf" : "", a);
                if (ty == 2) b++;
            }
            if (d->io) {
                u64 sup;
                u8 *res = NULL;
                if (!EFI_ERROR(d->io->GetBarAttributes(d->io, (u8)bi, &sup, (void **)&res)) && res &&
                    res[0] == 0x8A)
                    pr("  size=0x%llx", rd64(res + 38));
            }
            pr("\n");
        }
    }
    /* capabilities */
    VDEV cur;
    memset(&cur, 0, sizeof cur);
    if (vid == 0x1af4) cur.type = did >= 0x1040 ? did - 0x1040 : (subs >> 16);
    if ((cmdst >> 16) & 0x10) {
        u32 cp = pci_rd32(d, 0x34) & 0xfc;
        for (int guard = 0; cp && guard < 48; guard++) {
            u32 c0 = pci_rd32(d, cp);
            u32 id8 = c0 & 0xff;
            pr("      cap@%02x id=%02x", cp, id8);
            if (id8 == 0x09) {
                u32 c1 = pci_rd32(d, cp + 4), c2 = pci_rd32(d, cp + 8), c3 = pci_rd32(d, cp + 12);
                u32 ty = (c0 >> 24) & 0xff;
                static const char *tn[] = {"?", "common", "notify", "isr", "device", "pci-cfg", "shared-mem"};
                pr(" virtio-cap type=%u(%s) bar=%u offset=%x length=%x", ty, ty < 7 ? tn[ty] : "?", c1 & 0xff, c2, c3);
                if (ty == 2) pr(" notify_off_mult=%x", pci_rd32(d, cp + 16));
                u64 ba = pci_bar_base(d, c1 & 0xff);
                if (ba && vid == 0x1af4) {
                    if (ty == 1) cur.common = ba + c2;
                    else if (ty == 2) cur.notify = ba + c2, cur.mult = pci_rd32(d, cp + 16);
                    else if (ty == 3) cur.isr = ba + c2;
                    else if (ty == 4) cur.devcfg = ba + c2;
                }
            } else if (id8 == 0x05) pr(" MSI");
            else if (id8 == 0x11) {
                u32 c1 = pci_rd32(d, cp + 4);
                pr(" MSI-X tblsize=%u", (c0 >> 16 & 0x7ff) + 1);
                (void)c1;
            } else if (id8 == 0x10) pr(" PCIe");
            else if (id8 == 0x01) pr(" PM");
            pr("\n");
            cp = (c0 >> 8) & 0xfc;
        }
    }
    if (vid == 0x1af4 && did >= 0x1040 && cur.common && cur.notify && nvdev < 8) vdevs[nvdev++] = cur;
}

static void pr_res(const u8 *r) {
    for (int guard = 0; guard < 32; guard++) {
        u8 tag = r[0];
        if (tag == 0x79) break;
        if (tag == 0x8A) {
            u16 l = rd16(r + 1);
            u8 rt = r[3];
            pr("      window %s: min=%llx max=%llx len=%llx flags=%02x/%02x\n",
               rt == 0 ? "mem" : rt == 1 ? "io " : rt == 2 ? "bus" : "?", rd64(r + 14), rd64(r + 22), rd64(r + 38), r[4],
               r[5]);
            r += l + 3;
        } else if (tag == 0x87) {
            u16 l = rd16(r + 1);
            u8 rt = r[3];
            pr("      window(d) %s: min=%x max=%x len=%x\n", rt == 0 ? "mem" : rt == 1 ? "io " : rt == 2 ? "bus" : "?",
               rd32(r + 10), rd32(r + 14), rd32(r + 22));
            r += l + 3;
        } else {
            pr("      (descriptor tag %02x)\n", tag);
            break;
        }
    }
}

static void sec_pci(void) {
    sec("PCI");
    EFI_HANDLE *h;
    UINTN n;
    EFI_STATUS st = gBS->LocateHandleBuffer(2, &G_PCIRB, NULL, &n, &h);
    if (!EFI_ERROR(st)) {
        pr("PCI root bridges (PciRootBridgeIO): %llu\n", n);
        for (UINTN i = 0; i < n; i++) {
            PCIRB *rb;
            if (EFI_ERROR(gBS->HandleProtocol(h[i], &G_PCIRB, (void **)&rb))) continue;
            pr("  root bridge %p segment=%u\n", h[i], rb->SegmentNumber);
            void *res = NULL;
            if (!EFI_ERROR(rb->Configuration(rb, &res)) && res) pr_res(res);
        }
        gBS->FreePool(h);
    } else pr("no PciRootBridgeIO handles (status %llx)\n", st);
    flush_log();

    st = gBS->LocateHandleBuffer(2, &G_PCIIO, NULL, &n, &h);
    if (!EFI_ERROR(st)) {
        pr("PCI devices via PciIO protocol: %llu\n", n);
        for (UINTN i = 0; i < n; i++) {
            PCIDEV d = {0};
            if (EFI_ERROR(gBS->HandleProtocol(h[i], &G_PCIIO, (void **)&d.io))) continue;
            d.io->GetLocation(d.io, &d.seg, &d.bus, &d.dev, &d.fn);
            pci_dump(&d);
            if ((i & 7) == 7) flush_log();
        }
        gBS->FreePool(h);
    } else pr("no PciIO handles (status %llx)\n", st);
    int via_pciio = npci;
    flush_log();

    if (cfg_ecam && ecam_base) {
        u32 t = 0;
        int covered = mmio_type_at(ecam_base, &t);
        pr("ECAM %llx (buses %u..%u): %s", ecam_base, ecam_sbus, ecam_ebus,
           covered ? "in memory map as " : "NOT in UEFI memory map");
        if (covered) pr("%s", memtype_name(t));
        pr("\n");
        if (covered || cfg_ecam == 2) {
            pr("scanning ECAM directly:\n");
            flush_log();
            int keep = npci;
            npci = 0;
            for (UINTN bus = ecam_sbus; bus <= ecam_ebus; bus++)
                for (UINTN dev = 0; dev < 32; dev++)
                    for (UINTN fn = 0; fn < 8; fn++) {
                        PCIDEV d = {0};
                        d.bus = bus;
                        d.dev = dev;
                        d.fn = fn;
                        d.ecam = (volatile u8 *)(ecam_base + (((bus - ecam_sbus) << 20) | (dev << 15) | (fn << 12)));
                        u32 id = *(volatile u32 *)d.ecam;
                        if ((id & 0xffff) == 0xffff || id == 0) {
                            if (fn == 0) break;
                            continue;
                        }
                        /* when PciIO already listed it, skip the (noisy) full dump but still count */
                        if (via_pciio) {
                            pr("  ecam sees %02llx:%02llx.%llx [%04x:%04x]\n", bus, dev, fn, id & 0xffff, id >> 16);
                            npci++;
                        } else {
                            pci_dump(&d);
                            if (fn == 0 && !((*(volatile u32 *)(d.ecam + 0xc) >> 16) & 0x80)) break;
                        }
                    }
            if (via_pciio) npci = keep;
            else npci += keep;
        }
    } else pr("no MCFG/ECAM (or disabled): not scanning ECAM\n");
    sum("PCI: %d function(s); virtio: %s", npci, virtio_sum[0] ? virtio_sum : "none");
    flush_log();
}

/* ------------------------------------------------------------------ variables / PSCI */
static void sec_vars(void) {
    sec("EFI variables (names only)");
    static CHAR16 name[256];
    GUID g;
    memset(&g, 0, sizeof g);
    name[0] = 0;
    int count = 0;
    for (;;) {
        UINTN sz = sizeof name;
        EFI_STATUS st = gRT->GetNextVariableName(&sz, name, &g);
        if (EFI_ERROR(st)) break;
        UINTN vs = 0;
        u32 attr = 0;
        gRT->GetVariable(name, &g, &attr, &vs, NULL);
        pr("  %S  attr=%x size=%llu guid=", name, attr, vs);
        pguid(&g);
        pr("\n");
        if (++count >= 48) break;
    }
    pr("%d variable(s) listed\n", count);
    flush_log();
}

static void sec_psci(void) {
    sec("PSCI probe (HVC conduit)");
    flush_log();
    u64 v = psci(0x84000000, 0, 0, 0);
    pr("PSCI_VERSION -> %llx (%llu.%llu)\n", v, (v >> 16) & 0xffff, v & 0xffff);
    flush_log();
    static const struct {
        u64 id;
        const char *n;
    } f[] = {{0xC4000003, "CPU_ON(64)"}, {0x84000002, "CPU_OFF"}, {0xC4000001, "CPU_SUSPEND(64)"},
             {0x84000008, "SYSTEM_OFF"}, {0x84000009, "SYSTEM_RESET"}, {0xC4000012, "SYSTEM_RESET2(64)"},
             {0xC4000004, "AFFINITY_INFO(64)"}, {0x84000006, "MIGRATE_INFO_TYPE"}, {0x8400000A, "PSCI_FEATURES"}};
    for (UINTN i = 0; i < sizeof f / sizeof f[0]; i++) {
        u64 r = psci(0x8400000A, f[i].id, 0, 0);
        pr("  PSCI_FEATURES(%s) -> %llx%s\n", f[i].n, r, r == (u64)-1 ? " (NOT_SUPPORTED)" : "");
    }
    v = psci(0xC4000004, RDSR(mpidr_el1) & 0xffffff, 0, 0);
    pr("  AFFINITY_INFO(self) -> %llx\n", v);
    v = psci(0xC4000004, 1, 0, 0);
    pr("  AFFINITY_INFO(mpidr=1) -> %llx (0 ON, 1 OFF, 2 ON_PENDING)\n", v);
    sum("PSCI via HVC ok, version %llu.%llu", (psci(0x84000000, 0, 0, 0) >> 16) & 0xffff, psci(0x84000000, 0, 0, 0) & 0xffff);
    flush_log();
}

/* ------------------------------------------------------------------ minimal virtio-pci (modern) driver */
/* Everything here talks to BAR MMIO only (addresses gathered from PCI config
 * space while boot services were alive), so it keeps working after
 * ExitBootServices.  DMA memory comes from AllocatePages() beforehand. */
static inline void dmb_(void) { __asm__ volatile("dmb sy" ::: "memory"); }
static u8 mr8(u64 a) { return *(volatile u8 *)a; }
static u16 mr16(u64 a) { return *(volatile u16 *)a; }
static u32 mr32(u64 a) { return *(volatile u32 *)a; }
static void mw8(u64 a, u8 v) { *(volatile u8 *)a = v; }
static void mw16(u64 a, u16 v) { *(volatile u16 *)a = v; }
static void mw32(u64 a, u32 v) { *(volatile u32 *)a = v; }
static void mw64(u64 a, u64 v) {
    mw32(a, (u32)v);
    mw32(a + 4, (u32)(v >> 32));
}
/* common cfg offsets */
#define VC_DFSEL 0
#define VC_DF 4
#define VC_GFSEL 8
#define VC_GF 12
#define VC_NQ 18
#define VC_STATUS 20
#define VC_QSEL 22
#define VC_QSIZE 24
#define VC_QMSIX 26
#define VC_QEN 28
#define VC_QNOFF 30
#define VC_QDESC 32
#define VC_QAVAIL 40
#define VC_QUSED 48

static VDEV *find_vdev(int type) {
    for (int i = 0; i < nvdev; i++)
        if (vdevs[i].type == type) return &vdevs[i];
    return NULL;
}

static u64 dma_alloc(UINTN pages) {
    u64 a = 0;
    if (!bs_alive || EFI_ERROR(gBS->AllocatePages(0, 2, pages, &a)) || !a) return 0;
    memset((void *)a, 0, pages * 4096);
    return a;
}

typedef struct {
    u64 desc, avail, used, notify;
    u16 size, last_used, avail_idx, qindex;
} VQ;

static int vio_negotiate(VDEV *v, u32 want_lo, u32 *dlo, u32 *dhi) {
    u64 c = v->common;
    mw8(c + VC_STATUS, 0);
    for (int i = 0; i < 1000 && mr8(c + VC_STATUS); i++) delay_ms(1);
    mw8(c + VC_STATUS, 1);
    mw8(c + VC_STATUS, 1 | 2);
    mw32(c + VC_DFSEL, 0);
    *dlo = mr32(c + VC_DF);
    mw32(c + VC_DFSEL, 1);
    *dhi = mr32(c + VC_DF);
    mw32(c + VC_GFSEL, 0);
    mw32(c + VC_GF, *dlo & want_lo);
    mw32(c + VC_GFSEL, 1);
    mw32(c + VC_GF, 1); /* VIRTIO_F_VERSION_1 (bit 32) */
    mw8(c + VC_STATUS, 1 | 2 | 8);
    return (mr8(c + VC_STATUS) & 8) != 0;
}

static int vio_queue(VDEV *v, int q, u64 mem, u16 want, VQ *vq) {
    u64 c = v->common;
    mw16(c + VC_QSEL, (u16)q);
    u16 max = mr16(c + VC_QSIZE);
    if (!max) return 0;
    u16 n = max < want ? max : want;
    mw16(c + VC_QSIZE, n);
    vq->size = n;
    vq->desc = mem;
    vq->avail = mem + 16 * (u64)n;                          /* 2-byte aligned */
    vq->used = (vq->avail + 6 + 2 * (u64)n + 3) & ~3ULL;    /* 4-byte aligned */
    vq->last_used = 0;
    vq->avail_idx = 0;
    vq->qindex = (u16)q;
    mw64(c + VC_QDESC, vq->desc);
    mw64(c + VC_QAVAIL, vq->avail);
    mw64(c + VC_QUSED, vq->used);
    mw16(c + VC_QEN, 1);
    vq->notify = v->notify + (u64)mr16(c + VC_QNOFF) * v->mult;
    return 1;
}

/* Submit one request: buffer 0 device-readable, optional buffer 1 device-writable. */
static int vq_xfer(VQ *q, u64 a0, u32 l0, u64 a1, u32 l1, u64 timeout_ms) {
    volatile u8 *d = (volatile u8 *)q->desc;
    *(volatile u64 *)(d + 0) = a0;
    *(volatile u32 *)(d + 8) = l0;
    *(volatile u16 *)(d + 12) = a1 ? 1 : 0;
    *(volatile u16 *)(d + 14) = 1;
    if (a1) {
        *(volatile u64 *)(d + 16) = a1;
        *(volatile u32 *)(d + 24) = l1;
        *(volatile u16 *)(d + 28) = 2;
        *(volatile u16 *)(d + 30) = 0;
    }
    volatile u8 *av = (volatile u8 *)q->avail;
    *(volatile u16 *)(av + 4 + 2 * (q->avail_idx % q->size)) = 0;
    dmb_();
    q->avail_idx++;
    *(volatile u16 *)(av + 2) = q->avail_idx;
    dmb_();
    mw16(q->notify, q->qindex);
    volatile u16 *uidx = (volatile u16 *)(q->used + 2);
    u64 f = RDSR(cntfrq_el0), t0 = RDSR(cntvct_el0);
    while (*uidx == q->last_used) {
        if (RDSR(cntvct_el0) - t0 > f * timeout_ms / 1000) return -1;
    }
    dmb_();
    u32 len = *(volatile u32 *)(q->used + 4 + 8 * (q->last_used % q->size) + 4);
    q->last_used++;
    return (int)len;
}

/* ---- virtio-console ---- */
static int cons_delay_ms = 200;
static VQ cons_rx, cons_tx;
static u64 cons_buf;
static u32 cons_dlo, cons_dhi;

static void cons_write(const char *s, UINTN n) {
    if (cons_state != 1) return;
    while (n) {
        UINTN k = n > 3000 ? 3000 : n;
        memcpy((void *)cons_buf, s, k);
        if (vq_xfer(&cons_tx, cons_buf, (u32)k, 0, 0, 200) < 0) {
            cons_state = -1; /* device isn't consuming; stop trying */
            return;
        }
        s += k;
        n -= k;
    }
}

static void cons_init(void) {
    sec("virtio-console (host stdout path)");
    VDEV *v = find_vdev(3);
    if (!v) {
        pr("no virtio-console PCI device\n");
        cons_state = -1;
        return;
    }
    u64 mem = dma_alloc(3);
    cons_buf = mem + 8192;
    if (!mem) {
        pr("DMA alloc failed\n");
        cons_state = -1;
        return;
    }
    pr("common=%llx notify=%llx(mult %u) isr=%llx devcfg=%llx\n", v->common, v->notify, v->mult, v->isr, v->devcfg);
    int ok = vio_negotiate(v, 0, &cons_dlo, &cons_dhi);
    pr("device features: lo=%08x hi=%08x (bit0=SIZE bit1=MULTIPORT bit2=EMERG_WRITE; hi bit0 = VERSION_1)\n", cons_dlo,
       cons_dhi);
    pr("num_queues=%u FEATURES_OK=%d (we accept only VERSION_1: single-port mode)\n", mr16(v->common + VC_NQ), ok);
    if (!ok) {
        cons_state = -1;
        return;
    }
    if (!vio_queue(v, 0, mem, 8, &cons_rx) || !vio_queue(v, 1, mem + 4096, 8, &cons_tx)) {
        pr("queue setup failed\n");
        cons_state = -1;
        return;
    }
    mw8(v->common + VC_STATUS, 1 | 2 | 8 | 4); /* DRIVER_OK */
    cons_state = 1;
    {
        static const char hello[] = "VIRTIO-CONSOLE-HELLO from coolcom UEFI probe (port 0, transmitq)\r\n";
        memcpy((void *)cons_buf, hello, sizeof hello - 1);
        delay_ms(cons_delay_ms);
        u64 t0 = RDSR(cntvct_el0);
        int r = vq_xfer(&cons_tx, cons_buf, sizeof hello - 1, 0, 0, 1000);
        if (r < 0) {
            pr("  first kick timed out; kicking queue 1 again\n");
            mw16(cons_tx.notify, cons_tx.qindex);
            u64 f = RDSR(cntfrq_el0), t1 = RDSR(cntvct_el0);
            while (*(volatile u16 *)(cons_tx.used + 2) == cons_tx.last_used && RDSR(cntvct_el0) - t1 < f) {}
            if (*(volatile u16 *)(cons_tx.used + 2) != cons_tx.last_used) {
                cons_tx.last_used++;
                r = 0;
                pr("  second kick worked\n");
            }
        }
        u64 dt = (RDSR(cntvct_el0) - t0) * 1000000 / RDSR(cntfrq_el0);
        pr("test write on queue 1: used len=%d (%s) after %llu us, used.idx=%u\n", r,
           r < 0 ? "TIMEOUT - device did not consume" : "consumed", dt, *(volatile u16 *)(cons_tx.used + 2));
        if (r < 0) cons_state = -1;
    }
    /* replay everything logged so far, so the host sees the whole report */
    cons_write(logbuf, loglen);
    pr("virtio-console: DRIVER_OK, log replayed to the host serial path (status=%02x)\n", mr8(v->common + VC_STATUS));
}

/* ---- virtio-gpu (2D) ---- */
static VQ gpu_cq;
static u64 gpu_buf;
static int gpu_state;
static u32 gpu_w, gpu_h;

static int gpu_cmd(u32 reqlen, u32 resplen) {
    int r = vq_xfer(&gpu_cq, gpu_buf, reqlen, gpu_buf + 2048, resplen, 500);
    if (r < 0) return -1;
    return (int)rd32((void *)(gpu_buf + 2048)); /* response type */
}

static void gpu_hdr(u32 type) {
    memset((void *)gpu_buf, 0, 64);
    *(volatile u32 *)gpu_buf = type;
}

static void gpu_present(void) {
    volatile u32 *r = (volatile u32 *)gpu_buf;
    /* TRANSFER_TO_HOST_2D: hdr(24) rect(16) offset(8) resource(4) pad(4) */
    gpu_hdr(0x105);
    r[6] = 0, r[7] = 0, r[8] = fbw, r[9] = fbh;
    r[10] = 0, r[11] = 0; /* offset */
    r[12] = 1;
    gpu_cmd(56, 24);
    /* RESOURCE_FLUSH: hdr rect resource pad */
    gpu_hdr(0x104);
    r[6] = 0, r[7] = 0, r[8] = fbw, r[9] = fbh;
    r[10] = 1;
    gpu_cmd(48, 24);
}

/* Preallocate DMA memory while boot services are still alive. */
static u64 gpu_mem;
static void gpu_prealloc(void) {
    if (find_vdev(16)) gpu_mem = dma_alloc(2);
}

static void gpu_init(void) {
    VDEV *v = find_vdev(16);
    if (!v || !gpu_mem || !shadow) {
        pr("gpu_init: no virtio-gpu / no DMA memory / no shadow buffer\n");
        gpu_state = -1;
        return;
    }
    gpu_buf = gpu_mem + 4096;
    u32 dlo, dhi;
    int ok = vio_negotiate(v, 0, &dlo, &dhi);
    pr("virtio-gpu: device features lo=%08x hi=%08x (lo bit0=VIRGL bit1=EDID) FEATURES_OK=%d num_queues=%u\n", dlo, dhi, ok,
       mr16(v->common + VC_NQ));
    if (!ok || !vio_queue(v, 0, gpu_mem, 16, &gpu_cq)) {
        pr("virtio-gpu: negotiate/queue failed\n");
        gpu_state = -1;
        return;
    }
    mw8(v->common + VC_STATUS, 1 | 2 | 8 | 4);
    volatile u32 *r = (volatile u32 *)gpu_buf;
    volatile u32 *resp = (volatile u32 *)(gpu_buf + 2048);
    /* GET_DISPLAY_INFO */
    gpu_hdr(0x100);
    int t = gpu_cmd(24, 24 + 16 * 24);
    pr("virtio-gpu GET_DISPLAY_INFO -> resp 0x%x", t);
    if (t == 0x1101) {
        for (int i = 0; i < 4; i++)
            pr("  scanout%d: %ux%u+%u+%u enabled=%u", i, resp[6 + i * 6 + 2], resp[6 + i * 6 + 3], resp[6 + i * 6],
               resp[6 + i * 6 + 1], resp[6 + i * 6 + 4]);
        gpu_w = resp[8];
        gpu_h = resp[9];
    }
    pr("\n");
    /* RESOURCE_CREATE_2D id=1 B8G8R8X8_UNORM */
    gpu_hdr(0x101);
    r[6] = 1, r[7] = 2, r[8] = fbw, r[9] = fbh;
    t = gpu_cmd(40, 24);
    pr("virtio-gpu RESOURCE_CREATE_2D %ux%u -> 0x%x\n", fbw, fbh, t);
    /* RESOURCE_ATTACH_BACKING: one contiguous entry = the shadow buffer */
    gpu_hdr(0x106);
    r[6] = 1, r[7] = 1;
    *(volatile u64 *)(gpu_buf + 32) = shadow_base;
    r[10] = (u32)(fbw * fbh * 4), r[11] = 0;
    t = gpu_cmd(48, 24);
    pr("virtio-gpu RESOURCE_ATTACH_BACKING @%llx -> 0x%x\n", shadow_base, t);
    /* SET_SCANOUT */
    gpu_hdr(0x103);
    r[6] = 0, r[7] = 0, r[8] = fbw, r[9] = fbh;
    r[10] = 0, r[11] = 1;
    t = gpu_cmd(48, 24);
    pr("virtio-gpu SET_SCANOUT 0 <- res 1 -> 0x%x\n", t);
    gpu_state = (t == 0x1100) ? 1 : -1;
    gpu_ready = gpu_state == 1;
}

/* ------------------------------------------------------------------ files / config */
static EFIFILE *rootdir;

static void open_volume(void) {
    LOADEDIMG *li = NULL;
    SFS *fs = NULL;
    if (EFI_ERROR(gBS->HandleProtocol(gIH, &G_LOADEDIMG, (void **)&li)) || !li) return;
    if (EFI_ERROR(gBS->HandleProtocol(li->DeviceHandle, &G_SFS, (void **)&fs)) || !fs) return;
    if (EFI_ERROR(fs->OpenVolume(fs, &rootdir))) rootdir = NULL;
}

static void read_cfg(void) {
    if (!rootdir) return;
    EFIFILE *f;
    if (EFI_ERROR(rootdir->Open(rootdir, &f, L"probe.cfg", 1, 0))) return;
    static char b[513];
    UINTN n = 512;
    f->Read(f, &n, b);
    b[n] = 0;
    f->Close(f);
    for (char *p = b; *p;) {
        char *eol = p;
        while (*eol && *eol != '\n' && *eol != '\r') eol++;
        char save = *eol;
        *eol = 0;
        char *eq = p;
        while (*eq && *eq != '=') eq++;
        if (*eq) {
            *eq = 0;
            char *v = eq + 1;
            int num = 0;
            for (char *q = v; *q >= '0' && *q <= '9'; q++) num = num * 10 + (*q - '0');
            if (streq(p, "wait")) cfg_wait = num;
            else if (streq(p, "postwait")) cfg_postwait = num;
            else if (streq(p, "off")) {
                int i = 0;
                while (v[i] && i < 15) cfg_off[i] = v[i], i++;
                cfg_off[i] = 0;
            } else if (streq(p, "pci")) cfg_ecam = streq(v, "noecam") ? 0 : streq(v, "force") ? 2 : 1;
        }
        *eol = save;
        p = eol;
        while (*p == '\n' || *p == '\r') p++;
    }
}

static void open_log(void) {
    if (!rootdir) return;
    EFIFILE *f;
    if (!EFI_ERROR(rootdir->Open(rootdir, &f, L"probe.log", 3, 0))) f->Delete(f); /* start fresh */
    if (EFI_ERROR(rootdir->Open(rootdir, &logf, L"probe.log", 0x8000000000000003ULL, 0))) logf = NULL;
}

/* ------------------------------------------------------------------ post-ExitBootServices */
static void num_str(char *o, u64 v) {
    char t[24];
    int n = 0;
    if (!v) t[n++] = '0';
    while (v) t[n++] = '0' + v % 10, v /= 10;
    while (n) *o++ = t[--n];
    *o = 0;
}

static void power_off_psci(void) {
    psci(0x84000008, 0, 0, 0); /* PSCI SYSTEM_OFF */
}

static void spin(void) {
    for (;;) __asm__ volatile("wfi");
}

EFI_STATUS efi_main(EFI_HANDLE ih, SYSTBL *st) {
    gIH = ih;
    gST = st;
    gBS = st->BootServices;
    gRT = st->RuntimeServices;
    gBS->SetWatchdogTimer(0, 0, 0, NULL);
    gBS->LocateProtocol(&G_DP2T, NULL, (void **)&gDP2T);
    open_volume();
    read_cfg();
    open_log();
    gfx_init();

    pr("coolcom UEFI probe (build " __DATE__ " " __TIME__ ")\n");
    pr("config: wait=%d postwait=%d off=%s ecam=%d; log file: %s\n", cfg_wait, cfg_postwait, cfg_off, cfg_ecam,
       logf ? "\\probe.log" : "(none - no writable SimpleFileSystem)");
    out16(st->StdErr, "[stderr] STDERR-TEST hello from StdErr\n");
    out16(st->ConOut, "[conout] CONOUT-TEST hello from ConOut\n");
    sum("coolcom UEFI probe - running on the platform under test");

    sec_firmware();
    sec_cpu();
    sec_memmap();
    sec_gop();
    sec_cfgtables();
    sec_handles();
    sec_console();
    sec_pci();
    gpu_prealloc();
    cons_init();
    sec_vars();
    sec_psci();

    sec("Result");
    pr("probe finished collecting; drawing summary page, then off=%s\n", cfg_off);
    flush_log();

    /* summary page on the screen (GOP Blt from the RAM shadow buffer) */
    con_on = 0;
    sum("virtio-console: %s, virtio-gpu backing at %llx", cons_state == 1 ? "up" : "not working", shadow_base);
    gfx_page(rgb(0, 32, 96), rgb(255, 255, 255), rgb(200, 100, 0), "coolcom UEFI probe", 1, 0, nsumm);
    gfx_present();

    /* wait for a key or timeout */
    INKEY k;
    int got = 0;
    for (int i = 0; i < cfg_wait * 10; i++) {
        if (!EFI_ERROR(gST->ConIn->ReadKeyStroke(gST->ConIn, &k))) {
            got = 1;
            break;
        }
        gBS->Stall(100000);
    }
    pr("wait finished, key=%d\n", got);

    if (streq(cfg_off, "rt")) {
        pr("calling ResetSystem(EfiResetShutdown) with boot services alive\n");
        flush_log();
        gRT->ResetSystem(2, 0, 0, NULL);
        pr("ResetSystem returned!\n");
        flush_log();
        spin();
    }
    if (streq(cfg_off, "none")) {
        pr("off=none: spinning\n");
        flush_log();
        spin();
    }

    /* ExitBootServices */
    pr("calling ExitBootServices\n");
    flush_log();
    EFI_STATUS s = EFI_SUCCESS;
    for (int tries = 0; tries < 8; tries++) {
        s = get_memmap();
        if (EFI_ERROR(s)) break;
        s = gBS->ExitBootServices(gIH, mmkey);
        if (!EFI_ERROR(s)) break;
    }
    if (EFI_ERROR(s)) {
        pr("ExitBootServices FAILED: %llx\n", s);
        flush_log();
        gRT->ResetSystem(2, 0, 0, NULL);
        spin();
    }
    bs_alive = 0;
    /* From here: no boot services, no ConOut, no file writes.  Only MMIO + PSCI. */
    pr("[post-EBS] ExitBootServices returned SUCCESS; virtio-console %s\n", cons_state == 1 ? "still works" : "n/a");
    pr("[post-EBS] CurrentEL=EL%llu SCTLR_EL1=%llx TTBR0_EL1=%llx (firmware page tables still live)\n",
       RDSR(currentel) >> 2, RDSR(sctlr_el1), RDSR(ttbr0_el1));
    gpu_init();
    nsumm = 0;
    sum("ExitBootServices returned SUCCESS.");
    sum("GOP->Blt is gone (boot service); the firmware GOP");
    sum("was BltOnly anyway - there is no linear framebuffer.");
    sum("This page was drawn into a RAM buffer at %llx", shadow_base);
    sum("and pushed to the display by our own virtio-gpu");
    sum("driver (TRANSFER_TO_HOST_2D + RESOURCE_FLUSH).");
    sum("virtio-gpu init: %s   virtio-console: %s", gpu_state == 1 ? "OK" : "FAILED", cons_state == 1 ? "OK" : "n/a");
    sum("CurrentEL=EL%llu MPIDR=%llx", RDSR(currentel) >> 2, RDSR(mpidr_el1));
    sum("Runtime services table still at %p", gRT);
    gfx_page(rgb(0, 80, 0), rgb(255, 255, 255), rgb(160, 0, 160), "AFTER ExitBootServices", 2, 0, nsumm);
    gfx_present();
    pr("[post-EBS] page drawn via %s\n", gpu_state == 1 ? "virtio-gpu" : "(nothing: gpu failed)");
    int y = 48 + nsumm * 18 + 16;
    for (int i = cfg_postwait * 4; i > 0; i--) {
        char b[48] = "shutdown via ";
        char *p = b + 13;
        const char *how = streq(cfg_off, "rtpost") ? "RT ResetSystem" : "PSCI SYSTEM_OFF (HVC)";
        while (*how) *p++ = *how++;
        *p++ = ' ';
        *p++ = 'i';
        *p++ = 'n';
        *p++ = ' ';
        num_str(p, (u64)(i + 3) / 4);
        gfx_rect(8, y, fbw - 16, 20, rgb(0, 80, 0));
        gfx_str(8, y, b, 2, rgb(255, 255, 0));
        gfx_present();
        delay_ms(250);
    }
    gfx_rect(8, y, fbw - 16, 20, rgb(0, 80, 0));
    if (streq(cfg_off, "rtpost")) {
        gfx_str(8, y, "calling runtime ResetSystem now", 2, rgb(255, 255, 0));
        gfx_present();
        pr("[post-EBS] calling runtime ResetSystem(shutdown)\n");
        gRT->ResetSystem(2, 0, 0, NULL);
        pr("[post-EBS] ResetSystem RETURNED\n");
        gfx_str(8, y + 20, "ResetSystem RETURNED (did not power off)", 2, rgb(255, 128, 128));
        gfx_present();
    } else {
        gfx_str(8, y, "PSCI SYSTEM_OFF now", 2, rgb(255, 255, 0));
        gfx_present();
        pr("[post-EBS] calling PSCI SYSTEM_OFF via HVC\n");
        power_off_psci();
        pr("[post-EBS] PSCI SYSTEM_OFF RETURNED\n");
        gfx_str(8, y + 20, "PSCI SYSTEM_OFF RETURNED (did not power off)", 2, rgb(255, 128, 128));
        gfx_present();
    }
    spin();
    return 0;
}
