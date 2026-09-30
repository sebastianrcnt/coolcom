// HolyC x86 ABI: stack arguments, callee cleanup, F64 results in RAX.
// SysV macOS services run with their original GS base and preserved Cool
// registers. A descriptor supplies only the ABI conversion at that boundary.
typedef struct { uintptr_t fn; size_t argc; int kind; } X86HostImport;

uint64_t NativeX86Dispatch(const X86HostImport *desc, const uint64_t *args) {
    if (desc->kind == 4) {
        fprintf(stderr, "coolc-host: %s requires a threaded x86 runtime\n", (const char *)desc->fn);
        exit(1);
    }
    if (desc->kind == 3) host_unimplemented(desc->fn);
    if (desc->kind == 2) {
        // All HolyC varargs are eight-byte slots on the stack, including F64.
        // Mark SysV's GP and SSE save areas exhausted so vprintf consumes them
        // from overflow_arg_area in format-string order.
        struct { unsigned gp, fp; const void *overflow, *save; } state =
            {48, 176, args + 2, NULL};
        va_list ap;
        _Static_assert(sizeof(ap) == sizeof(state), "x86 SysV va_list layout");
        memcpy(ap, &state, sizeof(ap));
        return (uint64_t)vprintf((const char *)(uintptr_t)args[0], ap);
    }
    if (desc->kind == 1) {
        double a = 0, b = 0, result;
        memcpy(&a, args, 8);
        if (desc->argc == 2) {
            memcpy(&b, args + 1, 8);
            result = ((double (*)(double, double))desc->fn)(a, b);
        } else result = ((double (*)(double))desc->fn)(a);
        uint64_t bits;
        memcpy(&bits, &result, 8);
        return bits;
    }
    uint64_t a[6] = {0};
    if (desc->argc > 6) fail("host import has too many arguments");
    memcpy(a, args, desc->argc * 8);
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t))desc->fn)
        (a[0], a[1], a[2], a[3], a[4], a[5]);
}

static uintptr_t x86_import_thunk(X86HostImport *desc) {
    uint8_t *code = NativeJitAlloc(32);
    // movabs descriptor,%rax; call *3(%rip); ret $argc*8; .quad bridge
    const uint8_t prefix[] = {0x48,0xb8};
    memcpy(code, prefix, 2);
    uintptr_t pointer = (uintptr_t)desc;
    memcpy(code + 2, &pointer, 8);
    const uint8_t tail[] = {0xff,0x15,0x03,0,0,0,0xc2,0,0};
    memcpy(code + 10, tail, sizeof(tail));
    uint16_t pop = (uint16_t)(desc->argc * 8);
    memcpy(code + 17, &pop, 2);
    pointer = (uintptr_t)NativeX86Bridge;
    memcpy(code + 19, &pointer, 8);
    return (uintptr_t)code;
}

static uintptr_t x86_missing_import(size_t id) {
    X86HostImport *desc = malloc(sizeof(*desc));
    if (!desc) fail("out of memory creating diagnostic import");
    *desc = (X86HostImport){id, 0, 3};
    return x86_import_thunk(desc);
}

