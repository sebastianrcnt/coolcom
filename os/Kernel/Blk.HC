// Block devices: virtio-blk over virtio-mmio v2 ("modern"), VM-only (coolvm).
// One split virtqueue per device, requests are synchronous and polled: the
// driver posts a descriptor chain (header, data, status byte), rings the
// doorbell and spins until the used ring advances. Interrupts are suppressed
// (VRING_AVAIL_F_NO_INTERRUPT), so the AIC lines are not used.
//
// Ordering: ring and buffer stores are Normal memory, the doorbell is a Device
// store, so ArchDsb (dsb sy) sits between them and again after the used index
// is seen. Guest memory is coherent with the device model; a non-coherent DMA
// device would also need cache maintenance on the buffers here.
//
// Interface: BlkCount, BlkSectors, BlkRead, BlkWrite, BlkFlush (512-byte sectors,
// 0 on success, negative on error).
#define BLK_MAX          4
#define BLK_SECTOR       512
#define VQ_SIZE          8
#define VIO_MAGIC        0x74726976
#define VIO_MAGIC_OFF    0x00
#define VIO_VERSION_OFF  0x04
#define VIO_DEVID_OFF    0x08
#define VIO_DEVFEAT      0x10
#define VIO_DEVFEAT_SEL  0x14
#define VIO_DRVFEAT      0x20
#define VIO_DRVFEAT_SEL  0x24
#define VIO_QSEL         0x30
#define VIO_QNUM_MAX     0x34
#define VIO_QNUM         0x38
#define VIO_QREADY       0x44
#define VIO_QNOTIFY      0x50
#define VIO_ISR          0x60
#define VIO_ISR_ACK      0x64
#define VIO_STATUS       0x70
#define VIO_QDESC        0x80
#define VIO_QAVAIL       0x90
#define VIO_QUSED        0xA0
#define VIO_CONFIG       0x100
#define VIO_ST_ACK       1
#define VIO_ST_DRIVER    2
#define VIO_ST_DRIVER_OK 4
#define VIO_ST_FEAT_OK   8
#define VIO_F_BLK_FLUSH  (1 << 9)
#define VIO_F_VERSION_1  1
#define VRING_F_NEXT     1
#define VRING_F_WRITE    2
#define VBLK_T_IN        0
#define VBLK_T_OUT       1
#define VBLK_T_FLUSH     4
#define BLK_ERR_RANGE    -1
#define BLK_ERR_IO       -2
#define BLK_ERR_TIMEOUT  -3
#define BLK_ERR_NODEV    -4

class CBlkDev
{
    I64 base, sectors, lock, last_used;
    U8 *qdesc, *qavail, *qused, *qreq;  // req: 16-byte request header, status byte at +16
    Bool flush_ok;
};

CBlkDev blk_devs[BLK_MAX];
I64 blk_cnt;

I64 VioRd(CBlkDev *d, I64 off)
{
    return ArchMmioRead32(d->base + off);
}

U0 VioWr(CBlkDev *d, I64 off, I64 v)
{
    ArchMmioWrite32(d->base + off, v);
}

U0 VioWr64(CBlkDev *d, I64 off, I64 v)
{
    VioWr(d, off, v & 0xFFFFFFFF);
    VioWr(d, off + 4, v >> 32);
}

Bool BlkProbe(CBlkDev *d, I64 base)
{//Bring up a virtio-blk device; FALSE if it is not one or refuses us.
    I64 f0, f1;
    d->base = base;
    if (VioRd(d, VIO_MAGIC_OFF) != VIO_MAGIC || VioRd(d, VIO_VERSION_OFF) != 2 || VioRd(d, VIO_DEVID_OFF) != 2)
        return FALSE;
    VioWr(d, VIO_STATUS, 0);
    VioWr(d, VIO_STATUS, VIO_ST_ACK);
    VioWr(d, VIO_STATUS, VIO_ST_ACK | VIO_ST_DRIVER);
    VioWr(d, VIO_DEVFEAT_SEL, 0);
    f0 = VioRd(d, VIO_DEVFEAT);
    VioWr(d, VIO_DEVFEAT_SEL, 1);
    f1 = VioRd(d, VIO_DEVFEAT);
    if (!(f1 & VIO_F_VERSION_1))
        return FALSE;
    d->flush_ok = (f0 & VIO_F_BLK_FLUSH) != 0;
    VioWr(d, VIO_DRVFEAT_SEL, 0);
    VioWr(d, VIO_DRVFEAT, f0 & VIO_F_BLK_FLUSH);
    VioWr(d, VIO_DRVFEAT_SEL, 1);
    VioWr(d, VIO_DRVFEAT, VIO_F_VERSION_1);
    VioWr(d, VIO_STATUS, VIO_ST_ACK | VIO_ST_DRIVER | VIO_ST_FEAT_OK);
    if (!(VioRd(d, VIO_STATUS) & VIO_ST_FEAT_OK))
        return FALSE;
    VioWr(d, VIO_QSEL, 0);
    if (VioRd(d, VIO_QNUM_MAX) < VQ_SIZE)
        return FALSE;
    d->qdesc = CAlloc(16 * VQ_SIZE);
    d->qavail = CAlloc(6 + 2 * VQ_SIZE);
    d->qused = CAlloc(6 + 8 * VQ_SIZE);
    d->qreq = CAlloc(32);
    *(d->qavail)(U16i *) = 1;  // VRING_AVAIL_F_NO_INTERRUPT
    VioWr(d, VIO_QNUM, VQ_SIZE);
    VioWr64(d, VIO_QDESC, d->qdesc(I64));
    VioWr64(d, VIO_QAVAIL, d->qavail(I64));
    VioWr64(d, VIO_QUSED, d->qused(I64));
    ArchDsb;
    VioWr(d, VIO_QREADY, 1);
    VioWr(d, VIO_STATUS, VIO_ST_ACK | VIO_ST_DRIVER | VIO_ST_FEAT_OK | VIO_ST_DRIVER_OK);
    d->sectors = VioRd(d, VIO_CONFIG) | (VioRd(d, VIO_CONFIG + 4) << 32);
    return TRUE;
}

