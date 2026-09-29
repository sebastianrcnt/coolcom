// ARM64 disassembler, from Aiwnios (nrootconauto, BSD-3, commit e155e87,
// Src/UAsmARM64.HC). Changes: the opcode table comes from Arm64Ops.csv in
// the Image (LoadOpcodes), opcodes are not added to the compiler's asm hash,
// and GenTests is left out. DisasOpc is rewritten: the table still names the
// instruction, but operands are decoded from its bits and printed the way
// objdump does (Aiwnios printed raw fields, unsigned offsets and x31 for sp
// and zr). Uf, Disas and backtraces are in KDbg.HC.

I64 Sext(I64 v, I64 bits) {
    if (v & (1 << (bits - 1)))
        return -(1 << bits - v);
    return v;
}
I64 Arm64GetValue(CArm64Opc *opc, U32 inst, I64 which, I64 occ = 1, U8 specific = 'X') {
    I64 o;
    U8 buf[STR_LEN];
    for (o = 0; o != 16; o++) {
        if (opc->operands[o].type == which) {
            if (!--occ) {
                if (opc->operands[o].offset)
                    inst >>= opc->operands[o].offset;
                switch (which) {
                    case ARM64_OP_IMM9:
                        return Sext(inst & (1 << 9 - 1), 9);
                    case ARM64_OP_IMM7:
                        return Sext(inst & (1 << 7 - 1), 7);
                    case ARM64_OP_IMM19:
                        return Sext(inst & (1 << 19 - 1), 19);
                    case ARM64_OP_REG:
                        if (specific) {
                            StrPrint(buf, "%c%d", specific, inst & (1 << 5 - 1));
                            return buf[0](U64);
                        }
                        return inst & (1 << 5 - 1);
                    case ARM64_OP_B5:
                        return inst & 1;
                    case ARM64_OP_B40:
                        return inst & 0b1111;
                    case ARM64_OP_IMM14:
                        return Sext(inst & (1 << 14 - 1), 14);
                    case ARM64_OP_COND:
                        return inst & 0b1111;
                    case ARM64_OP_R:
                    case ARM64_OP_IMM26:
                        return Sext(inst & (1 << 26 - 1), 26);
                    case ARM64_OP_IMMLO:
                        return inst & (1 << 2 - 1);
                    case ARM64_OP_IMMHI:
                        return inst & (1 << 19 - 1);
                    case ARM64_OP_IMMS:
                    case ARM64_OP_IMMR:
                    case ARM64_OP_OPTION:
                    case ARM64_OP_SHIFT:
                        return inst & 0b11;
                    case ARM64_OP_S:
                        return inst & 0b1;
                    case ARM64_OP_IMM5:
                        return Sext(inst & (1 << 5 - 1), 5);
                    case ARM64_OP_NZCV:
                    case ARM64_OP_IMM4:
                        return Sext(inst & (1 << 4 - 1), 4);
                    case ARM64_OP_Q:
                    case ARM64_OP_IMM16:
                        return Sext(inst & (1 << 16 - 1), 16);
                    case ARM64_OP_IMM12:
                        return Sext(inst & (1 << 12 - 1), 12);
                }
            }
        }
    }
    return -1;
}
I64 Arm64SetValue(CArm64Opc *opc, U32 inst, I64 which, I64 value, I64 occ = 1) {
    I64 ret = inst;
    I64 o;
    I64 off;
    for (o = 0; o != 16; o++) {
        if (opc->operands[o].type == which) {
            if (!--occ) {
                if (opc->operands[o].offset)
                    off = opc->operands[o].offset;
                else
                    off = 0;
                switch (which) {
                    case ARM64_OP_IMM9:
                        value &= 1 << 9 - 1;
                        break;
                    case ARM64_OP_IMM7:
                        value &= 1 << 7 - 1;
                        break;
                    case ARM64_OP_IMM19:
                        value &= 1 << 19 - 1;
                        break;
                    case ARM64_OP_REG:
                        value &= 1 << 5 - 1;
                        break;
                    case ARM64_OP_B5:
bt:
                        if (value)
                            Bts(&ret, off);
                        else
                            Btr(&ret, off);
                        goto fin;
                    case ARM64_OP_B40:
                        value &= 0b1111;
                        break;
                    case ARM64_OP_IMM14:
                        value &= 1 << 14 - 1;
                        break;
                    case ARM64_OP_COND:
                        value &= 0b1111;
                        break;
                    case ARM64_OP_R:
                    case ARM64_OP_IMM26:
                        value &= 1 << 26 - 1;
                        break;
                    case ARM64_OP_IMMLO:
                        value &= 1 << 2 - 1;
                        break;
                    case ARM64_OP_IMMHI:
                        value = 1 << 19 - 1;
                        break;
                    case ARM64_OP_IMMS:
                    case ARM64_OP_IMMR:
                    case ARM64_OP_OPTION:
                    case ARM64_OP_SHIFT:
                        value &= 0b11;
                        break;
                    case ARM64_OP_S:
                        goto bt;
                    case ARM64_OP_IMM5:
                        value &= 1 << 5 - 1;
                        break;
                    case ARM64_OP_NZCV:
                    case ARM64_OP_IMM4:
                        value &= 1 << 4 - 1;
                        break;
                    case ARM64_OP_Q:
                    case ARM64_OP_IMM16:
                        value &= 1 << 16 - 1;
                        break;
                    case ARM64_OP_IMM12:
                        value &= 1 << 12 - 1;
                        break;
                }
                ret |= value << off;
            }
        }
    }
fin:;
    return ret;
}
U8 *ReadALine(U8 **_ptr) {
    U8 *ptr = *_ptr;
    if (!*ptr) return NULL;
    U8 *en = StrFirstOcc(ptr, "\n"), *ret;
    if (!en) {
        en = StrLen(ptr) + ptr;
    }
    ret = MAlloc(en - ptr + 1);
    MemCpy(ret, ptr, en - ptr);
    ret[en - ptr] = 0;
    if (*en == '\n')
        en++;
    *_ptr = en;
    return ret;
}
U8 *ReadAFeild(U8 **_ptr) {
    U8 *ptr = *_ptr;
    U8 *en = StrFirstOcc(ptr, ","), *ret;
    if (!en) {
        en = StrLen(ptr) + ptr;
    }
    ret = MAlloc(en - ptr + 1);
    MemCpy(ret, ptr, en - ptr);
    ret[en - ptr] = 0;
    if (*en == ',')
        en++;
    *_ptr = en;
    return ret;
}
CArm64Opc **arm64_opcodes_flat;

