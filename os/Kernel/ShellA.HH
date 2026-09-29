// Shell prelude: JIT-compiled by the shell (Shell.HC) after KernelA.HH, before
// the first command line. The shell registers each kernel routine below as a
// system symbol (ShellSyms), and in JIT mode `extern` binds a prototype to the
// system symbol of the same name, so shell code calls straight into the kernel.
// Keep the prototypes identical to the kernel's definitions.
extern U0 Print(U8 *fmt, ...);
extern U8 *StrPrint(U8 *dst, U8 *fmt, ...);
extern U0 PutChars(U64 ch);
extern U8 *MAlloc(I64 size);
extern U8 *CAlloc(I64 size);
extern U0 Free(U8 *p);
extern U8 *ReAlloc(U8 *p, I64 size);
extern I64 MSize(U8 *p);
extern U8 *StrNew(U8 *s);
extern U8 *MemSet(U8 *dst, I64 val, I64 cnt);
extern U8 *MemCpy(U8 *dst, U8 *src, I64 cnt);
extern I64 MemCmp(U8 *p1, U8 *p2, I64 cnt);
extern I64 StrLen(U8 *s);
extern U8 *StrCpy(U8 *dst, U8 *src);
extern U8 *StrCat(U8 *dst, U8 *src);
extern I64 StrCmp(U8 *s1, U8 *s2);
extern I64 StrNCmp(U8 *s1, U8 *s2, I64 n);
extern I64 StrICmp(U8 *s1, U8 *s2);
extern I64 ToUpper(I64 ch);
extern I64 ToLower(I64 ch);
extern U8 *StrFind(U8 *needle, U8 *haystack);
extern I64 GetKey(I64 *sc = NULL, Bool echo = TRUE);
extern I64 GetChar(I64 *sc = NULL, Bool echo = TRUE);
extern U8 *GetStr(U8 *buf, I64 size, Bool echo = TRUE);
extern U0 Yield();
extern U0 Sleep(I64 ms);
extern U0 TaskRep();
extern U0 HeapStats();
extern U0 ConsClear();
extern U0 FbFillRect(I64 x, I64 y, I64 w, I64 h, I64 color);
extern I64 BlkCount();
extern I64 BlkSectors(I64 dev);
extern I64 BlkRead(I64 dev, I64 lba, I64 cnt, U8 *buf);
extern I64 BlkWrite(I64 dev, I64 lba, I64 cnt, U8 *buf);
extern U8 *FileRead(U8 *filename, I64 *_size = NULL, I64 *_attr = NULL);
extern I64 FileWrite(U8 *filename, U8 *fbuf, I64 size, I64 cdt = 0, I64 attr = 0);
extern Bool Cd(U8 *dirname = NULL, Bool make_dirs = FALSE);
extern I64 Dir(U8 *files_find_mask = "*", Bool full = FALSE);
