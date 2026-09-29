int printf(const char *, ...);
int choose(int a, int b) { return a > b ? a : b; }
int main(void) {
    int n = 4, sum = 0;
    while (n > 0) {
        sum += choose(n, 2);
        n--;
    }
    printf("ternary %d\n", sum);
    return 0;
}
