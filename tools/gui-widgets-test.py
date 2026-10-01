#!/usr/bin/env python3
"""Warm capability widgets and the server menu overlay, using shared testvm."""
import subprocess
import sys
import testvm
from testvm import ROOT
OUT = ROOT / 'build/gui-widgets-test'
KERNEL = sys.argv[1]

def boot(mode, close=False):
    d = OUT / (mode + ('-close' if close else ''))
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    # Exercise UTF-8 codepoint boundaries on the real toolkit without relying on
    # the host keyboard layout. The example below still runs unchanged afterward.
    fixture = (ROOT / 'warmc/examples/gui/Widgets.warm').read_text()
    checks = '''textInput(&!w, &!input, Rect(x => 16, y => 176, width => 288, height => 28), Mouse(x => 20, y => 188, buttons => 1, wheel => 0));
        textInput(&!w, &!input, Rect(x => 16, y => 176, width => 288, height => 28), Key(code => 44032));
        if spanLength(inputText(&input)) /= 3 then abort("UTF-8 insertion failed"); end if;
        textInput(&!w, &!input, Rect(x => 16, y => 176, width => 288, height => 28), Key(code => 1114115));
        textInput(&!w, &!input, Rect(x => 16, y => 176, width => 288, height => 28), Key(code => 1114122));
        if spanLength(inputText(&input)) /= 0 then abort("UTF-8 deletion failed"); end if;
        printLn("GUI WIDGET UTF8 PASS");
        '''
    fixture = fixture.replace('var running: Bool',checks + 'var running: Bool')
    (d / 'Widgets.warm').write_text(fixture)
    subprocess.run(['mcopy','-o','-i',disk,d / 'Widgets.warm','::Warm/Examples/gui/Widgets.warm'],check=True)
    if mode == 'venus':
        subprocess.run([ROOT / 'tools/venus/install.sh', disk], check=True, stdout=subprocess.DEVNULL)
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n' + testvm.typed('if(gui.count!=1)throw(90); GuiShell;\n') + 'wait GUI SHELL OPEN\n'
    script += testvm.typed('GuiWidgets;\n') + 'wait GUI WIDGET READY\n'
    mx, my = 400, 300
    def move(x, y):
        nonlocal mx, my
        result = f'2 0 {x-mx}\n2 1 {y-my}\ndelay 30\n'
        mx, my = x, y
        return result
    def click(x,y):
        return move(x,y) + '1 272 1\ndelay 30\n1 272 0\ndelay 30\n'
    script += click(80, 10) + click(80, 34) + 'wait GUI WIDGET MENU\n'
    script += click(332, 161) + 'wait GUI WIDGET BUTTON\n'
    script += testvm.typed('\n') + 'wait GUI WIDGET BUTTON\n'
    script += click(92, 295) + testvm.typed('abc') + 'wait GUI WIDGET TEXT\n'
    script += testvm.keys_of(105) + testvm.keys_of(14) + testvm.typed('Z')
    script += click(110, 176) + 'wait GUI WIDGET LIST\n'
    if close:
        script += click(78, 92) + 'wait GUI WIDGET CLOSED\n'
    else:
        # Leave an open, highlighted File menu over the app and the shell behind it.
        script += click(80, 10) + move(80, 34)
    script += 'delay 100\nquit\n'
    (d / 'input.txt').write_text(script)
    vm = ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm')
    testvm.run_vm(testvm.vm_command(KERNEL, executable=vm, no_venus=mode == 'cpu', size=(800, 600),
        scale=1, timeout=90, host_timeout=110, disk=disk, input_script=d / 'input.txt', screenshot=d / 'screen.png'),
        d / 'vm.log', stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert 'GUI WIDGET TEXT aZc' in log, 'UTF-8 input editing state'
    assert 'ERROR:' not in log and 'VENUS FAIL' not in log and 'Type Error' not in log, log[-3000:]
    for marker in ['UTF8 PASS','READY','MENU','BUTTON','LIST','TEXT'] + (['CLOSED'] if close else []):
        assert 'GUI WIDGET ' + marker in log, log[-3000:]
    w,h,rows = testvm.read_png(d / 'screen.png')
    pixel = lambda x,y: tuple(rows[y][3*x:3*x+3])
    if not close:
        assert pixel(70,25) == (0,0,0), 'highlighted menu item'
        assert pixel(240,75) == (255,255,255), 'opaque popup over underlying window'
        assert pixel(70,67) == (0,0,0), 'menu border'
        assert pixel(292,148) == (0,0,0) and pixel(292,149) == (0,0,0), 'default button thick frame'
        assert pixel(298,158) == (255,255,255), 'button interior'
        assert pixel(92,169) == (0,0,0), 'selected list row inverted'
        assert pixel(254,186) != pixel(255,186), 'dither scrollbar track'
        assert pixel(89,283) == (0,0,0), 'text input border'
        assert any(pixel(x,y) == (0,0,0) for y in range(287,303) for x in range(92,116)), 'edited text is visible'
    print(f'gui-widgets-test: {mode}, menus, widgets, editing, close={close} PASS', flush=True)
    return w,h,rows

cpu = boot('cpu')
boot('cpu',close=True)
if '--venus' in sys.argv:
    gpu = boot('venus')
    for y in range(cpu[1]):
        end = 3*(cpu[0]-60) if y < 21 else 3*cpu[0]
        assert cpu[2][y][:end] == gpu[2][y][:end], f'widget CPU/Venus mismatch row {y}'
print('gui-widgets-test: G3 PASS', flush=True)
