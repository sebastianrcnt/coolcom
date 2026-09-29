// Floating-point functions Aiwnios takes from the C library (TempleOS has them
// in x87 assembly): exponentials, logarithms, trigonometry. Sqrt, Floor, Ceil
// and Round are single instructions in Arch.S. Accuracy is about 1e-15.

#define LN2  0.6931471805599453094
#define LN10 2.3025850929940456840
#define NAN  (0x7FF8000000000000(F64))

F64 Exp(F64 x)
{
    I64 k, i;
    F64 r, sum, term;
    if (x > 709.0)
        return inf;
    if (x < -745.0)
        return 0.0;
    k = Round(x / LN2);
    r = x - k * LN2;  // |r| <= ln2/2
    sum = 1.0;
    term = 1.0;
    for (i = 1; i < 25; i++) {
        term *= r / i;
        sum += term;
    }
    // times 2^k, through the exponent bits (two steps keep them in range)
    r = 1.0;
    *(&r)(I64 *) = (1023 + k / 2) << 52;
    sum *= r;
    *(&r)(I64 *) = (1023 + k - k / 2) << 52;
    return sum * r;
}

F64 Ln(F64 x)
{
    I64 bits, e, i;
    F64 m, t, t2, sum, term;
    if (x <= 0.0) {
        if (x == 0.0)
            return -inf;
        return NAN;  // NaN
    }
    bits = *(&x)(I64 *);
    e = (bits >> 52 & 0x7FF) - 1023;
    bits = bits & 0x000FFFFFFFFFFFFF | 1023 << 52;
    m = 0.0;
    *(&m)(I64 *) = bits;  // x = m * 2^e, m in [1,2)
    if (m > 1.4142135623730951) {
        m /= 2.0;
        e++;
    }
    t = (m - 1.0) / (m + 1.0);  // ln m = 2 atanh t
    t2 = t * t;
    sum = 0.0;
    term = t;
    for (i = 1; i < 60; i += 2) {
        sum += term / i;
        term *= t2;
    }
    return 2.0 * sum + e * LN2;
}

F64 Log2(F64 x)
{
    return Ln(x) / LN2;
}

F64 Log10(F64 x)
{
    return Ln(x) / LN10;
}

F64 Pow(F64 x, F64 y)
{
    I64 n;
    Bool neg;
    F64 r, b;
    if (y == 0.0)
        return 1.0;
    n = y;
    if (n == y && n > -1024 && n < 1024) {  // integer power: exact multiplications
        neg = n < 0;
        if (neg)
            n = -n;
        r = 1.0;
        b = x;
        while (n) {
            if (n & 1)
                r *= b;
            b *= b;
            n >>= 1;
        }
        if (neg)
            return 1.0 / r;
        return r;
    }
    if (x < 0.0)
        return NAN;
    if (x == 0.0)
        return 0.0;
    return Exp(y * Ln(x));
}

F64 Pow10(F64 x)
{
    return Pow(10.0, x);
}

F64 Sin(F64 x)
{
    I64 i;
    F64 x2, sum, term;
    x = x - Round(x / (2 * pi)) * 2 * pi;  // [-pi, pi]
    if (x > pi / 2)
        x = pi - x;
    else if (x < -pi / 2)
        x = -pi - x;
    x2 = x * x;
    sum = term = x;
    for (i = 3; i < 40; i += 2) {
        term *= -x2 / ((i - 1) * i);
        sum += term;
    }
    return sum;
}

F64 Cos(F64 x)
{
    return Sin(x + pi / 2);
}

F64 Tan(F64 x)
{
    return Sin(x) / Cos(x);
}

F64 ATan(F64 x)
{
    I64 i;
    Bool neg = x < 0.0, inv;
    F64 x2, sum, term;
    if (neg)
        x = -x;
    inv = x > 1.0;
    if (inv)
        x = 1.0 / x;
    x = x / (1.0 + Sqrt(1.0 + x * x));  // atan x = 2 atan(this), now <= 0.415
    x2 = x * x;
    sum = term = x;
    for (i = 3; i < 80; i += 2) {
        term *= -x2;
        sum += term / i;
    }
    sum *= 2.0;
    if (inv)
        sum = pi / 2 - sum;
    if (neg)
        return -sum;
    return sum;
}

F64 Arg(F64 x, F64 y)
{//Angle of the point (x,y) (ATAN2).
    if (x > 0.0)
        return ATan(y / x);
    if (x < 0.0) {
        if (y >= 0.0)
            return ATan(y / x) + pi;
        return ATan(y / x) - pi;
    }
    if (y > 0.0)
        return pi / 2;
    if (y < 0.0)
        return -pi / 2;
    return 0.0;
}

F64 ASin(F64 x)
{
    if (x >= 1.0)
        return pi / 2;
    if (x <= -1.0)
        return -pi / 2;
    return ATan(x / Sqrt(1.0 - x * x));
}

F64 ACos(F64 x)
{
    return pi / 2 - ASin(x);
}
