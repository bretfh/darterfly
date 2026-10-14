#include "../../pexpert/i386/pexpert.h"
#include "../vm/vm.h"
#include "seg.h"
#include "cpu_data.h"

#define LAPIC_START 0xFEE00000ull
#define IOAPIC_START 0xFEC00000ull
#define LAPIC_ID 0x20
#define LAPIC_EOI 0xB0
#define LAPIC_ICR 0x300
#define LAPIC_ICRD 0x310
#define LAPIC_ICR_DS_PENDING (1u << 12)
#define LAPIC_SVR 0xF0
#define LAPIC_TIMER 0x320
#define LAPIC_TIMER_INITIAL_COUNT 0x380
#define LAPIC_TIMER_CURRENT_COUNT 0x390
#define LAPIC_TIMER_DIVIDE_CONFIG 0x3E0
#define LAPIC_TIMER_PERIODIC (1u << 17)
#define LAPIC_SPURIOUS_VECTOR 0xDA
#define LAPIC_TIMER_VECTOR 0xDD
#define LAPIC_INTERPROCESSOR_INTERRUPT 0xDE
#define COM1_VECTOR 0x24
#define HZ 100

uint64_t ticks;
static uint32_t per_tick;

static volatile uint32_t *lapic(uint32_t reg) { return (volatile uint32_t *)PHYSMAP_PTOV(LAPIC_START + reg); }

static void ioapic_write(uint32_t reg, uint32_t value) {
  *(volatile uint32_t *)PHYSMAP_PTOV(IOAPIC_START) = reg;
  *(volatile uint32_t *)PHYSMAP_PTOV(IOAPIC_START + 0x10) = value;
}

static void pic_disable(void) {
  outb(0x20, 0x11);
  outb(0xA0, 0x11);
  outb(0x21, 0x20);
  outb(0xA1, 0x28);
  outb(0x21, 0x04);
  outb(0xA1, 0x02);
  outb(0x21, 0x01);
  outb(0xA1, 0x01);
  outb(0x21, 0xff);
  outb(0xA1, 0xff);
}

static uint32_t lapic_calibrate(void) {
  *lapic(LAPIC_TIMER_DIVIDE_CONFIG) = 0x3;
  *lapic(LAPIC_TIMER) = 1u << 16;
  *lapic(LAPIC_TIMER_INITIAL_COUNT) = 0xffffffff;
  outb(0x61, (inb(0x61) & ~0x02) | 0x01);
  outb(0x43, 0xb0);
  outb(0x42, 11932 & 0xff);
  outb(0x42, 11932 >> 8);
  outb(0x61, inb(0x61) & ~0x01);
  outb(0x61, inb(0x61) | 0x01);
  uint32_t start = *lapic(LAPIC_TIMER_CURRENT_COUNT);
  while (!(inb(0x61) & 0x20)) {}
  return start - *lapic(LAPIC_TIMER_CURRENT_COUNT);
}

uint32_t lapic_id(void) { return *lapic(LAPIC_ID) >> 24; }

void lapic_send_ipi(uint32_t apic_id, uint32_t icr) {
  while (*lapic(LAPIC_ICR) & LAPIC_ICR_DS_PENDING) cpu_pause();
  *lapic(LAPIC_ICRD) = apic_id << 24;
  *lapic(LAPIC_ICR) = icr;
  while (*lapic(LAPIC_ICR) & LAPIC_ICR_DS_PENDING) cpu_pause();
}

void i386_signal_cpu(int cpu) { lapic_send_ipi(cpu_datap(cpu)->cpu_phys_number, LAPIC_INTERPROCESSOR_INTERRUPT); }

void lapic_init_slave(void) {
  uint32_t lo, hi;
  __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(0x1b));
  lo |= 1u << 11;
  __asm__ volatile("wrmsr" ::"a"(lo), "d"(hi), "c"(0x1b));
  *lapic(LAPIC_SVR) = 0x100 | LAPIC_SPURIOUS_VECTOR;
  *lapic(LAPIC_TIMER_DIVIDE_CONFIG) = 0x3;
  *lapic(LAPIC_TIMER) = LAPIC_TIMER_VECTOR | LAPIC_TIMER_PERIODIC;
  *lapic(LAPIC_TIMER_INITIAL_COUNT) = per_tick;
}

void lapic_init(void) {
  pic_disable();
  uint32_t lo, hi;
  __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(0x1b));
  lo |= 1u << 11;
  __asm__ volatile("wrmsr" ::"a"(lo), "d"(hi), "c"(0x1b));
  *lapic(LAPIC_SVR) = 0x100 | LAPIC_SPURIOUS_VECTOR;
  per_tick = lapic_calibrate();
  *lapic(LAPIC_TIMER_DIVIDE_CONFIG) = 0x3;
  *lapic(LAPIC_TIMER) = LAPIC_TIMER_VECTOR | LAPIC_TIMER_PERIODIC;
  *lapic(LAPIC_TIMER_INITIAL_COUNT) = per_tick;
  ioapic_write(0x10 + 2 * 4, COM1_VECTOR);
  ioapic_write(0x10 + 2 * 4 + 1, lapic_id() << 24);
  serial_enable_interrupts();
  kprintf("lapic: timer %u counts per tick at %d Hz, com1 on vector 0x%x\n", per_tick, HZ, COM1_VECTOR);
}

void bsd_hardclock(void);
void sched_tick(void);
void bsd_serial_wakeup(void);
void PE_incoming_interrupt(int vector);

void lapic_interrupt(uint64_t vector) {
  if (vector == LAPIC_TIMER_VECTOR) {
    if (cpu_number() == 0) {
      ticks++;
      bsd_hardclock();
    }
    sched_tick();
  } else if (vector == COM1_VECTOR) {
    serial_interrupt();
    bsd_serial_wakeup();
  } else if (vector >= 0x30 && vector < 0x40) {
    PE_incoming_interrupt((int)vector);
  }
  if (vector != LAPIC_SPURIOUS_VECTOR) *lapic(LAPIC_EOI) = 0;
}
