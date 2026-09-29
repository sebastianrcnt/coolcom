// Minimal FDT v17 reader. Property payloads are 4-byte aligned, so read
// all 64-bit cells as two BE32 values instead of casting to I64 pointers.
#define FDT_MEMS 16
#define FDT_RES 64
#define FDT_CPUS 8
class CFdtRange {I64 start, end;};
class CFdtCpu {I64 mpidr, release;};
CFdtRange fdt_mem[FDT_MEMS], fdt_res[FDT_RES];
CFdtCpu fdt_cpu[FDT_CPUS];
I64 fdt_nmem, fdt_nres, fdt_ncpu;
I64 fdt_uart = 0x235200000, fdt_aic = 0x23B100000;
I64 fdt_finisher, fdt_size;
Bool fdt_vm, fdt_test;
I64 fdt_unix_time, fdt_utc_offset;  // coolvm /chosen: host clock at boot (KDate.HC)

// VM devices, found by compatible string under /soc and /chosen:
//   simple-framebuffer, coolcom,coolvm-input, virtio,mmio (any number).
#define FDT_BLKS 4
class CFdtDev {I64 base, size, irq;};
CFdtDev fdt_input, fdt_blk[FDT_BLKS], fdt_fb;
I64 fdt_nblk, fdt_fb_w, fdt_fb_h, fdt_fb_stride;
Bool fdt_fb_32bpp;  // format x8r8g8b8 or a8r8g8b8
// The node being parsed (leaf nodes below /soc and /chosen).
CFdtDev fdt_nd;
I64 fdt_nd_kind, fdt_nd_w, fdt_nd_h, fdt_nd_stride;
Bool fdt_nd_32bpp;

I64 Fdt32(U8 *p)
{
    return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
}

I64 Fdt64(U8 *p)
{
    return (Fdt32(p) << 32) | Fdt32(p + 4);
}

Bool FdtPrefix(U8 *s, U8 *prefix)
{
    while (*prefix) {
        if (*s++ != *prefix++)
            return FALSE;
    }
    return TRUE;
}

Bool FdtEqual(U8 *a, U8 *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return *a == *b;
}

Bool FdtCompat(U8 *data, I64 len, U8 *want)
{//Is want one of the NUL-separated strings of a compatible property?
    U8 *end = data + len;
    while (data < end) {
        if (FdtEqual(data, want))
            return TRUE;
        while (*data)
            data++;
        data++;
    }
    return FALSE;
}

U0 FdtNodeStart()
{
    fdt_nd.base = fdt_nd.size = fdt_nd.irq = 0;
    fdt_nd_kind = fdt_nd_w = fdt_nd_h = fdt_nd_stride = 0;
    fdt_nd_32bpp = FALSE;
}

U0 FdtNodeDone()
{
    if (fdt_nd_kind == 1) {
        fdt_input.base = fdt_nd.base;
        fdt_input.size = fdt_nd.size;
        fdt_input.irq = fdt_nd.irq;
    } else if (fdt_nd_kind == 2) {
        if (fdt_nblk < FDT_BLKS) {
            fdt_blk[fdt_nblk].base = fdt_nd.base;
            fdt_blk[fdt_nblk].size = fdt_nd.size;
            fdt_blk[fdt_nblk].irq = fdt_nd.irq;
            fdt_nblk++;
        }
    } else if (fdt_nd_kind == 3 && fdt_nd_32bpp && fdt_nd_w && fdt_nd_h) {
        fdt_fb.base = fdt_nd.base;
        fdt_fb.size = fdt_nd.size;
        fdt_fb_w = fdt_nd_w;
        fdt_fb_h = fdt_nd_h;
        fdt_fb_stride = fdt_nd_stride;
        if (!fdt_fb_stride)
            fdt_fb_stride = fdt_fb_w * 4;
        fdt_fb_32bpp = TRUE;
    }
}

U0 FdtReserve(I64 start, I64 size)
{
    if (size > 0 && fdt_nres < FDT_RES) {
        fdt_res[fdt_nres].start = start;
        fdt_res[fdt_nres].end = start + size;
        fdt_nres++;
    }
}

