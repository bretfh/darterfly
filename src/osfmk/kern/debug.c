#include <stdarg.h>
#include "../../pexpert/i386/pexpert.h"
#include "../i386/seg.h"

void vkprintf(const char *format, va_list ap);

void panic(const char *format, ...) {
  va_list ap;
  kprintf("panic(cpu 0 caller 0x%lx): ", (uint64_t)__builtin_return_address(0));
  va_start(ap, format);
  vkprintf(format, ap);
  va_end(ap);
  if (PE_parse_boot_arg("halt")) PE_halt();
  for (;;) __asm__ volatile("cli; hlt");
}
