#pragma once
#include <stdint.h>
#include <stddef.h>

typedef uint64_t EFI_STATUS;
typedef void *EFI_HANDLE;
typedef uint16_t CHAR16;
typedef uint64_t UINTN;
typedef uint64_t EFI_PHYSICAL_ADDRESS;

#define EFI_SUCCESS 0
#define EFI_ERROR(s) ((int64_t)(s) < 0)

typedef struct { uint32_t a; uint16_t b, c; uint8_t d[8]; } EFI_GUID;

typedef struct {
  uint64_t Signature;
  uint32_t Revision, HeaderSize, CRC32, Reserved;
} EFI_TABLE_HEADER;

typedef struct {
  uint32_t Type;
  EFI_PHYSICAL_ADDRESS PhysicalStart;
  uint64_t VirtualStart, NumberOfPages, Attribute;
} EFI_MEMORY_DESCRIPTOR;

enum { AllocateAnyPages, AllocateMaxAddress, AllocateAddress };
enum { EfiReservedMemoryType, EfiLoaderCode, EfiLoaderData };

typedef struct EFI_BOOT_SERVICES {
  EFI_TABLE_HEADER Hdr;
  void *RaiseTPL, *RestoreTPL;
  EFI_STATUS (*AllocatePages)(int type, int memory_type, UINTN pages, EFI_PHYSICAL_ADDRESS *memory);
  EFI_STATUS (*FreePages)(EFI_PHYSICAL_ADDRESS memory, UINTN pages);
  EFI_STATUS (*GetMemoryMap)(UINTN *size, EFI_MEMORY_DESCRIPTOR *map, UINTN *key,
                             UINTN *descriptor_size, uint32_t *descriptor_version);
  EFI_STATUS (*AllocatePool)(int type, UINTN size, void **buffer);
  EFI_STATUS (*FreePool)(void *buffer);
  void *CreateEvent, *SetTimer, *WaitForEvent, *SignalEvent, *CloseEvent, *CheckEvent;
  void *InstallProtocolInterface, *ReinstallProtocolInterface, *UninstallProtocolInterface;
  EFI_STATUS (*HandleProtocol)(EFI_HANDLE handle, EFI_GUID *protocol, void **interface);
  void *Reserved, *RegisterProtocolNotify, *LocateHandle, *LocateDevicePath, *InstallConfigurationTable;
  void *LoadImage, *StartImage, *Exit, *UnloadImage;
  EFI_STATUS (*ExitBootServices)(EFI_HANDLE image, UINTN key);
  void *GetNextMonotonicCount, *Stall;
  EFI_STATUS (*SetWatchdogTimer)(UINTN timeout, uint64_t code, UINTN size, CHAR16 *data);
  void *ConnectController, *DisconnectController, *OpenProtocol, *CloseProtocol;
  void *OpenProtocolInformation, *ProtocolsPerHandle, *LocateHandleBuffer;
  EFI_STATUS (*LocateProtocol)(EFI_GUID *protocol, void *registration, void **interface);
} EFI_BOOT_SERVICES;

typedef struct {
  EFI_GUID VendorGuid;
  void *VendorTable;
} EFI_CONFIGURATION_TABLE;

typedef struct {
  EFI_TABLE_HEADER Hdr;
  CHAR16 *FirmwareVendor;
  uint32_t FirmwareRevision;
  EFI_HANDLE ConsoleInHandle;
  void *ConIn;
  EFI_HANDLE ConsoleOutHandle;
  void *ConOut;
  EFI_HANDLE StandardErrorHandle;
  void *StdErr;
  void *RuntimeServices;
  EFI_BOOT_SERVICES *BootServices;
  UINTN NumberOfTableEntries;
  EFI_CONFIGURATION_TABLE *ConfigurationTable;
} EFI_SYSTEM_TABLE;

typedef struct {
  uint32_t Revision;
  EFI_HANDLE ParentHandle;
  EFI_SYSTEM_TABLE *SystemTable;
  EFI_HANDLE DeviceHandle;
  void *FilePath, *Reserved;
  uint32_t LoadOptionsSize;
  void *LoadOptions;
  void *ImageBase;
  uint64_t ImageSize;
} EFI_LOADED_IMAGE_PROTOCOL;

typedef struct EFI_FILE_PROTOCOL {
  uint64_t Revision;
  EFI_STATUS (*Open)(struct EFI_FILE_PROTOCOL *self, struct EFI_FILE_PROTOCOL **new,
                     CHAR16 *name, uint64_t mode, uint64_t attributes);
  EFI_STATUS (*Close)(struct EFI_FILE_PROTOCOL *self);
  void *Delete;
  EFI_STATUS (*Read)(struct EFI_FILE_PROTOCOL *self, UINTN *size, void *buffer);
  void *Write;
  EFI_STATUS (*GetPosition)(struct EFI_FILE_PROTOCOL *self, uint64_t *position);
  EFI_STATUS (*SetPosition)(struct EFI_FILE_PROTOCOL *self, uint64_t position);
} EFI_FILE_PROTOCOL;

typedef struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL {
  uint64_t Revision;
  EFI_STATUS (*OpenVolume)(struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *self, EFI_FILE_PROTOCOL **root);
} EFI_SIMPLE_FILE_SYSTEM_PROTOCOL;

typedef struct {
  uint32_t Version, HorizontalResolution, VerticalResolution, PixelFormat;
  uint32_t RedMask, GreenMask, BlueMask, ReservedMask;
  uint32_t PixelsPerScanLine;
} EFI_GRAPHICS_OUTPUT_MODE_INFORMATION;

typedef struct {
  uint32_t MaxMode, Mode;
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info;
  UINTN SizeOfInfo;
  EFI_PHYSICAL_ADDRESS FrameBufferBase;
  UINTN FrameBufferSize;
} EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE;

typedef struct {
  void *QueryMode, *SetMode, *Blt;
  EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *Mode;
} EFI_GRAPHICS_OUTPUT_PROTOCOL;

#define EFI_LOADED_IMAGE_PROTOCOL_GUID \
  {0x5b1b31a1, 0x9562, 0x11d2, {0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
#define EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID \
  {0x964e5b22, 0x6459, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
#define EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID \
  {0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}}
#define EFI_ACPI_20_TABLE_GUID \
  {0x8868e871, 0xe4f1, 0x11d3, {0xbc, 0x22, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81}}

#define EFI_FILE_MODE_READ 1
