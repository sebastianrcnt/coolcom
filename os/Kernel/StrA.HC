// Basic memory and string library, TempleOS argument orders/semantics
// (cf. Aiwnios Src/StrA.HC, BSD-3 / public domain).
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

I64 ToUpper(I64 ch)
{
  if ('a' <= ch <= 'z')
    return ch - 32;
  return ch;
}

I64 ToLower(I64 ch)
{
  if ('A' <= ch <= 'Z')
    return ch + 32;
  return ch;
}

// Case-insensitive compare (compares upper-cased chars, like TempleOS).
I64 StrICmp(U8 *s1, U8 *s2)
{
  while (*s1 && ToUpper(*s1) == ToUpper(*s2)) {
    s1++;
    s2++;
  }
  return ToUpper(*s1) - ToUpper(*s2);
}

// Number of occurrences of ch in src.
I64 StrOcc(U8 *src, I64 ch)
{
  I64 n = 0;
  while (*src)
    if (*src++ == ch)
      n++;
  return n;
}

// First occurrence of needle in haystack, or NULL. (TempleOS order.)
U8 *StrFind(U8 *needle, U8 *haystack)
{
  I64 n = StrLen(needle);
  if (!n)
    return haystack;
  while (*haystack) {
    if (!MemCmp(haystack, needle, n))
      return haystack;
    haystack++;
  }
  return NULL;
}
