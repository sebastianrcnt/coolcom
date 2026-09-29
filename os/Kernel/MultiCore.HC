// Secondary core bring-up via PSCI.
#define CORES_MAX     4
#define AP_STACK_SIZE (64*1024)
#define PSCI_INVALID_PARAMS (-2)

class CCPU
{
  I64 num;
  Bool online;
  U8 *stack;
};

CCPU cpu_structs[CORES_MAX];
I64 mp_cnt=1;  // cores online

CCPU *Gs()
{//This core's CCPU.
  return ArchTpidr;
}

U0 CoreInit(I64 num)
{//Common per-core init, runs on the core itself.
  CCPU *c=&cpu_structs[num];
  c->num=num;
  ArchTpidrSet(c);
  GicCpuInit;
}

U0 KMainAP(I64 num)
{//Secondary cores start here (from Boot.S).
  CoreInit(num);
  "Core %d online\n",num;
  cpu_structs[num].online=TRUE;
  ArchAdd(&mp_cnt,1);
  while (TRUE)
    ArchWfi;
}

U0 MPStart(I64 cnt)
{//Start cores 1..cnt-1 and wait for them.
  I64 i,r,t;
  CCPU *c;
  for (i=1;i<cnt && i<CORES_MAX;i++) {
    c=&cpu_structs[i];
    c->stack=MAlloc(AP_STACK_SIZE);
    r=ArchPsciCpuOn(i,ArchApEntry,c->stack+AP_STACK_SIZE);
    if (r==PSCI_INVALID_PARAMS) {  // no such core
      Free(c->stack);
      break;
    }
    if (r) {
      "Core %d: PSCI CPU_ON failed (%d)\n",i,r;
      goto mp_next;
    }
    t=jiffies+1000;
    while (!c->online && jiffies<t)
      ArchWfi;
    if (!c->online)
      "Core %d: no response\n",i;
mp_next:
  }
}
