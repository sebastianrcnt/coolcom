// Directory entries, from TempleOS by Terry A. Davis (public domain) as kept
// in Aiwnios (nrootconauto, commit e155e87, Src/DskDirA.HC). The DolDoc file
// and directory links are plain text here.

Bool DirNew(CDrv *dv, U8 *cur_dir, CDirEntry *tmpde, Bool free_old_chain = TRUE)
{//Makes a directory entry in the directory from a CDirEntry node.
    switch (dv->fs_type) {
        case FSt_FAT32:
            return FAT32DirNew(dv, cur_dir, tmpde, free_old_chain);
        default:
            PrintErr("File System Not Supported\n");
            return FALSE;
    }
}

U0 DirEntryDel(CDirEntry *tmpde)
{//Free node returned from FilesFind().  Doesn't Free user_data.
    //Does not change the directory on disk.
    if (tmpde) {
        Free(tmpde->full_name);
        Free(tmpde);
    }
}

U0 DirTreeDel(CDirEntry *tmpde)
{//Free tree returned from FilesFind().  Doesn't Free user_data.
    //Does not change the directory on disk.
    CDirEntry *tmpde2;
    while (tmpde) {
        tmpde2 = tmpde->next;
        if (tmpde->sub)
            DirTreeDel(tmpde->sub);
        DirEntryDel(tmpde);
        tmpde = tmpde2;
    }
}

I64 DirEntryCompareName(CDirEntry *e1, CDirEntry *e2)
{
    U8 buf1[CDIR_FILENAME_LEN], buf2[CDIR_FILENAME_LEN], buf3[CDIR_FILENAME_LEN], buf4[CDIR_FILENAME_LEN];
    I64 d1 = 0, d2 = 0;
    if (e1->attr & RS_ATTR_DIR)
        d1 = 1;
    if (e2->attr & RS_ATTR_DIR)
        d2 = 1;
    if (d1 != d2)
        return d2 - d1;
    else {
        StrCpy(buf1, e1->name);
        StrCpy(buf2, e2->name);
        FileExtRem(buf1, buf3);
        FileExtRem(buf2, buf4);
        if (d1 = StrCmp(buf3, buf4))
            return d1;
        return StrCmp(buf1, buf2);
    }
}

U0 DirFilesSort(CDirEntry **_tmpde)
{//Sort by name (TempleOS SK_NAME; an insertion sort instead of QSortI64).
    I64 i, j, cnt;
    CDirEntry *tmpde = *_tmpde, *tmpde1, **sort_buf;
    if (tmpde) {
        cnt = LinkedLstCnt(tmpde);
        if (cnt > 1) {
            sort_buf = MAlloc(cnt * sizeof(U8 *));
            i = 0;
            tmpde1 = tmpde;
            while (tmpde1) {
                sort_buf[i++] = tmpde1;
                tmpde1 = tmpde1->next;
            }
            for (i = 1; i < cnt; i++) {
                tmpde1 = sort_buf[i];
                j = i;
                while (j > 0 && DirEntryCompareName(sort_buf[j - 1], tmpde1) > 0) {
                    sort_buf[j] = sort_buf[j - 1];
                    j--;
                }
                sort_buf[j] = tmpde1;
            }
            tmpde = sort_buf[0];
            *_tmpde = tmpde;
            for (i = 0; i < cnt - 1; i++) {
                tmpde1 = sort_buf[i];
                tmpde1->next = sort_buf[i + 1];
            }
            tmpde1 = sort_buf[i];
            tmpde1->next = NULL;
            Free(sort_buf);

            tmpde1 = tmpde;
            while (tmpde1) {
                if (tmpde1->sub)
                    DirFilesSort(&tmpde1->sub);
                tmpde1 = tmpde1->next;
            }
        } else if (tmpde->sub)
            DirFilesSort(&tmpde->sub);
    }
}

CDirEntry **DirFilesFlatten(CDirEntry *tmpde, CDirEntry **_res, I64 fuf_flags)
{//Returns last node
    CDirEntry *tmpde1;
    Bool del;
    if (tmpde)
        while (TRUE) {
            tmpde1 = tmpde->next;
            if (!(tmpde->attr & RS_ATTR_DIR) || !(fuf_flags & FUF_JUST_FILES)) {
                *_res = tmpde;
                _res = tmpde;  // next is the first member
                del = FALSE;
            } else
                del = TRUE;
            if (tmpde->sub) {
                _res = DirFilesFlatten(tmpde->sub, _res, fuf_flags);
                tmpde->sub = NULL;
            }
            if (del)
                DirEntryDel(tmpde);
            if (tmpde1)
                tmpde = tmpde1;
            else
                break;
        }
    *_res = NULL;
    return _res;
}
