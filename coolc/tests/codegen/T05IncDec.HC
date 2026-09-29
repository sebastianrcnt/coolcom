#include "TestBase.HH"
class CPt{I64 x;U8 c;I32 y;U16 w;I8 b;};
I64 gi=10;U8 gu8=250;I16 gi16=-3;F64 gf=1.5;I64 garr[8];U8 g8[8];I32 g32[4];CPt gpt;
I64 Q1(I64 a){a++;return a;}
I64 Q2(I64 a){++a;return a;}
I64 Q3(I64 a){a--;return a;}
I64 Q4(I64 a){--a;return a;}
I64 Q5(I64 a){return a++;}
I64 Q6(I64 a){return ++a;}
I64 Q7(I64 a){return a--;}
I64 Q8(I64 a){return --a;}
I64 Q9(I64 a){return a+++a;}
I64 Q10(I64 a){return a++ + ++a;}
I64 Q11(I64 a){return a-- - --a;}
I64 Q12(I64 a){I64 b=a++;I64 c=++a;return b*c;}
U8 Q13(U8 a){a++;return a;}
I8 Q14(I8 a){return --a;}
U16 Q15(U16 a){return a++;}
I16 Q16f(I16 a){return ++a;}
U32 Q17(U32 a){a--;return a;}
I32 Q18(I32 a){return a--;}
I64 J1(){gi++;++gi;gi--;return gi++;}
I64 J2(){return --gi;}
I64 J3(){gu8++;return gu8++;}
I64 J4(){return --gi16;}
I64 J5(){gi16--;return gi16++;}
F64 J6(){gf++;return ++gf;}
F64 J7(){return gf--;}
F64 J8(){return --gf;}
I64 K1(I64 *p){(*p)++;++*p;(*p)--;return --*p;}
I64 K2(I64 *p){return *p++;}
I64 K3(I64 *p){return *++p;}
I64 K4(I64 *p){p++;return *p;}
I64 K5(I64 *p){return *p--;}
I64 K6(U8 *p){return *p++;}
I64 K7(U8 *p){return *p+++*p;}
I64 K8(U8 *p){(*p)++;return (*p)--;}
I64 K9(I16 *p){return (*p)++ + ++(*p);}
I64 K10(I64 **pp){(**pp)++;return *(*pp)++;}
I64 K11(I64 **pp){(*pp)++;return **pp;}
I64 K12(U32 *p){p++;p++;return *p;}
I64 L1(I64 i){garr[i]++;++garr[i];garr[i]--;return garr[i]++;}
I64 L2(I64 i){return --garr[i+1];}
I64 L3(){garr[3]++;return garr[3]--;}
I64 L4(I64 i){g8[i]++;g8[i+1]--;return ++g8[i]+--g8[i+1];}
I64 L5(I64 i){return g32[i]++ + ++g32[i&3];}
I64 L6(I64 *a,I64 i){a[i]++;return ++a[i]+a[i]--;}
I64 L7(U8 *a,I64 i){return a[i]++;}
I64 L8(){return garr[1]++ + garr[2]++;}
I64 L9(){I64 a[4];a[0]=1;a[1]=2;a[0]++;++a[1];return a[0]*a[1];}
I64 L10(){U8 a[4];a[0]=255;a[0]++;return a[0];}
I64 M1(CPt *p){p->x++;++p->x;p->x--;return p->x++;}
I64 M2(CPt *p){p->c++;return --p->c;}
I64 M3(CPt *p){p->y--;return p->y++;}
I64 M4(CPt *p){p->w++;return ++p->w;}
I64 M5(CPt *p){p->b--;return p->b--;}
I64 M6(){gpt.x++;gpt.c--;++gpt.y;gpt.w--;gpt.b++;return gpt.x+gpt.c+gpt.y+gpt.w+gpt.b;}
I64 M7(){CPt t;t.x=1;t.c=2;t.y=3;t.x++;t.c--;return t.x+t.c+t.y;}
I64 M8(CPt *p,I64 i){p[i].x++;return p[i].y--;}
I64 N1(I64 n){I64 i,s=0;for(i=0;i<n;i++)s+=i;return s;}
I64 N2(I64 n){I64 i,s=0;for(i=n;i>0;i--)s+=i;return s;}
I64 N3(I64 n){I64 i=0,s=0;while(i++<n)s+=i;return s;}
I64 N4(I64 n){I64 i=n,s=0;while(--i>=0)s+=i;return s;}
I64 N5(U8 *s){I64 n=0;while(*s++)n++;return n;}
U0 N6(U8 *d,U8 *s){while(*d++=*s++);}
U0 N7(I64 *d,I64 *s,I64 n){while(n--)*d++=*s++;}
I64 N8(I64 *p,I64 n){I64 s=0;while(n-->0)s+=*p++;return s;}
