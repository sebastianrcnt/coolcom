// Translated from Aiwnios arm_backend.c lines 1-2529 (nrootconauto, BSD-3), commit e155e87.
//INTEGRATION: needs BackendA.HH; ArmBackendB.HC holds the rest of arm_backend.c.
//PORT-NOTE: the ARM_REG_X*/ARM_REG_V* enums (arm_backend.c lines 382-461) live in BackendA.HH.
//PORT-NOTE: the C macro AIWNIOS_ADD_CODE(val) is the function AIWNIOS_ADD_CODE(bin, code_off, val)
//  returning the new code_off: every use is `code_off = AIWNIOS_ADD_CODE(bin, code_off, val);`.
//PORT-NOTE: the C copy of IsConst in this file is identical to optpass.c's BIsConst (OptPass.HC) and is not repeated.
//PORT-NOTE: class assignment in the stage-0 compiler does not copy whole classes, so every CICArg
//  struct copy is a MemCpy and every `CICArg x = {0}` is a declaration followed by MemSet.
//PORT-NOTE: HolyC has no `continue`/ternary/function-like macros; see the individual functions.

//PORT-NOTE: the C forward declarations of SpillsTmpRegs/ICMov/PutICArgIntoReg/__OptPassFinal are in BackendA.HH
//  (a bare prototype without `extern` would define an empty function in HolyC).
//
// ASSci art
// POOPING README
//     _^_
//    {   }        ______
//   {     }      /      \
//  {(o) (o)} <==( README )
// { \_____/ }    \______/
// \_________/
//
// In parser.c I defined some backend_user_dataX varaibles
// **backend_user_data0** is the maximum extra stack wiggle room^ that is
// used for random poop the program may need(if we run out of tmp regs)
//
// **backend_user_data1** is the current wiggle room^ size
// **backend_user_data2** is the current tmp int reg(overflow goes to stack)
// **backend_user_data3** is the current tmp float reg(overflow goes to stack)
// **backend_user_data4** is wiggle room start
// **backend_user_data5** is the "fail" codemisc for BIC_LT/GT etc
// **backend_user_data6** is the "pass" codemisc for BIC_LT/GT etc
// Stack layout
//  old X29
//  old X30
//  Pushed saved registers
//  Wiggle room
//  locals
//

//
// [^]Wiggle room means room on the stack that is reserved
//

//
// December 5,2022 I need to make a base class set the raw_type
// December 9,2022 I thought about Tucker Carlson while walking to get tea
// Decemeber 16,2022 Im stuck at home because of a snow storm
// Decemeber 23,2022,i got 3 monster energy drinks
//

I64 MIR(CBCmpCtrl *cc, I64 r) {
  CBRPN *rpn = cc->cur_rpn;
  if (!rpn)
    return r;
  rpn->changes_iregs |= 1 << r;
  return r;
}
I64 MFR(CBCmpCtrl *cc, I64 r) {
  CBRPN *rpn = cc->cur_rpn;
  if (!rpn)
    return r;
  rpn->changes_fregs |= 1 << r;
  return r;
}

I64 CanKeepInTmp(CBRPN *me, CBRPN *have, CBRPN *other,
                 I64 is_left_side) {
  I64 mask;
  if (have->res.mode != MD_REG)
    return 0; // No need to stuff in tmp
  // Fail safe
  if (other)
    if (SpillsTmpRegs(other))
      return 0;
  if (is_left_side) {
    if (other)
      mask = other->changes_iregs2 | me->changes_iregs;
    else
      mask = me->changes_iregs;
  } else {
    mask = me->changes_iregs;
  }
  mask |= ((1 << BAIWNIOS_TMP_IREG_CNT) - 1) << BAIWNIOS_TMP_IREG_START;
  // Function return values are safe
  if (other)
    if (other->type == BIC_CALL || other->type == __IC_CALL)
      goto skip;
  mask |= 1 << 0; // Accumulator is used for everything
skip:;
  if (have->tmp_res.mode == MD_REG && have->tmp_res.raw_type != BRT_F64)
    if (mask & (1 << have->tmp_res.reg))
      return 0;

  if (is_left_side) {
    if (other)
      mask = other->changes_fregs2 | me->changes_fregs;
    else
      mask = me->changes_fregs;
  } else {
    mask = me->changes_fregs;
  }

  mask |= ((1 << BAIWNIOS_TMP_FREG_CNT) - 1) << BAIWNIOS_TMP_FREG_START;
  // Function return values are safe
  if (other)
    if (other->type == BIC_CALL || other->type == __IC_CALL)
      goto skip2;
  mask |= 1 << 0; // Accumulator is used for everything
skip2:;
  if (have->tmp_res.mode == MD_REG && have->tmp_res.raw_type == BRT_F64)
    if (mask & (1 << have->tmp_res.reg))
      return 0;

  return 1;
}

//
// Sets keep_in_tmp
//
U0 SetKeepTmps(CBRPN *rpn) {
  I64 idx;
  CBRPN *left, *right;
  switch (rpn->type) {
    case BIC_FS:
    case BIC_GS:
      if (rpn->tmp_res.mode)
        rpn->res.keep_in_tmp = 1;
      return;
    case BIC_RET:
    case BIC_GOTO_IF:
      goto unop;
    case __IC_CALL:
    case BIC_CALL:
      break;
    case __IC_VARGS:
      for (idx = 0; idx != rpn->length; idx++) {
        right = ICArgN(rpn, idx);
        if (right->tmp_res.mode) {
          MemCpy(&right->res, &right->tmp_res, sizeof(CBICArg));
          right->res.keep_in_tmp = 1;
        }
      }
      return;
    case BIC_TO_F64:
    case BIC_TO_I64:
    case BIC_NEG:
    case BIC_TO_BOOL:
unop:
      right = ICArgN(rpn, 0);
      MemCpy(&right->res, &right->tmp_res, sizeof(CBICArg));
      if (right->tmp_res.mode)
        right->res.keep_in_tmp = 1;
      break;
    case BIC_SQR:
    case BIC_POS:
      goto unop;
      break;
    case BIC_POW:
binop:
      left = ICArgN(rpn, 1);
      right = ICArgN(rpn, 0);
      // In AArch64,I do left last,safe to  do stuff with it as ICArgN(rpn,0) wont
      // mutate regs
      if (CanKeepInTmp(rpn, left, right, 1) && left->tmp_res.mode) {
        if (left->tmp_res.mode == MD_REG) {
          MemCpy(&left->res, &left->tmp_res, sizeof(CBICArg));
          left->res.keep_in_tmp = 1;
          break;
        }
      }
      break;
    case BIC_ADD:
      goto binop;
      break;
    case BIC_EQ:
      goto abinop;
      break;
    case BIC_SUB:
      goto binop;
      break;
    case BIC_DIV:
      goto binop;
      break;
    case BIC_MUL:
      goto binop;
      break;
    case BIC_DEREF:
      goto unop;
      break;
    case BIC_AND:
      goto binop;
      break;
    case BIC_ADDR_OF:
      goto unop;
      break;
    case BIC_XOR:
      goto binop;
      break;
    case BIC_MOD:
      // composuite operation
      break;
    case BIC_OR:
      goto binop;
      break;
    case BIC_LT:
      goto binop;
      break;
    case BIC_GT:
      goto binop;
      break;
    case BIC_LNOT:
      goto unop;
      break;
    case BIC_BNOT:
      goto unop;
      break;
    case BIC_POST_INC:
      // Need a temporary to store result so no
      break;
    case BIC_POST_DEC:
      // Need a temporary to store result so no
      break;
    case BIC_PRE_INC:
      break;
    case BIC_PRE_DEC:
      break;
    case BIC_AND_AND:
      goto binop;
    case BIC_OR_OR:
      goto binop;
      break;
    case BIC_XOR_XOR:
      goto binop;
      break;
    case BIC_EQ_EQ:
      goto binop;
      break;
    case BIC_NE:
      goto binop;
      break;
    case BIC_LE:
      goto binop;
      break;
    case BIC_GE:
      goto binop;
      break;
    case BIC_LSH:
      goto binop;
      break;
    case BIC_RSH:
      goto binop;
      break;
    case BIC_ADD_EQ:
      goto abinop;
      break;
    case BIC_SUB_EQ:
      goto abinop;
      break;
    case BIC_MUL_EQ:
      goto abinop;
      break;
    case BIC_DIV_EQ:
      goto abinop;
      break;
    case BIC_LSH_EQ:
      goto abinop;
      break;
    case BIC_RSH_EQ:
      goto abinop;
      break;
    case BIC_AND_EQ:
      goto abinop;
      break;
    case BIC_OR_EQ:
      goto abinop;
      break;
    case BIC_XOR_EQ:
      goto abinop;
      break;
abinop:
      left = ICArgN(rpn, 1);
      right = ICArgN(rpn, 0);
      left->res.keep_in_tmp = 0;
      right->res.keep_in_tmp = 0;
      right->tmp_res.mode = 0; // Default to unused
      left->tmp_res.mode = 0;
      /* DUMB hack
     *  assigning into a BIC_DEREF bypasses the deref(uses deref->next)
     *  MAKE SURE deref->next is not a temporarry
     */
      if (left->type == BIC_DEREF) {
        CBRPN *arg = left->base.next(CBRPN *);
        arg->res.keep_in_tmp = 0;
        arg->tmp_res.mode = 0;
      }
      if (left->type == BIC_IREG || left->type == BIC_FREG ||
          left->type == BIC_BASE_PTR) {
        // Only act on accumulator for now in "safe" spots.
        if (right->tmp_res.mode == MD_REG && right->tmp_res.reg == 0) {
          MemCpy(&right->res, &right->tmp_res, sizeof(CBICArg));
          right->res.keep_in_tmp = 1;
        }
      }
      break;
    case BIC_BT:
    case BIC_BTS:
    case BIC_BTR:
    case BIC_BTC:
    case BIC_LBTS:
    case BIC_LBTR:
    case BIC_LBTC:
    case BIC_STORE:
      goto binop;
    case BIC_TYPECAST:
      goto unop;
  }
  return;
t:
  return;
}

I64 IsBranchableInst(CBRPN *rpn) {
  switch (rpn->type) {
    case BIC_OR_OR:
    case BIC_AND_AND:
    case BIC_LT:
    case BIC_GT:
    case BIC_GE:
    case BIC_LE:
    case BIC_EQ_EQ:
    case BIC_NE:
    case BIC_LNOT:
    case BIC_BT:
    case BIC_BTS:
    case BIC_BTR:
    case BIC_BTC:
    case BIC_LBTS:
    case BIC_LBTR:
    case BIC_LBTC:
      return 1;
  }
  return 0;
}

I64 IsTerminalInst(CBRPN *r) {
  switch (r->type) {
    case BIC_RET:
    case BIC_GOTO:
      return 1;
  }
  return 0;
}

I64 ConstVal(CBRPN *rpn) {
  switch (rpn->type) {
    case BIC_CHR:
    case BIC_I64:
      return rpn->integer;
    case BIC_F64:
      return rpn->flt;
  }
  return 0;
}

I64 AIWNIOS_ADD_CODE(U8 *bin, I64 code_off, I64 val) {
  I64 v2 = val;
  if (bin) {
    if (v2 == ARM_ERR_INV_REG || v2 == ARM_ERR_INV_OFF) {  // PORT-NOTE: diagnostic only
      Print("AIWNIOS_ADD_CODE: encoder error %d at code_off %X\n", v2, code_off);
      throw('ASM');
    }
    ((bin)(I32 *))[code_off / 4] = v2;
  }
  return code_off + 4;
}

