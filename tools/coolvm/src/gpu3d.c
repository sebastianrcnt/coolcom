/* Opt-in Venus transport. Called under g.lock; renderer fence callbacks use
 * their own lock and never touch virtqueues. No GL context or Vulkan loader. */
#ifdef COOLVM_VENUS
#include "virtio.h"
#include "gpu3d.h"
#include <virglrenderer.h>
#include <time.h>
#include <sys/uio.h>
#define NCTX 16
#define NRES 64
#define OK 0x1100
#define INVALID 0x1205
#define BAD_CONTEXT 0x1204
#define BAD_RESOURCE 0x1203
struct blob {
    uint32_t id,owner,mem,flags;
    uint64_t size,offset;
    void *ptr;
    struct iovec *iov;
    bool mapped;
    uint32_t attached;
};
static struct {
    bool ready;
    uint32_t ctx[NCTX],shmsel,capversion,capsize;
    struct blob blobs[NRES];
} venus;
static pthread_mutex_t fence_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fence_cv=PTHREAD_COND_INITIALIZER;
static uint64_t next_fence,done_fence;
static void context_fence(void *cookie,uint32_t ctx,uint32_t ring,uint64_t fence)
{
    pthread_mutex_lock(&fence_lock);
    if(fence>done_fence)done_fence=fence;pthread_cond_broadcast(&fence_cv);
    pthread_mutex_unlock(&fence_lock);
}
static struct virgl_renderer_callbacks callbacks={.version=3,.write_context_fence=context_fence};
static int context(uint32_t id)
{ for(int i=0;i<NCTX;i++)if(id && venus.ctx[i]==id)return i;return -1; }
static struct blob *find(uint32_t id)
{ for(unsigned i=0;i<NRES;i++)if(id && venus.blobs[i].id==id)return &venus.blobs[i];return NULL; }
bool gpu3d_resource(uint32_t id) { return find(id)!=NULL; }
bool gpu3d_init(void)
{
    if(venus.ready)return true;
    int r=virgl_renderer_init(&venus,VIRGL_RENDERER_VENUS|VIRGL_RENDERER_NO_VIRGL|
        VIRGL_RENDERER_THREAD_SYNC|VIRGL_RENDERER_ASYNC_FENCE_CB,&callbacks);
    if(r){LOGE("Venus init failed (%d), using 2D GPU\n",r);return false;}
    virgl_renderer_get_cap_set(4,&venus.capversion,&venus.capsize);
    if(!venus.capsize || venus.capsize>GPU3D_REPLY_MAX-24){virgl_renderer_cleanup(&venus);return false;}
    venus.ready=true;return true;
}
static void unmap(struct blob *b)
{
    if(b->mapped) {
        hv_return_t r=hv_vm_unmap(GPU3D_SHM_BASE+b->offset,b->size);
        if(r!=HV_SUCCESS){LOGE("Venus unmap failed: 0x%x\n",r);exit(1);}
        b->mapped=false;
    }
}
void gpu3d_cleanup(void)
{
    if(!venus.ready)return;
    for(unsigned i=0;i<NRES;i++)unmap(&venus.blobs[i]);
    /* Stop rings/contexts before releasing any guest backing or blob pointer. */
    virgl_renderer_cleanup(&venus);
    for(unsigned i=0;i<NRES;i++)free(venus.blobs[i].iov);
    memset(&venus,0,sizeof venus);
}
void gpu3d_reset(void) { gpu3d_cleanup();gpu3d_init(); }
/* Renderer completion is awaited separately from g.lock. One request at a time;
 * asynchronous ring work can still progress on renderer threads. */
