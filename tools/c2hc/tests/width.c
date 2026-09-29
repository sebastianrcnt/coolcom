int printf(const char *, ...);
int main(void) {
    unsigned int x = 0xffffffffu;
    unsigned int y = x + 3u;
    printf("width %d\n", (int)y);
    return 0;
}
