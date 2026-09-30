#!/usr/bin/env python3
"""Generate a Cool Venus client from the pinned upstream encoding backend.

No Mako dependency: we load only Gen and Ignorable, not the C template frontend.
All member/argument validity, count and conditional rules come from that backend.
"""
import argparse
import ast
import json
from pathlib import Path
import re
import sys
import types
from vendor import ROOT, check, VK_REV, VN_REV


def backend(vk, vn):
    sys.path.insert(0, str(vn))
    import vkxml
    source = ast.parse((vn / 'vn_protocol.py').read_text())
    nodes = [n for n in source.body if
             isinstance(n, (ast.ClassDef, ast.Assign)) or
             isinstance(n, (ast.Import, ast.ImportFrom)) and
             not (isinstance(n, ast.ImportFrom) and n.module.startswith('mako'))]
    module = types.ModuleType('venus_backend')
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(vn / 'vn_protocol.py'), 'exec'), module.__dict__)
    reg = vkxml.VkRegistry.parse(vk, [vn / 'xmls/VK_EXT_command_serialization.xml', vn / 'xmls/VK_MESA_venus_protocol.xml'])
    return module.Gen(True, reg), vkxml.VkType


class Generator:
    def __init__(self, vk, vn, subset):
        self.gen, self.T = backend(vk, vn)
        self.serial = 0
        table = self.gen.reg.type_table
        names = [s.split('#')[0].strip() for s in subset.read_text().splitlines()]
        names = [s for s in names if s]
        if len(names) != len(set(names)):
            raise ValueError('duplicate subset entry')
        self.commands, self.selected = [], {}
        for name in names:
            if name not in table:
                raise ValueError('unknown subset entry: ' + name)
            ty = table[name]
            if ty.category == self.T.COMMAND:
                if not self.gen.is_serializable(ty):
                    raise ValueError('command is not serializable: ' + name)
                self.commands.append(ty)
            elif ty.category != self.T.STRUCT:
                raise ValueError('extra subset entries must be structs: ' + name)
            for dep in ty.get_dependencies():
                self.selected[dep.name] = dep
        # pNext is deliberately NOT a transitive dependency. Only named nodes apply.
        self.records = [t for t in self.selected.values() if t.category in (self.T.STRUCT, self.T.UNION)]
        self.mapping = {'void': 'U8i', 'char': 'U8i', 'uint8_t': 'U8i', 'uint16_t': 'U16i',
                        'uint32_t': 'U32i', 'int32_t': 'I32i', 'uint64_t': 'U64i',
                        'int64_t': 'I64i', 'size_t': 'U64i', 'float': 'U32i', 'double': 'F64'}
        for t in table.values():
            if t.category == self.T.HANDLE or t.category == self.T.FUNCPOINTER:
                self.mapping[t.name] = 'U64i'
            elif t.category == self.T.ENUM:
                self.mapping[t.name] = 'U64i' if t.enums.bitwidth == 64 else 'I32i'
        for _ in range(5):
            for t in table.values():
                if t.typedef and t.typedef.base.name in self.mapping:
                    self.mapping[t.name] = self.mapping[t.typedef.base.name]
        self.tokens = re.compile(r'\b(' + '|'.join(map(re.escape, sorted(self.mapping, key=len, reverse=True))) + r')\b')

    def fragment(self, code):
        self.serial += 1
        locals_ = re.findall(r'\b(?:const\s+)?(?:size_t|uint32_t|uint64_t)\s+(\w+)\s*=', code)
        for name in set(locals_):
            code = re.sub(r'\b' + name + r'\b', name + '_' + str(self.serial), code)
        return code

    def cool(self, code):
        code = re.sub(r'\((\w+(?:->\w+)?) \? \*\1 : 0\)', r'vn_count(\1)', code)
        code = re.sub(r'(\w+(?:->\w+)?) \? (\w+(?:->\w+)?) : 0', r'vn_choose(\1, \2)', code)
        code = re.sub(r'\bconst\b\s*', '', code)
        code = code.replace('NULL', '0').replace('false', 'FALSE').replace('true', 'TRUE')
        code = code.replace('strlen(', 'vn_strlen(')
        code = code.replace('assert(FALSE);', 'enc->error = 1;')
        code = self.tokens.sub(lambda m: self.mapping[m[0]], code)
        # Cool uses postfix casts. Only pointer casts occur in backend expressions.
        code = re.sub(r'\((\w+\s*\*+)\)([A-Za-z_][\w]*(?:->\w+)?)', r'\2(\1)', code)
        code = re.sub(r'for \((\w+) (\w+) =', r'\1 \2; for (\2 =', code)
        return code

    def decl(self, v):
        return self.cool(v.to_c())

    def generate(self):
        out = ['// Generated; inputs pinned in tools/venus/vendor.py. Do not edit.',
               '// float fields contain IEEE-754 binary32 bits (Cool has no F32).',
               '// Handles are guest object ids; unions use the Venus default wire tags.',
               (ROOT / 'tools/venus/wire.cool').read_text()]
        # Constants include only selected enum groups plus sizes used in declarations.
        constants = {}
        for ty in self.selected.values():
            if ty.enums and ty.name != 'VkCommandTypeEXT':
                constants.update(ty.enums.values)
        constants.update({t.attrs['c_type']: self.gen.reg.type_table['VkCommandTypeEXT'].enums.values[t.attrs['c_type']] for t in self.commands})
        constants.update(self.gen.reg.type_table['VkCommandFlagBitsEXT'].enums.values)
        for t in self.records:
            for v in t.variables:
                if v.ty.is_static_array():
                    dim = v.ty.static_array_size()
                    if dim in self.gen.reg.type_table and self.gen.reg.type_table[dim].define:
                        constants[dim] = self.gen.reg.type_table[dim].define.split()[-1]
        # Vulkan fixed array constants are ordinary API Constants in registry XML.
        import xml.etree.ElementTree as ET
        for e in ET.parse(ROOT / 'vendor/vk.xml').findall("./enums[@name='API Constants']/enum"):
            constants[e.attrib['name']] = e.attrib.get('value', e.attrib.get('alias'))
        for k, v in constants.items():
            if v is not None and '"' not in v and 'VK_MAKE' not in v:
                v = re.sub(r'(?<=\d)[uUlLfF]+\b', '', v).replace('(~0)', '(-1)')
                out.append(f'#define {k} {v}')
        for t in self.records:
            out.append(f'extern class {t.name};')
        # dependencies precede containing records; union members are independent alternatives.
        for t in self.records:
            kind = 'union' if t.category == self.T.UNION else 'class'
            out.append(f'{kind} {t.name} {{\n' + '\n'.join('    ' + self.decl(v) + ';' for v in t.variables) + '\n};')
        funcs = []
        def add(ret, name, params, body):
            converted = self.cool(body)
            if 'vn_decode_' in name:
                converted = converted.replace('enc->error', 'dec->error')
            funcs.append((self.cool(f'{ret} {name}({params})'), converted))
        # All scalar aliases retain named wire helpers, while storage uses Cool types.
        scalars = {k: v for k, v in self.mapping.items() if k in self.selected or k in ('uint64_t', 'uint32_t', 'VkStructureType', 'VkFlags', 'VkCommandTypeEXT', 'char', 'size_t')}
        scalars['blob'] = 'U8i'
        for name, typ in scalars.items():
            if name == 'void':
                continue
            n = 8 if typ in ('U64i', 'I64i', 'F64') else (1 if typ == 'U8i' else 2 if typ == 'U16i' else 4)
            add('U0', 'vn_encode_' + name, f'VenusWire *enc, {typ} *val', f'vn_put(enc, val(U8i *), {n}, {max(n,4)});')
            add('U0', 'vn_decode_' + name, f'VenusWire *dec, {typ} *val', f'vn_get(dec, val(U8i *), {n}, {max(n,4)});')
            for mode, w in [('encode', 'enc'), ('decode', 'dec')]:
                add('U0', f'vn_{mode}_{name}_array', f'VenusWire *{w}, {typ} *val, U64i count',
                    f'if(count>(0xFFFFFFFFFFFFFFFF-3)/{n}) {{{w}->error=1; return;}} vn_{"put" if mode == "encode" else "get"}({w}, val(U8i *), count*{n}, (count*{n}+3)&~3);')
        for t in self.records:
            if not self.gen.is_serializable(t):
                # Optional allocation callbacks are unsupported by Venus; reject non-null.
                for mode, w in [('encode', 'enc'), ('decode', 'dec')]:
                    add('U0', f'vn_{mode}_{t.name}', f'VenusWire *{w}, {t.name} *val', f'{w}->error=1;')
                continue
            for partial in (False, True):
                if partial and 'need_partial' not in t.attrs:
                    continue
                suffix = '_partial' if partial else ''
                if t.category == self.T.UNION and partial:
                    continue
                for mode, w in [('encode', 'enc'), ('decode', 'dec')]:
                    emit = self.gen.encode_struct_member if mode == 'encode' else self.gen.decode_struct_member
                    def member(v):
                        return self.fragment(emit(t, v, 'val->', partial) if mode == 'encode' else emit(t, v, 'val->', partial, False))
                    if t.category == self.T.UNION:
                        tag = self.gen.UNION_DEFAULT_TAGS[t.name]
                        body = f'U32i tag={tag};\nvn_{mode}_uint32_t({w}, &tag);\nswitch(tag) {{\n'
                        for i, v in t.get_union_cases():
                            body += f'case {i}: {{ {member(v)} }} break;\n'
                        body += f'default: {w}->error=1; break;\n}}'
                        add('U0', f'vn_{mode}_{t.name}', f'VenusWire *{w}, {t.name} *val', body)
                    elif t.s_type:
                        body = '\n'.join(member(v) for v in t.variables[2:])
                        add('U0', f'vn_{mode}_{t.name}_self{suffix}', f'VenusWire *{w}, {t.name} *val', body)
                        nodes = [n for n in self.gen.get_chain(t)[0] if n.name in self.selected]
                        body = f'VenusBase *node=val(VenusBase *);\n'
                        if mode == 'encode':
                            body += 'while (node) {\n'
                            for n in nodes:
                                body += f'if(node->sType=={n.s_type}) {{ vn_encode_simple_pointer(enc,node); vn_encode_VkStructureType(enc,&node->sType); vn_encode_{t.name}_pnext{suffix}(enc,node->pNext); vn_encode_{n.name}_self{suffix}(enc,node({n.name} *)); return; }}\n'
                            body += 'node=node->pNext; }\nvn_encode_simple_pointer(enc,0);'
                        else:
                            body += 'I32i tag;\nif (!vn_decode_simple_pointer(dec)) return;\nvn_decode_VkStructureType(dec,&tag);\nwhile (node && node->sType!=tag) node=node->pNext;\nif (!node) {dec->error=1; return;}\n'
                            for n in nodes:
                                body += f'if(tag=={n.s_type}) {{ vn_decode_{t.name}_pnext{suffix}(dec,node->pNext); vn_decode_{n.name}_self{suffix}(dec,node({n.name} *)); return; }}\n'
                            body += 'dec->error=1;'
                        if not nodes:
                            body = 'vn_encode_simple_pointer(enc,0);' if mode == 'encode' else 'if(vn_decode_simple_pointer(dec)) dec->error=1;'
                        add('U0', f'vn_{mode}_{t.name}_pnext{suffix}', f'VenusWire *{w}, U8i *val', body)
                        body = f'I32i tag={t.s_type};\n'
                        if mode == 'decode':
                            body += f'vn_decode_VkStructureType(dec,&tag); if(tag!={t.s_type}) {{dec->error=1; return;}}\n'
                        else:
                            body += f'if(val->sType!=tag) {{enc->error=1; return;}}\nvn_encode_VkStructureType(enc,&tag);\n'
                        body += f'vn_{mode}_{t.name}_pnext{suffix}({w},val->pNext);\nvn_{mode}_{t.name}_self{suffix}({w},val);'
                        add('U0', f'vn_{mode}_{t.name}{suffix}', f'VenusWire *{w}, {t.name} *val', body)
                    else:
                        add('U0', f'vn_{mode}_{t.name}{suffix}', f'VenusWire *{w}, {t.name} *val', '\n'.join(member(v) for v in t.variables))
        ids = self.gen.reg.type_table['VkCommandTypeEXT'].enums.values
        for t in self.commands:
            params = ', '.join(self.decl(v) for v in t.variables)
            ident = t.attrs['c_type']
            body = f'I32i cmd={ident};\nvn_encode_VkCommandTypeEXT(enc,&cmd); vn_encode_VkFlags(enc,&cmd_flags);\n'
            if t.has_out_ty:
                body = body.replace('vn_encode_VkFlags(enc,&cmd_flags);', 'cmd_flags |= VK_COMMAND_GENERATE_REPLY_BIT_EXT; vn_encode_VkFlags(enc,&cmd_flags);')
            body += '\n'.join(self.fragment(self.gen.encode_command_arg(t, v, '')) for v in t.variables)
            add('U0', f'vn_encode_{t.name}', f'VenusWire *enc, U32i cmd_flags, {params}', body)
            ret = self.mapping.get(t.ret.ty.base.name, t.ret.ty.base.name) if t.ret else 'U0'
            body = f'I32i cmd;\nvn_decode_VkCommandTypeEXT(dec,&cmd);\nif(cmd!={ident}) {{dec->error=1; return' + (' 0' if t.ret else '') + ';}\n'
            if t.ret:
                body += self.decl(t.ret) + '=0;\n' + self.gen.decode_command_reply(t, t.ret, '') + '\n'
            body += '\n'.join(self.fragment(self.gen.decode_command_reply(t, v, '')) for v in t.variables)
            if t.ret:
                body += '\nreturn ' + t.ret.name + ';'
            add(ret, f'vn_decode_{t.name}_reply', f'VenusWire *dec, {params}', body)
        out += ['extern ' + sig + ';' for sig, _ in funcs]
        out += [sig + '\n{\n' + body + '\n}' for sig, body in funcs]
        return '\n\n'.join(out) + '\n', {'vk_revision': VK_REV, 'venus_revision': VN_REV,
                'commands': [t.name for t in self.commands], 'types': list(self.selected)}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--subset', type=Path, default=ROOT / 'tools/venus/subset.txt')
    p.add_argument('--out', type=Path, default=ROOT / 'build/venus')
    args = p.parse_args()
    if not args.out.resolve().is_relative_to((ROOT / 'build').resolve()):
        p.error('generated output must be under build/')
    vk, vn = check()
    source, manifest = Generator(vk, vn, args.subset).generate()
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'Vulkan.cool').write_text(source)
    (args.out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'generated {len(manifest["commands"])} commands, {len(manifest["types"])} reachable types')

if __name__ == '__main__':
    main()
