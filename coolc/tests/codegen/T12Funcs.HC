#include "TestBase.HH"
class COps {I64 (*fn)(I64 a, I64 b); I64 tag; U8 *name;};
I64 (*gfp)(I64 a, I64 b);
I64 (*gfp1)(I64 a);
U8 *gtab[4];
COps gops;
I64 Add(I64 a, I64 b) {return a + b;}
I64 Sub(I64 a, I64 b) {return a - b;}
I64 Mul(I64 a, I64 b) {return a * b;}
I64 Neg(I64 a) {return -a;}
F64 FAdd(F64 a, F64 b) {return a + b;}
I64 Dft1(I64 a, I64 b = 10) {return a + b;}
I64 Dft2(I64 a = 1, I64 b = 2, I64 c = 3) {return a * 100 + b * 10 + c;}
F64 Dft3(F64 a, F64 b = 2.5) {return a * b;}
I64 Dft4(I64 a, I64 s = 97) {return a + s;}  // not a string default: Aiwnios embeds its compile-time heap address
I64 Dft5(I64 a = -1, F64 b = 0.5) {return a + b;}
I64 UseDft() {return Dft1(1) + Dft1(1, 2) + Dft2() + Dft2(5) + Dft2(5, 6) + Dft2(5, 6, 7);}
F64 UseDft2() {return Dft3(2.0) + Dft3(2.0, 3.0) + Dft5() + Dft5(4);}
I64 UseDft3() {return Dft4(1) + Dft4(1, 120);}
I64 Sum(...) {I64 i, s = 0; for (i = 0; i < argc; i++) s += argv[i]; return s;}
I64 Sum2(I64 base, ...) {I64 i, s = base; for (i = 0; i < argc; i++) s += argv[i] * i; return s;}
I64 Cnt(...) {return argc;}
F64 SumF(...) {I64 i; F64 s = 0; for (i = 0; i < argc; i++) s += argv[i](F64); return s;}
I64 Mx(...) {I64 i, m = I64_MIN; for (i = 0; i < argc; i++) if (argv[i] > m) m = argv[i]; return m;}
I64 CallV() {return Sum(1, 2, 3) + Sum() + Cnt(1, 2, 3, 4, 5) + Sum2(10, 1, 2, 3);}
I64 CallV2() {return Sum(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12);}
I64 CallV3(I64 a) {return Sum(a, a + 1) + Mx(a, -a, 3);}
I64 CallV4() {return Sum(1.5(I64), 2);}
I64 Fib(I64 n) {if (n < 2) return n; return Fib(n - 1) + Fib(n - 2);}
I64 Fact(I64 n) {if (n <= 1) return 1; return n * Fact(n - 1);}
I64 Gcd(I64 a, I64 b) {if (!b) return a; return Gcd(b, a % b);}
I64 Ack(I64 m, I64 n) {if (!m) return n + 1; if (!n) return Ack(m - 1, 1); return Ack(m - 1, Ack(m, n - 1));}
extern I64 EvenP(I64 n);
I64 OddP(I64 n) {if (!n) return 0; return EvenP(n - 1);}
I64 EvenP(I64 n) {if (!n) return 1; return OddP(n - 1);}
F64 FPow(F64 x, I64 n) {if (!n) return 1.0; return x * FPow(x, n - 1);}
I64 Sum9(I64 a, I64 b, I64 c, I64 d, I64 e, I64 f, I64 g, I64 h, I64 i) {if (!a) return b + c + d + e + f + g + h + i; return Sum9(a - 1, b + 1, c, d, e, f, g, h, i + 1);}
U0 Hanoi(I64 n, I64 a, I64 b, I64 c) {if (!n) return; Hanoi(n - 1, a, c, b); gops.tag++; Hanoi(n - 1, c, b, a);}
I64 FP1() {I64 (*f)(I64 a, I64 b); f = &Add; return f(3, 4);}
I64 FP2(I64 x) {I64 (*f)(I64 a, I64 b); if (x) f = &Sub; else f = &Mul; return f(6, 7);}
I64 FP3(I64 (*f)(I64 a, I64 b), I64 x, I64 y) {return f(x, y);}
I64 FP4() {return FP3(&Add, 1, 2) + FP3(&Sub, 5, 3) + FP3(&Mul, 4, 5);}
I64 FP5() {gfp = &Add; return gfp(8, 9);}
I64 FP6(I64 x) {gfp1 = &Neg; return gfp1(x) + gfp1(gfp1(x));}
I64 FP7() {gops.fn = &Mul; gops.tag = 5; return gops.fn(gops.tag, 6);}
I64 FP8(COps *o) {return o->fn(1, 2) + o->fn(3, 4);}
I64 FP9() {gtab[0] = &Add; gtab[1] = &Sub; gtab[2] = &Mul; gtab[3] = &Neg; return 0;}
I64 FP10(I64 i, I64 a, I64 b) {I64 (*f)(I64 a, I64 b); f = gtab[i]; return f(a, b);}
I64 FP12() {I64 (*f)(I64 a); f = &Neg; return f(f(f(3)));}
I64 FP13(I64 (*f)(I64 a), I64 n) {I64 i, s = 0; for (i = 0; i < n; i++) s += f(i); return s;}
I64 FP14() {return FP13(&Neg, 10);}
I64 FP15(I64 (*f)(I64 a, I64 b), I64 n) {return f(n, f(n, f(n, n)));}
F64 FP16(F64 (*f)(F64 a, F64 b), F64 x) {return f(x, f(x, x));}
F64 FP17() {return FP16(&FAdd, 1.5);}
I64 FP19(U8 *fp, I64 a, I64 b) {I64 (*f)(I64 a, I64 b); f = fp; return f(a, b);}
U8 *FP20() {return &Add;}
U8 *FP21() {return gfp;}
I64 FP23() {return Add(1, 2);}
I64 FP24() {return Add(Sub(9, 1), Mul(2, 3));}
I64 FP25(COps *o) {return o->fn == &Add;}
I64 FP26() {return gfp == NULL;}
I64 FP27() {return gfp != &Sub;}
U0 Void1() {gops.tag = 1;}
U0 Void2() {Void1; Void1();}
I64 Tail(I64 n) {if (n > 0) return Tail(n - 1); return 0;}
I64 Many(I64 a, F64 b, I64 c, F64 d, I64 e, F64 f, I64 g, F64 h, I64 i, F64 j, I64 k, F64 l, I64 m, F64 n, I64 o, F64 p, I64 q, F64 r, I64 s, F64 t) {return a + b + c + d + e + f + g + h + i + j + k + l + m + n + o + p + q + r + s + t;}
F64 Many2() {return Many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20);}
