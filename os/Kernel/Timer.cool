// Generic timer: each core's virtual timer ticks at JIFFY_FREQ.
#define JIFFY_FREQ 1000

I64 cnt_freq, cnts_per_jiffy, cnt_start;
I64 jiffies;

U0 TimerFiq()
{//Derive jiffies from the counter so late interrupts don't make time drift.
    cnts.jiffies = jiffies = (ArchCntVct - cnt_start) / cnts_per_jiffy;
    ArchCntvCvalSet(cnt_start + (jiffies + 1) * cnts_per_jiffy);
}

U0 TimerCoreInit()
{//Start this core's timer.
    ArchCntvCvalSet(cnt_start + ((ArchCntVct - cnt_start) / cnts_per_jiffy + 1) * cnts_per_jiffy);
    ArchCntvCtlSet(1);
}

U0 TimerInit()
{//Once, on the boot core.
    cnt_freq = ArchCntFrq;
    cnts_per_jiffy = cnt_freq / JIFFY_FREQ;
    cnt_start = ArchCntVct;
    TimerCoreInit;
}
