// Standalone native formatter image. Only memory and string length come from
// the host; the formatter itself is the same HolyC implementation.
#define U8 U8i
#define I64 I64i
#define Bool I8i
#define TRUE 1
#define FALSE 0
#define NULL 0
import U8 *MAlloc(I64 size);
import U0 Free(U8 *ptr);
import U8 *MemCpy(U8 *dst, U8 *src, I64 size);
import U8 *MemSet(U8 *dst, I64 value, I64 size);
import I64 StrLen(U8 *str);
#include "HCFmt.HC"

U8 *CoolCFmt(U8 *src, I64 *error, I64 *warning)
{
    U8 *result = HCFmt(src);
    *error = hcfmt_err;
    *warning = hcfmt_warn;
    return result;
}
