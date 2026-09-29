// BQSort.HC -- exact permutation-compatible port of macOS libc qsort().
//
// Purpose: the Aiwnios C backend calls libc qsort() with comparators that
// return 0 on ties, so the order of equal elements (and hence the generated
// machine code) depends on the precise qsort algorithm. This file reproduces
// Apple's implementation so CoolC output matches byte-for-byte.
//
// Based on Apple Libc stdlib/FreeBSD/qsort.c (apple-oss-distributions/Libc,
// FreeBSD-derived Bentley & McIlroy quicksort with pseudomedian-of-9,
// insertion sort for n<=7, "swap_cnt==0 -> try insertion sort" heuristic,
// smaller-side recursion, and DEPTH()-limited fallback to heapsort), plus
// stdlib/FreeBSD/heapsort.c for the fallback. Verified against macOS 27.0
// (26A428) libc qsort()/heapsort().
//
// Comparator result is truncated to 32 bits (C `int`) before sign testing.
//
// Original copyright notices (BSD license):
//
// Copyright (c) 1992, 1993
//	The Regents of the University of California.  All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
// 3. Neither the name of the University nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
// OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
// LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
// OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
// SUCH DAMAGE.

// Call cmp and truncate the result to a signed 32-bit int, like C does.
I64 BQSCmp(I64 (*cmp)(U8 *a, U8 *b), I64 a, I64 b)
{
    I64 r = (*cmp)(a, b);
    r = r & 0xFFFFFFFF;
    if (r >= 0x80000000)
        r -= 0x100000000;
    return r;
}

U0 BQSSwap(I64 a, I64 b, I64 n)
{
    I64 t;
    U8 tb;
    while (n >= 8) {
        t = (a(I64 *))[0];
        (a(I64 *))[0] = (b(I64 *))[0];
        (b(I64 *))[0] = t;
        a += 8;
        b += 8;
        n -= 8;
    }
    while (n > 0) {
        tb = (a(U8 *))[0];
        (a(U8 *))[0] = (b(U8 *))[0];
        (b(U8 *))[0] = tb;
        a++;
        b++;
        n--;
    }
}

I64 BQSMed3(I64 a, I64 b, I64 c, I64 (*cmp)(U8 *a, U8 *b))
{
    if (BQSCmp(cmp, a, b) < 0) {
        if (BQSCmp(cmp, b, c) < 0)
            return b;
        if (BQSCmp(cmp, a, c) < 0)
            return c;
        return a;
    }
    if (BQSCmp(cmp, b, c) > 0)
        return b;
    if (BQSCmp(cmp, a, c) < 0)
        return a;
    return c;
}

// FreeBSD heapsort(); base is 1-based here (base - size), as in the original.
U0 BQSHeap(U8 *vbase, I64 nmemb, I64 size, I64 (*cmp)(U8 *a, U8 *b))
{
    I64 base, l, par, child, par_i, child_i, k;
    if (nmemb <= 1)
        return;
    k = MAlloc(size);
    base = vbase - size;
    for (l = nmemb / 2 + 1; --l;) {
        // CREATE(l)
        par_i = l;
        child_i = par_i * 2;
        while (child_i <= nmemb) {
            child = base + child_i * size;
            if (child_i < nmemb && BQSCmp(cmp, child, child + size) < 0) {
                child += size;
                child_i++;
            }
            par = base + par_i * size;
            if (BQSCmp(cmp, child, par) <= 0)
                break;
            BQSSwap(par, child, size);
            par_i = child_i;
            child_i = par_i * 2;
        }
    }
    while (nmemb > 1) {
        MemCpy(k, base + nmemb * size, size);
        MemCpy(base + nmemb * size, base + size, size);
        --nmemb;
        // SELECT
        par_i = 1;
        child_i = par_i * 2;
        while (child_i <= nmemb) {
            child = base + child_i * size;
            if (child_i < nmemb && BQSCmp(cmp, child, child + size) < 0) {
                child += size;
                child_i++;
            }
            par = base + par_i * size;
            MemCpy(par, child, size);
            par_i = child_i;
            child_i = par_i * 2;
        }
        while (TRUE) {
            child_i = par_i;
            par_i = child_i / 2;
            child = base + child_i * size;
            par = base + par_i * size;
            if (child_i == 1 || BQSCmp(cmp, k, par) < 0) {
                MemCpy(child, k, size);
                break;
            }
            MemCpy(child, par, size);
        }
    }
    Free(k);
}

