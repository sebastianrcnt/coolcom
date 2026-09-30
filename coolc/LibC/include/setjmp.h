#ifndef _LC_SETJMP_H
#define _LC_SETJMP_H
/* setjmp is a function only to the parser: c2hc turns a call into AIWNIOS_SetJmp(buf), which must
   run in the function that calls it. */
typedef long jmp_buf[24];
int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);
#endif
