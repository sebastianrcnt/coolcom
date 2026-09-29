// FAT32 file system, from TempleOS by Terry A. Davis (public domain) as kept
// in Aiwnios (nrootconauto, commit e155e87, Src/FileSysFAT.HC).
//
// Changes from the original:
// - no exceptions (the kernel has none yet): failures print and return;
// - dates are raw FAT timestamps (DskA.HH CDate) and new entries get a fixed
//   one, as there is no real-time clock;
// - names compare case-insensitively, as FAT requires, and short names show
//   the NT lower-case flags other systems set (mtools, Windows);
// - FATNameTo keeps the 8.3 short name within 11 bytes, FAT32FilesDel passes
//   the short name and not its first char, a removed long name at the end of
//   the previous cluster is written from that cluster's buffer, and a new
//   directory's ".." is cluster 0 when its parent is the root;
// - the FSInfo free cluster count is kept up to date, not set to unknown.
// FAT32Fmt is left out. Short names of long names are not made unique
// (TempleOS: "Supported except for short names, to some degree").

extern Bool Cd(U8 *dirname = NULL, Bool make_dirs = FALSE);
extern U0 DirEntryDel(CDirEntry *tmpde);
extern I64 FileWrite(U8 *filename, U8 *fbuf, I64 size, CDate cdt = 0, I64 attr = 0);

#define FAT_DFT_DATETIME 0x5C216000  // 2026-01-01 12:00:00

CDate Now()
{//No real-time clock yet.
    return FAT_DFT_DATETIME;
}

U0 CDate2Dos(U16 *t, U16 *d, CDate cdt)
{
    *d = cdt >> 16 & 0xFFFF;
    *t = cdt & 0xFFFF;
}

CDate Dos2CDate(U16 t, U16 d)
{
    return d << 16 | t;
}

Bool FAT32Init(CDrv *dv)
{//Read the boot sector and FSInfo of a FAT32 drive.
    CFAT32Boot br32;
    Bool unlock, res = FALSE;
    unlock = DrvLock(dv);
    dv->fs_type = FSt_FAT32;
    if (DrvBlkRead(dv, &br32, dv->drv_offset, 1)) {
        dv->file_system_info_sect = dv->drv_offset + br32.file_system_info_sect;
        dv->fat1 = dv->drv_offset + br32.reserved_sects;
        dv->fat2 = dv->fat1 + br32.sects_per_fat;
        dv->data_area = dv->fat2 + br32.sects_per_fat - 2 * br32.sects_per_clus;  // Starts at Clus 2
        dv->spc = br32.sects_per_clus;
        dv->root_clus = br32.root_clus;
        DrvFATBlkAlloc(dv);
        Free(dv->fis);
        dv->fis = MAlloc(BLK_SIZE);
        res = DrvBlkRead(dv, dv->fis, dv->file_system_info_sect, 1);
    }
    if (unlock)
        DrvUnlock(dv);
    return res;
}

Bool FATNameTo(U8 *dst, U8 *src)
{//Name to 8.3 short name (11 bytes, space padded).
    I64 i;
    U8 *ext;
    MemSet(dst, ' ', 11);
    if (!FileNameChk(src))
        return FALSE;
    if (!StrCmp(src, "..")) {
        *dst = '.';
        dst[1] = '.';
        return TRUE;
    } else if (!StrCmp(src, ".")) {
        *dst = '.';
        return TRUE;
    }
    ext = StrLastOcc(src, ".");
    i = 0;
    while (i < 8 && *src && src != ext)
        if (*src != '.' && *src != ' ')
            dst[i++] = ToUpper(*src++);
        else
            src++;
    if (ext) {
        ext++;
        i = 8;
        while (i < 11 && *ext)
            if (*ext != ' ')
                dst[i++] = ToUpper(*ext++);
            else
                ext++;
    }
    return TRUE;
}

I64 FATNameXSum(U8 *src)
{
    I64 i, res = 0;
    for (i = 0; i < 11; i++)
        if (res & 1)
            res.u8[0] = 0x80 + res >> 1 + *src++;
        else
            res.u8[0] = res >> 1 + *src++;
    return res;
}

Bool FATFromName(U8 *dst, U8 *src, I64 nt_res = 0)
{//8.3 short name to name. nt_res: FAT_NT_LOWER_BASE/EXT.
    I64 i, j, k = 0;
    for (j = 7; j >= 0 && src[j] == ' '; j--) {}
    for (i = 0; i <= j; i++)
        if (nt_res & FAT_NT_LOWER_BASE)
            dst[k++] = ToLower(src[i]);
        else
            dst[k++] = src[i];
    for (j = 10; j >= 8 && src[j] == ' '; j--) {}
    if (*src != '.' && j != 7)
        dst[k++] = '.';
    for (i = 8; i <= j; i++)
        if (nt_res & FAT_NT_LOWER_EXT)
            dst[k++] = ToLower(src[i]);
        else
            dst[k++] = src[i];
    dst[k++] = 0;
    return FileNameChk(dst);
}

