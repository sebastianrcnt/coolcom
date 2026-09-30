/* Opt-in command-flow oracle, deliberately not a Vulkan renderer. Kept separate
 * from the 2D model so the real host 3D backend can replace its dispatch hook. */
static bool stub_flush(struct gpu_resource *r)
{
    if(r->mapped)memcpy(r->pixels,g.gpu_stub_memory+r->map_offset,r->bytes);
    else if(r->blob_mem==1)return backing_read(r,0,r->pixels,r->bytes);
    return true;
}
static bool stub_command(uint32_t type,const uint8_t *p,size_t len,
                         uint8_t *out,size_t cap,uint32_t *result,size_t *n)
{
    if(type!=0x108 && type!=0x109 && type!=0x10c && type!=0x10d &&
       type!=0x200 && type!=0x201 && type!=0x202 && type!=0x203 &&
       type!=0x207 && type!=0x208 && type!=0x209)return false;
    *result=0x1205;
    if((gpu.v.drvfeat[0]&0x19)!=0x19)return true;
    uint32_t ctx=vio32(p+16);
    struct gpu_resource *r=len>=32?resource(vio32(p+24)):NULL;
    switch(type) {
    case 0x108:
        if(len!=32 || vio32(p+24)!=0 || cap<40)break;
        memset(out+24,0,16);vio_put32(out+24,4);vio_put32(out+28,0);vio_put32(out+32,16);
        *result=0x1102;*n=40;break;
    case 0x109:
        if(len!=32 || vio32(p+24)!=4 || vio32(p+28)!=0 || cap<40)break;
        /* An opaque marker, never advertised as actual Venus capabilities. */
        memcpy(out+24,"COOLVM-3D-STUB!!",16);*result=0x1103;*n=40;break;
    case 0x200:
        if(len!=96 || !ctx || gpu.stub_ctx || vio32(p+24)>64 || vio32(p+28)!=4)break;
        gpu.stub_ctx=ctx;*result=0x1100;break;
    case 0x201:
        if(len!=24 || ctx!=gpu.stub_ctx || !ctx)break;
        gpu.stub_ctx=0;*result=0x1100;break;
    case 0x202:case 0x203:
        if(len!=32 || !ctx || ctx!=gpu.stub_ctx || !r || !r->blob_mem)break;
        r->attached=type==0x202;*result=0x1100;break;
    case 0x207:
        if(len<32 || !ctx || ctx!=gpu.stub_ctx || vio32(p+24)!=len-32 ||
           (vio32(p+24)&3) || (vio32(p+4)&3)!=3 || p[20]>=64)break;
        /* Fence signals consumption immediately; no command stream decoding. */
        /* Like QEMU, echo ctx/fence without INFO_RING_IDX in the response. */
        vio_put32(out+16,ctx);*result=0x1100;break;
    case 0x10c: {
        if(len<56 || !ctx || ctx!=gpu.stub_ctx)break;
        uint32_t id=vio32(p+24),mem=vio32(p+28),flags=vio32(p+32),entries=vio32(p+36);
        uint64_t bytes=vio64(p+48);
        if(!id || resource(id) || !bytes || bytes>GPU_BYTES || bytes>GPU_TOTAL-gpu.bytes ||
           (flags&~7u) || (mem!=1 && mem!=2) || entries!=(mem==1?1u:0u) || len!=56+16ULL*entries)break;
        uint64_t addr=entries?vio64(p+56):0;
        if(entries && (vio32(p+64)!=bytes || !virtio_guest(addr,bytes)))break;
        r=NULL;for(unsigned i=0;i<GPU_RESOURCES;i++)if(!gpu.res[i].id){r=&gpu.res[i];break;}
        if(!r || !(r->pixels=calloc(1,bytes))){*result=0x1201;break;}
        if(entries) {
            r->back=calloc(1,sizeof *r->back);
            if(!r->back){free(r->pixels);r->pixels=NULL;*result=0x1201;break;}
            r->nback=1;r->backing=bytes;r->back[0].addr=addr;r->back[0].len=bytes;
        }
        r->id=id;r->bytes=bytes;r->blob_mem=mem;r->blob_flags=flags;gpu.bytes+=bytes;
        *result=0x1100;break;
    }
    case 0x208: {
        if(len!=40 || !r || !r->blob_mem || r->mapped || !(r->blob_flags&1) ||
           !ctx || ctx!=gpu.stub_ctx || cap<32 || !g.gpu_stub_memory)break;
        uint64_t off=vio64(p+32),size=(r->bytes+16383)&~16383ULL;
        if((off&16383) || off>GPU_STUB_SIZE || size>GPU_STUB_SIZE-off)break;
        bool overlap=false;
        for(unsigned i=0;i<GPU_RESOURCES;i++) {
            struct gpu_resource *other=&gpu.res[i];
            uint64_t end=other->map_offset+((other->bytes+16383)&~16383ULL);
            if(other->mapped && off<end && other->map_offset<off+size)overlap=true;
        }
        if(overlap)break;
        if(!stub_flush(r))break;
        memcpy(g.gpu_stub_memory+off,r->pixels,r->bytes);r->mapped=true;r->map_offset=off;
        memset(out+24,0,8);vio_put32(out+24,2);*result=0x1106;*n=32;break;
    }
    case 0x209:
        if(len!=32 || !r || !r->mapped || !ctx || ctx!=gpu.stub_ctx)break;
        stub_flush(r);r->mapped=false;*result=0x1100;break;
    case 0x10d: {
        if(len!=96 || vio32(p+40))break;
        r=resource(vio32(p+44));
        uint32_t w=vio32(p+48),h=vio32(p+52),format=vio32(p+56),stride=vio32(p+64),offset=vio32(p+80);
        if(!r || !r->blob_mem || !w || !h || w>8192 || h>8192 || (format!=1 && format!=2) ||
           vio32(p+24) || vio32(p+28) || vio32(p+32)!=w || vio32(p+36)!=h ||
           stride!=w*4 || offset || (uint64_t)w*h*4>r->bytes)break;
        r->w=w;r->h=h;r->format=format;gpu.active=true;gpu.scan_id=r->id;
        gpu.sx=0;gpu.sy=0;gpu.sw=w;gpu.sh=h;damage();*result=0x1100;break;
    }
    }
    LOGE("gpu-3d-stub: cmd=%04x ctx=%u ring=%u fence=%llu result=%04x\n",
         type,ctx,p[20],(unsigned long long)vio64(p+8),*result);
    return true;
}
