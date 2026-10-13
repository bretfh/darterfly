#include "../../pexpert/i386/pexpert.h"
#include "seg.h"
#include "../vm/vm.h"

typedef struct {
  uint32_t Type;
  uint64_t PhysicalStart, VirtualStart, NumberOfPages, Attribute;
} EfiMemoryRange;

boot_args *PE_boot_args;

static int usable(uint32_t type) {
  return type == 1 || type == 2 || type == 3 || type == 4 || type == 7;
}

static void vm_test(void) {
  uint64_t base = 0x1200000000ull, len = 1ull << 30;
  uint64_t before = vm_page_free_count();
  vm_map_enter(base, len, VM_PROT_READ | VM_PROT_WRITE);
  uint64_t sum = 0;
  for (uint64_t a = base; a < base + len; a += 2ull << 20) {
    if (*(volatile uint64_t *)a != 0) panic("vmtest: page at 0x%lx is not zero", a);
    *(volatile uint64_t *)a = a;
  }
  for (uint64_t a = base; a < base + len; a += 2ull << 20) sum += *(volatile uint64_t *)a == a;
  kprintf("vmtest: %lu demand-zero pages, %lu read back, %lu pages taken\n", len / (2ull << 20), sum,
          before - vm_page_free_count());
  void *a = kalloc(100), *b = kalloc(100000);
  kfree(a);
  void *c = kalloc(90);
  kprintf("vmtest: kalloc %s\n", a == c && b ? "reuses freed blocks" : "is wrong");
}

void i386_init(boot_args *args) {
  PE_boot_args = args;
  serial_init();
  kprintf("finch Kernel Version 0.1: %s; root:finch/RELEASE_X86_64\n", BUILD_DATE);
  kprintf("boot_args: Revision %u Version %u efiMode %u\n", args->Revision, args->Version, args->efiMode);
  kprintf("boot-args: %s\n", args->CommandLine);
  kprintf("kernel: 0x%x size %u kslide 0x%x\n", args->kaddr, args->ksize, args->kslide);
  uint64_t pages = 0;
  uint32_t ranges = args->MemoryMapSize / args->MemoryMapDescriptorSize;
  for (uint32_t i = 0; i < ranges; i++) {
    EfiMemoryRange *r = (EfiMemoryRange *)((uint8_t *)(uintptr_t)args->MemoryMap + i * args->MemoryMapDescriptorSize);
    if (usable(r->Type)) pages += r->NumberOfPages;
  }
  kprintf("memory: %u ranges, %lu MB usable\n", ranges, pages * 4096 / (1024 * 1024));
  kprintf("video: %ux%ux%u at 0x%lx\n", args->Video.v_width, args->Video.v_height, args->Video.v_depth,
          args->Video.v_baseAddr);
  mp_desc_init();
  kprintf("mp_desc: gdt, idt and ktss loaded\n");
  vm_page_bootstrap(args);
  pmap_bootstrap(args);
  args = PHYSMAP_PTOV(args);
  PE_boot_args = args;
  kalloc_init();
  kprintf("vm: %lu MB free\n", vm_page_free_count() * PAGE_SIZE / (1024 * 1024));
  if (PE_parse_boot_arg("vmtest")) vm_test();
  if (PE_parse_boot_arg("trap")) __asm__ volatile("int3");
  if (PE_parse_boot_arg("halt")) {
    kprintf("halt\n");
    PE_halt();
  }
  for (;;) __asm__ volatile("hlt");
}
