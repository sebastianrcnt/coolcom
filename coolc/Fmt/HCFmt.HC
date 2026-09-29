// HolyC source formatter: a gofmt-style canonical formatter.
//   U8 *HCFmt(U8 *src)  returns a new MAlloc'ed string, the caller frees it.
// Pure string -> string, no I/O. Needs only MAlloc, Free, MemCpy, MemSet, StrLen.
//
// Layout: the spaces between tokens on a line are re-emitted by rule (see
// "SPACING RULES" below), so the output does not depend on the input's
// intra-line spacing. Leading whitespace is rewritten (HCF_INDENT spaces per
// level), trailing whitespace is stripped, runs of blank lines collapse to one
// and the text ends with a single newline. Line breaks are kept: lines are
// never split, joined or wrapped, and braces are never moved.
// Kept as found: comments (and the whitespace right before one), string and
// char literal contents, preprocessor lines (except their indentation) and
// asm blocks (inner spacing).
// The output is verified to hold the same non-whitespace characters as the
// input; if not, a copy of the input is returned and hcfmt_err is set.
//
// After a call: hcfmt_err is 0 (ok) or 1 (token check failed, input returned),
// hcfmt_warn is 0 or 1 (unbalanced braces/quotes/comment: output may be off).

#define HCF_MAX    256
#define HCF_INDENT 4  // spaces per indent level
#define HCF_CONT_LEVELS 2  // continuation lines: this many levels past the statement
#define HCF_PALIGN_MAX 40  // max paren alignment past the statement indent
#define HCF_NCLS   512     // class names remembered from the file itself

#define HCF_BLOCK 1
#define HCF_CASE  2
#define HCF_INIT  3
#define HCF_IF    4   // if/try, waits for an optional else/catch
#define HCF_ELSE  5
#define HCF_LOOP  6   // while/for/switch
#define HCF_DO    7
#define HCF_ASM   8

#define HCFK_IF      1
#define HCFK_ELSE    2
#define HCFK_WHILE   3
#define HCFK_FOR     4
#define HCFK_DO      5
#define HCFK_SWITCH  6
#define HCFK_CASE    7
#define HCFK_DEFAULT 8
#define HCFK_TRY     9
#define HCFK_CATCH   10
#define HCFK_ASM     11
#define HCFK_ENUM    12
#define HCFK_START   13

I64 hcfmt_err, hcfmt_warn;

class CHCFmt
{
    U8 *out;
    I64 olen, ocap, last_blank;
    I64 nf;
    I64 kind[HCF_MAX], base[HCF_MAX], flag[HCF_MAX], spd[HCF_MAX];
    I64 pcol[HCF_MAX], pn;
    U8 *cnp[HCF_NCLS];
    I64 cnl[HCF_NCLS], ncls;
    U8 *lb;
    I64 lblen, lbcap, lend, lastcmt, tokcol, pk, plc;
    I64 pd, in_stmt, want, pend, hdr, dotail, pendsw, isenum, asm_next, incase;
    I64 in_bc, in_str, need_ind, ind, prev, nostate;
};

Bool HCFIsWs(I64 c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == 11 || c == 12;
}

Bool HCFIsId(I64 c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
            c == '_' || c == '@';
}

Bool HCFStrEq(U8 *p, I64 n, U8 *s)
{
    I64 i;
    for (i = 0; i < n; i++)
        if (p[i] != s[i] || !s[i])
            return FALSE;
    return !s[n];
}

I64 HCFKw(U8 *p, I64 n)
{
    if (n < 2 || n > 7)
        return 0;
    if (HCFStrEq(p, n, "if"))
        return HCFK_IF;
    if (HCFStrEq(p, n, "else"))
        return HCFK_ELSE;
    if (HCFStrEq(p, n, "while"))
        return HCFK_WHILE;
    if (HCFStrEq(p, n, "for"))
        return HCFK_FOR;
    if (HCFStrEq(p, n, "do"))
        return HCFK_DO;
    if (HCFStrEq(p, n, "switch"))
        return HCFK_SWITCH;
    if (HCFStrEq(p, n, "case"))
        return HCFK_CASE;
    if (HCFStrEq(p, n, "default"))
        return HCFK_DEFAULT;
    if (HCFStrEq(p, n, "try"))
        return HCFK_TRY;
    if (HCFStrEq(p, n, "catch"))
        return HCFK_CATCH;
    if (HCFStrEq(p, n, "asm"))
        return HCFK_ASM;
    if (HCFStrEq(p, n, "enum"))
        return HCFK_ENUM;
    if (HCFStrEq(p, n, "start") || HCFStrEq(p, n, "end"))
        return HCFK_START;
    return 0;
}

//---- output buffer

U0 HCFPut(CHCFmt *s, U8 *p, I64 n)
{
    U8 *t;
    if (s->olen + n + 1 > s->ocap) {
        s->ocap = (s->olen + n + 1) * 2;
        t = MAlloc(s->ocap);
        if (s->olen)
            MemCpy(t, s->out, s->olen);
        Free(s->out);
        s->out = t;
    }
    if (n)
        MemCpy(s->out + s->olen, p, n);
    s->olen += n;
    s->out[s->olen] = 0;
}

U0 HCFPutCh(CHCFmt *s, I64 c)
{
    U8 b[2];
    b[0] = c;
    b[1] = 0;
    HCFPut(s, b, 1);
}

