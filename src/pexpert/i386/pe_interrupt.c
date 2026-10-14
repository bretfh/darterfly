#include "pexpert.h"
#include "../../osfmk/kern/thread.h"

static volatile uint64_t interrupt_pending;

void PE_incoming_interrupt(int vector) {
  interrupt_pending |= 1ull << (vector - 0x30);
  thread_wakeup((uint64_t)&interrupt_pending, 1);
}

uint64_t PE_interrupt_wait(uint64_t mask, uint64_t deadline) {
  for (;;) {
    uint64_t fired = interrupt_pending & mask;
    if (fired) {
      interrupt_pending &= ~fired;
      return fired;
    }
    if (thread_wait((uint64_t)&interrupt_pending, deadline) != THREAD_AWAKENED) return 0;
  }
}
