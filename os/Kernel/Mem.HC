// Kernel heap. Boundary-tag allocator over one contiguous range.
//
// Every block (free or used) starts with a 16-byte header:
//   sz: total block size incl. header (multiple of 16) | 1 if in use
//   pm: (HEAP_MAGIC << 32) | size of the physically previous block (0 if first)
// Free blocks keep doubly-linked list pointers in their first payload words.
// Free lists ("bins"): bins 0..30 hold exactly one block size each (32..512
// bytes, the O(1) small-allocation path); bins 31.. hold power-of-two ranges
// searched first-fit. Free() coalesces with both neighbours immediately, so
// an empty heap is always a single block. A zero-size in-use sentinel header
// ends the range. State lives in a CHeapCtrl so tasks can get their own later.

#define HEAP_MAGIC 0xB10C5AFE
#define HEAP_HDR   16
#define HEAP_MIN   32     // smallest block: header + list links
#define HEAP_NBINS 64

class CMemBlk
{
    I64 sz;
    I64 pm;
    CMemBlk *next, *prev;   // valid only while free
};

class CHeapCtrl
{
    U8 *start, *end;    // aligned range, end includes the sentinel header
    I64 total;          // bytes in real blocks (range minus sentinel)
    I64 used;           // bytes in used blocks, headers included
    CMemBlk *bin[HEAP_NBINS];
    I64 lock, lock_daif;
};

CHeapCtrl sys_heap;
I64 heap_errs;   // count of detected misuses (bad/double Free)

// IRQs are masked while held, so the heap is safe from interrupt handlers too.
U0 HeapLock(CHeapCtrl *hc)
{
    I64 daif = SpinLockIrq(&hc->lock);
    hc->lock_daif = daif;
}

U0 HeapUnlock(CHeapCtrl *hc)
{
    SpinUnlockIrq(&hc->lock, hc->lock_daif);
}

I64 BlkSize(CMemBlk *b) {return b->sz & ~15;}
Bool BlkUsed(CMemBlk *b) {return b->sz & 1;}
I64 BlkPrev(CMemBlk *b) {return b->pm & 0xFFFFFFFF;}
Bool BlkMagicOk(CMemBlk *b) {return ((b->pm >> 32) & 0xFFFFFFFF) == HEAP_MAGIC;}

U0 BlkSet(CMemBlk *b, I64 size, I64 used, I64 prev)
{
    b->sz = size | used;
    b->pm = (HEAP_MAGIC << 32) | prev;
}

U0 BlkSetPrev(CMemBlk *b, I64 prev)
{
    b->pm = (HEAP_MAGIC << 32) | prev;
}

I64 HeapBin(I64 size)
{
    I64 lg = 0;
    if (size <= 512)
        return (size - HEAP_MIN) >> 4;
    while (size > 1) {
        size >>= 1;
        lg++;
    }
    return 31 + lg - 9;
}

U0 HeapLink(CHeapCtrl *hc, CMemBlk *b)
{
    I64 i = HeapBin(BlkSize(b));
    b->prev = NULL;
    b->next = hc->bin[i];
    if (b->next)
        b->next->prev = b;
    hc->bin[i] = b;
}

U0 HeapUnlink(CHeapCtrl *hc, CMemBlk *b)
{
    if (b->prev)
        b->prev->next = b->next;
    else
        hc->bin[HeapBin(BlkSize(b))] = b->next;
    if (b->next)
        b->next->prev = b->prev;
}

// Put a free block of `size` at b (prev block size `prev`), fix the
// following block's back-link, and add it to its bin.
U0 HeapPutFree(CHeapCtrl *hc, CMemBlk *b, I64 size, I64 prev)
{
    BlkSet(b, size, 0, prev);
    BlkSetPrev(b(U8 *) + size, size);
    HeapLink(hc, b);
}

U0 HeapInit(CHeapCtrl *hc, U8 *start, U8 *end)
{
    I64 s = (start(I64) + 15) & ~15, e = end(I64) & ~15;
    MemSet(hc, 0, sizeof(CHeapCtrl));
    if (e - s < 4 * HEAP_MIN)
        return;
    hc->start = s;
    hc->end = e;
    hc->total = e - s - HEAP_HDR;
    BlkSet((e - HEAP_HDR)(CMemBlk *), 0, 1, hc->total);   // sentinel
    HeapPutFree(hc, s(CMemBlk *), hc->total, 0);
}

