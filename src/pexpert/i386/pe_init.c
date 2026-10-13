#include "pexpert.h"

extern boot_args *PE_boot_args;

int PE_parse_boot_arg(const char *name) {
  const char *s = PE_boot_args->CommandLine;
  while (*s) {
    while (*s == ' ') s++;
    const char *n = name;
    while (*n && *s == *n) s++, n++;
    if (!*n && (*s == ' ' || *s == '=' || !*s)) return 1;
    while (*s && *s != ' ') s++;
  }
  return 0;
}

int PE_parse_boot_argn(const char *name, int *value) {
  const char *s = PE_boot_args->CommandLine;
  while (*s) {
    while (*s == ' ') s++;
    const char *n = name;
    while (*n && *s == *n) s++, n++;
    if (!*n && *s == '=') {
      int v = 0;
      for (s++; *s >= '0' && *s <= '9'; s++) v = v * 10 + (*s - '0');
      *value = v;
      return 1;
    }
    while (*s && *s != ' ') s++;
  }
  return 0;
}

void PE_halt(void) {
  outb(0xf4, 0);
  for (;;) __asm__ volatile("cli; hlt");
}
