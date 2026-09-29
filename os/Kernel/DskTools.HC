// FAT32 maintenance. All public commands are exported to the shell prelude.
// Fsck defaults to a read-only pass. Repair truncates ambiguous chains and
// frees unreachable allocation; it cannot recover lost file contents.

I64 DiskInfo(U8 drv_let = 0)
{//Print data capacity and free bytes, return free bytes or -1 on I/O failure.
    CDrv *dv;
    I64 c, limit, free = 0;
    U32 fat[128];
    Bool unlock;
    if (drv_let) dv = Let2Drv(drv_let); else dv = DrvCur;
    if (!dv) return -1;
    unlock = DrvLock(dv);
    DrvFATBlkClean(dv);
    limit = FAT32Limit(dv);
    for (c = 2; c < limit; c++) {
        if (c == 2 || !(c & 127))
            if (!DrvBlkRead(dv, fat, dv->fat1 + c / 128, 1)) {free = -1; goto info_done;}
        if (!(fat[c & 127] & 0x0FFFFFFF)) free++;
    }
    free *= dv->spc * 512;
    Print("%c: capacity %d bytes, free %d bytes, cluster %d bytes\n", Drv2Let(dv),
            (limit - 2) * dv->spc * 512, free, dv->spc * 512);
info_done:
    if (unlock) DrvUnlock(dv);
    return free;
}

Bool FatFormat(U8 drv_let)
{//Quick-format an existing mounted volume, preserving its partition boundaries.
    CDrv *dv = Let2Drv(drv_let);
    CFAT32Boot br;
    CFAT32FileInfoSect info;
    I64 total, spc = 1, fats, clusters, i, n;
    U8 *zero;
    U32 head[128];
    Bool unlock, ok = FALSE;
    if (!dv || dv->bd->flags & BDF_READ_ONLY) return FALSE;
    total = dv->size;
    if (total > 0xFFFFFFFF || total < 66581) return FALSE;
    while (total / spc > 0x0FFFFFF0 && spc < 128) spc *= 2;
    fats = (total - 32 + 130 * spc + 1) / (128 * spc + 2);
    clusters = (total - 32 - 2 * fats) / spc;
    if (clusters < 65525 || clusters >= 0x0FFFFFF0) return FALSE;
    unlock = DrvLock(dv);
    DrvFATBlkClean(dv);
    DskCacheInvalidate2(dv);
    zero = CAlloc(128 * 512);
    // Clear reserved sectors, both FATs, and the root directory.
    for (i = 0; i < 32 + 2 * fats + spc; i += n) {
        n = MinI64(128, 32 + 2 * fats + spc - i);
        if (!DrvBlkWrite(dv, zero, dv->drv_offset + i, n)) goto format_done;
    }
    MemSet(&br, 0, 512);
    br.jump_and_nop[0] = 0xEB; br.jump_and_nop[1] = 0x58; br.jump_and_nop[2] = 0x90;
    MemCpy(br.oem_name, "COOLCOM ", 8);
    br.bytes_per_sect = 512; br.sects_per_clus = spc; br.reserved_sects = 32;
    br.copies_of_fat = 2; br.media_desc = 0xF8; br.sects_per_track = 63; br.num_heads = 255;
    br.hidden_sects = dv->drv_offset; br.sects = total; br.sects_per_fat = fats;
    br.root_clus = 2; br.file_system_info_sect = 1; br.backup_boot_sect = 6;
    br.log_drv_num = 0x80; br.ext_signature = 0x29; br.serial_num = Now;
    MemCpy(br.vol_name, "NO NAME    ", 11); MemCpy(br.fat_name, "FAT32   ", 8); br.signature = 0xAA55;
    MemSet(&info, 0, 512);
    info.signature1 = 0x41615252; info.signature2 = 0x61417272; info.signature3 = 0xAA550000;
    info.free_clus = clusters - 1; info.most_recently_alloced = 2;
    MemSet(head, 0, 512); head[0] = 0x0FFFFFF8; head[1] = head[2] = 0x0FFFFFFF;
    if (!DrvBlkWrite(dv, head, dv->drv_offset + 32, 1) ||
            !DrvBlkWrite(dv, head, dv->drv_offset + 32 + fats, 1) ||
            !DrvBlkWrite(dv, &info, dv->drv_offset + 1, 1) ||
            !DrvBlkWrite(dv, &info, dv->drv_offset + 7, 1) ||
            !DrvBlkWrite(dv, &br, dv->drv_offset + 6, 1) ||
            !DrvBlkWrite(dv, &br, dv->drv_offset, 1)) goto format_done;
    ok = !BlkFlush(dv->bd->unit) && FAT32Init(dv);
    if (ok && Fs->cur_dv == dv) {Free(Fs->cur_dir); Fs->cur_dir = StrNew("/");}
format_done:
    Free(zero);
    if (unlock) DrvUnlock(dv);
    Print("FatFormat %c: success=%d (failure may leave an incomplete volume)\n", drv_let, ok);
    return ok;
}

