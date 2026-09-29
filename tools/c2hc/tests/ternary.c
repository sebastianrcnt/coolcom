int printf(const char *, ...);
int choose(int a, int b) { return a > b ? a : b; }
int main(void) {
    int n = 4, sum = 0;
    while (n > 0) {
        sum += choose(n, 2);
        n--;
    }
    int result = 0;
    result = sum > 0 ? sum : -sum;
    printf("ternary %d\n", result);
    return 0;
}
