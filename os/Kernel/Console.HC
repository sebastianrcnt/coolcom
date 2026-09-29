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

I64 Utf8Len(I64 lead)
{//Bytes in the UTF-8 sequence that lead starts: 1 for ASCII, 0 for a continuation or invalid byte.
    if (lead < 0x80)
        return 1;
    if (lead >= 0xC2 && lead <= 0xDF)
        return 2;
    if (lead >= 0xE0 && lead <= 0xEF)
        return 3;
    if (lead >= 0xF0 && lead <= 0xF4)
        return 4;
    return 0;
}

I64 Utf8Width(I64 cp)
{//Terminal columns a code point takes: 2 for Hangul, CJK and fullwidth forms, 0 for combining marks.
    if ((cp >= 0x300 && cp <= 0x36F) || (cp >= 0x200B && cp <= 0x200F) || (cp >= 0xFE00 && cp <= 0xFE0F))
        return 0;
    if ((cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0xA4CF) || (cp >= 0xAC00 && cp <= 0xD7A3) ||
            (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0xFE30 && cp <= 0xFE6F) || (cp >= 0xFF00 && cp <= 0xFF60) ||
            (cp >= 0xFFE0 && cp <= 0xFFE6) || (cp >= 0x20000 && cp <= 0x3FFFD))
        return 2;
    return 1;
}

I64 Utf8Cp(U8 *s, I64 k)
{//Code point of the k-byte sequence at s.
    I64 cp, i;
    if (k <= 1)
        return *s;
    cp = *s & (0x7F >> k);
    for (i = 1; i < k; i++)
        cp = (cp << 6) | (s[i] & 0x3F);
    return cp;
}

U0 ConsPutS(U8 *s)
{
    while (*s)
        ConsPut(*s++);
}

// (PutChars, which bare character statements compile to, is TempleOS's, in
// coolc/Runtime/StrPrint.HC; it prints through PutS, KPrint.HC.)
