#!/usr/bin/env python3
"""Compare executed Cool encoders with unmodified upstream C encoders."""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
from gen import Generator
from vendor import ROOT, check, missing_test_inputs

OUT = ROOT / 'build/venus'
ENV = dict(os.environ, COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))


def run(argv, **kwargs):
    try:
        return subprocess.run([str(a) for a in argv], check=True, timeout=90, **kwargs)
    except subprocess.CalledProcessError as e:
        if e.stdout:
            sys.stderr.buffer.write(e.stdout)
        if e.stderr:
            sys.stderr.buffer.write(e.stderr)
        raise


def compile_cool(path):
    target = path.with_suffix('.BIN')
    result = run([ROOT / 'build/coolc', path, target], env=ENV, capture_output=True)
    path.with_suffix('.compile.log').write_bytes(result.stdout + result.stderr)
    return target


# Shared statements, differing only in storage types/casts and dump function.
CASES = [
    ('idle', 'vn_encode_vkDeviceWaitIdle(&enc,1,device);'),
    ('draw', 'vn_encode_vkCmdDraw(&enc,0,cmd,3,1,0,0);'),
    ('buffer', '''VkBufferCreateInfo b;
ZERO(b); b.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO; b.size=4096; b.usage=VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
b.sharingMode=VK_SHARING_MODE_EXCLUSIVE; b.queueFamilyIndexCount=2;
COUNT families[2]; families[0]=3; families[1]=7; b.pQueueFamilyIndices=families;
vn_encode_vkCreateBuffer(&enc,1,device,&b,0,&buffer);'''),
    ('buffer_concurrent', '''b.sharingMode=VK_SHARING_MODE_CONCURRENT;
vn_encode_vkCreateBuffer(&enc,1,device,&b,0,&buffer);'''),
    ('shader', '''VkShaderModuleCreateInfo s; ZERO(s);
COUNT code[3]; code[0]=0x07230203; code[1]=0x00010000; code[2]=7;
s.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO; s.codeSize=12; s.pCode=code;
vn_encode_vkCreateShaderModule(&enc,1,device,&s,0,&shader);'''),
    ('pipeline_pnext', '''VkGraphicsPipelineCreateInfo g; ZERO(g);
VkPipelineRenderingCreateInfo p; ZERO(p);
COUNT formats[1]; formats[0]=VK_FORMAT_R8G8B8A8_UNORM;
p.sType=VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO; p.colorAttachmentCount=1; p.pColorAttachmentFormats=FORMAT_PTR(formats);
g.sType=VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO; g.pNext=&p; g.layout=layout;
vn_encode_vkCreateGraphicsPipelines(&enc,1,device,0,1,&g,0,&pipeline);'''),
    ('rendering', '''VkRenderingInfo r; ZERO(r);
VkRenderingAttachmentInfo a; ZERO(a);
a.sType=VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO; a.imageView=view; a.imageLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
a.loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR; a.storeOp=VK_ATTACHMENT_STORE_OP_STORE;
a.clearValue.color.uint32[0]=0x3f800000; a.clearValue.color.uint32[3]=0x3f800000;
r.sType=VK_STRUCTURE_TYPE_RENDERING_INFO; r.renderArea.extent.width=640; r.renderArea.extent.height=480;
r.layerCount=1; r.colorAttachmentCount=1; r.pColorAttachments=&a;
vn_encode_vkCmdBeginRendering(&enc,0,cmd,&r);'''),
    ('ring', '''VkRingCreateInfoMESA ring; ZERO(ring);
VkRingMonitorInfoMESA monitor; ZERO(monitor);
monitor.sType=VK_STRUCTURE_TYPE_RING_MONITOR_INFO_MESA; monitor.maxReportingPeriodMicroseconds=1000;
ring.sType=VK_STRUCTURE_TYPE_RING_CREATE_INFO_MESA; ring.pNext=&monitor;
ring.resourceId=42; ring.size=4096; ring.idleTimeout=1234567;
ring.headOffset=0; ring.tailOffset=4; ring.statusOffset=8; ring.bufferOffset=64; ring.bufferSize=2048;
vn_encode_vkCreateRingMESA(&enc,0,99,&ring);'''),
    ('notify', 'vn_encode_vkNotifyRingMESA(&enc,0,99,0,0);'),
    ('wait_ring', 'vn_encode_vkWaitRingSeqnoMESA(&enc,0,99,123);'),
    ('streams', '''VkCommandStreamDescriptionMESA streams[2]; ZERO(streams);
streams[0].resourceId=42; streams[0].offset=64; streams[0].size=100;
streams[1].resourceId=43; streams[1].offset=128; streams[1].size=200;
vn_encode_vkExecuteCommandStreamsMESA(&enc,0,2,streams,0,0,0,0);'''),
    ('reply_stream', 'vn_encode_vkSetReplyCommandStreamMESA(&enc,0,&streams[0]);'),
    ('wait_fences', '''FENCE fences[2]; fences[0]=FENCE_ID(0x1001); fences[1]=FENCE_ID(0x1002);
vn_encode_vkWaitForFences(&enc,1,device,2,fences,1,0x123456789);'''),
    ('submit', '''VkSubmitInfo submit; ZERO(submit);
COMMAND cmds[1]; cmds[0]=cmd;
submit.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO; submit.commandBufferCount=1; submit.pCommandBuffers=cmds;
vn_encode_vkQueueSubmit(&enc,1,queue,1,&submit,fences[0]);'''),
    ('queue_timeline', """VkDeviceQueueInfo2 queue_info; ZERO(queue_info);
VkDeviceQueueTimelineInfoMESA timeline; ZERO(timeline);
queue_info.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2; queue_info.queueFamilyIndex=3; queue_info.pNext=&timeline;
timeline.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_TIMELINE_INFO_MESA; timeline.ringIdx=1;
vn_encode_vkGetDeviceQueue2(&enc,1,device,&queue_info,&queue);"""),
    ('viewport', '''VkViewport vp; ZERO(vp); vp.width=FLOAT(0x44000000); vp.height=FLOAT(0x43f00000); vp.maxDepth=FLOAT(0x3f800000);
vn_encode_vkCmdSetViewport(&enc,0,cmd,0,1,&vp);'''),
    ('instance_strings', '''VkApplicationInfo app; ZERO(app); app.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO;
app.pApplicationName="triangle"; app.pEngineName="Cool"; app.apiVersion=0x00403000;
VkInstanceCreateInfo instance; ZERO(instance); instance.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO; instance.pApplicationInfo=&app;
TEXT names[1]; names[0]="VK_KHR_dynamic_rendering"; instance.enabledExtensionCount=1; instance.ppEnabledExtensionNames=names;
vn_encode_vkCreateInstance(&enc,1,&instance,0,&inst);'''),
]


