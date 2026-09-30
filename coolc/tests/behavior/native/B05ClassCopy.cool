class Pair {I64i x; I64i y;};
Pair g, h;
I64i ClassCopyCheck() {
    Pair a, b, c, d;
    Pair *p = &c, *q = &d;
    a.x = 1; a.y = 2; b.x = 3; b.y = 4;
    c.x = 5; c.y = 6; d.x = 7; d.y = 8;
    a = b;
    *p = *q;
    g.x = 11; g.y = 12; h.x = 13; h.y = 14;
    g = h;
    return a.x * 1000 + a.y * 100 + c.x * 10 + c.y + g.y * 10000;
}
