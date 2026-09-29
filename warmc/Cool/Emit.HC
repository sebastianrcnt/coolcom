// Reachability-driven monomorphization and a HolyC text sink.
class CWBuffer {U8 *data; I64 size, capacity;};
class CWGen {
    CWUnit *unit;
    CWBuffer *types_text, *body;
    CWNode *types, *names, *functions, *last_function, *current, *bindings;
    I64 serial;
};
U0 WGPut(CWUnit *u, CWBuffer *b, U8 *text)
{
    I64 n = StrLen(text), cap;
    U8 *p;
    if (b->size + n + 1 > b->capacity) {
        cap = (b->size + n + 4096) * 2; p = WAlloc(u, cap);
        if (b->size) MemCpy(p, b->data, b->size);
        b->data = p; b->capacity = cap;
    }
    MemCpy(b->data + b->size, text, n); b->size += n; b->data[b->size] = 0;
}
U8 *WGCat(CWUnit *u, U8 *a, U8 *b)
{
    I64 n = StrLen(a), m = StrLen(b); U8 *s = WAlloc(u, n + m + 1); MemCpy(s, a, n); MemCpy(s + n, b, m); return s;
}
U8 *WG3(CWUnit *u, U8 *a, U8 *b, U8 *c) {return WGCat(u, WGCat(u, a, b), c);}
U8 *WGDec(CWUnit *u, I64 i)
{
    U8 buf[32]; I64 n = 31; buf[n] = 0;
    do {buf[--n] = '0' + (i % 10); i /= 10;} while (i);
    return WText(u, buf + n, 31 - n);
}
U8 *WGFresh(CWGen *g, U8 *prefix) {return WGCat(g->unit, prefix, WGDec(g->unit, ++g->serial));}
U8 *WGName(CWGen *g, CWNode *d)
{
    CWNode *n;
    for (n = g->names; n; n = n->next) if (n->resolved == d) return n->name;
    n = WNode(g->unit, "name", NULL); n->resolved = d; n->name = WGFresh(g, "w"); n->next = g->names; g->names = n; return n->name;
}
U0 WGLine(CWGen *g, U8 *text) {WGPut(g->unit, g->body, text); WGPut(g->unit, g->body, "\n");}
Bool WGAggregate(CWNode *t)
{
    CWNode *d;
    if (!t) return FALSE;
    if (WEq(t->name, "Span") || WEq(t->name, "Span!")) return TRUE;
    if (WEq(t->name, "Pointer") || WEq(t->name, "Address") || WEq(t->name, "&") || WEq(t->name, "&!") || WEq(t->name, "Fn")) return FALSE;
    d = WCanon(t->resolved); return d && (WEq(d->tag, "record") || WEq(d->tag, "union") || WEq(d->name, "RootCapability"));
}
extern U8 *WGType(CWGen *g, CWNode *t);
U8 *WGType(CWGen *g, CWNode *t)
{
    CWUnit *u = g->unit;
    CWNode *d, *n, *slot, *c, *env, *fieldty;
    CWBuffer *buf;
    U8 *name, *field, *case_name;
    if (!t) {WFail(u, NULL, "Unsupported Feature", "Missing concrete type during emission"); return "I64";}
    if (WEq(t->name, "Unit") || WEq(t->name, "Bool") || WEq(t->name, "Nat8")) return "U8";
    if (WEq(t->name, "Nat16")) return "U16";
    if (WEq(t->name, "Nat32")) return "U32";
    if (WEq(t->name, "Nat64") || WEq(t->name, "Index") || WEq(t->name, "ByteSize")) return "U64";
    if (WEq(t->name, "Int8")) return "I8";
    if (WEq(t->name, "Int16")) return "I16";
    if (WEq(t->name, "Int32")) return "I32";
    if (WEq(t->name, "Int64")) return "I64";
    if (WEq(t->name, "Float64")) return "F64";
    if (WEq(t->name, "Float32")) return "U32";
    if (WEq(t->name, "Span") || WEq(t->name, "Span!")) return "au_span_t";
    if (WEq(t->name, "&") || WEq(t->name, "&!") || WEq(t->name, "Pointer") || WEq(t->name, "Address")) return WGCat(u, WGType(g, t->first), " *");
    if (WEq(t->name, "Fn")) return "U8 *";
    for (n = g->types; n; n = n->next) if (WTypeEq(n->ty, t)) return n->name;
    d = WCanon(t->resolved);
    if (!d || (!WEq(d->tag, "record") && !WEq(d->tag, "union") && !WEq(d->name, "RootCapability"))) {
        WFail(u, t->token, "Unsupported Feature", "Cannot emit an unconcretized or opaque type"); return "I64";
    }
    n = WNode(u, "emitted-type", t->token); n->ty = t; n->name = WGFresh(g, "WT"); n->next = g->types; g->types = n;
    name = n->name; env = WTypeParameters(u, t); buf = WAlloc(u, sizeof(CWBuffer));
    WGPut(u, buf, WG3(u, "class ", name, " {\n"));
    if (WEq(d->tag, "union")) {
        WGPut(u, buf, "I64 tag;\nunion {\n");
        for (c = d->first; c; c = c->next) if (WEq(c->role, "constructor")) {
                case_name = WG3(u, name, "_", WGName(g, c));
                CWBuffer *cb = WAlloc(u, sizeof(CWBuffer));
                WGPut(u, cb, WG3(u, "class ", case_name, " {\n"));
                if (!WChild(c, "slot")) WGPut(u, cb, "U8 empty;\n");
                for (slot = c->first; slot; slot = slot->next) if (WEq(slot->role, "slot")) {
                        fieldty = WSubst(u, WChild(slot, "type"), env); field = WGType(g, fieldty);
                        WGPut(u, cb, WG3(u, field, " ", WGCat(u, WGName(g, slot), ";\n")));
                    }
                WGPut(u, cb, "};\n"); WGPut(u, g->types_text, cb->data);
                WGPut(u, buf, WG3(u, case_name, " ", WGCat(u, WGName(g, c), ";\n")));
            }
        WGPut(u, buf, "};\n");
    } else {
        if (!WChild(d, "slot")) WGPut(u, buf, "U8 empty;\n");
        for (slot = d->first; slot; slot = slot->next) if (WEq(slot->role, "slot")) {
                fieldty = WSubst(u, WChild(slot, "type"), env); field = WGType(g, fieldty);
                WGPut(u, buf, WG3(u, field, " ", WGCat(u, WGName(g, slot), ";\n")));
            }
    }
    WGPut(u, buf, "};\n"); WGPut(u, g->types_text, buf->data); return name;
}
U8 *WGTemp(CWGen *g, CWNode *t)
{
    U8 *name = WGFresh(g, "wt"); WGLine(g, WG3(g->unit, WGType(g, t), " ", WGCat(g->unit, name, ";"))); return name;
}
U0 WGCopy(CWGen *g, U8 *dst, U8 *src, CWNode *ty)
{
    CWUnit *u = g->unit;
    if (WGAggregate(ty)) WGLine(g, WG3(u, "MemCpy(&(", dst, WG3(u, "), &(", src, WG3(u, "), sizeof(", WGType(g, ty), "));"))));
    else {
        I64 bits = WIntBits(ty->name);
        U8 *mask, *sign;
        if (bits > 0 && bits < 64) {
            mask = "255"; sign = "128";
            if (bits == 16) {mask = "65535"; sign = "32768";}
            if (bits == 32) {mask = "4294967295"; sign = "2147483648";}
            src = WG3(u, "((", src, WG3(u, ") & ", mask, ")"));
            if (WPrefix(ty->name, "Int")) src = WG3(u, "((", src, WG3(u, " ^ ", sign, WG3(u, ") - ", sign, ")")));
        }
        WGLine(g, WG3(u, dst, " = ", WGCat(u, src, ";")));
    }
}
CWNode *WGConcrete(CWGen *g, CWNode *ty) {return WSubst(g->unit, ty, g->bindings);}
U8 *WGQuote(CWUnit *u, U8 *s)
{
    CWBuffer *b = WAlloc(u, sizeof(CWBuffer)); I64 i; U8 ch[2]; ch[1] = 0;
    WGPut(u, b, "\"");
    for (i = 0; s[i]; i++) {
        if (s[i] == '"') WGPut(u, b, "\\\"");
        else if (s[i] == 92) WGPut(u, b, "\\\\");
        else if (s[i] == '\n') WGPut(u, b, "\\n");
        else if (s[i] == '\r') WGPut(u, b, "\\r");
        else if (s[i] == '\t') WGPut(u, b, "\\t");
        else {ch[0] = s[i]; WGPut(u, b, ch);}
    }
    WGPut(u, b, "\""); return b->data;
}
I64 WGTag(CWNode *cons)
{
    CWNode *c; I64 i = 0;
    for (c = cons->owner->first; c; c = c->next) if (WEq(c->role, "constructor")) {if (c == cons) return i; i++;}
    return -1;
}
CWNode *WGRequest(CWGen *g, CWNode *decl, CWNode *env)
{
    CWUnit *u = g->unit;
    CWNode *f, *p, *signature = WNode(u, "type", decl->token), *ty;
    if (decl->pair && WChild(decl->pair, "body")) decl = decl->pair;
    signature->name = "Fn";
    for (p = decl->first; p; p = p->next) if (WEq(p->role, "parameter") || WEq(p->role, "result")) {
            ty = p; if (WEq(p->role, "parameter")) ty = WChild(p, "type");
            WAdd(signature, WCopyType(u, WSubst(u, ty, env)), "argument");
        }
    for (f = g->functions; f; f = f->next) if (f->resolved == decl && WTypeEq(f->ty, signature)) return f;
    f = WNode(u, "specialization", decl->token); f->resolved = decl; f->pair = env; f->ty = signature; f->name = WGFresh(g, "wf");
    if (g->last_function) g->last_function->next = f; else g->functions = f; g->last_function = f; return f;
}
extern U8 *WGExpr(CWGen *g, CWNode *n);
extern U0 WGStmt(CWGen *g, CWNode *n);
U8 *WGInteger(CWUnit *u, U8 *s)
{
    CWBuffer *b = WAlloc(u, sizeof(CWBuffer)); I64 i = 0; U8 ch[2]; ch[1] = 0;
    if (s[0] == 39) {
        i = s[1]; if (i == 92) {i = s[2]; if (i == 'n') i = 10; else if (i == 'r') i = 13; else if (i == 't') i = 9;}
        return WGDec(u, i);
    }
    if (s[0] == '#') {
        if (s[1] == 'x') WGPut(u, b, "0x");
        else if (s[1] == 'b') WGPut(u, b, "0b");
        else {
            U64 oct = 0; I64 j = 2, k; U8 hex[19], *digits = "0123456789abcdef";
            while (s[j]) {if (s[j] != 39) oct = (oct << 3) + (s[j] - '0'); j++;}
            hex[0] = '0'; hex[1] = 'x'; hex[18] = 0;
            for (j = 0; j < 16; j++) {k = (oct >> ((15 - j) * 4)) & 15; hex[j + 2] = digits[k];}
            return WText(u, hex, 18);
        } i = 2;
    }
    for (; s[i]; i++) if (s[i] != 39) {ch[0] = s[i]; WGPut(u, b, ch);}
    return b->data;
}
U8 *WGStringValue(CWUnit *u, CWNode *n)
{
    // String lexer has already decoded escaped quotes. Warm preserves other
    // escapes for its C-compatible string renderer; decode them once here.
    U8 *s = n->name, *out = WAlloc(u, StrLen(s) + 1); I64 i = 0, j = 0, c;
    while (s[i]) {
        c = s[i++];
        if (c == 92 && s[i]) {c = s[i++]; if (c == 'n') c = 10; else if (c == 'r') c = 13; else if (c == 't') c = 9;}
        out[j++] = c;
    }
    return out;
}
U8 *WGPath(CWGen *g, CWNode *n)
{
    CWUnit *u = g->unit;
    CWNode *p, *ty = WGConcrete(g, WDeclType(n->resolved)), *inner;
    U8 *result = WGName(g, n->resolved), *idx, *ptr;
    Bool transform = WEq(n->tag, "ref-path");
    for (p = n->first; p; p = p->next) if (WEq(p->role, "path")) {
            if (WEq(p->tag, "index")) {
                idx = WGExpr(g, WChild(p, "value")); inner = ty;
                if (transform && (WEq(ty->name, "&") || WEq(ty->name, "&!"))) {result = WG3(u, "(*(", result, "))"); inner = ty->first;}
                ptr = WG3(u, "au_array_index(&(", result, WG3(u, "), ", idx, WG3(u, ", sizeof(", WGType(g, inner->first), "))")));
                result = WG3(u, "(", ptr, WG3(u, ")(", WGType(g, inner->first), " *)"));
                if (!transform) result = WG3(u, "(*(", result, "))");
            } else {
                if (WEq(p->tag, "->")) result = WG3(u, "(", result, WGCat(u, ")->", WGName(g, p->resolved)));
                else result = WG3(u, "(", result, WGCat(u, ").", WGName(g, p->resolved)));
                if (transform) result = WG3(u, "(&(", result, "))");
            }
            ty = WGConcrete(g, p->ty);
        }
    return result;
}
U8 *WGExpand(CWUnit *u, U8 *text, CWNode *values)
{
    CWBuffer *b = WAlloc(u, sizeof(CWBuffer)); CWNode *v; I64 i = 0, j; U8 ch[2]; ch[1] = 0;
    while (text[i]) {
        if (text[i] == '$' && text[i + 1] >= '1' && text[i + 1] <= '9') {
            j = text[++i] - '1'; i++; v = values; while (v && j--) v = v->next;
            if (!v) {WFail(u, NULL, "Unsupported Feature", "Invalid embed placeholder"); return "0";}
            WGPut(u, b, v->name);
        } else {ch[0] = text[i++]; WGPut(u, b, ch);}
    }
    if (!b->data) return "";
    return b->data;
}
U8 *WGEmbed(CWGen *g, CWNode *n, CWNode *args)
{
    CWUnit *u = g->unit; CWNode *ty = WGConcrete(g, n->ty), *a = args, *b = NULL, *c = NULL, *bound;
    U8 *s = n->name, *expr = NULL, *tmp, *pattern, *fmt, *tail, *maximum, *minimum;
    I64 len = StrLen(s), i, j, bits;
    Bool sign;
    if (a) b = a->next; if (b) c = b->next;
    if (WEq(s, "NULL")) return "0";
    if (WEq(s, "UINT8_MAX")) return "255";
    if (WEq(s, "UINT16_MAX")) return "65535";
    if (WEq(s, "UINT32_MAX")) return "4294967295";
    if (WEq(s, "UINT64_MAX") || WEq(s, "SIZE_MAX")) return "0xffffffffffffffff";
    if (WEq(s, "INT8_MIN")) return "-128";
    if (WEq(s, "INT8_MAX")) return "127";
    if (WEq(s, "INT16_MIN")) return "-32768";
    if (WEq(s, "INT16_MAX")) return "32767";
    if (WEq(s, "INT32_MIN")) return "-2147483648";
    if (WEq(s, "INT32_MAX")) return "2147483647";
    if (WEq(s, "INT64_MIN")) return "0x8000000000000000";
    if (WEq(s, "INT64_MAX")) return "0x7fffffffffffffff";
    if (WEq(s, "$1") && a && !b) {
        expr = a->name;
        if (WEq(a->ty->name, "Float32") && !WEq(ty->name, "Float32")) expr = WG3(u, "wc_f32_to_f64(", expr, ")");
        if (WEq(ty->name, "Float32") && !WEq(a->ty->name, "Float32")) expr = WG3(u, "wc_f64_to_f32(", expr, ")");
    }
    else if (WPrefix(s, "((") && len > 8 && WEq(s + len - 5, "($1))") && a && !b) {
        expr = a->name;
        if (WEq(a->ty->name, "Float32")) expr = WG3(u, "wc_f32_to_f64(", expr, ")");
        if (WEq(ty->name, "Float32")) expr = WG3(u, "wc_f64_to_f32(", expr, ")");
    }
    else if (WEq(s, "$1.size") && a && !b) expr = WGCat(u, a->name, ".wh_size");
    else if (WEq(s, "($1).data") && a && !b) expr = WGCat(u, a->name, ".wh_data");
    else if (WEq(s, "*($1)") && a && !b) expr = WG3(u, "(*(", a->name, "))");
    else if (WEq(s, "~ $1") && a && !b) expr = WG3(u, "(~(", a->name, "))");
    else if (WEq(s, "AU_STORE($1, $2)") && b && !c) {WGCopy(g, WG3(u, "(*(", a->name, "))"), b->name, b->ty); return "0";}
    else if (b && !c && (WEq(s, "$1 + $2") || WEq(s, "$1 - $2") || WEq(s, "$1 * $2") || WEq(s, "$1 / $2") || WEq(s, "$1 & $2") || WEq(s, "$1 | $2") || WEq(s, "$1 ^ $2") || WEq(s, "($1 % $2)"))) expr = WG3(u, "(", WGExpand(u, s, args), ")");
    else if (WPrefix(s, "au_printf(\"")) {
        i = 11;
        while (s[i] && s[i] != '"') {if (s[i] == 92 && s[i + 1]) i++; i++;}
        if (s[i] != '"') {WFail(u, n->token, "Unsupported Feature", "Malformed printf embed"); return "0";}
        fmt = WText(u, s + 10, (i - 10) + 1); tail = s + i + 1;
        // Only comma-separated placeholders are accepted after the literal format.
        CWBuffer *expected = WAlloc(u, sizeof(CWBuffer)); j = 1;
        for (bound = args; bound; bound = bound->next) {WGPut(u, expected, ", $"); WGPut(u, expected, WGDec(u, j++));}
        WGPut(u, expected, ")");
        if (!WEq(tail, expected->data)) {WFail(u, n->token, "Unsupported Feature", "Unsupported printf argument syntax"); return "0";}
        for (bound = args; bound; bound = bound->next) if (WEq(bound->ty->name, "Float32")) bound->name = WG3(u, "wc_f32_to_f64(", bound->name, ")");
        expr = WG3(u, "Print(", fmt, WGExpand(u, tail, args)); WGLine(g, WGCat(u, expr, ";")); return "0";
    } else if (c && !c->next && (WEq(s, "__builtin_add_overflow($1, $2, &$3)") || WEq(s, "__builtin_sub_overflow($1, $2, &$3)") || WEq(s, "__builtin_mul_overflow($1, $2, &$3)"))) {
        bits = WIntBits(c->ty->name); sign = WPrefix(c->ty->name, "Int"); maximum = "0xffffffffffffffff"; minimum = "0x8000000000000000";
        if (bits == 8) {maximum = "255"; minimum = "-128";} else if (bits == 16) {maximum = "65535"; minimum = "-32768";} else if (bits == 32) {maximum = "4294967295"; minimum = "-2147483648";}
        if (sign) {maximum = "0x7fffffffffffffff"; if (bits == 8) maximum = "127"; else if (bits == 16) maximum = "32767"; else if (bits == 32) maximum = "2147483647";}
        bound = WNode(u, "argument", n->token); bound->name = maximum; c->next = bound;
        bound->next = WNode(u, "argument", n->token); bound->next->name = minimum;
        pattern = "($2 && ($1 > ($4 / $2)))";
        if (WPrefix(s, "__builtin_add")) pattern = "($1 > ($4 - $2))";
        if (WPrefix(s, "__builtin_sub")) pattern = "($1 < $2)";
        if (sign) {
            pattern = "(($1 > 0) && ((($2 > 0) && ($1 > ($4 / $2))) || (($2 < 0) && ($2 < ($5 / $1))))) || (($1 < 0) && ((($2 > 0) && ($1 < ($5 / $2))) || (($2 < 0) && ($1 < ($4 / $2)))))";
            if (WPrefix(s, "__builtin_add")) pattern = "(($2 > 0) && ($1 > ($4 - $2))) || (($2 < 0) && ($1 < ($5 - $2)))";
            if (WPrefix(s, "__builtin_sub")) pattern = "(($2 < 0) && ($1 > ($4 + $2))) || (($2 > 0) && ($1 < ($5 + $2)))";
        }
        tmp = WGTemp(g, ty); WGCopy(g, tmp, WG3(u, "(", WGExpand(u, pattern, args), ")"), ty);
        pattern = "($1 * $2)"; if (WPrefix(s, "__builtin_add")) pattern = "($1 + $2)"; if (WPrefix(s, "__builtin_sub")) pattern = "($1 - $2)";
        WGCopy(g, c->name, WGExpand(u, pattern, args), c->ty); return tmp;
    } else if (WEq(s, "au_abort($1)") && a && !b) expr = WGExpand(u, "au_abort(&$1)", args);
    else if (WEq(s, "au_get_argc()") && !a) expr = s;
    else if (WEq(s, "au_get_nth_arg($1)") && a && !b) {
        tmp = WGTemp(g, ty); WGLine(g, WG3(u, "au_get_nth_arg(&", tmp, WGCat(u, WGExpand(u, ", $1)", args), ";"))); return tmp;
    } else if (WEq(s, "au_make_span($1, $2)") && b && !c) {
        tmp = WGTemp(g, ty); WGLine(g, WG3(u, "au_make_span(&", tmp, WGCat(u, WGExpand(u, ", $1, $2)", args), ";"))); return tmp;
    } else if ((WEq(s, "au_calloc($1, $2)") || WEq(s, "au_realloc($1, $2)")) && b && !c) expr = WGExpand(u, s, args);
    else if (WEq(s, "au_free($1)") && a && !b) expr = WGExpand(u, s, args);
    else if ((WEq(s, "au_memcpy($1, $2, $3)") || WEq(s, "au_memmove($1, $2, $3)")) && c && !c->next) expr = WGExpand(u, s, args);
    if (!expr) {WFail(u, n->token, "Unsupported Feature", "Unsupported C embed pattern"); return "0";}
    if (a && WIntBits(ty->name) && (WEq(a->ty->name, "Float64") || WEq(a->ty->name, "Float32")) && (WEq(s, "$1") || WPrefix(s, "(("))) {
        U8 *numeric = WGFresh(g, "wc"); WGLine(g, WG3(u, "I64 ", numeric, ";")); WGLine(g, WG3(u, numeric, " = ", WGCat(u, expr, ";"))); expr = numeric;
    }
    tmp = WGTemp(g, ty); WGCopy(g, tmp, expr, ty); return tmp;
}
CWNode *WGArguments(CWGen *g, CWNode *n)
{
    CWNode *args = NULL, *last = NULL, *a, *v, *expr;
    for (a = n->first; a; a = a->next) if (WEq(a->role, "argument")) {
            expr = a; if (WEq(a->tag, "argument")) expr = WChild(a, "value");
            v = WNode(g->unit, "value", a->token); v->name = WGExpr(g, expr); v->ty = WGConcrete(g, expr->ty); v->resolved = a->resolved;
            if (last) last->next = v; else args = v; last = v;
        }
    return args;
}
U8 *WGCallExpr(CWGen *g, CWNode *n)
{
    CWUnit *u = g->unit; CWNode *d = n->resolved, *args = WGArguments(g, n), *p, *v, *env = WScope(u, NULL), *f, *tc, *inst, *ty = WGConcrete(g, n->ty), *b, *bound, *q;
    CWBuffer *call = WAlloc(u, sizeof(CWBuffer));
    U8 *tmp, *dst, *role = "parameter", *foreign = NULL;
    if (WEq(d->tag, "record") || WEq(d->tag, "constructor")) {
        tmp = WGTemp(g, ty); WGLine(g, WG3(u, "MemSet(&", tmp, WG3(u, ", 0, sizeof(", WGType(g, ty), "));")));
        if (WEq(d->tag, "constructor")) WGLine(g, WG3(u, tmp, ".tag = ", WGCat(u, WGDec(u, WGTag(d)), ";")));
        for (p = d->first; p; p = p->next) if (WEq(p->role, "slot")) {
                for (v = args; v; v = v->next) if (v->resolved == p) break;
                if (v) {
                    dst = tmp; if (WEq(d->tag, "constructor")) dst = WG3(u, tmp, ".", WGName(g, d));
                    dst = WG3(u, dst, ".", WGName(g, p)); WGCopy(g, dst, v->name, v->ty);
                }
            }
        return tmp;
    }
    if (!WEq(d->tag, "function") && !WEq(d->tag, "method")) {
        CWNode *ft = WGConcrete(g, WDeclType(d)), *rt = ft->last;
        U8 *ptr = WGFresh(g, "wfp"); CWBuffer *sig = WAlloc(u, sizeof(CWBuffer));
        if (WGAggregate(rt)) WGPut(u, sig, "U0"); else WGPut(u, sig, WGType(g, rt));
        WGPut(u, sig, WG3(u, " (*", ptr, ")("));
        Bool comma = FALSE;
        if (WGAggregate(rt)) {WGPut(u, sig, WGCat(u, WGType(g, rt), " *")); comma = TRUE;}
        for (p = ft->first; p && p->next; p = p->next) {
            if (comma) WGPut(u, sig, ", "); comma = TRUE; WGPut(u, sig, WGType(g, p)); if (WGAggregate(p)) WGPut(u, sig, " *");
        }
        WGPut(u, sig, ");"); WGLine(g, sig->data); WGLine(g, WG3(u, ptr, " = ", WGCat(u, WGName(g, d), ";")));
        tmp = WGTemp(g, rt); WGPut(u, call, WGCat(u, ptr, "(")); comma = FALSE;
        if (WGAggregate(rt)) {WGPut(u, call, WGCat(u, "&", tmp)); comma = TRUE;}
        for (v = args; v; v = v->next) {if (comma) WGPut(u, call, ", "); comma = TRUE; if (WGAggregate(v->ty)) WGPut(u, call, "&"); WGPut(u, call, v->name);}
        WGPut(u, call, ")");
        if (WGAggregate(rt)) WGLine(g, WGCat(u, call->data, ";")); else WGCopy(g, tmp, call->data, rt);
        return tmp;
    }
    // Resolve the class instance again after substituting enclosing generics.
    for (b = n->pair->first; b; b = b->next) {bound = WNode(u, "substitution", b->token); bound->resolved = b->resolved; bound->ty = WGConcrete(g, b->ty); WAdd(env, bound, "binding");}
    if (WEq(d->tag, "method") && d->owner && WEq(d->owner->tag, "typeclass")) {
        tc = d->owner; bound = WBinding(env, WChild(tc, "type-parameter")); inst = WFindInstance(u, g->current->resolved, tc, bound);
        if (inst && inst->pair) inst = inst->pair;
        if (!inst || WEq(inst->tag, "type-parameter")) {WFail(u, n->token, "Unsupported Feature", "Could not specialize typeclass call"); return "0";}
        CWNode *ie = WScope(u, NULL); WMatch(u, WChild(inst, "argument"), bound, ie);
        for (p = inst->first; p; p = p->next) if (WEq(p->role, "method") && WEq(p->name, d->name)) break;
        if (!p) {WFail(u, n->token, "Unsupported Feature", "Instance method body is missing"); return "0";}
        q = WChild(p, "type-parameter");
        for (b = d->first; b; b = b->next) if (WEq(b->role, "type-parameter") && q) {
                bound = WNode(u, "substitution", b->token); bound->resolved = q; bound->ty = WBinding(env, b); WAdd(ie, bound, "binding");
                q = q->next; while (q && !WEq(q->role, "type-parameter")) q = q->next;
            }
        // Parameter identities differ between declaration and implementation.
        q = WChild(p, "parameter");
        for (b = d->first; b; b = b->next) if (WEq(b->role, "parameter")) {
                for (v = args; v; v = v->next) if (v->resolved == b) v->resolved = q;
                if (q) {q = q->next; while (q && !WEq(q->role, "parameter")) q = q->next;}
            }
        d = p; env = ie;
    }
    // Public function definitions may use distinct type parameter nodes.
    if (d->pair && WChild(d->pair, "body")) {
        q = WChild(d->pair, "type-parameter");
        for (p = d->first; p; p = p->next) if (WEq(p->role, "type-parameter") && q) {
                bound = WNode(u, "substitution", p->token); bound->resolved = q; bound->ty = WBinding(env, p); WAdd(env, bound, "binding");
                q = q->next; while (q && !WEq(q->role, "type-parameter")) q = q->next;
            }
        q = WChild(d->pair, "parameter");
        for (p = d->first; p; p = p->next) if (WEq(p->role, "parameter")) {
                for (v = args; v; v = v->next) if (v->resolved == p) v->resolved = q;
                if (q) {q = q->next; while (q && !WEq(q->role, "parameter")) q = q->next;}
            }
        d = d->pair;
    }
    if (!WChild(d, "body")) {WFail(u, n->token, "Unsupported Feature", "No function implementation for output"); return "0";}
    for (p = d->first; p; p = p->next) if (WEq(p->tag, "pragma") && WEq(p->name, "Foreign_Import")) {
            q = WChild(p, "argument"); if (q) foreign = WChild(q, "value")->name;
        }
    if (foreign) {
        if (WEq(foreign, "putchar")) WGPut(u, call, "au_putchar(");
        else if (WEq(foreign, "puts")) WGPut(u, call, "au_puts(");
        else {WFail(u, n->token, "Unsupported Feature", "Unsupported foreign binding"); return "0";}
        if (args) {WGPut(u, call, args->name); if (WEq(foreign, "puts")) WGPut(u, call, ".wh_data");}
    } else {
        f = WGRequest(g, d, env); WGPut(u, call, WGCat(u, f->name, "("));
        tmp = NULL;
        if (WGAggregate(ty)) {tmp = WGTemp(g, ty); WGPut(u, call, WGCat(u, "&", tmp));}
        comma = tmp != NULL;
        for (p = d->first; p; p = p->next) if (WEq(p->role, "parameter")) {
                for (v = args; v; v = v->next) if (v->resolved == p) break;
                if (!v) {WFail(u, n->token, "Unsupported Feature", "Argument mapping failed"); break;}
                if (comma) WGPut(u, call, ", "); comma = TRUE;
                if (WGAggregate(v->ty)) WGPut(u, call, "&"); WGPut(u, call, v->name);
            }
        if (tmp) {WGPut(u, call, ");"); WGLine(g, call->data); return tmp;}
    }
    WGPut(u, call, ")"); tmp = WGTemp(g, ty); WGCopy(g, tmp, call->data, ty); return tmp;
}
U8 *WGExpr(CWGen *g, CWNode *n)
{
    CWUnit *u = g->unit; CWNode *ty = WGConcrete(g, n->ty), *d, *v, *args;
    U8 *a, *b, *tmp, *op, *text;
    if (u->error_kind) return "0";
    if (WEq(n->tag, "literal")) {
        if (WEq(n->name, "nil") || WEq(n->name, "false")) return "0";
        if (WEq(n->name, "true")) return "1";
        if (n->token->kind == 3 || n->token->kind == 4) {
            text = WGInteger(u, n->name);
            if (WEq(ty->name, "Float32")) {
                tmp = WGTemp(g, ty); WGCopy(g, tmp, WG3(u, "wc_f64_to_f32(", text, ")"), ty); return tmp;
            }
            return text;
        }
        text = WGStringValue(u, n); tmp = WGTemp(g, ty);
        WGLine(g, WG3(u, "au_make_span_from_string(&", tmp, WG3(u, ", ", WGQuote(u, text), WG3(u, ", ", WGDec(u, StrLen(text)), ");")))); return tmp;
    }
    if (WEq(n->tag, "variable")) {
        d = n->resolved;
        if (WEq(d->tag, "constant")) {
            if (d->pair) d = d->pair;
            v = WChild(d, "value"); if (v) return WGExpr(g, v);
            WFail(u, n->token, "Unsupported Feature", "Constant has no implementation"); return "0";
        }
        if (WEq(d->tag, "function")) {
            CWNode *fe = WScope(u, NULL), *bp, *bound;
            if (n->pair) for (bp = n->pair->first; bp; bp = bp->next) {bound = WNode(u, "substitution", bp->token); bound->resolved = bp->resolved; bound->ty = WGConcrete(g, bp->ty); WAdd(fe, bound, "binding");}
            CWNode *target = WGRequest(g, d, fe); return WGCat(u, "&", target->name);
        }
        return WGName(g, d);
    }
    if (WEq(n->tag, "path") || WEq(n->tag, "ref-path")) return WGPath(g, n);
    if (WEq(n->tag, "call")) return WGCallExpr(g, n);
    if (WEq(n->tag, "embed")) {args = WGArguments(g, n); return WGEmbed(g, n, args);}
    if (WEq(n->tag, "sizeof")) return WG3(u, "sizeof(", WGType(g, WGConcrete(g, WChild(n, "type"))), ")");
    if (WEq(n->tag, "borrow-expression")) {
        v = WChild(n, "value"); a = WGName(g, v->resolved);
        if (WEq(n->name, "&~")) return a;
        return WG3(u, "(&(", a, "))");
    }
    if (WEq(n->tag, "dereference")) return WG3(u, "(*(", WGExpr(g, WChild(n, "value")), "))");
    if (WEq(n->tag, "cast")) return WGExpr(g, WChild(n, "value"));
    if (WEq(n->tag, "if-expression")) {
        a = WGExpr(g, WChild(n, "condition")); tmp = WGTemp(g, ty); WGLine(g, WG3(u, "if (", a, ") {"));
        b = WGExpr(g, WChild(n, "then")); WGCopy(g, tmp, b, ty); WGLine(g, "} else {"); b = WGExpr(g, WChild(n, "else")); WGCopy(g, tmp, b, ty); WGLine(g, "}"); return tmp;
    }
    if (WEq(n->tag, "binary")) {
        a = WGExpr(g, WChild(n, "left")); tmp = WGTemp(g, ty); op = n->name;
        if (WEq(op, "and") || WEq(op, "or")) {
            WGCopy(g, tmp, a, ty);
            text = tmp; if (WEq(op, "or")) text = WG3(u, "!(", tmp, ")");
            WGLine(g, WG3(u, "if (", text, ") {")); b = WGExpr(g, WChild(n, "right")); WGCopy(g, tmp, b, ty); WGLine(g, "}"); return tmp;
        }
        b = WGExpr(g, WChild(n, "right"));
        if (WEq(WGConcrete(g, WChild(n, "left")->ty)->name, "Float32")) {a = WG3(u, "wc_f32_to_f64(", a, ")"); b = WG3(u, "wc_f32_to_f64(", b, ")");}
        if (WEq(op, "=")) op = "=="; else if (WEq(op, "/=")) op = "!=";
        text = WG3(u, "(", a, WG3(u, " ", op, WG3(u, " ", b, ")"))); if (WEq(ty->name, "Float32")) text = WG3(u, "wc_f64_to_f32(", text, ")"); WGCopy(g, tmp, text, ty); return tmp;
    }
    if (WEq(n->tag, "unary")) {
        a = WGExpr(g, WChild(n, "value")); tmp = WGTemp(g, ty); op = n->name; if (WEq(op, "not")) op = "!";
        if (WEq(ty->name, "Float32")) a = WG3(u, "wc_f32_to_f64(", a, ")");
        text = WG3(u, op, "(", WGCat(u, a, ")")); if (WEq(ty->name, "Float32")) text = WG3(u, "wc_f64_to_f32(", text, ")");
        WGCopy(g, tmp, text, ty); return tmp;
    }
    WFail(u, n->token, "Unsupported Feature", "Expression output is not implemented"); return "0";
}
U0 WGBindLocal(CWGen *g, CWNode *binding, U8 *value)
{
    CWNode *ty = WGConcrete(g, WDeclType(binding)); U8 *name = WGName(g, binding);
    WGLine(g, WG3(g->unit, WGType(g, ty), " ", WGCat(g->unit, name, ";"))); WGCopy(g, name, value, ty);
}
U0 WGStmt(CWGen *g, CWNode *n)
{
    CWUnit *u = g->unit; CWNode *c, *b, *v, *ty, *ref, *rt;
    U8 *a, *value, *name, *dest, *limit;
    if (!n || u->error_kind) return;
    if (WEq(n->tag, "block")) {for (c = n->first; c && !u->error_kind; c = c->next) WGStmt(g, c);}
    else if (WEq(n->tag, "let")) {value = WGExpr(g, WChild(n, "value")); WGBindLocal(g, WChild(n, "binding"), value);}
    else if (WEq(n->tag, "destructure")) {
        value = WGExpr(g, WChild(n, "value"));
        for (b = n->first; b; b = b->next) if (WEq(b->role, "binding")) WGBindLocal(g, b, WG3(u, value, ".", WGName(g, b->resolved)));
    } else if (WEq(n->tag, "assign")) {
        // Resolve lvalue indices before evaluating the right-hand side.
        v = WChild(n, "target"); a = WGExpr(g, v); value = WGExpr(g, WChild(n, "value")); WGCopy(g, a, value, WGConcrete(g, v->ty));
    } else if (WEq(n->tag, "return")) {
        value = WGExpr(g, WChild(n, "value")); rt = WSubst(u, WChild(g->current->resolved, "result"), g->bindings);
        if (WGAggregate(rt)) {WGCopy(g, "*wr", value, rt); WGLine(g, "return;");}
        else WGLine(g, WG3(u, "return ", value, ";"));
    } else if (WEq(n->tag, "discard")) WGExpr(g, WChild(n, "value"));
    else if (WEq(n->tag, "if")) {
        a = WGExpr(g, WChild(n, "condition")); WGLine(g, WG3(u, "if (", a, ") {")); WGStmt(g, WChild(n, "then"));
        c = WChild(n, "else"); if (c) {WGLine(g, "} else {"); WGStmt(g, c);} WGLine(g, "}");
    } else if (WEq(n->tag, "while")) {
        WGLine(g, "while (1) {"); a = WGExpr(g, WChild(n, "condition")); WGLine(g, WG3(u, "if (!(", a, ")) break;")); WGStmt(g, WChild(n, "body")); WGLine(g, "}");
    } else if (WEq(n->tag, "for")) {
        name = WGName(g, n->resolved); value = WGExpr(g, WChild(n, "from")); WGBindLocal(g, n->resolved, value);
        WGLine(g, "while (1) {"); limit = WGExpr(g, WChild(n, "to")); WGLine(g, WG3(u, "if (", name, WG3(u, " > ", limit, ") break;")));
        WGStmt(g, WChild(n, "body")); WGLine(g, WGCat(u, name, "++;")); WGLine(g, "}");
    } else if (WEq(n->tag, "borrow")) {
        v = WChild(n, "original"); value = WGName(g, v->resolved); c = WChild(n, "mode");
        if (!WEq(c->name, "&~")) value = WG3(u, "(&(", value, "))"); WGBindLocal(g, n->resolved, value); WGStmt(g, WChild(n, "body"));
    } else if (WEq(n->tag, "case")) {
        v = WChild(n, "value"); value = WGExpr(g, v); ty = WGConcrete(g, v->ty); ref = NULL;
        if (WEq(ty->name, "&") || WEq(ty->name, "&!")) {ref = ty; ty = ty->first; value = WG3(u, "(*(", value, "))");}
        WGLine(g, WG3(u, "switch ((", value, ").tag) {"));
        for (c = n->first; c && !u->error_kind; c = c->next) if (WEq(c->role, "when")) {
                WGLine(g, WG3(u, "case ", WGDec(u, WGTag(c->resolved)), ":\n{"));
                for (b = c->first; b; b = b->next) if (WEq(b->role, "binding")) {
                        dest = WG3(u, "(", value, WG3(u, ").", WGName(g, c->resolved), WGCat(u, ".", WGName(g, b->resolved))));
                        if (ref) dest = WG3(u, "(&(", dest, "))"); WGBindLocal(g, b, dest);
                    }
                WGStmt(g, WChild(c, "body")); WGLine(g, "break;\n}");
            }
        WGLine(g, "}");
    } else if (!WEq(n->tag, "skip")) WFail(u, n->token, "Unsupported Feature", "Statement output is not implemented");
}
U8 *WGSignature(CWGen *g, CWNode *f)
{
    CWUnit *u = g->unit; CWBuffer *b = WAlloc(u, sizeof(CWBuffer));
    CWNode *d = f->resolved, *p, *t = WSubst(u, WChild(d, "result"), f->pair);
    Bool comma = FALSE;
    if (WGAggregate(t)) WGPut(u, b, "U0"); else WGPut(u, b, WGType(g, t));
    WGPut(u, b, WG3(u, " ", f->name, "("));
    if (WGAggregate(t)) {WGPut(u, b, WGCat(u, WGType(g, t), " *wr")); comma = TRUE;}
    for (p = d->first; p; p = p->next) if (WEq(p->role, "parameter")) {
            t = WSubst(u, WChild(p, "type"), f->pair);
            if (comma) WGPut(u, b, ", "); comma = TRUE;
            WGPut(u, b, WGType(g, t)); WGPut(u, b, " ");
            if (WGAggregate(t)) WGPut(u, b, "*wp_");
            WGPut(u, b, WGName(g, p));
        }
    WGPut(u, b, ")"); return b->data;
}
U8 *WEmit(CWUnit *u, U8 *entry, U8 *runtime, Bool native)
{
    CWGen *g = WAlloc(u, sizeof(CWGen)); CWNode *m, *d, *f, *p, *ty, *entryfun = NULL;
    CWBuffer *result = WAlloc(u, sizeof(CWBuffer)), *protos = WAlloc(u, sizeof(CWBuffer));
    U8 *mn, *fn, *sig, *value, *call; I64 i = 0;
    g->unit = u; g->types_text = WAlloc(u, sizeof(CWBuffer));
    while (entry[i] && entry[i] != ':') i++;
    if (!entry[i]) {WFail(u, NULL, "Entrypoint Definition Error", "Expected Module:function entrypoint"); return NULL;}
    mn = WText(u, entry, i); fn = entry + i + 1; m = WModule(u, mn, "module");
    d = NULL; if (m) d = WLocal(m->scope, fn);
    if (!d || !WEq(d->tag, "function")) {WFail(u, NULL, "Entrypoint Definition Error", "Entrypoint function not found"); return NULL;}
    ty = WChild(d, "result"); p = WChild(d, "parameter");
    if (WChild(d, "type-parameter") || !ty || !WEq(ty->name, "ExitCode") || (p && (!WEq(WChild(p, "type")->name, "RootCapability") || (p->next && WEq(p->next->role, "parameter"))))) {
        WFail(u, d->token, "Entrypoint Definition Error", "Entrypoint requires ExitCode and at most one RootCapability"); return NULL;
    }
    entryfun = WGRequest(g, d, WScope(u, NULL));
    for (f = g->functions; f && !u->error_kind; f = f->next) {
        g->current = f; g->bindings = f->pair; g->body = WAlloc(u, sizeof(CWBuffer));
        sig = WGSignature(g, f); WGLine(g, WGCat(u, sig, " {"));
        for (p = f->resolved->first; p; p = p->next) if (WEq(p->role, "parameter")) {
                ty = WSubst(u, WChild(p, "type"), f->pair);
                if (WGAggregate(ty)) {
                    WGLine(g, WG3(u, WGType(g, ty), " ", WGCat(u, WGName(g, p), ";")));
                    WGCopy(g, WGName(g, p), WGCat(u, "*wp_", WGName(g, p)), ty);
                }
            }
        WGStmt(g, WChild(f->resolved, "body")); WGLine(g, "}"); f->role = g->body->data;
        WGPut(u, protos, WG3(u, "extern ", sig, ";\n"));
        if (g->serial > 100000) WFail(u, f->token, "Unsupported Feature", "Specialization limit exceeded");
    }
    g->body = WAlloc(u, sizeof(CWBuffer)); g->current = entryfun; g->bindings = entryfun->pair;
    WGLine(g, "U0 WarmMain() {"); ty = WChild(entryfun->resolved, "result"); value = WGTemp(g, ty);
    call = WG3(u, entryfun->name, "(&", value); p = WChild(entryfun->resolved, "parameter");
    if (p) {fn = WGTemp(g, WChild(p, "type")); WGLine(g, WG3(u, "MemSet(&", fn, WG3(u, ",0,sizeof(", WGType(g, WChild(p, "type")), "));"))); call = WG3(u, call, ", &", fn);}
    WGLine(g, WGCat(u, call, ");"));
    if (native) WGLine(g, WG3(u, "if (", value, ".tag != 0) NativeExit(1);"));
    WGLine(g, "}\nWarmMain();");
    if (u->error_kind) return NULL;
    WGPut(u, result, runtime); if (g->types_text->data) WGPut(u, result, g->types_text->data);
    WGPut(u, result, protos->data);
    for (f = g->functions; f; f = f->next) WGPut(u, result, f->role);
    WGPut(u, result, g->body->data); return result->data;
}
