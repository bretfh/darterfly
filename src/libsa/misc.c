#include <stdlib.h>
#include <string.h>
#include <locale.h>
#include <libgen.h>

char *setlocale(int c, const char *l) { (void)c; (void)l; return "C"; }

char *dirname(char *p) {
  char *s = strrchr(p, '/');
  if (!s) return ".";
  if (s == p) return "/";
  *s = 0;
  return p;
}

char *basename(char *p) {
  char *s = strrchr(p, '/');
  return s ? s + 1 : p;
}

int prctl(int o, ...) { (void)o; return 0; }

unsigned _os_cpu_number(void) {
  unsigned aux;
  __asm__ volatile("rdtscp" : "=c"(aux)::"eax", "edx");
  return aux;
}
