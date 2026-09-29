#include "TestBase.HH"
I64 gc=0;
I64 F1(I64 a){if(a>0)return 1;else if(a<0)return -1;else return 0;}
I64 F2(I64 a){if(a==1)return 10;else if(a==2)return 20;else if(a==3)return 30;else if(a==4)return 40;return 0;}
I64 F3(I64 a,I64 b){if(a){if(b)return 3;else return 2;}else{if(b)return 1;}return 0;}
I64 F4(I64 a){I64 r=0;if(a&1)r|=1;if(a&2)r|=2;if(a&4)r|=4;return r;}
I64 F5(I64 a){I64 r;if(a<10)r=1;else r=2;return r;}
U0 F6(I64 a){if(a)gc++;}
U0 F7(I64 a){if(!a)return;gc+=2;}
I64 W1(I64 n){I64 s=0;while(n>0){s+=n;n--;}return s;}
I64 W2(I64 n){I64 s=0;while(1){if(n<=0)break;s+=n;n--;}return s;}
I64 W3(I64 n){I64 s=0,i=0;while(i<n){i++;if(i&1)goto skip;s+=i;skip:;}return s;}
I64 W4(I64 n){I64 s=0;do{s+=n;n--;}while(n>0);return s;}
I64 W5(I64 n){I64 s=0;do{s++;if(s>n)break;}while(1);return s;}
I64 W6(I64 a,I64 b){while(a!=b){if(a>b)a-=b;else b-=a;}return a;}
I64 W7(I64 n){I64 r=1;while(n)r*=n--;return r;}
I64 W8(){while(gc<10)gc++;return gc;}
I64 W9(U8 *s){I64 h=0;while(*s){h=h*31+*s;s++;}return h;}
I64 W10(I64 n){while(n>100)n/=2;return n;}
I64 X1(I64 n){I64 i,s=0;for(i=0;i<n;i++)s+=i;return s;}
I64 X2(I64 n){I64 i,j,s=0;for(i=0;i<n;i++)for(j=0;j<i;j++)s+=i*j;return s;}
I64 X3(I64 n){I64 i,s=0;for(i=n;i;i--)s+=i;return s;}
I64 X4(I64 n){I64 i=0,s=0;for(;i<n;i++)s+=i;return s;}
I64 X5(I64 n){I64 s=0;I64 i;for(i=0;i<n;i+=2)s+=i;return s;}
I64 X6(){I64 i;for(i=0;1;i++)if(i>50)break;return i;}
I64 X7(I64 n){I64 i,j,s=0;for(i=0;i<n;i++){for(j=0;j<n;j++){if(j>i)break;s++;}if(i>7)break;}return s;}
I64 X8(I64 n){I64 i,j,s=0;for(i=0;i<n;i++){for(j=0;j<n;j++){if(i*j>20)goto done;s+=j;}}done:return s;}
I64 X9(I64 n){I64 i,j,k,s=0;for(i=0;i<n;i++)for(j=0;j<n;j++)for(k=0;k<n;k++)s+=i^j^k;return s;}
I64 X10(I64 *a,I64 n){I64 i,m=a[0];for(i=1;i<n;i++)if(a[i]>m)m=a[i];return m;}
U0 X11(I64 *a,I64 n){I64 i,j,t;for(i=0;i<n;i++)for(j=0;j<n-1-i;j++)if(a[j]>a[j+1]){t=a[j];a[j]=a[j+1];a[j+1]=t;}}
I64 X12(F64 a){I64 n=0;F64 x;for(x=0;x<a;x+=0.25)n++;return n;}
I64 G1(I64 n){I64 s=0;top:if(n<=0)goto out;s+=n;n--;goto top;out:return s;}
I64 G2(I64 a){if(a)goto L1;a=5;L1:a++;goto L2;a=100;L2:return a;}
I64 G3(I64 n){I64 s=0;a1:s++;if(s<n)goto a1;b1:s+=10;if(s<50)goto b1;return s;}
I64 H1(I64 a){I64 r=0;{I64 t=a*2;r+=t;}{I64 u=a*3;r+=u;}return r;}
I64 H2(I64 a){I64 r=0;if(a){I64 q=a+1;r=q;}else{I64 w=a-1;r=w;}return r;}
I64 H3(I64 a){;;;return a;}
I64 H4(I64 a){a;a+1;return a;}
U0 H5(){}
U0 H6(){return;}
I64 H7(){return 1;return 2;}
I64 H8(I64 a){if(a)return 1;else return 2;return 3;}
I64 H9(I64 a){for(;1;){if(a++>5)return a;}}
I64 H10(I64 a){while(1){a++;if(a>10)return a;}}
I64 H11(I64 a){do{a+=3;}while(a<20);return a;}
I64 H12(I64 a,I64 b){I64 r=a;if(b)r=a+b;else r=a-b;return r;}
I64 H13(I64 a){if(a<0)a=-a;return a;}
I64 H14(I64 a,I64 b){if(a<b){I64 t=a;a=b;b=t;}return a-b;}
I64 H15(I64 a){I64 r=0;if(a==0)r=1;if(a==1)r=2;if(a==2)r=3;return r;}
