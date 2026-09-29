// A session belongs to the invoking shell. Tmux() attaches or creates it;
// Ctrl+B d returns to that shell and leaves all pane shells running.
#define TM_WINDOWS 8
#define TM_PANES 16
class CTmPane
{
    CTmPane *parent, *a, *b;
    CVTerm *term;
    I64 x, y, w, h, vertical;
};
class CTmWindow
{
    CTmPane *root, *active;
};
class CTmSession
{
    CTmWindow win[TM_WINDOWS];
    I64 current, panes, cols, rows, redraw;
};
CTmSession *tm_session;

CTmPane *TmLeaf(CTmPane *p)
{
    while (p && p->a) p = p->a;
    return p;
}

U0 TmLayout(CTmPane *p, I64 x, I64 y, I64 w, I64 h)
{
    I64 n;
    p->x = x; p->y = y; p->w = w; p->h = h;
    if (!p->a) VtResize(p->term, w, h);
    else if (p->vertical) {
        n = (w - 1) / 2;
        TmLayout(p->a, x, y, n, h);
        TmLayout(p->b, x + n + 1, y, w - n - 1, h);
    } else {
        n = (h - 1) / 2;
        TmLayout(p->a, x, y, w, n);
        TmLayout(p->b, x, y + n + 1, w, h - n - 1);
    }
}

CTmPane *TmNew(I64 w, I64 h)
{
    CTmPane *p = CAlloc(sizeof(CTmPane));
    CTask *t;
    p->term = VtNew(w, h);
    t = ShellStart;
    VtBind(t, p->term);
    p->term->owner = t;
    tm_session->panes++;
    return p;
}

U0 TmFocus()
{
    vt_focus = tm_session->win[tm_session->current].active->term;
    tm_session->redraw = TRUE;
}

U0 TmWindowNew()
{
    I64 i;
    CTmWindow *w;
    if (tm_session->panes >= TM_PANES) return;
    for (i = 0; i < TM_WINDOWS; i++)
        if (!tm_session->win[i].root) {
            w = &tm_session->win[i];
            w->root = w->active = TmNew(tm_session->cols, tm_session->rows - 1);
            TmLayout(w->root, 0, 0, tm_session->cols, tm_session->rows - 1);
            tm_session->current = i;
            TmFocus;
            return;
        }
}

U0 TmSplit(Bool vertical)
{
    CTmWindow *w = &tm_session->win[tm_session->current];
    CTmPane *p = w->active, *a;
    if (tm_session->panes >= TM_PANES) return;
    if ((vertical && p->w < 21) || (!vertical && p->h < 7)) return;
    a = CAlloc(sizeof(CTmPane));
    a->term = p->term;
    p->term = NULL;
    p->a = a; p->b = TmNew(p->w, p->h);
    p->vertical = vertical;
    p->a->parent = p->b->parent = p;
    TmLayout(p, p->x, p->y, p->w, p->h);
    w->active = p->b;
    TmFocus;
}

CTmPane *TmNext(CTmPane *p)
{
    while (p->parent && p == p->parent->b) p = p->parent;
    if (!p->parent) return TmLeaf(p);
    return TmLeaf(p->parent->b);
}

U0 TmMove(I64 key)
{
    CTmWindow *w = &tm_session->win[tm_session->current];
    CTmPane *p = w->active, *q = TmNext(p), *best = p;
    I64 distance = I64_MAX, d, overlap;
    if (key == 'o') best = q;
    else while (q != p) {
            d = -1;
            if (key == KEY_LEFT || key == KEY_RIGHT) {
                overlap = q->y < p->y + p->h && p->y < q->y + q->h;
                if (overlap && key == KEY_LEFT && q->x < p->x) d = p->x - q->x - q->w;
                if (overlap && key == KEY_RIGHT && q->x > p->x) d = q->x - p->x - p->w;
            } else {
                overlap = q->x < p->x + p->w && p->x < q->x + q->w;
                if (overlap && key == KEY_UP && q->y < p->y) d = p->y - q->y - q->h;
                if (overlap && key == KEY_DOWN && q->y > p->y) d = q->y - p->y - p->h;
            }
            if (d >= 0 && d < distance) {distance = d; best = q;}
            q = TmNext(q);
        }
    w->active = best; TmFocus;
}

U0 TmWindowMove(I64 delta)
{
    I64 i, n = tm_session->current;
    for (i = 0; i < TM_WINDOWS; i++) {
        n = (n + delta + TM_WINDOWS) % TM_WINDOWS;
        if (tm_session->win[n].root) {
            tm_session->current = n; TmFocus; return;
        }
    }
}

