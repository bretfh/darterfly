#include "../../pexpert/i386/pexpert.h"
#include "../vm/vm.h"
#include "seg.h"

typedef struct { uint64_t tsc_hz, tsc_base, epoch_base; } commpage_time;

commpage_time commpage __attribute__((aligned(4096)));

static uint64_t rdtsc(void) {
  uint32_t lo, hi;
  __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
  return ((uint64_t)hi << 32) | lo;
}

static uint64_t tsc_calibrate(void) {
  uint16_t count = 11932;
  outb(0x61, (inb(0x61) & ~0x02) | 0x01);
  outb(0x43, 0xb0);
  outb(0x42, count & 0xff);
  outb(0x42, count >> 8);
  uint64_t t0 = rdtsc();
  while (!(inb(0x61) & 0x20)) {}
  return (rdtsc() - t0) * 100;
}

static uint8_t cmos(uint8_t reg) {
  outb(0x70, reg);
  return inb(0x71);
}

static int bcd(int v, int binary) { return binary ? v : (v & 0x0f) + (v >> 4) * 10; }

static uint64_t rtc_epoch(void) {
  while (cmos(0x0a) & 0x80) {}
  int binary = cmos(0x0b) & 0x04;
  int sec = bcd(cmos(0x00), binary), min = bcd(cmos(0x02), binary), hour = bcd(cmos(0x04) & 0x7f, binary);
  int day = bcd(cmos(0x07), binary), month = bcd(cmos(0x08), binary), year = bcd(cmos(0x09), binary) + 2000;
  static const int before[] = {0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334};
  uint64_t days = (uint64_t)(year - 1970) * 365 + (year - 1969) / 4 - (year - 1901) / 100 + (year - 1601) / 400;
  days += before[month - 1] + day - 1;
  if (month > 2 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0)) days++;
  return days * 86400 + hour * 3600 + min * 60 + sec;
}

void rtclock_init(void) {
  commpage.tsc_hz = tsc_calibrate();
  commpage.epoch_base = rtc_epoch();
  commpage.tsc_base = rdtsc();
  kprintf("rtclock: tsc %lu MHz, epoch %lu\n", commpage.tsc_hz / 1000000, commpage.epoch_base);
}
