// Diff(a, b): report how two text files differ; Diff(a, b, TRUE) also merges, hunk by hunk,
// into a. A port of Aiwnios Src/Diff.HC (nrootconauto, BSD-3; TempleOS by Terry A. Davis, public
// domain) with the same algorithm: sort both files' lines, take the longest run of equal lines
// that both files share, and recurse on what lies before and after it; what is left between
// two runs is a hunk. The DolDoc document and pop-up menu are replaced by plain lines, ANSI
// colors and a one-key menu:
//   6,4---------------------      (red: the hunk's line number in a, in b)
//   the hunk's lines in a         (default color; starts one line above the hunk)
//   the hunk's lines in b         (cyan)
// Merge keys: 1 keep a's lines, 2 take b's, a rest of the file from a, b rest of the file from b,
// q leave this file alone, Esc leave it alone and stop. Returns TRUE if the files differ.
#define DF_MODIFIED             0x01
#define DF_DONT_MODIFIED        0x02
#define DF_ABORT_FILE           0x04
#define DF_ABORT_ALL_FILES      0x08
#define DF_REMAINDER_ALL_FILE1  0x10
#define DF_REMAINDER_ALL_FILE2  0x20
#define DF_NO_MORE_PMTS_THIS_FILE 0x40

class CDiffLine
{
    U8 *tag;
    I64 idx;  // the line's number in its file (the original's "new y")
};

class CDiff
{
    CDiffLine **sorted1, **sorted2, **unsorted1, **unsorted2;
    I64 cnt1, cnt2, flags;
    Bool merge;
    U8 *del1;                // merge: file 1's line i is replaced
    I64 *ins_lo, *ins_hi;    // merge: file 2's lines [lo, hi) go before file 1's line i
};

I64 DiffLineCompare(CDiffLine *e1, CDiffLine *e2)
{
    return StrCmp(e1->tag, e2->tag);
}

I64 DiffMenu()
{//The original's pop-up menu, as one line and a key. 1 2 a b q, else abort everything.
    I64 c;
    AnsiFg(ANSI_YELLOW);
    Print("[1] use a  [2] use b  [a] rest from a  [b] rest from b  [q] skip file  [Esc] stop: ");
    AnsiReset;
    c = GetKey & KEY_CODE;
    Print("\n");
    if (c == '1') return 1;
    if (c == '2') return 2;
    if (c == 'a') return 3;
    if (c == 'b') return 4;
    if (c == 'q') return 5;
    return 6;
}

U0 DiffPutLines(CDiffLine **lines, I64 lo, I64 hi)
{
    I64 i = lo - 1;
    if (lo <= 0) i = 0;
    while (i < hi) {
        TextPutLine(lines[i]->tag, StrLen(lines[i]->tag), 300);
        ConsPut('\n');
        i++;
    }
}