U0 VioDesc(CBlkDev *d, I64 i, U8 *addr, I64 len, I64 flags, I64 next)
{
    U8 *p = d->qdesc + 16 * i;
    *p(I64 *) = addr;
    *(p + 8)(U32i *) = len;
    *(p + 12)(U16i *) = flags;
    *(p + 14)(U16i *) = next;
}

I64 BlkRequest(CBlkDev *d, I64 type, I64 lba, U8 *buf, I64 bytes)
{//One synchronous request. Returns 0, BLK_ERR_IO or BLK_ERR_TIMEOUT.
    I64 daif, idx, deadline, res;
    U8 *status = d->qreq + 16;
    daif = SpinLockIrq(&d->lock);
    *(d->qreq)(U32i *) = type;
    *(d->qreq + 4)(U32i *) = 0;
    *(d->qreq + 8)(I64 *) = lba;
    *status = 0xFF;
    if (bytes) {
        VioDesc(d, 0, d->qreq, 16, VRING_F_NEXT, 1);
        if (type == VBLK_T_IN)
            VioDesc(d, 1, buf, bytes, VRING_F_NEXT | VRING_F_WRITE, 2);
        else
            VioDesc(d, 1, buf, bytes, VRING_F_NEXT, 2);
    } else
        VioDesc(d, 0, d->qreq, 16, VRING_F_NEXT, 2);
    VioDesc(d, 2, status, 1, VRING_F_WRITE, 0);
    idx = *(d->qavail + 2)(U16i *);
    *(d->qavail + 4 + 2 * (idx % VQ_SIZE))(U16i *) = 0;  // head descriptor 0
    ArchDsb;
    *(d->qavail + 2)(U16i *) = idx + 1;
    ArchDsb;
    VioWr(d, VIO_QNOTIFY, 0);
    deadline = ArchCntVct + 2 * ArchCntFrq;
    while (*(d->qused + 2)(U16i *) == (d->last_used & 0xFFFF)) {
        ArchDsb;
        if (ArchCntVct > deadline) {
            SpinUnlockIrq(&d->lock, daif);
            return BLK_ERR_TIMEOUT;
        }
    }
    ArchDsb;
    d->last_used++;
    VioWr(d, VIO_ISR_ACK, VioRd(d, VIO_ISR));
    res = 0;
    if (*status)
        res = BLK_ERR_IO;
    SpinUnlockIrq(&d->lock, daif);
    return res;
}

I64 BlkInit()
{//Probe the FDT's virtio-mmio nodes; returns the number of block devices.
    I64 i;
    for (i = 0; i < fdt_nblk && blk_cnt < BLK_MAX; i++)
        if (BlkProbe(&blk_devs[blk_cnt], fdt_blk[i].base))
            blk_cnt++;
    return blk_cnt;
}

I64 BlkCount()
{
    return blk_cnt;
}

I64 BlkSectors(I64 dev)
{
    if (dev < 0 || dev >= blk_cnt)
        return 0;
    return blk_devs[dev].sectors;
}

I64 BlkIo(I64 dev, I64 type, I64 lba, I64 cnt, U8 *buf)
{
    if (dev < 0 || dev >= blk_cnt)
        return BLK_ERR_NODEV;
    if (lba < 0 || cnt < 1 || cnt > 0x7FFFF || lba + cnt > blk_devs[dev].sectors)
        return BLK_ERR_RANGE;
    return BlkRequest(&blk_devs[dev], type, lba, buf, cnt * BLK_SECTOR);
}

I64 BlkRead(I64 dev, I64 lba, I64 cnt, U8 *buf)
{//Read cnt sectors starting at lba into buf.
    return BlkIo(dev, VBLK_T_IN, lba, cnt, buf);
}

I64 BlkWrite(I64 dev, I64 lba, I64 cnt, U8 *buf)
{
    return BlkIo(dev, VBLK_T_OUT, lba, cnt, buf);
}

I64 BlkFlush(I64 dev)
{//Make written sectors durable on the backing store.
    if (dev < 0 || dev >= blk_cnt)
        return BLK_ERR_NODEV;
    if (!blk_devs[dev].flush_ok)
        return 0;
    return BlkRequest(&blk_devs[dev], VBLK_T_FLUSH, 0, NULL, 0);
}
