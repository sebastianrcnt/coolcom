#!/usr/bin/env python3
"""Task-owned GUI windows: terminal apps, focus, geometry, lifecycle, and pixels.
All VM setup and PNG decoding uses testvm. Artifacts: build/gui-test/.
"""
import pathlib
import subprocess
import sys
import testvm
from testvm import ROOT

OUT = ROOT / 'build/gui-test'
KERNEL = sys.argv[1]
VENUS = '--venus' in sys.argv
OUT.mkdir(parents=True, exist_ok=True)


def line(code, marker):
    return testvm.typed(code + f' U8 *m = MStrPrint("GUITEST%d\\n", {marker}); GuiLog(m); Free(m);\n') + f'wait GUITEST{marker}\n'


def boot(mode, scale=1):
    d = OUT / f'{mode}-{scale}x'
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    if mode == 'venus':
        subprocess.run([str(ROOT / 'tools/venus/install.sh'), str(disk)], check=True, stdout=subprocess.DEVNULL)
    # Keep chrome/terminal font deterministic even when the host has Sarasa.
    init = (ROOT / 'os/Disk/Init.cool').read_text()
    init += '\nFontSet(NULL);\n'
    (d / 'Init.cool').write_text(init)
    subprocess.run(['mcopy', '-o', '-i', str(disk), str(d / 'Init.cool'), '::Init.cool'], check=True)
    script = testvm.BOOT + testvm.typed('Gui;\n') + 'wait GUI READY\nwait GUI WINDOWS READY\n' + testvm.typed('if(gui.count!=1)throw(90); GuiShell;\n') + 'wait GUI SHELL OPEN\n'
    script += line('CVTerm *back = gui.windows[0]->term; I64 dl = SpinLockIrq(&back->lock); back->bg = ANSI_RGB_FLAG | 0x204060; VtClear(back); back->dirty = TRUE; SpinUnlockIrq(&back->lock, dl);', 40)
    script += line('ConsPutS("\\e[2J\\e[H"); Print("WINDOW ONE\\n");', 1)
    # Click the left close box of the background window; its task is reaped.
    script += f'2 0 {-369*scale}\n2 1 {-256*scale}\ndelay 30\n1 272 1\ndelay 30\n1 272 0\ndelay 30\n1 272 1\ndelay 30\n1 272 0\ndelay 30\n'
    script += line('if (gui.count != 1) throw(5); GuiShell;', 11) + 'wait GUI WINDOWS READY\n'
    script += line('if (gui.count != 2) throw(6);', 12)
    # Restore pointer to its initial position for the title-drag scenario.
    script += f'2 0 {369*scale}\n2 1 {256*scale}\ndelay 30\n'
    # Existing, unchanged applications run on the window terminal.
    script += testvm.typed('Vim("C:/Init.cool");\n') + 'delay 300\n' + testvm.typed(':q\n')
    script += line('if (VtCurrent->alternate) throw(1);', 2)
    script += testvm.typed('Top;\n') + 'delay 300\n' + testvm.typed('q')
    script += line('if (VtCurrent->cols < 10) throw(2);', 3)
    script += testvm.typed('Tmux;\n') + 'delay 400\n'
    script += '1 29 1\n' + testvm.keys_of(48) + '1 29 0\n' + testvm.typed('d')
    # Mouse title drag preserves the task and its terminal.
    script += f'2 0 {-300*scale}\n2 1 {-236*scale}\ndelay 30\n1 272 1\ndelay 30\n2 0 {40*scale}\n2 1 {20*scale}\ndelay 30\n1 272 0\ndelay 30\n'
    script += line('if (gui.focus->x != 84 || gui.focus->y != 78) throw(3);', 31)
    # Keyboard tile, then restore floating geometry.
    script += '1 29 1\n1 56 1\n' + testvm.keys_of(105) + '1 56 0\n1 29 0\ndelay 30\n'
    script += line('if (gui.focus->x || gui.focus->y != GUI_MENU) throw(4);', 32)
    script += line('GuiZoom(Fs->gui_window); GuiZoom(Fs->gui_window); GuiMove(Fs->gui_window, 80, 90); GuiResize(Fs->gui_window, 400, 208);', 4)
    script += line('CVTerm *back = gui.windows[0]->term; I64 dl = SpinLockIrq(&back->lock); back->bg = ANSI_RGB_FLAG | 0x204060; VtClear(back); back->dirty = TRUE; SpinUnlockIrq(&back->lock, dl);', 40)
    script += line('ConsPutS("\\e[2J\\e[H"); Print("\\e[31mRED\\e[0m \\e[7mREVERSE\\e[0m\\n"); AnsiCursorHide;', 5)
    script += 'delay 300\nquit\n'
    (d / 'input.txt').write_text(script)
    vm = ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm')
    testvm.run_vm(testvm.vm_command(KERNEL, executable=vm, no_venus=mode != 'venus',
        timeout=100, host_timeout=120, disk=disk, input_script=d / 'input.txt',
        screenshot=d / 'screen.png', size=(800 * scale, 600 * scale), scale=scale),
        d / 'vm.log', stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert 'GUITEST5' in log, f'{d}: window apps did not return'
    assert ('GUI VENUS READY' in log) == (mode == 'venus'), f'{d}: wrong compositor'
    assert 'ERROR:' not in log and 'VENUS FAIL' not in log and 'Except' not in log.split('GUI READY', 1)[-1], log[-2000:]
    return testvm.read_png(d / 'screen.png')


cpu = boot('cpu')
# Chrome pixel checks are independent of the guest's rendering code.
w, h, rows = cpu
px = lambda x, y: tuple(rows[y][3*x:3*x+3])
assert px(700, 300) == (0, 0, 0) and px(701, 300) == (255, 255, 255), 'desktop dither'
# x=720: left of the clock (drawn from x=748), whose digits change with the time of day.
assert px(720, 10) == (255, 255, 255) and px(750, 21) == (0, 0, 0), 'menu bar'
assert px(80, 90) == (0, 0, 0) and px(81, 91) == (255, 255, 255), 'window border'
assert px(104, 94) == (0, 0, 0), 'active title stripes'
assert px(70, 150) == (32, 64, 96), 'background window has independent blue content'
assert px(90, 150) == (0, 0, 0), 'front body must occlude background content'
assert px(80, 150) == (0, 0, 0) and px(81, 150) == (255, 255, 255), 'left border and inset'
assert px(100, 339) == (0, 0, 0) and px(100, 340) == (0, 0, 0), 'bottom border and shadow'
assert px(51, 64) == (255, 255, 255), 'inactive close box hidden'
assert px(524, 344) == (255, 255, 255), 'inactive resize box hidden'
assert px(700, 300) != px(701, 300)
two = boot('cpu', 2)
for y in range(h):
    end = w - 60 if y < 21 else w
    doubled = b''.join(rows[y][3*x:3*x+3] * 2 for x in range(end))
    assert two[2][2*y][:6*end] == doubled and two[2][2*y+1][:6*end] == doubled, f'GUI HiDPI row {y}'
print('gui-test: 2x chrome and content equal 1x doubled', flush=True)
if VENUS:
    gpu = boot('venus')
    assert gpu[:2] == cpu[:2]
    # The clock can cross a minute between boots; all other pixels must agree.
    for y in range(h):
        end = 3 * (w - 60) if y < 21 else 3 * w
        assert rows[y][:end] == gpu[2][y][:end], f'CPU/Venus mismatch row {y}'
    print('gui-test: CPU and Venus composition pixels match', flush=True)
else:
    print('gui-test: Venus not installed; GPU comparison skipped', flush=True)
print('gui-test: G1 PASS', flush=True)