U0 DiffSel(CDiff *d, I64 j1_lo, I64 j1_hi, I64 j2_lo, I64 j2_hi)
{
    Bool use_file1 = TRUE;
    I64 k;
    if (d->flags & (DF_ABORT_FILE | DF_ABORT_ALL_FILES)) return;
    AnsiFg(ANSI_RED);
    if (0 <= j1_lo < d->cnt1) Print("%d,", d->unsorted1[j1_lo]->idx + 1);
    else if (0 <= j1_hi - 1 < d->cnt1) Print("%d,", d->unsorted1[j1_hi - 1]->idx + 1);
    else Print("***,");
    if (0 <= j2_lo < d->cnt2) Print("%d", d->unsorted2[j2_lo]->idx + 1);
    else if (0 <= j2_hi - 1 < d->cnt2) Print("%d", d->unsorted2[j2_hi - 1]->idx + 1);
    else Print("***");
    Print("---------------------");
    AnsiReset;
    ConsPut('\n');
    DiffPutLines(d->unsorted1, j1_lo, j1_hi);
    AnsiFg(ANSI_CYAN);
    DiffPutLines(d->unsorted2, j2_lo, j2_hi);
    AnsiReset;
    if (!d->merge) return;
    if (!(d->flags & DF_NO_MORE_PMTS_THIS_FILE)) {
        switch (DiffMenu) {
            case 1:
                break;
            case 2:
                use_file1 = FALSE;
                break;
            case 3:
                d->flags = (d->flags & ~DF_REMAINDER_ALL_FILE2) | DF_REMAINDER_ALL_FILE1 | DF_NO_MORE_PMTS_THIS_FILE;
                break;
            case 4:
                d->flags = (d->flags & ~DF_REMAINDER_ALL_FILE1) | DF_REMAINDER_ALL_FILE2 | DF_NO_MORE_PMTS_THIS_FILE;
                break;
            case 5:
                d->flags |= DF_DONT_MODIFIED | DF_ABORT_FILE | DF_NO_MORE_PMTS_THIS_FILE;
                break;
            default:
                d->flags |= DF_DONT_MODIFIED | DF_ABORT_ALL_FILES | DF_NO_MORE_PMTS_THIS_FILE;
        }
    }
    if ((d->flags & DF_REMAINDER_ALL_FILE2) && !(d->flags & (DF_DONT_MODIFIED | DF_REMAINDER_ALL_FILE1)))
        use_file1 = FALSE;
    if (!use_file1) {
        d->flags |= DF_MODIFIED;
        for (k = j1_lo; k < j1_hi; k++) d->del1[k] = TRUE;
        d->ins_lo[j1_lo] = j2_lo;
        d->ins_hi[j1_lo] = j2_hi;
    }
}

Bool DiffSub(CDiff *d, I64 j1_lo, I64 j1_hi, I64 j2_lo, I64 j2_hi)
{
    I64 i, i1 = 0, i2 = 0, i2b, j1, j2, n, best_j1 = 0, best_j2 = 0, best_score = 0, score;
    Bool res = FALSE;
    CDiffLine **s1 = d->sorted1, **s2 = d->sorted2, **u1 = d->unsorted1, **u2 = d->unsorted2;
    if (j1_lo >= j1_hi || j2_lo >= j2_hi) {
        if (j1_lo < j1_hi || j2_lo < j2_hi) {
            DiffSel(d, j1_lo, j1_hi, j2_lo, j2_hi);
            return TRUE;
        } else
            return FALSE;
    }
    // Locate the longest matching run of lines in the intervals.
    while (i1 < d->cnt1 && i2 < d->cnt2) {
        if (!(j1_lo <= s1[i1]->idx < j1_hi))
            i1++;
        else if (!(j2_lo <= s2[i2]->idx < j2_hi))
            i2++;
        else {
            i = StrCmp(s1[i1]->tag, s2[i2]->tag);
            if (i > 0)
                i2++;
            else if (i < 0)
                i1++;
            else {
                i2b = i2;
                while (!StrCmp(s1[i1]->tag, s2[i2]->tag)) {
                    if (j2_lo <= s2[i2]->idx < j2_hi) {
                        score = 0;
                        j1 = s1[i1]->idx;
                        j2 = s2[i2]->idx;
                        n = j1_hi - j1;
                        if (j2_hi - j2 < n) n = j2_hi - j2;
                        while (score < n) {
                            if (!StrCmp(u1[j1 + score]->tag, u2[j2 + score]->tag)) score++;
                            else break;
                        }
                        if (score > best_score) {
                            best_score = score;
                            best_j1 = j1;
                            best_j2 = j2;
                        }
                    }
                    i2++;
                    if (i2 >= d->cnt2) break;
                }
                i2 = i2b;
                i1++;
            }
        }
    }
    if (!best_score) {
        DiffSel(d, j1_lo, j1_hi, j2_lo, j2_hi);
        return TRUE;
    }
    if (DiffSub(d, j1_lo, best_j1, j2_lo, best_j2)) res = TRUE;
    if (DiffSub(d, best_j1 + best_score, j1_hi, best_j2 + best_score, j2_hi)) res = TRUE;
    return res;
}