Bool FdtInit(U8 *dt)
{
    U8 *p, *str, *data, *r;
    I64 tok, len, nameoff, depth = -1, kind[16], k, i, start, size;
    if (Fdt32(dt) != 0xD00DFEED)
        return FALSE;
    fdt_size = Fdt32(dt + 4);
    if (fdt_size < 40 || fdt_size > (2 << 20))
        return FALSE;
    p = dt + Fdt32(dt + 8);
    str = dt + Fdt32(dt + 12);
    r = dt + Fdt32(dt + 16);
    while ((start = Fdt64(r)) | (size = Fdt64(r + 8))) {
        FdtReserve(start, size);
        r += 16;
    }
    while (p < dt + fdt_size) {
        tok = Fdt32(p);
        p += 4;
        if (tok == 1) {
            depth++;
            if (depth >= 16)
                return FALSE;
            k = 0;
            if (depth == 1) {
                if (FdtPrefix(p, "memory@")) k = 1;
                if (FdtPrefix(p, "cpus")) k = 2;
                if (FdtPrefix(p, "soc")) k = 3;
                if (FdtPrefix(p, "reserved-memory")) k = 4;
                if (FdtPrefix(p, "chosen")) k = 10;
            } else if (depth == 2) {
                if (kind[1] == 2 && FdtPrefix(p, "cpu@")) {
                    k = 5;
                    if (fdt_ncpu < FDT_CPUS) fdt_ncpu++;
                }
                if (kind[1] == 3 && FdtPrefix(p, "serial@")) k = 6;
                if (kind[1] == 3 && FdtPrefix(p, "interrupt-controller@")) k = 7;
                if (kind[1] == 3 && FdtPrefix(p, "finisher@")) k = 8;
                if (kind[1] == 4) k = 9;
            }
            kind[depth] = k;
            if (depth == 2 && (kind[1] == 3 || kind[1] == 10))
                FdtNodeStart;
            while (*p) p++;
            p = ((p + 4)(I64) & ~3)(U8 *);
        } else if (tok == 2) {
            if (depth == 2 && (kind[1] == 3 || kind[1] == 10))
                FdtNodeDone;
            depth--;
        } else if (tok == 3) {
            len = Fdt32(p);
            nameoff = Fdt32(p + 4);
            data = p + 8;
            p = ((data + len + 3)(I64) & ~3)(U8 *);
            if (kind[depth] == 10 && FdtEqual(str + nameoff, "bootargs"))
                fdt_test = FdtPrefix(data, "coolcom.test=1");
            if (kind[depth] == 10 && FdtEqual(str + nameoff, "coolcom,unix-time") && len == 8)
                fdt_unix_time = Fdt64(data);
            if (kind[depth] == 10 && FdtEqual(str + nameoff, "coolcom,utc-offset") && len == 4)
                fdt_utc_offset = Fdt32(data)(I32);
            if (depth == 0 && FdtEqual(str + nameoff, "compatible"))
                fdt_vm = FdtPrefix(data, "coolcom,coolvm");
            if (FdtEqual(str + nameoff, "reg") && len >= 16) {
                start = Fdt64(data);
                size = Fdt64(data + 8);
                if (kind[depth] == 1) {
                    for (i = 0; i + 16 <= len && fdt_nmem < FDT_MEMS; i += 16) {
                        start = Fdt64(data + i);
                        size = Fdt64(data + i + 8);
                        fdt_mem[fdt_nmem].start = start;
                        fdt_mem[fdt_nmem].end = start + size;
                        fdt_nmem++;
                    }
                }
                if (kind[depth] == 6) fdt_uart = start;
                if (kind[depth] == 7) fdt_aic = start;
                if (kind[depth] == 8) fdt_finisher = start;
                if (kind[depth] == 9) FdtReserve(start, size);
            }
            if (depth == 2 && (kind[1] == 3 || kind[1] == 10)) {
                if (FdtEqual(str + nameoff, "reg") && len >= 16) {
                    fdt_nd.base = Fdt64(data);
                    fdt_nd.size = Fdt64(data + 8);
                } else if (FdtEqual(str + nameoff, "interrupts") && len >= 8)
                    fdt_nd.irq = Fdt32(data + 4);
                else if (FdtEqual(str + nameoff, "compatible")) {
                    if (FdtCompat(data, len, "coolcom,coolvm-input"))
                        fdt_nd_kind = 1;
                    else if (FdtCompat(data, len, "virtio,mmio"))
                        fdt_nd_kind = 2;
                    else if (FdtCompat(data, len, "simple-framebuffer"))
                        fdt_nd_kind = 3;
                } else if (FdtEqual(str + nameoff, "width") && len >= 4)
                    fdt_nd_w = Fdt32(data);
                else if (FdtEqual(str + nameoff, "height") && len >= 4)
                    fdt_nd_h = Fdt32(data);
                else if (FdtEqual(str + nameoff, "stride") && len >= 4)
                    fdt_nd_stride = Fdt32(data);
                else if (FdtEqual(str + nameoff, "format"))
                    fdt_nd_32bpp = FdtEqual(data, "x8r8g8b8") || FdtEqual(data, "a8r8g8b8");
            }
            if (kind[depth] == 5) {
                if (FdtEqual(str + nameoff, "reg") && len >= 8 && fdt_ncpu)
                    fdt_cpu[fdt_ncpu - 1].mpidr = Fdt64(data);
                if (FdtEqual(str + nameoff, "cpu-release-addr") && len >= 8 && fdt_ncpu)
                    fdt_cpu[fdt_ncpu - 1].release = Fdt64(data);
            }
        } else if (tok == 9) {
            return fdt_nmem > 0 && fdt_ncpu > 0;
        } else if (tok != 4) {
            return FALSE;
        }
    }
    return FALSE;
}

// Pick the largest contiguous unreserved region after the Image and DTB.
U0 FdtHeap(U8 *image_end, U8 *dt, U8 **heap_start, U8 **heap_end)
{
    I64 i, j, s, e, next, best = 0, bestend = 0, floor;
    floor = image_end(I64);
    if (dt(I64) + fdt_size > floor)
        floor = dt(I64) + fdt_size;
    floor = (floor + 16383) & ~16383;
    for (i = 0; i < fdt_nmem; i++) {
        s = fdt_mem[i].start;
        if (s < floor) s = floor;
        e = fdt_mem[i].end;
        while (s < e) {
            next = e;
            for (j = 0; j < fdt_nres; j++) {
                if (fdt_res[j].start <= s && fdt_res[j].end > s) {
                    s = (fdt_res[j].end + 16383) & ~16383;
                    next = s;
                    break;
                }
                if (fdt_res[j].start > s && fdt_res[j].start < next)
                    next = fdt_res[j].start;
            }
            if (next == s)
                goto heap_next;
            if (next - s > bestend - best) {
                best = s;
                bestend = next;
            }
            s = (next + 16383) & ~16383;
            for (j = 0; j < fdt_nres; j++)
                if (fdt_res[j].start <= next && fdt_res[j].end > next)
                    s = (fdt_res[j].end + 16383) & ~16383;
heap_next:
        }
    }
    *heap_start = best;
    *heap_end = bestend;
}
