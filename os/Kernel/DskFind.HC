// Directory contexts and finding files, from TempleOS by Terry A. Davis
// (public domain) as kept in Aiwnios (nrootconauto, commit e155e87):
// Src/DskDirContext.HC and Src/DskFind.HC. FAT32 only; no .Z alternatives.

U0 DirContextDel(CDirContext *dirc, Bool restore = TRUE)
{//Change back to old cur_dir and drv.
    CBlkDev *bd;
    CTask *task = Fs;
    if (!dirc)
        return;
    if (restore) {
        bd = dirc->old_dv->bd;
        if (!(bd->flags & BDF_INIT_IN_PROGRESS)) {
            if (dirc->old_dir) {
                Drv(Drv2Let(dirc->old_dv));
                Cd(dirc->old_dir);
            }
        } else {
            task->cur_dv = dirc->old_dv;
            Free(task->cur_dir);
            task->cur_dir = StrNew("/");
        }
    }
    Free(dirc->old_dir);
    Free(dirc->mask);
    Free(dirc);
}

CDirContext *DirContextNew(U8 *_mask, Bool make_mask = FALSE, Bool make_dirs = FALSE, Bool no_mask = FALSE)
{//Save cur_dir and drv. Change to new dir.
    Bool valid = TRUE, old_silent;
    I64 mask_len = StrLen(_mask);
    U8 *buf, *mask, *tmp_mask, *semicolon_mask;
    CTask *task = Fs;
    CDirContext *dirc;
    if (!DrvCur) {
        PrintErr("No drive\n");
        return NULL;
    }
    dirc = CAlloc(sizeof(CDirContext));
    dirc->old_dir = StrNew(task->cur_dir);
    dirc->old_dv = task->cur_dv;
    mask = MStrTrim(_mask);
    tmp_mask = mask;
    if (*mask && mask[1] == ':') {
        if (task->cur_dv != Let2Drv(*mask) && !Drv(*mask))
            valid = FALSE;
        mask += 2;
    }
    dirc->dv = task->cur_dv;
    buf = MAlloc(mask_len + 2);
    StrCpy(buf, mask);

    dirc->mask = MAlloc(mask_len + 2);
    if (no_mask)
        *dirc->mask = 0;
    else if (StrOcc(buf, ';')) {
        semicolon_mask = MAlloc(mask_len + 2);
        StrCpy(semicolon_mask, mask);
        StrFirstRem(semicolon_mask, ";", buf);
        StrLastRem(buf, "/", dirc->mask);
        StrCat(dirc->mask, ";");
        StrCat(dirc->mask, semicolon_mask);
        Free(semicolon_mask);
    } else
        StrLastRem(buf, "/", dirc->mask);

    if (*mask == '/' && !*buf)
        StrCpy(buf, "/");
    // If began with Dir, change to Dir.
    if (valid && *buf && !Cd(buf, make_dirs))
        valid = FALSE;
    if (valid && make_mask) {
        if (!*dirc->mask) {
            Free(dirc->mask);
            dirc->mask = StrNew("*");
        } else {
            if (!make_dirs || FileNameChk(dirc->mask)) {
                old_silent = Silent;
                // Try mask to see if Dir. If Dir, change to dir and set to "*".
                if (Cd(dirc->mask, make_dirs)) {
                    Free(dirc->mask);
                    dirc->mask = StrNew("*");
                }
                Silent(old_silent);
            }
        }
    }
    Free(buf);
    Free(tmp_mask);
    if (!valid) {
        DirContextDel(dirc);
        dirc = NULL;
    }
    return dirc;
}

CDirEntry *FilesFind2(U8 *files_find_mask, I64 fuf_flags)
{
    CDrv *dv = DrvCur;
    CDirEntry *res = NULL;
    if (!DrvChk(dv))
        return NULL;
    switch (dv->fs_type) {
        case FSt_FAT32:
            res = FAT32FilesFind(files_find_mask, fuf_flags);
            break;
        default:
            PrintErr("File System Not Supported\n");
            res = NULL;
    }
    if (res) {
        DirFilesSort(&res);
        if (fuf_flags & (FUF_FLATTEN_TREE | FUF_JUST_FILES))
            DirFilesFlatten(res, &res, fuf_flags);
    }
    return res;
}

Bool FileFind(U8 *filename, CDirEntry *_de = NULL, I64 fuf_flags = 0)
{//FUF_JUST_DIRS, FUF_JUST_FILES, FUF_SCAN_PARENTS
    //If you pass _de, you must Free(_de->full_name);
    I64 cur_dir_clus;
    U8 *full_name = NULL;
    CDirEntry de;
    CDirContext *dirc;
    CTask *task = Fs;
    Bool res = FALSE, old_silent, scan;
    if (fuf_flags & ~FUG_FILE_FIND) {
        PrintErr("Bad FileFind flags\n");
        return FALSE;
    }
    if (!filename || *filename && filename[1] == ':' && !Let2Drv(*filename, FALSE))
        return FALSE;
    old_silent = Silent;
    dirc = DirContextNew(filename);
    Silent(old_silent);
    if (dirc) {
        scan = FALSE;
        while (TRUE) {
            cur_dir_clus = Name2DirClus(dirc->dv, task->cur_dir);
            if (cur_dir_clus)
                res = FAT32FileFind(dirc->dv, cur_dir_clus, dirc->mask, &de, fuf_flags & ~FUF_SCAN_PARENTS);
            if (res || !(fuf_flags & FUF_SCAN_PARENTS) || !StrCmp(task->cur_dir, "/"))
                break;
            Cd("..");
        }
        if (res && _de) {
            full_name = MAlloc(StrLen(task->cur_dir) + StrLen(de.name) + 4);
            full_name[0] = Drv2Let(task->cur_dv);
            full_name[1] = ':';
            StrCpy(full_name + 2, task->cur_dir);
            if (StrCmp(task->cur_dir, "/"))
                StrCat(full_name, "/");
            StrCat(full_name, de.name);
        }
        DirContextDel(dirc);
    }
    if (_de) {
        if (res) {
            MemCpy(_de, &de, sizeof(CDirEntry));
            _de->full_name = full_name;
        } else
            MemSet(_de, 0, sizeof(CDirEntry));
    }
    return res;
}

CDirEntry *FilesFind(U8 *files_find_mask, I64 fuf_flags = 0)
{/* Find files and make a directory tree in memory.
When done, you free with DirEntryDel() or DirTreeDel(). */
    CDirEntry *res;
    CDirContext *dirc;
    if (fuf_flags & ~FUG_FILES_FIND) {
        PrintErr("Bad FilesFind flags\n");
        return NULL;
    }
    if (fuf_flags & FUF_SINGLE) {
        res = MAlloc(sizeof(CDirEntry));
        if (!FileFind(files_find_mask, res)) {
            Free(res);
            return NULL;
        }
    } else if (dirc = DirContextNew(files_find_mask, TRUE)) {
        res = FilesFind2(dirc->mask, fuf_flags);
        DirContextDel(dirc);
    } else
        return NULL;
    return res;
}
