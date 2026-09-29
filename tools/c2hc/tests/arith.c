int printf(const char *, ...);
int square(int x) { return x * x; }
int main(void) {
    int a = 7, b = 3;
    printf("arith %d %d %d\n", square(a) + b, a / b, (a + b) * 2);
    return 0;
}
