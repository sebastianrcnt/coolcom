// Native Apple Silicon loader for Aiwnios/TempleOS BIN modules.
// Patch table format follows Aiwnios c/loader.c (nrootconauto, BSD-3),
// commit e155e87, and tools/binlink.py in this repository.
#include <errno.h>
#include <ctype.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>

enum {
    IET_REL_I8 = 4, IET_IMM_U8, IET_REL_I16, IET_IMM_U16,
    IET_REL_I32, IET_IMM_U32, IET_REL_I64, IET_IMM_I64,
    IET_REL32_EXPORT = 16, IET_IMM32_EXPORT, IET_REL64_EXPORT,
    IET_IMM64_EXPORT, IET_ABS_ADDR, IET_CODE_HEAP,
    IET_ZEROED_CODE_HEAP, IET_DATA_HEAP, IET_ZEROED_DATA_HEAP,
    IET_MAIN
};

typedef struct {
    char *name;
    uintptr_t value;
} Symbol;

typedef struct {
    uint8_t type;
    uint32_t at;
    int32_t addend;
    const char *name;
} Import;

typedef struct {
    uint8_t *map;
    uint8_t *code;
    size_t file_size;
    size_t code_size;
    size_t map_size;
    Symbol *symbols;
    size_t symbol_count;
    Import *imports;
    size_t import_count;
    uint32_t *mains;
    size_t main_count;
} Module;

static void fail(const char *message);
static void add_symbol(Module *m, const char *name, uintptr_t value);
static void *NativeJitAlloc(int64_t size);
static void NativeJitCommit(void *code, const void *scratch, int64_t size);
extern int64_t AIWNIOS_SetJmp(int64_t *context);
extern void AIWNIOS_LongJmp(int64_t *context);
static Module *active_module;

static void host_unimplemented(uint64_t id) {
    fprintf(stderr, "coolc-host: native runtime import %s was called\n",
            active_module->imports[id].name);
    exit(1);
}
static void host_exit(int64_t status) { exit((int)status); }
static int64_t host_float_to_int(double value) { return (int64_t)value; }
static double host_int_to_float(int64_t value) { return (double)value; }

// Standalone program services. Compiler invocations do not expose their argv.
static int native_argc;
static char **native_argv;
static int64_t host_arg_count(void) { return native_argc; }
static const char *host_arg(int64_t index) {
    if (index < 0 || index >= native_argc)
        return NULL;
    return native_argv[index];
}
static int64_t host_get_char(void) {
    fflush(stdout);  // a prompt printed before the read must show first
    return getchar();  // the next byte of standard input, or -1 at the end
}
static void host_err_puts(const char *text) {
    fputs(text, stderr);
    fflush(stderr);
}

static uintptr_t import_trap(size_t id) {
    if (id > UINT16_MAX)
        fail("too many native imports for diagnostic trap");
    uint8_t *code = NativeJitAlloc(24);
    uint32_t insn[3] = {
        UINT32_C(0xd2800000) | ((uint32_t)id << 5), // movz x0, #id
        UINT32_C(0x58000051),                       // ldr x17, +8
        UINT32_C(0xd61f0220)                        // br x17
    };
    memcpy(code, insn, sizeof(insn));
    uintptr_t target = (uintptr_t)host_unimplemented;
    memcpy(code + sizeof(insn), &target, sizeof(target));
    __builtin___clear_cache((char *)code, (char *)code + 20);
    return (uintptr_t)code;
}

typedef struct { uint64_t size, magic; } Allocation;
static const uint64_t allocation_magic = UINT64_C(0xc001c0de5eed1234);
static void *native_task;
static void *native_tls[2];

static void *host_alloc(int64_t size, void *task) {
    (void)task;
    if (size < 0 || (uint64_t)size > SIZE_MAX - sizeof(Allocation))
        fail("invalid HolyC allocation size");
    Allocation *p = malloc(sizeof(*p) + (size_t)size + 1);
    if (!p)
        fail("out of memory in HolyC allocation");
    p->size = (uint64_t)size;
    p->magic = allocation_magic;
    return p + 1;
}

static void *host_calloc(int64_t size, void *task) {
    void *p = host_alloc(size, task);
    memset(p, 0, (size_t)size);
    return p;
}

