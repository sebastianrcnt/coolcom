// Current directory, listing and making directories, from TempleOS by Terry
// A. Davis (public domain) as kept in Aiwnios (nrootconauto, commit e155e87,
// Src/DskDirB.HC). FAT32 only; no home directory ("~"). Dir prints plain
// text: month/day and local time, hex size, name ("/" after directories).

extern Bool DirMk(U8 *filename, I64 entry_cnt = 0);

Bool Cd(U8 *dirname = NULL, Bool make_dirs = FALSE)
{//Change directory. Optionally, make directories, too.
    I64 maxlen, cur_dir_clus = 0;
    U8 *chg_to_buf, *new_cur_dir, *buf;
    CDrv *dv;
    CTask *task = Fs;
    Bool res = TRUE;
    if (!DrvCur) {
        PrintErr("No drive\n");
        return FALSE;
    }
    if (!dirname)
        dirname = "/";
    else if (!*dirname)
        return TRUE;
    if (dirname[1] == ':') {
        if (*dirname == ':') {
            if (task->cur_dv != Let2Drv(':') && !Drv(*dirname))
                return FALSE;
        } else if (task->cur_dv != Let2Drv(*dirname) && !Drv(*dirname))
            return FALSE;
        dirname += 2;
    }
    if (*dirname == '/' || !*dirname || !task->cur_dir) {
        Free(task->cur_dir);
        task->cur_dir = StrNew("/");
        if (*dirname == '/')
            dirname++;
    }
    chg_to_buf = MStrTrim(dirname);
    maxlen = StrLen(task->cur_dir) + 1 + StrLen(chg_to_buf) + 1;
    new_cur_dir = MAlloc(maxlen);
    buf = MAlloc(maxlen);
    StrCpy(new_cur_dir, task->cur_dir);
    while (*chg_to_buf && res) {
        StrFirstRem(chg_to_buf, "/", buf);
        if (!*buf)
            StrCpy(new_cur_dir, "/");
        else if (!StrCmp(buf, "..")) {
            StrLastRem(new_cur_dir, "/");
            if (!*new_cur_dir)
                StrCpy(new_cur_dir, "/");
        } else if (StrCmp(buf, ".") && *buf) {
            dv = task->cur_dv;
            switch (dv->fs_type) {
                case FSt_FAT32:
                    cur_dir_clus = Name2DirClus(dv, new_cur_dir);
                    res = cur_dir_clus && FAT32Cd(buf, cur_dir_clus);
                    break;
                default:
                    PrintErr("File System Not Supported\n");
                    res = FALSE;
            }
            if (!res && make_dirs) {
                Free(task->cur_dir);
                task->cur_dir = StrNew(new_cur_dir);
                res = DirMk(buf);
            }
            if (res) {
                if (StrCmp(new_cur_dir, "/"))
                    StrCat(new_cur_dir, "/");
                StrCat(new_cur_dir, buf);
            }
        }
    }
    if (res) {  // TempleOS keeps the part that worked; a failed Cd changes nothing here
        Free(task->cur_dir);
        task->cur_dir = StrNew(new_cur_dir);
    }
    Free(buf);
    Free(chg_to_buf);
    Free(new_cur_dir);
    return res;
}

I64 Dir(U8 *files_find_mask = "*", Bool full = FALSE)
{//List directory.
    CDirEntry *tmpde1 = NULL, *tmpde2;
    U8 *st;
    I64 csize = 0xFFFF, c = 0xFFFF, res = 0;
    CDateStruct ds;
    tmpde1 = FilesFind(files_find_mask);
    if (!(st = DirCur))
        PrintErr("Invalid Drive\n");
    else {
        if (tmpde1) {
            Free(st);
            st = StrNew(tmpde1->full_name);
            StrLastRem(st, "/");
            if (!st[2])
                StrCpy(st + 2, "/");
            // Find max columns
            tmpde2 = tmpde1;
            while (tmpde2) {
                if (tmpde2->size > csize)
                    csize = tmpde2->size;
                if (tmpde2->clus > c)
                    c = tmpde2->clus;
                tmpde2 = tmpde2->next;
            }
            csize = Bsr(csize) / 4 + 1;
            c = Bsr(c) / 4 + 1;

            "Directory of %s\n", st;
            if (full)
                "DATE_ TIME_ %-*s %-*s NAME\n", csize, "SIZE", c, "CLUS";
            else
                "DATE_ TIME_ %-*s NAME\n", csize, "SIZE";
            while (tmpde1) {
                tmpde2 = tmpde1->next;
                res++;
                Date2Struct(&ds, tmpde1->datetime + local_time_offset);
                "%02d/%02d %02d:%02d %0*X ", ds.mon, ds.day_of_mon, ds.hour, ds.min, csize, tmpde1->size;
                if (full)
                    "%0*X ", c, tmpde1->clus;
                if (tmpde1->attr & RS_ATTR_DIR)
                    "%s/\n", tmpde1->name;
                else
                    "%s\n", tmpde1->name;
                DirEntryDel(tmpde1);
                tmpde1 = tmpde2;
            }
        } else
            "No matching entries\n";
        Free(st);
    }
    return res;
}

Bool DirMk(U8 *filename, I64 entry_cnt = 0)
{//Make directory. Cd() can also make directories.
    //entry_cnt is for preallocating dir blks, leave it zero if you like.
    U8 *name;
    CDirContext *dirc;
    CTask *task = Fs;
    Bool res = FALSE;
    if (FileFind(filename,, FUF_JUST_DIRS))
        return FALSE;
    if (dirc = DirContextNew(filename)) {
        if (*dirc->mask) {
            if (!FileNameChk(dirc->mask))
                PrintErr("Invalid FileName: \"%s\".\n", dirc->mask);
            else {
                "Make Directory:%s\n", filename;
                name = MStrTrim(dirc->mask);
                switch (dirc->dv->fs_type) {
                    case FSt_FAT32:
                        res = FAT32MkDir(dirc->dv, task->cur_dir, name, entry_cnt);
                        break;
                    default:
                        PrintErr("File System Not Supported\n");
                }
                Free(name);
            }
        }
        DirContextDel(dirc);
    }
    return res;
}
