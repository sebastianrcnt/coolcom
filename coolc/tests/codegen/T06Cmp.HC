#include "TestBase.HH"
I64 gi=3;U64 gu=4;
I64 C1(I64 a,I64 b){return a<b;}
I64 C2(I64 a,I64 b){return a<=b;}
I64 C3(I64 a,I64 b){return a>b;}
I64 C4(I64 a,I64 b){return a>=b;}
I64 C5(I64 a,I64 b){return a==b;}
I64 C6(I64 a,I64 b){return a!=b;}
I64 D1(U64 a,U64 b){return a<b;}
I64 D2(U64 a,U64 b){return a<=b;}
I64 D3(U64 a,U64 b){return a>b;}
I64 D4(U64 a,U64 b){return a>=b;}
I64 D5(U64 a,U64 b){return a==b;}
I64 D6(U64 a,U64 b){return a!=b;}
I64 E1(I64 a){return a<0;}
I64 E2(I64 a){return a<=0;}
I64 E3(I64 a){return a>0;}
I64 E4(I64 a){return a>=0;}
I64 E5(I64 a){return a==0;}
I64 E6(I64 a){return a!=0;}
I64 E7(I64 a){return a<5;}
I64 E8(I64 a){return a==1000;}
I64 E9(I64 a){return a!=-1;}
I64 E10(I64 a){return a>4096;}
I64 E11(I64 a){return a<0x123456789;}
I64 E12(I64 a){return a==0x100000000;}
I64 E13(U64 a){return a<10;}
I64 E14(U64 a){return a>=10;}
I64 E15(U64 a){return a==0;}
I64 E16(I64 a,I64 b){if(a<b)return 1;return 0;}
I64 E17(I64 a,I64 b){if(a<=b)return 1;else return 2;}
I64 E18(I64 a,I64 b){if(a==b)return 1;return 2;}
I64 E19(I64 a,I64 b){if(a!=b)return 1;return 2;}
I64 E20(U64 a,U64 b){if(a>b)return 1;return 2;}
I64 E21(U64 a,U64 b){if(a>=b)return 1;return 2;}
I64 E22(U64 a,U64 b){if(a<b)return 1;return 2;}
I64 E23(U64 a,U64 b){if(a<=b)return 1;return 2;}
I64 E24(I64 a){if(a)return 1;return 2;}
I64 E25(I64 a){if(!a)return 1;return 2;}
I64 E26(I64 a){if(a==0)return 1;return 2;}
I64 E27(I64 a){if(a<0)return 1;return 2;}
I64 E28(U8 a,U8 b){if(a<b)return 1;return 2;}
I64 E29(I8 a,I8 b){if(a<b)return 1;return 2;}
I64 E30(U16 a,I16 b){if(a==b)return 1;return 2;}
I64 E31(I32 a,U32 b){if(a<b)return 1;return 2;}
I64 E32(I64 a){return a<gi;}
I64 E33(){return gi<gu;}
I64 E34(I64 a,I64 b){return (a<b)+(a>b)*2+(a==b)*4;}
I64 E35(I64 a,I64 b){return (a<b)==(b<a);}
I64 F1(I64 a,I64 b){return a&&b;}
I64 F2(I64 a,I64 b){return a||b;}
I64 F3(I64 a,I64 b){return a^^b;}
I64 F4(I64 a,I64 b,I64 c){return a&&b&&c;}
I64 F5(I64 a,I64 b,I64 c){return a||b||c;}
I64 F6(I64 a,I64 b,I64 c){return a&&(b||c);}
I64 F7(I64 a,I64 b,I64 c){return (a||b)&&c;}
I64 F8(I64 a,I64 b,I64 c){return a^^b^^c;}
I64 F9(I64 a,I64 b,I64 c){return (a&&b)^^c;}
I64 F10(I64 a,I64 b,I64 c){return !(a&&b)||c;}
I64 F11(I64 a,I64 b,I64 c){return !a&&!b;}
I64 F12(I64 a,I64 b,I64 c){return !(a||b)&&c;}
I64 F13(I64 a,I64 b){if(a&&b)return 1;return 2;}
I64 F14(I64 a,I64 b){if(a||b)return 1;return 2;}
I64 F15(I64 a,I64 b){if(a^^b)return 1;return 2;}
I64 F16(I64 a,I64 b,I64 c){if(a&&b||c)return 1;return 2;}
I64 F17(I64 a,I64 b,I64 c){if(a<b&&b<c)return 1;return 2;}
I64 F18(I64 a,I64 b,I64 c){if(a<b||b<c&&c<a)return 1;return 2;}
I64 F19(I64 a,I64 b){if(!(a<b))return 1;return 2;}
I64 F20(I64 a,I64 b){if(!(a&&b))return 1;return 2;}
I64 F21(I64 a,I64 b){if(!a||!b)return 1;return 2;}
I64 F22(I64 *p,I64 a){if(p&&*p==a)return 1;return 2;}
I64 F23(I64 *p){if(!p||*p==0)return 1;return 2;}
I64 F24(U8 *s){if(s&&*s)return 1;return 2;}
I64 F25(I64 a,I64 b){I64 r=0;if(a&&(r=b))r++;return r;}
I64 F26(I64 a,I64 b){I64 r=0;a&&(r=b);return r;}
I64 F27(I64 a,I64 b){I64 r=0;a||(r=b);return r;}