// Round a payload size up to a block size.
I64 HeapBlkSize(I64 size)
{
    size = (size + HEAP_HDR + 15) & ~15;
    if (size < HEAP_MIN)
        size = HEAP_MIN;
    return size;
}

U8 *HeapAlloc(CHeapCtrl *hc, I64 size)
{
    CMemBlk *b, *r;
    I64 tot, i, rem;
    if (size < 0 || size > hc->total)
        return NULL;
    tot = HeapBlkSize(size);
    HeapLock(hc);
    for (i = HeapBin(tot); i < HEAP_NBINS; i++) {
        b = hc->bin[i];
        while (b) {
            if (BlkSize(b) >= tot)
                goto found;
            b = b->next;
        }
    }
    HeapUnlock(hc);
    return NULL;
found:
    HeapUnlink(hc, b);
    rem = BlkSize(b) - tot;
    if (rem >= HEAP_MIN) {   // split off the tail
        r = b(U8 *) + tot;
        HeapPutFree(hc, r, rem, tot);
        BlkSet(b, tot, 1, BlkPrev(b));
    } else
        b->sz |= 1;
    hc->used += BlkSize(b);
    HeapUnlock(hc);
    return b(U8 *) + HEAP_HDR;
}

// Validate p and return its block, or NULL (and count an error) if bad.
CMemBlk *HeapChk(CHeapCtrl *hc, U8 *p, U8 *who)
{
    CMemBlk *b = p - HEAP_HDR;
    if (p(I64) & 15 || p < hc->start + HEAP_HDR || p >= hc->end ||
            !BlkMagicOk(b) || !BlkUsed(b)) {
        Print("%s: bad pointer %p (invalid or double free)\n", who, p);
        heap_errs++;
        return NULL;
    }
    return b;
}

// Release used block b, coalescing with free neighbours.
U0 HeapFreeBlk(CHeapCtrl *hc, CMemBlk *b)
{
    CMemBlk *n, *pb;
    I64 size = BlkSize(b), prev = BlkPrev(b);
    hc->used -= size;
    n = b(U8 *) + size;
    if (!BlkUsed(n)) {
        HeapUnlink(hc, n);
        size += BlkSize(n);
    }
    if (prev) {
        pb = b(U8 *) - prev;
        if (!BlkUsed(pb)) {
            HeapUnlink(hc, pb);
            size += prev;
            prev = BlkPrev(pb);
            b = pb;
        }
    }
    HeapPutFree(hc, b, size, prev);
}

U0 HeapFree(CHeapCtrl *hc, U8 *p)
{
    CMemBlk *b;
    if (!p)
        return;
    HeapLock(hc);
    b = HeapChk(hc, p, "Free");
    if (b)
        HeapFreeBlk(hc, b);
    HeapUnlock(hc);
}

// Shrink used block b to `tot` bytes, releasing the tail if large enough.
U0 HeapTrim(CHeapCtrl *hc, CMemBlk *b, I64 tot)
{
    I64 rem = BlkSize(b) - tot;
    CMemBlk *r;
    if (rem < HEAP_MIN)
        return;
    r = b(U8 *) + tot;
    BlkSet(b, tot, 1, BlkPrev(b));
    BlkSet(r, rem, 1, tot);   // used for the moment, so HeapFreeBlk accounts it
    BlkSetPrev(r(U8 *) + rem, rem);
    HeapFreeBlk(hc, r);
}

U8 *HeapReAlloc(CHeapCtrl *hc, U8 *p, I64 size)
{
    CMemBlk *b, *n;
    I64 tot, cur, ncur;
    U8 *q;
    if (!p)
        return HeapAlloc(hc, size);
    if (size < 0 || size > hc->total)
        return NULL;
    HeapLock(hc);
    b = HeapChk(hc, p, "ReAlloc");
    if (!b) {
        HeapUnlock(hc);
        return NULL;
    }
    tot = HeapBlkSize(size);
    cur = BlkSize(b);
    if (tot > cur) {   // try to grow into a free right neighbour
        n = b(U8 *) + cur;
        if (!BlkUsed(n) && cur + BlkSize(n) >= tot) {
            ncur = cur + BlkSize(n);
            HeapUnlink(hc, n);
            hc->used += BlkSize(n);
            BlkSet(b, ncur, 1, BlkPrev(b));
            BlkSetPrev(b(U8 *) + ncur, ncur);
            cur = ncur;
        }
    }
    if (tot <= cur) {
        HeapTrim(hc, b, tot);
        HeapUnlock(hc);
        return p;
    }
    HeapUnlock(hc);
    q = HeapAlloc(hc, size);
    if (!q)
        return NULL;   // original block is untouched
    MemCpy(q, p, cur - HEAP_HDR);
    HeapFree(hc, p);
    return q;
}

