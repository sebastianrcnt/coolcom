/* Virtio 1.2 section 5.7: synchronous unaccelerated 2D, one scanout, two
 * split queues. All device state (including presentation) is under g.lock. */
#include "virtio.h"
#define GPU_RESOURCES 64
#define GPU_BYTES (256ULL << 20)
#define GPU_TOTAL (512ULL << 20)
struct gpu_resource {
    uint32_t id, w, h, format, nback;
    uint8_t *pixels;
    struct { uint64_t addr; uint32_t len; } *back;
    uint64_t bytes, backing;
};
static struct {
    struct virtio_mmio v;
    struct gpu_resource res[GPU_RESOURCES];
    uint32_t events, width, height, scan_id, sx, sy, sw, sh;
    uint32_t cursor[64*64], cx, cy, hx, hy;
    bool cursor_on, active;
    uint64_t bytes;
} gpu;
static struct gpu_resource *resource(uint32_t id)
{
    for(unsigned i=0;i<GPU_RESOURCES;i++) if(id && gpu.res[i].id==id)return &gpu.res[i];
    return NULL;
}
static bool rect(struct gpu_resource *r, uint32_t x,uint32_t y,uint32_t w,uint32_t h)
{ return r && w && h && x<r->w && y<r->h && w<=r->w-x && h<=r->h-y; }
static void discard(struct gpu_resource *r)
{ gpu.bytes-=r->bytes; free(r->pixels);free(r->back);memset(r,0,sizeof *r); }
static void damage(void)
{ atomic_store(&g.fb_damage_used,true);atomic_store(&g.fb_damage,1); }
/* Copy from a guest scatter list without requiring physically contiguous backing. */
static bool backing_read(struct gpu_resource *r,uint64_t off,uint8_t *dst,size_t len)
{
    if(off>r->backing || len>r->backing-off)return false;
    for(uint32_t i=0;i<r->nback && len;i++) {
        if(off>=r->back[i].len){off-=r->back[i].len;continue;}
        size_t n=r->back[i].len-off;if(n>len)n=len;
        uint8_t *src=virtio_guest(r->back[i].addr,r->back[i].len);
        if(!src)return false;
        memcpy(dst,src+off,n);dst+=n;len-=n;off=0;
    }
    return len==0;
}
/* Response headers always carry the request fence, after processing finishes. */
static size_t command(unsigned queue,const uint8_t *p,size_t len,uint8_t *out,size_t cap)
{
    uint32_t type=vio32(p), result=0x1100;
    size_t n=24;
    memcpy(out,p,24);memset(out+16,0,8);vio_put32(out+4,vio32(p+4)&1);
    if(queue==1) {
        if((type!=0x300 && type!=0x301) || len<56 || vio32(p+24))result=0x1205;
        else {
            struct gpu_resource *r=resource(vio32(p+40));
            if(type==0x300 && vio32(p+40) && (!r || r->w!=64 || r->h!=64 || vio32(p+44)>=64 || vio32(p+48)>=64))result=0x1205;
            else {
                gpu.cx=vio32(p+28);gpu.cy=vio32(p+32);
                if(type==0x300) {
                    gpu.cursor_on=r!=NULL;gpu.hx=vio32(p+44);gpu.hy=vio32(p+48);
                    if(r) {
                        memcpy(gpu.cursor,r->pixels,sizeof gpu.cursor);
                        if(r->format==2)for(unsigned i=0;i<64*64;i++)gpu.cursor[i]|=0xff000000;
                    }
                }
                damage();
            }
        }
    } else if(type==0x100) {
        n=24+16*24;
        if(cap<n){result=0x1205;n=24;}
        else {memset(out+24,0,n-24);vio_put32(out+32,gpu.width);vio_put32(out+36,gpu.height);vio_put32(out+40,1);result=0x1101;}
    } else if(type==0x101) {
        if(len<40)result=0x1205;
        else {
            uint32_t id=vio32(p+24), format=vio32(p+28), w=vio32(p+32), h=vio32(p+36);
            uint64_t bytes=(uint64_t)w*h*4;
            if(!id || resource(id) || (format!=1 && format!=2) || !w || !h || w>8192 || h>16384 || bytes>GPU_BYTES)result=0x1205;
            else if(bytes>GPU_TOTAL-gpu.bytes)result=0x1201;
            else {
                struct gpu_resource *r=NULL;
                for(unsigned i=0;i<GPU_RESOURCES;i++)if(!gpu.res[i].id){r=&gpu.res[i];break;}
                if(!r || !(r->pixels=calloc(1,bytes)))result=0x1201;
                else {r->id=id;r->w=w;r->h=h;r->format=format;r->bytes=bytes;gpu.bytes+=bytes;}
            }
        }
    } else if(type==0x102 || type==0x107) {
        struct gpu_resource *r=len>=32?resource(vio32(p+24)):NULL;
        if(!r)result=0x1203;
        else if(type==0x102) {if(gpu.scan_id==r->id){gpu.scan_id=0;gpu.active=true;damage();}discard(r);}
        else {free(r->back);r->back=NULL;r->nback=0;r->backing=0;}
    } else if(type==0x106) {
        struct gpu_resource *r=len>=32?resource(vio32(p+24)):NULL;
        uint32_t entries=len>=32?vio32(p+28):0;
        if(!r)result=0x1203;
        else if(!entries || entries>1024 || len<32+16ULL*entries || r->back)result=0x1205;
        else {
            r->back=calloc(entries,sizeof *r->back);
            if(!r->back)result=0x1201;
            else {
                r->nback=entries;
                for(uint32_t i=0;i<entries;i++) {
                    uint64_t addr=vio64(p+32+16*i);uint32_t bytes=vio32(p+40+16*i);
                    if(!bytes || !virtio_guest(addr,bytes)){result=0x1205;break;}
                    r->back[i].addr=addr;r->back[i].len=bytes;r->backing+=bytes;
                }
                if(result!=0x1100){free(r->back);r->back=NULL;r->nback=0;r->backing=0;}
            }
        }
    } else if(type==0x103 || type==0x104 || type==0x105) {
        size_t needed=type==0x105?56:48;
        if(len<needed)result=0x1205;
        else {
            uint32_t x=vio32(p+24),y=vio32(p+28),w=vio32(p+32),h=vio32(p+36);
            uint32_t id=vio32(p+(type==0x103?44:type==0x105?48:40));
            struct gpu_resource *r=resource(id);
            if(type==0x103 && vio32(p+40))result=0x1202;
            else if(type==0x103 && !id){gpu.scan_id=0;gpu.active=true;damage();}
            else if(!r)result=0x1203;
            else if(!rect(r,x,y,w,h))result=0x1205;
            else if(type==0x103){gpu.active=true;gpu.scan_id=id;gpu.sx=x;gpu.sy=y;gpu.sw=w;gpu.sh=h;damage();}
            else if(type==0x104){if(gpu.scan_id==id){damage();fb_frame_dump();}}
            else {
                uint64_t offset=vio64(p+40),stride=(uint64_t)r->w*4;
                if(!r->back || offset>r->backing || (uint64_t)(h-1)*stride+(uint64_t)w*4>r->backing-offset)result=0x1205;
                else for(uint32_t row=0;row<h;row++)
                    if(!backing_read(r,offset+row*stride,r->pixels+((uint64_t)(y+row)*r->w+x)*4,w*4)){result=0x1205;break;}
            }
        }
    } else result=0x1200;
    vio_put32(out,result);return n;
}
static void process(unsigned queue)
{
    struct vq *q=&gpu.v.q[queue];
    if(!(gpu.v.status&4) || !(gpu.v.status&8) || !q->ready || !q->num)return;
    uint8_t *avail=virtio_guest(q->avail,6+2ULL*q->num);
    if(!avail || !virtio_guest(q->used,6+8ULL*q->num))return;
    atomic_thread_fence(memory_order_acquire);
    uint16_t end=vio16(avail+2);
    if((uint16_t)(end-q->last_avail)>q->num)return;
    while(q->last_avail!=end) {
        uint16_t head=vio16(avail+4+2*(q->last_avail%q->num)),id=head;
        uint8_t req[32+1024*16],reply[24+16*24];
        struct {uint8_t *p;uint32_t len;} writable[256];
        size_t nr=0,capacity=0;unsigned nw=0,steps=0;bool valid=true,done=false;
        do {
            uint64_t addr;uint32_t len;uint16_t flags,next;
            if(++steps>q->num || !virtio_desc(q,id,&addr,&len,&flags,&next)){valid=false;break;}
            uint8_t *ptr=virtio_guest(addr,len);if(!ptr){valid=false;break;}
            if(flags&2){writable[nw++]=(typeof(writable[0])){ptr,len};capacity+=len;}
            else if(nw || len>sizeof req-nr){valid=false;break;}
            else {memcpy(req+nr,ptr,len);nr+=len;}
            if(!(flags&1)){done=true;break;}id=next;
        } while(valid);
        uint32_t written=0;
        if(valid && done && nr>=24 && capacity>=24) {
            size_t n=command(queue,req,nr,reply,capacity),off=0;
            for(unsigned i=0;i<nw && off<n;i++){size_t bytes=writable[i].len;if(bytes>n-off)bytes=n-off;memcpy(writable[i].p,reply+off,bytes);off+=bytes;}
            written=(uint32_t)off;
        } else LOGE("gpu: malformed chain %u\n",head);
        virtio_used(q,head,written);q->last_avail++;
        if(!(vio16(avail)&1))gpu.v.isr|=1;
    }
    aic_update_locked();
}
void gpu_init(void) {gpu.width=g.fb_width;gpu.height=g.fb_height;}
bool gpu_irq_level(void){return g.gpu && gpu.v.isr!=0;}
bool gpu_mmio(uint64_t off,int size,bool wr,uint64_t *val)
{
    if(size!=4)return false;
    uint32_t x=(uint32_t)*val;
    if(off>=0x100) {
        if(wr){if(off!=0x104)return false;gpu.events&=~x;}
        else {switch(off){case 0x100:x=gpu.events;break;case 0x104:x=0;break;case 0x108:x=1;break;case 0x10c:x=0;break;default:return false;}*val=x;}
        return true;
    }
    if(wr && off==0x50){if(x>=2)return false;process(x);return true;}
    if(wr && off==0x70 && x==0) {
        for(unsigned i=0;i<GPU_RESOURCES;i++)discard(&gpu.res[i]);
        memset(&gpu.v,0,sizeof gpu.v);gpu.scan_id=0;gpu.cursor_on=false;gpu.active=false;
    } else if(!virtio_regs(&gpu.v,16,off,wr,&x))return false;
    if(!wr)*val=x;aic_update_locked();return true;
}
void gpu_resize(uint32_t width,uint32_t height)
{
    if(!g.gpu || width<8 || height<32 || width>8192 || height>8192 || (uint64_t)width*height*8>GPU_BYTES)return;
    pthread_mutex_lock(&g.lock);
    if(width!=gpu.width || height!=gpu.height){gpu.width=width;gpu.height=height;gpu.events|=1;gpu.v.generation++;gpu.v.isr|=2;aic_update_locked();}
    pthread_mutex_unlock(&g.lock);
}
/* Copy the visible resource crop and ARGB hardware cursor, atomically relative
 * to queue processing. Caller holds g.lock. */
