#!/usr/bin/env python3
"""A C to Cool translator on top of clang's JSON AST (see README.md).

The C source is parsed by clang with the hermetic headers of coolc/LibC/include, so macros, typedefs,
implicit conversions and types are all resolved before this program sees them. Nothing is copied as C:
a construct this program cannot translate stops it with the source position.

The Cool it writes keeps C's meaning:
  - every C type has the size and layout it has in C (records get explicit padding), so sizeof and
    offsetof are constants and pointer arithmetic scales the same;
  - small integers are kept normalized (an unsigned char is 0..255, an int is sign-extended);
  - conditional operators, and && / || / commas around them, are lowered to statements and temporaries;
  - function pointers are plain U8i * and are called through one small thunk per signature;
  - static data is initialized by generated functions, run when the file loads;
  - the C library is coolc/LibC/LibC.cool.
"""
import argparse
import json
import re
import subprocess
import sys
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ctype_model import (CError, CT, Rec, TypeParser, VOID, DOUBLE, INT, UINT, LONG, ULONG, BOOL,  # noqa: E402
                         layout, sizeof, alignof, ptr_to)
from c2hc_body import FnTranslator  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
LIBC_INCLUDE = ROOT / 'coolc' / 'LibC' / 'include'

# Names Cool cannot have as C identifiers (its keywords and types, and the names the output uses).
KEYWORDS = {'reg', 'class', 'union', 'public', 'private', 'lock', 'try', 'catch', 'throw', 'import',
            'export', 'asm', 'Bool', 'Print', 'I8', 'U8', 'I16', 'U16', 'I32', 'U32', 'I64', 'U64', 'F64',
            'U0', 'I0', 'lastclass', 'no_warn', 'start', 'end', 'interrupt', 'haserrcode', 'argpop',
            'noargpop', 'argc', 'argv', 'fmt', 'ON', 'OFF', 'TRUE', 'FALSE', 'pi', 'inf', 'Fs', 'Gs',
            'I8i', 'U8i', 'I16i', 'U16i', 'I32i', 'U32i', 'I64i', 'U64i'}

SENT_STATIC = ('\x01', '\x02', '\x03')   # \x01 stem \x02 name \x03
SENT_LOCAL = ('\x04', '\x05')            # \x04 name \x05


class FileTracker:
    """The file each top-level declaration is in. clang prints a file name only when it changes, so
    the state must follow every location in document order."""

    def __init__(self):
        self.cur = None

    def visit(self, x):
        if isinstance(x, dict):
            if 'offset' in x and 'tokLen' in x and 'file' in x:
                self.cur = x['file']
            for k, v in x.items():
                if k == 'includedFrom':
                    continue
                if isinstance(v, (dict, list)):
                    self.visit(v)
        else:
            for v in x:
                if isinstance(v, (dict, list)):
                    self.visit(v)

    def scan(self, ast):
        files = {}
        for n in ast['inner']:
            loc = n.get('loc')
            if loc:
                self.visit(loc)
            files[id(n)] = self.cur
            self.visit({k: v for k, v in n.items() if k != 'loc'})
        return files


class Global:
    def __init__(self, name, ct, static, stem, external):
        self.name = name
        self.ct = ct
        self.static = static
        self.stem = stem
        self.external = external
        self.defined = False


