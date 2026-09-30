# FAT32 shell commands

Paths in the kernel and shell are UTF-8. A component can contain up to 255
UTF-16 code units: 255 Hangul characters, or 127 supplementary characters plus
one BMP character. Invalid UTF-8, surrogate code points, FAT-forbidden characters,
and trailing spaces/dots are rejected. ASCII comparison is case-insensitive;
Unicode normalization and full Unicode case folding are not performed.

```c
DirMk("C:/자료");
FileWrite("C:/자료/긴 한글 파일 이름.txt", "hello", 5);
Copy("C:/자료", "D:/백업");
Move("D:/백업", "D:/보관");
Del("D:/보관");
DiskInfo('C');
Fsck('C');
Fsck('C', TRUE);
Fsck('C');
FatFormat('D');
```

`Copy` copies a tree to the requested new name. If the destination is an existing
directory, it receives the source basename. Masks such as `Copy("C:/자료/*",
"D:/백업")` copy each matched entry. A destination inside the source is rejected,
including a short alias for the source directory. `Move` copies first and deletes
the source only if the entire copy succeeds; it works across drives. `Del` removes
a named directory recursively. The root cannot be deleted.

`Copy`/`Move` return a Boolean. `Del` returns the number of removed files and
directories, or -1 on failure. Failures print the affected paths and completed/
failed counts. Completed destinations remain after a partial copy; after a
failed source deletion, a move can leave both copies. These commands are not
transactions and do not guarantee recovery from power loss. Tree traversal is
limited to 128 levels and rejects unreadable or cyclic directory chains.

`DiskInfo` scans the FAT, prints data capacity, free bytes and cluster size, and
returns free bytes (-1 on error). It does not trust FSInfo's cached count.

`Fsck` defaults to a read-only scan and returns the number of detected issues,
0 for clean, or -1 for an incomplete scan/I/O failure. With `TRUE`, it repairs:

- invalid links, loops and shared chains by truncating before the invalid/shared
  cluster; the first directory entry encountered owns a shared cluster;
- chains longer than a file and file sizes longer than their chains;
- incorrect `.`/`..` targets and directory sizes;
- malformed/orphan LFN sequences and duplicate short aliases;
- FAT mirror differences, using the first FAT as authoritative;
- unreachable allocated clusters by freeing them (not recovering them as files);
- reserved FAT entries and FSInfo signatures/free counts, including backup FSInfo.

Run a second read-only pass after repair. A repair return value counts issues
encountered, not issues remaining. Missing dot entries, an unusable root chain,
or an excessive directory depth require manual recovery; the command reports
an incomplete scan and does not sweep unvisited allocation. Repair may discard
ambiguous names, duplicate entries, or unreachable data. It is not a replacement
for a forensic recovery tool.

`FatFormat('D')` is an explicit, destructive quick format with no interactive
prompt. It formats an existing mounted volume while retaining partition bounds,
creates two FATs, boot/FSInfo backups and an empty root, flushes, and remounts the
volume. It returns a Boolean. It requires enough space for at least 65,525 data
clusters and supports 512-byte sectors. It does not create partitions or format
an unmounted raw device. Other tasks should not be using the target volume.
The mount implementation currently accepts two mirrored FATs, not active-FAT-only
volumes.

## Tests

`make test` includes the existing editor, input, shell, relocation and device
tests, plus FAT32 interoperability tests in `DevTest.cool` and
`tools/kernel-verify.py`. All FAT test images are disposable and created under
`build/`. Required macOS commands: `newfs_msdos`, `fsck_msdos`, and mtools
(`mformat`, `mcopy`, `mdir`).

The Mac seeds 255-unit and Hangul names that the kernel reads. The kernel writes
255-unit ASCII and Hangul names, an emoji name, colliding aliases past `~9`,
LFNs at exact 13-unit boundaries, and a 20-level Hangul tree. The host reads the
contents, independently validates raw UTF-16/order/checksums/alias uniqueness,
and requires `fsck_msdos -n` to be clean on both the host-formatted and
kernel-formatted volumes. This mtools build truncates supplementary-plane names
in its display; that case is checked through raw UTF-16 and short-alias reads.
Injected corruption exercises read-only detection, repair, and a clean recheck.
