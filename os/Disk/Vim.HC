// Modal UTF-8 editor, loaded on the shell task by Init.HC.
// Positions and ranges are byte offsets; all movement follows character boundaries.
// Bounded storage: 128 KiB text, 32 undo transactions, 4096 keys per dot command.
#define VIM_CAP 131072
#define VIM_HIST 33
#define VIM_KEYS 4096
U8 *vim_buf, *vim_yank, *vim_saved, *vim_hist;
U8 vim_name[256], vim_cmd[256], vim_search[256];
U8 *vim_msg;
I64 vim_len, vim_pos, vim_top, vim_left, vim_mode, vim_anchor;
I64 vim_dirty, vim_saved_len, vim_yank_len, vim_yank_line;
I64 vim_hlen[VIM_HIST], vim_hpos[VIM_HIST], vim_hn, vim_hi;
I64 vim_count, vim_op, vim_opcount, vim_pending, vim_cmd_n, vim_prompt;
I64 vim_search_dir, vim_goal, vim_active, vim_transaction;
I64 vim_keys[VIM_KEYS], vim_dot[VIM_KEYS], vim_kn, vim_dn, vim_replay;
I64 vim_changed, vim_record, vim_overflow;

I64 VimStep(I64 p)
{
    I64 k, i;
    if (p >= vim_len) return vim_len;
    k = Utf8Len(vim_buf[p]);
    if (k < 1 || p + k > vim_len) k = 1;
    for (i = 1; i < k; i++)
        if ((vim_buf[p + i] & 0xC0) != 0x80) {k = 1; break;}
    return p + k;
}

I64 VimPrev(I64 p)
{
    I64 q = p - 1, n = 0;
    if (p <= 0) return 0;
    while (q > 0 && (vim_buf[q] & 0xC0) == 0x80 && n++ < 3) q--;
    if (VimStep(q) != p) return p - 1;
    return q;
}

I64 VimLine(I64 p)
{
    while (p > 0 && vim_buf[p - 1] != '\n') p--;
    return p;
}

I64 VimEnd(I64 p)
{
    while (p < vim_len && vim_buf[p] != '\n') p++;
    return p;
}

I64 VimNextLine(I64 p)
{
    p = VimEnd(p);
    if (p < vim_len) p++;
    return p;
}

I64 VimLastLine()
{
    I64 p = vim_len;
    if (p && vim_buf[p - 1] == '\n') p--;
    return VimLine(p);
}

I64 VimWidth(I64 p, I64 col)
{
    I64 cp;
    if (vim_buf[p] == '\t') return 4 - (col % 4);
    cp = Utf8Cp(vim_buf + p, VimStep(p) - p);
    if (cp < 32 || cp == 127) return 1;
    return Utf8Width(cp);
}

I64 VimCol(I64 p)
{
    I64 a = VimLine(p), w = 0;
    while (a < p) {w += VimWidth(a, w); a = VimStep(a);}
    return w;
}

I64 VimAtCol(I64 p, I64 col)
{
    I64 end = VimEnd(p), w = 0, cw;
    while (p < end) {
        cw = VimWidth(p, w);
        if (w + cw > col) break;
        w += cw;
        p = VimStep(p);
    }
    return p;
}

U0 VimClamp()
{
    I64 end;
    if (vim_pos < 0) vim_pos = 0;
    if (vim_pos > vim_len) vim_pos = vim_len;
    if (vim_mode != 1) {
        if (vim_pos > VimLastLine() && vim_pos == vim_len && vim_len && vim_buf[vim_len - 1] == '\n')
            vim_pos = vim_len - 1;
        end = VimEnd(vim_pos);
        if (vim_pos == end && end > VimLine(end)) vim_pos = VimPrev(end);
    }
}

U0 VimDirty()
{
    vim_dirty = vim_len != vim_saved_len;
    if (!vim_dirty) vim_dirty = MemCmp(vim_buf, vim_saved, vim_len) != 0;
}

U0 VimStore(I64 slot)
{
    MemCpy(vim_hist + slot * VIM_CAP, vim_buf, vim_len + 1);
    vim_hlen[slot] = vim_len;
    vim_hpos[slot] = vim_pos;
}

