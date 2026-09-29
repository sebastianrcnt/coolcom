#include "TestBase.HH"
F64 gf = 2.5; F64 gf2; F64 garr[6] = {1.0, 2.0, 3.5, -4.25, 0.5, 8.0}; I64 gi = 7;
F64 A1(F64 a, F64 b) {return a + b;}
F64 A2(F64 a, F64 b) {return a - b;}
F64 A3(F64 a, F64 b) {return a * b;}
F64 A4(F64 a, F64 b) {return a / b;}
F64 A5(F64 a) {return -a;}
F64 A6(F64 a) {return a + 1.0;}
F64 A7(F64 a) {return a * 2.0;}
F64 A8(F64 a) {return a / 3.0;}
F64 A9(F64 a) {return 10.0 - a;}
F64 A10(F64 a) {return a + 0.0;}
F64 A11(F64 a) {return a * 1e100;}
F64 A12(F64 a) {return a + 1.5e-300;}
F64 A13(F64 a) {return a * 3.14159265358979;}
F64 A14(F64 a, F64 b, F64 c) {return (a + b) * c - a / b;}
F64 A15(F64 a, F64 b, F64 c) {return a * b + b * c + c * a;}
F64 A16(F64 a, F64 b) {return a * a + b * b;}
F64 A17() {return 1.0;}
F64 A18() {return 0.0;}
F64 A19() {return -2.5;}
F64 A20() {return 1.0 / 3.0;}
F64 A21() {return 100;}
F64 A22() {return gf;}
F64 A23() {gf = gf * 2.0; gf += 1; gf -= 0.5; gf *= 3; gf /= 2; return gf;}
F64 A24(F64 a) {a += 1; a -= 2; a *= 3; a /= 4; return a;}
F64 A25(F64 *p) {*p += 1.0; *p *= 2.0; return *p;}
F64 A26(I64 i) {garr[i] += 1.5; return garr[i] * garr[i + 1];}
F64 A27(F64 *a, I64 i) {return a[i] + a[i + 1] - a[i + 2];}
F64 A28(F64 *a, I64 n) {I64 i; F64 s = 0; for (i = 0; i < n; i++) s += a[i]; return s;}
U0 A29(F64 *a, F64 *b, I64 n) {I64 i; for (i = 0; i < n; i++) a[i] = b[i] * 2.0 + 1;}
F64 A30() {F64 t[4]; t[0] = 1.0; t[1] = t[0] + 1; t[2] = t[1] * t[1]; t[3] = t[2] - t[0]; return t[3];}
I64 B1(F64 a, F64 b) {return a < b;}
I64 B2(F64 a, F64 b) {return a <= b;}
I64 B3(F64 a, F64 b) {return a > b;}
I64 B4(F64 a, F64 b) {return a >= b;}
I64 B5(F64 a, F64 b) {return a == b;}
I64 B6(F64 a, F64 b) {return a != b;}
I64 B7(F64 a) {return a < 0;}
I64 B8(F64 a) {return a == 0.0;}
I64 B9(F64 a) {return a > 1.5;}
I64 B10(F64 a, I64 b) {return a < b;}
I64 B11(I64 a, F64 b) {return a >= b;}
I64 B12(F64 a) {if (a) return 1; return 2;}
I64 B13(F64 a) {if (!a) return 1; return 2;}
I64 B14(F64 a, F64 b) {if (a < b) return 1; return 2;}
I64 B15(F64 a, F64 b) {if (a >= b) return 1; else return 2;}
I64 B16(F64 a, F64 b) {if (a == b) return 1; return 2;}
I64 B17(F64 a, F64 b) {if (a != b) return 1; return 2;}
I64 B18(F64 a, F64 b, F64 c) {if (a < b && b < c) return 1; return 2;}
I64 B19(F64 a, F64 b, F64 c) {if (a < b || c > b) return 1; return 2;}
I64 B20(F64 a, F64 b) {return a && b;}
I64 B21(F64 a, F64 b) {return a || b;}
I64 B22(F64 a) {return !a;}
F64 B23(F64 a, F64 b) {if (a > b) return a; return b;}
F64 B24(F64 a) {F64 s = 0; while (s < a) s += 0.5; return s;}
I64 B25(F64 a, F64 b) {return a < b < gf;}
I64 C1(F64 a) {return a;}
F64 C2(I64 a) {return a;}
I64 C3(F64 a) {I64 b = a; return b * 2;}
F64 C4(I64 a) {F64 b = a; return b / 2;}
F64 C5(I64 a, I64 b) {return a / b;}
F64 C6(I64 a, I64 b) {return a / b * 1.0;}
F64 C7(I64 a, F64 b) {return a + b;}
F64 C8(F64 a, I64 b) {return a * b;}
F64 C9(I64 a, F64 b) {return a * b - a;}
F64 C10(U8 a, F64 b) {return a + b;}
F64 C11(F64 a, I8 b) {return a - b;}
F64 C12(U64 a) {return a;}
F64 C13(I32 a, F64 b) {return a / b;}
F64 C14(F64 a) {return a(I64);}
F64 C15(I64 a) {return a(F64) / 2;}
I64 C16(F64 a) {return a(I64) + 1;}
I64 C17(F64 a) {return a + 0.5;}
I64 C18(F64 a) {return a * a;}
U8 C19(F64 a) {return a;}
I16 C20(F64 a) {return a;}
U0 C21(U8 *p, F64 v) {*p = v;}
U0 C22(I32 *p, F64 v) {*p = v;}
U0 C23(F64 *p, I64 v) {*p = v;}
U0 C24(F64 *p, U8 v) {*p = v;}
F64 C25(I64 *p) {return *p;}
F64 C26(U16 *p) {return *p + 0.5;}
F64 D1(F64 a) {return A1(a, a);}
F64 D2(F64 a, I64 b, F64 c) {return A14(a, c, b);}
F64 D3(I64 a, F64 b, I64 c, F64 d) {return a * b + c * d;}
F64 D4(F64 a, F64 b, F64 c, F64 d, F64 e, F64 f, F64 g, F64 h) {return a + b + c + d + e + f + g + h;}
F64 D5(F64 a, F64 b, F64 c, F64 d, F64 e, F64 f, F64 g, F64 h, F64 i, F64 j) {return a - b + c - d + e - f + g - h + i - j;}
F64 D6() {return D4(1, 2, 3, 4, 5, 6, 7, 8);}
F64 D7(F64 a) {return D5(a, a + 1, a + 2, a + 3, a + 4, a + 5, a + 6, a + 7, a + 8, a + 9);}
F64 D8(I64 a, I64 b, I64 c, I64 d, I64 e, I64 f, I64 g, I64 h, F64 i, F64 j, I64 k, F64 l) {return a + b + c + d + e + f + g + h + i + j + k + l;}
F64 D9() {return D8(1, 2, 3, 4, 5, 6, 7, 8, 9.5, 10.5, 11, 12.25);}
F64 D10(F64 a) {return A1(A3(a, a), A2(a, 1.0));}
F64 D11(F64 a) {return A1(a, 1) + A1(a, 2) + A1(a, 3);}
F64 D12(F64 a, F64 b) {F64 x = A3(a, b); F64 y = A4(a, b); return x * A1(x, y) - A2(y, x);}
I64 D13(F64 a) {return A1(a, 0.5);}
F64 E1(F64 a, F64 b, F64 c, F64 d) {return ((a + b) * (c + d)) / ((a - b) * (c - d)) + a * b * c * d;}
F64 E2(F64 a, I64 b) {return a * b + b * a - a / b;}
F64 E3() {return 2.0 * 3.0 + 4.0 * 5.0;}
F64 E4(F64 a) {return a * a * a * a * a * a;}
F64 E5(F64 a, F64 b) {return a ` b;}
F64 E6(F64 a) {return a ` 2 + a ` 3;}
F64 E7(I64 a, I64 b) {return a ` b;}
I64 E8(I64 a, I64 b) {return a ` b;}
I64 E9(I64 a) {return 2 ` a;}
F64 E10(F64 a) {return 2 ` a;}
