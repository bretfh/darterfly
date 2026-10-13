#pragma once
#include <stdint.h>

#define KERNEL64_CS 0x08
#define KERNEL_DS 0x10
#define KERNEL_TSS 0x18
#define USER_DS 0x2b
#define USER64_CS 0x33

typedef struct x86_saved_state64 {
  uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp;
  uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
  uint64_t trapno, err;
  uint64_t rip, cs, rflags, rsp, ss;
} x86_saved_state64_t;

void mp_desc_init(void);
void thread_bootstrap_return(uint64_t rip, uint64_t rsp, uint64_t arg) __attribute__((noreturn));
void unix_syscall(x86_saved_state64_t *regs);
void machdep_syscall(x86_saved_state64_t *regs);
void mach_call(x86_saved_state64_t *regs);
int sendsig(x86_saved_state64_t *regs, int sig, int code, uint64_t addr);
void panic(const char *format, ...) __attribute__((noreturn));
