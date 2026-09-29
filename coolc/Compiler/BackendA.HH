// Translated from Aiwnios c/aiwn_lexparser.h, aiwn_arm.h, aiwn_hash.h, aiwn_mem.h, aiwn_que.h,
// aiwn_asm.h and the local types of arm64_asm.c / optpass.c (nrootconauto, BSD-3), commit e155e87.
//
// Shared types, constants and prototypes of the CoolC AArch64 backend port
// (IRBind.HC, Arm64Enc.HC, OptPass.HC, ArmBackendA.HC, ArmBackendB.HC).
// See PORTING.md and RENAMES.txt.  Include this header (after KernelA.HH) before any of them.
//
// Layout notes:
//  * HolyC classes are packed; field order and names are those of the C structs.
//  * `enum`s became #defines with the same numeric values.
//  * Constant families that clash with the HolyC frontend carry a B prefix (see RENAMES.txt).
//  * Function-like macros are functions (bodies live in IRBind.HC).
//  * Every function of the port files is declared `extern` below so the files can call each
//    other regardless of include order.  `static` C functions are ordinary functions here.

#define ERR         0x7fFFffFFffFFffFF
#define BINVALID_PTR ERR
#define BSTR_LEN     144
#define STAR_CNT    5

// ------------------------------------------------------------------ classes
extern class CBQue;
extern class CBRPN;
extern class CBCodeMisc;
extern class CBCodeMiscRef;
extern class CBCodeCtrl;
extern class CBCmpCtrl;
extern class CBLexFile;
extern class CBLexer;
extern class CBHeapCtrl;
extern class CBTask;
extern class CBHashTable;
extern class CBHashClass;
extern class CBHashFun;
extern class CBHashGlblVar;
extern class CBMemberLst;
extern class CBMemUnused;
extern class CBBuddyPair;

// aiwn_que.h
class CBQue
{
  CBQue *last, *next;
};

// aiwn_hash.h
class CBArrayDim
{
  CBArrayDim *next;
  I64 cnt, total_cnt;
};

class CBMemberLst
{
  CBMemberLst *next, *last;
  CBHashClass *member_class;
  CBArrayDim dim;
  CBHashFun *fun_ptr;
  U8 *str;
  I64 off, reg, use_cnt, flags;
  union {
    I64 dft_val;
    F64 dft_val_flt;
    // USed for MLF_STATIC,this is a heap allocated "static" variable
    U8 *static_bytes;
  };
};

class CBHash
{
  CBHash *next;
  U8 *str;
  I32 type, use_cnt;
};

class CBHashTable
{
  CBHashTable *next;
  I64 mask, locked_flags;
  CBHash **body;
};

class CBHashDefineStr
{
  CBHash base;
  U8 *src_link;
  U8 *name;
  U8 *data;
};

class CBHashKeyword
{
  CBHash base;
  I64 tk;
};

class CBHashImport
{
  CBHash base;
  U8 **address;
};

class CBHashClass
{
  CBHash base;
  U8 *src_link;
  U8 *import_name;
  I64 member_cnt, ptr_star_cnt, raw_type, flags, use_cnt, sz;
  CBHashClass *base_class;
  CBMemberLst *members_lst;
  CBHashClass *fwd_class;
};

class CBHashExport
{
  CBHash base;
  U8 *val;
  U8 *oval;
};

class CBHashFun
{
  CBHashClass base;
  U8 *import_name;
  CBHashClass *return_class;
  I64 argc;
  U8 *fun_ptr;
  U8 *orig_fun_ptr;
};

class CBHashGlblVar
{
  CBHash base;
  U8 *src_link, *import_name;
  CBHashClass *var_class;
  U8 *data_addr;
  CBArrayDim dim;
  CBHashFun *fun_ptr;
};

// aiwn_mem.h / aiwn_multic.h
class CBTask
{
  U8 *pad;
  I64 task_signature;
  CBQue *except; // CExcept
  I64 except_ch;
  I64 catch_except;
  CBHashTable *hash_table;
  U8 *stack;
  U8 ctx[2048];
  U8 throw_pad[192]; //INTEGRATION: jmp_buf (192 bytes on Apple AArch64), unused by the backend
  CBHeapCtrl *heap, *code_heap;
};

class CBMemUnused
{
  // MUST BE FIRST MEMBER
  CBMemUnused *next;
  CBMemUnused *last; // Used for used memory only
  CBHeapCtrl *hc;
  I64 caller1, caller2; // Used for used memory only
  I64 which_bucket;
  I64 sz; // MUST BE LAST MEMBER FOR MAllocAligned
};

class CBHeapCtrlArena
{
  CBMemUnused *heap_hash[5];
  CBMemUnused *used_next, *used_last;
  CBMemUnused *malloc_free_lst;
};

class CBBuddyPair
{
  I64 offset_l, offset_r;
  CBBuddyPair *left, *right;
  I8 occupied, partial;
};

class CBHeapCtrl
{
  U8 *pad; // Needed
  I32 hc_signature;
  I32 is_code_heap;
  I64 locked_flags, alloced_u8s, used_u8s;
  CBTask *mem_task;
  I64 arena_lock;
  CBHeapCtrlArena arenas[16];
  CBQue mem_blks;
};

class CBMemBlk
{
  CBQue base;
  CBQue base2;
  I64 pags;
};

// aiwn_lexparser.h
// This represents a peice of text being lexed(it could be a file macro, or such)
class CBLexFile
{
  // If we include a file,we put the current file on hold
  // last will point to the "old" file we are in
  CBLexFile *last;
  U8 *filename, *text, *dir;
  I64 ln, col, pos, is_file;
};

class CBLexer
{
  CBLexFile *file;
  // These are our lexer values,I put them in a union to save memory
  I64 str_len;
  union {
    I64 integer;
    F64 flt;
    U8 string[864]; // STR_LEN*6
  };
  // Sometimes we are lexing and want to go back a charactor
  // LEXF_USE_LAST_CHAR allows us to simulate this.
  I64 flags, cur_char;
  I64 cur_tok;
  CBHeapCtrl *hc;
};

class CBCodeCtrl
{
  CBCodeCtrl *next;
  CBQue *ir_code;
  CBQue *code_misc;
  CBCodeMisc *break_to;
  I64 final_pass; // See OptPassFinal
  I64 min_ln;
  U8 **dbg_info;
  I64 statics_offset;
  CBHeapCtrl *hc;
};

class CBCodeMiscRef
{
  CBCodeMiscRef *next;
  CBRPN *from_ic;
  I32 *add_to, offset;
  // For arm
  // I32 (*)(I64, I64) and I32 (*)(I64), stored as U8 *: the C bootstrap compiler
  // yields the member's address for p->fnptr_member. Call via BCallPatch*.
  U8 *patch_cond_br;
  U8 *patch_uncond_br;
  I64 user_data1;
  I64 user_data2;
  I8 is_abs64;
  // Used for RISC-V
  I8 is_jal;     // Not JALR
  I8 is_4_bytes; // Default is 8 bytes
  //Used for bytecode
  I8 is_rel;
};

class CBCodeMisc
{
  CBQue base;
  I32 type, flags;
  // These are used for jump tables
  I64 lo, hi;
  U8 *str;
  U8 *addr;
  union {
    CBCodeMisc *dft_lab;
    I64 str_len;
  };
  U8 **patch_addr;
  union {
    CBCodeMisc **jmp_tab;
    F64 flt;
    I64 integer;
  };
  I32 aot_before_hint; // See __HC_SetAOTRelocBeforeRIP
  I32 use_cnt;
  I32 code_off; // Used for riscv_backend.c for choosing big/small jumps
  // The bit is set if the floating point register is alive at this inst
  I64 freg_alive_bmp;
  CBCodeMiscRef *refs;
};

class CBCmpCtrl
{
  CBLexer *lex;
  I64 flags;
  CBHashFun *cur_fun;
  CBCodeCtrl *code_ctrl;
  I64 backend_user_data0;
  I64 backend_user_data1;
  I64 backend_user_data2;
  I64 backend_user_data3;
  I64 backend_user_data4;
  I64 backend_user_data5;
  I64 backend_user_data6;
  I64 backend_user_data7;
  I64 backend_user_data8;
  I64 backend_user_data9;
  I64 backend_user_data10;
  I64 backend_user_data11;
  I64 prolog_stk_sz;
  I64 used_iregs_bmp;
  I64 used_fregs_bmp;
  I32 found_used_iregs;
  I32 found_used_fregs;
  // Used for returns
  CBCodeMisc *epilog_label, *statics_label;
  // In SysV,the fregs are not saved,so i will make a mini function to save them
  CBCodeMisc *fregs_save_label, *fregs_restore_label;
  CBHeapCtrl *hc, *final_hc;
  I64 is_lock_expr; // lock EXPRESSION;
  // private for AARCH64 for use with IC_LOCK
  // I will use the ldxsr/stxr instructions in a loop
  I64 aarch64_atomic_loop_start;
  CBRPN *cur_rpn;
};

