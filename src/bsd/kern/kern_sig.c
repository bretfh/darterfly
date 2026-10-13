#include "../../pexpert/i386/pexpert.h"
#include "../../osfmk/i386/seg.h"
#include "../../osfmk/kern/thread.h"
#include "kern_sig.h"

uint64_t p_siglist;
struct sigacts p_sigacts[NSIG];
uint64_t sigtramp;
int sigtrace = -1;

static struct { uint64_t interval, deadline; } realtimer;

static const uint64_t unblockable = sigmask(SIGKILL) | sigmask(SIGSTOP);

static uint64_t deliverable(thread_t t) { return (t->siglist | p_siglist) & ~(t->sigmask & ~unblockable); }

static void interrupt_if_waiting(thread_t t) { thread_abort_safely(t); }

void psignal_thread(thread_t t, int sig) {
  if (sig <= 0 || sig >= NSIG) return;
  t->siglist |= sigmask(sig);
  if (deliverable(t)) interrupt_if_waiting(t);
}

void psignal(int sig) {
  if (sig <= 0 || sig >= NSIG) return;
  p_siglist |= sigmask(sig);
  for (thread_t t = all_threads; t; t = t->all_next)
    if (t->state != TH_TERMINATE && !(t->sigmask & sigmask(sig))) {
      interrupt_if_waiting(t);
      return;
    }
}

int issignal(void) {
  uint64_t ready = deliverable(current_thread());
  return ready ? __builtin_ctzll(ready) + 1 : 0;
}

void bsd_hardclock(void) {
  if (realtimer.deadline && rdtsc() >= realtimer.deadline) {
    psignal(SIGALRM);
    realtimer.deadline = realtimer.interval ? rdtsc() + realtimer.interval : 0;
  }
}

void bsd_console_interrupt_char(void) { psignal(SIGINT); }

void bsd_ast(x86_saved_state64_t *regs) {
  thread_t self = current_thread();
  self->sched_flags &= ~TH_SFLAG_ABORTSAFELY;
  int sig;
  if (sigtrace < 0) sigtrace = PE_parse_boot_arg("sigtrace");
  while ((sig = issignal())) {
    if (self->siglist & sigmask(sig)) self->siglist &= ~sigmask(sig);
    else p_siglist &= ~sigmask(sig);
    if (sigtrace) kprintf("[ast: thread 0x%lx deliver %d at 0x%lx mask 0x%lx]\n", self->thread_id, sig, regs->rip, self->sigmask);
    if (p_sigacts[sig].handler == SIG_IGN_VALUE) continue;
    sendsig(regs, sig, 0, 0);
    return;
  }
}

int tsleep(int (*ready)(void), uint64_t event, uint64_t deadline) {
  for (;;) {
    if (ready && ready()) return 0;
    if (issignal()) return EINTR;
    if (deadline && rdtsc() >= deadline) return ETIMEDOUT;
    int r = thread_wait(event, deadline);
    if (r == THREAD_INTERRUPTED && issignal()) return EINTR;
    if (r == THREAD_TIMED_OUT) return ETIMEDOUT;
    if (!ready && r == THREAD_AWAKENED && event) return 0;
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
