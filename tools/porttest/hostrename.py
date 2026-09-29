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
       'COptMemberVar': 'CBOptMemberVar'}
pat = re.compile(r'(?<![A-Za-z0-9_])(' + '|'.join(MAP) + r')(?![A-Za-z0-9_])')
for f in sys.argv[1:]:
    s = open(f, 'rb').read().decode('latin-1')
    # Rename in code only; text after // on a line is left alone.
    out = []
    for line in s.split('\n'):
        code, sep, comment = line.partition('//')
        out.append(pat.sub(lambda m: MAP[m.group(1)], code) + sep + comment)
    t = '\n'.join(out)
    if t != s:
        open(f, 'wb').write(t.encode('latin-1'))
        print(f'{f}: {len(pat.findall(s))} renames')