I64 PushToStack(CBCmpCtrl *cctrl, CBICArg *arg, U8 *bin,
                I64 code_off) {
  CBICArg tmp;
  MemCpy(&tmp, arg, sizeof(CBICArg));
  code_off = PutICArgIntoReg(cctrl, &tmp, tmp.raw_type, 0, bin, code_off);
  if (tmp.raw_type != BRT_F64) {
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_strPreImmX(tmp.reg, ARM_REG_SP, -16));
  } else {
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_strPreImmF64(tmp.reg, ARM_REG_SP, -16));
  }
  return code_off;
}
I64 PopFromStack(CBCmpCtrl *cctrl, CBICArg *arg, U8 *bin,
                 I64 code_off) {
  CBICArg tmp;
  MemCpy(&tmp, arg, sizeof(CBICArg));
  if (arg->mode == MD_REG) {
    // All is good
  } else {
    tmp.mode = MD_REG;
    tmp.reg = 0;
  }
  if (tmp.raw_type != BRT_F64) {
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrPostImmX(MIR(cctrl, tmp.reg), ARM_REG_SP, 16));
  } else {
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrPostImmF64(MFR(cctrl, tmp.reg), ARM_REG_SP, 16));
  }
  if (arg->mode != MD_REG)
    code_off = ICMov(cctrl, arg, &tmp, bin, code_off);
  return code_off;
}
//
// Will overwrite the arg's value,but it's ok as we are about to use it's
// value(and discard it)
//
I64 PutICArgIntoReg(CBCmpCtrl *cctrl, CBICArg *arg, I64 raw_type,
                    I64 fallback, U8 *bin, I64 code_off) {
  CBICArg tmp;
  MemSet(&tmp, 0, sizeof(CBICArg));
  if (arg->mode == MD_REG) {
    if ((raw_type == BRT_F64) ^ (arg->raw_type == BRT_F64)) {
      // They differ so continue as usaul
    } else // They are the same
      return code_off;
  }
  tmp.raw_type = raw_type;
  tmp.reg = fallback;
  tmp.mode = MD_REG;
  code_off = ICMov(cctrl, &tmp, arg, bin, code_off);
  MemCpy(arg, &tmp, sizeof(CBICArg));
  return code_off;
}

//PORT-NOTE: `reg` is a keyword in HolyC, so the parameter `reg` of __ICMoveI64/__ICMoveF64 is named `dst_reg`.
I64 __ICMoveI64(CBCmpCtrl *cctrl, I64 dst_reg, U64 imm,
                U8 *bin, I64 code_off) {
  I64 code, which;
  I64 z;
  if (bin && !(cctrl->flags & BCCF_AOT_COMPILE) && 0) { // TODO make sure not AOT
    if (ARM_ERR_INV_OFF !=
        (code = ARM_adrX(dst_reg, imm - (bin + code_off)(I64)))) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off, code);
      return code_off;
    }
  }
  z = 1;
  for (which = 0; which != 4; which++) {
    if ((imm >> (which * 16)) & 0xffff) {
      if (z) {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_movzImmX(
            MIR(cctrl, dst_reg), 0xffff & (imm >> (which * 16)), which * 16));
        z = 0;
      } else {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_movkImmX(
            MIR(cctrl, dst_reg), 0xffff & (imm >> (which * 16)), which * 16));
      }
    }
  }
  if (z) {
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_movzImmX(MIR(cctrl, dst_reg), 0, 0));
  }
  return code_off;
}

// FIX(1): A negative displacement can exceed the encoder's immediate range.
// Split the adjustment into encodable parts without clobbering a store source.
I64 BAdjustNegOffset(CBCmpCtrl *cctrl, I64 base, I64 amount, Bool subtract,
                     U8 *bin, I64 code_off) {
  I64 part, sh;
  while (amount) {
    if (amount >= 4096) {
      part = amount >> 12;
      if (part > 2047)
        part = 2047;
      sh = 1;
      amount -= part << 12;
    } else {
      part = amount;
      if (part > 2047)
        part = 2047;
      sh = 0;
      amount -= part;
    }
    code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                BAddSubImmX(subtract, 0, MIR(cctrl, base), base, part, sh));
  }
  return code_off;
}

I64 __ICMoveF64(CBCmpCtrl *cctrl, I64 dst_reg, F64 imm, U8 *bin,
                I64 code_off) {
  //(For now),I ain't messing around with binary literals in ARM
  CBCodeMisc *misc = cctrl->code_ctrl->code_misc->next(CBCodeMisc *);
  CBCodeMiscRef *ref;
  U8 *dptr;
  for (; misc != cctrl->code_ctrl->code_misc; misc = misc->base.next(CBCodeMisc *)) {
    if (misc->type == BCMT_FLOAT_CONST)
      if (misc->integer == *(&imm)(I64 *)) {
        goto found;
      }
  }
  misc = CAlloc(sizeof(CBCodeMisc));
  misc->type = BCMT_FLOAT_CONST;
  misc->integer = *(&imm)(I64 *);
  BQueIns(misc, cctrl->code_ctrl->code_misc->last);
found:
  MFR(cctrl, dst_reg);
  if (bin && misc->addr && cctrl->code_ctrl->final_pass) {
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrLabelF64(MFR(cctrl, dst_reg), 0));
    ref = CodeMiscAddRef(misc, bin + code_off - 4);
    ref->patch_cond_br = &ARM_ldrLabelF64;
    ref->user_data1 = dst_reg;
  } else
    code_off = AIWNIOS_ADD_CODE(bin, code_off, 0); // See above AIWNIOS_ADD_CODE
  return code_off;
}

#define ARM_LABEL_DIST (((1 << 19) - 1) << 2)
I64 PtrDist(I64 a, I64 b) {
  if (a > b)
    return a - b;
  return b - a;
}
U0 PushSpilledTmp(CBCmpCtrl *cctrl, CBRPN *rpn) {
  I64 raw_type = rpn->raw_type;
  CBICArg *res = &rpn->res;
  // These have no need to be put into a temporay
  if (res->keep_in_tmp) {
    MemCpy(&rpn->res, &rpn->tmp_res, sizeof(CBICArg));
    rpn->flags |= ICF_TMP_NO_UNDO;
    return;
  }
  switch (rpn->type) {
    case BIC_IREG:
    case BIC_FREG:
      res->mode = MD_REG;
      res->raw_type = raw_type;
      res->reg = rpn->integer;
      return;
      break;
    case BIC_BASE_PTR:
      res->mode = MD_FRAME;
      res->raw_type = raw_type;
      res->off = rpn->integer;
      return;
    case BIC_STATIC:
      res->mode = MD_PTR;
      res->raw_type = raw_type;
      res->off = rpn->integer;
      return;
    case __IC_STATIC_REF:
      res->mode = MD_STATIC;
      res->raw_type = raw_type;
      res->off = rpn->integer;
      return;
    case BIC_GLOBAL:
      res->mode = MD_PTR;
      res->raw_type = raw_type;
      res->off = rpn->global_var->data_addr;
      return;
      // These dudes will compile down to a MD_I64/MD_F64
    case BIC_I64:
      res->mode = MD_I64;
      res->integer = rpn->integer;
      res->raw_type = BRT_I64i;
      return;
      break;
    case BIC_F64:
      res->mode = MD_F64;
      res->flt = rpn->flt;
      res->raw_type = BRT_F64;
      return;
  }
  rpn->flags |= ICF_SPILLED;
  if (raw_type != BRT_F64) {
    res->mode = MD_FRAME;
    res->raw_type = raw_type;
    if (cctrl->backend_user_data0 <
        (res->off = (cctrl->backend_user_data1 +=
                     8))) { // Will set ref->off before the top
      cctrl->backend_user_data0 = res->off;
    }
  } else {
    res->mode = MD_FRAME;
    res->raw_type = raw_type;
    if (cctrl->backend_user_data0 <
        (res->off = (cctrl->backend_user_data1 +=
                     8))) { // Will set ref->off before the top
      cctrl->backend_user_data0 = res->off;
    }
  }
  // See two above notes
  res->off -= 8;
  // In functions,wiggle room comes after the function locals.
  if (cctrl->cur_fun && res->mode == MD_FRAME)
    res->off += cctrl->cur_fun->base.sz + 16; //+16 for LR/FP
  else if (res->mode == MD_FRAME) {
    if (cctrl->backend_user_data4) {
      res->off += cctrl->backend_user_data4; // wiggle room start(if set)
    } else
      // Anonymus potatoes like to assume LR/FP pair too.
      res->off += 16;
  }
}
//
// Takes an argument called inher. We can use the parent's destination
// as a temporary. I'll give an example
//
// DO: -~!a;
// - dst=0
//  ~ dst=0
//   ! dst=0
//
// DON'T: -~!a
// - dst=0
//  ~ dst=1
//   ! dst=2

U0 PushTmp(CBCmpCtrl *cctrl, CBRPN *rpn) {
  I64 raw_type = rpn->raw_type;
  CBICArg *res = &rpn->res;
  if (res->keep_in_tmp) {
    MemCpy(&rpn->res, &rpn->tmp_res, sizeof(CBICArg));
    rpn->flags |= ICF_TMP_NO_UNDO;
    return;
  }
  // These have no need to be put into a temporay
  switch (rpn->type) {
    case __IC_STATIC_REF:
      res->mode = MD_STATIC;
      res->raw_type = raw_type;
      res->off = rpn->integer;
      return;
    case BIC_STATIC:
      res->mode = MD_PTR;
      res->raw_type = raw_type;
      res->off = rpn->integer;
      return;
    case BIC_GLOBAL:
      res->mode = MD_PTR;
      res->raw_type = raw_type;
      res->off = rpn->global_var->data_addr;
      return;
      // These dudes will compile down to a MD_I64/MD_F64
    case BIC_I64:
      res->mode = MD_I64;
      res->integer = rpn->integer;
      res->raw_type = BRT_I64i;
      return;
      break;
    case BIC_F64:
      res->mode = MD_F64;
      res->flt = rpn->flt;
      res->raw_type = BRT_F64;
      return;
    case BIC_IREG:
    case BIC_FREG:
      res->mode = MD_REG;
      res->raw_type = raw_type;
      res->reg = rpn->integer;
      return;
      break;
    case BIC_BASE_PTR:
      res->mode = MD_FRAME;
      res->raw_type = raw_type;
      res->off = rpn->integer;
      return;
  }
normal:
  if (raw_type != BRT_F64) {
    if (cctrl->backend_user_data2 < BAIWNIOS_TMP_IREG_CNT) {
      res->mode = MD_REG;
      res->raw_type = raw_type;
      res->off = 0;
      res->reg = BAIWNIOS_TMP_IREG_START + cctrl->backend_user_data2++;
      BAssert(res->reg > 0, "res->reg > 0");
    } else {
      PushSpilledTmp(cctrl, rpn);
    }
  } else {
    if (cctrl->backend_user_data3 < BAIWNIOS_TMP_FREG_CNT) {
      res->mode = MD_REG;
      res->raw_type = raw_type;
      res->off = 0;
      res->reg = BAIWNIOS_TMP_FREG_START + cctrl->backend_user_data3++;
    } else {
      PushSpilledTmp(cctrl, rpn);
    }
  }
}

