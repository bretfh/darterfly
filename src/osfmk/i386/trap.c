#include "../../pexpert/i386/pexpert.h"
#include "seg.h"
#include "../vm/vm.h"
#include "../kern/thread.h"

#define SIGILL 4
#define SIGTRAP 5
#define SIGBUS 7
#define SIGFPE 8
#define SIGSEGV 11

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

static void panic_trap(x86_saved_state64_t *regs) {
  const char *type = regs->trapno < sizeof trap_type / sizeof *trap_type ? trap_type[regs->trapno] : "(reserved)";
  uint64_t cr2 = READ_CR(2);
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

static void user_trap(x86_saved_state64_t *regs) {
  uint64_t cr2 = READ_CR(2);
  switch (regs->trapno) {
  case 0x80: unix_syscall(regs); return;
  case 0x81: mach_call(regs); return;
  case 0x82: machdep_syscall(regs); return;
  case 14:
    if (vm_fault(cr2, regs->err)) return;
    if (PE_parse_boot_arg("faulttrace")) {
      uint32_t lo, hi;
      __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(0xc0000100));
      kprintf("[fault: thread 0x%lx rip 0x%lx cr2 0x%lx err 0x%lx r13 0x%lx rsp 0x%lx fs 0x%lx]\n",
              current_thread()->thread_id, regs->rip, cr2, regs->err, regs->r13, regs->rsp,
              ((uint64_t)hi << 32) | lo);
    }
    if (sendsig(regs, SIGSEGV, (regs->err & 1) ? 2 : 1, cr2)) return;
    break;
  case 1:
  case 3:
    if (sendsig(regs, SIGTRAP, 1, regs->rip)) return;
    break;
  case 6:
    if (sendsig(regs, SIGILL, 1, regs->rip)) return;
    break;
  case 0:
    if (sendsig(regs, SIGFPE, 1, regs->rip)) return;
    break;
  case 19:
    if (sendsig(regs, SIGFPE, 0, regs->rip)) return;
    break;
  case 13:
  case 17:
    if (sendsig(regs, regs->trapno == 13 ? SIGSEGV : SIGBUS, 0, 0)) return;
    break;
  }
  kprintf("user trap with no handler:\n");
  panic_trap(regs);
}

void lapic_interrupt(uint64_t vector);
void bsd_ast(x86_saved_state64_t *regs);
void mach_call(x86_saved_state64_t *regs);
void sched_ast(void);

void kernel_trap(x86_saved_state64_t *regs) {
  process_pmap_updates();
  funnel_lock();
  int user = (regs->cs & 3) == 3;
  if ((regs->trapno >= 0x20 && regs->trapno < 0x80) || regs->trapno >= 0xd0) {
    lapic_interrupt(regs->trapno);
    if (user) {
      sched_ast();
      bsd_ast(regs);
    }
    return;
  }
  if (user) {
    user_trap(regs);
    sched_ast();
    bsd_ast(regs);
    return;
  }
  if (regs->trapno == 14 && vm_fault(READ_CR(2), regs->err)) return;
  panic_trap(regs);
}
