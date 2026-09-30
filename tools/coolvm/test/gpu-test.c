/* Real MMIO/split queues, scatter backing, fences, crop/panning, cursor and
 * config IRQs. The expected pixels are independent of the device implementation. */
#include "../src/virtio.h"
#include <assert.h>
struct vm g;
void aic_update_locked(void) {}
void fb_frame_dump(void) {}
static void wr(uint64_t off,uint32_t v){uint64_t x=v;assert(gpu_mmio(off,4,true,&x));}
static uint32_t rd(uint64_t off){uint64_t x=0;assert(gpu_mmio(off,4,false,&x));return x;}
static uint8_t *mem(unsigned off){return g.ram+off;}
static void desc(unsigned q,unsigned id,unsigned off,unsigned len,unsigned flags,unsigned next)
{
    uint8_t *d=mem(0x1000+q*0x1000+id*16);
    uint64_t addr=DRAM_BASE+off;memcpy(d,&addr,8);vio_put32(d+8,len);vio_put16(d+12,flags);vio_put16(d+14,next);
}
static uint8_t *send(unsigned q,uint32_t type,unsigned len)
{
    static uint16_t idx[2];
    vio_put32(mem(0x4000),type);vio_put32(mem(0x4004),1);
    uint64_t fence=0x123456789abcdef0ULL;memcpy(mem(0x4008),&fence,8);
    memset(mem(0x5000),0xff,512);
    desc(q,0,0x4000,len,1,1);desc(q,1,0x5000,512,2,0);
    uint8_t *avail=mem(0x1200+q*0x1000);
    vio_put16(avail+4+2*(idx[q]%8),0);vio_put16(avail+2,++idx[q]);wr(0x50,q);
    assert(vio16(mem(0x1302+q*0x1000))==idx[q]);
    assert(vio64(mem(0x5008))==fence);
    assert(vio32(mem(0x5004))==1 || (type==0x207 && vio32(mem(0x5000))>=0x1200 && vio32(mem(0x5004))==0));
    return mem(0x5000);
}
static void initq(unsigned q)
{
    wr(0x30,q);wr(0x38,8);
    wr(0x80,0x1000+q*0x1000);wr(0x84,DRAM_BASE>>32);
    wr(0x90,0x1200+q*0x1000);wr(0x94,DRAM_BASE>>32);
    wr(0xa0,0x1300+q*0x1000);wr(0xa4,DRAM_BASE>>32);wr(0x44,1);
}
static void start(void){memset(mem(0x4000),0,512);}
static void put(unsigned off,uint32_t x){vio_put32(mem(0x4000+off),x);}
static void create(unsigned id,unsigned w,unsigned h,unsigned format)
{start();put(24,id);put(28,format);put(32,w);put(36,h);assert(vio32(send(0,0x101,40))==0x1100);}
static void attach(unsigned id,unsigned off,unsigned bytes)
{start();put(24,id);put(28,2);uint64_t addr=DRAM_BASE+off;memcpy(mem(0x4020),&addr,8);put(40,bytes/2);addr+=bytes/2;memcpy(mem(0x4030),&addr,8);put(56,bytes-bytes/2);assert(vio32(send(0,0x106,64))==0x1100);}
static void region(unsigned type,unsigned id,unsigned x,unsigned y,unsigned w,unsigned h,uint64_t offset)
{start();put(24,x);put(28,y);put(32,w);put(36,h);if(type==0x105){memcpy(mem(0x4028),&offset,8);put(48,id);}else put(type==0x103?44:40,id);assert(vio32(send(0,type,type==0x105?56:48))==0x1100);}
static void pixels(unsigned w,unsigned h,unsigned off)
{for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++)vio_put32(mem(off+(y*w+x)*4),0xff000000|(y<<16)|(x<<8)|y+x);}
int main(void)
{
    g.gpu=true;g.fb_width=8;g.fb_height=32;g.ram_size=1<<20;g.ram=calloc(1,g.ram_size);pthread_mutex_init(&g.lock,NULL);gpu_init();
    assert(rd(8)==16 && rd(4)==2);wr(0x70,3);wr(0x24,1);wr(0x20,1);wr(0x70,11);assert(rd(0x70)==11);initq(0);initq(1);wr(0x70,15);
    start();uint8_t *reply=send(0,0x100,24);assert(vio32(reply)==0x1101 && vio32(reply+32)==8 && vio32(reply+36)==32 && vio32(reply+40)==1);
    create(1,8,64,2);pixels(8,64,0x10000);attach(1,0x10000,8*64*4);
    region(0x103,1,0,16,8,32,0);region(0x105,1,0,0,8,64,0);region(0x104,1,0,0,8,64,0);
    uint8_t *image;uint32_t w,h;assert(gpu_snapshot(&image,&w,&h) && w==8 && h==32);
    assert(!memcmp(image,mem(0x10000+16*8*4),8*32*4));free(image);
    region(0x103,1,0,31,8,32,0);assert(gpu_snapshot(&image,&w,&h));assert(!memcmp(image,mem(0x10000+31*8*4),8*32*4));free(image);
    /* One opaque red cursor pixel; the rest are transparent. */
    create(2,64,64,1);vio_put32(mem(0x20000),0xffff0000);attach(2,0x20000,64*64*4);region(0x105,2,0,0,64,64,0);
    start();put(28,3);put(32,4);put(40,2);assert(vio32(send(1,0x300,56))==0x1100);
    assert(gpu_snapshot(&image,&w,&h));assert(vio32(image+(4*w+3)*4)==0xff0000);free(image);
    start();put(28,2);put(32,5);assert(vio32(send(1,0x301,56))==0x1100);
    assert(gpu_snapshot(&image,&w,&h));assert(vio32(image+(5*w+2)*4)==0xff0000);free(image);
    start();assert(vio32(send(1,0x300,56))==0x1100); /* hide */
    start();put(24,99);assert(vio32(send(0,0x102,32))==0x1203);
    start();put(24,0);put(28,63);put(32,8);put(36,32);put(44,1);assert(vio32(send(0,0x103,48))==0x1205);
    gpu_resize(96,80);assert(rd(0x100)==1 && (rd(0x60)&2) && rd(0xfc)==1);wr(0x104,1);wr(0x64,3);assert(rd(0x100)==0 && rd(0x60)==0);
    start();reply=send(0,0x100,24);assert(vio32(reply+32)==96 && vio32(reply+36)==80);
    for(unsigned i=0;i<40;i++){start();assert(vio32(send(0,0x100,24))==0x1101);} /* ring wrap */
    wr(0x70,0);assert(rd(0x70)==0);free(g.ram);puts("gpu-test: queues, backing, fences, panning, cursor, display events PASS");return 0;
}
