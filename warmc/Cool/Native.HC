// Host services only; Warm.HC can also be included in the kernel shell.
#define U8 U8i
#define I64 I64i
#define U64 U64i
#define Bool I8i
#define TRUE 1
#define FALSE 0
#define NULL 0
import U8 *CAlloc(I64 size);
import U0 Free(U8 *ptr);
import U8 *MemCpy(U8 *dst, U8 *src, I64 size);
import I64 StrLen(U8 *s);
import I64 StrCmp(U8 *a, U8 *b);
import U0 Print(U8 *format, ...);
import U8 *FileRead(U8 *path, I64 *size, U8 *attrs = NULL);
import I64 FileWrite(U8 *path, U8 *data, I64 size);
import I64 NativeArgCount();
import U8 *NativeArg(I64 index);
import U0 NativeExit(I64 code);
#include "Warm.HC"
#include "../../build/warmcool/Builtins.HC"
#include "../../build/warmcool/RuntimeText.HC"
U0 WDiagnostic(CWUnit *u)
{
    CWToken *t = u->error_token;
    I64 line = 1, col = 1, i, start = 0, end;
    U8 *s;
    if (!t) {Print("%s: %s\n", u->error_kind, u->error_message); return;}
    s = t->source->text;
    for (i = 0; i < t->start; i++) {if (s[i] == '\n') {line++; col = 1; start = i + 1;} else col++;}
    end = start; while (s[end] && s[end] != '\n' && s[end] != '\r') end++;
    Print("%s:%d:%d: %s: %s\n", t->source->path, line, col, u->error_kind, u->error_message);
    Print("%s\n", WText(u, s + start, end - start));
    for (i = 1; i < col; i++) {if (s[(start + i) - 1] == '\t') Print("\t"); else Print(" ");}
    Print("^\n");
}
U0 WDump(CWNode *n, I64 indent)
{
    CWNode *c; I64 i;
    for (i = 0; i < indent; i++) Print(" ");
    Print("%s %s %s\n", n->role, n->tag, n->name);
    for (c = n->first; c; c = c->next) WDump(c, indent + 1);
}
I64 WNativeMain()
{
    CWUnit *u = WNew();
    U8 *arg, *source, *part, *output = NULL, *entry = "Test:main", *generated;
    I64 i, j, start, size, n, code = 0;
    Bool dump = FALSE, parse = FALSE;
    CWNode *m;
    for (i = 1; i < NativeArgCount(); i++) {
        arg = NativeArg(i);
        if (WEq(arg, "--dump-ast")) dump = TRUE;
        else if (WEq(arg, "--parse")) parse = TRUE;
        else if (WEq(arg, "compile")) {}
        else if (WPrefix(arg, "--output=")) output = arg + 9;
        else if (WPrefix(arg, "--entrypoint=")) entry = arg + 13;
        else if (WPrefix(arg, "--")) {}
        else {
            start = 0; n = StrLen(arg);
            for (j = 0; j <= n; j++) if (arg[j] == ',' || !arg[j]) {
                    part = WText(u, arg + start, j - start); start = j + 1;
                    source = FileRead(part, &size);
                    if (!source) {WFail(u, NULL, "Command Line Arguments Error", "Cannot read input file"); break;}
                    size = StrLen(part); WParse(u, part, source, !(size >= 4 && WEq(part + size - 4, ".aui"))); Free(source);
                    if (u->error_kind) break;
                }
            if (u->error_kind) break;
        }
    }
    if (!u->modules && !u->error_kind) WFail(u, NULL, "Command Line Arguments Error", "No input files");
    if (!u->error_kind && dump) for (m = u->modules; m; m = m->next) WDump(m, 0);
    if (!u->error_kind && !parse && !dump) {WBuiltins(u); if (!u->error_kind) WResolve(u); if (!u->error_kind) WTypeCheck(u); if (!u->error_kind) WLinearity(u);}
    if (!u->error_kind && !parse && !dump) {
        generated = WEmit(u, entry, WRuntime(u), TRUE);
        if (!u->error_kind) {
            if (!output) WFail(u, NULL, "Command Line Arguments Error", "--output is required");
            else if (!FileWrite(output, generated, StrLen(generated))) WFail(u, NULL, "Command Line Arguments Error", "Cannot write output");
        }
    }
    if (u->error_kind) {WDiagnostic(u); code = 1;}
    WDestroy(u); return code;
}
NativeExit(WNativeMain());
