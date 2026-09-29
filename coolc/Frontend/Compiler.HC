// Translated from Aiwnios Src/Compiler.HC (nrootconauto, BSD-3), commit e155e87.
CCmpGlbls cmp;
#include "OptLib.HC"
#include "CInit.HC"
#include "AsmLib.HC"
#include "CExcept.HC"
#include "LexLib.HC"
#include "Lex.HC"
#include "PrsLib.HC"
#include "PrsVar.HC"
#include "CMisc.HC"
CmpLoadDefines;
CmpFillTables;
CMiscInit;
#include "AIWNIOS_PrsExp.HC"
#include "AIWNIOS_CodeGen.HC"
#include "PrsStmt.HC";
#include "AsmResolve.HC"
#include "CMain.HC"
//AiwniosAotCompile("HCRT_TOS.HC","HCRT.BIN")
