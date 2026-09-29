#!/usr/bin/env python3
# Point the port's host-runtime calls at the backend-private runtime in
# BackendRT.HC (see RENAMES.txt, "host runtime"). Idempotent.
# Usage: hostrename.py file...
import re, sys
MAP = {'Fs': 'BFs', 'HashFind': 'BHashFind', 'HashAdd': 'BHashAdd',
       'HeapCtrlInit': 'BHeapCtrlInit', 'HeapCtrlDel': 'BHeapCtrlDel',
       'SetWriteNP': 'BSetWriteNP', 'DoNothing': 'BDoNothing',
       'FFI_CALL_TOS_2': 'BFFICall2', 'qsort': 'BQSort', 'fmod': 'BFMod', 'pow': 'BPow',
       # functions that clash with the Aiwnios HolyC frontend (found at integration)
       'AssignRawTypeToNode': 'BAssignRawTypeToNode', 'CmpCtrlNew': 'BCmpCtrlNew',
       'CmpCtrlDel': 'BCmpCtrlDel', 'MASKn': 'BMASKn', 'CondSel': 'BCondSel',
       'COptMemberVar': 'CBOptMemberVar',
       # C-layout queues (CBQue is {last,next}, TempleOS CQue is {next,last})
       'QueIns': 'BQueIns', 'QueRem': 'BQueRem', 'QueInit': 'BQueInit',
       'QueDel': 'BQueDel', 'QueCnt': 'BQueCnt',
       # #defines that clash with the frontend's (e.g. CMF_DEFINED is 1 here, 2 there)
       'AIWNIOS_FREG_CNT': 'BAIWNIOS_FREG_CNT', 'AIWNIOS_FREG_START': 'BAIWNIOS_FREG_START', 'AIWNIOS_IREG_CNT': 'BAIWNIOS_IREG_CNT', 'AIWNIOS_IREG_START': 'BAIWNIOS_IREG_START', 'AIWNIOS_REG_FP': 'BAIWNIOS_REG_FP', 'AIWNIOS_REG_SP': 'BAIWNIOS_REG_SP', 'AIWNIOS_TMP_FREG_CNT': 'BAIWNIOS_TMP_FREG_CNT', 'AIWNIOS_TMP_FREG_START': 'BAIWNIOS_TMP_FREG_START', 'AIWNIOS_TMP_IREG_CNT': 'BAIWNIOS_TMP_IREG_CNT', 'AIWNIOS_TMP_IREG_POOP': 'BAIWNIOS_TMP_IREG_POOP', 'AIWNIOS_TMP_IREG_POOP2': 'BAIWNIOS_TMP_IREG_POOP2', 'AIWNIOS_TMP_IREG_START': 'BAIWNIOS_TMP_IREG_START', 'CMF_DEFINED': 'BCMF_DEFINED', 'INVALID_PTR': 'BINVALID_PTR', 'STR_LEN': 'BSTR_LEN'}
pat = re.compile(r'(?<![A-Za-z0-9_])(' + '|'.join(MAP) + r')(?![A-Za-z0-9_])')
for f in sys.argv[1:]:
    s = open(f, 'rb').read().decode('latin-1')
    # Rename in code only; text after // on a line is left alone.
    out = []
    for line in s.split('\n'):
        code, sep, comment = line.partition('//')
        if comment.startswith('HOST'):  # a line marked //HOST uses the real host names
            out.append(line); continue
        out.append(pat.sub(lambda m: MAP[m.group(1)], code) + sep + comment)
    t = '\n'.join(out)
    if t != s:
        open(f, 'wb').write(t.encode('latin-1'))
        print(f'{f}: {len(pat.findall(s))} renames')
