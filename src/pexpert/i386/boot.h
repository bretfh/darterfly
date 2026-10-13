#pragma once
#include <stdint.h>

#define BOOT_LINE_LENGTH 1024

#define kBootArgsRevision 1
#define kBootArgsVersion 2
#define kBootArgsEfiMode64 64

#define GRAPHICS_MODE 1

typedef struct Boot_VideoV1 {
  uint32_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
} Boot_VideoV1;

typedef struct Boot_Video {
  uint32_t v_display, v_rowBytes, v_width, v_height, v_depth;
  uint8_t v_rotate;
  uint8_t v_resv_byte[3];
  uint32_t v_resv[6];
  uint64_t v_baseAddr;
} Boot_Video;

typedef struct boot_args {
  uint16_t Revision;
  uint16_t Version;
  uint8_t efiMode;
  uint8_t debugMode;
  uint16_t flags;
  char CommandLine[BOOT_LINE_LENGTH];
  uint32_t MemoryMap;
  uint32_t MemoryMapSize;
  uint32_t MemoryMapDescriptorSize;
  uint32_t MemoryMapDescriptorVersion;
  Boot_VideoV1 VideoV1;
  uint32_t deviceTreeP;
  uint32_t deviceTreeLength;
  uint32_t kaddr;
  uint32_t ksize;
  uint32_t efiRuntimeServicesPageStart;
  uint32_t efiRuntimeServicesPageCount;
  uint64_t efiRuntimeServicesVirtualPageStart;
  uint32_t efiSystemTable;
  uint32_t kslide;
  uint32_t performanceDataStart;
  uint32_t performanceDataSize;
  uint32_t keyStoreDataStart;
  uint32_t keyStoreDataSize;
  uint64_t bootMemStart;
  uint64_t bootMemSize;
  uint64_t PhysicalMemorySize;
  uint64_t FSBFrequency;
  uint64_t pciConfigSpaceBaseAddress;
  uint32_t pciConfigSpaceStartBusNumber;
  uint32_t pciConfigSpaceEndBusNumber;
  uint32_t csrActiveConfig;
  uint32_t csrCapabilities;
  uint32_t boot_SMC_plimit;
  uint16_t bootProgressMeterStart;
  uint16_t bootProgressMeterEnd;
  Boot_Video Video;
  uint32_t apfsDataStart;
  uint32_t apfsDataSize;
  uint64_t KC_hdrs_vaddr;
  uint64_t arvRootHashStart, arvRootHashSize;
  uint64_t arvManifestStart, arvManifestSize;
  uint64_t bsARVRootHashStart, bsARVRootHashSize;
  uint64_t bsARVManifestStart, bsARVManifestSize;
  uint32_t __reserved4[692];
} boot_args;
