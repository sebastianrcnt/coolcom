/* C source for both the native reference and the Cool translation.
   The overrides only replace stb's platform hooks; stb_truetype.h is intact. */
#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_RASTERIZER_VERSION 1
typedef __SIZE_TYPE__ size_t;
#define NULL ((void *) 0)

extern void *malloc(unsigned long);
extern void free(void *);
extern void *memcpy(void *, const void *, unsigned long);
extern void *memset(void *, int, unsigned long);
extern double floor(double);
extern double ceil(double);
extern double sqrt(double);
extern double fabs(double);
extern double fmod(double, double);
extern double cos(double);
extern double acos(double);
extern double pow(double, double);
extern unsigned long strlen(const char *);

#define STBTT_malloc(size, userdata) malloc(size)
#define STBTT_free(ptr, userdata) free(ptr)
#define STBTT_memcpy memcpy
#define STBTT_memset memset
#define STBTT_strlen strlen
#define STBTT_assert(condition) ((void) 0)
#define STBTT_ifloor(x) ((int) floor(x))
#define STBTT_iceil(x) ((int) ceil(x))
#define STBTT_sqrt(x) sqrt(x)
#define STBTT_pow(x,y) pow(x,y)
#define STBTT_fmod(x,y) fmod(x,y)
#define STBTT_cos(x) cos(x)
#define STBTT_acos(x) acos(x)
#define STBTT_fabs(x) fabs(x)

#include "../../vendor/stb/stb_truetype.h"
