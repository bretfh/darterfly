#include "../vm/vm.h"
#include "../../pexpert/i386/pexpert.h"

#define KALLOC_BASE 0xffffff0000000000ull
#define KALLOC_SIZE (64ull << 30)

static uint64_t kalloc_next = KALLOC_BASE;
static void *zones[64];

typedef struct { uint64_t size, pad; } kalloc_header;

void kalloc_init(void) { vm_map_enter(KALLOC_BASE, KALLOC_SIZE, VM_PROT_READ | VM_PROT_WRITE); }

static int zone_of(size_t size) {
  int z = 4;
  while ((1ull << z) < size) z++;
  return z;
}

void *kalloc(size_t size) {
  int z = zone_of(size + sizeof(kalloc_header));
  kalloc_header *h;
  if (zones[z]) {
    h = zones[z];
    zones[z] = *(void **)h;
  } else {
    uint64_t align = (1ull << z) < PAGE_SIZE ? 16 : PAGE_SIZE;
    kalloc_next = (kalloc_next + align - 1) & ~(align - 1);
    h = (kalloc_header *)kalloc_next;
    kalloc_next += 1ull << z;
  }
  h->size = (uint64_t)z;
  return h + 1;
}

void kfree(void *p) {
  if (!p) return;
  kalloc_header *h = (kalloc_header *)p - 1;
  int z = (int)h->size;
  *(void **)h = zones[z];
  zones[z] = h;
}
