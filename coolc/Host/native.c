// Native Apple Silicon loader for Aiwnios/TempleOS BIN modules.
// Patch table format follows Aiwnios c/loader.c (nrootconauto, BSD-3),
// commit e155e87, and tools/binlink.py in this repository.
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
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
    for (size_t i = 0; i < m->import_count; i++) {
        Import *imp = &m->imports[i];
        uintptr_t value = find_symbol(m, imp->name);
        if (!value) {
            fprintf(stderr, "coolc-host: unresolved import %s\n", imp->name);
            exit(1);
        }
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
    if (fread(memory, 1, (size_t)length, input) != (size_t)length)
        fail("could not read complete BIN file");
    fclose(input);
    uint64_t patch = u64(memory + 16);
    if (patch < 32 || patch >= (uint64_t)length)
        fail("invalid BIN patch table offset");
    Module module = {.map = memory, .code = memory + 32,
                     .file_size = (size_t)length, .code_size = (size_t)patch - 32,
                     .map_size = mapped};
    parse_patches(&module, (size_t)patch);
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
    if (argc == 4 && !strcmp(argv[1], "--probe")) {
        Module module = load_bin(argv[2]);
        run_initializers(&module);
        uintptr_t address = find_symbol(&module, argv[3]);
        if (!address)
            fail("probe symbol is not exported");
        int64_t (*probe)(void) = (int64_t (*)(void))address;
        printf("%" PRId64 "\n", probe());
        return 0;
    }
    if (argc != 3)
        fail("usage: coolc <entry.HC> <out.BIN>");
    Module module = load_bin("build/coolc-compiler.BIN");
    run_initializers(&module);
    uintptr_t address = find_symbol(&module, "CoolCMain");
    if (!address)
        fail("compiler BIN does not export CoolCMain");
    int64_t (*compile)(const char *, const char *) =
        (int64_t (*)(const char *, const char *))address;
    return (int)compile(argv[1], argv[2]);
}
