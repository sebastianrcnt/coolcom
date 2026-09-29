// Warm compiler. Language derived from Austral; see ../LICENSE.
class CWArena {CWArena *next; I64 used, capacity;};
class CWSource {CWSource *next; U8 *path, *text; I64 size;};
class CWToken {CWToken *next; CWSource *source; U8 *text; I64 kind, start, end;};
class CWNode {
    CWNode *next, *first, *last;
    CWToken *token, *finish;
    U8 *tag, *name, *role;
    CWNode *resolved, *ty, *owner, *scope, *pair;
    I64 flags;
};
class CWUnit {
    CWArena *arena;
    CWSource *sources;
    CWToken *cursor;
    CWNode *modules, *last_module;
    CWToken *error_token;
    U8 *error_kind, *error_message;
    I64 nodes, tokens, depth;
};
U8 *WAlloc(CWUnit *u, I64 size)
{
    CWArena *a = u->arena;
    U8 *p;
    size = (size + 7) & ~7;
    if (!a || a->used + size > a->capacity) {
        a = CAlloc(sizeof(CWArena) + size + 65536);
        a->capacity = size + 65536;
        a->next = u->arena;
        u->arena = a;
    }
    p = (a(U8 *) + sizeof(CWArena)) + a->used;
    a->used += size;
    return p;
}
U8 *WText(CWUnit *u, U8 *s, I64 n)
{
    U8 *p = WAlloc(u, n + 1);
    MemCpy(p, s, n);
    return p;
}
Bool WEq(U8 *a, U8 *b) {return !StrCmp(a, b);}
U0 WFail(CWUnit *u, CWToken *t, U8 *kind, U8 *message)
{
    if (!u->error_kind) {
        u->error_token = t;
        u->error_kind = kind;
        u->error_message = message;
    }
}
CWNode *WNode(CWUnit *u, U8 *tag, CWToken *t)
{
    CWNode *n = WAlloc(u, sizeof(CWNode));
    n->tag = tag; n->token = t; n->finish = t; n->name = ""; n->role = "";
    u->nodes++;
    return n;
}
CWNode *WAdd(CWNode *parent, CWNode *child, U8 *role)
{
    if (!child) return NULL;
    child->role = role;
    if (parent->last) parent->last->next = child;
    else parent->first = child;
    parent->last = child;
    return child;
}
CWNode *WChild(CWNode *n, U8 *role)
{
    CWNode *c;
    for (c = n->first; c; c = c->next) if (WEq(c->role, role)) return c;
    return NULL;
}
CWUnit *WNew() {return CAlloc(sizeof(CWUnit));}
U0 WDestroy(CWUnit *u)
{
    CWArena *a = u->arena, *next;
    while (a) {next = a->next; Free(a); a = next;}
    Free(u);
}
U8 *WTriple(CWUnit *u, U8 *s)
{
    I64 len = StrLen(s), i = 0, start = 0, count = 0, j, k, min = 0x7fffffffffffffff, n = 0, lead;
    I64 *starts = WAlloc(u, (len + 2) * 8), *sizes = WAlloc(u, (len + 2) * 8);
    U8 *joined = WAlloc(u, len + 1), *out = WAlloc(u, len + 1);
    for (i = 0; i <= len; i++) if (s[i] == '\n' || !s[i]) {starts[count] = start; sizes[count++] = i - start; start = i + 1;}
    for (i = 0; i < count; i++) {
        j = starts[i]; k = sizes[i];
        if (i == 0 || i == count - 1) {
            lead = 0; while (lead < k && (s[j + lead] == ' ' || s[j + lead] == '\t' || s[j + lead] == '\r')) lead++;
            if (lead == k) k = 0;
        }
        if (i > 1 && i < count - 1) joined[n++] = '\n';
        MemCpy(joined + n, s + j, k); n += k;
    }
    if (count == 1) return joined;
    start = 0;
    for (i = 0; i <= n; i++) if (joined[i] == '\n' || !joined[i]) {
            lead = 0; while (start + lead < i && joined[start + lead] == ' ') lead++;
            if (lead < min) min = lead; start = i + 1;
        }
    start = 0; k = 0;
    for (i = 0; i <= n; i++) if (joined[i] == '\n' || !joined[i]) {
            j = start + min; while (j < i) out[k++] = joined[j++];
            if (joined[i]) out[k++] = '\n'; start = i + 1;
        }
    return out;
}