//---- indentation state

// Indent level of the first n frames.
I64 HCFLevelN(CHCFmt *s, I64 n)
{
    I64 i, k, lvl = 0;
    for (i = 0; i < n; i++) {
        k = s->kind[i];
        if (k == HCF_BLOCK || k == HCF_CASE || k == HCF_ASM)
            lvl++;
        else if (k >= HCF_IF && k <= HCF_DO && !s->flag[i])
            lvl++;
    }
    return lvl;
}

I64 HCFLevel(CHCFmt *s)
{
    return HCFLevelN(s, s->nf);
}

I64 HCFInitDepth(CHCFmt *s)
{
    I64 i, d = 0;
    for (i = 0; i < s->nf; i++)
        if (s->kind[i] == HCF_INIT)
            d++;
    return d;
}

// Indent of a continuation line of the current statement.
I64 HCFCont(CHCFmt *s)
{
    I64 d = HCFInitDepth(s);
    if (d < 1)
        d = HCF_CONT_LEVELS;  // flat continuation
    return HCFLevel(s) + d;
}

// Continuation in spaces: align under the innermost open paren when it is
// on the same scope and not too far right, else the flat indent.
I64 HCFContCol(CHCFmt *s)
{
    I64 flat = HCFCont(s) * HCF_INDENT, col;
    if (s->pd > 0 && s->pn > 0) {
        col = s->pcol[s->pn - 1];
        if (col >= flat && col <= HCFLevel(s) * HCF_INDENT + HCF_PALIGN_MAX)
            return col;
    }
    return flat;
}

// Indent for a comment-only line: as if a statement token came next.
I64 HCFPeekLevel(CHCFmt *s)
{
    I64 n = s->nf;
    if (s->pend) {
        while (n > 0 && s->kind[n - 1] >= HCF_IF && s->kind[n - 1] <= HCF_DO)
            n--;
        return HCFLevelN(s, n) * HCF_INDENT;
    }
    if (s->in_stmt || s->pd > 0)
        return HCFContCol(s);
    return HCFLevel(s) * HCF_INDENT;
}

U0 HCFPush(CHCFmt *s, I64 kind, I64 flag)
{
    if (s->nf < HCF_MAX) {
        s->kind[s->nf] = kind;
        s->base[s->nf] = HCFLevel(s);
        s->flag[s->nf] = flag;
        s->spd[s->nf] = 0;
        s->nf++;
    } else
        hcfmt_warn = 1;
}

// A statement just ended: finish the constructs it completed.
U0 HCFComplete(CHCFmt *s)
{
    I64 k;
    s->in_stmt = FALSE;
    s->pend = FALSE;
    s->want = FALSE;
    s->incase = FALSE;
    while (s->nf) {
        k = s->kind[s->nf - 1];
        if (k == HCF_IF || k == HCF_DO) {
            s->pend = TRUE;  // an else / while may follow
            return;
        }
        if (k == HCF_ELSE || k == HCF_LOOP)
            s->nf--;
        else
            return;
    }
}

//---- token handler

// Set the indent of the line's first token (in levels).
U0 HCFSetInd(CHCFmt *s, I64 ind)
{
    if (s->need_ind) {
        s->ind = ind * HCF_INDENT;
        s->need_ind = FALSE;
    }
}

U0 HCFSetCont(CHCFmt *s)
{
    if (s->need_ind) {
        s->ind = HCFContCol(s);
        s->need_ind = FALSE;
    }
}