U0 VimBegin()
{
    if (vim_transaction) return;
    VimStore(vim_hi);
    vim_transaction = TRUE;
    vim_changed = FALSE;
}

U0 VimFinish()
{
    I64 i;
    if (!vim_transaction) return;
    vim_transaction = FALSE;
    if (!vim_changed) return;
    if (vim_len == vim_hlen[vim_hi] && !MemCmp(vim_buf, vim_hist + vim_hi * VIM_CAP, vim_len)) {VimDirty(); return;}
    if (vim_hi == VIM_HIST - 1) {
        for (i = 1; i < VIM_HIST; i++) {
            MemCpy(vim_hist + (i - 1) * VIM_CAP, vim_hist + i * VIM_CAP, vim_hlen[i] + 1);
            vim_hlen[i - 1] = vim_hlen[i];
            vim_hpos[i - 1] = vim_hpos[i];
        }
        vim_hi--;
    }
    vim_hi++;
    vim_hn = vim_hi + 1;
    VimStore(vim_hi);
    if (!vim_replay && vim_record && !vim_overflow) {
        MemCpy(vim_dot, vim_keys, vim_kn * sizeof(I64));
        vim_dn = vim_kn;
    }
    VimDirty();
}

U0 VimUndo(I64 dir)
{
    I64 next = vim_hi + dir;
    if (next < 0 || next >= vim_hn) {vim_msg = "No more history"; return;}
    vim_hi = next;
    vim_len = vim_hlen[next];
    vim_pos = vim_hpos[next];
    MemCpy(vim_buf, vim_hist + next * VIM_CAP, vim_len + 1);
    VimClamp();
    VimDirty();
}

Bool VimInsert(U8 *s, I64 n)
{
    I64 i;
    if (n <= 0) return TRUE;
    if (n >= VIM_CAP - vim_len) {vim_msg = "Buffer full (128 KiB limit)"; return FALSE;}
    for (i = vim_len; i >= vim_pos; i--) vim_buf[i + n] = vim_buf[i];
    MemCpy(vim_buf + vim_pos, s, n);
    vim_pos += n;
    vim_len += n;
    vim_changed = vim_dirty = TRUE;
    return TRUE;
}

U0 VimDelete(I64 a, I64 b)
{
    I64 i;
    if (a < 0 || b > vim_len || a >= b) return;
    for (i = b; i <= vim_len; i++) vim_buf[a + i - b] = vim_buf[i];
    vim_len -= b - a;
    vim_pos = a;
    vim_changed = vim_dirty = TRUE;
}

