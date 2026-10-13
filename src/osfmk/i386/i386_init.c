#include "../../pexpert/i386/pexpert.h"

typedef struct {
  uint32_t Type;
  uint64_t PhysicalStart, VirtualStart, NumberOfPages, Attribute;
} EfiMemoryRange;

boot_args *PE_boot_args;

static int usable(uint32_t type) {
  return type == 1 || type == 2 || type == 3 || type == 4 || type == 7;
}

void i386_init(boot_args *args) {
  PE_boot_args = args;
  serial_init();
  kprintf("finch Kernel Version 0.1: %s; root:finch/RELEASE_X86_64\n", BUILD_DATE);
  kprintf("boot_args: Revision %u Version %u efiMode %u\n", args->Revision, args->Version, args->efiMode);
  kprintf("boot-args: %s\n", args->CommandLine);
  kprintf("kernel: %x size %u kslide %x\n", args->kaddr, args->ksize, args->kslide);
  uint64_t pages = 0;
  uint32_t ranges = args->MemoryMapSize / args->MemoryMapDescriptorSize;
  for (uint32_t i = 0; i < ranges; i++) {
    EfiMemoryRange *r = (EfiMemoryRange *)((uint8_t *)(uintptr_t)args->MemoryMap + i * args->MemoryMapDescriptorSize);
    if (usable(r->Type)) pages += r->NumberOfPages;
  }
  kprintf("memory: %u ranges, %lu MB usable\n", ranges, pages * 4096 / (1024 * 1024));
  kprintf("video: %ux%ux%u at %lx\n", args->Video.v_width, args->Video.v_height, args->Video.v_depth,
          args->Video.v_baseAddr);
  if (PE_parse_boot_arg("halt")) {
    kprintf("halt\n");
    PE_halt();
  }
  for (;;) __asm__ volatile("hlt");
}
