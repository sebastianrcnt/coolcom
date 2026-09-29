// Disk and file system definitions, from TempleOS by Terry A. Davis (public
// domain) as kept in Aiwnios (nrootconauto, commit e155e87, Src/KernelA.HH).
// Only what the FAT32 file system needs is kept: RedSea, ATA, CD/DVD and ISO
// definitions are gone. The block device bottom is our virtio-blk (Blk.HC).
// Classes are packed, so the on-disk structures map byte for byte.

#define BLK_SIZE_BITS 9
#define BLK_SIZE      (1 << BLK_SIZE_BITS)
#define INVALID_CLUS  (-1)

class CMBRPrt
{
    U8 active,  // 0x80=active  0x00=inactive
            start_head;
    U16 start_cyl;
    U8 type, end_head;
    U16 end_cyl;
    U32 offset,  // Sects between MBR and first sect
            size;  // Sects in drv
};

class CMasterBoot
{
    U8 code[440];
    U32 media_id;
    U16 zero;
    CMBRPrt p[4];
    U16 signature;  // AA55
};

class CFAT32Boot
{
    U8 jump_and_nop[3], oem_name[8];
    U16 bytes_per_sect;
    U8 sects_per_clus;
    U16 reserved_sects;
    U8 copies_of_fat;
    U16 max_root_dir_entries,  // Not used
            old_sects_in_drv;  // Not used
    U8 media_desc;
    U16 old_sects_per_fat,  // Not used
            sects_per_track, num_heads;
    U32 hidden_sects, sects, sects_per_fat;
    U16 flags, version;
    U32 root_clus;
    U16 file_system_info_sect, backup_boot_sect;
    U8 reserved[12], log_drv_num, unused,
            ext_signature;  // 0x29
    U32 serial_num;
    U8 vol_name[11], fat_name[8], code[420];
    U16 signature;
};

class CFAT32FileInfoSect
{
    U32 signature1;
    U8 unknown[480];
    U32 signature2, free_clus, most_recently_alloced;
    U8 reserved[12];
    U32 signature3;
};

class CFAT32DirEntry
{
    U8 name[11], attr, NTres, CrtTimeTenth;
    U16 CrtTime, CrtDate, LstAccDate, clus_hi, WrtTime, WrtDate, clus_lo;
    U32 size;
};

class CFAT32DirEntryLong
{
    U8 ord;
    U16 name1[5];
    U8 attr, type, xsum;
    U16 name2[6], zero, name3[2];
};

#define FAT32_ENTRIES_PER_BLK (BLK_SIZE / sizeof(CFAT32DirEntry))
#define FAT32_ENTRIES_BITS    4  // Bsf(FAT32_ENTRIES_PER_BLK)

// NTres bits (Windows NT): the short name's base or extension is lower case.
#define FAT_NT_LOWER_BASE 0x08
#define FAT_NT_LOWER_EXT  0x10

// File attributes (TempleOS keeps the RedSea names).
#define RS_ATTR_READ_ONLY      0x01  // R
#define RS_ATTR_HIDDEN         0x02  // H
#define RS_ATTR_SYSTEM         0x04  // S
#define RS_ATTR_VOL_ID         0x08  // V
#define RS_ATTR_DIR            0x10  // D
#define RS_ATTR_ARCHIVE        0x20  // A
#define RS_ATTR_LONG_NAME      (RS_ATTR_READ_ONLY | RS_ATTR_HIDDEN | RS_ATTR_SYSTEM | RS_ATTR_VOL_ID)
#define RS_ATTR_LONG_NAME_MASK (RS_ATTR_LONG_NAME | RS_ATTR_DIR | RS_ATTR_ARCHIVE)
#define RS_ATTR_DELETED        0x100   // X
#define RS_ATTR_RESIDENT       0x200   // T
#define RS_ATTR_COMPRESSED     0x400   // Z
#define RS_ATTR_CONTIGUOUS     0x800   // C
#define RS_ATTR_FIXED          0x1000  // F

// CDate here is the FAT timestamp: DOS date << 16 | DOS time (TempleOS uses
// its own 64-bit date; there is no real-time clock yet).
#define CDate I64

