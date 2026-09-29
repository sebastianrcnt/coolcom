// Owned frontend bootstrap unit. The native runtime and backend are included
// here as they are brought up. The checked-in native compiler BIN is the seed.
#define TARGET_AARCH64 1
#define TEXT_MODE 1
#define NATIVE_CANONICAL_AOT 1
#include "KernelA.HH"
#include "CompilerA.HH"
#include "CExts.HC"
#include "CompilerB.HH"
#include "KGlbls.HC"
#include "KMisc.HC"
#include "CQue.HC"
#include "KDataTypes.HC"
#include "StrA.HC"
#include "KHashA.HC"
#include "KMath.HC"
#include "KMathB.HC"
#include "StrPrint.HC"
#include "KHashB.HC"
#include "StrB.HC"
#include "KDefine.HC"
#include "StrScan.HC"
#include "QSort.HC"
#include "NativeExcept.HC"
// The host supplies task access and allocation until the owned runtime is live.
U0 NativeInit()
{
    I64 i, j, count, reversed;
    adam_task = CAlloc(sizeof(CTask));
    SetFs(adam_task);
    Fs->addr = Fs;
    Fs->hash_table = HashTableNew(0x4000);
    QueInit(&Fs->next_cc);
    QueInit(&Fs->next_except);
    blkdev.tmp_filename = StrNew("NativeTmp.HC");
    set_bits_table = MAlloc(256);
    rev_bits_table = MAlloc(256);
    for (i = 0; i < 256; i++) {
        count = 0;
        reversed = 0;
        for (j = 0; j < 8; j++) {
            count += ((i >> j) & 1);
            reversed = (reversed << 1) | ((i >> j) & 1);
        }
        set_bits_table[i] = count;
        rev_bits_table[i] = reversed;
    }
}
NativeInit;
#include "Compiler.HC"

I64 CoolCMain(U8 *entry, U8 *output)
{
    return Cmp(entry, NULL, output);
}
