#include "stbtt_source.c"
#include <stdio.h>

int main(void) {
    FILE *input = fopen("vendor/fonts/NotoSansKR.ttf", "rb");
    FILE *output = fopen("build/stbtt-test/clang.bin", "wb");
    unsigned char *data = malloc(16000000);
    unsigned char bitmap[64 * 64];
    stbtt_fontinfo font;
    int codepoints[] = {65, 103, 90, 44032, 45208, 54620};
    int i;
    if (!input || !output || !data) return 1;
    if (!fread(data, 1, 16000000, input)) return 2;
    if (!stbtt_InitFont(&font, data, 0)) return 3;
    for (i = 0; i < 6; ++i) {
        memset(bitmap, 0, sizeof(bitmap));
        stbtt_MakeCodepointBitmap(&font, bitmap, 64, 64, 64,
                                  0.04f, 0.04f, codepoints[i]);
        if (fwrite(bitmap, 1, sizeof(bitmap), output) != sizeof(bitmap)) return 4;
    }
    fclose(output);
    fclose(input);
    free(data);
    return 0;
}
