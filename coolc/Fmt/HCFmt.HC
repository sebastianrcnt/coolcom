// HolyC source formatter: an indentation and whitespace normalizer.
//   U8 *HCFmt(U8 *src)  returns a new MAlloc'ed string, the caller frees it.
// Pure string -> string, no I/O. Needs only MAlloc, Free, MemCpy, MemSet, StrLen.
//
// It rewrites leading whitespace (2 spaces per level), strips trailing
// whitespace, collapses runs of blank lines to one and ends the text with a
// single newline. Everything else on a line is kept byte for byte, and lines
// are never split or joined. Strings, char literals, comments, preprocessor
// lines and asm blocks are lexed so their contents are never touched.
// The output is verified to hold the same non-whitespace characters as the
// input; if not, a copy of the input is returned and hcfmt_err is set.
//
// After a call: hcfmt_err is 0 (ok) or 1 (token check failed, input returned),
// hcfmt_warn is 0 or 1 (unbalanced braces/quotes/comment: output may be off).

#define HCF_MAX    256
#define HCF_INDENT 2
#define HCF_PALIGN_MAX 40  // max paren alignment past the statement indent

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

I64 hcfmt_err,hcfmt_warn;

class CHCFmt
{
  U8 *out;
  I64 olen,ocap,last_blank;
  I64 nf;
  I64 kind[HCF_MAX],base[HCF_MAX],flag[HCF_MAX],spd[HCF_MAX];
  I64 pcol[HCF_MAX],pn;
  U8 *lq;
  I64 pd,in_stmt,want,pend,hdr,dotail,pendsw,isenum,asm_next,incase;
  I64 in_bc,in_str,need_ind,ind,prev,nostate;
};

Bool HCFIsWs(I64 c)
{
  return c==' ' || c=='\t' || c=='\r' || c=='\n' || c==11 || c==12;
}