// k: 'i' word/number, 'L' label ("name:"), 's' string, 'c' char, 'o' other
// punctuation, or one of ( ) [ ] { } ; :
U0 HCFTok(CHCFmt *s, I64 k, U8 *p, I64 n)
{
    I64 kw = 0, top, isel, iswh, init, i, d;
    if (s->nostate)
        return;
    if (s->nf && s->kind[s->nf - 1] == HCF_ASM) {
        top = s->nf - 1;
        if (k == '{') {
            HCFSetInd(s, HCFLevel(s));
            s->flag[top]++;
        } else if (k == '}') {
            if (s->flag[top] > 0) {
                HCFSetInd(s, HCFLevel(s));
                s->flag[top]--;
            } else {
                s->nf--;
                HCFSetInd(s, HCFLevel(s));
                HCFComplete(s);
            }
        } else if (k == 'L')
            HCFSetInd(s, HCFLevel(s) - 1);
        else
            HCFSetInd(s, HCFLevel(s));
        return;
    }
    if (k == 'i' || k == 'L') {
        i = n;
        if (k == 'L') {
            i = 0;
            while (HCFIsId(p[i]))
                i++;
        }
        kw = HCFKw(p, i);
    }
    isel = (kw == HCFK_ELSE || kw == HCFK_CATCH) && k == 'i';
    iswh = kw == HCFK_WHILE && k == 'i';
    // finish constructs that a token other than else/while completes
    if (s->pd == 0)
        while (s->pend) {
            top = s->nf - 1;
            if (isel && s->kind[top] == HCF_IF)
                break;
            if (iswh && s->kind[top] == HCF_DO)
                break;
            s->nf--;
            HCFComplete(s);
        }
    if (s->pend && s->pd == 0) {
        top = s->nf - 1;
        HCFSetInd(s, s->base[top]);
        if (isel) {
            s->kind[top] = HCF_ELSE;
            s->flag[top] = 0;
            s->want = TRUE;
            s->pend = FALSE;
            s->in_stmt = FALSE;
        } else {
            s->nf--;
            s->pend = FALSE;
            s->dotail = TRUE;
            s->in_stmt = TRUE;
        }
        s->prev = 'x';
        return;
    }
    // a construct header is complete and waits for its body
    if (s->want) {
        s->want = FALSE;
        top = s->nf - 1;
        if (k == '{')
            s->flag[top] = 1;
        else if (kw == HCFK_IF && k == 'i' && s->kind[top] == HCF_ELSE)
            s->nf--;  // else if: one chain, one level
    }
    if (k == '}') {
        while (s->nf && s->kind[s->nf - 1] != HCF_BLOCK && s->kind[s->nf - 1] != HCF_INIT)
            s->nf--;
        if (s->nf && s->kind[s->nf - 1] == HCF_INIT) {
            d = HCFInitDepth(s);
            HCFSetInd(s, HCFLevel(s) + d - 1);
            s->pd = s->spd[s->nf - 1];
            s->nf--;
        } else {
            if (s->nf)
                s->nf--;
            HCFSetInd(s, HCFLevel(s));
            HCFComplete(s);
        }
        s->prev = '}';
        return;
    }
    if (k == '{') {
        init = s->pd > 0 || s->isenum || s->prev == '=' || s->prev == ',' || s->prev == '(' ||
                s->prev == '[' || (s->nf && s->kind[s->nf - 1] == HCF_INIT);
        if (init) {
            HCFSetCont(s);
            HCFPush(s, HCF_INIT, 0);
            s->spd[s->nf - 1] = s->pd;
            s->pd = 0;
            s->in_stmt = TRUE;
            s->isenum = FALSE;
        } else {
            HCFSetInd(s, HCFLevel(s));
            if (s->asm_next)
                HCFPush(s, HCF_ASM, 0);
            else
                HCFPush(s, HCF_BLOCK, s->pendsw);
            s->asm_next = FALSE;
            s->pendsw = FALSE;
            s->in_stmt = FALSE;
        }
        s->prev = '{';
        return;
    }
    if (k == '(' || k == '[') {
        if (s->in_stmt || s->pd > 0)
            HCFSetCont(s);
        else
            HCFSetInd(s, HCFLevel(s));
        if (s->pn < HCF_MAX) {
            s->pcol[s->pn] = s->ind + s->tokcol + 1;
            s->pn++;
        }
        s->pd++;
        s->in_stmt = TRUE;
        s->prev = '(';
        return;
    }
    if (k == ')' || k == ']') {
        HCFSetCont(s);
        if (s->pd > 0) {
            s->pd--;
            if (s->pn > 0)
                s->pn--;
        }
        if (s->pd == 0 && s->hdr) {
            s->in_stmt = FALSE;
            if (s->hdr == HCFK_IF)
                HCFPush(s, HCF_IF, 0);
            else
                HCFPush(s, HCF_LOOP, 0);
            if (s->hdr == HCFK_SWITCH)
                s->pendsw = TRUE;
            s->hdr = 0;
            s->want = TRUE;
        }
        s->prev = ')';
        return;
    }
    if (k == ';') {
        if (s->in_stmt || s->pd > 0)
            HCFSetCont(s);
        else
            HCFSetInd(s, HCFLevel(s));
        if (s->pd == 0 && !(s->nf && s->kind[s->nf - 1] == HCF_INIT)) {
            s->isenum = FALSE;
            s->dotail = FALSE;
            s->asm_next = FALSE;
            HCFComplete(s);
        }
        s->prev = ';';
        return;
    }
    if (k == ':') {
        HCFSetCont(s);
        if (s->incase && s->pd == 0) {
            HCFPush(s, HCF_CASE, 0);
            s->incase = FALSE;
            s->in_stmt = FALSE;
        }
        s->prev = ':';
        return;
    }
    // words, strings and other tokens
    if (k == 'L') {
        if (kw == HCFK_DEFAULT || kw == HCFK_CASE || kw == HCFK_START) {
            if (s->nf && s->kind[s->nf - 1] == HCF_CASE)
                s->nf--;
            HCFSetInd(s, HCFLevel(s));
            HCFPush(s, HCF_CASE, 0);
        } else
            HCFSetInd(s, 0);  // goto label
        s->in_stmt = FALSE;
        s->prev = ':';
        return;
    }
    if (s->in_stmt || s->pd > 0)
        HCFSetCont(s);
    else {
        if (kw == HCFK_CASE && k == 'i' && s->nf && s->kind[s->nf - 1] == HCF_CASE)
            s->nf--;
        HCFSetInd(s, HCFLevel(s));
    }
    if (!s->in_stmt && k == 'i') {
        if (kw == HCFK_IF || kw == HCFK_FOR || kw == HCFK_SWITCH || kw == HCFK_WHILE) {
            if (kw == HCFK_WHILE && s->dotail)
                s->hdr = 0;
            else
                s->hdr = kw;
            s->in_stmt = TRUE;
            s->prev = 'x';
            return;
        }
        if (kw == HCFK_DO || kw == HCFK_TRY) {
            if (kw == HCFK_DO)
                HCFPush(s, HCF_DO, 0);
            else
                HCFPush(s, HCF_IF, 0);
            s->want = TRUE;
            s->prev = 'x';
            return;
        }
        if (kw == HCFK_CASE)
            s->incase = TRUE;
        else if (kw == HCFK_ENUM)
            s->isenum = TRUE;
        else if (kw == HCFK_ASM)
            s->asm_next = TRUE;
    }
    s->in_stmt = TRUE;
    if (k == 'o')
        s->prev = p[n - 1];
    else
        s->prev = 'x';
}

