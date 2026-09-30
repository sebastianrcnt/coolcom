#!/usr/bin/env python3
"""Compile Warm examples and #include them in the real FAT32 kernel shell."""
import argparse
import importlib.util
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "warmc/standard/src/OS"
import sys
sys.path.insert(0, str(ROOT / "warmc"))
from os_modules import os_modules
spec = importlib.util.spec_from_file_location("kv", ROOT / "tools/kernel-verify.py")
kv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kv)

def run(*args):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, capture_output=True)
    if p.returncode:
        raise RuntimeError(p.stdout.decode(errors="replace") + p.stderr.decode(errors="replace"))
    return p

def install(disk):
    # Exercise the production installer rather than flattening library fixtures.
    run(ROOT / "tools/disk-files.sh", disk)
    run("mdel", "-i", disk, "::Init.cool")
    assert b"Warm.cool" in run("mdir", "-b", "-i", disk, "::Warm/Warm.cool").stdout
    for old in ("::Warm.cool", "::coolc", "::Compiler"):
        assert subprocess.run(["mdir", "-i", str(disk), old], capture_output=True).returncode

def disk_path(source):
    path = Path(source).relative_to(ROOT / "warmc")
    if path.parts[:2] == ("standard", "src"):
        return "C:/Warm/Standard/" + "/".join(path.parts[2:])
    if path.parts[0] == "examples":
        return "C:/Warm/Examples/" + "/".join(path.parts[1:])
    raise ValueError(source)

def warm_run(paths, entry):
    # GetLine holds 511 bytes, but the guest key queue holds only 255 events.
    # Keep each statement + acknowledgement below that and wait for execution
    # before sending the next one (including after the compiler package loads).
    if len(paths) >= 4096:
        raise ValueError("Warm input paths exceed the guest buffer")
    lines = ["U8 warm_inputs[4096]; warm_inputs[0] = 0;"]
    lines += ['StrCat(warm_inputs, "' + paths[start:start + 160] + '");'
              for start in range(0, len(paths), 160)]
    script = ""
    for index, line in enumerate(lines):
        line += ' Print("WARM-INPUT-%d\\n", ' + str(index) + ');'
        assert len(line) < 255
        script += kv.typed(line) + "wait WARM-INPUT-" + str(index) + "\n"
    return script + kv.typed('WarmRun(warm_inputs, "' + entry + '");')