I64 VimClass(I64 p)
{
    I64 c;
    if (p >= vim_len) return 0;
    c = vim_buf[p];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') return 0;
    if (c >= 128 || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return 1;
    return 2;
}

I64 VimWord(I64 p, I64 motion)
{
    I64 cl;
    if (motion == 'b') {
        if (p) p = VimPrev(p);
        while (p && !VimClass(p)) p = VimPrev(p);
        cl = VimClass(p);
        while (p && VimClass(VimPrev(p)) == cl) p = VimPrev(p);
    } else if (motion == 'e') {
        if (p < vim_len) p = VimStep(p);
        while (p < vim_len && !VimClass(p)) p = VimStep(p);
        cl = VimClass(p);
        while (p < vim_len && VimClass(VimStep(p)) == cl && VimStep(p) < vim_len) p = VimStep(p);
    } else {
        cl = VimClass(p);
        while (p < vim_len && VimClass(p) == cl) p = VimStep(p);
        while (p < vim_len && !VimClass(p)) p = VimStep(p);
    }
    return p;
}

I64 VimFirst(I64 p)
{
    p = VimLine(p);
    while (p < vim_len && (vim_buf[p] == ' ' || vim_buf[p] == '\t')) p++;
    return p;
}

I64 VimGoto(I64 line)
{
    I64 p = 0, next;
    while (--line > 0) {
        next = VimNextLine(p);
        if (next > VimLastLine() || next == p) break;
        p = next;
    }
    return p;
}

Bool VimMotion(I64 c, I64 count, Bool explicit_count)
{
    I64 i, p;
    if (c == 'j' || c == 'k') {
        if (vim_goal < 0) vim_goal = VimCol(vim_pos);
        p = VimLine(vim_pos);
        for (i = 0; i < count; i++) {
            if (c == 'k') {if (p) p = VimLine(p - 1);}
            else if (p < VimLastLine()) p = VimNextLine(p);
        }
        vim_pos = VimAtCol(p, vim_goal);
        return TRUE;
    }
    vim_goal = -1;
    if (c == 'G') {
        if (explicit_count) vim_pos = VimGoto(count);
        else vim_pos = VimLastLine();
    } else if (c == 'g') vim_pos = VimGoto(count);
    else if (c == '0') vim_pos = VimLine(vim_pos);
    else if (c == '^') vim_pos = VimFirst(vim_pos);
    else if (c == '$') {
        for (i = 1; i < count && vim_pos < VimLastLine(); i++) vim_pos = VimNextLine(vim_pos);
        vim_pos = VimEnd(vim_pos);
        if (vim_pos > VimLine(vim_pos)) vim_pos = VimPrev(vim_pos);
    } else if (c == 'h' || c == 'l' || c == 'w' || c == 'b' || c == 'e') {
        for (i = 0; i < count; i++) {
            if (c == 'h') {if (vim_pos > VimLine(vim_pos)) vim_pos = VimPrev(vim_pos);}
            else if (c == 'l') {if (VimStep(vim_pos) < VimEnd(vim_pos)) vim_pos = VimStep(vim_pos);}
            else vim_pos = VimWord(vim_pos, c);
        }
    } else return FALSE;
    return TRUE;
}

U0 VimYank(I64 a, I64 b, Bool line)
{
    vim_yank_len = b - a;
    MemCpy(vim_yank, vim_buf + a, vim_yank_len);
    vim_yank_line = line;
    if (line && (!vim_yank_len || vim_yank[vim_yank_len - 1] != '\n'))
        vim_yank[vim_yank_len++] = '\n';
}

U0 VimOperate(I64 op, I64 a, I64 b, Bool line)
{
    I64 end = b;
    VimYank(a, b, line);
    vim_pos = a;
    if (op == 'y') {vim_mode = 0; return;}
    VimBegin();
    if (op == 'c' && line && b > a && vim_buf[b - 1] == '\n') end--;
    if (op == 'd' && line && b == vim_len && a && vim_buf[b - 1] != '\n') a--;
    VimDelete(a, end);
    if (op == 'c') vim_mode = 1;
    else vim_mode = 0;
}

U0 VimRange(I64 *a, I64 *b)
{
    *a = vim_anchor;
    *b = vim_pos;
    if (*a > *b) {*a = vim_pos; *b = vim_anchor;}
    if (vim_mode == 4) {*a = VimLine(*a); *b = VimNextLine(*b);}
    else *b = VimStep(*b);
}

Bool VimLoad(U8 *name)
{
    I64 n = 0;
    U8 *file = NULL;
    CDirEntry de;
    if (!*name || StrLen(name) >= sizeof(vim_name)) {vim_msg = "Invalid file name"; return FALSE;}
    if (FileFind(name, &de)) {
        if (de.size >= VIM_CAP) {vim_msg = "File too large (128 KiB limit)"; return FALSE;}
        file = FileRead(name, &n);
        if (!file) {vim_msg = "Read failed"; return FALSE;}
        if (n >= VIM_CAP) {Free(file); vim_msg = "File too large"; return FALSE;}
    }
    if (file) {MemCpy(vim_buf, file, n); Free(file);}
    vim_buf[n] = 0;
    vim_len = n;
    StrCpy(vim_name, name);
    MemCpy(vim_saved, vim_buf, n + 1);
    vim_saved_len = n;
    vim_pos = vim_top = vim_left = vim_dirty = vim_hi = 0;
    vim_hn = 1;
    VimStore(0);
    return TRUE;
}

Bool VimSearch(I64 dir)
{
    I64 p = vim_pos, n = StrLen(vim_search), i;
    if (!n) {vim_msg = "No previous search"; return FALSE;}
    for (i = 0; i < vim_len; i++) {
        if (dir > 0) {p = VimStep(p); if (p >= vim_len) p = 0;}
        else {if (!p) p = vim_len; p = VimPrev(p);}
        if (p + n <= vim_len && !MemCmp(vim_buf + p, vim_search, n)) {vim_pos = p; return TRUE;}
    }
    vim_msg = "Pattern not found";
    return FALSE;
}

Bool VimCommand()
{
    I64 i, n = 0, result;
    CDirEntry de;
    U8 *cmd = vim_cmd;
    if (!StrCmp(cmd, "w") || !StrCmp(cmd, "wq")) {
        result = FileWrite(vim_name, vim_buf, vim_len);
        // Empty FAT files correctly return cluster zero; validate the directory too.
        if (result == INVALID_CLUS || (!result && vim_len) || !FileFind(vim_name, &de) || de.size != vim_len) {
            vim_msg = "Write failed"; return FALSE;
        }
        MemCpy(vim_saved, vim_buf, vim_len + 1);
        vim_saved_len = vim_len;
        vim_dirty = FALSE;
        vim_msg = "Written";
        return !StrCmp(cmd, "wq");
    }
    if (!StrCmp(cmd, "q!")) return TRUE;
    if (!StrCmp(cmd, "q")) {
        if (!vim_dirty) return TRUE;
        vim_msg = "Unsaved changes: use :w or :q!";
        return FALSE;
    }
    if (!StrNCmp(cmd, "e ", 2)) {
        if (vim_dirty) vim_msg = "Unsaved changes: use :w first";
        else VimLoad(cmd + 2);
        return FALSE;
    }
    for (i = 0; cmd[i] >= '0' && cmd[i] <= '9'; i++) {
        n = n * 10 + cmd[i] - '0';
        if (n > VIM_CAP) n = VIM_CAP;
    }
    if (i && !cmd[i]) {vim_pos = VimGoto(n); return FALSE;}
    vim_msg = "Unknown command";
    return FALSE;
}

// Returns TRUE only when the user has requested a successful exit.
// This event handler is shared by interactive use and the VM regression tests.
extern Bool VimKey(I64 ev);

Bool VimNormal(I64 c)
{
    I64 n = vim_count, op, a, b, i, p, k, explicit_count = n != 0;
    U8 ub[4], ch = '\n';
    if (!n) n = 1;
    if (vim_pending) {
        p = vim_pending;
        vim_pending = 0;
        if (p == 'g') {
            if (c != 'g') {vim_op = vim_count = 0; return FALSE;}
            c = 'g';
        } else if (p == 'r') {
            if (c < 32 || c >= KEY_SPECIAL) {vim_count = 0; return FALSE;}
            b = vim_pos;
            for (i = 0; i < n && b < VimEnd(vim_pos); i++) b = VimStep(b);
            if (i == n) {
                VimBegin();
                a = vim_pos;
                VimDelete(a, b);
                k = Utf8Enc(ub, c);
                for (i = 0; i < n; i++) VimInsert(ub, k);
                vim_pos = VimPrev(vim_pos);
            }
            vim_count = 0;
            return FALSE;
        } else {
            a = vim_pos;
            b = vim_pos;
            k = n;
            if (vim_op) k *= vim_opcount;
            for (i = 0; i < k; i++) {
                b = VimStep(b);
                while (b < VimEnd(a) && Utf8Cp(vim_buf + b, VimStep(b) - b) != c) b = VimStep(b);
                if (b >= VimEnd(a)) {vim_op = vim_count = 0; return FALSE;}
            }
            if (p == 't') b = VimPrev(b);
            vim_pos = b;
            if (vim_op) {op = vim_op; vim_op = 0; VimOperate(op, a, VimStep(b), FALSE);}
            vim_count = 0;
            return FALSE;
        }
    } else {
        if (c >= '0' && c <= '9' && (c != '0' || vim_count)) {
            vim_count = vim_count * 10 + c - '0';
            if (vim_count > 10000) vim_count = 10000;
            return FALSE;
        }
        if (c == 'g' || c == 'f' || c == 't' || (c == 'r' && !vim_op && vim_mode == 0)) {
            vim_pending = c;
            return FALSE;
        }
    }
    vim_count = 0;
    if (vim_mode >= 3 && (c == 'd' || c == 'x' || c == 'c' || c == 'y')) {
        VimRange(&a, &b);
        if (c == 'x') c = 'd';
        VimOperate(c, a, b, vim_mode == 4);
        return FALSE;
    }
    if (vim_op) {
        op = vim_op;
        vim_op = 0;
        n *= vim_opcount;
        if (n > VIM_CAP) n = VIM_CAP;
        a = vim_pos;
        if (c == op) {
            a = VimLine(a);
            b = a;
            for (i = 0; i < n; i++) b = VimNextLine(b);
            VimOperate(op, a, b, TRUE);
        } else {
            // cw changes through the last nonblank character, preserving following spaces.
            if (c == 'w' && op == 'c' && VimClass(a)) {
                b = a;
                for (i = 0; i < n; i++) {
                    k = VimClass(b);
                    while (b < vim_len && VimClass(b) == k) b = VimStep(b);
                    if (i + 1 < n) while (b < vim_len && !VimClass(b)) b = VimStep(b);
                }
                VimOperate(op, a, b, FALSE);
            } else if (VimMotion(c, n, explicit_count)) {
                b = vim_pos;
                vim_pos = a;
                if (c == 'j' || c == 'k' || c == 'G' || c == 'g') {
                    if (b < a) {p = a; a = b; b = p;}
                    VimOperate(op, VimLine(a), VimNextLine(b), TRUE);
                } else {
                    if (c == 'e' || c == '$') b = VimStep(b);
                    if (b < a) {p = a; a = b; b = p;}
                    VimOperate(op, a, b, FALSE);
                }
            }
        }
        return FALSE;
    }
    if (VimMotion(c, n, explicit_count)) return FALSE;
    if (c == 'v' || c == 'V') {
        p = 3;
        if (c == 'V') p = 4;
        if (vim_mode == p) vim_mode = 0;
        else {if (vim_mode == 0) vim_anchor = vim_pos; vim_mode = p;}
    } else if (vim_mode >= 3) return FALSE;
    else if (c == 'd' || c == 'c' || c == 'y') {vim_op = c; vim_opcount = n;}
    else if (c == 'u') {for (i = 0; i < n; i++) VimUndo(-1);}
    else if (c == 'i' || c == 'a' || c == 'I' || c == 'A' || c == 'o' || c == 'O') {
        VimBegin();
        vim_mode = 1;
        if (c == 'a' && vim_pos < VimEnd(vim_pos)) vim_pos = VimStep(vim_pos);
        if (c == 'I') vim_pos = VimFirst(vim_pos);
        if (c == 'A') vim_pos = VimEnd(vim_pos);
        if (c == 'o') {vim_pos = VimEnd(vim_pos); VimInsert(&ch, 1);}
        if (c == 'O') {vim_pos = VimLine(vim_pos); if (VimInsert(&ch, 1)) vim_pos--;}
    } else if (c == 'x') {
        a = b = vim_pos;
        for (i = 0; i < n && b < VimEnd(a); i++) b = VimStep(b);
        if (b > a) VimOperate('d', a, b, FALSE);
    } else if (c == 'p' || c == 'P') {
        if (vim_yank_len && vim_yank_len * n + vim_len + 1 < VIM_CAP) {
            VimBegin();
            if (vim_yank_line) {
                if (c == 'P') vim_pos = VimLine(vim_pos);
                else {
                    vim_pos = VimNextLine(vim_pos);
                    if (vim_pos && vim_buf[vim_pos - 1] != '\n') VimInsert(&ch, 1);
                }
            } else if (c == 'p' && vim_pos < VimEnd(vim_pos)) vim_pos = VimStep(vim_pos);
            a = vim_pos;
            for (i = 0; i < n; i++) VimInsert(vim_yank, vim_yank_len);
            if (vim_yank_line) vim_pos = VimFirst(a);
            else vim_pos = VimPrev(vim_pos);
        }
    } else if (c == 'J') {
        VimBegin();
        if (n < 2) n = 2;
        for (i = 1; i < n; i++) {
            a = VimEnd(vim_pos);
            if (a < vim_len && a + 1 < vim_len) {
                b = VimFirst(a + 1);
                VimDelete(a, b);
                ch = ' ';
                if (a && vim_buf[a - 1] != ' ' && vim_buf[a - 1] != '\t') VimInsert(&ch, 1);
                vim_pos = a;
            }
        }
    } else if (c == ':' || c == '/' || c == '?') {
        vim_mode = 2; vim_prompt = c; vim_cmd_n = 0; vim_cmd[0] = 0;
    } else if (c == 'n' || c == 'N') {
        p = vim_search_dir;
        if (c == 'N') p = -p;
        for (i = 0; i < n; i++) if (!VimSearch(p)) break;
    } else if (c == '.' && vim_dn && !vim_replay) {
        vim_replay = TRUE;
        for (i = 0; i < n; i++) for (p = 0; p < vim_dn; p++) VimKey(vim_dot[p]);
        vim_replay = FALSE;
    }
    return FALSE;
}

Bool VimKey(I64 ev)
{
    I64 c = ev & KEY_CODE, k, i, n;
    U8 ub[4];
    Bool quit = FALSE;
    if (!vim_replay) {
        if (!vim_record) {vim_kn = 0; vim_record = TRUE; vim_overflow = FALSE;}
        if (vim_kn < VIM_KEYS) vim_keys[vim_kn++] = ev;
        else vim_overflow = TRUE;
    }
    vim_msg = "";
    if (ev & KF_ALT) goto done;
    if (ev & KF_CTRL) {
        if (c == 'r' && vim_mode == 0) {
            n = vim_count;
            if (!n) n = 1;
            for (i = 0; i < n; i++) VimUndo(1);
            vim_count = 0;
        }
        goto done;
    }
    if (c == KEY_ESC) {
        if (vim_mode == 1 && vim_pos > VimLine(vim_pos)) vim_pos = VimPrev(vim_pos);
        vim_mode = vim_pending = vim_op = vim_count = 0;
    } else if (vim_mode == 2) {
        if (c == KEY_ENTER) {
            vim_mode = 0;
            if (vim_prompt == ':') quit = VimCommand();
            else {
                if (vim_cmd_n) StrCpy(vim_search, vim_cmd);
                vim_search_dir = 1;
                if (vim_prompt == '?') vim_search_dir = -1;
                VimSearch(vim_search_dir);
            }
        } else if (c == KEY_BACKSPACE) {
            if (vim_cmd_n) {vim_cmd_n = LinePrev(vim_cmd, vim_cmd_n); vim_cmd[vim_cmd_n] = 0;}
            else vim_mode = 0;
        } else if (c >= 32 && c < KEY_SPECIAL) {
            k = Utf8Enc(ub, c);
            if (vim_cmd_n + k < sizeof(vim_cmd)) {
                MemCpy(vim_cmd + vim_cmd_n, ub, k);
                vim_cmd_n += k;
                vim_cmd[vim_cmd_n] = 0;
            }
        }
    } else if (vim_mode == 1) {
        if (c == KEY_BACKSPACE) {if (vim_pos) VimDelete(VimPrev(vim_pos), vim_pos);}
        else if (c == KEY_DEL) VimDelete(vim_pos, VimStep(vim_pos));
        else if (c == KEY_LEFT) {if (vim_pos > VimLine(vim_pos)) vim_pos = VimPrev(vim_pos);}
        else if (c == KEY_RIGHT) {if (vim_pos < VimEnd(vim_pos)) vim_pos = VimStep(vim_pos);}
        else if (c == KEY_UP) VimMotion('k', 1, FALSE);
        else if (c == KEY_DOWN) VimMotion('j', 1, FALSE);
        else if (c == KEY_HOME) vim_pos = VimLine(vim_pos);
        else if (c == KEY_END) vim_pos = VimEnd(vim_pos);
        else if (c == KEY_ENTER || c == KEY_TAB || (c >= 32 && c < KEY_SPECIAL)) VimInsert(ub, Utf8Enc(ub, c));
    } else {
        if (c == KEY_LEFT) c = 'h';
        if (c == KEY_RIGHT) c = 'l';
        if (c == KEY_UP) c = 'k';
        if (c == KEY_DOWN) c = 'j';
        if (c == KEY_HOME) c = '0';
        if (c == KEY_END) c = '$';
        quit = VimNormal(c);
    }
done:
    VimClamp();
    if (vim_mode != 1) VimFinish();
    if (!vim_mode && !vim_count && !vim_op && !vim_pending) vim_record = FALSE;
    return quit;
}

U0 VimPutNum(I64 n)
{
    U8 b[32];
    StrPrint(b, "%d", n);
    ConsPutS(b);
}

U0 VimCsi(I64 row, I64 col)
{
    ConsPutS("\x1b["); VimPutNum(row); ConsPut(';'); VimPutNum(col); ConsPut('H');
}

// Render only printable text: a file cannot inject terminal control sequences.
U0 VimText(U8 *s, I64 limit)
{
    I64 p = 0, x = 0, k, cp, w;
    while (s[p] && x < limit) {
        k = Utf8Len(s[p]);
        if (k < 1) k = 1;
        if (StrLen(s + p) < k) k = 1;
        cp = Utf8Cp(s + p, k);
        w = Utf8Width(cp);
        if (x + w > limit) break;
        if (cp < 32 || cp == 127) ConsPut('?');
        else {while (k--) ConsPut(s[p++]); p--;}
        p++; x += w;
    }
}

// Classify Cool tokens rather than coloring every identifier as a keyword.
I64 VimTokenColor(I64 p)
{
    I64 a = p, n;
    U8 word[80];
    while (a && VimClass(VimPrev(a)) == 1) a = VimPrev(a);
    p = a;
    while (p < vim_len && VimClass(p) == 1) p = VimStep(p);
    n = p - a;
    if (n > 76) return 37;
    word[0] = '|';
    MemCpy(word + 1, vim_buf + a, n);
    word[n + 1] = '|'; word[n + 2] = 0;
    if (StrMatch(word, "|if|else|for|while|do|switch|case|break|return|goto|class|union|extern|import|public|sizeof|try|catch|throw|")) return 35;
    if (StrMatch(word, "|U0|U8|U16|U32|U64|I8|I16|I32|I64|F64|Bool|TRUE|FALSE|NULL|")) return 36;
    if (vim_buf[a] >= '0' && vim_buf[a] <= '9') return 33;
    return 37;
}

U0 VimDraw()
{
    I64 rows = 24, cols = 80, p, q, y, x, k, w, col, row = 1, line = 1, a = -1, b = -1;
    I64 color, quote, comment, cp, i, token_end = 0, token_color = 37;
    U8 number[32], status[512];
    if (fb.base) {rows = fb.rows; cols = fb.cols;}
    if (rows < 3 || cols < 12) return;
    if (vim_mode >= 3) VimRange(&a, &b);
    if (vim_top > VimLine(vim_pos)) vim_top = VimLine(vim_pos);
    p = vim_top;
    for (y = 1; y < rows - 1; y++) p = VimNextLine(p);
    while (VimLine(vim_pos) > p) {vim_top = VimNextLine(vim_top); p = VimNextLine(p);}
    col = VimCol(vim_pos);
    if (col < vim_left) vim_left = col;
    if (col >= vim_left + cols - 8) vim_left = col - cols + 9;
    for (p = 0; p < vim_top; p++) if (vim_buf[p] == '\n') line++;
    p = vim_top;
    comment = 0;
    // Recover block-comment state even when its opening delimiter scrolled away.
    quote = 0;
    for (i = 0; i < p; i++) {
        if (comment == 2) {if (vim_buf[i] == '*' && vim_buf[i + 1] == '/') {comment = 0; i++;}}
        else if (comment == 1) {if (vim_buf[i] == '\n') comment = 0;}
        else if (quote) {if (vim_buf[i] == '\\') i++; else if (vim_buf[i] == quote) quote = 0;}
        else if (vim_buf[i] == '"' || vim_buf[i] == 39) quote = vim_buf[i];
        else if (vim_buf[i] == '/' && vim_buf[i + 1] == '*') {comment = 2; i++;}
        else if (vim_buf[i] == '/' && vim_buf[i + 1] == '/') comment = 1;
    }
    for (y = 1; y < rows; y++) {
        VimCsi(y, 1); ConsPutS("\x1b[0m\x1b[K");
        if (p > VimLastLine()) {ConsPutS("\x1b[90m~");}
        else {
            if (VimLine(vim_pos) == p) row = y;
            StrPrint(number, "%5d ", line++);
            ConsPutS("\x1b[90m"); ConsPutS(number);
            q = VimEnd(p); x = 0; quote = 0;
            while (p < q) {
                k = VimStep(p) - p; w = VimWidth(p, x);
                cp = Utf8Cp(vim_buf + p, k);
                color = 37;
                if (!comment && !quote && cp == '/' && p + 1 < q) {
                    if (vim_buf[p + 1] == '/') comment = 1;
                    if (vim_buf[p + 1] == '*') comment = 2;
                }
                if (comment) color = 90;
                else if (quote || cp == '"' || cp == 39) color = 32;
                else if (VimClass(p) == 1) {
                    if (p >= token_end) {
                        token_color = VimTokenColor(p); token_end = p;
                        while (token_end < vim_len && VimClass(token_end) == 1) token_end = VimStep(token_end);
                    }
                    color = token_color;
                }
                else if (cp == '#') color = 35;
                if (x >= vim_left && x + w <= vim_left + cols - 7) {
                    ConsPutS("\x1b[0;"); VimPutNum(color);
                    if (p >= a && p < b) ConsPutS(";44");
                    ConsPut('m');
                    if (cp == '\t') {for (i = 0; i < w; i++) ConsPut(' ');}
                    else if (cp < 32 || cp == 127) ConsPut('?');
                    else {for (i = 0; i < k; i++) ConsPut(vim_buf[p + i]);}
                } else if (x < vim_left && x + w > vim_left) ConsPut(' ');
                if (comment == 2 && cp == '/' && p && vim_buf[p - 1] == '*') comment = 0;
                if (!comment) {
                    if (quote && cp == quote && (!p || vim_buf[p - 1] != '\\')) quote = 0;
                    else if (!quote && (cp == '"' || cp == 39)) quote = cp;
                }
                p += k; x += w;
            }
            if (comment == 1) comment = 0;
            p = q + 1;
        }
    }
    VimCsi(rows, 1); ConsPutS("\x1b[0;30;47m\x1b[K");
    if (vim_mode == 2) {
        ConsPut(vim_prompt); VimText(vim_cmd, cols - 2);
        VimCsi(rows, 2 + LineWidth(vim_cmd, 0, vim_cmd_n));
    } else {
        if (vim_mode == 1) StrCpy(status, "INSERT");
        else if (vim_mode == 3) StrCpy(status, "VISUAL");
        else if (vim_mode == 4) StrCpy(status, "VISUAL LINE");
        else StrCpy(status, "NORMAL");
        StrCat(status, " "); StrCat(status, vim_name);
        if (vim_dirty) StrCat(status, " [+]");
        StrCat(status, "  "); StrCat(status, vim_msg);
        VimText(status, cols - 1);
        VimCsi(row, 7 + col - vim_left);
    }
    ConsPutS("\x1b[0m");
}

U0 VimClose()
{
    if (!vim_active) return;
    vim_active = FALSE;
    ConsPutS("\x1b[0m\x1b[?25h\x1b[?1049l");
    Free(vim_buf); Free(vim_saved); Free(vim_yank); Free(vim_hist);
    vim_buf = vim_saved = vim_yank = vim_hist = NULL;
    shell_stmt_cleanup = NULL;
}

Bool VimOpen(U8 *name)
{
    if (vim_active) {Print("Vim is already active\n"); return FALSE;}
    vim_active = TRUE;
    shell_stmt_cleanup = &VimClose;
    vim_buf = CAlloc(VIM_CAP); vim_saved = MAlloc(VIM_CAP);
    vim_yank = MAlloc(VIM_CAP); vim_hist = MAlloc(VIM_CAP * VIM_HIST);
    if (!vim_buf || !vim_saved || !vim_yank || !vim_hist) {VimClose(); Print("Vim: out of memory\n"); return FALSE;}
    vim_mode = vim_count = vim_op = vim_pending = vim_transaction = 0;
    vim_record = vim_kn = vim_dn = vim_replay = vim_yank_len = 0;
    vim_search[0] = 0; vim_search_dir = 1; vim_goal = -1; vim_msg = "";
    if (!VimLoad(name)) {Print("Vim: %s\n", vim_msg); VimClose(); return FALSE;}
    ConsPutS("\x1b[?1049h\x1b[?25h");
    return TRUE;
}

U0 Vim(U8 *name)
{
    if (!VimOpen(name)) return;
    VimDraw();
    while (TRUE) {
        if (VimKey(GetKey())) break;
        if (!KeyPending()) VimDraw();
    }
    VimDraw();
    VimClose();
}
