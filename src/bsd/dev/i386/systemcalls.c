#include "../../../pexpert/i386/pexpert.h"
#include "../../../osfmk/i386/seg.h"
#include "../../../osfmk/vm/vm.h"
#include "../../kern/kern_sig.h"

#define EBADF 9
#define ENOMEM 12
#define EINVAL 22
#define ENOSYS 78

#define DARWIN_MAP_FIXED 0x10
#define DARWIN_MAP_ANON 0x1000

void sigreturn(x86_saved_state64_t *regs, void *uc);

static void ok(x86_saved_state64_t *regs, uint64_t value) {
  regs->rax = value;
  regs->rflags &= ~1ull;
}

static void error(x86_saved_state64_t *regs, int code) {
  regs->rax = (uint64_t)code;
  regs->rflags |= 1ull;
}

extern int sigtrace;

void unix_syscall(x86_saved_state64_t *regs) {
  uint64_t a = regs->rdi, b = regs->rsi, c = regs->rdx, d = regs->r10, e = regs->r8;
  if (sigtrace > 0 && regs->rax != 3 && regs->rax != 4 && regs->rax != 197 && regs->rax != 75)
    kprintf("[syscall %lu (0x%lx, 0x%lx, 0x%lx) mask 0x%lx pending 0x%lx]\n", regs->rax, a, b && regs->rax == 48 ? *(uint64_t *)b : b, c, p_sigmask, p_siglist);
  switch (regs->rax) {
  case 1:
    kprintf("exit(%d)\n", (int)a);
    PE_halt();
  case 3: {
    if (a != 0) return error(regs, EBADF);
    char *buf = (char *)b;
    uint64_t n = 0;
    if (c == 0) return ok(regs, 0);
    int r = tsleep(serial_ready, 0);
    if (r) return error(regs, r);
    while (n < c && serial_ready()) buf[n++] = (char)serial_getc();
    return ok(regs, n);
  }
  case 4: {
    if (a != 1 && a != 2) return error(regs, EBADF);
    const char *buf = (const char *)b;
    for (uint64_t i = 0; i < c; i++) serial_putc(buf[i]);
    return ok(regs, c);
  }
  case 20: return ok(regs, 1);
  case 37:
    psignal((int)b);
    return ok(regs, 0);
  case 46: {
    if (a == 0 || a >= NSIG) return error(regs, EINVAL);
    if (c) {
      struct sigacts *o = (struct sigacts *)c;
      *o = p_sigacts[a];
    }
    if (b) {
      uint64_t *nsa = (uint64_t *)b;
      sigtramp = nsa[1];
      p_sigacts[a].handler = nsa[0];
      p_sigacts[a].mask = nsa[2];
      p_sigacts[a].flags = (uint32_t)nsa[3];
    }
    return ok(regs, 0);
  }
  case 48: {
    uint64_t old = p_sigmask;
    if (b) {
      uint64_t set = *(uint64_t *)b;
      if (a == 0) p_sigmask |= set;
      else if (a == 1) p_sigmask &= ~set;
      else p_sigmask = set;
      p_sigmask &= ~(sigmask(SIGKILL) | sigmask(SIGSTOP));
    }
    if (c) *(uint64_t *)c = old;
    return ok(regs, 0);
  }
  case 83:
    if (a != 0) return error(regs, EINVAL);
    setitimer_real((const int64_t *)b, (int64_t *)c);
    return ok(regs, 0);
  case 86:
    if (a != 0) return error(regs, EINVAL);
    getitimer_real((int64_t *)b);
    return ok(regs, 0);
  case 230: {
    struct pollfd { int fd; short events, revents; } *fds = (void *)a;
    uint64_t deadline = (int)c < 0 ? 0 : deadline_after((int)c / 1000, (int64_t)((int)c % 1000) * 1000000);
    for (;;) {
      int ready = 0;
      for (uint64_t i = 0; i < b; i++) {
        fds[i].revents = 0;
        if (fds[i].fd == 1 || fds[i].fd == 2) fds[i].revents = fds[i].events & 4;
        if (fds[i].fd == 0 && (fds[i].events & 1) && serial_ready()) fds[i].revents |= 1;
        if (fds[i].revents) ready++;
      }
      if (ready || (int)c == 0) return ok(regs, ready);
      int r = tsleep(serial_ready, deadline);
      if (r == EINTR) return error(regs, EINTR);
      if (r == ETIMEDOUT) return ok(regs, 0);
    }
  }
  case 334: {
    int r = tsleep(0, deadline_after((int64_t)a, (int64_t)b));
    if (r == EINTR) return error(regs, EINTR);
    return ok(regs, 0);
  }
  case 73:
    vm_map_remove(a, b);
    return ok(regs, 0);
  case 74:
    vm_map_protect(a, b, (int)c);
    return ok(regs, 0);
  case 75:
    if (c == 4) pmap_remove(a & ~4095ull, ((a + b + 4095) & ~4095ull) - (a & ~4095ull));
    return ok(regs, 0);
  case 184:
    sigreturn(regs, (void *)a);
    return;
  case 197: {
    if (!(d & DARWIN_MAP_ANON)) return error(regs, ENOSYS);
    uint64_t at = (d & DARWIN_MAP_FIXED) || a ? a : vm_map_find_space(b);
    (void)e;
    vm_map_enter(at, b, (int)c);
    return ok(regs, at);
  }
  default:
    kprintf("unix_syscall: %lu not implemented\n", regs->rax);
    return error(regs, ENOSYS);
  }
}

extern char commpage[];
extern boot_args *PE_boot_args;

void machdep_syscall(x86_saved_state64_t *regs) {
  switch (regs->rax) {
  case 4: return ok(regs, (uint64_t)commpage);
  case 5: return ok(regs, serial_ready());
  case 6: {
    uint64_t *out = (uint64_t *)regs->rdi;
    out[0] = (uint64_t)PHYSMAP_PTOV(PE_boot_args->kernelFileStart);
    out[1] = PE_boot_args->kernelFileSize;
    return ok(regs, 0);
  }
  case 3: {
    uint64_t base = regs->rdi;
    __asm__ volatile("wrmsr" ::"c"(0xc0000100), "a"((uint32_t)base), "d"((uint32_t)(base >> 32)));
    return ok(regs, 0);
  }
  default:
    return error(regs, ENOSYS);
  }
}
