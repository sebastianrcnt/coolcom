#ifndef _LC_MATH_H
#define _LC_MATH_H
#define HUGE_VAL (__builtin_huge_val())
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))
#define M_PI 3.14159265358979323846
double fabs(double x);
double floor(double x);
double ceil(double x);
double trunc(double x);
double round(double x);
double sqrt(double x);
float sqrtf(float x);
double fma(double x, double y, double z);
float fmaf(float x, float y, float z);
double exp(double x);
double log(double x);
double log2(double x);
double log10(double x);
double pow(double x, double y);
double sin(double x);
double cos(double x);
double tan(double x);
double asin(double x);
double acos(double x);
double atan(double x);
double atan2(double y, double x);
double sinh(double x);
double cosh(double x);
double tanh(double x);
double fmod(double x, double y);
double frexp(double x, int *e);
double ldexp(double x, int e);
double modf(double x, double *ip);
int isnan(double x);
int isinf(double x);
#endif