// Returns FALSE if swap_limit (nonzero) was exceeded.
Bool BQSIsort(I64 a, I64 n, I64 es, I64 (*cmp)(U8 *a, U8 *b), I64 swap_limit)
{
    I64 swap_cnt = 0, pm, pl;
    for (pm = a + es; pm < a + n * es; pm += es) {
        pl = pm;
        while (pl > a && BQSCmp(cmp, pl - es, pl) > 0) {
            BQSSwap(pl, pl - es, es);
            if (swap_limit) {
                swap_cnt++;
                if (swap_cnt > swap_limit)
                    return FALSE;
            }
            pl -= es;
        }
    }
    return TRUE;
}

I64 BQSFls(I64 x) // C flsl(): 1-based index of highest set bit, 0 for 0
{
    I64 r = 0;
    while (x) {
        r++;
        x = x >> 1 & 0x7FFFFFFFFFFFFFFF;
    }
    return r;
}

U0 BQSRec(I64 a, I64 n, I64 es, I64 (*cmp)(U8 *a, U8 *b), I64 depth_limit)
{
    I64 pa, pb, pc, pd, pl, pm, pn, d, d1, d2, r, swap_cnt, cr;
    while (TRUE) {
        swap_cnt = 0;
        r = depth_limit;
        depth_limit--;
        if (r <= 0) {
            BQSHeap(a, n, es, cmp);
            return;
        }
        if (n <= 7) {
            BQSIsort(a, n, es, cmp, 0);
            return;
        }
        pl = a;
        pm = a + (n / 2) * es;
        pn = a + (n - 1) * es;
        if (n > 40) {
            d = (n / 8) * es;
            pl = BQSMed3(pl, pl + d, pl + 2 * d, cmp);
            pm = BQSMed3(pm - d, pm, pm + d, cmp);
            pn = BQSMed3(pn - 2 * d, pn - d, pn, cmp);
        }
        pm = BQSMed3(pl, pm, pn, cmp);
        BQSSwap(a, pm, es);
        pa = pb = a + es;
        pc = pd = a + (n - 1) * es;
        while (TRUE) {
            while (pb <= pc && (cr = BQSCmp(cmp, pb, a)) <= 0) {
                if (cr == 0) {
                    swap_cnt = 1;
                    BQSSwap(pa, pb, es);
                    pa += es;
                }
                pb += es;
            }
            while (pb <= pc && (cr = BQSCmp(cmp, pc, a)) >= 0) {
                if (cr == 0) {
                    swap_cnt = 1;
                    BQSSwap(pc, pd, es);
                    pd -= es;
                }
                pc -= es;
            }
            if (pb > pc)
                break;
            BQSSwap(pb, pc, es);
            swap_cnt = 1;
            pb += es;
            pc -= es;
        }
        pn = a + n * es;
        d1 = pa - a;
        if (pb - pa < d1)
            d1 = pb - pa;
        if (d1 > 0)
            BQSSwap(a, pb - d1, d1);
        d1 = pd - pc;
        if (pn - pd - es < d1)
            d1 = pn - pd - es;
        if (d1 > 0)
            BQSSwap(pb, pn - d1, d1);
        if (swap_cnt == 0) {
            r = 1 + n / 4;
            if (BQSIsort(a, n, es, cmp, r))
                return;
        }
        d1 = pb - pa;
        d2 = pd - pc;
        if (d1 <= d2) {
            if (d1 > es)
                BQSRec(a, d1 / es, es, cmp, depth_limit);
            if (d2 > es) {
                a = pn - d2;
                n = d2 / es;
            } else
                return;
        } else {
            if (d2 > es)
                BQSRec(pn - d2, d2 / es, es, cmp, depth_limit);
            if (d1 > es)
                n = d1 / es;
            else
                return;
        }
    }
}

U0 BQSort(U8 *base, I64 cnt, I64 size, U8 *cmp)
{
    I64 (*fp)(U8 *a, U8 *b);
    fp = cmp;
    BQSRec(base, cnt, size, fp, 2 * (BQSFls(cnt) - 1));
}
