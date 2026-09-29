// The primitives TempleOS has in assembly (and Aiwnios in C): memory and
// string routines, bit operations, pointer checks. The rest of the library is
// TempleOS's own, from coolc/Runtime (StrA.HC, StrB.HC, StrPrint.HC, ...).
// Multi-byte copies use unaligned 8-byte accesses (fine on Normal memory).

U8 *MemSet(U8 *dst, I64 val, I64 cnt)
{
    U8 *d = dst;
    I64 v = (val & 0xFF) * 0x0101010101010101;
    while (cnt >= 8) {
        *d(I64 *) = v;
        d += 8;
        cnt -= 8;
    }
    while (cnt-- > 0)
        *d++ = val;
    return dst;
}

// memmove semantics: overlap is fine.
U8 *MemCpy(U8 *dst, U8 *src, I64 cnt)
{
    U8 *d = dst, *s = src;
    if (d <= s || d >= s + cnt) {
        while (cnt >= 8) {
            *d(I64 *) = *s(I64 *);
            d += 8;
            s += 8;
            cnt -= 8;
        }
        while (cnt-- > 0)
            *d++ = *s++;
    } else {   // overlapping, copy backwards
        d += cnt;
        s += cnt;
        while (cnt >= 8) {
            d -= 8;
            s -= 8;
            *d(I64 *) = *s(I64 *);
            cnt -= 8;
        }
        while (cnt-- > 0)
            *--d = *--s;
    }
    return dst;
}

// <0, 0, >0 like memcmp.
I64 MemCmp(U8 *p1, U8 *p2, I64 cnt)
{
    while (cnt-- > 0) {
        if (*p1 != *p2)
            return *p1 - *p2;
        p1++;
        p2++;
    }
    return 0;
}

U8 *MemSetU16(U16 *dst, U16 val, I64 cnt)
{
    I64 i;
    for (i = 0; i < cnt; i++)
        dst[i] = val;
    return dst;
}

U8 *MemSetU32(U32 *dst, U32 val, I64 cnt)
{
    I64 i;
    for (i = 0; i < cnt; i++)
        dst[i] = val;
    return dst;
}

U8 *MemSetU64(U64 *dst, U64 val, I64 cnt)
{
    I64 i;
    for (i = 0; i < cnt; i++)
        dst[i] = val;
    return dst;
}

U8 *MemSetI64(I64 *dst, I64 val, I64 cnt)
{
    I64 i;
    for (i = 0; i < cnt; i++)
        dst[i] = val;
    return dst;
}

I64 StrLen(U8 *s)
{
    I64 n = 0;
    if (!s)
        return 0;
    while (s[n])
        n++;
    return n;
}

U8 *StrCpy(U8 *dst, U8 *src)
{
    U8 *d = dst;
    while (*d++ = *src++);
    return dst;
}

U8 *StrCat(U8 *dst, U8 *src)
{
    StrCpy(dst + StrLen(dst), src);
    return dst;
}

I64 StrCmp(U8 *s1, U8 *s2)
{
    while (*s1 && *s1 == *s2) {
        s1++;
        s2++;
    }
    return *s1 - *s2;
}

I64 StrNCmp(U8 *s1, U8 *s2, I64 n)
{
    while (n > 0 && *s1 && *s1 == *s2) {
        s1++;
        s2++;
        n--;
    }
    if (n <= 0)
        return 0;
    return *s1 - *s2;
}

I64 ToLower(I64 ch)
{
    if ('A' <= ch <= 'Z')
        return ch + 32;
    return ch;
}

I64 StrICmp(U8 *s1, U8 *s2)
{//Case-insensitive compare (compares upper-cased chars, like TempleOS).
    while (*s1 && ToUpper(*s1) == ToUpper(*s2)) {
        s1++;
        s2++;
    }
    return ToUpper(*s1) - ToUpper(*s2);
}

I64 StrNICmp(U8 *s1, U8 *s2, I64 n)
{
    while (n > 0 && *s1 && ToUpper(*s1) == ToUpper(*s2)) {
        s1++;
        s2++;
        n--;
    }
    if (n <= 0)
        return 0;
    return ToUpper(*s1) - ToUpper(*s2);
}

U8 *StrMatch(U8 *needle, U8 *haystack)
{//First occurrence of needle in haystack, or NULL.
    I64 n = StrLen(needle);
    if (!n)
        return haystack;
    while (*haystack) {
        if (!StrNCmp(haystack, needle, n))
            return haystack;
        haystack++;
    }
    return NULL;
}

U8 *StrIMatch(U8 *needle, U8 *haystack)
{//StrMatch() ignoring case.
    I64 n = StrLen(needle);
    if (!n)
        return haystack;
    while (*haystack) {
        if (!StrNICmp(haystack, needle, n))
            return haystack;
        haystack++;
    }
    return NULL;
}

// ---- Bits. Bit n of a field is bit n%8 of byte n/8, as on x86. ----

Bool Bt(U8 *bits, I64 bit)
{
    return (bits[bit >> 3] >> (bit & 7)) & 1;
}

Bool Bts(U8 *bits, I64 bit)
{
    Bool old = Bt(bits, bit);
    bits[bit >> 3] |= 1 << (bit & 7);
    return old;
}

Bool Btr(U8 *bits, I64 bit)
{
    Bool old = Bt(bits, bit);
    bits[bit >> 3] &= ~(1 << (bit & 7));
    return old;
}

Bool Btc(U8 *bits, I64 bit)
{
    Bool old = Bt(bits, bit);
    bits[bit >> 3] ^= 1 << (bit & 7);
    return old;
}

Bool LBitOp(U8 *bits, I64 bit, I64 op)
{//Atomic Bts (op 0), Btr (1) or Btc (2), on the aligned I64 holding the bit.
    U8 *byte = bits + (bit >> 3);
    I64 *p = byte(I64) & ~7, m = 1 << ((byte - p(U8 *)) * 8 + (bit & 7)), old, new;
    while (TRUE) {
        old = *p;
        if (op == 0)
            new = old | m;
        else if (op == 1)
            new = old & ~m;
        else
            new = old ^ m;
        if (ArchCas(p, old, new) == old)
            return (old & m) != 0;
    }
}

Bool LBts(U8 *bits, I64 bit)
{
    return LBitOp(bits, bit, 0);
}

Bool LBtr(U8 *bits, I64 bit)
{
    return LBitOp(bits, bit, 1);
}

Bool LBtc(U8 *bits, I64 bit)
{
    return LBitOp(bits, bit, 2);
}

I64 Bsf(I64 v)
{//Index of the lowest set bit, -1 for 0.
    I64 i;
    for (i = 0; i < 64; i++)
        if ((v >> i) & 1)
            return i;
    return -1;
}

I64 Bsr(I64 v)
{//Index of the highest set bit, -1 for 0.
    I64 i;
    for (i = 63; i >= 0; i--)
        if ((v >> i) & 1)
            return i;
    return -1;
}

Bool IsValidPtr(U8 *p)
{//DRAM only (the kernel has no page faults to try an access with).
    return 0x800000000 <= p(I64) < 0xC00000000;
}