U0 PopTmp(CBCmpCtrl *cctrl, CBRPN *rpn) {
  I64 raw_type = rpn->raw_type;
  if (rpn->flags & ICF_TMP_NO_UNDO)
    return;
  if (rpn->flags & ICF_SIB) {
    if (rpn->res.__sib_idx_rpn)
      cctrl->backend_user_data2--;
    if (rpn->res.__sib_base_rpn)
      cctrl->backend_user_data2--;
    return;
  }
  // These have no need to be put into a temporay
  switch (rpn->type) {
    case BIC_I64:
    case BIC_F64:
    case BIC_IREG:
    case BIC_FREG:
    case BIC_BASE_PTR:
    case BIC_GLOBAL:
    case BIC_STATIC:
    case __IC_STATIC_REF:
      return;
  }
  if (rpn->flags & ICF_SPILLED) {
    cctrl->backend_user_data1 -= 8;
  } else {
    if (raw_type != BRT_F64) {
      --cctrl->backend_user_data2;
      BAssert(cctrl->backend_user_data2 >= 0, "cctrl->backend_user_data2 >= 0");
    } else {
      --cctrl->backend_user_data3;
      BAssert(cctrl->backend_user_data3 >= 0, "cctrl->backend_user_data3 >= 0");
    }
  }
  BAssert(cctrl->backend_user_data1 >= 0, "cctrl->backend_user_data1 >= 0");
}
//
// Here's the deal,we can replace an *(reg+123) with MD_INDIR_REG with
// off==123
//
I64 DerefToICArg(CBCmpCtrl *cctrl, CBICArg *res, CBRPN *rpn,
                 I64 base_reg_fallback, U8 *bin,
                 I64 code_off) {
  if (rpn->type != BIC_DEREF) {
    code_off = __OptPassFinal(cctrl, rpn, bin, code_off);
    MemCpy(res, &rpn->res, sizeof(CBICArg));
    return code_off;
  }
  I64 r = rpn->raw_type, rsz, off, mul;
  switch (r) {
    case BRT_I8i:
      rsz = 1;
      break;
    case BRT_U8i:
      rsz = 1;
      break;
    case BRT_I16i:
      rsz = 2;
      break;
    case BRT_U16i:
      rsz = 2;
      break;
    case BRT_I32i:
      rsz = 4;
      break;
    case BRT_U32i:
      rsz = 4;
      break;
    default:
      rsz = 8;
  }
  if (rpn->flags & ICF_SIB) {
    CBRPN *b = rpn->res.__sib_base_rpn, *i = rpn->res.__sib_idx_rpn;
    if (b)
      code_off = __OptPassFinal(cctrl, b, bin, code_off);
    if (i)
      code_off = __OptPassFinal(cctrl, i, bin, code_off);
    if (b && i) {
      code_off = PutICArgIntoReg(cctrl, &b->res, BRT_I64i, b->res.fallback_reg,
                                 bin, code_off);
      code_off = PutICArgIntoReg(cctrl, &i->res, BRT_I64i, i->res.fallback_reg,
                                 bin, code_off);
      rpn->res.reg = b->res.reg;
      rpn->res.reg2 = i->res.reg;
    } else if (b) {
      code_off = PutICArgIntoReg(cctrl, &b->res, BRT_I64i, b->res.fallback_reg,
                                 bin, code_off);
      rpn->res.reg = b->res.reg;
    }
    MemCpy(res, &rpn->res, sizeof(CBICArg));
    return code_off;
  }
  rpn = rpn->base.next(CBRPN *);
  code_off = __OptPassFinal(cctrl, rpn, bin, code_off);
  code_off = PutICArgIntoReg(cctrl, &rpn->res, BRT_PTR, base_reg_fallback, bin,
                             code_off);
fallback:;
  res->mode = MD_INDIR_REG;
  res->off = 0;
  res->raw_type = r;
  res->reg = rpn->res.reg;
  return code_off;
}
// Arguments are called backwards
//PORT-NOTE: `reg` is a HolyC keyword: the parameter is named arg_reg.
I64 ArgRPNMutatesArgumentRegister(CBRPN *rpn, I64 arg_reg,
                                  I64 is_freg) {
  I64 i = rpn->length - arg_reg - 1;
  CBRPN *arg;
  if (SpillsTmpRegs(arg = ICArgN(rpn, rpn->length)))
    return 1;
  if (is_freg) {
    if ((arg->changes_fregs | arg->changes_fregs2) & (1 << arg_reg))
      return 1;
  } else {
    if ((arg->changes_iregs | arg->changes_iregs2) & (1 << arg_reg))
      return 1;
  }
  while (++i < rpn->length) {
    if (SpillsTmpRegs(arg = ICArgN(rpn, i)))
      return 1;

    // In Aiwnios RISC-V ABI,I pass all arguments in int registers
    if (is_freg) {
      if ((arg->changes_fregs | arg->changes_fregs2) & (1 << arg_reg))
        return 1;
    } else {
      if ((arg->changes_iregs | arg->changes_iregs2) & (1 << arg_reg))
        return 1;
    }
  }
  return 0;
}
// Here's Nroots deal. Things that wont change"BIC_IREG,BIC_FREG,BIC_IMM_X64" will
// be passed later. Other arguments will be passed to a temporary area on the
// stack 21.,this makes passing "spilled" arguments easier
//PORT-NOTE: WONT_CHANGE and BEFORE_CALL were function-local C macros; they are
//  functions here (BEFORE_CALL gets rpn/tmp/tmp2 as arguments and returns code_off).
I64 WONT_CHANGE(I64 t) {
  return (t == BIC_IREG || t == BIC_FREG || t == BIC_I64 || t == BIC_F64 ||
          t == BIC_BASE_PTR);
}
I64 BEFORE_CALL(CBCmpCtrl *cctrl, CBRPN *rpn, CBICArg *tmp, CBICArg *tmp2,
                U8 *bin, I64 code_off) {
  CBRPN *rpn2;
  I64 i;
  for (i = ((rpn->length > 8) * 8 + (rpn->length <= 8) * rpn->length) - 1; i >= 0; i--) {
    rpn2 = ICArgN(rpn, rpn->length - i - 1); /* REVBERSE polish notation */
    tmp->mode = MD_REG;
    tmp->raw_type = rpn2->res.raw_type;
    tmp->reg = i;
    if (WONT_CHANGE(rpn2->type)) {
      switch (rpn2->type) {
        case BIC_IREG:
        case BIC_FREG:
          tmp2->mode = MD_REG;
          tmp2->raw_type = rpn2->res.raw_type;
          tmp2->reg = rpn2->integer;
          break;
        case BIC_I64:
          tmp2->mode = MD_I64;
          tmp2->raw_type = BRT_I64i;
          tmp2->integer = rpn2->integer;
          break;
        case BIC_BASE_PTR:
          tmp2->mode = MD_FRAME;
          tmp2->mode = MD_FRAME;
          tmp2->off = rpn2->integer;
          tmp2->raw_type = tmp->raw_type;
          break;
        case BIC_F64:
          tmp2->mode = MD_F64;
          tmp2->raw_type = BRT_F64;
          tmp2->flt = rpn2->flt;
          break;
      }
      code_off = ICMov(cctrl, tmp, tmp2, bin, code_off);
    } else {
      code_off = ICMov(cctrl, tmp, &rpn2->res, bin,
                       code_off); /* In PushSpilledTmp I spilled them*/
    }
    if (tmp->raw_type == BRT_F64) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovI64F64(i, i));
    }
  }
  return code_off;
}
I64 __ICFCallTOS(CBCmpCtrl *cctrl, CBRPN *rpn, U8 *bin,
                 I64 code_off) {
  I64 i, first_is_vargs = 0, base; // This is reverse polish notation
  CBICArg tmp, tmp2;
  MemSet(&tmp, 0, sizeof(CBICArg));
  MemSet(&tmp2, 0, sizeof(CBICArg));
  CBRPN *rpn2, *varg;
  I64 to_pop, vargs_len = 0, ptr;
  U8 *fptr;
  if (rpn->length - 8 > 0)
    to_pop = (rpn->length - 8) * 8;
  else
    to_pop = 0;
  for (i = 0; i < rpn->length; i++) {
    rpn2 = ICArgN(rpn, i);
    if (rpn2->type == __IC_VARGS) {
      vargs_len = rpn2->length * 8;
      first_is_vargs = 1;
    }
  }
  // Arm mandates 16 byte align
  ptr = to_pop; // SAVE FOR_LATEER GROWS DOWN
  if (to_pop % 16)
    to_pop += 8;
  if (to_pop) {
    if (ARM_ERR_INV_OFF != ARM_subImmX(ARM_REG_SP, ARM_REG_SP, to_pop)) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_subImmX(ARM_REG_SP, ARM_REG_SP, to_pop));
    } else {
      code_off = __ICMoveI64(cctrl, 0, to_pop, bin, code_off);
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_subRegX(ARM_REG_SP, ARM_REG_SP, 0));
    }
  }
  for (i = 0; i < rpn->length; i++) {
    rpn2 = ICArgN(rpn, i);
    if (rpn->length - 1 - i >= 8) {
      ptr -= 8; // Arguments are reversed
      tmp.mode = MD_INDIR_REG;
      tmp.reg = 31;
      tmp.off = ptr;
      // PROMOTE to 64bit
      if (rpn2->res.raw_type == BRT_F64)
        tmp.raw_type = BRT_F64;
      else
        tmp.raw_type = BRT_I64i;
      code_off = __OptPassFinal(cctrl, rpn2, bin, code_off);
      code_off = ICMov(cctrl, &tmp, &rpn2->res, bin, code_off);
    }
  }
  for (i = 0; i < rpn->length; i++) {
    rpn2 = ICArgN(rpn, i);
    if (!WONT_CHANGE(rpn2->type)) {
      if (!ArgRPNMutatesArgumentRegister(rpn, rpn->length - i - 1,
                                         rpn2->res.raw_type == BRT_F64) &&
          rpn->length - i - 1 < 8) {
        // Favor storing in argument registers if they arent changed
        tmp.mode = MD_REG;
        tmp.raw_type = rpn2->res.raw_type;
        tmp.reg = rpn->length - i - 1;
        if (rpn2->res.mode == MD_FRAME)
          MemCpy(&rpn2->res, &tmp, sizeof(CBICArg));
        code_off = __OptPassFinal(cctrl, rpn2, bin, code_off);
        code_off = ICMov(cctrl, &tmp, &rpn2->res, bin, code_off);
        MemCpy(&rpn2->res, &tmp, sizeof(CBICArg));
      } else if (rpn->length - i - 1 < 8) {
        code_off = __OptPassFinal(cctrl, rpn2, bin, code_off);
      }
    }
  }
  rpn2 = ICArgN(rpn, rpn->length);
  if (rpn2->type == BIC_SHORT_ADDR) {
    rpn2->code_misc->addr = code_off + bin;
    code_off = BEFORE_CALL(cctrl, rpn, &tmp, &tmp2, bin, code_off);
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_bl(0));
    goto after_call;
  }
  if (rpn2->type == BIC_GLOBAL) {
    if (rpn2->global_var->base.type & BHTT_FUN) {
      fptr = rpn2->global_var(CBHashFun *)->fun_ptr;
      //INTEGRATION: BDoNothing is the host runtime's no-op function.
      if (cctrl->code_ctrl->final_pass && fptr != &BDoNothing && fptr) {
        if (ARM_ERR_INV_OFF != ARM_bl(fptr(I64) - (bin + code_off)(I64))) {
          code_off = BEFORE_CALL(cctrl, rpn, &tmp, &tmp2, bin, code_off);
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_bl(fptr(I64) - (bin + code_off)(I64)));
        } else
          goto defacto;
      } else
        goto defacto;
    } else
      goto defacto;
  } else {
defacto:
    if ((rpn2->res.mode == MD_PTR)) {
      rpn2->raw_type = BRT_PTR;
      rpn2->res.mode = MD_REG;
      rpn2->res.raw_type = BRT_PTR;
      rpn2->res.reg = 8;
    }
    rpn2->raw_type = BRT_PTR;
    code_off = __OptPassFinal(cctrl, rpn2, bin, code_off);
    code_off = PutICArgIntoReg(cctrl, &rpn2->res, BRT_PTR, 8, bin, code_off);
    code_off = BEFORE_CALL(cctrl, rpn, &tmp, &tmp2, bin, code_off);
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_blr(MIR(cctrl, rpn2->res.reg)));
  }
after_call:
  if ((vargs_len / 8) & 1)
    vargs_len += 8;
  if (to_pop || vargs_len) {
    if (ARM_ERR_INV_OFF !=
        ARM_addImmX(ARM_REG_SP, ARM_REG_SP, to_pop + vargs_len)) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_addImmX(ARM_REG_SP, ARM_REG_SP, to_pop + vargs_len));
    } else {
      code_off = __ICMoveI64(cctrl, 0, to_pop + vargs_len, bin, code_off);
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_addRegX(ARM_REG_SP, ARM_REG_SP, 0));
    }
  }

  if (rpn->raw_type != BRT_U0) {
    tmp.reg = 0;
    tmp.mode = MD_REG;
    tmp.raw_type = rpn->raw_type;
    MemCpy(&rpn->tmp_res, &tmp, sizeof(CBICArg));
    if (rpn->res.keep_in_tmp)
      MemCpy(&rpn->res, &tmp, sizeof(CBICArg));
    code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
  }
  return code_off;
}

I64 ICMov(CBCmpCtrl *cctrl, CBICArg *dst, CBICArg *src, U8 *bin,
          I64 code_off) {
  I64 use_reg, use_reg2, restore_from_tmp = 0, indir_off = 0,
      indir_off2 = 0, opc;
  CBCodeMiscRef *ref;
  if (dst->mode == MD_NULL)
    return code_off;
  if (src->mode != -1 && src->mode)
    ;
  else
    abort();
  CBICArg tmp;
  MemSet(&tmp, 0, sizeof(CBICArg));
  if ((dst->raw_type == BRT_F64) == (src->raw_type == BRT_F64))
    if (dst->mode == src->mode) {
      switch (dst->mode) {
        case __MD_ARM_SHIFT:
          if (dst->reg == src->reg)
            if (dst->reg2 == src->reg2)
              return code_off;
          break;
        case MD_STATIC:
          if (dst->off == src->off)
            return code_off;
          break;
        case MD_PTR:
          if (dst->off == src->off)
            return code_off;
          break;
        case MD_REG:
          if (dst->reg == src->reg)
            return code_off;
          break;
        case MD_FRAME:
          if (dst->off == src->off)
            return code_off;
          break;
        case MD_INDIR_REG:
          if (dst->off == src->off && dst->reg == src->reg)
            return code_off;
      }
    }
  switch (dst->mode) {
    case __MD_ARM_SHIFT:
      if (src->mode == MD_REG &&
          ((src->raw_type == BRT_F64) == (dst->raw_type == BRT_F64))) {
        switch (dst->raw_type) {
          case BRT_U0:
            break;
          case BRT_U8i:
          case BRT_I8i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_strbRegReg(src->reg, dst->reg, dst->reg2));
            break;
          case BRT_U16i:
          case BRT_I16i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_strhRegRegShift(src->reg, dst->reg, dst->reg2));
            break;
          case BRT_U32i:
          case BRT_I32i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_strRegRegShift(src->reg, dst->reg, dst->reg2));
            break;
          case BRT_U64i:
          case BRT_I64i:
          case BRT_PTR:
          case BRT_FUNC:
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_strRegRegShiftX(src->reg, dst->reg, dst->reg2));
            break;
          case BRT_F64:
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_strRegRegShiftF64(src->reg, dst->reg, dst->reg2));
        }
        return code_off;
      }
      goto dft;
      break;
    case MD_STATIC:
      use_reg2 = BAIWNIOS_TMP_IREG_POOP;
      indir_off = 0;
      if (cctrl->code_ctrl->final_pass) {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_adrX(MIR(cctrl, use_reg2), 0));
        ref = CodeMiscAddRef(cctrl->statics_label, bin + code_off - 4);
        ref->patch_cond_br = &ARM_adrX;
        ref->user_data1 = use_reg2;
        ref->offset = dst->off;
      } else
        code_off = AIWNIOS_ADD_CODE(bin, code_off, 0);
      goto indir_r2;
      break;
    case MD_INDIR_REG:
      use_reg2 = dst->reg;
      indir_off = dst->off;
