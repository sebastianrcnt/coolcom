/* Real split queues plus the real vendored renderer; no guest or vCPU. */
#define main gpu_2d_test_main
#include "gpu-test.c"
#undef main
#include "../src/gpu3d.h"
#include "vn_protocol_driver.h"
#include <virglrenderer.h>
#include <sys/mman.h>
static void context_header(uint32_t ctx) { put(16,ctx); }
static void create_blob(uint32_t id)
{
    start();context_header(1);put(24,id);put(28,2);put(32,1);put(48,16384);
    assert(vio32(send(0,0x10c,56))==0x1100);
}
static uint32_t map_blob(uint32_t id,uint64_t offset)
{
    start();put(24,id);memcpy(mem(0x4020),&offset,8);
    return vio32(send(0,0x208,40));
}
static void stream(struct vn_cs_encoder *e)
{
    assert(e->len<=480);start();context_header(1);put(24,e->len);memcpy(mem(0x4020),e->data,e->len);
    uint8_t *r=send(0,0x207,32+e->len);
    assert(vio32(r)==0x1100 && vio32(r+16)==1);e->len=0;
}
int main(void)
{
    assert(hv_vm_create(NULL)==HV_SUCCESS);
    g.gpu=true;g.fb_width=8;g.fb_height=32;g.ram_size=1<<20;g.ram=calloc(1,g.ram_size);pthread_mutex_init(&g.lock,NULL);gpu_init();
    assert(rd(0x10)==0x19);wr(0xac,1);assert(rd(0xb0)==GPU3D_SHM_SIZE && rd(0xb8)==0 && rd(0xbc)==4);
    wr(0xac,0);assert(rd(0xb0)==UINT32_MAX && rd(0xb4)==UINT32_MAX);wr(0xac,1);
    wr(0x70,3);wr(0x24,1);wr(0x20,1);wr(0x24,0);wr(0x20,0x19);wr(0x70,11);initq(0);wr(0x70,15);
    assert(rd(0x10c)==1);
    start();uint8_t *r=send(0,0x108,32);assert(vio32(r)==0x1102 && vio32(r+24)==4 && vio32(r+32)==156);
    start();put(24,4);assert(vio32(send(0,0x109,32))==0x1103);
    start();put(24,1);assert(vio32(send(0,0x108,32))==0x1205);
    start();context_header(1);put(28,4);assert(vio32(send(0,0x200,96))==0x1100);
    start();context_header(1);put(28,4);assert(vio32(send(0,0x200,96))==0x1205); /* duplicate */
    start();context_header(9);put(28,4);assert(vio32(send(0,0x200,96))==0x1100);
    create_blob(1);create_blob(2);
    start();context_header(9);put(24,1);assert(vio32(send(0,0x202,32))==0x1205); /* unshareable HOST3D */
    start();context_header(9);assert(vio32(send(0,0x201,24))==0x1100);
    start();context_header(9);assert(vio32(send(0,0x207,32))==0x1204);

    assert(map_blob(1,0)==0x1106);
    assert(map_blob(2,0)==0x1205); /* overlapping aperture */
    assert(map_blob(2,UINT64_MAX-16383)==0x1205); /* wrapping offset */
    assert(map_blob(2,1)==0x1205);assert(map_blob(2,GPU3D_SHM_SIZE)==0x1205);
    assert(map_blob(2,16384)==0x1106);
    /* A 2D resource cannot reuse a renderer resource id. */
    start();put(24,1);put(28,1);put(32,8);put(36,32);assert(vio32(send(0,0x101,40))==0x1205);
    struct vn_cs_encoder e={0};VkCommandStreamDescriptionMESA reply_stream={.resourceId=1,.size=16384};
    vn_encode_vkSetReplyCommandStreamMESA(&e,0,&reply_stream);stream(&e);
    uint64_t ptr=0;assert(!virgl_renderer_resource_get_map_ptr(1,&ptr));
    uint32_t api=0;vn_encode_vkEnumerateInstanceVersion(&e,VK_COMMAND_GENERATE_REPLY_BIT_EXT,&api);stream(&e);
    struct vn_cs_decoder d={(const uint8_t *)(uintptr_t)ptr,16384,0};
    assert(vn_decode_vkEnumerateInstanceVersion_reply(&d,&api)==VK_SUCCESS && api>=VK_API_VERSION_1_1);
    /* A nonzero timeline without a Vulkan queue is rejected, not falsely fenced. */
    /* A direct header exercises INFO_RING_IDX (the shared queue helper uses ring 0). */
    uint8_t cmd[32]={0},out[64]={0};size_t n=24;
    vio_put32(cmd,0x207);vio_put32(cmd+4,3);vio_put32(cmd+16,1);cmd[20]=63;
    memcpy(out,cmd,24);
    assert(gpu3d_command(cmd,sizeof cmd,out,sizeof out,&n) && vio32(out)==0x1200 && !vio32(out+4));
    /* Malformed stream size fails without reporting a completed submission fence. */
    start();context_header(1);put(24,4);r=send(0,0x207,32);assert(vio32(r)==0x1205 && vio32(r+4)==0);
    start();context_header(1);assert(vio32(send(0,0x201,24))==0x1205); /* owner still has blobs */
    /* GUEST backing and context attachment, used for Venus ring/reply resources. */
    start();put(24,3);put(28,1);put(32,1);put(36,1);put(48,16384);
    uint64_t addr=DRAM_BASE+0x10000;memcpy(mem(0x4038),&addr,8);put(64,16384);
    assert(vio32(send(0,0x10c,72))==0x1100);
    start();context_header(1);put(24,3);assert(vio32(send(0,0x202,32))==0x1100);
    start();context_header(1);put(24,3);assert(vio32(send(0,0x203,32))==0x1100);
    start();put(24,3);assert(vio32(send(0,0x102,32))==0x1100);
    start();put(24,2);assert(vio32(send(0,0x209,32))==0x1100);
    start();put(24,2);assert(vio32(send(0,0x209,32))==0x1205);
    start();put(24,2);assert(vio32(send(0,0x102,32))==0x1100);
    /* Reset must unmap remaining blob 1 before renderer cleanup. */
    wr(0x70,0);assert(rd(0x70)==0);
    void *test=mmap(NULL,16384,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);assert(test!=MAP_FAILED);
    assert(hv_vm_map(test,GPU3D_SHM_BASE,16384,HV_MEMORY_READ|HV_MEMORY_WRITE)==HV_SUCCESS);
    assert(hv_vm_unmap(GPU3D_SHM_BASE,16384)==HV_SUCCESS);munmap(test,16384);
    gpu3d_cleanup();assert(hv_vm_destroy()==HV_SUCCESS);free(g.ram);
    puts("venus-gpu-test: capsets, contexts, fenced SUBMIT_3D, blobs, bounds, reset PASS");
    return 0;
}
