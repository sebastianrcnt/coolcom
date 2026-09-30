#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <setjmp.h>
static jmp_buf ctx;
static void jump(void) { longjmp(ctx, 7); }
int main(void) {
    char *p = calloc(8, 1), b[100];
    strcpy(p, "abc"); p = realloc(p, 64);
    memmove(p + 1, p, 4);
    printf("memory %s %d %zu\n", p, memcmp("a", "b", 1) < 0, strlen(p));
    snprintf(b, sizeof b, "%08x %.2f %s", 42, 1.25, "ok");
    printf("format %s\n", b);
    FILE *f = fopen("build/c2hc-test/io.tmp", "w+");
    fwrite("file", 1, 4, f); rewind(f);
    memset(b, 0, sizeof b); fread(b, 1, 4, f); fclose(f);
    printf("file %s\n", b);
    printf("math %.1f %.1f\n", sqrt(9), fmod(7, 2));
    time_t t = 0; struct tm *tm = gmtime(&t);
    strftime(b, sizeof b, "%Y-%m-%d", tm); printf("time %s\n", b);
    int n = setjmp(ctx); if (!n) jump(); printf("jump %d\n", n);
    free(p); return 0;
}