indir_r2:
      if (src->raw_type == dst->raw_type && src->raw_type == BRT_F64 &&
          src->mode == MD_REG) {
        use_reg = src->reg;
      } else if ((src->raw_type == BRT_F64) ^
                 (BRT_F64 == dst->raw_type)) { // Do they differ
        goto dft;
      } else if (src->mode == MD_FRAME || src->mode == MD_PTR ||
                 src->mode == MD_INDIR_REG) {
        goto dft;
      } else if (src->mode == MD_REG) {
        use_reg = src->reg;
        // Cant assign SP into mem directly in arm
        if (use_reg == ARM_REG_SP)
          goto dft;
      } else {
dft:
        tmp.raw_type = src->raw_type;
        if (dst->raw_type != BRT_F64)
          use_reg = tmp.reg = BAIWNIOS_TMP_IREG_POOP2;
        else
          use_reg = tmp.reg = 0;
        tmp.mode = MD_REG;
        if (dst->raw_type == BRT_F64 && src->raw_type != dst->raw_type) {
          tmp.reg = 0;
          code_off = ICMov(cctrl, &tmp, src, bin, code_off);
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_scvtf(MFR(cctrl, 0), MIR(cctrl, 0)));
          tmp.raw_type = BRT_F64;
          tmp.reg = 0;
          code_off = ICMov(cctrl, dst, &tmp, bin, code_off);
          return code_off;
        } else if (src->raw_type == BRT_F64 && src->raw_type != dst->raw_type) {
          tmp.reg = 0;
          code_off = ICMov(cctrl, &tmp, src, bin, code_off);
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fcvtzs(MIR(cctrl, 0), MFR(cctrl, 0)));
          tmp.raw_type = BRT_I64i;
          tmp.reg = 0;
          code_off = ICMov(cctrl, dst, &tmp, bin, code_off);
          return code_off;
        }
        code_off = ICMov(cctrl, &tmp, src, bin, code_off);
        code_off = ICMov(cctrl, dst, &tmp, bin, code_off);
        return code_off;
      }
      goto store_r2;
      break;
    case MD_PTR:
      use_reg2 = BAIWNIOS_TMP_IREG_POOP;
      code_off = __ICMoveI64(cctrl, use_reg2, dst->off, bin, code_off);
      indir_off = 0;
      goto indir_r2;
store_r2:
      if (indir_off < 0) {
        indir_off2 = indir_off;
        indir_off = 0;
        // FIX(1): Handle negative offsets beyond the immediate range.
        code_off = BAdjustNegOffset(cctrl, use_reg2, -indir_off2, TRUE, bin, code_off);
      }
      switch (dst->raw_type) {
        case BRT_U0:
          break;
        case BRT_F64:
          // TODO atomic
          opc = ARM_strRegImmF64(use_reg, use_reg2, indir_off);
          if (opc != ARM_ERR_INV_OFF) {
            code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
          } else {
            // TODO unaligned version
            //  5 is one of our poop registers
            code_off =
                __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin, code_off);
            code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                        ARM_strRegRegF64(use_reg, use_reg2, BAIWNIOS_TMP_IREG_POOP));
          }
          break;
        case BRT_U8i:
        case BRT_I8i:

          opc = ARM_strbRegImm(use_reg, use_reg2, indir_off);
          if (opc != ARM_ERR_INV_OFF) {
            code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
          } else {
            // Try unaligned version
            opc = ARM_sturb(use_reg, use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                     code_off);
              code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                          ARM_strbRegReg(use_reg, use_reg2, BAIWNIOS_TMP_IREG_POOP));
            }
          }
          break;
        case BRT_U16i:
        case BRT_I16i:

          opc = ARM_strhRegImm(use_reg, use_reg2, indir_off);
          if (opc != ARM_ERR_INV_OFF) {
            code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
          } else {
            // Try unaligned version
            opc = ARM_sturh(use_reg, use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                     code_off);
              code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                          ARM_strhRegReg(use_reg, use_reg2, BAIWNIOS_TMP_IREG_POOP));
            }
          }
          break;
        case BRT_U32i:
        case BRT_I32i:

          opc = ARM_strRegImm(use_reg, use_reg2, indir_off);
          if (opc != ARM_ERR_INV_OFF) {
            code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
          } else {
            // Try unaligned version
            opc = ARM_sturw(use_reg, use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // 5 is one of our poop registers
              code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                     code_off);
              code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                          ARM_strRegReg(use_reg, use_reg2, BAIWNIOS_TMP_IREG_POOP));
            }
          }
          break;
        case BRT_U64i:
        case BRT_I64i:
        case BRT_FUNC: // func ptr
        case BRT_PTR:
          opc = ARM_strRegImmX(use_reg, use_reg2, indir_off);
          if (opc != ARM_ERR_INV_OFF) {
            code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
          } else {
            opc = ARM_strRegImmX(use_reg, use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // Try unaligned version
              opc = ARM_stur(use_reg, use_reg2, indir_off);
              if (opc != ARM_ERR_INV_OFF) {
                code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
              } else {
                // 5 is one of our poop registers
                code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                       code_off);
                code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                            ARM_strRegRegX(use_reg, use_reg2, BAIWNIOS_TMP_IREG_POOP));
              }
            }
          }
          break;
        default:
          abort();
      }
      if (indir_off2 < 0) {
        // FIX(1): Restore a base adjusted by a large negative offset.
        code_off = BAdjustNegOffset(cctrl, use_reg2, -indir_off2, FALSE, bin, code_off);
      } else if (indir_off2 > 0) {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_subImmX(MIR(cctrl, use_reg2), use_reg2, indir_off2));
      }
      break;
    case MD_FRAME:
      use_reg2 = ARM_REG_FP;
      indir_off = dst->off;
      goto indir_r2;
      break;
    case MD_REG:
      use_reg = dst->reg;
      if (src->mode == MD_FRAME) {
        if (src->raw_type == BRT_F64 && src->raw_type == dst->raw_type) {
          use_reg2 = ARM_REG_FP;
          indir_off = src->off;
          goto load_r2;
        } else if ((src->raw_type == BRT_F64) ^ (BRT_F64 == dst->raw_type)) {
          goto dft;
        }
        use_reg2 = ARM_REG_FP;
        indir_off = src->off;
        goto load_r2;
      } else if (src->mode == __MD_ARM_SHIFT) {
        if ((src->raw_type == BRT_F64) != (dst->raw_type == BRT_F64))
          goto dft;
        switch (src->raw_type) {
          case BRT_U0:
            break;
          case BRT_U8i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                        ARM_ldrbRegReg(MIR(cctrl, dst->reg), src->reg, src->reg2));
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxtbX(MIR(cctrl, dst->reg), MIR(cctrl, dst->reg)));
            break;
          case BRT_I8i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                        ARM_ldrsbRegRegX(MIR(cctrl, dst->reg), src->reg, src->reg2));
            break;
          case BRT_U16i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                        ARM_ldrhRegRegShift(MIR(cctrl, dst->reg), src->reg, src->reg2));
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxthX(dst->reg, dst->reg));
            break;
          case BRT_I16i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                        ARM_ldrshRegRegShiftX(MIR(cctrl, dst->reg), src->reg, src->reg2));
            break;
          case BRT_U32i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                        ARM_ldrRegRegShift(MIR(cctrl, dst->reg), src->reg, src->reg2));
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxtwX(dst->reg, dst->reg));
            break;
          case BRT_I32i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                        ARM_ldrswRegRegShiftX(MIR(cctrl, dst->reg), src->reg, src->reg2));
            break;
          case BRT_U64i:
          case BRT_PTR:
          case BRT_FUNC:
          case BRT_I64i:
            code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                        ARM_ldrRegRegShiftX(MIR(cctrl, dst->reg), src->reg, src->reg2));
            break;
          case BRT_F64:
            code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                        ARM_ldrRegRegShiftF64(MFR(cctrl, dst->reg), src->reg, src->reg2));
        }
        return code_off;
      } else if (src->mode == MD_REG) {
        if (src->raw_type == BRT_F64 && src->raw_type == dst->raw_type) {
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovReg(MFR(cctrl, dst->reg), src->reg));
        } else if (src->raw_type != BRT_F64 && dst->raw_type != BRT_F64) {
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_movRegX(MIR(cctrl, dst->reg), src->reg));
        } else if (src->raw_type == BRT_F64 && dst->raw_type != BRT_F64) {
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fcvtzs(MFR(cctrl, dst->reg), src->reg));
        } else if (src->raw_type != BRT_F64 && dst->raw_type == BRT_F64) {
          switch (src->raw_type) {
            case BRT_U8i:
            case BRT_U16i:
            case BRT_U32i:
            case BRT_U64i:
              code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ucvtf(MFR(cctrl, dst->reg), src->reg));
              break;
            default:
              code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_scvtf(MFR(cctrl, dst->reg), src->reg));
          }
          return code_off;
        }
      } else if (src->mode == MD_PTR) {
        if (src->raw_type == BRT_F64 && src->raw_type == dst->raw_type) {
          use_reg2 = 0;
          code_off = __ICMoveI64(cctrl, use_reg2, src->off, bin, code_off);
          goto load_r2;
        } else if ((src->raw_type == BRT_F64) ^ (BRT_F64 == dst->raw_type)) {
          goto dft;
        }
        // We can use ARM_ldrLabel/ARM_ldrLabelX for 64/32bit shenangins if it is
        // in range
        if (cctrl->code_ctrl->final_pass)
          switch (src->raw_type) {
            case BRT_I32i:
              opc = ARM_ldrLabel(use_reg, src->off - (code_off + bin)(I64));
              if (opc != ARM_ERR_INV_OFF) {
                code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
                code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_sxtwX(MIR(cctrl, use_reg), use_reg));
                return code_off;
              }
              break;
            case BRT_U32i:
              opc = ARM_ldrLabel(use_reg, src->off - (code_off + bin)(I64));
              if (opc != ARM_ERR_INV_OFF) {
                code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
                code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxtwX(MIR(cctrl, use_reg), use_reg));
                return code_off;
              }
              break;
            case BRT_I64i:
            case BRT_U64i:
              opc = ARM_ldrLabelX(MIR(cctrl, use_reg),
                                  src->off - (code_off + bin)(I64));
              if (opc != ARM_ERR_INV_OFF) {
                code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
                return code_off;
              }
              break;
            case BRT_F64:
              opc = ARM_ldrLabelF64(MFR(cctrl, use_reg),
                                    src->off - (code_off + bin)(I64));
              if (opc != ARM_ERR_INV_OFF) {
                code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
                return code_off;
              }
          }

        use_reg2 = BAIWNIOS_TMP_IREG_POOP;
        code_off = __ICMoveI64(cctrl, use_reg2, src->off, bin, code_off);
        indir_off = 0;
