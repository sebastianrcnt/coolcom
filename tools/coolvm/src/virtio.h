/* Shared split-ring primitives used by blk, net and GPU. The model runs on
 * little-endian macOS ARM; memcpy permits unaligned guest structures. */
#ifndef COOLVM_VIRTIO_H
#define COOLVM_VIRTIO_H
#include "coolvm.h"
static inline uint16_t vio16(const void *p) { uint16_t v; memcpy(&v,p,2); return v; }
static inline uint32_t vio32(const void *p) { uint32_t v; memcpy(&v,p,4); return v; }
static inline uint64_t vio64(const void *p) { uint64_t v; memcpy(&v,p,8); return v; }
static inline void vio_put16(void *p,uint16_t v) { memcpy(p,&v,2); }
static inline void vio_put32(void *p,uint32_t v) { memcpy(p,&v,4); }
static inline void *virtio_guest(uint64_t pa, uint64_t len)
{
    if (pa < DRAM_BASE || len > g.ram_size || pa - DRAM_BASE > g.ram_size - len) return NULL;
    return g.ram + (pa - DRAM_BASE);
}
struct vq { uint32_t num, ready; uint64_t desc, avail, used; uint16_t last_avail, used_idx; };
static inline bool virtio_desc(struct vq *q, unsigned id, uint64_t *addr, uint32_t *len, uint16_t *flags, uint16_t *next)
{
    uint8_t *table = virtio_guest(q->desc, 16ULL * q->num);
    if (id >= q->num || !table) return false;
    uint8_t *p = table + 16 * id;
    *addr=vio64(p); *len=vio32(p+8); *flags=vio16(p+12); *next=vio16(p+14);
    return !(*flags & 4); /* INDIRECT is not offered */
}
static inline bool virtio_used(struct vq *q, uint16_t head, uint32_t len)
{
    uint8_t *used = virtio_guest(q->used, 6 + 8ULL * q->num);
    if (!used) return false;
    uint8_t *e = used + 4 + 8 * (q->used_idx % q->num);
    vio_put32(e, head); vio_put32(e+4, len);
    atomic_thread_fence(memory_order_release);
    vio_put16(used+2, ++q->used_idx);
    return true;
}
struct virtio_mmio { uint32_t status, devsel, drvsel, drvfeat[2], qsel, isr, generation; struct vq q[2]; };
/* Configuration and notify are device-specific; common modern MMIO registers. */
static inline bool virtio_regs(struct virtio_mmio *v, unsigned devid, uint64_t off, bool wr, uint32_t *val)
{
    uint32_t x=*val, r=0;
    struct vq *q=v->qsel < 2 ? &v->q[v->qsel] : NULL;
    if (wr) {
        switch(off) {
        case 0x14:v->devsel=x;break;case 0x24:v->drvsel=x;break;
        case 0x20:if(v->drvsel<2)v->drvfeat[v->drvsel]=x;break;
        case 0x30:v->qsel=x;break;
        case 0x38:if(!q || !x || x>256 || (x&(x-1)) || q->ready)return false;q->num=x;break;
        case 0x44:if(!q)return false;q->ready=x&1;break;
        case 0x64:v->isr&=~x;break;
        case 0x70:v->status=x;if((x&8) && (v->drvfeat[0] || v->drvfeat[1]!=1))v->status&=~8u;break;
        case 0x80:case 0x84:case 0x90:case 0x94:case 0xa0:case 0xa4: {
            if(!q || q->ready)return false;
            uint64_t *p=off<0x90?&q->desc:off<0xa0?&q->avail:&q->used;
            *p=(off&4)?(*p&0xffffffffULL)|((uint64_t)x<<32):(*p&0xffffffff00000000ULL)|x;
            break;
        }
        default:return false;
        }
    } else {
        switch(off) {
        case 0:r=0x74726976;break;case 4:r=2;break;case 8:r=devid;break;case 12:r=0x554d5643;break;
        case 0x10:r=v->devsel==1?1:0;break;
        case 0x20:r=v->drvsel<2?v->drvfeat[v->drvsel]:0;break;
        case 0x34:r=q?256:0;break;case 0x38:r=q?q->num:0;break;case 0x44:r=q?q->ready:0;break;
        case 0x60:r=v->isr;break;case 0x70:r=v->status;break;case 0xfc:r=v->generation;break;
        default:return false;
        }
        *val=r;
    }
    return true;
}
#endif
