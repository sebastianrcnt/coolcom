#include "TestBase.HH"
U8 sieve[1000];
I64 tbl[64];
F64 mat[16];
U0 MemCpy8(U8 *d,U8 *s,I64 n){while(n--)*d++=*s++;}
U0 MemSet8(U8 *d,I64 v,I64 n){I64 i;for(i=0;i<n;i++)d[i]=v;}
I64 StrLen(U8 *s){U8 *p=s;while(*p)p++;return p-s;}
I64 StrCmp(U8 *a,U8 *b){while(*a&&*a==*b){a++;b++;}return *a-*b;}
U8 *StrCpy(U8 *d,U8 *s){U8 *r=d;while(*d++=*s++);return r;}
U8 *StrChr(U8 *s,I64 c){while(*s){if(*s==c)return s;s++;}return NULL;}
I64 Atoi(U8 *s){I64 n=0,neg=0;if(*s=='-'){neg=1;s++;}while(*s>='0'&&*s<='9'){n=n*10+*s-'0';s++;}if(neg)return -n;return n;}
I64 Itoa(U8 *d,I64 n){U8 tmp[24];I64 i=0,j=0;if(n<0){d[j++]='-';n=-n;}if(!n)tmp[i++]='0';while(n){tmp[i++]='0'+n%10;n/=10;}while(i)d[j++]=tmp[--i];d[j]=0;return j;}
I64 Hash(U8 *s){I64 h=5381;while(*s)h=(h<<5)+h+*s++;return h;}
I64 Fnv(U8 *s){U64 h=0xCBF29CE484222325;while(*s){h^=*s++;h*=0x100000001B3;}return h;}
I64 Crc(U8 *p,I64 n){U32 c=0xFFFFFFFF;I64 i,k;for(i=0;i<n;i++){c^=p[i];for(k=0;k<8;k++)if(c&1)c=c>>1^0xEDB88320;else c>>=1;}return ~c;}
I64 PopCnt(U64 x){I64 n=0;while(x){x&=x-1;n++;}return n;}
I64 Clz(U64 x){I64 n=0;if(!x)return 64;while(!(x&0x8000000000000000)){x<<=1;n++;}return n;}
I64 Bsr(U64 x){I64 n=-1;while(x){x>>=1;n++;}return n;}
I64 Rev(U64 x){I64 r=0,i;for(i=0;i<64;i++){r=r<<1|x&1;x>>=1;}return r;}
I64 Isqrt(I64 n){I64 x=n,y=(x+1)/2;while(y<x){x=y;y=(x+n/x)/2;}return x;}
I64 Sieve(I64 n){I64 i,j,c=0;MemSet8(sieve,1,n);for(i=2;i<n;i++)if(sieve[i]){c++;for(j=i*i;j<n;j+=i)sieve[j]=0;}return c;}
I64 Fibo(I64 n){I64 a=0,b=1,t;while(n--){t=a+b;a=b;b=t;}return a;}
I64 Collatz(I64 n){I64 c=0;while(n!=1){if(n&1)n=3*n+1;else n>>=1;c++;}return c;}
I64 PowMod(I64 b,I64 e,I64 m){I64 r=1;b%=m;while(e){if(e&1)r=r*b%m;b=b*b%m;e>>=1;}return r;}
I64 Bin(I64 *a,I64 n,I64 x){I64 lo=0,hi=n-1,mid;while(lo<=hi){mid=(lo+hi)>>1;if(a[mid]==x)return mid;if(a[mid]<x)lo=mid+1;else hi=mid-1;}return -1;}
U0 Isort(I64 *a,I64 n){I64 i,j,k;for(i=1;i<n;i++){k=a[i];j=i-1;while(j>=0&&a[j]>k){a[j+1]=a[j];j--;}a[j+1]=k;}}
U0 Qsort(I64 *a,I64 lo,I64 hi){I64 i=lo,j=hi,p=a[(lo+hi)/2],t;while(i<=j){while(a[i]<p)i++;while(a[j]>p)j--;if(i<=j){t=a[i];a[i]=a[j];a[j]=t;i++;j--;}}if(lo<j)Qsort(a,lo,j);if(i<hi)Qsort(a,i,hi);}
U0 Rev8(U8 *s,I64 n){I64 i;U8 t;for(i=0;i<n/2;i++){t=s[i];s[i]=s[n-1-i];s[n-1-i]=t;}}
I64 Dot(I64 *a,I64 *b,I64 n){I64 i,s=0;for(i=0;i<n;i++)s+=a[i]*b[i];return s;}
U0 MatMul(F64 *c,F64 *a,F64 *b){I64 i,j,k;for(i=0;i<4;i++)for(j=0;j<4;j++){F64 s=0;for(k=0;k<4;k++)s+=a[i*4+k]*b[k*4+j];c[i*4+j]=s;}}
F64 Trace(F64 *m){return m[0]+m[5]+m[10]+m[15];}
F64 Newton(F64 x){F64 g=x/2;I64 i;for(i=0;i<20;i++)g=(g+x/g)/2;return g;}
F64 Horner(F64 *c,I64 n,F64 x){F64 r=0;I64 i;for(i=n-1;i>=0;i--)r=r*x+c[i];return r;}
F64 Mean(F64 *a,I64 n){F64 s=0;I64 i;for(i=0;i<n;i++)s+=a[i];return s/n;}
F64 Var(F64 *a,I64 n){F64 m=Mean(a,n),s=0,d;I64 i;for(i=0;i<n;i++){d=a[i]-m;s+=d*d;}return s/n;}
F64 Fabs(F64 x){if(x<0)return -x;return x;}
F64 Fmax(F64 a,F64 b){if(a>b)return a;return b;}
I64 Floor(F64 x){I64 i=x;if(i>x)i--;return i;}
F64 Lerp(F64 a,F64 b,F64 t){return a+(b-a)*t;}
F64 Sin(F64 x){F64 t=x,s=x,x2=x*x;I64 i;for(i=1;i<10;i++){t*=-x2/((2*i)*(2*i+1));s+=t;}return s;}
I64 Gray(I64 n){return n^n>>1;}
I64 Parity(U64 x){x^=x>>32;x^=x>>16;x^=x>>8;x^=x>>4;x^=x>>2;x^=x>>1;return x&1;}
I64 Swap16(I64 x){return (x&0xFF)<<8|x>>8&0xFF;}
I64 Rotl(U64 x,I64 n){return x<<n|x>>64-n;}
I64 Min(I64 a,I64 b){if(a<b)return a;return b;}
I64 Max(I64 a,I64 b){if(a>b)return a;return b;}
I64 Clamp(I64 x,I64 lo,I64 hi){return Min(Max(x,lo),hi);}
I64 Abs(I64 x){if(x<0)return -x;return x;}
I64 Sgn(I64 x){if(x>0)return 1;if(x<0)return -1;return 0;}
I64 Tbl(){I64 i;for(i=0;i<64;i++)tbl[i]=i*i-i;return tbl[63];}
I64 Life(U8 *g,I64 w,I64 h,I64 x,I64 y){I64 dx,dy,n=0;for(dy=-1;dy<=1;dy++)for(dx=-1;dx<=1;dx++){if(dx||dy){I64 nx=x+dx,ny=y+dy;if(nx>=0&&nx<w&&ny>=0&&ny<h)n+=g[ny*w+nx];}}return n;}
I64 Lcg(I64 s){return s*6364136223846793005+1442695040888963407;}
I64 Xorshift(U64 s){s^=s<<13;s^=s>>7;s^=s<<17;return s;}
I64 Bubble(I64 *a,I64 n){I64 i,j,t,sw=0;for(i=0;i<n;i++)for(j=0;j<n-i-1;j++)if(a[j]>a[j+1]){t=a[j];a[j]=a[j+1];a[j+1]=t;sw++;}return sw;}