def stdin_test(OUT):
    """WarmRun the greet example in the shell: it reads a line typed at the terminal."""
    std = ROOT / "warmc/standard/src"
    disk = OUT / "stdin-disk.img"
    with disk.open("wb") as f:
        f.truncate(64 * 1024 * 1024)
    run("mformat", "-i", disk, "-F", "::")
    install(disk)
    files = []
    for name in ("Buffer", "String", "StringBuilder", "OS/Terminal"):
        files += [std / (name + ".warmh"), std / (name + ".warm")]
    files += [std / "OS/Error.warm",
              ROOT / "warmc/examples/greet/Greet.warmh", ROOT / "warmc/examples/greet/Greet.warm"]
    modules = ",".join(disk_path(path) for path in files)
    script = OUT / "Stdin.input"
    script.write_text("wait Cool shell\nwait > \n" + kv.typed('#include "C:/Warm/Warm.cool"') +
                      kv.typed('Print("WLOAD%d\\n", 1);') + "wait WLOAD1\n" +
                      warm_run(modules, "Example.Greet:main") +
                      "delay 3000\n" + kv.typed("Zed") + "wait Hello, Zed!\ndelay 200\nquit\n")
    log = OUT / "Stdin.log"
    with log.open("wb") as stream:
        proc = subprocess.Popen(["gtimeout", "-k", "2", "40", str(ROOT / "build/coolvm"),
            "--headless", "--cpus", "2", "--mem", "1024", "--timeout", "35",
            "--disk", str(disk), "--input-script", str(script), str(ROOT / "build/kernel.Image")],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
        proc.wait()
    output = log.read_text(errors="replace")
    assert proc.returncode == 0, output[-6000:]
    assert "ERROR:" not in output and "input FIFO overflow" not in output, output[-6000:]
    assert "Hello, Zed!" in output.split("WarmRun(", 1)[-1], output[-6000:]
    print("warm-kernel: Stdin (greet reads the terminal) PASS", flush=True)

def portable_test(OUT, name):
    """Compile and run a portable file program with WarmRun itself."""
    disk = OUT / (name + "-run.img")
    with disk.open("wb") as f:
        f.truncate(64 * 1024 * 1024)
    run("mformat", "-i", disk, "-F", "::")
    install(disk)
    files = []
    for pair in os_modules(ROOT):
        if "/Raw." in pair or "/CoolOS/" in pair or "/Terminal." in pair:
            continue
        files += [Path(path) for path in pair.split(",")]
    files += [ROOT / ("warmc/examples/kernel/" + name + ".warm")]
    modules = ",".join(disk_path(path) for path in files)
    marker = "WARM " + name.upper() + " PASS"
    script = OUT / (name + "Run.input")
    script.write_text("wait Cool shell\nwait > \n" + kv.typed('#include "C:/Warm/Warm.cool"') +
        warm_run(modules, name + ":main") +
        "wait " + marker + "\ndelay 200\nquit\n")
    log = OUT / (name + "Run.log")
    with log.open("wb") as stream:
        proc = subprocess.run(["gtimeout", "-k", "2", "40", str(ROOT / "build/coolvm"),
            "--headless", "--cpus", "2", "--mem", "1024", "--timeout", "35",
            "--disk", str(disk), "--input-script", str(script), str(ROOT / "build/kernel.Image")],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
    output = log.read_text(errors="replace")
    assert proc.returncode == 0, output[-6000:]
    assert "ERROR:" not in output and "input FIFO overflow" not in output, output[-6000:]
    assert marker in output.splitlines(), output[-6000:]
    print("warm-kernel: " + name + " WarmRun PASS", flush=True)

def fmt_test(OUT):
    """WarmFmt in the shell formats a messy file on the disk (the fixture of warmc/test_fmt.py)."""
    disk = OUT / "fmt-disk.img"
    with disk.open("wb") as f:
        f.truncate(64 * 1024 * 1024)
    run("mformat", "-i", disk, "-F", "::")
    install(disk)
    run("mcopy", "-o", "-i", disk, ROOT / "warmc/fmt-tests/basic.in.warm", "::Fmt.warm")
    script = OUT / "Fmt.input"
    script.write_text("wait Cool shell\nwait > \n" + kv.typed('#include "C:/Warm/Warm.cool"') +
                      kv.typed('Print("WLOAD%d\\n", 1);') + "wait WLOAD1\n" +
                      kv.typed('WarmFmt("C:/Fmt.warm");') + "wait WARMFMT CHANGED C:/Fmt.warm\n" +
                      kv.typed('WarmFmt("C:/Fmt.warm");') + "wait WARMFMT OK C:/Fmt.warm\ndelay 300\nquit\n")
    log = OUT / "Fmt.log"
    with log.open("wb") as stream:
        proc = subprocess.Popen(["gtimeout", "-k", "2", "40", str(ROOT / "build/coolvm"),
            "--headless", "--cpus", "2", "--mem", "1024", "--timeout", "35",
            "--disk", str(disk), "--input-script", str(script), str(ROOT / "build/kernel.Image")],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
        proc.wait()
    output = log.read_text(errors="replace")
    assert proc.returncode == 0, output[-6000:]
    assert "ERROR:" not in output and "input FIFO overflow" not in output, output[-6000:]
    assert "WARMFMT CHANGED C:/Fmt.warm" in output and "WARMFMT OK C:/Fmt.warm" in output, output[-6000:]
    assert "ERROR" not in output.split("WLOAD1", 1)[-1], output[-6000:]
    data = run("mtype", "-i", disk, "::Fmt.warm").stdout
    assert data == (ROOT / "warmc/fmt-tests/basic.exp.warm").read_bytes(), data.decode(errors="replace")
    print("warm-kernel: Fmt (WarmFmt in the shell) PASS", flush=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter", default="", choices=("", "Files", "Streams", "Sockets", "Tasks", "TaskKilled", "Capabilities", "Screen", "Key", "Errors", "Stdin", "Fmt"))
    args = parser.parse_args()
    OUT = ROOT / "build/warm-kernel"
    if args.filter:
        OUT = OUT / args.filter
    OUT.mkdir(parents=True, exist_ok=True)
    for name, diagnostic in (("Leak", "not consumed"), ("DoubleClose", "consumed"),
                             ("NoCapability", "Type Error"), ("Forge", "callable named Filesystem")):
        result = subprocess.run([str(ROOT / "build/warmc"), "compile",
            *os_modules(ROOT),
            str(ROOT / "warmc/test-programs/kernel" / (name + ".warm")),
            "--entrypoint=" + name + ":main", "--target-type=hc",
            "--output=" + str(OUT / (name + ".cool"))], cwd=OUT, capture_output=True)
        diagnostic_text = (result.stdout + result.stderr).decode(errors="replace")
        (OUT / (name + ".log")).write_text(diagnostic_text)
        assert result.returncode and diagnostic in diagnostic_text, diagnostic_text
        print("warm-kernel: rejects " + name, flush=True)
    # Exercise Unit/U0, scalar and decayed-span foreign calls directly.
    foreign_hc = OUT / "ForeignUnit.cool"
    foreign_bin = OUT / "ForeignUnit.BIN"
    run(ROOT / "build/warmc", "compile", ROOT / "warmc/test-programs/kernel/ForeignUnit.warm",
        "--entrypoint=ForeignUnit:main", "--target-type=hc", "--output=" + str(foreign_hc))
    compiled = run("env", "COOLC_COMPILER_BIN=" + str(ROOT / "coolc/seed/Compiler.BIN"),
                   ROOT / "build/coolc", foreign_hc, foreign_bin)
    assert b"Errs:0 " in compiled.stdout, compiled.stdout
    assert run(ROOT / "build/coolc", "--run", foreign_bin).stdout == b"FOREIGN UNIT PASS\n"
    print("warm-kernel: native foreign Unit/scalar/span PASS", flush=True)
    disk = OUT / "disk.img"
    with disk.open("wb") as f:
        f.truncate(64 * 1024 * 1024)
    run("mformat", "-i", disk, "-F", "::")
    adapter = OUT / "Adapter.cool"
    adapter.write_text("".join((ROOT / "warmc" / n).read_text() for n in ["OSKernel.cool", "OSCommon.cool", "OSDirKernel.cool", "OSNetCommon.cool", "OSNetKernel.cool", "OSTaskKernel.cool"]))
    run("mcopy", "-o", "-i", disk, adapter, "::Adapter.cool")
    for name in ("Files", "Streams", "Sockets", "Tasks", "TaskKilled", "Capabilities", "Screen", "Key", "Errors"):
        if args.filter not in name:
            continue
        hc = OUT / (name + ".cool")
        run(ROOT / "build/warmc", "compile",
            *os_modules(ROOT),
            ROOT / "warmc/examples/kernel" / (name + ".warm"),
            "--entrypoint=" + name + ":main", "--target-type=hc", "--output=" + str(hc))
        prefix = ""
        if name == "Errors":
            prefix = ("I64 WarmThrowWrite(U8 *p, U8 *d, I64 n) { throw('WarmTest'); return 0; }\n"
                      "#define FileWrite WarmThrowWrite\n")
        if name == "TaskKilled":
            prefix = ('U0 WtTestKill() {Sleep(5); CTask *t,*target=NULL; I64 i; '
                'for(i=0;i<mp_cnt;i++){t=cpu_structs[i].seth_task; do {'
                'if(!StrCmp(t->task_name,"WarmTask"))target=t; t=t->next_task; '
                '}while(t!=cpu_structs[i].seth_task);} if(target)Kill(target); }\n')
        hc.write_text(prefix + '#include "C:/Adapter.cool"\n' +
                      hc.read_text())
        run("mcopy", "-o", "-i", disk, hc, "::")
        script = OUT / (name + ".input")
        marker = "WARM " + name.upper().replace("FILES", "FILE") + " PASS"
        # Type once the shell prompts; stop the VM once the program has passed (coolvm wait/quit).
        script.write_text("wait Cool shell\nwait > \n" + kv.typed('#include "C:/' + name + '.cool"') +
                          ("wait WARM KEY READY\n" + kv.keys_of(45) if name == "Key" else "") +
                          "wait " + marker + "\ndelay 200\nquit\n")
        log = OUT / (name + ".log")
        with log.open("wb") as stream:
            proc = subprocess.Popen(["gtimeout", "-k", "2", "22", str(ROOT / "build/coolvm"),
                "--headless", "--cpus", "2", "--mem", "1024", "--timeout", "18",
                "--disk", str(disk), "--input-script", str(script),
                "--screenshot", str(OUT / (name + ".png")), str(ROOT / "build/kernel.Image")],
                cwd=ROOT, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
            proc.wait()
        output = log.read_text(errors="replace")
        assert proc.returncode == 0, output[-6000:]
        assert "input FIFO overflow" not in output, output[-6000:]
        assert marker in output.splitlines(), output[-6000:]
        shell_output = output.split('> #include', 1)[-1]
        errors = [line for line in shell_output.splitlines() if "ERROR:" in line]
        expected_errors = []
        assert errors == expected_errors, shell_output[-6000:]
        assert "heap overflow" not in shell_output, shell_output[-6000:]
        if name == "Screen":
            width, height, rows = kv.read_png(OUT / "Screen.png")
            assert width > 50 and height > 420
            assert all(row[10*3:50*3] == bytes([0, 255, 0]) * 40
                       for row in rows[400:420]), "Warm framebuffer rectangle missing"
        print("warm-kernel: " + name + " PASS", flush=True)
    for name in ("Streams", "Sockets", "Tasks", "Capabilities"):
        if not args.filter or args.filter == name:
            portable_test(OUT, name)
    if not args.filter or args.filter == "Stdin":
        stdin_test(OUT)
    if not args.filter or args.filter == "Fmt":
        fmt_test(OUT)
    if not args.filter or args.filter == "Files":
        data = run("mtype", "-i", disk, "::Warm.txt").stdout
        assert data == b"Warm FAT32\n", data

if __name__ == "__main__":
    main()
