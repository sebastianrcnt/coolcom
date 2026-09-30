// Basic definitions shared by all kernel code. Cmp() starts from an empty
// symbol table holding only the raw types (U0 U8i I8i U16i I16i U32i I32i
// U64i I64i F64), so the usual TempleOS type names are defined here.
U16i union U16 {I8i i8[2]; U8i u8[2];};
I16i union I16 {I8i i8[2]; U8i u8[2];};
U32i union U32 {I8i i8[4]; U8i u8[4]; I16 i16[2]; U16 u16[2];};
I32i union I32 {I8i i8[4]; U8i u8[4]; I16 i16[2]; U16 u16[2];};
U64i union U64 {I8i i8[8]; U8i u8[8]; I16 i16[4]; U16 u16[4]; I32 i32[2]; U32 u32[2];};
I64i union I64 {I8i i8[8]; U8i u8[8]; I16 i16[4]; U16 u16[4]; I32 i32[2]; U32 u32[2];};
#define U8   U8i
#define I8   I8i
#define Bool I8i

#define TRUE  1
#define FALSE 0
#define NULL  0
#define I64_MIN (-0x7FFFFFFFFFFFFFFF-1)
#define I64_MAX 0x7FFFFFFFFFFFFFFF
#define F64_MAX 1.7976931348623157e308
extern U0 Print(U8 *fmt, ...);
extern U0 PutChars(U64 ch);
extern F64 Pow(F64 a, F64 b);
extern U8 *SysTry();
extern U0 SysUntry();
extern U0 EndCatch();
extern I64 AIWNIOS_SetJmp(U8 *);
extern U0 throw(I64 v = 0, Bool no_log = FALSE);
