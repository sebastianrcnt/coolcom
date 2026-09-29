// What the backend needs from its host (the C runtime, in Aiwnios), kept
// private to the backend. The port calls these B-prefixed names instead of
// the host's Fs/HashFind/..., so it behaves the same inside the Aiwnios
// runtime (for differential testing) and inside the CoolC kernel.

#define BHASH_SIZE 64

CBHashTable *BHashTableNew(I64 size)
{//size must be a power of two.
  CBHashTable *t=CAlloc(sizeof(CBHashTable));
  t->mask=size-1;
  t->body=CAlloc(size*sizeof(CBHash *));
  return t;
}

I64 BHashStr(U8 *s)
{
  I64 h=0;
  while (*s)
    h=(h<<5)+h+*s++;
  return h;
}

CBHash *BHashFind(U8 *str,CBHashTable *t,I64 type,I64 inst=1)
{//Like TempleOS HashFind: inst-th match of any of the type bits, searching parent tables too.
  CBHash *h;
  I64 hs=BHashStr(str);
  while (t) {
    h=t->body[hs&t->mask];
    while (h) {
      if ((h->type&type) && !StrCmp(h->str,str)) {
	if (!--inst)
	  return h;
      }
      h=h->next;
    }
    t=t->next;
  }
  return NULL;
}

U0 BHashAdd(CBHash *h,CBHashTable *t)
{
  CBHash **bucket=&t->body[BHashStr(h->str)&t->mask];
  h->next=*bucket;
  *bucket=h;
}

CBHeapCtrl *BHeapCtrlInit(CBHeapCtrl *ct,CBTask *task,I64 is_code_heap)
{//The port allocates with MAlloc/Free; heap controls are only tokens.
  if (!ct)
    ct=CAlloc(sizeof(CBHeapCtrl));
  ct->mem_task=task;
  ct->is_code_heap=is_code_heap;
  return ct;
}

U0 BHeapCtrlDel(CBHeapCtrl *ct)
{//PORT-NOTE: the C heap control frees all its allocations at once; here
//they are only freed individually, so a compile may leak what C would reclaim.
  Free(ct);
}

I64 BSetWriteNP(I64 n)
{//Apple W^X toggle in the C runtime; code memory is always writable here.
  return n;
}

I64 BDoNothing()
{
  return 0;
}

I64 BFFICall2(U8 *fptr,I64 a,I64 b)
{
  I64 (*fp)(I64 a,I64 b);
  fp=fptr;  // declare and assign separately: an initializer here doesn't parse
  return (*fp)(a,b);
}

F64 BFMod(F64 a,F64 b)
{
  return a%b;
}

#ifdef BACKEND_STANDALONE
extern F64 Pow(F64 base,F64 power);  //INTEGRATION: the kernel must provide Pow (libm pow-exact)
#endif

F64 BPow(F64 a,F64 b)
{
  return Pow(a,b);
}

I64 ParseErr(CBCmpCtrl *ctrl,U8 *fmt,...)
{//The C parser's error report; the frontend normally catches these first.
  Print("backend: error: %s\n",fmt);
  return 0;
}

I64 ParseWarn(CBCmpCtrl *ctrl,U8 *fmt,...)
{
  Print("backend: warning: %s\n",fmt);
  return 0;
}

CBTask b_task;
CBTask *BFs=&b_task;
b_task.hash_table=BHashTableNew(BHASH_SIZE);
b_task.heap=BHeapCtrlInit(NULL,BFs,FALSE);
b_task.code_heap=BHeapCtrlInit(NULL,BFs,TRUE);