class CBICArg
{
  // Feel free to define more in backend
  I32 mode;
  I32 raw_type;
  I8 reg, reg2, fallback_reg;
  // True on enter of things that want to set the flags
  // True/False if the result of the thing set the flags or not
  U8 want_use_flags; // This is reset by __OptPassFinal
  U8 set_flags;
  // keep the value in a temp location,good for removing reundant stores
  U8 keep_in_tmp;
  U8 keep_in_reg0; // RAX on X86_64
  union {
    CBCodeMisc *code_misc;
    I64 integer;
    I64 off;
    F64 flt;
  };
  I8 __SIB_scale, pop_n_tmp_regs;
  U8 is_tmp;
  CBRPN *__sib_base_rpn, *__sib_idx_rpn;
};

class CBRPN
{
  CBQue base;

  I16 type, length, raw_type, flags, ic_line;
  CBHashClass *ic_class;
  CBHashFun *ic_fun;
  CBArrayDim *ic_dim;
  union {
    F64 flt;
    U8 *raw_bytes;
    I64 integer;
    U8 *string;
    CBMemberLst *local_mem;
    CBHashGlblVar *global_var;
    CBCodeMisc *code_misc;
    CBCodeMisc *break_to;
  };
  CBCodeMisc *code_misc2, *code_misc3, *code_misc4;
  CBICArg res, tmp_res;
  CBRPN *tree1, *tree2, *ic_fwd;
  // Use with Bt,includes temporaries
  U32 changes_iregs, changes_fregs;
  U32 changes_iregs2, changes_fregs2;
  // Will be stored into this reg if ICF_STUFF_IN_REG is set
  U8 *start_ptr, *end_ptr;
  U8 stuff_in_reg;
};

// Local types of arm64_asm.c (https://github.com/fujitsu/xbyak_aarch64)
class CBARMAdrRegReg
{
  I64 n, m;
  I64 type;
  I64 shift;
  I64 init_sh;
};
class CBARMAdrRegImm
{
  I64 n;
  I64 off;
};
class CBARMAdrPostImm
{
  I64 n;
  I64 off;
};
class CBARMAdrPreImm
{
  I64 n;
  I64 off;
};
class CBARMAdrScImm
{
  I64 n;
  I64 off;
  I64 ext;
};

// Local type of optpass.c
class CBOptMemberVar
{
  I64 score;
  CBMemberLst *m;
};

// ---------------------------------------------------------------- constants
// aiwn_lexparser.h: LEXF_ flags
#define LEXF_USE_LAST_CHAR 1
#define LEXF_ERROR         2
#define LEXF_NO_EXPAND     4 // Don't expand macros
#define LEXF_UNTIL_NEWLINE 8

// CCodeMisc types/flags
#define BCMT_LABEL       1
#define BCMT_JMP_TAB     2
#define BCMT_STRING      3
#define BCMT_FLOAT_CONST 4
#define BCMT_INT_CONST   5 // ARM has constraints on literals
#define BCMT_RELOC_U64   6
#define BCMT_STATIC_DATA 7 // integer is the offset(in the statics data) str/str_len is the data
#define BCMT_SHORT_ADDR  8
#define BCMF_DEFINED             1 // Used with Labels to tell if already defined
#define CMF_JMP_TABLE_TAINTED   2 // Used with jump tables to tell if we tained the floating point registers

// CCmpCtrl flags
#define BCCF_IN_SUBSWITCH_START_BLOCK 0x1
#define BCCF_STRINGS_ON_HEAP          0x2
#define BCCF_AOT_COMPILE              0x4
#define BCCF_ICMOV_NO_USE_RAX         0x8

#define BPRSF_CLASS    1
#define BPRSF_UNION    2
#define BPRSF_FUN_ARGS 4
#define BPRSF_EXTERN   8
#define BPRSF__EXTERN  0x10
#define BPRSF_IMPORT   0x20
#define BPRSF__IMPORT  0x40
#define BPRSF_STATIC   0x80

// CICArg modes
#define MD_NULL      -1
#define MD_REG       1 // raw_type==RT_F64 for flt register
#define MD_FRAME     2 // ditto
#define MD_PTR       3 // ditto
#define MD_INDIR_REG 4 // ditto
#define MD_I64       5
#define MD_F64       6
#define MD_STATIC    7 // off points to start of function's code
// Here's the deal. Arm let's you shift like this (ldr dst,[a,b,lsl 3])
// integer is the shift amt
#define __MD_ARM_SHIFT 8
// X86_64 SIB
#define __MD_X86_64_SIB 9
// Like X86_64 but uses LEA
#define __MD_X86_64_LEA_SIB 10
#define MD_CODE_MISC_PTR    11
#define __MD_ARM_SHIFT_ADD  12 // Like lea
#define __MD_ARM_SHIFT_SUB  13 // Like lea

// aiwn_hash.h
#define BMLF_STATIC        1
#define BMLF_DFT_AVAILABLE 2

#define BHTT_INVALID         0
#define BHTT_DEFINE_STR      0x1
#define BHTT_KEYWORD         0x2
#define BHTT_CLASS           0x4
#define BHTT_GLBL_VAR        0x8
#define BHTT_FUN             0x10
#define BHTF_IMPORT          0x20
#define BHTF_EXTERN          0x40
#define BHTT_IMPORT_SYS_SYM  0x80
#define BHTT_EXPORT_SYS_SYM  0x100
#define BHTT_IMPORT_SYS_SYM2 0x200 // See arm_loader.c

#define BREG_ALLOC -1
#define BREG_NONE  -2
#define BREG_MAYBE -3
// TODO make a mechanism for assigning hardware regs

#define BRT_U0    -1
#define BRT_UNDEF 0
#define BRT_I8i   1
#define BRT_U8i   2
#define BRT_I16i  3
#define BRT_U16i  4
#define BRT_I32i  5
#define BRT_U32i  6
#define BRT_I64i  7
#define BRT_U64i  8
#define BRT_PTR   9
#define BRT_F64   10
#define BRT_FUNC  11

#define CLSF_VARGS  1
#define CLSF_FUNPTR 2

// aiwn_arm.h
#define ARM_ERR         -1
#define ARM_ERR_INV_OFF -2
#define ARM_ERR_INV_REG -3

#define LSL  0
#define LSR  1
#define ASR  2
#define ROR  3
#define MSL  4
#define NONE 5

#define EXT_NONE   0xffff
#define UXTB_32    0
#define UXTH_32    1
#define EXT_LSL_32 2
#define UXTW_32    2
#define UXTX_32    3
#define SXTB_32    4
#define SXTH_32    5
#define SXTW_32    6
#define SXTX_32    7

#define UXTB_64    0
#define UXTH_64    1
#define EXT_LSL_64 2
#define UXTW_64    2
#define UXTX_64    3
#define SXTB_64    4
#define SXTH_64    5
#define SXTW_64    6
#define SXTX_64    7

#define ARM_EQ 0x0
#define ARM_NE 0x1
#define ARM_CS 0x2
#define ARM_HS 0x2
#define ARM_CC 0x3
#define ARM_LO 0x3
#define ARM_MI 0x4
#define ARM_PL 0x5
#define ARM_VS 0x6
#define ARM_VC 0x7
#define ARM_HI 0x8
#define ARM_LS 0x9
#define ARM_GE 0xa
#define ARM_LT 0xb
#define ARM_GT 0xc
#define ARM_LE 0xd
#define ARM_AL 0xe
#define ARM_NV 0xf

