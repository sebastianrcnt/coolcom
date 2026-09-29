// File name strings, from TempleOS by Terry A. Davis (public domain) as kept
// in Aiwnios (nrootconauto, commit e155e87): Src/DskStrA.HC and parts of
// Src/DskStrB.HC, plus the few TempleOS library routines they use (StrA.HC,
// StrPrint.HC, KDataTypes.HC) that the kernel did not have yet. Compressed
// (.Z) files and the resident file hash are left out.

// ---- Library routines the disk code expects ----

U32 char_bmp_filename[16] = {
    0x0000000, 0x03FF73FB, 0xEFFFFFFF, 0x6FFFFFFF,
    0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
    0, 0, 0, 0, 0, 0, 0, 0};

Bool Bt(U8 *bits, I64 bit)
{
    return (bits[bit >> 3] >> (bit & 7)) & 1;
}

Bool LBts(I64 *bits, I64 bit)
{//Atomically set a bit of an I64 array; returns the old value.
    I64 *p = bits + (bit >> 6), m = 1 << (bit & 63), old;
    while (TRUE) {
        old = *p;
        if (ArchCas(p, old, old | m) == old)
            return (old & m) != 0;
    }
}

Bool LBtr(I64 *bits, I64 bit)
{//Atomically clear a bit of an I64 array; returns the old value.
    I64 *p = bits + (bit >> 6), m = 1 << (bit & 63), old;
    while (TRUE) {
        old = *p;
        if (ArchCas(p, old, old & ~m) == old)
            return (old & m) != 0;
    }
}

I64 Bsr(U64 v)
{//Index of the highest set bit, -1 for 0.
    I64 i;
    for (i = 63; i >= 0; i--)
        if ((v >> i) & 1)
            return i;
    return -1;
}

Bool dsk_silent;

Bool Silent(Bool val = TRUE)
{//Turn off PrintErr messages; returns the old setting.
    Bool old = dsk_silent;
    dsk_silent = val;
    return old;
}

U0 PrintErr(U8 *fmt, ...)
{
    U8 buf[512], *d = buf;
    if (dsk_silent)
        return;
    KFmt(&d, fmt, argc, argv);
    Print("ERROR: %s", buf);
}

U8 *StrLastOcc(U8 *src, U8 *marker)
{//Point to last occurrence of marker set in str.
    I64 ch;
    U8 *res = NULL;
    while (ch = *src++)
        if (StrOcc(marker, ch))
            res = src - 1;
    return res;
}

U8 *StrFirstRem(U8 *src, U8 *marker, U8 *dst = NULL)
{//Remove first str segment and place in dst buf or NULL.
    I64 ch;
    U8 *ptr = src, *res = dst;
    if (dst) {
        while ((ch = *ptr++) && !StrOcc(marker, ch))
            *dst++ = ch;
        *dst = 0;
    } else
        while ((ch = *ptr++) && !StrOcc(marker, ch)) {}
    if (ch)
        StrCpy(src, ptr);
    else
        *src = 0;
    return res;
}

U8 *StrLastRem(U8 *src, U8 *marker, U8 *dst = NULL)
{//Remove last str segment and place in dst buf or NULL.
    U8 *ptr;
    if (ptr = StrLastOcc(src, marker)) {
        if (dst)
            StrCpy(dst, ptr + 1);
        *ptr = 0;
    } else {
        if (dst)
            StrCpy(dst, src);
        *src = 0;
    }
    return dst;
}

U8 *MStrTrim(U8 *src)
{//MAlloc copy without leading/trailing white space and control chars
    //(TempleOS MStrUtil(src, SUF_REM_LEADING|SUF_REM_TRAILING|SUF_REM_CTRL_CHARS)).
    U8 *res = MAlloc(StrLen(src) + 1), *dst = res;
    while (*src && *src <= ' ')
        src++;
    while (*src) {
        if (*src >= ' ')
            *dst++ = *src;
        src++;
    }
    *dst = 0;
    while (dst > res && dst[-1] == ' ')
        *--dst = 0;
    return res;
}

