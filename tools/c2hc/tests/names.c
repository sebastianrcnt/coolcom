int printf(const char *, ...);
int main(void) {
    int reg = 9;
    int flag = reg > 3;
    printf("names %d %s\n", flag + reg, "ok");
    return 0;
}
