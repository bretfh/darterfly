#include "../../../pexpert/i386/pexpert.h"
#include "../../../osfmk/i386/seg.h"
#include "../../kern/kern_sig.h"
#include "../../../osfmk/kern/thread.h"

typedef struct {
  uint8_t fxsave[512];
  uint64_t sigmask[16];
  x86_saved_state64_t ss;
} __attribute__((aligned(16))) user_ucontext;

typedef struct {
  int si_signo, si_errno, si_code, pad;
  uint64_t si_addr;
  uint8_t rest[104];
} user_siginfo;

int sendsig(x86_saved_state64_t *regs, int sig, int code, uint64_t addr) {
  if (!sigtramp) return 0;
  uint64_t sp = (regs->rsp - 128 - sizeof(user_ucontext)) & ~15ull;
  user_ucontext *uc = (user_ucontext *)sp;
  sp = (sp - sizeof(user_siginfo)) & ~15ull;
  user_siginfo *si = (user_siginfo *)sp;
  sp -= 8;
  *(uint64_t *)sp = 0;
  __asm__ volatile("fxsave64 %0" : "=m"(uc->fxsave));
  for (int i = 0; i < 16; i++) uc->sigmask[i] = 0;
  uc->sigmask[0] = current_thread()->sigmask;
  uc->ss = *regs;
  si->si_signo = sig;
  si->si_errno = 0;
  si->si_code = code;
  si->si_addr = addr;
  struct sigacts *act = &p_sigacts[sig];
  current_thread()->sigmask |= act->mask;
  if (!(act->flags & SA_NODEFER)) current_thread()->sigmask |= sigmask(sig);
  if (act->flags & SA_RESETHAND) act->handler = 0;
  regs->rip = sigtramp;
  regs->rdi = (uint64_t)sig;
  regs->rsi = (uint64_t)si;
  regs->rdx = (uint64_t)uc;
  regs->rsp = sp;
  regs->rflags &= ~0x100ull;
  return 1;
}

void sigreturn(x86_saved_state64_t *regs, user_ucontext *uc) {
  __asm__ volatile("fxrstor64 %0" ::"m"(uc->fxsave));
  uint64_t rflags = regs->rflags;
  *regs = uc->ss;
  regs->cs = USER64_CS;
  regs->ss = USER_DS;
  regs->rflags = (uc->ss.rflags & 0x0dd5ull) | (rflags & ~0x0dd5ull);
  current_thread()->sigmask = uc->sigmask[0] & ~(sigmask(SIGKILL) | sigmask(SIGSTOP));
}
