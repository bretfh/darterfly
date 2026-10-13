#include <stddef.h>
#include <stdint.h>

void *memcpy(void *d, const void *s, size_t n) {
  void *r = d;
  __asm__ volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
  return r;
}

void *memset(void *d, int c, size_t n) {
  void *r = d;
  __asm__ volatile("rep stosb" : "+D"(d), "+c"(n) : "a"(c) : "memory");
  return r;
}

void *memmove(void *d, const void *s, size_t n) {
  unsigned char *p = d;
  const unsigned char *q = s;
  if (p <= q || p >= q + n) return memcpy(d, s, n);
  while (n--) p[n] = q[n];
  return d;
}

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *p = a, *q = b;
  for (; n; n--, p++, q++)
    if (*p != *q) return *p - *q;
  return 0;
}

void bzero(void *d, size_t n) { memset(d, 0, n); }
