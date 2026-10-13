#pragma once
#include <stdint.h>

#define KERNEL64_CS 0x08
#define KERNEL_DS 0x10
#define KERNEL_TSS 0x18

typedef struct x86_saved_state64 {
  uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp;
  uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
  uint64_t trapno, err;
  uint64_t rip, cs, rflags, rsp, ss;
} x86_saved_state64_t;

void mp_desc_init(void);
void panic(const char *format, ...) __attribute__((noreturn));
