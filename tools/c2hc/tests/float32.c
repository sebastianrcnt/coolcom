#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stddef.h>
#include <math.h>

static void bits(float x) {
    uint32_t u;
    memcpy(&u, &x, sizeof u);
    printf("%08x\n", u);
}
static float step(float x, float y) { return (x + y) / 3.0f; }
static float *identity(float *p) { return p; }
static float global[] = {0.1f, -0.0f, 0x1p-149f, 0x1.fffffep127f};
struct Layout { char a; float b; float c[3]; double d; char e; };
union Value { float f; uint32_t u; };
int main(void) {
    float sum = 0.0f, a = 16777216.0f, b = 1.0f;
    float values[8];
    uint32_t copy[8];
    struct Layout r;
    union Value v;
    float (*fp)(float, float) = step;
    int i;
    float (*root)(float) = sqrtf;
    float nan = NAN, inf = INFINITY;
    for (i = 0; i < 10000; ++i) sum += 0.1f;
    bits(sum);
    bits((a + b) - a);
    bits((a - b) * 0.1f);
    bits(1.0f / 3.0f);
    bits(sqrtf(2.0f));
    bits(root(2.0f));
    bits(__builtin_sqrtf(2.0f));
    printf("%d %d %d %d\n", !nan, (_Bool)nan, !(-0.0f), (_Bool)inf);
    printf("%d %d %d %d %d %d\n", nan == nan, nan != nan, nan < inf, nan <= inf, nan > inf, nan >= inf);
    bits(inf);
    bits(1e50f);
    bits(sqrtf(0x1p-149f));
    bits((float)(a + 1.0));
    bits((float)((double)a + b));
    printf("%d %d %d %d\n", a + b == a, a + 1.0 > a, (int)-3.75f, (unsigned)4294967040.0f == 4294967040U);
    bits((float)16777217);
    bits((float)9223372586610589697ULL);
    bits((float)-9223372586610589697.0);
    bits((float)0x1.000001p0);
    bits((float)0x1.000003p0);
    bits((float)0x1.0000000000001p-150);
    bits((float)0x1p-150);
    bits((float)0x1.fffffep-127);
    bits((float)0x1.ffffffp127);
    bits(-0.0f / 3.0f);
    bits(step(0.1f, 0.2f));
    bits(fp(0.1f, 0.2f));
    bits(global[2]);
    printf("%zu %zu %zu %zu %zu %zu %zu\n", sizeof(float), sizeof r, offsetof(struct Layout, b), offsetof(struct Layout, c), offsetof(struct Layout, d), offsetof(struct Layout, e), sizeof v);
    r.b = 0.1f;
    r.c[0] = 0.2f;
    r.c[1] = r.b + r.c[0];
    bits(r.c[1]);
    v.f = 1.5f;
    printf("%08x\n", v.u);
    for (i = 0; i < 4; ++i) values[i] = global[i];
    values[4] = 1.0f / 7.0f;
    values[5] = sqrtf(3.0f);
    values[6] = 2.0f;
    values[7] = 4.0f;
    bits((*identity(&values[6]))++);
    bits(++(*identity(&values[7])));
    values[6] *= 0.1;
    values[7] /= 3.0f;
    memcpy(copy, values, sizeof values);
    for (i = 0; i < 8; ++i) printf("%08x\n", copy[i]);
    printf("%.9f %.9f\n", sum, 0.1f);
    return 0;
}
