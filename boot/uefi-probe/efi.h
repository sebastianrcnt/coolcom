/* Minimal hand-rolled UEFI definitions for the probe (no external EFI library).
 * Target: aarch64-unknown-windows PE/COFF; the default calling convention of
 * that target is the one UEFI uses, so no EFIAPI annotation is needed. */
#ifndef PROBE_EFI_H
#define PROBE_EFI_H

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef int s32;
typedef long long s64;
typedef u64 UINTN;
typedef u64 EFI_STATUS;
typedef void *EFI_HANDLE;
typedef void *EFI_EVENT;
typedef u16 CHAR16;
typedef u8 BOOLEAN;

typedef __builtin_va_list va_list;
#define va_start(a, b) __builtin_va_start(a, b)
#define va_end(a) __builtin_va_end(a)
#define va_arg(a, t) __builtin_va_arg(a, t)

#define NULL ((void *)0)
#define EFI_SUCCESS 0ULL
#define EFI_ERROR(s) (((s64)(s)) < 0)
#define EFI_NOT_READY 0x8000000000000006ULL
#define EFI_BUFFER_TOO_SMALL 0x8000000000000005ULL

typedef struct {
    u32 a;
    u16 b;
    u16 c;
    u8 d[8];
} GUID;

typedef struct {
    u64 Signature;
    u32 Revision;
    u32 HeaderSize;
    u32 CRC32;
    u32 Reserved;
} TBLHDR;

/* ---- text output / input ---- */
typedef struct {
    s32 MaxMode, Mode, Attribute, CursorColumn, CursorRow;
    BOOLEAN CursorVisible;
} TXTMODE;
typedef struct TXTOUT TXTOUT;
struct TXTOUT {
    void *Reset;
    EFI_STATUS (*OutputString)(TXTOUT *, CHAR16 *);
    void *TestString;
    EFI_STATUS (*QueryMode)(TXTOUT *, UINTN, UINTN *, UINTN *);
    void *SetMode;
    EFI_STATUS (*SetAttribute)(TXTOUT *, UINTN);
    EFI_STATUS (*ClearScreen)(TXTOUT *);
    void *SetCursorPosition;
    void *EnableCursor;
    TXTMODE *Mode;
};
typedef struct {
    u16 ScanCode;
    u16 UnicodeChar;
} INKEY;
typedef struct TXTIN TXTIN;
struct TXTIN {
    EFI_STATUS (*Reset)(TXTIN *, BOOLEAN);
    EFI_STATUS (*ReadKeyStroke)(TXTIN *, INKEY *);
    EFI_EVENT WaitForKey;
};

/* ---- memory ---- */
typedef struct {
    u32 Type;
    u32 Pad;
    u64 PhysicalStart;
    u64 VirtualStart;
    u64 NumberOfPages;
    u64 Attribute;
} MEMDESC;

typedef struct {
    GUID VendorGuid;
    void *VendorTable;
} CFGTBL;

/* ---- time ---- */
typedef struct {
    u16 Year;
    u8 Month, Day, Hour, Minute, Second, Pad1;
    u32 Nanosecond;
    s32 TimeZone;
    u8 Daylight, Pad2;
} EFITIME;

/* ---- boot / runtime services ---- */
typedef struct {
    TBLHDR Hdr;
    void *RaiseTPL, *RestoreTPL;
    EFI_STATUS (*AllocatePages)(u32 type, u32 memtype, UINTN pages, u64 *addr);
    void *FreePages;
    EFI_STATUS (*GetMemoryMap)(UINTN *, MEMDESC *, UINTN *, UINTN *, u32 *);
    EFI_STATUS (*AllocatePool)(u32, UINTN, void **);
    EFI_STATUS (*FreePool)(void *);
    void *CreateEvent, *SetTimer;
    EFI_STATUS (*WaitForEvent)(UINTN, EFI_EVENT *, UINTN *);
    void *SignalEvent, *CloseEvent, *CheckEvent;
    void *InstallProtocolInterface, *ReinstallProtocolInterface, *UninstallProtocolInterface;
    EFI_STATUS (*HandleProtocol)(EFI_HANDLE, GUID *, void **);
    void *Reserved;
    void *RegisterProtocolNotify;
    void *LocateHandle;
    void *LocateDevicePath;
    void *InstallConfigurationTable;
    void *LoadImage, *StartImage, *Exit, *UnloadImage;
    EFI_STATUS (*ExitBootServices)(EFI_HANDLE, UINTN);
    void *GetNextMonotonicCount;
    EFI_STATUS (*Stall)(UINTN);
    EFI_STATUS (*SetWatchdogTimer)(UINTN, u64, UINTN, CHAR16 *);
    void *ConnectController, *DisconnectController;
    void *OpenProtocol, *CloseProtocol, *OpenProtocolInformation;
    EFI_STATUS (*ProtocolsPerHandle)(EFI_HANDLE, GUID ***, UINTN *);
    EFI_STATUS (*LocateHandleBuffer)(u32, GUID *, void *, UINTN *, EFI_HANDLE **);
    EFI_STATUS (*LocateProtocol)(GUID *, void *, void **);
    void *InstallMultipleProtocolInterfaces, *UninstallMultipleProtocolInterfaces;
    void *CalculateCrc32, *CopyMem, *SetMem, *CreateEventEx;
} BOOTSVC;