//---- SPACING RULES
//
// Every token gets a class (HCFS_*). The space before a token is a function of
// the previous token's class and this token's class only (HCFGap below), never
// of the input's spacing. To change the style, edit HCFGap (the gap between two
// tokens) and the classifiers HCFWordClass / HCFPunct (how ambiguous tokens
// are classed).
//
//   binary operators   one space each side:  = += -= ... + - * / % << >> & | ^
//                      && || ^^ == != < > <= >= and ` (power)
//   unary operators    attach to the operand: -x !x ~x *p &v ++i i++ --i
//                      a - + * & is binary after an operand (identifier,
//                      number, string/char, ) ] postfix ++ --), else unary
//   pointer declarator `U8 *p`, `CTask **t`, `(U8 *)`: after a type name the
//                      star follows one space and attaches to what comes next.
//                      Type names: builtin (U0 U8 .. I64 F64 Bool, the *i raw
//                      types), or C+Uppercase identifiers without '_' that
//                      stand at a declaration start (after ; { } ( , : or a
//                      modifier like extern) and are followed by a name
//   comma              no space before, one after
//   semicolon          no space before, one after (for (a; b; c)); for (;;)
//   if while for switch catch return case else do try: one space before (
//   calls, sizeof(X), offset(C.m), casts x(U8 *): no space before (
//   no space just inside ( ) [ ], none around . and ->
//   `{` one space before it (if (x) {, } else {) unless it follows ( [ {;
//   no space just inside { }:  {1, 2}, {return x;}
//   labels `name:`, `case X:`, `default:`: colon attached; `case 1...5:` and
//   the `...` in (U8 *fmt, ...) : compact
//   Kept as found: comments and the whitespace before/after one, asm bodies.

#define HCFS_NONE  0   // nothing before (start of file)
#define HCFS_ID    1   // identifier, number: an operand
#define HCFS_STR   2   // string or char literal: an operand
#define HCFS_CLSD  3   // C+Uppercase class name at a declaration start
#define HCFS_TYPE  4   // builtin type name
#define HCFS_KW    5   // if else return ...: a word, not an operand
#define HCFS_MOD   6   // extern public ...: a modifier that starts a declaration
#define HCFS_OPEN  7   // (
#define HCFS_OPENB 8   // [
#define HCFS_CLOSE 9   // )
#define HCFS_CLOSB 10  // ]
#define HCFS_LBR   11  // {
#define HCFS_RBR   12  // }
#define HCFS_SEMI  13
#define HCFS_COMMA 14
#define HCFS_COLON 15
#define HCFS_DOT   16  // . and ->
#define HCFS_BIN   17  // binary operator
#define HCFS_UN    18  // prefix operator: ! ~ and unary - + * &
#define HCFS_PRE   19  // prefix ++ --
#define HCFS_POST  20  // postfix ++ --
#define HCFS_PTR   21  // the star(s) of a pointer declarator
#define HCFS_ELL   22  // ...
#define HCFS_HDR   23  // the ) that closes an if/while/for/switch header
#define HCFS_CMT   24  // comment
#define HCFS_UNK   25  // anything else: spacing kept as found

#define HCFG_NONE  0
#define HCFG_ONE   1
#define HCFG_FOUND 2   // the input's own whitespace

// Would the two characters, written next to each other, lex differently?
Bool HCFGlue(I64 a, I64 b)
{
    if (b == '=' && (a == '+' || a == '-' || a == '*' || a == '/' || a == '%' || a == '&' ||
                     a == '|' || a == '^' || a == '<' || a == '>' || a == '=' || a == '!' || a == '`'))
        return TRUE;
    if (a == b && (a == '+' || a == '-' || a == '&' || a == '|' || a == '^' || a == '<' || a == '>' ||
                   a == '=' || a == '.' || a == ':' || a == '/'))
        return TRUE;
    if (a == '-' && b == '>')
        return TRUE;
    if (a == '/' && b == '*')
        return TRUE;
    if (a == '*' && b == '/')
        return TRUE;
    return FALSE;
}

// Tokens after which a following + - * & is binary.
Bool HCFOperandEnd(I64 c)
{
    return c == HCFS_ID || c == HCFS_STR || c == HCFS_CLSD || c == HCFS_TYPE ||
            c == HCFS_CLOSE || c == HCFS_CLOSB || c == HCFS_POST;
}

// Where a declaration (and so a class name) can start.
Bool HCFDeclStart(I64 c)
{
    return c == HCFS_NONE || c == HCFS_SEMI || c == HCFS_LBR || c == HCFS_RBR ||
            c == HCFS_OPEN || c == HCFS_COMMA || c == HCFS_COLON || c == HCFS_HDR || c == HCFS_MOD;
}

