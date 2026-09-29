// Nominal types, universe validation, substitutions and checked literals.
CWNode *WTypeNamed(CWUnit *u, CWNode *scope, U8 *name)
{
    CWNode *t = WNode(u, "type", NULL); t->name = name; t->resolved = WLookup(scope, name); return t;
}
CWNode *WCanon(CWNode *d)
{
    if (d && d->pair && WEq(d->tag, "type")) return d->pair;
    return d;
}
Bool WTypeEq(CWNode *a, CWNode *b)
{
    CWNode *x, *y;
    if (!a || !b) return a == b;
    if (WCanon(a->resolved) != WCanon(b->resolved) || !WEq(a->name, b->name)) {
        if (!a->resolved || !b->resolved || WCanon(a->resolved) != WCanon(b->resolved)) return FALSE;
    }
    x = a->first; y = b->first;
    while (x && y) {if (!WTypeEq(x, y)) return FALSE; x = x->next; y = y->next;}
    return !x && !y;
}
I64 WUniverseOf(CWNode *t)
{
    CWNode *d, *v, *p, *a;
    I64 result = 0;
    if (!t) return 0;
    if (WEq(t->name, "&") || WEq(t->name, "Span")) return 0;
    if (WEq(t->name, "&!") || WEq(t->name, "Span!")) return 1;
    if (WEq(t->name, "Static")) return 3;
    d = WCanon(t->resolved);
    if (!d) return 0;
    v = WChild(d, "universe");
    if (!v) return 0;
    if (WEq(v->name, "Linear")) return 1;
    if (WEq(v->name, "Region")) return 3;
    if (WEq(v->name, "Type")) {
        if (WEq(d->tag, "type-parameter")) return 2;
        for (a = t->first; a; a = a->next) {
            result = WUniverseOf(a); if (result == 1 || result == 2) return result;
        }
    }
    return 0;
}
Bool WTypeVar(CWNode *t) {return t && t->resolved && WEq(t->resolved->tag, "type-parameter");}
CWNode *WBinding(CWNode *bindings, CWNode *var)
{
    CWNode *b;
    if (!bindings) return NULL;
    for (b = bindings->first; b; b = b->next) if (b->resolved == var) return b->ty;
    return NULL;
}
CWNode *WSubst(CWUnit *u, CWNode *t, CWNode *bindings)
{
    CWNode *n, *c, *v;
    if (!t) return NULL;
    v = WBinding(bindings, t->resolved); if (v) return v;
    n = WNode(u, "type", t->token); n->name = t->name; n->resolved = t->resolved;
    for (c = t->first; c; c = c->next) {
        v = WSubst(u, c, bindings);
        // Each tree occurrence owns its sibling link, including substitutions.
        CWNode *copy = WNode(u, "type", v->token);
        copy->name = v->name; copy->resolved = v->resolved; copy->first = v->first; copy->last = v->last;
        WAdd(n, copy, "argument");
    }
    return n;
}
Bool WMatch(CWUnit *u, CWNode *pattern, CWNode *actual, CWNode *bindings)
{
    CWNode *bound, *b, *x, *y;
    I64 pu, au;
    if (!pattern || !actual) return FALSE;
    if (WTypeVar(pattern)) {
        bound = WBinding(bindings, pattern->resolved);
        if (bound) return WTypeEq(bound, actual);
        pu = WUniverseOf(pattern); au = WUniverseOf(actual);
        if (pu != 2 && pu != au) return FALSE;
        if (pu == 2 && au == 3) return FALSE;
        b = WNode(u, "substitution", pattern->token); b->resolved = pattern->resolved; b->ty = actual; WAdd(bindings, b, "binding"); return TRUE;
    }
    if (WCanon(pattern->resolved) != WCanon(actual->resolved)) return FALSE;
    if (!pattern->resolved && !WEq(pattern->name, actual->name)) return FALSE;
    x = pattern->first; y = actual->first;
    while (x && y) {if (!WMatch(u, x, y, bindings)) return FALSE; x = x->next; y = y->next;}
    return !x && !y;
}
U0 WRequire(CWUnit *u, CWNode *n, CWNode *actual, CWNode *expected)
{
    if (expected && actual && !WTypeEq(actual, expected)) WFail(u, n->token, "Type Error", "Type mismatch");
}
I64 WIntBits(U8 *name)
{
    if (WEq(name, "Nat8") || WEq(name, "Int8")) return 8;
    if (WEq(name, "Nat16") || WEq(name, "Int16")) return 16;
    if (WEq(name, "Nat32") || WEq(name, "Int32")) return 32;
    if (WEq(name, "Nat64") || WEq(name, "Int64") || WEq(name, "Index") || WEq(name, "ByteSize")) return 64;
    return 0;
}
Bool WNumber(CWNode *t) {return t && (WIntBits(t->name) || WEq(t->name, "Float32") || WEq(t->name, "Float64"));}
U0 WIntLiteral(CWUnit *u, CWNode *n, CWNode *ty)
{
    U8 *s = n->name;
    I64 bits = WIntBits(ty->name), base = 10, d, i = 0;
    Bool negative = FALSE, sign = WPrefix(ty->name, "Int");
    U64 max = 0xffffffffffffffff, value = 0;
    if (!bits) {WFail(u, n->token, "Type Error", "Integer literal requires an integer type"); return;}
    if (s[i] == '-' || s[i] == '+') {negative = s[i] == '-'; i++;}
    if (negative && !sign) {WFail(u, n->token, "Type Error", "Negative unsigned integer literal"); return;}
    if (sign) {max = 0x7fffffffffffffff; if (bits < 64) max = (1 << (bits - 1)) - 1; if (negative) max++;}
    else if (bits < 64) max = (1 << bits) - 1;
    if (s[i] == 39) {
        value = s[i + 1]; if (value == 92) {value = s[i + 2]; if (value == 'n') value = 10; else if (value == 'r') value = 13; else if (value == 't') value = 9;}
        if (value > max) WFail(u, n->token, "Type Error", "Character literal is out of range");
        return;
    }
    if (s[i] == '#') {if (s[i + 1] == 'x') base = 16; else if (s[i + 1] == 'o') base = 8; else base = 2; i += 2;}
    while (s[i]) {
        d = s[i++];
        if (d != 39) {
            if (d >= 'a' && d <= 'f') d = (d - 'a') + 10;
            else if (d >= 'A' && d <= 'F') d = (d - 'A') + 10;
            else d -= '0';
            if (value > (max - d) / base) {WFail(u, n->token, "Type Error", "Integer literal is out of range"); return;}
            value = (value * base) + d;
        }
    }
}
CWNode *WTypeParameters(CWUnit *u, CWNode *type)
{
    CWNode *bindings = WScope(u, NULL), *d = WCanon(type->resolved), *p, *a = type->first, *b;
    if (d) for (p = d->first; p; p = p->next) if (WEq(p->role, "type-parameter") && a) {
                b = WNode(u, "substitution", p->token); b->resolved = p; b->ty = a; WAdd(bindings, b, "binding"); a = a->next;
            }
    return bindings;
}
U0 WValidateType(CWUnit *u, CWNode *t)
{
    CWNode *d, *p, *a, *b;
    I64 arity = 0, count = 0, pu, au;
    if (!t || u->error_kind) return;
    for (a = t->first; a; a = a->next) {count++; WValidateType(u, a);}
    d = WCanon(t->resolved);
    if (d && (WEq(d->tag, "record") || WEq(d->tag, "union") || WEq(d->tag, "type"))) {
        a = t->first;
        for (p = d->first; p; p = p->next) if (WEq(p->role, "type-parameter")) {
                arity++;
                if (a) {
                    b = WNode(u, "type", p->token); b->resolved = p; b->name = p->name;
                    pu = WUniverseOf(b); au = WUniverseOf(a);
                    if ((pu != 2 && pu != au) || (pu == 2 && au == 3)) WFail(u, t->token, "Type Error", "Type argument has the wrong universe");
                    a = a->next;
                }
            }
    } else if (WEq(t->name, "&") || WEq(t->name, "&!") || WEq(t->name, "Span") || WEq(t->name, "Span!")) {
        arity = 2;
        if (count == 2 && WUniverseOf(t->first->next) != 3) WFail(u, t->token, "Type Error", "Reference requires a region argument");
    } else if (WEq(t->name, "Pointer") || WEq(t->name, "Address")) arity = 1;
    else if (WEq(t->name, "Fn")) arity = count;
    if (count != arity) WFail(u, t->token, "Type Error", "Wrong number of type arguments");
}