class CFatCheck
{
    CDrv *dv;
    U32 *fat;
    U8 *seen;
    I64 limit, errors, lost;
    Bool repair, io_error;
};

U0 FatCheckError(CFatCheck *ck, U8 *message, I64 c)
{
    ck->errors++;
    Print("Fsck: %s (cluster %d)\n", message, c);
}

I64 FatCheckChain(CFatCheck *ck, I64 first, I64 wanted = -1)
{//First claimant owns a shared cluster; later chains are truncated before it.
    I64 c = first, prev = 0, count = 0, next;
    if (!first && !wanted) return 0;
    while (TRUE) {
        if (wanted >= 0 && count == wanted) {
            if (c < 0x0FFFFFF8 && c) FatCheckError(ck, "chain longer than file", c);
            if (prev) ck->fat[prev] = 0x0FFFFFFF;
            break;
        }
        if (c >= 0x0FFFFFF8) break;
        if (!(2 <= c < ck->limit) || !ck->fat[c] || ck->fat[c] == 0x0FFFFFF7 || ck->seen[c]) {
            FatCheckError(ck, "invalid, cyclic or shared chain", c);
            if (prev) ck->fat[prev] = 0x0FFFFFFF;
            break;
        }
        ck->seen[c] = 1;
        count++;
        next = ck->fat[c];
        prev = c; c = next;
    }
    if (wanted > count) FatCheckError(ck, "chain shorter than file", first);
    return count;
}

U0 FatCheckDir(CFatCheck *ck, I64 first, I64 parent, I64 depth)
{
    I64 c, i, j, count = 0, sum = -1, begin = -1, child, n, expected, epc = ck->dv->spc * 16;
    CFAT32DirEntry *buf;
    CDirEntry lfn;
    Bool changed = FALSE;
    if (depth > 128) {ck->io_error = TRUE; FatCheckError(ck, "directory depth exceeds 128", first); return;}
    for (c = first; 2 <= c < ck->limit; c = ck->fat[c]) count += epc;
    buf = MAlloc(count * 32);
    for (c = first, i = 0; 2 <= c < ck->limit; c = ck->fat[c], i += epc)
        if (!DrvBlkRead(ck->dv, &buf[i], Clus2Blk(ck->dv, c), ck->dv->spc)) {
            ck->io_error = TRUE; goto check_dir_done;
        }
    MemSet(&lfn, 0, sizeof(CDirEntry));
    for (i = 0; i < count; i++) {
        if (!buf[i].name[0]) break;
        if (buf[i].name[0] == 0xE5) goto check_reset;
        if (buf[i].attr == RS_ATTR_LONG_NAME) {
            if (begin < 0) begin = i;
            DirLongNameFill(&lfn, &buf[i], &sum);
            goto check_next;
        }
        if (begin >= 0 && (sum != FATNameXSum(buf[i].name) || lfn.user_data || !lfn.name[0])) {
            FatCheckError(ck, "invalid long name", first);
            for (j = begin; j < i; j++) buf[j].name[0] = 0xE5;
            changed = TRUE;
        }
        begin = -1;
        child = buf[i].clus_lo + (buf[i].clus_hi << 16);
        if (buf[i].name[0] == '.' && (buf[i].name[1] == ' ' || buf[i].name[1] == '.')) {
            expected = first;
            if (buf[i].name[1] == '.') expected = parent;
            if (child != expected || buf[i].size || buf[i].attr != RS_ATTR_DIR) {
                FatCheckError(ck, "dot directory entry", first);
                buf[i].clus_lo = expected; buf[i].clus_hi = expected >> 16;
                buf[i].size = 0; buf[i].attr = RS_ATTR_DIR; changed = TRUE;
            }
        } else if (!(buf[i].attr & RS_ATTR_VOL_ID)) {
            if (buf[i].attr & RS_ATTR_DIR) expected = -1;
            else expected = (buf[i].size + ck->dv->spc * 512 - 1) / (ck->dv->spc * 512);
            n = FatCheckChain(ck, child, expected);
            if (!n && (child || buf[i].attr & RS_ATTR_DIR)) {
                buf[i].clus_lo = buf[i].clus_hi = 0; changed = TRUE;
                if (buf[i].attr & RS_ATTR_DIR) {
                    buf[i].name[0] = 0xE5;
                    for (j = i - 1; j >= 0 && buf[j].attr == RS_ATTR_LONG_NAME; j--) buf[j].name[0] = 0xE5;
                }
            }
            if (buf[i].attr & RS_ATTR_DIR) {
                if (buf[i].size) {FatCheckError(ck, "directory has file size", child); buf[i].size = 0; changed = TRUE;}
                if (n) {
                    j = first; if (j == ck->dv->root_clus) j = 0;
                    FatCheckDir(ck, child, j, depth + 1);
                }
            } else if (n < expected) {buf[i].size = n * ck->dv->spc * 512; changed = TRUE;}
        }
check_reset:
        if (begin >= 0) {
            FatCheckError(ck, "orphan long name", first);
            for (j = begin; j < i; j++) buf[j].name[0] = 0xE5;
            changed = TRUE;
        }
        begin = -1; sum = -1; MemSet(&lfn, 0, sizeof(CDirEntry));
check_next:;
    }
    if (begin >= 0) {
        FatCheckError(ck, "trailing long name", first);
        for (j = begin; j < i; j++) buf[j].name[0] = 0xE5;
        changed = TRUE;
    }
    if (changed && ck->repair)
        for (c = first, i = 0; 2 <= c < ck->limit; c = ck->fat[c], i += epc)
            if (!DrvBlkWrite(ck->dv, &buf[i], Clus2Blk(ck->dv, c), ck->dv->spc)) ck->io_error = TRUE;
check_dir_done:
    Free(buf);
}

