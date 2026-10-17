#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stddef.h>
#include "os.h"
#include "thread.h"
#include "interr.h"

int arch_os_thread_init(struct thread *thread) {
  (void)thread;
  return 1;
}

int arch_os_thread_cleanup(struct thread *thread) {
  (void)thread;
  return 1;
}

static const unsigned short regmap[16] = {
    offsetof(os_context_t, rax), offsetof(os_context_t, rcx), offsetof(os_context_t, rdx),
    offsetof(os_context_t, rbx), offsetof(os_context_t, rsp), offsetof(os_context_t, rbp),
    offsetof(os_context_t, rsi), offsetof(os_context_t, rdi), offsetof(os_context_t, r8),
    offsetof(os_context_t, r9),  offsetof(os_context_t, r10), offsetof(os_context_t, r11),
    offsetof(os_context_t, r12), offsetof(os_context_t, r13), offsetof(os_context_t, r14),
    offsetof(os_context_t, r15)};

static const char *gprnames[] = {"rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
                                 "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15"};

void visit_context_registers(void (*p)(os_context_register_t, void *), os_context_t *context, void *arg) {
  p(context->rip, arg);
  for (int i = 0; i < 16; i++)
    if (i != 4) p(*(os_context_register_t *)((char *)context + regmap[i]), arg);
}

void sb_dump_mcontext(char *reason, os_context_t *context) {
  char buf[1024];
  int n = snprintf(buf, sizeof buf, "%s: rip=%016lx rflags=%016lx\n", reason, (long)context->rip, (long)context->rflags);
  for (int i = 0; i < 16; i++)
    n += snprintf(buf + n, sizeof buf - n, "%s=%016lx%s", gprnames[i],
                  *(long *)((char *)context + regmap[i]), i % 4 == 3 ? "\n" : " ");
  write(2, buf, n);
}

os_context_register_t *os_context_register_addr(os_context_t *context, int offset) {
  if (offset >= 0 && offset < 16) return (os_context_register_t *)((char *)context + regmap[offset]);
  return 0;
}

os_context_register_t *os_context_sp_addr(os_context_t *context) { return (os_context_register_t *)&context->rsp; }
os_context_register_t *os_context_fp_addr(os_context_t *context) { return (os_context_register_t *)&context->rbp; }

static unsigned int *mxcsr(os_context_t *context) { return (unsigned int *)(context->fxsave + 24); }

unsigned int os_context_fp_control(os_context_t *context) { return *mxcsr(context) ^ (0x3F << 7); }
void os_context_set_fp_control(os_context_t *context, unsigned int value) { *mxcsr(context) = value ^ (0x3F << 7); }

os_context_register_t *os_context_float_register_addr(os_context_t *context, int offset) {
  return (os_context_register_t *)(context->fxsave + 160 + 16 * offset);
}

os_context_register_t *os_context_ymm_register_addr(os_context_t *context, int offset) {
  return os_context_float_register_addr(context, offset);
}

sigset_t *os_context_sigmask_addr(os_context_t *context) { return &context->uc_sigmask; }

void os_restore_fp_control(os_context_t *context) {
  unsigned int temp = *mxcsr(context) & ~0x3F;
  __asm__("ldmxcsr %0" : : "m"(temp));
  __asm__("fldcw %0" : : "m"(*(unsigned short *)context->fxsave));
}

void os_flush_icache(os_vm_address_t address, os_vm_size_t length) {
  (void)address;
  (void)length;
}