static void host_free(void *p) {
    if (!p)
        return;
    Allocation *a = (Allocation *)p - 1;
    // AOT data heaps and executable JIT mappings do not carry our malloc
    // header. Their lifetime is the compiler process; Free leaves them mapped.
    if (a->magic != allocation_magic)
        return;
    a->magic = 0;
    free(a);
}

static int64_t host_msize(const void *p) {
    if (!p)
        return 0;
    const Allocation *a = (const Allocation *)p - 1;
    return a->magic == allocation_magic ? (int64_t)a->size : 0;
}

static char *host_strnew(const char *s, void *task) {
    if (!s)
        s = "";
    size_t n = strlen(s) + 1;
    char *copy = host_alloc((int64_t)n, task);
    memcpy(copy, s, n);
    return copy;
}

static void *host_alloc_ident(const void *p, void *task) {
    int64_t n = host_msize(p);
    void *copy = host_alloc(n, task);
    if (n)
        memcpy(copy, p, (size_t)n);
    return copy;
}

static void *host_fs(void) { return native_task; }
static void host_set_fs(void *task) {
    native_task = task;
    native_tls[0] = task;
}
static void *host_fs_offset(void) { return NULL; }

static int64_t host_bt(const uint8_t *bits, int64_t bit) {
    return (bits[(uint64_t)bit >> 3] >> (bit & 7)) & 1;
}
static int64_t host_bts(uint8_t *bits, int64_t bit) {
    uint8_t *p = bits + ((uint64_t)bit >> 3);
    uint8_t mask = (uint8_t)(1u << (bit & 7));
    int64_t old = !!(*p & mask);
    *p |= mask;
    return old;
}
static int64_t host_btr(uint8_t *bits, int64_t bit) {
    uint8_t *p = bits + ((uint64_t)bit >> 3);
    uint8_t mask = (uint8_t)(1u << (bit & 7));
    int64_t old = !!(*p & mask);
    *p &= (uint8_t)~mask;
    return old;
}
static int64_t host_bsf(uint64_t bits) { return bits ? __builtin_ctzll(bits) : -1; }
static int64_t host_bsr(uint64_t bits) { return bits ? 63 - __builtin_clzll(bits) : -1; }
static void *host_memcpy(void *dst, const void *src, int64_t n) {
    return memcpy(dst, src, (size_t)n);
}
static void *host_memset(void *dst, int64_t value, int64_t n) {
    return memset(dst, (int)value, (size_t)n);
}
static void *host_memset_i64(uint64_t *dst, uint64_t value, int64_t n) {
    for (int64_t i = 0; i < n; i++) dst[i] = value;
    return dst;
}
static int64_t host_memcmp(const void *a, const void *b, int64_t n) {
    return memcmp(a, b, (size_t)n);
}
static int64_t host_stricmp(const char *a, const char *b) {
    while (*a && *b) {
        int delta = tolower((unsigned char)*a) - tolower((unsigned char)*b);
        if (delta) return delta;
        a++; b++;
    }
    return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}
static uintptr_t host_caller(int64_t depth) {
    uintptr_t frame;
    __asm__ volatile("mov %0, x29" : "=r"(frame));
    if (depth < 0 || depth > 32) return 0;
    for (int64_t i = 0; i <= depth; i++) {
        if (!frame || (frame & 15)) return 0;
        frame = *(uintptr_t *)frame;
    }
    return frame ? ((uintptr_t *)frame)[1] : 0;
}
static int64_t host_true(void) { return 1; }
static int64_t host_zero(void) { return 0; }
static void host_str_print_fun_seg(char *out, uintptr_t address,
                                   int64_t field_len, int64_t flags) {
    (void)field_len;
    (void)flags;
    snprintf(out, 32, "0x%" PRIxPTR, address);
}
static void host_puts(const char *message) {
    fputs(message ? message : "", stdout);
    fflush(stdout);
}
static void host_swap_i64(int64_t *a, int64_t *b) {
    int64_t tmp = *a;
    *a = *b;
    *b = tmp;
}
static double host_pow10(double exponent) { return pow(10.0, exponent); }
static void *host_write_protect_memcpy(void *dst, const void *src, int64_t size) {
    pthread_jit_write_protect_np(0);
    memcpy(dst, src, (size_t)size);
    __builtin___clear_cache(dst, (char *)dst + size);
    pthread_jit_write_protect_np(1);
    return dst;
}
static const char *extension_dot(const char *path) {
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return strrchr(base, '.');
}
static char *host_ext_dft(const char *path, const char *extension) {
    if (extension_dot(path)) return host_strnew(path, NULL);
    size_t n = strlen(path), e = strlen(extension);
    char *result = host_alloc((int64_t)(n + e + 2), NULL);
    memcpy(result, path, n);
    result[n] = '.';
    memcpy(result + n + 1, extension, e + 1);
    return result;
}
static char *host_ext_chg(const char *path, const char *extension) {
    const char *dot = extension_dot(path);
    size_t n = dot ? (size_t)(dot - path) : strlen(path);
    size_t e = strlen(extension);
    char *result = host_alloc((int64_t)(n + e + 2), NULL);
    memcpy(result, path, n);
    result[n] = '.';
    memcpy(result + n + 1, extension, e + 1);
    return result;
}
static char *host_file_name_abs(const char *path, int64_t flags) {
    (void)flags;
    if (*path == '/') return host_strnew(path, NULL);
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) fail("getcwd failed");
    size_t n = strlen(cwd), p = strlen(path);
    char *result = host_alloc((int64_t)(n + p + 2), NULL);
    memcpy(result, cwd, n);
    result[n] = '/';
    memcpy(result + n + 1, path, p + 1);
    return result;
}

