#include "TestBase.HH"
I64 S1(I64 a){switch(a){case 0:return 10;case 1:return 11;case 2:return 12;case 3:return 13;default:return -1;}}
I64 S2(I64 a){switch(a){case 0:case 1:case 2:return 1;case 3:case 4:return 2;}return 0;}
I64 S3(I64 a){I64 r=0;switch(a){case 0:r+=1;case 1:r+=2;case 2:r+=4;break;case 3:r+=8;}return r;}
I64 S4(I64 a){switch(a){case 1...5:return 1;case 6...10:return 2;case 20...30:return 3;default:return 0;}}
I64 S5(I64 a){switch(a){case 'A'...'Z':return 1;case 'a'...'z':return 2;case '0'...'9':return 3;}return 0;}
I64 S6(I64 a){switch(a){case 1:return 1;case 100:return 2;case 1000:return 3;case -5:return 5;default:return 0;}}
I64 S9(I64 a){switch(a){case 3:return 1;}return 0;}
I64 S10(I64 a){I64 r=0;switch(a){case 0:r=1;break;case 1:r=2;break;case 2:r=3;break;default:r=4;}return r;}
I64 S11(I64 a){I64 r=0;switch(a){case 0:r=1;break;default:r=5;case 5:r+=2;}return r;}
I64 S12(I64 a,I64 b){switch(a){case 0:switch(b){case 0:return 1;case 1:return 2;}break;case 1:switch(b){case 0:return 3;default:return 4;}}return 0;}
I64 S13(U8 a){switch(a){case 0...31:return 1;case 127:return 2;case 128...255:return 3;default:return 0;}}
I64 S14(I64 a){I64 i,s=0;for(i=0;i<a;i++){switch(i&3){case 0:s+=1;break;case 1:s+=10;break;case 2:s+=100;break;case 3:s+=1000;}}return s;}
I64 S15(I64 a){switch(a){case -3...-1:return 1;case 0:return 2;case 1...3:return 3;}return 0;}
I64 S16(I64 a){switch(a){case 0x100:return 1;case 0x200:return 2;case 0x300:return 3;case 0x400:return 4;case 0x500:return 5;}return 0;}
I64 S17(I64 a){I64 r=0;switch(a){start:r+=1;case 0:r+=2;case 1:r+=4;end:r+=8;}return r;}
I64 S18(I64 a){I64 r=0;switch(a){case 0:r+=1;break;case 1:r+=2;start:r+=100;case 2:r+=200;break;case 3:r+=300;end:r+=1000;}return r;}
I64 S19(I64 a){I64 r=0;switch(a){case 0:r=1;start:switch(r){case 1:r=10;break;case 2:r=20;}end:r++;}return r;}
I64 S20(I64 a){switch[a]{case 0:return 1;case 1:return 2;case 2:return 3;}return 0;}
I64 S21(I64 a){switch[a]{case 3:return 1;case 4:return 2;case 5...7:return 3;default:return 9;}}
I64 S22(I64 a){switch(a){case 0:{I64 t=a+1;return t;}case 1:{I64 u=a+2;return u;}}return 0;}
I64 S23(I64 a){switch(a&7){case 0:return 0;case 1:return 1;case 2:return 4;case 3:return 9;case 4:return 16;case 5:return 25;case 6:return 36;case 7:return 49;}return -1;}
U0 S24(I64 a){switch(a){case 0:"zero\n";break;case 1:"one\n";break;default:"many %d\n",a;}}
I64 S25(I64 a){switch(a){case 10:return 1;case 11:return 2;case 12:return 3;case 13:return 4;case 14:return 5;case 15:return 6;case 16:return 7;case 17:return 8;case 18:return 9;case 19:return 10;}return 0;}
I64 S26(I64 a){switch(a){case 0:goto L;case 1:return 5;}return 0;L:return 77;}
I64 S27(I64 a){I64 r=0;while(a){switch(a){case 1:r++;break;case 2:r+=2;break;default:r+=10;}a--;}return r;}
I64 S28(I64 a){I64 r=0;switch(a){case 1:r=1;case 2:r=2;case 3:r=3;}return r;}
I64 S29(I64 a){switch(a){case 5...5:return 1;}return 0;}
I64 S30(I64 a){switch(a){case 0...255:return 1;case 256...300:return 2;}return 0;}
I64 S7(I64 a){switch(a){case 5:return 1;case 6:return 2;case 7:return 3;case 9:return 4;case 12:return 5;}return 0;}
