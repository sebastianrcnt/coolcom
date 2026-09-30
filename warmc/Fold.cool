// Signed decimal bignums for the reference's unbounded integer constant folding.
class CWBig {I64 sign, len, capacity; U8 *digits;};
CWBig *WBNew(CWUnit *u, I64 capacity)
{
    CWBig *b = WAlloc(u, sizeof(CWBig)); b->capacity = capacity; b->digits = WAlloc(u, capacity); b->len = 1; b->sign = 1; return b;
}
U0 WBTrim(CWBig *b) {while (b->len > 1 && !b->digits[b->len - 1]) b->len--; if (b->len == 1 && !b->digits[0]) b->sign = 1;}
I64 WBCmp(CWBig *a, CWBig *b)
{
    I64 i;
    if (a->len > b->len) return 1; if (a->len < b->len) return -1;
    for (i = a->len - 1; i >= 0; i--) {if (a->digits[i] > b->digits[i]) return 1; if (a->digits[i] < b->digits[i]) return -1;}
    return 0;
}
CWBig *WBAddAbs(CWUnit *u, CWBig *a, CWBig *b)
{
    I64 len = a->len, i, c = 0; if (b->len > len) len = b->len;
    CWBig *r = WBNew(u, len + 2); r->len = len;
    for (i = 0; i < len; i++) {if (i < a->len) c += a->digits[i]; if (i < b->len) c += b->digits[i]; r->digits[i] = c % 10; c /= 10;}
    if (c) r->digits[r->len++] = c; return r;
}
CWBig *WBSubAbs(CWUnit *u, CWBig *a, CWBig *b)
{
    CWBig *r = WBNew(u, a->len + 1); I64 i, v, borrow = 0; r->len = a->len;
    for (i = 0; i < a->len; i++) {v = a->digits[i] - borrow; if (i < b->len) v -= b->digits[i]; borrow = 0; if (v < 0) {v += 10; borrow = 1;} r->digits[i] = v;}
    WBTrim(r); return r;
}
CWBig *WBAdd(CWUnit *u, CWBig *a, CWBig *b)
{
    CWBig *r;
    if (a->sign == b->sign) {r = WBAddAbs(u, a, b); r->sign = a->sign;}
    else if (WBCmp(a, b) >= 0) {r = WBSubAbs(u, a, b); r->sign = a->sign;}
    else {r = WBSubAbs(u, b, a); r->sign = b->sign;}
    WBTrim(r); return r;
}
CWBig *WBMul(CWUnit *u, CWBig *a, CWBig *b)
{
    CWBig *r = WBNew(u, a->len + b->len + 1); I64 i, j, v, carry;
    r->len = a->len + b->len; r->sign = a->sign * b->sign;
    for (i = 0; i < a->len; i++) {
        carry = 0;
        for (j = 0; j < b->len; j++) {v = (a->digits[i] * b->digits[j]) + r->digits[i + j] + carry; r->digits[i + j] = v % 10; carry = v / 10;}
        j = i + b->len;
        while (carry) {v = r->digits[j] + carry; r->digits[j++] = v % 10; carry = v / 10;}
    }
    WBTrim(r); return r;
}
U0 WBScale(CWBig *b, I64 base, I64 digit)
{
    I64 i, v, carry = digit;
    for (i = 0; i < b->len; i++) {v = (b->digits[i] * base) + carry; b->digits[i] = v % 10; carry = v / 10;}
    while (carry) {b->digits[b->len++] = carry % 10; carry /= 10;}
    WBTrim(b);
}
CWBig *WBDiv(CWUnit *u, CWBig *a, CWBig *b, CWToken *at)
{
    CWBig *q = WBNew(u, a->len + 1), *r = WBNew(u, a->len + 2), *sub;
    I64 i;
    if (b->len == 1 && !b->digits[0]) {WFail(u, at, "Type Error", "Division by zero in constant expression"); return q;}
    q->len = a->len; q->sign = a->sign * b->sign;
    for (i = a->len - 1; i >= 0; i--) {
        WBScale(r, 10, a->digits[i]);
        while (WBCmp(r, b) >= 0) {
            sub = WBSubAbs(u, r, b); MemCpy(r->digits, sub->digits, sub->len); r->len = sub->len; q->digits[i]++;
        }
    }
    WBTrim(q); return q;
}
CWBig *WBParse(CWUnit *u, U8 *s)
{
    CWBig *r = WBNew(u, (StrLen(s) * 2) + 4); I64 i = 0, base = 10, d;
    if (s[0] == '-' || s[0] == '+') {if (s[0] == '-') r->sign = -1; i++;}
    if (s[i] == 39) {d = s[i + 1]; if (d == 92) {d = s[i + 2]; if (d == 'n') d = 10; else if (d == 'r') d = 13; else if (d == 't') d = 9;} WBScale(r, 10, d); return r;}
    if (s[i] == '#') {if (s[i + 1] == 'x') base = 16; else if (s[i + 1] == 'b') base = 2; else base = 8; i += 2;}
    I64 sign = r->sign;
    for (; s[i]; i++) if (s[i] != 39) {d = s[i] - '0'; if (s[i] >= 'a' && s[i] <= 'f') d = (s[i] - 'a') + 10; if (s[i] >= 'A' && s[i] <= 'F') d = (s[i] - 'A') + 10; WBScale(r, base, d);}
    r->sign = sign; WBTrim(r); return r;
}
U8 *WBText(CWUnit *u, CWBig *b)
{
    U8 *s = WAlloc(u, b->len + 2); I64 i, j = 0;
    if (b->sign < 0) s[j++] = '-';
    for (i = b->len - 1; i >= 0; i--) s[j++] = b->digits[i] + '0'; return s;
}
CWBig *WBFold(CWUnit *u, CWNode *n)
{
    CWBig *a, *b;
    if (WEq(n->tag, "literal") && n->token->kind == 3) return WBParse(u, n->name);
    if (WEq(n->tag, "unary") && WEq(n->name, "-")) {a = WBFold(u, WChild(n, "value")); if (a) a->sign = -a->sign; return a;}
    if (!WEq(n->tag, "binary") || (!WEq(n->name, "+") && !WEq(n->name, "-") && !WEq(n->name, "*") && !WEq(n->name, "/"))) return NULL;
    a = WBFold(u, WChild(n, "left")); if (!a) return NULL;
    b = WBFold(u, WChild(n, "right")); if (!b) return NULL;
    if (WEq(n->name, "*")) return WBMul(u, a, b);
    if (WEq(n->name, "/")) return WBDiv(u, a, b, n->token);
    if (WEq(n->name, "-")) b->sign = -b->sign;
    return WBAdd(u, a, b);
}
U0 WFold(CWUnit *u, CWNode *n)
{
    CWNode *c; CWBig *value = NULL; CWToken *token;
    if (WEq(n->tag, "binary") || WEq(n->tag, "unary")) value = WBFold(u, n);
    if (value && !u->error_kind) {
        token = WAlloc(u, sizeof(CWToken)); MemCpy(token, n->token, sizeof(CWToken)); token->kind = 3;
        n->token = token; n->tag = "literal"; n->name = WBText(u, value); n->first = NULL; n->last = NULL;
    } else for (c = n->first; c && !u->error_kind; c = c->next) WFold(u, c);
}
U0 WFoldUnit(CWUnit *u) {CWNode *m; for (m = u->modules; m && !u->error_kind; m = m->next) WFold(u, m);}
// Correctly rounded decimal -> binary64. Emit exact bits instead of depending
// on the HolyC lexer's decimal accumulation, which loses ulps for large inputs.
U64 WBFloatBits(CWUnit *u, U8 *text)
{
    I64 i = 0, j = 0, fraction = 0, exponent = 0, esign = 1, scale, e = 0, keep, k, cmp;
    Bool negative = FALSE, point = FALSE;
    U8 *digits = WAlloc(u, StrLen(text) + 1);
    CWBig *n, *d, *twice, *r, *copy;
    U64 sign = 0, mantissa = 1, bits;
    if (text[i] == '+' || text[i] == '-') {negative = text[i] == '-'; i++;}
    if (negative) sign = 0x8000000000000000;
    while (text[i] && text[i] != 'e' && text[i] != 'E') {
        if (text[i] == '.') point = TRUE;
        else if (text[i] != 39) {digits[j++] = text[i]; if (point) fraction++;}
        i++;
    }
    if (text[i]) {
        i++; if (text[i] == '+' || text[i] == '-') {if (text[i] == '-') esign = -1; i++;}
        while (text[i]) {if (text[i] != 39 && exponent < 1000000) exponent = (exponent * 10) + (text[i] - '0'); i++;}
    }
    n = WBParse(u, digits);
    if (n->len == 1 && !n->digits[0]) return sign;
    scale = fraction - (exponent * esign);
    if (n->len - scale > 310) return sign | 0x7ff0000000000000;
    if (n->len - scale < -325) return sign;
    k = n->len + fraction + 400;
    if (scale < 0) k -= scale; else k += scale;
    copy = WBNew(u, k); MemCpy(copy->digits, n->digits, n->len); copy->len = n->len; n = copy;
    d = WBNew(u, k); d->digits[0] = 1;
    if (scale > 0) for (i = 0; i < scale; i++) WBScale(d, 10, 0);
    else for (i = 0; i < -scale; i++) WBScale(n, 10, 0);
    while (WBCmp(n, d) < 0) {WBScale(n, 2, 0); e--;}
    twice = WBNew(u, k); MemCpy(twice->digits, d->digits, d->len); twice->len = d->len; WBScale(twice, 2, 0);
    while (WBCmp(n, twice) >= 0) {WBScale(d, 2, 0); WBScale(twice, 2, 0); e++;}
    if (e > 1023) return sign | 0x7ff0000000000000;
    if (e < -1075) return sign;
    if (e == -1075) {if (WBCmp(n, d) > 0) return sign | 1; return sign;}
    keep = 53; if (e < -1022) keep = e + 1075;
    copy = WBSubAbs(u, n, d); r = WBNew(u, k); MemCpy(r->digits, copy->digits, copy->len); r->len = copy->len;
    for (i = 1; i < keep; i++) {
        WBScale(r, 2, 0); mantissa <<= 1;
        if (WBCmp(r, d) >= 0) {mantissa |= 1; copy = WBSubAbs(u, r, d); MemCpy(r->digits, copy->digits, copy->len); r->len = copy->len;}
    }
    WBScale(r, 2, 0); cmp = WBCmp(r, d);
    if (cmp > 0 || (cmp == 0 && (mantissa & 1))) mantissa++;
    if (e < -1022) return sign | mantissa;
    if (mantissa == 0x20000000000000) {mantissa >>= 1; e++;}
    if (e > 1023) return sign | 0x7ff0000000000000;
    bits = sign | ((e + 1023) << 52) | (mantissa & 0xfffffffffffff);
    return bits;
}
