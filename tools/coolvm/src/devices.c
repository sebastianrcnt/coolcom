#include "coolvm.h"
#include <errno.h>
#include <time.h>
#include <unistd.h>

/* Simple VM-only input FIFO. A record is three 32-bit words: type, code, value.
 * Types/codes use Linux EV_KEY, EV_REL, EV_SYN numbers. DATA pops one word;
 * STATUS gives the number of complete records, IRQ is level until drained. */
#define INPUT_CAP 256
static struct { uint32_t word[3]; } input_q[INPUT_CAP];
static unsigned input_head, input_tail, input_word;

bool input_irq_level(void) { return input_head != input_tail; }

void input_push(uint32_t type, uint32_t code, int32_t value)
{
    pthread_mutex_lock(&g.lock);
    unsigned next = (input_tail + 1) % INPUT_CAP;
    if (next != input_head) {
        input_q[input_tail].word[0] = type;
        input_q[input_tail].word[1] = code;
        input_q[input_tail].word[2] = (uint32_t)value;
        input_tail = next;
        aic_update_locked();
    }
    pthread_mutex_unlock(&g.lock);
}

/* Records after a "delay MS" line are pushed by a feeder thread, MS
 * milliseconds (cumulative) after the script is loaded, so a script can type at
 * a running program: "delay 2000" then Ctrl+Alt+C. A "wait TEXT" line holds
 * the records after it until the guest has written TEXT to the UART (after the
 * previous wait's match); later delays count from that moment. Host-time
 * delays alone race a slow guest: a Ctrl+Alt+C meant for a running statement
 * can arrive while the kernel is still booting. */
// Long modal-editor regressions share one boot; the guest FIFO stays bounded.
#define SCRIPT_LATE_CAP 16384
static struct { uint32_t type, code; int32_t value; unsigned ms; char *wait; } late_q[SCRIPT_LATE_CAP];
static unsigned late_n;

/* UART output matcher for "wait": the last bytes the guest wrote. */
static pthread_mutex_t wait_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wait_cond = PTHREAD_COND_INITIALIZER;
static char wait_win[256];
static size_t wait_len;
static const char *wait_text;
static bool wait_hit;

void input_uart_out(uint8_t ch)
{
    if (!late_n) return;
    pthread_mutex_lock(&wait_lock);
    if (wait_len == sizeof wait_win) {
        memmove(wait_win, wait_win + 1, sizeof wait_win - 1);
        wait_len--;
    }
    wait_win[wait_len++] = (char)ch;
    size_t n = wait_text ? strlen(wait_text) : 0;
    if (n && n <= wait_len && !memcmp(wait_win + wait_len - n, wait_text, n)) {
        wait_hit = true;
        wait_len = 0;
        pthread_cond_signal(&wait_cond);
    }
    pthread_mutex_unlock(&wait_lock);
}

static void *late_main(void *arg)
{
    unsigned now = 0;
    for (unsigned i = 0; i < late_n; i++) {
        if (late_q[i].wait) {
            pthread_mutex_lock(&wait_lock);
            wait_text = late_q[i].wait;
            /* The text may already be in the window. */
            size_t n = strlen(wait_text);
            for (size_t j = 0; j + n <= wait_len && !wait_hit; j++)
                if (!memcmp(wait_win + j, wait_text, n)) { wait_hit = true; wait_len = 0; }
            while (!wait_hit)
                pthread_cond_wait(&wait_cond, &wait_lock);
            wait_hit = false;
            wait_text = NULL;
            pthread_mutex_unlock(&wait_lock);
            now = late_q[i].ms;  /* later delays count from here */
            continue;
        }
        if (late_q[i].ms > now) {
            unsigned d = late_q[i].ms - now;
            struct timespec ts = {d / 1000, (long)(d % 1000) * 1000000L};
            nanosleep(&ts, NULL);
            now = late_q[i].ms;
        }
        input_push(late_q[i].type, late_q[i].code, late_q[i].value);
        nanosleep(&(struct timespec){0, 200000}, NULL); /* pace them: the guest FIFO holds 255 */
    }
    return NULL;
}

