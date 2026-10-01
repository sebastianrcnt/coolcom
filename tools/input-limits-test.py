#!/usr/bin/env python3
"""Input limits reject a complete line/script instead of executing truncated text."""
from pathlib import Path
import subprocess
import tempfile

import testvm
from testvm import ROOT


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), cwd=ROOT, capture_output=True, **kwargs)

with tempfile.TemporaryDirectory(prefix="input-limits-", dir=ROOT / "build") as tmp:
    out = Path(tmp)
    disk = out / "disk.img"
    testvm.create_disk(disk, 64 * 1024 * 1024, capture_output=True)
    init = out / "Init.cool"
    init.write_text('''U8 limit_line[16];
I64 limit_i;
for (limit_i = 0; limit_i < 20; limit_i++) KeyPush('a');
KeyPush(10);
GetLine(limit_line, 16);
Print("LINE-LIMIT:%d\\n", StrLen(limit_line));
// Fill the 255-event queue with a complete line, then overflow it.
for (limit_i = 0; limit_i < 254; limit_i++) KeyPush('x');
KeyPush(10);
KeyPush('x');
GetLine(limit_line, 16);
Print("QUEUE-LIMIT:%d\\n", StrLen(limit_line));
KeyPush('O'); KeyPush('K'); KeyPush(10);
GetLine(limit_line, 16);
Print("INPUT-RECOVERY:%s\\n", limit_line);
Shutdown;
''')
    assert run("mcopy", "-i", disk, init, "::Init.cool").returncode == 0
    vm = testvm.vm_command(executable=ROOT / "build/coolvm", timeout=15, disk=disk)
    result = run(*vm, ROOT / "build/kernel.Image", timeout=20, stdin=subprocess.DEVNULL)
    text = (result.stdout + result.stderr).decode(errors="replace")
    assert result.returncode == 0, text
    for expected in ("ERROR: line exceeds 15 bytes; input discarded",
                     "ERROR: key input queue overflow; input lost",
                     "LINE-LIMIT:0", "QUEUE-LIMIT:0", "INPUT-RECOVERY:OK"):
        assert expected in text, text
    # Parse-time limits must fail before the guest can run.
    for body, expected in (("#" + "x" * 400 + "\n", "input script line 1 exceeds"),
                           ("1 30 1\n" * 256, "input script exceeds 255 records"),
                           ("wait NEVER\n" + "1 30 1\n" * 16384,
                            "input script exceeds 16384 delayed records")):
        script = out / "bad.input"
        script.write_text(body)
        result = run(*vm, "--input-script", script, ROOT / "build/kernel.Image", timeout=20)
        text = (result.stdout + result.stderr).decode(errors="replace")
        assert result.returncode == 2 and expected in text, (result.returncode, text)
    # A guest that stops taking interrupts for a second (as a descheduled vCPU on a
    # loaded host looks to the feeder) loses no scripted input: the feeder waits.
    init.write_text('''U8 stall_line[256]; I64 stall_t = ArchCntVct, stall_daif = ArchDaif;
Print("FIFO-STALL\\n"); ArchIrqOff; while (ArchCntVct - stall_t < cnt_freq) {} ArchIntRestore(stall_daif);
GetLine(stall_line, 256); Print("STALL-LINE:%d\\n", StrLen(stall_line)); Shutdown;
''')
    assert run("mcopy", "-o", "-i", disk, init, "::Init.cool").returncode == 0
    script.write_text("wait FIFO-STALL\n" + "1 45 1\n0 0 0\n1 45 0\n0 0 0\n" * 100 + "1 28 1\n0 0 0\n1 28 0\n0 0 0\n")
    result = run(*vm, "--input-script", script, ROOT / "build/kernel.Image", timeout=20)
    text = (result.stdout + result.stderr).decode(errors="replace")
    assert result.returncode == 0 and "STALL-LINE:100" in text and "input FIFO overflow" not in text, (result.returncode, text)
    # Runtime FIFO overflow must also fail, even for syntactically valid scripts.
    init.write_text('Print("FIFO-BLOCKED\\n"); ArchIrqOff; while (TRUE) {}\n')
    assert run("mcopy", "-o", "-i", disk, init, "::Init.cool").returncode == 0
    script.write_text("wait FIFO-BLOCKED\n" + "1 30 1\n" * 600)
    result = run(*vm, "--input-script", script, ROOT / "build/kernel.Image", timeout=20)
    text = (result.stdout + result.stderr).decode(errors="replace")
    assert result.returncode == 2 and "input FIFO overflow" in text, (result.returncode, text)
print("input-limits-test: queue/line overflow rejects input, next line recovers; a stalled guest loses no scripted input; script limits fail PASS")
