// Console outputs. Print(), PutChars() and the input echo send every character
// to each registered output (UART first, then the framebuffer console), so a
// new output only needs ConsAdd(&MyPut).
#define CONS_OUTS 4
U8 *cons_out[CONS_OUTS];
I64 cons_nout;

U0 ConsAdd(U0 (*put)(U8 c))
{
    if (cons_nout < CONS_OUTS)
        cons_out[cons_nout++] = put;
}

U0 ConsPut(U8 c)
{
    I64 i;
    U0 (*fp)(U8 c);
    for (i = 0; i < cons_nout; i++) {
        fp = cons_out[i];
        (*fp)(c);
    }
}

U0 ConsPutS(U8 *s)
{
    while (*s)
        ConsPut(*s++);
}

U0 PutChars(U64 ch)
{//Bare character statements ('a'; '\n';) compile to this.
    while (ch) {
        ConsPut(ch & 0xFF);
        ch >>= 8;
    }
}
