int printf(const char *, ...);
int main(void) {
    int reg = 9;
    int flag = reg > 3;
    printf("names %d\n", flag + reg);
    return 0;
}
