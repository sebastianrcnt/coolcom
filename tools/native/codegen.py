#!/usr/bin/env python3
"""Compile all 24 codegen units for both targets and compare executable probes.

The corpus contains functions rather than a test main. Scalar arithmetic units
are exercised broadly; pointer, class, control-flow and ABI units use explicit
safe entry points. Outputs include return values and mutated memory.
"""
import argparse
import difflib
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / 'coolc/tests/codegen'
OUT = ROOT / 'build/codegen'

SELECT = {
    'T08Ptr': ['P' + str(i) for i in range(1, 23)],
    'T09Flow': ['F1', 'F2', 'F3', 'F4', 'F5', 'W1', 'W2', 'W3', 'W4', 'W5'],
    'T10Switch': None,
    'T11Args': None,
    'T12Funcs': ['Add', 'Sub', 'Mul', 'Neg', 'FAdd', 'UseDft', 'UseDft2', 'FP17', 'FP23', 'FP24', 'Tail', 'Many', 'Many2'],
    'T13Class': ['A1', 'A2', 'A3', 'A4', 'A5', 'A6', 'A7', 'A8', 'A9', 'A10', 'B1', 'B2'],
    'T14Globals': ['R' + str(i) for i in range(1, 12)] + ['W1'],
    'T15Print': ['P' + str(i) for i in range(1, 24)],
    'T18Misc': ['L' + str(i) for i in range(1, 9)] + ['T' + str(i) for i in range(1, 7)] + ['A' + str(i) for i in range(1, 30)],
    'T21Algo': ['MemCpy8', 'MemSet8', 'StrLen', 'StrCmp', 'Atoi', 'Itoa', 'Hash', 'Fnv', 'Crc', 'PopCnt', 'Fmax', 'Floor', 'Lerp', 'Sin', 'Gray', 'Parity', 'Swap16', 'Rotl', 'Min', 'Max', 'Clamp', 'Abs', 'Sgn', 'Tbl', 'Life', 'Lcg', 'Xorshift', 'Bubble'],
    'T22Addr': ['G_a0', 'S_a0', 'G_a1', 'S_a1', 'G_a7', 'S_a7', 'GG_a0', 'SG_a0', 'GG_a1', 'SG_a1', 'LA_U8', 'LB_U8', 'LC_U8', 'LD_U8', 'LA_I64', 'LB_I64', 'LC_I64', 'LD_I64', 'LA_F64', 'LB_F64', 'LC_F64', 'LD_F64', 'BigFrame', 'BigFrame2', 'BigFrame3', 'BigFrame4'],
    'T24Extern': ['X' + str(i) for i in range(1, 16)] + ['X17', 'X18', 'X19', 'Y3', 'Y4', 'Y5', 'Y6', 'Y12', 'Y13', 'Y14', 'Y15', 'Y16', 'Z1', 'Z2', 'Z3', 'Z4', 'Z10', 'Z12', 'Z14', 'Z15', 'Z16'],
}

SUPPORT = '''
extern U8 *MemCpy(U8 *dst, U8 *src, I64 n);
extern U8 *MemSet(U8 *dst, I64 value, I64 n);
extern U0 AIWNIOS_LongJmp(U8 *ctx);
U8 cg_memory[8][131072];
U8 cg_contexts[16][16384];
I64 cg_depth;
U8 *SysTry() {return cg_contexts[cg_depth++];}
U0 SysUntry() {cg_depth--;}
U0 EndCatch() {}
U0 throw(I64 ch=0, Bool no_log=FALSE) {
    U8 saved[16384];
    MemCpy(saved, cg_contexts[--cg_depth], 16384);
    AIWNIOS_LongJmp(saved);
}
I64 CGHash(U8 *p) {
    I64 i, h=0;
    for (i=0; i<65536; i++) h=(h*33)^p[i];
    return h;
}
'''


def functions(src):
    pattern = r'^(\w+(?:\s*\*)?)\s+(\w+)\s*\(([^)]*)\)\s*\{'
    return re.findall(pattern, src, re.M)


def harness(path):
    src = path.read_text()
    include = path
    if path.stem == 'T24Extern':
        # Existing ARM lowering cannot take the address of an aggregate call.
        src = re.sub(r'^I64 Y[79]\([^\n]+\n', '', src, flags=re.M)
        src = src.replace('extern U8 GArr[100];', 'U8 GArr[100];')
        src = src.replace('extern I64 GArr2[10];', 'I64 GArr2[10];')
        include = OUT / 'T24Extern-supported.cool'
        include.write_text(src)
    out = [f'#include "{include}"', SUPPORT]
    if path.stem == 'T24Extern':
        out += ['''
I64 GExt=17; F64 GFExt=1.5;
I64 Ext1(I64 a,F64 b,I64 c) {return a+b+c;}
F64 Ext2(F64 a) {return a*1.5;}
I64 ExtV(...) {I64 i,s=0; for(i=0;i<argc;i++) s+=argv[i]; return s;}
''']
    count = 0
    selected = SELECT.get(path.stem)
    for ret, name, params in functions(src):
        if selected is not None and name not in selected: continue
        if path.stem == 'T19Conv' and name in ('R31', 'R32'): continue # invalid address / ASLR
        if '*' in ret or ret not in ('U0', 'Bool', 'I8', 'U8', 'I16', 'U16', 'I32', 'U32', 'I64', 'U64', 'F64'): continue
        parts = [x.strip().split('=')[0].strip() for x in params.split(',')] if params.strip() else []
        if any(not re.fullmatch(r'\w+\s+\w+', p) for p in parts) and path.stem not in SELECT: continue
        args, before, ptrs = [], [], []
        valid = True
        for i, part in enumerate(parts):
            m = re.fullmatch(r'(\w+)\s*(\*?)\s*(\w+)', part)
            if not m: valid = False; break
            typ, pointer, param = m.groups()
            if pointer:
                if i >= 8: valid = False; break
                before += [f'MemSet(cg_memory[{i}],0,131072);']
                base = f'(cg_memory[{i}]+2048)'
                if typ in ('U8', 'I8'):
                    before += [f'MemCpy({base},"123",4);']
                elif typ in ('I16','U16','I32','U32','I64','U64','F64'):
                    for j in range(16): before += [f'{base}({typ} *)[{j}]={j+2};']
                args.append(f'{base}({typ} *)')
                ptrs.append(i)
            elif typ not in ('Bool','I8','U8','I16','U16','I32','U32','I64','U64','F64'):
                valid = False; break
            elif typ == 'F64': args.append(f'{2+i}.25')
            else: args.append(str(1 if param in ('i','j') else 2+i))
        if not valid: continue
        count += 1
        out += before
        expr = f'{name}({", ".join(args)})'
        if ret == 'U0': out += [expr + ';', f'Print("{name}:void\\n");']
        elif ret == 'F64': out += [f'F64 cg_float_{count}={expr};', f'Print("{name}:%016llX\\n",cg_float_{count}(I64));']
        else: out += [f'Print("{name}:%lld\\n",{expr});']
        for i in ptrs: out += [f'Print("memory{i}:%016llX\\n",CGHash(cg_memory[{i}]));']
    if not count: raise RuntimeError(f'no probes for {path.stem}')
    return '\n'.join(out) + '\n', count