def harness(c):
    if c:
        out = ['''#include <stdio.h>
#include "vn_protocol_driver.h"
#define ZERO(x) memset(&(x),0,sizeof(x))
#define COUNT uint32_t
#define COMMAND VkCommandBuffer
#define FENCE VkFence
#define FENCE_ID(x) ((VkFence)(uintptr_t)(x))
#define FORMAT_PTR(x) ((VkFormat *)(x))
#define TEXT const char *
static float bits(uint32_t n) {float f; memcpy(&f,&n,4); return f;}
#define FLOAT(x) bits(x)
static void dump(struct vn_cs_encoder *e) {uint64_t n=e->pos; fwrite(&n,8,1,stdout); fwrite(e->data,1,n,stdout); e->pos=0;}
int main(void) {
struct vn_cs_encoder enc={0};
VkDevice device=(VkDevice)(uintptr_t)0x1122334455667788;
VkCommandBuffer cmd=(VkCommandBuffer)(uintptr_t)0x1020304050607080;
VkQueue queue=(VkQueue)(uintptr_t)0x2233445566778899;
VkBuffer buffer=(VkBuffer)(uintptr_t)0x100;
VkShaderModule shader=(VkShaderModule)(uintptr_t)0x101;
VkPipelineLayout layout=(VkPipelineLayout)(uintptr_t)0x102;
VkPipeline pipeline=(VkPipeline)(uintptr_t)0x103;
VkImageView view=(VkImageView)(uintptr_t)0x104;
VkInstance inst=(VkInstance)(uintptr_t)0x105;
''']
    else:
        out = [f'#include "{OUT / "Vulkan.cool"}"', '''import U8i *MemSet(U8i *p,I64i v,I64i n);
import I64i NativeWrite(I64i fd,U8i *p,I64i n);
import U0 NativeExit(I64i n);
U0 Dump(VenusWire *e) {if(e->error) NativeExit(1); NativeWrite(1,(&e->pos)(U8i *),8); NativeWrite(1,e->data,e->pos); e->pos=0;}
U0 Test() {
U8i data[65536]; VenusWire enc; enc.data=data; enc.pos=0; enc.capacity=65536; enc.error=0;
U64i device=0x1122334455667788,cmd=0x1020304050607080,queue=0x2233445566778899;
U64i buffer=0x100,shader=0x101,layout=0x102,pipeline=0x103,view=0x104,inst=0x105;
''']
    for name, statements in CASES:
        if not c:
            import re
            statements = re.sub(r'ZERO\((\w+)\)', r'MemSet((&\1)(U8i *),0,sizeof(\1))', statements)
            statements = statements.replace('COUNT', 'U32i').replace('COMMAND', 'U64i').replace('FENCE_ID', '').replace('FENCE', 'U64i')
            statements = statements.replace('FORMAT_PTR', '').replace('FLOAT', '').replace('TEXT', 'U8i *')
        out += ['// ' + name, statements, 'dump(&enc);' if c else 'Dump(&enc);']
    out += ['return 0;\n}' if c else '}\nTest();']
    return '\n'.join(out)


