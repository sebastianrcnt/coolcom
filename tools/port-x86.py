#!/usr/bin/env python3
"""Regenerate the packed-IR Cool port from pinned Aiwnios x86_64_backend.c.

Uses clang's AST for macro expansion, C precedence, casts and struct copies.
The C shim is derived from the owned IR header, rather than assuming C padding.
"""
import argparse
import re
import sys
import subprocess
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/c2hc'))
import c2hc
import c2hc_body
from ctype_model import sizeof


def tokens(s, names):
    return re.sub(r'"(?:\\.|[^"\\])*"|\b[A-Za-z_]\w*\b',
                  lambda m: names.get(m[0], m[0]), s)


class BackendProgram(c2hc.Program):
    def ctype(self, s):
        s = re.sub(r'(union|struct) \w+::', r'\1 ', s)
        return super().ctype(s)

    def define_record(self, rec, fields):
        off = 0
        rec.fields = []
        for name, ct in fields:
            rec.fields.append((name, ct, 0 if rec.is_union else off))
            off = max(off, sizeof(ct)) if rec.is_union else off + sizeof(ct)
        rec.size, rec.align = off, 1


class BackendTU(c2hc.TU):
    def record(self, n, ext, owner_name=None):
        for i, c in enumerate(self.kids(n)):
            if c['kind'] == 'FieldDecl' and not c.get('name'):
                c['name'] = f'_anonymous{i}'
        super().record(n, ext, owner_name)
        if n.get('name', '').startswith('CB'):
            self.prog.tags[(n['tagUsed'], n['name'])].rec.external = True


original_member = c2hc_body.FnTranslator.e_MemberExpr
def member(self, n):
    if not n.get('name'):
        return self.E(c2hc_body.kids(n)[0])
    child = c2hc_body.kids(n)[0]
    if child['kind'] == 'MemberExpr' and not child.get('name'):
        n = dict(n, inner=child['inner'], isArrow=child.get('isArrow', False))
    return original_member(self, n)
c2hc_body.FnTranslator.e_MemberExpr = member

original_call = c2hc_body.FnTranslator.e_CallExpr
def call(self, n, void=False):
    target = self.unimplicit(c2hc_body.kids(n)[0])
    name = target.get('referencedDecl', {}).get('name')
    if name in ('__builtin_ffsll', '__builtin_popcountll'):
        return name + '(' + self.E(c2hc_body.kids(n)[1]) + ')'
    if name == 'abort':
        line = n.get('range', {}).get('begin', {}).get('line', '?')
        return f'BAssert(FALSE, "x86 unreachable path: {self.fname}:{line}")'
    return original_call(self, n, void)
c2hc_body.FnTranslator.e_CallExpr = call

def compound_literal(self, n):
    ct = self.ct(n)
    name = self.temp(self.prog.cool(ct))
    self.emit(f'MemSet(&{name}, 0, {sizeof(ct)});')
    self.init_object(name, ct, c2hc_body.kids(n)[0], True)
    return name
c2hc_body.FnTranslator.e_CompoundLiteralExpr = compound_literal

original_conv = c2hc_body.FnTranslator.conv
def conv(self, x, src, dst):
    # Cool already promotes normalized small integers to 64 bits. Avoid
    # inventing one mutable local for every encoder argument and literal.
    if src.kind == dst.kind == 'int' and dst.bits == 64 and src.bits < 64:
        return x if dst.signed else self.relabel(x, dst)
    return original_conv(self, x, src, dst)
