int printf(const char *, ...);
struct Pair { int x; int y; int z; };
int main(void) {
    struct Pair a, b;
    a.x = 11; a.y = 12; a.z = 13;
    b.x = 3; b.y = 4; b.z = 5;
    a = b;
    struct Pair *p = &a;
    printf("struct %d %d %d\n", p->x, a.y, a.z);
    return 0;
}