bool input_load_script(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return false; }
    char line[256];
    int n = 0, lineno = 0;
    unsigned delay = 0;
    bool waited = false;
    while (fgets(line, sizeof line, f)) {
        unsigned type, code, ms; int value;
        lineno++;
        if (line[0] == '#' || line[0] == '\n') continue;
        if (sscanf(line, "delay %u", &ms) == 1) {
            delay += ms;
            continue;
        }
        if (!strncmp(line, "wait ", 5)) {
            line[strcspn(line, "\r\n")] = 0;
            if (late_n >= SCRIPT_LATE_CAP || !line[5] || strlen(line + 5) >= sizeof wait_win) {
                LOGE("invalid input script wait at line %d\n", lineno);
                fclose(f); return false;
            }
            late_q[late_n].wait = strdup(line + 5);
            late_q[late_n++].ms = delay;
            waited = true;
            continue;
        }
        if (sscanf(line, "%u %u %d", &type, &code, &value) != 3 || type > 0x1f || code > 0xffff) {
            LOGE("invalid input script line %d\n", lineno);
            fclose(f); return false;
        }
        if (delay || waited) {
            if (late_n >= SCRIPT_LATE_CAP) {
                LOGE("input script exceeds %d delayed records\n", SCRIPT_LATE_CAP);
                fclose(f); return false;
            }
            late_q[late_n].type = type;
            late_q[late_n].code = code;
            late_q[late_n].value = value;
            late_q[late_n++].ms = delay;
            continue;
        }
        if (n >= INPUT_CAP - 1) {
            LOGE("input script exceeds %d records\n", INPUT_CAP - 1);
            fclose(f); return false;
        }
        input_push(type, code, value);
        n++;
    }
    bool ok = !ferror(f);
    fclose(f);
    if (ok && late_n) {
        pthread_t th;
        ok = pthread_create(&th, NULL, late_main, NULL) == 0;
        if (ok) pthread_detach(th);
    }
    return ok;
}

bool input_mmio(uint64_t off, int size, bool wr, uint64_t *val)
{
    if (size != 4 || wr) return false;
    if (off == 0) { *val = (input_tail + INPUT_CAP - input_head) % INPUT_CAP; return true; }
    if (off == 4) {
        if (input_head == input_tail) { *val = 0; return true; }
        *val = input_q[input_head].word[input_word++];
        if (input_word == 3) { input_word = 0; input_head = (input_head + 1) % INPUT_CAP; aic_update_locked(); }
        return true;
    }
    return false;
}

/* virtio-mmio v2, one virtqueue per block device. Descriptor chains consist
 * of an out header, data descriptors, and a writable status byte. */
#define VIRTIO_MAGIC 0x74726976u
#define VIRTIO_VERSION 2
#define VIRTIO_BLK 2
#define VIRTIO_F_VERSION_1 (1u << 0) /* feature word 1, bit 32 */
#define VIRTIO_BLK_F_FLUSH (1u << 9)
#define VRING_DESC_F_NEXT 1
#define VRING_DESC_F_WRITE 2

struct blk_state {
    uint32_t status, devsel, drvsel, driver_features[2], qsel, qnum, qready, isr;
    uint64_t desc, avail, used;
    uint16_t last_avail, used_idx;
};
static struct blk_state bs[MAX_DISKS];

static void *guest_ptr(uint64_t pa, uint64_t len)
{
    if (pa < DRAM_BASE || len > g.ram_size || pa - DRAM_BASE > g.ram_size - len) return NULL;
    return g.ram + (pa - DRAM_BASE);
}
static uint16_t ld16(const void *p) { uint16_t v; memcpy(&v,p,2); return v; }
static uint32_t ld32(const void *p) { uint32_t v; memcpy(&v,p,4); return v; }
static uint64_t ld64(const void *p) { uint64_t v; memcpy(&v,p,8); return v; }
static void st16(void *p,uint16_t v) { memcpy(p,&v,2); }
static void st32(void *p,uint32_t v) { memcpy(p,&v,4); }

static bool descriptor(struct blk_state *b, unsigned id, uint64_t *addr, uint32_t *len, uint16_t *flags, uint16_t *next)
{
    if (id >= b->qnum) return false;
    uint8_t *p = guest_ptr(b->desc + 16ULL * id, 16);
    if (!p) return false;
    *addr=ld64(p); *len=ld32(p+8); *flags=ld16(p+12); *next=ld16(p+14);
    return !(*flags & 4); /* indirect descriptors not negotiated */
}

static bool process_chain(int disk, uint16_t head, uint32_t *used_len)
{
    struct blk_state *b=&bs[disk];
    uint64_t addr; uint32_t len; uint16_t flags,next;
    if (!descriptor(b,head,&addr,&len,&flags,&next) || len < 16 || !(flags & VRING_DESC_F_NEXT) || (flags & VRING_DESC_F_WRITE)) return false;
    uint8_t *hdr=guest_ptr(addr,16);
    if (!hdr) return false;
    uint32_t type=ld32(hdr);
    uint64_t sector=ld64(hdr+8);
    uint64_t offset=sector*512ULL;
    bool valid=sector <= UINT64_MAX/512 && offset <= g.disk_size[disk];
    unsigned id=next, steps=0;
    *used_len=0;
    while (++steps <= b->qnum && descriptor(b,id,&addr,&len,&flags,&next)) {
        uint8_t *data=guest_ptr(addr,len);
        if (!data) return false;
        if (!(flags & VRING_DESC_F_NEXT)) {
            if (len < 1 || !(flags & VRING_DESC_F_WRITE)) return false;
            uint8_t result=valid ? 0 : 1;
            if (type == 4 && valid) result=fsync(g.disk_fd[disk]) == 0 ? 0 : 1;
            else if (type != 0 && type != 1) result=2;
            *data=result;
            *used_len += 1;
            return true;
        }
        if (type == 4 || (type == 0 && !(flags & VRING_DESC_F_WRITE)) || (type == 1 && (flags & VRING_DESC_F_WRITE))) valid=false;
        if (len > g.disk_size[disk] - (valid ? offset : 0) || !valid) valid=false;
        if (valid) {
            ssize_t n = type == 0 ? pread(g.disk_fd[disk],data,len,(off_t)offset) : pwrite(g.disk_fd[disk],data,len,(off_t)offset);
            if (n != (ssize_t)len) valid=false;
            if (type == 0) *used_len += len;
            offset += len;
        }
        id=next;
    }
    return false;
}