bool gpu_snapshot(uint8_t **pixels,uint32_t *width,uint32_t *height)
{
    if(!gpu.active)return false;
    struct gpu_resource *r=resource(gpu.scan_id);
    uint32_t w=r?gpu.sw:gpu.width,h=r?gpu.sh:gpu.height;
    uint8_t *dst=calloc((size_t)w*h,4);if(!dst)return false;
    if(r)for(uint32_t y=0;y<h;y++)memcpy(dst+(size_t)y*w*4,r->pixels+((size_t)(gpu.sy+y)*r->w+gpu.sx)*4,w*4);
    if(gpu.cursor_on)for(int y=0;y<64;y++)for(int x=0;x<64;x++) {
        int64_t dx=(int64_t)gpu.cx-gpu.hx+x,dy=(int64_t)gpu.cy-gpu.hy+y;
        if(dx<0 || dy<0 || dx>=w || dy>=h)continue;
        uint32_t s=gpu.cursor[y*64+x],*d=(uint32_t *)dst+dy*w+dx,a=s>>24,out=0;
        for(int b=0;b<24;b+=8)out|=((((s>>b)&255)*a+((*d>>b)&255)*(255-a)+127)/255)<<b;
        *d=out;
    }
    *pixels=dst;*width=w;*height=h;return true;
}
