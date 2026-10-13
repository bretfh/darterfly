#include "../../../pexpert/i386/pexpert.h"
#include "../../../osfmk/i386/seg.h"
#include "../../../osfmk/vm/vm.h"

#define EBADF 9
#define ENOMEM 12
#define EINVAL 22
#define ENOSYS 78

#define DARWIN_MAP_FIXED 0x10
#define DARWIN_MAP_ANON 0x1000

extern uint64_t sigtramp;
void sigreturn(x86_saved_state64_t *regs, void *uc);
int serial_getc(void);

static void ok(x86_saved_state64_t *regs, uint64_t value) {
  regs->rax = value;
  regs->rflags &= ~1ull;
}

static void error(x86_saved_state64_t *regs, int code) {
  regs->rax = (uint64_t)code;
  regs->rflags |= 1ull;
}

void unix_syscall(x86_saved_state64_t *regs) {
  uint64_t a = regs->rdi, b = regs->rsi, c = regs->rdx, d = regs->r10, e = regs->r8;
  switch (regs->rax) {
  case 1:
    kprintf("exit(%d)\n", (int)a);
    PE_halt();
  case 3: {
    if (a != 0) return error(regs, EBADF);
    char *buf = (char *)b;
    uint64_t n = 0;
    if (c == 0) return ok(regs, 0);
    buf[n++] = (char)serial_getc();
    return ok(regs, n);
  }
  case 4: {
    if (a != 1 && a != 2) return error(regs, EBADF);
    const char *buf = (const char *)b;
    for (uint64_t i = 0; i < c; i++) serial_putc(buf[i]);
    return ok(regs, c);
  }
  case 20: return ok(regs, 1);
  case 46:
    if (b) sigtramp = *(uint64_t *)(b + 8);
    return ok(regs, 0);
  case 48: return ok(regs, 0);
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
  case 5: return ok(regs, inb(0x3f8 + 5) & 1);
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
