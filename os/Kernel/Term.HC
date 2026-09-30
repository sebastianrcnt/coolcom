extern U0 ConsPutCp(I64 cp);
// Task-bound ANSI terminals. Shells run cooperatively on core 0; inherited
// terminal references and cell/input locks also support worker tasks on other cores.
// Screen cells are independent of the physical framebuffer and UART.
// A cell color is an Ansi.HC color: 0..15 the ANSI colors, 16..255 the xterm palette,
// ANSI_RGB_FLAG | 0xRRGGBB a 24-bit color.
class CVtCell
{
    I64 cp, fg, bg, width;
};
class CVTerm
{
    I64 cols, rows, cx, cy, fg, bg, bold;
    I64 esc, csi_n, csi_val[16], csi_private, u8_left, u8_cp;
    I64 saved_cx, saved_cy, saved_fg, saved_bg, saved_bold, alternate;
    I64 sv_cx, sv_cy, sv_fg, sv_bg, sv_bold; // ESC 7 / CSI s
    Bool sv_reverse;
    Bool reverse, saved_reverse;
    CVtCell *cells, *saved;
    I64 keys[256], head, tail;
    I64 dirty, refs, lock;
    Bool direct, closed;
    CTask *owner;
    U8 *sink;       // optional U0 (*)(CVTerm *v, U8 c): sees every output byte, called under v->lock (NetShell.HC)
    U8 *sink_data;
};
CVTerm *vt_focus;

CVTerm *VtCurrent() {return Fs->terminal;}