U0 LoadOpcodes() {
    //Build the opcode table from Arm64Ops.csv (tools/mkarm64ops.py), embedded
    //in the Image (ArchArm64Ops). Aiwnios reads its full CSV from disk.
    U8 *optr = StrNew(ArchArm64Ops), *ptr = optr;
    I64 max_opc_cnt = StrOcc(optr, '\n') + 1;
    U8 *oln, *ln, *field;
    U8 *name, *prepend, *append;
    CArm64Opc *opc, **store_at;
    I64 operand, bit, num, bit2;
    store_at = arm64_opcodes_flat = CAlloc((max_opc_cnt + 1) * 8);
    Free(ReadALine(&ptr)); //Skip table header line
    while (oln = ReadALine(&ptr)) {
        ln = oln;
        //num
        field = ReadAFeild(&ln);
        num = Str2I64(field);
        Free(field);
        //Opcode name
        name = ReadAFeild(&ln);
        if (!StrLen(name)) {
            Free(name);
            goto next;
        }
        //Prepend
        prepend = ReadAFeild(&ln);
        //Append
        append = ReadAFeild(&ln);
        opc = CAlloc(sizeof(CArm64Opc));
        opc->num = num;
        opc->str = StrNew(name);
        opc->type = HTT_OPCODE;
        *store_at++ = opc;
        Free(name);
        //Specific
        field = ReadAFeild(&ln);
        opc->flags = StrNew(field);  // the variant, e.g. "Double_precision_to_64_bit" (DisasOpc)
        if (field && field[0] != 'v')
            opc->specific = field[0];
        else {
            if (StrMatch("Single", append) || StrMatch("Single", append))
                opc->specific = 'S';
            else if (StrMatch("Double", append) || StrMatch("Double", prepend))
                opc->specific = 'D';
            else
                opc->specific = 0;
        }
        Free(field);
        Free(prepend);
        Free(append);
        //Get first 9 bits
        operand = 0;
        for (bit = 31; bit >= 0; --bit) {
            field = ReadAFeild(&ln);
            for (bit2 = 0; ln[bit2] == ','; bit2++)
                ;
            bit2 = bit - bit2;
            if (bit2 < 0) bit2 = 0;
            if (!StrLen(field)) {
            } else if (!StrCmp(field, "1")) {
                Bts(&opc->value, bit);
                Bts(&opc->mask, bit);
            } else if (!StrCmp(field, "0")) {
                Bts(&opc->mask, bit);
            } else if (!StrCmp(field, "-")) {
            } else if (!StrCmp(field, "b5")) {
                opc->operands[operand].type = ARM64_OP_B5;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "b40")) {
                opc->operands[operand].type = ARM64_OP_B40;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imm14")) {
                opc->operands[operand].type = ARM64_OP_IMM14;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "cond")) {
                opc->operands[operand].type = ARM64_OP_COND;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imm19")) {
                opc->operands[operand].type = ARM64_OP_IMM19;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imm16")) {
                opc->operands[operand].type = ARM64_OP_IMM16;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "Rt2")
                       || !StrCmp(field, "Rt")
                       || !StrCmp(field, "Rn")
                       || !StrCmp(field, "Rs")
                       || !StrCmp(field, "Rm")
                       || !StrCmp(field, "Rd")
                       || !StrCmp(field, "Ra")) {
                opc->operands[operand].type = ARM64_OP_REG;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imm26")) {
                opc->operands[operand].type = ARM64_OP_IMM26;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imm7")) {
                opc->operands[operand].type = ARM64_OP_IMM7;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imm9")) {
                opc->operands[operand].type = ARM64_OP_IMM9;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imm12")) {
                opc->operands[operand].type = ARM64_OP_IMM12;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "immlo")) {
                opc->operands[operand].type = ARM64_OP_IMMLO;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "immhi")) {
                opc->operands[operand].type = ARM64_OP_IMMHI;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imms")) {
                opc->operands[operand].type = ARM64_OP_IMMS;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "immr")) {
                opc->operands[operand].type = ARM64_OP_IMMR;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "option")) {
                opc->operands[operand].type = ARM64_OP_OPTION;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "shift")) {
                opc->operands[operand].type = ARM64_OP_SHIFT;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imm5")) {
                opc->operands[operand].type = ARM64_OP_IMM5;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "imm4")) {
                opc->operands[operand].type = ARM64_OP_IMM4;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "nzcv")) {
                opc->operands[operand].type = ARM64_OP_NZCV;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "Q")) {
                opc->operands[operand].type = ARM64_OP_Q;
                opc->operands[operand++].offset = bit2;
            } else if (!StrCmp(field, "Q")) {
                opc->operands[operand].type = ARM64_OP_S;
                opc->operands[operand++].offset = bit2;
            }
            Free(field);
        }
