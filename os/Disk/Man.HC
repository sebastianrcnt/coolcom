// Man("Name"): show where a function, class, global variable or #define is defined.
// The shell compiler's symbol table says what Name is. A symbol defined in a file the shell
// compiled (Vim.HC, your own #include) carries its file and line, and Vim opens there. The
// kernel's own symbols come from the compiler's prelude, so their source is looked up in
// the kernel sources on the disk (C:/Kernel: os/Kernel and the shared library files) by
// the shape of a definition: a function is a line with a return type and Name(, a class is
// "class Name", a global is a declaration at the start of a line, a #define is #define Name.
// A file too big for Vim (over 128 KiB, e.g. KernelA.HH) opens in Less at the line.
//   Man("StrLen");   Man("CTask");   Man("VimOpen");   Man("jiffies");
#define MAN_SRC   "C:/Kernel/*"
#define MAN_FUN   1
#define MAN_CLASS 2
#define MAN_GLOBAL 3
#define MAN_DEFINE 4
U8 man_extra[600];

// The compiler's hash entry for name, or NULL. Real definitions win over the bare kernel
// export every symbol also has.
CHashSrcSym *ManHash(U8 *name)
{
    CHashSrcSym *h;
    if (!ShellCur || !ShellCur->hash) return NULL;
    h = HashFind(name, ShellCur->hash, HTT_FUN | HTT_CLASS | HTT_INTERNAL_TYPE | HTT_GLBL_VAR | HTT_DEFINE_STR);
    if (!h) h = HashFind(name, ShellCur->hash, HTT_EXPORT_SYS_SYM);
    return h;
}

I64 ManKind(CHashSrcSym *h)
{
    if (h->type & HTT_FUN) return MAN_FUN;
    if (h->type & (HTT_CLASS | HTT_INTERNAL_TYPE)) return MAN_CLASS;
    if (h->type & HTT_GLBL_VAR) return MAN_GLOBAL;
    if (h->type & HTT_DEFINE_STR) return MAN_DEFINE;
    return 0;
}

Bool ManSrcLink(CHashSrcSym *h, U8 *file, I64 *_line)
{//"FL:C:/Vim.HC,803" -> file (at least 200 bytes) and line, if it is a real file.
    U8 *s = h->src_link, *comma = NULL;
    if (!s || StrNCmp(s, "FL:", 3)) return FALSE;
    s += 3;
    while (*s) {
        if (*s == ',') comma = s;
        s++;
    }
    if (!comma || comma - h->src_link - 3 > 190) return FALSE;
    MemCpy(file, h->src_link + 3, comma - h->src_link - 3);
    file[comma - h->src_link - 3] = 0;
    *_line = Str2I64(comma + 1);
    return FileFind(file);
}

Bool ManIsId(I64 c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '@';
}

Bool ManDefLine(U8 *p, I64 n, U8 *name, I64 nl, I64 kind)
{//Is p[0..n) the definition of name (of that kind; 0: any)?
    I64 i, j, c;
    if (n < nl + 1 || p[0] == ' ' || p[0] == '\t' || p[0] == '/' || p[0] == '{' || p[0] == '}' || p[0] == '\r')
        return FALSE;
    if (p[0] == '#') {
        if ((kind && kind != MAN_DEFINE) || n < 8 || StrNCmp(p, "#define", 7)) return FALSE;
        for (i = 7; i < n && (p[i] == ' ' || p[i] == '\t'); i++);
        return i + nl <= n && !MemCmp(p + i, name, nl) && (i + nl == n || !ManIsId(p[i + nl]));
    }
    if (!StrNCmp(p, "extern ", 7) || !StrNCmp(p, "public extern ", 14) || !StrNCmp(p, "import ", 7) ||
            !StrNCmp(p, "_extern ", 8) || !StrNCmp(p, "_import ", 8))
        return FALSE;
    // Assembly: a label at the start of the line, or the symbol after .global.
    if (!MemCmp(p, name, nl) && p[nl] == ':' && (!kind || kind == MAN_FUN)) return TRUE;
    if (!kind || kind == MAN_CLASS) {
        i = 0;
        if (!StrNCmp(p, "public ", 7)) i = 7;
        if (!StrNCmp(p + i, "class ", 6) || !StrNCmp(p + i, "union ", 6)) {
            i += 6;
            while (i < n && p[i] == ' ') i++;
            if (i + nl <= n && !MemCmp(p + i, name, nl) && (i + nl == n || !ManIsId(p[i + nl]))) return TRUE;
        }
        if (kind == MAN_CLASS) return FALSE;
    }
    if (kind == MAN_DEFINE) return FALSE;
    for (i = 1; i + nl <= n; i++) {
        c = p[i - 1];
        if ((c == ' ' || c == '*' || c == '\t') && !MemCmp(p + i, name, nl) && (i + nl == n || !ManIsId(p[i + nl]))) {
            for (j = 0; j < i; j++)
                if (p[j] == '(' || p[j] == '=' || p[j] == '"' || p[j] == ',') return FALSE;
            j = i + nl;
            while (j < n && p[j] == ' ') j++;
            if (kind == MAN_FUN || !kind) {
                if (j < n && p[j] == '(') {
                    j = n;
                    while (j > i && (p[j - 1] == ' ' || p[j - 1] == '\r')) j--;
                    if (p[j - 1] != ';' || TextFind(p, 0, n, "{", 1) >= 0) return TRUE;
                    return FALSE;
                }
            }
            if (kind == MAN_GLOBAL || !kind) {
                if (j >= n || p[j] == ';' || p[j] == '=' || p[j] == '[' || p[j] == ',' || p[j] == '\r') return TRUE;
            }
            return FALSE;
        }
    }
    return FALSE;
}

