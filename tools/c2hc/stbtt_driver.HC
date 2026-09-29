extern U8i *FileRead(U8i *name, I64i *size, U8i *attrs);
extern I64i FileWrite(U8i *name, U8i *data, I64i size);
#include "../../coolc/Lib/StbTrueType.HC"

I32i main() {
    I64i size;
    U8i *data = FileRead("vendor/fonts/NotoSansKR.ttf", &size, 0);
    U8i *output = MAlloc(64 * 64 * 6);
    stbtt_fontinfo font;
    I32i codepoints[6];
    I32i i;
    codepoints[0] = 65;
    codepoints[1] = 103;
    codepoints[2] = 90;
    codepoints[3] = 44032;
    codepoints[4] = 45208;
    codepoints[5] = 54620;
    if (!data || !output) return 1;
    if (!stbtt_InitFont(&font, data, 0)) return 2;
    for (i = 0; i < 6; ++i) {
        MemSet(output + i * 4096, 0, 4096);
        stbtt_MakeCodepointBitmap(&font, output + i * 4096,
                                  64, 64, 64, 0.04, 0.04, codepoints[i]);
    }
    if (!FileWrite("build/stbtt-test/cool.bin", output, 64 * 64 * 6)) return 3;
    return 0;
}

main();
