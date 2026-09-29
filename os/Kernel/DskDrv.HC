// Drives and block devices, from TempleOS by Terry A. Davis (public domain)
// as kept in Aiwnios (nrootconauto, commit e155e87): Src/DskDrv.HC and
// Src/DskBlkDev.HC. RAM disks, ISO files, ATA/ATAPI, RedSea and the drive
// report are left out; a block device is a virtio-blk device (Blk.HC).
//
// The kernel has no exceptions yet, so where TempleOS throws, these routines
// print an error (PrintErr) and return failure.

CDrv *DrvChk(CDrv *dv, Bool except = TRUE)
{//Check for valid drv. NULL (and an error message if except) if not.
    if (!dv || dv->dv_signature != DRV_SIGNATURE_VAL) {
        if (except)
            PrintErr("Invalid drive\n");
        return NULL;
    } else
        return dv;
}

CBlkDev *BlkDevChk(CBlkDev *bd, Bool except = TRUE)
{//Check for valid BlkDev.
    if (!bd || bd->bd_signature != BD_SIGNATURE_VAL || !(BDT_NULL < bd->type < BDT_TYPES_NUM)) {
        if (except)
            PrintErr("Invalid block device\n");
        return NULL;
    } else
        return bd;
}

// ---- DskBlkDev.HC ----

Bool BlkDevLock(CBlkDev *bd)
{//Make this task have exclusive access to BlkDev.
    BlkDevChk(bd);
    while (bd->lock_fwding)
        bd = bd->lock_fwding;  // If two blkdevs on same controller, use just one lock
    if (!Bt(&bd->locked_flags, BDlf_LOCKED) || bd->owning_task != Fs) {
        while (LBts(&bd->locked_flags, BDlf_LOCKED))
            Yield;
        bd->owning_task = Fs;
        return TRUE;
    } else
        return FALSE;
}

Bool BlkDevUnlock(CBlkDev *bd, Bool rst = FALSE)
{//Release exclusive lock on access to BlkDev.
    BlkDevChk(bd);
    while (bd->lock_fwding)
        bd = bd->lock_fwding;  // If two blkdevs on same controller, use just one lock
    if (Bt(&bd->locked_flags, BDlf_LOCKED) && bd->owning_task == Fs) {
        if (rst)
            bd->flags &= ~(BDF_INITIALIZED | BDF_INIT_IN_PROGRESS);
        bd->owning_task = NULL;
        LBtr(&bd->locked_flags, BDlf_LOCKED);
        Yield;  // Prevent deadlock
        return TRUE;
    } else
        return FALSE;
}

Bool BlkDevInit(CBlkDev *bd)
{
    CDrv *dv;
    Bool res = FALSE;
    if (!(bd->flags & BDF_INITIALIZED)) {
        bd->flags |= BDF_INITIALIZED | BDF_INIT_IN_PROGRESS;
        switch (bd->type) {
            case BDT_VIRTIO:
                res = bd->unit < BlkCount;
                break;
        }
        if (res && bd->flags & BDF_READ_CACHE) {
            dv = blkdev.let_to_drv[bd->first_drv_let - 'A'];
            if (dv)
                DskCacheInvalidate2(dv);
        }
        bd->flags &= ~BDF_INIT_IN_PROGRESS;
    } else
        res = TRUE;
    return res;
}

CBlkDev *BlkDevNextFreeSlot(U8 first_drv_let, I64 type)
{//Locate free slot for new BlkDev, like during Mount().
    I64 i = 0;
    CBlkDev *res;
    do {
        res = &blkdev.blkdevs[i];
        if (res->bd_signature != BD_SIGNATURE_VAL) {
            MemSet(res, 0, sizeof(CBlkDev));
            res->first_drv_let = first_drv_let;
            res->type = type;
            res->flags = BDF_READ_CACHE;
            res->blk_size = BLK_SIZE;
            res->max_blk = 0xEFFFFFFF;
            return res;
        }
    } while (++i < BLKDEVS_NUM);
    PrintErr("No free block device slot\n");
    return NULL;
}

// ---- DskDrv.HC ----

Bool DrvLock(CDrv *dv)
{//Make this task have exclusive access to drv & BlkDev.
    DrvChk(dv);
    BlkDevLock(dv->bd);
    if (!Bt(&dv->locked_flags, DVlf_LOCKED) || dv->owning_task != Fs) {
        while (LBts(&dv->locked_flags, DVlf_LOCKED))
            Yield;
        dv->owning_task = Fs;
        return TRUE;
    } else
        return FALSE;
}

Bool DrvUnlock(CDrv *dv, Bool rst = FALSE)
{//Release exclusive lock on access to drv & BlkDev.
    DrvChk(dv);
    if (Bt(&dv->locked_flags, DVlf_LOCKED) && dv->owning_task == Fs) {
        BlkDevUnlock(dv->bd, rst);
        dv->owning_task = NULL;
        LBtr(&dv->locked_flags, DVlf_LOCKED);
        Yield;  // Prevent deadlock
        return TRUE;
    } else
        return FALSE;
}

U0 DrvsRelease()
{//When task dies, release all owned drvs.
    I64 i;
    CDrv *dv;
    for (i = 0; i < DRVS_NUM; i++) {
        dv = &blkdev.drvs[i];
        if (dv->owning_task == Fs && dv->dv_signature == DRV_SIGNATURE_VAL)
            DrvUnlock(dv, TRUE);
    }
}

CDrv *DrvMakeFreeSlot(U8 drv_let)
{//Make a slot free for a new drv, like during Mount().
    I64 i = ToUpper(drv_let) - 'A';
    CDrv *res;
    if (!(0 <= i < DRVS_NUM)) {
        PrintErr("Invalid drive letter\n");
        return NULL;
    }
    res = &blkdev.drvs[i];
    MemSet(res, 0, sizeof(CDrv));
    res->drv_let = 'A' + i;
    return res;
}

