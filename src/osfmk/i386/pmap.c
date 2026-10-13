#include "../../pexpert/i386/pexpert.h"
#include "seg.h"

#define INTEL_PTE_VALID 0x1ull
#define INTEL_PTE_WRITE 0x2ull
#define INTEL_PTE_PS 0x80ull

static uint64_t IdlePML4[512] __attribute__((aligned(4096)));
static uint64_t IdlePDPT[512] __attribute__((aligned(4096)));
static uint64_t IdlePD[64][512] __attribute__((aligned(4096)));

static int cpu_has_1g_pages(void) {
  uint32_t a, b, c, d;
  __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0x80000001));
  return (d >> 26) & 1;
}

void pmap_bootstrap(void) {
  int gigs;
  if (cpu_has_1g_pages()) {
    gigs = 512;
    for (uint64_t i = 0; i < 512; i++) IdlePDPT[i] = (i << 30) | INTEL_PTE_VALID | INTEL_PTE_WRITE | INTEL_PTE_PS;
  } else {
    gigs = 64;
    for (uint64_t g = 0; g < 64; g++) {
      for (uint64_t i = 0; i < 512; i++)
        IdlePD[g][i] = (g << 30) | (i << 21) | INTEL_PTE_VALID | INTEL_PTE_WRITE | INTEL_PTE_PS;
      IdlePDPT[g] = (uint64_t)IdlePD[g] | INTEL_PTE_VALID | INTEL_PTE_WRITE;
    }
  }
  IdlePML4[0] = (uint64_t)IdlePDPT | INTEL_PTE_VALID | INTEL_PTE_WRITE;
  __asm__ volatile("mov %0, %%cr3" ::"r"((uint64_t)IdlePML4) : "memory");
  kprintf("pmap: direct map %d GB with %s pages\n", gigs, gigs == 512 ? "1 GB" : "2 MB");
}