// arm_backend.c: register enums (moved here because AIWNIOS_REG_FP needs them)
// Meet the arguments
#define ARM_REG_X0  0 // I am also a return value
#define ARM_REG_X1  1
#define ARM_REG_X2  2
#define ARM_REG_X3  3
#define ARM_REG_X4  4
#define ARM_REG_X5  5
#define ARM_REG_X6  6
#define ARM_REG_X7  7
// Meet the silly willies(scratch)
#define ARM_REG_X8  8
#define ARM_REG_X9  9
#define ARM_REG_X10 10
#define ARM_REG_X11 11
#define ARM_REG_X12 12
#define ARM_REG_X13 13
#define ARM_REG_X14 14
#define ARM_REG_X15 15
#define ARM_REG_X16 16
#define ARM_REG_X17 17
// Meet the platform register(does something?)
#define ARM_REG_X18 18
// Meet the bodacious bunch(saved accross calls)
#define ARM_REG_X19 19
#define ARM_REG_X20 20
#define ARM_REG_X21 21
#define ARM_REG_X22 22
#define ARM_REG_X23 23
#define ARM_REG_X24 24
#define ARM_REG_X25 25
#define ARM_REG_X26 26
#define ARM_REG_X27 27
#define ARM_REG_X28 28
// Meet the frame pointer
#define ARM_REG_X29 29
#define ARM_REG_FP  ARM_REG_X29
// Meet the return address
#define ARM_REG_X30 30
#define ARM_REG_LR  ARM_REG_X30
// Meet the (secret) stack pointer
#define ARM_REG_SP  31
// Meet the floating point arguments
#define ARM_REG_V0  0 // Also return register
#define ARM_REG_V1  1
#define ARM_REG_V2  2
#define ARM_REG_V3  3
#define ARM_REG_V4  4
#define ARM_REG_V5  5
#define ARM_REG_V6  6
#define ARM_REG_V7  7
// Meet the saved registers
#define ARM_REG_V8  8
#define ARM_REG_V9  9
#define ARM_REG_V10 10
#define ARM_REG_V11 11
#define ARM_REG_V12 12
#define ARM_REG_V13 13
#define ARM_REG_V14 14
#define ARM_REG_V15 15
// Meet the poo poo registers(not saved)
#define ARM_REG_V16 16
#define ARM_REG_V17 17
#define ARM_REG_V18 18
#define ARM_REG_V19 19
#define ARM_REG_V20 20
#define ARM_REG_V21 21
#define ARM_REG_V22 22
#define ARM_REG_V23 23
#define ARM_REG_V24 24
#define ARM_REG_V25 25
#define ARM_REG_V26 26
#define ARM_REG_V27 27
#define ARM_REG_V28 28
#define ARM_REG_V29 29
#define ARM_REG_V30 30
#define ARM_REG_V31 31

// Register-allocation parameters used by optpass.c and the backend (aiwn_lexparser.h).
// The C header picks these per OS; the Apple set is used by default so the output can be
// compared byte-for-byte with the C backend on macOS.  Define BACKEND_LINUX_ABI before
// including this header to get the Linux/BSD set (x18 as scratch instead of x16).
#define BAIWNIOS_IREG_START     19
#define BAIWNIOS_IREG_CNT       9  // (27 - 19 + 1)
#define BAIWNIOS_REG_FP         ARM_REG_FP
#define BAIWNIOS_REG_SP         ARM_REG_SP
#define BAIWNIOS_TMP_IREG_POOP2 17 // I use it as a second poo poo ALWAYS
#define BAIWNIOS_TMP_IREG_START 8
#ifdef BACKEND_LINUX_ABI
#define BAIWNIOS_TMP_IREG_POOP  18 // Platform register,I use it as a poo poo
#define BAIWNIOS_TMP_IREG_CNT   9  // (16 - 8 + 1)
#else
#define BAIWNIOS_TMP_IREG_POOP  16
#define BAIWNIOS_TMP_IREG_CNT   8  // (15 - 8 + 1)
#endif
#define BAIWNIOS_FREG_START     8
#define BAIWNIOS_FREG_CNT       8  // (15 - 8 + 1)
#define BAIWNIOS_TMP_FREG_START 16
#define BAIWNIOS_TMP_FREG_CNT   16 // (31 - 16 + 1)

// ---- LexTok / IC_ / ICF_ (enums in C) ----
// ---- LexTok (enum) ----
#define BTK_I64                  0x100
#define BTK_F64                  0x101
#define BTK_NAME                 0x102
#define BTK_STR                  0x103
#define BTK_CHR                  0x104
#define BTK_ERR                  0x105
#define BTK_INC_INC              0x106
#define BTK_DEC_DEC              0x107
#define BTK_AND_AND              0x108
#define BTK_XOR_XOR              0x109
#define BTK_OR_OR                0x10A
#define BTK_EQ_EQ                0x10B
#define BTK_NE                   0x10C
#define BTK_LE                   0x10D
#define BTK_GE                   0x10E
#define BTK_LSH                  0x10F
#define BTK_RSH                  0x110
#define BTK_ADD_EQ               0x111
#define BTK_SUB_EQ               0x112
#define BTK_MUL_EQ               0x113
#define BTK_DIV_EQ               0x114
#define BTK_LSH_EQ               0x115
#define BTK_RSH_EQ               0x116
#define BTK_AND_EQ               0x117
#define BTK_OR_EQ                0x118
#define BTK_XOR_EQ               0x119
#define BTK_ARROW                0x11A
#define BTK_DOT_DOT_DOT          0x11B
#define BTK_MOD_EQ               0x11C
#define BTK_KW_UNION             0x11D
#define BTK_KW_CATCH             0x11E
#define BTK_KW_CLASS             0x11F
#define BTK_KW_TRY               0x120
#define BTK_KW_IF                0x121
#define BTK_KW_ELSE              0x122
#define BTK_KW_FOR               0x123
#define BTK_KW_WHILE             0x124
#define BTK_KW_EXTERN            0x125
#define BTK_KW__EXTERN           0x126
#define BTK_KW_RETURN            0x127
#define BTK_KW_SIZEOF            0x128
#define BTK_KW__INTERN           0x129
#define BTK_KW_DO                0x12A
#define BTK_KW_ASM               0x12B
#define BTK_KW_GOTO              0x12C
#define BTK_KW_BREAK             0x12D
#define BTK_KW_SWITCH            0x12E
#define BTK_KW_START             0x12F
#define BTK_KW_END               0x130
#define BTK_KW_CASE              0x131
#define BTK_KW_DEFUALT           0x132
#define BTK_KW_PUBLIC            0x133
#define BTK_KW_OFFSET            0x134
#define BTK_KW_IMPORT            0x135
#define BTK_KW__IMPORT           0x136
#define BTK_KW_REG               0x137
#define BTK_KW_NOREG             0x138
#define BTK_KW_LASTCLASS         0x139
#define BTK_KW_NOWARN            0x13A
#define BTK_KW_STATIC            0x13B
#define BTK_KW_LOCK              0x13C
#define BTK_KW_DEFINED           0x13D
#define BTK_KW_INTERRUPT         0x13E
#define BTK_KW_HASERRCODE        0x13F
#define BTK_KW_ARGPOP            0x140
#define BTK_KW_NOARGPOP          0x141
// ---- IC_ enum ----
#define BIC_GOTO                 0
#define BIC_SQR                  1
#define BIC_GOTO_IF              2
#define BIC_TO_I64               3
#define BIC_TO_F64               4
#define BIC_LABEL                5
#define BIC_STATIC               6
#define BIC_LOCAL                7
#define BIC_GLOBAL               8
#define BIC_NOP                  9
#define BIC_PAREN                10
#define BIC_NEG                  11
#define BIC_POS                  12
#define BIC_NAME                 13
#define BIC_STR                  14
#define BIC_CHR                  15
#define BIC_POW                  16
#define BIC_ADD                  17
#define BIC_EQ                   18
#define BIC_SUB                  19
#define BIC_DIV                  20
#define BIC_MUL                  21
#define BIC_DEREF                22
#define BIC_AND                  23
#define BIC_ADDR_OF              24
#define BIC_XOR                  25
#define BIC_MOD                  26
#define BIC_OR                   27
#define BIC_LT                   28
#define BIC_GT                   29
#define BIC_LNOT                 30
#define BIC_BNOT                 31
#define BIC_POST_INC             32
#define BIC_POST_DEC             33
#define BIC_PRE_INC              34
#define BIC_PRE_DEC              35
#define BIC_AND_AND              36
#define BIC_OR_OR                37
#define BIC_XOR_XOR              38
#define BIC_EQ_EQ                39
#define BIC_NE                   40
#define BIC_LE                   41
#define BIC_GE                   42
#define BIC_LSH                  43
#define BIC_RSH                  44
#define BIC_ADD_EQ               45
#define BIC_SUB_EQ               46
#define BIC_MUL_EQ               47
#define BIC_DIV_EQ               48
#define BIC_LSH_EQ               49
#define BIC_RSH_EQ               50
#define BIC_AND_EQ               51
#define BIC_OR_EQ                52
#define BIC_XOR_EQ               53
#define BIC_ARROW                54
#define BIC_DOT                  55
#define BIC_MOD_EQ               56
#define BIC_I64                  57
#define BIC_F64                  58
#define BIC_ARRAY_ACC            59
#define BIC_RET                  60
#define BIC_CALL                 61
#define BIC_COMMA                62
#define BIC_UNBOUNDED_SWITCH     63
#define BIC_BOUNDED_SWITCH       64
#define BIC_SUB_RET              65
#define BIC_SUB_PROLOG           66
#define BIC_SUB_CALL             67
#define BIC_TYPECAST             68
#define BIC_BASE_PTR             69
#define BIC_IREG                 70
#define BIC_FREG                 71
#define BIC_LOAD                 72
#define BIC_STORE                73
#define __IC_VARGS               74
#define __IC_ARG                 75
#define __IC_SET_FRAME_SIZE      76
#define BIC_RELOC                77
#define __IC_CALL                78
#define __IC_STATICS_SIZE        79
#define __IC_STATIC_REF          80
#define __IC_SET_STATIC_DATA     81
#define BIC_SHORT_ADDR           82
#define BIC_BT                   83
#define BIC_BTC                  84
#define BIC_BTS                  85
#define BIC_BTR                  86
#define BIC_LBTC                 87
#define BIC_LBTS                 88
#define BIC_LBTR                 89
#define BIC_MAX_I64              90
#define BIC_MIN_I64              91
#define BIC_MAX_U64              92
#define BIC_MIN_U64              93
#define BIC_MAX_F64              94
#define BIC_MIN_F64              95
#define BIC_SIGN_I64             96
#define BIC_SQR_I64              97
#define BIC_SQR_U64              98
#define BIC_ABS                  99
#define BIC_SIN                  100
#define BIC_COS                  101
#define BIC_TAN                  102
#define BIC_ATAN                 103
#define BIC_RAW_BYTES            104
#define BIC_GET_VARGS_PTR        105
#define BIC_LOCK                 106
#define BIC_FS                   107
#define BIC_GS                   108
#define BIC_TO_BOOL              109
#define BIC_SQRT                 110
#define BIC_CNT                  111
// ---- ICF ----
#define ICF_SPILLED              1
#define ICF_DEAD_CODE            2
#define ICF_TMP_NO_UNDO          4
#define ICF_PRECOMPUTED          8
#define ICF_SIB                  16
#define ICF_INDIR_REG            32
#define ICF_STUFF_IN_REG         64
#define ICF_LOCK_EXPR            128
#define ICF_IS_BOOL              256
#define ICF_NO_JUMP              512
#define ICF_SPILLS_TMP_REGS      1024
#define ICF_DOESNT_SPILL_TMP_REGS 2048