static char *absolute_argument(const char *path) {
    return host_file_name_abs(path, 0);
}
static char *host_file_read(const char *path, int64_t *size, void *attrs) {
    (void)attrs;
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END)) fail("file seek failed");
    long n = ftell(f);
    if (n < 0) fail("file size failed");
    rewind(f);
    char *data = host_alloc((int64_t)n + 1, NULL);
    if (fread(data, 1, (size_t)n, f) != (size_t)n)
        fail("file read failed");
    data[n] = 0;
    fclose(f);
    if (size) *size = n;
    return data;
}
static int64_t host_file_write(const char *path, const void *data, int64_t size) {
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    size_t n = fwrite(data, 1, (size_t)size, f);
    fclose(f);
    return n == (size_t)size;
}

// 0 if the path does not exist, 1 for a file (or anything else), 2 for a directory.
static int64_t host_file_stat(const char *path) {
    struct stat st;
    if (stat(path, &st)) return 0;
    return S_ISDIR(st.st_mode) ? 2 : 1;
}

static int64_t host_io_error(void) {
    switch(errno) {case ENOENT: return -10; case EEXIST: return -11;
    case EACCES: case EPERM: return -13; case ENOSPC: return -14;
    case ENOTEMPTY: return -15; default: return -1;}
}
static int64_t host_file_delete(const char *path) {return remove(path) ? host_io_error() : 0;}
static int64_t host_file_mkdir(const char *path) {return mkdir(path, 0755) ? host_io_error() : 0;}

// Snapshot layout matches WoEntry; every allocation uses the HolyC heap header.
typedef struct HostDirEntry {struct HostDirEntry *next; char *name; int64_t size, is_dir, modified;} HostDirEntry;
static HostDirEntry *host_dir_list(const char *path, int64_t *error) {
    DIR *dir = opendir(path);
    *error = dir ? 0 : host_io_error();
    if (!dir) return NULL;
    HostDirEntry *head = NULL;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        char full[PATH_MAX];
        int len = snprintf(full, sizeof(full), "%s/%s", path, entry->d_name);
        struct stat st;
        if (len < 0 || len >= (int)sizeof(full)) {*error = -12; break;}
        if (lstat(full, &st)) {*error = host_io_error(); break;}
        HostDirEntry *e = host_calloc(sizeof(*e), NULL);
        e->name = host_strnew(entry->d_name, NULL);
        e->size = st.st_size; e->is_dir = S_ISDIR(st.st_mode); e->modified = st.st_mtime;
        e->next = head; head = e;
    }
    closedir(dir);
    return head;
}

#include "warm_net.h"
#include "warm_task.h"
#include "warm_file.h"

