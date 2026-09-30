// Clusters, from TempleOS by Terry A. Davis (public domain) as kept in
// Aiwnios (nrootconauto, commit e155e87, Src/DskClus.HC). FAT32 only.

extern I64 FAT32AllocClus(CDrv *dv, I64 c, I64 cnt);
extern I64 FAT32AllocContiguousClus(CDrv *dv, I64 cnt);

I64 ClusNumNext(CDrv *dv, I64 c, I64 cnt = 1)
{//Return next cnt'th clus in chain.
    Bool unlock;
    if (!DrvChk(dv))
        return INVALID_CLUS;
    if (cnt <= 0)
        return c;
    unlock = DrvLock(dv);
    switch (dv->fs_type) {
        case FSt_FAT32:
            while (cnt-- > 0 && 0 < c < 0x0FFFFFF8) {
                DrvFATBlkSet(dv, c);
                c = dv->cur_fat_blk[c & (BLK_SIZE / 4 - 1)] & 0x0FFFFFFF;
            }
            if (!(0 < c < 0x0FFFFFF8))
                c = INVALID_CLUS;
            break;
        default:
            c = INVALID_CLUS;
    }
    if (unlock)
        DrvUnlock(dv);
    return c;
}

I64 Clus2Blk(CDrv *dv, I64 c)
{//Drv clus num to blk num.
    return dv->data_area + c * dv->spc;
}

I64 ClusBlkRead(CDrv *dv, U8 *buf, I64 c, I64 blks)
{//Accepts blk count, so padding on last clus is not read.
    I64 i;
    Bool unlock;
    if (!DrvChk(dv))
        return INVALID_CLUS;
    if (blks <= 0)
        return c;
    unlock = DrvLock(dv);
    while (blks && 0 < c < 0x0FFFFFF8) {
        i = blks;
        if (i > dv->spc)
            i = dv->spc;
        DrvBlkRead(dv, buf, dv->data_area + c * dv->spc, i);
        buf += i << BLK_SIZE_BITS;
        c = ClusNumNext(dv, c, 1);
        blks -= i;
    }
    if (blks)
        PrintErr("Cluster chain too short\n");
    if (unlock)
        DrvUnlock(dv);
    return c;
}

I64 ClusRead(CDrv *dv, U8 *buf, I64 c, I64 cnt)
{//Read clus cnt from drv to buf.
    return ClusBlkRead(dv, buf, c, cnt * dv->spc);
}

I64 ClusBlkWrite(CDrv *dv, U8 *buf, I64 c, I64 blks)
{//Accepts blk count, so padding on last clus is not written.
    I64 i;
    Bool unlock;
    if (!DrvChk(dv))
        return INVALID_CLUS;
    if (blks <= 0)
        return c;
    unlock = DrvLock(dv);
    while (blks) {
        if (!(0 < c < 0x0FFFFFF8)) {
            PrintErr("Cluster chain too short\n");
            break;
        }
        i = blks;
        if (i > dv->spc)
            i = dv->spc;
        DrvBlkWrite(dv, buf, dv->data_area + c * dv->spc, i);
        buf += i << BLK_SIZE_BITS;
        c = ClusNumNext(dv, c);
        blks -= i;
    }
    if (unlock)
        DrvUnlock(dv);
    return c;
}

I64 ClusWrite(CDrv *dv, U8 *buf, I64 c, I64 cnt)
{//Write clus cnt from buf to drv.
    return ClusBlkWrite(dv, buf, c, cnt * dv->spc);
}

I64 ClusAlloc(CDrv *dv, I64 c = 0, I64 cnt = 1, Bool contiguous = FALSE)
{//Alloc clus cnt into chain.
    //c=0 means first clus in chain
    if (!DrvChk(dv))
        return INVALID_CLUS;
    if (cnt <= 0)
        return c;
    if (contiguous) {
        if (c) {
            PrintErr("Can't extend a contiguous file\n");
            return INVALID_CLUS;
        }
        return FAT32AllocContiguousClus(dv, cnt);
    } else
        return FAT32AllocClus(dv, c, cnt);
}