def frames(data):
    packets = []
    while data:
        assert len(data) >= 8
        n, = struct.unpack_from('<Q', data)
        assert n <= len(data)-8
        packets.append(data[8:8+n])
        data = data[8+n:]
    return packets


def main():
    missing = missing_test_inputs()
    if missing:
        print('SKIP venus-gen-test: 건너뜀 (벤더 입력 없음: ' + ', '.join(missing) +
              '); run make venus-vendor to enable the full checks')
        return
    vk, vn = check()
    # Generate only after the offline preflight, even when build/ is empty.
    run([sys.executable, ROOT / 'tools/venus/gen.py'])
    src, manifest = Generator(vk, vn, ROOT / 'tools/venus/subset.txt').generate()
    assert src == (OUT / 'Vulkan.cool').read_text(), 'generation is not deterministic'
    assert 'vkMapMemory' not in manifest['commands']
    assert 'vn_encode_vkCreateSwapchainKHR' not in src
    assert 'class VkSwapchainCreateInfoKHR' not in src
    compile_cool(OUT / 'Vulkan.cool')
    small = OUT / 'minimal-subset.txt'
    small.write_text('vkDeviceWaitIdle\n')
    minimal, subset_manifest = Generator(vk, vn, small).generate()
    assert subset_manifest['commands'] == ['vkDeviceWaitIdle']
    assert 'class VkBufferCreateInfo' not in minimal and 'vn_encode_vkCmdDraw' not in minimal
    (OUT / 'Minimal.cool').write_text(minimal)
    compile_cool(OUT / 'Minimal.cool')
    for text in ('vkTypo\n', 'vkDeviceWaitIdle\nvkDeviceWaitIdle\n'):
        small.write_text(text)
        try:
            Generator(vk, vn, small)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid subset accepted')
    print('PASS deterministic generation, subset isolation and invalid entries')
    ref = OUT / 'reference'
    ref.mkdir(exist_ok=True)
    python = ROOT / 'vendor/venus-python/bin/python'
    run([python, vn / 'vn_protocol.py', '--outdir', ref])
    shutil.copy(ROOT / 'tools/venus/tests/vn_cs.h', ref)
    shutil.copy(vn / 'tests/vn_ring.h', ref)
    (ref / 'oracle.c').write_text(harness(True))
    run(['clang', '-std=c11', '-O2', '-I' + str(ref), '-I' + str(vn / 'include'), ref / 'oracle.c', '-o', ref / 'oracle'], capture_output=True)
    expected = frames(run([ref / 'oracle'], capture_output=True).stdout)
    (OUT / 'EncodeTest.cool').write_text(harness(False))
    actual = frames(run([ROOT / 'build/coolc', '--run', compile_cool(OUT / 'EncodeTest.cool')], capture_output=True).stdout)
    assert len(actual) == len(expected) == len(CASES)
    for (name, _), a, e in zip(CASES, actual, expected):
        assert a == e, f'{name}: Cool {a.hex()} != Venus {e.hex()}'
        print(f'PASS upstream bytes: {name} ({len(a)} bytes)')
    # Literal fixture independently fixes header/id/flag/64-bit handle byte order.
    assert actual[0].hex() == '14000000010000008877665544332211'
    (OUT / 'oracle-packets.json').write_text(json.dumps(dict(zip([n for n, _ in CASES], [p.hex() for p in expected])), indent=2))
    run_decode_tests()


def run_decode_tests():
    path = OUT / 'DecodeTest.cool'
    source = (ROOT / 'tools/venus/tests/decode.cool').read_text()
    path.write_text(f'#include "{OUT / "Vulkan.cool"}"\n' + source)
    run([ROOT / 'build/coolc', '--run', compile_cool(path)], capture_output=True)
    print('PASS replies, array counts, pNext, truncation and overflow')


if __name__ == '__main__':
    main()