static void register_host_symbols(Module *m) {
#define HOST(name, fn) add_symbol(m, name, (uintptr_t)(fn))
    HOST("NativeJitAlloc", NativeJitAlloc);
    HOST("NativeJitCommit", NativeJitCommit);
    HOST("MAlloc", host_alloc);
    HOST("CAlloc", host_calloc);
    HOST("Free", host_free);
    HOST("MSize", host_msize);
    HOST("StrNew", host_strnew);
    HOST("MAllocIdent", host_alloc_ident);
    HOST("Fs", host_fs);
    HOST("SetFs", host_set_fs);
    HOST("__Fs", host_fs_offset);
    HOST("Bt", host_bt);
    HOST("Bts", host_bts);
    HOST("Btr", host_btr);
    HOST("LBts", host_bts);
    HOST("LBtr", host_btr);
    HOST("Bsf", host_bsf);
    HOST("Bsr", host_bsr);
    HOST("MemCpy", host_memcpy);
    HOST("MemSet", host_memset);
    HOST("MemSetI64", host_memset_i64);
    HOST("MemCmp", host_memcmp);
    HOST("StrLen", strlen);
    HOST("StrCmp", strcmp);
    HOST("StrNCmp", strncmp);
    HOST("StrCpy", strcpy);
    HOST("StrICmp", host_stricmp);
    HOST("Caller", host_caller);
    HOST("IsCmdLineMode", host_true);
    HOST("StrPrintFunSeg", host_str_print_fun_seg);
    HOST("PutS", host_puts);
    HOST("Print", printf);  // Standalone native HolyC programs use C printf.
    HOST("SwapI64", host_swap_i64);
    HOST("Pow10", host_pow10);
    HOST("WriteProtectMemCpy", host_write_protect_memcpy);
    HOST("NativeExit", host_exit);
    HOST("NativeErrPutS", host_err_puts);
    HOST("NativeArgCount", host_arg_count);
    HOST("NativeArg", host_arg);
    HOST("NativeGetChar", host_get_char);
    HOST("AIWNIOS_SetJmp", AIWNIOS_SetJmp);
    HOST("AIWNIOS_LongJmp", AIWNIOS_LongJmp);
    HOST("ExtDft", host_ext_dft);
    HOST("ExtChg", host_ext_chg);
    HOST("FileNameAbs", host_file_name_abs);
    HOST("FileRead", host_file_read);
    HOST("FileWrite", host_file_write);
    HOST("NativeFileStat", host_file_stat);
    HOST("NativeSafeStat", warm_file_stat);
    HOST("NativeSafeRead", warm_file_read);
    HOST("NativeSafeWrite", warm_file_write);
    HOST("NativeSafeDelete", warm_file_delete);
    HOST("NativeSafeMkdir", warm_file_mkdir);
    HOST("NativeSafeList", warm_file_list);
    HOST("NativeDirList", host_dir_list);
    HOST("NativeNetResolve", warm_net_resolve);
    HOST("NativeNetConnect", warm_net_connect);
    HOST("NativeNetListen", warm_net_listen);
    HOST("NativeNetAccept", warm_net_accept);
    HOST("NativeNetSend", warm_net_send);
    HOST("NativeNetReceive", warm_net_receive);
    HOST("NativeNetUdpOpen", warm_net_udp_open);
    HOST("NativeNetUdpSend", warm_net_udp_send);
    HOST("NativeNetUdpReceive", warm_net_udp_receive);
    HOST("NativeNetSource", warm_net_source);
    HOST("NativeNetSourcePort", warm_net_source_port);
    HOST("NativeNetPort", warm_net_port);
    HOST("NativeNetClose", warm_net_close);
    HOST("NativeTaskSpawn", warm_task_spawn);
    HOST("NativeTaskWait", warm_task_wait);
    HOST("NativeTaskResult", warm_task_result);
    HOST("NativeTaskMessage", warm_task_message);
    HOST("NativeTaskRelease", warm_task_release);
    HOST("NativeTaskDetach", warm_task_detach);
    HOST("NativeTaskAbort", warm_task_abort);
    HOST("NativeUnixNow", warm_unix_now);
    HOST("NativeMonotonicMs", warm_monotonic_ms);
    HOST("NativeSleep", warm_sleep);
    HOST("NativeYield", warm_yield);


    HOST("NativeFileDelete", host_file_delete);
    HOST("NativeFileMkdir", host_file_mkdir);
    HOST("C2HFloor", floor);
    HOST("C2HCeil", ceil);
    HOST("C2HSqrt", sqrt);
    HOST("C2HFabs", fabs);
    HOST("C2HFmod", fmod);
    HOST("C2HCos", cos);
    HOST("C2HAcos", acos);
    HOST("C2HPow", pow);
    HOST("C2HFloatToInt", host_float_to_int);
    HOST("C2HIntToFloat", host_int_to_float);
    HOST("FlushMsgs", host_zero);  // compiler errors are printed as they happen
#undef HOST
}

