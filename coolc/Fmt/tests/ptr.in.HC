U8 *p;
U8* q;
U8 * r;
U8 **s;
U8 * * t;
I64 *a,*b,c;
CTask *task;
CTask **tasks;
CBRPN *rpn;
CBRPN * *rpn2;
extern CMemBlk *blk;
extern U8 *names[];
public I64 *pub;
class CFoo
{
  CFoo *next,*prev;
  U8 *name;
  I64 n;
};
U8 *Foo(CFoo *f,U8 *s,I64 **pp,U0 *v)
{
  CFoo *g=f->next;
  U8 *t=s;
  I64 n=sizeof(CFoo)*2;
  I64 m=CLSF_VARGS * 4;
  x=y(U8 *);
  x=y(I64);
  x=y( CFoo * );
  x=y(U8 **)+1;
  x=a[i](U8 *)+n;
  n=sizeof(U8 *);
  n=sizeof(CFoo *);
  n=offset(CFoo.name);
  for (g=f;g;g=g->next)
    n++;
  for (CFoo *h=f;h;h=h->next)
    n++;
  return g;
}
U0 Fn(U0 (*fp)(I64 x),U8 *,I64,...)
{
  fp(1);
}
Bool Cb(I64 x)
{
  F64 *f=&d;
  U16 *w;
  I32i *r;
  U64i *u;
  CDate *dt;
  CO2 *o;
  CBIG * 2;
}