static uintptr_t x86_host_import(const char *name, uintptr_t fn) {
    static const struct { const char *name; unsigned argc; } arities[] = {
        {"NativeJitAlloc",1}, {"NativeJitCommit",3}, {"MAlloc",2}, {"CAlloc",2},
        {"Free",1}, {"MSize",1}, {"StrNew",2}, {"MAllocIdent",2}, {"Fs",0},
        {"SetFs",1}, {"__Fs",0}, {"Bt",2}, {"Bts",2}, {"Btr",2}, {"LBts",2},
        {"LBtr",2}, {"Bsf",1}, {"Bsr",1}, {"MemCpy",3}, {"MemSet",3},
        {"MemSetI64",3}, {"MemCmp",3}, {"StrLen",1}, {"StrCmp",2}, {"StrNCmp",3},
        {"StrCpy",2}, {"StrICmp",2}, {"Caller",1}, {"IsCmdLineMode",0},
        {"StrPrintFunSeg",4}, {"PutS",1}, {"Print",0}, {"SwapI64",2}, {"Pow10",1},
        {"WriteProtectMemCpy",3}, {"NativeExit",1}, {"NativeErrPutS",1},
        {"NativeArgCount",0}, {"NativeArg",1}, {"NativeGetChar",0},
        {"AIWNIOS_SetJmp",1}, {"AIWNIOS_LongJmp",1}, {"ExtDft",2}, {"ExtChg",2},
        {"FileNameAbs",2}, {"FileRead",3}, {"FileWrite",3}, {"NativeWrite",3},
        {"UnixNow",0}, {"__GetTicks",0}, {"Sin",1}, {"Cos",1}, {"Tan",1},
        {"ATan",1}, {"Arg",2}, {"Exp",1}, {"Ln",1}, {"Log2",1}, {"Log10",1},
        {"Pow",2}, {"Sqrt",1}, {"Floor",1}, {"Ceil",1}, {"FlushMsgs",0},
        {"NativeFileStat",1}, {"NativeDirList",2}, {"NativeFileDelete",1}, {"NativeFileMkdir",1},
        {"NativeNetResolve",1}, {"NativeNetConnect",3}, {"NativeNetListen",1}, {"NativeNetAccept",2},
        {"NativeNetSend",3}, {"NativeNetReceive",4}, {"NativeNetUdpOpen",1}, {"NativeNetUdpSend",5},
        {"NativeNetUdpReceive",4}, {"NativeNetSource",1}, {"NativeNetSourcePort",1},
        {"NativeNetPort",1}, {"NativeNetClose",1},
        {"NativeSafeStat",1}, {"NativeSafeRead",1}, {"NativeSafeWrite",4},
        {"NativeSafeDelete",1}, {"NativeSafeMkdir",1}, {"NativeSafeList",2},
        {"NativeTaskSpawn",4}, {"NativeTaskAbort",1}, {"NativeTaskWait",1}, {"NativeTaskResult",1}, {"NativeTaskMessage",1},
        {"NativeTaskRelease",1}, {"NativeTaskDetach",1},
        {"NativeUnixNow",0}, {"NativeMonotonicMs",0}, {"NativeSleep",1}, {"NativeYield",0}
    };
    // Exception intrinsics see the Cool frame directly; wrapping setjmp would
    // save the bridge's already-returned stack frame.
    if (!strcmp(name, "AIWNIOS_SetJmp") || !strcmp(name, "AIWNIOS_LongJmp")) return fn;
    size_t argc = 0;
    int found = 0, kind = 0;
    for (size_t i = 0; i < sizeof(arities)/sizeof(arities[0]); i++)
        if (!strcmp(name, arities[i].name)) {argc = arities[i].argc; found = 1; break;}
    if (!found) fail("host import lacks an x86 ABI descriptor");
    if (!strcmp(name, "Print")) kind = 2;
    else if (!strcmp(name, "Pow10") || !strcmp(name, "Sin") || !strcmp(name, "Cos") ||
             !strcmp(name, "Tan") || !strcmp(name, "ATan") || !strcmp(name, "Arg") ||
             !strcmp(name, "Exp") || !strcmp(name, "Ln") || !strcmp(name, "Log2") ||
             !strcmp(name, "Log10") || !strcmp(name, "Pow") || !strcmp(name, "Sqrt") ||
             !strcmp(name, "Floor") || !strcmp(name, "Ceil")) kind = 1;
    X86HostImport *desc = malloc(sizeof(*desc));
    if (!desc) fail("out of memory creating host import");
    if (!strcmp(name, "NativeTaskSpawn") || !strcmp(name, "NativeTaskAbort")) {kind = 4; fn = (uintptr_t)name;}
    *desc = (X86HostImport){fn, argc, kind};
    return x86_import_thunk(desc);
}