U8 fat_long_name_map[13] = {
    offset(CFAT32DirEntryLong.name1),
    offset(CFAT32DirEntryLong.name1) + 2,
    offset(CFAT32DirEntryLong.name1) + 4,
    offset(CFAT32DirEntryLong.name1) + 6,
    offset(CFAT32DirEntryLong.name1) + 8,
    offset(CFAT32DirEntryLong.name2),
    offset(CFAT32DirEntryLong.name2) + 2,
    offset(CFAT32DirEntryLong.name2) + 4,
    offset(CFAT32DirEntryLong.name2) + 6,
    offset(CFAT32DirEntryLong.name2) + 8,
    offset(CFAT32DirEntryLong.name2) + 10,
    offset(CFAT32DirEntryLong.name3),
    offset(CFAT32DirEntryLong.name3) + 2};

Bool DirLongNameFill(CDirEntry *tmpde, CFAT32DirEntryLong *de, I64 *xsum)
{
    I64 i;
    U8 *ptr = de;
    if (de->ord & 0x40) {
        MemSet(tmpde, 0, sizeof(CDirEntry));
        *xsum = de->xsum;
    } else if (de->type || de->zero || de->xsum != *xsum) {
        MemSet(tmpde, 0, sizeof(CDirEntry));
        *xsum = 0;
        return FALSE;
    }
    switch (de->ord & 0x3F) {
        case 1:
            for (i = 0; i < 13; i++)
                if (!(tmpde->name[i] = ptr[fat_long_name_map[i]]))
                    return TRUE;
            break;
        case 2:
            for (i = 0; i < 12; i++)
                if (!(tmpde->name[i + 13] = ptr[fat_long_name_map[i]]))
                    return TRUE;
            break;
    }
    return TRUE;
}

Bool FAT32CDirFill(CDirEntry *tmpde, CFAT32DirEntry *de, CDate _local_time_offset)
{
    Bool res;
    if (tmpde->name[0])
        res = TRUE;
    else
        res = FATFromName(tmpde->name, de->name, de->NTres);
    tmpde->clus = de->clus_lo + de->clus_hi << 16;
    tmpde->size = de->size;
    tmpde->attr = de->attr;
    tmpde->datetime = Dos2CDate(de->WrtTime, de->WrtDate) - _local_time_offset;
    return res;
}

Bool FAT32DirFill(CFAT32DirEntry *de, CDirEntry *tmpde, I64 *_de_cnt, CDate _local_time_offset)
{//Fill up to 3 entries and store cnt of entries.
    I64 de_cnt = 0, i, l, xsum, ord;
    U8 *ptr, dname[16];
    CFAT32DirEntryLong *ld = de;
    Bool res;

    MemSet(de, 0, sizeof(CFAT32DirEntry));
    res = FATNameTo(de->name, tmpde->name);
    FATFromName(dname, de->name);
    if (StrCmp(dname, tmpde->name)) {
        ord = 0x41;
        xsum = FATNameXSum(de->name);
        if ((l = StrLen(tmpde->name)) > 13) {
            ptr = &ld[de_cnt];
            MemSet(ptr, 0, sizeof(CFAT32DirEntryLong));
            ld[de_cnt].attr = RS_ATTR_LONG_NAME;
            ld[de_cnt].xsum = xsum;
            ld[de_cnt].ord = 0x42;
            for (i = 13; i < l; i++)
                ptr[fat_long_name_map[i - 13]] = tmpde->name[i];
            i++;
            for (; i < 26; i++)
                *(ptr + fat_long_name_map[i - 13])(U16 *) = 0xFFFF;
            ord = 1;
            l = 13;
            de_cnt++;
        }
        ptr = &de[de_cnt];
        MemSet(ptr, 0, sizeof(CFAT32DirEntryLong));
        ld[de_cnt].attr = RS_ATTR_LONG_NAME;
        ld[de_cnt].xsum = xsum;
        ld[de_cnt].ord = ord;
        for (i = 0; i < l; i++)
            ptr[fat_long_name_map[i]] = tmpde->name[i];
        i++;
        for (; i < 13; i++)
            *(ptr + fat_long_name_map[i])(U16 *) = 0xFFFF;
        de_cnt++;
        MemSet(&de[de_cnt], 0, sizeof(CFAT32DirEntry));
        res = FATNameTo(de[de_cnt].name, tmpde->name);
    }
    de[de_cnt].clus_lo = tmpde->clus.u16[0];
    de[de_cnt].clus_hi = tmpde->clus.u16[1];
    if (!(tmpde->attr & RS_ATTR_DIR))
        de[de_cnt].size = tmpde->size;
    de[de_cnt].attr = tmpde->attr;
    if (!tmpde->datetime)
        tmpde->datetime = Now;
    CDate2Dos(&de[de_cnt].WrtTime, &de[de_cnt].WrtDate, tmpde->datetime + _local_time_offset);
    de[de_cnt].CrtTime = de[de_cnt].WrtTime;
    de[de_cnt].CrtDate = de[de_cnt].LstAccDate = de[de_cnt].WrtDate;
    if (_de_cnt)
        *_de_cnt = de_cnt + 1;
    return res;
}

