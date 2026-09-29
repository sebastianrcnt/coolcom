// Translated from Aiwnios c/parser.c (IR construction helpers and the __HC_* bindings), aiwn_asm.h,
// aiwn_mem.h (nrootconauto, BSD-3), commit e155e87.
//
// Needs BackendA.HH.  Not translated: the C lexer/parser itself; of the parser.c helpers only those the
// backend/optpass/frontend bindings need are here (CodeCtrlPopNoFree, CodeCtrlAppend, ArrayDimDel,
// MemberLstDel and HashFunDel are parser-only and were left out).

// ------------------------------------------------ macro / builtin replacements
U0 BAssert(Bool cond, U8 *what)
{
  if (!cond) {
    Print("BAssert failed: %s\n", what);
    throw('BAsr'); //INTEGRATION: halt; no handler is expected to catch this
  }
}

//INTEGRATION: abort() of C, used for "can't happen" paths of the port.
U0 abort()
{
  Print("abort()\n");
  throw('Abrt');
}

// MemGetWritePtr/MemGetExecPtr are in BackendRT.HC (code-buffer mapping).

I64 __builtin_ffsll(I64 x)
{
  I64 i;
  if (!x)
    return 0;
  for (i = 0; i < 64; i++)
    if ((x >> i) & 1)
      return i + 1;
  return 0;
}
I64 __builtin_popcountll(I64 x)
{
  I64 i, cnt = 0;
  for (i = 0; i < 64; i++)
    if ((x >> i) & 1)
      cnt++;
  return cnt;
}
I64 __builtin_clzl(I64 x)
{
  I64 i;
  for (i = 63; i >= 0; i--)
    if ((x >> i) & 1)
      return 63 - i;
  return 64; // undefined in C
}
I64 __builtin_ctzl(I64 x)
{
  I64 i;
  for (i = 0; i < 64; i++)
    if ((x >> i) & 1)
      return i;
  return 64; // undefined in C
}
//INTEGRATION: instruction-cache maintenance after writing code (no-op until the kernel provides it)
U0 __builtin___clear_cache(U8 *begin, U8 *_end)
{
}
U0 sys_icache_invalidate(U8 *begin, I64 len)
{
}

// C: #define BETWEEN(a, min, max) ((a) >= min) && ((a) <= max)
I64 BETWEEN(I64 a, I64 min, I64 max)
{
  return (a >= min) && (a <= max);
}

// ------------------------------------------------ parser.c
CBCodeCtrl *CodeCtrlPush(CBCmpCtrl *ccmp)
{
  CBCodeCtrl *cctrl;
  cctrl = CAlloc(sizeof(CBCodeCtrl));
  cctrl->hc = ccmp->hc;
  cctrl->next = ccmp->code_ctrl;
  cctrl->ir_code = CAlloc(sizeof(CBRPN));
  cctrl->code_misc = CAlloc(sizeof(CBQue));
  cctrl->ir_code(CBRPN *)->type = BIC_NOP;
  BQueInit(cctrl->ir_code);
  BQueInit(cctrl->code_misc);
  ccmp->code_ctrl = cctrl;
  return cctrl;
}

U0 CodeCtrlDel(CBCodeCtrl *ctrl)
{
  CBCodeMisc *misc;
  for (misc = ctrl->code_misc->next; misc != ctrl->code_misc;
       misc = misc->base.next) {
    switch (misc->type) {
      case BCMT_STRING:
        Free(misc->str);
        break;
      case BCMT_RELOC_U64:
      case BCMT_LABEL:
        Free(misc->str);
        break;
      case BCMT_JMP_TAB:
        Free(misc->jmp_tab);
        break;
      case BCMT_STATIC_DATA:
        Free(misc->str);
    }
  }
  BQueDel(ctrl->ir_code);
  BQueDel(ctrl->code_misc);
  Free(ctrl);
}

CBCodeMisc *CodeMiscNew(CBCmpCtrl *ccmp, I64 type)
{
  CBCodeMisc *misc = CAlloc(sizeof(CBCodeMisc));
  misc->type = type;
  BQueIns(misc, ccmp->code_ctrl->code_misc->last);
  return misc;
}

U0 CodeCtrlPop(CBCmpCtrl *ccmp)
{
  CBCodeCtrl *next = ccmp->code_ctrl->next, *c = ccmp->code_ctrl;
  CodeCtrlDel(c);
  ccmp->code_ctrl = next;
}

//PORT-NOTE: the C function is declared to return CCmpCtrl* but has no return statement.
CBCmpCtrl *BCmpCtrlDel(CBCmpCtrl *d)
{
  BHeapCtrlDel(d->hc);
  Free(d);
  return NULL;
}

// Helper type for the `static raw_types[]` table of BCmpCtrlNew (HolyC has no static locals
// or initialised anonymous struct arrays; the table is filled on each call instead).
class CBCmpCtrlNewRawType
{
  U8 *name;
  I64 rt;
  I64 sz;
};

