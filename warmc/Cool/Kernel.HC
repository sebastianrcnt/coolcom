// Appended to the generated single-file kernel package. Requires Warm.HC,
// Diagnostic.HC, builtin data, and WKernelRuntime(CWUnit *).
// Invoke only on the compiler/shell task (ShellExe requires its x28 state).
I64 warm_kernel_serial;
Bool warm_kernel_runtime_ready, warm_kernel_completed;
U0 WKernelComplete() {warm_kernel_completed = TRUE;}
U8 *warm_kernel_argv0;
U0 WKernelExit(I64 status) {if (status) throw('Warm');}
U0 WKernelErrPutS(U8 *text) {Print("%s", text);}
I64 WKernelArgCount() {return 1;}
U8 *WKernelArg(I64 index) {if (index == 0) return warm_kernel_argv0; return NULL;}

Bool WarmCompile(U8 *paths, U8 *entry = "Test:main", U8 *output = NULL)
{
    CWUnit *u = WNew();
    U8 *path, *source, *code, *runtime;
    I64 i = 0, start = 0, size;
    Bool ok = FALSE;
    u->symbol_base = (++warm_kernel_serial) * 1000000;
    for (i = 0; !u->error_kind; i++) {
        if (paths[i] == ',' || !paths[i]) {
            path = WText(u, paths + start, i - start); start = i + 1;
            source = FileRead(path, &size);
            if (!source) {WFail(u, NULL, "Command Line Arguments Error", "Cannot read Warm input"); break;}
            size = StrLen(path);
            WParse(u, path, source, !(size >= 4 && WEq(path + size - 4, ".aui"))); Free(source);
        }
        if (!paths[i]) break;
    }
    if (!u->error_kind) WBuiltins(u);
    if (!u->error_kind) WResolve(u);
    if (!u->error_kind) WTypeCheck(u);
    if (!u->error_kind) WLinearity(u);
    if (!u->error_kind) {
        runtime = "";
        if (output) runtime = WKernelRuntime(u);
        code = WEmit(u, entry, runtime, FALSE);
        if (!u->error_kind) {
            if (output) {
                ok = FileWrite(output, code, StrLen(code));
                if (!ok) WFail(u, NULL, "Command Line Arguments Error", "Cannot write Warm output");
            }
            else {
                warm_kernel_argv0 = paths;
                try {
                    if (!warm_kernel_runtime_ready) {
                        warm_kernel_completed = FALSE;
                        ShellExe(WGCat(u, WKernelRuntime(u), "\nWKernelComplete();\n"));
                        warm_kernel_runtime_ready = warm_kernel_completed;
                    }
                    warm_kernel_completed = FALSE;
                    if (warm_kernel_runtime_ready) ShellExe(WGCat(u, code, "\nWKernelComplete();\n"));
                    ok = warm_kernel_completed;
                    if (ok) warm_kernel_runtime_ready = TRUE;
                } catch {
                    Fs->catch_except = TRUE;
                    Print("Warm execution aborted\n");
                }
            }
        }
    }
    if (u->error_kind) WDiagnostic(u);
    WDestroy(u);
    return ok;
}
Bool WarmRun(U8 *paths, U8 *entry = "Test:main") {return WarmCompile(paths, entry);}
