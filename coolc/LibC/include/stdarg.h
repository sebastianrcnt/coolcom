#ifndef _LC_STDARG_H
#define _LC_STDARG_H
/* A variadic Cool function sees its arguments as 64-bit slots argv[0..argc). c2hc maps the
   magic names __c2h_argv and __c2h_argc to them. va_arg reads a slot as the type asked for
   (an int is the slot's low 32 bits, a double is the slot's bits). */
struct LC_VA { long *argv; long i; long n; };
typedef struct LC_VA va_list[1];
extern long *__c2h_argv;
extern long __c2h_argc;
#define va_start(ap, last) ((ap)->argv = __c2h_argv, (ap)->i = 0, (ap)->n = __c2h_argc)
#define va_arg(ap, T) (*(T *)&(ap)->argv[(ap)->i++])
#define va_end(ap) ((void)0)
#define va_copy(dst, src) (*(dst) = *(src))
#endif