Bool FAT32FileFind(CDrv *dv, I64 cur_dir_clus, U8 *name, CDirEntry *_res, I64 fuf_flags = 0)
{//FUF_JUST_DIRS, FUF_JUST_FILES
    Bool res = FALSE, unlock;
    CFAT32DirEntry *buf;
    I64 xsum = 0, attr, cur_dir_entry, entries_per_clus;
    U8 dname[CDIR_FILENAME_LEN], ch;
    CDirEntry long_name;
    MemSet(_res, 0, sizeof(CDirEntry));
    MemSet(&long_name, 0, sizeof(CDirEntry));
    if (!DrvChk(dv))
        return FALSE;
    if (dv->fs_type != FSt_FAT32)
        PrintErr("Not FAT32 Drv\n");
    else if (!CFileNameTo(dname, name))
        PrintErr("Invalid FileName: \"%s\".\n", name);
    else {
        unlock = DrvLock(dv);
        buf = MAlloc(BLK_SIZE * dv->spc);
        entries_per_clus = dv->spc << FAT32_ENTRIES_BITS;
        ClusRead(dv, buf, cur_dir_clus, 1);
        cur_dir_entry = 0;
        while (ch = buf[cur_dir_entry].name[0]) {
            attr = buf[cur_dir_entry].attr;
            if (ch != 0xE5) {
                if (attr & RS_ATTR_LONG_NAME_MASK == RS_ATTR_LONG_NAME)
                    DirLongNameFill(&long_name, &buf[cur_dir_entry], &xsum);
                else {
                    if (!(attr & RS_ATTR_VOL_ID)) {
                        if (xsum == FATNameXSum(buf[cur_dir_entry].name))
                            MemCpy(_res, &long_name, sizeof(CDirEntry));
                        else
                            MemSet(_res, 0, sizeof(CDirEntry));
                        if (!(fuf_flags & FUF_JUST_DIRS && !(attr & RS_ATTR_DIR)) &&
                                !(fuf_flags & FUF_JUST_FILES && attr & RS_ATTR_DIR) &&
                                FAT32CDirFill(_res, &buf[cur_dir_entry], dv->fat32_local_time_offset) &&
                                !StrICmp(dname, _res->name)) {
                            res = TRUE;
                            goto fff_done;
                        }
                    }
                    MemSet(&long_name, 0, sizeof(CDirEntry));
                }
            } else
                MemSet(&long_name, 0, sizeof(CDirEntry));
            if (++cur_dir_entry == entries_per_clus) {
                cur_dir_clus = ClusNumNext(dv, cur_dir_clus);
                if (!(0 < cur_dir_clus < 0x0FFFFFF8))
                    break;
                else {
                    ClusRead(dv, buf, cur_dir_clus, 1);
                    cur_dir_entry = 0;
                }
            }
        }
        MemSet(_res, 0, sizeof(CDirEntry));
fff_done:
        Free(buf);
        if (unlock)
            DrvUnlock(dv);
    }
    return res;
}

I64 Name2DirClus(CDrv *dv, U8 *dirname)
{//(DskStrB.HC) Clus of the directory dirname ("/A/B"), 0 if not found.
    Bool cont = TRUE, unlock;
    I64 cur_dir_clus;
    CDirEntry de;
    U8 *buf = StrNew(dirname), *buf2 = StrNew(dirname);
    if (!DrvChk(dv))
        return 0;
    unlock = DrvLock(dv);
    cur_dir_clus = dv->root_clus;
    while (*buf && cont) {
        StrFirstRem(buf, "/", buf2);
        if (*buf2) {
            cont = FAT32FileFind(dv, cur_dir_clus, buf2, &de, FUF_JUST_DIRS);
            cur_dir_clus = de.clus;
            if (!cur_dir_clus)  // ".." to the root
                cur_dir_clus = dv->root_clus;
        }
    }
    if (!cont) {
        PrintErr("File not found: \"%s\".\n", dirname);
        cur_dir_clus = 0;
    }
    if (unlock)
        DrvUnlock(dv);
    Free(buf);
    Free(buf2);
    return cur_dir_clus;
}

U8 *FAT32FileRead(CDrv *dv, U8 *cur_dir, U8 *filename, I64 *_size, I64 *_attr)
{
    U8 *buf = NULL;
    CDirEntry de;
    I64 c, blk_cnt, cur_dir_clus;
    *_size = 0;
    *_attr = 0;
    if (!DrvChk(dv))
        return NULL;
    if (dv->fs_type != FSt_FAT32)
        PrintErr("Not FAT32 Drv\n");
    else {
        DrvLock(dv);
        cur_dir_clus = Name2DirClus(dv, cur_dir);
        if (cur_dir_clus && FAT32FileFind(dv, cur_dir_clus, filename, &de, FUF_JUST_FILES)) {
            blk_cnt = (de.size + BLK_SIZE - 1) >> BLK_SIZE_BITS;
            buf = MAlloc(blk_cnt << BLK_SIZE_BITS + 1);
            c = de.clus;
            if (!(0 < c < 0x0FFFFFF8))
                c = 0x0FFFFFFF;
            else
                c = ClusBlkRead(dv, buf, c, blk_cnt);
            buf[de.size] = 0;  // Terminate
            *_size = de.size;
            *_attr = FileAttr(de.name, de.attr);
        }
        DrvUnlock(dv);
    }
    return buf;
}

