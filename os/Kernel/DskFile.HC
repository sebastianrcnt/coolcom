// Whole-file read and write, from TempleOS by Terry A. Davis (public domain)
// as kept in Aiwnios (nrootconauto, commit e155e87, Src/DskFile.HC). No
// resident-file hash, no .Z compression, FAT32 only.

U8 *FileRead(U8 *filename, I64 *_size = NULL, I64 *_attr = NULL)
{//Read whole file from disk. MAlloced, with a terminating zero; NULL if not found.
    U8 *res = NULL;
    I64 size = 0, attr = 0;
    CDirContext *dirc;
    if (dirc = DirContextNew(filename)) {
        switch (dirc->dv->fs_type) {
            case FSt_FAT32:
                res = FAT32FileRead(dirc->dv, Fs->cur_dir, dirc->mask, &size, &attr);
                break;
            default:
                PrintErr("File System Not Supported\n");
        }
        DirContextDel(dirc);
    }
    if (!res)
        PrintErr("File not found: \"%s\".\n", filename);
    if (_attr)
        *_attr = attr;
    if (_size)
        *_size = size;
    return res;
}

I64 FileWrite(U8 *filename, U8 *fbuf, I64 size, CDate cdt = 0, I64 attr = 0)
{//Write whole file to disk. Returns its first cluster.
    I64 c = 0;
    CDirContext *dirc;
    if (dirc = DirContextNew(filename, FALSE, TRUE)) {
        attr = FileAttr(dirc->mask, attr);
        if (!cdt)
            cdt = Now;
        switch (dirc->dv->fs_type) {
            case FSt_FAT32:
                c = FAT32FileWrite(dirc->dv, Fs->cur_dir, dirc->mask, fbuf, size, cdt, attr);
                break;
            default:
                PrintErr("File System Not Supported\n");
        }
        BlkFlush(dirc->dv->bd->unit);
        DirContextDel(dirc);
    }
    return c;
}
