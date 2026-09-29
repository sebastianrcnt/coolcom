// Recursive descent over the reference Parser.mly grammar.
Bool WAt(CWUnit *u, U8 *s) {return WEq(u->cursor->text, s);}
CWToken *WTake(CWUnit *u)
{
    CWToken *t = u->cursor;
    if (t->next) u->cursor = t->next;
    return t;
}
Bool WAccept(CWUnit *u, U8 *s)
{
    if (WAt(u, s)) {WTake(u); return TRUE;}
    return FALSE;
}
CWToken *WExpect(CWUnit *u, U8 *s)
{
    CWToken *t = u->cursor;
    if (!WAccept(u, s)) WFail(u, t, "Parse Error", WConcat(u, "Expected token: ", s));
    return t;
}
CWToken *WIdent(CWUnit *u)
{
    CWToken *t = u->cursor;
    if (t->kind != 2) WFail(u, t, "Parse Error", "Expected identifier");
    else WTake(u);
    return t;
}
CWNode *WNamed(CWUnit *u, U8 *tag)
{
    CWToken *t = WIdent(u);
    CWNode *n = WNode(u, tag, t); n->name = t->text; return n;
}
Bool WEnter(CWUnit *u)
{
    if (u->error_kind) return FALSE;
    if (u->depth >= 256) {WFail(u, u->cursor, "Parse Error", "Syntax nesting exceeds 256"); return FALSE;}
    u->depth++; return TRUE;
}
extern CWNode *WType(CWUnit *u);
extern CWNode *WExpr(CWUnit *u);
extern CWNode *WAtom(CWUnit *u);
extern CWNode *WBlock(CWUnit *u, Bool empty);
extern CWNode *WStatement(CWUnit *u);
CWNode *WType(CWUnit *u)
{
    CWNode *n = WNode(u, "type", u->cursor);
    Bool ref = FALSE;
    if (!WEnter(u)) return n;
    if (WAt(u, "&") || WAt(u, "&!") || WAt(u, "Span") || WAt(u, "Span!")) {
        n->name = WTake(u)->text; ref = TRUE;
    } else n->name = WIdent(u)->text;
    if (ref || WAt(u, "[")) {
        WExpect(u, "[");
        if (ref) {
            WAdd(n, WType(u), "argument"); WExpect(u, ","); WAdd(n, WType(u), "argument");
        } else if (!WAt(u, "]")) {
            WAdd(n, WType(u), "argument");
            while (!u->error_kind && WAccept(u, ",")) WAdd(n, WType(u), "argument");
        }
        WExpect(u, "]");
    }
    u->depth--; n->finish = u->cursor; return n;
}
CWNode *WUniverse(CWUnit *u)
{
    CWNode *n = WNode(u, "universe", u->cursor);
    if (WAt(u, "Free") || WAt(u, "Linear") || WAt(u, "Type") || WAt(u, "Region")) n->name = WTake(u)->text;
    else WFail(u, u->cursor, "Parse Error", "Expected universe");
    return n;
}
CWNode *WTypeParam(CWUnit *u)
{
    CWNode *n = WNamed(u, "type-parameter");
    WExpect(u, ":"); WAdd(n, WUniverse(u), "universe");
    if (WAccept(u, "(")) {
        if (!WAt(u, ")")) {
            WAdd(n, WNamed(u, "constraint"), "constraint");
            while (!u->error_kind && WAccept(u, ",")) WAdd(n, WNamed(u, "constraint"), "constraint");
        }
        WExpect(u, ")");
    }
    return n;
}
U0 WTypeParams(CWUnit *u, CWNode *n)
{
    if (WAccept(u, "[")) {
        if (!WAt(u, "]")) {
            WAdd(n, WTypeParam(u), "type-parameter");
            while (!u->error_kind && WAccept(u, ",")) WAdd(n, WTypeParam(u), "type-parameter");
        }
        WExpect(u, "]");
    }
}
U0 WParams(CWUnit *u, CWNode *n)
{
    CWNode *p;
    WExpect(u, "(");
    if (!WAt(u, ")")) {
        do {
            p = WNamed(u, "parameter"); WExpect(u, ":"); WAdd(p, WType(u), "type"); WAdd(n, p, "parameter");
        } while (!u->error_kind && WAccept(u, ","));
    }
    WExpect(u, ")");
}
U0 WArgs(CWUnit *u, CWNode *n)
{
    CWNode *a;
    Bool named = FALSE;
    WExpect(u, "(");
    if (!WAt(u, ")")) {
        if (u->cursor->kind == 2 && u->cursor->next && WEq(u->cursor->next->text, "=>")) named = TRUE;
        do {
            a = WNode(u, "argument", u->cursor);
            if (named) {a->name = WIdent(u)->text; WExpect(u, "=>");}
            WAdd(a, WExpr(u), "value"); WAdd(n, a, "argument");
        } while (!u->error_kind && WAccept(u, ","));
    }
    WExpect(u, ")");
}
Bool WPathRest(CWUnit *u, CWNode *n)
{
    CWNode *p;
    if (WAt(u, ".") || WAt(u, "->")) {
        p = WNode(u, WTake(u)->text, u->cursor); p->name = WIdent(u)->text; WAdd(n, p, "path");
        return TRUE;
    }
    if (WAccept(u, "[")) {
        p = WNode(u, "index", u->cursor); WAdd(p, WExpr(u), "value"); WExpect(u, "]"); WAdd(n, p, "path");
        return TRUE;
    }
    return FALSE;
}
CWNode *WAtom(CWUnit *u)
{
    CWToken *t = u->cursor;
    CWNode *n = WNode(u, "literal", t);
    I64 k = t->kind;
    if (!WEnter(u)) return n;
    n->name = t->text;
    if (k == 6) n->name = WTriple(u, n->name);
    if (k == 3 || k == 4 || k == 5 || k == 6 || WAt(u, "nil") || WAt(u, "true") || WAt(u, "false")) {
        WTake(u);
    } else if (WAccept(u, "(")) {
        n = WExpr(u); WExpect(u, ")");
    } else if (WAccept(u, "sizeof")) {
        n->tag = "sizeof"; WExpect(u, "("); WAdd(n, WType(u), "type"); WExpect(u, ")");
    } else if (WAccept(u, "@embed")) {
        n->tag = "embed"; WExpect(u, "("); WAdd(n, WType(u), "type"); WExpect(u, ",");
        if (u->cursor->kind != 5) WFail(u, u->cursor, "Parse Error", "Expected embed string");
        n->name = WTake(u)->text;
        if (WAccept(u, ",")) {
            if (!WAt(u, ")")) {
                WAdd(n, WExpr(u), "argument");
                while (!u->error_kind && WAccept(u, ",")) WAdd(n, WExpr(u), "argument");
            }
        }
        WExpect(u, ")");
    } else if (WAt(u, "&") || WAt(u, "&!") || WAt(u, "&~")) {
        n->tag = "borrow-expression"; n->name = WTake(u)->text; WAdd(n, WNamed(u, "variable"), "value");
    } else if (WAccept(u, "!")) {
        n->tag = "dereference"; WAdd(n, WAtom(u), "value");
    } else if (WAccept(u, "&(")) {
        n->tag = "ref-path"; n->name = WIdent(u)->text;
        if (!WPathRest(u, n)) WFail(u, u->cursor, "Parse Error", "Expected reference path");
        while (!u->error_kind && WPathRest(u, n)) {}
        WExpect(u, ")");
    } else if (k == 2) {
        WTake(u); n->tag = "variable";
        if (WAt(u, "(")) {n->tag = "call"; WArgs(u, n);}
        else while (!u->error_kind && WPathRest(u, n)) n->tag = "path";
    } else WFail(u, t, "Parse Error", "Expected expression");
    u->depth--; n->finish = u->cursor; return n;
}
Bool WBinary(CWUnit *u)
{
    return WAt(u, "+") || WAt(u, "-") || WAt(u, "*") || WAt(u, "/") || WAt(u, "=") || WAt(u, "/=") || WAt(u, "<") || WAt(u, "<=") || WAt(u, ">") || WAt(u, ">=") || WAt(u, "and") || WAt(u, "or");
}
CWNode *WExpr(CWUnit *u)
{
    CWNode *n, *left;
    CWToken *t = u->cursor;
    if (!WEnter(u)) return WNode(u, "error", t);
    if (WAccept(u, "if")) {
        n = WNode(u, "if-expression", t); WAdd(n, WExpr(u), "condition"); WExpect(u, "then");
        WAdd(n, WExpr(u), "then"); WExpect(u, "else"); WAdd(n, WExpr(u), "else");
    } else if (WAt(u, "not") || WAt(u, "-")) {
        n = WNode(u, "unary", t); n->name = WTake(u)->text; WAdd(n, WAtom(u), "value");
    } else {
        n = WAtom(u);
        if (WBinary(u)) {
            left = n; n = WNode(u, "binary", u->cursor); n->name = WTake(u)->text;
            WAdd(n, left, "left"); WAdd(n, WAtom(u), "right");
        } else if (WAccept(u, ":")) {
            left = n; n = WNode(u, "cast", t); WAdd(n, left, "value"); WAdd(n, WType(u), "type");
        }
    }
    u->depth--; n->finish = u->cursor; return n;
}
U0 WBindings(CWUnit *u, CWNode *n, U8 *end)
{
    CWNode *b, *rename;
    if (!WAt(u, end)) {
        do {
            b = WNamed(u, "binding");
            if (WAccept(u, "as")) {rename = WNamed(u, "rename"); WAdd(b, rename, "rename");}
            WExpect(u, ":"); WAdd(b, WType(u), "type"); WAdd(n, b, "binding");
        } while (!u->error_kind && WAccept(u, ","));
    }
    WExpect(u, end);
}
CWNode *WIf(CWUnit *u)
{
    CWNode *n = WNode(u, "if", WTake(u));
    WAdd(n, WExpr(u), "condition"); WExpect(u, "then"); WAdd(n, WBlock(u, FALSE), "then");
    if (WAt(u, "else if")) WAdd(n, WIf(u), "else");
    else {
        if (WAccept(u, "else")) WAdd(n, WBlock(u, FALSE), "else");
        WExpect(u, "end"); WExpect(u, "if"); WExpect(u, ";");
    }
    return n;
}
CWNode *WStatement(CWUnit *u)
{
    CWToken *t = u->cursor;
    CWNode *n = WNode(u, t->text, t), *c;
    if (!WEnter(u)) return n;
    if (WAt(u, "if")) n = WIf(u);
    else if (WAt(u, "let") || WAt(u, "var")) {
        n->name = WTake(u)->text; n->tag = "let";
        if (WAccept(u, "{")) {n->tag = "destructure"; WBindings(u, n, "}");}
        else {WAdd(n, WNamed(u, "binding"), "binding"); WExpect(u, ":"); WAdd(n, WType(u), "type");}
        WExpect(u, ":="); WAdd(n, WExpr(u), "value"); WExpect(u, ";");
    } else if (WAccept(u, "case")) {
        WAdd(n, WExpr(u), "value"); WExpect(u, "of");
        while (!u->error_kind && WAccept(u, "when")) {
            c = WNamed(u, "when"); if (WAccept(u, "(")) WBindings(u, c, ")");
            WExpect(u, "do"); WAdd(c, WBlock(u, FALSE), "body"); WAdd(n, c, "when");
        }
        WExpect(u, "end"); WExpect(u, "case"); WExpect(u, ";");
    } else if (WAccept(u, "while")) {
        WAdd(n, WExpr(u), "condition"); WExpect(u, "do"); WAdd(n, WBlock(u, FALSE), "body");
        WExpect(u, "end"); WExpect(u, "while"); WExpect(u, ";");
    } else if (WAccept(u, "for")) {
        n->name = WIdent(u)->text; WExpect(u, "from"); WAdd(n, WExpr(u), "from");
        WExpect(u, "to"); WAdd(n, WExpr(u), "to"); WExpect(u, "do"); WAdd(n, WBlock(u, FALSE), "body");
        WExpect(u, "end"); WExpect(u, "for"); WExpect(u, ";");
    } else if (WAccept(u, "borrow")) {
        n->name = WIdent(u)->text; WExpect(u, ":");
        if (!WAt(u, "&") && !WAt(u, "&!")) WFail(u, u->cursor, "Parse Error", "Expected reference type");
        WAdd(n, WType(u), "type"); WExpect(u, ":=");
        c = WNode(u, "mode", u->cursor);
        if (!WAt(u, "&") && !WAt(u, "&!") && !WAt(u, "&~")) WFail(u, u->cursor, "Parse Error", "Expected borrow mode");
        c->name = WTake(u)->text; WAdd(n, c, "mode"); WAdd(n, WNamed(u, "variable"), "original");
        WExpect(u, "do"); WAdd(n, WBlock(u, FALSE), "body"); WExpect(u, "end"); WExpect(u, "borrow"); WExpect(u, ";");
    } else if (WAccept(u, "return")) {WAdd(n, WExpr(u), "value"); WExpect(u, ";");}
    else if (WAccept(u, "skip")) WExpect(u, ";");
    else {
        c = WExpr(u); n->tag = "discard";
        if (WAccept(u, ":=")) {
            n->tag = "assign";
            if (!WEq(c->tag, "variable") && !WEq(c->tag, "path")) WFail(u, c->token, "Parse Error", "Expected assignment path");
            WAdd(n, c, "target"); WAdd(n, WExpr(u), "value");
        } else WAdd(n, c, "value");
        WExpect(u, ";");
    }
    u->depth--; n->finish = u->cursor; return n;
}
CWNode *WBlock(CWUnit *u, Bool empty)
{
    CWNode *n = WNode(u, "block", u->cursor);
    while (!u->error_kind && u->cursor->kind && !WAt(u, "end") && !WAt(u, "else") && !WAt(u, "else if") && !WAt(u, "when")) WAdd(n, WStatement(u), "statement");
    if (!n->first && !empty) WFail(u, u->cursor, "Parse Error", "Expected nonempty block");
    return n;
}
U0 WDoc(CWUnit *u, CWNode *n)
{
    CWNode *d;
    if (u->cursor->kind == 6) {d = WNode(u, "doc", u->cursor); d->name = WTake(u)->text; WAdd(n, d, "doc");}
}
U0 WPragmas(CWUnit *u, CWNode *n)
{
    CWNode *p;
    while (!u->error_kind && WAccept(u, "pragma")) {
        p = WNamed(u, "pragma"); if (WAt(u, "(")) WArgs(u, p); WExpect(u, ";"); WAdd(n, p, "pragma");
    }
}
CWNode *WSlot(CWUnit *u)
{
    CWNode *s = WNode(u, "slot", u->cursor);
    WDoc(u, s); s->name = WIdent(u)->text; WExpect(u, ":"); WAdd(s, WType(u), "type"); WExpect(u, ";");
    return s;
}
CWNode *WMethod(CWUnit *u, Bool body)
{
    CWNode *n = WNode(u, "method", u->cursor);
    WDoc(u, n); if (WAccept(u, "generic")) WTypeParams(u, n);
    WExpect(u, "method"); n->name = WIdent(u)->text; WParams(u, n); WExpect(u, ":"); WAdd(n, WType(u), "result");
    if (body) {WExpect(u, "is"); WAdd(n, WBlock(u, FALSE), "body"); WExpect(u, "end");}
    WExpect(u, ";"); return n;
}
CWNode *WDecl(CWUnit *u, Bool body)
{
    CWNode *n = WNode(u, "declaration", u->cursor), *c;
    Bool generic = FALSE;
    WDoc(u, n); WPragmas(u, n);
    if (WAccept(u, "generic")) {generic = TRUE; WTypeParams(u, n);}
    n->tag = WTake(u)->text; n->name = WIdent(u)->text;
    if (generic && !WEq(n->tag, "function") && !WEq(n->tag, "instance")) WFail(u, n->token, "Parse Error", "Unexpected generic segment");
    if (WEq(n->tag, "constant")) {
        WExpect(u, ":"); WAdd(n, WType(u), "type");
        if (body) {WExpect(u, ":="); WAdd(n, WExpr(u), "value");}
        WExpect(u, ";");
    } else if (WEq(n->tag, "type") || WEq(n->tag, "record") || WEq(n->tag, "union")) {
        WTypeParams(u, n); WExpect(u, ":"); WAdd(n, WUniverse(u), "universe");
        if (WEq(n->tag, "type")) {
            if (body) WFail(u, n->token, "Parse Error", "Opaque type only allowed in interface");
        } else {
            WExpect(u, "is");
            while (!u->error_kind && !WAt(u, "end")) {
                if (WEq(n->tag, "record")) WAdd(n, WSlot(u), "slot");
                else {
                    c = WNode(u, "constructor", u->cursor); WDoc(u, c); WExpect(u, "case"); c->name = WIdent(u)->text;
                    if (!WAccept(u, ";")) {
                        WExpect(u, "is");
                        while (!u->error_kind && !WAt(u, "end") && !WAt(u, "case")) {
                            // A docstring may introduce the next case rather than a slot.
                            if (u->cursor->kind == 6 && u->cursor->next && WEq(u->cursor->next->text, "case")) break;
                            WAdd(c, WSlot(u), "slot");
                        }
                    }
                    WAdd(n, c, "constructor");
                }
            }
            WExpect(u, "end");
        }
        WExpect(u, ";");
    } else if (WEq(n->tag, "function")) {
        WParams(u, n); WExpect(u, ":"); WAdd(n, WType(u), "result");
        if (body) {WExpect(u, "is"); WAdd(n, WBlock(u, TRUE), "body"); WExpect(u, "end");}
        WExpect(u, ";");
    } else if (WEq(n->tag, "typeclass")) {
        WExpect(u, "("); WAdd(n, WTypeParam(u), "type-parameter"); WExpect(u, ")"); WExpect(u, "is");
        while (!u->error_kind && !WAt(u, "end")) WAdd(n, WMethod(u, FALSE), "method");
        WExpect(u, "end"); WExpect(u, ";");
    } else if (WEq(n->tag, "instance")) {
        WExpect(u, "("); WAdd(n, WType(u), "argument"); WExpect(u, ")");
        if (body) {WExpect(u, "is"); while (!u->error_kind && !WAt(u, "end")) WAdd(n, WMethod(u, TRUE), "method"); WExpect(u, "end");}
        WExpect(u, ";");
    } else WFail(u, n->token, "Parse Error", "Expected declaration");
    n->finish = u->cursor; return n;
}
U8 *WModuleName(CWUnit *u)
{
    U8 *text = WAlloc(u, u->cursor->source->size + 1), *s;
    I64 n = 0, l;
    s = WIdent(u)->text; l = StrLen(s); MemCpy(text + n, s, l); n += l;
    while (!u->error_kind && WAccept(u, ".")) {
        text[n++] = '.'; s = WIdent(u)->text; l = StrLen(s); MemCpy(text + n, s, l); n += l;
    }
    return text;
}
CWNode *WParse(CWUnit *u, U8 *path, U8 *text, Bool body)
{
    CWSource *src = WAlloc(u, sizeof(CWSource));
    CWNode *n, *imp, *sym, *alias;
    src->size = StrLen(text); src->text = WText(u, text, src->size); src->path = WText(u, path, StrLen(path));
    src->next = u->sources; u->sources = src; u->cursor = WLex(u, src);
    n = WNode(u, "interface", u->cursor); if (body) n->tag = "module";
    WDoc(u, n); if (body) WPragmas(u, n);
    while (!u->error_kind && WAccept(u, "import")) {
        imp = WNode(u, "import", u->cursor); imp->name = WModuleName(u); WExpect(u, "(");
        if (!WAt(u, ")")) {
            do {
                sym = WNamed(u, "import-symbol");
                if (WAccept(u, "as")) {alias = WNamed(u, "alias"); WAdd(sym, alias, "alias");}
                WAdd(imp, sym, "symbol");
            } while (!u->error_kind && WAccept(u, ","));
        }
        WExpect(u, ")"); WExpect(u, ";"); WAdd(n, imp, "import");
    }
    WExpect(u, "module"); if (body) WExpect(u, "body"); n->name = WModuleName(u); WExpect(u, "is");
    while (!u->error_kind && !WAt(u, "end")) WAdd(n, WDecl(u, body), "declaration");
    WExpect(u, "end"); WExpect(u, "module"); if (body) WExpect(u, "body"); WExpect(u, ".");
    if (u->cursor->kind) WFail(u, u->cursor, "Parse Error", "Expected end of file");
    n->finish = u->cursor;
    if (u->last_module) u->last_module->next = n; else u->modules = n;
    u->last_module = n;
    return n;
}
