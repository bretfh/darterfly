#pragma once
#include <signal.h>
#include <stdint.h>
/* Exact kernel signal frame: src/bsd/kern/signal.lisp. */
typedef struct {
    uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp;
    uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
    uint64_t trapno, err, rip, cs, rflags, rsp, ss;
} mcontext_t;
typedef struct {
    unsigned char fpstate[512];
    sigset_t uc_sigmask;
    mcontext_t uc_mcontext;
} ucontext_t;
