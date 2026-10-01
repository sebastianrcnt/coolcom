#!/usr/bin/env python3
"""OS.Ui pure modules on the host (layout, identity, keys, damage, interaction,
text editing) and the gallery/apps type-check. The VM side is tools/ui-test.py."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ENV = dict(os.environ, WARM_TOOLCHAIN_READY='1')


def warm(*args):
    return subprocess.run([str(ROOT / 'tools/warm'), *map(str, args)], capture_output=True, env=ENV, timeout=300)


p = warm('run', ROOT / 'warmc/standard/test/ui/UiTest.warm')
assert p.returncode == 0 and p.stdout.endswith(b'UI HOST PASS\n'), (p.stdout + p.stderr).decode(errors='replace')[-3000:]
# Every example built on OS.Ui type-checks against the portable library.
for app in sorted((ROOT / 'warmc/examples/gui').glob('*.warm')):
    if 'import OS.Ui' in app.read_text():
        p = warm('check', app)
        assert p.returncode == 0, (app, (p.stdout + p.stderr).decode(errors='replace'))
# Without a display the application reports that the GUI is unavailable.
p = warm('run', ROOT / 'warmc/examples/gui/Gallery.warm')
assert p.returncode == 0 and b'GALLERY NO GUI' in p.stdout, p.stdout + p.stderr
print('test_ui: OS.Ui host PASS')
