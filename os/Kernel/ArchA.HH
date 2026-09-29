// Interface to the assembly in Arch.S.

import I64 ArchCntFrq();           // counter frequency, Hz
import I64 ArchCntVct();           // virtual counter
import U0 ArchCntvTvalSet(I64 t);  // virtual timer: fire t counts from now
import U0 ArchCntvCvalSet(I64 t);  // virtual timer: fire when the counter reaches t
import U0 ArchCntvCtlSet(I64 v);   // virtual timer control (1=enable)
import I64 ArchMpidr();
import I64 ArchDaif();
import U0 ArchIrqOn();
import U0 ArchIrqOff();
import U0 ArchIntRestore(I64 daif);
import U0 ArchWfi();
import U0 ArchWfe();
import U0 ArchSev();
import I64 ArchTpidr();
import U0 ArchTpidrSet(I64 v);
import I64 ArchCpuNum();
import I64 ArchXchg(I64 *p, I64 v);          // atomic swap, returns old
import I64 ArchCas(I64 *p, I64 old, I64 new); // compare-and-swap, returns seen
import I64 ArchAdd(I64 *p, I64 v);           // atomic add, returns new
import U0 ArchStoreRel(I64 *p, I64 v);       // store-release + sev
import I64 ArchMmioRead32(I64 addr);
import U0 ArchMmioWrite32(I64 addr, I64 val);
import U0 ArchSpinRelease(I64 addr, I64 entry);
import I64 ArchCntvCtl();
import I64 ArchIpiStatus();
import U0 ArchFiqSourcesInit();
import U0 ArchIpiAck(I64 v);
import U0 ArchIpiSend(I64 target);
import U8 *ArchApEntry();
import U0 ArchCtxSwitch(U8 **save_sp, U8 *new_sp);
import U8 *ArchTaskStartAddr();

// Initial stack frame of a new task, popped by ArchCtxSwitch (CTX_SIZE in Arch.S).
class CCtxFrame
{
    I64 x19, x20, x21_28[8], x29, x30;
    F64 d8_15[8];
};

// Saved by the exception entry in Arch.S; layout must match FR_* there.
class CExceptFrame
{
    I64 x[31];
    I64 elr, spsr, esr, far, vec;
    U8 q[32 * 16];
};

#define EXC_CUR_SPX_SYNC 4
#define EXC_CUR_SPX_IRQ  5
#define EXC_CUR_SPX_FIQ  6
import U0 ArchDsb();
import U0 ArchTlbFlush();
import I64 *ArchL2Table();  // boot translation table: entry i maps the 32 MiB block at i << 25
import U0 ArchICacheSync(U8 *addr, I64 len);  // after writing code at addr
import U0 ArchX28Set(I64 v);                  // Fs base register for compiler-built code
import I64 ArchSetJmp(I64 *ctx);
import U0 ArchLongJmp(I64 *ctx);
import U8 *ArchCompilerBin(I64 *size);         // embedded coolc/seed/Compiler.BIN (Blob.S)
import U8 *ArchShellPrelude();                 // embedded shell prelude text
import U8 *ArchKSyms();                        // kernel symbol table (KSym.HC)
import I64 AIWNIOS_SetJmp(I64 *ctx);           // = ArchSetJmp (try/catch)
import U0 AIWNIOS_LongJmp(I64 *ctx);
import F64 Sqrt(F64 d);
import F64 Floor(F64 d);
import F64 Ceil(F64 d);
import F64 Round(F64 d);                       // to nearest, ties away from zero
