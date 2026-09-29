// Small modal UTF-8 editor for the Cool shell. Load through C:/Init.HC.
#define VIM_CAP 131072
U8 *vim_buf, *vim_undo, *vim_yank;
I64 vim_len, vim_pos, vim_top, vim_mode, vim_dirty, vim_undo_len, vim_undo_pos;
I64 vim_yank_len, vim_yank_line, vim_have_undo, vim_cmd_n;
U8 vim_cmd[80];
U8 *vim_name;

I64 VimStep(I64 p)
{
    I64 k;
    if (p >= vim_len) return vim_len;
    k = Utf8Len(vim_buf[p]);
    if (k < 1 || p + k > vim_len) k = 1;
    return p + k;
}

I64 VimPrev(I64 p)
{
    if (p) p--;
    while (p && (vim_buf[p] & 0xC0) == 0x80) p--;
    return p;
}

I64 VimLine(I64 p)
{
    while (p && vim_buf[p - 1] != '\n') p--;
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

I64 VimCol(I64 p)
{
    I64 a = VimLine(p), w = 0, k;
    while (a < p) {
        k = VimStep(a) - a;
        w += Utf8Width(Utf8Cp(vim_buf + a, k));
        a += k;
    }
    return w;
}

I64 VimAtCol(I64 p, I64 col)
{
    I64 end = VimEnd(p), w = 0, k, cw;
    while (p < end) {
        k = VimStep(p) - p;
        cw = Utf8Width(Utf8Cp(vim_buf + p, k));
        if (w + cw > col) break;
        w += cw;
        p += k;
    }
    return p;
}

U0 VimSnapshot()
{
    MemCpy(vim_undo, vim_buf, vim_len);
    vim_undo_len = vim_len;
    vim_undo_pos = vim_pos;
    vim_have_undo = TRUE;
}

U0 VimInsert(U8 *s, I64 n)
{
    if (n <= 0 || vim_len + n >= VIM_CAP) return;
    MemCpy(vim_buf + vim_pos + n, vim_buf + vim_pos, vim_len - vim_pos + 1);
    MemCpy(vim_buf + vim_pos, s, n);
    vim_pos += n;
    vim_len += n;
    vim_dirty = TRUE;
}

U0 VimDelete(I64 a, I64 b)
{
    if (a < 0 || b > vim_len || a >= b) return;
    MemCpy(vim_buf + a, vim_buf + b, vim_len - b + 1);
    vim_len -= b - a;
    vim_pos = a;
    vim_dirty = TRUE;
}

U0 VimMoveLine(I64 dir)
{
    I64 col = VimCol(vim_pos), p = VimLine(vim_pos);
    if (dir < 0) {
        if (p) p = VimLine(p - 1);
    } else p = VimNextLine(p);
    vim_pos = VimAtCol(p, col);
}

U0 VimWord(I64 dir)
{
    I64 p = vim_pos;
    if (dir > 0) {
        if (p < vim_len) p = VimStep(p);
        while (p < vim_len && vim_buf[p] != '\n' && vim_buf[p] != ' ' && vim_buf[p] != '\t') p = VimStep(p);
        while (p < vim_len && (vim_buf[p] == ' ' || vim_buf[p] == '\t' || vim_buf[p] == '\n')) p++;
    } else {
        if (p) p = VimPrev(p);
        while (p && (vim_buf[p] == ' ' || vim_buf[p] == '\t' || vim_buf[p] == '\n')) p = VimPrev(p);
        while (p && vim_buf[VimPrev(p)] != ' ' && vim_buf[VimPrev(p)] != '\t' && vim_buf[VimPrev(p)] != '\n') p = VimPrev(p);
    }
    vim_pos = p;
}

U0 VimPutNum(I64 n)
{
    U8 b[32];
    StrPrint(b, "%d", n);
    ConsPutS(b);
}

U0 VimCsi(I64 row, I64 col)
{
    ConsPutS("\x1b[");
    VimPutNum(row);
    ConsPut(';');
    VimPutNum(col);
    ConsPut('H');
}

U0 VimDraw()
{
    I64 rows = 24, cols = 80, p, q, y, x, k, cw, cursor_row = 1, line = 1;
    if (fb.base) {rows = fb.rows; cols = fb.cols;}
    if (rows < 3) rows = 3;
    if (cols < 2) cols = 2;
    while (vim_pos < vim_top) vim_top = VimLine(vim_pos);
    p = vim_top;
    for (y = 1; y < rows; y++) {
        if (p <= vim_pos && vim_pos <= VimEnd(p)) cursor_row = y;
        if (p >= vim_len && y > 1) break;
        p = VimNextLine(p);
        if (p == vim_len && (p == 0 || vim_buf[p - 1] != '\n')) break;
    }
    if (y >= rows && vim_pos >= p) vim_top = VimLine(vim_pos);
    ConsPutS("\x1b[H");
    p = vim_top;
    for (y = 1; y < rows; y++) {
        VimCsi(y, 1);
        ConsPutS("\x1b[K");
        if (p > vim_len) ConsPut('~');
        else {
            q = VimEnd(p);
            x = 0;
            while (p < q && x < cols) {
                k = VimStep(p) - p;
                cw = Utf8Width(Utf8Cp(vim_buf + p, k));
                if (x + cw > cols) break;
                while (k--) ConsPut(vim_buf[p++]);
                x += cw;
            }
            if (q >= vim_len) p = vim_len + 1;
            else p = q + 1;
        }
    }
    VimCsi(rows, 1);
    ConsPutS("\x1b[7m");
    if (vim_mode == 1) ConsPutS("-- INSERT -- ");
    else if (vim_mode == 2) {ConsPut(':'); ConsPutS(vim_cmd);}
    else ConsPutS("-- NORMAL -- ");
    ConsPutS(vim_name);
    if (vim_dirty) ConsPutS(" [+]");
    ConsPutS("\x1b[0m\x1b[K");
    p = vim_top;
    cursor_row = 1;
    while (p < VimLine(vim_pos) && cursor_row < rows - 1) {
        p = VimNextLine(p);
        cursor_row++;
    }
    VimCsi(cursor_row, 1 + VimCol(vim_pos));
}

Bool VimCommand(U8 *cmd)
{
    if (!StrCmp(cmd, "w") || !StrCmp(cmd, "wq")) {
        if (!FileWrite(vim_name, vim_buf, vim_len)) {
            ConsPutS("\x1b[24;1Hwrite failed");
            return FALSE;
        }
        vim_dirty = FALSE;
    }
    if (!StrCmp(cmd, "q") && vim_dirty) return FALSE;
    return !StrCmp(cmd, "q") || !StrCmp(cmd, "q!") || !StrCmp(cmd, "wq");
}

U0 Vim(U8 *name)
{
    I64 n = 0, c, sc, a, b, g = 0, pending = 0;
    U8 *file, ch;
    vim_name = name;
    vim_buf = CAlloc(VIM_CAP);
    vim_undo = MAlloc(VIM_CAP);
    vim_yank = MAlloc(VIM_CAP);
    file = NULL;
    if (FileFind(name)) file = FileRead(name, &n);
    if (file && n < VIM_CAP) MemCpy(vim_buf, file, n);
    else n = 0;
    if (file) Free(file);
    vim_len = n;
    vim_pos = vim_top = vim_mode = vim_dirty = vim_have_undo = vim_yank_len = 0;
    ConsPutS("\x1b[?1049h\x1b[?25h");
    while (TRUE) {
        VimDraw;
        c = GetKey(&sc, FALSE);
        if (vim_mode == 2) {
            if (c == 27) vim_mode = 0;
            else if (c == '\n' || c == '\r') {
                vim_cmd[vim_cmd_n] = 0;
                if (VimCommand(vim_cmd)) break;
                vim_mode = 0;
            } else if (c == 8 || c == 127) {
                if (vim_cmd_n) vim_cmd[--vim_cmd_n] = 0;
                else vim_mode = 0;
            } else if (c >= 32 && vim_cmd_n < 78) {vim_cmd[vim_cmd_n++] = c; vim_cmd[vim_cmd_n] = 0;}
        } else if (vim_mode == 1) {
            if (c == 27) {vim_mode = 0; if (vim_pos) vim_pos = VimPrev(vim_pos);}
            else if (c == 8 || c == 127) {if (vim_pos) VimDelete(VimPrev(vim_pos), vim_pos);}
            else if (c == '\n' || c >= 32) {ch = c; VimInsert(&ch, 1);}
        } else {
            if (sc == SC_LEFT) c = 'h';
            if (sc == SC_RIGHT) c = 'l';
            if (sc == SC_UP) c = 'k';
            if (sc == SC_DOWN) c = 'j';
            if (pending == 'd' || pending == 'y') {
                if (c == pending) {
                    a = VimLine(vim_pos);
                    b = VimNextLine(a);
                    if (b == a) b = vim_len;
                    vim_yank_len = b - a;
                    MemCpy(vim_yank, vim_buf + a, vim_yank_len);
                    vim_yank_line = TRUE;
                    if (c == 'd') {VimSnapshot; VimDelete(a, b);}
                }
                pending = 0;
            } else if (c == 'g') {if (g) vim_pos = 0; g = !g;}
            else {
                g = 0;
                switch (c) {
                    case 'h': if (vim_pos > VimLine(vim_pos)) vim_pos = VimPrev(vim_pos); break;
                    case 'l': if (vim_pos < VimEnd(vim_pos)) vim_pos = VimStep(vim_pos); break;
                    case 'j': VimMoveLine(1); break;
                    case 'k': VimMoveLine(-1); break;
                    case 'w': VimWord(1); break;
                    case 'b': VimWord(-1); break;
                    case '0': vim_pos = VimLine(vim_pos); break;
                    case '$': vim_pos = VimEnd(vim_pos); break;
                    case 'G': vim_pos = VimLine(vim_len); break;
                    case 'i': VimSnapshot; vim_mode = 1; break;
                    case 'a': VimSnapshot; if (vim_pos < VimEnd(vim_pos)) vim_pos = VimStep(vim_pos); vim_mode = 1; break;
                    case 'o': VimSnapshot; vim_pos = VimEnd(vim_pos); ch = '\n'; VimInsert(&ch, 1); vim_mode = 1; break;
                    case 'x': VimSnapshot; VimDelete(vim_pos, VimStep(vim_pos)); break;
                    case 'd': case 'y': pending = c; break;
                    case 'p':
                        if (vim_yank_len) {
                            VimSnapshot;
                            if (vim_yank_line) vim_pos = VimNextLine(vim_pos);
                            else vim_pos = VimStep(vim_pos);
                            VimInsert(vim_yank, vim_yank_len);
                        }
                        break;
                    case 'u':
                        if (vim_have_undo) {
                            MemCpy(vim_buf, vim_undo, vim_undo_len);
                            vim_len = vim_undo_len;
                            vim_buf[vim_len] = 0;
                            vim_pos = vim_undo_pos;
                            vim_dirty = TRUE;
                            vim_have_undo = FALSE;
                        }
                        break;
                    case ':': vim_mode = 2; vim_cmd_n = 0; vim_cmd[0] = 0; break;
                }
            }
        }
    }
    ConsPutS("\x1b[?1049l");
    Free(vim_buf);
    Free(vim_undo);
    Free(vim_yank);
}