next:;
        Free(oln);
    }
    Free(optr);
}
U8 *ArmCond2Str(I64 cond) {
    switch (cond) {
        case 0: return "EQ";
        case 1: return "NE";
        case 2: return "CS";
        case 3: return "CC";
        case 4: return "MI";
        case 5: return "PL";
        case 6: return "VS";
        case 7: return "VC";
        case 8: return "HI";
        case 9: return "LS";
        case 0xa: return "GE";
        case 0xb: return "LT";
        case 0xc: return "GT";
        case 0xd: return "LE";
        case 0xe: return "AL";
        case 0xf: return "NV";
    }
    return NULL;
}
I64 ImmSImmR2Val(U32 inst) {
    inst = (inst >> 10) & (1 << 13 - 1);
    Bool n = !!(inst & (1 << 12));
    I64 s = inst & (1 << 6 - 1), r = (inst >> 6) & (1 << 6 - 1);
    I64 consec, base_pat, width, idx, idx2, final;
    if (n) {
        consec = s + 1;
        width = 64;
    } else if (s & 0b111110 == 0b111100) {
        consec = 1 + (s & 1);
        width = 2;
    } else if (s & 0b111100 == 0b111000) {
        consec = 1 + (s & 0b11);
        width = 4;
    } else if (s & 0b111000 == 0b110000) {
        consec = 1 + (s & 0b111);
        width = 8;
    } else if (s & 0b110000 == 0b100000) {
        consec = 1 + (s & 0b1111);
        width = 16;
    } else if (s & 0b100000 == 0b000000) {
        consec = 1 + (s & 0b11111);
        width = 32;
    }
    final = 0;
    for (idx = 0; idx != 64 / width; idx++) {
        for (idx2 = 0; idx2 != consec; idx2++) {
            Bts(&final, (idx * width + idx2 - r) & 63);
        }
    }
    return final;
}
U8 *ArmShmod2Str(I64 opt) {
    switch (opt) {
        case 0b00: return "LSL";
        case 0b01: return "LSR";
        case 0b10: return "ASR";
        case 0b11: return "ROR";
    }
    return NULL;
}
U8 *ArmOption2Str(I64 opt) {
    switch (opt) {
        case 0b000: return "UXTB";
        case 0b001: return "UXTH";
        case 0b010: return "LSL";
        case 0b011: return "UXTX";
        case 0b100: return "SXTB";
        case 0b101: return "SXTH";
        case 0b110: return "SXTW";
        case 0b111: return "SXTX";
    }
    return NULL;
}
// ---- Printing. Operands are decoded from the instruction's bits (the
// table above identifies the instruction), in objdump's syntax: lower case,
// sp/xzr/wzr for register 31, #immediates, [base, #offset], and objdump's
// aliases (mov, cmp, cset, lsl, ubfx, mul, ...). ----

I64 DBits(U32 inst, I64 hi, I64 lo)
{//Field inst[hi:lo].
    return inst >> lo & (1 << (hi - lo + 1) - 1);
}

I64 DSBits(U32 inst, I64 hi, I64 lo)
{//Sign-extended field inst[hi:lo].
    return Sext(DBits(inst, hi, lo), hi - lo + 1);
}

U0 DReg(U8 *line, I64 n, I64 kind, Bool sp = FALSE)
{//Append register n; kind 'X' 'W' (31 is sp/wsp if sp, else xzr/wzr) or 'B' 'H' 'S' 'D' 'Q'.
    if (kind == 'X') {
        if (n != 31)
            CatPrint(line, "x%d", n);
        else if (sp)
            CatPrint(line, "sp");
        else
            CatPrint(line, "xzr");
    } else if (kind == 'W') {
        if (n != 31)
            CatPrint(line, "w%d", n);
        else if (sp)
            CatPrint(line, "wsp");
        else
            CatPrint(line, "wzr");
    } else
        CatPrint(line, "%c%d", ToLower(kind), n);
}

U0 DSep(U8 *line)
{
    CatPrint(line, ", ");
}

U0 DTarget(U8 *line, U8 *target)
{//A branch or literal address: absolute, and the function it is in.
    U8 buf[STR_LEN];
    StrPrintFunSeg(buf, target);
    if (buf[0] == '0' && buf[1] == 'x')
        CatPrint(line, "0x%X", target);
    else
        CatPrint(line, "0x%X <%s>", target, buf);
}

U0 DMem(U8 *line, I64 rn, I64 off, I64 mode)
{//Base-register address: mode 0 [xn, #off], 1 pre-index [xn, #off]!, 2 post-index [xn], #off.
    CatPrint(line, "[");
    DReg(line, rn, 'X', TRUE);
    if (mode == 2)
        CatPrint(line, "], #%d", off);
    else {
        if (off || mode == 1)
            CatPrint(line, ", #%d", off);
        CatPrint(line, "]");
        if (mode == 1)
            CatPrint(line, "!");
    }
}

I64 DInvCond(I64 cond)
{
    return cond ^ 1;
}

U0 DCond(U8 *line, I64 cond)
{
    U8 *s = ArmCond2Str(cond), buf[4];
    StrCpy(buf, s);
    CatPrint(line, "%s", StrUtil(buf, SUF_TO_LOWER));
}

I64 DKindOfWord(U8 *s)
{//Register kind of one side of a conversion's name ("Double_precision", "64_bit", ...).
    if (!StrNCmp(s, "Single", 6) || !StrNCmp(s, "single", 6))
        return 'S';
    if (!StrNCmp(s, "Double", 6) || !StrNCmp(s, "double", 6))
        return 'D';
    if (!StrNCmp(s, "Half", 4) || !StrNCmp(s, "half", 4))
        return 'H';
    if (!StrNCmp(s, "32_bit", 6))
        return 'W';
    if (!StrNCmp(s, "64_bit", 6))
        return 'X';
    return 'D';
}

