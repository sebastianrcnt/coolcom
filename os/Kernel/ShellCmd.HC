// What the shell's line reader adds to HolyC (included by Shell.HC):
//
// Unix-style command lines. A line that is a function's name (any capitalization: vim, Vim,
// find) followed by words rewrites to a call, so `vim a.HC` runs Vim("a.HC");, `find foo
// *.HC` runs Find("foo", "*.HC"); and `hexdump C:/A.TXT 0 16` runs HexDump("C:/A.TXT", 0, 16);.
// The function's own parameter types (from the compiler's symbol table) decide what a word
// becomes: a pointer parameter takes a string, an integer parameter a number (12, -3, 0x1F,
// TRUE) or a constant's name. Words in "quotes" or 'quotes' keep their spaces. A line that
// is just a lowercase function name (top) runs it (Top;). The rewrite only applies when the
// word after the name cannot continue a HolyC statement, so `Sq(7);`, `x = 5;`, `Print("a");`
// and `I64 n;` are compiled as they are; a variable with the exact name wins over a command.
//
// Tab completion (Key.HC's GetLine calls line_complete_hook): an identifier completes from the
// compiler's symbol table (functions, classes, globals, #defines; the first word also matches
// ignoring case), a word after a command, or inside a string, completes as a file name. It
// extends to the longest common prefix, and lists the candidates when that adds nothing.
#define SHELL_CANDS    400

