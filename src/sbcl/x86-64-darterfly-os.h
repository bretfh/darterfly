#ifndef _X86_64_DARTERFLY_OS_H
#define _X86_64_DARTERFLY_OS_H

#include <stdint.h>
#include <signal.h>

typedef struct os_context {
  uint8_t fxsave[512];
  sigset_t uc_sigmask;
  uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp, r8, r9, r10, r11, r12, r13, r14, r15;
  uint64_t trapno, err, rip, cs, rflags, rsp, ss;
} __attribute__((aligned(16))) os_context_t;

typedef long os_context_register_t;

unsigned int os_context_fp_control(os_context_t *context);
#define RESTORE_FP_CONTROL_FROM_CONTEXT
void os_restore_fp_control(os_context_t *context);

#define OS_CONTEXT_PC(context) (context)->rip

#endif