load_r2:
        if (indir_off < 0) {
          indir_off2 = indir_off;
          indir_off = 0;
          // FIX(1): Handle negative offsets beyond the immediate range.
          code_off = BAdjustNegOffset(cctrl, use_reg2, -indir_off2, TRUE, bin, code_off);
        }
        switch (src->raw_type) {
          case BRT_U0:
            break;
          case BRT_F64:
            // TODO atomic
            opc = ARM_ldrRegImmF64(MFR(cctrl, use_reg), use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // 5 is one of our poop registers
              code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                     code_off);
              code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrRegRegF64(MFR(cctrl, use_reg), use_reg2,
                  BAIWNIOS_TMP_IREG_POOP));
            }
            break;
          case BRT_U8i:
            opc = ARM_ldrbRegImm(MIR(cctrl, use_reg), use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // 5 is one of our poop registers
              code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                     code_off);
              code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrbRegReg(MIR(cctrl, use_reg), use_reg2,
                  BAIWNIOS_TMP_IREG_POOP));
            }
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxtbX(use_reg, use_reg));
            break;
          case BRT_I8i:
            opc = ARM_ldrsbX(MIR(cctrl, use_reg), use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // Try unaligned version
              opc = ARM_ldursbX(use_reg, use_reg2, indir_off);
              if (opc != ARM_ERR_INV_OFF) {
                code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
              } else {
                // 5 is one of our poop registers
                code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                       code_off);
                code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrsbRegRegX(MIR(cctrl, use_reg), use_reg2,
                    BAIWNIOS_TMP_IREG_POOP));
              }
            }
            break;
          case BRT_U16i:
            opc = ARM_ldrhRegImm(MIR(cctrl, use_reg), use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // 5 is one of our poop registers
              code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                     code_off);
              code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrhRegReg(MIR(cctrl, use_reg), use_reg2,
                  BAIWNIOS_TMP_IREG_POOP));
            }
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxthX(MIR(cctrl, use_reg), use_reg));
            break;
          case BRT_I16i:
            opc = ARM_ldrshX(MIR(cctrl, use_reg), use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // Try unaligned version
              opc = ARM_ldurshX(use_reg, use_reg2, indir_off);
              if (opc != ARM_ERR_INV_OFF) {
                code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
              } else {
                // 5 is one of our poop registers
                code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                       code_off);
                code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrshRegRegX(MIR(cctrl, use_reg), use_reg2,
                    BAIWNIOS_TMP_IREG_POOP));
              }
            }
            break;
          case BRT_U32i:
            opc = ARM_ldrRegImm(MIR(cctrl, use_reg), use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // 5 is one of our poop registers
              code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                     code_off);
              code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrRegReg(MIR(cctrl, use_reg), use_reg2,
                  BAIWNIOS_TMP_IREG_POOP));
            }
            code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxtwX(use_reg, use_reg));
            break;
          case BRT_I32i:
            opc = ARM_ldrswX(MIR(cctrl, use_reg), use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // Try unaligned version
              opc = ARM_ldurswX(use_reg, use_reg2, indir_off);
              if (opc != ARM_ERR_INV_OFF) {
                code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
              } else {
                // 5 is one of our poop registers
                code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                       code_off);
                code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrswRegRegX(MIR(cctrl, use_reg), use_reg2,
                    BAIWNIOS_TMP_IREG_POOP));
              }
            }
            break;
          case BRT_U64i:
          case BRT_I64i:
          case BRT_FUNC: // func ptr
          case BRT_PTR:
            opc = ARM_ldrRegImmX(MIR(cctrl, use_reg), use_reg2, indir_off);
            if (opc != ARM_ERR_INV_OFF) {
              code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
            } else {
              // Try unaligned version
              opc = ARM_ldur(use_reg, use_reg2, indir_off);
              if (opc != ARM_ERR_INV_OFF) {
                code_off = AIWNIOS_ADD_CODE(bin, code_off, opc);
              } else {
                // 5 is one of our poop registers
                code_off = __ICMoveI64(cctrl, BAIWNIOS_TMP_IREG_POOP, indir_off, bin,
                                       code_off);
                code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldrRegRegX(MIR(cctrl, use_reg), use_reg2,
                    BAIWNIOS_TMP_IREG_POOP));
              }
            }
            break;
          default:
            abort();
        }
        if (indir_off2 < 0) {
          // FIX(1): Restore a base adjusted by a large negative offset.
          code_off = BAdjustNegOffset(cctrl, use_reg2, -indir_off2, FALSE, bin, code_off);
        } else if (indir_off2 > 0) {
          code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                      ARM_subImmX(MIR(cctrl, use_reg2), use_reg2, indir_off2));
        }
      } else if (src->mode == MD_INDIR_REG) {
        use_reg2 = src->reg;
        indir_off = src->off;
        if (src->raw_type == BRT_F64 && src->raw_type == dst->raw_type) {
          use_reg2 = src->reg;
        } else if ((src->raw_type == BRT_F64) ^ (BRT_F64 == dst->raw_type)) {
          goto dft;
        }
        goto load_r2;
      } else if (src->mode == MD_I64 && dst->raw_type != BRT_F64) {
        code_off = __ICMoveI64(cctrl, dst->reg, src->integer, bin, code_off);
      } else if (src->mode == MD_F64 && dst->raw_type == BRT_F64) {
        code_off = __ICMoveF64(cctrl, dst->reg, src->flt, bin, code_off);
      } else if (src->mode == MD_I64 && dst->raw_type == BRT_F64) {
        code_off = __ICMoveF64(cctrl, dst->reg, src->integer, bin, code_off);
      } else if (src->mode == MD_F64 && dst->raw_type != BRT_F64) {
        //PORT-NOTE: C converts the double to uint64_t here; HolyC converts F64 to U64 with its own rounding (same for in-range positive values).
        code_off = __ICMoveI64(cctrl, dst->reg, BF64ToU64(src->flt), bin, code_off); // PORT-NOTE: C passes the F64 to a uint64_t parameter
      } else if (src->mode == MD_STATIC) {
        use_reg2 = BAIWNIOS_TMP_IREG_POOP;
        indir_off = 0;
        if (cctrl->code_ctrl->final_pass) {
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_adrX(MIR(cctrl, use_reg2), 0));
          ref = CodeMiscAddRef(cctrl->statics_label, bin + code_off - 4);
          ref->patch_cond_br = &ARM_adrX;
          ref->user_data1 = use_reg2;
          ref->offset = src->off;
        } else
          code_off = AIWNIOS_ADD_CODE(bin, code_off, 0);
        if (src->raw_type == BRT_F64 && src->raw_type == dst->raw_type) {
        } else if ((src->raw_type == BRT_F64) ^ (BRT_F64 == dst->raw_type)) {
          goto dft;
        }
        goto load_r2;
      } else
        goto dft;
      break;
    default:
      abort();
  }
  return code_off;
}

//
// If we call a function the tmp regs go to poo poo land
//
I64 SpillsTmpRegs(CBRPN *rpn) {
  I64 idx;
  switch (rpn->type) {
    case __IC_CALL:
    case BIC_CALL:
      return 1;
      break;
    case __IC_VARGS:
      for (idx = 0; idx != rpn->length; idx++)
        if (SpillsTmpRegs(ICArgN(rpn, idx)))
          return 1;
      return 0;
    case BIC_TO_F64:
    case BIC_TO_I64:
    case BIC_NEG:
    case BIC_TO_BOOL:
unop:
      return SpillsTmpRegs(rpn->base.next(CBRPN *));
      break;
    case BIC_SQR:
    case BIC_POS:
      goto unop;
      break;
    case BIC_POW:
      return 1; // calls BPow
binop:
      if (SpillsTmpRegs(rpn->base.next(CBRPN *)))
        return 1;
      if (SpillsTmpRegs(ICFwd(rpn->base.next(CBRPN *))))
        return 1;
      break;
    case BIC_ADD:
      goto binop;
      break;
    case BIC_EQ:
      goto binop;
      break;
    case BIC_MAX_F64:
    case BIC_MAX_I64:
    case BIC_MAX_U64:
    case BIC_MIN_F64:
    case BIC_MIN_I64:
    case BIC_MIN_U64:
    case BIC_SUB:
      goto binop;
      break;
    case BIC_DIV:
      goto binop;
      break;
    case BIC_MUL:
      goto binop;
      break;
    case BIC_DEREF:
      goto unop;
      break;
    case BIC_AND:
      goto binop;
      break;
    case BIC_ADDR_OF:
      goto unop;
      break;
    case BIC_XOR:
      goto binop;
      break;
    case BIC_MOD:
      goto binop;
      break;
    case BIC_OR:
      goto binop;
      break;
    case BIC_LT:
      goto binop;
      break;
    case BIC_GT:
      goto binop;
      break;
    case BIC_LNOT:
      goto unop;
      break;
    case BIC_BNOT:
      goto unop;
      break;
    case BIC_POST_INC:
      goto binop;
      break;
    case BIC_POST_DEC:
      goto binop;
      break;
    case BIC_PRE_INC:
      goto binop;
      break;
    case BIC_PRE_DEC:
      goto binop;
      break;
    case BIC_AND_AND:
      goto binop;
      break;
    case BIC_OR_OR:
      goto binop;
      break;
    case BIC_XOR_XOR:
      goto binop;
      break;
    case BIC_EQ_EQ:
      goto binop;
      break;
    case BIC_NE:
      goto binop;
      break;
    case BIC_LE:
      goto binop;
      break;
    case BIC_GE:
      goto binop;
      break;
    case BIC_LSH:
      goto binop;
      break;
    case BIC_RSH:
      goto binop;
      break;
    case BIC_ADD_EQ:
      goto binop;
      break;
    case BIC_SUB_EQ:
      goto binop;
      break;
    case BIC_MUL_EQ:
      goto binop;
      break;
    case BIC_DIV_EQ:
      goto binop;
      break;
    case BIC_LSH_EQ:
      goto binop;
      break;
    case BIC_RSH_EQ:
      goto binop;
      break;
    case BIC_AND_EQ:
      goto binop;
      break;
    case BIC_OR_EQ:
      goto binop;
      break;
    case BIC_XOR_EQ:
      goto binop;
      break;
    case BIC_MOD_EQ:
      goto binop;
      break;
    case BIC_STORE:
      goto binop;
    case BIC_TYPECAST:
      goto unop;
    case BIC_FS:
    case BIC_GS:
      return 0;
  }
  return 0;
t:
  return 1;
}

