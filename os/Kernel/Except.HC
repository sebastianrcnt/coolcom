// Exception dispatch. Arch.S saves a CExceptFrame and calls KExcept.

U8 *except_vec_names[16] = {
    "Sync (SP0)", "IRQ (SP0)", "FIQ (SP0)", "SError (SP0)",
    "Sync", "IRQ", "FIQ", "SError",
    "Sync (lower EL)", "IRQ (lower EL)", "FIQ (lower EL)", "SError (lower EL)",
    "Sync (AArch32)", "IRQ (AArch32)", "FIQ (AArch32)", "SError (AArch32)"};

U0 ExceptDump(I64 vec, CExceptFrame *f)
{
    I64 i;
    "\n*** Exception: %s\n", except_vec_names[vec & 15];
    "ESR=%016X (EC=%02X) ELR=%016X FAR=%016X SPSR=%08X\n",
            f->esr, f->esr >> 26 & 0x3F, f->elr, f->far, f->spsr;
    for (i = 0; i < 31; i++) {
        "x%-2d=%016X", i, f->x[i];
        if (i % 4 == 3)
            '\n';
        else
            "  ";
    }
    '\n';
}

U8 *except_hook;  // I64 (*)(I64 vec, CExceptFrame *f): TRUE if it recovered (the shell)

I64 break_req;    // set by the input IRQ handler on Ctrl+Alt+C
U8 *break_hook;   // U0 (*)(CExceptFrame *f): called with the interrupted frame after such an IRQ (the shell)

U0 KExcept(I64 vec, CExceptFrame *f)
{
    I64 (*hook)(I64 vec, CExceptFrame *f);
    U0 (*brk)(CExceptFrame *f);
    if (vec == EXC_CUR_SPX_IRQ) {
        IrqDispatch;
        if (break_req) {
            break_req = 0;
            brk = break_hook;
            if (brk)
                (*brk)(f);
        }
        return;
    }
    if (vec == EXC_CUR_SPX_FIQ) {
        FiqDispatch;
        return;
    }
    PrintBreakLock;
    hook = except_hook;
    if (hook && (*hook)(vec, f))
        return;
    ExceptDump(vec, f);
    "System halted.\n";
    while (TRUE) {}
}
