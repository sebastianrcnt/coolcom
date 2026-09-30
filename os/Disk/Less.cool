// Less("file"): a pager on the alternate screen. Long lines wrap by terminal columns
// (UTF-8, Hangul and CJK two columns wide). Keys:
//   Space f PgDn  page down        b PgUp   page up      d u  half page down / up
//   Enter j Down  line down        k Up     line up      g Home  top    G End  bottom
//   /text  search forward          ?text  search backward   n N  next / previous match
//   q  quit
// The file is read whole, the position is a byte offset of a screen row's start.
U8 *less_buf, *less_pat, *less_name;
I64 less_size, less_top, less_rows, less_cols, less_patn, less_active;

U0 LessClose()
{
    if (!less_active) return;
    less_active = FALSE;
    AnsiReset;
    AnsiCursorShow;
    AnsiAltScreen(FALSE);
    Free(less_buf);
    Free(less_pat);
    less_buf = less_pat = NULL;
    shell_stmt_cleanup = NULL;
}

I64 LessWidth(I64 p, I64 x, I64 *_k)
{//Columns of the character at p when it starts in column x; its bytes in *_k. Tabs go to
    //multiples of 8, a CR takes none, other control characters show as ? in one column.
    I64 k = Utf8Len(less_buf[p]), cp, i;
    if (k < 1 || p + k > less_size) k = 1;
    for (i = 1; i < k; i++)
        if ((less_buf[p + i] & 0xC0) != 0x80) {k = 1; break;}
    *_k = k;
    cp = less_buf[p];
    if (k > 1) cp = Utf8Cp(less_buf + p, k);
    if (cp == '\t') return 8 - (x & 7);
    if (cp == '\r') return 0;
    if (cp < 32 || cp == 127) return 1;
    return Utf8Width(cp);
}

I64 LessRow(I64 pos, I64 *_next)
{//The screen row that starts at pos: returns the end of its text, *_next is where the next row starts.
    I64 p = pos, x = 0, w, k;
    while (p < less_size && less_buf[p] != '\n') {
        w = LessWidth(p, x, &k);
        if (x + w > less_cols && p > pos) break;
        x += w;
        p += k;
    }
    if (p < less_size && less_buf[p] == '\n') *_next = p + 1;
    else *_next = p;
    return p;
}

I64 LessNextRow(I64 pos)
{
    I64 next;
    LessRow(pos, &next);
    return next;
}

I64 LessPrevRow(I64 pos)
{//Start of the row before pos.
    I64 ls, next;
    if (pos <= 0) return 0;
    ls = pos - 1;  // a byte of the previous row: find its line's start, then walk the rows
    while (ls > 0 && less_buf[ls - 1] != '\n') ls--;
    while (TRUE) {
        LessRow(ls, &next);
        if (next >= pos) return ls;
        ls = next;
    }
}

I64 LessRowOf(I64 m)
{//Start of the row that holds offset m.
    I64 ls = m, next;
    while (ls > 0 && less_buf[ls - 1] != '\n') ls--;
    while (TRUE) {
        LessRow(ls, &next);
        if (next > m || next >= less_size) return ls;
        ls = next;
    }
}

I64 LessMaxTop()
{//The first row of the last full page.
    I64 top, i;
    if (!less_size) return 0;
    top = LessRowOf(less_size - 1);
    for (i = 1; i < less_rows - 1; i++)
        if (top > 0) top = LessPrevRow(top);
    return top;
}

U0 LessDrawRow(I64 pos, I64 end)
{//Draw the row [pos, end), the search matches in reverse video.
    I64 p = pos, x = 0, w, k, i, mend = -1, next_m = -1;
    if (less_patn) next_m = TextFind(less_buf, pos, end, less_pat, less_patn);
    while (p < end) {
        if (mend < 0 && p == next_m) {
            AnsiReverse;
            mend = p + less_patn;
        } else if (mend >= 0 && p >= mend) {
            AnsiReset;
            mend = -1;
            next_m = TextFind(less_buf, p, end, less_pat, less_patn);
            if (p == next_m) {
                AnsiReverse;
                mend = p + less_patn;
            }
        }
        w = LessWidth(p, x, &k);
        if (less_buf[p] == '\t') {for (i = 0; i < w; i++) ConsPut(' ');}
        else if (less_buf[p] == '\r') {}
        else if (k == 1 && (less_buf[p] < 32 || less_buf[p] == 127)) ConsPut('?');
        else {for (i = 0; i < k; i++) ConsPut(less_buf[p + i]);}
        x += w;
        p += k;
    }
    if (mend >= 0) AnsiReset;
}

