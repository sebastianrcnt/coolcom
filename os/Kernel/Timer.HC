// Generic timer: the virtual timer drives a JIFFY_FREQ tick.
#define JIFFY_FREQ 1000
#define TIMER_IRQ  27  // virtual timer PPI

I64 cnt_freq,cnts_per_jiffy,cnt_start;
I64 jiffies;

U0 TimerIrq(I64)
{//Derive jiffies from the counter so late interrupts don't make time drift.
  jiffies=(ArchCntVct-cnt_start)/cnts_per_jiffy;
  ArchCntvCvalSet(cnt_start+(jiffies+1)*cnts_per_jiffy);
}

U0 TimerInit()
{
  cnt_freq=ArchCntFrq;
  cnts_per_jiffy=cnt_freq/JIFFY_FREQ;
  cnt_start=ArchCntVct;
  IrqSet(TIMER_IRQ,&TimerIrq);
  ArchCntvCvalSet(cnt_start+cnts_per_jiffy);
  ArchCntvCtlSet(1);
}

U0 Sleep(I64 ms)
{//Busy-wait in low power; the scheduler will replace this.
  I64 end=jiffies+ms*JIFFY_FREQ/1000;
  while (jiffies<end)
    ArchWfi;
}
