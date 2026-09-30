// Nyan cat for the ANSI console: 16-color background blocks, two columns per
// pixel, so it runs the same on the framebuffer and on the host terminal.
// Nyan; starts it, any key stops it.

#define NYAN_W 40
#define NYAN_H 22

// Pixel colors are ANSI palette indices 0..15; 16 means "leave as is".
#define NC_BLACK  0
#define NC_RED    1
#define NC_ORANGE 3
#define NC_BLUE   4
#define NC_VIOLET 5
#define NC_GRAY   7
#define NC_DGRAY  8
#define NC_PINK   13
#define NC_YELLOW 11
#define NC_GREEN  10
#define NC_LBLUE  12
#define NC_WHITE  15
#define NC_CRUST  11
#define NC_CHEEK  9

U8 nyan_grid[NYAN_W * NYAN_H];
U8 nyan_rainbow[6] = {NC_RED, NC_ORANGE, NC_YELLOW, NC_GREEN, NC_LBLUE, NC_VIOLET};
I64 nyan_star_x[6] = {5, 17, 31, 9, 24, 37};
I64 nyan_star_y[6] = {2, 5, 1, 18, 20, 16};

U0 NyanPut(I64 x, I64 y, I64 c)
{
    if (x >= 0 && x < NYAN_W && y >= 0 && y < NYAN_H)
        nyan_grid[y * NYAN_W + x] = c;
}

U0 NyanRect(I64 x, I64 y, I64 w, I64 h, I64 c)
{
    I64 i, j;
    for (j = 0; j < h; j++)
        for (i = 0; i < w; i++)
            NyanPut(x + i, y + j, c);
}

U0 NyanStar(I64 x, I64 y, I64 phase)
{//A twinkling star: a dot, a small cross or a big cross.
    if (phase == 0) {
        NyanPut(x, y, NC_WHITE);
    } else if (phase == 1) {
        NyanPut(x - 1, y, NC_WHITE);
        NyanPut(x + 1, y, NC_WHITE);
        NyanPut(x, y - 1, NC_WHITE);
        NyanPut(x, y + 1, NC_WHITE);
    } else {
        NyanPut(x - 2, y, NC_WHITE);
        NyanPut(x + 2, y, NC_WHITE);
        NyanPut(x, y - 2, NC_WHITE);
        NyanPut(x, y + 2, NC_WHITE);
        NyanPut(x, y, NC_WHITE);
    }
}

U0 NyanCat(I64 x, I64 y, I64 frame)
{//The pop-tart body at (x, y), head on the right, legs and tail animated.
    I64 leg = frame & 1, tail = (frame >> 1) & 1;
    // tail
    NyanRect(x - 3, y + 6 - tail, 3, 2, NC_BLACK);
    NyanRect(x - 2, y + 7 - tail, 2, 1, NC_GRAY);
    // legs
    NyanRect(x + 1 + leg, y + 10, 2, 2, NC_BLACK);
    NyanRect(x + 5 + leg, y + 10, 2, 2, NC_BLACK);
    NyanRect(x + 11 + leg, y + 10, 2, 2, NC_BLACK);
    NyanRect(x + 15 + leg, y + 10, 2, 2, NC_BLACK);
    NyanRect(x + 2 + leg, y + 10, 1, 1, NC_GRAY);
    NyanRect(x + 6 + leg, y + 10, 1, 1, NC_GRAY);
    NyanRect(x + 12 + leg, y + 10, 1, 1, NC_GRAY);
    NyanRect(x + 16 + leg, y + 10, 1, 1, NC_GRAY);
    // pop-tart: outline, crust, frosting, sprinkles
    NyanRect(x, y, 17, 11, NC_BLACK);
    NyanRect(x + 1, y + 1, 15, 9, NC_CRUST);
    NyanRect(x + 2, y + 2, 13, 7, NC_PINK);
    NyanPut(x + 4, y + 3, NC_VIOLET);
    NyanPut(x + 8, y + 2, NC_VIOLET);
    NyanPut(x + 11, y + 4, NC_VIOLET);
    NyanPut(x + 5, y + 6, NC_VIOLET);
    NyanPut(x + 9, y + 7, NC_VIOLET);
    NyanPut(x + 3, y + 8, NC_VIOLET);
    // head
    NyanRect(x + 12, y + 3, 10, 7, NC_BLACK);
    NyanRect(x + 13, y + 4, 8, 5, NC_GRAY);
    NyanRect(x + 13, y + 2, 2, 2, NC_BLACK);  // ears
    NyanRect(x + 19, y + 2, 2, 2, NC_BLACK);
    NyanPut(x + 14, y + 3, NC_GRAY);
    NyanPut(x + 19, y + 3, NC_GRAY);
    NyanPut(x + 14, y + 5, NC_BLACK);  // eyes
    NyanPut(x + 19, y + 5, NC_BLACK);
    NyanPut(x + 14, y + 4, NC_WHITE);
    NyanPut(x + 19, y + 4, NC_WHITE);
    NyanPut(x + 13, y + 7, NC_CHEEK);  // cheeks
    NyanPut(x + 20, y + 7, NC_CHEEK);
    NyanPut(x + 16, y + 7, NC_BLACK);  // mouth
    NyanPut(x + 17, y + 7, NC_BLACK);
    NyanPut(x + 15, y + 6, NC_BLACK);
    NyanPut(x + 18, y + 6, NC_BLACK);
}

U0 NyanFrame(I64 frame)
{
    I64 i, x, y, band, bob = (frame >> 1) & 1, cat_x = NYAN_W / 2 - 6, cat_y = 5 + bob, up;
    MemSet(nyan_grid, NC_BLUE, NYAN_W * NYAN_H);
    // stars drift left
    for (i = 0; i < 6; i++) {
        x = nyan_star_x[i] - frame % (NYAN_W + 4);
        if (x < -2)
            x += NYAN_W + 4;
        NyanStar(x, nyan_star_y[i], (frame + i) % 3);
    }
    // rainbow: six two-pixel bands in four-pixel steps that bob out of phase
    for (x = 0; x < cat_x; x++) {
        up = ((x / 4 + frame) & 1);
        for (band = 0; band < 6; band++)
            for (y = 0; y < 2; y++)
                NyanPut(x, 6 + band * 2 + y - up, nyan_rainbow[band]);
    }
    NyanCat(cat_x, cat_y, frame);
}

U0 NyanDraw(U8 *buf)
{//The whole grid as one string: home, then each row with color changes only.
    I64 x, y, c, last;
    U8 *p = buf;
    for (y = 0; y < NYAN_H; y++) {
        p = AnsiCursorS(p, y + 1, 1);
        last = -1;
        for (x = 0; x < NYAN_W; x++) {
            c = nyan_grid[y * NYAN_W + x];
            if (c != last) {
                p = AnsiBgS(p, c);
                last = c;
            }
            *p++ = ' ';
            *p++ = ' ';
        }
        p = AnsiResetS(p);
    }
    p = AnsiCursorS(p, NYAN_H + 2, 1);
    p = AnsiResetS(p);
    StrCpy(p, "  Nyan Cool OS  (any key to stop)");
    Print("%s", buf);
}

U0 Nyan()
{
    I64 frame = 0;
    U8 *buf = MAlloc(NYAN_W * NYAN_H * 12 + 4096);
    while (KeyPending)
        KeyPop;
    AnsiAltScreen(TRUE);
    AnsiClear;
    while (!KeyPending) {
        NyanFrame(frame++);
        NyanDraw(buf);
        Sleep(90);
    }
    KeyPop;
    Free(buf);
    AnsiReset;
    AnsiAltScreen(FALSE);
}
