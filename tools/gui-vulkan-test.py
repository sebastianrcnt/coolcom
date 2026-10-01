#!/usr/bin/env python3
"""App-owned Vulkan window sampling, CPU mirror equality and producer lifetime."""
import re
import subprocess
import sys
import testvm
from testvm import ROOT
KERNEL=sys.argv[1]
OUT=ROOT / 'build/gui-vulkan-test'
FIXTURE=r'''
I64 vk_blobs;
CGuiWindow *VkWindow() {I64 i;for(i=0;i<gui.count;i++)if(gui.windows[i]->pixel)return gui.windows[i];return NULL;}
I64 VkBlobCount() {I64 i,n=0;for(i=0;i<GPU_VENUS_BLOBS;i++)if(venus.blobs[i].id)n++;return n;}
U0 VkMarker(I64 id) {U8 *m=MStrPrint("VKTEST%d\n",id);GuiLog(m);Free(m);}
U0 VkStart(U8 *data)
{
    CVTerm *v=VtNew(80,24);VtBind(Fs,v);v->owner=Fs;v->sink=&GuiShellSink;VtRelease(v);ShellTask(0);
    if(data(I64)) ShellExe("#include \"C:/Cube.cool\"\nCubeWindow(0,FALSE);");
    else ShellExe("#include \"C:/Cube.cool\"\nCubeWindow;");
}
U0 VkLaunch(Bool copy=FALSE) {Spawn(&VkStart,copy(U8 *),"VkCube",0,adam_task,SHELL_STACK);}
U0 VkInspect(Bool direct)
{
    CGuiWindow *w=VkWindow; I64 x,y,colored=0,overlay=0; U32 p;
    if(!w || !w->pixel || (w->vk_view!=0)!=direct) throw(5);
    if(GuiVulkanPresent(w->vk_device,w->vk_view,w->vk_w,w->vk_h))throw(11); // A terminal task cannot publish another window.
    if(direct) {
        if(!w->vk_mirror || w->vk_device!=gui.vk_device) throw(6);
        for(y=0;y<w->vk_h;y++)for(x=0;x<w->vk_w;x++) {
            p=w->vk_mirror[y*w->vk_w+x]; if((p&255)!=((p>>16)&255))colored++;
            p=w->pixels[(y+(GUI_TITLE+GUI_PAD)*w->scale)*w->pw+x+(1+GUI_PAD)*w->scale];if(p>>24)overlay++;
        }
        if(colored<10000 || overlay>5000*w->scale*w->scale) throw(7);
    }
    while(w->presented<w->revision) Sleep(1);
    GuiFocus(w);VkMarker(1);
}
U0 VkMulti()
{
    I64 i,n=0;CGuiWindow *w;
    for(i=0;i<gui.count;i++) {w=gui.windows[i];if(w->vk_view) {if(w->vk_device!=gui.vk_device)throw(9);n++;}}
    if(n!=2)throw(10);VkMarker(4);
}
U0 VkCloseAll() {I64 i;for(i=0;i<gui.count;i++)if(gui.windows[i]->pixel)GuiClose(gui.windows[i]);}
U0 VkBaseline() {while(gui.frames<3)Sleep(1);vk_blobs=VkBlobCount;VkMarker(2);}
U0 VkLife()
{
    while(gui.count!=2)Sleep(1);
    // Reap the unused compositor texture before checking borrowed app resources.
    I64 frame=gui.frames;GuiDamage(0,0,gui.w,gui.h);while(gui.frames<=frame)Sleep(1);
    if(VkBlobCount!=vk_blobs)throw(8);VkMarker(3);
}
'''

