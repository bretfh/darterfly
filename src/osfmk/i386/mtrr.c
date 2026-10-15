#include "../../pexpert/i386/pexpert.h"

#define MSR_IA32_CR_PAT 0x277
#define PAT_WRITE_COMBINED 0x01ull

void pat_init(void) {
  uint32_t lo, hi;
  __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(MSR_IA32_CR_PAT));
  uint64_t pat = ((uint64_t)hi << 32) | lo;
  if ((pat & (0x07ull << 48)) == (PAT_WRITE_COMBINED << 48)) return;
  pat = (pat & ~(0x07ull << 48)) | (PAT_WRITE_COMBINED << 48);
  __asm__ volatile("wbinvd" ::: "memory");
  __asm__ volatile("wrmsr" ::"c"(MSR_IA32_CR_PAT), "a"((uint32_t)pat), "d"((uint32_t)(pat >> 32)));
  __asm__ volatile("wbinvd" ::: "memory");
}
