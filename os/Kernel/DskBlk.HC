// Drive block I/O, from TempleOS by Terry A. Davis (public domain) as kept in
// Aiwnios (nrootconauto, commit e155e87, Src/DskBlk.HC). TempleOS calls these
// BlkRead/BlkWrite; here those names are the virtio-blk driver's (Blk.HC),
// which is what they sit on. Blocks are 512 bytes and absolute on the device.

Bool DrvBlkRead(CDrv *dv, U8 *buf, I64 blk, I64 cnt)
{//Read blk cnt from Drv to buf.
    Bool res = TRUE, unlock;
    CBlkDev *bd;
    if (cnt <= 0)
        return TRUE;
    if (!DrvChk(dv))
        return FALSE;
    bd = dv->bd;
    unlock = DrvLock(dv);
    BlkDevInit(bd);
    if (dv->drv_offset && blk < dv->drv_offset || blk + cnt > dv->drv_offset + dv->size) {
        PrintErr("Block %d out of drive %c:\n", blk, Drv2Let(dv));
        res = FALSE;
    } else {
        if (bd->flags & BDF_READ_CACHE)
            RCache(dv, &buf, &blk, &cnt);
        if (cnt > 0) {
            switch (bd->type) {
                case BDT_VIRTIO:
                    if (BlkRead(bd->unit, blk, cnt, buf)) {
                        PrintErr("Disk read error, block %d\n", blk);
                        res = FALSE;
                    }
                    break;
            }
            blkdev.read_cnt += cnt;
            if (res && bd->flags & BDF_READ_CACHE)
                DskCacheAdd(dv, buf, blk, cnt);
        }
    }
    if (unlock)
        DrvUnlock(dv);
    return res;
}

Bool DrvBlkWrite(CDrv *dv, U8 *buf, I64 blk, I64 cnt)
{//Write blk cnt from buf to Drv.
    Bool res = TRUE, unlock;
    CBlkDev *bd;
    if (cnt <= 0)
        return TRUE;
    if (!DrvChk(dv))
        return FALSE;
    bd = dv->bd;
    unlock = DrvLock(dv);
    BlkDevInit(bd);
    if (bd->flags & BDF_READ_ONLY) {
        PrintErr("Drive %c: is read-only\n", Drv2Let(dv));
        res = FALSE;
    } else if (dv->drv_offset && blk < dv->drv_offset || blk + cnt > dv->drv_offset + dv->size) {
        PrintErr("Block %d out of drive %c:\n", blk, Drv2Let(dv));
        res = FALSE;
    } else {
        switch (bd->type) {
            case BDT_VIRTIO:
                if (BlkWrite(bd->unit, blk, cnt, buf)) {
                    PrintErr("Disk write error, block %d\n", blk);
                    res = FALSE;
                }
                break;
        }
        blkdev.write_cnt += cnt;
        if (bd->flags & BDF_READ_CACHE)
            DskCacheAdd(dv, buf, blk, cnt);
    }
    if (unlock)
        DrvUnlock(dv);
    return res;
}

#define ZERO_BUF_SIZE 2048
U0 BlkWriteZero(CDrv *dv, I64 blk, I64 cnt)
{//Fill blk cnt with zeros in Drv.
    I64 n;
    U8 *z = CAlloc(ZERO_BUF_SIZE << BLK_SIZE_BITS);
    while (cnt > 0) {
        n = cnt;
        if (n > ZERO_BUF_SIZE)
            n = ZERO_BUF_SIZE;
        DrvBlkWrite(dv, z, blk, n);
        blk += n;
        cnt -= n;
        Yield;  // Prevent locking
    }
    Free(z);
}
