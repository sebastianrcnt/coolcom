// Device tests, run by KMain when booted with coolcom.test=1 under coolvm.
// tools/kernel-test.sh supplies a 64 KiB disk (128 sectors, sector s byte j =
// s*31 + j*7 mod 256), a FAT32 disk, a scripted input queue (mouse +5,-3,
// wheel +2, left button, then the keys h x BACKSPACE i SHIFT+a ENTER, then
// ten shell lines) and a 640x480 framebuffer, and afterwards checks the
// disk files, the screenshot and that the shell printed 49.

U8 dt_line[64];

U0 DevTestBlk()
{
    U8 *a = MAlloc(2048), *b = MAlloc(2048);
    I64 i, j, f0 = kt_fails;
    Print("blk: %d device(s), dev0 %d sectors\n", BlkCount, BlkSectors(0));
    if (BlkCount < 1 || BlkSectors(0) != 128) {
        KTFail("blk device missing or wrong size");
        goto blk_done;
    }
    if (BlkRead(0, 5, 2, a)) {
        KTFail("BlkRead");
        goto blk_done;
    }
    for (j = 0; j < 1024; j++)
        if (a[j] != ((5 + j / 512) * 31 + (j % 512) * 7) & 0xFF) {
            KTFail("blk read contents");
            break;
        }
    if (BlkRead(0, 127, 2, a) >= 0 || BlkRead(0, -1, 1, a) >= 0 || BlkRead(3, 0, 1, a) >= 0)
        KTFail("blk range checks");
    for (j = 0; j < 1024; j++)
        a[j] = j * 3 + 17;
    if (BlkWrite(0, 9, 2, a) || BlkFlush(0))
        KTFail("BlkWrite/BlkFlush");
    MemSet(b, 0, 1024);
    if (BlkRead(0, 9, 2, b) || MemCmp(a, b, 1024))
        KTFail("blk write readback");
    for (i = 0; i < 20; i++)  // many requests reuse the ring
        if (BlkRead(0, i, 1, b)) {
            KTFail("blk ring reuse");
            break;
        }
blk_done:
    Free(a);
    Free(b);
    if (kt_fails == f0)
        Print("  blk: PASS\n");
}

U8 *DevTestFsData(I64 n, I64 seed)
{//Printable test file contents; tools/kernel-verify.py makes the same.
    U8 *s = MAlloc(n);
    I64 j;
    for (j = 0; j < n; j++)
        if (j % 64 == 63)
            s[j] = '\n';
        else
            s[j] = 'A' + (j * 7 + seed) % 26;
    return s;
}

U0 DevTestFs()
{//Disk 1 is a FAT32 image made on the host (newfs_msdos) holding HostNote.txt.
    //Read it, write FromCoolcom.txt (twice, so the first copy is freed) and
    //Sub/Inner.TXT; the host checks them afterwards with mtools and fsck_msdos.
    I64 size, f0 = kt_fails;
    U8 *s, *a = DevTestFsData(3000, 0), *b = DevTestFsData(700, 5);
    DrvRep;
    if (sizeof(CFAT32Boot) != 512 || sizeof(CFAT32DirEntry) != 32 || sizeof(CFAT32DirEntryLong) != 32 ||
            offset(CFAT32Boot.root_clus) != 44)
        KTFail("fs: FAT structure layout");
    if (!Cd("C:/")) {
        KTFail("fs: no drive C:");
        goto fs_done;
    }
    s = FileRead("hostnote.txt", &size);
    if (!s || size != 20 || StrCmp(s, "Hello from the host\n"))
        KTFail("fs: FileRead of the host's file");
    Free(s);
    FileWrite("FromCoolcom.txt", b, 100);
    FileWrite("FromCoolcom.txt", a, 3000);
    if (!DirMk("Sub") || !Cd("Sub"))
        KTFail("fs: DirMk/Cd");
    FileWrite("Inner.TXT", b, 700);
    s = DirCur;
    Print("cur dir: %s\n", s);
    if (StrCmp(s, "C:/Sub"))
        KTFail("fs: DirCur in Sub");
    Free(s);
    Cd("..");
    if (Dir != 4)
        KTFail("fs: Dir count");
    s = FileRead("FromCoolcom.txt", &size);
    if (!s || size != 3000 || MemCmp(s, a, 3000))
        KTFail("fs: read back FromCoolcom.txt");
    Free(s);
    s = FileRead("C:/Sub/Inner.TXT", &size);
    if (!s || size != 700 || MemCmp(s, b, 700))
        KTFail("fs: read back Sub/Inner.TXT");
    Free(s);
    if (!Copy("C:/Sub/Inner.TXT", "C:/Copy.TXT") || !Move("Copy.TXT", "Moved.TXT") || FileFind("Copy.TXT") ||
            Del("Moved.TXT") != 1 || FileFind("Moved.TXT") || !IsDir("Sub") || IsDir("HostNote.txt"))
        KTFail("fs: Copy/Move/Del/IsDir");
    s = FileRead("Missing.TXT");
    if (s)
        KTFail("fs: FileRead of a missing file");
fs_done:
    Free(a);
    Free(b);
    if (kt_fails == f0)
        Print("  fs: PASS\n");
}