Bool FAT32Cd(U8 *name, I64 cur_dir_clus)
{
    CDirEntry de;
    CDrv *dv = DrvCur;
    if (dv->fs_type != FSt_FAT32)
        PrintErr("Not FAT32 Drv\n");
    else if (FAT32FileFind(dv, cur_dir_clus, name, &de, FUF_JUST_DIRS))
        return TRUE;
    else
        PrintErr("File not found: \"%s\".\n", name);
    return FALSE;
}

U0 FAT32FreeCntAdd(CDrv *dv, I64 n)
{//Keep FSInfo's free cluster count, unless it is unknown.
    if (dv->fis->free_clus != 0xFFFFFFFF)
        dv->fis->free_clus += n;
    DrvBlkWrite(dv, dv->fis, dv->file_system_info_sect, 1);
}

U0 FAT32FreeClus(CDrv *dv, I64 c)
{
    I64 next, saved_c = c, freed = 0;
    Bool unlock;
    if (!DrvChk(dv))
        return;
    if (!(0 < c < 0x0FFFFFF8))
        return;
    if (dv->fs_type != FSt_FAT32)
        PrintErr("Not FAT32 Drv\n");
    else {
        unlock = DrvLock(dv);
        DrvFATBlkClean(dv);
        do {
            DrvFATBlkSet(dv, c, 0);
            next = dv->cur_fat_blk[c & (BLK_SIZE / 4 - 1)] & 0x0FFFFFFF;
            dv->cur_fat_blk[c & (BLK_SIZE / 4 - 1)] = 0;
            LBts(&dv->fat_blk_dirty, 0);
            c = next;
            freed++;
        } while (0 < c < 0x0FFFFFF8);
        DrvFATBlkClean(dv, 0);

        c = saved_c;
        do {
            DrvFATBlkSet(dv, c, 1);
            next = dv->cur_fat_blk[c & (BLK_SIZE / 4 - 1)] & 0x0FFFFFFF;
            dv->cur_fat_blk[c & (BLK_SIZE / 4 - 1)] = 0;
            LBts(&dv->fat_blk_dirty, 0);
            c = next;
        } while (0 < c < 0x0FFFFFF8);
        DrvFATBlkClean(dv, 1);
        FAT32FreeCntAdd(dv, freed);
        if (unlock)
            DrvUnlock(dv);
    }
}

I64 FAT32AllocClus(CDrv *dv, I64 c, I64 cnt)
{
    Bool wrap_around = FALSE, unlock;
    I64 first = INVALID_CLUS, j, l, n = 0;

    if (cnt <= 0)
        return 0x0FFFFFFF;
    unlock = DrvLock(dv);
    l = (dv->size + dv->drv_offset - dv->data_area) / dv->spc - 1;
    j = dv->fis->most_recently_alloced;
    while (cnt-- > 0) {
        while (TRUE) {
            j++;
            if (j < 1)
                j = 1;
            if (j >= l) {
                if (wrap_around) {
                    PrintErr("Drive %c: is full\n", Drv2Let(dv));
                    goto fac_done;
                }
                j = 1;
                wrap_around = TRUE;
            }
            DrvFATBlkSet(dv, j);
            if (!dv->cur_fat_blk[j & (BLK_SIZE / 4 - 1)])
                break;
        }
        if (!(0 < first < 0x0FFFFFF8))
            first = j;
        n++;
        if (0 < c < l) {
            DrvFATBlkSet(dv, c);
            dv->cur_fat_blk[c & (BLK_SIZE / 4 - 1)] = j;
            LBts(&dv->fat_blk_dirty, 0);
        }
        c = j;
    }

fac_done:
    if (0 < c < l) {
        DrvFATBlkSet(dv, c);
        dv->cur_fat_blk[c & (BLK_SIZE / 4 - 1)] = 0x0FFFFFFF;
        LBts(&dv->fat_blk_dirty, 0);
    }
    DrvFATBlkClean(dv);

    dv->fis->most_recently_alloced = j;
    FAT32FreeCntAdd(dv, -n);
    if (unlock)
        DrvUnlock(dv);
    return first;
}

I64 FAT32AllocContiguousClus(CDrv *dv, I64 cnt)
{
    I64 i, first = 1;
    Bool cont, unlock;

    if (cnt <= 0)
        return 0x0FFFFFFF;
    unlock = DrvLock(dv);
    while (TRUE) {
        first++;
        i = 0;
        cont = TRUE;
        while (cont && i < cnt) {
            if ((first + i + 1) * dv->spc + dv->data_area > dv->size + dv->drv_offset) {
                PrintErr("Drive %c: has no contiguous space\n", Drv2Let(dv));
                first = INVALID_CLUS;
                goto facc_done;
            }
            DrvFATBlkSet(dv, first + i);
            if (dv->cur_fat_blk[(first + i) & (BLK_SIZE / 4 - 1)])
                cont = FALSE;
            else
                i++;
        }
        if (!cont)
            first = first + i;
        else {
            DrvFATBlkClean(dv);

            for (i = 0; i < cnt; i++) {
                DrvFATBlkSet(dv, first + i, 0);
                if (i + 1 == cnt)
                    dv->cur_fat_blk[(first + i) & (BLK_SIZE / 4 - 1)] = 0x0FFFFFFF;
                else
                    dv->cur_fat_blk[(first + i) & (BLK_SIZE / 4 - 1)] = first + i + 1;
                LBts(&dv->fat_blk_dirty, 0);
            }
            DrvFATBlkClean(dv, 0);

            for (i = 0; i < cnt; i++) {
                DrvFATBlkSet(dv, first + i, 1);
                if (i + 1 == cnt)
                    dv->cur_fat_blk[(first + i) & (BLK_SIZE / 4 - 1)] = 0x0FFFFFFF;
                else
                    dv->cur_fat_blk[(first + i) & (BLK_SIZE / 4 - 1)] = first + i + 1;
                LBts(&dv->fat_blk_dirty, 0);
            }
            DrvFATBlkClean(dv, 1);
            FAT32FreeCntAdd(dv, -cnt);
            break;
        }
    }
facc_done:
    if (unlock)
        DrvUnlock(dv);
    return first;
}

