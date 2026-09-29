#!/usr/bin/env python3
"""A deliberately small AST based C to Cool translator.

Unsupported constructs fail with a source location instead of being copied as C.
The clang AST supplies types and statement structure; no token level C rewriting
is used for expressions.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

BASE = {'void': 'U0', 'char': 'U8i', 'signed char': 'I8i',
        'unsigned char': 'U8i', 'short': 'I16i', 'unsigned short': 'U16i',
        'int': 'I32i', 'unsigned int': 'U32i', 'long': 'I64i',
        'unsigned long': 'U64i', 'long long': 'I64i',
        'unsigned long long': 'U64i', '_Bool': 'I8i',
        'float': 'F64', 'double': 'F64'}
KEYWORDS = {'reg', 'class', 'union', 'public', 'private', 'lock', 'try', 'catch',
            'throw', 'import', 'export', 'asm', 'Bool', 'Print', 'I32', 'U32'}
WRAPPERS = {'ImplicitCastExpr', 'ParenExpr', 'ConstantExpr', 'ExprWithCleanups'}


class Translator:
    def __init__(self, path, roots=None):
        self.path = Path(path).resolve()
        self.source = self.path.read_text()
        command = ['clang', '-std=c11', '-fsyntax-only', '-Xclang', '-ast-dump=json', str(self.path)]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise ValueError(result.stderr)
        self.ast = json.loads(result.stdout)
        self.lines = []
        self.static = []
        self.function = ''
        self.loop = []
        self.serial = 0
        self.static_names = {}
        self.roots = roots
        self.aliases = {}
        self.record_names = {}
        self.record_fields = {}
        self.enums = {}
        self.select_types = {}
        self.local_names = {}
        self.labels = {}

    def fail(self, node, detail):
        loc = node.get('range', {}).get('begin', node.get('loc', {}))
        raise ValueError(f'{self.path}:{loc.get("line", "?")}:{loc.get("col", "?")}: unsupported {detail} ({node.get("kind")})')

    def name(self, value):
        return 'c_' + value if value in KEYWORDS else value

    def typ(self, spelling, node=None):
        spelling = re.sub(r'\b(const|volatile|restrict|static)\b', '', spelling).strip()
        array = re.search(r'\[(\d+)\]$', spelling)
        if array:
            return self.typ(spelling[:array.start()].strip(), node), int(array.group(1))
        pointers = spelling.count('*')
        spelling = spelling.replace('*', '').strip()
        if spelling.startswith('struct '):
            result = self.name(spelling[7:])
        elif spelling.startswith('enum '):
            result = 'I32i'
        elif spelling in BASE:
            result = BASE[spelling]
        elif spelling in self.aliases:
            result = self.typ(self.aliases[spelling], node)
        else:
            self.fail(node or {}, f'type {spelling}')
        if isinstance(result, tuple):
            self.fail(node or {}, f'pointer to array type {spelling}')
        return result + ' *' * pointers

    def decl(self, node):
        t = self.typ(node['type']['qualType'], node)
        n = self.local_names.get(node['id'], self.name(node['name']))
        if isinstance(t, tuple):
            return f'{t[0]} {n}[{t[1]}]'
        return f'{t} {n}'

    def children(self, node):
        return [x for x in node.get('inner', []) if x.get('kind') and
                not x['kind'].endswith('Comment')]

    def unwrap(self, node):
        while node['kind'] in WRAPPERS:
            node = self.children(node)[0]
        return node

    def narrowed(self, expression, node):
        """HolyC promotes small integer operations to 64 bits; C does not."""
        spelling = node.get('type', {}).get('qualType', '')
        widths = {'int': (32, True), 'unsigned int': (32, False),
                  'short': (16, True), 'unsigned short': (16, False),
                  'char': (8, False), 'signed char': (8, True),
                  'unsigned char': (8, False)}
        if spelling not in widths:
            return expression
        bits, signed = widths[spelling]
        mask = (1 << bits) - 1
        clipped = f'({expression} & 0x{mask:X})'
        if not signed:
            return clipped
        sign = 1 << (bits - 1)
        return f'(({clipped} ^ 0x{sign:X}) - 0x{sign:X})'

    def pure(self, node):
        n = self.unwrap(node)
        if n['kind'] in ('CallExpr', 'CompoundAssignOperator'):
            return False
        if n['kind'] == 'UnaryOperator' and n['opcode'] in ('++', '--'):
            return False
        if n['kind'] == 'BinaryOperator' and n['opcode'] in ('=', ','):
            return False
        return all(self.pure(child) for child in self.children(n))

    def expr(self, node):
        n = self.unwrap(node)
        k = n['kind']
        ch = self.children(n)
        if k == 'IntegerLiteral':
            return n['value']
        if k == 'FloatingLiteral':
            return n['value'].rstrip('fF')
        if k == 'StringLiteral':
            return n['value']
        if k == 'CharacterLiteral':
            return str(n['value'])
        if k == 'DeclRefExpr':
            ref = n['referencedDecl']
            if ref['name'] in self.enums:
                return str(self.enums[ref['name']])
            return self.static_names.get(ref['id'],
                                         self.local_names.get(ref['id'], self.name(ref['name'])))
        if k == 'UnaryOperator':
            x = self.expr(ch[0])
            op = n['opcode']
            result = f'({x}{op})' if n.get('isPostfix') else f'({op}{x})'
            return self.narrowed(result, n) if op in ('-', '~') else result
        if k in ('BinaryOperator', 'CompoundAssignOperator'):
            a, b = map(self.expr, ch)
            op = n['opcode']
            if op == '=' and n['type']['qualType'].startswith('struct ') and '*' not in n['type']['qualType']:
                self.fail(n, 'struct assignment in expression position')
            result = f'({a} {op} {b})'
            if k == 'BinaryOperator' and op in ('+', '-', '*', '/', '%', '<<', '>>', '&', '|', '^'):
                return self.narrowed(result, n)
            return result
        if k == 'ArraySubscriptExpr':
            return f'({self.expr(ch[0])}[{self.expr(ch[1])}])'
        if k == 'MemberExpr':
            return f'({self.expr(ch[0])}{"->" if n.get("isArrow") else "."}{self.name(n["name"])})'
        if k == 'CallExpr':
            callee = self.expr(ch[0])
            callee = {'printf': 'Print', 'malloc': 'MAlloc', 'free': 'Free',
                      'memcpy': 'MemCpy', 'memset': 'MemSet', 'strlen': 'StrLen',
                      'floor': 'C2HFloor', 'ceil': 'C2HCeil', 'sqrt': 'C2HSqrt',
                      'fabs': 'C2HFabs', 'fmod': 'C2HFmod', 'cos': 'C2HCos',
                      'acos': 'C2HAcos', 'pow': 'C2HPow'}.get(callee, callee)
            return f'{callee}({", ".join(self.expr(x) for x in ch[1:])})'
        if k == 'CStyleCastExpr':
            target = self.typ(n['type']['qualType'], n)
            source = self.typ(ch[0]['type']['qualType'], ch[0])
            if target == 'U0':
                return self.expr(ch[0])
            if target == 'F64' and source != 'F64':
                return f'C2HIntToFloat({self.expr(ch[0])})'
            if target != 'F64' and source == 'F64':
                return f'(C2HFloatToInt({self.expr(ch[0])}))({target})'
            return f'({self.expr(ch[0])})({target})'
        if k == 'ConditionalOperator':
            target = self.typ(n['type']['qualType'], n)
            if not all(self.pure(branch) for branch in ch[1:]):
                self.fail(n, 'side effects in nested conditional expression')
            if target not in BASE.values() and not target.endswith(' *'):
                self.fail(n, 'record-valued conditional expression')
            helper = f'_c2hc_select_{len(self.select_types)}'
            if target not in self.select_types:
                self.select_types[target] = helper
            return f'{self.select_types[target]}({self.expr(ch[0])}, {self.expr(ch[1])}, {self.expr(ch[2])})'
        if k == 'UnaryExprOrTypeTraitExpr' and n.get('name') == 'sizeof':
            arg_type = n.get('argType') or ch[0]['type']
            return f'sizeof({self.typ(arg_type["qualType"], n)})'
        self.fail(n, 'expression')

    def out(self, indent, content):
        self.lines.append('    ' * indent + content)

    def value(self, node, target, indent):
        n = self.unwrap(node)
        if n['kind'] == 'ConditionalOperator':
            condition, yes, no = self.children(n)
            self.out(indent, f'if ({self.expr(condition)}) {{')
            self.value(yes, target, indent + 1)
            self.out(indent, '} else {')
            self.value(no, target, indent + 1)
            self.out(indent, '}')
        else:
            self.out(indent, f'{target} = {self.expr(n)};')

    def vars(self, node, indent):
        for v in self.children(node):
            if v['kind'] != 'VarDecl':
                self.fail(v, 'declaration')
            initial = self.children(v)
            if v.get('storageClass') == 'static':
                if len(initial) > 1 or (initial and initial[0]['kind'] == 'InitListExpr'):
                    self.fail(v, 'static initializer')
                new_name = self.function + '_' + self.name(v['name'])
                self.static_names[v['id']] = new_name
                self.static.append(self.decl(v).replace(' ' + self.name(v['name']), ' ' + new_name, 1) +
                                   (f' = {self.expr(initial[0])}' if initial else '') + ';')
                continue
            self.out(indent, self.decl(v) + ';')
            if initial:
                init = self.unwrap(initial[0])
                name = self.local_names.get(v['id'], self.name(v['name']))
                if init['kind'] == 'InitListExpr':
                    elems = self.children(init)
                    if not elems and init.get('array_filler'):
                        elems = init['array_filler'][1:]
                    t = self.typ(v['type']['qualType'], v)
                    if not isinstance(t, tuple):
                        if t not in self.record_fields:
                            self.fail(v, 'record initializer')
                        self.out(indent, f'MemSet(&{name}, 0, sizeof({t}));')
                        for field, elem in zip(self.record_fields[t], elems):
                            if elem['kind'] != 'ImplicitValueInitExpr':
                                self.out(indent, f'{name}.{field} = {self.expr(elem)};')
                        continue
                    for i, elem in enumerate(elems):
                        self.out(indent, f'{name}[{i}] = {self.expr(elem)};')
                    for i in range(len(elems), t[1]):
                        self.out(indent, f'{name}[{i}] = 0;')
                else:
                    self.value(init, name, indent)

    def statement(self, node, indent):
        n = self.unwrap(node)
        k = n['kind']
        ch = self.children(n)
        if k == 'CompoundStmt':
            for x in ch:
                self.statement(x, indent)
        elif k == 'DeclStmt':
            self.vars(n, indent)
        elif k == 'ReturnStmt':
            if ch and self.unwrap(ch[0])['kind'] == 'ConditionalOperator':
                temp = f'_c2hc_return_{self.serial}'; self.serial += 1
                self.out(indent, f'{self.typ(ch[0]["type"]["qualType"], ch[0])} {temp};')
                self.value(ch[0], temp, indent)
                self.out(indent, f'return {temp};')
            else:
                self.out(indent, 'return' + (f' {self.expr(ch[0])}' if ch else '') + ';')
        elif k == 'IfStmt':
            self.out(indent, f'if ({self.expr(ch[0])}) {{')
            self.statement(ch[1], indent + 1)
            self.out(indent, '}')
            if len(ch) > 2:
                self.out(indent, 'else {')
                self.statement(ch[2], indent + 1)
                self.out(indent, '}')
        elif k == 'SwitchStmt':
            self.out(indent, f'switch ({self.expr(ch[0])}) {{')
            self.statement(ch[1], indent + 1)
            self.out(indent, '}')
        elif k == 'CaseStmt':
            self.out(indent, f'case {self.expr(ch[0])}:')
            for item in ch[1:]:
                self.statement(item, indent + 1)
        elif k == 'DefaultStmt':
            self.out(indent, 'default:')
            for item in ch:
                self.statement(item, indent + 1)
        elif k in ('ForStmt', 'WhileStmt', 'DoStmt'):
            label = f'_c2hc_continue_{self.serial}'; self.serial += 1
            if k == 'ForStmt':
                # clang keeps empty for-clause slots as untyped dictionaries.
                slots = n.get('inner', [])
                init, _, cond, step, body = (slots + [None] * 5)[:5]
                if init and init.get('kind'):
                    self.statement(init, indent)
                self.out(indent, f'while ({self.expr(cond) if cond and cond.get("kind") else "1"}) {{')
                self.loop.append(label)
                self.statement(body, indent + 1)
                self.loop.pop()
                self.out(indent + 1, label + ':;')
                if step and step.get('kind'):
                    self.statement(step, indent + 1)
                self.out(indent, '}')
            elif k == 'WhileStmt':
                self.out(indent, f'while ({self.expr(ch[0])}) {{')
                self.loop.append(label)
                self.statement(ch[1], indent + 1)
                self.loop.pop()
                self.out(indent + 1, label + ':;')
                self.out(indent, '}')
            else:
                self.out(indent, 'do {')
                self.loop.append(label)
                self.statement(ch[0], indent + 1)
                self.loop.pop()
                self.out(indent + 1, label + ':;')
                self.out(indent, f'}} while ({self.expr(ch[1])});')
        elif k == 'ContinueStmt':
            if not self.loop: self.fail(n, 'continue outside loop')
            self.out(indent, f'goto {self.loop[-1]};')
        elif k == 'BreakStmt':
            self.out(indent, 'break;')
        elif k == 'GotoStmt':
            self.out(indent, f'goto {self.labels[n["targetLabelDeclId"]]};')
        elif k == 'LabelStmt':
            self.out(indent, f'{self.labels[n["declId"]]}:;')
            for item in ch:
                self.statement(item, indent)
        elif k == 'NullStmt':
            self.out(indent, ';')
        elif k == 'BinaryOperator' and n['opcode'] == '=' and n['type']['qualType'].startswith('struct ') and '*' not in n['type']['qualType']:
            dst, src = ch
            self.out(indent, f'MemCpy(&{self.expr(dst)}, &{self.expr(src)}, sizeof({self.typ(n["type"]["qualType"], n)}));')
        elif k == 'BinaryOperator' and n['opcode'] == '=' and self.unwrap(ch[1])['kind'] == 'ConditionalOperator':
            self.value(ch[1], self.expr(ch[0]), indent)
        elif k in ('CallExpr', 'BinaryOperator', 'CompoundAssignOperator', 'UnaryOperator',
                   'CStyleCastExpr'):
            self.out(indent, self.expr(n) + ';')
        else:
            self.fail(n, 'statement')

    def translate(self):
        records, globals_, functions = [], [], []
        nodes = self.children(self.ast)
        for n in nodes:
            if n['kind'] == 'TypedefDecl' and 'offset' in n.get('loc', {}):
                spelling = n['type']['qualType']
                if spelling != n['name']:
                    self.aliases[n['name']] = spelling
                for child in self.children(n):
                    tag = child.get('ownedTagDecl', {})
                    if tag.get('kind') == 'RecordDecl':
                        self.record_names[tag['id']] = n['name']
            if n['kind'] == 'EnumDecl' and 'offset' in n.get('loc', {}):
                value = -1
                for child in self.children(n):
                    if child['kind'] != 'EnumConstantDecl':
                        continue
                    if self.children(child):
                        expr = self.unwrap(self.children(child)[0])
                        value = int(expr.get('value', value + 1), 0)
                    else:
                        value += 1
                    self.enums[child['name']] = value
        if self.roots:
            by_name = {n['name']: n for n in nodes if n['kind'] == 'FunctionDecl'
                       and any(x['kind'] == 'CompoundStmt' for x in self.children(n))}
            selected = set()
            pending = list(self.roots)
            while pending:
                name = pending.pop()
                if name in selected:
                    continue
                if name not in by_name:
                    raise ValueError(f'root function not found: {name}')
                selected.add(name)
                stack = [by_name[name]]
                while stack:
                    item = stack.pop()
                    if item.get('kind') == 'DeclRefExpr':
                        ref = item.get('referencedDecl', {})
                        if ref.get('kind') == 'FunctionDecl' and ref.get('name') in by_name:
                            pending.append(ref['name'])
                    stack.extend(self.children(item))
        else:
            selected = None
        for n in nodes:
            loc = n.get('loc', {})
            if not self.roots:
                if loc.get('includedFrom'):
                    continue
                if loc.get('file') and Path(loc['file']).resolve() != self.path:
                    continue
            if 'offset' not in loc:
                continue
            k = n['kind']
            if k == 'RecordDecl' and n.get('completeDefinition') and (n.get('name') or n['id'] in self.record_names):
                fields = [f for f in self.children(n) if f['kind'] == 'FieldDecl']
                record_name = self.name(n.get('name') or self.record_names[n['id']])
                self.record_fields[record_name] = [self.name(f['name']) for f in fields]
                records.append('class ' + record_name + ' {\n' +
                               ''.join('    ' + self.decl(f) + ';\n' for f in fields) + '};')
            elif k == 'FunctionDecl' and any(x['kind'] == 'CompoundStmt' for x in self.children(n)):
                if selected is None or n['name'] in selected:
                    functions.append(n)
            elif k == 'VarDecl':
                globals_.append(self.decl(n) + ';')
            elif k in ('FunctionDecl', 'TypedefDecl', 'EnumDecl', 'RecordDecl'):
                pass  # C prototypes, including printf
            else:
                self.fail(n, 'top level declaration')
        self.lines = ['// Generated by tools/c2hc/c2hc.py from ' + self.path.name,
                      'extern U0 Print(U8i *fmt, ...);',
                      'extern U8i *MemCpy(U8i *dst, U8i *src, I64i cnt);',
                      'extern U8i *MemSet(U8i *dst, I64i value, I64i cnt);',
                      'extern U8i *MAlloc(I64i size);',
                      'extern U0 Free(U8i *ptr);',
                      'extern I64i StrLen(U8i *ptr);',
                      'extern F64 C2HFloor(F64 x);',
                      'extern F64 C2HCeil(F64 x);',
                      'extern F64 C2HSqrt(F64 x);',
                      'extern F64 C2HFabs(F64 x);',
                      'extern F64 C2HFmod(F64 x, F64 y);',
                      'extern F64 C2HCos(F64 x);',
                      'extern F64 C2HAcos(F64 x);',
                      'extern F64 C2HPow(F64 x, F64 y);',
                      'extern I64i C2HFloatToInt(F64 x);',
                      'extern F64 C2HIntToFloat(I64i x);',
                      *records, *globals_]
        if self.roots:
            for n in functions:
                args = [x for x in self.children(n) if x['kind'] == 'ParmVarDecl']
                return_type = n['type']['qualType'].split('(', 1)[0].strip()
                self.lines.append(f'extern {self.typ(return_type, n)} {self.name(n["name"])}(' +
                                  ', '.join(self.decl(x) for x in args) + ');')
        prefix = len(self.lines)
        for n in functions:
            self.function = self.name(n['name'])
            ch = self.children(n)
            counts = {}
            stack = [ch[-1]]
            while stack:
                item = stack.pop()
                if item['kind'] == 'LabelStmt':
                    self.labels[item['declId']] = f'_c2hc_label_{len(self.labels)}'
                if item['kind'] == 'VarDecl':
                    base = self.name(item['name'])
                    count = counts.get(base, 0)
                    counts[base] = count + 1
                    self.local_names[item['id']] = base if count == 0 else f'{base}_{count}'
                stack.extend(reversed(self.children(item)))
            args = [x for x in ch if x['kind'] == 'ParmVarDecl']
            return_type = n['type']['qualType'].split('(', 1)[0].strip()
            self.out(0, f'{self.typ(return_type, n)} {self.function}(' +
                     ', '.join(self.decl(x) for x in args) + ') {')
            self.statement(ch[-1], 1)
            self.out(0, '}')
        if not self.roots and not any(n['name'] == 'main' for n in functions):
            raise ValueError('input needs a main function')
        # Globals must precede functions because static locals become globals.
        self.lines[prefix:prefix] = self.static
        helpers = [f'{type_name} {helper}(I64i cond, {type_name} yes, {type_name} no) {{\n'
                   f'    if (cond) return yes;\n    return no;\n}}'
                   for type_name, helper in self.select_types.items()]
        prefix += len(self.static)
        self.lines[prefix:prefix] = helpers
        if not self.roots:
            self.lines.append('main();')
        return '\n'.join(self.lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--root', action='append', dest='roots',
                        help='translate only this function and its dependencies; emit a library')
    args = parser.parse_args()
    try:
        output = Translator(args.input, args.roots).translate()
    except ValueError as error:
        parser.exit(1, str(error) + '\n')
    args.output.write_text(output)


if __name__ == '__main__':
    main()