U0 DevTestInput()
{
    I64 deadline = ArchCntVct + 3 * ArchCntFrq, f0 = kt_fails;
    while (KbdPending < 7 && ArchCntVct < deadline)
        Sleep(10);
    if (KbdPending < 7) {
        KTFail("scripted keys not received");
        return;
    }
    GetStr(dt_line, 64);
    Print("input: [%s]\n", dt_line);
    if (StrCmp(dt_line, "hiA"))
        KTFail("GetStr line");
    Print("mouse: x=%d y=%d b=%d w=%d\n", mouse.mx, mouse.my, mouse.buttons, mouse.wheel);
    if (mouse.mx != fb.w / 2 + 5 || mouse.my != fb.h / 2 - 3 || mouse.buttons != 1 || mouse.wheel != 2)
        KTFail("mouse state");
    if (kt_fails == f0)
        Print("  input: PASS\n");
}

U0 DevTestShell()
{//The shell reads the next two scripted lines:
    //  I64 Sq(I64 x) { return x * x; }
    //  Print("%d\n", Sq(7));
    //  while (TRUE) {}               broken by Ctrl+Alt+C
    //  Sleep(60000);                 broken by Ctrl+Alt+C
    //  Print("%d\n", 51);
    //  Print("%d\n", 7); edited to print 42 (Left, Left, Backspace, 4, 2)
    //  Up, Up recalls the 51 line, which prints 51 again
    //  #include "Test.HC" (from the FAT32 disk) and Print("%d\n", Tripled(21)); print 63
    //  escapes: "\101" is "A" and '\101' + '\e' is 65 + 27: prints A92
    //then runs Sq(7) itself, so Sq must have persisted.
    I64 deadline = ArchCntVct + 20 * ArchCntFrq, f0 = kt_fails;
    ShellStart(10);
    while (shell_state < 2 && shell_state >= 0 && ArchCntVct < deadline)
        Sleep(10);
    if (shell_state != 2)
        KTFail("shell did not finish");
    else if (shell_check != 49)
        KTFail("shell: Sq(7) after the scripted lines");
    if (kt_fails == f0)
        Print("  shell: PASS\n");
}

U0 DevTestScreen()
{//Leave a known picture: 4 text rows, then color bars and a gradient.
    I64 i;
    ConsClear;
    "COOLCOM FB TEST\n";
    "input: %s\n", dt_line;
    "mouse: x=%d y=%d b=%d\n", mouse.mx, mouse.my, mouse.buttons;
    "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz\n";
    FbFillRect(16, 80, 32, 32, 0xFF0000);
    FbFillRect(64, 80, 32, 32, 0x00FF00);
    FbFillRect(112, 80, 32, 32, 0x0000FF);
    for (i = 0; i < 256; i++)
        FbFillRect(16 + i, 128, 1, 16, i * 0x010101);
}

U0 DevTest()
{
    if (!fb.base)
        KTFail("no framebuffer");
    if (!fdt_input.base)
        KTFail("no input device");
    if (fb.base && fdt_input.base) {
        DevTestInput;
        DevTestBlk;
        DevTestFs;
        DevTestShell;
        DevTestScreen;
    }
}