class Program:
    def __init__(self, args):
        self.args = args
        self.typedefs = {}
        self.tags = {}
        self.anon_by_text = {}
        self.anon_pending = deque()
        self.enum_consts = {}
        self.enum_types = {}
        self.recs = []
        self.anon_count = 0
        self.globals = {}       # (stem or '', name) -> Global
        self.global_order = []
        self.funcs = {}         # (stem or '', name) -> dict(ct, external, defined)
        self.func_defs = []     # (key, text, refs)
        self.inits = []         # (lines, refs)
        self.thunks = {}
        self.strings = 0
        self.reserved = set(KEYWORDS)
        self.parser = TypeParser(self)
        self.cache = {}
        self.names_used = set()

    def thunk(self, ft):
        key = ft.key()
        if key not in self.thunks:
            self.thunks[key] = (ft, f"_c2hc_call_{len(self.thunks)}")
        return self.thunks[key][1]

    # -- the resolver interface of TypeParser
    def typedef(self, name):
        if name in self.typedefs:
            return self.typedefs[name]
        raise CError(f'unknown type name {name}')

    def aggregate(self, agg, name):
        if name.startswith('('):
            if name in self.anon_by_text:
                return self.anon_by_text[name]
            for i, (kind, ct) in enumerate(self.anon_pending):
                if kind == agg:
                    del self.anon_pending[i]
                    self.anon_by_text[name] = ct
                    return ct
            raise CError(f'unknown anonymous {agg} {name}')
        if agg == 'enum':
            return self.enum_types.get(name, INT)
        key = (agg, name)
        if key not in self.tags:
            rec = Rec(name, agg == 'union')
            rec.cool = self.cool_ident(name)
            self.tags[key] = CT('rec', rec=rec)
        return self.tags[key]

    def ctype(self, s):
        t = self.cache.get(s)
        if t is None:
            t = TypeParser(self).parse(s)
            if not (t.kind == 'rec' and t.rec.fields is None) and '(unnamed' not in s and '(anonymous' not in s:
                self.cache[s] = t
        return t

    def cool_ident(self, name):
        if name in self.reserved:
            return 'c_' + name
        return name

    # -- Cool type text
    def cool(self, t):
        k = t.kind
        if k == 'void':
            return 'U0'
        if k == 'int':
            return ('I' if t.signed else 'U') + str(t.bits) + 'i'
        if k == 'float':
            return 'F64'
        if k == 'ptr':
            to = t.to
            if to.kind in ('void', 'func'):
                return 'U8i *'
            if to.kind == 'arr':
                raise CError('pointer to array')
            return self.storage(to) + (' *' if to.kind != 'ptr' else '*')
        if k == 'rec':
            return t.rec.cool
        if k == 'arr':
            raise CError('array type in a scalar position')
        raise CError(f'cool type of {k}')

    def storage(self, t):
        return 'U32i' if t.kind == 'float' and t.bits == 32 else self.cool(t)

    def decl(self, t, name, value=False):
        """A Cool declaration of name with type t (arrays get their dimensions)."""
        dims = ''
        while t.kind == 'arr':
            dims += f'[{t.n if t.n is not None else 1}]'
            t = t.to
        c = self.cool(t) if value else self.storage(t)
        if c.endswith('*'):
            return f'{c}{name}{dims}'
        return f'{c} {name}{dims}'

    # -- records
    def define_record(self, rec, fields):
        layout(rec, fields)

    def record_text(self, rec):
        lines = [('union ' if rec.is_union else 'class ') + rec.cool + ' {']
        off = 0
        pad = 0
        for name, t, o in rec.fields:
            if not rec.is_union and o > off:
                lines.append(f'    U8i _pad{pad}[{o - off}];')
                pad += 1
            lines.append('    ' + self.decl(t, self.cool_ident(name)) + ';')
            off = o + sizeof(t)
        if rec.is_union:
            if rec.size:
                lines.append(f'    U8i _size[{rec.size}];')
        elif rec.size > off:
            lines.append(f'    U8i _pad{pad}[{rec.size - off}];')
        lines.append('};')
        return '\n'.join(lines)


