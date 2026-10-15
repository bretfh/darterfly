#pragma once
#include <stdint.h>
#include <stddef.h>
#include "boot.h"

static inline void outb(uint16_t port, uint8_t v) { __asm__ volatile("outb %0, %1" ::"a"(v), "Nd"(port)); }
static inline uint8_t inb(uint16_t port) {
  uint8_t v;
  __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
  return v;
}

void serial_init(void);
void serial_putc(char c);
void serial_write(char c);
void serial_tx_kick(void);
int serial_tx_room(void);
int serial_getc(void);
int serial_ready(void);
void serial_interrupt(void);
void serial_enable_interrupts(void);
int PE_parse_boot_arg(const char *name);
int PE_parse_boot_argn(const char *name, int *value);
void PE_halt(void) __attribute__((noreturn));
uint64_t PE_interrupt_wait(uint64_t mask, uint64_t deadline);
void kprintf(const char *format, ...);
void panic(const char *format, ...) __attribute__((noreturn));
