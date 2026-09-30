// Spinlocks. A lock is an I64: 0 free, 1 held.

U0 SpinLock(I64 *l)
{
    while (ArchXchg(l, 1))
        while (*l)
            ArchWfe;  // woken by the sev in ArchStoreRel
}

U0 SpinUnlock(I64 *l)
{
    ArchStoreRel(l, 0);
}

I64 SpinLockIrq(I64 *l)
{//Lock with IRQs masked on this core; returns the old DAIF for SpinUnlockIrq.
    I64 daif = ArchDaif;
    ArchIrqOff;
    SpinLock(l);
    return daif;
}

U0 SpinUnlockIrq(I64 *l, I64 daif)
{
    SpinUnlock(l);
    ArchIntRestore(daif);
}
