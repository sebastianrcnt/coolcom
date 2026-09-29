U0 F()
{
    a = b + c - d * e / f % g;
    a += 1; a -= 2; a *= 3; a /= 4; a %= 5; a &= 6; a |= 7; a ^= 8; a <<= 1; a >>= 2;
    a = b << c >> d & e | f ^ g;
    a = b && c || d ^^ e;
    a = b == c != d < e > f <= g >= h;
    a = b ` c;
    a = b + c;
    x = -y;
    x = -y;
    x = a - -b;
    x = a - -b;
    x = a - b;
    x = a * *p;
    x = a * *p;
    x = *p * q;
    x = *p;
    x = &v;
    x = a & b;
    x = a && b;
    x = a & &b;
    x = !y;
    x = !!y;
    x = ~y;
    x = ~~y;
    x = - -y;
    x = +y;
    ++i;
    i++;
    --i;
    i--;
    x = i++ + ++j;
    x = i++ - --j;
    x = a[i] - 1;
    x = f(a) - 1;
    x = f(a) * 2;
    x = (a) * 2;
    x = (*p) - 1;
    x = y[-1];
    x = f(-1, -2);
    x = f(*p, &q);
    x = 1 - 2;
    x = y - 1.5e-3;
    *p = 1;
    *p++ = 2;
    *p += 3;
    x = sizeof(I64) * 2;
    x = a < -1;
    x = a << -1;
    x = a == -1;
    x = *p == *q;
    x = **pp;
    x = a->b - c->d;
    x = a.b * c.d;
    if (a)
        *p = 1;
    if (a)
        -b;
    while (a)
        --i;
    return -1;
    return *p;
    return &x;
    return !x;
}