CBCmpCtrl *BCmpCtrlNew(CBLexer *lex)
{
  I64 idx, idx2;
  CBHashClass *cls;
  CBCmpCtrl *ccmp;
  ccmp = CAlloc(sizeof(CBCmpCtrl));
  ccmp->lex = lex;
  ccmp->hc = BHeapCtrlInit(NULL, BFs, 0);
  ccmp->final_hc = BFs->code_heap;
  CBCmpCtrlNewRawType raw_types[10];
  raw_types[0].name = "U0";   raw_types[0].rt = BRT_U0;   raw_types[0].sz = 0;
  raw_types[1].name = "U8i";  raw_types[1].rt = BRT_U8i;  raw_types[1].sz = 1;
  raw_types[2].name = "I8i";  raw_types[2].rt = BRT_I8i;  raw_types[2].sz = 1;
  raw_types[3].name = "U16i"; raw_types[3].rt = BRT_U16i; raw_types[3].sz = 2;
  raw_types[4].name = "I16i"; raw_types[4].rt = BRT_I16i; raw_types[4].sz = 2;
  raw_types[5].name = "U32i"; raw_types[5].rt = BRT_U32i; raw_types[5].sz = 4;
  raw_types[6].name = "I32i"; raw_types[6].rt = BRT_I32i; raw_types[6].sz = 4;
  raw_types[7].name = "U64i"; raw_types[7].rt = BRT_U64i; raw_types[7].sz = 8;
  raw_types[8].name = "I64i"; raw_types[8].rt = BRT_I64i; raw_types[8].sz = 8;
  raw_types[9].name = "F64";  raw_types[9].rt = BRT_F64;  raw_types[9].sz = 8;
  for (idx = 0; idx != 10 /* entries in raw_types; the C bootstrap compiler only takes sizeof(type) */; idx++) {
    if (!BHashFind(raw_types[idx].name, BFs->hash_table, BHTT_CLASS, 1)) {
      cls = CAlloc(sizeof(CBHashClass) * STAR_CNT);
      cls->base.type = BHTT_CLASS;
      cls->sz = raw_types[idx].sz;
      for (idx2 = 0; idx2 != STAR_CNT; idx2++) {
        cls[idx2].base.str = StrNew(raw_types[idx].name);
        if (!idx2) {
          cls[idx2].raw_type = raw_types[idx].rt;
          cls[idx2].sz = raw_types[idx].sz;
        } else {
          cls[idx2].raw_type = BRT_PTR;
          cls[idx2].sz = 8; // sizeof(void *)
        }
        cls[idx2].ptr_star_cnt = idx2;
        cls[idx2].use_cnt++;
      }
      BHashAdd(cls, BFs->hash_table);
      cls = CAlloc(sizeof(CBHashClass) * STAR_CNT);
      cls->base.type = BHTT_CLASS;
      cls->sz = raw_types[idx].sz;
      for (idx2 = 0; idx2 != STAR_CNT; idx2++) {
        cls[idx2].base.str = StrNew(raw_types[idx].name);
        if (!idx2) {
          cls[idx2].raw_type = raw_types[idx].rt;
          cls[idx2].sz = raw_types[idx].sz;
        } else {
          cls[idx2].raw_type = BRT_PTR;
          cls[idx2].sz = 8; // sizeof(void *)
        }
        cls[idx2].ptr_star_cnt = idx2;
        cls[idx2].use_cnt++;
      }
      BHashAdd(cls, BFs->hash_table);
    }
  }
  return ccmp;
}

CBRPN *ICFwd(CBRPN *rpn)
{
  CBRPN *orig_rpn = rpn;
  I64 idx;
  if (rpn->ic_fwd)
    return rpn->ic_fwd;
  switch (rpn->type) {
    case BIC_GS:
    case BIC_FS:
      goto unop;
    case BIC_LOCK:
    case BIC_RAW_BYTES:
    case __IC_STATICS_SIZE:
    case __IC_SET_STATIC_DATA:
    case __IC_STATIC_REF:
      return rpn->base.next;
      break;
    case BIC_SHORT_ADDR:
    case BIC_RELOC:
      return rpn->base.next;
      break;
    case BIC_GET_VARGS_PTR:
    case BIC_TO_F64:
    case BIC_TO_I64:
    case BIC_TO_BOOL:
      goto unop;
      break;
    case BIC_GOTO_IF:
      goto unop;
      break;
    case BIC_STATIC:
      return rpn->base.next;
      break;
    case BIC_TYPECAST:
      goto unop;
      break;
    case BIC_COMMA:
    case BIC_MAX_F64:
    case BIC_MAX_U64:
    case BIC_MAX_I64:
    case BIC_MIN_F64:
    case BIC_MIN_U64:
    case BIC_MIN_I64:
      goto binop;
      break;
    case __IC_VARGS:
      rpn = rpn->base.next;
      // Args
      for (idx = 0; idx != orig_rpn->length; idx++)
        rpn = ICFwd(rpn);
      return rpn;
      break;
    case __IC_CALL:
    case BIC_CALL:
      rpn = rpn->base.next;
      // Args
      for (idx = 0; idx != orig_rpn->length; idx++)
        rpn = ICFwd(rpn);
      // Function
      rpn = ICFwd(rpn);
      return rpn;
      break;
    case BIC_BASE_PTR:
      return rpn->base.next;
      break;
    case BIC_IREG:
      return rpn->base.next;
      break;
    case BIC_FREG:
      return rpn->base.next;
      break;
    case BIC_LOAD:
      goto binop;
      break;
    case BIC_STORE:
      goto binop;
      break;
    case BIC_RET:
      return ICFwd(rpn->base.next);
      break;
    case BIC_LABEL:
      return rpn->base.next;
      break;
    case BIC_GOTO:
      return rpn->base.next;
      break;
    case BIC_GLOBAL:
      return rpn->base.next;
      break;
    case BIC_LOCAL:
      return rpn->base.next;
      break;
    case BIC_NOP:
      return rpn->base.next;
      break;
    case BIC_BOUNDED_SWITCH:
      goto swit;
      break;
    case BIC_UNBOUNDED_SWITCH:
swit:
      return ICFwd(rpn->base.next);
      break;
    case BIC_SUB_CALL:
      return rpn->base.next;
      break;
    case BIC_SUB_PROLOG:
      return rpn->base.next;
      break;
    case BIC_SUB_RET:
      return rpn->base.next;
      break;
    case BIC_PAREN:
      abort();
      break;
    case BIC_NEG:
    case BIC_SQRT:
unop:
      return ICFwd(rpn->base.next);
      break;
    case BIC_SQR:
    case BIC_POS:
      goto unop;
      break;
    case BIC_NAME:
      return rpn->base.next;
      break;
    case BIC_STR:
      return rpn->base.next;
      break;
    case BIC_CHR:
      return rpn->base.next;
      break;
    case BIC_POW:
binop:
      return ICFwd(ICFwd(rpn->base.next));
      break;
    case BIC_ADD:
      goto binop;
      break;
    case BIC_BT:
    case BIC_BTR:
    case BIC_BTS:
    case BIC_BTC:
    case BIC_LBTR:
    case BIC_LBTS:
    case BIC_LBTC:
    case BIC_EQ:
      goto binop;
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
    case __IC_ARG:
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
      goto unop;
      break;
    case BIC_POST_DEC:
      goto unop;
      break;
    case BIC_PRE_INC:
      goto unop;
      break;
    case BIC_PRE_DEC:
      goto unop;
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
    case BIC_ARROW:
      goto unop;
      break;
    case BIC_DOT:
      goto unop;
      break;
    case BIC_MOD_EQ:
      goto binop;
      break;
    case BIC_I64:
      return rpn->base.next;
      break;
    case __IC_SET_FRAME_SIZE:
    case BIC_F64:
      return rpn->base.next;
      break;
    case BIC_ARRAY_ACC:
      goto binop;
  }
  abort();
}