U0 VtBlank(CVTerm *v, I64 col, I64 row)
{
    CVtCell *p;
    if (col < 0 || col >= v->cols || row < 0 || row >= v->rows) return;
    p = &v->cells[row * v->cols + col];
    p->cp = ' '; p->width = 1; p->fg = v->fg; p->bg = v->bg;
    if (v->reverse) {p->fg = v->bg; p->bg = v->fg;}
}
U0 VtErase(CVTerm *v, I64 x1, I64 y1, I64 x2, I64 y2)
{
    I64 x, y;
    for (y = y1; y <= y2; y++)
        for (x = x1; x <= x2; x++) VtBlank(v, x, y);
}
U0 VtClear(CVTerm *v)
{
    VtErase(v, 0, 0, v->cols - 1, v->rows - 1);
    v->cx = v->cy = 0;
}
U0 VtScroll(CVTerm *v)
{
    MemCpy(v->cells, v->cells + v->cols, (v->rows - 1) * v->cols * sizeof(CVtCell));
    VtErase(v, 0, v->rows - 1, v->cols - 1, v->rows - 1);
    v->cy = v->rows - 1;
}
U0 VtPutCp(CVTerm *v, I64 cp)
{
    I64 w = Utf8Width(cp), i, j;
    CVtCell *p;
    if (!w) return;
    if (w > v->cols) {cp = '?'; w = 1;}
    if (v->cx + w > v->cols) {
        v->cx = 0; v->cy++;
        if (v->cy >= v->rows) VtScroll(v);
    }
    i = v->cy * v->cols + v->cx;
    if (v->cx && !v->cells[i].width) VtBlank(v, v->cx - 1, v->cy);
    for (j = 0; j < w; j++)
        if (v->cells[i + j].width == 2 && j + 1 >= w)
            VtBlank(v, v->cx + j + 1, v->cy);
    p = &v->cells[i];
    p->cp = cp; p->fg = v->fg; p->bg = v->bg; p->width = w;
    if (v->reverse) {p->fg = v->bg; p->bg = v->fg;}
    if (w == 2) {
        VtBlank(v, v->cx + 1, v->cy);
        v->cells[i + 1].width = 0;
    }
    v->cx += w;
}
I64 VtParam(CVTerm *v, I64 i, I64 def)
{
    if (i > v->csi_n || !v->csi_val[i]) return def;
    return v->csi_val[i];
}
U0 VtAlt(CVTerm *v, Bool on)
{
    CVtCell *p;
    if (on && !v->alternate) {
        p = v->cells; v->cells = v->saved; v->saved = p;
        v->saved_cx = v->cx; v->saved_cy = v->cy;
        v->saved_fg = v->fg; v->saved_bg = v->bg;
        v->saved_bold = v->bold; v->saved_reverse = v->reverse;
        v->alternate = TRUE; VtClear(v);
    } else if (!on && v->alternate) {
        p = v->cells; v->cells = v->saved; v->saved = p;
        v->cx = v->saved_cx; v->cy = v->saved_cy;
        v->fg = v->saved_fg; v->bg = v->saved_bg;
        v->bold = v->saved_bold; v->reverse = v->saved_reverse;
        v->alternate = FALSE;
    }
}
U0 VtCsi(CVTerm *v, U8 c)
{
    I64 i, n = v->csi_val[0], x, y;
    if (v->csi_private) {
        if ((c == 'h' || c == 'l') && (n == 1049 || n == 47))
            VtAlt(v, c == 'h');
        return;
    }
    switch (c) {
        case 'm':
            for (i = 0; i <= v->csi_n; i++) {
                n = v->csi_val[i];
                if (!n) {v->fg = 15; v->bg = 0; v->bold = FALSE; v->reverse = FALSE;}
                else if (n == 1) v->bold = TRUE;
                else if (n == 7) v->reverse = TRUE;
                else if (n == 27) v->reverse = FALSE;
                else if (n == 22) v->bold = FALSE;
                else if (n == 39) v->fg = 15;
                else if (n == 49) v->bg = 0;
                else if (n >= 30 && n <= 37) v->fg = (n - 30 + 8 * v->bold);
                else if (n >= 40 && n <= 47) v->bg = (n - 40);
                else if (n >= 90 && n <= 97) v->fg = (n - 90 + 8);
                else if (n >= 100 && n <= 107) v->bg = (n - 100 + 8);
                else if (n == 38 || n == 48) {
                    // 38;5;N (palette) or 38;2;R;G;B (24-bit); 48 is the background.
                    if (i + 2 <= v->csi_n && v->csi_val[i + 1] == 5) {
                        x = v->csi_val[i + 2] & 255;
                        i += 2;
                    } else if (i + 4 <= v->csi_n && v->csi_val[i + 1] == 2) {
                        x = ANSI_RGB_FLAG | ((v->csi_val[i + 2] & 255) << 16) | ((v->csi_val[i + 3] & 255) << 8) | (v->csi_val[i + 4] & 255);
                        i += 4;
                    } else break;
                    if (n == 38) v->fg = x;
                    else v->bg = x;
                }
            }
            break;
        case 's':
            v->sv_cx = v->cx; v->sv_cy = v->cy; v->sv_fg = v->fg; v->sv_bg = v->bg;
            v->sv_bold = v->bold; v->sv_reverse = v->reverse;
            break;
        case 'u':
            v->cx = v->sv_cx; v->cy = v->sv_cy; v->fg = v->sv_fg; v->bg = v->sv_bg;
            v->bold = v->sv_bold; v->reverse = v->sv_reverse;
            break;
        case 'H': case 'f':
            v->cy = VtParam(v, 0, 1) - 1;
            v->cx = VtParam(v, 1, 1) - 1;
            break;
        case 'A': v->cy -= VtParam(v, 0, 1); break;
        case 'B': v->cy += VtParam(v, 0, 1); break;
        case 'C': v->cx += VtParam(v, 0, 1); break;
        case 'D': v->cx -= VtParam(v, 0, 1); break;
        case 'G': v->cx = VtParam(v, 0, 1) - 1; break;
        case 'd': v->cy = VtParam(v, 0, 1) - 1; break;
        case 'J':
            if (n == 2 || n == 3) VtErase(v, 0, 0, v->cols - 1, v->rows - 1);
            else if (n == 0) {
                VtErase(v, v->cx, v->cy, v->cols - 1, v->cy);
                for (y = v->cy + 1; y < v->rows; y++) VtErase(v, 0, y, v->cols - 1, y);
            } else if (n == 1) {
                for (y = 0; y < v->cy; y++) VtErase(v, 0, y, v->cols - 1, y);
                VtErase(v, 0, v->cy, v->cx, v->cy);
            }
            break;
        case 'K':
            x = v->cx;
            y = v->cols - 1;
            if (n == 1) {x = 0; y = v->cx;}
            else if (n == 2) x = 0;
            VtErase(v, x, v->cy, y, v->cy);
            break;
    }
    if (v->cx < 0) v->cx = 0;
    if (v->cx >= v->cols) v->cx = v->cols - 1;
    if (v->cy < 0) v->cy = 0;
    if (v->cy >= v->rows) v->cy = v->rows - 1;
}