static void process_queue(int disk)
{
    struct blk_state *b=&bs[disk];
    if (!b->qready || !b->qnum || !(b->status & 4)) return;
    uint8_t *avail=guest_ptr(b->avail,6+2*b->qnum);
    uint8_t *used=guest_ptr(b->used,6+8*b->qnum);
    if (!avail || !used) return;
    uint16_t end=ld16(avail+2);
    if ((uint16_t)(end-b->last_avail)>b->qnum) return;
    bool completed = false;
    while (b->last_avail != end) {
        uint16_t head=ld16(avail+4+2*(b->last_avail%b->qnum));
        uint32_t used_len=0;
        if (!process_chain(disk,head,&used_len)) { LOGE("disk%d: malformed descriptor chain %u\n",disk,head); break; }
        uint8_t *entry=used+4+8*(b->used_idx%b->qnum);
        st32(entry,head); st32(entry+4,used_len);
        b->used_idx++; st16(used+2,b->used_idx);
        b->last_avail++;
        completed = true;
    }
    if (completed && !(ld16(avail) & 1)) b->isr |= 1; /* VRING_AVAIL_F_NO_INTERRUPT */
    aic_update_locked();
}

bool blk_irq_level(int disk) { return disk < g.ndisks && bs[disk].isr != 0; }

bool blk_mmio(int disk, uint64_t off, int size, bool wr, uint64_t *val)
{
    if (size!=4 || disk>=g.ndisks) return false;
    struct blk_state *b=&bs[disk]; uint32_t v=(uint32_t)*val, r=0;
    if (wr) {
        switch(off) {
        case 0x14:b->devsel=v;break; case 0x24:b->drvsel=v;break;
        case 0x20:if (b->drvsel < 2) b->driver_features[b->drvsel]=v;break;
        case 0x30:b->qsel=v;break; case 0x38:if (b->qsel==0 && v>0 && v<=256) b->qnum=v; else return false;break;
        case 0x44:b->qready=v&1;break; case 0x50:if(v==0)process_queue(disk);break;
        case 0x64:b->isr &= ~v;aic_update_locked();break;
        case 0x70:
            if(v==0) { memset(b,0,sizeof *b); aic_update_locked(); }
            else {
                b->status=v;
                if ((v & 8) && !(b->driver_features[1] & VIRTIO_F_VERSION_1)) b->status &= ~8u;
            }
            break;
        case 0x80:b->desc=(b->desc&0xffffffff00000000ULL)|v;break;
        case 0x84:b->desc=(b->desc&0xffffffffULL)|((uint64_t)v<<32);break;
        case 0x90:b->avail=(b->avail&0xffffffff00000000ULL)|v;break;
        case 0x94:b->avail=(b->avail&0xffffffffULL)|((uint64_t)v<<32);break;
        case 0xa0:b->used=(b->used&0xffffffff00000000ULL)|v;break;
        case 0xa4:b->used=(b->used&0xffffffffULL)|((uint64_t)v<<32);break;
        default:return false;
        }
        return true;
    }
    if(off>=0x100 && off<0x108 && (off&3)==0) {
        uint64_t cap=g.disk_size[disk]/512; r=off==0x100?(uint32_t)cap:(uint32_t)(cap>>32);
    } else switch(off) {
    case 0x00:r=VIRTIO_MAGIC;break;case 0x04:r=VIRTIO_VERSION;break;case 0x08:r=VIRTIO_BLK;break;case 0x0c:r=0x554d5643;break;
    case 0x10:r=b->devsel==0?VIRTIO_BLK_F_FLUSH:(b->devsel==1?VIRTIO_F_VERSION_1:0);break;
    case 0x20:r=b->drvsel < 2 ? b->driver_features[b->drvsel] : 0;break;
    case 0x34:r=b->qsel==0?256:0;break;case 0x38:r=b->qnum;break;case 0x44:r=b->qready;break;
    case 0x60:r=b->isr;break;case 0x70:r=b->status;break;case 0xfc:r=0;break;
    default:return false;
    }
    *val=r;return true;
}
