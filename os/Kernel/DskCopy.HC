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

I64 Del(U8 *files_find_mask, Bool make_mask = FALSE, Bool del_dir = FALSE, Bool print_msg = TRUE)
{//Delete files; returns how many.
    I64 res = 0;
    CDirContext *dirc;
    if (dirc = DirContextNew(files_find_mask, make_mask)) {
        switch (dirc->dv->fs_type) {
            case FSt_FAT32:
                res = FAT32FilesDel(dirc->dv, Fs->cur_dir, dirc->mask, 0, del_dir, print_msg);
                break;
            default:
                PrintErr("File System Not Supported\n");
        }
        BlkFlush(dirc->dv->bd->unit);
        DirContextDel(dirc);
    }
    return res;
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

Bool Copy(U8 *src_files_find_mask, U8 *dst_files_find_mask = ".")
{//Copy files: a mask into a directory, or one file to a new name.
    Bool res = TRUE;
    CDirContext *dirc;
    CDirEntry *tmpde, *tmpde1;
    U8 *st;
    if (!(tmpde1 = FilesFind(src_files_find_mask)))
        return FALSE;
    if (IsDir(dst_files_find_mask)) {
        if (dirc = DirContextNew(dst_files_find_mask, TRUE)) {
            tmpde = tmpde1;
            while (tmpde) {
                if (!(tmpde->attr & RS_ATTR_DIR)) {
                    st = FileNameAbs(tmpde->name);
                    if (!CopySingle(tmpde->full_name, st))
                        res = FALSE;
                    Free(st);
                }
                tmpde = tmpde->next;
            }
            DirContextDel(dirc);
        }
        DirTreeDel(tmpde1);
        return res;
    } else {
        DirTreeDel(tmpde1);
        return CopySingle(src_files_find_mask, dst_files_find_mask);
    }
}

Bool Move(U8 *f1, U8 *f2)
{//Move files from one location to another or rename.
    if (Copy(f1, f2)) {
        Del(f1);
        return TRUE;
    }
    return FALSE;
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