class TU:
    """Translation of one C file into the program."""

    def __init__(self, prog, path, flags):
        self.prog = prog
        self.path = Path(path).resolve()
        self.flags = flags
        self.stem = re.sub(r'\W', '_', self.path.stem)
        self.file_of = {}

    def clang(self):
        cmd = ['clang', '-std=gnu11', '-funsigned-char', '-fsyntax-only', '-Xclang', '-ast-dump=json',
               '-nostdinc', '-isystem', str(LIBC_INCLUDE), '-Wno-everything'] + self.flags + [str(self.path)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            raise CError('clang failed:\n' + r.stderr[-4000:])
        return json.loads(r.stdout)

    def external(self, n):
        f = self.file_of.get(id(n))
        return bool(f) and str(LIBC_INCLUDE) in str(Path(f).resolve()) if f else False

    def fail(self, n, why):
        loc = n.get('range', {}).get('begin', n.get('loc', {}))
        raise CError(f'{self.path}:{loc.get("line", "?")}:{loc.get("col", "?")}: {why} ({n.get("kind")})')

    def run(self):
        ast = self.clang()
        self.file_of = FileTracker().scan(ast)
        self.statics = {n['name'] for n in ast['inner'] if n.get('storageClass') == 'static' and 'name' in n}
        prog = self.prog
        if prog.args.roots:
            defs = {n.get('name'): n for n in ast['inner'] if n['kind'] == 'FunctionDecl' and any(c['kind'] == 'CompoundStmt' for c in self.kids(n))}
            wanted, pending = set(), list(prog.args.roots)
            def calls(n):
                if n.get('kind') == 'DeclRefExpr' and n.get('referencedDecl', {}).get('kind') == 'FunctionDecl':
                    yield n['referencedDecl']['name']
                for c in self.kids(n): yield from calls(c)
            while pending:
                name = pending.pop()
                if name in wanted: continue
                wanted.add(name)
                if name in defs: pending.extend(calls(defs[name]))
            self.wanted = wanted
        for n in ast['inner']:
            try:
                self.top(n)
            except CError as e:
                if str(e).startswith(str(self.path)) or ':' in str(e).split(' ')[0]:
                    raise
                self.fail(n, str(e))
        del ast

    # -- top level declarations
    def top(self, n):
        k = n['kind']
        if n.get('isImplicit'): return
        prog = self.prog
        ext = self.external(n)
        if k == 'RecordDecl':
            self.record(n, ext)
        elif k == 'TypedefDecl':
            self.typedef(n, ext)
        elif k == 'EnumDecl':
            self.enum(n)
        elif k == 'VarDecl':
            self.var(n, ext)
        elif k == 'FunctionDecl':
            self.function(n, ext)
        elif k in ('EmptyDecl', 'FileScopeAsmDecl', 'StaticAssertDecl'):
            pass
        else:
            self.fail(n, 'top level declaration')

    def kids(self, n):
        return [x for x in n.get('inner', []) if isinstance(x, dict) and x.get('kind') and not x['kind'].endswith('Comment')]

    def record(self, n, ext, owner_name=None):
        prog = self.prog
        if not n.get('completeDefinition'):
            if n.get('name'):
                prog.aggregate(n['tagUsed'], n['name'])
            return
        name = n.get('name') or owner_name
        agg = n['tagUsed']
        if name:
            ct = prog.aggregate(agg, name)
        else:
            prog.anon_count += 1
            name = f'anon{prog.anon_count}'
            rec = Rec(name, agg == 'union')
            rec.cool = prog.cool_ident(name)
            ct = CT('rec', rec=rec)
            prog.anon_pending.append((agg, ct))
        self.record_ids = getattr(self, 'record_ids', {})
        self.record_ids[n['id']] = ct
        rec = ct.rec
        if rec.fields is not None:
            return          # already defined (the same header in another translation unit)
        fields = []
        nested = None
        for c in self.kids(n):
            if c['kind'] == 'RecordDecl':
                self.record(c, ext)
                nested = self.record_ids.get(c['id'])
            elif c['kind'] == 'FieldDecl':
                if c.get('isBitfield'):
                    self.fail(c, 'bit-field')
                if not c.get('name'):
                    self.fail(c, 'anonymous member')
                spelling = c['type']['qualType']
                if nested is not None and ('(unnamed' in spelling or '(anonymous' in spelling):
                    anon = re.search(r'\((?:unnamed|anonymous)[^()]*\)', spelling)
                    if anon: prog.anon_by_text[anon[0]] = nested
                    prog.anon_pending = deque((a, t) for a, t in prog.anon_pending if t is not nested)
                fields.append((c['name'], prog.ctype(spelling)))
                nested = None
            elif c['kind'] in ('IndirectFieldDecl', 'StaticAssertDecl'):
                pass
        prog.define_record(rec, fields)
        rec.external = ext
        prog.recs.append(rec)

    def typedef(self, n, ext):
        prog = self.prog
        name = n['name']
        # typedef struct { ... } Name;  the record takes the name
        owned = None
        for c in self.kids(n):
            tag = c.get('ownedTagDecl')
            if tag and tag.get('kind') in ('RecordDecl',) and not tag.get('name'):
                owned = tag
        if owned is not None:
            for r in [x for x in self._pending_records if x.get('id') == owned['id']] if hasattr(self, '_pending_records') else []:
                pass
        spelling = n['type']['qualType']
        t = self.record_ids[owned['id']] if owned is not None else prog.ctype(spelling)
        if owned is not None:
            prog.anon_pending = deque((a, ct) for a, ct in prog.anon_pending if ct is not t)
            prog.tags[('struct' if not t.rec.is_union else 'union', name)] = t
        if t.kind == 'rec' and t.rec.name.startswith('anon') and owned is not None:
            t.rec.name = name
            t.rec.cool = prog.cool_ident(name)
        prog.typedefs[name] = t

    def enum(self, n):
        prog = self.prog
        value = -1
        neg = False
        consts = []
        for c in self.kids(n):
            if c['kind'] != 'EnumConstantDecl':
                continue
            inner = self.kids(c)
            if inner:
                value = self.const_int(inner[0])
            else:
                value += 1
            consts.append((c['name'], value))
            if value < 0:
                neg = True
        for name, v in consts:
            prog.enum_consts[name] = v
        if n.get('name'):
            prog.enum_types[n['name']] = INT if neg else UINT

    def const_int(self, n):
        k = n['kind']
        if k in ('ConstantExpr',) and 'value' in n:
            return int(n['value'])
        if k in ('ImplicitCastExpr', 'ParenExpr', 'ConstantExpr', 'CStyleCastExpr'):
            return self.const_int(self.kids(n)[0])
        if k == 'IntegerLiteral':
            return int(n['value'])
        if k == 'CharacterLiteral':
            return int(n['value'])
        if k == 'UnaryOperator':
            v = self.const_int(self.kids(n)[0])
            op = n['opcode']
            return {'-': -v, '+': v, '~': ~v, '!': int(not v)}[op]
        if k == 'BinaryOperator':
            a, b = (self.const_int(x) for x in self.kids(n))
            op = n['opcode']
            ops = {'+': lambda: a + b, '-': lambda: a - b, '*': lambda: a * b, '/': lambda: int(a / b),
                   '%': lambda: a % b, '<<': lambda: a << b, '>>': lambda: a >> b, '&': lambda: a & b,
                   '|': lambda: a | b, '^': lambda: a ^ b}
            if op in ops:
                return ops[op]()
        if k == 'DeclRefExpr':
            ref = n['referencedDecl']
            if ref['name'] in self.prog.enum_consts:
                return self.prog.enum_consts[ref['name']]
        if k == 'UnaryExprOrTypeTraitExpr' and n.get('name') == 'sizeof':
            arg = n.get('argType') or self.kids(n)[0]['type']
            return sizeof(self.prog.ctype(arg['qualType']))
        raise CError(f'not a constant: {k}')

    def var(self, n, ext):
        prog = self.prog
        name = n['name']
        static = n.get('storageClass') == 'static'
        ct = prog.ctype(n['type']['qualType'])
        key = (self.stem if static else '', name)
        g = prog.globals.get(key)
        if g is None:
            g = Global(name, ct, static, self.stem, ext or n.get('storageClass') == 'extern' and not self.kids(n))
            prog.globals[key] = g
            prog.global_order.append(key)
        else:
            if ct.kind == 'arr' and ct.n is not None:
                g.ct = ct
        inits = [c for c in self.kids(n) if c['kind'] not in ('ConstantExpr',) or True]
        has_init = bool(inits)
        if n.get('storageClass') != 'extern' and not ext:
            g.external = False
        if ext:
            g.external = True
            return
        if has_init:
            g.defined = True
            fn = FnTranslator(self, None)
            fn.global_init(key, n, inits[0])
        elif n.get('storageClass') != 'extern':
            g.defined = True

    def function(self, n, ext):
        prog = self.prog
        name = n['name']
        if hasattr(self, 'wanted') and name not in self.wanted: return
        static = n.get('storageClass') == 'static'
        ct = prog.ctype(n['type']['qualType'])
        key = (self.stem if static else '', name)
        body = [c for c in self.kids(n) if c['kind'] == 'CompoundStmt']
        f = prog.funcs.get(key)
        if f is None:
            f = {'ct': ct, 'external': ext, 'defined': False, 'static': static, 'stem': self.stem}
            prog.funcs[key] = f
        if ext:
            f['external'] = True
            return
        if not body:
            return
        f['defined'] = True
        f['external'] = False
        fn = FnTranslator(self, key)
        text, refs = fn.function(n, body[0])
        prog.func_defs.append((key, text, refs))


def resolve_sentinels(prog, text, statics_final):
    def stat(m):
        return statics_final[(m.group(1), m.group(2))]
    text = re.sub('\x01([^\x02]*)\x02([^\x03]*)\x03', stat, text)
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('inputs', nargs='+', help='C files, then the Cool output file last')
    ap.add_argument('--root', action='append', dest='roots', help='keep only this function and what it uses (a library)')
    ap.add_argument('--libc', help='#include this LibC.cool at the top of the output')
    ap.add_argument('--library', action='store_true', help='no main call')
    ap.add_argument('--reserved-from', action='append', default=[],
                    help='a Cool header (Kernel.coolh): its macro and function names are renamed in the C code')
    ap.add_argument('-I', action='append', default=[], dest='includes')
    ap.add_argument('-D', action='append', default=[], dest='defines')
    args = ap.parse_args()
    *sources, output = args.inputs
    prog = Program(args)
    for header in args.reserved_from:
        text = Path(header).read_text(errors='replace')
        for m in re.finditer(r'^\s*#define\s+([A-Za-z_]\w*)', text, re.M):
            prog.reserved.add(m.group(1))
        for m in re.finditer(r'^\s*(?:public\s+)?(?:extern|import)?\s*[\w\s\*]*?\b([A-Za-z_]\w*)\s*\(', text, re.M):
            prog.reserved.add(m.group(1))
        for m in re.finditer(r'^\s*(?:public\s+)?(?:class|union)\s+([A-Za-z_]\w*)', text, re.M):
            prog.reserved.add(m.group(1))
    flags = [f'-I{i}' for i in args.includes] + [f'-D{d}' for d in args.defines]
    try:
        for s in sources:
            TU(prog, s, flags).run()
        text = emit(prog, args)
    except CError as e:
        sys.exit(f'c2hc: {e}')
    Path(output).write_text(text)


from c2hc_emit import emit  # noqa: E402

if __name__ == '__main__':
    main()
