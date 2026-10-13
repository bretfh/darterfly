#include <stdint.h>
#include "pexpert.h"

#define COM1 0x3f8

void serial_init(void) {
  outb(COM1 + 1, 0x00);
  outb(COM1 + 3, 0x80);
  outb(COM1 + 0, 0x01);
  outb(COM1 + 1, 0x00);
  outb(COM1 + 3, 0x03);
  outb(COM1 + 2, 0xc7);
  outb(COM1 + 4, 0x03);
}

void serial_putc(char c) {
  if (c == '\n') serial_putc('\r');
  while (!(inb(COM1 + 5) & 0x20)) {}
  outb(COM1, (uint8_t)c);
}
