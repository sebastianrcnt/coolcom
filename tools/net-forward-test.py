#!/usr/bin/env python3
"""coolvm --net-forward into the OS: a remote shell (ShellServe) and the HTTP file
server (HttpServe) reached from the host, and Wget from a host HTTP server to C:.
Needs no Internet access. Usage: net-forward-test.py kernel.Image"""
import http.server
import pathlib
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
D = ROOT / 'build/net-forward-test'


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def fail(msg):
    print(f'net-forward-test: FAIL: {msg}; see {D}/vm.log')
    sys.exit(1)


def wait_log(pat, t=20):
    end = time.time() + t
    while time.time() < end:
        if pat in (D / 'vm.log').read_bytes():
            return
        time.sleep(0.1)
    fail(f'{pat!r} never appeared in the VM log')


def read_until(s, pat, t=10):
    buf, end = b'', time.time() + t
    while time.time() < end and pat not in buf:
        try:
            d = s.recv(4096)
            if not d:
                break
            buf += d
        except socket.timeout:
            pass
    return buf


def shell(port):
    s = socket.create_connection(('127.0.0.1', port), timeout=5)
    s.settimeout(0.2)
    if b'> ' not in read_until(s, b'> ', 20):
        fail('no remote shell prompt')
    return s


def run(s, line, expect, t=15):
    s.sendall(line.encode() + b'\r')
    out = read_until(s, expect.encode(), t)
    if expect.encode() not in out:
        fail(f'remote shell: {line!r} gave {out!r}, expected {expect!r}')
    read_until(s, b'> ', 5)
    return out


def get(port, path):
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def main():
    kernel = sys.argv[1]
    D.mkdir(parents=True, exist_ok=True)
    disk = D / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(32 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'NETFWD', '::'], check=True)
    hello = b'Hello from C: over HTTP\n' * 100
    (D / 'Hello.txt').write_bytes(hello)
    subprocess.run(['mcopy', '-o', '-i', str(disk), str(D / 'Hello.txt'), '::Hello.txt'], check=True)
    subprocess.run(['mmd', '-i', str(disk), '::Sub'], check=True)
    # The host's HTTP server, which the guest reaches as 10.0.2.2.
    web = D / 'web'
    web.mkdir(exist_ok=True)
    remote = bytes(range(256)) * 300  # binary, 76800 bytes
    (web / 'Remote.bin').write_bytes(remote)
    handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory=str(web), **k)
    http.server.SimpleHTTPRequestHandler.log_message = lambda *a: None
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    hport, sport, wport = srv.server_address[1], free_port(), free_port()
    log = (D / 'vm.log').open('wb')
    vm = subprocess.Popen(['build/coolvm', '--headless', '--cpus', '2', '--mem', '1024', '--timeout', '60',
                           '--disk', str(disk), '--net-forward', f'{sport}:23', '--net-forward', f'{wport}:80',
                           kernel], stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT, cwd=ROOT)
    try:
        wait_log(b'compiler loaded')
        wait_log(b'net: DHCP address')
        vm.stdin.write(b'ShellServe(23); HttpServe(80, "C:/");\n')
        vm.stdin.flush()
        wait_log(b'HttpServe: C:/ on port 80')
        a, b = shell(sport), shell(sport)
        # Independent shells: the same name holds different values.
        run(a, 'I64 Value = 1;', '')
        run(b, 'I64 Value = 2;', '')
        run(a, 'Print("A=%d\\n", Value * 21);', 'A=21')
        run(b, 'Print("B=%d\\n", Value * 21);', 'B=42')
        # Line editing: Backspace, Left and Right.
        run(a, 'Prnt\x1b[D\x7fin\x1b[C("edited\\n");', 'edited\r\n')
        # Ctrl+C breaks a busy statement; the shell keeps its state.
        a.sendall(b'while (TRUE) {}\r')
        time.sleep(0.5)
        a.sendall(b'\x03')
        if b'Break' not in read_until(a, b'Break'):
            fail('Ctrl+C did not break the statement')
        read_until(a, b'> ', 5)
        run(a, 'Print("after=%d\\n", Value);', 'after=1')
        # Wget from the host's server to C:, in the remote shell.
        run(a, f'Wget("http://10.0.2.2:{hport}/Remote.bin", "C:/Sub/Got.bin");', f'Wget: {len(remote)} bytes saved')
        # The HTTP file server, from the host.
        st, body = get(wport, '/Hello.txt')
        if st != 200 or body != hello:
            fail(f'GET /Hello.txt: {st}, {len(body)} bytes')
        st, body = get(wport, '/Sub/Got.bin')
        if st != 200 or body != remote:
            fail(f'GET /Sub/Got.bin: {st}, {len(body)} bytes (Wget saved it)')
        st, body = get(wport, '/')
        if st != 200 or b'Hello.txt' not in body or b'Sub/' not in body:
            fail(f'GET /: {st} {body[:200]!r}')
        st, body = get(wport, '/Sub')  # redirected to /Sub/
        if st != 200 or b'Got.bin' not in body:
            fail(f'GET /Sub: {st} {body[:200]!r}')
        st, _ = get(wport, '/Missing.txt')
        if st != 404:
            fail(f'GET /Missing.txt: {st}')
        st, _ = get(wport, '/../x')
        if st not in (400, 404):
            fail(f'GET /../x: {st}')
        # Disconnecting kills that shell only; Exit; closes the connection.
        a.close()
        time.sleep(1)
        out = run(b, 'TaskRep;', 'RShell')
        if out.count(b'RShell ') != 1:
            fail(f'a disconnected shell is still running: {out!r}')
        b.sendall(b'Exit;\r')
        read_until(b, b'never', 5)
        try:
            gone = b.recv(1) == b''
        except (socket.timeout, ConnectionError):
            gone = False
        if not gone:
            fail('Exit; did not close the connection')
        b.close()
    finally:
        vm.kill()
        vm.wait()
        srv.shutdown()
    print('net-forward-test: --net-forward, ShellServe (2 shells, editing, Ctrl+C, disconnect, Exit), '
          'Wget to C: and HttpServe PASS')


main()