// The space between the previous token (class s->pk) and this one (class ck,
// first character c1) on the same line. Returns HCFG_*.
I64 HCFGap(CHCFmt *s, I64 ck, I64 c1)
{
    I64 pk = s->pk, g;
    if (s->lend < 0)
        return HCFG_NONE;  // first token of the line: the indent is added later
    if (s->nf && s->kind[s->nf - 1] == HCF_ASM && !s->nostate)
        return HCFG_FOUND;  // asm bodies are left alone
    if (ck == HCFS_CMT || s->lastcmt || ck == HCFS_UNK || pk == HCFS_UNK)
        return HCFG_FOUND;
    if (ck == HCFS_STR && pk == HCFS_STR)
        return HCFG_FOUND;
    if (ck == HCFS_COMMA || ck == HCFS_SEMI || ck == HCFS_DOT || ck == HCFS_POST ||
            ck == HCFS_CLOSE || ck == HCFS_CLOSB || ck == HCFS_COLON || ck == HCFS_RBR)
        g = HCFG_NONE;
    else if (pk == HCFS_UN || pk == HCFS_PRE || pk == HCFS_PTR || pk == HCFS_OPEN ||
             pk == HCFS_OPENB || pk == HCFS_DOT || pk == HCFS_LBR || pk == HCFS_ELL)
        g = HCFG_NONE;
    else if (ck == HCFS_ELL) {
        if (pk == HCFS_COMMA)
            g = HCFG_ONE;
        else
            g = HCFG_NONE;
    } else if (ck == HCFS_OPEN || ck == HCFS_OPENB) {
        // a call, an index or a postfix cast has no space; keywords, types, the )
        // of a header and operators do
        if (pk == HCFS_ID || pk == HCFS_CLSD || pk == HCFS_CLOSE || pk == HCFS_CLOSB ||
                pk == HCFS_POST)
            g = HCFG_NONE;
        else
            g = HCFG_ONE;
    } else
        g = HCFG_ONE;
    if (g == HCFG_NONE && HCFGlue(s->plc, c1))
        g = HCFG_ONE;
    return g;
}

//---- token classification

Bool HCFIsUp(I64 c)
{
    return c >= 'A' && c <= 'Z';
}

Bool HCFIsDigit(I64 c)
{
    return c >= '0' && c <= '9';
}

// Builtin type names: U0 U8 U16 U32 U64 I8 I16 I32 I64 F64 Bool and the raw
// types with a trailing i.
Bool HCFIsType(U8 *p, I64 n)
{
    I64 v, i;
    if (HCFStrEq(p, n, "Bool"))
        return TRUE;
    if (n < 2 || n > 4 || (p[0] != 'U' && p[0] != 'I' && p[0] != 'F'))
        return FALSE;
    if (p[n - 1] == 'i')
        n--;
    if (n < 2)
        return FALSE;
    v = 0;
    for (i = 1; i < n; i++) {
        if (!HCFIsDigit(p[i]))
            return FALSE;
        v = v * 10 + p[i] - '0';
    }
    return v == 0 || v == 8 || v == 16 || v == 32 || v == 64;
}

// C+Uppercase without '_': CTask, CMemBlk, CBRPN (but not CLSF_VARGS).
Bool HCFIsClsName(U8 *p, I64 n)
{
    I64 i;
    if (n < 3 || p[0] != 'C' || !HCFIsUp(p[1]))
        return FALSE;
    for (i = 0; i < n; i++)
        if (p[i] == '_')
            return FALSE;
    return TRUE;
}

// Is p[0..n) a class or union declared in this file (class Name / union Name)?
Bool HCFKnownCls(CHCFmt *s, U8 *p, I64 n)
{
    I64 i, j;
    for (i = 0; i < s->ncls; i++)
        if (s->cnl[i] == n) {
            for (j = 0; j < n && p[j] == s->cnp[i][j]; j++);
            if (j == n)
                return TRUE;
        }
    return FALSE;
}

// Remember the uppercase names that follow "class" or "union" in src.
U0 HCFFindClasses(CHCFmt *s, U8 *src)
{
    U8 *p = src, *q;
    while (*p) {
        if ((p == src || !HCFIsId(p[-1])) &&
                (HCFStrEq(p, 5, "class") || HCFStrEq(p, 5, "union")) && !HCFIsId(p[5])) {
            q = p + 5;
            while (*q == ' ' || *q == '\t')
                q++;
            if (HCFIsUp(*q) && s->ncls < HCF_NCLS) {
                s->cnp[s->ncls] = q;
                while (HCFIsId(*q))
                    q++;
                s->cnl[s->ncls] = q - s->cnp[s->ncls];
                s->ncls++;
            }
            p = q;
        } else
            p++;
    }
}

// Words that are followed by a space and are not operands.
Bool HCFIsKwSp(U8 *p, I64 n)
{
    return HCFStrEq(p, n, "if") || HCFStrEq(p, n, "else") || HCFStrEq(p, n, "while") ||
            HCFStrEq(p, n, "for") || HCFStrEq(p, n, "do") || HCFStrEq(p, n, "switch") ||
            HCFStrEq(p, n, "case") || HCFStrEq(p, n, "try") || HCFStrEq(p, n, "catch") ||
            HCFStrEq(p, n, "return") || HCFStrEq(p, n, "goto");
}

