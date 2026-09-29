#!/usr/bin/env python3
# Flag by-value class assignments in HolyC port files. Aiwnios' HolyC
# compiler copies only the first 8 bytes when assigning a class by value,
# so every such copy must be a MemCpy. Heuristic: finds assignments to/from
# class-typed locals/globals, class-typed members and `*p = *q`.
# Usage: classassign.py BackendA.HH file.HC...
import re, sys
hdr = open(sys.argv[1], encoding='latin-1').read()
classes = set(re.findall(r'^\s*(?:public\s+)?(?:class|union)\s+(\w+)', hdr, re.M))
# class-typed members: "  CBICArg res;" inside class bodies
members = set()
for body in re.findall(r'(?:class|union)\s+\w+[^{]*\{(.*?)\n\};', hdr, re.S):
    for t, names in re.findall(r'^\s*(\w+)\s+([^;(]+);', body, re.M):
        if t in classes:
            for n in names.split(','):
                n = n.strip()
                if n and not n.startswith('*'):
                    members.add(re.sub(r'\[.*', '', n))
bad = 0
for f in sys.argv[2:]:
    src = open(f, encoding='latin-1').read().split('\n')
    vars_ = set()
    for line in src:
        for t, names in re.findall(r'^\s*(\w+)\s+([^;(]+);', line):
            if t in classes:
                for n in names.split(','):
                    n = n.strip().split('=')[0].strip()
                    if n and not n.startswith('*') and '[' not in n:
                        vars_.add(n)
    name_re = '|'.join(map(re.escape, sorted(vars_))) or 'NOMATCH'
    mem_re = '|'.join(map(re.escape, sorted(members))) or 'NOMATCH'
    pats = [
        re.compile(r'\*\s*\(?\w[\w\->.\[\]]*\)?\s*=[^=]\s*\*\s*\(?\w'),              # *p = *q
        re.compile(r'(?<![\w>.&])(' + name_re + r')\s*=[^=]'),                      # var = ...
        re.compile(r'=\s*(?<![=!<>])(' + name_re + r')\s*;'),                      # ... = var;
        re.compile(r'(->|\.)(' + mem_re + r')\s*=[^=]'),                            # x->m = ...
        re.compile(r'=\s*[\w\->.\[\]()*]*(->|\.)(' + mem_re + r')\s*;'),           # ... = y->m;
    ]
    for no, line in enumerate(src, 1):
        code = line.split('//')[0]
        if 'MemCpy' in code or 'MemSet' in code:
            continue
        if any(p.search(code) for p in pats):
            print(f'{f}:{no}: {line.strip()}')
            bad += 1
print(f'{bad} suspicious lines', file=sys.stderr)
