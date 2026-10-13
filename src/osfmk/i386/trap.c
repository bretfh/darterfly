#include "../../pexpert/i386/pexpert.h"
#include "seg.h"
#include "../vm/vm.h"

static const char *trap_type[] = {
    "divide error", "debug trap", "NMI", "breakpoint", "overflow", "bounds check", "invalid opcode",
    "no coprocessor", "double fault", "coprocessor overrun", "invalid TSS", "segment not present",
    "stack bounds", "general protection", "page fault", "(reserved)", "coprocessor error", "watchpoint",
    "machine check", "SSE floating point"};

#define READ_CR(n)                                       \
  ({                                                     \
    uint64_t v;                                          \
    __asm__ volatile("mov %%cr" #n ", %0" : "=r"(v));    \
    v;                                                   \
  })

void kernel_trap(x86_saved_state64_t *regs) {
  const char *type = regs->trapno < sizeof trap_type / sizeof *trap_type ? trap_type[regs->trapno] : "(reserved)";
  uint64_t cr2 = READ_CR(2);
  if (regs->trapno == 14 && vm_fault(cr2, regs->err)) return;
  panic("Kernel trap at 0x%016lx, type %lu=%s, registers:\n"
        "CR0: 0x%016lx, CR2: 0x%016lx, CR3: 0x%016lx, CR4: 0x%016lx\n"
        "RAX: 0x%016lx, RBX: 0x%016lx, RCX: 0x%016lx, RDX: 0x%016lx\n"
        "RSP: 0x%016lx, RBP: 0x%016lx, RSI: 0x%016lx, RDI: 0x%016lx\n"
        "R8:  0x%016lx, R9:  0x%016lx, R10: 0x%016lx, R11: 0x%016lx\n"
        "R12: 0x%016lx, R13: 0x%016lx, R14: 0x%016lx, R15: 0x%016lx\n"
        "RFL: 0x%016lx, RIP: 0x%016lx, CS:  0x%016lx, SS:  0x%016lx\n"
        "Fault CR2: 0x%016lx, Error code: 0x%016lx, Fault CPU: 0x0\n",
        regs->rip, regs->trapno, type, READ_CR(0), cr2, READ_CR(3), READ_CR(4), regs->rax, regs->rbx,
        regs->rcx, regs->rdx, regs->rsp, regs->rbp, regs->rsi, regs->rdi, regs->r8, regs->r9, regs->r10,
        regs->r11, regs->r12, regs->r13, regs->r14, regs->r15, regs->rflags, regs->rip, regs->cs & 0xffff,
        regs->ss & 0xffff, cr2, regs->err);
}