Bool WildMatch(U8 *test_str, U8 *wild_str)
{//Wildcard match with '*' and '?'. FAT names are case-insensitive, so this is too.
    I64 ch1, ch2;
    U8 *fall_back_src = NULL, *fall_back_wild = NULL;
    while (TRUE) {
        if (!(ch1 = ToUpper(*test_str++))) {
            if (*wild_str && *wild_str != '*')
                return FALSE;
            else
                return TRUE;
        } else {
            if (!(ch2 = ToUpper(*wild_str++)))
                return FALSE;
            else {
                if (ch2 == '*') {
                    fall_back_wild = wild_str - 1;
                    fall_back_src = test_str;
                    if (!(ch2 = ToUpper(*wild_str++)))
                        return TRUE;
                    while (ch2 != ch1)
                        if (!(ch1 = ToUpper(*test_str++)))
                            return FALSE;
                } else if (ch2 != '?' && ch1 != ch2) {
                    if (fall_back_wild) {
                        wild_str = fall_back_wild;
                        test_str = fall_back_src;
                        fall_back_wild = NULL;
                        fall_back_src = NULL;
                    } else
                        return FALSE;
                }
            }
        }
    }
}

I64 LinkedLstCnt(U8 **_lst)
{//Count of nodes in a singly linked list (next pointer first).
    I64 res = 0;
    while (_lst) {
        _lst = *_lst;
        res++;
    }
    return res;
}

// ---- DskStrA.HC ----

U8 *FileExtDot(U8 *src)
{//Find dot char in name.
    I64 ch;
    while (ch = *src++)
        if (ch == '.' && *src != '/' && *src != '.')
            return src - 1;
    return NULL;
}

U8 *FileExtRem(U8 *src, U8 *dst = NULL)
{//Remove filename extension from str.
    U8 *ptr;
    if (ptr = FileExtDot(src)) {
        if (dst)
            StrCpy(dst, ptr + 1);
        *ptr = 0;
    } else if (dst)
        *dst = 0;
    return dst;
}

Bool IsDotC(U8 *filename)
{//Does name end in .C?
    I64 i = StrLen(filename);
    if (StrOcc(filename, '.') > 1 && filename[i - 1] == 'C' && filename[i - 2] == '.')
        return TRUE;
    else
        return FALSE;
}

Bool FilesFindMatch(U8 *_test_name, U8 *files_find_mask, I64 fuf_flags = 0)
{//Does filename meet Files Find mask? (';' separates masks, '!' excludes.)
    I64 tn_len = StrLen(_test_name), mask_len = StrLen(files_find_mask);
    U8 *mask1 = MAlloc(mask_len + 1), *mask2 = MAlloc(mask_len + 1), *ptr, *test_name1, *test_name2;
    Bool res = FALSE;
    no_warn fuf_flags;
    StrCpy(mask1, files_find_mask);
    if (StrOcc(_test_name, '/')) {
        test_name1 = MAlloc(tn_len + 1);
        test_name2 = MAlloc(tn_len + 1);
        StrCpy(test_name1, _test_name);
        StrLastRem(test_name1, "/", test_name2);
    } else {
        test_name1 = NULL;
        test_name2 = NULL;
    }
    while (TRUE) {
        StrFirstRem(mask1, ";", mask2);
        if (!test_name2 || StrOcc(mask2, '/'))
            ptr = _test_name;
        else
            ptr = test_name2;
        if (*mask2) {
            if (*mask2 == '!') {
                if (WildMatch(ptr, mask2 + 1)) {
                    res = FALSE;
                    break;
                }
            } else if (WildMatch(ptr, mask2))
                res = TRUE;
        } else
            break;
    }
    Free(test_name1);
    Free(test_name2);
    Free(mask1);
    Free(mask2);
    return res;
}

I64 FileAttr(U8 *name, I64 attr = 0)
{
    if (IsDotC(name))
        attr |= RS_ATTR_CONTIGUOUS;
    return attr;
}