I64 FAT32DirBlk(CDrv *dv, I64 clus, I64 entry)
{//Block holding directory entry number entry of cluster clus.
    return dv->data_area + clus * dv->spc + (entry >> FAT32_ENTRIES_BITS);
}

Bool FAT32DirNew(CDrv *dv, U8 *cur_dir, CDirEntry *tmpde, Bool free_old_chain)
{//Write tmpde's entries into cur_dir, replacing an entry of the same name.
    CFAT32DirEntry *buf, *last_buf, *tmp_buf, de[3];
    I64 i, attr, avail_cnt, de_cnt, c, cur_dir_entry, entries_per_clus, cur_dir_clus, xsum = 0,
            last_dir_clus = INVALID_CLUS;
    U8 ch;
    Bool written = FALSE, unlock;
    CDirEntry long_name;
    FAT32DirFill(&de, tmpde, &de_cnt, dv->fat32_local_time_offset);
    MemSet(&long_name, 0, sizeof(CDirEntry));
    unlock = DrvLock(dv);
    cur_dir_clus = Name2DirClus(dv, cur_dir);
    if (!cur_dir_clus) {
        if (unlock)
            DrvUnlock(dv);
        return FALSE;
    }
    buf = MAlloc(BLK_SIZE * dv->spc);
    last_buf = CAlloc(BLK_SIZE * dv->spc);
    entries_per_clus = dv->spc << FAT32_ENTRIES_BITS;
    ClusRead(dv, buf, cur_dir_clus, 1);
    cur_dir_entry = 0;
    while (ch = buf[cur_dir_entry].name[0]) {
        attr = buf[cur_dir_entry].attr;
        if (ch != 0xE5 && attr & RS_ATTR_LONG_NAME_MASK == RS_ATTR_LONG_NAME)
            DirLongNameFill(&long_name, &buf[cur_dir_entry], &xsum);
        else {
            avail_cnt = FAT32_ENTRIES_PER_BLK - cur_dir_entry & (FAT32_ENTRIES_PER_BLK - 1);
            for (i = 0; i < avail_cnt; i++)
                if (buf[cur_dir_entry + i].name[0] != 0xE5) {
                    if (buf[cur_dir_entry + i].name[0])
                        avail_cnt = i;
                    break;
                }
            if (ch == 0xE5 && !written && avail_cnt >= de_cnt) {
                MemCpy(&buf[cur_dir_entry], &de, de_cnt * sizeof(CFAT32DirEntry));
                DrvBlkWrite(dv, &buf[cur_dir_entry & -FAT32_ENTRIES_PER_BLK],
                            FAT32DirBlk(dv, cur_dir_clus, cur_dir_entry), 1);
                cur_dir_entry += de_cnt - 1;  // gets inc'ed
                written = TRUE;
            } else if (ch != 0xE5 && !(attr & RS_ATTR_VOL_ID)) {
                if (xsum != FATNameXSum(buf[cur_dir_entry].name))
                    MemSet(&long_name, 0, sizeof(CDirEntry));
                if (!long_name.name[0])
                    FATFromName(long_name.name, buf[cur_dir_entry].name, buf[cur_dir_entry].NTres);
                // Del old entry with same name
                if (!StrICmp(long_name.name, tmpde->name)) {
                    if (free_old_chain)
                        FAT32FreeClus(dv, buf[cur_dir_entry].clus_lo + buf[cur_dir_entry].clus_hi << 16);
                    if (!written) {
                        MemCpy(&buf[cur_dir_entry], &de[de_cnt - 1], sizeof(CFAT32DirEntry));
                        DrvBlkWrite(dv, &buf[cur_dir_entry & -FAT32_ENTRIES_PER_BLK],
                                    FAT32DirBlk(dv, cur_dir_clus, cur_dir_entry), 1);
                        written = TRUE;
                    } else {
                        buf[cur_dir_entry].name[0] = 0xE5;
                        i = 1;
                        while (i <= cur_dir_entry &&
                                buf[cur_dir_entry - i].attr & RS_ATTR_LONG_NAME_MASK == RS_ATTR_LONG_NAME)
                            buf[cur_dir_entry - i++].name[0] = 0xE5;
                        i--;
                        DrvBlkWrite(dv, &buf[(cur_dir_entry - i) & -FAT32_ENTRIES_PER_BLK],
                                    FAT32DirBlk(dv, cur_dir_clus, cur_dir_entry - i),
                                    (i + FAT32_ENTRIES_PER_BLK) >> FAT32_ENTRIES_BITS);
                        if (i == cur_dir_entry && 0 < last_dir_clus < 0x0FFFFFF8) {
                            i = 1;
                            while (i <= entries_per_clus &&
                                    last_buf[entries_per_clus - i].attr & RS_ATTR_LONG_NAME_MASK ==
                                    RS_ATTR_LONG_NAME)
                                last_buf[entries_per_clus - i++].name[0] = 0xE5;
                            if (--i > 0)
                                DrvBlkWrite(dv, &last_buf[(entries_per_clus - i) & -FAT32_ENTRIES_PER_BLK],
                                            FAT32DirBlk(dv, last_dir_clus, entries_per_clus - i),
                                            (i + FAT32_ENTRIES_PER_BLK - 1) >> FAT32_ENTRIES_BITS);
                        }
                    }
                    break;
                }
            }
            MemSet(&long_name, 0, sizeof(CDirEntry));
        }
        if (++cur_dir_entry == entries_per_clus) {
            last_dir_clus = cur_dir_clus;
            tmp_buf = buf;
            buf = last_buf;
            last_buf = tmp_buf;
            c = ClusNumNext(dv, cur_dir_clus);
            if (!(0 < c < 0x0FFFFFF8)) {
                c = ClusAlloc(dv, cur_dir_clus, 1, FALSE);
                MemSet(buf, 0, BLK_SIZE * dv->spc);
                ClusWrite(dv, buf, c, 1);
            } else
                ClusRead(dv, buf, c, 1);
            cur_dir_clus = c;
            cur_dir_entry = 0;
        }
    }
    if (!written) {
        avail_cnt = FAT32_ENTRIES_PER_BLK - cur_dir_entry & (FAT32_ENTRIES_PER_BLK - 1);
        if (avail_cnt < de_cnt) {
            for (i = 0; i < avail_cnt; i++)
                buf[cur_dir_entry + i].name[0] = 0xE5;
            DrvBlkWrite(dv, &buf[cur_dir_entry & -FAT32_ENTRIES_PER_BLK],
                        FAT32DirBlk(dv, cur_dir_clus, cur_dir_entry), 1);
            cur_dir_entry += avail_cnt;
            if (cur_dir_entry == entries_per_clus) {
                last_dir_clus = cur_dir_clus;
                tmp_buf = buf;
                buf = last_buf;
                last_buf = tmp_buf;
                cur_dir_clus = ClusAlloc(dv, cur_dir_clus, 1);
                cur_dir_entry = 0;
                MemSet(buf, 0, BLK_SIZE * dv->spc);
                ClusWrite(dv, buf, cur_dir_clus, 1);
            }
        }
        MemCpy(&buf[cur_dir_entry], &de, de_cnt * sizeof(CFAT32DirEntry));
        DrvBlkWrite(dv, &buf[cur_dir_entry & -FAT32_ENTRIES_PER_BLK],
                    FAT32DirBlk(dv, cur_dir_clus, cur_dir_entry), 1);
        cur_dir_entry += de_cnt;
        if (cur_dir_entry == entries_per_clus) {
            cur_dir_clus = ClusAlloc(dv, cur_dir_clus, 1);
            MemSet(buf, 0, BLK_SIZE * dv->spc);
            ClusWrite(dv, buf, cur_dir_clus, 1);
        } else {
            MemSet(&buf[cur_dir_entry], 0, sizeof(CFAT32DirEntry));
            DrvBlkWrite(dv, &buf[cur_dir_entry & -FAT32_ENTRIES_PER_BLK],
                        FAT32DirBlk(dv, cur_dir_clus, cur_dir_entry), 1);
        }
    }
    Free(last_buf);
    Free(buf);
    if (unlock)
        DrvUnlock(dv);
    return TRUE;
}