typedef struct {
    TBLHDR Hdr;
    EFI_STATUS (*GetTime)(EFITIME *, void *);
    void *SetTime, *GetWakeupTime, *SetWakeupTime;
    void *SetVirtualAddressMap, *ConvertPointer;
    EFI_STATUS (*GetVariable)(CHAR16 *, GUID *, u32 *, UINTN *, void *);
    EFI_STATUS (*GetNextVariableName)(UINTN *, CHAR16 *, GUID *);
    void *SetVariable;
    void *GetNextHighMonotonicCount;
    void (*ResetSystem)(u32, EFI_STATUS, UINTN, void *);
    void *UpdateCapsule, *QueryCapsuleCapabilities, *QueryVariableInfo;
} RTSVC;

typedef struct {
    TBLHDR Hdr;
    CHAR16 *FirmwareVendor;
    u32 FirmwareRevision;
    EFI_HANDLE ConsoleInHandle;
    TXTIN *ConIn;
    EFI_HANDLE ConsoleOutHandle;
    TXTOUT *ConOut;
    EFI_HANDLE StandardErrorHandle;
    TXTOUT *StdErr;
    RTSVC *RuntimeServices;
    BOOTSVC *BootServices;
    UINTN NumberOfTableEntries;
    CFGTBL *ConfigurationTable;
} SYSTBL;

/* ---- GOP ---- */
typedef struct {
    u32 RedMask, GreenMask, BlueMask, ReservedMask;
} PIXBITMASK;
typedef struct {
    u32 Version;
    u32 HorizontalResolution;
    u32 VerticalResolution;
    u32 PixelFormat; /* 0 RGBX, 1 BGRX, 2 bitmask, 3 blt only */
    PIXBITMASK PixelInformation;
    u32 PixelsPerScanLine;
} GOPINFO;
typedef struct {
    u32 MaxMode;
    u32 Mode;
    GOPINFO *Info;
    UINTN SizeOfInfo;
    u64 FrameBufferBase;
    UINTN FrameBufferSize;
} GOPMODE;
typedef struct GOP GOP;
struct GOP {
    EFI_STATUS (*QueryMode)(GOP *, u32, UINTN *, GOPINFO **);
    EFI_STATUS (*SetMode)(GOP *, u32);
    EFI_STATUS (*Blt)(GOP *, void *, u32, UINTN, UINTN, UINTN, UINTN, UINTN, UINTN, UINTN);
    GOPMODE *Mode;
};

/* ---- loaded image / file system ---- */
typedef struct {
    u32 Revision;
    EFI_HANDLE ParentHandle;
    SYSTBL *SystemTable;
    EFI_HANDLE DeviceHandle;
    void *FilePath;
    void *Reserved;
    u32 LoadOptionsSize;
    void *LoadOptions;
    void *ImageBase;
    u64 ImageSize;
    u32 ImageCodeType;
    u32 ImageDataType;
    void *Unload;
} LOADEDIMG;

typedef struct EFIFILE EFIFILE;
struct EFIFILE {
    u64 Revision;
    EFI_STATUS (*Open)(EFIFILE *, EFIFILE **, CHAR16 *, u64, u64);
    EFI_STATUS (*Close)(EFIFILE *);
    EFI_STATUS (*Delete)(EFIFILE *);
    EFI_STATUS (*Read)(EFIFILE *, UINTN *, void *);
    EFI_STATUS (*Write)(EFIFILE *, UINTN *, void *);
    void *GetPosition, *SetPosition, *GetInfo, *SetInfo;
    EFI_STATUS (*Flush)(EFIFILE *);
};
typedef struct SFS SFS;
struct SFS {
    u64 Revision;
    EFI_STATUS (*OpenVolume)(SFS *, EFIFILE **);
};

/* ---- device path to text ---- */
typedef struct DP2T DP2T;
struct DP2T {
    void *ConvertDeviceNodeToText;
    CHAR16 *(*ConvertDevicePathToText)(void *, BOOLEAN, BOOLEAN);
};

/* ---- PCI ---- */
typedef struct PCIIO PCIIO;
struct PCIIO {
    void *PollMem, *PollIo;
    void *MemRead, *MemWrite;
    void *IoRead, *IoWrite;
    EFI_STATUS (*PciRead)(PCIIO *, u32 width, u32 off, UINTN count, void *buf);
    EFI_STATUS (*PciWrite)(PCIIO *, u32 width, u32 off, UINTN count, void *buf);
    void *CopyMem, *Map, *Unmap, *AllocateBuffer, *FreeBuffer, *Flush;
    EFI_STATUS (*GetLocation)(PCIIO *, UINTN *, UINTN *, UINTN *, UINTN *);
    void *Attributes;
    EFI_STATUS (*GetBarAttributes)(PCIIO *, u8 bar, u64 *supports, void **resources);
    void *SetBarAttributes;
    u64 RomSize;
    void *RomImage;
};

typedef struct PCIRB PCIRB;
struct PCIRB {
    EFI_HANDLE ParentHandle;
    void *PollMem, *PollIo;
    void *MemRead, *MemWrite;
    void *IoRead, *IoWrite;
    void *PciRead, *PciWrite;
    void *CopyMem, *Map, *Unmap, *AllocateBuffer, *FreeBuffer, *Flush;
    void *GetAttributes, *SetAttributes;
    EFI_STATUS (*Configuration)(PCIRB *, void **);
    u32 SegmentNumber;
};

#define GUID_INIT(a, b, c, d0, d1, d2, d3, d4, d5, d6, d7) \
    { a, b, c, { d0, d1, d2, d3, d4, d5, d6, d7 } }

#endif
