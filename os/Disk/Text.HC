// Helpers shared by the text tools (Find, Less, Man, Diff, HexDump).

Bool TextIsBinary(U8 *buf, I64 size)
{//A NUL byte in the first 512 bytes.
    I64 i, n = size;
    if (n > 512) n = 512;
    for (i = 0; i < n; i++)
        if (!buf[i]) return TRUE;
    return FALSE;
}

I64 TextLower(I64 c)
{
    if (c >= 'A' && c <= 'Z') return c + 32;
    return c;
}

I64 TextFind(U8 *hay, I64 from, I64 to, U8 *needle, I64 n, Bool icase = FALSE)
{//Offset of the first needle[0..n) in hay[from..to), or -1.
    I64 i, j;
    if (n <= 0) return -1;
    for (i = from; i + n <= to; i++) {
        for (j = 0; j < n; j++) {
            if (icase) {
                if (TextLower(hay[i + j]) != TextLower(needle[j])) break;
            } else if (hay[i + j] != needle[j]) break;
        }
        if (j == n) return i;
    }
    return -1;
}

I64 TextFindBack(U8 *hay, I64 from, I64 to, U8 *needle, I64 n, Bool icase = FALSE)
{//Offset of the last needle[0..n) starting in hay[from..to), or -1.
    I64 i, j;
    if (n <= 0) return -1;
    for (i = to - n; i >= from; i--) {
        for (j = 0; j < n; j++) {
            if (icase) {
                if (TextLower(hay[i + j]) != TextLower(needle[j])) break;
            } else if (hay[i + j] != needle[j]) break;
        }
        if (j == n) return i;
    }
    return -1;
}

U0 TextPutLine(U8 *p, I64 n, I64 max)
{//Print n bytes without control characters (they would drive the terminal) and at most
    //max bytes, never in the middle of a UTF-8 sequence.
    I64 i = 0, k, j;
    while (i < n) {
        k = Utf8Len(p[i]);
        if (k < 1 || i + k > n) k = 1;
        if (i + k > max) break;
        if (k == 1 && (p[i] < 32 || p[i] == 127)) {
            if (p[i] == '\t') ConsPut(' ');
            else ConsPut('?');
        } else
            for (j = 0; j < k; j++) ConsPut(p[i + j]);
        i += k;
    }
}

I64 TextRead(U8 *name, U8 **_buf)
{//The file's bytes (a NUL follows them) in *_buf, and their count; -1 if it cannot be read.
    I64 size = 0;
    *_buf = FileRead(name, &size);
    if (!*_buf) return -1;
    return size;
}
