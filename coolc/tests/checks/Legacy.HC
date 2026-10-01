#include "../../Frontend/KernelA.coolh"
// Legacy TempleOS/Aiwnios code: the strict errors of Errors.cool are only Vet findings in .HC/.HH files
// (tools/native/checks.sh compiles this as Legacy.HC, as a .cool with and without --compat).
U0 Unused()
{
    I64 forgotten;
    Print("a\n");
}
U0 Compare(U8 *s, U8 *p)
{
    if (s == "abc") Print("b\n");
    if (p == 5) Print("c\n");
    Print("%d %d\n", 1);
}
extern I64 Declared(I64 a, U8 *b);
I64 Declared(I64 a, I64 b)
{
    return a + b;
}
I64 NoReturn()
{
    Print("d\n");
}