Bool ShellIdStart(I64 c) {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';}
Bool ShellIdChar(I64 c) {return ShellIdStart(c) || (c >= '0' && c <= '9');}
Bool ShellBlank(I64 c) {return c == ' ' || c == '\t';}

CHashFun *ShellFunIcase(U8 *word, Bool *_ambiguous)
{//The function whose name equals word ignoring case; *_ambiguous if two spellings exist.
    CHashTable *table;
    CHash *h;
    CHashFun *found = NULL;
    I64 i;
    *_ambiguous = FALSE;
    for (table = ShellCur->hash; table; table = table->next)
        for (i = 0; i <= table->mask; i++)
            for (h = table->body[i]; h; h = h->next)
                if ((h->type & HTT_FUN) && !StrICmp(h->str, word)) {
                    if (found && StrCmp(found->str, h->str)) *_ambiguous = TRUE;
                    else if (!found) found = h;
                }
    return found;
}

U8 *ShellAlias(U8 *w)
{//Names from other shells.
    if (!StrCmp(w, "ls")) return "Dir";
    if (!StrCmp(w, "cat")) return "Type";
    if (!StrCmp(w, "rm")) return "Del";
    if (!StrCmp(w, "cp")) return "Copy";
    if (!StrCmp(w, "mv")) return "Move";
    if (!StrCmp(w, "clear")) return "Cls";
    return NULL;
}

Bool ShellKeyword(U8 *w)
{
    I64 n = StrLen(w);
    return HCTIsKwSp(w, n) || HCTIsKw2(w, n) || HCTIsMod(w, n) || HCTIsType(w, n) || HCTIsConst(w, n);
}

CHashFun *ShellCmdFun(U8 *word)
{//The function a command word names, or NULL.
    CHashFun *f;
    Bool amb;
    U8 *alias;
    if (!ShellCur || !ShellCur->hash || ShellKeyword(word)) return NULL;
    f = HashFind(word, ShellCur->hash, HTT_FUN);
    if (f) return f;
    if (HashFind(word, ShellCur->hash, HTT_GLBL_VAR | HTT_CLASS | HTT_INTERNAL_TYPE | HTT_DEFINE_STR)) return NULL;
    f = ShellFunIcase(word, &amb);
    if (f && !amb) return f;
    alias = ShellAlias(word);
    if (alias) return HashFind(alias, ShellCur->hash, HTT_FUN);
    return NULL;
}

Bool ShellNumber(U8 *s, I64 n)
{//12, -3, 0x1F, 1.5, TRUE, FALSE
    I64 i = 0;
    if (!n) return FALSE;
    if (HCTStrEq(s, n, "TRUE") || HCTStrEq(s, n, "FALSE")) return TRUE;
    if (s[0] == '-') i = 1;
    if (i >= n) return FALSE;
    if (n - i > 2 && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
        for (i += 2; i < n; i++)
            if (!HCTIsDigit(s[i]) && !((s[i] | 0x20) >= 'a' && (s[i] | 0x20) <= 'f')) return FALSE;
        return TRUE;
    }
    for (; i < n; i++)
        if (!HCTIsDigit(s[i]) && s[i] != '.') return FALSE;
    return TRUE;
}

Bool ShellIsIdent(U8 *s, I64 n)
{
    I64 i;
    if (n < 1 || !ShellIdStart(s[0])) return FALSE;
    for (i = 1; i < n; i++)
        if (!ShellIdChar(s[i])) return FALSE;
    return TRUE;
}

Bool ShellArgStart(U8 *p, U8 *end)
{//Can the text at p start a command's arguments (rather than continue a HolyC statement)?
    I64 c = *p;
    if (ShellIdChar(c)) return TRUE;
    if (c == '"' || c == '\'' || c == '/' || c == '.' || c == '~' || c == '*' || c == '\\') return TRUE;
    return c == '-' && p + 1 < end && ShellIdChar(p[1]);
}

Bool ShellPut(U8 **_o, U8 *limit, U8 *s, I64 n)
{
    if (*_o + n >= limit) return FALSE;
    MemCpy(*_o, s, n);
    *_o += n;
    return TRUE;
}

U8 *ShellUnix(U8 *line)
{//The line, or its rewrite as a call when it is a command line.
    U8 word[64], *ws, *p = line, *end, *out = ShellCur->cmd, *o, *limit = ShellCur->cmd + SHELL_CMD_LEN - 8, q, tok[520], c1[2];
    CHashFun *f;
    CMemberLst *m;
    I64 wn, k = 0, n, i;
    Bool quoted, want_str;
    while (ShellBlank(*p)) p++;
    if (!ShellIdStart(*p)) return line;
    ws = p;
    while (ShellIdChar(*p)) p++;
    wn = p - ws;
    if (wn > 60 || (*p && !ShellBlank(*p))) return line;
    MemCpy(word, ws, wn);
    word[wn] = 0;
    end = p + StrLen(p);
    while (end > p && ShellBlank(end[-1])) end--;
    if (end > p && end[-1] == ';') end--;
    while (end > p && ShellBlank(end[-1])) end--;
    while (p < end && ShellBlank(*p)) p++;
    if (p == end) {  // a lone word: only a function named with other capitalization is a command
        f = ShellCmdFun(word);
        if (!f || !StrCmp(word, f->str)) return line;
        StrPrint(out, "%s;", f->str);
        return out;
    }
    if (!ShellArgStart(p, end)) return line;
    f = ShellCmdFun(word);
    if (!f) return line;
    StrPrint(out, "%s(", f->str);
    o = out + StrLen(out);
    m = f->member_lst_and_root;
    while (p < end) {
        n = 0;
        quoted = FALSE;
        if (*p == '"' || *p == '\'') {
            q = *p++;
            quoted = TRUE;
            while (p < end && *p != q) {
                if (*p == '\\' && p + 1 < end && (p[1] == q || p[1] == '\\')) p++;
                if (n < 500) tok[n++] = *p;
                p++;
            }
            if (p < end) p++;
        } else
            while (p < end && !ShellBlank(*p)) {
                if (*p == '\\' && p + 1 < end) p++;
                if (n < 500) tok[n++] = *p;
                p++;
            }
        while (p < end && ShellBlank(*p)) p++;
        if (k) {if (!ShellPut(&o, limit, ", ", 2)) return line;}
        want_str = TRUE;
        if (quoted)
            want_str = TRUE;
        else if (k < f->arg_cnt && m && m->member_class->ptr_stars_cnt > 0)
            want_str = TRUE;
        else if (ShellNumber(tok, n))
            want_str = FALSE;
        else if (k < f->arg_cnt && m && ShellIsIdent(tok, n)) {
            // an integer parameter takes a constant's name too
            tok[n] = 0;
            want_str = !HashFind(tok, ShellCur->hash, HTT_GLBL_VAR | HTT_DEFINE_STR);
        }
        if (quoted || want_str) {
            if (!ShellPut(&o, limit, "\"", 1)) return line;
            for (i = 0; i < n; i++) {
                if (tok[i] < 32) goto shell_skip;
                if (tok[i] == '"' || tok[i] == '\\') {
                    if (!ShellPut(&o, limit, "\\", 1)) return line;
                }
                c1[0] = tok[i];
                if (!ShellPut(&o, limit, c1, 1)) return line;
shell_skip:
            }
            if (!ShellPut(&o, limit, "\"", 1)) return line;
        } else if (!ShellPut(&o, limit, tok, n))
            return line;
        k++;
        if (m && k <= f->arg_cnt) m = m->next;
    }
    if (!ShellPut(&o, limit, ");", 3)) return line;  // includes the NUL
    return out;
}

// ---- Tab completion ----

Bool ShellCandAdd(U8 **c, I64 *_n, U8 *s, Bool icase)
{//Insert s into the sorted candidate list, once. FALSE if the list is full.
    I64 i, j, d;
    for (i = 0; i < *_n; i++) {
        if (icase) d = StrICmp(c[i], s);
        else d = StrCmp(c[i], s);
        if (!d && !StrCmp(c[i], s)) return TRUE;
        if (d > 0) break;
    }
    if (*_n >= SHELL_CANDS) return FALSE;
    for (j = *_n; j > i; j--) c[j] = c[j - 1];
    c[i] = s;
    ++*_n;
    return TRUE;
}

I64 ShellCommon(U8 **c, I64 n, Bool icase)
{//Length of the prefix all candidates share.
    I64 len = StrLen(c[0]), i, j;
    for (i = 1; i < n; i++) {
        for (j = 0; j < len && c[0][j] && c[i][j]; j++)
            if (icase) {
                if ((c[0][j] | 0x20) != (c[i][j] | 0x20)) break;
            } else if (c[0][j] != c[i][j]) break;
        len = j;
    }
    return len;
}

U0 ShellReplace(U8 *b, I64 size, I64 *_n, I64 *_pos, I64 from, U8 *s, I64 len)
{//Replace b[from..cursor) by s[0..len), redrawing the line.
    if (*_pos - from == len && !MemCmp(b + from, s, len)) return;
    if (*_pos > from) LineDelete(b, _n, _pos, from, *_pos);
    LineInsert(b, size, _n, _pos, s, len);
}

U0 ShellList(U8 **c, I64 n, U8 *suffix_dirs)
{//Print the candidates in columns, then the prompt and line again is the caller's job.
    I64 rows, cols, i, w, wide = 0, per, x = 0;
    U8 buf[300];
    AnsiTermSize(&rows, &cols);
    for (i = 0; i < n && i < 150; i++) {
        w = StrLen(c[i]) + 2;
        if (w > wide) wide = w;
    }
    per = cols / wide;
    if (per < 1) per = 1;
    ConsPut('\n');
    for (i = 0; i < n && i < 150; i++) {
        StrCpy(buf, c[i]);
        if (suffix_dirs && suffix_dirs[i]) StrCat(buf, "/");
        ConsPutS(buf);
        for (w = StrLen(buf); w < wide; w++) ConsPut(' ');
        if (++x >= per) {
            x = 0;
            ConsPut('\n');
        }
    }
    if (n > 150) Print("\n... %d more", n - 150);
    if (x || n > 150) ConsPut('\n');
}

Bool ShellInString(U8 *b, I64 pos)
{//An odd number of unescaped quotes before pos?
    I64 i;
    Bool in = FALSE;
    for (i = 0; i < pos; i++) {
        if (b[i] == '\\' && in) i++;
        else if (b[i] == '"') in = !in;
    }
    return in;
}

Bool ShellArgPos(U8 *b, I64 ts)
{//Does a command word (a function) precede ts on the line, with only arguments in between?
    U8 word[64], *p = b, *stop = b + ts;
    I64 wn;
    CHashFun *f;
    while (p < stop && ShellBlank(*p)) p++;
    if (p >= stop || !ShellIdStart(*p)) return FALSE;
    wn = 0;
    while (p < stop && ShellIdChar(*p) && wn < 60) word[wn++] = *p++;
    word[wn] = 0;
    if (p >= stop || !ShellBlank(*p)) return FALSE;
    while (p < stop && ShellBlank(*p)) p++;
    if (p < stop && !ShellArgStart(p, stop)) return FALSE;
    f = ShellCmdFun(word);
    return f != NULL;
}

U0 ShellCompleteFile(U8 *b, I64 size, I64 *_n, I64 *_pos, Bool in_str)
{
    I64 pos = *_pos, ts = pos, slash, n = 0, common, len;
    U8 mask[300], *cand[SHELL_CANDS], dirs[SHELL_CANDS], *base, *name;
    CDirEntry *list, *de;
    Bool old_silent, show;
    while (ts > 0 && !ShellBlank(b[ts - 1]) && b[ts - 1] != '"' && b[ts - 1] != '\'' && b[ts - 1] != '(' && b[ts - 1] != ',' &&
            b[ts - 1] != ';')
        ts--;
    slash = pos;
    while (slash > ts && b[slash - 1] != '/') slash--;
    if (pos - ts > 250) return;
    MemCpy(mask, b + ts, pos - ts);
    mask[pos - ts] = 0;
    StrCat(mask, "*");
    base = b + slash;
    old_silent = Silent;
    Silent(TRUE);
    list = FilesFind(mask, 0);
    Silent(old_silent);
    for (de = list; de; de = de->next) {
        name = de->name;
        if (name[0] == '.' && base[0] != '.') goto next_de;
        if (n < SHELL_CANDS) {
            dirs[n] = (de->attr & RS_ATTR_DIR) != 0;
            cand[n++] = name;
        }
next_de:
    }
    if (!n) {
        DirTreeDel(list);
        return;
    }
    // Candidates are in directory order; the shared part is the longest prefix, ignoring case.
    common = ShellCommon(cand, n, TRUE);
    len = pos - slash;
    show = FALSE;
    if (n == 1) {
        StrCpy(mask, cand[0]);
        if (dirs[0]) StrCat(mask, "/");
        else if (!in_str) StrCat(mask, " ");
        ShellReplace(b, size, _n, _pos, slash, mask, StrLen(mask));
    } else if (common > len) {
        MemCpy(mask, cand[0], common);
        mask[common] = 0;
        ShellReplace(b, size, _n, _pos, slash, mask, common);
    } else
        show = TRUE;
    if (show) {
        ShellList(cand, n, dirs);
        Print("%s", SHELL_PROMPT);
        LineOut(b, 0, *_n);
        LineBack(LineWidth(b, *_pos, *_n));
    }
    DirTreeDel(list);
}

U0 ShellCompleteSymbol(U8 *b, I64 size, I64 *_n, I64 *_pos)
{
    I64 pos = *_pos, ts = pos, f0 = 0, n = 0, i, common, len, kinds, mask;
    U8 *cand[SHELL_CANDS], tok[80], *s, buf[80];
    CHashTable *table;
    CHash *h;
    Bool first, icase = FALSE;
    while (ts > 0 && ShellIdChar(b[ts - 1])) ts--;
    if (ts == pos || pos - ts > 70) return;
    while (ShellBlank(b[f0])) f0++;
    first = ts == f0;
    MemCpy(tok, b + ts, pos - ts);
    tok[pos - ts] = 0;
    len = pos - ts;
    mask = HTT_FUN | HTT_CLASS | HTT_GLBL_VAR | HTT_DEFINE_STR | HTT_EXPORT_SYS_SYM;
    for (kinds = 0; kinds < 2 && !n; kinds++) {
        // pass 0: the prefix as typed; pass 1 (the first word only): ignoring case, functions
        if (kinds == 1) {
            if (!first) break;
            icase = TRUE;
            mask = HTT_FUN;
        }
        for (table = ShellCur->hash; table; table = table->next)
            for (i = 0; i <= table->mask; i++)
                for (h = table->body[i]; h; h = h->next)
                    if (h->type & mask) {
                        s = h->str;
                        if (icase) {
                            if (StrNICmp(s, tok, len)) goto next_h;
                        } else if (StrNCmp(s, tok, len))
                            goto next_h;
                        ShellCandAdd(cand, &n, s, icase);
next_h:
                    }
    }
    if (!n) return;
    common = ShellCommon(cand, n, icase);
    if (n == 1) {
        StrCpy(buf, cand[0]);
        if (first && HashFind(buf, ShellCur->hash, HTT_FUN)) StrCat(buf, " ");
        ShellReplace(b, size, _n, _pos, ts, buf, StrLen(buf));
    } else if (common > len || (icase && common == len && StrNCmp(cand[0], tok, len))) {
        MemCpy(buf, cand[0], common);
        buf[common] = 0;
        ShellReplace(b, size, _n, _pos, ts, buf, common);
    } else {
        ShellList(cand, n, NULL);
        Print("%s", SHELL_PROMPT);
        LineOut(b, 0, *_n);
        LineBack(LineWidth(b, *_pos, *_n));
    }
}

U0 ShellComplete(U8 *b, I64 size, I64 *_n, I64 *_pos)
{//line_complete_hook: Tab in the line editor.
    I64 pos = *_pos, ts = pos;
    if (!ShellCur || !ShellCur->hash) return;
    if (ShellInString(b, pos)) {ShellCompleteFile(b, size, _n, _pos, TRUE); return;}
    while (ts > 0 && ShellIdChar(b[ts - 1])) ts--;
    if (ShellArgPos(b, ts) || (ts > 0 && b[ts - 1] == '/')) {
        ShellCompleteFile(b, size, _n, _pos, FALSE);
        return;
    }
    ShellCompleteSymbol(b, size, _n, _pos);
}
