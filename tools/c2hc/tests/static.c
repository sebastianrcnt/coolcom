int printf(const char *, ...);
int next(void) { static int value = 5; value += 2; return value; }
int main(void) {
    printf("static %d\n", next());
    printf("static %d\n", next());
    return 0;
}
