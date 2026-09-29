// Framebuffer text console on the FDT's simple-framebuffer (32 bits per pixel,
// 0x00RRGGBB), drawn with the TempleOS 8x8 font.
//
// The framebuffer is outside /memory, but on real hardware it lies inside the
// DRAM aperture the boot tables map as Normal write-back. FbMapNC() splits the
// affected 32 MiB blocks into 16 KiB pages and remaps just the framebuffer
// pages as Normal non-cacheable, so the display controller sees every store.
class CFb
{
    U8 *base;
    I64 w, h, stride, cols, rows, cx, cy, fg, bg;
};

CFb fb;

#define FB_BLK_SHIFT  25   // level-2 block: 32 MiB
#define FB_PAGE_SHIFT 14   // 16 KiB granule
#define FB_PAGES      2048 // pages per block

U0 FbMapNC(I64 start, I64 size)
{
    I64 *l2 = ArchL2Table, *l3;
    I64 blk, i, addr, desc;
    for (blk = start >> FB_BLK_SHIFT; blk <= (start + size - 1) >> FB_BLK_SHIFT; blk++) {
        l3 = (MAlloc(2 * 16384)(I64) + 16383) & ~16383;
        for (i = 0; i < FB_PAGES; i++) {
            addr = (blk << FB_BLK_SHIFT) + (i << FB_PAGE_SHIFT);
            // page descriptor: valid, AttrIndx 1 (Normal WB), inner shareable, AF
            desc = addr | 3 | (1 << 2) | (3 << 8) | (1 << 10);
            if (addr + 16384 > start && addr < start + size)
                desc = addr | 3 | (2 << 2) | (3 << 8) | (1 << 10);  // AttrIndx 2: Normal NC
            l3[i] = desc;
        }
        ArchDsb;
        l2[blk] = l3(I64) | 3;  // table descriptor
    }
    ArchTlbFlush;
}

U0 FbFillRect(I64 x, I64 y, I64 w, I64 h, I64 color)
{
    I64 i, j;
    if (x < 0) {
        w += x;
        x = 0;
    }
    if (y < 0) {
        h += y;
        y = 0;
    }
    if (x + w > fb.w)
        w = fb.w - x;
    if (y + h > fb.h)
        h = fb.h - y;
    for (j = y; j < y + h; j++)
        for (i = x; i < x + w; i++)
            *(fb.base + j * fb.stride + i * 4)(U32i *) = color;
}

U0 FbGlyph(I64 col, I64 row, I64 ch)
{
    U64 g = font8x8[ch & 0xFF];
    U8 *p = fb.base + row * 8 * fb.stride + col * 32;
    I64 y, x, bits;
    for (y = 0; y < 8; y++) {
        bits = (g >> (y * 8)) & 0xFF;
        for (x = 0; x < 8; x++) {
            if (bits & 1)
                *p(U32i *) = fb.fg;
            else
                *p(U32i *) = fb.bg;
            bits >>= 1;
            p += 4;
        }
        p += fb.stride - 32;
    }
}

U0 FbClear()
{
    FbFillRect(0, 0, fb.w, fb.h, fb.bg);
    fb.cx = fb.cy = 0;
}

U0 FbScroll()
{
    I64 band = fb.stride * 8;
    MemCpy(fb.base, fb.base + band, (fb.rows - 1) * band);
    FbFillRect(0, (fb.rows - 1) * 8, fb.w, fb.h - (fb.rows - 1) * 8, fb.bg);
    fb.cy = fb.rows - 1;
}

U0 FbPutC(U8 c)
{//Console output: \n \r \b \t are handled, other control codes are ignored.
    if (c == '\n') {
        fb.cx = 0;
        fb.cy++;
    } else if (c == '\r')
        fb.cx = 0;
    else if (c == 8) {
        if (fb.cx > 0)
            fb.cx--;
    } else if (c == '\t')
        fb.cx = (fb.cx + 8) & ~7;
    else if (c >= 32) {
        if (fb.cx >= fb.cols) {  // wrap lazily, so a full line followed by \n is one line
            fb.cx = 0;
            fb.cy++;
            if (fb.cy >= fb.rows)
                FbScroll;
        }
        FbGlyph(fb.cx, fb.cy, c);
        fb.cx++;
    }
    if (fb.cy >= fb.rows)
        FbScroll;
}

Bool FbInit()
{//Map the framebuffer and add it as a console output. FALSE if the FDT has none.
    if (!fdt_fb_32bpp || !fdt_fb.base)
        return FALSE;
    fb.base = fdt_fb.base;
    fb.w = fdt_fb_w;
    fb.h = fdt_fb_h;
    fb.stride = fdt_fb_stride;
    fb.cols = fb.w / 8;
    fb.rows = fb.h / 8;
    fb.fg = 0xFFFFFF;
    fb.bg = 0;
    if (fb.cols < 1 || fb.rows < 2 || fb.stride < fb.w * 4)
        return FALSE;
    FbMapNC(fdt_fb.base, fb.stride * fb.h);
    FbClear;
    ConsAdd(&FbPutC);
    return TRUE;
}

U0 ConsClear()
{
    if (fb.base)
        FbClear;
}

U0 FbSetColor(I64 fg, I64 bg)
{
    fb.fg = fg;
    fb.bg = bg;
}
