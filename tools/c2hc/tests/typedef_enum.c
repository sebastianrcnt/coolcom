#include <stdio.h>

typedef unsigned short word;
enum { base = 3, next, last = 9 };

int main(void) {
    word x = base + next + last;
    printf("%d\n", x);
    return 0;
}