Bool FileNameChk(U8 *filename)
{//Return check for valid filename, not checking existence.
    U8 *ptr = filename;
    if (!filename)
        return FALSE;
    if (!*ptr)
        return FALSE;
    if (*ptr == '.') {
        if (!ptr[1])
            return TRUE;
        if (ptr[1] == '.' && !ptr[2])
            return TRUE;
    }
    if (StrLen(filename) >= CDIR_FILENAME_LEN)
        return FALSE;
    while (*ptr)
        if (!Bt(char_bmp_filename, *ptr++))
            return FALSE;
    return TRUE;
}

// ---- DskStrB.HC ----

Bool CFileNameTo(U8 *dst, U8 *src)
{
    MemSet(dst, 0, CDIR_FILENAME_LEN);
    if (!FileNameChk(src))
        return FALSE;
    StrCpy(dst, src);
    return TRUE;
}

// ---- DskStrA.HC: absolute names ----

extern CDrv *DrvCur();
extern U8 Drv2Let(CDrv *dv = NULL);

U8 *DirNameAbs(U8 *_dirname)
{//MAlloc absolute dir string with drv letter.
    I64 maxlen;
    U8 drv[3], *res, *buf, *buf2, *buf3, *buf4, *dirname, *free_dirname;
    CTask *task = Fs;
    DrvCur;
    if (!task->cur_dir || !*task->cur_dir)
        return StrNew(_dirname);
    free_dirname = dirname = MStrTrim(_dirname);
    drv[0] = Drv2Let;
    drv[1] = ':';
    drv[2] = 0;
    if (*dirname && dirname[1] == ':') {
        if (*dirname == ':')
            drv[0] = blkdev.boot_drv_let;
        else
            drv[0] = ToUpper(*dirname);
        dirname = dirname + 2;
        buf = StrNew("/");
    } else
        buf = StrNew(task->cur_dir);
    if (*dirname == '/') {
        Free(buf);
        buf = StrNew("/");
        dirname++;
    }
    buf2 = StrNew(dirname);
    maxlen = StrLen(buf) + 1 + StrLen(buf2) + 1;
    buf3 = MAlloc(maxlen);
    buf4 = MAlloc(maxlen);
    StrCpy(buf3, buf);
    while (*buf2) {
        StrFirstRem(buf2, "/", buf4);
        if (!*buf4)
            StrCpy(buf3, "/");
        else if (!StrCmp(buf4, "..")) {
            StrLastRem(buf3, "/");
            if (!*buf3)
                StrCpy(buf3, "/");
        } else if (StrCmp(buf4, ".") && *buf4) {
            if (StrCmp(buf3, "/"))
                StrCat(buf3, "/");
            StrCat(buf3, buf4);
        }
    }
    Free(buf);
    res = MAlloc(StrLen(buf3) + 3);
    StrCpy(res, drv);
    StrCpy(res + 2, buf3);
    Free(buf2);
    Free(buf3);
    Free(buf4);
    Free(free_dirname);
    return res;
}

U8 *FileNameAbs(U8 *_filename)
{//Absolute filename.
    U8 *res, *filename, *buf, *buf_file, *buf_dir, *free_filename, *free_buf;
    free_filename = filename = MStrTrim(_filename);
    free_buf = buf = StrNew(filename);
    if (*buf && buf[1] == ':') {
        buf += 2;
        filename += 2;
    }
    buf_file = MAlloc(StrLen(free_filename) + 1);
    StrLastRem(buf, "/", buf_file);
    if (*filename == '/' && !*buf)
        StrCpy(buf, "/");
    buf_dir = DirNameAbs(free_buf);
    Free(free_buf);
    res = MAlloc(StrLen(buf_dir) + 1 + StrLen(buf_file) + 1);
    StrCpy(res, buf_dir);
    if (res[StrLen(res) - 1] != '/')
        StrCat(res, "/");
    StrCat(res, buf_file);
    Free(buf_file);
    Free(buf_dir);
    Free(free_filename);
    return res;
}

U8 *DirCur()
{//MAlloc copy of cur dir with drv letter.
    U8 *st;
    CTask *task = Fs;
    if (!DrvCur || !task->cur_dir)
        return NULL;
    st = MAlloc(StrLen(task->cur_dir) + 3);
    *st = Drv2Let(task->cur_dv);
    st[1] = ':';
    StrCpy(st + 2, task->cur_dir);
    return st;
}