Bool DConvKinds(CArm64Opc *opc, I64 *_dst, I64 *_src)
{//"X_to_Y" in the opcode's variant: Rd is Y, Rn is X.
    U8 *v = opc->flags, *to;
    if (!v || !(to = StrMatch("_to_", v)))
        return FALSE;
    *_src = DKindOfWord(v);
    *_dst = DKindOfWord(to + 4);
    return TRUE;
}

I64 DKind(CArm64Opc *opc)
{//Register kind of a data or load/store register: the table's, else by name.
    U8 *s = opc->str;
    if (opc->specific && StrOcc("WXBHSDQ", opc->specific))
        return opc->specific;
    if (StrMatch("SW", s))
        return 'X';  // LDRSW, LDPSW
    return 'W';      // byte and halfword loads and stores
}

I64 DScale(CArm64Opc *opc)
{//Bytes per element of a load or store, from its register kind and name.
    I64 k = DKind(opc);
    U8 *s = opc->str;
    if (k == 'Q')
        return 16;
    if (k == 'D')
        return 8;
    if (k == 'S')
        return 4;
    if (k == 'H')
        return 2;
    if (k == 'B')
        return 1;
    if (StrMatch("SW", s))
        return 4;
    if (StrMatch("B", s + 3) || !StrCmp(s, "STRB") || !StrCmp(s, "LDRB") || !StrCmp(s, "STURB") ||
            !StrCmp(s, "LDURB") || !StrCmp(s, "STTRB") || !StrCmp(s, "LDTRB") || StrMatch("SB", s))
        return 1;
    if (StrMatch("H", s + 3) || StrMatch("SH", s) || !StrCmp(s, "STRH") || !StrCmp(s, "LDRH"))
        return 2;
    if (k == 'X')
        return 8;
    return 4;
}

// System registers and SYS operations by instruction bits 20..5:
// op0:op1:CRn:CRm:op2 (op0 is 1 for SYS, 2 or 3 for MRS/MSR).
U16 dsys_reg_nums[40] = {0xDA10, 0xDA11, 0xDA20, 0xDA21, 0xD801, 0xD807, 0xDE82, 0xDE83, 0xDF00, 0xDF01, 0xDF02, 0xDF10, 0xDF11, 0xDF12, 0xDF18, 0xDF19, 0xDF1A, 0xC000, 0xC005, 0xC038, 0xC080, 0xC082, 0xC100, 0xC101, 0xC102, 0xC200, 0xC201, 0xC208, 0xC210, 0xC212, 0xC290, 0xC300, 0xC510, 0xC600, 0xC684, 0xC708, 0xE088, 0xE200, 0xE201, 0xE708};
U8 *dsys_reg_names[40] = {"nzcv", "daif", "fpcr", "fpsr", "ctr_el0", "dczid_el0", "tpidr_el0", "tpidrro_el0", "cntfrq_el0", "cntpct_el0", "cntvct_el0", "cntp_tval_el0", "cntp_ctl_el0", "cntp_cval_el0", "cntv_tval_el0", "cntv_ctl_el0", "cntv_cval_el0", "midr_el1", "mpidr_el1", "id_aa64mmfr0_el1", "sctlr_el1", "cpacr_el1", "ttbr0_el1", "ttbr1_el1", "tcr_el1", "spsr_el1", "elr_el1", "sp_el0", "spsel", "currentel", "esr_el1", "far_el1", "mair_el1", "vbar_el1", "tpidr_el1", "cntkctl_el1", "hcr_el2", "spsr_el2", "elr_el2", "cnthctl_el2"};

U8 *DSysRegName(I64 n)
{//MRS/MSR register name, NULL if not known.
    I64 i;
    for (i = 0; i < 40; i++)
        if (dsys_reg_nums[i] == n)
            return dsys_reg_names[i];
    return NULL;
}

U16 dsys_op_nums[21] = {0x4388, 0x43A8, 0x5BA9, 0x5BA1, 0x43B1, 0x43B2, 0x5BD1, 0x43D2, 0x5BD9, 0x5BF1, 0x43F2, 0x4418, 0x4419, 0x441A, 0x441B, 0x4438, 0x4439, 0x443A, 0x443B, 0x443D, 0x643C};
U8 *dsys_op_names[21] = {"ic ialluis", "ic iallu", "ic ivau", "dc zva", "dc ivac", "dc isw", "dc cvac", "dc csw", "dc cvau", "dc civac", "dc cisw", "tlbi vmalle1is", "tlbi vae1is", "tlbi aside1is", "tlbi vaae1is", "tlbi vmalle1", "tlbi vae1", "tlbi aside1", "tlbi vaae1", "tlbi vale1", "tlbi alle1"};

U8 *DSysOpName(I64 n)
{//SYS aliases: cache and TLB maintenance.
    I64 i;
    for (i = 0; i < 21; i++)
        if (dsys_op_nums[i] == n)
            return dsys_op_names[i];
    return NULL;
}