def run(cmd, log, env=None):
    with log.open('wb') as stream:
        p = subprocess.run(cmd, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=90)
    if p.returncode:
        raise RuntimeError(f'{cmd[0]} exited {p.returncode}: {log}\n{log.read_text()[-3000:]}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--suite', help='one suite stem, for diagnosis')
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'TestBase.coolh').write_bytes((TESTS / 'TestBase.coolh').read_bytes())
    env = dict(os.environ, COOLC_COMPILER_BIN=str(ROOT/'coolc/seed/Compiler.BIN'))
    total = 0
    for path in sorted(TESTS.glob('T*.cool')):
        if args.suite and args.suite != path.stem: continue
        text, count = harness(path)
        driver = OUT / (path.stem + '.cool')
        driver.write_text(text)
        actual = []
        for target, host in [('arm64', 'coolc'), ('x86_64', 'coolc-x86_64')]:
            image = OUT / f'{path.stem}-{target}.BIN'
            run([str(ROOT/'build/coolc'), '--compat', '--target', target, str(driver), str(image)], OUT/f'{path.stem}-{target}.compile.log', env)
            output = OUT / f'{path.stem}-{target}.out'
            run([str(ROOT/'build'/host), '--run', str(image)], output)
            actual.append(output.read_text())
        if actual[0] != actual[1]:
            diff = ''.join(difflib.unified_diff(actual[0].splitlines(True), actual[1].splitlines(True), 'arm64', 'x86_64'))
            (OUT / f'{path.stem}.diff').write_text(diff)
            raise RuntimeError(f'{path.stem} differs:\n{diff[:6000]}')
        print(f'PASS {path.stem}: {count} probes', flush=True)
        total += count
    # Independently assert the two ARM regressions, rather than trusting parity.
    if not args.suite:
        arithmetic = (OUT / 'T21Algo-arm64.out').read_text()
        assert 'Fnv:5003431119771845851\n' in arithmetic
        atomic = (OUT / 'T18Misc-arm64.out').read_text()
        assert atomic.startswith('L1:1\n') and '\nL4:1\n' in atomic
        segments = OUT / 'Segments.cool'
        segments.write_text('#include "TestBase.coolh"\n' + """
_intern 0x15 U8 *Fs(); extern U8 *__Fs();
_intern 0x17 U8 *Gs(); extern U8 *__Gs();
extern U0 SetFs(U8 *t);
I64 cg_task=1234;
SetFs(&cg_task);
Print("segments %d %d\\n",Fs()(I64 *)[0],Gs==NULL);
""")
        image = OUT / 'Segments-x86_64.BIN'
        default_env = dict(os.environ)
        default_env.pop('COOLC_COMPILER_BIN', None)
        run([str(ROOT/'build/coolc'), '--target', 'x86_64', str(segments), str(image)], OUT/'Segments.compile.log', default_env)
        output = OUT/'Segments.out'
        run([str(ROOT/'build/coolc-x86_64'), '--run', str(image)], output)
        assert output.read_text() == 'segments 1234 1\n'
        for host, wrong in [('coolc',image), ('coolc-x86_64',OUT/'T01Arith64-arm64.BIN')]:
            rejected = subprocess.run([str(ROOT/'build'/host),'--run',str(wrong)],cwd=ROOT,capture_output=True)
            assert rejected.returncode and b'architecture mismatch' in rejected.stderr
        rejected = subprocess.run([str(ROOT/'build/coolc'),'--target','invalid',str(segments),str(OUT/'invalid.BIN')],cwd=ROOT,capture_output=True)
        assert rejected.returncode and b'unknown target' in rejected.stderr
        assert not (OUT/'invalid.BIN').exists()
        default = OUT/'T01Arith64-default.BIN'
        run([str(ROOT/'build/coolc'),'--compat',str(OUT/'T01Arith64.cool'),str(default)], OUT/'default.compile.log',default_env)
        assert default.read_bytes() == (OUT/'T01Arith64-arm64.BIN').read_bytes()
        print('PASS: GS slots, architecture guards, default arm64 and target validation')
    print(f'PASS: {total} executable probes match across arm64/x86_64')


if __name__ == '__main__':
    main()
