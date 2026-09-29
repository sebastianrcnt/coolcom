// Translated from Aiwnios Src/OptLib.HC (nrootconauto, BSD-3), commit e155e87.
//TODO INCOMPLETE
CHashClass *OptClassFwd(CHashClass *tmpc)
{//Class forwarding for unions and subclasses.
    CHashClass *tmpc1;
    while (tmpc1 = tmpc->fwd_class)
        tmpc = tmpc1;
    return tmpc;
}

class COptMemberVar
{
    I64 score, addrof_cnt;
    CMemberLst *m;
};

I64 OptMVCompare(COptMemberVar *mv1, COptMemberVar *mv2)
{
    return mv2->score - mv1->score;
}
