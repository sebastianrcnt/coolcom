// Interface to the assembly in Arch.S.

import I64 ArchCntFrq();           // counter frequency, Hz
import I64 ArchCntVct();           // virtual counter
import U0 ArchCntvTvalSet(I64 t);  // virtual timer: fire t counts from now
import U0 ArchCntvCvalSet(I64 t);  // virtual timer: fire when the counter reaches t
import U0 ArchCntvCtlSet(I64 v);   // virtual timer control (1=enable)
import I64 ArchMpidr();
import I64 ArchDaif();
import U0 ArchIrqOn();
import U0 ArchIrqOff();
import U0 ArchWfi();
import U0 ArchWfe();
import U0 ArchSev();
import I64 ArchTpidr();
import U0 ArchTpidrSet(I64 v);
import I64 ArchCpuNum();
import I64 ArchXchg(I64 *p,I64 v);          // atomic swap, returns old
import I64 ArchCas(I64 *p,I64 old,I64 new); // compare-and-swap, returns seen
import I64 ArchAdd(I64 *p,I64 v);           // atomic add, returns new
import U0 ArchStoreRel(I64 *p,I64 v);       // store-release + sev
import I64 ArchPsciCpuOn(I64 mpidr,U8 *entry,I64 ctx);
import U8 *ArchApEntry();

// Saved by the exception entry in Arch.S; layout must match FR_* there.
class CExceptFrame
{
  I64 x[31];
  I64 elr,spsr,esr,far,vec;
  U8 q[32*16];
};

#define EXC_CUR_SPX_SYNC 4
#define EXC_CUR_SPX_IRQ  5