// Search the kernel sources for the definition. Returns the number of places found;
// the first is in file (>= 200 bytes) and *_line.
I64 ManSearch(U8 *name, I64 kind, U8 *file, I64 *_line)
{
    CDirEntry *list, *de;
    U8 *buf, *p, *q, *end;
    I64 size, line, nl = StrLen(name), found = 0;
    man_extra[0] = 0;
    list = FilesFind(MAN_SRC, FUF_RECURSE | FUF_JUST_FILES | FUF_FLATTEN_TREE);
    for (de = list; de; de = de->next) {
        size = TextRead(de->full_name, &buf);
        if (size <= 0) {Free(buf); goto man_next;}
        end = buf + size;
        line = 1;
        for (p = buf; p < end; p = q + 1) {
            q = p;
            while (q < end && *q != '\n') q++;
            if (ManDefLine(p, q - p, name, nl, kind)) {
                if (!found) {
                    StrCpy(file, de->full_name);
                    *_line = line;
                } else if (found < 4 && StrLen(man_extra) < 400) {
                    StrPrint(man_extra + StrLen(man_extra), "  also %s:%d\n", de->full_name, line);
                }
                found++;
            }
            line++;
        }
        Free(buf);
man_next:
    }
    DirTreeDel(list);
    return found;
}

U0 ManOpen(U8 *file, I64 line)
{
    CDirEntry de;
    if (FileFind(file, &de) && de.size >= VIM_CAP) {
        Free(de.full_name);
        Print("%s is too big for Vim; opening it in Less\n", file);
        Less(file, line);
    } else {
        if (de.full_name) Free(de.full_name);
        Vim(file, line);
    }
}

U0 Man(U8 *name)
{
    CHashSrcSym *h = ManHash(name);
    U8 file[208], *what = "symbol";
    I64 line = 0, kind = 0, n;
    if (HCTIsType(name, StrLen(name))) {
        Print("%s is a built-in type\n", name);
        return;
    }
    if (h) {
        kind = ManKind(h);
        if (kind == MAN_FUN) what = "function";
        else if (kind == MAN_CLASS) what = "type";
        else if (kind == MAN_GLOBAL) what = "global variable";
        else if (kind == MAN_DEFINE) what = "#define";
        if (ManSrcLink(h, file, &line)) {
            Print("%s: %s, %s:%d\n", name, what, file, line);
            ManOpen(file, line);
            return;
        }
    }
    n = ManSearch(name, kind, file, &line);
    if (!n && kind) n = ManSearch(name, 0, file, &line);
    if (!n) {
        if (h) Print("Man: no source found for %s (looked in C:/Kernel)\n", name);
        else Print("Man: unknown symbol %s\n", name);
        return;
    }
    Print("%s: %s, %s:%d\n%s", name, what, file, line, man_extra);
    ManOpen(file, line);
}
