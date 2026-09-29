#include "TestBase.HH"
I64 g0(){return 42;}
I64 g1(I64 a){return a;}
I64 g2(I64 a,I64 b){return a-b;}
I64 g3(I64 a,I64 b,I64 c){return a*b+c;}
I64 g4(I64 a,I64 b,I64 c,I64 d){return a-b+c-d;}
I64 g5(I64 a,I64 b,I64 c,I64 d,I64 e){return a+b*2+c*3+d*4+e*5;}
I64 g6(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f){return a+b*2+c*3+d*4+e*5+f*6;}
I64 g7(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g){return a+b*2+c*3+d*4+e*5+f*6+g*7;}
I64 g8(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h){return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8;}
I64 g9(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h,I64 i){return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8+i*9;}
I64 g10(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h,I64 i,I64 j){return a-b+c-d+e-f+g-h+i-j;}
I64 g11(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h,I64 i,I64 j,I64 k){return a+b+c+d+e+f+g+h+i+j+k;}
I64 g12(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h,I64 i,I64 j,I64 k,I64 l){return a*l+b*k+c*j+d*i+e*h+f*g;}
I64 g14(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h,I64 i,I64 j,I64 k,I64 l,I64 m,I64 n){return a+n+g*m;}
I64 gc0;
U0 v0(){gc0++;}
I64 c0(){return g0();}
I64 c1(){return g1(5);}
I64 c2(I64 a){return g2(a,a+1);}
I64 c3(){return g3(1,2,3);}
I64 c4(I64 a){return g4(a,a,a,a);}
I64 c5(){return g5(1,2,3,4,5);}
I64 c6(){return g6(1,2,3,4,5,6);}
I64 c7(){return g7(1,2,3,4,5,6,7);}
I64 c8(){return g8(1,2,3,4,5,6,7,8);}
I64 c9(){return g9(1,2,3,4,5,6,7,8,9);}
I64 c10(){return g10(1,2,3,4,5,6,7,8,9,10);}
I64 c11(){return g11(1,2,3,4,5,6,7,8,9,10,11);}
I64 c12(I64 x){return g12(x,x+1,x+2,x+3,x+4,x+5,x+6,x+7,x+8,x+9,x+10,x+11);}
I64 c14(I64 x){return g14(1,2,3,4,5,6,7,8,9,10,11,12,13,14)+x;}
I64 n1(I64 a){return g1(g1(g1(a)));}
I64 n2(I64 a,I64 b){return g2(g2(a,b),g2(b,a));}
I64 n3(I64 a){return g3(g1(a),g2(a,1),g3(a,a,a));}
I64 n4(I64 a){return g9(g1(a),g1(a+1),g1(a+2),g1(a+3),g1(a+4),g1(a+5),g1(a+6),g1(a+7),g1(a+8));}
I64 n5(I64 a){return g10(a,g9(1,2,3,4,5,6,7,8,9),a,g8(1,2,3,4,5,6,7,a),a,a,a,a,a,a);}
I64 n6(I64 a){return g1(a)+g1(a+1)*g1(a+2)-g2(a,3);}
I64 n7(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h,I64 i,I64 j){return g10(j,i,h,g,f,e,d,c,b,a);}
I64 n8(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h,I64 i,I64 j){return a+j+g1(i);}
I64 n9(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h,I64 i,I64 j){I64 *p=&j;*p=5;p=&a;return i+*p+j;}
I64 n10(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h,I64 i,I64 j){return g11(a,b,c,d,e,f,g,h,i,j,n8(a,b,c,d,e,f,g,h,i,j));}
U0 u1(U8 a,I8 b,U16 c,I16 d,U32 e,I32 f,U64 g,I64 h){gc0+=a+b+c+d+e+f+g+h;}
U0 u2(U8 a,I8 b,U16 c,I16 d,U32 e,I32 f,U64 g,I64 h,U8 i,I8 j,U16 k,I16 l){gc0+=a+b+c+d+e+f+g+h+i+j+k+l;}
I64 u3(){u1(200,-5,60000,-300,4000000000,-100000,5,6);return gc0;}
I64 u4(){u2(1,2,3,4,5,6,7,8,9,10,11,12);return gc0;}
I64 u5(U8 a,U8 b,U8 c,U8 d,U8 e,U8 f,U8 g,U8 h,U8 i,U8 j){return a+j+i;}
I64 u6(I8 a,I8 b,I8 c,I8 d,I8 e,I8 f,I8 g,I8 h,I8 i,I8 j){return a+j+i;}
F64 f1(F64 a,I64 b,F64 c,I64 d,F64 e,I64 f,F64 g,I64 h,F64 i,I64 j,F64 k,I64 l){return a+b+c+d+e+f+g+h+i+j+k+l;}
I64 vv(){v0();v0();return gc0;}
I64 vw(I64 a){g1(a);g2(a,a);g0();return a;}
U0 vx(I64 a){g1(a);}
U0 vy(I64 a){vx(a);vx(a+1);}
I64 vz(I64 a){return g0;}
I64 vz2(I64 a){return g0+g0;}
U0 vz3(){v0;v0;}
I64 t1(I64 a){return g2(a,a)+g2(a,g2(a,a));}
I64 t2(I64 a){I64 x=g1(a),y=g1(x),z=g1(y);return g3(x,y,z);}
I64 t3(I64 a,I64 b){return g2(a,b)*g2(b,a)+g2(a+b,a-b);}
I64 t4(I64 a){I64 s=0,i;for(i=0;i<a;i++)s+=g3(i,i,i);return s;}
I64 t5(I64 a,I64 b,I64 c,I64 d,I64 e,I64 f,I64 g,I64 h){I64 x=g8(a,b,c,d,e,f,g,h);I64 y=g8(h,g,f,e,d,c,b,a);return x-y;}
