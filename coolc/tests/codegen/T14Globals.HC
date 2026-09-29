#include "TestBase.HH"
I64 g0; I64 g1 = 5; U64 g2 = 0xFFFFFFFFFFFFFFFF; I64 g3 = -7;
U8 h0 = 200; I8 h1 = -100; U16 h2 = 65535; I16 h3 = -32768; U32 h4 = 0xDEADBEEF; I32 h5 = -2000000000;
F64 f0; F64 f1 = 3.25; F64 f2 = -0.5;
I64 ga[4] = {10, 20, 30, 40};
U8 gb[8] = {1, 2, 3, 4, 5, 6, 7, 8};
I16 gc[3] = {-1, 0, 1};
I32 gd[2] = {100000, -100000};
F64 ge[3] = {1.5, 2.5, 3.5};
U8 gz[32]; I64 gy[16]; F64 gx[8];
I64 gm[3][4];
U8 *gs0 = "hello";
U8 *gs1 = "wor\tld\n\"q\"\\";
U8 *gsa[3] = {"one", "two", "three"};
U8 gstr[8] = "abc";
I64 *gpi = &g1;
I64 gcalc = 3 * 4 + 2;
I64 gcalc2 = 1 << 20;
I64 gcalc3 = 0x10 + 0b101;
I64 gch = 'A';
I64 gch2 = 'AB';
I64 gch3 = 'ABCDEFGH';
F64 gfc = 1.0 / 4.0;
I64 R1() {return g0 + g1 + g3;}
U64 R2() {return g2;}
I64 R3() {return h0 + h1 + h2 + h3;}
I64 R4() {return h4 + h5;}
F64 R5() {return f0 + f1 + f2;}
I64 R6(I64 i) {return ga[i];}
I64 R7() {return ga[0] + ga[3];}
I64 R8(I64 i) {return gb[i & 7];}
I64 R9() {return gc[0] + gc[2];}
I64 R10(I64 i) {return gd[i];}
F64 R11(I64 i) {return ge[i];}
U0 W1() {g0 = 1; g1 = 2; g2 = 3; g3 = 4;}
U0 W2() {h0 = 1; h1 = 2; h2 = 3; h3 = 4; h4 = 5; h5 = 6;}
U0 W3() {f0 = 1.5; f1 = f0 * 2; f2 = f1 - f0;}
U0 W4(I64 i, I64 v) {ga[i] = v; gb[i] = v; gc[i & 1] = v; gd[i & 1] = v; ge[i % 3] = v;}
U0 W5() {ga[2] = ga[1] + ga[3]; gb[0] = gb[1] * gb[2];}
U0 W6() {I64 i; for (i = 0; i < 32; i++) gz[i] = i; for (i = 0; i < 16; i++) gy[i] = i * i; for (i = 0; i < 8; i++) gx[i] = i / 2.0;}
I64 W7() {I64 i, s = 0; for (i = 0; i < 16; i++) s += gy[i]; return s;}
I64 M1(I64 i, I64 j) {return gm[i][j];}
U0 M2(I64 i, I64 j, I64 v) {gm[i][j] = v;}
I64 M3() {gm[1][2] = 5; gm[2][3] = gm[1][2] * 2; return gm[2][3] + gm[0][0];}
I64 M4() {I64 i, j, s = 0; for (i = 0; i < 3; i++) for (j = 0; j < 4; j++) {gm[i][j] = i * j; s += gm[i][j];} return s;}
I64 M5() {I64 m[2][3]; m[1][2] = 4; m[0][1] = 2; return m[1][2] * m[0][1];}
I64 M6() {U8 m[3][3][3]; m[2][2][2] = 9; m[1][0][2] = 1; return m[2][2][2] + m[1][0][2];}
F64 M7() {F64 m[2][2]; m[0][0] = 1.5; m[1][1] = 2.5; return m[0][0] + m[1][1];}
U8 *S1() {return gs0;}
U8 *S2() {return "literal";}
I64 S3() {return gs0[1];}
I64 S4() {return "abc" [2];}
I64 S5(I64 i) {return gsa[i][0];}
U8 *S6(I64 i) {return gsa[i];}
I64 S7() {return gstr[0] + gstr[1] + gstr[2] + gstr[3];}
I64 S8(U8 *s) {I64 n = 0; while (s[n]) n++; return n;}
I64 S9() {return S8("hello world");}
I64 S10() {return S8("a\nb\tc\\d\"e\x41\101");}
I64 S11() {return S8("");}
I64 S12() {return S8("same") + S8("same");}
I64 S13() {U8 buf[16]; buf[0] = 'h'; buf[1] = 'i'; buf[2] = 0; return S8(buf);}
I64 S14(U8 *a, U8 *b) {while (*a && *a == *b) {a++; b++;} return *a - *b;}
I64 S15() {return S14("abc", "abd");}
I64 S16() {return gch + gch2 + gch3;}
I64 S17() {return 'x';}
I64 S18() {return '\n' + '\t' + '\\' + '\'' + '\0';}
I64 S19() {return 'ABCD';}
I64 S20() {return 'A' + 1;}
U8 S21() {return 'Z';}
I64 S22(I64 c) {return c >= 'a' && c <= 'z';}
I64 S23(I64 c) {if (c >= 'a' && c <= 'z') return c - 32; return c;}
I64 S24() {return *gpi;}
U0 S25() {*gpi = 9;}
I64 S26() {return gcalc + gcalc2 + gcalc3;}
F64 S27() {return gfc;}
I64 S28() {return &g1;}
I64 S29() {return &ga[2] - &ga[0];}
I64 S30() {return sizeof(ga) + sizeof(gb) + sizeof(gm) + sizeof(gs0) + sizeof(h0) + sizeof(h3) + sizeof(f0);}
I64 S31() {return sizeof(I64) + sizeof(U8) + sizeof(I16) + sizeof(U32) + sizeof(F64) + sizeof(U8 *);}
I64 T1() {I64 c = 0; return c;}
I64 T3() {I64 x = 1, y = 2, z = 3; return x + y * z;}
I64 T6() {U8 *p = "abc"; return p[1];}
I64 T8() {I64 a = 5, b = a * 2, c = a + b; return c;}