#define CDIR_FILENAME_LEN 38  // Must include terminator zero
class CDirEntry
{
    CDirEntry *next, *parent, *sub;
    U8 *full_name;
    I64 user_data, user_data2;

    U16 attr;
    U8 name[CDIR_FILENAME_LEN];
    I64 clus, size;
    CDate datetime;
};

// File Util Flags
#define FUf_RECURSE     0
#define FUf_JUST_DIRS   10
#define FUf_JUST_FILES  11
#define FUf_FLATTEN_TREE 21

#define FUF_RECURSE      0x0000001  // r
#define FUF_SINGLE       0x0000200  // s
#define FUF_JUST_DIRS    0x0000400  // D
#define FUF_JUST_FILES   0x0000800  // F
#define FUF_SCAN_PARENTS 0x0100000  // P
#define FUF_FLATTEN_TREE 0x0200000  // f

#define FUG_FILES_FIND (FUF_RECURSE | FUF_SINGLE | FUF_JUST_DIRS | FUF_JUST_FILES | FUF_FLATTEN_TREE)
#define FUG_FILE_FIND  (FUF_JUST_DIRS | FUF_JUST_FILES | FUF_SCAN_PARENTS)

#define BDT_NULL      0
#define BDT_VIRTIO    1  // coolvm virtio-blk, Blk.HC
#define BDT_TYPES_NUM 2

#define BDF_REMOVABLE        0x001
#define BDF_INITIALIZED      0x002
#define BDF_READ_ONLY        0x004
#define BDF_READ_CACHE       0x020
#define BDF_INIT_IN_PROGRESS 0x080

#define BDf_INITIALIZED 1

// locked flags
#define BDlf_LOCKED 0

#define BLKDEVS_NUM      26
#define BD_SIGNATURE_VAL 'BDSV'
class CBlkDev
{
    CBlkDev *lock_fwding;  // If two blkdevs on same controller, use just one lock
    I64 locked_flags;
    U32 bd_signature, type, flags, blk_size;
    I64 unit,  // Blk.HC device number
            max_blk;
    CTask *owning_task;
    U8 first_drv_let, pad[7];
};

// Drive locked_flags
#define DVlf_LOCKED 0

#define FSt_NULL      0
#define FSt_REDSEA    1  // Not supported here
#define FSt_FAT32     2  // Supported except for short names, to some degree
#define FSt_UNKNOWN   5
#define FSt_TYPES_NUM 7

#define MBR_PT_FAT32a 0x0B
#define MBR_PT_FAT32b 0x0C
#define MBR_PT_FAT32c 0x1B
#define MBR_PT_FAT32d 0x1C
#define MBR_PT_FAT32e 0x8B
#define MBR_PT_FAT32f 0x8C

#define DRVS_NUM          26
#define DRV_SIGNATURE_VAL 'DVSV'
class CDrv
{
    // Don't access ->drv_let directly in case a drive has been remapped.
    // Use Drv2Let().
    I64 locked_flags;
    U32 dv_signature;
    U8 drv_let, pad;
    U16 fs_type;
    I64 drv_offset, size, prt_num, file_system_info_sect, fat1, fat2, root_clus, data_area,
            spc;  // sectors per clus
    CDate fat32_local_time_offset;
    CTask *owning_task;
    CBlkDev *bd;

    CFAT32FileInfoSect *fis;
    I64 fat_blk_dirty, cur_fat_blk_num;
    U32 *cur_fat_blk;
};

#define DSK_CACHE_HASH_SIZE 0x2000

class CCacheBlk
{
    CCacheBlk *next_lru, *last_lru;
    CCacheBlk *next_hash, *last_hash;
    CDrv *dv;
    I64 blk;
    U8 body[BLK_SIZE];
};

class CBlkDevGlbls
{
    CBlkDev *blkdevs;
    U8 *home_dir;
    CCacheBlk *cache_base, *cache_ctrl, **cache_hash_table;
    I64 cache_size, read_cnt, write_cnt;
    CDrv *drvs, *let_to_drv[32];
    U8 boot_drv_let, first_hd_drv_let, pad[6];
};

CBlkDevGlbls blkdev;

class CDirContext
{
    CDrv *old_dv, *dv;
    U8 *old_dir, *mask;
};