Bool HCFIsId(I64 c)
{
  return (c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') ||
      c=='_' || c=='@';
}

Bool HCFStrEq(U8 *p,I64 n,U8 *s)
{
  I64 i;
  for (i=0;i<n;i++)
    if (p[i]!=s[i] || !s[i])
      return FALSE;
  return !s[n];
}

I64 HCFKw(U8 *p,I64 n)
{
  if (n<2 || n>7)
    return 0;
  if (HCFStrEq(p,n,"if"))
    return HCFK_IF;
  if (HCFStrEq(p,n,"else"))
    return HCFK_ELSE;
  if (HCFStrEq(p,n,"while"))
    return HCFK_WHILE;
  if (HCFStrEq(p,n,"for"))
    return HCFK_FOR;
  if (HCFStrEq(p,n,"do"))
    return HCFK_DO;
  if (HCFStrEq(p,n,"switch"))
    return HCFK_SWITCH;
  if (HCFStrEq(p,n,"case"))
    return HCFK_CASE;
  if (HCFStrEq(p,n,"default"))
    return HCFK_DEFAULT;
  if (HCFStrEq(p,n,"try"))
    return HCFK_TRY;
  if (HCFStrEq(p,n,"catch"))
    return HCFK_CATCH;
  if (HCFStrEq(p,n,"asm"))
    return HCFK_ASM;
  if (HCFStrEq(p,n,"enum"))
    return HCFK_ENUM;
  if (HCFStrEq(p,n,"start") || HCFStrEq(p,n,"end"))
    return HCFK_START;
  return 0;
}

//---- output buffer

U0 HCFPut(CHCFmt *s,U8 *p,I64 n)
{
  U8 *t;
  if (s->olen+n+1>s->ocap) {
    s->ocap=(s->olen+n+1)*2;
    t=MAlloc(s->ocap);
    if (s->olen)
      MemCpy(t,s->out,s->olen);
    Free(s->out);
    s->out=t;
  }
  if (n)
    MemCpy(s->out+s->olen,p,n);
  s->olen+=n;
  s->out[s->olen]=0;
}

U0 HCFPutCh(CHCFmt *s,I64 c)
{
  U8 b[2];
  b[0]=c;
  b[1]=0;
  HCFPut(s,b,1);
}

//---- indentation state

// Indent level of the first n frames.
I64 HCFLevelN(CHCFmt *s,I64 n)
{
  I64 i,k,lvl=0;
  for (i=0;i<n;i++) {
    k=s->kind[i];
    if (k==HCF_BLOCK || k==HCF_CASE || k==HCF_ASM)
      lvl++;
    else if (k>=HCF_IF && k<=HCF_DO && !s->flag[i])
      lvl++;
  }
  return lvl;
}

I64 HCFLevel(CHCFmt *s)
{
  return HCFLevelN(s,s->nf);
}

I64 HCFInitDepth(CHCFmt *s)
{
  I64 i,d=0;
  for (i=0;i<s->nf;i++)
    if (s->kind[i]==HCF_INIT)
      d++;
  return d;
}

// Indent of a continuation line of the current statement.
I64 HCFCont(CHCFmt *s)
{
  I64 d=HCFInitDepth(s);
  if (d<1)
    d=2;  // flat continuation: two levels
  return HCFLevel(s)+d;
}

// Continuation in spaces: align under the innermost open paren when it is
// on the same scope and not too far right, else the flat indent.
I64 HCFContCol(CHCFmt *s)
{
  I64 flat=HCFCont(s)*HCF_INDENT,col;
  if (s->pd>0 && s->pn>0) {
    col=s->pcol[s->pn-1];
    if (col>=flat && col<=HCFLevel(s)*HCF_INDENT+HCF_PALIGN_MAX)
      return col;
  }
  return flat;
}

// Indent for a comment-only line: as if a statement token came next.
I64 HCFPeekLevel(CHCFmt *s)
{
  I64 n=s->nf;
  if (s->pend) {
    while (n>0 && s->kind[n-1]>=HCF_IF && s->kind[n-1]<=HCF_DO)
      n--;
    return HCFLevelN(s,n)*HCF_INDENT;
  }
  if (s->in_stmt || s->pd>0)
    return HCFContCol(s);
  return HCFLevel(s)*HCF_INDENT;
}

U0 HCFPush(CHCFmt *s,I64 kind,I64 flag)
{
  if (s->nf<HCF_MAX) {
    s->kind[s->nf]=kind;
    s->base[s->nf]=HCFLevel(s);
    s->flag[s->nf]=flag;
    s->spd[s->nf]=0;
    s->nf++;
  } else
    hcfmt_warn=1;
}

// A statement just ended: finish the constructs it completed.
U0 HCFComplete(CHCFmt *s)
{
  I64 k;
  s->in_stmt=FALSE;
  s->pend=FALSE;
  s->want=FALSE;
  s->incase=FALSE;
  while (s->nf) {
    k=s->kind[s->nf-1];
    if (k==HCF_IF || k==HCF_DO) {
      s->pend=TRUE;  // an else / while may follow
      return;
    }
    if (k==HCF_ELSE || k==HCF_LOOP)
      s->nf--;
    else
      return;
  }
}

//---- token handler

// Set the indent of the line's first token (in levels).
U0 HCFSetInd(CHCFmt *s,I64 ind)
{
  if (s->need_ind) {
    s->ind=ind*HCF_INDENT;
    s->need_ind=FALSE;
  }
}

U0 HCFSetCont(CHCFmt *s)
{
  if (s->need_ind) {
    s->ind=HCFContCol(s);
    s->need_ind=FALSE;
  }
}

// k: 'i' word/number, 'L' label ("name:"), 's' string, 'c' char, 'o' other
// punctuation, or one of ( ) [ ] { } ; :
U0 HCFTok(CHCFmt *s,I64 k,U8 *p,I64 n)
{
  I64 kw=0,top,isel,iswh,init,i,d;
  if (s->nostate)
    return;
  if (s->nf && s->kind[s->nf-1]==HCF_ASM) {
    top=s->nf-1;
    if (k=='{') {
      HCFSetInd(s,HCFLevel(s));
      s->flag[top]++;
    } else if (k=='}') {
      if (s->flag[top]>0) {
        HCFSetInd(s,HCFLevel(s));
        s->flag[top]--;
      } else {
        s->nf--;
        HCFSetInd(s,HCFLevel(s));
        HCFComplete(s);
      }
    } else if (k=='L')
      HCFSetInd(s,HCFLevel(s)-1);
    else
      HCFSetInd(s,HCFLevel(s));
    return;
  }
  if (k=='i' || k=='L') {
    i=n;
    if (k=='L') {
      i=0;
      while (HCFIsId(p[i]))
        i++;
    }
    kw=HCFKw(p,i);
  }
  isel=(kw==HCFK_ELSE || kw==HCFK_CATCH) && k=='i';
  iswh=kw==HCFK_WHILE && k=='i';
  // finish constructs that a token other than else/while completes
  if (s->pd==0)
    while (s->pend) {
      top=s->nf-1;
      if (isel && s->kind[top]==HCF_IF)
        break;
      if (iswh && s->kind[top]==HCF_DO)
        break;
      s->nf--;
      HCFComplete(s);
    }
  if (s->pend && s->pd==0) {
    top=s->nf-1;
    HCFSetInd(s,s->base[top]);
    if (isel) {
      s->kind[top]=HCF_ELSE;
      s->flag[top]=0;
      s->want=TRUE;
      s->pend=FALSE;
      s->in_stmt=FALSE;
    } else {
      s->nf--;
      s->pend=FALSE;
      s->dotail=TRUE;
      s->in_stmt=TRUE;
    }
    s->prev='x';
    return;
  }
  // a construct header is complete and waits for its body
  if (s->want) {
    s->want=FALSE;
    top=s->nf-1;
    if (k=='{')
      s->flag[top]=1;
    else if (kw==HCFK_IF && k=='i' && s->kind[top]==HCF_ELSE)
      s->nf--;  // else if: one chain, one level
  }
  if (k=='}') {
    while (s->nf && s->kind[s->nf-1]!=HCF_BLOCK && s->kind[s->nf-1]!=HCF_INIT)
      s->nf--;
    if (s->nf && s->kind[s->nf-1]==HCF_INIT) {
      d=HCFInitDepth(s);
      HCFSetInd(s,HCFLevel(s)+d-1);
      s->pd=s->spd[s->nf-1];
      s->nf--;
    } else {
      if (s->nf)
        s->nf--;
      HCFSetInd(s,HCFLevel(s));
      HCFComplete(s);
    }
    s->prev='}';
    return;
  }
  if (k=='{') {
    init=s->pd>0 || s->isenum || s->prev=='=' || s->prev==',' || s->prev=='(' ||
        s->prev=='[' || (s->nf && s->kind[s->nf-1]==HCF_INIT);
    if (init) {
      HCFSetCont(s);
      HCFPush(s,HCF_INIT,0);
      s->spd[s->nf-1]=s->pd;
      s->pd=0;
      s->in_stmt=TRUE;
      s->isenum=FALSE;
    } else {
      HCFSetInd(s,HCFLevel(s));
      if (s->asm_next)
        HCFPush(s,HCF_ASM,0);
      else
        HCFPush(s,HCF_BLOCK,s->pendsw);
      s->asm_next=FALSE;
      s->pendsw=FALSE;
      s->in_stmt=FALSE;
    }
    s->prev='{';
    return;
  }
  if (k=='(' || k=='[') {
    if (s->in_stmt || s->pd>0)
      HCFSetCont(s);
    else
      HCFSetInd(s,HCFLevel(s));
    if (s->pn<HCF_MAX) {
      s->pcol[s->pn]=s->ind+(p-s->lq)+1;
      s->pn++;
    }
    s->pd++;
    s->in_stmt=TRUE;
    s->prev='(';
    return;
  }
  if (k==')' || k==']') {
    HCFSetCont(s);
    if (s->pd>0) {
      s->pd--;
      if (s->pn>0)
        s->pn--;
    }
    if (s->pd==0 && s->hdr) {
      s->in_stmt=FALSE;
      if (s->hdr==HCFK_IF)
        HCFPush(s,HCF_IF,0);
      else
        HCFPush(s,HCF_LOOP,0);
      if (s->hdr==HCFK_SWITCH)
        s->pendsw=TRUE;
      s->hdr=0;
      s->want=TRUE;
    }
    s->prev=')';
    return;
  }
  if (k==';') {
    if (s->in_stmt || s->pd>0)
      HCFSetCont(s);
    else
      HCFSetInd(s,HCFLevel(s));
    if (s->pd==0 && !(s->nf && s->kind[s->nf-1]==HCF_INIT)) {
      s->isenum=FALSE;
      s->dotail=FALSE;
      s->asm_next=FALSE;
      HCFComplete(s);
    }
    s->prev=';';
    return;
  }
  if (k==':') {
    HCFSetCont(s);
    if (s->incase && s->pd==0) {
      HCFPush(s,HCF_CASE,0);
      s->incase=FALSE;
      s->in_stmt=FALSE;
    }
    s->prev=':';
    return;
  }
  // words, strings and other tokens
  if (k=='L') {
    if (kw==HCFK_DEFAULT || kw==HCFK_CASE || kw==HCFK_START) {
      if (s->nf && s->kind[s->nf-1]==HCF_CASE)
        s->nf--;
      HCFSetInd(s,HCFLevel(s));
      HCFPush(s,HCF_CASE,0);
    } else
      HCFSetInd(s,0);  // goto label
    s->in_stmt=FALSE;
    s->prev=':';
    return;
  }
  if (s->in_stmt || s->pd>0)
    HCFSetCont(s);
  else {
    if (kw==HCFK_CASE && k=='i' && s->nf && s->kind[s->nf-1]==HCF_CASE)
      s->nf--;
    HCFSetInd(s,HCFLevel(s));
  }
  if (!s->in_stmt && k=='i') {
    if (kw==HCFK_IF || kw==HCFK_FOR || kw==HCFK_SWITCH || kw==HCFK_WHILE) {
      if (kw==HCFK_WHILE && s->dotail)
        s->hdr=0;
      else
        s->hdr=kw;
      s->in_stmt=TRUE;
      s->prev='x';
      return;
    }
    if (kw==HCFK_DO || kw==HCFK_TRY) {
      if (kw==HCFK_DO)
        HCFPush(s,HCF_DO,0);
      else
        HCFPush(s,HCF_IF,0);
      s->want=TRUE;
      s->prev='x';
      return;
    }
    if (kw==HCFK_CASE)
      s->incase=TRUE;
    else if (kw==HCFK_ENUM)
      s->isenum=TRUE;
    else if (kw==HCFK_ASM)
      s->asm_next=TRUE;
  }
  s->in_stmt=TRUE;
  if (k=='o')
    s->prev=p[0];
  else
    s->prev='x';
}

//---- lexer

// Scan ls[i,n) of one line, feeding tokens to HCFTok. Starts in the string or
// block comment state left by the previous line.
U0 HCFScan(CHCFmt *s,U8 *ls,I64 i,I64 n)
{
  I64 c,j,k,t;
  while (i<n) {
    c=ls[i];
    if (s->in_bc) {
      while (i<n && !(ls[i]=='*' && i+1<n && ls[i+1]=='/'))
        i++;
      if (i<n) {
        s->in_bc=FALSE;
        i+=2;
      }
    } else if (s->in_str) {
      while (i<n && ls[i]!='"') {
        if (ls[i]=='\\')
          i++;
        i++;
      }
      if (i<n) {
        s->in_str=FALSE;
        i++;
      }
    } else if (HCFIsWs(c))
      i++;
    else if (c=='/' && i+1<n && ls[i+1]=='/')
      i=n;
    else if (c=='/' && i+1<n && ls[i+1]=='*') {
      s->in_bc=TRUE;
      i+=2;
    } else if (c=='"') {
      HCFTok(s,'s',ls+i,1);
      s->in_str=TRUE;
      i++;
    } else if (c=='\'') {
      j=i+1;
      while (j<n && ls[j]!='\'') {
        if (ls[j]=='\\')
          j++;
        j++;
      }
      if (j<n) {
        HCFTok(s,'c',ls+i,j+1-i);
        i=j+1;
      } else {
        HCFTok(s,'o',ls+i,1);
        i++;
      }
    } else if (HCFIsId(c)) {
      j=i;
      while (j<n && HCFIsId(ls[j]))
        j++;
      k=j;
      while (k<n && (ls[k]==' ' || ls[k]=='\t'))
        k++;
      t=0;
      if (k<n && ls[k]==':' && (ls[i]<'0' || ls[i]>'9') && !s->in_stmt && !s->pd) {
        if (k+1>=n || ls[k+1]!=':')
          t=1;
        else if (s->nf && s->kind[s->nf-1]==HCF_ASM)
          t=2;
      }
      if (t==1) {
        HCFTok(s,'L',ls+i,k+1-i);
        i=k+1;
      } else if (t==2) {
        HCFTok(s,'L',ls+i,k+2-i);
        i=k+2;
      } else {
        HCFTok(s,'i',ls+i,j-i);
        i=j;
      }
    } else if (c=='(' || c==')' || c=='[' || c==']' || c=='{' || c=='}' || c==';') {
      HCFTok(s,c,ls+i,1);
      i++;
    } else if (c==':') {
      if (i+1<n && ls[i+1]==':') {
        HCFTok(s,'o',ls+i,2);
        i+=2;
      } else {
        HCFTok(s,':',ls+i,1);
        i++;
      }
    } else {
      HCFTok(s,'o',ls+i,1);
      i++;
    }
  }
}

//---- driver

U0 HCFEmit(CHCFmt *s,I64 ind,U8 *p,I64 n)
{
  I64 i;
  for (i=0;i<ind;i++)
    HCFPutCh(s,' ');
  HCFPut(s,p,n);
  HCFPutCh(s,'\n');
  s->last_blank=FALSE;
}

U0 HCFLine(CHCFmt *s,U8 *ls,I64 n)
{
  I64 q=0,e,st,ind;
  while (n>0 && ls[n-1]=='\r')
    n--;
  if (s->in_str)
    st=1;
  else if (s->in_bc)
    st=2;
  else
    st=0;
  if (st) {
    s->need_ind=FALSE;
    s->ind=0;
    s->lq=ls;
    HCFScan(s,ls,0,n);
    e=n;
    if (!s->in_str)
      while (e>0 && HCFIsWs(ls[e-1]))
        e--;
    HCFEmit(s,0,ls,e);
    return;
  }
  while (q<n && HCFIsWs(ls[q]))
    q++;
  if (q==n) {
    if (!s->last_blank) {
      HCFPutCh(s,'\n');
      s->last_blank=TRUE;
    }
    return;
  }
  s->need_ind=TRUE;
  s->ind=0;
  s->lq=ls+q;
  if (ls[q]=='#') {
    // #exe {...} holds real code, lex it; other directives only for quotes
    s->need_ind=FALSE;
    ind=0;
    if (n-q>=4 && ls[q+1]=='e' && ls[q+2]=='x' && ls[q+3]=='e' && !HCFIsId(ls[q+4]))
      HCFScan(s,ls,q+4,n);
    else {
      s->nostate=TRUE;
      HCFScan(s,ls,q+1,n);
      s->nostate=FALSE;
    }
  } else {
    HCFScan(s,ls,q,n);
    if (s->need_ind) {  // no code on this line: a comment
      s->need_ind=FALSE;
      s->ind=HCFPeekLevel(s);
    }
    ind=s->ind;
  }
  e=n;
  if (!s->in_str)
    while (e>q && HCFIsWs(ls[e-1]))
      e--;
  HCFEmit(s,ind,ls+q,e-q);
}

// Non-whitespace characters identical?
Bool HCFSameTokens(U8 *a,U8 *b)
{
  while (TRUE) {
    while (*a && HCFIsWs(*a))
      a++;
    while (*b && HCFIsWs(*b))
      b++;
    if (*a!=*b)
      return FALSE;
    if (!*a)
      return TRUE;
    a++;
    b++;
  }
}

U8 *HCFmt(U8 *src)
{
  CHCFmt *s=MAlloc(sizeof(CHCFmt));
  U8 *res,*p,*ls;
  I64 i;
  MemSet(s,0,sizeof(CHCFmt));
  hcfmt_err=0;
  hcfmt_warn=0;
  s->ocap=StrLen(src)*2+64;
  s->out=MAlloc(s->ocap);
  s->out[0]=0;
  s->last_blank=TRUE;  // no blank lines at the start
  p=src;
  while (*p) {
    ls=p;
    while (*p && *p!='\n')
      p++;
    HCFLine(s,ls,p-ls);
    if (*p)
      p++;
  }
  if (s->pd || s->in_str || s->in_bc)
    hcfmt_warn=1;
  for (i=0;i<s->nf;i++)
    if (s->kind[i]==HCF_BLOCK || s->kind[i]==HCF_INIT || s->kind[i]==HCF_ASM)
      hcfmt_warn=1;
  while (s->olen>1 && s->out[s->olen-1]=='\n' && s->out[s->olen-2]=='\n') {
    s->olen--;
    s->out[s->olen]=0;
  }
  res=s->out;
  Free(s);
  if (!HCFSameTokens(src,res)) {
    hcfmt_err=1;
    Free(res);
    res=MAlloc(StrLen(src)+1);
    MemCpy(res,src,StrLen(src)+1);
  }
  return res;
}
