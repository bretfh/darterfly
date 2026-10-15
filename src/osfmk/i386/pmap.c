#include "../../pexpert/i386/pexpert.h"
#include "../vm/vm.h"
#include "seg.h"
#include "cpu_data.h"

#define INTEL_PTE_VALID 0x1ull
#define INTEL_PTE_WRITE 0x2ull
#define INTEL_PTE_PS 0x80ull
#define INTEL_PTE_USER 0x4ull
#define PTE_FRAME 0x200ull
#define INTEL_PTE_NX (1ull << 63)
#define PTE_PFN 0x000ffffffffff000ull

static uint64_t IdlePML4[512] __attribute__((aligned(4096)));
static uint64_t IdlePhysPDPT[512] __attribute__((aligned(4096)));
static uint64_t IdlePhysPD[64][512] __attribute__((aligned(4096)));
static uint64_t bootstrap_tables[16][512] __attribute__((aligned(4096)));
static int bootstrap_used;
static int physmap_ready;
extern boot_args *PE_boot_args;

static void *ptov(uint64_t pa) { return physmap_ready ? PHYSMAP_PTOV(pa) : (void *)pa; }

uint64_t kernel_phys;

static uint64_t table_page(void) {
  uint64_t pa;
  if (!physmap_ready) {
    if (bootstrap_used == 16) panic("pmap: out of bootstrap tables");
    pa = kvtophys(bootstrap_tables[bootstrap_used++]);
  } else {
    pa = vm_page_grab();
    if (!pa) panic("pmap: out of pages");
  }
  uint64_t *t = ptov(pa);
  for (int i = 0; i < 512; i++) t[i] = 0;
  return pa;
}

static uint64_t *pte(uint64_t va, int create) {
  uint64_t *table = ptov(kvtophys(IdlePML4));
  for (int shift = 39; shift > 12; shift -= 9) {
    uint64_t *e = &table[(va >> shift) & 511];
    if (!(*e & INTEL_PTE_VALID)) {
      if (!create) return 0;
      *e = table_page() | INTEL_PTE_VALID | INTEL_PTE_WRITE | INTEL_PTE_USER;
    }
    if (*e & INTEL_PTE_PS) panic("pmap: 0x%lx is inside a large page", va);
    table = ptov(*e & PTE_PFN);
  }
  return &table[(va >> 12) & 511];
}

static uint64_t prot_bits(int prot) {
  if (!prot) return 0;
  return INTEL_PTE_VALID | INTEL_PTE_USER | (prot & VM_PROT_WRITE ? INTEL_PTE_WRITE : 0) | (prot & VM_PROT_EXECUTE ? 0 : INTEL_PTE_NX);
}

static inline void invlpg(uint64_t va) { __asm__ volatile("invlpg (%0)" ::"r"(va) : "memory"); }

void pmap_enter(uint64_t va, uint64_t pa, int prot) {
  uint64_t *e = pte(va, 1);
  uint64_t old = *e;
  *e = (pa & PTE_PFN) | prot_bits(prot) | PTE_FRAME;
  invlpg(va);
  if (old & INTEL_PTE_VALID) pmap_flush_tlbs();
}



void pmap_protect(uint64_t va, uint64_t len, int prot) {
  int changed = 0;
  for (uint64_t a = va & ~(PAGE_SIZE - 1); a < va + len; a += PAGE_SIZE) {
    uint64_t *e = pte(a, 0);
    if (e && (*e & PTE_FRAME)) {
      *e = (*e & PTE_PFN) | prot_bits(prot) | PTE_FRAME;
      invlpg(a);
      changed = 1;
    }
  }
  if (changed) pmap_flush_tlbs();
}

void pmap_remove(uint64_t va, uint64_t len) {
  uint64_t freed[64];
  int n = 0;
  for (uint64_t a = va & ~(PAGE_SIZE - 1); a < va + len; a += PAGE_SIZE) {
    uint64_t *e = pte(a, 0);
    if (e && (*e & PTE_FRAME)) {
      freed[n++] = *e & PTE_PFN;
      *e = 0;
      invlpg(a);
      if (n == 64) {
        pmap_flush_tlbs();
        while (n) vm_page_free(freed[--n]);
      }
    }
  }
  if (n) pmap_flush_tlbs();
  while (n) vm_page_free(freed[--n]);
}