// ---- Arm64Enc.HC (c/arm64_asm.c) ----
extern I64 LdStRegExt(I64 sz, I64 opc, I64 rt, I64 n, I64 m, I64 mod);
extern I64 BMvWideImmX(U32 opc, I64 d, I64 imm, I64 shift);
extern I64 BDataProc2Src(U32 opcode, I64 rd, I64 rn, I64 rm);
extern I64 BFpComp(U32 M, U32 S, U32 type, U32 op, U32 opcode2, I64 vn, I64 vm);
extern I64 BFpDataProc1Reg(U32 M, U32 S, U32 type, U32 opcode, I64 vd, I64 vn);
extern I64 LdStRegPairPostImm(I64 opc, I64 l, I64 r, I64 r2, CBARMAdrPostImm *pre);
extern I64 LdStRegPairPre(I64 opc, I64 L, I64 rt1, I64 rt2, CBARMAdrPreImm *adr);
extern I64 LdStSimdFpUnImm(I32 opc, I64 vt, I64 n, I64 imm);
extern I64 LdRegSimdFpLiteralEnc(I64 vt, I64 imm);
extern I64 LdStRegPre(I64 sz, I64 opc, I64 r, CBARMAdrPreImm *adr);
extern I64 LdStRegPostImm(I64 sz, I64 opc, I64 r, CBARMAdrPostImm *adr);
extern I64 BFpDataProc2Reg(I64 M, I64 s, I64 type, I64 opcode, I64 d, I64 n, I64 m);
extern I64 BLdRegLiteralEnc(I64 opc, I64 v, I64 r, I64 label);
extern I64 ConversionFpIntIF(I64 sf, I64 s, I64 type, I64 rmode, I64 opcode, I64 d, I64 n);
extern I64 ConversionFpIntFI(U32 sf, U32 S, U32 type, U32 rmode, U32 opcode, I32 vd, I32 rn);
extern I64 BLdStRegUnImm(I64 sz, I64 opc, I64 r, CBARMAdrRegImm *adr);
extern I64 BLdStRegReg(I64 size, I64 opc, I64 rt, I64 m, I64 n, I64 shift);
extern I64 CompareBr(I64 op, I64 r, I64 imm);
extern I64 CompareBrX(I64 op, I64 r, I64 imm);
extern I64 BUncondBrNoReg(I64 opc, I64 op2, I64 op3, I64 rn, I64 op4);
extern I64 UncondBrImm(I64 op, I64 label);
extern I64 UncondBr1Reg(I64 opc, I64 op2, I64 op3, I64 reg, I64 op4);
extern I64 CondBrImm(I64 cond, I64 imm);
extern I64 AddSubImm(I64 op, I64 s, I64 d, I64 n, I64 imm, I64 sh);
extern I64 TestBr(I64 op, I64 rt, I64 imm, I64 off);
extern I64 Bitfield(I64 op, I64 d, I64 n, U64 immr, U64 imms);
extern I64 BBitfieldX(I64 op, I64 d, I64 n, U64 immr, U64 imms);
extern I64 BAddSubImmX(I64 op, I64 s, I64 d, I64 n, I64 imm, I64 sh);
extern I64 AddSubExtReg(I64 opc, I64 s, I64 d, I64 n, I64 m, I64 emod, I64 sh);
extern I64 BAddSubExtRegX(I64 opc, I64 s, I64 d, I64 n, I64 m, I64 emod, I64 sh);
extern I64 AddSubShiftReg(I64 opc, I64 s, I64 d, I64 n, I64 m, I64 shmod, I64 sh, I64 alias);
extern I64 LdStSimdFpRegPostImm(I64 opc, I64 d, I64 p, I64 off);
extern I64 LdStSimdFpRegPreImm(I64 opc, I64 d, I64 p, I64 off);
extern I64 BAddSubShiftRegX(I64 opc, I64 s, I64 d, I64 n, I64 m, I64 shmod, I64 sh, I64 alias);
extern I64 DataProc3RegX(I64 op54, I64 op31, I64 o0, I64 d, I64 n, I64 m, I64 ra);
extern I64 LogicalShiftReg(I64 opc, I64 N, I64 rd, I64 rn, I64 rm, I64 shmod, U32 sh);
extern I64 BLogicalShiftRegX(I64 opc, I64 N, I64 rd, I64 rn, I64 rm, I64 shmod, U32 sh);
extern I64 BCondSel(I64 op, I64 s, I64 op2, I64 d, I64 n, I64 m, I64 cond);
extern I64 CondSelX(I64 op, I64 s, I64 op2, I64 d, I64 n, I64 m, I64 cond);
extern I64 MvReg(I64 d, I64 n);
extern I64 BMvRegX(I64 d, I64 n);
extern I64 LdStSimdFpRegRegShift(U32 opc, I64 vt, I64 rn, I64 rm);
extern I64 ARM_adrX(I64 d, I64 pc_off);
extern I64 ARM_addImmX(I64 d, I64 n, I64 imm);
extern I64 ARM_subImmX(I64 d, I64 n, I64 imm);
extern I64 ARM_subsImmX(I64 d, I64 n, I64 imm);
extern I64 ARM_cmpImmX(I64 n, I64 imm);
extern I64 ARM_andRegX(I64 rd, I64 rn, I64 rm);
extern I64 ARM_orrRegX(I64 rd, I64 rn, I64 rm);
extern I64 ARM_mvnShift(I64 rd, I64 rm, I64 shmod, I64 sh);
extern I64 ARM_mvnShiftX(I64 rd, I64 rm, I64 shmod, I64 sh);
extern I64 ARM_mvnReg(I64 rd, I64 rm);
extern I64 ARM_mvnRegX(I64 rd, I64 rm);
extern I64 ARM_eorShiftX(I64 rd, I64 rn, I64 rm, I64 shmod, I64 sh);
extern I64 ARM_eorRegX(I64 rd, I64 rn, I64 rm);
extern I64 ARM_andsRegX(I64 rd, I64 rn, I64 rm);
extern I64 ARM_movReg(I64 d, I64 n);
extern I64 ARM_movRegX(I64 d, I64 n);
extern I64 ARM_addShiftRegX(I64 d, I64 n, I64 m, I64 sh);
extern I64 ARM_subShiftRegX(I64 d, I64 n, I64 m, I64 sh);
extern I64 ARM_addShiftRegXs(I64 d, I64 n, I64 m, I64 sh);
extern I64 ARM_subShiftRegXs(I64 d, I64 n, I64 m, I64 sh);
extern I64 ARM_addRegX(I64 d, I64 n, I64 m);
extern I64 ARM_addsRegX(I64 d, I64 n, I64 m);
extern I64 ARM_addsImmX(I64 rd, I64 rn, I64 imm);
extern I64 ARM_subRegX(I64 d, I64 n, I64 m);
extern I64 ARM_subsRegX(I64 d, I64 n, I64 m);
extern I64 ARM_negsRegX(I64 d, I64 m);
extern I64 ARM_cmpRegX(I64 n, I64 m);
extern I64 ARM_csel(I64 d, I64 n, I64 m, I64 cond);
extern I64 ARM_cselX(I64 d, I64 n, I64 m, I64 cond);
extern I64 ARM_cset(I64 d, I64 cond);
extern I64 ARM_csetX(I64 d, I64 cond);
extern I64 ARM_mulRegX(I64 d, I64 n, I64 m);
extern I64 ARM_uxtb(I64 d, I64 n);
extern I64 ARM_uxtbX(I64 d, I64 n);
extern I64 ARM_uxth(I64 d, I64 n);
extern I64 ARM_uxthX(I64 d, I64 n);
extern I64 ARM_uxtwX(I64 d, I64 n);
extern I64 ARM_sxtb(I64 d, I64 n);
extern I64 ARM_sxtbX(I64 d, I64 n);
extern I64 ARM_sxth(I64 d, I64 n);
extern I64 ARM_sxthX(I64 d, I64 n);
extern I64 ARM_sxtw(I64 d, I64 n);
extern I64 ARM_sxtwX(I64 d, I64 n);
extern I64 ARM_asrImm(I64 d, I64 n, I64 imm);
extern I64 ARM_asrImmX(I64 d, I64 n, I64 imm);
extern I64 ARM_lslImm(I64 d, I64 n, I64 imm);
extern I64 ARM_lslImmX(I64 d, I64 n, I64 imm);
extern I64 ARM_lsrImm(I64 d, I64 n, I64 imm);
extern I64 ARM_lsrImmX(I64 d, I64 n, I64 imm);
extern I64 ARM_ret();
extern I64 ARM_eret();
extern I64 ARM_br(I64 r);
extern I64 ARM_blr(I64 r);
extern I64 ARM_retReg(I64 r);
extern I64 ARM_bcc(I64 cond, I64 lab);
extern I64 ARM_b(I64 lab);
extern I64 ARM_bl(I64 lab);
extern I64 ARM_cbz(I64 r, I64 label);
extern I64 ARM_cbzX(I64 r, I64 label);
extern I64 ARM_cbnz(I64 r, I64 label);
extern I64 ARM_cbnzX(I64 r, I64 label);
extern I64 ARM_tbz(I64 rt, I64 bit, I64 label);
extern I64 ARM_tbnz(I64 rt, I64 bit, I64 label);
extern I64 ARM_strbRegReg(I64 r, I64 a, I64 b);
extern I64 ARM_strbRegImm(I64 r, I64 n, I64 off);
extern I64 ARM_ldrbRegImm(I64 r, I64 n, I64 off);
extern I64 ARM_ldrbRegReg(I64 r, I64 a, I64 b);
extern I64 ARM_strhRegReg(I64 r, I64 a, I64 b);
extern I64 ARM_strhRegImm(I64 r, I64 n, I64 off);
extern I64 ARM_ldrhRegReg(I64 r, I64 a, I64 b);
extern I64 ARM_ldrhRegImm(I64 r, I64 n, I64 off);
extern I64 ARM_strRegImm(I64 r, I64 n, I64 off);
extern I64 ARM_strRegReg(I64 r, I64 a, I64 b);
extern I64 ARM_ldrRegReg(I64 r, I64 a, I64 b);
extern I64 ARM_ldrRegImm(I64 r, I64 n, I64 off);
extern I64 ARM_strRegImmX(I64 r, I64 n, I64 off);
extern I64 ARM_ldrRegImmX(I64 r, I64 n, I64 off);
extern I64 ARM_strRegRegX(I64 r, I64 a, I64 b);
extern I64 ARM_ldrRegRegX(I64 r, I64 a, I64 b);
extern I64 ARM_fmulReg(I64 d, I64 n, I64 m);
extern I64 ARM_fdivReg(I64 d, I64 n, I64 m);
extern I64 ARM_faddReg(I64 d, I64 n, I64 m);
extern I64 ARM_fsubReg(I64 d, I64 n, I64 m);
extern I64 ARM_scvtf(I64 d, I64 n);
extern I64 ARM_ucvtf(I64 d, I64 n);
extern I64 ARM_fcvtzs(I64 d, I64 n);
extern I64 ARM_ldrLabel(I64 d, I64 label);
extern I64 ARM_ldrLabelX(I64 d, I64 label);
extern I64 ARM_ldrLabelF64(I64 d, I64 label);
extern I64 ARM_strPostImm(I64 r, I64 b, I64 off);
extern I64 ARM_ldrPostImm(I64 r, I64 b, I64 off);
extern I64 ARM_strPreImm(I64 r, I64 b, I64 off);
extern I64 ARM_ldrPreImm(I64 r, I64 b, I64 off);
extern I64 ARM_strPostImmX(I64 r, I64 b, I64 off);
extern I64 ARM_ldrPostImmX(I64 r, I64 b, I64 off);
extern I64 ARM_strPreImmX(I64 r, I64 b, I64 off);
extern I64 ARM_ldrPreImmX(I64 r, I64 b, I64 off);
extern I64 ARM_stpPreImm(I64 r, I64 r2, I64 b, I64 off);
extern I64 ARM_stpPreImmX(I64 r, I64 r2, I64 b, I64 off);
extern I64 ARM_ldpPreImm(I64 r, I64 r2, I64 b, I64 off);
extern I64 ARM_ldpPreImmX(I64 r, I64 r2, I64 b, I64 off);
extern I64 ARM_stpPostImm(I64 r, I64 r2, I64 b, I64 off);
extern I64 ARM_stpPostImmX(I64 r, I64 r2, I64 b, I64 off);
extern I64 ARM_ldpPostImm(I64 r, I64 r2, I64 b, I64 off);
extern I64 ARM_ldpPostImmX(I64 r, I64 r2, I64 b, I64 off);
extern I64 ARM_ldrRegImmF64(I64 r, I64 n, U64 off);
extern I64 ARM_strRegImmF64(I64 r, I64 n, U64 off);
extern I64 ARM_fnegReg(I64 d, I64 s);
extern I64 ARM_fmovReg(I64 d, I64 s);
extern I64 ARM_fcmp(I64 a, I64 b);
extern I64 ARM_sdivRegX(I64 d, I64 n, I64 m);
extern I64 ARM_lslvRegX(I64 d, I64 n, I64 m);
extern I64 ARM_lsrvRegX(I64 d, I64 n, I64 m);
extern I64 ARM_asrvRegX(I64 d, I64 n, I64 m);
extern I64 ARM_movzImmX(I64 d, I64 i16, I64 sh);
extern I64 ARM_movkImmX(I64 d, I64 i16, I64 sh);
extern I64 ARM_movnImmX(I64 d, I64 i16, I64 sh);
extern I64 ARM_strPostImmF64(I64 d, I64 p, I64 off);
extern I64 ARM_ldrPostImmF64(I64 d, I64 p, I64 off);
extern I64 ARM_strPreImmF64(I64 d, I64 p, I64 off);
extern I64 ARM_ldrPreImmF64(I64 d, I64 p, I64 off);
extern I64 LdStSimdFpReg(I64 opc, I64 d, I64 n, I64 m);
extern I64 ARM_strRegRegF64(I64 d, I64 n, I64 m);
extern I64 ARM_ldrRegRegF64(I64 d, I64 n, I64 m);
extern I64 ARM_fmovI64F64(I64 d, I64 s);
extern I64 ARM_fmovF64I64(I64 d, I64 s);
extern I64 ARM_strhRegRegShift(I64 a, I64 n, I64 m);
extern I64 ARM_ldrhRegRegShift(I64 a, I64 n, I64 m);
extern I64 ARM_strRegRegShift(I64 a, I64 n, I64 m);
extern I64 ARM_ldrRegRegShift(I64 a, I64 n, I64 m);
extern I64 ARM_strRegRegShiftX(I64 a, I64 n, I64 m);
extern I64 ARM_ldrRegRegShiftX(I64 a, I64 n, I64 m);
extern I64 ARM_ldrRegRegShiftF64(I64 a, I64 n, I64 m);
extern I64 ARM_strRegRegShiftF64(I64 a, I64 n, I64 m);
extern I64 GenNImmSImmR(I64 imm);
extern I64 LogicalImm(I64 opc, I64 d, I64 s, I64 i);
extern I64 LogicalImmX(I64 opc, I64 d, I64 s, I64 i);
extern I64 ARM_andImmX(I64 d, I64 s, I64 i);
extern I64 ARM_orrImmX(I64 d, I64 s, I64 i);
extern I64 ARM_eorImmX(I64 d, I64 s, I64 i);
extern I64 LdStRegPairImm(I64 opc, I64 L, I64 r1, I64 r2, I64 ra, I64 off);
extern I64 ARM_stpImmX(I64 r1, I64 r2, I64 ra, I64 off);
extern I64 ARM_ldpImmX(I64 r1, I64 r2, I64 ra, I64 off);
extern I64 LdStSimdFpPairImm(I64 opc, I64 L, I64 r1, I64 r2, I64 ra, I64 off);
extern I64 ARM_stpImmF64(I64 r1, I64 r2, I64 ra, I64 off);
extern I64 ARM_ldpImmF64(I64 r1, I64 r2, I64 ra, I64 off);
extern I64 ARM_andsImmX(I64 d, I64 n, I64 imm);
extern I64 ARM_udivX(I64 d, I64 n, I64 m);
extern I64 ARM_umullX(I64 d, I64 n, I64 m);
extern I64 LdStRegUnsImm(I64 size, I64 opc, I64 rt, I64 adr_reg, I64 off);
extern I64 ARM_sturb(I64 r, I64 a, I64 off);
extern I64 ARM_sturh(I64 r, I64 a, I64 off);
extern I64 ARM_sturw(I64 r, I64 a, I64 off);
extern I64 ARM_ldursbX(I64 r, I64 a, I64 off);
extern I64 ARM_ldurshX(I64 r, I64 a, I64 off);
extern I64 ARM_ldurswX(I64 r, I64 a, I64 off);
extern I64 ARM_stur(I64 r, I64 a, I64 off);
extern I64 ARM_ldur(I64 r, I64 a, I64 off);
extern I64 ARM_ldrsbX(I64 r, I64 a, I64 off);
extern I64 ARM_ldrshX(I64 r, I64 a, I64 off);
extern I64 ARM_ldrswX(I64 r, I64 a, I64 off);
extern I64 ARM_ldrsbRegRegX(I64 r, I64 a, I64 b);
extern I64 ARM_ldrshRegRegX(I64 r, I64 a, I64 b);
extern I64 ARM_ldrswRegRegX(I64 r, I64 a, I64 b);
extern I64 ARM_ldrsbRegRegShiftX(I64 r, I64 a, I64 b);
extern I64 ARM_ldrshRegRegShiftX(I64 r, I64 a, I64 b);
extern I64 ARM_ldrswRegRegShiftX(I64 r, I64 a, I64 b);
extern I64 LdExclusive(I64 sz, I64 o0, I64 d, I64 s);
extern I64 ARM_ldaxrb(I64 d, I64 s);
extern I64 ARM_ldaxrh(I64 d, I64 s);
extern I64 ARM_ldaxr(I64 d, I64 s);
extern I64 ARM_ldaxrX(I64 d, I64 s);
extern I64 StExclusive(I64 sz, I64 o0, I64 pass, I64 d, I64 s);
extern I64 ARM_stlxrb(I64 p, I64 d, I64 s);
extern I64 ARM_stlxrh(I64 p, I64 d, I64 s);
extern I64 ARM_stlxr(I64 p, I64 d, I64 s);
extern I64 ARM_stlxrX(I64 p, I64 d, I64 s);
extern I64 FpCondSel(I64 m, I64 s, I64 t, I64 d, I64 n, I64 M, I64 cond);
extern I64 ARM_fcsel(I64 d, I64 a, I64 b, I64 c);