I64 FAT32FilesDel(CDrv *dv, U8 *cur_dir, U8 *files_find_mask, I64 fuf_flags, Bool del_dir, Bool print_msg)
{
    CFAT32DirEntry *buf, *last_buf, *tmp_buf;
    I64 i, res = 0, attr, xsum = 0, last_dir_clus = INVALID_CLUS, cur_dir_entry, entries_per_clus,
            cur_dir_clus;
    U8 ch;
    CDirEntry long_name;
    MemSet(&long_name, 0, sizeof(CDirEntry));
    DrvLock(dv);
    cur_dir_clus = Name2DirClus(dv, cur_dir);
    if (!cur_dir_clus) {
        DrvUnlock(dv);
        return 0;
    }
    buf = MAlloc(BLK_SIZE * dv->spc);
    last_buf = CAlloc(BLK_SIZE * dv->spc);
    entries_per_clus = dv->spc << FAT32_ENTRIES_BITS;
    ClusRead(dv, buf, cur_dir_clus, 1);
    cur_dir_entry = 0;
    while (ch = buf[cur_dir_entry].name[0]) {
        attr = buf[cur_dir_entry].attr;
        if (ch != 0xE5 && ch != '.') {
            if (attr & RS_ATTR_LONG_NAME_MASK == RS_ATTR_LONG_NAME)
                DirLongNameFill(&long_name, &buf[cur_dir_entry], &xsum);
            else {
                if (!(attr & RS_ATTR_VOL_ID) && (del_dir || !(attr & RS_ATTR_DIR))) {
                    if (xsum != FATNameXSum(buf[cur_dir_entry].name))
                        MemSet(&long_name, 0, sizeof(CDirEntry));
                    if (!long_name.name[0])
                        FATFromName(long_name.name, buf[cur_dir_entry].name, buf[cur_dir_entry].NTres);
                    if (FilesFindMatch(long_name.name, files_find_mask, fuf_flags)) {
                        if (!(attr & RS_ATTR_DIR))
                            res++;
                        if (print_msg)
                            "Del %s\n", long_name.name;
                        buf[cur_dir_entry].name[0] = 0xE5;
                        i = 1;
                        while (i <= cur_dir_entry &&
                                buf[cur_dir_entry - i].attr & RS_ATTR_LONG_NAME_MASK == RS_ATTR_LONG_NAME)
                            buf[cur_dir_entry - i++].name[0] = 0xE5;
                        i--;
                        DrvBlkWrite(dv, &buf[(cur_dir_entry - i) & -FAT32_ENTRIES_PER_BLK],
                                    FAT32DirBlk(dv, cur_dir_clus, cur_dir_entry - i),
                                    (i + FAT32_ENTRIES_PER_BLK) >> FAT32_ENTRIES_BITS);
                        if (i == cur_dir_entry && last_dir_clus != INVALID_CLUS) {
                            i = 1;
                            while (i <= entries_per_clus &&
                                    last_buf[entries_per_clus - i].attr & RS_ATTR_LONG_NAME_MASK ==
                                    RS_ATTR_LONG_NAME)
                                last_buf[entries_per_clus - i++].name[0] = 0xE5;
                            if (--i > 0)
                                DrvBlkWrite(dv, &last_buf[(entries_per_clus - i) & -FAT32_ENTRIES_PER_BLK],
                                            FAT32DirBlk(dv, last_dir_clus, entries_per_clus - i),
                                            (i + FAT32_ENTRIES_PER_BLK - 1) >> FAT32_ENTRIES_BITS);
                        }
                        FAT32FreeClus(dv, buf[cur_dir_entry].clus_lo + buf[cur_dir_entry].clus_hi << 16);
                    }
                }
                MemSet(&long_name, 0, sizeof(CDirEntry));
            }
        } else
            MemSet(&long_name, 0, sizeof(CDirEntry));
        if (++cur_dir_entry == entries_per_clus) {
            last_dir_clus = cur_dir_clus;
            cur_dir_clus = ClusNumNext(dv, cur_dir_clus, 1);
            if (!(0 < cur_dir_clus < 0x0FFFFFF8))
                break;
            tmp_buf = buf;
            buf = last_buf;
            last_buf = tmp_buf;
            ClusRead(dv, buf, cur_dir_clus, 1);
            cur_dir_entry = 0;
        }
    }
    Free(buf);
    Free(last_buf);
    DrvUnlock(dv);
    return res;
}

