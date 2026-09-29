// Type checking and typeclass contracts; AST declarations remain the identities.
CWNode *WDeclType(CWNode *d)
{
    CWNode *t;
    if (!d) return NULL;
    if (d->ty) return d->ty;
    t = WChild(d, "type");
    if (!t && d->owner && WEq(d->tag, "binding")) t = WChild(d->owner, "type");
    return t;
}
CWNode *WCopyType(CWUnit *u, CWNode *t)
{
    CWNode *n = WNode(u, "type", t->token); n->name = t->name; n->resolved = t->resolved; n->first = t->first; n->last = t->last; return n;
}
CWNode *WRefType(CWUnit *u, U8 *name, CWNode *value, CWNode *region)
{
    CWNode *n = WNode(u, "type", value->token); n->name = name;
    WAdd(n, WCopyType(u, value), "argument"); WAdd(n, WCopyType(u, region), "argument"); return n;
}
CWNode *WDeclModule(CWNode *d)
{
    while (d && !WEq(d->tag, "module") && !WEq(d->tag, "interface")) d = d->owner;
    return d;
}
Bool WVisibleInstance(CWNode *from, CWNode *inst)
{
    CWNode *im = WDeclModule(inst), *c;
    from = WDeclModule(from);
    if (!im || !from) return FALSE;
    if (WEq(im->name, from->name) || WEq(im->name, "Austral.Pervasive")) return TRUE;
    if (WEq(im->tag, "module") && im->pair && !inst->pair) return FALSE;
    for (c = from->first; c; c = c->next) if (WEq(c->tag, "import") && WEq(c->name, im->name)) return TRUE;
    return FALSE;
}
CWNode *WFindInstance(CWUnit *u, CWNode *from, CWNode *tc, CWNode *ty)
{
    CWNode *m, *d, *env, *c;
    if (WTypeVar(ty)) {
        for (c = ty->resolved->first; c; c = c->next) if (WEq(c->role, "constraint") && c->resolved == tc) return ty->resolved;
        return NULL;
    }
    for (m = u->modules; m; m = m->next) for (d = m->first; d; d = d->next)
            if (WEq(d->tag, "instance") && d->resolved == tc && WVisibleInstance(from, d)) {
                env = WScope(u, NULL); if (WMatch(u, WChild(d, "argument"), ty, env)) return d;
            }
    return NULL;
}
U0 WConstraints(CWUnit *u, CWNode *from, CWNode *decl, CWNode *bindings, CWToken *at)
{
    CWNode *p, *c, *ty;
    for (p = decl->first; p && !u->error_kind; p = p->next) if (WEq(p->role, "type-parameter")) {
            ty = WBinding(bindings, p);
            if (ty) for (c = p->first; c; c = c->next) if (WEq(c->role, "constraint")) {
                        if (!WFindInstance(u, from, c->resolved, ty)) WFail(u, at, "Type Error", "Typeclass constraint is not satisfied");
                    }
        }
}
CWNode *WNominal(CWUnit *u, CWNode *d)
{
    CWNode *t = WNode(u, "type", d->token), *p, *v;
    t->name = d->name; t->resolved = d;
    for (p = d->first; p; p = p->next) if (WEq(p->role, "type-parameter")) {
            v = WNode(u, "type", p->token); v->name = p->name; v->resolved = p; WAdd(t, v, "argument");
        }
    return t;
}
extern CWNode *WInfer(CWUnit *u, CWNode *n, CWNode *expected, CWNode *fun);
Bool WHasVar(CWNode *t)
{
    CWNode *c;
    if (!t) return FALSE;
    if (WTypeVar(t)) return TRUE;
    for (c = t->first; c; c = c->next) if (WHasVar(c)) return TRUE;
    return FALSE;
}
CWNode *WCall(CWUnit *u, CWNode *n, CWNode *expected, CWNode *fun)
{
    CWNode *d = n->resolved, *result, *params, *p, *arg, *value, *ty, *formal, *bindings = WScope(u, NULL), *inst, *tc, *bound, *tp;
    U8 *role = "parameter";
    I64 argc = 0, paramc = 0;
    if (!d || u->error_kind) return NULL;
    if (WEq(d->tag, "record")) {result = WNominal(u, d); role = "slot";}
    else if (WEq(d->tag, "constructor")) {result = WNominal(u, d->owner); role = "slot";}
    else if (WEq(d->tag, "function") || WEq(d->tag, "method")) result = WChild(d, "result");
    else {
        ty = WDeclType(d);
        if (!ty || !WEq(ty->name, "Fn")) {WFail(u, n->token, "Type Error", "Value is not callable"); return NULL;}
        // Synthesize a signature for a function pointer value.
        params = WNode(u, "function", n->token); params->name = n->name; params->owner = d->owner;
        for (p = ty->first; p; p = p->next) {
            if (p->next) {arg = WNode(u, "parameter", n->token); WAdd(arg, WCopyType(u, p), "type"); WAdd(params, arg, "parameter");}
            else WAdd(params, WCopyType(u, p), "result");
        }
        d = params; result = WChild(d, "result");
    }
    if (expected && !WMatch(u, result, expected, bindings)) WFail(u, n->token, "Type Error", "Call result has incompatible type");
    for (arg = n->first; arg; arg = arg->next) if (WEq(arg->role, "argument")) argc++;
    for (p = d->first; p; p = p->next) if (WEq(p->role, role)) paramc++;
    if (argc != paramc) {WFail(u, n->token, "Generic Error", "Wrong number of arguments"); return result;}
    arg = WChild(n, "argument");
    for (p = d->first; p && !u->error_kind; p = p->next) if (WEq(p->role, role)) {
            if (arg && *arg->name) {
                for (arg = n->first; arg; arg = arg->next) if (WEq(arg->role, "argument") && WEq(arg->name, p->name)) break;
                if (!arg) {WFail(u, n->token, "Generic Error", "Named argument missing"); break;}
            }
            if (!arg) break;
            formal = WChild(p, "type"); ty = WSubst(u, formal, bindings);
            value = WChild(arg, "value");
            // Literals are checked against concrete parameters; polymorphic literals default.
            if (WHasVar(ty)) ty = NULL;
            value->ty = WInfer(u, value, ty, fun);
            if (!WMatch(u, formal, value->ty, bindings)) WFail(u, value->token, "Type Error", "Argument type mismatch");
            arg->resolved = p;
            if (!*arg->name) {arg = arg->next; while (arg && !WEq(arg->role, "argument")) arg = arg->next;}
        }
    WConstraints(u, fun, d, bindings, n->token);
    n->pair = bindings;
    if (WEq(d->tag, "method") && d->owner && WEq(d->owner->tag, "typeclass")) {
        tc = d->owner; tp = WChild(tc, "type-parameter"); bound = WBinding(bindings, tp);
        if (!bound) WFail(u, n->token, "Type Error", "Cannot infer typeclass argument");
        else {
            inst = WFindInstance(u, fun, tc, bound);
            if (!inst) WFail(u, n->token, "Type Error", "No visible matching typeclass instance");
            else n->owner = inst;
        }
    }
    return WSubst(u, result, bindings);
}
CWNode *WPathType(CWUnit *u, CWNode *n, CWNode *ty, CWNode *fun)
{
    CWNode *part, *d, *slot, *env, *region, *inner;
    Bool refpath = WEq(n->tag, "ref-path");
    U8 *mode;
    for (part = n->first; part && !u->error_kind; part = part->next) if (WEq(part->role, "path")) {
            region = NULL; mode = "&";
            if (WEq(part->tag, "index")) {
                WInfer(u, WChild(part, "value"), WTypeNamed(u, fun->scope, "Index"), fun);
                inner = ty;
                if (refpath && inner && (WEq(inner->name, "&") || WEq(inner->name, "&!"))) inner = inner->first;
                if (!inner || (!WEq(inner->name, "Span") && !WEq(inner->name, "Span!"))) {WFail(u, n->token, "Type Error", "Index requires a span"); break;}
                region = inner->first->next; if (WEq(inner->name, "Span!")) mode = "&!";
                ty = inner->first;
            } else {
                if (WEq(part->tag, "->")) {
                    if (!ty || (!WEq(ty->name, "&") && !WEq(ty->name, "&!"))) {WFail(u, n->token, "Generic Error", "Arrow requires a reference"); break;}
                    region = ty->first->next; mode = ty->name; ty = ty->first;
                } else if (refpath) {WFail(u, n->token, "Type Error", "Reference transform field requires an arrow"); break;}
                d = NULL; if (ty) d = WCanon(ty->resolved);
                if (!d || !WEq(d->tag, "record")) {WFail(u, n->token, "Type Error", "Field access requires a record"); break;}
                for (slot = d->first; slot; slot = slot->next) if (WEq(slot->role, "slot") && WEq(slot->name, part->name)) break;
                if (!slot) {WFail(u, part->token, "Generic Error", "Unknown record field"); break;}
                env = WTypeParameters(u, ty); ty = WSubst(u, WChild(slot, "type"), env); part->resolved = slot;
            }
            if (refpath && region) ty = WRefType(u, mode, ty, region);
            part->ty = ty;
        }
    return ty;
}
CWNode *WInfer(CWUnit *u, CWNode *n, CWNode *expected, CWNode *fun)
{
    CWNode *ty = NULL, *v, *a, *b, *left, *right, *scope = fun->scope, *d, *p;
    U8 *tag = n->tag, *name = n->name;
    Bool cmp;
    if (u->error_kind) return NULL;
    if (WEq(tag, "literal")) {
        if (WEq(name, "nil")) ty = WTypeNamed(u, scope, "Unit");
        else if (WEq(name, "true") || WEq(name, "false")) ty = WTypeNamed(u, scope, "Bool");
        else if (n->token->kind == 3) {
            ty = expected; if (!ty) ty = WTypeNamed(u, scope, "Int32"); WIntLiteral(u, n, ty);
        } else if (n->token->kind == 4) {
            ty = expected; if (!ty) ty = WTypeNamed(u, scope, "Float64");
            if (!WEq(ty->name, "Float32") && !WEq(ty->name, "Float64")) WFail(u, n->token, "Type Error", "Floating literal requires floating type");
        } else ty = WRefType(u, "Span", WTypeNamed(u, scope, "Nat8"), WTypeNamed(u, scope, "Static"));
    } else if (WEq(tag, "call")) ty = WCall(u, n, expected, fun);
    else if (WEq(tag, "variable") || WEq(tag, "path") || WEq(tag, "ref-path")) {
        d = n->resolved; ty = WDeclType(d);
        if (d && WEq(d->tag, "function")) {
            ty = WTypeNamed(u, scope, "Fn");
            if (WChild(d, "type-parameter") && !expected) WFail(u, n->token, "Type Error", "Generic function value requires an asserted type");
            for (p = d->first; p; p = p->next) if (WEq(p->role, "parameter")) WAdd(ty, WCopyType(u, WChild(p, "type")), "argument");
            WAdd(ty, WCopyType(u, WChild(d, "result")), "argument");
            if (expected) {a = WScope(u, NULL); if (WMatch(u, ty, expected, a)) {ty = WSubst(u, ty, a); n->pair = a;}}
        }
        if (!ty) WFail(u, n->token, "Type Error", "Name is not a value");
        if (!WEq(tag, "variable")) ty = WPathType(u, n, ty, fun);
    } else if (WEq(tag, "binary")) {
        cmp = WEq(name, "=") || WEq(name, "/=") || WEq(name, "<") || WEq(name, "<=") || WEq(name, ">") || WEq(name, ">=");
        left = WChild(n, "left"); right = WChild(n, "right"); a = expected;
        if (cmp) a = NULL;
        if (WEq(name, "and") || WEq(name, "or")) a = WTypeNamed(u, scope, "Bool");
        if (!a && WEq(left->tag, "literal") && !WEq(right->tag, "literal")) {b = WInfer(u, right, NULL, fun); a = WInfer(u, left, b, fun);}
        else {a = WInfer(u, left, a, fun); b = WInfer(u, right, a, fun);}
        WRequire(u, n, b, a); ty = a;
        if (!cmp && !WEq(name, "and") && !WEq(name, "or") && !WNumber(a)) WFail(u, n->token, "Type Error", "Arithmetic requires numeric operands");
        if (cmp) ty = WTypeNamed(u, scope, "Bool");
    } else if (WEq(tag, "unary")) {
        a = expected; if (WEq(name, "not")) a = WTypeNamed(u, scope, "Bool");
        ty = WInfer(u, WChild(n, "value"), a, fun);
        if (WEq(name, "-") && !WNumber(ty)) WFail(u, n->token, "Type Error", "Negation requires a number");
    } else if (WEq(tag, "cast")) {
        ty = WChild(n, "type"); WValidateType(u, ty); a = WInfer(u, WChild(n, "value"), ty, fun);
        // Literal/asserted-type casts are checked by the operand; explicit numeric
        // conversions are builtin functions in Warm.
        WRequire(u, n, a, ty);
    } else if (WEq(tag, "sizeof")) {WValidateType(u, WChild(n, "type")); ty = WTypeNamed(u, scope, "ByteSize");}
    else if (WEq(tag, "embed")) {
        ty = WChild(n, "type"); for (v = n->first; v; v = v->next) if (WEq(v->role, "argument")) WInfer(u, v, NULL, fun);
    } else if (WEq(tag, "if-expression")) {
        WInfer(u, WChild(n, "condition"), WTypeNamed(u, scope, "Bool"), fun);
        ty = WInfer(u, WChild(n, "then"), expected, fun); WInfer(u, WChild(n, "else"), ty, fun);
    } else if (WEq(tag, "borrow-expression")) {
        v = WChild(n, "value"); a = WInfer(u, v, NULL, fun); d = v->resolved;
        if (WEq(name, "&!") && d && !(d->flags & 1)) WFail(u, n->token, "Type Error", "Cannot mutably borrow an immutable binding");
        b = WTypeNamed(u, scope, "Static");
        if (WEq(name, "&~")) {
            if (!a || !WEq(a->name, "&!")) WFail(u, n->token, "Type Error", "Reborrow requires a mutable reference");
            else ty = WRefType(u, "&!", a->first, b);
        } else if (a) ty = WRefType(u, name, a, b);
    } else if (WEq(tag, "dereference")) {
        a = WInfer(u, WChild(n, "value"), NULL, fun);
        if (!a || (!WEq(a->name, "&") && !WEq(a->name, "&!"))) WFail(u, n->token, "Type Error", "Dereference requires a reference");
        else {
            ty = a->first;
            if (WUniverseOf(ty) != 0) WFail(u, n->token, "Linearity Error", "Cannot copy a linear value out of a reference");
        }
    } else WFail(u, n->token, "Unsupported Feature", "Expression typing not implemented");
    n->ty = ty; WRequire(u, n, ty, expected); return ty;
}
extern U0 WCheckBlock(CWUnit *u, CWNode *block, CWNode *fun);
U0 WCheckStmt(CWUnit *u, CWNode *n, CWNode *fun)
{
    CWNode *ty, *a, *b, *v, *d, *c, *slot, *env, *other, *cons, *case_ref = NULL;
    U8 *tag = n->tag;
    if (u->error_kind) return;
    if (WEq(tag, "block")) WCheckBlock(u, n, fun);
    else if (WEq(tag, "let")) {
        ty = WChild(n, "type"); WValidateType(u, ty); WInfer(u, WChild(n, "value"), ty, fun); WChild(n, "binding")->ty = ty;
    } else if (WEq(tag, "destructure")) {
        ty = WInfer(u, WChild(n, "value"), NULL, fun); d = NULL; if (ty) d = WCanon(ty->resolved);
        if (!d || !WEq(d->tag, "record")) {WFail(u, n->token, "Type Error", "Destructure requires a record"); return;}
        env = WTypeParameters(u, ty);
        for (b = n->first; b && !u->error_kind; b = b->next) if (WEq(b->role, "binding")) {
                for (slot = d->first; slot; slot = slot->next) if (WEq(slot->role, "slot") && WEq(slot->name, b->name)) break;
                if (!slot) WFail(u, b->token, "Generic Error", "Unknown destructured field");
                else {a = WSubst(u, WChild(slot, "type"), env); b->ty = WChild(b, "type"); WRequire(u, b, a, b->ty); b->resolved = slot;}
            }
    } else if (WEq(tag, "assign")) {
        v = WChild(n, "target"); ty = WInfer(u, v, NULL, fun); d = v->resolved;
        if (d && WEq(d->tag, "constant")) WFail(u, n->token, "Generic Error", "Cannot assign to a constant");
        else if (d && !(d->flags & 1)) WFail(u, n->token, "Generic Error", "Cannot assign to an immutable binding");
        WInfer(u, WChild(n, "value"), ty, fun);
    } else if (WEq(tag, "return")) WInfer(u, WChild(n, "value"), WChild(fun, "result"), fun);
    else if (WEq(tag, "discard")) WInfer(u, WChild(n, "value"), NULL, fun);
    else if (WEq(tag, "if") || WEq(tag, "while")) {
        WInfer(u, WChild(n, "condition"), WTypeNamed(u, fun->scope, "Bool"), fun);
        if (WEq(tag, "if")) {WCheckStmt(u, WChild(n, "then"), fun); c = WChild(n, "else"); if (c) WCheckStmt(u, c, fun);}
        else WCheckBlock(u, WChild(n, "body"), fun);
    } else if (WEq(tag, "for")) {
        ty = WTypeNamed(u, fun->scope, "Index"); n->resolved->ty = ty;
        WInfer(u, WChild(n, "from"), ty, fun); WInfer(u, WChild(n, "to"), ty, fun); WCheckBlock(u, WChild(n, "body"), fun);
    } else if (WEq(tag, "borrow")) {
        v = WChild(n, "original"); ty = WInfer(u, v, NULL, fun); d = v->resolved; a = WChild(n, "type"); b = WChild(n, "mode");
        if (WEq(b->name, "&!") && d && !(d->flags & 1)) WFail(u, n->token, "Type Error", "Cannot mutably borrow an immutable binding");
        if (WEq(b->name, "&~")) {
            if (!ty || !WEq(ty->name, "&!")) WFail(u, n->token, "Type Error", "Reborrow requires a mutable reference");
            else ty = ty->first;
        }
        if (ty) {a->first->name = ty->name; a->first->resolved = ty->resolved; a->first->first = ty->first; a->first->last = ty->last;}
        n->resolved->ty = a; WCheckBlock(u, WChild(n, "body"), fun);
    } else if (WEq(tag, "case")) {
        ty = WInfer(u, WChild(n, "value"), NULL, fun);
        if (ty && (WEq(ty->name, "&") || WEq(ty->name, "&!"))) {case_ref = ty; ty = ty->first;}
        d = NULL; if (ty) d = WCanon(ty->resolved);
        if (!d || !WEq(d->tag, "union")) {WFail(u, n->token, "Type Error", "Case requires a union"); return;}
        env = WTypeParameters(u, ty);
        for (c = n->first; c && !u->error_kind; c = c->next) if (WEq(c->role, "when")) {
                for (cons = d->first; cons; cons = cons->next) if (WEq(cons->role, "constructor") && WEq(cons->name, c->name)) break;
                if (!cons) {WFail(u, c->token, "Type Error", "Unknown union constructor"); break;}
                c->resolved = cons;
                for (other = n->first; other != c; other = other->next) if (WEq(other->role, "when") && WEq(other->name, c->name)) WFail(u, c->token, "Type Error", "Duplicate case arm");
                for (b = c->first; b; b = b->next) if (WEq(b->role, "binding")) {
                        for (slot = cons->first; slot; slot = slot->next) if (WEq(slot->role, "slot") && WEq(slot->name, b->name)) break;
                        if (!slot) WFail(u, b->token, "Type Error", "Unknown case payload field");
                        else {b->ty = WChild(b, "type"); a = WSubst(u, WChild(slot, "type"), env); if (case_ref) a = WRefType(u, case_ref->name, a, case_ref->first->next); WRequire(u, b, a, b->ty); b->resolved = slot;}
                    }
                WCheckBlock(u, WChild(c, "body"), fun);
            }
        for (cons = d->first; cons; cons = cons->next) if (WEq(cons->role, "constructor")) {
                for (c = n->first; c; c = c->next) if (WEq(c->role, "when") && WEq(c->name, cons->name)) break;
                if (!c) WFail(u, n->token, "Type Error", "Non-exhaustive case statement");
            }
    } else if (!WEq(tag, "skip")) WFail(u, n->token, "Unsupported Feature", "Statement typing not implemented");
}
U0 WCheckBlock(CWUnit *u, CWNode *block, CWNode *fun)
{
    CWNode *s;
    for (s = block->first; s && !u->error_kind; s = s->next) WCheckStmt(u, s, fun);
}
I64 WVarOccurrences(CWNode *t, CWNode *var)
{
    CWNode *c; I64 count = 0;
    if (t->resolved == var) count++;
    for (c = t->first; c; c = c->next) count += WVarOccurrences(c, var);
    return count;
}
Bool WReturn(CWNode *n)
{
    CWNode *c;
    if (!n) return FALSE;
    if (WEq(n->tag, "return")) return TRUE;
    if (WEq(n->tag, "block")) return WReturn(n->last);
    if (WEq(n->tag, "if")) return WReturn(WChild(n, "then")) && WReturn(WChild(n, "else"));
    if (WEq(n->tag, "while") || WEq(n->tag, "for") || WEq(n->tag, "borrow")) return WReturn(WChild(n, "body"));
    if (WEq(n->tag, "case")) {
        for (c = n->first; c; c = c->next) if (WEq(c->role, "when") && !WReturn(WChild(c, "body"))) return FALSE;
        return TRUE;
    }
    if (WEq(n->tag, "discard")) {
        c = WChild(n, "value");
        if (c && WEq(c->tag, "call") && c->resolved && WEq(c->resolved->name, "abort")) {
            c = WDeclModule(c->resolved); return c && WEq(c->name, "Austral.Pervasive");
        }
    }
    return FALSE;
}
U0 WSignature(CWUnit *u, CWNode *decl, CWNode *def, CWNode *env)
{
    CWNode *p, *q, *v, *b, *x, *y;
    q = WChild(def, "type-parameter");
    for (p = decl->first; p; p = p->next) if (WEq(p->role, "type-parameter")) {
            if (!q) {WFail(u, def->token, "Declaration Error", "Type parameter count differs from declaration"); return;}
            if (!WSameSyntax(WChild(p, "universe"), WChild(q, "universe"))) WFail(u, q->token, "Declaration Error", "Type parameter universe differs from declaration");
            v = WNode(u, "type", q->token); v->name = q->name; v->resolved = q;
            b = WNode(u, "substitution", p->token); b->resolved = p; b->ty = v; WAdd(env, b, "binding");
            q = q->next; while (q && !WEq(q->role, "type-parameter")) q = q->next;
        }
    if (q) WFail(u, def->token, "Declaration Error", "Extra method type parameters");
    q = WChild(def, "parameter");
    for (p = decl->first; p; p = p->next) if (WEq(p->role, "parameter")) {
            if (!q) {WFail(u, def->token, "Declaration Error", "Parameter count differs from declaration"); return;}
            x = WSubst(u, WChild(p, "type"), env); y = WChild(q, "type");
            if (!WEq(p->name, q->name) || !WTypeEq(x, y)) WFail(u, q->token, "Declaration Error", "Parameter signature differs from declaration");
            q = q->next; while (q && !WEq(q->role, "parameter")) q = q->next;
        }
    if (q) WFail(u, def->token, "Declaration Error", "Extra parameters");
    x = WSubst(u, WChild(decl, "result"), env); y = WChild(def, "result");
    if (!WTypeEq(x, y)) WFail(u, def->token, "Declaration Error", "Return type differs from declaration");
}
Bool WOverlap(CWNode *a, CWNode *b)
{
    CWNode *x, *y;
    if (WTypeVar(a) || WTypeVar(b)) return TRUE;
    if (WCanon(a->resolved) != WCanon(b->resolved) || !WEq(a->name, b->name)) return FALSE;
    x = a->first; y = b->first;
    while (x && y) {if (!WOverlap(x, y)) return FALSE; x = x->next; y = y->next;}
    return !x && !y;
}
U0 WInstanceContract(CWUnit *u, CWNode *d)
{
    CWNode *tc = d->resolved, *tp, *arg = WChild(d, "argument"), *p, *q, *v, *b, *env, *m, *other, *home, *foreign;
    I64 count;
    if (!tc || u->error_kind) return;
    tp = WChild(tc, "type-parameter"); v = WNode(u, "type", tp->token); v->name = tp->name; v->resolved = tp;
    env = WScope(u, NULL);
    if (!WMatch(u, v, arg, env)) WFail(u, d->token, "Type Error", "Instance argument has the wrong universe");
    home = WDeclModule(d); foreign = WDeclModule(tc); m = WDeclModule(WCanon(arg->resolved));
    if (foreign && !WEq(home->name, foreign->name) && (!m || !WEq(home->name, m->name))) WFail(u, d->token, "Generic Error", "Orphan instance: type and typeclass are both foreign");
    for (p = d->first; p; p = p->next) if (WEq(p->role, "type-parameter")) {
            count = WVarOccurrences(arg, p);
            if (count != 1) WFail(u, d->token, "Declaration Error", "Instance must use each type parameter exactly once");
        }
    // Interface declarations describe instances; contracts apply to definitions.
    if (!WEq(home->tag, "module")) return;
    for (p = d->first; p; p = p->next) if (WEq(p->role, "method")) {
            for (q = d->first; q != p; q = q->next) if (WEq(q->role, "method") && WEq(q->name, p->name)) WFail(u, p->token, "Declaration Error", "Duplicate instance method");
            for (q = tc->first; q; q = q->next) if (WEq(q->role, "method") && WEq(q->name, p->name)) break;
            if (!q) WFail(u, p->token, "Declaration Error", "Extra instance method");
        }
    for (p = tc->first; p && !u->error_kind; p = p->next) if (WEq(p->role, "method")) {
            for (q = d->first; q; q = q->next) if (WEq(q->role, "method") && WEq(q->name, p->name)) break;
            if (!q) WFail(u, d->token, "Declaration Error", "Required instance method is missing");
            else {
                env = WScope(u, NULL); b = WNode(u, "substitution", tp->token); b->resolved = tp; b->ty = arg; WAdd(env, b, "binding");
                WSignature(u, p, q, env);
            }
        }
    // Check overlap against preceding definitions, ignoring matching interfaces.
    for (m = u->modules; m; m = m->next) {
        if (WEq(m->tag, "module")) for (other = m->first; other; other = other->next) {
                if (other == d) return;
                if (WEq(other->tag, "instance") && other->resolved == tc) {
                    env = WScope(u, NULL);
                    if (WOverlap(WChild(other, "argument"), arg)) WFail(u, d->token, "Generic Error", "Overlapping instances");
                }
            }
    }
}
U0 WDeclarationTypes(CWUnit *u, CWNode *n)
{
    CWNode *c, *univ, *ty, *p;
    if (u->error_kind) return;
    if (WEq(n->tag, "type") && !WEq(n->role, "declaration")) {WValidateType(u, n); return;}
    univ = WChild(n, "universe");
    if (WEq(n->tag, "record") || WEq(n->tag, "union")) {
        if (univ && WEq(univ->name, "Region")) WFail(u, n->token, "Declaration Error", "Records and unions cannot inhabit Region");
        if (univ && WEq(univ->name, "Free")) {
            for (p = n->first; p; p = p->next) if (WEq(p->role, "type-parameter")) {
                    ty = WNode(u, "type", p->token); ty->resolved = p;
                    if (WUniverseOf(ty) == 1 || WUniverseOf(ty) == 2) WFail(u, n->token, "Linearity Error", "Free aggregate has a potentially linear type parameter");
                }
            for (p = n->first; p; p = p->next) {
                if (WEq(p->role, "slot") && WUniverseOf(WChild(p, "type")) != 0) WFail(u, p->token, "Linearity Error", "Free aggregate contains a linear field");
                if (WEq(p->role, "constructor")) for (c = p->first; c; c = c->next)
                        if (WEq(c->role, "slot") && WUniverseOf(WChild(c, "type")) != 0) WFail(u, c->token, "Linearity Error", "Free union contains a linear field");
            }
        }
    }
    if (WEq(n->tag, "typeclass")) {
        p = WChild(n, "type-parameter"); univ = WChild(p, "universe");
        if (WEq(univ->name, "Region")) WFail(u, n->token, "Declaration Error", "Typeclass parameter cannot inhabit Region");
    }
    if (WEq(n->tag, "function")) {
        for (p = n->first; p; p = p->next) if (WEq(p->role, "type-parameter")) {
                I64 used = 0;
                for (c = n->first; c; c = c->next) {
                    if (WEq(c->role, "parameter")) used += WVarOccurrences(WChild(c, "type"), p);
                    if (WEq(c->role, "result")) used += WVarOccurrences(c, p);
                }
                if (!used) WFail(u, p->token, "Declaration Error", "Unused type parameter in function signature");
            }
    }
    if (WEq(n->tag, "instance")) WInstanceContract(u, n);
    if (WEq(n->tag, "function") && n->pair && WChild(n, "body")) WSignature(u, n->pair, n, WScope(u, NULL));
    for (c = n->first; c && !u->error_kind; c = c->next) if (!WEq(c->role, "body") && !WEq(c->role, "value") && !WEq(c->role, "doc")) WDeclarationTypes(u, c);
}
U0 WTypeCheck(CWUnit *u)
{
    CWNode *m, *d, *f, *body;
    for (m = u->modules; m && !u->error_kind; m = m->next)
        for (d = m->first; d && !u->error_kind; d = d->next) if (WEq(d->role, "declaration")) WDeclarationTypes(u, d);
    for (m = u->modules; m && !u->error_kind; m = m->next) {
        for (d = m->first; d && !u->error_kind; d = d->next) if (WEq(d->role, "declaration")) {
                if (WEq(d->tag, "constant") && WChild(d, "value")) WInfer(u, WChild(d, "value"), WChild(d, "type"), d);
                if (WEq(d->tag, "instance")) f = WChild(d, "method"); else f = d;
                while (f && !u->error_kind) {
                    body = WChild(f, "body");
                    if (body) {
                        if (!WReturn(body) && !WChild(f, "pragma")) WFail(u, f->token, "Declaration Error", "Function or method does not end in return");
                        WCheckBlock(u, body, f);
                    }
                    if (!WEq(d->tag, "instance")) break;
                    f = f->next; while (f && !WEq(f->role, "method")) f = f->next;
                }
            }
    }
}
