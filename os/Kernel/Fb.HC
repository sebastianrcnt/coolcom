// Framebuffer text console on the FDT's simple-framebuffer (32 bits per pixel,
// 0x00RRGGBB), drawn with GNU Unifont (Font.HC): 8x16 cells, wide glyphs take two.
//
// The framebuffer is outside /memory, but on real hardware it lies inside the
// DRAM aperture the boot tables map as Normal write-back. FbMapNC() splits the
// affected 32 MiB blocks into 16 KiB pages and remaps just the framebuffer
// pages as Normal non-cacheable, so the display controller sees every store.
class CFb
{
    U8 *base;
    I64 w, h, stride, cols, rows, cx, cy, fg, bg;
    I64 cur_drawn;             // the cursor block is currently XORed onto the screen
    I64 u8_left, u8_cp;        // UTF-8 sequence being received
    U8 *cw;                    // per cell: 1 = narrow or blank, 2 = left half of a wide glyph, 0 = its right half
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

U0 FbBlit(I64 col, I64 row, U8 *g, I64 cells)
{//Draw a glyph (16 rows of 1 or 2 bytes, MSB = leftmost pixel) into cells cells at text position col,row.
    U8 *p = fb.base + row * FONT_CELL_H * fb.stride + col * FONT_CELL_W * 4;
    I64 y, x, bits, n = cells * FONT_CELL_W;
    for (y = 0; y < FONT_CELL_H; y++) {
        if (cells == 2) {
            bits = (g[0] << 8) | g[1];
            g += 2;
        } else
            bits = *g++;
        for (x = n - 1; x >= 0; x--) {
            if ((bits >> x) & 1)
                *p(U32i *) = fb.fg;
            else
                *p(U32i *) = fb.bg;
            p += 4;
        }
        p += fb.stride - n * 4;
    }
}

U0 FbBlank(I64 col, I64 row)
{//Erase one cell.
    FbFillRect(col * FONT_CELL_W, row * FONT_CELL_H, FONT_CELL_W, FONT_CELL_H, fb.bg);
    fb.cw[row * fb.cols + col] = 1;
}

U0 FbScroll()
{
    I64 band = fb.stride * FONT_CELL_H;
    MemCpy(fb.base, fb.base + band, (fb.rows - 1) * band);
    FbFillRect(0, (fb.rows - 1) * FONT_CELL_H, fb.w, fb.h - (fb.rows - 1) * FONT_CELL_H, fb.bg);
    MemCpy(fb.cw, fb.cw + fb.cols, (fb.rows - 1) * fb.cols);
    MemSet(fb.cw + (fb.rows - 1) * fb.cols, 1, fb.cols);
    fb.cy = fb.rows - 1;
}

U0 FbPutCp(I64 cp)
{//Draw a code point at the cursor and advance by the columns it takes (Utf8Width). Without a
    //glyph it is a '?' in each column.
    I64 w = Utf8Width(cp), cells, i, j;
    U8 *g = NULL;
    if (!w)
        return;
    if (cp < 0x110000)
        g = FontGlyph(cp, &cells);
    if (!g || cells != w) {
        while (w-- > 0)
            FbPutCp('?');
        return;
    }
    if (fb.cx + w > fb.cols) {  // wrap lazily, so a full line followed by \n is one line
        fb.cx = 0;
        fb.cy++;
        if (fb.cy >= fb.rows)
            FbScroll;
    }
    i = fb.cy * fb.cols + fb.cx;
    // Drawing over half of a wide glyph erases the other half.
    if (fb.cx > 0 && !fb.cw[i])
        FbBlank(fb.cx - 1, fb.cy);
    for (j = 0; j < w; j++)
        if (fb.cw[i + j] == 2 && j + 1 >= w && fb.cx + j + 1 < fb.cols)
            FbBlank(fb.cx + j + 1, fb.cy);
    FbBlit(fb.cx, fb.cy, g, w);
    fb.cw[i] = w;
    if (w == 2)
        fb.cw[i + 1] = 0;
    fb.cx += w;
}

U0 FbCursorFlip()
{//XOR the cell under the text cursor (a block cursor, two cells wide over a wide glyph); twice restores it.
    U8 *p;
    I64 x, y, w;
    if (fb.cx >= fb.cols || fb.cy >= fb.rows)
        return;
    w = FONT_CELL_W;
    if (fb.cw[fb.cy * fb.cols + fb.cx] == 2)
        w *= 2;
    p = fb.base + fb.cy * FONT_CELL_H * fb.stride + fb.cx * FONT_CELL_W * 4;
    for (y = 0; y < FONT_CELL_H; y++) {
        for (x = 0; x < w; x++)
            *(p + x * 4)(U32i *) ^= 0xFFFFFF;
        p += fb.stride;
    }
}

U0 FbCursorHide()
{
    if (fb.cur_drawn) {
        FbCursorFlip;
        fb.cur_drawn = FALSE;
    }
}

U0 FbCursorShow()
{
    if (!fb.cur_drawn) {
        FbCursorFlip;
        fb.cur_drawn = TRUE;
    }
}

U0 FbClear()
{
    fb.cur_drawn = FALSE;  // the fill wipes it
    FbFillRect(0, 0, fb.w, fb.h, fb.bg);
    MemSet(fb.cw, 1, fb.cols * fb.rows);
    fb.cx = fb.cy = 0;
    FbCursorShow;
}

U0 FbPutC1(U8 c)
{//Console output: \n \r \b \t are handled, other control codes are ignored. UTF-8 is decoded;
    //a character takes Utf8Width columns, like on a terminal, so \b (one column) matches the
    //shell's line editing, which backs up by columns.
    if (c >= 0x80) {
        if (Utf8Len(c) > 1) {
            fb.u8_left = Utf8Len(c) - 1;
            fb.u8_cp = c & (0x7F >> Utf8Len(c));
        } else if (fb.u8_left > 0) {
            fb.u8_cp = (fb.u8_cp << 6) | (c & 0x3F);
            if (!--fb.u8_left)
                FbPutCp(fb.u8_cp);
        }
        return;
    }
    fb.u8_left = 0;
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
    else if (c >= 32 && c < 127)
        FbPutCp(c);
    if (fb.cy >= fb.rows)
        FbScroll;
}

U0 FbPutC(U8 c)
{
    FbCursorHide;
    FbPutC1(c);
    FbCursorShow;
}

Bool FbInit()
{//Map the framebuffer and add it as a console output. FALSE if the FDT has none.
    if (!fdt_fb_32bpp || !fdt_fb.base)
        return FALSE;
    fb.base = fdt_fb.base;
    fb.w = fdt_fb_w;
    fb.h = fdt_fb_h;
    fb.stride = fdt_fb_stride;
    fb.cols = fb.w / FONT_CELL_W;
    fb.rows = fb.h / FONT_CELL_H;
    fb.fg = 0xFFFFFF;
    fb.bg = 0;
    if (fb.cols < 1 || fb.rows < 2 || fb.stride < fb.w * 4)
        return FALSE;
    fb.cw = MAlloc(fb.cols * fb.rows);
    FbMapNC(fdt_fb.base, fb.stride * fb.h);
    FbClear;  // also draws the cursor
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
