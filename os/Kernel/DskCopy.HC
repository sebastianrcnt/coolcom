// File commands, from TempleOS by Terry A. Davis (public domain) as kept in
// Aiwnios (nrootconauto, commit e155e87): Del (Src/DskCopy.HC), Copy and
// Move (Src/ADskA.HC), IsDir (Src/DskDirB.HC). CopySingle is TempleOS's
// CopySingleZ (whole-file read and write; there is no CFile yet). Type prints
// plain text (TempleOS shows a DolDoc); MkDir and Rename are aliases.

Bool IsDir(U8 *dir_name)
{//Is a str a valid, existing Dir?
    U8 *mask = MAlloc(StrLen(dir_name) + 3);
    Bool res, old_silent = Silent;
    CDirContext *dirc;
    StrCpy(mask, dir_name);
    StrCat(mask, "/*");
    if (dirc = DirContextNew(mask)) {
        DirContextDel(dirc);
        res = TRUE;
    } else
        res = FALSE;
    Free(mask);
    Silent(old_silent);
    return res;
}

CDirEntry *DskTreeEntries(U8 *path, Bool *ok)
{//Snapshot a validated directory; distinguish an empty directory from a failed read.
    CDirContext *ctx;
    CFAT32DirEntry *buf;
    CDirEntry entry, *e, *list = NULL;
    I64 first, count, i, sum = -1;
    U8 *mask = MStrPrint("%s/*", path);
    Bool unlock;
    *ok = FALSE;
    ctx = DirContextNew(mask);
    Free(mask);
    if (!ctx) return NULL;
    unlock = DrvLock(ctx->dv);
    first = Name2DirClus(ctx->dv, Fs->cur_dir);
    buf = FAT32DirLoad(ctx->dv, first, &count);
    if (!buf) goto entries_done;
    MemSet(&entry, 0, sizeof(CDirEntry));
    for (i = 0; i < count && buf[i].name[0]; i++) {
        if (buf[i].name[0] == 0xE5) {sum = -1; MemSet(&entry, 0, sizeof(CDirEntry));}
        else if (buf[i].attr == RS_ATTR_LONG_NAME) DirLongNameFill(&entry, &buf[i], &sum);
        else {
            if (sum != FATNameXSum(buf[i].name) || entry.user_data) entry.name[0] = 0;
            if (!FAT32CDirFill(&entry, &buf[i], ctx->dv->fat32_local_time_offset)) goto entries_done;
            if (!(entry.attr & RS_ATTR_VOL_ID) && StrCmp(entry.name, ".") && StrCmp(entry.name, "..")) {
                e = MAlloc(sizeof(CDirEntry)); MemCpy(e, &entry, sizeof(CDirEntry));
                e->full_name = FileNameAbs(e->name); e->next = list; list = e;
            }
            sum = -1; MemSet(&entry, 0, sizeof(CDirEntry));
        }
    }
    *ok = TRUE;
entries_done:
    Free(buf);
    if (unlock) DrvUnlock(ctx->dv);
    DirContextDel(ctx);
    if (!*ok) {DirTreeDel(list); list = NULL;}
    return list;
}

I64 DelOne(U8 *path, Bool print_msg)
{//Unlink one entry only; the recursive walker has already removed its children.
    CDirContext *ctx;
    I64 n = -1;
    if (ctx = DirContextNew(path)) {
        n = FAT32FilesDel(ctx->dv, Fs->cur_dir, ctx->mask, 0, TRUE, print_msg);
        if (BlkFlush(ctx->dv->bd->unit)) n = -1;
        DirContextDel(ctx);
    }
    return n;
}

Bool DskTreeDelete(U8 *path, I64 *done, I64 *failed, I64 depth, Bool print_msg)
{
    CDirEntry de, *list, *e;
    Bool ok = TRUE, readable;
    if (depth > 128 || !FileFind(path, &de)) goto tree_del_fail;
    Free(de.full_name);
    if (de.attr & RS_ATTR_DIR) {
        list = DskTreeEntries(path, &readable);
        if (!readable) goto tree_del_fail;
        for (e = list; e; e = e->next)
            if (StrCmp(e->name, ".") && StrCmp(e->name, ".."))
                if (!DskTreeDelete(e->full_name, done, failed, depth + 1, print_msg)) ok = FALSE;
        DirTreeDel(list);
    }
    if (!ok) return FALSE;
    if (DelOne(path, print_msg) != 1) goto tree_del_fail;
    (*done)++;
    return TRUE;
tree_del_fail:
    (*failed)++;
    PrintErr("Delete failed: %s\n", path);
    return FALSE;
}

I64 Del(U8 *files_find_mask, Bool make_mask = FALSE, Bool del_dir = FALSE, Bool print_msg = TRUE)
{//Recursive for an explicit directory. Returns removed entries, -1 on partial failure.
    CDirEntry de, *list, *e;
    I64 done = 0, failed = 0;
    U8 *abs = FileNameAbs(files_find_mask);
    no_warn del_dir;
    if (StrLen(abs) <= 3 || !StrCmp(files_find_mask, ".") || !StrCmp(files_find_mask, "..")) {
        Free(abs); return -1;
    }
    if (!make_mask && FileFind(abs, &de)) {
        Free(de.full_name);
        DskTreeDelete(abs, &done, &failed, 0, print_msg);
    } else {
        list = FilesFind(abs);
        for (e = list; e; e = e->next)
            if (StrCmp(e->name, ".") && StrCmp(e->name, ".."))
                DskTreeDelete(e->full_name, &done, &failed, 0, print_msg);
        DirTreeDel(list);
    }
    Free(abs);
    if (failed) {PrintErr("Del: %d removed, %d failed; partial results remain\n", done, failed); return -1;}
    return done;
}

