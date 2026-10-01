#!/usr/bin/env python3
"""Task boundary checks: Sendable is structural and cannot be forged."""
from pathlib import Path
import subprocess
from os_modules import os_modules
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warm-tasks'
OUT.mkdir(parents=True, exist_ok=True)
def probe(name, declarations, body, success, diagnostic=''):
    source = OUT / (name + '.warm')
    source.write_text('module body Test is\n' + declarations + '\nfunction main(root: RootCapability): ExitCode is\n' + body + '\nend; end module body.\n')
    p = subprocess.run([ROOT / 'tools/warm', 'compile', source, '--check'], capture_output=True, text=True)
    assert (p.returncode == 0) == success and diagnostic in p.stdout + p.stderr, (name, p.stdout, p.stderr)
    print('tasks: ' + name + ' PASS')
require = 'generic [T: Type(Sendable)] function transfer(arg: T): T is return arg; end;'
probe('root', require, 'let r: RootCapability := transfer(root); surrenderRoot(r); return ExitSuccess();', False, 'Sendable')
probe('borrow', require + ' function forbidden(ref: &[Nat64]): Unit is let x: &[Nat64, _R1] := transfer(ref); return nil; end;', 'surrenderRoot(root); return ExitSuccess();', False, 'Sendable')
probe('nested', require + ' record Borrowed[R: Region]: Free is value: Span[Nat8, R]; end; generic [R: Region] function forbidden(arg: Borrowed[R]): Unit is transfer(arg); return nil; end;', 'surrenderRoot(root); return ExitSuccess();', False, 'Sendable')
probe('generic-forward', require + 'generic [T: Type(Sendable)] function forward(arg: T): T is return transfer(arg); end;', 'printLn(forward(42 : Nat64)); surrenderRoot(root); return ExitSuccess();', True)
probe('static-span', require, 'let x: Span[Nat8, Static] := transfer("static"); printLn(spanLength(x)); surrenderRoot(root); return ExitSuccess();', True)
probe('forged-marker', 'record Own: Free is end; instance Sendable(Own) is end;', 'surrenderRoot(root); return ExitSuccess();', False, 'compiler-derived')
# Unsafe-only codeAddress still rejects aggregate ABIs.
for name, declarations, body, success, diagnostic in [
    ('code-scalar', 'function identity(arg: Int64): Int64 is return arg; end;', 'let fn: Fn[Int64, Int64] := identity; let address: Address[Nat8] := codeAddress(fn);', True, ''),
    ('code-aggregate', 'record Aggregate: Free is x: Int64; end; function identity(arg: Aggregate): Aggregate is return arg; end;', 'let fn: Fn[Aggregate, Aggregate] := identity; let address: Address[Nat8] := codeAddress(fn);', False, 'scalar'),
    ('raw-pointer-alias', require, 'let p: Address[Nat8] := nullPointer(); transfer(p);', False, 'Sendable'),
    ('raw-pointer', require, 'let p: Address[Nat8] := nullPointer(); transfer(p);', False, 'Sendable'),
]:
    source = OUT / (name + '.warm')
    source.write_text(('pragma Unsafe_Module; import Austral.Memory (Address as RawAddress, nullPointer, codeAddress); module body Test is\n' if name == 'raw-pointer-alias' else 'pragma Unsafe_Module; import Austral.Memory (Address, nullPointer, codeAddress); module body Test is\n') + declarations + '\nfunction main(root: RootCapability): ExitCode is\n' + (body.replace('Address[Nat8]', 'RawAddress[Nat8]') if name == 'raw-pointer-alias' else body) + '\nsurrenderRoot(root); return ExitSuccess(); end; end module body.')
    p = subprocess.run([ROOT / 'tools/warm', 'compile', source, '--check'], capture_output=True, text=True)
    assert (p.returncode == 0) == success and diagnostic in p.stdout + p.stderr, (name, p.stdout, p.stderr)
    print('tasks: ' + name + ' PASS')
# A linear completion value cannot be detached.
source = OUT / 'detach-linear.warm'
source.write_text('import OS.Task (Task, detach); import OS.Dir (Dir); module body Test is function forbidden(task: Task[Dir]): Unit is detach(task); return nil; end; function main(): ExitCode is return ExitSuccess(); end; end module body.')
p = subprocess.run([ROOT / 'tools/warm', 'compile', *os_modules(ROOT), source, '--check'], capture_output=True, text=True)
assert p.returncode and 'Type Error' in p.stdout + p.stderr, (p.stdout, p.stderr)
print('tasks: detach-linear PASS')
