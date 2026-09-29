int printf(const char *, ...);
int main(void) {
    int sum = 0;
    for (int i = 0; i < 8; i++) {
        if (i % 2 == 0) continue;
        sum += i;
    }
    printf("continue %d\n", sum);
    return 0;
}