static bool wait_fence(uint32_t ctx,uint32_t ring)
{
    pthread_mutex_lock(&fence_lock);
    uint64_t token=++next_fence;
    pthread_mutex_unlock(&fence_lock);
    if(virgl_renderer_context_create_fence(ctx,0,ring,token))return false;
    struct timespec deadline;clock_gettime(CLOCK_REALTIME,&deadline);deadline.tv_sec+=5;
    pthread_mutex_lock(&fence_lock);
    int r=0;
    while(done_fence!=token && !r)r=pthread_cond_timedwait(&fence_cv,&fence_lock,&deadline);
    bool done=done_fence==token;
    pthread_mutex_unlock(&fence_lock);
    return done;
}
bool gpu3d_mmio(uint64_t off,bool wr,uint32_t *val)
{
    if(off<0xac || off>0xbc || (off&3))return false;
    if(wr){if(off!=0xac)return false;venus.shmsel=*val;return true;}
    uint64_t size=venus.ready && venus.shmsel==1?GPU3D_SHM_SIZE:UINT64_MAX;
    switch(off){
    case 0xac:*val=venus.shmsel;break;
    case 0xb0:*val=(uint32_t)size;break;case 0xb4:*val=size>>32;break;
    case 0xb8:*val=venus.ready && venus.shmsel==1?(uint32_t)GPU3D_SHM_BASE:0;break;
    case 0xbc:*val=venus.ready && venus.shmsel==1?GPU3D_SHM_BASE>>32:0;break;
    }
    return true;
}
bool gpu3d_command(const uint8_t *p,size_t len,uint8_t *out,size_t cap,size_t *n)
{
    uint32_t type=vio32(p),ctx=vio32(p+16),flags=vio32(p+4),result=OK;
    bool is3d=(type>=0x200 && type<=0x207) || type==0x108 || type==0x109 || type==0x10c || type==0x208 || type==0x209;
    struct blob *b=len>=32?find(vio32(p+24)):NULL;
    if(type==0x102 && b)is3d=true;
    if(!is3d || !venus.ready)return false;
    int ci=context(ctx);
    if(flags&~3u || ((flags&2) && (!(flags&1) || p[20]>=64))){result=INVALID;goto end;}
    switch(type) {
    case 0x108: /* GET_CAPSET_INFO */
        if(len!=32 || vio32(p+24) || cap<40){result=INVALID;break;}
        memset(out+24,0,16);vio_put32(out+24,4);vio_put32(out+28,venus.capversion);vio_put32(out+32,venus.capsize);
        result=0x1102;*n=40;break;
    case 0x109: /* GET_CAPSET */
        if(len!=32 || vio32(p+24)!=4 || vio32(p+28)!=venus.capversion || cap<24+venus.capsize){result=INVALID;break;}
        virgl_renderer_fill_caps(4,venus.capversion,out+24);result=0x1103;*n=24+venus.capsize;break;
    case 0x200: /* CTX_CREATE: context_init contains the capset id, not ring count */
        if(len!=96 || !ctx || ci>=0 || vio32(p+24)>64 || vio32(p+28)!=4){result=INVALID;break;}
        for(ci=0;ci<NCTX && venus.ctx[ci];ci++);
        if(ci==NCTX){result=0x1201;break;}
        if(virgl_renderer_context_create_with_flags(ctx,4,vio32(p+24),(const char *)p+32))result=0x1200;
        else venus.ctx[ci]=ctx;
        break;
    case 0x201: /* CTX_DESTROY: resources must be released first */
        if(len!=24 || ci<0){result=BAD_CONTEXT;break;}
        for(unsigned i=0;i<NRES;i++)if(venus.blobs[i].id && venus.blobs[i].owner==ctx){result=INVALID;break;}
        if(result!=OK)break;
        virgl_renderer_context_destroy(ctx);venus.ctx[ci]=0;
        for(unsigned i=0;i<NRES;i++)venus.blobs[i].attached&=~(1u<<ci);
        break;
    case 0x202:case 0x203:
        if(len!=32 || ci<0){result=BAD_CONTEXT;break;}
        if(!b){result=BAD_RESOURCE;break;}
        if(b->mem==2 && b->owner!=ctx){result=INVALID;break;}
        if(type==0x202) {
            if(!(b->attached&(1u<<ci))){virgl_renderer_ctx_attach_resource(ctx,b->id);b->attached|=1u<<ci;}
        } else if(b->attached&(1u<<ci)) {
            if(b->owner==ctx){result=INVALID;break;}
            virgl_renderer_ctx_detach_resource(ctx,b->id);b->attached&=~(1u<<ci);
        }
        break;
    case 0x207: /* SUBMIT_3D uses dwords in the renderer API */
        if(len<32 || ci<0){result=BAD_CONTEXT;break;}
        if(vio32(p+24)!=len-32 || ((len-32)&3)){result=INVALID;break;}
        int submit_result=virgl_renderer_submit_cmd((void *)(p+32),ctx,(int)((len-32)/4));
        if(submit_result){LOGE("Venus submit ctx=%u bytes=%zu failed: %d\n",ctx,len-32,submit_result);result=0x1200;}
        if(result==OK && (flags&1) && !wait_fence(ctx,flags&2?p[20]:0))result=0x1200;
        break;
    case 0x10c: { /* RESOURCE_CREATE_BLOB */
        if(len<56 || !vio32(p+24) || b){result=INVALID;break;}
        uint32_t mem=vio32(p+28),bf=vio32(p+32),niov=vio32(p+36);
        uint64_t bytes=vio64(p+48);
        if(!bytes || bytes>GPU3D_SHM_SIZE || (bytes&0x3fff) || bf!=1 ||
           (mem!=1 && mem!=2) || niov>1024 || len!=56+16ULL*niov ||
           (mem==2 && (ci<0 || niov)) || (mem==1 && ((ctx && ci<0) || !niov || vio64(p+40)))){result=INVALID;break;}
        for(unsigned i=0;i<NRES;i++)if(!venus.blobs[i].id){b=&venus.blobs[i];break;}
        if(!b){result=0x1201;break;}
        uint64_t total=0;
        for(unsigned i=0;i<NRES;i++)total+=venus.blobs[i].size;
        if(bytes>GPU3D_SHM_SIZE-total){result=0x1201;break;}
        struct iovec *iov=niov?calloc(niov,sizeof *iov):NULL;
        if(niov && !iov){result=0x1201;break;}
        uint64_t backing=0;
        for(uint32_t i=0;i<niov;i++) {
            uint32_t sz=vio32(p+64+16*i);void *ptr=virtio_guest(vio64(p+56+16*i),sz);
            if(!ptr || !sz || sz>bytes-backing){result=INVALID;break;}
            iov[i]=(struct iovec){ptr,sz};backing+=sz;
        }
        if(mem==1 && backing!=bytes)result=INVALID;
        if(result!=OK){free(iov);break;}
        struct virgl_renderer_resource_create_blob_args args={.res_handle=vio32(p+24),.ctx_id=ctx,
            .blob_mem=mem,.blob_flags=bf,.blob_id=vio64(p+40),.size=bytes,.iovecs=iov,.num_iovs=niov};
        if(virgl_renderer_resource_create_blob(&args)){free(iov);result=0x1200;break;}
        if(mem==1 && ci>=0)virgl_renderer_ctx_attach_resource(ctx,args.res_handle);
        *b=(struct blob){.id=args.res_handle,.owner=ctx,.mem=mem,.flags=bf,.size=bytes,.iov=iov,.attached=ci<0?0:1u<<ci};
        break;
    }
    case 0x208: { /* RESOURCE_MAP_BLOB */
        if(len!=40 || !b || b->mem!=2){result=BAD_RESOURCE;break;}
        uint64_t offset=vio64(p+32),ptr=0;uint32_t info=0;
        if(b->mapped || (offset&0x3fff) || offset>GPU3D_SHM_SIZE-b->size || cap<32){result=INVALID;break;}
        for(unsigned i=0;i<NRES;i++) {
            struct blob *other=&venus.blobs[i];
            if(other->mapped && offset<other->offset+other->size && other->offset<offset+b->size){result=INVALID;break;}
        }
        if(result!=OK)break;
        if(virgl_renderer_resource_get_map_ptr(b->id,&ptr) || !ptr || (ptr&0x3fff) ||
           virgl_renderer_resource_get_map_info(b->id,&info) ||
           hv_vm_map((void *)(uintptr_t)ptr,GPU3D_SHM_BASE+offset,b->size,HV_MEMORY_READ|HV_MEMORY_WRITE)!=HV_SUCCESS){result=0x1200;break;}
        b->mapped=true;b->offset=offset;b->ptr=(void *)(uintptr_t)ptr;
        vio_put32(out+24,info&VIRGL_RENDERER_MAP_CACHE_MASK);vio_put32(out+28,0);*n=32;result=0x1106;break;
    }
    case 0x209:
        if(len!=32 || !b){result=BAD_RESOURCE;break;}
        if(!b->mapped){result=INVALID;break;}unmap(b);break;
    case 0x102:
        if(len!=32){result=INVALID;break;}
        unmap(b);virgl_renderer_resource_unref(b->id);free(b->iov);memset(b,0,sizeof *b);break;
    default:result=0x1200;break;
    }
end:
    if(result>=0x1200)*n=24;
    /* Synchronous host submission fence; never claim a fence for a failed submit. */
    if(type==0x207 && result>=0x1200)vio_put32(out+4,0);
    else {vio_put32(out+4,flags&3);vio_put32(out+16,flags&1?ctx:0);out[20]=flags&2?p[20]:0;}
    vio_put32(out,result);return true;
}
#endif
