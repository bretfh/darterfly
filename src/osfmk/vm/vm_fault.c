#include "vm.h"
#include "../../pexpert/i386/pexpert.h"

static struct { uint64_t start, end; int prot; } entries[64];
static int nentries;

int vm_map_enter(uint64_t start, uint64_t len, int prot) {
  if (nentries == 64) return 0;
  entries[nentries].start = start & ~(PAGE_SIZE - 1);
  entries[nentries].end = (start + len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
  entries[nentries].prot = prot;
  nentries++;
  return 1;
}

int vm_fault(uint64_t va, uint64_t err) {
  if (err & 1) return 0;
  for (int i = 0; i < nentries; i++) {
    if (va < entries[i].start || va >= entries[i].end) continue;
    uint64_t pa = vm_page_grab();
    if (!pa) return 0;
    uint64_t *page = PHYSMAP_PTOV(pa);
    for (int j = 0; j < 512; j++) page[j] = 0;
    pmap_enter(va & ~(PAGE_SIZE - 1), pa, entries[i].prot);
    return 1;
  }
  return 0;
}