// Called by the HolyC backend when it finishes a JIT function.
static void *NativeJitAlloc(int64_t size) {
    if (size <= 0)
        size = 1;
    void *code = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE | PROT_EXEC,
                      MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (code == MAP_FAILED) {
        perror("mmap JIT function");
        exit(1);
    }
    return code;
}

static void NativeJitCommit(void *code, const void *scratch, int64_t size) {
    if (size < 0)
        fail("negative JIT code length");
    pthread_jit_write_protect_np(0);
    memcpy(code, scratch, (size_t)size);
    __builtin___clear_cache(code, (char *)code + size);
    pthread_jit_write_protect_np(1);
}

static void fail(const char *message) {
    fprintf(stderr, "coolc-host: %s\n", message);
    exit(1);
}

static void require_range(const Module *m, size_t at, size_t len) {
    if (at > m->file_size || len > m->file_size - at)
        fail("truncated or invalid BIN patch table");
}

static uint32_t u32(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static uint64_t u64(const uint8_t *p) {
    uint64_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static void add_symbol(Module *m, const char *name, uintptr_t value) {
    Symbol *next = realloc(m->symbols, (m->symbol_count + 1) * sizeof(*next));
    if (!next)
        fail("out of memory recording symbols");
    m->symbols = next;
    m->symbols[m->symbol_count].name = strdup(name);
    m->symbols[m->symbol_count].value = value;
    m->symbol_count++;
}

static uintptr_t find_symbol(const Module *m, const char *name) {
    for (size_t i = m->symbol_count; i; i--)
        if (!strcmp(m->symbols[i - 1].name, name))
            return m->symbols[i - 1].value;
    return 0;
}

static void add_import(Module *m, uint8_t type, uint32_t at,
                       int32_t addend, const char *name) {
    Import *next = realloc(m->imports, (m->import_count + 1) * sizeof(*next));
    if (!next)
        fail("out of memory recording imports");
    m->imports = next;
    m->imports[m->import_count++] = (Import){type, at, addend, name};
}

static void add_main(Module *m, uint32_t at) {
    uint32_t *next = realloc(m->mains, (m->main_count + 1) * sizeof(*next));
    if (!next)
        fail("out of memory recording initializers");
    m->mains = next;
    m->mains[m->main_count++] = at;
}

static void write_patch(Module *m, uint32_t at, uint64_t value, size_t width) {
    if (at > m->code_size || width > m->code_size - at)
        fail("patch offset lies outside code");
    memcpy(m->code + at, &value, width);
}

static void parse_patches(Module *m, size_t patch_at) {
    size_t p = patch_at;
    const char *last_import = NULL;
    while (1) {
        require_range(m, p, 1);
        uint8_t type = m->map[p++];
        if (!type)
            break;
        require_range(m, p, 4);
        uint32_t index = u32(m->map + p);
        p += 4;
        int32_t addend = 0;
        if (type >= 2 && type <= 12) {
            require_range(m, p, 4);
            addend = (int32_t)u32(m->map + p);
            p += 4;
        }
        const char *name = (const char *)m->map + p;
        const uint8_t *end = memchr(m->map + p, 0, m->file_size - p);
        if (!end)
            fail("unterminated BIN symbol name");
        p = (size_t)(end - m->map) + 1;

        if (type >= IET_REL_I8 && type <= IET_IMM_I64) {
            if (*name)
                last_import = name;
            if (!last_import)
                fail("import continuation has no symbol");
            add_import(m, type, index, addend, last_import);
        } else if (type >= IET_REL32_EXPORT && type <= IET_IMM64_EXPORT) {
            uintptr_t value = index;
            if (type == IET_REL32_EXPORT || type == IET_REL64_EXPORT)
                value += (uintptr_t)m->code;
            add_symbol(m, name, value);
        } else if (type == IET_ABS_ADDR) {
            for (uint32_t i = 0; i < index; i++) {
                require_range(m, p, 4);
                uint32_t at = u32(m->map + p);
                p += 4;
                if (at > m->code_size || 8 > m->code_size - at)
                    fail("absolute address patch lies outside code");
                write_patch(m, at, u64(m->code + at) + (uintptr_t)m->code, 8);
            }
        } else if (type == IET_CODE_HEAP || type == IET_ZEROED_CODE_HEAP) {
            require_range(m, p, 4);
            uint32_t size = u32(m->map + p);
            p += 4;
            uint8_t *heap = calloc(1, (size_t)size + 1);
            if (!heap)
                fail("out of memory allocating BIN code heap");
            if (*name)
                add_symbol(m, name, (uintptr_t)heap);
            for (uint32_t i = 0; i < index; i++) {
                require_range(m, p, 8);
                uint32_t at = u32(m->map + p);
                int32_t offset = (int32_t)u32(m->map + p + 4);
                p += 8;
                write_patch(m, at, (uintptr_t)heap + offset, 8);
            }
        } else if (type == IET_DATA_HEAP || type == IET_ZEROED_DATA_HEAP) {
            require_range(m, p, 8);
            uint64_t size = u64(m->map + p);
            p += 8;
            if (size > SIZE_MAX - 1)
                fail("invalid data heap size");
            require_range(m, p, (size_t)size);
            uint8_t *heap = calloc(1, (size_t)size + 1);
            if (!heap)
                fail("out of memory allocating BIN data");
            if (type == IET_DATA_HEAP)
                memcpy(heap, m->map + p, (size_t)size);
            p += (size_t)size;
            if (*name)
                add_symbol(m, name, (uintptr_t)heap);
            for (uint32_t i = 0; i < index; i++) {
                require_range(m, p, 8);
                uint32_t at = u32(m->map + p);
                int32_t offset = (int32_t)u32(m->map + p + 4);
                p += 8;
                write_patch(m, at, (uintptr_t)heap + offset, 8);
            }
        } else if (type == IET_MAIN) {
            if (index >= m->code_size)
                fail("initializer offset lies outside code");
            add_main(m, index);
        } else {
            fprintf(stderr, "coolc-host: unsupported BIN patch type %u\n", type);
            exit(1);
        }
    }
}

static void resolve_imports(Module *m) {
    active_module = m;
    for (size_t i = 0; i < m->import_count; i++) {
        Import *imp = &m->imports[i];
        uintptr_t value = find_symbol(m, imp->name);
        if (!value)
            value = import_trap(i);
        value += imp->addend;
        size_t width = 1u << ((imp->type - IET_REL_I8) / 2);
        if (!(imp->type & 1)) {
            int64_t relative = (int64_t)value -
                (int64_t)(uintptr_t)(m->code + imp->at) - (int64_t)width;
            if (width < 8) {
                int64_t lo = -(1LL << (width * 8 - 1));
                int64_t hi = -lo - 1;
                if (relative < lo || relative > hi)
                    fail("relative import does not fit its patch width");
            }
            value = (uint64_t)relative;
        }
        write_patch(m, imp->at, value, width);
    }
}

static Module load_bin(const char *path) {
    FILE *input = fopen(path, "rb");
    if (!input) {
        perror(path);
        exit(1);
    }
    if (fseek(input, 0, SEEK_END) || ftell(input) < 32)
        fail("invalid BIN file size");
    long length = ftell(input);
    rewind(input);
    size_t pages = (size_t)sysconf(_SC_PAGESIZE);
    size_t mapped = ((size_t)length + pages - 1) & ~(pages - 1);
    uint8_t *memory = mmap(NULL, mapped, PROT_READ | PROT_WRITE | PROT_EXEC,
                           MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (memory == MAP_FAILED) {
        perror("mmap MAP_JIT");
        exit(1);
    }
    pthread_jit_write_protect_np(0);
    // macOS read(2) cannot DMA into a MAP_JIT page even while this thread
    // has JIT writes enabled. Read into ordinary memory and copy from user space.
    uint8_t *staging = malloc((size_t)length);
    if (!staging)
        fail("out of memory reading BIN file");
    size_t bytes_read = fread(staging, 1, (size_t)length, input);
    if (bytes_read != (size_t)length)
        fail("could not read complete BIN file");
    memcpy(memory, staging, (size_t)length);
    free(staging);
    fclose(input);
    uint64_t patch = u64(memory + 16);
    if (patch < 32 || patch >= (uint64_t)length)
        fail("invalid BIN patch table offset");
    Module module = {.map = memory, .code = memory + 32,
                     .file_size = (size_t)length, .code_size = (size_t)patch - 32,
                     .map_size = mapped};
    parse_patches(&module, (size_t)patch);
    register_host_symbols(&module);
    resolve_imports(&module);
    __builtin___clear_cache((char *)module.code, (char *)module.code + module.code_size);
    pthread_jit_write_protect_np(1);
    return module;
}

static void run_initializers(const Module *m) {
    for (size_t i = 0; i < m->main_count; i++) {
        void (*initialization)(void) = (void (*)(void))(m->code + m->mains[i]);
        initialization();
    }
}

int main(int argc, char **argv) {
    __asm__ volatile("mov x28, %0" : : "r"(native_tls));
    if (argc >= 3 && !strcmp(argv[1], "--run")) {
        native_argc = argc - 2;
        native_argv = argv + 2;
        Module module = load_bin(argv[2]);
        active_module = &module;
        run_initializers(&module);
        return 0;
    }
    if (argc == 5 && !strcmp(argv[1], "--format")) {
        Module module = load_bin(argv[2]);
        active_module = &module;
        run_initializers(&module);
        uintptr_t address = find_symbol(&module, "CoolCFmt");
        if (!address)
            fail("formatter BIN does not export CoolCFmt");
        int64_t size = 0, error = 0, warning = 0;
        char *source = host_file_read(argv[3], &size, NULL);
        if (!source)
            fail("formatter input could not be read");
        char *(*format)(char *, int64_t *, int64_t *) =
            (char *(*)(char *, int64_t *, int64_t *))address;
        char *result = format(source, &error, &warning);
        if (error)
            return 2;
        if (!host_file_write(argv[4], result, (int64_t)strlen(result)))
            fail("formatter output could not be written");
        if (warning)
            fprintf(stderr, "hcfmt: unbalanced input %s\n", argv[3]);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "--probe")) {
        Module module = load_bin(argv[2]);
        active_module = &module;
        run_initializers(&module);
        uintptr_t address = find_symbol(&module, argv[3]);
        if (!address)
            fail("probe symbol is not exported");
        int64_t (*probe)(void) = (int64_t (*)(void))address;
        printf("%" PRId64 "\n", probe());
        return 0;
    }
    // coolc [--compat] <entry.cool> <out.BIN> | coolc --vet [--compat] <entry.cool>
    int vet = 0, compat = 0;
    while (argc > 1 && argv[1][0] == '-' && argv[1][1] == '-') {
        if (!strcmp(argv[1], "--vet"))
            vet = 1;
        else if (!strcmp(argv[1], "--compat"))
            compat = 1; // the strict errors are only vet findings (.HC/.HH files always)
        else
            fail("usage: coolc [--compat] <entry.cool> <out.BIN> | coolc --vet [--compat] <entry.cool>");
        argc--;
        argv++;
    }
    if (argc != (vet ? 2 : 3))
        fail("usage: coolc [--compat] <entry.cool> <out.BIN> | coolc --vet [--compat] <entry.cool>");
    const char *compiler_image = getenv("COOLC_COMPILER_BIN");
    Module module = load_bin(compiler_image ? compiler_image : "build/coolc-compiler.BIN");
    if (getenv("COOLC_DEBUG"))
        fprintf(stderr, "coolc-host: code base %p\n", (void *)module.code);
    active_module = &module;
    run_initializers(&module);
    const char *symbol = vet ? (compat ? "CoolCVetCompat" : "CoolCVet") : (compat ? "CoolCMainCompat" : "CoolCMain");
    uintptr_t address = find_symbol(&module, symbol);
    if (!address) {
        fprintf(stderr, "coolc: compiler BIN does not export %s\n", symbol);
        exit(1);
    }
    char *entry = absolute_argument(argv[1]);
    char *output = vet ? NULL : absolute_argument(argv[2]);
    char *directory = strdup(entry);
    if (!directory)
        fail("out of memory preparing source directory");
    char *slash = strrchr(directory, '/');
    if (!slash)
        fail("entry has no parent directory");
    slash[1] = 0;
    if (chdir(directory)) {
        perror(directory);
        exit(1);
    }
    if (vet) {
        int64_t (*check)(const char *) = (int64_t (*)(const char *))address;
        check(entry);
        return 0; // findings are reported, not failed on
    }
    int64_t (*compile)(const char *, const char *) =
        (int64_t (*)(const char *, const char *))address;
    return (int)compile(entry, output);
}