I64 FAT32FileWrite(CDrv *dv, U8 *cur_dir, U8 *name, U8 *buf, I64 size, CDate cdt, I64 attr)
{
    CDirEntry de;
    I64 c = 0, blk_cnt;
    Bool contiguous;
    MemSet(&de, 0, sizeof(CDirEntry));
    if (size < 0)
        size = 0;
    if (dv->fs_type != FSt_FAT32)
        PrintErr("Not FAT32 Drv\n");
    else if (!CFileNameTo(de.name, name))
        PrintErr("Invalid FileName: \"%s\".\n", name);
    else {
        FAT32FilesDel(dv, cur_dir, de.name, 0, FALSE, FALSE);
        if (attr & RS_ATTR_CONTIGUOUS)
            contiguous = TRUE;
        else
            contiguous = FALSE;
        de.size = size;
        if (blk_cnt = (size + BLK_SIZE - 1) >> BLK_SIZE_BITS)
            c = ClusAlloc(dv, 0, (blk_cnt + dv->spc - 1) / dv->spc, contiguous);
        else
            c = 0;  // An empty file has no clusters.
        if (c == INVALID_CLUS)
            return c;
        de.clus = c;
        de.attr = attr;
        de.datetime = cdt;
        if (blk_cnt)
            ClusBlkWrite(dv, buf, c, blk_cnt);
        FAT32DirNew(dv, cur_dir, &de, TRUE);
    }
    return c;
}

