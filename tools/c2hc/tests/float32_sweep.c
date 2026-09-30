#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

static uint64_t hash = 0;
static void add(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    hash = hash * 33 + u;
}
static uint64_t next(uint64_t *state) {
    *state = *state * 6364136223846793005ULL + 1442695040888963407ULL;
    return *state;
}
int main(void) {
    uint64_t state = 42, raw;
    uint32_t u, v;
    float a, b;
    double d;
    int chunk, i;
    for (chunk = 0; chunk < 16; ++chunk) {
        for (i = 0; i < 256; ++i) {
            /* Finite operands, including subnormals, with a nonzero divisor. */
            u = (uint32_t)next(&state);
            v = (uint32_t)next(&state);
            if ((u & 0x7f800000) == 0x7f800000) u ^= 0x00800000;
            if ((v & 0x7f800000) == 0x7f800000) v ^= 0x00800000;
            v |= 1;
            memcpy(&a, &u, 4);
            memcpy(&b, &v, 4);
            add(a); add(b);
            add(a + b); add(a - b); add(a * b); add(a / b);
            add(sqrtf(a < 0 ? -a : a));
            raw = next(&state);
            d = (double)raw;
            {uint64_t db; memcpy(&db, &d, 8); hash = hash * 33 + db;}
            add((float)raw);
            add((float)(int64_t)raw);
            /* Every binary64 exponent, rounded at the binary32 boundary. */
            if ((raw & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL)
                raw ^= 0x0010000000000000ULL;
            memcpy(&d, &raw, 8);
            add((float)d);
        }
        printf("%016llx\n", (unsigned long long)hash);
    }
    return 0;
}