// ---- OptPass.HC (c/optpass.c) ----
extern I64 BIsConst(CBRPN *rpn);
extern I64 PtrWidthOfRPN(CBRPN *rpn);
extern U0 FixFunArgs(CBCmpCtrl *cctrl, CBRPN *rpn);
extern U0 OptPassFixFunArgs(CBCmpCtrl *cctrl);
extern U0 OptPassExpandPtrs(CBCmpCtrl *cctrl);
extern U0 OptPassMergeCommunitives(CBCmpCtrl *cctrl);
extern U0 BOptPassConstFold(CBCmpCtrl *cctrl);
extern I64 OptMemberVarSort(CBOptMemberVar *a, CBOptMemberVar *b);
extern I64 OptMemberVarSortSz(CBOptMemberVar *a, CBOptMemberVar *b);
extern U0 OptPassRegAlloc(CBCmpCtrl *cctrl);
extern I64 AlwaysPasses(CBRPN *rpn);
extern U0 OptPassRemoveUselessArith(CBCmpCtrl *cctrl);
extern U0 OptPassRemoveUselessTypecasts(CBCmpCtrl *cctrl);
extern U0 OptPassMergeAddressOffsets(CBCmpCtrl *cctrl);
extern U8 *Compile(CBCmpCtrl *cctrl, I64 *res_sz, U8 **dbg_info, CBHeapCtrl *heap);