U0 LessDraw(U8 *prompt)
{
    I64 y, p = less_top, end, next, pct;
    U8 status[256];
    for (y = 0; y < less_rows - 1; y++) {
        AnsiCursor(y + 1, 1);
        AnsiClearEol;
        if (p < less_size || (y == 0 && !less_size)) {
            end = LessRow(p, &next);
            LessDrawRow(p, end);
            p = next;
        } else {
            AnsiFg(ANSI_GRAY);
            ConsPut('~');
            AnsiReset;
        }
    }
    pct = 100;
    if (p < less_size) pct = p * 100 / less_size;
    AnsiCursor(less_rows, 1);
    AnsiSet(ANSI_BLACK, ANSI_WHITE);
    AnsiClearEol;
    if (prompt) Print("%s", prompt);
    else {
        StrPrint(status, "%s  %d%%  (q quit, space/b page, /? search)", less_name, pct);
        TextPutLine(status, StrLen(status), less_cols - 1);
    }
    AnsiReset;
}

Bool LessSearch(U8 *pat, Bool forward)
{//Move to the next (or previous) match; FALSE if there is none.
    I64 n = StrLen(pat), m;
    if (!n) return FALSE;
    if (forward) {
        m = TextFind(less_buf, LessNextRow(less_top), less_size, pat, n);
        if (m < 0) m = TextFind(less_buf, 0, LessNextRow(less_top), pat, n);
    } else {
        m = TextFindBack(less_buf, 0, less_top, pat, n);
        if (m < 0) m = TextFindBack(less_buf, less_top, less_size, pat, n);
    }
    if (m < 0) return FALSE;
    less_top = LessRowOf(m);
    return TRUE;
}

U0 Less(U8 *name, I64 line = 1)
{//line: start with that line at the top.
    I64 ev, c, max_top, i, n, half, p;
    U8 prompt[256], pat[128];
    I64 dir;
    if (less_active) {Print("Less is already active\n"); return;}
    less_size = TextRead(name, &less_buf);
    if (less_size < 0) return;
    less_name = name;
    less_pat = CAlloc(128);
    less_patn = 0;
    less_top = 0;
    AnsiTermSize(&less_rows, &less_cols);
    p = 0;
    for (i = 1; i < line; i++) {
        while (p < less_size && less_buf[p] != '\n') p++;
        if (p >= less_size) break;
        p++;
    }
    if (p < less_size) less_top = LessRowOf(p);
    less_active = TRUE;
    shell_stmt_cleanup = &LessClose;
    AnsiAltScreen(TRUE);
    AnsiCursorHide;
    while (TRUE) {
        AnsiTermSize(&less_rows, &less_cols);
        max_top = LessMaxTop;
        if (less_top > max_top) less_top = max_top;
        LessDraw(NULL);
        ev = GetKey;
        c = ev & KEY_CODE;
        half = (less_rows - 1) / 2;
        if (c == 'q' || c == 'Q' || c == KEY_ESC) break;
        else if (c == ' ' || c == 'f' || c == KEY_PGDN || ev == (KF_CTRL | 'f')) {
            for (i = 0; i < less_rows - 1; i++) less_top = LessNextRow(less_top);
        } else if (c == 'b' || c == KEY_PGUP || ev == (KF_CTRL | 'b')) {
            for (i = 0; i < less_rows - 1; i++) less_top = LessPrevRow(less_top);
        } else if (c == 'd') {
            for (i = 0; i < half; i++) less_top = LessNextRow(less_top);
        } else if (c == 'u') {
            for (i = 0; i < half; i++) less_top = LessPrevRow(less_top);
        } else if (c == KEY_ENTER || c == 'j' || c == KEY_DOWN || ev == (KF_CTRL | 'n'))
            less_top = LessNextRow(less_top);
        else if (c == 'k' || c == KEY_UP || ev == (KF_CTRL | 'p'))
            less_top = LessPrevRow(less_top);
        else if (c == 'g' || c == KEY_HOME)
            less_top = 0;
        else if (c == 'G' || c == KEY_END)
            less_top = max_top;
        else if (c == '/' || c == '?') {
            dir = c;
            n = 0;
            pat[0] = 0;
            while (TRUE) {
                StrPrint(prompt, "%c%s", dir, pat);
                LessDraw(prompt);
                ev = GetKey;
                c = ev & KEY_CODE;
                if (c == KEY_ENTER) {
                    if (n) {StrCpy(less_pat, pat); less_patn = n;}
                    if (less_patn) LessSearch(less_pat, dir == '/');
                    break;
                }
                if (c == KEY_ESC) break;
                if (c == KEY_BACKSPACE) {
                    if (n > 0) {
                        n = LinePrev(pat, n);
                        pat[n] = 0;
                    } else
                        break;
                } else if (c >= 32 && c < KEY_SPECIAL && !(ev & (KF_CTRL | KF_ALT)) && n < 100) {
                    n += Utf8Enc(pat + n, c);
                    pat[n] = 0;
                }
            }
        } else if (c == 'n' || c == 'N') {
            if (less_patn) LessSearch(less_pat, c == 'n');
        }
        if (less_top < 0) less_top = 0;
    }
    LessClose;
}
