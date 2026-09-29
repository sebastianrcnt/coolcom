#include <stdio.h>

typedef struct { int left, right; } pair;

int main(void) {
    pair p = {2, 3};
    float f = 3.75f;
    int value = (int)f;
    switch (p.left) {
    case 2: value += p.right; break;
    default: value = 0;
    }
    {
        int value = 8;
        printf("%d ", value);
    }
    goto done;
    value = 1;
done:
    printf("%d %d\n", value, (int)sizeof(p));
    return 0;
}