// ---- ArmBackendA.HC / ArmBackendB.HC (c/arm_backend.c) ----
extern I64 MIR(CBCmpCtrl *cc, I64 r);
extern I64 MFR(CBCmpCtrl *cc, I64 r);
extern I64 CanKeepInTmp(CBRPN *me, CBRPN *have, CBRPN *other, I64 is_left_side);
extern U0 SetKeepTmps(CBRPN *rpn);
extern I64 IsBranchableInst(CBRPN *rpn);
extern I64 IsTerminalInst(CBRPN *r);
extern I64 ConstVal(CBRPN *rpn);
extern I64 PushToStack(CBCmpCtrl *cctrl, CBICArg *arg, U8 *bin, I64 code_off);
extern I64 PopFromStack(CBCmpCtrl *cctrl, CBICArg *arg, U8 *bin, I64 code_off);
extern I64 PutICArgIntoReg(CBCmpCtrl *cctrl, CBICArg *arg, I64 raw_type, I64 fallback, U8 *bin, I64 code_off);
extern I64 __ICMoveI64(CBCmpCtrl *cctrl, I64 reg, U64 imm, U8 *bin, I64 code_off);
extern I64 __ICMoveF64(CBCmpCtrl *cctrl, I64 reg, F64 imm, U8 *bin, I64 code_off);
extern I64 PtrDist(I64 a, I64 b);
extern U0 PushSpilledTmp(CBCmpCtrl *cctrl, CBRPN *rpn);
extern U0 PushTmp(CBCmpCtrl *cctrl, CBRPN *rpn);
extern U0 PopTmp(CBCmpCtrl *cctrl, CBRPN *rpn);
extern I64 DerefToICArg(CBCmpCtrl *cctrl, CBICArg *res, CBRPN *rpn, I64 base_reg_fallback, U8 *bin, I64 code_off);
extern I64 ArgRPNMutatesArgumentRegister(CBRPN *rpn, I64 reg, I64 is_freg);
extern I64 __ICFCallTOS(CBCmpCtrl *cctrl, CBRPN *rpn, U8 *bin, I64 code_off);
extern I64 ICMov(CBCmpCtrl *cctrl, CBICArg *dst, CBICArg *src, U8 *bin, I64 code_off);
extern I64 SpillsTmpRegs(CBRPN *rpn);
extern I64 __SexyWriteIntoDst(CBCmpCtrl *cctrl, CBRPN *deref, CBICArg *arg, U8 *bin, I64 code_off);
extern I64 __SexyPreOp(CBCmpCtrl *cctrl, CBRPN *rpn, I64 (*i_imm_op)(I64,I64,I64), I64 (*i_reg_op)(I64,I64,I64), I32 (*f_op)(I64,I64,I64), U8 *bin, I64 code_off);
extern I64 __SexyPostOp(CBCmpCtrl *cctrl, CBRPN *rpn, I64 (*i_imm_op)(I64,I64,I64), I64 (*i_reg_op)(I64,I64,I64), I64 (*f_op)(I64,I64,I64), U8 *bin, I64 code_off);
extern I64 FBitOp(CBCmpCtrl *cctrl, CBICArg *res, CBICArg *next, CBICArg *next2, I32 (*bit_op)(I64,I64,I64), I32 shift, U8 *bin, I64 code_off);
extern I64 __SexyAssignOp(CBCmpCtrl *cctrl, CBRPN *rpn, I32 (*i_op)(I64,I64,I64), I32 (*i_imm_op)(I64,I64,I64), I32 (*f_op)(I64,I64,I64), U8 *bin, I64 code_off);
extern I64 __FMod(I64 dst, I64 a, I64 b, U8 *bin, I64 code_off);
extern I64 __CompileMod(CBCmpCtrl *cctrl, CBRPN *rpn, U8 *bin, I64 code_off);
extern I64 __FindPushedIRegs(CBCmpCtrl *cctrl, U8 *to_push);
extern I64 __FindPushedFRegs(CBCmpCtrl *cctrl, U8 *to_push);
extern I64 FuncProlog(CBCmpCtrl *cctrl, U8 *bin, I64 code_off);
extern I64 FuncEpilog(CBCmpCtrl *cctrl, U8 *bin, I64 code_off);
extern I64 IsCompoundCompare(CBRPN *r);
extern I64 ARM_msrX1_tpidr_el0(I64 ul);
extern I64 __OptPassFinal(CBCmpCtrl *cctrl, CBRPN *rpn, U8 *bin, I64 code_off);
extern I64 IsCompare(I64 c);
extern I64 GetAddrModeParts(CBCmpCtrl *cctrl, CBRPN *r);
extern I64 PushTmpDepthFirst(CBCmpCtrl *cctrl, CBRPN *r, I64 spilled);
extern U8 *OptPassFinal(CBCmpCtrl *cctrl, I64 *res_sz, U8 **dbg_info, CBHeapCtrl *heap);

