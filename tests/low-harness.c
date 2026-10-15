#include <stdio.h>
#include <stdint.h>
#include <stdarg.h>

uint64_t low_add8(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
uint64_t low_nested(uint64_t);
uint64_t low_calls_low(void);
uint64_t low_varargs(void);
uint64_t low_signed(uint64_t, uint64_t);
uint64_t low_shifts(uint64_t);
uint64_t low_divide(uint64_t, uint64_t);
uint64_t low_deep(void);
uint64_t low_pointer(void);
uint64_t low_callback(uint64_t);

static int misaligned;

static void note_alignment(void) {
  if ((uintptr_t)__builtin_frame_address(0) % 16 != 0) misaligned++;
}

uint64_t c_check(void) {
  note_alignment();
  return 1;
}

uint64_t c_eight(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f, uint64_t g, uint64_t h) {
  note_alignment();
  return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h;
}

uint64_t c_sum(int n, ...) {
  va_list ap;
  uint64_t sum = 0;
  note_alignment();
  va_start(ap, n);
  for (int i = 0; i < n; i++) sum += va_arg(ap, uint64_t);
  va_end(ap);
  return sum;
}

uint64_t c_twice(uint64_t x) {
  note_alignment();
  return 2 * x;
}

uint64_t c_apply(uint64_t (*f)(uint64_t), uint64_t x) {
  note_alignment();
  return f(x) + 1;
}

uint64_t preserved(uint64_t (*f)(void));
__asm__(".text\n.globl preserved\npreserved:\n"
        "push %rbx\npush %r12\npush %r13\npush %r14\npush %r15\n"
        "mov $0x1111, %rbx\nmov $0x1212, %r12\nmov $0x1313, %r13\nmov $0x1414, %r14\nmov $0x1515, %r15\n"
        "call *%rdi\n"
        "xor %eax, %eax\n"
        "cmp $0x1111, %rbx\njne 1f\ncmp $0x1212, %r12\njne 1f\ncmp $0x1313, %r13\njne 1f\n"
        "cmp $0x1414, %r14\njne 1f\ncmp $0x1515, %r15\njne 1f\nmov $1, %eax\n"
        "1:\npop %r15\npop %r14\npop %r13\npop %r12\npop %rbx\nret\n");

int main(void) {
  printf("add8 %lu\n", (unsigned long)low_add8(1, 2, 3, 4, 5, 6, 7, 8));
  printf("nested %lu\n", (unsigned long)low_nested(10));
  printf("calls-low %lu\n", (unsigned long)low_calls_low());
  printf("varargs %lu\n", (unsigned long)low_varargs());
  printf("signed %lu %lu %lu\n", (unsigned long)low_signed((uint64_t)-1, 1), (unsigned long)low_signed(1, (uint64_t)-1),
         (unsigned long)low_signed(5, 5));
  printf("shifts %ld\n", (long)low_shifts((uint64_t)-64));
  printf("divide %ld\n", (long)low_divide((uint64_t)-7, 2));
  printf("deep %lu\n", (unsigned long)low_deep());
  printf("pointer %lu\n", (unsigned long)low_pointer());
  printf("callback %lu\n", (unsigned long)low_callback(20));
  printf("preserved %lu\n", (unsigned long)preserved(low_deep));
  printf("misaligned %d\n", misaligned);
  return 0;
}
