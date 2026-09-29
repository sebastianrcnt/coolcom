#!/usr/bin/env python3
"""Ctrl+B, Up and Esc must give the same key events (os/Kernel/Key.HC) from the VM
window's input FIFO and from the host terminal on the UART.

The window types a shell line that prints six GetKey events, then Ctrl+B, Up, Esc;
once those three are printed, the same keys go to the UART as raw bytes
(0x02, ESC [ A, a lone ESC that only the timeout makes Esc).
Usage: key-test.py kernel.Image
"""
import importlib.util
import pathlib
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("kv", ROOT / "tools/kernel-verify.py")
kv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kv)

LCTRL, B, UP, ESC = 29, 48, 103, 1
EXPECT = ["2000062", "110001", "1B"]  # KF_CTRL|'b', KEY_UP, KEY_ESC
LINE = r'I64 i; for (i = 0; i < 6; i++) Print("key %X\n", GetKey);'


def main():
    script = ROOT / "build/key-test-input.txt"
    script.write_text("delay 3000\n" + kv.typed(LINE) +
                      f"1 {LCTRL} 1\n" + kv.keys_of(B) + f"1 {LCTRL} 0\n" +
                      kv.keys_of(UP) + kv.keys_of(ESC))
    vm = subprocess.Popen(["gtimeout", "-k", "2", "25", "build/coolvm", "--headless", "--cpus", "2",
                           "--mem", "1024", "--timeout", "20", "--input-script", str(script), sys.argv[1]],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out, keys = [], []

    def reader():
        for raw in vm.stdout:
            line = raw.decode(errors="replace").strip()
            out.append(line)
            if line.startswith("key "):
                keys.append(line[4:])

    threading.Thread(target=reader, daemon=True).start()
    deadline = time.time() + 20
    while len(keys) < 3 and time.time() < deadline:
        time.sleep(0.05)
    if len(keys) == 3:
        vm.stdin.write(b"\x02\x1b[A\x1b")
        vm.stdin.flush()
    while len(keys) < 6 and time.time() < deadline:
        time.sleep(0.05)
    vm.kill()
    if keys != EXPECT * 2:
        print("\n".join(out[-30:]))
        raise SystemExit(f"key-test: window then UART gave {keys}, expected {EXPECT} twice")
    print("key-test: Ctrl+B, Up and Esc are the same events from the window and the UART")


if __name__ == "__main__":
    main()