CBRPN *ICArgN(CBRPN *rpn, I64 n)
{
  if (n == 1 && rpn->tree1)
    return rpn->tree1;
  if (n == 2 && rpn->tree2)
    return rpn->tree2;
  rpn = rpn->base.next;
  while (--n >= 0)
    rpn = ICFwd(rpn);
  return rpn;
}

I64 BAssignRawTypeToNode(CBCmpCtrl *ccmp, CBRPN *rpn)
{
  I64 a, b, arg;
  CBMemberLst *mlst;
  CBHashFun *fun;
  U8 *name;
  CBRPN *orig_rpn = rpn;
  if (rpn->raw_type)
    return rpn->raw_type;
  switch (rpn->type) {
    case BIC_SQRT:
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 0));
      rpn->ic_class = BHashFind("F64", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = BRT_F64;
      return rpn->raw_type;
      break;
    case BIC_MAX_I64:
    case BIC_MIN_I64:
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 0));
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 1));
      rpn->ic_class = BHashFind("I64i", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = BRT_I64i;
      return rpn->raw_type;
      break;
    case BIC_MIN_U64:
    case BIC_MAX_U64:
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 0));
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 1));
      rpn->ic_class = BHashFind("U64i", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = BRT_U64i;
      return rpn->raw_type;
      break;
    case BIC_MIN_F64:
    case BIC_MAX_F64:
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 0));
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 1));
      rpn->ic_class = BHashFind("F64", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = BRT_F64;
      return rpn->raw_type;
      break;
    case BIC_FS:
    case BIC_GS:
      rpn->ic_class = BHashFind("I64i", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = BRT_I64i;
      return rpn->raw_type;
      break;
    case BIC_LOCK: // Lock means "lock *ptr++;",it operates on expressions as a
      // whole
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 0));
      rpn->raw_type = BRT_U0; // dummy
      return rpn->raw_type;
      break;
    case BIC_BT:
    case BIC_BTR:
    case BIC_BTS:
    case BIC_BTC:
    case BIC_LBTR:
    case BIC_LBTS:
    case BIC_LBTC:
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 1));
      BAssignRawTypeToNode(ccmp, ICArgN(rpn, 0));
      rpn->ic_class = BHashFind("I64i", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = BRT_I64i;
      return rpn->raw_type;
      break;
    case BIC_SHORT_ADDR:
    case BIC_RELOC:
      rpn->ic_class = BHashFind("U8i", BFs->hash_table, BHTT_CLASS, 1);
      rpn->ic_class++;
      rpn->raw_type = BRT_PTR;
      return rpn->raw_type;
      break;
    case __IC_VARGS:
      rpn->ic_class = BHashFind("I64i", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = BRT_I64i;
      return rpn->raw_type;
      break;
    case BIC_TO_BOOL:
      BAssignRawTypeToNode(ccmp, rpn->base.next);
      // Falls through to IC_TO_I64
    case BIC_TO_I64:
      rpn->ic_class = BHashFind("I64i", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = BRT_I64i;
      return rpn->raw_type;
      break;
    case BIC_TO_F64:
      rpn->ic_class = BHashFind("F64", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = BRT_F64;
      return rpn->raw_type;
      break;
    case BIC_TYPECAST:
      rpn->raw_type = rpn->ic_class->raw_type;
      return rpn->raw_type;
      break;
    case __IC_CALL:
      rpn = orig_rpn->base.next;
      for (arg = 0; arg != orig_rpn->length + 1; arg++) {
        if (rpn->type != BIC_NOP)
          BAssignRawTypeToNode(ccmp, rpn);
        rpn = ICFwd(rpn);
      }
      //PORT-NOTE: C stores the ic_class *pointer* into the 16 bit raw_type of the node that
      // follows the call (`rpn` was advanced by the loop); translated as is.
      rpn->raw_type = rpn->ic_class;
      return rpn->raw_type;
    case BIC_CALL:
      rpn = orig_rpn->base.next;
      for (arg = 0; arg != orig_rpn->length; arg++) {
        if (rpn->type != BIC_NOP)
          BAssignRawTypeToNode(ccmp, rpn);
        rpn = ICFwd(rpn);
      }
      if (BRT_PTR == BAssignRawTypeToNode(ccmp, rpn)) {
        if (rpn->ic_class->ptr_star_cnt > 1)
          ParseErr(ccmp, "Can't call this pointer."); // TODO add type name
      }
      fun = rpn->ic_fun;
got_fun:
      if (!fun)
        ParseErr(ccmp, "Invalid type to call."); // TODO add type name
      if (arg > fun->argc && !(fun->base.flags & CLSF_VARGS)) {
        ParseErr(ccmp, "Excess arguments for function");
      }
      mlst = fun->base.members_lst;
      rpn = orig_rpn->base.next;
      for (arg = 0; arg != orig_rpn->length; arg++) {
        if (arg >= fun->argc)
          break;
        rpn = ICArgN(orig_rpn, orig_rpn->length - arg - 1);
        if (rpn->type == BIC_NOP)
          if (!(mlst->flags & BMLF_DFT_AVAILABLE)) {
            ParseErr(ccmp, "No default value for argument %d.", arg);
          }
        mlst = mlst->next;
      }
      for (; arg < fun->argc; arg++) {
        if (fun->base.flags & CLSF_VARGS && arg >= fun->argc - 2)
          break;
        if (!(mlst->flags & BMLF_DFT_AVAILABLE)) {
          ParseErr(ccmp, "No default value for argument %d.", arg);
        }
        mlst = mlst->next;
      }
      orig_rpn->ic_class = fun->return_class;
      orig_rpn->ic_dim = NULL;
      orig_rpn->raw_type = orig_rpn->ic_class->raw_type;
      break;
    case BIC_COMMA:
      BAssignRawTypeToNode(ccmp, rpn->base.next);
      BAssignRawTypeToNode(ccmp, ICFwd(rpn->base.next));
      rpn->ic_class = rpn->base.next(CBRPN *)->ic_class;
      rpn->ic_dim = rpn->base.next(CBRPN *)->ic_dim;
      rpn->ic_fun = rpn->base.next(CBRPN *)->ic_fun;
      rpn->raw_type = rpn->base.next(CBRPN *)->raw_type;
      return rpn->raw_type;
      break;
    case BIC_GLOBAL:
      if (rpn->global_var->base.type & BHTT_GLBL_VAR) {
        rpn->ic_class = rpn->global_var->var_class;
        rpn->ic_dim = rpn->global_var->dim.next;
        rpn->ic_fun = rpn->global_var->fun_ptr;
        rpn->raw_type = rpn->ic_class->raw_type;
        return rpn->raw_type;
      } else if (rpn->global_var->base.type & BHTT_FUN) {
        fun = rpn->global_var;
        rpn->ic_class = &fun->base;
        rpn->ic_dim = NULL;
        rpn->ic_fun = fun;
        return BRT_FUNC;
      }
      abort();
      break;
    case BIC_LOCAL:
      rpn->ic_class = rpn->local_mem->member_class;
      rpn->ic_dim = rpn->local_mem->dim.next;
      rpn->ic_fun = rpn->local_mem->fun_ptr;
      rpn->raw_type = rpn->ic_class->raw_type;
      return rpn->raw_type;
      break;
    case BIC_NEG:
unop:
      BAssignRawTypeToNode(ccmp, rpn->base.next);
      if (BETWEEN(rpn->base.next(CBRPN *)->raw_type, BRT_I8i, BRT_U32i)) {
        // Promote to 64bit
        rpn->raw_type = BRT_I64i;
      } else {
        rpn->raw_type = rpn->base.next(CBRPN *)->raw_type;
        rpn->ic_class = rpn->base.next(CBRPN *)->ic_class;
        rpn->ic_fun = rpn->base.next(CBRPN *)->ic_fun;
        rpn->ic_dim = NULL;
      }
      goto ret;
      break;
    case BIC_POS:
      goto unop;
      break;
    case BIC_NAME:
      abort();
      break;
    case BIC_STR:
      rpn->raw_type = BRT_PTR;
      goto ret;
      break;
    case BIC_CHR:
      rpn->raw_type = BRT_U64i;
      goto ret;
      break;
    case BIC_POW:
      rpn->raw_type = BRT_F64;
      goto ret;
      break;
    case BIC_ADD:
      a = BAssignRawTypeToNode(ccmp, ICFwd(rpn->base.next));
      b = BAssignRawTypeToNode(ccmp, rpn->base.next);
      if (a == BRT_PTR || b == BRT_PTR) {
        if (a == BRT_PTR) {
          rpn->raw_type = BRT_PTR;
          rpn->ic_class = ICFwd(rpn->base.next)->ic_class;
          rpn->ic_dim = ICFwd(rpn->base.next)->ic_dim;
          rpn->ic_fun = ICFwd(rpn->base.next)->ic_fun;
        } else {
          rpn->raw_type = BRT_PTR;
          rpn->ic_class = rpn->base.next(CBRPN *)->ic_class;
          rpn->ic_fun = rpn->base.next(CBRPN *)->ic_fun;
          rpn->ic_dim = rpn->base.next(CBRPN *)->ic_dim;
        }
        return rpn->raw_type;
      } else if (BETWEEN(a, BRT_I8i, BRT_U32i) && BETWEEN(a, BRT_I8i, BRT_U32i)) {
        // Promote to I64i
        a = BRT_I64i;
      }
      if (a > b)
        rpn->raw_type = a;
      else
        rpn->raw_type = b;
      goto ret;
      break;
    case BIC_EQ:
      goto abinop;
      break;
    case BIC_SUB:
      a = BAssignRawTypeToNode(ccmp, ICFwd(rpn->base.next));
      b = BAssignRawTypeToNode(ccmp, rpn->base.next);
      // PTR-idx
      if (a == BRT_PTR) {
        rpn->raw_type = BRT_PTR;
        rpn->ic_class = ICFwd(rpn->base.next)->ic_class;
        rpn->ic_dim = ICFwd(rpn->base.next)->ic_dim;
        rpn->ic_fun = ICFwd(rpn->base.next)->ic_fun;
        return rpn->raw_type;
      } else if (BETWEEN(a, BRT_I8i, BRT_U32i) && BETWEEN(a, BRT_I8i, BRT_U32i)) {
        // Promote to I64i
        a = BRT_I64i;
      }
      if (a > b)
        rpn->raw_type = a;
      else
        rpn->raw_type = b;
      goto ret;
      break;
    case BIC_DIV:
binop:
      a = BAssignRawTypeToNode(ccmp, ICFwd(rpn->base.next));
      b = BAssignRawTypeToNode(ccmp, rpn->base.next);
      if (BETWEEN(a, BRT_I8i, BRT_U32i) && BETWEEN(b, BRT_I8i, BRT_U32i)) {
        // Promote to I64i
        a = BRT_I64i;
      }
      if (a > b)
        rpn->raw_type = a;
      else
        rpn->raw_type = b;
      goto ret;
      break;
    case BIC_MUL:
      goto binop;
      break;
    case BIC_DEREF:
      BAssignRawTypeToNode(ccmp, rpn->base.next);
      if (!rpn->base.next(CBRPN *)->ic_class->ptr_star_cnt) {
        ParseErr(ccmp, "Can't derefernce a non-pointer/array.");
        return 0;
      }
      rpn->ic_dim = rpn->base.next(CBRPN *)->ic_dim;
      rpn->ic_fun = rpn->base.next(CBRPN *)->ic_fun;
      if (!rpn->ic_dim)
        goto no_dim;
      if (!rpn->ic_dim->next) {
no_dim:
        rpn->ic_class = rpn->base.next(CBRPN *)->ic_class - 1;
      } else {
        rpn->ic_dim = rpn->ic_dim->next;
      }
      rpn->raw_type = rpn->ic_class->raw_type;
      return rpn->raw_type;
      break;
    case BIC_AND:
      goto binop;
      break;
    case BIC_SQR:
      BAssignRawTypeToNode(ccmp, rpn->base.next);
      rpn->ic_class = BHashFind("F64", BFs->hash_table, BHTT_CLASS, 1);
      rpn->raw_type = rpn->ic_class->raw_type;
      return rpn->raw_type;
      break;
    case BIC_DOT:
      BAssignRawTypeToNode(ccmp, rpn->base.next);
      if (rpn->base.next(CBRPN *)->ic_class->ptr_star_cnt ||
          rpn->base.next(CBRPN *)->ic_dim) {
        ParseErr(ccmp, "Must not be a pointer to use a '.' operator.");
        return 0;
      }
      rpn->ic_class = rpn->local_mem->member_class;
      rpn->ic_dim = rpn->local_mem->dim.next;
      rpn->ic_fun = rpn->local_mem->fun_ptr;
      rpn->raw_type = rpn->ic_class->raw_type;
      return rpn->raw_type;
      break;
    case BIC_ADDR_OF:
      BAssignRawTypeToNode(ccmp, rpn->base.next);
      if (rpn->base.next(CBRPN *)->ic_class->ptr_star_cnt >= STAR_CNT) {
        ParseErr(ccmp, "Too many pointer stars.");
        return 0;
      }
      if (rpn->base.next(CBRPN *)->ic_dim) {
        rpn->ic_class = rpn->base.next(CBRPN *)->ic_class;
        rpn->ic_dim = rpn->base.next(CBRPN *)->ic_dim;
      } else {
        rpn->ic_class = rpn->base.next(CBRPN *)->ic_class;
        if (rpn->ic_class->raw_type == BRT_FUNC)
          rpn->ic_class = BHashFind("U8i", BFs->hash_table, BHTT_CLASS, 1);
        rpn->ic_class++;
      }
      rpn->ic_fun = rpn->base.next(CBRPN *)->ic_fun;
      rpn->raw_type = BRT_PTR;
      return rpn->raw_type;
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
      rpn->raw_type = BRT_I64i;
      goto ret;
      break;
    case BIC_GT:
      rpn->raw_type = BRT_I64i;
      goto ret;
      break;
    case BIC_LNOT:
      rpn->raw_type = BRT_I64i;
      goto ret;
      break;
    case BIC_BNOT:
      goto unop;
      break;
    case BIC_POST_INC:
      goto unop;
      break;
    case BIC_POST_DEC:
      goto unop;
      break;
    case BIC_PRE_INC:
      goto unop;
      break;
    case BIC_PRE_DEC:
      goto unop;
      break;
    case BIC_AND_AND:
cmp_rt:  // "cmp" trips the C bootstrap compiler
      rpn->raw_type = BRT_I64i;
      goto ret;
      break;
    case BIC_OR_OR:
      goto cmp_rt;
      break;
    case BIC_XOR_XOR:
      goto cmp_rt;
      break;
    case BIC_EQ_EQ:
      goto cmp_rt;
      break;
    case BIC_NE:
      goto cmp_rt;
      break;
    case BIC_LE:
      goto cmp_rt;
      break;
    case BIC_GE:
      goto cmp_rt;
      break;
    case BIC_LSH:
      goto binop;
      break;
    case BIC_RSH:
      goto binop;
      break;
    case BIC_ADD_EQ:
abinop:
      BAssignRawTypeToNode(ccmp, rpn->base.next);
      BAssignRawTypeToNode(ccmp, ICFwd(rpn->base.next));
      rpn->ic_class = ICFwd(rpn->base.next)->ic_class;
      rpn->ic_fun = ICFwd(rpn->base.next)->ic_fun;
      rpn->ic_dim = ICFwd(rpn->base.next)->ic_dim;
      rpn->raw_type = rpn->ic_class->raw_type;
      return rpn->raw_type;
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
    case BIC_ARROW:
      BAssignRawTypeToNode(ccmp, rpn->base.next);
      rpn->ic_class = rpn->local_mem->member_class;
      rpn->ic_fun = rpn->local_mem->fun_ptr;
      rpn->ic_dim = rpn->local_mem->dim.next;
      rpn->raw_type = rpn->ic_class->raw_type;
      return rpn->raw_type;
      break;
    case BIC_MOD_EQ:
      goto abinop;
      break;
    case BIC_I64:
      rpn->raw_type = BRT_I64i;
      goto ret;
      break;
    case BIC_F64:
      rpn->raw_type = BRT_F64;
      goto ret;
      break;
    case BIC_ARRAY_ACC:
      b = BAssignRawTypeToNode(ccmp, rpn->base.next);
      a = BAssignRawTypeToNode(ccmp, ICFwd(rpn->base.next));
      if (ICFwd(rpn->base.next)->ic_class->ptr_star_cnt == 0 &&
          !ICFwd(rpn->base.next)->ic_dim) {
        ParseErr(ccmp, "Expected a pointer or array type for array access.");
        return 0;
      }
      if (ICFwd(rpn->base.next)->ic_dim) {
        rpn->ic_class = ICFwd(rpn->base.next)->ic_class;
        rpn->ic_dim = ICFwd(rpn->base.next)->ic_dim->next;
      } else
        rpn->ic_class = ICFwd(rpn->base.next)->ic_class - 1;
      rpn->ic_fun = ICFwd(rpn->base.next)->ic_fun;
      rpn->raw_type = rpn->ic_class->raw_type;
      return rpn->raw_type;
  }
ret:
  switch (rpn->raw_type) {
    case BRT_U0:
      name = "U0";
      break;
    case BRT_I8i:
      name = "I8i";
      break;
    case BRT_U8i:
      name = "U8i";
      break;
    case BRT_I16i:
      name = "I16i";
      break;
    case BRT_U16i:
      name = "U16i";
      break;
    case BRT_I32i:
      name = "I32i";
      break;
    case BRT_U32i:
      name = "U32i";
      break;
    case BRT_I64i:
      name = "I64i";
      break;
    case BRT_U64i:
      name = "U64i";
      break;
    case BRT_F64:
      name = "F64";
      break;
    case BRT_PTR:
      if (rpn->ic_class)
        return rpn->raw_type;
      else
        name = "U8i";
      break;
    default:
      return 0;
  }
  rpn->ic_class = BHashFind(name, BFs->hash_table, BHTT_CLASS, 1);
  if (rpn->raw_type == BRT_PTR)
    rpn->ic_class++;
  return rpn->raw_type;
}

U0 ICFree(CBRPN *ic)
{
  BQueRem(ic);
  Free(ic);
}

//
// Nroot here,im about to make bindings for the IR stuff
//
// C: #define HC_IC_BINDING(name, op) -- expanded by hand, one function per opcode.
CBRPN *__HC_ICAdd_Sqr(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_SQR;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Lock(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LOCK;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Pow(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_POW;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Eq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Div(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_DIV;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Sqrt(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_SQRT;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Sub(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_SUB;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Mul(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MUL;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Add(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_ADD;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Comma(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_COMMA;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Addr(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_ADDR_OF;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Xor(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_XOR;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Mod(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MOD;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Or(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_OR;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Lt(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LT;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Gt(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_GT;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Le(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LE;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Ge(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_GE;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_LNot(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LNOT;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_BNot(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_BNOT;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_AndAnd(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_AND_AND;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_OrOr(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_OR_OR;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_XorXor(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_XOR_XOR;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_EqEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_EQ_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Ne(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_NE;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Lsh(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LSH;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Rsh(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_RSH;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Neg(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_NEG;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_And(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_AND;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Ret(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_RET;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_SetFrameSize(CBCodeCtrl *cc, I64 arg)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = __IC_SET_FRAME_SIZE;
  rpn->integer = arg;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Arg(CBCodeCtrl *cc, I64 arg)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = __IC_ARG;
  rpn->integer = arg;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_PostInc(CBCodeCtrl *cc, I64 amt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_POST_INC;
  rpn->integer = amt;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_PostDec(CBCodeCtrl *cc, I64 amt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_POST_DEC;
  rpn->integer = amt;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_PreInc(CBCodeCtrl *cc, I64 amt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_PRE_INC;
  rpn->integer = amt;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_PreDec(CBCodeCtrl *cc, I64 amt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_PRE_DEC;
  rpn->integer = amt;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_AddEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_ADD_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_SubEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_SUB_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_MulEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MUL_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_DivEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_DIV_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_LshEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LSH_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_RshEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_RSH_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_AndEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_AND_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_OrEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_OR_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_XorEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_XOR_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_ModEq(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MOD_EQ;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_ToI64(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_TO_I64;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_ToF64(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_TO_F64;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Min_I64(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MIN_I64;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Max_I64(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MAX_I64;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Min_U64(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MIN_U64;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Max_U64(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MAX_U64;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Min_F64(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MIN_F64;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Max_F64(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_MAX_F64;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_I64(CBCodeCtrl *cc, I64 integer)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_I64;
  rpn->integer = integer;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_F64(CBCodeCtrl *cc, F64 f)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_F64;
  rpn->flt = f;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Switch(CBCodeCtrl *cc, CBCodeMisc *misc, CBCodeMisc *dft)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_BOUNDED_SWITCH;
  rpn->code_misc = misc;
  misc->dft_lab = dft;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
// The frontend imports the bounded switch under this name (main.c: STK___HC_ICAdd_Switch).
CBRPN *__HC_ICAdd_BoundedSwitch(CBCodeCtrl *cc, CBCodeMisc *misc, CBCodeMisc *dft)
{
  return __HC_ICAdd_Switch(cc, misc, dft);
}
CBRPN *__HC_ICAdd_UnboundedSwitch(CBCodeCtrl *cc, CBCodeMisc *misc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_UNBOUNDED_SWITCH;
  rpn->code_misc = misc;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_SubRet(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_SUB_RET;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_SubProlog(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_SUB_PROLOG;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_SubCall(CBCodeCtrl *cc, CBCodeMisc *cm)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_SUB_CALL;
  rpn->code_misc = cm;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
//INTEGRATION: rt2cls relies on BHashFind() returning the first of STAR_CNT consecutive
// CBHashClass entries (one per pointer depth), so `ic_class + ptr_cnt` is the pointer class.
// This needs the kernel's class table to use the CBHashClass layout.
CBHashClass *rt2cls(I64 rt, I64 ptr_cnt)
{
  CBHashClass *ic_class;
  switch (rt) {
    case 3:
      ic_class = BHashFind("U0", BFs->hash_table, BHTT_CLASS, 1);
      break;
    case 5:
      ic_class = BHashFind("U8i", BFs->hash_table, BHTT_CLASS, 1);
      break;
    case 4:
      ic_class = BHashFind("I8i", BFs->hash_table, BHTT_CLASS, 1);
      break;
    case 7:
      ic_class = BHashFind("U16i", BFs->hash_table, BHTT_CLASS, 1);
      break;
    case 6:
      ic_class = BHashFind("I16i", BFs->hash_table, BHTT_CLASS, 1);
      break;
    case 9:
      ic_class = BHashFind("U32i", BFs->hash_table, BHTT_CLASS, 1);
      break;
    case 8:
      ic_class = BHashFind("I32i", BFs->hash_table, BHTT_CLASS, 1);
      break;
    case 11:
      ic_class = BHashFind("U64i", BFs->hash_table, BHTT_CLASS, 1);
      break;
    case 10:
      ic_class = BHashFind("I64i", BFs->hash_table, BHTT_CLASS, 1);
      break;
    case 14:
      ic_class = BHashFind("F64", BFs->hash_table, BHTT_CLASS, 1);
      break;
    default:
      ic_class = BHashFind("I64i", BFs->hash_table, BHTT_CLASS, 1);
  }
  return ic_class + ptr_cnt;
}
CBRPN *__HC_ICAdd_ShortAddr(CBCmpCtrl *acc, CBCodeCtrl *cc, U8 *name, CBCodeMisc *ptr)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_SHORT_ADDR;
  rpn->code_misc = ptr;
  ptr->type = BCMT_SHORT_ADDR;
  rpn->ic_class = BHashFind("U8i", BFs->hash_table, BHTT_CLASS, 1);
  rpn->ic_class++;
  rpn->raw_type = BRT_PTR;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Deref(CBCodeCtrl *cc, I64 rt, I64 ptr_cnt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_DEREF;
  rpn->ic_class = rt2cls(rt, ptr_cnt);
  rpn->raw_type = rpn->ic_class->raw_type;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_Call(CBCodeCtrl *cc, I64 arity, I64 rt, I64 ptr_cnt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = __IC_CALL;
  rpn->length = arity;
  rpn->ic_class = rt2cls(rt, ptr_cnt);
  rpn->raw_type = rpn->ic_class->raw_type;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_FReg(CBCodeCtrl *cc, I64 r)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_FREG;
  rpn->integer = r;
  rpn->ic_class = BHashFind("F64", BFs->hash_table, BHTT_CLASS, 1);
  rpn->raw_type = BRT_F64;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_IReg(CBCodeCtrl *cc, I64 r, I64 rt, I64 ptr_cnt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_IREG;
  rpn->integer = r;
  rpn->ic_class = rt2cls(rt, ptr_cnt);
  if (ptr_cnt)
    rt = BRT_PTR;
  rpn->raw_type = rpn->ic_class->raw_type;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_Frame(CBCodeCtrl *cc, I64 off, I64 rt, I64 ptr_cnt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_BASE_PTR;
  rpn->integer = off;
  rpn->ic_class = rt2cls(rt, ptr_cnt);
  if (ptr_cnt)
    rt = BRT_PTR;
  rpn->raw_type = rpn->ic_class->raw_type;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Typecast(CBCodeCtrl *cc, I64 rt, I64 ptr_cnt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_TYPECAST;
  rpn->ic_class = rt2cls(rt, ptr_cnt);
  if (ptr_cnt)
    rt = BRT_PTR;
  rpn->raw_type = rpn->ic_class->raw_type;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBCmpCtrl *__HC_CmpCtrlNew()
{
  return BCmpCtrlNew(NULL);
}
// Imported by the frontend as __HC_CmpCtrlDel (main.c: STK_CmpCtrlDel -> BCmpCtrlDel).
CBCmpCtrl *__HC_CmpCtrlDel(CBCmpCtrl *d)
{
  return BCmpCtrlDel(d);
}
// Imported by the frontend but has no C implementation.
U0 __HC_CmpCtrlSetRip(CBCmpCtrl *cc, I64 rip)
{
}
CBCodeCtrl *__HC_CodeCtrlPush(CBCmpCtrl *ccmp)
{
  return CodeCtrlPush(ccmp);
}
//PORT-NOTE: the C function is declared to return CCodeCtrl* but never returns; the frontend imports it as U0.
U0 __HC_CodeCtrlPop(CBCmpCtrl *ccmp)
{
  CodeCtrlPop(ccmp);
}
U8 *__HC_Compile(CBCmpCtrl *ccmp, I64 *sz=NULL, U8 **dbg_info=NULL, CBHeapCtrl *h)
{
  return Compile(ccmp, sz, dbg_info, h);
}
CBCodeMisc *__HC_CodeMiscLabelNew(CBCmpCtrl *ccmp, U8 **patch_addr=NULL)
{
  CBCodeMisc *misc;
  misc = CodeMiscNew(ccmp, BCMT_LABEL);
  misc->patch_addr = patch_addr;
  return misc;
}
CBCodeMisc *__HC_CodeMiscStrNew(CBCmpCtrl *ccmp, U8 *str, I64 sz)
{
  CBCodeMisc *misc;
  misc = CodeMiscNew(ccmp, BCMT_STRING);
  misc->str = CAlloc(sz + 1);
  MemCpy(misc->str, str, sz);
  misc->str_len = sz;
  return misc;
}
CBCodeMisc *__HC_CodeMiscJmpTableNew(CBCmpCtrl *ccmp, CBCodeMisc *labels, U8 **table_address, I64 hi)
{
  CBCodeMisc *misc = CodeMiscNew(ccmp, BCMT_JMP_TAB);
  misc->jmp_tab = CAlloc((hi - 0) * 8);
  MemCpy(misc->jmp_tab, labels, (hi - 0) * 8);
  misc->hi = hi - 1;
  misc->lo = 0;
  misc->patch_addr = table_address;
  return misc;
}

CBRPN *__HC_ICAdd_Label(CBCodeCtrl *cc, CBCodeMisc *misc)
{
  CBRPN *rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_NOP;
  // Label must consume something
  BQueIns(rpn, cc->ir_code);
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LABEL;
  rpn->code_misc = misc;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_Goto(CBCodeCtrl *cc, CBCodeMisc *cm)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_GOTO;
  rpn->code_misc = cm;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_GotoIf(CBCodeCtrl *cc, CBCodeMisc *cm)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_GOTO_IF;
  rpn->code_misc = cm;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_RawBytes(CBCodeCtrl *cc, U8 *bytes, I64 cnt)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_RAW_BYTES;
  rpn->length = cnt;
  rpn->raw_bytes = CAlloc(cnt);
  MemCpy(rpn->raw_bytes, bytes, cnt);
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_Vargs(CBCodeCtrl *cc, I64 arity)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = __IC_VARGS;
  rpn->length = arity;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_Str(CBCodeCtrl *cc, CBCodeMisc *cm)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_STR;
  rpn->code_misc = cm;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBCodeMisc *AddRelocMisc(CBCmpCtrl *cctrl, U8 *name)
{
  CBCodeMisc *reloc, *head = cctrl->code_ctrl->code_misc;
  for (reloc = head->base.next; reloc != head; reloc = reloc->base.next) {
    if (reloc->type == BCMT_RELOC_U64) {
      if (!StrCmp(reloc->str, name))
        return reloc;
    }
  }
  reloc = CodeMiscNew(cctrl, BCMT_RELOC_U64);
  reloc->str = StrNew(name);
  return reloc;
}
U0 __HC_ICSetLine(CBRPN *r, I64 ln)
{
  r->ic_line = ln;
}

CBRPN *__HC_ICAdd_Reloc(CBCmpCtrl *cmpc, CBCodeCtrl *cc, I64 *pat_addr, U8 *sym, I64 rt, I64 ptrs)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_RELOC;
  rpn->ic_class = rt2cls(rt, ptrs);
  rpn->code_misc = AddRelocMisc(cmpc, sym);
  rpn->code_misc->patch_addr = pat_addr;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_RelocUnqiue(CBCmpCtrl *cmpc, CBCodeCtrl *cc, I64 *pat_addr, U8 *sym, I64 rt, I64 ptrs)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_RELOC;
  rpn->ic_class = rt2cls(rt, ptrs);
  rpn->code_misc = CodeMiscNew(cmpc, BCMT_RELOC_U64);
  rpn->code_misc->patch_addr = pat_addr;
  rpn->code_misc->str = StrNew(sym);
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
// The frontend imports it under the correctly spelled name (main.c: STK___HC_ICAdd_RelocUnique).
CBRPN *__HC_ICAdd_RelocUnique(CBCmpCtrl *cmpc, CBCodeCtrl *cc, I64 *pat_addr, U8 *sym, I64 rt, I64 ptrs)
{
  return __HC_ICAdd_RelocUnqiue(cmpc, cc, pat_addr, sym, rt, ptrs);
}

// Sets how many bytes before function start a symbol starts at
// Symbol    <=====RIP-off
// some...code
// Fun Start <==== RIP
U0 __HC_SetAOTRelocBeforeRIP(CBRPN *r, I64 off)
{
  r->code_misc->aot_before_hint = off;
}

I64 __HC_CodeMiscIsUsed(CBCodeMisc *cm)
{
  return cm->use_cnt != 0;
}

CBRPN *__HC_ICAdd_StaticData(CBCmpCtrl *cmp, CBCodeCtrl *cc, I64 at, U8 *d, I64 len)
{
  CBCodeMisc *misc = CodeMiscNew(cmp, BCMT_STATIC_DATA);
  misc->integer = at;
  misc->str_len = len;
  misc->str = CAlloc(len);
  MemCpy(misc->str, d, len);
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = __IC_SET_STATIC_DATA;
  rpn->code_misc = misc;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_SetStaticsSize(CBCodeCtrl *cc, I64 len)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = __IC_STATICS_SIZE;
  rpn->integer = len;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_StaticRef(CBCodeCtrl *cc, I64 off, I64 rt, I64 ptrs)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = __IC_STATIC_REF;
  rpn->integer = off;
  rpn->ic_class = rt2cls(rt, ptrs);
  rpn->raw_type = rpn->ic_class->raw_type;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

U0 __HC_CmpCtrl_SetAOT(CBCmpCtrl *cc)
{
  cc->flags |= BCCF_AOT_COMPILE;
}
CBRPN *__HC_ICAdd_ToBool(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_TO_BOOL;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_BT(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_BT;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_BTC(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_BTC;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_BTS(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_BTS;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_BTR(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_BTR;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_LBTC(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LBTC;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_LBTS(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LBTS;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_LBTR(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_LBTR;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBRPN *__HC_ICAdd_Fs(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_FS;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}
CBRPN *__HC_ICAdd_Gs(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_GS;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

CBCodeMiscRef *CodeMiscAddRef(CBCodeMisc *misc, I32 *addr)
{
  CBCodeMiscRef *ref;
  ref = CAlloc(sizeof(CBCodeMiscRef));
  ref->add_to = addr;
  ref->next = misc->refs;
  misc->refs = ref;
  return ref;
}
U0 __HC_ICSetLock(CBRPN *l)
{
  l->flags |= ICF_LOCK_EXPR;
}

CBRPN *__HC_ICAdd_GetVargsPtr(CBCodeCtrl *cc)
{
  CBRPN *rpn;
  rpn = CAlloc(sizeof(CBRPN));
  rpn->type = BIC_GET_VARGS_PTR;
  rpn->ic_class = NULL;
  rpn->raw_type = BRT_I64i;
  BQueIns(rpn, cc->ir_code);
  return rpn;
}

U0 __HC_CodeMiscInterateThroughRefs(CBCodeMisc *cm, U0 (*fptr)(U8 *addr, U8 *user_data), U8 *user_data)
{
  CBCodeMiscRef *refs = cm->refs;
  I64 old = BSetWriteNP(1);
  while (refs) {
    // C: BFFICall2(fptr, MemGetExecPtr(refs->add_to), user_data);
    fptr(MemGetExecPtr(refs->add_to), user_data);
    refs = refs->next;
  }
  BSetWriteNP(old);
}

U0 CacheRPNArgs(CBCmpCtrl *cctrl)
{
  CBRPN *head = cctrl->code_ctrl->ir_code, *rpn;
  for (rpn = head->base.next; rpn != head; rpn = rpn->base.next) {
    rpn->tree1 = ICArgN(rpn, 1);
    rpn->tree2 = ICArgN(rpn, 2);
  }
}
