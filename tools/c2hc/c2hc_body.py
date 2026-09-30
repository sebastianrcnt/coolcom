"""c2hc: translating function bodies, initializers and expressions."""
import re

from ctype_model import (CError, CT, VOID, DOUBLE, INT, UINT, LONG, ULONG, BOOL, sizeof, alignof, ptr_to)

ASSIGN_OPS = {'=', '+=', '-=', '*=', '/=', '%=', '<<=', '>>=', '&=', '|=', '^='}
LOCAL_L, LOCAL_R = '\x04', '\x05'
STATIC_A, STATIC_B, STATIC_C = '\x01', '\x02', '\x03'


def kids(n):
    return [x for x in n.get('inner', []) if isinstance(x, dict) and x.get('kind')
            and not x['kind'].endswith('Comment') and not x['kind'].endswith('Attr')]


def mask_of(bits):
    return (1 << bits) - 1


def c_string_bytes(value):
    """The bytes of a clang StringLiteral 'value' ("\"abc\\n\"")."""
    assert value[0] == '"' and value[-1] == '"'
    s = value[1:-1]
    out = bytearray()
    i = 0
    simple = {'n': 10, 't': 9, 'r': 13, 'a': 7, 'b': 8, 'f': 12, 'v': 11, '\\': 92, '"': 34, "'": 39, '?': 63, 'e': 27}
    while i < len(s):
        c = s[i]
        if c != '\\':
            out += c.encode('utf-8')
            i += 1
            continue
        i += 1
        c = s[i]
        if c in simple:
            out.append(simple[c])
            i += 1
        elif c == 'x':
            j = i + 1
            while j < len(s) and s[j] in '0123456789abcdefABCDEF':
                j += 1
            out.append(int(s[i + 1:j], 16) & 0xFF)
            i = j
        elif c in '01234567':
            j = i
            while j < len(s) and j < i + 3 and s[j] in '01234567':
                j += 1
            out.append(int(s[i:j], 8) & 0xFF)
            i = j
        else:
            raise CError(f'string escape \\{c}')
    return bytes(out)


def cool_string(data):
    out = ['"']
    for b in data:
        if b == 0x22:
            out.append('\\"')
        elif b == 0x5C:
            out.append('\\\\')
        elif b == 10:
            out.append('\\n')
        elif b == 9:
            out.append('\\t')
        elif b == 13:
            out.append('\\r')
        elif 0x20 <= b < 0x7F and b not in (0x24, 0x60):
            out.append(chr(b))
        else:
            out.append(f'\\x{b:02X}')
    out.append('"')
    return ''.join(out)