U0 VtPut(CVTerm *v, U8 c)
{//Console output: \n \r \b \t are handled, other control codes are ignored. UTF-8 is decoded;
    //a character takes Utf8Width columns, like on a terminal, so \b (one column) matches the
    //shell's line editing, which backs up by columns.
    if (v->esc == 1) {
        v->esc = 0;
        if (c == '[') {
            v->esc = 2;
            v->csi_n = v->csi_private = 0;
            MemSet(v->csi_val, 0, 16 * sizeof(I64));
        } else if (c == '7') {
            v->csi_n = v->csi_private = 0; VtCsi(v, 's');
        } else if (c == '8') {
            v->csi_n = v->csi_private = 0; VtCsi(v, 'u');
        }
        return;
    }
    if (v->esc == 2) {
        if (c == '?' && !v->csi_n && !v->csi_val[0]) v->csi_private = TRUE;
        else if (c >= '0' && c <= '9') v->csi_val[v->csi_n] = v->csi_val[v->csi_n] * 10 + c - '0';
        else if (c == ';' && v->csi_n < 15) v->csi_n++;
        else {v->esc = 0; VtCsi(v, c);}
        return;
    }
    if (c == 27) {v->esc = 1; v->u8_left = 0; return;}
    if (c >= 0x80) {
        if (Utf8Len(c) > 1) {
            v->u8_left = Utf8Len(c) - 1;
            v->u8_cp = c & (0x7F >> Utf8Len(c));
        } else if (v->u8_left > 0) {
            v->u8_cp = (v->u8_cp << 6) | (c & 0x3F);
            if (!--v->u8_left)
                VtPutCp(v, v->u8_cp);
        }
        return;
    }
    v->u8_left = 0;
    if (c == '\n') {
        v->cx = 0;
        v->cy++;
    } else if (c == '\r')
        v->cx = 0;
    else if (c == 8) {
        if (v->cx > 0)
            v->cx--;
    } else if (c == '\t')
        v->cx = (v->cx + 8) & ~7;
    else if (c >= 32 && c < 127)
        VtPutCp(v, c);
    if (v->cy >= v->rows)
        VtScroll(v);
}

