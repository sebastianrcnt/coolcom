// Handwritten equivalent of lib/Lexer.mll. Token kinds: EOF=0,
// punctuation/keyword=1, identifier=2, integer=3, float=4, string=5, doc=6.
Bool WAlpha(I64 c) {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');}
Bool WDigit(I64 c) {return c >= '0' && c <= '9';}
Bool WPrefix(U8 *s, U8 *p)
{
    while (*p) {if (*s++ != *p++) return FALSE;}
    return TRUE;
}
Bool WKeyword(U8 *s)
{
    U8 *p = "and or not module is body import as end constant type function generic record union case of when typeclass instance method if then else let var while for do from to borrow return skip Free Linear Type Region pragma sizeof nil true false Span";
    I64 n = StrLen(s);
    while (*p) {
        if (WPrefix(p, s) && (p[n] == ' ' || !p[n])) return TRUE;
        while (*p && *p != ' ') p++;
        if (*p) p++;
    }
    return FALSE;
}
CWToken *WLex(CWUnit *u, CWSource *src)
{
    U8 *s = src->text, *value;
    CWToken *head = NULL, *tail = NULL, *t;
    I64 i = 0, start, k, n, quote, base, c, j;
    while (i < src->size && !u->error_kind) {
        c = s[i];
        if (c == ' ' || c == '\t' || c == '\n' || (c == '\r' && s[i + 1] == '\n')) {i++; goto lex_next;}
        if (c == '-' && s[i + 1] == '-') {while (i < src->size && s[i] != '\n' && s[i] != '\r') i++; goto lex_next;}
        start = i; k = 1; value = NULL;
        if (WAlpha(c)) {
            i++;
            while (WAlpha(s[i]) || WDigit(s[i]) || s[i] == '_') i++;
            value = WText(u, s + start, i - start); k = 2;
            if (WKeyword(value)) k = 1;
            if (WEq(value, "Span") && s[i] == '!') {i++; value = "Span!";}
            if (WEq(value, "else")) {
                j = i; while (s[j] == ' ' || s[j] == '\t') j++;
                if (j > i && WPrefix(s + j, "if")) {i = j + 2; value = "else if";}
            }
        } else if (WDigit(c) || ((c == '+' || c == '-') && WDigit(s[i + 1]))) {
            k = 3; i++;
            while (WDigit(s[i]) || s[i] == 39) i++;
            if (s[i] == '.') {
                k = 4; i++;
                if ((s[i] == '+' || s[i] == '-') && WDigit(s[i + 1])) i++;
                while (WDigit(s[i]) || s[i] == 39) i++;
                if (s[i] == 'e' || s[i] == 'E') {
                    j = i + 1; if (s[j] == '+' || s[j] == '-') j++;
                    if (WDigit(s[j])) {i = j + 1; while (WDigit(s[i]) || s[i] == 39) i++;}
                }
            }
        } else if (c == '#') {
            base = 0;
            if (s[i + 1] == 'x') base = 16;
            if (s[i + 1] == 'o') base = 8;
            if (s[i + 1] == 'b') base = 2;
            i += 2; j = i;
            while (TRUE) {
                c = s[i]; n = -1;
                if (WDigit(c)) n = c - '0';
                if (c >= 'a' && c <= 'f') n = (c - 'a') + 10;
                if (c >= 'A' && c <= 'F') n = (c - 'A') + 10;
                if ((n >= 0 && n < base) || (c == 39 && i > j)) i++;
                else break;
            }
            k = 3;
            if (!base || i == j) k = -1;
        } else if (c == 39) {
            i++;
            if (s[i] == 92) {i++; if (s[i] != 'n' && s[i] != 'r' && s[i] != 't' && s[i] != 92) k = -1;}
            else if (s[i] < 32 || s[i] > 126 || s[i] == 92) k = -1;
            if (s[i]) i++;
            if (s[i] != 39) k = -1; else i++;
            if (k != -1) k = 3;
        } else if (c == '"') {
            quote = 1; k = 5;
            if (s[i + 1] == '"' && s[i + 2] == '"') {quote = 3; k = 6;}
            i += quote; j = i;
            while (i < src->size) {
                if (s[i] == 92 && s[i + 1] == '"' && (quote == 1 || (s[i + 2] == '"' && s[i + 3] == '"'))) i += quote + 1;
                else if (s[i] == '"' && (quote == 1 || (s[i + 1] == '"' && s[i + 2] == '"'))) break;
                else i++;
            }
            value = WAlloc(u, (i - j) + 1); n = 0;
            while (j < i) {
                if (s[j] == 92 && s[j + 1] == '"' && (quote == 1 || (s[j + 2] == '"' && s[j + 3] == '"'))) j++;
                value[n++] = s[j++];
            }
            if (i == src->size) k = -1; else i += quote;
        } else {
            if (WPrefix(s + i, "@embed")) {i += 6;}
            else if (WPrefix(s + i, "&!") || WPrefix(s + i, "&~") || WPrefix(s + i, "&(") || WPrefix(s + i, "/=") || WPrefix(s + i, "<=") || WPrefix(s + i, ">=") || WPrefix(s + i, "->") || WPrefix(s + i, "=>") || WPrefix(s + i, ":=")) i += 2;
            else {
                value = "()[]{}+-*/=<>;&,.:!";
                j = 0; while (value[j] && value[j] != c) j++;
                if (!value[j]) k = -1;
                i++; value = NULL;
            }
        }
        t = WAlloc(u, sizeof(CWToken)); t->source = src; t->start = start; t->end = i; t->kind = k;
        if (!value) value = WText(u, s + start, i - start);
        t->text = value;
        if (tail) tail->next = t; else head = t;
        tail = t; u->tokens++;
        if (k == -1) WFail(u, t, "Parse Error", "Invalid character or unterminated literal");
lex_next:
    }
    t = WAlloc(u, sizeof(CWToken)); t->source = src; t->start = i; t->end = i; t->text = "<eof>";
    if (tail) tail->next = t; else head = t;
    return head;
}