U0 DrvDel(CDrv *dv)
{//Delete drv
    Free(dv->cur_fat_blk);
    Free(dv->fis);
    MemSet(dv, 0, sizeof(CDrv));
}

extern Bool DrvBlkRead(CDrv *dv, U8 *buf, I64 blk, I64 cnt);
extern Bool DrvBlkWrite(CDrv *dv, U8 *buf, I64 blk, I64 cnt);

U0 DrvFATBlkAlloc(CDrv *dv)
{
    DrvChk(dv);
    Free(dv->cur_fat_blk);
    dv->cur_fat_blk = MAlloc(BLK_SIZE);
    dv->cur_fat_blk_num = 0;
    dv->fat_blk_dirty = 0;
    DrvBlkRead(dv, dv->cur_fat_blk, dv->fat1, 1);
}

U0 DrvFATBlkClean(CDrv *dv, I64 fat_sel = 3)
{
    if (dv->fs_type == FSt_FAT32 && Bt(&dv->fat_blk_dirty, 0)) {
        if (dv->fat1 == dv->fat2) {
            DrvBlkWrite(dv, dv->cur_fat_blk, dv->fat1 + dv->cur_fat_blk_num, 1);
            LBtr(&dv->fat_blk_dirty, 0);
        } else {
            if (fat_sel == 3 || !fat_sel)
                DrvBlkWrite(dv, dv->cur_fat_blk, dv->fat1 + dv->cur_fat_blk_num, 1);
            if (fat_sel == 3 || fat_sel == 1) {
                DrvBlkWrite(dv, dv->cur_fat_blk, dv->fat2 + dv->cur_fat_blk_num, 1);
                LBtr(&dv->fat_blk_dirty, 0);
            }
        }
    }
}

Bool DrvFATBlkSet(CDrv *dv, I64 c, I64 fat_sel = 3)
{//Make cur_fat_blk the FAT block holding clus c. FALSE if c is invalid.
    I64 fat_blk_num;
    if (c == INVALID_CLUS || dv->fs_type != FSt_FAT32) {
        PrintErr("Bad cluster\n");
        return FALSE;
    }
    fat_blk_num = c >> (BLK_SIZE_BITS - 2);
    if (fat_blk_num != dv->cur_fat_blk_num) {
        DrvFATBlkClean(dv, fat_sel);
        dv->cur_fat_blk_num = fat_blk_num;
        if (fat_sel == 3 || !fat_sel)
            DrvBlkRead(dv, dv->cur_fat_blk, dv->fat1 + dv->cur_fat_blk_num, 1);
        else
            DrvBlkRead(dv, dv->cur_fat_blk, dv->fat2 + dv->cur_fat_blk_num, 1);
    }
    return TRUE;
}

CDrv *DrvCur()
{//The running task's drive; a new task starts on the boot drive at "/".
    CTask *task = Fs;
    if (!task->cur_dv && blkdev.boot_drv_let) {
        task->cur_dv = blkdev.let_to_drv[blkdev.boot_drv_let - 'A'];
        Free(task->cur_dir);
        task->cur_dir = StrNew("/");
    }
    return task->cur_dv;
}

U8 Drv2Let(CDrv *dv = NULL)
{//Drv ptr to Drv letter.
    if (!dv)
        dv = DrvCur;
    if (!DrvChk(dv))
        return 0;
    return dv->drv_let;
}

U8 Let2Let(U8 drv_let = 0)
{//Drv letter to Drv letter.
    if (!drv_let)
        drv_let = Drv2Let(DrvCur);
    else if (drv_let == ':')
        drv_let = blkdev.boot_drv_let;
    else if (drv_let == '~')
        drv_let = *blkdev.home_dir;
    return ToUpper(drv_let);
}

CDrv *Let2Drv(U8 drv_let = 0, Bool except = TRUE)
{//Drv letter to Drv ptr.
    CDrv *dv;
    if (!drv_let)
        dv = DrvCur;
    else {
        drv_let = Let2Let(drv_let);
        if (!('A' <= drv_let <= 'Z')) {
            if (except)
                PrintErr("Invalid drive letter\n");
            return NULL;
        }
        dv = blkdev.let_to_drv[drv_let - 'A'];
    }
    return DrvChk(dv, except);
}

U0 DskCacheInvalidate(CDrv *dv)
{//Needed for removable media.
    Bool unlock;
    CBlkDev *bd = dv->bd;
    if (!DrvChk(dv))
        return;
    unlock = DrvLock(dv);
    BlkDevInit(bd);
    if (bd->flags & BDF_READ_CACHE)
        DskCacheInvalidate2(dv);
    if (unlock)
        DrvUnlock(dv);
}

Bool DrvMap(U8 drv_let, CDrv *dv)
{//Make drive letter map to another.
    drv_let = Let2Let(drv_let);
    if ('A' <= drv_let <= 'Z') {
        blkdev.let_to_drv[drv_let - 'A'] = dv;
        dv->drv_let = drv_let;
        return TRUE;
    } else
        return FALSE;
}

Bool Drv(U8 drv_let)
{//Change drive.  You can set drive with Cd() as well.
    CDrv *dv = Let2Drv(drv_let);
    CTask *task = Fs;
    if (!dv || !BlkDevChk(dv->bd))
        return FALSE;
    if (dv != task->cur_dv)
        BlkDevInit(dv->bd);
    task->cur_dv = dv;
    Free(task->cur_dir);
    task->cur_dir = StrNew("/");
    switch (dv->fs_type) {
        case FSt_FAT32:
            return TRUE;
        default:
            PrintErr("File System Not Supported\n");
            return FALSE;
    }
}