U0 TmClose()
{
    CTmWindow *w = &tm_session->win[tm_session->current];
    CTmPane *p = w->active, *parent = p->parent, *sibling, *grand;
    vt_focus = NULL;
    VtStop(p->term);
    VtRelease(p->term);
    tm_session->panes--;
    if (parent) {
        sibling = parent->a;
        if (sibling == p) sibling = parent->b;
        grand = parent->parent;
        sibling->parent = grand;
        if (!grand) w->root = sibling;
        else if (grand->a == parent) grand->a = sibling;
        else grand->b = sibling;
        w->active = TmLeaf(sibling);
        Free(parent);
        TmLayout(w->root, 0, 0, tm_session->cols, tm_session->rows - 1);
        TmFocus;
    } else {
        w->root = w->active = NULL;
        TmWindowMove(1);
    }
    Free(p);
}

Bool TmDirty(CTmPane *p)
{
    if (!p->a) return p->term->dirty;
    return TmDirty(p->a) || TmDirty(p->b);
}
U0 TmDraw(CTmPane *p)
{
    I64 i;
    if (!p->a) VtDraw(p->term, p->x, p->y);
    else {
        TmDraw(p->a); TmDraw(p->b);
        if (p->vertical)
            for (i = 0; i < p->h; i++) Print("\x1b[%d;%dH|", p->y + i + 1, p->b->x);
        else {
            Print("\x1b[%d;%dH", p->b->y, p->x + 1);
            for (i = 0; i < p->w; i++) ConsPut('-');
        }
    }
}
U0 TmRender()
{
    CTmWindow *w = &tm_session->win[tm_session->current];
    CTmPane *p = w->active;
    I64 i, n;
    U8 status[256], tmp[32];
    if (!tm_session->redraw && !TmDirty(w->root)) return;
    TmDraw(w->root);
    StrCpy(status, " tmux");
    for (i = 0; i < TM_WINDOWS; i++)
        if (tm_session->win[i].root) {
            if (i == tm_session->current) StrPrint(tmp, " [%d*]", i + 1);
            else StrPrint(tmp, " %d", i + 1);
            StrCat(status, tmp);
        }
    StrCat(status, "  ^B %/\" split o/arrows move c:new n/p:window x:close d:detach");
    n = MinI64(StrLen(status), tm_session->cols);
    status[n] = 0;
    Print("\x1b[%d;1H\x1b[37;44m\x1b[K%s\x1b[0m", tm_session->rows, status);
    Print("\x1b[%d;%dH", p->y + p->term->cy + 1, p->x + MinI64(p->term->cx, p->w - 1) + 1);
    tm_session->redraw = FALSE;
}

U0 Tmux()
{
    I64 key, prefix = FALSE, paint_at = 0;
    CVTerm *old_focus = vt_focus;
    if (!tm_session) {
        tm_session = CAlloc(sizeof(CTmSession));
        tm_session->cols = 80; tm_session->rows = 24;
        if (VtCurrent) {tm_session->cols = VtCurrent->cols; tm_session->rows = VtCurrent->rows;}
        else if (fb.base) {tm_session->cols = fb.cols; tm_session->rows = fb.rows;}
        TmWindowNew;
    }
    ConsPutS("\x1b[?1049h");
    TmFocus;
    while (tm_session->panes) {
        // Batch bursts of input/output instead of repainting the entire
        // screen for every byte typed into an editor or shell command.
        if (tm_session->redraw || jiffies >= paint_at) {
            TmRender;
            paint_at = jiffies + JIFFY_FREQ / 30;
        }
        key = KeyPop;
        if (!key) {Sleep(10); goto tm_again;}
        if (prefix) {
            prefix = FALSE;
            if (key == 'd') break;
            if (key == '%') TmSplit(TRUE);
            else if (key == '"') TmSplit(FALSE);
            else if (key == 'c') TmWindowNew;
            else if (key == 'n') TmWindowMove(1);
            else if (key == 'p') TmWindowMove(-1);
            else if (key == 'x') TmClose;
            else if (key == 'o' || (key >= KEY_UP && key <= KEY_RIGHT)) TmMove(key);
            else if (key == (KF_CTRL | 'b')) VtKeyPush(tm_session->win[tm_session->current].active->term, key);
        } else if (key == (KF_CTRL | 'b')) prefix = TRUE;
        else VtKeyPush(tm_session->win[tm_session->current].active->term, key);
        Yield;
tm_again:
    }
    if (!tm_session->panes) {Free(tm_session); tm_session = NULL;}
    vt_focus = old_focus;
    ConsPutS("\x1b[?1049l");
}