//
// Here's the 3rd Donald Trump deal. L-values in HolyC are typecastable
// Here's an example
//
// U8 *a=0xb00b1e5;
// *a(F64*)=pi; //We write an F64 into a U8 pointer
//
// We we need silly sauce to check if we are writing int an typecasted l-value.
// If so,time to rock
//
I64 __SexyWriteIntoDst(CBCmpCtrl *cctrl, CBRPN *deref, CBICArg *arg,
                       U8 *bin, I64 code_off) {
  CBICArg derefed, tmp;
  MemSet(&derefed, 0, sizeof(CBICArg));
  MemSet(&tmp, 0, sizeof(CBICArg));
  I64 tc = 0;
  CBRPN *orig_rpn = deref;
  code_off = DerefToICArg(cctrl, &derefed, deref, 2, bin, code_off);
  if (!tc) {
dft:
    code_off = ICMov(cctrl, &derefed, arg, bin, code_off);
  } else {
    if (derefed.mode == MD_REG) {
      if (orig_rpn->raw_type == BRT_F64 && arg->raw_type != BRT_F64) {
        code_off = PutICArgIntoReg(cctrl, arg, arg->raw_type, 0, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovF64I64(MFR(cctrl, derefed.reg), arg->reg));
      } else if (orig_rpn->raw_type != BRT_F64 && arg->raw_type == BRT_F64) {
        code_off = PutICArgIntoReg(cctrl, arg, arg->raw_type, 0, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovI64F64(MIR(cctrl, derefed.reg), arg->reg));
      } else {
        goto dft;
      }
    } else {
      tmp.reg = 1;
      tmp.mode = MD_REG;
      tmp.raw_type = orig_rpn->raw_type;
      if (orig_rpn->raw_type == BRT_F64 && arg->raw_type != BRT_F64) {
        code_off = PutICArgIntoReg(cctrl, arg, arg->raw_type, 0, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovF64I64(MFR(cctrl, 1), arg->reg));
      } else if (orig_rpn->raw_type != BRT_F64 && arg->raw_type == BRT_F64) {
        code_off = PutICArgIntoReg(cctrl, arg, arg->raw_type, 0, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovI64F64(MIR(cctrl, 1), arg->reg));
      } else {
        goto dft;
      }
      arg = &tmp;
      goto dft;
    }
  }
  return code_off;
}
//PORT-NOTE: ATOMIC_LOAD/ATOMIC_STORE were a pair of C macros that opened and closed one
//  block sharing `retry`. They are functions here; the caller sets `retry = code_off;`
//  before ATOMIC_LOAD and passes it to ATOMIC_STORE. Both return the new code_off.
//PORT-NOTE: C bugs kept as is: the 16 and 32 bit cases of ATOMIC_LOAD test
//  `RT_U8i == derefed.raw_type` (so U16/U32 get sign extended), and the 32 bit case
//  of ATOMIC_STORE uses ARM_stlxrh.
I64 ATOMIC_LOAD(CBCmpCtrl *cctrl, CBICArg *derefed, U8 *bin, I64 code_off) {
  if (derefed->mode == __MD_ARM_SHIFT) {
    switch (derefed->raw_type) {
      case BRT_I8i:
      case BRT_U8i:
        code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                    ARM_addRegX(MIR(cctrl, 1), derefed->reg2, derefed->reg));
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldaxrb(MIR(cctrl, 0), 1));
        if (BRT_U8i == derefed->raw_type)
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxtbX(0, 0));
        else
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_sxtbX(0, 0));
        break;
      case BRT_I16i:
      case BRT_U16i:
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_lslImmX(MIR(cctrl, 0), derefed->reg2, 1));
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_addRegX(MIR(cctrl, 1), 0, derefed->reg));
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldaxrh(0, 1));
        if (BRT_U8i == derefed->raw_type)
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxthX(0, 0));
        else
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_sxthX(0, 0));
        break;
      case BRT_I32i:
      case BRT_U32i:
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_lslImmX(MIR(cctrl, 0), derefed->reg2, 2));
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_addRegX(MIR(cctrl, 1), 0, derefed->reg));
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldaxr(0, 1));
        if (BRT_U8i == derefed->raw_type)
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxtwX(0, 0));
        else
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_sxtwX(0, 0));
        break;
      case BRT_I64i:
      case BRT_U64i:
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_lslImmX(MIR(cctrl, 0), derefed->reg2, 3));
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_addRegX(MIR(cctrl, 1), 0, derefed->reg));
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldaxrX(0, 1));
        break;
    }
  } else if (derefed->mode == MD_INDIR_REG) {
    if (derefed->off) {
      code_off = __ICMoveI64(cctrl, MIR(cctrl, 0), derefed->off, bin, code_off);
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_addRegX(MIR(cctrl, 1), 0, derefed->reg));
    } else {
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_movRegX(MIR(cctrl, 1), derefed->reg));
    }
    switch (derefed->raw_type) {
      case BRT_I8i:
      case BRT_U8i:
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldaxrb(MIR(cctrl, 0), 1));
        if (BRT_U8i == derefed->raw_type)
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxtbX(0, 0));
        else
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_sxtbX(0, 0));
        break;
      case BRT_I16i:
      case BRT_U16i:
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldaxrh(MIR(cctrl, 0), 1));
        if (BRT_U8i == derefed->raw_type)
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxthX(0, 0));
        else
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_sxthX(0, 0));
        break;
      case BRT_I32i:
      case BRT_U32i:
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldaxr(MIR(cctrl, 0), 1));
        if (BRT_U8i == derefed->raw_type)
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_uxtwX(0, 0));
        else
          code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_sxtwX(0, 0));
        break;
      case BRT_I64i:
      case BRT_U64i:
        code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_ldaxrX(MIR(cctrl, 0), 1));
        break;
    }
  }
  return code_off;
}
I64 ATOMIC_STORE(CBCmpCtrl *cctrl, CBICArg *derefed, I64 r, I64 retry, U8 *bin,
                 I64 code_off) {
  switch (derefed->raw_type) {
    case BRT_I8i:
    case BRT_U8i:
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_stlxrb(MIR(cctrl, 0), r, 1));
      break;
    case BRT_I16i:
    case BRT_U16i:
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_stlxrh(MIR(cctrl, 0), r, 1));
      break;
    case BRT_I32i:
    case BRT_U32i:
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_stlxrh(MIR(cctrl, 0), r, 1));
      break;
    case BRT_I64i:
    case BRT_U64i:
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_stlxrX(MIR(cctrl, 0), r, 1));
      break;
  }
  code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_cbnz(0, retry - code_off));
  return code_off;
}
//PORT-NOTE: TYPECAST_ASSIGN_BEGIN/END were a pair of C macros that opened and closed one
//  block declaring pop, pop2, _orig. They are functions here: the caller declares
//  `I64 pop, pop2; CBICArg _orig;`, `dst` is the address of the RPN variable the macro
//  reassigned (DST), `src` is the value of the SRC argument. Both return the new code_off.
//  In __SexyAssignOp the C jumps (goto defacto) from one BEGIN block into another one,
//  skipping its initialisation; here the shared variables keep the values of the first BEGIN.
I64 TYPECAST_ASSIGN_BEGIN(CBCmpCtrl *cctrl, CBRPN **dst, CBRPN *src,
                          CBICArg *_orig, I64 *pop, I64 *pop2, U8 *bin,
                          I64 code_off) {
  CBRPN *_tc = *dst;
  CBRPN *SRC2 = src;
  *pop = 0;
  *pop2 = 0;
  MemSet(_orig, 0, sizeof(CBICArg));
  *dst = (*dst)->base.next(CBRPN *);
  if ((*dst)->type == BIC_DEREF) {
    code_off = DerefToICArg(cctrl, _orig, *dst, 1, bin, code_off);
    MemCpy(&(*dst)->res, _orig, sizeof(CBICArg));
    (*dst)->raw_type = _tc->raw_type;
  } else if (((*dst)->raw_type == BRT_F64) ^ (SRC2->raw_type == BRT_F64)) {
    *pop = 1;
    *pop2 = 1;
    MemCpy(_orig, &(*dst)->res, sizeof(CBICArg));
    code_off = PutICArgIntoReg(cctrl, &(*dst)->res, (*dst)->raw_type, 0, bin, code_off);
    code_off = PushToStack(cctrl, &(*dst)->res, bin, code_off);
    (*dst)->res.mode = MD_INDIR_REG;
    (*dst)->res.off = 0;
    (*dst)->res.reg = ARM_REG_SP;
    (*dst)->res.raw_type = _tc->raw_type;
    (*dst)->raw_type = _tc->raw_type;
  } else {
    *pop2 = 1;
    (*dst)->res.raw_type = _tc->raw_type;
    (*dst)->raw_type = _tc->raw_type;
  }
  return code_off;
}
I64 TYPECAST_ASSIGN_END(CBCmpCtrl *cctrl, I64 pop, CBICArg *_orig, U8 *bin,
                        I64 code_off) {
  if (pop)
    code_off = PopFromStack(cctrl, _orig, bin, code_off);
  return code_off;
}
I64 __SexyPreOp(CBCmpCtrl *cctrl, CBRPN *rpn,
                I64 (*i_imm_op)(I64, I64, I64),
                I64 (*i_reg_op)(I64, I64, I64),
                I32 (*f_op)(I64, I64, I64),
                U8 *bin, I64 code_off) {
  I64 code;
  CBRPN *next = rpn->base.next(CBRPN *), *tc;
  CBICArg derefed, tmp, tmp2;
  MemSet(&derefed, 0, sizeof(CBICArg));
  MemSet(&tmp, 0, sizeof(CBICArg));
  MemSet(&tmp2, 0, sizeof(CBICArg));
  I64 pop, pop2, retry;
  CBICArg _orig;
  if (next->type == BIC_TYPECAST) {
    code_off = TYPECAST_ASSIGN_BEGIN(cctrl, &next, next, &_orig, &pop, &pop2, bin, code_off);
    if (next->raw_type == BRT_F64) {
      CBICArg orig;
      MemCpy(&orig, &next->res, sizeof(CBICArg));
      code_off =
          PutICArgIntoReg(cctrl, &next->res, next->raw_type, 2, bin, code_off);
      code_off = __ICMoveF64(cctrl, 1, rpn->integer, bin, code_off);
      code_off = AIWNIOS_ADD_CODE(bin, code_off, f_op(MFR(cctrl, next->res.reg), next->res.reg, 1));
      code_off = ICMov(cctrl, &rpn->res, &next->res, bin, code_off);
      code_off = ICMov(cctrl, &orig, &next->res, bin, code_off);
    } else {
      //PORT-NOTE: HolyC locals are function scoped; this second `CBICArg orig` was merged with the first.
      MemCpy(&orig, &next->res, sizeof(CBICArg));
      code_off =
          PutICArgIntoReg(cctrl, &next->res, next->raw_type, 1, bin, code_off);
      code = i_imm_op(MIR(cctrl, next->res.reg), next->res.reg, rpn->integer);
      if (code != ARM_ERR_INV_OFF) {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, code);
      } else {
        code_off =
            __ICMoveI64(cctrl, MIR(cctrl, 2), rpn->integer, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, i_reg_op(MIR(cctrl, next->res.reg), next->res.reg, 2));
      }
      code_off = ICMov(cctrl, &orig, &next->res, bin, code_off);
      code_off = ICMov(cctrl, &rpn->res, &next->res, bin, code_off);
    }
    code_off = TYPECAST_ASSIGN_END(cctrl, pop, &_orig, bin, code_off);
  } else {
    if (next->raw_type == BRT_F64) {
      code_off = DerefToICArg(cctrl, &derefed, next, 3, bin, code_off);
      MemCpy(&tmp, &derefed, sizeof(CBICArg)); //==BRT_F64
      code_off = PutICArgIntoReg(cctrl, &tmp, tmp.raw_type, 2, bin, code_off);
      code_off = __ICMoveF64(cctrl, 1, rpn->integer, bin, code_off);
      code_off = AIWNIOS_ADD_CODE(bin, code_off, f_op(MFR(cctrl, tmp.reg), tmp.reg, 1));
      code_off = ICMov(cctrl, &derefed, &tmp, bin, code_off);
      code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
    } else {
      code_off = DerefToICArg(cctrl, &derefed, next, 3, bin, code_off);
      MemCpy(&tmp, &derefed, sizeof(CBICArg));
      if ((rpn->flags & ICF_LOCK_EXPR) &&
          (tmp.mode == MD_INDIR_REG || tmp.mode == __MD_ARM_SHIFT)) {
        retry = code_off;
        code_off = ATOMIC_LOAD(cctrl, &derefed, bin, code_off);
        tmp.mode = MD_REG;
        tmp.reg = 0;
        code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
        code = i_imm_op(MIR(cctrl, 0), 0, rpn->integer);
        if (code != ARM_ERR_INV_OFF) {
          code_off = AIWNIOS_ADD_CODE(bin, code_off, code);
        } else {
          code_off = __ICMoveI64(cctrl, 2, rpn->integer, bin, code_off);
          code_off = AIWNIOS_ADD_CODE(bin, code_off, i_reg_op(MIR(cctrl, 0), 0, 2));
        }
        code_off = ATOMIC_STORE(cctrl, &derefed, 0, retry, bin, code_off);
        return code_off;
      }
      code_off = PutICArgIntoReg(cctrl, &tmp, tmp.raw_type, 2, bin, code_off);
      code = i_imm_op(tmp.reg, tmp.reg, rpn->integer);
      if (code != ARM_ERR_INV_OFF) {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, code);
      } else {
        code_off = __ICMoveI64(cctrl, 1, rpn->integer, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, i_reg_op(MIR(cctrl, tmp.reg), tmp.reg, 1));
      }
      code_off = ICMov(cctrl, &derefed, &tmp, bin, code_off);
      code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
    }
  }
  return code_off;
}