c2hc_body.FnTranslator.conv = conv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', type=Path, default=ROOT / 'vendor/aiwnios/c/x86_64_backend.c')
    args = ap.parse_args()
    stage = ROOT / 'build/port-x86'
    stage.mkdir(parents=True, exist_ok=True)
    names = {}
    prefixes = {}
    for line in (ROOT / 'coolc/Compiler/RENAMES.txt').read_text().splitlines():
        if not line or line.startswith('#'): continue
        a, b = line.split()
        (prefixes if a.endswith('_') else names)[a] = b
    src = args.source.read_text()
    for word in re.findall(r'\b\w+\b', src):
        for a, b in prefixes.items():
            if word.startswith(a): names[word] = b + word[len(a):]
    src = tokens(src, names)
    src = src.replace('extern void BDoNothing();', '')
    # Match the shared frontend ABI: returns expose their bits in both banks.
    src = src.replace('if (tmp.raw_type == BRT_F64)\n      AIWNIOS_ADD_CODE(X86MovQI64F64, MIR(cctrl, 0), 0);\n    {',
                      'if (tmp.raw_type == BRT_F64) {\n      AIWNIOS_ADD_CODE(X86MovQI64F64, MIR(cctrl, 0), 0);\n    } else {\n      AIWNIOS_ADD_CODE(X86MovQF64I64, MFR(cctrl, 0), 0);\n    }\n    {')
    src = src.replace('X86ShrRCX, MIR(cctrl, tmp.reg2)', 'X86ShrRCX, MIR(cctrl, tmp2.reg)')
    # Retrying a failed speculative LEA recursively traverses long addition
    # chains twice per level (exponential work). Keep the ordinary add path.
    src = src.replace('!spilled && GetSIBParts(orig, &i, &b, &idx, &i2, 0)', '0')
    src = re.sub(r'^#include.*\n', '', src, flags=re.M)
    # GNU labels-as-values become a switch with the same destination labels.
    table = re.search(r'static const void \*poop_ants\[BIC_CNT\] = \{(.*?)\};', src, re.S)
    entries = dict(re.findall(r'\[(\w+)\]\s*=\s*&&(\w+)', table[1]))
    dispatch = 'switch (rpn->type) {\n' + ''.join(f'case {op}: goto {label};\n' for op, label in entries.items()) + 'default: goto ret;\n}'
    src = src[:table.start()] + src[table.end():]
    src = re.sub(r'if \(!poop_ants\[rpn->type\]\)\s*goto ret;\s*goto \*poop_ants\[rpn->type\];', dispatch, src)
    src = src.replace('heap ?: BFs->code_heap', 'heap ? heap : BFs->code_heap')
    src = src.replace('CBRPN *forwards[cnt2 = cnt];', 'cnt2 = cnt; CBRPN **forwards = MAlloc(cnt2 * sizeof(CBRPN *));')
    at = src.rfind('return xbin;')
    src = src[:at] + 'Free(forwards);\n  ' + src[at:]
    # Floating shifts operate on IEEE bits, then retain an F64 result.
    start = src.index('    } else {\n      next = ICArgN(rpn, 1);', src.index('  ic_lsh:'))
    end = src.index('    break;\n  ic_rsh:', start)
    shift = """    } else {
      next = ICArgN(rpn, 1); next2 = ICArgN(rpn, 0);
      code_off = __OptPassFinal(cctrl, next2, bin, code_off);
      code_off = PutICArgIntoReg(cctrl, &next2->res, BRT_I64i, RCX, bin, code_off);
      code_off = PushToStack(cctrl, &next2->res, bin, code_off);
      code_off = __OptPassFinal(cctrl, next, bin, code_off);
      code_off = PutICArgIntoReg(cctrl, &next->res, BRT_F64, 0, bin, code_off);
      AIWNIOS_ADD_CODE(X86MovQI64F64, MIR(cctrl, RAX), next->res.reg);
      tmp.mode = MD_REG; tmp.raw_type = BRT_I64i; tmp.reg = RCX;
      code_off = PopFromStack(cctrl, &tmp, bin, code_off);
      AIWNIOS_ADD_CODE(X86ShlRCX, MIR(cctrl, RAX));
      AIWNIOS_ADD_CODE(X86MovQF64I64, MFR(cctrl, 0), RAX);
      tmp.raw_type = BRT_F64; tmp.reg = 0;
      rpn->tmp_res = tmp;
      if (rpn->res.keep_in_tmp) {rpn->res = tmp; rpn->res.keep_in_tmp = 1;}
      code_off = ICMov(cctrl, &rpn->res, &tmp, bin, code_off);
    }
"""
    src = src[:start] + shift + src[end:]
    start = src.index('    if (rpn->raw_type == BRT_F64) {', src.index('  ic_rsh:'))
    end = src.index('    switch (rpn->raw_type)', start)
    src = src[:start] + shift.replace('    } else {', '    if (rpn->raw_type == BRT_F64) {', 1).replace('X86ShlRCX', 'X86SarRCX').replace('    }\n', '      break;\n    }\n') + src[end:]
    src = """static int MutatingOperand(CBRPN *r) {
      switch (r->type) {
        case BIC_EQ: case BIC_ADD_EQ: case BIC_SUB_EQ: case BIC_MUL_EQ:
        case BIC_DIV_EQ: case BIC_MOD_EQ: case BIC_LSH_EQ: case BIC_RSH_EQ:
        case BIC_AND_EQ: case BIC_OR_EQ: case BIC_XOR_EQ:
        case BIC_PRE_INC: case BIC_POST_INC: case BIC_PRE_DEC: case BIC_POST_DEC: return 1;
      }
      return 0;
    }\n""" + src
    a = src.index('#define BACKEND_BINOP(f_op')
    b = src.index('#define BACKEND_BINOP_IMM', a)
    pair = re.compile(r'code_off = __OptPassFinal\(cctrl, next, bin, code_off\);[ \t\\]*\n[ \t]*code_off = __OptPassFinal\(cctrl, next2, bin, code_off\);')
    lines = ['if (MutatingOperand(next) || MutatingOperand(next2)) {',
        'code_off = __OptPassFinal(cctrl, next2, bin, code_off);',
        'code_off = __OptPassFinal(cctrl, next, bin, code_off);', '} else {',
        'code_off = __OptPassFinal(cctrl, next, bin, code_off);',
        'code_off = __OptPassFinal(cctrl, next2, bin, code_off);', '}']
    src = src[:a] + pair.sub(lambda m: (' '+chr(92)+'\n').join(lines), src[a:b]) + src[b:]
    src = src.replace('PushTmpDepthFirst(cctrl, arg, SpillsTmpRegs(arg2));\n    PushTmpDepthFirst(cctrl, arg2, 0);\n    PopTmp(cctrl, arg2);\n    PopTmp(cctrl, arg);',
        'if (r->type == BIC_ADD || r->type == BIC_SUB || r->type == BIC_MUL || (r->type == BIC_DIV && r->raw_type == BRT_F64)) {\n'
        'if (MutatingOperand(arg) || MutatingOperand(arg2)) {\n'
        'PushTmpDepthFirst(cctrl, arg2, SpillsTmpRegs(arg)); PushTmpDepthFirst(cctrl, arg, 0); PopTmp(cctrl, arg); PopTmp(cctrl, arg2); goto fin;\n}\n}\n'
        'PushTmpDepthFirst(cctrl, arg, SpillsTmpRegs(arg2));\n    PushTmpDepthFirst(cctrl, arg2, 0);\n    PopTmp(cctrl, arg2);\n    PopTmp(cctrl, arg);')
    # The owned ARM frontend marks aggregate assignment with a byte size.
    class_copy = """static int64_t ClassCopy(CBCmpCtrl *cctrl, CBRPN *rpn, char *bin, int64_t code_off) {

      CBICArg src_addr = {0}, dst_addr = {0};
      CBRPN *next, *next2;
      int64_t copied = 0, step;
      next = ICArgN(rpn,1); next2 = ICArgN(rpn,0);
      code_off = __OptPassFinal(cctrl,next2,bin,code_off);
      code_off = __OptPassFinal(cctrl,next,bin,code_off);
      src_addr.mode = MD_REG; src_addr.raw_type = BRT_PTR; src_addr.reg = R8;
      dst_addr.mode = MD_REG; dst_addr.raw_type = BRT_PTR; dst_addr.reg = RCX;
      code_off = ICMov(cctrl,&src_addr,&next2->res,bin,code_off);
      code_off = ICMov(cctrl,&dst_addr,&next->res,bin,code_off);
      while (copied < rpn->integer) {
        if (rpn->integer-copied >= 8) {
          step = 8;
          AIWNIOS_ADD_CODE(X86MovRegIndirI64,MIR(cctrl,RAX),-1,-1,R8,copied);
          AIWNIOS_ADD_CODE(X86MovIndirRegI64,RAX,-1,-1,RCX,copied);
        } else {
          step = 1;
          AIWNIOS_ADD_CODE(X86MovZXRegIndirI8,MIR(cctrl,RAX),-1,-1,R8,copied);
          AIWNIOS_ADD_CODE(X86MovIndirRegI8,RAX,-1,-1,RCX,copied);
        }
        copied += step;
      }
      return code_off;
    }
"""
    definition = re.search(r'\nint64_t __OptPassFinal\([^;]+?\{', src, re.S)
    src = src[:definition.start()] + '\n' + class_copy + src[definition.start():]
    src = src.replace('  ic_eq:\n', '  ic_eq:\n    if (rpn->integer > 8) {code_off = ClassCopy(cctrl,rpn,bin,code_off); break;}\n')
    a = src.index('  ic_comma:'); b = src.index('  ic_eq:', a)
    src = src[:a] + src[a:b].replace('code_off = __OptPassFinal(cctrl, next2, bin, code_off);\n    next->res.keep_in_tmp = 1;\n    code_off = __OptPassFinal(cctrl, next, bin, code_off);', 'code_off = __OptPassFinal(cctrl, next, bin, code_off);\n    code_off = __OptPassFinal(cctrl, next2, bin, code_off);') + src[b:]
    hdr = (ROOT / 'coolc/Compiler/BackendA.coolh').read_text()
    hdr = re.sub(r'//[^\n]*', '', hdr)
    classes = hdr[hdr.index('extern class'):hdr.index('// ---------------------------------------------------------------- constants') if '// ---------------------------------------------------------------- constants' in hdr else hdr.index('#define LEXF_')]
    classes = re.sub(r'extern class (\w+);', r'typedef struct \1 \1;', classes)
    classes = re.sub(r'\bclass (\w+)\s*\{', r'struct \1 {', classes)
    classes = ''.join(f'typedef struct {n} {n};\n' for n in re.findall(r'struct (\w+)\s*\{', classes)) + classes
    defines = '\n'.join(line for line in hdr.splitlines() if line.startswith('#define') and not any(x in line for x in ('BAIWNIOS_',)))
    # Only shared helpers: ARM-specific prototypes have different signatures.
    helpers = hdr[hdr.index('extern CBRPN *__HC_ICAdd_Sqr'):]
    helpers = re.sub(r'^#.*$', '', helpers, flags=re.M)
    helpers = re.sub(r'=\s*(?:NULL|TRUE|FALSE|\d+)', '', helpers)
    helpers = re.sub(r'extern U0 throw\([^;]*;', '', helpers)
    helpers = re.sub(r'extern [^;]*\b__builtin_\w+\([^;]*;', '', helpers)
    ctypes = {'U0': 'void', 'U8': 'uint8_t', 'I8': 'int8_t', 'I16': 'int16_t', 'U16': 'uint16_t', 'I32': 'int32_t', 'U32': 'uint32_t', 'I64': 'int64_t', 'U64': 'uint64_t', 'F64': 'double', 'Bool': 'int8_t'}
    shim = '#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#define TRUE 1\n#define FALSE 0\n#define NULL 0\n#pragma pack(push,1)\n' + tokens(classes, ctypes) + '\n#pragma pack(pop)\n' + defines + '\n' + tokens(helpers, ctypes)
    shim += '\n#define assert(x) BAssert(x, "x86 backend assertion")\n#define A_MALLOC(n,h) MAlloc(n)\n#define A_CALLOC(n,h) CAlloc(n)\n#define A_FREE(p) Free(p)\n#define A_STRDUP(s,h) StrNew(s)\n'
    regs = 'RAX RCX RDX RBX RSP RBP RSI RDI R8 R9 R10 R11 R12 R13 R14 R15 RIP'.split()
    shim += ''.join(f'#define {r} {i}\n' for i, r in enumerate(regs))
    shim += '\n#define BAIWNIOS_IREG_START 10\n#define BAIWNIOS_IREG_CNT 7\n#define BAIWNIOS_FREG_START 6\n#define BAIWNIOS_FREG_CNT 10\n#define BAIWNIOS_TMP_FREG_START 3\n#define BAIWNIOS_TMP_FREG_CNT 3\n#define BAIWNIOS_TMP_IREG_START 0\n#define BAIWNIOS_TMP_IREG_CNT 2\n#define BAIWNIOS_TMP_IREG_POOP 8\n#define BAIWNIOS_TMP_IREG_POOP2 1\n'
    path = stage / 'x86_backend.c'
    path.write_text(shim + '\n' + src)
    p = BackendProgram(SimpleNamespace(roots=None))
    tu = BackendTU(p, path, [])
    tu.run()
    renamed = {}
    for key, f in p.funcs.items():
        if f['defined']: renamed[key] = 'X64' + key[1]
        else: renamed[key] = key[1]
    for key in p.globals:
        renamed[key] = 'X64' + key[1] if key[0] else key[1]
    def fix(s):
        s = re.sub('\x01([^\x02]*)\x02([^\x03]*)\x03', lambda m: renamed[(m[1], m[2])], s)
        s = re.sub('\x04([^\x05]*)\x05', lambda m: m[1], s)
        s = tokens(s, {k[1]: v for k, v in renamed.items() if not k[0]})
        return tokens(s, {'printf': 'Print', 'memcpy': 'MemCpy', 'memset': 'MemSet', 'strlen': 'StrLen', 'strcmp': 'StrCmp', 'LC_popcount': '__builtin_popcountll', 'C2HFloatToUnsigned': 'BF64ToU64', 'C2HUnsignedToFloat': 'X64UnsignedToFloat'})
    credit = '// Translated from Aiwnios c/x86_64_backend.c (nrootconauto, BSD-3), commit e155e87.\n// Generated by tools/port-x86.py; shared packed IR from BackendA.coolh.\n'
    prototypes = []
    for key, f in p.funcs.items():
        if not f['defined']: continue
        ft = f['ct']
        params = ', '.join(p.decl(t, f'p{i}') for i, t in enumerate(ft.params))
        prototypes.append('extern ' + p.cool(ft.to) + ' ' + renamed[key] + '(' + params + ');')
    (ROOT / 'coolc/Compiler/X64Backend.coolh').write_text(credit + '\n'.join(prototypes) + '\n')
    out = [credit, 'F64 X64UnsignedToFloat(U64i x) {F64 f = x & 0x7FFFFFFFFFFFFFFF; if (x >> 63) f += 9223372036854775808.0; return f;}']
    for key in p.global_order:
        g = p.globals[key]
        if g.defined and not g.external: out.append(p.decl(g.ct, renamed[key]) + ';')
    for ft, name in p.thunks.values():
        params = ', '.join(p.decl(t, f'p{i}') for i, t in enumerate(ft.params))
        out.append(p.cool(ft.to) + ' ' + name + '(U8i *fp, ' + params + ') {\n' + p.cool(ft.to) + ' (*fn)(' + params + ');\nfn = fp;\n' + ('return ' if ft.to.kind != 'void' else '') + '(*fn)(' + ', '.join(f'p{i}' for i in range(len(ft.params))) + ');\n}')
    out.extend(fix(s) for _, s, _ in p.func_defs)
    for i, (key, lines, _, decls) in enumerate(p.inits):
        out.append(f'U0 X64Init{i}() {{')
        out.extend(p.decl(t, n) + ';' for t, n in decls)
        out.extend(fix(s) for s in lines)
        out.extend(['}', f'X64Init{i}();'])
    (ROOT / 'coolc/Compiler/X64Backend.cool').write_text('\n\n'.join(out) + '\n')
    subprocess.run([str(ROOT / 'tools/hcfmt.sh'),
                    str(ROOT / 'coolc/Compiler/X64Backend.cool'),
                    str(ROOT / 'coolc/Compiler/X64Backend.coolh')], check=True)


if __name__ == '__main__':
    main()
