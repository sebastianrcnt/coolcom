/* Tiny flattened-device-tree (DTB v17) builder. No libfdt / dtc needed at runtime.
 * Spec: devicetree.org "Devicetree Specification" chapter 5. */
#include "coolvm.h"

#define FDT_MAGIC 0xd00dfeedu
#define FDT_BEGIN_NODE 1
#define FDT_END_NODE 2
#define FDT_PROP 3
#define FDT_END 9

struct fdt {
    uint8_t *st;
    size_t st_len, st_cap;
    char *strs;
    size_t strs_len, strs_cap;
    uint64_t rsv[16][2];
    int nrsv;
    int depth;
};

static void st_put(fdt_t *f, const void *p, size_t n)
{
    if (f->st_len + n > f->st_cap) {
        f->st_cap = (f->st_cap ? f->st_cap * 2 : 4096);
        while (f->st_cap < f->st_len + n)
            f->st_cap *= 2;
        f->st = realloc(f->st, f->st_cap);
    }
    memcpy(f->st + f->st_len, p, n);
    f->st_len += n;
}

static void st_pad(fdt_t *f)
{
    static const uint8_t z[4] = {0};
    if (f->st_len & 3)
        st_put(f, z, 4 - (f->st_len & 3));
}

static void st_u32(fdt_t *f, uint32_t v)
{
    uint32_t be = __builtin_bswap32(v);
    st_put(f, &be, 4);
}

fdt_t *fdt_new(void)
{
    return calloc(1, sizeof(fdt_t));
}

void fdt_begin(fdt_t *f, const char *name)
{
    st_u32(f, FDT_BEGIN_NODE);
    st_put(f, name, strlen(name) + 1);
    st_pad(f);
    f->depth++;
}

void fdt_end(fdt_t *f)
{
    st_u32(f, FDT_END_NODE);
    f->depth--;
}

static uint32_t str_off(fdt_t *f, const char *s)
{
    size_t n = strlen(s) + 1;
    for (size_t i = 0; i + n <= f->strs_len; i += strlen(f->strs + i) + 1)
        if (!strcmp(f->strs + i, s))
            return (uint32_t)i;
    if (f->strs_len + n > f->strs_cap) {
        f->strs_cap = f->strs_cap ? f->strs_cap * 2 : 1024;
        while (f->strs_cap < f->strs_len + n)
            f->strs_cap *= 2;
        f->strs = realloc(f->strs, f->strs_cap);
    }
    memcpy(f->strs + f->strs_len, s, n);
    f->strs_len += n;
    return (uint32_t)(f->strs_len - n);
}

void fdt_prop(fdt_t *f, const char *name, const void *data, uint32_t len)
{
    st_u32(f, FDT_PROP);
    st_u32(f, len);
    st_u32(f, str_off(f, name));
    if (len)
        st_put(f, data, len);
    st_pad(f);
}

void fdt_prop_empty(fdt_t *f, const char *name)
{
    fdt_prop(f, name, NULL, 0);
}

void fdt_prop_u32(fdt_t *f, const char *name, uint32_t v)
{
    uint32_t be = __builtin_bswap32(v);
    fdt_prop(f, name, &be, 4);
}

void fdt_prop_u64(fdt_t *f, const char *name, uint64_t v)
{
    uint64_t be = __builtin_bswap64(v);
    fdt_prop(f, name, &be, 8);
}

void fdt_prop_str(fdt_t *f, const char *name, const char *s)
{
    fdt_prop(f, name, s, (uint32_t)strlen(s) + 1);
}

void fdt_prop_strs(fdt_t *f, const char *name, const char *const *strs, int n)
{
    char buf[512];
    size_t len = 0;
    for (int i = 0; i < n; i++) {
        size_t l = strlen(strs[i]) + 1;
        if (len + l > sizeof(buf)) {
            fprintf(stderr, "fdt: string list too long\n");
            abort();
        }
        memcpy(buf + len, strs[i], l);
        len += l;
    }
    fdt_prop(f, name, buf, (uint32_t)len);
}

void fdt_prop_cells(fdt_t *f, const char *name, const uint32_t *cells, int n)
{
    uint32_t buf[64];
    if (n > 64)
        abort();
    for (int i = 0; i < n; i++)
        buf[i] = __builtin_bswap32(cells[i]);
    fdt_prop(f, name, buf, (uint32_t)n * 4);
}

void fdt_add_memrsv(fdt_t *f, uint64_t addr, uint64_t size)
{
    if (f->nrsv >= 16)
        abort();
    f->rsv[f->nrsv][0] = addr;
    f->rsv[f->nrsv][1] = size;
    f->nrsv++;
}

uint8_t *fdt_finish(fdt_t *f, uint32_t *size)
{
    st_u32(f, FDT_END);
    uint32_t off_rsv = 40;
    uint32_t rsv_len = (uint32_t)(f->nrsv + 1) * 16;
    uint32_t off_st = off_rsv + rsv_len;
    uint32_t off_strs = off_st + (uint32_t)f->st_len;
    uint32_t total = off_strs + (uint32_t)f->strs_len;
    total = (total + 7) & ~7u;
    uint8_t *out = calloc(1, total);
    uint32_t hdr[10] = {FDT_MAGIC, total, off_st, off_strs, off_rsv, 17, 16,
                        0 /* boot_cpuid_phys */, (uint32_t)f->strs_len, (uint32_t)f->st_len};
    for (int i = 0; i < 10; i++) {
        uint32_t be = __builtin_bswap32(hdr[i]);
        memcpy(out + i * 4, &be, 4);
    }
    for (int i = 0; i < f->nrsv; i++) {
        uint64_t a = __builtin_bswap64(f->rsv[i][0]), s = __builtin_bswap64(f->rsv[i][1]);
        memcpy(out + off_rsv + i * 16, &a, 8);
        memcpy(out + off_rsv + i * 16 + 8, &s, 8);
    }
    memcpy(out + off_st, f->st, f->st_len);
    memcpy(out + off_strs, f->strs, f->strs_len);
    *size = total;
    free(f->st);
    free(f->strs);
    free(f);
    return out;
}