// Usable bytes in the block at p (0 for NULL or a bad pointer).
I64 HeapMSize(CHeapCtrl *hc, U8 *p)
{
    CMemBlk *b;
    if (!p)
        return 0;
    b = HeapChk(hc, p, "MSize");
    if (!b)
        return 0;
    return BlkSize(b) - HEAP_HDR;
}

// Walk the whole block chain. Returns TRUE if consistent; optionally reports
// block counts and the largest free block.
Bool HeapCheck(CHeapCtrl *hc, I64 *nused = NULL, I64 *nfree = NULL, I64 *largest = NULL)
{
    CMemBlk *b = hc->start;
    I64 prev = 0, u = 0, f = 0, big = 0, bytes = 0, fbytes = 0;
    Bool ok = TRUE;
    HeapLock(hc);
    while (BlkSize(b)) {
        if (!BlkMagicOk(b) || BlkPrev(b) != prev || (b(U8 *) + BlkSize(b)) > hc->end) {
            ok = FALSE;
            break;
        }
        if (BlkUsed(b))
            u++;
        else {
            f++;
            fbytes += BlkSize(b);
            if (BlkSize(b) > big)
                big = BlkSize(b);
        }
        bytes += BlkSize(b);
        prev = BlkSize(b);
        b = b(U8 *) + prev;
    }
    if (ok && (b(U8 *) != hc->end - HEAP_HDR || bytes != hc->total ||
               bytes - fbytes != hc->used))
        ok = FALSE;
    HeapUnlock(hc);
    if (nused)
        *nused = u;
    if (nfree)
        *nfree = f;
    if (largest)
        *largest = big;
    return ok;
}

I64 HeapUsedBytes(CHeapCtrl *hc) {return hc->used;}
I64 HeapFreeBytes(CHeapCtrl *hc) {return hc->total - hc->used;}

U0 HeapStatsCtrl(CHeapCtrl *hc)
{
    I64 nu, nf, big;
    U8 *st = "consistent";
    if (!HeapCheck(hc, &nu, &nf, &big))
        st = "CORRUPT";
    Print("heap: used %d KB in %d blks, free %d KB in %d blks (largest %d KB), %s\n",
            hc->used >> 10, nu, (hc->total - hc->used) >> 10, nf, big >> 10, st);
}

// ---- TempleOS-style API on the system heap ----

U0 MemInit(U8 *start, U8 *end) {HeapInit(&sys_heap, start, end);}
U8 *MAlloc(I64 size) {return HeapAlloc(&sys_heap, size);}

U8 *CAlloc(I64 size)
{
    U8 *p = HeapAlloc(&sys_heap, size);
    if (p)
        MemSet(p, 0, size);
    return p;
}

U0 Free(U8 *p) {HeapFree(&sys_heap, p);}
U8 *ReAlloc(U8 *p, I64 size) {return HeapReAlloc(&sys_heap, p, size);}
I64 MSize(U8 *p) {return HeapMSize(&sys_heap, p);}

// Copy of a heap block (its whole usable size).
U8 *MAllocIdent(U8 *src)
{
    I64 n = MSize(src);
    U8 *p;
    if (!src || !n)
        return NULL;
    p = MAlloc(n);
    if (p)
        MemCpy(p, src, n);
    return p;
}

// Heap copy of a string.
U8 *StrNew(U8 *s)
{
    I64 n = StrLen(s) + 1;
    U8 *p = MAlloc(n);
    if (p)
        MemCpy(p, s, n);
    return p;
}

U0 HeapStats() {HeapStatsCtrl(&sys_heap);}