I64 DiffLines(U8 *buf, I64 size, CDiffLine ***_sorted, CDiffLine ***_unsorted)
{//Split buf into lines (NULs replace the newlines and any CR before them); the arrays hold
    //them in file order and sorted by text (the unsorted one has a spare entry at the end).
    I64 cnt = 0, i, start = 0;
    CDiffLine **sorted, **unsorted;
    for (i = 0; i < size; i++)
        if (buf[i] == '\n') cnt++;
    if (size && buf[size - 1] != '\n') cnt++;
    sorted = MAlloc((cnt + 1) * sizeof(U8 *));
    unsorted = MAlloc((cnt + 1) * sizeof(U8 *));
    cnt = 0;
    for (i = 0; i <= size; i++) {
        if (i == size && start == size) break;
        if (i == size || buf[i] == '\n') {
            unsorted[cnt] = MAlloc(sizeof(CDiffLine));
            unsorted[cnt]->tag = buf + start;
            unsorted[cnt]->idx = cnt;
            if (i > start && buf[i - 1] == '\r') buf[i - 1] = 0;
            buf[i] = 0;  // the NUL FileRead left after the data serves a last line without newline
            sorted[cnt] = unsorted[cnt];
            cnt++;
            start = i + 1;
        }
    }
    unsorted[cnt] = NULL;
    QSortI64(sorted, cnt, &DiffLineCompare);
    *_sorted = sorted;
    *_unsorted = unsorted;
    return cnt;
}

U0 DiffFreeLines(CDiffLine **sorted, CDiffLine **unsorted, I64 cnt)
{
    I64 i;
    for (i = 0; i < cnt; i++) Free(unsorted[i]);
    Free(sorted);
    Free(unsorted);
}

Bool Diff(U8 *dst_file, U8 *src_file, Bool merge = FALSE, I64 *_df_flags = NULL)
{
    CDiff d;
    U8 *buf1, *buf2, *out, *tag;
    I64 size1 = TextRead(dst_file, &buf1), size2, i, k, n, len = 0;
    Bool res;
    if (size1 < 0) return FALSE;
    size2 = TextRead(src_file, &buf2);
    if (size2 < 0) {Free(buf1); return FALSE;}
    MemSet(&d, 0, sizeof(CDiff));
    d.merge = merge;
    if (_df_flags) d.flags = *_df_flags & DF_ABORT_ALL_FILES;
    d.cnt1 = DiffLines(buf1, size1, &d.sorted1, &d.unsorted1);
    d.cnt2 = DiffLines(buf2, size2, &d.sorted2, &d.unsorted2);
    d.del1 = CAlloc(d.cnt1 + 1);
    d.ins_lo = CAlloc((d.cnt1 + 1) * sizeof(I64));
    d.ins_hi = CAlloc((d.cnt1 + 1) * sizeof(I64));
    res = DiffSub(&d, 0, d.cnt1, 0, d.cnt2);
    if (!res) Print("Files are identical\n");
    if (merge && (d.flags & DF_MODIFIED) && !(d.flags & DF_DONT_MODIFIED)) {
        out = MAlloc(size1 + size2 + 2 * (d.cnt1 + d.cnt2) + 16);
        for (i = 0; i <= d.cnt1; i++) {
            if (d.ins_hi[i] > d.ins_lo[i])
                for (k = d.ins_lo[i]; k < d.ins_hi[i]; k++) {
                    tag = d.unsorted2[k]->tag;
                    n = StrLen(tag);
                    MemCpy(out + len, tag, n);
                    len += n;
                    out[len++] = '\n';
                }
            if (i < d.cnt1 && !d.del1[i]) {
                tag = d.unsorted1[i]->tag;
                n = StrLen(tag);
                MemCpy(out + len, tag, n);
                len += n;
                out[len++] = '\n';
            }
        }
        if (FileWrite(dst_file, out, len) == INVALID_CLUS && len) Print("Diff: could not write %s\n", dst_file);
        Free(out);
    }
    DiffFreeLines(d.sorted1, d.unsorted1, d.cnt1);
    DiffFreeLines(d.sorted2, d.unsorted2, d.cnt2);
    Free(d.del1);
    Free(d.ins_lo);
    Free(d.ins_hi);
    Free(buf1);
    Free(buf2);
    if (_df_flags) *_df_flags = d.flags;
    return res;
}
