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

static char tx[65536];
static unsigned txhead, txtail;
static int interrupts_on;

static void put_polled(char c) {
  while (!(inb(COM1 + 5) & 0x20)) {}
  outb(COM1, (uint8_t)c);
}

void serial_putc(char c) {
  while (txhead != txtail) put_polled(tx[txtail++ % sizeof tx]);
  if (c == '\n') put_polled('\r');
  put_polled(c);
}

void serial_tx_kick(void) {
  while (txhead != txtail && (inb(COM1 + 5) & 0x20))
    for (int i = 0; i < 16 && txhead != txtail; i++) outb(COM1, (uint8_t)tx[txtail++ % sizeof tx]);
  if (interrupts_on) outb(COM1 + 1, txhead != txtail ? 0x03 : 0x01);
}

int serial_tx_room(void) { return txhead - txtail < sizeof tx - 2; }

void serial_write(char c) {
  if (!interrupts_on) {
    serial_putc(c);
    return;
  }
  if (c == '\n') tx[txhead++ % sizeof tx] = '\r';
  tx[txhead++ % sizeof tx] = c;
}

static char ring[4096];
static unsigned head, tail;

void serial_enable_interrupts(void) {
  outb(COM1 + 1, 0x01);
  outb(COM1 + 4, 0x0b);
  interrupts_on = 1;
}

void bsd_console_interrupt_char(void);

void serial_interrupt(void) {
  while (inb(COM1 + 5) & 1) {
    char c = (char)inb(COM1);
    if (c == 3) {
      bsd_console_interrupt_char();
      continue;
    }
    if (head - tail < sizeof ring) ring[head++ % sizeof ring] = c;
  }
  serial_tx_kick();
}

int serial_ready(void) {
  if (!interrupts_on) return inb(COM1 + 5) & 1;
  return head != tail;
}

int serial_getc(void) {
  if (!interrupts_on) {
    while (!(inb(COM1 + 5) & 1)) __asm__ volatile("pause");
    return inb(COM1);
  }
  if (head == tail) return -1;
  return (unsigned char)ring[tail++ % sizeof ring];
}