class FnTranslator:
    def __init__(self, tu, key):
        self.tu = tu
        self.prog = tu.prog
        self.key = key
        self.lines = []          # (level, text)
        self.level = 1
        self.locals = {}         # VarDecl id -> cool name (with sentinels)
        self.static_locals = {}  # VarDecl id -> global name text
        self.base_names = set()
        self.decls = []          # (cool type text, name)
        self.uses = {}
        self.refs = set()
        self.loops = []
        self.label_names = {}
        self.fname = key[1] if key else 'init'
        self.variadic = False
        self.ret = VOID
        self.switch_depth = 0

    # ------------------------------------------------------------ small helpers
    def fail(self, n, why):
        self.tu.fail(n, why)

    def ct(self, n):
        try:
            return self.prog.ctype(n['type']['qualType'])
        except CError as e:
            self.fail(n, str(e))

    def emit(self, text):
        self.lines.append((self.level, text))

    def temp(self, t_text):
        self.prog.temp_serial = getattr(self.prog, 'temp_serial', 0) + 1
        name = f'_c2hc_t{self.prog.temp_serial}'
        self.decls.append((t_text, name))
        return name

    def temp_for(self, t):
        if t.kind == 'arr':
            t = ptr_to(t.to)
        if t.kind == 'rec':
            raise CError('temporary of a record type')
        return self.temp(self.prog.cool(t))

    def local_name(self, base):
        base = self.prog.cool_ident(base)
        name, i = base, 0
        while name in self.base_names:
            i += 1
            name = f'{base}_{i}'
        self.base_names.add(name)
        return name

    def sentinel_local(self, name):
        return f'{LOCAL_L}{name}{LOCAL_R}'

    def static_ref(self, kind, name):
        """A reference to a file-level name; static ones are renamed at the end."""
        tu = self.tu
        if name in (tu.statics if kind else set()):
            return f'{STATIC_A}{tu.stem}{STATIC_B}{name}{STATIC_C}'
        return name

    def note_ref(self, kind, name):
        key = (self.tu.stem if name in self.tu.statics else '', name)
        self.refs.add((kind, key))

    def strip(self, n):
        while n['kind'] in ('ParenExpr', 'ConstantExpr') and kids(n):
            n = kids(n)[0]
        return n

    def unimplicit(self, n):
        while n['kind'] in ('ParenExpr', 'ConstantExpr', 'ImplicitCastExpr') and kids(n):
            n = kids(n)[0]
        return n

    def impure(self, n):
        k = n['kind']
        if k == 'CallExpr' or k == 'CompoundAssignOperator' or k == 'StmtExpr' or k == 'VAArgExpr':
            return True
        if k == 'BinaryOperator' and n['opcode'] in ASSIGN_OPS | {','}:
            return True
        if k == 'UnaryOperator' and n['opcode'] in ('++', '--'):
            return True
        return any(self.impure(c) for c in kids(n))

    # ------------------------------------------------------------ numbers
    def norm(self, x, t):
        """x, an int expression, brought into the range of the C type t."""
        if t.kind != 'int' or t.bits >= 64:
            return x
        if t.is_bool:
            return f'({x} != 0)'
        m = mask_of(t.bits)
        if not t.signed:
            return f'({x} & 0x{m:X})'
        s = 1 << (t.bits - 1)
        return f'((({x} & 0x{m:X}) ^ 0x{s:X}) - 0x{s:X})'

    def fits(self, src, dst):
        """Every value of int type src is a value of int type dst."""
        if dst.is_bool:
            return False
        if dst.bits >= 64 and dst.signed == src.signed:
            return True
        if src.is_bool:
            return True
        if dst.bits == 64:
            return src.bits < 64 and not src.signed or (dst.signed and src.bits < 64) or dst.signed == src.signed
        if src.signed == dst.signed:
            return src.bits <= dst.bits
        if dst.signed and not src.signed:
            return src.bits < dst.bits
        return False

    def relabel(self, x, t):
        return f'(({x})({self.prog.cool(t)}))'

    def conv(self, x, src, dst):
        """x, a value of C type src, converted to C type dst."""
        if dst.kind == 'void':
            return x
        if src.kind == 'arr':
            src = ptr_to(src.to)
        if src.kind == 'func':
            src = ptr_to(src)
        if src.kind == 'int' and dst.kind == 'int':
            if dst.bits == 64 and src.bits < 64:
                t = self.temp(self.prog.cool(dst))
                return f'({t} = {x})'
            if dst.is_bool:
                return f'({x} != 0)'
            if self.fits(src, dst):
                if dst.bits == 64 and src.bits == 64 and src.signed != dst.signed:
                    return self.relabel(x, dst)
                return x
            r = self.norm(x, dst)
            if dst.bits == 64:
                return self.relabel(x, dst)
            return r
        if src.kind == 'int' and dst.kind == 'float':
            if src.bits == 64 and not src.signed:
                return f'C2HUnsignedToFloat({x})'
            t = self.temp('F64')
            return f'({t} = {x})'
        if src.kind == 'float' and dst.kind == 'int':
            if dst.is_bool:
                return f'({x} != 0.0)'
            if dst.bits == 64 and not dst.signed:
                return f'C2HFloatToUnsigned({x})'
            t = self.temp('I64i')
            return self.norm(f'({t} = {x})', dst)
        if src.kind == 'float' and dst.kind == 'float':
            return x
        if src.kind == 'ptr' and dst.kind == 'ptr':
            a, b = self.prog.cool(src), self.prog.cool(dst)
            if a == b:
                return x
            return f'(({x})({b}))'
        if src.kind == 'int' and dst.kind == 'ptr':
            return f'(({x})({self.prog.cool(dst)}))'
        if src.kind == 'ptr' and dst.kind == 'int':
            if dst.is_bool:
                return f'({x} != 0)'
            r = f'(({x})(I64i))'
            if dst.bits < 64:
                return self.norm(r, dst)
            return self.relabel(r, dst) if not dst.signed else r
        if src.kind == 'rec' and dst.kind == 'rec':
            return x
        raise CError(f'conversion {src.kind} to {dst.kind}')

    def truth(self, x, t):
        """x as a C condition: text that is nonzero when x is true."""
        if t.kind == 'float':
            return f'({x} != 0.0)'
        return x

    # ------------------------------------------------------------ expressions
    def E(self, n, void=False):
        k = n['kind']
        m = getattr(self, 'e_' + k, None)
        if m is None:
            self.fail(n, 'expression')
        try:
            return m(n, void) if k in ('UnaryOperator', 'BinaryOperator', 'CompoundAssignOperator', 'CallExpr', 'ConditionalOperator') else m(n)
        except CError as e:
            if str(e).startswith(str(self.tu.path)):
                raise
            self.fail(n, str(e))

    def e_ParenExpr(self, n):
        return self.E(kids(n)[0])

    def e_ConstantExpr(self, n):
        c = kids(n)
        if c:
            return self.E(c[0])
        return n['value']

    def e_IntegerLiteral(self, n):
        v = int(n['value'])
        t = self.ct(n)
        if v > 0x7FFFFFFFFFFFFFFF:
            return f'(0x{v:X})'
        return str(v)

    def e_CharacterLiteral(self, n):
        return str(int(n['value']))

    def e_FloatingLiteral(self, n):
        v = float(n['value'])
        if v != v or v in (float('inf'), float('-inf')):
            raise CError('non-finite float literal')
        s = repr(v)
        if 'e' in s and '.' not in s.split('e')[0]:
            a, b = s.split('e')
            s = a + '.0e' + b
        elif '.' not in s and 'e' not in s:
            s += '.0'
        return s

    def e_StringLiteral(self, n):
        return cool_string(c_string_bytes(n['value']))

    def e_PredefinedExpr(self, n):
        return cool_string(self.fname.encode())

    def e_GNUNullExpr(self, n):
        return '0'

    def e_DeclRefExpr(self, n):
        ref = n['referencedDecl']
        k = ref['kind']
        name = ref['name']
        if k == 'EnumConstantDecl':
            return str(self.prog.enum_consts[name])
        if k == 'VarDecl':
            if ref['id'] in self.locals:
                self.uses[ref['id']] = self.uses.get(ref['id'], 0) + 1
                return self.locals[ref['id']]
            if ref['id'] in self.static_locals:
                self.refs.add(('g', self.static_locals[ref['id']][1]))
                return self.static_locals[ref['id']][0]
            if name == '__c2h_argv':
                return 'argv'
            if name == '__c2h_argc':
                return 'argc'
            self.note_ref('g', name)
            return self.static_ref(True, name)
        if k == 'FunctionDecl':
            self.note_ref('f', name)
            return '&' + self.static_ref(True, name)
        if k == 'ParmVarDecl':
            if ref['id'] in self.locals:
                self.uses[ref['id']] = self.uses.get(ref['id'], 0) + 1
                return self.locals[ref['id']]
        self.fail(n, f'reference to {k}')

    def e_ImplicitCastExpr(self, n):
        return self.cast(n)

    def e_CStyleCastExpr(self, n):
        return self.cast(n)

    def cast(self, n):
        c = kids(n)[0]
        kind = n.get('castKind', '')
        dst = self.ct(n)
        if kind in ('LValueToRValue', 'NoOp', 'ToVoid', 'BitCast', 'AtomicToNonAtomic', 'NonAtomicToAtomic', 'BuiltinFnToFnPtr'):
            x = self.E(c)
            if kind == 'ToVoid':
                return x
            return self.conv(x, self.ct(c), dst) if self.ct(c).kind in ('ptr', 'int', 'float') and dst.kind in ('ptr', 'int', 'float') and kind == 'BitCast' else x
        if kind == 'ArrayToPointerDecay':
            base = self.E(c)
            if self.ct(c).to.kind == 'rec': return f'(&({base})[0])'
            return base
        if kind == 'FunctionToPointerDecay':
            return self.E(c)
        if kind == 'NullToPointer':
            self.E(c)
            return f'((0)({self.prog.cool(dst)}))'
        if kind in ('IntegralCast', 'IntegralToFloating', 'FloatingToIntegral', 'FloatingCast',
                    'IntegralToPointer', 'PointerToIntegral', 'IntegralToBoolean', 'PointerToBoolean',
                    'FloatingToBoolean'):
            src = self.ct(c)
            x = self.E(c)
            if kind in ('IntegralToBoolean', 'PointerToBoolean'):
                return f'({x} != 0)'
            if kind == 'FloatingToBoolean':
                return f'({x} != 0.0)'
            return self.conv(x, src, dst)
        if kind == 'LValueBitCast':
            self.fail(n, 'lvalue bit cast')
        self.fail(n, f'cast kind {kind}')

    def e_UnaryOperator(self, n, void=False):
        c = kids(n)[0]
        op = n['opcode']
        t = self.ct(n)
        if op == '&':
            x = self.E(c)
            ct = self.ct(c)
            if ct.kind == 'func':
                return x
            return f'(&{x})'
        if op == '*':
            ct = self.ct(c)
            x = self.E(c)
            if ct.kind == 'ptr' and ct.to.kind == 'func':
                return x
            return f'(*{x})'
        if op in ('++', '--'):
            return self.incdec(n, c, op, n.get('isPostfix'), void)
        x = self.E(c)
        if op == '+':
            return x
        if op == '-':
            if t.kind == 'float':
                return f'(-{x})'
            return self.norm(f'(-{x})', t) if not (t.bits == 32 and t.signed) else f'(-{x})'
        if op == '~':
            return self.norm(f'(~{x})', t) if not t.signed else f'(~{x})'
        if op == '!':
            ct = self.ct(c)
            if ct.kind == 'float':
                return f'({x} == 0.0)'
            return f'(!{x})'
        if op == '__extension__':
            return x
        self.fail(n, f'unary {op}')

    def stable_lvalue(self, c):
        """An lvalue text that evaluates c's side effects once, however often it is used."""
        if not self.impure(c):
            return self.E(c)
        t = self.ct(c)
        p = self.temp(self.prog.cool(ptr_to(t)) if t.kind != 'arr' else 'U8i *')
        self.emit(f'{p} = &{self.E(c)};')
        return f'(*{p})'

    def incdec(self, n, c, op, postfix, void):
        t = self.ct(c)
        delta = '+' if op == '++' else '-'
        if t.kind == 'float':
            lv = self.stable_lvalue(c)
            if void or not postfix:
                return f'({lv} = {lv} {delta} 1.0)'
            tmp = self.temp('F64')
            return f'(({tmp} = {lv}), ({lv} = {tmp} {delta} 1.0), {tmp})'
        if t.kind == 'ptr' or (t.kind == 'int' and (t.bits == 64 or (t.bits == 32 and t.signed))):
            x = self.E(c)
            if self.impure(c):
                lv = self.stable_lvalue(c)
                x = lv
            if postfix and not void:
                return f'({x}{op})'
            return f'({op}{x})'
        if t.kind != 'int':
            self.fail(n, f'{op} on {t.kind}')
        lv = self.stable_lvalue(c)
        if void or not postfix:
            return f'({lv} = {self.norm(f"({lv} {delta} 1)", t)})'
        tmp = self.temp(self.prog.cool(t))
        return f'(({tmp} = {lv}), ({lv} = {self.norm(f"({tmp} {delta} 1)", t)}), {tmp})'

    def operands(self, nodes):
        """Translate operands in order; if a later one needs statements first, materialize earlier impure ones."""
        texts = []
        for n in nodes:
            start = len(self.lines)
            t = self.E(n)
            if len(self.lines) > start:
                ins = []
                for j, (nj, tj) in enumerate(zip(nodes, texts)):
                    if self.impure(nj) and not tj.startswith('_c2hc_t'):
                        cj = self.ct(nj)
                        if cj.kind in ('int', 'float', 'ptr'):
                            tmp = self.temp_for(cj)
                            ins.append((self.level, f'{tmp} = {tj};'))
                            texts[j] = tmp
                self.lines[start:start] = ins
            texts.append(t)
        return texts

    def e_BinaryOperator(self, n, void=False):
        a, b = kids(n)
        op = n['opcode']
        t = self.ct(n)
        if op == ',':
            x = self.E(a, True)
            self.emit(f'{x};')
            return self.E(b, void)
        if op in ('&&', '||'):
            x = self.E(a)
            x = self.truth(x, self.ct(a))
            start = len(self.lines)
            y = self.E(b)
            y = self.truth(y, self.ct(b))
            if len(self.lines) == start:
                return f'({x} {op} {y})'
            pre = self.lines[start:]
            del self.lines[start:]
            r = self.temp('I32i')
            self.emit(f'{r} = ({x}) != 0;')
            self.emit(f'if ({"" if op == "&&" else "!"}{r}) {{')
            for lvl, text in pre:
                self.lines.append((lvl + 1, text))
            self.level += 1
            self.emit(f'{r} = ({y}) != 0;')
            self.level -= 1
            self.emit('}')
            return r
        if op == '=':
            return self.assign(n, a, b, void)
        ca, cb = self.ct(a), self.ct(b)
        x, y = self.operands([a, b])
        if op in ('==', '!=', '<', '>', '<=', '>='):
            return f'({x} {op} {y})'
        if ca.kind == 'ptr' or cb.kind == 'ptr':
            return f'({x} {op} {y})'
        r = f'({x} {op} {y})'
        if t.kind == 'float':
            return r
        if t.kind != 'int':
            self.fail(n, f'binary {op} on {t.kind}')
        if op in ('+', '-', '*'):
            if t.bits == 32 and t.signed:
                return r
            return self.norm(r, t)
        if op == '<<':
            return self.norm(r, t)
        return r

    def assign(self, n, a, b, void):
        ta = self.ct(a)
        if ta.kind == 'rec':
            size = sizeof(ta)
            lv = self.E(a)
            src = self.E(b)
            self.emit(f'MemCpy(&{lv}, &{src}, {size});')
            return lv
        if self.impure(a):
            lv = self.stable_lvalue(a)
            rhs = self.E(b)
        else:
            rhs = self.E(b)
            lv = self.E(a)
        if ta.kind == 'arr':
            self.fail(n, 'assignment to an array')
        return f'({lv} = {rhs})'

    def e_CompoundAssignOperator(self, n, void=False):
        a, b = kids(n)
        op = n['opcode'][:-1]
        ta = self.ct(a)
        comp = n.get('computeResultType') or n.get('computeLHSType')
        tc = self.prog.ctype(comp['qualType']) if comp else ta
        rhs = self.E(b)
        lv = self.stable_lvalue(a)
        if ta.kind == 'ptr':
            return f'({lv} {op}= {rhs})'
        if ta.kind == 'float':
            return f'({lv} {op}= {rhs})'
        native = tc.kind == 'int' and tc.bits == ta.bits and tc.signed == ta.signed and (ta.bits == 64 or (ta.bits == 32 and ta.signed and op in '+-*/%&|^'))
        if native and op not in ('<<', '>>'):
            return f'({lv} {op}= {rhs})'
        if native and ta.bits == 64:
            return f'({lv} {op}= {rhs})'
        cur = self.conv(lv, ta, tc)
        r = f'({cur} {op} {rhs})'
        if tc.kind == 'int' and op in ('+', '-', '*', '<<') and not (tc.bits == 32 and tc.signed and op != '<<'):
            r = self.norm(r, tc)
        return f'({lv} = {self.conv(r, tc, ta)})'

    def e_ConditionalOperator(self, n, void=False):
        c, y, z = kids(n)
        t = self.ct(n)
        # x ? 1 : 0 and friends
        cy, cz = self.unimplicit(y), self.unimplicit(z)
        if (cy['kind'] == 'IntegerLiteral' and cz['kind'] == 'IntegerLiteral' and t.kind == 'int'
                and int(cy['value']) == 1 and int(cz['value']) == 0):
            return f'({self.truth(self.E(c), self.ct(c))} != 0)'
        if t.kind == 'void':
            cond = self.truth(self.E(c), self.ct(c))
            self.emit(f'if ({cond}) {{')
            self.level += 1
            self.emit(f'{self.E(y, True)};')
            self.level -= 1
            self.emit('} else {')
            self.level += 1
            self.emit(f'{self.E(z, True)};')
            self.level -= 1
            self.emit('}')
            return '0'
        if t.kind == 'rec':
            self.fail(n, 'record-valued conditional')
        r = self.temp_for(t)
        cond = self.truth(self.E(c), self.ct(c))
        self.emit(f'if ({cond}) {{')
        self.level += 1
        self.emit(f'{r} = {self.E(y)};')
        self.level -= 1
        self.emit('} else {')
        self.level += 1
        self.emit(f'{r} = {self.E(z)};')
        self.level -= 1
        self.emit('}')
        return r

    def e_MemberExpr(self, n):
        c = kids(n)[0]
        ct = self.ct(c)
        if ct.kind in ('ptr', 'arr'): ct = ct.to
        name = n['name'] if ct.kind == 'rec' and ct.rec.external else self.prog.cool_ident(n['name'])
        base = self.E(c)
        if n.get('isArrow'):
            return f'({base}->{name})'
        return f'({base}.{name})'

    def e_ArraySubscriptExpr(self, n):
        a, b = kids(n)
        x, y = self.operands([a, b])
        return f'({x}[{y}])'

    def e_UnaryExprOrTypeTraitExpr(self, n):
        name = n.get('name')
        arg = n.get('argType')
        if arg is None:
            arg = kids(n)[0]['type']
        t = self.prog.ctype(arg['qualType'])
        if name == 'sizeof':
            return str(sizeof(t))
        if name in ('alignof', '_Alignof', '__alignof'):
            return str(alignof(t))
        self.fail(n, f'trait {name}')

    def e_OffsetOfExpr(self, n):
        self.fail(n, 'offsetof')

    def e_CompoundLiteralExpr(self, n):
        self.fail(n, 'compound literal')

    def e_CallExpr(self, n, void=False):
        c = kids(n)
        callee, args = c[0], c[1:]
        target = self.unimplicit(callee)
        ft = None
        name = None
        if target['kind'] == 'DeclRefExpr' and target['referencedDecl']['kind'] == 'FunctionDecl':
            name = target['referencedDecl']['name']
        rt = self.ct(n)
        # builtins
        if name in ('setjmp', '_setjmp', '__builtin_setjmp'):
            buf = self.E(args[0])
            return f'LC_JmpResult({buf}, AIWNIOS_SetJmp({buf}))'
        if name == '__builtin_expect':
            x = self.E(args[0])
            self.E(args[1])
            return x
        if name in ('__builtin_unreachable', '__builtin_trap'):
            return '0'
        if name in ('__builtin_huge_val', '__builtin_inf'):
            return 'LC_INF_VALUE()'
        if name in ('__builtin_inff', '__builtin_huge_valf'):
            return 'LC_INF_VALUE()'
        if name in ('__builtin_nan', '__builtin_nanf'):
            return 'LC_NAN_VALUE()'
        if name in ('__builtin_ctz', '__builtin_ctzl', '__builtin_ctzll'):
            return f'LC_ctz({self.E(args[0])})'
        if name in ('__builtin_clz', '__builtin_clzl', '__builtin_clzll'):
            bits = 32 if name == '__builtin_clz' else 64
            return f'LC_clz({self.E(args[0])}, {bits})'
        if name in ('__builtin_popcount', '__builtin_popcountl', '__builtin_popcountll'):
            return f'LC_popcount({self.E(args[0])})'
        if name and name.startswith('__builtin_'):
            self.fail(n, f'builtin {name}')
        texts = self.operands(args)
        if name is not None:
            self.note_ref('f', name)
            fname = self.static_ref(True, name)
            fct = self.prog.ctype(target['referencedDecl']['type']['qualType'])
            return f'{fname}({", ".join(texts)})'
        # through a pointer
        pct = self.ct(callee)
        if pct.kind == 'arr':
            self.fail(n, 'call of an array')
        if pct.kind == 'ptr' and pct.to.kind == 'func':
            fct = pct.to
        elif pct.kind == 'func':
            fct = pct
        else:
            self.fail(n, 'call of a non-function')
        if fct.variadic:
            self.fail(n, 'call of a variadic function through a pointer')
        thunk = self.prog.thunk(fct)
        fp = self.E(callee)
        return f'{thunk}({", ".join([fp] + texts)})'

    def e_InitListExpr(self, n):
        self.fail(n, 'initializer list in an expression')

    def e_StmtExpr(self, n):
        self.fail(n, 'statement expression')

    def e_VAArgExpr(self, n):
        self.fail(n, 'va_arg')

    def e_ImplicitValueInitExpr(self, n):
        t = self.ct(n)
        return '0.0' if t.kind == 'float' else '0'

    # ------------------------------------------------------------ initializers
    def zero_text(self, t):
        return '0.0' if t.kind == 'float' else '0'

    def init_object(self, lv, t, n, zeroed):
        """Statements storing the initializer n into the object lv of type t."""
        n0 = n
        n = self.strip(n)
        if n['kind'] == 'InitListExpr':
            elems = kids(n)
            if t.kind == 'arr':
                et = t.to
                if 'array_filler' in n: elems = n['array_filler'][1:]
                for i, e in enumerate(elems):
                    if e['kind'] == 'ImplicitValueInitExpr' and zeroed:
                        continue
                    self.init_object(f'{lv}[{i}]', et, e, zeroed)
                filler = n.get('array_filler')
                if filler and not zeroed and t.n is not None and len(elems) < t.n:
                    self.emit(f'MemSet(&{lv}[{len(elems)}], 0, {sizeof(et) * (t.n - len(elems))});')
                return
            if t.kind == 'rec':
                fields = t.rec.fields
                if t.rec.is_union:
                    if elems:
                        e = elems[0]
                        fname = (n.get('field') or {}).get('name') or fields[0][0]
                        matches = [f[1] for f in fields if f[0] == fname]
                        if not matches: self.fail(n, f'union field {fname} absent from {t.rec.name}: {fields}')
                        ft = matches[0]
                        self.init_object(f'{lv}.{self.prog.cool_ident(fname)}', ft, e, zeroed)
                    return
                for i, e in enumerate(elems):
                    if e['kind'] == 'ImplicitValueInitExpr' and zeroed:
                        continue
                    fname, ft, _ = fields[i]
                    self.init_object(f'{lv}.{self.prog.cool_ident(fname)}', ft, e, zeroed)
                return
            if len(elems) == 1:
                self.init_object(lv, t, elems[0], zeroed)
                return
            self.fail(n, 'initializer list for a scalar')
        if n['kind'] == 'ImplicitValueInitExpr':
            if not zeroed:
                if t.is_scalar():
                    self.emit(f'{lv} = {self.zero_text(t)};')
                else:
                    self.emit(f'MemSet(&{lv}, 0, {sizeof(t)});')
            return
        if t.kind == 'arr':
            u = self.unimplicit(n0)
            if u['kind'] != 'StringLiteral':
                self.fail(n, 'array initialized by an expression')
            data = c_string_bytes(u['value'])
            size = sizeof(t)
            data = data[:size]
            if b'\x00' in data[:-1] or len(data) > 200:
                for i, b in enumerate(data):
                    if b or not zeroed:
                        self.emit(f'{lv}[{i}] = {b};')
                for i in range(len(data), size):
                    if not zeroed:
                        self.emit(f'{lv}[{i}] = 0;')
            else:
                self.emit(f'MemCpy({lv}, {cool_string(data)}, {len(data)});')
                if not zeroed and size > len(data):
                    self.emit(f'MemSet(&{lv}[{len(data)}], 0, {size - len(data)});')
            return
        if t.kind == 'rec':
            self.emit(f'MemCpy(&{lv}, &{self.E(n0)}, {sizeof(t)});')
            return
        self.emit(f'{lv} = {self.E(n0)};')

    def global_init(self, key, n, init):
        prog = self.prog
        g = prog.globals[key]
        name = f'{STATIC_A}{key[0]}{STATIC_B}{key[1]}{STATIC_C}' if key[0] else key[1]
        self.level = 1
        self.init_object(name, g.ct, init, True)
        self.refs.add(('g', key))
        prog.inits.append((key, self.render_body(), self.refs, self.decls))

    # ------------------------------------------------------------ statements
    def render_body(self):
        return [('    ' * lvl) + text for lvl, text in self.lines]

    def register_local(self, n):
        t = self.prog.ctype(n['type']['qualType'])
        base = n.get('name') or f'p{len(self.locals)}'
        name = self.local_name(base)
        text = self.sentinel_local(name)
        self.locals[n['id']] = text
        return text, t

    def s_DeclStmt(self, n):
        for v in kids(n):
            k = v['kind']
            if k == 'VarDecl':
                self.local_var(v)
            elif k in ('TypedefDecl', 'RecordDecl', 'EnumDecl', 'StaticAssertDecl'):
                # types are program-wide; a local one is registered like a file-level one
                getattr(self.tu, {'TypedefDecl': 'typedef', 'RecordDecl': 'record', 'EnumDecl': 'enum', 'StaticAssertDecl': 'enum'}[k])(*( (v, False) if k != 'EnumDecl' and k != 'StaticAssertDecl' else (v,)))
            else:
                self.fail(v, 'local declaration')

    def local_var(self, v):
        prog = self.prog
        t = prog.ctype(v['type']['qualType'])
        init = [c for c in kids(v)]
        if v.get('storageClass') == 'static':
            gname = f'{self.fname}_{v["name"]}'
            key = (self.tu.stem, gname)
            self.tu.statics.add(gname)
            from c2hc import Global
            prog.globals[key] = Global(gname, t, True, self.tu.stem, False)
            prog.global_order.append(key)
            prog.globals[key].defined = True
            self.static_locals[v['id']] = (f'{STATIC_A}{self.tu.stem}{STATIC_B}{gname}{STATIC_C}', key)
            if init:
                sub = FnTranslator(self.tu, self.key)
                sub.static_locals = self.static_locals
                sub.locals = self.locals
                sub.level = 1
                sub.init_object(self.static_locals[v['id']][0], t, init[0], True)
                prog.inits.append((key, sub.render_body(), sub.refs | {('g', key)}, sub.decls))
            return
        if v.get('storageClass') == 'extern':
            self.note_ref('g', v['name'])
            self.locals[v['id']] = v['name']
            return
        text, t = self.register_local(v)
        name = text[1:-1]
        self.decls.append((t, name, v['id']))
        if init:
            i0 = init[0]
            zeroed = False
            u = self.strip(i0)
            if u['kind'] == 'InitListExpr' or (t.kind == 'arr'):
                if t.kind in ('arr', 'rec'):
                    self.emit(f'MemSet(&{text}, 0, {sizeof(t)});')
                    zeroed = True
            self.init_object(text, t, i0, zeroed)

    def s_CompoundStmt(self, n):
        for c in kids(n):
            self.stmt(c)

    def s_NullStmt(self, n):
        pass

    def s_AttributedStmt(self, n):
        for c in kids(n):
            self.stmt(c)

    def s_ReturnStmt(self, n):
        c = kids(n)
        if not c:
            self.emit('return;')
            return
        x = self.E(c[0])
        self.emit(f'return {x};')

    def expr_stmt(self, n):
        k = n['kind']
        if k == 'BinaryOperator' and n['opcode'] == '=':
            a, b = kids(n)
            if self.ct(a).kind == 'rec':
                lv = self.E(a)
                src = self.E(b)
                self.emit(f'MemCpy(&{lv}, &{src}, {sizeof(self.ct(a))});')
                return
        x = self.E(n, True)
        if x and not re.fullmatch(r'[\w.\-]+|0', x):
            self.emit(f'{x};')

    def cond(self, c):
        x = self.E(c)
        return self.truth(x, self.ct(c))

    def block(self, n):
        """A statement as a { } body."""
        self.level += 1
        self.stmt(n)
        self.level -= 1

    def s_IfStmt(self, n):
        c = kids(n)
        if n.get('hasVar') or n.get('hasInit'):
            self.fail(n, 'if with a declaration')
        cond = self.cond(c[0])
        self.emit(f'if ({cond}) {{')
        self.block(c[1])
        if len(c) > 2:
            self.emit('} else {')
            self.block(c[2])
        self.emit('}')

    def loop_label(self):
        self.label_count = getattr(self, 'label_count', 0)
        self.prog.label_serial = getattr(self.prog, 'label_serial', 0) + 1
        return f'_c2hc_continue_{self.prog.label_serial}'

    def captured_cond(self, c):
        """(pre lines relative to level 0, condition text) of a loop condition."""
        start = len(self.lines)
        old = self.level
        self.level = 0
        x = self.cond(c)
        self.level = old
        pre = self.lines[start:]
        del self.lines[start:]
        return pre, x

    def s_WhileStmt(self, n):
        c = kids(n)
        label = self.loop_label()
        pre, x = self.captured_cond(c[0])
        if not pre:
            self.emit(f'while ({x}) {{')
        else:
            self.emit('while (1) {')
            for lvl, text in pre:
                self.lines.append((self.level + 1 + lvl, text))
            self.emit(f'    if (!({x})) break;')
        self.loops.append([label, False])
        self.block(c[-1])
        used = self.loops.pop()[1]
        if used:
            self.emit(f'    {label}:;')
        self.emit('}')
        if used and pre:
            pass

    def s_DoStmt(self, n):
        c = kids(n)
        label = self.loop_label()
        self.emit('do {')
        self.loops.append([label, False])
        self.block(c[0])
        used = self.loops.pop()[1]
        if used:
            self.emit(f'    {label}:;')
        self.level += 1
        x = self.cond(c[1])
        self.level -= 1
        self.emit(f'}} while ({x});')

    def s_ForStmt(self, n):
        slots = n.get('inner', [])
        slots = (slots + [None] * 5)[:5]
        init, _, cond, step, body = slots
        label = self.loop_label()
        if init and init.get('kind'):
            self.stmt(init)
        if cond and cond.get('kind'):
            pre, x = self.captured_cond(cond)
        else:
            pre, x = [], '1'
        if not pre:
            self.emit(f'while ({x}) {{')
        else:
            self.emit('while (1) {')
            for lvl, text in pre:
                self.lines.append((self.level + 1 + lvl, text))
            self.emit(f'    if (!({x})) break;')
        self.loops.append([label, False])
        self.block(body)
        used = self.loops.pop()[1]
        if used:
            self.emit(f'    {label}:;')
        if step and step.get('kind'):
            self.level += 1
            self.expr_stmt(step)
            self.level -= 1
        self.emit('}')

    def s_ContinueStmt(self, n):
        if not self.loops:
            self.fail(n, 'continue outside a loop')
        self.loops[-1][1] = True
        self.emit(f'goto {self.loops[-1][0]};')

    def s_BreakStmt(self, n):
        self.emit('break;')

    def s_GotoStmt(self, n):
        self.emit(f'goto {self.label(n["targetLabelDeclId"])};')

    def label(self, decl_id):
        if decl_id not in self.label_names:
            self.prog.label_serial = getattr(self.prog, 'label_serial', 0) + 1
            self.label_names[decl_id] = f'_c2hc_label_{self.prog.label_serial}'
        return self.label_names[decl_id]

    def s_LabelStmt(self, n):
        self.emit(f'{self.label(n["declId"])}:;')
        for c in kids(n):
            self.stmt(c)

    def s_SwitchStmt(self, n):
        c = kids(n)
        if n.get('hasVar') or n.get('hasInit'):
            self.fail(n, 'switch with a declaration')
        x = self.E(c[0])
        vals = []
        self.collect_cases(c[1], vals)
        if vals and (max(vals) - min(vals) > 60000):
            self.fail(n, 'switch with a wide range of cases')
        self.emit(f'switch ({x}) {{')
        self.level += 1
        self.switch_depth += 1
        self.stmt(c[1])
        self.switch_depth -= 1
        self.level -= 1
        self.emit('}')

    def collect_cases(self, n, vals):
        if n['kind'] == 'CaseStmt':
            vals.append(self.tu.const_int(kids(n)[0]))
        if n['kind'] in ('CompoundStmt', 'CaseStmt', 'DefaultStmt', 'LabelStmt', 'AttributedStmt', 'IfStmt', 'WhileStmt', 'DoStmt', 'ForStmt'):
            for c in kids(n):
                self.collect_cases(c, vals)

    def s_CaseStmt(self, n):
        c = kids(n)
        if n.get('inner') and any(x.get('kind') is None for x in n['inner']):
            pass
        v = self.tu.const_int(c[0])
        self.emit(f'case {v}:')
        self.level += 1
        for s in c[1:]:
            self.stmt(s)
        self.level -= 1

    def s_DefaultStmt(self, n):
        self.emit('default:')
        self.level += 1
        for s in kids(n):
            self.stmt(s)
        self.level -= 1

    def stmt(self, n):
        k = n['kind']
        m = getattr(self, 's_' + k, None)
        if m is not None:
            m(n)
        else:
            self.expr_stmt(n)

    # ------------------------------------------------------------ functions
    def function(self, n, body):
        prog = self.prog
        ft = prog.ctype(n['type']['qualType'])
        self.ret = ft.to
        self.variadic = ft.variadic
        params = [p for p in kids(n) if p['kind'] == 'ParmVarDecl']
        ptext = []
        for i, p in enumerate(params):
            pt = prog.ctype(p['type']['qualType'])
            if pt.kind == 'arr':
                pt = ptr_to(pt.to)
            if pt.kind == 'rec':
                self.fail(p, 'record passed by value')
            if pt.kind == 'func':
                pt = ptr_to(pt)
            if not p.get('name'):
                p = dict(p)
                p['name'] = f'unused{i}'
            base = p['name']
            if base in ('argc', 'argv'):
                base = 'c_' + base
            name = self.local_name(base)
            self.locals[p['id']] = self.sentinel_local(name)
            self.uses[p['id']] = 1
            ptext.append(prog.decl(pt, self.sentinel_local(name)))
        if self.variadic:
            ptext.append('...')
        if ft.to.kind == 'rec':
            self.fail(n, 'record returned by value')
        if ft.to.kind == 'arr':
            self.fail(n, 'array returned')
        ret = prog.cool(ft.to)
        fname = self.static_ref(True, n['name'])
        self.level = 1
        self.stmt(body)
        head = f'{ret} {fname}({", ".join(ptext)}) {{'
        lines = [head]
        unused = []
        for d in self.decls:
            if len(d) == 3:
                t, name, vid = d
                lines.append('    ' + prog.decl(t, self.sentinel_local(name)) + ';')
                if not self.uses.get(vid):
                    unused.append(self.sentinel_local(name))
            else:
                t, name = d
                lines.append(f'    {t} {name};')
                unused.append(name)
        if unused:
            lines.append('    no_warn ' + ', '.join(unused) + ';')
        lines += self.render_body()
        lines.append('}')
        return '\n'.join(lines), self.refs