// Modifiers that come before a declaration.
Bool HCFIsMod(U8 *p, I64 n)
{
    return HCFStrEq(p, n, "extern") || HCFStrEq(p, n, "public") ||
            HCFStrEq(p, n, "static") || HCFStrEq(p, n, "reg") || HCFStrEq(p, n, "noreg") ||
            HCFStrEq(p, n, "import") || HCFStrEq(p, n, "export") ||
            HCFStrEq(p, n, "_extern") || HCFStrEq(p, n, "_import") ||
            HCFStrEq(p, n, "_intern") || HCFStrEq(p, n, "interrupt") ||
            HCFStrEq(p, n, "haserrcode") || HCFStrEq(p, n, "argpop");
}

// Class of an identifier or number (p[0..n)).
I64 HCFWordClass(CHCFmt *s, U8 *p, I64 n)
{
    if (HCFIsDigit(p[0]) || p[0] == '.' || s->pk == HCFS_DOT)
        return HCFS_ID;  // numbers and member names
    if (HCFIsKwSp(p, n))
        return HCFS_KW;
    if (HCFIsMod(p, n))
        return HCFS_MOD;
    if (HCFIsType(p, n))
        return HCFS_TYPE;
    if ((HCFIsClsName(p, n) || HCFKnownCls(s, p, n)) && HCFDeclStart(s->pk))
        return HCFS_CLSD;
    return HCFS_ID;
}

// End of the number starting at ls[i]: 0x1F, 1.5e-3, .5, stops before "...".
I64 HCFNumEnd(U8 *ls, I64 i, I64 n)
{
    I64 j = i;
    Bool hex = FALSE;
    if (ls[j] == '0' && j + 1 < n && (ls[j + 1] == 'x' || ls[j + 1] == 'X'))
        hex = TRUE;
    while (j < n) {
        if (HCFIsId(ls[j])) {
            j++;
            if (!hex && (ls[j - 1] == 'e' || ls[j - 1] == 'E') && j + 1 < n &&
                    (ls[j] == '+' || ls[j] == '-') && HCFIsDigit(ls[j + 1]))
                j++;
        } else if (ls[j] == '.' && !(j + 1 < n && ls[j + 1] == '.'))
            j++;
        else
            break;
    }
    return j;
}

//---- line buffer

U0 HCFLbPut(CHCFmt *s, U8 *p, I64 n)
{
    U8 *t;
    if (s->lblen + n + 1 > s->lbcap) {
        s->lbcap = (s->lblen + n + 1) * 2;
        t = MAlloc(s->lbcap);
        if (s->lblen)
            MemCpy(t, s->lb, s->lblen);
        Free(s->lb);
        s->lb = t;
    }
    if (n)
        MemCpy(s->lb + s->lblen, p, n);
    s->lblen += n;
    s->lb[s->lblen] = 0;
}

// Append source text ls[a,b) untouched (string and comment contents).
U0 HCFRaw(CHCFmt *s, U8 *ls, I64 a, I64 b)
{
    HCFLbPut(s, ls + a, b - a);
    s->lend = b;
}

// Append one token ls[i,i+n) of class ck, preceded by the gap the rules give.
U0 HCFOut(CHCFmt *s, U8 *ls, I64 i, I64 n, I64 ck)
{
    I64 g = HCFGap(s, ck, ls[i]);
    if (g == HCFG_ONE)
        HCFLbPut(s, " ", 1);
    else if (g == HCFG_FOUND && s->lend >= 0 && s->lend < i)
        HCFLbPut(s, ls + s->lend, i - s->lend);
    s->tokcol = s->lblen;
    HCFLbPut(s, ls + i, n);
    s->lend = i + n;
    s->lastcmt = ck == HCFS_CMT;
}

// Remember the class and last character of the token just handled.
U0 HCFPk(CHCFmt *s, I64 ck, I64 lc)
{
    s->pk = ck;
    s->plc = lc;
}

//---- lexer