// arm_backend.c also has its own copy of IsConst (identical to optpass.c).  A port that follows
// the file-tag rule names it ArmABIsConst; both spellings are declared.
extern I64 ArmABIsConst(CBRPN *rpn);

// ---- IRBind.HC (c/parser.c) ----
// Bindings created by the HC_IC_BINDING macro: one function per IC_ opcode.
extern CBRPN *__HC_ICAdd_Sqr(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Lock(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Pow(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Eq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Div(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Sqrt(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Sub(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Mul(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Add(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Comma(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Addr(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Xor(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Mod(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Or(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Lt(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Gt(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Le(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Ge(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_LNot(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_BNot(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_AndAnd(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_OrOr(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_XorXor(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_EqEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Ne(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Lsh(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Rsh(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Neg(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_And(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Ret(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_AddEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_SubEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_MulEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_DivEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_LshEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_RshEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_AndEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_OrEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_XorEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_ModEq(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_ToI64(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_ToF64(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Min_I64(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Max_I64(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Min_U64(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Max_U64(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Min_F64(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Max_F64(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_ToBool(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_BT(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_BTC(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_BTS(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_BTR(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_LBTC(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_LBTS(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_LBTR(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Fs(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_Gs(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_SetFrameSize(CBCodeCtrl *cc, I64 arg);
extern CBRPN *__HC_ICAdd_Arg(CBCodeCtrl *cc, I64 arg);
extern CBRPN *__HC_ICAdd_PostInc(CBCodeCtrl *cc, I64 amt);
extern CBRPN *__HC_ICAdd_PostDec(CBCodeCtrl *cc, I64 amt);
extern CBRPN *__HC_ICAdd_PreInc(CBCodeCtrl *cc, I64 amt);
extern CBRPN *__HC_ICAdd_PreDec(CBCodeCtrl *cc, I64 amt);
extern CBRPN *__HC_ICAdd_I64(CBCodeCtrl *cc, I64 integer);
extern CBRPN *__HC_ICAdd_F64(CBCodeCtrl *cc, F64 f);
extern CBRPN *__HC_ICAdd_Switch(CBCodeCtrl *cc, CBCodeMisc *misc, CBCodeMisc *dft);
// The frontend imports the bounded switch under this name (main.c: STK___HC_ICAdd_Switch).
extern CBRPN *__HC_ICAdd_BoundedSwitch(CBCodeCtrl *cc, CBCodeMisc *misc, CBCodeMisc *dft);
extern CBRPN *__HC_ICAdd_UnboundedSwitch(CBCodeCtrl *cc, CBCodeMisc *misc);
extern CBRPN *__HC_ICAdd_SubRet(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_SubProlog(CBCodeCtrl *cc);
extern CBRPN *__HC_ICAdd_SubCall(CBCodeCtrl *cc, CBCodeMisc *cm);
extern CBHashClass *rt2cls(I64 rt, I64 ptr_cnt);
extern CBRPN *__HC_ICAdd_ShortAddr(CBCmpCtrl *acc, CBCodeCtrl *cc, U8 *name, CBCodeMisc *ptr);
extern CBRPN *__HC_ICAdd_Deref(CBCodeCtrl *cc, I64 rt, I64 ptr_cnt);
extern CBRPN *__HC_ICAdd_Call(CBCodeCtrl *cc, I64 arity, I64 rt, I64 ptr_cnt);
extern CBRPN *__HC_ICAdd_FReg(CBCodeCtrl *cc, I64 r);
extern CBRPN *__HC_ICAdd_IReg(CBCodeCtrl *cc, I64 r, I64 rt, I64 ptr_cnt);
extern CBRPN *__HC_ICAdd_Frame(CBCodeCtrl *cc, I64 off, I64 rt, I64 ptr_cnt);
extern CBRPN *__HC_ICAdd_Typecast(CBCodeCtrl *cc, I64 rt, I64 ptr_cnt);
extern CBCmpCtrl *__HC_CmpCtrlNew();
extern CBCmpCtrl *__HC_CmpCtrlDel(CBCmpCtrl *d);
extern CBCodeCtrl *__HC_CodeCtrlPush(CBCmpCtrl *ccmp);
extern U0 __HC_CodeCtrlPop(CBCmpCtrl *ccmp);
extern U8 *__HC_Compile(CBCmpCtrl *ccmp, I64 *sz=NULL, U8 **dbg_info=NULL, CBHeapCtrl *h);
extern CBCodeMisc *__HC_CodeMiscLabelNew(CBCmpCtrl *ccmp, U8 **patch_addr=NULL);
extern CBCodeMisc *__HC_CodeMiscStrNew(CBCmpCtrl *ccmp, U8 *str, I64 sz);
extern CBCodeMisc *__HC_CodeMiscJmpTableNew(CBCmpCtrl *ccmp, CBCodeMisc *labels, U8 **table_address, I64 hi);
extern CBRPN *__HC_ICAdd_Label(CBCodeCtrl *cc, CBCodeMisc *misc);
extern CBRPN *__HC_ICAdd_Goto(CBCodeCtrl *cc, CBCodeMisc *cm);
extern CBRPN *__HC_ICAdd_GotoIf(CBCodeCtrl *cc, CBCodeMisc *cm);
extern CBRPN *__HC_ICAdd_RawBytes(CBCodeCtrl *cc, U8 *bytes, I64 cnt);
extern CBRPN *__HC_ICAdd_Vargs(CBCodeCtrl *cc, I64 arity);
extern CBRPN *__HC_ICAdd_Str(CBCodeCtrl *cc, CBCodeMisc *cm);
extern CBCodeMisc *AddRelocMisc(CBCmpCtrl *cctrl, U8 *name);
extern U0 __HC_ICSetLine(CBRPN *r, I64 ln);
extern CBRPN *__HC_ICAdd_Reloc(CBCmpCtrl *cmpc, CBCodeCtrl *cc, I64 *pat_addr, U8 *sym, I64 rt, I64 ptrs);
extern CBRPN *__HC_ICAdd_RelocUnqiue(CBCmpCtrl *cmpc, CBCodeCtrl *cc, I64 *pat_addr, U8 *sym, I64 rt, I64 ptrs);
// The frontend imports it under the correctly spelled name (main.c: STK___HC_ICAdd_RelocUnique).
extern CBRPN *__HC_ICAdd_RelocUnique(CBCmpCtrl *cmpc, CBCodeCtrl *cc, I64 *pat_addr, U8 *sym, I64 rt, I64 ptrs);
extern U0 __HC_SetAOTRelocBeforeRIP(CBRPN *r, I64 off);
extern I64 __HC_CodeMiscIsUsed(CBCodeMisc *cm);
extern CBRPN *__HC_ICAdd_StaticData(CBCmpCtrl *cmp, CBCodeCtrl *cc, I64 at, U8 *d, I64 len);
extern CBRPN *__HC_ICAdd_SetStaticsSize(CBCodeCtrl *cc, I64 len);
extern CBRPN *__HC_ICAdd_StaticRef(CBCodeCtrl *cc, I64 off, I64 rt, I64 ptrs);
extern U0 __HC_CmpCtrl_SetAOT(CBCmpCtrl *cc);
extern CBCodeMiscRef *CodeMiscAddRef(CBCodeMisc *misc, I32 *addr);
extern U0 __HC_ICSetLock(CBRPN *l);
extern CBRPN *__HC_ICAdd_GetVargsPtr(CBCodeCtrl *cc);
extern U0 __HC_CodeMiscInterateThroughRefs(CBCodeMisc *cm, U0 (*fptr)(U8 *addr, U8 *user_data), U8 *user_data);
extern U0 __HC_CmpCtrlSetRip(CBCmpCtrl *cc, I64 rip); // imported by the frontend, no C implementation (stub)
extern U0 CacheRPNArgs(CBCmpCtrl *cctrl);

// parser.c helpers used by the backend / optpass
extern CBCodeCtrl *CodeCtrlPush(CBCmpCtrl *ccmp);
extern U0 CodeCtrlDel(CBCodeCtrl *ctrl);
extern CBCodeMisc *CodeMiscNew(CBCmpCtrl *ccmp, I64 type);
extern U0 CodeCtrlPop(CBCmpCtrl *ccmp);
extern CBCmpCtrl *BCmpCtrlDel(CBCmpCtrl *d);
extern CBCmpCtrl *BCmpCtrlNew(CBLexer *lex);
extern CBRPN *ICFwd(CBRPN *rpn);
extern CBRPN *ICArgN(CBRPN *rpn, I64 n);
extern I64 BAssignRawTypeToNode(CBCmpCtrl *ccmp, CBRPN *rpn);
extern U0 ICFree(CBRPN *ic);

// Function-like macros of the C headers / files, as functions (bodies in IRBind.HC)
extern U0 BAssert(Bool cond, U8 *what); // print `what` and halt when cond is FALSE (C assert())
extern F64 BToF64(I64 x);
extern I64 BToI64(F64 x);
extern U64 BF64ToU64(F64 x);
extern U8 *BCodeAlloc(I64 size,CBHeapCtrl *heap);
extern U0 BCodeCommit(U8 *obin);
extern U8 *MemGetWritePtr(U8 *ptr);     // identity outside OpenBSD/NetBSD
extern U8 *MemGetExecPtr(U8 *ptr);      // identity outside OpenBSD/NetBSD
extern I64 __builtin_ffsll(I64 x);      // 1+index of the lowest set bit, 0 if x==0
extern I64 __builtin_popcountll(I64 x);
extern I64 __builtin_clzl(I64 x);       // count of leading zero bits, x!=0
extern I64 __builtin_ctzl(I64 x);       // count of trailing zero bits, x!=0
extern U0 __builtin___clear_cache(U8 *begin, U8 *end); //INTEGRATION: I-cache flush, stubbed
extern U0 sys_icache_invalidate(U8 *begin, I64 len);   //INTEGRATION: I-cache flush, stubbed

// ---- Host runtime used by the port (INTEGRATION: provided by the CoolC kernel, wired up later) ----
extern CBTask *BFs;                                                    //INTEGRATION: current task
extern CBHash *BHashFind(U8 *str, CBHashTable *table, I64 type, I64 inst); //INTEGRATION
extern U0 BHashAdd(CBHash *h, CBHashTable *table);                     //INTEGRATION
extern CBHeapCtrl *BHeapCtrlInit(CBHeapCtrl *ct, CBTask *task, I64 is_code_heap); //INTEGRATION
extern U0 BHeapCtrlDel(CBHeapCtrl *ct);                                //INTEGRATION
#ifdef BACKEND_STANDALONE // MSize: kernel provides it
extern I64 MSize(U8 *ptr);
#endif
extern I64 BSetWriteNP(I64 n);                                         //INTEGRATION: W^X toggle (Apple), identity elsewhere
extern I64 BDoNothing();                                               //INTEGRATION
#ifdef BACKEND_STANDALONE // Que*: kernel provides them
extern U0 BQueIns(CBQue *a, CBQue *to);
extern U0 BQueRem(CBQue *a);
extern U0 BQueInit(CBQue *i);
extern U0 BQueDel(CBQue *f);
extern I64 BQueCnt(CBQue *head);
#endif
extern I64 BFFICall2(U8 *fptr, I64 a, I64 b);                    //INTEGRATION
extern U0 BQSort(U8 *base, I64 cnt, I64 sz, U8 *cmp);                  //INTEGRATION: libc BQSort (cmp takes two element pointers)
extern F64 BFMod(F64 a, F64 b);                                        //INTEGRATION: libc
extern F64 BPow(F64 a, F64 b);                                         //INTEGRATION: libc

// Replacements for arm_backend.c macros, defined in ArmBackendA.HC and used by
// both halves. Each returns the new code_off.
extern I64 AIWNIOS_ADD_CODE(U8 *bin,I64 code_off,I64 val);
extern I64 TYPECAST_ASSIGN_BEGIN(CBCmpCtrl *cctrl,CBRPN **dst,CBRPN *src,
                                 CBICArg *_orig,I64 *pop,I64 *pop2,U8 *bin,I64 code_off);
extern I64 TYPECAST_ASSIGN_END(CBCmpCtrl *cctrl,I64 pop,CBICArg *_orig,
                               U8 *bin,I64 code_off);

// ---- Kernel heap/string/print functions used by the port (INTEGRATION: provided by the CoolC kernel) ----
// These are only declared for standalone syntax checks (#define BACKEND_STANDALONE): the backend is
// included after the kernel/runtime that defines them, and an extern here would hide those definitions.
#ifdef BACKEND_STANDALONE // kernel provides these
extern U8 *MAlloc(I64 size);
extern U8 *CAlloc(I64 size);
extern U0 Free(U8 *ptr);
extern U8 *StrNew(U8 *s);
extern U8 *MemCpy(U8 *dst, U8 *src, I64 cnt);
extern U8 *MemSet(U8 *dst, I64 val, I64 cnt);
extern I64 StrLen(U8 *s);
extern I64 StrCmp(U8 *a, U8 *b);
extern U0 Print(U8 *fmt, ...);
#endif

// ---- Frontend diagnostics used by BAssignRawTypeToNode (INTEGRATION: the HolyC frontend's error reporting) ----
extern I64 ParseErr(CBCmpCtrl *ctrl, U8 *fmt, ...);
extern I64 ParseWarn(CBCmpCtrl *ctrl, U8 *fmt, ...);

// ---- Defined in IRBind.HC ----
extern U0 abort();                              // print and halt (C abort())
extern I64 BETWEEN(I64 a, I64 min, I64 max);    // C macro: a>=min && a<=max

#ifdef BACKEND_STANDALONE
extern U0 throw(I64 code); //INTEGRATION: kernel exception throw (keyword in full HolyC)
#endif