Bool VtOutput(U8 c)
{
    CVTerm *v = VtCurrent;
    I64 daif;
    U0 (*sink)(CVTerm *v, U8 c);
    if (!v) return FALSE;
    daif = SpinLockIrq(&v->lock);
    VtPut(v, c); v->dirty = TRUE;
    if (sink = v->sink) (*sink)(v, c);
    SpinUnlockIrq(&v->lock, daif);
    return !v->direct;
}
CVTerm *VtNew(I64 cols, I64 rows)
{
    CVTerm *v = CAlloc(sizeof(CVTerm));
    v->cols = cols; v->rows = rows; v->fg = 15; v->refs = 1;
    v->cells = CAlloc(cols * rows * sizeof(CVtCell));
    v->saved = CAlloc(cols * rows * sizeof(CVtCell));
    VtClear(v); v->dirty = TRUE;
    cons_route = &VtOutput;
    return v;
}
U0 VtRelease(CVTerm *v)
{
    if (v && !ArchAdd(&v->refs, -1)) {
        Free(v->cells); Free(v->saved); Free(v);
    }
}
U0 VtBind(CTask *t, CVTerm *v)
{
    if (v) ArchAdd(&v->refs, 1);
    VtRelease(t->terminal);
    t->terminal = v;
}
U0 VtResize(CVTerm *v, I64 cols, I64 rows)
{
    CVtCell *old = v->cells, *saved = v->saved;
    I64 daif = SpinLockIrq(&v->lock);
    I64 x, y, oc = v->cols, orows = v->rows;
    if (cols == oc && rows == orows) {SpinUnlockIrq(&v->lock, daif); return;}
    v->cells = CAlloc(cols * rows * sizeof(CVtCell));
    v->saved = CAlloc(cols * rows * sizeof(CVtCell));
    v->cols = cols; v->rows = rows;
    VtErase(v, 0, 0, cols - 1, rows - 1);
    MemCpy(v->saved, v->cells, cols * rows * sizeof(CVtCell));
    for (y = 0; y < rows && y < orows; y++)
        for (x = 0; x < cols && x < oc; x++) {
            MemCpy(&v->cells[y * cols + x], &old[y * oc + x], sizeof(CVtCell));
            MemCpy(&v->saved[y * cols + x], &saved[y * oc + x], sizeof(CVtCell));
            if (x == cols - 1) {
                if (v->cells[y * cols + x].width == 2) VtBlank(v, x, y);
                if (v->saved[y * cols + x].width == 2) {
                    v->saved[y * cols + x].cp = ' ';
                    v->saved[y * cols + x].width = 1;
                }
            }
        }
    if (v->cx >= cols) v->cx = cols - 1;
    if (v->cy >= rows) v->cy = rows - 1;
    if (v->saved_cx >= cols) v->saved_cx = cols - 1;
    if (v->saved_cy >= rows) v->saved_cy = rows - 1;
    Free(old); Free(saved); v->dirty = TRUE;
    SpinUnlockIrq(&v->lock, daif);
}
Bool VtKeyPush(CVTerm *v, I64 key)
{
    I64 daif = SpinLockIrq(&v->lock), next = (v->tail + 1) % 256;
    if (next == v->head || v->closed) {SpinUnlockIrq(&v->lock, daif); return FALSE;}
    v->keys[v->tail] = key; v->tail = next;
    SpinUnlockIrq(&v->lock, daif);
    return TRUE;
}
I64 VtKeyPop()
{
    CVTerm *v = VtCurrent;
    I64 key = 0, daif = SpinLockIrq(&v->lock);
    if (v->head != v->tail) {
        key = v->keys[v->head]; v->head = (v->head + 1) % 256;
    }
    SpinUnlockIrq(&v->lock, daif);
    return key;
}
// Drawing goes through the caller's console, so a nested Tmux composes into
// its parent terminal too. SGR is reset at every row boundary.
U0 VtDraw(CVTerm *v, I64 left, I64 top)
{
    I64 x, y, fg = -1, bg = -1;
    U8 sgr[96];
    CVtCell *p;
    CVTerm snapshot;
    I64 daif = SpinLockIrq(&v->lock);
    // Never hold the terminal lock while Print acquires print_lock: a worker
    // on another core may already hold print_lock while writing this terminal.
    MemCpy(&snapshot, v, sizeof(CVTerm));
    snapshot.cells = MAlloc(v->cols * v->rows * sizeof(CVtCell));
    MemCpy(snapshot.cells, v->cells, v->cols * v->rows * sizeof(CVtCell));
    v->dirty = FALSE;
    SpinUnlockIrq(&v->lock, daif);
    v = &snapshot;
    for (y = 0; y < v->rows; y++) {
        Print("\x1b[%d;%dH", top + y + 1, left + 1);
        for (x = 0; x < v->cols; x++) {
            p = &v->cells[y * v->cols + x];
            if (p->width) {
                if (p->fg != fg || p->bg != bg) {
                    fg = p->fg; bg = p->bg;
                    AnsiSetS(sgr, fg, bg);
                    ConsPutS(sgr);
                }
                ConsPutCp(p->cp);
            }
        }
    }
    ConsPutS("\x1b[0m");
    Free(snapshot.cells);
}

U0 VtTaskGone(CTask *t)
{
    CVTerm *v = t->terminal;
    I64 daif;
    if (!v) return;
    daif = SpinLockIrq(&v->lock);
    if (v->owner == t) v->owner = NULL;
    SpinUnlockIrq(&v->lock, daif);
    VtRelease(v);
}
U0 VtStop(CVTerm *v)
{//Close the terminal's process group, including inherited worker tasks.
    I64 i, daif;
    CCPU *c;
    CTask *t;
    v->closed = TRUE;
    for (i = 0; i < mp_cnt; i++) {
        c = &cpu_structs[i];
        daif = SpinLockIrq(&c->lock);
        t = c->seth_task->next_task;
        while (t != c->seth_task) {
            if (t->terminal == v) {
                LBts(&t->task_flags, TASKf_KILL_TASK);
                t->wake_jiffy = 0;
            }
            t = t->next_task;
        }
        SpinUnlockIrq(&c->lock, daif);
    }
}

Bool AnsiTermSize(I64 *rows, I64 *cols)
{//The size of the current task's terminal. FALSE (and 24x80) if it has none, e.g. UART only.
    if (VtCurrent) {
        *rows = VtCurrent->rows;
        *cols = VtCurrent->cols;
        return TRUE;
    }
    if (fb.base) {
        *rows = fb.rows;
        *cols = fb.cols;
        return TRUE;
    }
    *rows = 24;
    *cols = 80;
    return FALSE;
}