// Handle the punctuation token at ls[i]; returns its length.
I64 HCFPunct(CHCFmt *s, U8 *ls, I64 i, I64 n)
{
    I64 c = ls[i], c2 = 0, c3 = 0, m = 1, ck = HCFS_UNK, k = 'o', hd, j;
    if (i + 1 < n)
        c2 = ls[i + 1];
    if (i + 2 < n)
        c3 = ls[i + 2];
    if (c == '(') {
        ck = HCFS_OPEN;
        k = c;
    } else if (c == ')') {
        ck = HCFS_CLOSE;
        k = c;
    } else if (c == '[') {
        ck = HCFS_OPENB;
        k = c;
    } else if (c == ']') {
        ck = HCFS_CLOSB;
        k = c;
    } else if (c == '{') {
        ck = HCFS_LBR;
        k = c;
    } else if (c == '}') {
        ck = HCFS_RBR;
        k = c;
    } else if (c == ';') {
        ck = HCFS_SEMI;
        k = c;
    } else if (c == ':') {
        if (c2 == ':')
            m = 2;
        else {
            ck = HCFS_COLON;
            k = c;
        }
    } else if (c == ',')
        ck = HCFS_COMMA;
    else if (c == '.') {
        if (c2 == '.' && c3 == '.') {
            m = 3;
            ck = HCFS_ELL;
        } else
            ck = HCFS_DOT;
    } else if (c == '-' && c2 == '>') {
        m = 2;
        ck = HCFS_DOT;
    } else if ((c == '+' || c == '-') && c2 == c) {
        m = 2;
        if (HCFOperandEnd(s->pk))
            ck = HCFS_POST;
        else
            ck = HCFS_PRE;
    } else if (c2 == '=' && (c == '+' || c == '-' || c == '*' || c == '/' || c == '%' ||
                             c == '&' || c == '|' || c == '^' || c == '<' || c == '>' || c == '=' || c == '!' ||
                             c == '`')) {
        m = 2;
        ck = HCFS_BIN;
    } else if (c2 == c && (c == '&' || c == '|' || c == '^' || c == '<' || c == '>')) {
        m = 2;
        if ((c == '<' || c == '>') && c3 == '=')
            m = 3;
        ck = HCFS_BIN;
    } else if (c == '=' || c == '<' || c == '>' || c == '/' || c == '%' || c == '|' ||
               c == '^' || c == '`')
        ck = HCFS_BIN;
    else if (c == '!' || c == '~')
        ck = HCFS_UN;
    else if (c == '-' || c == '+' || c == '*' || c == '&') {
        if (HCFOperandEnd(s->pk))
            ck = HCFS_BIN;
        else
            ck = HCFS_UN;
        if (c == '*') {
            if (s->pk == HCFS_TYPE || s->pk == HCFS_PTR)
                ck = HCFS_PTR;
            else if (s->pk == HCFS_CLSD) {
                // a declarator if a name (or more stars) follows, else a product
                j = i + 1;
                while (j < n && HCFIsWs(ls[j]))
                    j++;
                if (j >= n || (HCFIsId(ls[j]) && !HCFIsDigit(ls[j])) || ls[j] == '*' ||
                        ls[j] == ')' || ls[j] == ',')
                    ck = HCFS_PTR;
            }
        }
    }
    hd = s->hdr;
    HCFOut(s, ls, i, m, ck);
    HCFTok(s, k, ls + i, m);
    if (ck == HCFS_CLOSE && hd && !s->hdr)
        ck = HCFS_HDR;  // the body of the if/while/for/switch starts here
    HCFPk(s, ck, ls[i + m - 1]);
    return m;
}

// Scan ls[i,n) of one line, feeding tokens to HCFTok and the line buffer.
// Starts in the string or block comment state left by the previous line.
U0 HCFScan(CHCFmt *s, U8 *ls, I64 i, I64 n)
{
    I64 c, j, k, t, ck;
    while (i < n) {
        c = ls[i];
        if (s->in_bc) {
            j = i;
            while (i < n && !(ls[i] == '*' && i + 1 < n && ls[i + 1] == '/'))
                i++;
            if (i < n) {
                s->in_bc = FALSE;
                i += 2;
            }
            HCFRaw(s, ls, j, i);
            s->lastcmt = TRUE;
        } else if (s->in_str) {
            j = i;
            while (i < n && ls[i] != '"') {
                if (ls[i] == '\\')
                    i++;
                i++;
            }
            if (i < n) {
                s->in_str = FALSE;
                i++;
            } else
                i = n;
            HCFRaw(s, ls, j, i);
        } else if (HCFIsWs(c))
            i++;
        else if (c == '/' && i + 1 < n && ls[i + 1] == '/') {
            HCFOut(s, ls, i, n - i, HCFS_CMT);
            i = n;
        } else if (c == '/' && i + 1 < n && ls[i + 1] == '*') {
            HCFOut(s, ls, i, 2, HCFS_CMT);
            s->in_bc = TRUE;
            i += 2;
        } else if (c == '"') {
            HCFOut(s, ls, i, 1, HCFS_STR);
            HCFTok(s, 's', ls + i, 1);
            HCFPk(s, HCFS_STR, c);
            s->in_str = TRUE;
            i++;
        } else if (c == '\'') {
            j = i + 1;
            while (j < n && ls[j] != '\'') {
                if (ls[j] == '\\')
                    j++;
                j++;
            }
            if (j < n) {
                HCFOut(s, ls, i, j + 1 - i, HCFS_STR);
                HCFTok(s, 'c', ls + i, j + 1 - i);
                HCFPk(s, HCFS_STR, c);
                i = j + 1;
            } else {
                HCFOut(s, ls, i, 1, HCFS_UNK);
                HCFTok(s, 'o', ls + i, 1);
                HCFPk(s, HCFS_UNK, c);
                i++;
            }
        } else if (HCFIsId(c) || (c == '.' && i + 1 < n && HCFIsDigit(ls[i + 1]) &&
                                  !HCFOperandEnd(s->pk) && s->pk != HCFS_DOT)) {
            j = i;
            if (HCFIsDigit(c) || c == '.')
                j = HCFNumEnd(ls, i, n);
            else
                while (j < n && HCFIsId(ls[j]))
                    j++;
            k = j;
            while (k < n && (ls[k] == ' ' || ls[k] == '\t'))
                k++;
            t = 0;
            if (k < n && ls[k] == ':' && !HCFIsDigit(ls[i]) && ls[i] != '.' && !s->in_stmt &&
                    !s->pd) {
                if (k + 1 >= n || ls[k + 1] != ':')
                    t = 1;
                else if (s->nf && s->kind[s->nf - 1] == HCF_ASM)
                    t = 2;
            }
            if (t) {
                // label: the name and its colon(s) are joined
                HCFOut(s, ls, i, j - i, HCFS_ID);
                HCFLbPut(s, "::", t);
                s->lend = k + t;
                HCFTok(s, 'L', ls + i, k + t - i);
                HCFPk(s, HCFS_COLON, ':');
                i = k + t;
            } else {
                ck = HCFWordClass(s, ls + i, j - i);
                HCFOut(s, ls, i, j - i, ck);
                HCFTok(s, 'i', ls + i, j - i);
                HCFPk(s, ck, ls[j - 1]);
                i = j;
            }
        } else
            i += HCFPunct(s, ls, i, n);
    }
}

