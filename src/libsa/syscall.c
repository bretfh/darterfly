#include <errno.h>
#include "libsa.h"

static __thread int errno_value;
int *__errno_location(void) { return &errno_value; }

long __syscall(long n, long a, long b, long c, long d, long e, long f) {
  register long r10 __asm__("r10") = d;
  register long r8 __asm__("r8") = e;
  register long r9 __asm__("r9") = f;
  unsigned char carry;
  __asm__ volatile("int $0x80; setc %1"
                   : "+a"(n), "=r"(carry), "+D"(a), "+S"(b), "+d"(c), "+r"(r10), "+r"(r8), "+r"(r9)
                   :
                   : "memory", "rcx", "r11", "cc");
  if (carry) {
    errno = (int)n;
    return -1;
  }
  return n;
}

long __machdep5(long n, long a, long b, long c, long d, long e) {
  register long r10 __asm__("r10") = d;
  register long r8 __asm__("r8") = e;
  __asm__ volatile("int $0x82" : "+a"(n), "+D"(a), "+S"(b), "+d"(c), "+r"(r10), "+r"(r8) : : "memory", "rcx", "r9", "r11", "cc");
  return n;
}

long __machdep(long n, long a, long b) { return __machdep5(n, a, b, 0, 0, 0); }