CDirEntry *FAT32FilesFind(U8 *files_find_mask, I64 fuf_flags, CDirEntry *parent = NULL, I64 *_dir_size = NULL)
{
    CDrv *dv = DrvCur;
    CFAT32DirEntry *buf;
    I64 attr, xsum = 0, dir_size = 0, sub_dir_size, cur_dir_clus, cur_dir_entry, entries_per_clus;
    U8 ch;
    CDirEntry *res = NULL, *tmpde, long_name;
    MemSet(&long_name, 0, sizeof(CDirEntry));
    DrvLock(dv);
    cur_dir_clus = Name2DirClus(dv, Fs->cur_dir);
    if (!cur_dir_clus) {
        DrvUnlock(dv);
        return NULL;
    }
    buf = MAlloc(BLK_SIZE * dv->spc);
    entries_per_clus = dv->spc << FAT32_ENTRIES_BITS;
    ClusRead(dv, buf, cur_dir_clus, 1);
    dir_size += dv->spc * BLK_SIZE;
    cur_dir_entry = 0;
    while (ch = buf[cur_dir_entry].name[0]) {
        attr = buf[cur_dir_entry].attr;
        if (ch != 0xE5) {
            if (attr & RS_ATTR_LONG_NAME_MASK == RS_ATTR_LONG_NAME)
                DirLongNameFill(&long_name, &buf[cur_dir_entry], &xsum);
            else {
                if (!(attr & RS_ATTR_VOL_ID)) {
                    tmpde = MAlloc(sizeof(CDirEntry));
                    if (xsum == FATNameXSum(buf[cur_dir_entry].name))
                        MemCpy(tmpde, &long_name, sizeof(CDirEntry));
                    else
                        MemSet(tmpde, 0, sizeof(CDirEntry));
                    if (FAT32CDirFill(tmpde, &buf[cur_dir_entry], dv->fat32_local_time_offset)) {
                        tmpde->parent = parent;
                        if (Bt(&fuf_flags, FUf_RECURSE) && attr & RS_ATTR_DIR && tmpde->name[0] != '.') {
                            tmpde->next = res;
                            res = tmpde;
                            tmpde->full_name = DirNameAbs(tmpde->name);
                            DrvUnlock(dv);
                            if (Cd(tmpde->name)) {
                                tmpde->sub = FAT32FilesFind(files_find_mask, fuf_flags, tmpde, &sub_dir_size);
                                tmpde->size = sub_dir_size;
                                Cd("..");
                            }
                            DrvLock(dv);
                        } else {
                            tmpde->full_name = FileNameAbs(tmpde->name);
                            if ((attr & RS_ATTR_DIR || !Bt(&fuf_flags, FUf_JUST_DIRS)) &&
                                    !(Bt(&fuf_flags, FUf_RECURSE) && tmpde->name[0] == '.' && attr & RS_ATTR_DIR) &&
                                    FilesFindMatch(tmpde->full_name, files_find_mask, fuf_flags)) {
                                tmpde->next = res;
                                res = tmpde;
                            } else
                                DirEntryDel(tmpde);
                        }
                    } else
                        DirEntryDel(tmpde);
                }
                MemSet(&long_name, 0, sizeof(CDirEntry));
            }
        } else
            MemSet(&long_name, 0, sizeof(CDirEntry));
        if (++cur_dir_entry == entries_per_clus) {
            cur_dir_clus = ClusNumNext(dv, cur_dir_clus);
            if (cur_dir_clus == INVALID_CLUS)
                break;
            else {
                ClusRead(dv, buf, cur_dir_clus, 1);
                dir_size += dv->spc * BLK_SIZE;
                cur_dir_entry = 0;
            }
        }
    }
    Free(buf);
    DrvUnlock(dv);
    if (_dir_size)
        *_dir_size = dir_size;
    return res;
}

Bool FAT32MkDir(CDrv *dv, U8 *cur_dir, U8 *name, I64 entry_cnt)
{
    I64 c, cur_dir_clus = Name2DirClus(dv, cur_dir), clus_bytes = dv->spc << BLK_SIZE_BITS,
            // Rough estimate of size
            size = ((entry_cnt + 2) * sizeof(CFAT32DirEntry) + clus_bytes - 1) / clus_bytes * clus_bytes;
    U8 *buf = CAlloc(size);
    CDirEntry d_native;
    CFAT32DirEntry *dFAT = buf;

    if (!cur_dir_clus) {
        Free(buf);
        return FALSE;
    }
    c = FileWrite(name, buf, size, 0, RS_ATTR_DIR);
    if (!(0 < c < 0x0FFFFFF8)) {
        Free(buf);
        return FALSE;
    }
    MemSet(&d_native, 0, sizeof(CDirEntry));
    d_native.attr = RS_ATTR_DIR;
    d_native.name[0] = '.';
    d_native.name[1] = 0;
    d_native.clus = c;
    d_native.size = 0;
    d_native.datetime = Now;
    FAT32DirFill(dFAT, &d_native, NULL, dv->fat32_local_time_offset);
    dFAT++;

    MemSet(&d_native, 0, sizeof(CDirEntry));
    d_native.attr = RS_ATTR_DIR;
    d_native.name[0] = '.';
    d_native.name[1] = '.';
    d_native.name[2] = 0;
    if (cur_dir_clus == dv->root_clus)
        d_native.clus = 0;  // FAT: ".." of a child of the root is 0
    else
        d_native.clus = cur_dir_clus;
    d_native.size = 0;
    d_native.datetime = Now;
    FAT32DirFill(dFAT, &d_native, NULL, dv->fat32_local_time_offset);
    ClusWrite(dv, buf, c, 1);
    Free(buf);
    return TRUE;
}
