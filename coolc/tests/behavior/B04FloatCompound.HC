U0 FloatCompound()
{
    F64 a = 1.0;
    a |= 2.0;
    Print("or %X\n", a(I64));
    a = 1.0;
    a &= 2.0;
    Print("and %X\n", a(I64));
    a = 1.0;
    a ^= 2.0;
    Print("xor %X\n", a(I64));
    a = 1.0;
    a <<= 1;
    Print("left %X\n", a(I64));
    a = 1.0;
    a >>= 1;
    Print("right %X\n", a(I64));
    F64 *p = &a;
    *p |= 2.0;
    Print("ptr %X\n", a(I64));
}
FloatCompound();