#define INTEL_PTE_NCACHE 0x10ull
#define INTEL_PTE_WTHRU 0x8ull
#define INTEL_PTE_PAT 0x80ull

void pmap_enter_io(uint64_t va, uint64_t pa, int wcomb) {
  *pte(va, 1) = (pa & PTE_PFN) | INTEL_PTE_VALID | INTEL_PTE_WRITE | INTEL_PTE_USER | INTEL_PTE_NX |
                (wcomb ? INTEL_PTE_PAT | INTEL_PTE_NCACHE : INTEL_PTE_NCACHE | INTEL_PTE_WTHRU);
  invlpg(va);
}

int pmap_access_ok(uint64_t va, uint64_t err) {
  uint64_t *e = pte(va, 0);
  if (!e || !(*e & INTEL_PTE_VALID)) return 0;
  if ((err & 2) && !(*e & INTEL_PTE_WRITE)) return 0;
  if ((err & 0x10) && (*e & INTEL_PTE_NX)) return 0;
  invlpg(va);
  return 1;
}

uint64_t pmap_find_phys(uint64_t va) {
  uint64_t *e = pte(va, 0);
  return e && (*e & PTE_FRAME) ? (*e & PTE_PFN) | (va & (PAGE_SIZE - 1)) : 0;
}

static int cpu_has_1g_pages(void) {
  uint32_t a, b, c, d;
  __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0x80000001));
  return (d >> 26) & 1;
}

static void enable_nx(void) {
  uint32_t lo, hi;
  __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(0xc0000080));
  lo |= 1 << 11;
  __asm__ volatile("wrmsr" ::"a"(lo), "d"(hi), "c"(0xc0000080));
}

void pmap_bootstrap(boot_args *args) {
  int gigs;
  kernel_phys = args->kaddr;
  if (cpu_has_1g_pages()) {
    gigs = 512;
    for (uint64_t i = 0; i < 512; i++)
      IdlePhysPDPT[i] = (i << 30) | INTEL_PTE_VALID | INTEL_PTE_WRITE | INTEL_PTE_USER | INTEL_PTE_PS | INTEL_PTE_NX;
  } else {
    gigs = 64;
    for (uint64_t g = 0; g < 64; g++) {
      for (uint64_t i = 0; i < 512; i++)
        IdlePhysPD[g][i] = (g << 30) | (i << 21) | INTEL_PTE_VALID | INTEL_PTE_WRITE | INTEL_PTE_USER | INTEL_PTE_PS | INTEL_PTE_NX;
      IdlePhysPDPT[g] = kvtophys(IdlePhysPD[g]) | INTEL_PTE_VALID | INTEL_PTE_WRITE | INTEL_PTE_USER;
    }
  }
  enable_nx();
  IdlePML4[256] = kvtophys(IdlePhysPDPT) | INTEL_PTE_VALID | INTEL_PTE_WRITE | INTEL_PTE_USER;
  for (uint32_t r = 0; r < args->kernelRegionCount; r++)
    for (uint64_t off = 0; off < args->kernelRegions[r].size; off += PAGE_SIZE)
      pmap_enter(args->kernelRegions[r].va + off, args->kernelRegions[r].pa + off,
                 VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
  uint32_t kaddr = args->kaddr;
  __asm__ volatile("mov %0, %%cr3" ::"r"(kvtophys(IdlePML4)) : "memory");
  physmap_ready = 1;
  PE_boot_args = PHYSMAP_PTOV(args);
  kprintf("pmap: physmap %d GB at 0x%lx with %s pages, kernel at 0x%lx from 0x%x\n", gigs, PHYSMAP_BASE,
          gigs == 512 ? "1 GB" : "2 MB", KERNEL_BASE, kaddr);
}
