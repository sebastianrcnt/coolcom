"""C types for c2hc: a small type model, C layout, and a parser for clang's qualType spellings."""
import re


class CError(Exception):
    pass


class CT:
    """A C type. kind: void, int, float, ptr, arr, func, rec."""
    __slots__ = ('kind', 'bits', 'signed', 'to', 'n', 'params', 'variadic', 'rec', 'is_bool')

    def __init__(self, kind, bits=0, signed=False, to=None, n=None, params=None, variadic=False,
                 rec=None, is_bool=False):
        self.kind = kind
        self.bits = bits
        self.signed = signed
        self.to = to
        self.n = n
        self.params = params
        self.variadic = variadic
        self.rec = rec
        self.is_bool = is_bool

    def key(self):
        k = self.kind
        if k == 'int':
            return f'i{self.bits}{"s" if self.signed else "u"}{"b" if self.is_bool else ""}'
        if k == 'float':
            return 'f'
        if k == 'void':
            return 'v'
        if k == 'ptr':
            return 'p(' + self.to.key() + ')'
        if k == 'arr':
            return f'a{self.n}(' + self.to.key() + ')'
        if k == 'func':
            return 'F(' + ','.join(p.key() for p in self.params) + (',...' if self.variadic else '') + ')' + self.to.key()
        return 'r:' + self.rec.name

    def is_int(self):
        return self.kind == 'int'

    def is_scalar(self):
        return self.kind in ('int', 'float', 'ptr')

    def is_fnptr(self):
        return self.kind == 'ptr' and self.to.kind == 'func'


VOID = CT('void')
DOUBLE = CT('float')
INT = CT('int', bits=32, signed=True)
UINT = CT('int', bits=32, signed=False)
LONG = CT('int', bits=64, signed=True)
ULONG = CT('int', bits=64, signed=False)
UCHAR = CT('int', bits=8, signed=False)
BOOL = CT('int', bits=8, signed=False, is_bool=True)


def ptr_to(t):
    return CT('ptr', to=t)


class Rec:
    def __init__(self, name, is_union):
        self.name = name
        self.is_union = is_union
        self.fields = None      # [(name, CT, offset)] once defined
        self.size = 0
        self.align = 1
        self.external = False   # defined in a LibC header: the library has the class
        self.cool = None        # the Cool name


def align_up(n, a):
    return (n + a - 1) // a * a


def sizeof(t):
    k = t.kind
    if k == 'int':
        return t.bits // 8
    if k in ('float', 'ptr'):
        return 8
    if k == 'arr':
        return (t.n or 0) * sizeof(t.to)
    if k == 'rec':
        if t.rec.fields is None:
            raise CError(f'sizeof incomplete type {t.rec.name}')
        return t.rec.size
    raise CError(f'sizeof {k}')


def alignof(t):
    k = t.kind
    if k == 'arr':
        return alignof(t.to)
    if k == 'rec':
        return t.rec.align
    return min(sizeof(t), 8) or 1


def layout(rec, fields):
    off, align = 0, 1
    placed = []
    for name, t in fields:
        a = alignof(t)
        if rec.is_union:
            placed.append((name, t, 0))
            off = max(off, sizeof(t))
        else:
            off = align_up(off, a)
            placed.append((name, t, off))
            off += sizeof(t)
        align = max(align, a)
    rec.fields = placed
    rec.align = align
    rec.size = align_up(off, align)


TOKEN = re.compile(r'\s*(\((?:unnamed|anonymous)[^()]*\)|\.\.\.|[A-Za-z_][A-Za-z_0-9]*|\d+|[*()\[\],])')
QUALIFIERS = ('const', 'volatile', 'restrict', '__restrict', '_Atomic', 'static', 'inline', 'register', 'extern')


class TypeParser:
    """Parses clang qualType spellings against a resolver with typedef(name) and aggregate(kind, name)."""

    def __init__(self, resolver):
        self.r = resolver

    def parse(self, s):
        s = re.sub(r' __attribute__\(\(.*?\)\)', '', s).strip()
        toks, pos = [], 0
        while pos < len(s):
            m = TOKEN.match(s, pos)
            if not m:
                raise CError(f'cannot parse type {s!r} at {s[pos:]!r}')
            toks.append(m.group(1))
            pos = m.end()
        self.toks, self.i, self.src = toks, 0, s
        base = self.specifiers()
        t = self.declarator()(base)
        if self.i != len(self.toks):
            raise CError(f'trailing text in type {s!r}')
        return t

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def next(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def specifiers(self):
        words, agg, name = [], None, None
        while self.peek() is not None:
            t = self.peek()
            if t in ('*', '(', '[', ')', ',', '...') or t.isdigit():
                break
            if t in QUALIFIERS:
                self.next()
                continue
            if t in ('struct', 'union', 'enum'):
                self.next()
                agg = t
                name = self.next()
                continue
            if t in ('unsigned', 'signed', 'short', 'long', 'int', 'char', 'float', 'double', '_Bool', 'void', '__int128'):
                self.next()
                words.append(t)
                continue
            if agg is None and not words and name is None and not t.startswith('('):
                self.next()
                name = t
                continue
            break
        if agg:
            return self.r.aggregate(agg, name)
        if name is not None:
            return self.r.typedef(name)
        if not words:
            raise CError(f'no type in {self.src!r}')
        if 'void' in words:
            return VOID
        if 'float' in words or 'double' in words:
            return DOUBLE
        if '_Bool' in words:
            return BOOL
        if '__int128' in words:
            raise CError('__int128')
        uns = 'unsigned' in words
        if 'char' in words:
            return CT('int', bits=8, signed='signed' in words)
        if 'short' in words:
            return CT('int', bits=16, signed=not uns)
        if 'long' in words:
            return CT('int', bits=64, signed=not uns)
        return CT('int', bits=32, signed=not uns)

    def declarator(self):
        stars = 0
        while self.peek() == '*':
            self.next()
            stars += 1
            while self.peek() in QUALIFIERS:
                self.next()
        inner = None
        if self.peek() == '(' and self.i + 1 < len(self.toks) and self.toks[self.i + 1] in ('*', '('):
            self.next()
            inner = self.declarator()
            if self.next() != ')':
                raise CError(f'bad declarator in {self.src!r}')
        suffixes = []
        while self.peek() in ('[', '('):
            if self.next() == '[':
                n = None
                if self.peek() != ']':
                    n = int(self.next())
                self.next()
                suffixes.append(('arr', n))
            else:
                params, variadic = [], False
                if self.peek() == ')':
                    self.next()
                else:
                    while True:
                        if self.peek() == '...':
                            self.next()
                            variadic = True
                        else:
                            b = self.specifiers()
                            params.append(self.declarator()(b))
                        t = self.next()
                        if t == ')':
                            break
                        if t != ',':
                            raise CError(f'bad parameter list in {self.src!r}')
                if len(params) == 1 and params[0].kind == 'void':
                    params = []
                suffixes.append(('func', params, variadic))

        def apply(t):
            for _ in range(stars):
                t = ptr_to(t)
            for s in reversed(suffixes):
                if s[0] == 'arr':
                    t = CT('arr', to=t, n=s[1])
                else:
                    t = CT('func', to=t, params=s[1], variadic=s[2])
            if inner:
                t = inner(t)
            return t
        return apply
