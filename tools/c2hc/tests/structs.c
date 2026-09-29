int printf(const char *, ...);
struct Pair { int x; int y; };
int main(void) {
    struct Pair a, b;
    a.x = 11; a.y = 12;
    b.x = 3; b.y = 4;
    a = b;
    struct Pair *p = &a;
    printf("struct %d %d\n", p->x, a.y);
    return 0;
}