U8 *DisasOpc(CDoc *doc, U32 *ptr)
{
    U32 inst = *ptr;
    CArm64Opc **opcs, *opc;
    U8 line[STR_LEN * 2], mnem[STR_LEN], *nm;
    I64 k, rd, rn, rm, ra, rt2, imm, sh, immr, imms, size, cond, opt, amt, dk, sk;
    Bool sf;
    opcs = arm64_opcodes_flat;
    if (!opcs)
        return ptr + 1;
    while (opc = *opcs) {
        if (opc->mask & inst == opc->value)
            goto found;
        opcs++;
    }
    DocPrint(doc, "%P\t.word 0x%08X\n", ptr, inst);
    return ptr + 1;
found:
    StrCpy(mnem, opc->str);
    StrUtil(mnem, SUF_TO_LOWER);
    line[0] = 0;
    k = DKind(opc);
    sf = k == 'X';
    size = 32;
    if (sf)
        size = 64;
    rd = inst & 31;
    rn = inst >> 5 & 31;
    rm = inst >> 16 & 31;
    ra = inst >> 10 & 31;
    rt2 = ra;
    switch (opc->num) {
        case 3:
            StrCpy(mnem, ".word");
            CatPrint(line, "0x%08X", inst);
            break;
        case 6...9:  // cbz, cbnz
            DReg(line, rd, k);
            DSep(line);
            DTarget(line, ptr + DSBits(inst, 23, 5));
            break;
        case 11...12:  // tbz, tbnz
            imm = DBits(inst, 31, 31) << 5 | DBits(inst, 23, 19);
            if (imm < 32)
                DReg(line, rd, 'W');
            else
                DReg(line, rd, 'X');
            CatPrint(line, ", #%d, ", imm);
            DTarget(line, ptr + DSBits(inst, 18, 5));
            break;
        case 14:  // b.cond
            StrCpy(mnem, "b.");
            DCond(mnem, inst & 15);
            DTarget(line, ptr + DSBits(inst, 23, 5));
            break;
        case 16...23:  // svc hvc smc brk hlt dcps
            CatPrint(line, "#0x%X", DBits(inst, 20, 5));
            break;
        case 26:  // hint
            imm = DBits(inst, 11, 5);
            switch (imm) {
                case 0: StrCpy(mnem, "nop"); break;
                case 1: StrCpy(mnem, "yield"); break;
                case 2: StrCpy(mnem, "wfe"); break;
                case 3: StrCpy(mnem, "wfi"); break;
                case 4: StrCpy(mnem, "sev"); break;
                case 5: StrCpy(mnem, "sevl"); break;
                default: CatPrint(line, "#0x%X", imm);
            }
            break;
        case 28...30:  // dsb dmb isb
            imm = DBits(inst, 11, 8);
            if (opc->num == 30 && imm == 15)
                break;
            switch (imm) {
                case 15: CatPrint(line, "sy"); break;
                case 14: CatPrint(line, "st"); break;
                case 13: CatPrint(line, "ld"); break;
                case 11: CatPrint(line, "ish"); break;
                case 10: CatPrint(line, "ishst"); break;
                case 9: CatPrint(line, "ishld"); break;
                case 7: CatPrint(line, "nsh"); break;
                case 3: CatPrint(line, "osh"); break;
                default: CatPrint(line, "#0x%X", imm);
            }
            break;
        case 27:  // clrex
        case 39...40:  // eret drps
            break;
        case 25:  // msr (immediate): pstate field
            imm = DBits(inst, 18, 16) << 3 | DBits(inst, 7, 5);
            if (imm == 0x1E)
                CatPrint(line, "daifset");
            else if (imm == 0x1F)
                CatPrint(line, "daifclr");
            else if (imm == 0x05)
                CatPrint(line, "spsel");
            else
                CatPrint(line, "pstate_%d_%d", DBits(inst, 18, 16), DBits(inst, 7, 5));
            CatPrint(line, ", #0x%X", DBits(inst, 11, 8));
            break;
        case 31...34:  // sys msr sysl mrs
            imm = DBits(inst, 20, 5);
            if (opc->num == 31 && (nm = DSysOpName(imm))) {  // dc ic tlbi
                StrCpy(mnem, nm);
                *StrFirstOcc(mnem, " ") = 0;
                CatPrint(line, "%s", StrFirstOcc(nm, " ") + 1);
                if (rd != 31 || mnem[0] != 't') {
                    DSep(line);
                    DReg(line, rd, 'X');
                }
                break;
            }
            if (opc->num == 33 || opc->num == 34) {
                DReg(line, rd, 'X');
                DSep(line);
            }
            if (nm = DSysRegName(imm))
                CatPrint(line, "%s", nm);
            else
                CatPrint(line, "s%d_%d_c%d_c%d_%d", DBits(inst, 20, 19), DBits(inst, 18, 16),
                         DBits(inst, 15, 12), DBits(inst, 11, 8), DBits(inst, 7, 5));
            if (opc->num == 31 || opc->num == 32) {
                DSep(line);
                DReg(line, rd, 'X');
            }
            break;
        case 36...38:  // br blr ret
            if (opc->num != 38 || rn != 30)
                DReg(line, rn, 'X');
            break;
        case 42...43:  // b bl
            DTarget(line, ptr + DSBits(inst, 25, 0));
            break;
        case 46...77:  // exclusive and acquire/release
            if (mnem[0] == 's' && StrMatch("x", mnem)) {  // stxr stlxr stxp stlxp: status
                DReg(line, rm, 'W');
                DSep(line);
            }
            DReg(line, rd, k);
            if (StrMatch("xp", mnem)) {
                DSep(line);
                DReg(line, rt2, k);
            }
            DSep(line);
            DMem(line, rn, 0, 0);
            break;
        case 79...85:  // ldr (literal), prfm
            if (opc->num == 85)
                CatPrint(line, "#%d", rd);
            else
                DReg(line, rd, k);
            DSep(line);
            DTarget(line, ptr + DSBits(inst, 23, 5));
            break;
        case 87...132:  // pairs: 87-96 non-temporal, 98-108 post, 110-120 offset, 122-132 pre
            DReg(line, rd, k);
            DSep(line);
            DReg(line, rt2, k);
            DSep(line);
            if (98 <= opc->num <= 108)
                DMem(line, rn, DSBits(inst, 21, 15) * DScale(opc), 2);
            else if (122 <= opc->num)
                DMem(line, rn, DSBits(inst, 21, 15) * DScale(opc), 1);
            else
                DMem(line, rn, DSBits(inst, 21, 15) * DScale(opc), 0);
            break;
        case 134...219:  // imm9: 134-157 unscaled, 159-181 post, 183-195 unprivileged, 197-219 pre
            if (StrMatch("prf", mnem))
                CatPrint(line, "#%d", rd);
            else
                DReg(line, rd, k);
            DSep(line);
            imm = DSBits(inst, 20, 12);
            if (159 <= opc->num <= 181)
                DMem(line, rn, imm, 2);
            else if (197 <= opc->num)
                DMem(line, rn, imm, 1);
            else
                DMem(line, rn, imm, 0);
            break;
        case 220...245:  // register offset
            if (StrMatch("prf", mnem))
                CatPrint(line, "#%d", rd);
            else
                DReg(line, rd, k);
            CatPrint(line, ", [");
            DReg(line, rn, 'X', TRUE);
            DSep(line);
            opt = DBits(inst, 15, 13);
            if (opt & 1)
                DReg(line, rm, 'X');
            else
                DReg(line, rm, 'W');
            amt = 0;
            if (DBits(inst, 12, 12))
                amt = Bsf(DScale(opc));
            if (opt == 3) {
                if (DBits(inst, 12, 12))
                    CatPrint(line, ", lsl #%d", amt);
            } else {
                CatPrint(line, ", %s", ArmOption2Str(opt));
                StrUtil(line, SUF_TO_LOWER);
                if (DBits(inst, 12, 12))
                    CatPrint(line, " #%d", amt);
            }
            CatPrint(line, "]");
            break;
        case 246...269:  // unsigned offset
            if (StrMatch("prf", mnem))
                CatPrint(line, "#%d", rd);
            else
                DReg(line, rd, k);
            DSep(line);
            DMem(line, rn, DBits(inst, 21, 10) * DScale(opc), 0);
            break;
        case 272:  // adr
            DReg(line, rd, 'X');
            DSep(line);
            DTarget(line, ptr(U8 *) + Sext(DBits(inst, 23, 5) << 2 | DBits(inst, 30, 29), 21));
            break;
        case 273:  // adrp
            DReg(line, rd, 'X');
            DSep(line);
            DTarget(line, ptr(I64) & ~0xFFF + Sext(DBits(inst, 23, 5) << 2 | DBits(inst, 30, 29), 21) << 12);
            break;
        case 275...282:  // add/sub (immediate)
            imm = DBits(inst, 21, 10);
            if (DBits(inst, 22, 22))
                imm <<= 12;
            if (StrMatch("s", mnem + 3) && rd == 31) {  // adds/subs to zr: cmn/cmp
                if (mnem[0] == 'a')
                    StrCpy(mnem, "cmn");
                else
                    StrCpy(mnem, "cmp");
                DReg(line, rn, k, TRUE);
            } else if (!imm && mnem[0] == 'a' && !mnem[3] && (rd == 31 || rn == 31)) {
                StrCpy(mnem, "mov");
                DReg(line, rd, k, TRUE);
                DSep(line);
                DReg(line, rn, k, TRUE);
                break;
            } else {
                DReg(line, rd, k, !mnem[3]);
                DSep(line);
                DReg(line, rn, k, TRUE);
            }
            CatPrint(line, ", #0x%X", imm);
            break;
        case 284...291:  // logical (immediate)
            imm = ImmSImmR2Val(inst);
            if (!sf)
                imm &= 0xFFFFFFFF;
            if (!StrCmp(mnem, "orr") && rn == 31) {
                StrCpy(mnem, "mov");
                DReg(line, rd, k, TRUE);
            } else if (!StrCmp(mnem, "ands") && rd == 31) {
                StrCpy(mnem, "tst");
                DReg(line, rn, k);
            } else {
                DReg(line, rd, k, StrCmp(mnem, "ands"));
                DSep(line);
                DReg(line, rn, k);
            }
            CatPrint(line, ", #0x%X", imm);
            break;
        case 293...298:  // movn movz movk
            imm = DBits(inst, 20, 5);
            sh = DBits(inst, 22, 21) * 16;
            DReg(line, rd, k);
            if (!StrCmp(mnem, "movk")) {
                CatPrint(line, ", #0x%X", imm);
                if (sh)
                    CatPrint(line, ", lsl #%d", sh);
            } else if (!StrCmp(mnem, "movz") && (imm || !sh)) {
                StrCpy(mnem, "mov");
                CatPrint(line, ", #0x%X", imm << sh);
            } else if (!StrCmp(mnem, "movn") && (imm || !sh)) {
                StrCpy(mnem, "mov");
                imm = ~(imm << sh);
                if (!sf)
                    imm &= 0xFFFFFFFF;
                CatPrint(line, ", #0x%X", imm);
            } else {
                CatPrint(line, ", #0x%X", imm);
                if (sh)
                    CatPrint(line, ", lsl #%d", sh);
            }
            break;
        case 300...305:  // sbfm bfm ubfm and their aliases
            immr = DBits(inst, 21, 16);
            imms = DBits(inst, 15, 10);
            if (!StrCmp(mnem, "ubfm")) {
                if (imms == size - 1) {
                    StrCpy(mnem, "lsr");
                    amt = immr;
                    goto bf_shift;
                } else if (imms + 1 == immr) {
                    StrCpy(mnem, "lsl");
                    amt = size - 1 - imms;
                    goto bf_shift;
                } else if (!sf && !immr && (imms == 7 || imms == 15)) {
                    if (imms == 7)
                        StrCpy(mnem, "uxtb");
                    else
                        StrCpy(mnem, "uxth");
                    goto bf_ext;
                } else if (imms < immr) {
                    StrCpy(mnem, "ubfiz");
                    goto bf_iz;
                } else {
                    StrCpy(mnem, "ubfx");
                    goto bf_x;
                }
            } else if (!StrCmp(mnem, "sbfm")) {
                if (imms == size - 1) {
                    StrCpy(mnem, "asr");
                    amt = immr;
                    goto bf_shift;
                } else if (!immr && (imms == 7 || imms == 15 || imms == 31 && sf)) {
                    if (imms == 7)
                        StrCpy(mnem, "sxtb");
                    else if (imms == 15)
                        StrCpy(mnem, "sxth");
                    else
                        StrCpy(mnem, "sxtw");
                    DReg(line, rd, k);
                    DSep(line);
                    DReg(line, rn, 'W');
                    break;
                } else if (imms < immr) {
                    StrCpy(mnem, "sbfiz");
                    goto bf_iz;
                } else {
                    StrCpy(mnem, "sbfx");
                    goto bf_x;
                }
            } else {  // bfm
                if (imms < immr) {
                    StrCpy(mnem, "bfi");
                    goto bf_iz;
                } else {
                    StrCpy(mnem, "bfxil");
                    goto bf_x;
                }
            }
bf_shift:
            DReg(line, rd, k);
            DSep(line);
            DReg(line, rn, k);
            CatPrint(line, ", #%d", amt);
            break;
bf_ext:
            DReg(line, rd, k);
            DSep(line);
            DReg(line, rn, 'W');
            break;
bf_iz:
            DReg(line, rd, k);
            DSep(line);
            DReg(line, rn, k);
            CatPrint(line, ", #%d, #%d", size - immr, imms + 1);
            break;
bf_x:
            DReg(line, rd, k);
            DSep(line);
            DReg(line, rn, k);
            CatPrint(line, ", #%d, #%d", immr, imms - immr + 1);
            break;
        case 307...308:  // extr, ror
            if (rn == rm) {
                StrCpy(mnem, "ror");
                DReg(line, rd, k);
                DSep(line);
                DReg(line, rn, k);
            } else {
                DReg(line, rd, k);
                DSep(line);
                DReg(line, rn, k);
                DSep(line);
                DReg(line, rm, k);
            }
            CatPrint(line, ", #%d", DBits(inst, 15, 10));
            break;
        case 311...335:  // logical and add/sub (shifted register)
            sh = DBits(inst, 23, 22);
            amt = DBits(inst, 15, 10);
            if (rn == 31 && !sh && !amt && !StrCmp(mnem, "orr")) {
                StrCpy(mnem, "mov");
                DReg(line, rd, k);
                DSep(line);
                DReg(line, rm, k);
                break;
            }
            if (rn == 31 && !StrCmp(mnem, "orn")) {
                StrCpy(mnem, "mvn");
                DReg(line, rd, k);
            } else if (rn == 31 && (!StrCmp(mnem, "sub") || !StrCmp(mnem, "subs"))) {
                if (mnem[3])
                    StrCpy(mnem, "negs");
                else
                    StrCpy(mnem, "neg");
                DReg(line, rd, k);
            } else if (rd == 31 && (!StrCmp(mnem, "subs") || !StrCmp(mnem, "adds") || !StrCmp(mnem, "ands"))) {
                if (mnem[0] == 's')
                    StrCpy(mnem, "cmp");
                else if (mnem[1] == 'd')
                    StrCpy(mnem, "cmn");
                else
                    StrCpy(mnem, "tst");
                DReg(line, rn, k);
            } else {
                DReg(line, rd, k);
                DSep(line);
                DReg(line, rn, k);
            }
            DSep(line);
            DReg(line, rm, k);
            if (sh || amt) {
                CatPrint(line, ", %s #%d", ArmShmod2Str(sh), amt);
                StrUtil(line, SUF_TO_LOWER);
            }
            break;
        case 337...344:  // add/sub (extended register)
            opt = DBits(inst, 15, 13);
            amt = DBits(inst, 12, 10);
            if (StrMatch("s", mnem + 3) && rd == 31) {
                if (mnem[0] == 'a')
                    StrCpy(mnem, "cmn");
                else
                    StrCpy(mnem, "cmp");
                DReg(line, rn, k, TRUE);
            } else {
                DReg(line, rd, k, !mnem[3]);
                DSep(line);
                DReg(line, rn, k, TRUE);
            }
            DSep(line);
            if (sf && opt & 3 == 3)  // uxtx/sxtx: an X register (in 64-bit ops)
                DReg(line, rm, 'X');
            else
                DReg(line, rm, 'W');
            if ((rd == 31 || rn == 31) && opt == 2 + sf) {
                if (amt)
                    CatPrint(line, ", lsl #%d", amt);
            } else {
                CatPrint(line, ", %s", ArmOption2Str(opt));
                StrUtil(line, SUF_TO_LOWER);
                if (amt)
                    CatPrint(line, " #%d", amt);
            }
            break;
        case 346...353:  // adc sbc
            if (rn == 31 && mnem[0] == 's') {
                if (mnem[3])
                    StrCpy(mnem, "ngcs");
                else
                    StrCpy(mnem, "ngc");
            } else {
                DReg(line, rd, k);
                DSep(line);
                DReg(line, rn, k);
                DSep(line);
                DReg(line, rm, k);
                break;
            }
            DReg(line, rd, k);
            DSep(line);
            DReg(line, rm, k);
            break;
        case 355...363:  // ccmn ccmp
            DReg(line, rn, k);
            if (opc->num >= 360)
                CatPrint(line, ", #%d", rm);
            else {
                DSep(line);
                DReg(line, rm, k);
            }
            CatPrint(line, ", #0x%X, ", inst & 15);
            DCond(line, DBits(inst, 15, 12));
            break;
        case 365...372:  // csel csinc csinv csneg
            cond = DBits(inst, 15, 12);
            if (cond < 14 && rn == rm && mnem[2] != 'e') {  // (not csel)
                if (rn == 31 && StrCmp(mnem, "csneg")) {
                    if (!StrCmp(mnem, "csinc"))
                        StrCpy(mnem, "cset");
                    else
                        StrCpy(mnem, "csetm");
                    DReg(line, rd, k);
                } else {
                    if (!StrCmp(mnem, "csinc"))
                        StrCpy(mnem, "cinc");
                    else if (!StrCmp(mnem, "csinv"))
                        StrCpy(mnem, "cinv");
                    else
                        StrCpy(mnem, "cneg");
                    DReg(line, rd, k);
                    DSep(line);
                    DReg(line, rn, k);
                }
                DSep(line);
                DCond(line, DInvCond(cond));
                break;
            }
            DReg(line, rd, k);
            DSep(line);
            DReg(line, rn, k);
            DSep(line);
            DReg(line, rm, k);
            DSep(line);
            DCond(line, cond);
            break;
        case 374...383:  // madd msub smaddl umaddl smsubl umsubl smulh umulh
            if (opc->num >= 382) {  // smulh umulh
                DReg(line, rd, 'X');
                DSep(line);
                DReg(line, rn, 'X');
                DSep(line);
                DReg(line, rm, 'X');
                break;
            }
            sk = k;
            dk = k;
            if (StrMatch("l", mnem + 4)) {  // long: W sources, X result
                sk = 'W';
                dk = 'X';
            }
            if (ra == 31) {
                if (!StrCmp(mnem, "madd"))
                    StrCpy(mnem, "mul");
                else if (!StrCmp(mnem, "msub"))
                    StrCpy(mnem, "mneg");
                else if (!StrCmp(mnem, "smaddl"))
                    StrCpy(mnem, "smull");
                else if (!StrCmp(mnem, "umaddl"))
                    StrCpy(mnem, "umull");
                else if (!StrCmp(mnem, "smsubl"))
                    StrCpy(mnem, "smnegl");
                else
                    StrCpy(mnem, "umnegl");
            }
            DReg(line, rd, dk);
            DSep(line);
            DReg(line, rn, sk);
            DSep(line);
            DReg(line, rm, sk);
            if (ra != 31) {
                DSep(line);
                DReg(line, ra, dk);
            }
            break;
        case 385...404:  // crc32, udiv sdiv, lslv lsrv asrv rorv
            if (397 <= opc->num) {
                mnem[3] = 0;  // lslv -> lsl, ...
            }
            if (opc->num <= 392) {
                DReg(line, rd, 'W');
                DSep(line);
                DReg(line, rn, 'W');
                DSep(line);
                if (mnem[StrLen(mnem) - 1] == 'x')
                    DReg(line, rm, 'X');
                else
                    DReg(line, rm, 'W');
                break;
            }
            DReg(line, rd, k);
            DSep(line);
            DReg(line, rn, k);
            DSep(line);
            DReg(line, rm, k);
            break;
        case 406...416:  // rbit clz cls rev rev16 rev32
            if (opc->num == 416)
                k = 'X';
            DReg(line, rd, k);
            DSep(line);
            DReg(line, rn, k);
            break;
        default:
            if (opc->num >= 419) {  // floating point and SIMD scalar
                k = 'D';
                if (StrMatch("Single", opc->flags) || StrMatch("single", opc->flags))
                    k = 'S';
                if (DConvKinds(opc, &dk, &sk)) {
                    if (556 <= opc->num <= 557) {  // fmov to/from the top half
                        if (opc->num == 556)
                            CatPrint(line, "x%d, v%d.d[1]", rd, rn);
                        else
                            CatPrint(line, "v%d.d[1], x%d", rd, rn);
                        break;
                    }
                    DReg(line, rd, dk);
                    DSep(line);
                    DReg(line, rn, sk);
                    if (opc->num <= 434)  // fixed point: fraction bits
                        CatPrint(line, ", #%d", 64 - DBits(inst, 15, 10));
                    break;
                }
                switch (opc->num) {
                    case 436...439:  // fccmp
                        DReg(line, rn, k);
                        DSep(line);
                        DReg(line, rm, k);
                        CatPrint(line, ", #0x%X, ", inst & 15);
                        DCond(line, DBits(inst, 15, 12));
                        break;
                    case 441...458:  // fmul fdiv fadd fsub fmax fmin ... fnmul
                    case 568...603:
                        DReg(line, rd, k);
                        DSep(line);
                        DReg(line, rn, k);
                        DSep(line);
                        DReg(line, rm, k);
                        break;
                    case 460...461:  // fcsel
                        DReg(line, rd, k);
                        DSep(line);
                        DReg(line, rn, k);
                        DSep(line);
                        DReg(line, rm, k);
                        DSep(line);
                        DCond(line, DBits(inst, 15, 12));
                        break;
                    case 463...464:  // fmov (immediate): imm8 = a:b:c:d:e:f:g:h
                        imm = DBits(inst, 20, 13);
                        DReg(line, rd, k);
                        CatPrint(line, ", #0x%02X", imm);
                        break;
                    case 466...473:  // fcmp fcmpe
                        DReg(line, rn, k);
                        if (StrMatch("zero", opc->flags))
                            CatPrint(line, ", #0.0");
                        else {
                            DSep(line);
                            DReg(line, rm, k);
                        }
                        break;
                    case 559...566:  // fmadd fmsub fnmadd fnmsub
                        DReg(line, rd, k);
                        DSep(line);
                        DReg(line, rn, k);
                        DSep(line);
                        DReg(line, rm, k);
                        DSep(line);
                        DReg(line, ra, k);
                        break;
                    default:  // one source: fmov fabs fneg fsqrt frint* ...
                        DReg(line, rd, k);
                        DSep(line);
                        DReg(line, rn, k);
                }
            } else
                CatPrint(line, "0x%08X", inst);
    }
    DocPrint(doc, "%P\t%-7s %s\n", ptr, mnem, line);
    return ptr + 1;
}
