// Two lightweight text panes. The Cool compiler can run only on the shell task;
// these panes are scratch views, not independent shells.
U0 Tmux()
{
    U8 left[4096], right[4096], *pane;
    I64 ln = 0, rn = 0, active = 0, split = FALSE, c, sc, rows, cols, y, i, limit;
    left[0] = right[0] = 0;
    ConsPutS("\x1b[?1049h");
    while (TRUE) {
        rows = fb.base ? fb.rows: 24;
        cols = fb.base ? fb.cols: 80;
        ConsPutS("\x1b[H\x1b[2J");
        limit = split ? cols / 2: cols;
        ConsPutS(left);
        if (split) {
            for (y = 1; y < rows; y++) {
                VimCsi(y, limit);
                ConsPut('|');
            }
            VimCsi(1, limit + 1);
            ConsPutS(right);
        }
        VimCsi(rows, 1);
        ConsPutS("\x1b[7m tmux  Ctrl-B % split | o switch | q quit  pane ");
        VimPutNum(active + 1);
        ConsPutS(" \x1b[0m\x1b[K");
        VimCsi(2, active ? limit + 1: 1);
        c = GetKey(&sc, FALSE);
        if (c == 2) {
            c = GetKey(&sc, FALSE);
            if (c == 'q') break;
            if (c == '%') split = TRUE;
            if (c == 'o' && split) active = !active;
            continue;
        }
        pane = active ? right: left;
        i = active ? rn: ln;
        if (c == 8 || c == 127) {if (i) pane[--i] = 0;}
        else if (c >= 32 && c < 127 && i < 4094) {pane[i++] = c; pane[i] = 0;}
        if (active) rn = i;
        else ln = i;
    }
}
ConsPutS("\x1b[?1049l");
}