I64 Fsck(U8 drv_let = 0, Bool repair = FALSE)
{//Return issues found (0 clean), or -1 for incomplete scan/I/O. Recheck after repair.
    CFatCheck ck;
    CFAT32Boot br;
    CFAT32FileInfoSect info;
    U32 mirror[128];
    I64 i, sectors, free = 0;
    Bool unlock;
    MemSet(&ck, 0, sizeof(CFatCheck));
    if (drv_let) ck.dv = Let2Drv(drv_let); else ck.dv = DrvCur;
    if (!ck.dv || repair && ck.dv->bd->flags & BDF_READ_ONLY) return -1;
    unlock = DrvLock(ck.dv);
    DrvFATBlkClean(ck.dv);
    ck.repair = repair; ck.limit = FAT32Limit(ck.dv);
    sectors = (ck.limit + 127) / 128;
    ck.fat = MAlloc(sectors * 512); ck.seen = CAlloc(ck.limit);
    if (!DrvBlkRead(ck.dv, ck.fat, ck.dv->fat1, sectors) ||
            !DrvBlkRead(ck.dv, &br, ck.dv->drv_offset, 1)) {ck.io_error = TRUE; goto fsck_done;}
    for (i = 0; i < sectors; i++) {
        if (!DrvBlkRead(ck.dv, mirror, ck.dv->fat2 + i, 1)) {ck.io_error = TRUE; goto fsck_done;}
        if (MemCmp(mirror, ck.fat + i * 128, 512)) FatCheckError(&ck, "FAT copies differ", i * 128);
    }
    for (i = 0; i < ck.limit; i++) ck.fat[i] &= 0x0FFFFFFF;
    if (FatCheckChain(&ck, ck.dv->root_clus)) FatCheckDir(&ck, ck.dv->root_clus, 0, 0);
    else ck.io_error = TRUE;
    if (ck.io_error) goto fsck_done;
    for (i = 2; i < ck.limit; i++) {
        if (ck.fat[i] && ck.fat[i] != 0x0FFFFFF7 && !ck.seen[i]) {
            ck.lost++;
            if (repair) ck.fat[i] = 0;
        }
        if (!ck.fat[i]) free++;
    }
    if (ck.lost) {ck.errors++; Print("Fsck: %d lost clusters, repair=%d\n", ck.lost, repair);}
    if (!DrvBlkRead(ck.dv, &info, ck.dv->file_system_info_sect, 1)) {ck.io_error = TRUE; goto fsck_done;}
    if (info.signature1 != 0x41615252 || info.signature2 != 0x61417272 || info.signature3 != 0xAA550000 ||
            info.free_clus != 0xFFFFFFFF && info.free_clus != free)
        FatCheckError(&ck, "FSInfo free count/signatures", 0);
    if (repair) {
        if (!DrvBlkWrite(ck.dv, ck.fat, ck.dv->fat1, sectors) ||
                !DrvBlkWrite(ck.dv, ck.fat, ck.dv->fat2, sectors)) ck.io_error = TRUE;
        MemSet(&info, 0, 512); info.signature1 = 0x41615252; info.signature2 = 0x61417272;
        info.signature3 = 0xAA550000; info.free_clus = free; info.most_recently_alloced = 2;
        if (!DrvBlkWrite(ck.dv, &info, ck.dv->file_system_info_sect, 1)) ck.io_error = TRUE;
        if (br.backup_boot_sect && br.backup_boot_sect + br.file_system_info_sect < br.reserved_sects)
            if (!DrvBlkWrite(ck.dv, &info, ck.dv->drv_offset + br.backup_boot_sect + br.file_system_info_sect, 1)) ck.io_error = TRUE;
        MemCpy(ck.dv->fis, &info, 512);
        ck.dv->fat_blk_dirty = 0;
        DrvFATBlkAlloc(ck.dv);
        if (BlkFlush(ck.dv->bd->unit)) ck.io_error = TRUE;
    }
fsck_done:
    Print("Fsck %c: %d issues, incomplete=%d\n", Drv2Let(ck.dv), ck.errors, ck.io_error);
    Free(ck.fat); Free(ck.seen);
    if (unlock) DrvUnlock(ck.dv);
    if (ck.io_error) return -1;
    return ck.errors;
}
