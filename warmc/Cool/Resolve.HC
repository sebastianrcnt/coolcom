// Modules, declaration identities, explicit import aliases, and lexical scopes.
CWNode *WScope(CWUnit *u, CWNode *outer)
{
    CWNode *s = WNode(u, "scope", NULL); s->resolved = outer; return s;
}
CWNode *WLocal(CWNode *scope, U8 *name)
{
    CWNode *s;
    if (!scope) return NULL;
    for (s = scope->first; s; s = s->next) if (WEq(s->name, name)) return s->resolved;
    return NULL;
}
CWNode *WLookup(CWNode *scope, U8 *name)
{
    CWNode *d;
    while (scope) {d = WLocal(scope, name); if (d) return d; scope = scope->resolved;}
    return NULL;
}
U0 WBind(CWUnit *u, CWNode *scope, U8 *name, CWNode *decl, U8 *kind)
{
    CWNode *s;
    if (WLocal(scope, name)) {WFail(u, decl->token, kind, WConcat(u, "Duplicate declaration or binding: ", name)); return;}
    s = WNode(u, "symbol", decl->token); s->name = name; s->resolved = decl; WAdd(scope, s, "symbol");
}
CWNode *WModule(CWUnit *u, U8 *name, U8 *tag)
{
    CWNode *m;
    for (m = u->modules; m; m = m->next) if (WEq(m->name, name) && WEq(m->tag, tag)) return m;
    return NULL;
}
U0 WIndexDecl(CWUnit *u, CWNode *scope, CWNode *d, CWNode *owner)
{
    CWNode *c;
    d->owner = owner;
    if (WEq(d->tag, "instance")) return;
    WBind(u, scope, d->name, d, "Declaration Error");
    if (WEq(d->tag, "union") || WEq(d->tag, "typeclass")) {
        for (c = d->first; c; c = c->next) if (WEq(c->role, "constructor") || WEq(c->role, "method")) {
                c->owner = d; WBind(u, scope, c->name, c, "Declaration Error");
            }
    }
}
Bool WSameSyntax(CWNode *a, CWNode *b)
{
    CWNode *x, *y;
    if (!a || !b) return a == b;
    if (!WEq(a->tag, b->tag) || !WEq(a->name, b->name)) return FALSE;
    x = a->first; y = b->first;
    while (x && y) {if (!WSameSyntax(x, y)) return FALSE; x = x->next; y = y->next;}
    return !x && !y;
}
U0 WIndex(CWUnit *u)
{
    CWNode *m, *p, *d, *other, *c, *builtin, *prim;
    U8 *names = "Unit Bool Nat8 Nat16 Nat32 Nat64 Int8 Int16 Int32 Int64 Index ByteSize Float32 Float64 Static Address Pointer Fn";
    U8 *start = names;
    CWNode *base = WScope(u, NULL);
    while (*start) {
        names = start; while (*names && *names != ' ') names++;
        prim = WNode(u, "primitive", NULL); prim->name = WText(u, start, names - start); WBind(u, base, prim->name, prim, "Declaration Error");
        start = names; if (*start) start++;
    }
    for (m = u->modules; m && !u->error_kind; m = m->next) {
        for (p = u->modules; p != m; p = p->next) if (WEq(m->name, p->name) && WEq(m->tag, p->tag)) WFail(u, m->token, "Declaration Error", "Duplicate module");
        m->scope = WScope(u, base); m->scope->owner = m;
        for (d = m->first; d; d = d->next) if (WEq(d->role, "declaration")) WIndexDecl(u, m->scope, d, m);
    }
    // Pair interfaces before importing, and give the body its public type declarations.
    for (m = u->modules; m && !u->error_kind; m = m->next) if (WEq(m->tag, "interface")) {
            p = WModule(u, m->name, "module"); m->pair = p;
            if (p) {
                p->pair = m;
                for (d = m->first; d && !u->error_kind; d = d->next) if (WEq(d->role, "declaration")) {
                        if (WEq(d->tag, "instance")) {
                            for (c = p->first; c; c = c->next) if (WEq(c->tag, "instance") && WEq(c->name, d->name) && WSameSyntax(WChild(c, "argument"), WChild(d, "argument"))) break;
                            if (!c) WFail(u, d->token, "Declaration Error", "Missing instance implementation");
                            else {d->pair = c; c->pair = d;}
                        } else {
                            other = WLocal(p->scope, d->name);
                            if (WEq(d->tag, "record") || WEq(d->tag, "union") || WEq(d->tag, "typeclass")) {
                                if (other) WFail(u, other->token, "Declaration Error", "Public type declared again in body");
                                else WIndexDecl(u, p->scope, d, m);
                            } else if (!other) WFail(u, d->token, "Declaration Error", "Missing implementation for public declaration");
                            else {d->pair = other; other->pair = d;}
                        }
                    }
            } else if (!WPrefix(m->name, "Austral.")) WFail(u, m->token, "Declaration Error", "Interface has no implementation");
        }
    // The reference combining pass selects the first body for each public
    // instance declaration, then excludes matching definitions from private defs.
    for (m = u->modules; m; m = m->next) if (WEq(m->tag, "module") && m->pair) {
            for (d = m->first; d; d = d->next) if (WEq(d->tag, "instance") && !d->pair) {
                    for (c = m->pair->first; c; c = c->next) if (WEq(c->tag, "instance") && WEq(c->name, d->name) && WSameSyntax(WChild(c, "argument"), WChild(d, "argument"))) d->flags |= 1024;
                }
        }
    builtin = WModule(u, "Austral.Pervasive", "interface");
    for (m = u->modules; m && !u->error_kind; m = m->next) {
        if (builtin && !WEq(m->name, "Austral.Pervasive")) {
            // Pervasive definitions are an implicit outer scope; local names shadow them.
            p = WScope(u, base); m->scope->resolved = p;
            for (c = builtin->scope->first; c; c = c->next) WBind(u, p, c->name, c->resolved, "Declaration Error");
        }
        for (d = m->first; d && !u->error_kind; d = d->next) if (WEq(d->tag, "import")) {
                p = WModule(u, d->name, "interface"); if (!p) p = WModule(u, d->name, "module");
                if (!p) {WFail(u, d->token, "Declaration Error", "Imported module not provided"); break;}
                if (WEq(d->name, "Austral.Memory")) {
                    for (c = m->first; c; c = c->next) if (WEq(c->tag, "pragma") && WEq(c->name, "Unsafe_Module")) break;
                    if (!c) WFail(u, d->token, "Declaration Error", "Austral.Memory import requires Unsafe_Module");
                }
                for (c = d->first; c && !u->error_kind; c = c->next) {
                    other = WLocal(p->scope, c->name);
                    if (!other) {WFail(u, c->token, "Declaration Error", "Imported declaration is missing or private"); break;}
                    c->resolved = other;
                    prim = WChild(c, "alias"); names = c->name; if (prim) names = prim->name;
                    WBind(u, m->scope, names, other, "Declaration Error");
                }
            }
    }
}
extern U0 WResolveTree(CWUnit *u, CWNode *n, CWNode *scope);
U0 WResolveType(CWUnit *u, CWNode *n, CWNode *scope)
{
    CWNode *c, *d;
    if (!n || u->error_kind) return;
    n->scope = scope;
    if (!WEq(n->name, "&") && !WEq(n->name, "&!") && !WEq(n->name, "Span") && !WEq(n->name, "Span!")) {
        d = WLookup(scope, n->name); n->resolved = d;
        if (!d) WFail(u, n->token, "Declaration Error", WConcat(u, "Unknown type: ", n->name));
        else if (!WEq(d->tag, "primitive") && !WEq(d->tag, "type-parameter") && !WEq(d->tag, "record") && !WEq(d->tag, "union") && !WEq(d->tag, "type")) WFail(u, n->token, "Declaration Error", "Name does not denote a type");
    }
    for (c = n->first; c; c = c->next) WResolveType(u, c, scope);
}
U0 WResolveTree(CWUnit *u, CWNode *n, CWNode *scope)
{
    CWNode *c, *b, *d, *s = scope, *t;
    U8 *name;
    if (!n || u->error_kind) return;
    n->scope = scope;
    if (WEq(n->tag, "type")) {WResolveType(u, n, scope); return;}
    if (WEq(n->tag, "variable") || WEq(n->tag, "call") || WEq(n->tag, "path") || WEq(n->tag, "ref-path")) {
        n->resolved = WLookup(scope, n->name);
        if (!n->resolved) WFail(u, n->token, "Generic Error", WConcat(u, "Unknown value or function: ", n->name));
    }
    if (WEq(n->tag, "block")) {
        s = WScope(u, scope); n->scope = s;
        for (c = n->first; c && !u->error_kind; c = c->next) {
            WResolveTree(u, c, s);
            if (WEq(c->tag, "let") || WEq(c->tag, "destructure")) {
                for (b = c->first; b; b = b->next) if (WEq(b->role, "binding")) {
                        t = WChild(b, "rename"); name = b->name; if (t) name = t->name;
                        b->owner = c; if (WEq(c->name, "var")) b->flags = 1;
                        if (WLookup(s, name)) WFail(u, b->token, "Generic Error", "Local binding shadows an existing name");
                        else WBind(u, s, name, b, "Generic Error");
                    }
            }
        }
        return;
    }
    if (WEq(n->tag, "for") || WEq(n->tag, "borrow") || WEq(n->tag, "when")) {
        s = WScope(u, scope);
        if (WEq(n->tag, "when")) {
            for (b = n->first; b; b = b->next) if (WEq(b->role, "binding")) {
                    WResolveType(u, WChild(b, "type"), scope); b->owner = n;
                    t = WChild(b, "rename"); name = b->name; if (t) name = t->name;
                    WBind(u, s, name, b, "Generic Error");
                }
        } else {
            b = WNode(u, "binding", n->token); b->name = n->name; b->owner = n; n->resolved = b;
            WBind(u, s, n->name, b, "Generic Error");
            if (WEq(n->tag, "borrow")) {
                t = WChild(n, "type"); b->ty = t;
                if (t && t->first && t->first->next) {
                    d = WNode(u, "primitive", t->first->next->token); d->name = t->first->next->name;
                    CWNode *uv = WNode(u, "universe", d->token); uv->name = "Region"; WAdd(d, uv, "universe");
                    t->first->next->resolved = d;
                    WBind(u, s, d->name, d, "Generic Error");
                }
            }
        }
    }
    for (c = n->first; c && !u->error_kind; c = c->next) {
        if (WEq(c->tag, "doc") || WEq(c->tag, "mode") || WEq(c->tag, "rename") || WEq(c->tag, "alias")) {}
        else if (WEq(n->tag, "borrow") && WEq(c->role, "type")) {}
        else if (WEq(c->role, "body")) WResolveTree(u, c, s);
        else WResolveTree(u, c, scope);
    }
}
U0 WResolveDecl(CWUnit *u, CWNode *d, CWNode *outer)
{
    CWNode *s = WScope(u, outer), *c, *p, *b;
    d->scope = s;
    for (c = d->first; c && !u->error_kind; c = c->next) if (WEq(c->role, "type-parameter")) {
            if (WLookup(s, c->name)) WFail(u, c->token, "Generic Error", "Duplicate type parameter");
            else WBind(u, s, c->name, c, "Generic Error");
            c->owner = d;
        }
    for (c = d->first; c && !u->error_kind; c = c->next) if (WEq(c->role, "parameter")) {
            WResolveType(u, WChild(c, "type"), s);
            if (WLookup(s, c->name)) WFail(u, c->token, "Generic Error", "Parameter shadows an existing name");
            else WBind(u, s, c->name, c, "Generic Error"); c->owner = d;
        }
    if (WEq(d->tag, "instance")) {
        d->resolved = WLookup(outer, d->name);
        if (!d->resolved || !WEq(d->resolved->tag, "typeclass")) WFail(u, d->token, "Declaration Error", "Instance target is not a typeclass");
    }
    for (c = d->first; c && !u->error_kind; c = c->next) {
        if (WEq(c->role, "type") || WEq(c->role, "result") || WEq(c->role, "argument")) WResolveType(u, c, s);
        else if (WEq(c->role, "slot")) WResolveType(u, WChild(c, "type"), s);
        else if (WEq(c->role, "constructor")) {
            for (p = c->first; p; p = p->next) if (WEq(p->role, "slot")) WResolveType(u, WChild(p, "type"), s);
        } else if (WEq(c->role, "method")) {c->owner = d; WResolveDecl(u, c, s);}
        else if (WEq(c->role, "body") || WEq(c->role, "value")) WResolveTree(u, c, s);
        else if (WEq(c->role, "type-parameter")) {
            for (b = c->first; b; b = b->next) if (WEq(b->role, "constraint")) {
                    b->resolved = WLookup(s, b->name);
                    if (!b->resolved || !WEq(b->resolved->tag, "typeclass")) WFail(u, b->token, "Declaration Error", "Constraint is not a typeclass");
                }
        }
    }
}
U0 WResolve(CWUnit *u)
{
    CWNode *m, *d;
    WIndex(u);
    for (m = u->modules; m && !u->error_kind; m = m->next)
        for (d = m->first; d && !u->error_kind; d = d->next)
            if (WEq(d->role, "declaration")) WResolveDecl(u, d, m->scope);
}