//---- driver

U0 HCFEmit(CHCFmt *s, I64 ind, U8 *p, I64 n)
{
    I64 i;
    for (i = 0; i < ind; i++)
        HCFPutCh(s, ' ');
    HCFPut(s, p, n);
    HCFPutCh(s, '\n');
    s->last_blank = FALSE;
}

// The line buffer without trailing whitespace (kept inside an open string).
I64 HCFLineEnd(CHCFmt *s)
{
    I64 e = s->lblen;
    if (!s->in_str)
        while (e > 0 && HCFIsWs(s->lb[e - 1]))
            e--;
    return e;
}

U0 HCFLine(CHCFmt *s, U8 *ls, I64 n)
{
    I64 q = 0, e, st, spk, splc;
    while (n > 0 && ls[n - 1] == '\r')
        n--;
    if (s->in_str)
        st = 1;
    else if (s->in_bc)
        st = 2;
    else
        st = 0;
    s->lblen = 0;
    s->lend = -1;
    s->lastcmt = FALSE;
    if (st) {
        s->need_ind = FALSE;
        s->ind = 0;
        HCFScan(s, ls, 0, n);
        HCFEmit(s, 0, s->lb, HCFLineEnd(s));
        return;
    }
    while (q < n && HCFIsWs(ls[q]))
        q++;
    if (q == n) {
        if (!s->last_blank) {
            HCFPutCh(s, '\n');
            s->last_blank = TRUE;
        }
        return;
    }
    s->need_ind = TRUE;
    s->ind = 0;
    if (ls[q] == '#') {
        // Preprocessor line: kept as found. #exe {...} holds real code, lex it;
        // other directives are only lexed for quotes. Spacing state is not kept.
        spk = s->pk;
        splc = s->plc;
        s->need_ind = FALSE;
        if (n - q >= 4 && ls[q + 1] == 'e' && ls[q + 2] == 'x' && ls[q + 3] == 'e' && !HCFIsId(ls[q + 4]))
            HCFScan(s, ls, q + 4, n);
        else {
            s->nostate = TRUE;
            HCFScan(s, ls, q + 1, n);
            s->nostate = FALSE;
        }
        s->pk = spk;
        s->plc = splc;
        e = n;
        if (!s->in_str)
            while (e > q && HCFIsWs(ls[e - 1]))
                e--;
        HCFEmit(s, 0, ls + q, e - q);
        return;
    }
    HCFScan(s, ls, q, n);
    if (s->need_ind) {  // no code on this line: a comment
        s->need_ind = FALSE;
        s->ind = HCFPeekLevel(s);
    }
    HCFEmit(s, s->ind, s->lb, HCFLineEnd(s));
}

// Non-whitespace characters identical?
Bool HCFSameTokens(U8 *a, U8 *b)
{
    while (TRUE) {
        while (*a && HCFIsWs(*a))
            a++;
        while (*b && HCFIsWs(*b))
            b++;
        if (*a != *b)
            return FALSE;
        if (!*a)
            return TRUE;
        a++;
        b++;
    }
}

U8 *HCFmt(U8 *src)
{
    CHCFmt *s = MAlloc(sizeof(CHCFmt));
    U8 *res, *p, *ls;
    I64 i;
    MemSet(s, 0, sizeof(CHCFmt));
    s->lbcap = 256;
    s->lb = MAlloc(s->lbcap);
    HCFFindClasses(s, src);
    hcfmt_err = 0;
    hcfmt_warn = 0;
    s->ocap = StrLen(src) * 2 + 64;
    s->out = MAlloc(s->ocap);
    s->out[0] = 0;
    s->last_blank = TRUE;  // no blank lines at the start
    p = src;
    while (*p) {
        ls = p;
        while (*p && *p != '\n')
            p++;
        HCFLine(s, ls, p - ls);
        if (*p)
            p++;
    }
    if (s->pd || s->in_str || s->in_bc)
        hcfmt_warn = 1;
    for (i = 0; i < s->nf; i++)
        if (s->kind[i] == HCF_BLOCK || s->kind[i] == HCF_INIT || s->kind[i] == HCF_ASM)
            hcfmt_warn = 1;
    while (s->olen > 1 && s->out[s->olen - 1] == '\n' && s->out[s->olen - 2] == '\n') {
        s->olen--;
        s->out[s->olen] = 0;
    }
    res = s->out;
    Free(s->lb);
    Free(s);
    if (!HCFSameTokens(src, res)) {
        hcfmt_err = 1;
        Free(res);
        res = MAlloc(StrLen(src) + 1);
        MemCpy(res, src, StrLen(src) + 1);
    }
    return res;
}
