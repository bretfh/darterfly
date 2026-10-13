#include "../../pexpert/i386/pexpert.h"
#include "../../osfmk/i386/seg.h"
#include "kern_sig.h"

uint64_t p_sigmask, p_siglist;
struct sigacts p_sigacts[NSIG];
uint64_t sigtramp;

static struct { uint64_t interval, deadline; } realtimer;

static uint64_t rdtsc(void) {
  uint32_t lo, hi;
  __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
  return ((uint64_t)hi << 32) | lo;
}

void psignal(int sig) {
  if (sig > 0 && sig < NSIG) p_siglist |= sigmask(sig);
}

int issignal(void) {
  uint64_t ready = p_siglist & ~(p_sigmask & ~(sigmask(SIGKILL) | sigmask(SIGSTOP)));
  return ready ? __builtin_ctzll(ready) + 1 : 0;
}

void bsd_hardclock(void) {
  if (realtimer.deadline && rdtsc() >= realtimer.deadline) {
    psignal(SIGALRM);
    realtimer.deadline = realtimer.interval ? rdtsc() + realtimer.interval : 0;
  }
}

void bsd_console_interrupt_char(void) { psignal(SIGINT); }

int sigtrace = -1;

void bsd_ast(x86_saved_state64_t *regs) {
  int sig;
  if (sigtrace < 0) sigtrace = PE_parse_boot_arg("sigtrace");
  while ((sig = issignal())) {
    p_siglist &= ~sigmask(sig);
    if (sigtrace) kprintf("[ast: deliver %d at 0x%lx mask 0x%lx]\n", sig, regs->rip, p_sigmask);
    if (p_sigacts[sig].handler == SIG_IGN_VALUE) continue;
    sendsig(regs, sig, 0, 0);
    return;
  }
}

int tsleep(int (*ready)(void), uint64_t deadline) {
  for (;;) {
    if (ready && ready()) return 0;
    if (issignal()) return EINTR;
    if (deadline && rdtsc() >= deadline) return ETIMEDOUT;
    __asm__ volatile("sti; hlt; cli");
  }
}

extern struct { uint64_t tsc_hz, tsc_base, epoch_base; } commpage;

static uint64_t usec_to_tsc(int64_t sec, int64_t usec) {
  return (uint64_t)sec * commpage.tsc_hz + (uint64_t)usec * (commpage.tsc_hz / 1000000);
}

static void tsc_to_timeval(uint64_t t, int64_t *tv) {
  tv[0] = (int64_t)(t / commpage.tsc_hz);
  tv[1] = (int64_t)(t % commpage.tsc_hz / (commpage.tsc_hz / 1000000));
}

void getitimer_real(int64_t *out) {
  uint64_t now = rdtsc();
  tsc_to_timeval(realtimer.interval, out);
  tsc_to_timeval(realtimer.deadline > now ? realtimer.deadline - now : 0, out + 2);
}

void setitimer_real(const int64_t *in, int64_t *old) {
  if (old) getitimer_real(old);
  realtimer.interval = usec_to_tsc(in[0], in[1]);
  uint64_t value = usec_to_tsc(in[2], in[3]);
  realtimer.deadline = value ? rdtsc() + value : 0;
}

uint64_t deadline_after(int64_t sec, int64_t nsec) { return rdtsc() + usec_to_tsc(sec, nsec / 1000); }
