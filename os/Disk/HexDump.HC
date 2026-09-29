// HexDump("file", start, count): 16 bytes a line, the offset, the bytes in hex and their
// ASCII characters. start and count (default: to the end) select a part of the file.
//   00000000  48 65 6c 6c 6f 20 57 6f  72 6c 64 0a 00 00 00 00  |Hello World.....|

U0 HexDump(U8 *name, I64 start = 0, I64 count = -1)
{
    U8 *buf;
    I64 size = TextRead(name, &buf), i, j, n, c, end;
    if (size < 0) return;
    if (start < 0) start = 0;
    end = size;
    if (count >= 0 && start + count < size) end = start + count;
    for (i = start; i < end; i += 16) {
        n = end - i;
        if (n > 16) n = 16;
        Print("%08X  ", i);
        for (j = 0; j < 16; j++) {
            if (j < n) {
                c = buf[i + j];
                if (!c) AnsiFg(ANSI_GRAY);
                Print("%02x ", c);
                if (!c) AnsiReset;
            } else
                Print("   ");
            if (j == 7) ConsPut(' ');
        }
        Print(" |");
        for (j = 0; j < n; j++) {
            c = buf[i + j];
            if (c >= 32 && c < 127) ConsPut(c);
            else ConsPut('.');
        }
        Print("|\n");
    }
    Print("%08X\n", end);
    Free(buf);
}
