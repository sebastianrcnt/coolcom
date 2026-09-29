int printf(const char *, ...);
int sum(int *p, int n) {
    int s = 0;
    for (int i = 0; i < n; i++) s += p[i];
    return s;
}
int main(void) {
    int a[4] = {2, 4, 6, 8};
    int *p = a;
    printf("arrays %d %d\n", sum(p, 4), *(p + 2));
    return 0;
}