Bool CopySingle(U8 *f1, U8 *f2)
{//Just one file.
    U8 *file_buf = NULL, *absf1 = FileNameAbs(f1), *absf2 = FileNameAbs(f2);
    I64 size, attr = 0, c;
    CDirEntry de;
    Bool same = !StrICmp(absf1, absf2);
    Free(absf1);
    Free(absf2);
    if (same)  // onto self?
        return FALSE;
    if (FileFind(f1, &de, FUF_JUST_FILES)) {
        Free(de.full_name);
        file_buf = FileRead(f1, &size, &attr);
        attr = FileAttr(f2, attr);
        if (file_buf) {
            "Copying %s to %s\n", f1, f2;
            c = FileWrite(f2, file_buf, size, de.datetime, attr);
            Free(file_buf);
            return c != INVALID_CLUS;
        }
    }
    PrintErr("File not found: \"%s\".\n", f1);
    return FALSE;
}

Bool DskTreeCopy(U8 *src, U8 *dst, I64 *done, I64 *failed, I64 depth)
{
    CDirEntry de, *e, *list;
    U8 *target;
    Bool ok = TRUE, readable;
    if (depth > 128 || !FileFind(src, &de)) goto tree_copy_fail;
    Free(de.full_name);
    if (!(de.attr & RS_ATTR_DIR)) {
        if (!CopySingle(src, dst)) goto tree_copy_fail;
        (*done)++;
        return TRUE;
    }
    if (!IsDir(dst) && !DirMk(dst)) goto tree_copy_fail;
    (*done)++;
    list = DskTreeEntries(src, &readable);
    if (!readable) goto tree_copy_fail;
    for (e = list; e; e = e->next) {
        if (StrCmp(e->name, ".") && StrCmp(e->name, "..")) {
            target = MStrPrint("%s/%s", dst, e->name);
            if (!DskTreeCopy(e->full_name, target, done, failed, depth + 1)) ok = FALSE;
            Free(target);
        }
    }
    DirTreeDel(list);
    return ok;
tree_copy_fail:
    (*failed)++;
    PrintErr("Copy failed: %s -> %s\n", src, dst);
    return FALSE;
}

Bool DskCopyTarget(U8 *src, U8 *dst, I64 *done, I64 *failed)
{//Reject copying onto self or into a descendant, including normalized ../ paths.
    U8 *a = FileNameAbs(src), *b = FileNameAbs(dst);
    I64 n = StrLen(a);
    CDirEntry source, parent;
    U8 *ancestor;
    Bool ok, inside = FALSE;
    if (a[0] == b[0] && FileFind(a, &source)) {
        Free(source.full_name);
        if (source.attr & RS_ATTR_DIR) {
            ancestor = StrNew(b);
            while (StrLen(ancestor) > 3) {
                if (FileFind(ancestor, &parent)) {
                    Free(parent.full_name);
                    if (parent.attr & RS_ATTR_DIR && parent.clus == source.clus) inside = TRUE;
                }
                StrLastRem(ancestor, "/");
            }
            Free(ancestor);
        }
    }
    if (inside || !StrICmp(a, b) || StrLen(b) > n && !StrNICmp(a, b, n) && b[n] == '/') {
        (*failed)++;
        PrintErr("Copy target is inside source: %s\n", b);
        ok = FALSE;
    } else ok = DskTreeCopy(a, b, done, failed, 0);
    Free(a); Free(b);
    return ok;
}

Bool Copy(U8 *src_files_find_mask, U8 *dst_files_find_mask = ".")
{//Directory destinations receive the source basename, like file destinations.
    CDirEntry de, *list, *e;
    I64 done = 0, failed = 0;
    U8 *target;
    Bool directory = IsDir(dst_files_find_mask);
    if (FileFind(src_files_find_mask, &de)) {
        target = StrNew(dst_files_find_mask);
        if (directory) {Free(target); target = MStrPrint("%s/%s", dst_files_find_mask, de.name);}
        DskCopyTarget(de.full_name, target, &done, &failed);
        Free(target); Free(de.full_name);
    } else {
        list = FilesFind(src_files_find_mask);
        if (!list || !directory) failed++;
        else for (e = list; e; e = e->next) {
                if (StrCmp(e->name, ".") && StrCmp(e->name, "..")) {
                    target = MStrPrint("%s/%s", dst_files_find_mask, e->name);
                    DskCopyTarget(e->full_name, target, &done, &failed);
                    Free(target);
                }
            }
        DirTreeDel(list);
    }
    if (failed) PrintErr("Copy: %d copied, %d failed; partial results remain\n", done, failed);
    return !failed;
}

Bool Move(U8 *f1, U8 *f2)
{//Copy then remove only after the entire copy succeeds. Cross-drive moves work too.
    if (!Copy(f1, f2)) return FALSE;
    if (Del(f1) < 0) {PrintErr("Move: destination copied, source partially removed\n"); return FALSE;}
    return TRUE;
}

Bool Rename(U8 *f1, U8 *f2)
{//Same as Move().
    return Move(f1, f2);
}

Bool MkDir(U8 *filename, I64 entry_cnt = 0)
{//Same as DirMk().
    return DirMk(filename, entry_cnt);
}

U0 Type(U8 *filename, I64 trailing_new_lines = 1)
{//Print a text file.
    I64 size;
    U8 *buf = FileRead(filename, &size);
    if (buf) {
        Print("%s", buf);
        while (trailing_new_lines-- > 0)
            '\n';
        Free(buf);
    }
}
