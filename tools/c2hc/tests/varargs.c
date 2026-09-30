#include <stdio.h>
#include <stdarg.h>
int add(int n, ...) { va_list ap; va_start(ap,n); int r=0; for(int i=0;i<n;i++)r+=va_arg(ap,int); va_end(ap); return r; }
int main(void) {printf("varargs %d\n",add(3,2,4,6)); return 0;}
