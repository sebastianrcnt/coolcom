class Pair { I64i x; I64i y; };
Pair a, b, c, d;
a.x = 1; a.y = 2; b.x = 3; b.y = 4;
a = b;
c.x = 5; c.y = 6; d.x = 7; d.y = 8;
Pair *p = &c, *q = &d;
*p = *q;
Print("%d %d / %d %d\n", a.x, a.y, c.x, c.y);