def boot(name,scale=1,copy=False,cpu=False,lifecycle=False,exit_gui=False,multiple=False,size=None):
    width,height=size or (800*scale,600*scale)
    d=OUT / name;d.mkdir(parents=True,exist_ok=True)
    disk=d / 'disk.img';testvm.create_disk(disk);testvm.install_disk_files(disk,stdout=subprocess.DEVNULL)
    subprocess.run([ROOT / 'tools/venus/install.sh',disk],check=True,stdout=subprocess.DEVNULL)
    for shader in (ROOT / 'build/venus').glob('cube.*.spv'):subprocess.run(['mcopy','-o','-i',disk,shader,'::Vulkan/'],check=True)
    fixture=d / 'VkProbe.cool';fixture.write_text(FIXTURE);subprocess.run(['mcopy','-o','-i',disk,fixture,'::VkProbe.cool'],check=True)
    script=testvm.BOOT
    if exit_gui:
        script+=testvm.typed('I64 before=0,i;for(i=0;i<GPU_VENUS_BLOBS;i++)if(venus.blobs[i].id)before++;\n')
    script+=testvm.typed('FontSet(NULL); Gui;\n')+'wait GUI WINDOWS READY\n' + testvm.typed('if(gui.count!=1)throw(90); GuiShell;\n') + 'wait GUI SHELL OPEN\n'
    script+=testvm.typed('#include "C:/VkProbe.cool"\nVkBaseline;\n')+'wait VKTEST2\n'
    if cpu:script+=testvm.typed('gui.frame_hook=NULL;\n')
    script+=testvm.typed(f'VkLaunch({"TRUE" if copy else "FALSE"});\n')+'wait CUBE WINDOW READY\n'
    script+=testvm.typed('r ',delay=0)+'wait CUBE WINDOW KEY\nwait CUBE WINDOW KEY\n'
    root_focus='1 29 1\n1 56 1\n'+testvm.keys_of(15)+testvm.keys_of(15)+'1 56 0\n1 29 0\ndelay 30\n'
    root_click=testvm.pointer_absolute(200*scale,65*scale,width,height)+'delay 20\n1 272 1\ndelay 20\n1 272 0\ndelay 20\n'
    script+=root_focus
    script+=testvm.typed(f'VkInspect({"FALSE" if copy else "TRUE"});\n')+'wait VKTEST1\n'
    if multiple:
        script+=root_click+testvm.typed('VkLaunch;\n')+'wait CUBE WINDOW READY\n'
        script+=root_click+testvm.typed('VkMulti;\n')+'wait VKTEST4\n'
        script+=testvm.typed('VkCloseAll; VkLife;\n')+'wait VKTEST3\n'
    if lifecycle:
        # Abrupt producer kill, graceful server close, then graceful application quit.
        for action in ['Kill(VkWindow->owner,FALSE);','GuiClose(VkWindow);',None]:
            if action:script+=root_focus+testvm.typed(action+'\n')
            else:script+=testvm.typed('q')+'wait CUBE CLOSED\n'
            script+=root_click+testvm.typed('VkLife;\n')+'wait VKTEST3\n'
            if action!=None:script+=testvm.typed('VkLaunch;\n')+'wait CUBE WINDOW READY\n'
    if exit_gui:
        script+='1 29 1\n1 56 1\n'+testvm.keys_of(16)+'1 56 0\n1 29 0\ndelay 100\n'
        script+=testvm.typed('while(gui.task)Sleep(1); I64 after=0;for(i=0;i<GPU_VENUS_BLOBS;i++)if(venus.blobs[i].id)after++;Print("VKLIFE%d %d %d\\n",1,before,after);\n')+'wait VKLIFE1\n'
    script+='delay 150\nquit\n';(d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(KERNEL,executable=ROOT / 'build/coolvm-venus',size=(width,height),scale=scale,
        timeout=100,host_timeout=120,disk=disk,input_script=d / 'input.txt',screenshot=d / 'screen.png'),d / 'vm.log',stdin=subprocess.DEVNULL,check=True)
    log=(d / 'vm.log').read_text(errors='replace')
    assert 'VKTEST1' in log and not any(s in log for s in ['ERROR:','VENUS FAIL','graphics error','Exception:']),log[-3000:]
    assert ('CUBE VULKAN WINDOW READY' in log)==(not copy),log[-1000:]
    if lifecycle:assert log.count('VKTEST3')==3,log[-2000:]
    if exit_gui:
        m=re.search(r'VKLIFE1 (\d+) (\d+)',log);assert m and m[1]==m[2],log[-2000:]
    print(f'gui-vulkan-test: {name} PASS',flush=True)
    return testvm.read_png(d / 'screen.png')


def odd_edges():
    direct=boot('odd-direct-2x',2,size=(1031,775))
    cpu=boot('odd-cpu-2x',2,cpu=True,size=(1031,775))
    # The foreground client extends past both screen edges. Include the final
    # physical row and column, which are only half a logical pixel at 2x.
    for y in range(164,775):
        assert direct[2][y][408:]==cpu[2][y][408:],f'clipped odd-screen mismatch row {y}'
    print('gui-vulkan-test: clipped odd-sized 2x screen pixels match PASS',flush=True)


if '--odd-only' in sys.argv:
    odd_edges();sys.exit(0)
for scale in (() if '--lifetime-only' in sys.argv else (1,2)):
    direct=boot(f'direct-{scale}x',scale)
    copy=boot(f'copy-{scale}x',scale,copy=True)
    cpu=boot(f'cpu-mirror-{scale}x',scale,cpu=True)
    # The window's complete frame, client scene and HUD must match exactly.
    for y in range(82*scale,423*scale):
        start,end=3*68*scale,3*557*scale
        assert direct[2][y][start:end]==copy[2][y][start:end],f'direct/copy pixel mismatch {scale}x row {y}'
        assert direct[2][y][start:end]==cpu[2][y][start:end],f'direct/CPU mirror mismatch {scale}x row {y}'
    colored=sum(1 for row in direct[2][110*scale:380*scale] for x in range(80*scale,540*scale)
                if max(row[3*x:3*x+3])-min(row[3*x:3*x+3])>45)
    assert colored>8000*scale*scale,colored
    print(f'gui-vulkan-test: {scale}x direct/readback/CPU pixels match PASS',flush=True)
if '--lifetime-only' not in sys.argv:odd_edges()
boot('multiple',multiple=True)
boot('lifetime',lifecycle=True)
boot('desktop-exit',exit_gui=True)
print('gui-vulkan-test: G5 PASS',flush=True)
