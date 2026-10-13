#include <stdarg.h>
#include "../../pexpert/i386/pexpert.h"

static void put_unsigned(uint64_t v, unsigned base) {
  char b[24];
  int n = 0;
  do b[n++] = "0123456789abcdef"[v % base]; while (v /= base);
  while (n) serial_putc(b[--n]);
}

void kprintf(const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  for (const char *f = format; *f; f++) {
    if (*f != '%') {
      serial_putc(*f);
      continue;
    }
    int wide = 0;
    while (*++f == 'l') wide = 1;
    switch (*f) {
    case 's': for (const char *s = va_arg(ap, const char *); *s; s++) serial_putc(*s); break;
    case 'c': serial_putc((char)va_arg(ap, int)); break;
    case 'd': {
      int64_t v = wide ? va_arg(ap, int64_t) : va_arg(ap, int);
      if (v < 0) serial_putc('-'), v = -v;
      put_unsigned((uint64_t)v, 10);
      break;
    }
    case 'u': put_unsigned(wide ? va_arg(ap, uint64_t) : va_arg(ap, unsigned), 10); break;
    case 'x': serial_putc('0'), serial_putc('x'), put_unsigned(wide ? va_arg(ap, uint64_t) : va_arg(ap, unsigned), 16); break;
    case 'p': serial_putc('0'), serial_putc('x'), put_unsigned((uint64_t)va_arg(ap, void *), 16); break;
    default: serial_putc('%'), serial_putc(*f);
    }
  }
  va_end(ap);
}
