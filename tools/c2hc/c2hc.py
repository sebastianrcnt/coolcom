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
        'unsigned long long': 'U64i', '_Bool': 'I8i'}
KEYWORDS = {'reg', 'class', 'union', 'public', 'private', 'lock', 'try', 'catch',
            'throw', 'import', 'export', 'asm', 'Bool', 'Print', 'I32', 'U32'}
WRAPPERS = {'ImplicitCastExpr', 'ParenExpr', 'ConstantExpr', 'ExprWithCleanups'}


class Translator:
    def __init__(self, path):
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
        elif spelling in BASE:
            result = BASE[spelling]
        else:
            self.fail(node or {}, f'type {spelling}')
        return result + ' *' * pointers

    def decl(self, node):
        t = self.typ(node['type']['qualType'], node)
        n = self.name(node['name'])
        if isinstance(t, tuple):
            return f'{t[0]} {n}[{t[1]}]'
        return f'{t} {n}'

    def children(self, node):
        return [x for x in node.get('inner', []) if x.get('kind')]

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

    def expr(self, node):
        n = self.unwrap(node)
        k = n['kind']
        ch = self.children(n)
        if k == 'IntegerLiteral':
            return n['value']
        if k == 'StringLiteral':
            return n['value']
        if k == 'CharacterLiteral':
            return str(n['value'])
        if k == 'DeclRefExpr':
            ref = n['referencedDecl']
            return self.static_names.get(ref['id'], self.name(ref['name']))
        if k == 'UnaryOperator':
            x = self.expr(ch[0])
            op = n['opcode']
            result = f'({x}{op})' if n.get('isPostfix') else f'({op}{x})'
            return self.narrowed(result, n) if op in ('-', '~') else result
        if k in ('BinaryOperator', 'CompoundAssignOperator'):
            a, b = map(self.expr, ch)
            op = n['opcode']
            if op == '=' and n['type']['qualType'].startswith('struct '):
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
            if callee == 'printf':
                callee = 'Print'
            return f'{callee}({", ".join(self.expr(x) for x in ch[1:])})'
        if k == 'CStyleCastExpr':
            target = self.typ(n['type']['qualType'], n)
            return f'({self.expr(ch[0])})({target})'
        if k == 'UnaryExprOrTypeTraitExpr' and n.get('name') == 'sizeof':
            return f'sizeof({self.typ(n["argType"]["qualType"], n)})'
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
                name = self.name(v['name'])
                if init['kind'] == 'InitListExpr':
                    elems = self.children(init)
                    if not elems and init.get('array_filler'):
                        elems = init['array_filler'][1:]
                    t = self.typ(v['type']['qualType'], v)
                    if not isinstance(t, tuple):
                        self.fail(v, 'record initializer')
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
        elif k == 'NullStmt':
            self.out(indent, ';')
        elif k == 'BinaryOperator' and n['opcode'] == '=' and n['type']['qualType'].startswith('struct '):
            dst, src = ch
            self.out(indent, f'MemCpy(&{self.expr(dst)}, &{self.expr(src)}, sizeof({self.typ(n["type"]["qualType"], n)}));')
        elif k == 'BinaryOperator' and n['opcode'] == '=' and self.unwrap(ch[1])['kind'] == 'ConditionalOperator':
            self.value(ch[1], self.expr(ch[0]), indent)
        elif k in ('CallExpr', 'BinaryOperator', 'CompoundAssignOperator', 'UnaryOperator'):
            self.out(indent, self.expr(n) + ';')
        else:
            self.fail(n, 'statement')

    def translate(self):
        records, globals_, functions = [], [], []
        for n in self.children(self.ast):
            loc = n.get('loc', {})
            if loc.get('file') and Path(loc['file']).resolve() != self.path:
                continue
            if 'offset' not in loc:
                continue
            k = n['kind']
            if k == 'RecordDecl' and n.get('completeDefinition') and n.get('name'):
                fields = self.children(n)
                records.append('class ' + self.name(n['name']) + ' {\n' +
                               ''.join('    ' + self.decl(f) + ';\n' for f in fields) + '};')
            elif k == 'FunctionDecl' and any(x['kind'] == 'CompoundStmt' for x in self.children(n)):
                functions.append(n)
            elif k == 'VarDecl':
                globals_.append(self.decl(n) + ';')
            elif k == 'FunctionDecl':
                pass  # C prototypes, including printf
            else:
                self.fail(n, 'top level declaration')
        self.lines = ['// Generated by tools/c2hc/c2hc.py from ' + self.path.name,
                      'extern U0 Print(U8i *fmt, ...);',
                      'extern U8i *MemCpy(U8i *dst, U8i *src, I64i cnt);',
                      *records, *globals_]
        for n in functions:
            self.function = self.name(n['name'])
            ch = self.children(n)
            args = [x for x in ch if x['kind'] == 'ParmVarDecl']
            return_type = n['type']['qualType'].split(' (', 1)[0]
            self.out(0, f'{self.typ(return_type, n)} {self.function}(' +
                     ', '.join(self.decl(x) for x in args) + ') {')
            self.statement(ch[-1], 1)
            self.out(0, '}')
        if not any(n['name'] == 'main' for n in functions):
            raise ValueError('input needs a main function')
        # Globals must precede functions because static locals become globals.
        self.lines[3 + len(records):3 + len(records)] = self.static
        self.lines.append('main();')
        return '\n'.join(self.lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        output = Translator(args.input).translate()
    except ValueError as error:
        parser.exit(1, str(error) + '\n')
    args.output.write_text(output)


if __name__ == '__main__':
    main()
