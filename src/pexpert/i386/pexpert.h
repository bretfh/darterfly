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
int serial_getc(void);
int serial_ready(void);
void serial_interrupt(void);
void serial_enable_interrupts(void);
int PE_parse_boot_arg(const char *name);
void PE_halt(void) __attribute__((noreturn));
void kprintf(const char *format, ...);
void panic(const char *format, ...) __attribute__((noreturn));
