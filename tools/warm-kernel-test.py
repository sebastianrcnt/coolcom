#!/usr/bin/env python3
"""Compile Warm examples and #include them in the real FAT32 kernel shell."""
import argparse
import importlib.util
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "warmc/standard/src/Kernel"
spec = importlib.util.spec_from_file_location("kv", ROOT / "tools/kernel-verify.py")
kv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kv)

def run(*args):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, capture_output=True)
    if p.returncode:
        raise RuntimeError(p.stdout.decode(errors="replace") + p.stderr.decode(errors="replace"))
    return p

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter", default="", choices=("", "Files", "Screen", "Key", "Errors"))
    args = parser.parse_args()
    OUT = ROOT / "build/warm-kernel"
    if args.filter:
        OUT = OUT / args.filter
    OUT.mkdir(parents=True, exist_ok=True)
    for name, diagnostic in (("Leak", "not consumed"), ("DoubleClose", "consumed"),
                             ("NoCapability", "Type Error"), ("Forge", "callable named `Filesystem`")):
        result = subprocess.run([str(ROOT / "warmc/warmc"), "compile",
            str(MODULE / "Kernel.aui") + "," + str(MODULE / "Kernel.aum"),
            str(ROOT / "warmc/test-programs/kernel" / (name + ".aum")),
            "--entrypoint=" + name + ":main", "--target-type=hc",
            "--output=" + str(OUT / (name + ".HC"))], cwd=OUT, capture_output=True)
        diagnostic_text = (result.stdout + result.stderr).decode(errors="replace")
        (OUT / (name + ".log")).write_text(diagnostic_text)
        assert result.returncode and diagnostic in diagnostic_text, diagnostic_text
        print("warm-kernel: rejects " + name, flush=True)
    # Exercise Unit/U0, scalar and decayed-span foreign calls directly.
    foreign_hc = OUT / "ForeignUnit.HC"
    foreign_bin = OUT / "ForeignUnit.BIN"
    run(ROOT / "warmc/warmc", "compile", ROOT / "warmc/test-programs/kernel/ForeignUnit.aum",
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
    run("mcopy", "-o", "-i", disk, MODULE / "Adapter.HC", "::")
    for name in ("Files", "Screen", "Key", "Errors"):
        if args.filter not in name:
            continue
        hc = OUT / (name + ".HC")
        run(ROOT / "warmc/warmc", "compile",
            str(MODULE / "Kernel.aui") + "," + str(MODULE / "Kernel.aum"),
            ROOT / "warmc/examples/kernel" / (name + ".aum"),
            "--entrypoint=" + name + ":main", "--target-type=hc", "--output=" + str(hc))
        prefix = ""
        if name == "Errors":
            prefix = ("I64 WarmThrowWrite(U8 *p, U8 *d, I64 n) { throw('WarmTest'); return 0; }\n"
                      "#define FileWrite WarmThrowWrite\n")
        hc.write_text(prefix + '#include "C:/Adapter.HC"\n' +
                      hc.read_text())
        run("mcopy", "-o", "-i", disk, hc, "::")
        script = OUT / (name + ".input")
        marker = "WARM " + name.upper().replace("FILES", "FILE") + " PASS"
        # Type once the shell prompts; stop the VM once the program has passed (coolvm wait/quit).
        script.write_text("wait Cool shell\nwait > \n" + kv.typed('#include "C:/' + name + '.HC"') +
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
        assert marker in output.splitlines(), output[-6000:]
        shell_output = output.split('> #include', 1)[-1]
        errors = [line for line in shell_output.splitlines() if "ERROR:" in line]
        expected_errors = ['ERROR: File not found: "C:/Absent.txt".'] if name == "Errors" else []
        assert errors == expected_errors, shell_output[-6000:]
        assert "heap overflow" not in shell_output, shell_output[-6000:]
        if name == "Screen":
            width, height, rows = kv.read_png(OUT / "Screen.png")
            assert width > 50 and height > 420
            assert all(row[10*3:50*3] == bytes([0, 255, 0]) * 40
                       for row in rows[400:420]), "Warm framebuffer rectangle missing"
        print("warm-kernel: " + name + " PASS", flush=True)
    if not args.filter or args.filter == "Files":
        data = run("mtype", "-i", disk, "::Warm.txt").stdout
        assert data == b"Warm FAT32\n", data

if __name__ == "__main__":
    main()
