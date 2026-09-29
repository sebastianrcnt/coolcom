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

// Saved by the exception entry in Arch.S; layout must match FR_* there.
class CExceptFrame
{
  I64 x[31];
  I64 elr,spsr,esr,far,vec;
  U8 q[32*16];
};

#define EXC_CUR_SPX_SYNC 4
#define EXC_CUR_SPX_IRQ  5