I64 __SexyPostOp(CBCmpCtrl *cctrl, CBRPN *rpn,
                 I64 (*i_imm_op)(I64, I64, I64),
                 I64 (*i_reg_op)(I64, I64, I64),
                 I64 (*f_op)(I64, I64, I64),
                 U8 *bin, I64 code_off) {
  CBRPN *next = rpn->base.next(CBRPN *), *tc;
  I64 code;
  CBICArg derefed, tmp, tmp2;
  MemSet(&derefed, 0, sizeof(CBICArg));
  MemSet(&tmp, 0, sizeof(CBICArg));
  MemSet(&tmp2, 0, sizeof(CBICArg));
  I64 pop, pop2, retry;
  CBICArg _orig;
  if (next->type == BIC_TYPECAST) {
    code_off = TYPECAST_ASSIGN_BEGIN(cctrl, &next, next, &_orig, &pop, &pop2, bin, code_off);
    if (next->raw_type == BRT_F64) {
      CBICArg orig;
      MemCpy(&orig, &next->res, sizeof(CBICArg));
      code_off =
          PutICArgIntoReg(cctrl, &next->res, next->raw_type, 2, bin, code_off);
      code_off = __ICMoveF64(cctrl, 1, rpn->integer, bin, code_off);
      code_off = ICMov(cctrl, &rpn->res, &next->res, bin, code_off);
      code_off = AIWNIOS_ADD_CODE(bin, code_off, f_op(MFR(cctrl, next->res.reg), next->res.reg, 1));
      code_off = ICMov(cctrl, &orig, &next->res, bin, code_off);
    } else {
      //PORT-NOTE: HolyC locals are function scoped; this second `CBICArg orig` was merged with the first.
      MemCpy(&orig, &next->res, sizeof(CBICArg));
      code_off =
          PutICArgIntoReg(cctrl, &next->res, next->raw_type, 1, bin, code_off);
      code_off = ICMov(cctrl, &rpn->res, &next->res, bin, code_off);
      code = i_imm_op(MIR(cctrl, next->res.reg), next->res.reg, rpn->integer);
      if (code != ARM_ERR_INV_OFF) {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, code);
      } else {
        code_off = __ICMoveI64(cctrl, 2, rpn->integer, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, i_reg_op(MIR(cctrl, next->res.reg), next->res.reg, 2));
      }
      code_off = ICMov(cctrl, &orig, &next->res, bin, code_off);
    }
    code_off = TYPECAST_ASSIGN_END(cctrl, pop, &_orig, bin, code_off);
  } else {
    if (next->raw_type == BRT_F64) {
      code_off = DerefToICArg(cctrl, &derefed, next, 3, bin, code_off);
      MemCpy(&tmp, &derefed, sizeof(CBICArg)); //==BRT_F64
      code_off = PutICArgIntoReg(cctrl, &tmp, tmp.raw_type, 2, bin, code_off);
      code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
      code_off = __ICMoveF64(cctrl, 1, rpn->integer, bin, code_off);
      code_off = AIWNIOS_ADD_CODE(bin, code_off, f_op(MFR(cctrl, tmp.reg), tmp.reg, 1));
      code_off = ICMov(cctrl, &derefed, &tmp, bin, code_off);
    } else {
      code_off = DerefToICArg(cctrl, &derefed, next, 3, bin, code_off);
      MemCpy(&tmp, &derefed, sizeof(CBICArg));
      code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
      if ((rpn->flags & ICF_LOCK_EXPR) &&
          (tmp.mode == MD_INDIR_REG || tmp.mode == __MD_ARM_SHIFT)) {
        retry = code_off;
        code_off = ATOMIC_LOAD(cctrl, &derefed, bin, code_off);
        tmp.mode = MD_REG;
        tmp.reg = 1;
        code = i_imm_op(MIR(cctrl, 1), 1, rpn->integer);
        if (code != ARM_ERR_INV_OFF) {
          code_off = AIWNIOS_ADD_CODE(bin, code_off, code);
        } else {
          code_off = __ICMoveI64(cctrl, 2, rpn->integer, bin, code_off);
          code_off = AIWNIOS_ADD_CODE(bin, code_off, i_reg_op(MIR(cctrl, 1), 1, 2));
        }
        code_off = ATOMIC_STORE(cctrl, &derefed, 0, retry, bin, code_off);
        return code_off;
      }
      code_off = PutICArgIntoReg(cctrl, &tmp, tmp.raw_type, 2, bin, code_off);
      code = i_imm_op(MIR(cctrl, tmp.reg), tmp.reg, rpn->integer);
      if (code != ARM_ERR_INV_OFF) {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, code);
      } else {
        code_off = __ICMoveI64(cctrl, 1, rpn->integer, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, i_reg_op(MIR(cctrl, tmp.reg), tmp.reg, 1));
      }
      code_off = ICMov(cctrl, &derefed, &tmp, bin, code_off);
    }
  }
  return code_off;
}
I64 FBitOp(CBCmpCtrl *cctrl, CBICArg *res, CBICArg *next, CBICArg *next2,
           I32 (*bit_op)(I64, I64, I64), I32 shift,
           U8 *bin, I64 code_off) {
  CBICArg tmp;
  MemSet(&tmp, 0, sizeof(CBICArg));
  if (shift) {
    code_off = PutICArgIntoReg(cctrl, next, BRT_F64, 2, bin, code_off);
    code_off = PutICArgIntoReg(cctrl, next2, BRT_I64i, 1, bin, code_off);
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovI64F64(MIR(cctrl, 2), next->reg));
    code_off = AIWNIOS_ADD_CODE(bin, code_off, bit_op(MIR(cctrl, 2), 2, 1));
    if (res->mode == MD_REG) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovF64I64(MFR(cctrl, res->reg), 2));
    } else {
      tmp.mode = MD_REG;
      tmp.reg = 2;
      tmp.raw_type = BRT_F64;
      code_off = ICMov(cctrl, res, &tmp, bin, code_off);
    }
  } else {
    code_off = PutICArgIntoReg(cctrl, next, BRT_F64, 2, bin, code_off);
    code_off = PutICArgIntoReg(cctrl, next2, BRT_F64, 1, bin, code_off);
    if (next->raw_type != BRT_F64) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovI64F64(MIR(cctrl, 2), next->reg));
      next->reg = 2;
      next->raw_type = BRT_F64;
    }
    if (next2->raw_type != BRT_F64) {
      next2->reg = 1;
      next2->raw_type = BRT_F64;
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovI64F64(MIR(cctrl, 1), next2->reg));
    }
    code_off = AIWNIOS_ADD_CODE(bin, code_off, bit_op(2, next2->reg, next->reg));
    if (res->mode == MD_REG) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovF64I64(MFR(cctrl, res->reg), 2));
    } else {
      tmp.mode = MD_REG;
      tmp.reg = 2;
      tmp.raw_type = BRT_F64;
      code_off = ICMov(cctrl, res, &tmp, bin, code_off);
    }
  }
  return code_off;
}
// FIX(4): Apply bitwise compound operators to the bits of an F64 lvalue.
I64 BF64BitAssign(CBCmpCtrl *cctrl, CBRPN *rpn,
                  I32 (*bit_op)(I64, I64, I64), Bool shift,
                  U8 *bin, I64 code_off) {
  CBRPN *dst = ICArgN(rpn, 1), *rhs = ICArgN(rpn, 0);
  CBICArg derefed, lhs, result, orig;
  I64 pop = 0, pop2 = 0;
  MemSet(&derefed, 0, sizeof(CBICArg));
  MemSet(&lhs, 0, sizeof(CBICArg));
  MemSet(&result, 0, sizeof(CBICArg));
  MemSet(&orig, 0, sizeof(CBICArg));
  code_off = __OptPassFinal(cctrl, rhs, bin, code_off);
  if (dst->type == BIC_TYPECAST) {
    code_off = TYPECAST_ASSIGN_BEGIN(cctrl, &dst, rhs, &orig, &pop, &pop2, bin, code_off);
    MemCpy(&derefed, &dst->res, sizeof(CBICArg));
  } else {
    code_off = DerefToICArg(cctrl, &derefed, dst, 2, bin, code_off);
  }
  MemCpy(&lhs, &derefed, sizeof(CBICArg));
  code_off = PutICArgIntoReg(cctrl, &lhs, BRT_F64, 2, bin, code_off);
  result.mode = MD_REG;
  result.reg = 4;
  result.raw_type = BRT_F64;
  if (shift) {
    code_off = FBitOp(cctrl, &result, &lhs, &rhs->res, bit_op, TRUE, bin, code_off);
  } else {
    // FIX(4): Move both floating registers to integer registers before the bit op.
    code_off = PutICArgIntoReg(cctrl, &rhs->res, BRT_F64, 1, bin, code_off);
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovI64F64(MIR(cctrl, 2), lhs.reg));
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovI64F64(MIR(cctrl, 1), rhs->res.reg));
    code_off = AIWNIOS_ADD_CODE(bin, code_off, bit_op(MIR(cctrl, 2), 2, 1));
    code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmovF64I64(MFR(cctrl, result.reg), 2));
  }
  code_off = ICMov(cctrl, &derefed, &result, bin, code_off);
  code_off = ICMov(cctrl, &rpn->res, &result, bin, code_off);
  if (pop2)
    code_off = TYPECAST_ASSIGN_END(cctrl, pop, &orig, bin, code_off);
  return code_off;
}
I64 __SexyAssignOp(CBCmpCtrl *cctrl, CBRPN *rpn,
                   I32 (*i_op)(I64, I64, I64),
                   I32 (*i_imm_op)(I64, I64, I64),
                   I32 (*f_op)(I64, I64, I64),
                   U8 *bin, I64 code_off) {
  CBRPN *next = ICArgN(rpn, 1), *next2, *next3, *b;
  CBICArg tmp, tmp2, derefed;
  MemSet(&tmp, 0, sizeof(CBICArg));
  MemSet(&tmp2, 0, sizeof(CBICArg));
  I64 pop, pop2;
  CBICArg _orig;
  MemSet(&derefed, 0, sizeof(CBICArg));
  I64 i = 0, const_can = 0, retry;
  next2 = b = ICArgN(rpn, 0);
  if (i_imm_op)
    if (BIsConst(b) && ARM_ERR_INV_OFF != i_imm_op(0, 0, ConstVal(b)))
      const_can = 1;
  if (const_can) {
    if (next->type == BIC_TYPECAST) {
      code_off = TYPECAST_ASSIGN_BEGIN(cctrl, &next, b, &_orig, &pop, &pop2, bin, code_off);
      MemCpy(&tmp2, &next->res, sizeof(CBICArg));
      if (tmp2.raw_type == BRT_F64)
        goto defacto;
      code_off =
          PutICArgIntoReg(cctrl, &tmp2, next->raw_type, 3, bin, code_off);
      code_off = AIWNIOS_ADD_CODE(bin, code_off, i_imm_op(MIR(cctrl, tmp2.reg), tmp2.reg, ConstVal(b)));
      code_off = ICMov(cctrl, &next->res, &tmp2, bin, code_off);
      code_off = ICMov(cctrl, &rpn->res, &tmp2, bin, code_off);
      code_off = TYPECAST_ASSIGN_END(cctrl, pop, &_orig, bin, code_off);
      return code_off;
    } else {
      if (next->raw_type == BRT_F64 || rpn->raw_type == BRT_F64)
        goto defacto2;
      code_off = DerefToICArg(cctrl, &derefed, next, 2, bin, code_off);
      MemCpy(&tmp2, &derefed, sizeof(CBICArg));
      if (!(rpn->flags & ICF_LOCK_EXPR)) {
not_lock_const:;
        code_off = PutICArgIntoReg(cctrl, &tmp2, BRT_I64i, 3, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, i_imm_op(MIR(cctrl, tmp2.reg), tmp2.reg, ConstVal(b)));
        code_off = ICMov(cctrl, &derefed, &tmp2, bin, code_off);
        code_off = ICMov(cctrl, &rpn->res, &tmp2, bin, code_off);
      } else {
        if (derefed.mode != __MD_ARM_SHIFT && derefed.mode != MD_INDIR_REG)
          goto not_lock_const;
        retry = code_off;
        code_off = ATOMIC_LOAD(cctrl, &derefed, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, i_imm_op(MIR(cctrl, 0), 0, ConstVal(b)));
        tmp2.mode = MD_REG;
        tmp2.reg = 0;
        tmp2.raw_type = BRT_I64i;
        code_off = ICMov(cctrl, &rpn->res, &tmp2, bin, code_off);
        code_off = ATOMIC_STORE(cctrl, &derefed, 0, retry, bin, code_off);
      }
    }
    return code_off;
  } else {
    if (next->type == BIC_TYPECAST) {
      code_off = TYPECAST_ASSIGN_BEGIN(cctrl, &next, b, &_orig, &pop, &pop2, bin, code_off);
defacto:
      code_off = __OptPassFinal(cctrl, next2, bin, code_off);
      code_off = PutICArgIntoReg(cctrl, &next2->res, next->raw_type, 1, bin,
                                 code_off); // 1
      MemCpy(&tmp2, &next->res, sizeof(CBICArg));
      code_off =
          PutICArgIntoReg(cctrl, &tmp2, next->raw_type, 3, bin, code_off);
      if (tmp2.raw_type == BRT_F64) {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, f_op(MFR(cctrl, tmp2.reg), tmp2.reg, b->res.reg));
      } else {
        code_off = AIWNIOS_ADD_CODE(bin, code_off, i_op(MIR(cctrl, tmp2.reg), tmp2.reg, b->res.reg));
      }
      code_off = ICMov(cctrl, &next->res, &tmp2, bin, code_off);
      code_off = ICMov(cctrl, &rpn->res, &tmp2, bin, code_off);
      code_off = TYPECAST_ASSIGN_END(cctrl, pop, &_orig, bin, code_off);
      return code_off;
    } else {
defacto2:
      if ((rpn->flags & ICF_LOCK_EXPR) && next->raw_type != BRT_F64) {
        code_off = __OptPassFinal(cctrl, next2, bin, code_off);
        code_off = DerefToICArg(cctrl, &derefed, next, 1, bin, code_off);
        code_off = PutICArgIntoReg(cctrl, &b->res, next->raw_type, 3, bin,
                                   code_off); // 1
        if (derefed.mode != __MD_ARM_SHIFT && derefed.mode != MD_INDIR_REG)
          goto normal;
        retry = code_off;
        code_off = ATOMIC_LOAD(cctrl, &derefed, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, i_op(MIR(cctrl, 0), 0, b->res.reg));
        tmp2.mode = MD_REG;
        tmp2.reg = 0;
        tmp2.raw_type = BRT_I64i;
        code_off = ICMov(cctrl, &rpn->res, &tmp2, bin, code_off);
        code_off = ATOMIC_STORE(cctrl, &derefed, 0, retry, bin, code_off);
        return code_off;
      }
      //
      code_off = __OptPassFinal(cctrl, next2, bin, code_off);
      code_off = DerefToICArg(cctrl, &derefed, next, 2, bin, code_off);
normal:;
      MemCpy(&tmp2, &derefed, sizeof(CBICArg));
      // Check if different
      if ((tmp2.raw_type == BRT_F64) ^ (b->res.raw_type == BRT_F64)) {
        code_off = PutICArgIntoReg(cctrl, &b->res, BRT_F64, 1, bin, code_off);
        code_off = PutICArgIntoReg(cctrl, &tmp2, BRT_F64, 3, bin, code_off);
        code_off = AIWNIOS_ADD_CODE(bin, code_off, f_op(MFR(cctrl, tmp2.reg), tmp2.reg, b->res.reg));
      } else {
        //                ____________
        // (o)    (o)    /            \
        //  \      /    |             |
        //   \ ___/     |    tmp2 has |
        //  / _____\    |   register 3|
        // /  \___/ \___| as fallback |
        // \ _________________________/
        //
        code_off = PutICArgIntoReg(cctrl, &b->res, next->raw_type, 1, bin,
                                   code_off); // 1
        code_off =
            PutICArgIntoReg(cctrl, &tmp2, next->raw_type, 3, bin, code_off);
        if (tmp2.raw_type == BRT_F64) {
          code_off = AIWNIOS_ADD_CODE(bin, code_off, f_op(MFR(cctrl, tmp2.reg), tmp2.reg, b->res.reg));
        } else {
          code_off = AIWNIOS_ADD_CODE(bin, code_off, i_op(MIR(cctrl, tmp2.reg), tmp2.reg, b->res.reg));
        }
      }
      code_off = ICMov(cctrl, &derefed, &tmp2, bin, code_off);
      code_off = ICMov(cctrl, &rpn->res, &tmp2, bin, code_off);
      return code_off;
    }
  }
  return code_off;
}
I64 __FMod(I64 dst, I64 a, I64 b, U8 *bin,
           I64 code_off) {
  code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fdivReg(dst, a, b));
  code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fcvtzs(0, dst));
  code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_scvtf(dst, 0));
  code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fmulReg(dst, dst, b));
  code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_fsubReg(dst, a, dst));
  return code_off;
}
// Also handles BIC_MOD_EQ
I64 __CompileMod(CBCmpCtrl *cctrl, CBRPN *rpn, U8 *bin,
                 I64 code_off) {
  CBRPN *next, *next2, *tc;
  CBICArg tmp, orig_dst, derefed, tmp2;
  MemSet(&tmp, 0, sizeof(CBICArg));
  MemSet(&orig_dst, 0, sizeof(CBICArg));
  MemSet(&derefed, 0, sizeof(CBICArg));
  MemSet(&tmp2, 0, sizeof(CBICArg));
  I64 pop, pop2;
  CBICArg _orig;
  I64 into_reg;
  next = ICArgN(rpn, 1);
  next2 = ICArgN(rpn, 0);
  if (next->type == BIC_TYPECAST && rpn->type == BIC_MOD_EQ) {
    code_off = __OptPassFinal(cctrl, next2, bin, code_off);
    code_off = TYPECAST_ASSIGN_BEGIN(cctrl, &next, next2, &_orig, &pop, &pop2, bin, code_off);
    MemCpy(&orig_dst, &tmp, sizeof(CBICArg));
    code_off = PutICArgIntoReg(cctrl, &tmp, next->raw_type, 2, bin, code_off);
    code_off =
        PutICArgIntoReg(cctrl, &next2->res, next->raw_type, 1, bin, code_off);
    if (next->raw_type == BRT_F64) {
      MFR(cctrl, 0); // See _FMOD
      code_off = __FMod(MFR(cctrl, 4), tmp.reg, next2->res.reg, bin, code_off);
      tmp.mode = MD_REG;
      tmp.raw_type = BRT_F64;
      tmp.reg = 4;
      code_off = ICMov(cctrl, &orig_dst, &tmp, bin, code_off);
      MemCpy(&rpn->tmp_res, &tmp, sizeof(CBICArg));
      if (rpn->res.keep_in_tmp)
        MemCpy(&rpn->res, &tmp, sizeof(CBICArg));
      code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
      goto tc_fin;
    }
    into_reg = 0;
    if (rpn->raw_type == BRT_U64i) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_udivX(MIR(cctrl, into_reg), tmp.reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_umullX(MIR(cctrl, into_reg), into_reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_subRegX(MIR(cctrl, into_reg), tmp.reg, into_reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_uxtwX(into_reg, into_reg)); // umull takes into account 32bit
      // operands,so I will "accomodate"
    } else {
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_sdivRegX(MIR(cctrl, into_reg), tmp.reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_mulRegX(into_reg, into_reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_subRegX(into_reg, tmp.reg, into_reg));
    }
    tmp.mode = MD_REG;
    tmp.raw_type = BRT_I64i;
    tmp.reg = into_reg;
    tmp.off = 0;
    code_off = ICMov(cctrl, &orig_dst, &tmp, bin, code_off);
    code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
tc_fin:
    code_off = TYPECAST_ASSIGN_END(cctrl, pop, &_orig, bin, code_off);
    return code_off;
  }
  if (rpn->type == BIC_MOD_EQ) {
    code_off = __OptPassFinal(cctrl, next2, bin, code_off);
    code_off = DerefToICArg(cctrl, &tmp, next, 3, bin, code_off);
    MemCpy(&orig_dst, &tmp, sizeof(CBICArg));
    code_off = PutICArgIntoReg(cctrl, &tmp, next->raw_type, 2, bin, code_off);
    code_off =
        PutICArgIntoReg(cctrl, &next2->res, next->raw_type, 1, bin, code_off);
    if (next->raw_type == BRT_F64) {
      MFR(cctrl, 0); // See __FMOD
      code_off = __FMod(MFR(cctrl, 4), tmp.reg, next2->res.reg, bin, code_off);
      tmp.mode = MD_REG;
      tmp.raw_type = BRT_F64;
      tmp.reg = 4;
      code_off = ICMov(cctrl, &orig_dst, &tmp, bin, code_off);
      MemCpy(&rpn->tmp_res, &tmp, sizeof(CBICArg));
      if (rpn->res.keep_in_tmp)
        MemCpy(&rpn->res, &tmp, sizeof(CBICArg));

      code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
      return code_off;
    }
    into_reg = 3;
    if (next->raw_type == BRT_U64i) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_udivX(MIR(cctrl, into_reg), tmp.reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_umullX(into_reg, into_reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_subRegX(into_reg, tmp.reg, into_reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_uxtwX(into_reg, into_reg)); // umull takes into account 32bit
      // operands,so I will "accomodate"
    } else {
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_sdivRegX(MIR(cctrl, into_reg), tmp.reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_mulRegX(into_reg, into_reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_subRegX(into_reg, tmp.reg, into_reg));
    }
    tmp.mode = MD_REG;
    tmp.raw_type = BRT_I64i;
    tmp.reg = into_reg;
    code_off = ICMov(cctrl, &orig_dst, &tmp, bin, code_off);
    code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
    return code_off;
  }
  code_off = __OptPassFinal(cctrl, next2, bin, code_off);
  code_off = __OptPassFinal(cctrl, next, bin, code_off);
  code_off =
      PutICArgIntoReg(cctrl, &next2->res, rpn->raw_type, 1, bin, code_off);
  code_off =
      PutICArgIntoReg(cctrl, &next->res, rpn->raw_type, 2, bin, code_off);
  if (rpn->raw_type == BRT_F64) {
    MFR(cctrl, 0); // See __FMod
    code_off =
        __FMod(MFR(cctrl, 4), next->res.reg, next2->res.reg, bin, code_off);
    tmp.mode = MD_REG;
    tmp.raw_type = BRT_F64;
    tmp.reg = 4;
  } else {
    into_reg = 3;
    tmp.reg = 3;
    tmp.raw_type = BRT_I64i;
    tmp.mode = MD_REG;
    if (rpn->raw_type == BRT_U64i) {
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_udivX(MIR(cctrl, into_reg), next->res.reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_umullX(into_reg, into_reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_subRegX(into_reg, next->res.reg, into_reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_uxtwX(into_reg, into_reg)); // umull takes into account 32bit
      // operands,so I will "accomodate"
    } else {
      code_off = AIWNIOS_ADD_CODE(bin, code_off,
                                  ARM_sdivRegX(MIR(cctrl, into_reg), next->res.reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_mulRegX(into_reg, into_reg, next2->res.reg));
      code_off = AIWNIOS_ADD_CODE(bin, code_off, ARM_subRegX(into_reg, next->res.reg, into_reg));
    }
  }
  MemCpy(&rpn->tmp_res, &tmp, sizeof(CBICArg));
  if (rpn->res.keep_in_tmp)
    MemCpy(&rpn->res, &tmp, sizeof(CBICArg));

  code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
  return code_off;
}

// This is used for FuncProlog/Epilog. It is used for finding the non-violatle
// registers that must be saved and pushed to the stack
//
// to_push is a char[32] ,1 is push,0 is not push
//
// Returns number of pushed regs
//
I64 __FindPushedIRegs(CBCmpCtrl *cctrl, U8 *to_push) {
  CBMemberLst *lst;
  CBRPN *r;
  I64 cnt = 0;
  MemSet(to_push, 0, 32);
  if (!cctrl->cur_fun) {
    // Perhaps we are being called from HolyC and we aren't using a "cur_fun"
    for (r = cctrl->code_ctrl->ir_code->next(CBRPN *); r != cctrl->code_ctrl->ir_code;
         r = r->base.next(CBRPN *)) {
      if (r->type == BIC_IREG && r->raw_type != BRT_F64) {
        if (!to_push[r->integer])
          if (BAIWNIOS_IREG_START <= r->integer)
            if (BAIWNIOS_IREG_CNT > r->integer - BAIWNIOS_IREG_START) {
              to_push[r->integer] = 1;
              cnt++;
            }
      }
    }
    return cnt;
  }
  for (lst = cctrl->cur_fun->base.members_lst; lst; lst = lst->next) {
    if (lst->reg != BREG_NONE && lst->member_class->raw_type != BRT_F64) {
      BAssert(lst->reg >= 0, "lst->reg >= 0");
      to_push[lst->reg] = 1;
      cnt++;
    }
  }
  return cnt;
}

I64 __FindPushedFRegs(CBCmpCtrl *cctrl, U8 *to_push) {
  CBMemberLst *lst;
  I64 cnt = 0;
  MemSet(to_push, 0, 32);
  CBRPN *r;
  if (!cctrl->cur_fun) {
    // Perhaps we are being called from HolyC and we aren't using a "cur_fun"
    for (r = cctrl->code_ctrl->ir_code->next(CBRPN *); r != cctrl->code_ctrl->ir_code;
         r = r->base.next(CBRPN *)) {
      if (r->type == BIC_FREG && r->raw_type == BRT_F64) {
        if (!to_push[r->integer])
          if (BAIWNIOS_FREG_START <= r->integer)
            if (BAIWNIOS_FREG_CNT > r->integer - BAIWNIOS_FREG_START) {
              to_push[r->integer] = 1;
              cnt++;
            }
      }
    }
    return cnt;
  }
  for (lst = cctrl->cur_fun->base.members_lst; lst; lst = lst->next) {
    if (lst->reg != BREG_NONE && lst->member_class->raw_type == BRT_F64) {
      BAssert(lst->reg >= 0, "lst->reg >= 0");
      to_push[lst->reg] = 1;
      cnt++;
    }
  }
  return cnt;
}
