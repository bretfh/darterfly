#include "vm.h"
#include "../../pexpert/i386/pexpert.h"

typedef struct {
  uint32_t Type;
  uint64_t PhysicalStart, VirtualStart, NumberOfPages, Attribute;
} EfiMemoryRange;

static struct { uint64_t next, end; } ranges[256];
static int nranges, current;
static uint64_t free_list;
static uint64_t free_count;

void vm_page_bootstrap(boot_args *args) {
  uint32_t n = args->MemoryMapSize / args->MemoryMapDescriptorSize;
  for (uint32_t i = 0; i < n && nranges < 256; i++) {
    EfiMemoryRange *r = (EfiMemoryRange *)((uint8_t *)(uintptr_t)args->MemoryMap + i * args->MemoryMapDescriptorSize);
    if (r->Type != 3 && r->Type != 4 && r->Type != 7) continue;
    uint64_t start = r->PhysicalStart < 0x100000 ? 0x100000 : r->PhysicalStart;
    uint64_t end = r->PhysicalStart + r->NumberOfPages * PAGE_SIZE;
    if (start >= end) continue;
    ranges[nranges].next = start;
    ranges[nranges].end = end;
    free_count += (end - start) / PAGE_SIZE;
    nranges++;
  }
}

uint64_t vm_page_grab(void) {
  if (free_list) {
    uint64_t pa = free_list;
    free_list = *(uint64_t *)PHYSMAP_PTOV(pa);
    free_count--;
    return pa;
  }
  while (current < nranges && ranges[current].next >= ranges[current].end) current++;
  if (current == nranges) return 0;
  uint64_t pa = ranges[current].next;
  ranges[current].next += PAGE_SIZE;
  free_count--;
  return pa;
}

void vm_page_free(uint64_t pa) {
  *(uint64_t *)PHYSMAP_PTOV(pa) = free_list;
  free_list = pa;
  free_count++;
}

uint64_t vm_page_free_count(void) { return free_count; }
