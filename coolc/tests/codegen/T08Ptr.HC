#include "TestBase.HH"
class CS {I64 a; I64 b;};
class CT {U8 a; I64 b; U16 c;};
I64 garr[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}; U8 g8[16]; I16 g16[8]; I32 g32[8]; U32 gu32[4]; F64 gfa[4];
I64 *gp; U8 *gs; I64 **gpp; CS gcs[4];
I64 P1(I64 *p, I64 n) {return p[n];}
I64 P2(U8 *p, I64 n) {return p[n];}
I64 P3(I16 *p, I64 n) {return p[n];}
I64 P4(I32 *p, I64 n) {return p[n];}
I64 P5(U16 *p, I64 n) {return p[n];}
I64 P6(U32 *p, I64 n) {return p[n];}
I64 P7(I8 *p, I64 n) {return p[n];}
F64 P8(F64 *p, I64 n) {return p[n];}
I64 P9(I64 *p) {return p[3];}
I64 P10(U8 *p) {return p[17];}
I64 P11(I16 *p) {return p[5];}
I64 P12(I32 *p) {return p[100];}
I64 P13(I64 *p) {return p[-2];}
I64 P14(I64 *p, I64 i) {return p[i + 1] + p[i - 1];}
I64 P15(I64 *p, I64 i) {return p[i * 2];}
I64 P16(I64 *p, I64 i, I64 j) {return p[i] * p[j];}
U0 P17(I64 *p, I64 i, I64 v) {p[i] = v;}
U0 P18(U8 *p, I64 i, I64 v) {p[i] = v;}
U0 P19(I16 *p, I64 i, I64 v) {p[i] = v;}
U0 P20(I32 *p, I64 i, I64 v) {p[i] = v;}
U0 P21(F64 *p, I64 i, F64 v) {p[i] = v;}
U0 P22(I64 *p) {p[0] = p[1] + p[2];}
I64 Q1(I64 *p) {return *(p + 1);}
I64 Q2(I64 *p, I64 n) {return *(p + n);}
I64 Q3(U8 *p, I64 n) {return *(p + n);}
I64 Q4(I32 *p, I64 n) {return *(p + n * 2);}
I64 *Q5(I64 *p, I64 n) {return p + n;}
I64 *Q6(I64 *p, I64 n) {return p - n;}
U8 *Q7(U8 *p, I64 n) {return p + n;}
I32 *Q8(I32 *p, I64 n) {return p + n;}
I16 *Q9(I16 *p) {return p + 1;}
F64 *Q10(F64 *p) {return p - 1;}
I64 Q11(I64 *p, I64 *q) {return p - q;}
I64 Q12(U8 *p, U8 *q) {return p - q;}
I64 Q13(I32 *p, I32 *q) {return q - p;}
I64 Q14(U16 *p, U16 *q) {return p - q;}
I64 Q15(I64 *p, I64 *q) {return p < q;}
I64 Q16(I64 *p, I64 *q) {return p == q;}
I64 Q17(I64 *p) {return p == NULL;}
I64 Q18(I64 *p) {return p != 0;}
I64 Q19(I64 *p) {return !p;}
I64 Q20(I64 *p, I64 n) {p += n; return *p;}
I64 Q21(I32 *p, I64 n) {p -= n; return *p;}
I64 Q22(U8 *p) {p += 3; return *p;}
I64 Q23(I64 *p) {p = p + 1; return *p;}
I64 Q24(I64 *p, I64 n) {p = &p[n]; return *p;}
I64 Q25(I64 *p, I64 n) {return &p[n] - p;}
I64 Q26(U8 *p) {return p(I64);}
I64 *Q27(I64 a) {return a;}
I64 Q28(I64 *p) {return p;}
I64 R1() {I64 a = 5; I64 *p = &a; *p = 6; return a;}
I64 R2() {I64 a = 5, b = 6; I64 *p = &a; p++; return *p;}
I64 R3() {I64 a[4]; I64 *p = a; p[2] = 9; *p = 1; return a[2] + a[0];}
I64 R4() {I64 a[4]; I64 *p = &a[1]; p[1] = 3; return a[2];}
I64 R5() {U8 a = 1; U8 *p = &a; *p += 200; return a;}
I64 R6() {I32 a = 1; I16 *p = &a; *p = 0x7FFF; return a;}
I64 R7() {F64 f = 1.5; F64 *p = &f; *p *= 2; return f;}
I64 R8() {I64 a = 1; I64 *p = &a; I64 **pp = &p; **pp = 7; return a;}
I64 R9() {I64 a = 1, b = 2; I64 *p = &a; I64 **pp = &p; *pp = &b; **pp += 5; return b;}
I64 R10(I64 **pp) {return **pp;}
I64 R11(I64 **pp) {**pp = 3; *pp = NULL; return 1;}
I64 R12(I64 **pp, I64 i) {return pp[i][i];}
I64 R13(U8 **pp, I64 i, I64 j) {return pp[i][j];}
I64 R14(I64 ***ppp) {return ***ppp;}
U0 R15(I64 *p, I64 *q) {I64 t = *p; *p = *q; *q = t;}
I64 R16() {I64 a = 1, b = 2; R15(&a, &b); return a * 10 + b;}
I64 R17() {return *gp;}
U0 R18() {gp = &garr[3]; *gp = 99; gp++; *gp = 98;}
U0 R19() {gp = garr; gpp = &gp; **gpp = 5; (*gpp)++;}
I64 R20() {return gs[2];}
U0 R21() {gs = "Hello"; gs[0] = 'J';}
I64 R22() {return *gpp[0];}
I64 R23(I64 i) {return garr[i];}
I64 R24(I64 i) {return g8[i] + g16[i] + g32[i] + gu32[i];}
I64 R25() {return garr[9] - garr[0];}
I64 R26() {g8[3] = 7; g16[2] = -1; g32[1] = 100000; gu32[0] = 0xFFFFFFFF; return 0;}
F64 R27(I64 i) {return gfa[i];}
I64 R28() {return &garr[2];}
I64 R29() {return &g8[5] - g8;}
I64 R30() {return &g32[6] - &g32[2];}
I64 R31() {return &gcs[2].b;}
I64 R32() {return gcs[1].a + gcs[3].b;}
I64 R33(I64 i) {return gcs[i].a;}
I64 R34(I64 i) {gcs[i].b = i; return gcs[i].b;}
U0 R35() {gp = &gcs[1].b; *gp = 4;}
I64 S1(CS *p) {return p->a + p->b;}
I64 S2(CS *p, I64 i) {return p[i].b;}
I64 S3(CS *p) {p++; return p->a;}
I64 S4(CS *p) {return (p + 2)->b;}
CS *S5(CS *p, I64 n) {return p + n;}
CT *S6(CT *p, I64 n) {return p + n;}
I64 S7(CT *p, CT *q) {return q - p;}
I64 S8(CT *p) {return sizeof(CT);}
I64 S9(CS *p) {return &p->b;}
I64 S10(CS *p) {I64 *q = &p->b; return *q;}
I64 S11(CT *p) {return p->a + p->b + p->c;}
I64 S12(CT *p, I64 i) {return p[i].c;}
I64 S13() {return offset(CT.a) + offset(CT.b) * 10 + offset(CT.c) * 100;}
I64 S14(CS **pp) {return (*pp)->a + pp[1]->b;}
I64 S15(CS *p) {CS *q = p; q++; q->a = 5; return p[1].a;}
I64 T1(U8 *p) {return *p(I64 *);}
I64 T2(U8 *p) {return *(p(I32 *));}
I64 T3(I64 p) {return *p(U8 *);}
I64 T4(I64 *p) {return *p(U16 *);}
I64 T5(I64 *p) {return p(U8 *)[3];}
I64 T6(I64 *p, I64 i) {return *(p(U8 *) + i);}
U0 T7(U8 *p, I64 v) {*p(I64 *) = v;}
U0 T8(U8 *p, I64 v) {*p(U16 *) = v;}
U0 T9(U8 *p, I64 v) {p(I32 *)[1] = v;}
I64 T10(F64 *p) {return *p(I64 *);}
F64 T11(I64 *p) {return *p(F64 *);}
I64 T12(I64 a) {return a(U8 *)[0];}
I64 T13(U8 *p) {return (*p(I16 *))++;}
I64 T14(U8 *p) {return (p + 4)(I32 *)[0];}
I64 T15(I64 *p) {return p(I8 *)[-1];}
I64 T16(I64 a) {return *(a + 8)(I64 *);}
